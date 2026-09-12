/**
 ******************************************************************************
 * HX360E : OHAudio audio driver (Phase 3).
 * 结构照搬上游 xe_aaudio_audio_driver.cpp，API 换 OHAudio。
 ******************************************************************************
 */
#include "ohaudio_audio_driver.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>

#include "xenia/apu/apu_flags.h"
#include "xenia/apu/conversion.h"
#include "xenia/base/assert.h"
#include "xenia/base/cvar.h"
#include "xenia/base/logging.h"
#include "xenia/base/profiling.h"

DEFINE_bool(apu_ohaudio_dynamic_rate, true,
            "Slow playback toward 0.9x as the audio queue drains, so a guest "
            "that cannot keep real time bends pitch instead of popping.",
            "APU");
DEFINE_bool(apu_ohaudio_log_stats, false,
            "Log OHOS audio callback statistics (gaps, queue depth, underruns) "
            "once a second.",
            "APU");

namespace xe {
namespace apu {
namespace ohaudio {

static constexpr uint32_t kStatsIntervalMs = 1000;

// 队列深度低于该值时放慢播放，给生产者争取时间。
static constexpr uint32_t kRateControlDepth = 3;

OHaudioAudioDriver::OHaudioAudioDriver(Memory* memory,
                                       xe::threading::Semaphore* semaphore,
                                       uint32_t frequency, uint32_t channels,
                                       bool need_format_conversion)
    : semaphore_(semaphore),
      frame_frequency_(frequency),
      frame_channels_(channels),
      need_format_conversion_(need_format_conversion),
      channel_samples_(channels == 6 ? 256 : 768),
      submit_samples_(channels * (channels == 6 ? 256 : 768)),
      host_block_samples_(host_frame_channels_ * (channels == 6 ? 256 : 768)) {
  assert_true(channels == 6 || channels == 2);
  last_block_.resize(host_block_samples_, 0.0f);
}

OHaudioAudioDriver::~OHaudioAudioDriver() {
  assert_true(frames_queued_.empty());
  assert_true(frames_unused_.empty());
}

bool OHaudioAudioDriver::Initialize() {
  {
    std::unique_lock<std::mutex> guard(frames_mutex_);
    for (int i = 0; i < 2; i++) {
      float* buffer = new float[submit_samples_];
      frames_unused_.push(buffer);
    }
  }

  {
    std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
    if (!BuildRenderer()) {
      return false;
    }
  }

  recovery_thread_ = std::thread(&OHaudioAudioDriver::RecoveryThreadMain, this);
  return true;
}

bool OHaudioAudioDriver::BuildRenderer() {
  OH_AudioStream_Result result =
      OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
  if (result != AUDIOSTREAM_SUCCESS) {
    XELOGE("OH_AudioStreamBuilder_Create failed: {}", static_cast<int>(result));
    builder_ = nullptr;
    return false;
  }

  OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_F32LE);
  OH_AudioStreamBuilder_SetSamplingRate(builder_,
                                        static_cast<int32_t>(frame_frequency_));
  OH_AudioStreamBuilder_SetChannelCount(builder_,
                                        static_cast<int32_t>(host_frame_channels_));
  OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
  // 请求每个回调的帧数（近似 AAudio 的 setFramesPerDataCallback）。
  OH_AudioStreamBuilder_SetFrameSizeInCallback(
      builder_, static_cast<int32_t>(channel_samples_));

  OH_AudioRenderer_Callbacks callbacks = {};
  callbacks.OH_AudioRenderer_OnWriteData = AudioCallback;
  callbacks.OH_AudioRenderer_OnInterruptEvent = AudioInterruptCallback;
  callbacks.OH_AudioRenderer_OnError = AudioErrorCallback;
  OH_AudioStreamBuilder_SetRendererCallback(builder_, callbacks, this);

  result = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
  if (result != AUDIOSTREAM_SUCCESS) {
    XELOGE("OH_AudioStreamBuilder_GenerateRenderer failed: {}",
           static_cast<int>(result));
    OH_AudioStreamBuilder_Destroy(builder_);
    builder_ = nullptr;
    return false;
  }

  result = OH_AudioRenderer_Start(renderer_);
  if (result != AUDIOSTREAM_SUCCESS) {
    XELOGE("OH_AudioRenderer_Start failed: {}", static_cast<int>(result));
    OH_AudioRenderer_Release(renderer_);
    renderer_ = nullptr;
    OH_AudioStreamBuilder_Destroy(builder_);
    builder_ = nullptr;
    return false;
  }

  int32_t rate = 0;
  int32_t channels = 0;
  int32_t callback_frames = 0;
  OH_AudioRenderer_GetSamplingRate(renderer_, &rate);
  OH_AudioRenderer_GetChannelCount(renderer_, &channels);
  OH_AudioRenderer_GetFrameSizeInCallback(renderer_, &callback_frames);
  XELOGI(
      "OHAudio: rate {}, {} ch, callback {} frames (asked {}), latency FAST",
      rate, channels, callback_frames, channel_samples_);

  renderer_initialized_ = true;
  return true;
}

void OHaudioAudioDriver::Pause() {
  std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
  if (renderer_initialized_ && renderer_) {
    OH_AudioRenderer_Pause(renderer_);
  }
}

void OHaudioAudioDriver::Resume() {
  std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
  rate_ = 1.0f;
  conceal_gain_ = 1.0f;
  gap_blocks_ = 0;
  stat_rate_milli_.store(1000, std::memory_order_relaxed);
  if (renderer_initialized_ && renderer_) {
    OH_AudioRenderer_Start(renderer_);
  }
}

size_t OHaudioAudioDriver::GetQueuedFrameCount() {
  std::unique_lock<std::mutex> guard(frames_mutex_);
  return frames_queued_.size();
}

void OHaudioAudioDriver::SetVolume(float volume) {
  // OHAudio 不走系统音量，回调里对样本做增益。
  driver_volume_.store(std::clamp(volume, 0.0f, 1.0f),
                       std::memory_order_relaxed);
}

int32_t OHaudioAudioDriver::AudioCallback(OH_AudioRenderer* renderer,
                                          void* userdata, void* audio_data,
                                          int32_t length) {
  SCOPE_profile_cpu_f("apu");

  auto driver = static_cast<OHaudioAudioDriver*>(userdata);
  float* output_buffer = reinterpret_cast<float*>(audio_data);

  const int32_t numFrames =
      length / static_cast<int32_t>(host_frame_channels_ * sizeof(float));

  // setFrameSizeInCallback 只是请求，实际回调帧数可能不同；下面的转换用
  // channel_samples_ 作为源步长，必须以该尺寸运行。
  if (numFrames != static_cast<int32_t>(driver->channel_samples_)) {
    driver->stat_unexpected_frames_.store(numFrames, std::memory_order_relaxed);
  }

  driver->stat_callbacks_.fetch_add(1, std::memory_order_relaxed);

  uint32_t depth_now;
  {
    std::unique_lock<std::mutex> guard(driver->frames_mutex_);
    depth_now = static_cast<uint32_t>(driver->frames_queued_.size());
  }
  float rate_target = 1.0f;
  if (cvars::apu_ohaudio_dynamic_rate && depth_now < kRateControlDepth) {
    rate_target =
        std::max(0.90f, 1.0f - 0.05f * float(kRateControlDepth - depth_now));
  }
  driver->rate_ += std::clamp(rate_target - driver->rate_, -0.003f, 0.003f);
  driver->stat_rate_milli_.store(
      static_cast<uint32_t>(driver->rate_ * 1000.0f + 0.5f),
      std::memory_order_relaxed);

  int32_t frames_done = 0;
  uint32_t releases = 0;
  bool gapped = false;
  while (frames_done < numFrames) {
    while (driver->resample_frac_ >= 1.0f) {
      driver->resample_frac_ -= 1.0f;
      if (driver->last_block_pos_ >= driver->channel_samples_) {
        driver->LoadNextBlock(releases, gapped);
      }
      driver->prev_l_ = driver->cur_l_;
      driver->prev_r_ = driver->cur_r_;
      driver->cur_l_ = driver->last_block_[driver->last_block_pos_ * 2 + 0];
      driver->cur_r_ = driver->last_block_[driver->last_block_pos_ * 2 + 1];
      driver->last_block_pos_++;
    }
    const float f = driver->resample_frac_;
    output_buffer[frames_done * 2 + 0] =
        driver->prev_l_ + f * (driver->cur_l_ - driver->prev_l_);
    output_buffer[frames_done * 2 + 1] =
        driver->prev_r_ + f * (driver->cur_r_ - driver->prev_r_);
    frames_done++;
    driver->resample_frac_ += driver->rate_;
  }

  // 每消费一个块 tick 一次；欠载时也 tick 一次，保证 guest 引擎继续跑。
  if (releases == 0 && gapped) {
    releases = 1;
  }
  for (uint32_t i = 0; i < releases; ++i) {
    driver->semaphore_->Release(1, nullptr);
  }

  return 0;  // 成功（旧式回调：非负即可）
}

void OHaudioAudioDriver::LoadNextBlock(uint32_t& releases, bool& gapped) {
  float* buffer = nullptr;
  uint32_t depth = 0;
  {
    std::unique_lock<std::mutex> guard(frames_mutex_);
    depth = static_cast<uint32_t>(frames_queued_.size());
    if (!frames_queued_.empty()) {
      buffer = frames_queued_.front();
      frames_queued_.pop();
    }
  }
  stat_queue_depth_sum_.fetch_add(depth, std::memory_order_relaxed);
  if (depth > stat_queue_depth_max_.load(std::memory_order_relaxed)) {
    stat_queue_depth_max_.store(depth, std::memory_order_relaxed);
  }
  if (!buffer) {
    stat_gaps_.fetch_add(1, std::memory_order_relaxed);
    gapped = true;
    ConcealNextBlock();
    last_block_pos_ = 0;
    return;
  }
  if (frame_channels_ == 6) {
    conversion::sequential_6_BE_to_interleaved_2_LE(last_block_.data(), buffer,
                                                    channel_samples_);
  } else {
    std::memcpy(last_block_.data(), buffer,
                host_block_samples_ * sizeof(float));
  }
  ApplyGainAndClamp();
  ApplyFadeIn();
  last_block_valid_ = true;
  last_block_pos_ = 0;
  gap_blocks_ = 0;
  conceal_gain_ = 1.0f;
  {
    std::unique_lock<std::mutex> guard(frames_mutex_);
    frames_unused_.push(buffer);
  }
  ++releases;
}

void OHaudioAudioDriver::ConcealNextBlock() {
  if (!last_block_valid_) {
    std::memset(last_block_.data(), 0, host_block_samples_ * sizeof(float));
    return;
  }

  conceal_gain_ *= 0.6f;
  if (conceal_gain_ < 0.002f) {
    std::memset(last_block_.data(), 0, host_block_samples_ * sizeof(float));
    last_block_valid_ = false;
    gap_blocks_++;
    fade_in_pending_ = true;
    return;
  }
  const int32_t frames = static_cast<int32_t>(channel_samples_);
  const float step = frames > 0 ? (0.6f - 1.0f) / frames : 0.0f;
  for (int32_t f = 0; f < frames; ++f) {
    const float g = 1.0f + step * f;
    last_block_[f * 2 + 0] *= g;
    last_block_[f * 2 + 1] *= g;
  }
  gap_blocks_++;
  fade_in_pending_ = true;
}

void OHaudioAudioDriver::ApplyGainAndClamp() {
  const uint32_t master = std::min<uint32_t>(cvars::volume, 100);
  const float gain =
      driver_volume_.load(std::memory_order_relaxed) * (master / 100.0f);

  uint32_t clipped = 0;
  for (uint32_t i = 0; i < host_block_samples_; ++i) {
    float s = last_block_[i] * gain;
    if (s > 1.0f) {
      s = 1.0f;
      ++clipped;
    } else if (s < -1.0f) {
      s = -1.0f;
      ++clipped;
    }
    last_block_[i] = s;
  }
  if (clipped) {
    stat_clipped_.fetch_add(clipped, std::memory_order_relaxed);
  }
}

void OHaudioAudioDriver::ApplyFadeIn() {
  if (!fade_in_pending_) {
    return;
  }
  fade_in_pending_ = false;
  // 第一个真实块淡入，避免恢复边缘是阶跃。64 帧约 1.3ms。
  const int32_t ramp = 64;
  for (int32_t f = 0; f < ramp; ++f) {
    const float g = static_cast<float>(f) / ramp;
    last_block_[f * 2 + 0] *= g;
    last_block_[f * 2 + 1] *= g;
  }
}

void OHaudioAudioDriver::LogAndResetStats() {
  const uint64_t callbacks =
      stat_callbacks_.exchange(0, std::memory_order_relaxed);
  if (!callbacks) {
    return;
  }
  const uint64_t gaps = stat_gaps_.exchange(0, std::memory_order_relaxed);
  const uint64_t depth_sum =
      stat_queue_depth_sum_.exchange(0, std::memory_order_relaxed);
  const uint32_t depth_max =
      stat_queue_depth_max_.exchange(0, std::memory_order_relaxed);
  const int32_t odd_frames =
      stat_unexpected_frames_.exchange(0, std::memory_order_relaxed);
  const uint64_t clipped = stat_clipped_.exchange(0, std::memory_order_relaxed);
  const uint64_t played = (callbacks - gaps) * host_block_samples_;

  uint32_t xruns = 0;
  {
    std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
    if (renderer_initialized_ && renderer_) {
      OH_AudioRenderer_GetUnderflowCount(renderer_, &xruns);
    }
  }

  XELOGI(
      "OHAudio: {} cb, {} gaps ({:.1f}%), queue avg {:.2f} max {}, rate {:.3f}, "
      "underruns {}, clipped {} ({:.3f}%){}",
      callbacks, gaps, 100.0 * double(gaps) / double(callbacks),
      double(depth_sum) / double(callbacks), depth_max,
      stat_rate_milli_.load(std::memory_order_relaxed) / 1000.0, xruns, clipped,
      played ? 100.0 * double(clipped) / double(played) : 0.0,
      odd_frames ? fmt::format(", UNEXPECTED framesPerCallback {}", odd_frames)
                 : "");
}

void OHaudioAudioDriver::RequestRestart(const char* reason) {
  XELOGW("OHAudio stream {} - requesting stream rebuild", reason);
  {
    std::lock_guard<std::mutex> lk(recovery_mutex_);
    restart_requested_ = true;
  }
  recovery_cv_.notify_one();
}

int32_t OHaudioAudioDriver::AudioInterruptCallback(
    OH_AudioRenderer* renderer, void* userdata, OH_AudioInterrupt_ForceType type,
    OH_AudioInterrupt_Hint hint) {
  auto driver = static_cast<OHaudioAudioDriver*>(userdata);
  (void)renderer;
  (void)type;
  (void)hint;
  // 打断（如换输出设备）后需要重开流。
  driver->RequestRestart("interrupt");
  return 0;
}

int32_t OHaudioAudioDriver::AudioErrorCallback(OH_AudioRenderer* renderer,
                                               void* userdata,
                                               OH_AudioStream_Result error) {
  auto driver = static_cast<OHaudioAudioDriver*>(userdata);
  (void)renderer;
  XELOGW("OHAudio stream error: {} - requesting stream rebuild",
         static_cast<int>(error));
  driver->RequestRestart("error");
  return 0;
}

void OHaudioAudioDriver::RecoveryThreadMain() {
  bool retry_pending = false;
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(recovery_mutex_);
      auto wake = [this] { return restart_requested_ || recovery_quit_; };
      if (retry_pending) {
        recovery_cv_.wait_for(lk, std::chrono::milliseconds(250), wake);
      } else {
        recovery_cv_.wait_for(lk, std::chrono::milliseconds(kStatsIntervalMs),
                              wake);
      }
      if (recovery_quit_) {
        return;
      }
      if (!restart_requested_) {
        lk.unlock();
        if (cvars::apu_ohaudio_log_stats) {
          LogAndResetStats();
        }
        continue;
      }
      restart_requested_ = false;
    }
    retry_pending = !RestartRenderer();
  }
}

bool OHaudioAudioDriver::RestartRenderer() {
  std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
  XELOGW("OHAudio: rebuilding stream on the current default output device");
  if (renderer_) {
    OH_AudioRenderer_Stop(renderer_);
    OH_AudioRenderer_Release(renderer_);
    renderer_ = nullptr;
  }
  if (builder_) {
    OH_AudioStreamBuilder_Destroy(builder_);
    builder_ = nullptr;
  }
  renderer_initialized_ = false;

  if (shutting_down_.load(std::memory_order_acquire)) {
    return true;
  }

  if (BuildRenderer()) {
    XELOGI("OHAudio: stream rebuilt; audio output restored");
    return true;
  }
  XELOGE("OHAudio: stream rebuild failed; will retry");
  return false;
}

void OHaudioAudioDriver::SubmitFrame(float* samples) {
  float* output_frame;
  {
    std::unique_lock<std::mutex> guard(frames_mutex_);
    if (frames_unused_.empty()) {
      output_frame = new float[submit_samples_];
    } else {
      output_frame = frames_unused_.top();
      frames_unused_.pop();
    }
  }

  std::memcpy(output_frame, samples, submit_samples_ * sizeof(float));

  {
    std::unique_lock<std::mutex> guard(frames_mutex_);
    frames_queued_.push(output_frame);
  }
}

void OHaudioAudioDriver::Shutdown() {
  shutting_down_.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lk(recovery_mutex_);
    recovery_quit_ = true;
  }
  recovery_cv_.notify_one();
  if (recovery_thread_.joinable()) {
    recovery_thread_.join();
  }

  {
    std::unique_lock<std::mutex> renderer_guard(renderer_mutex_);
    if (renderer_) {
      OH_AudioRenderer_Stop(renderer_);
      OH_AudioRenderer_Release(renderer_);
      renderer_ = nullptr;
    }
    if (builder_) {
      OH_AudioStreamBuilder_Destroy(builder_);
      builder_ = nullptr;
    }
    renderer_initialized_ = false;
  }

  std::unique_lock<std::mutex> guard(frames_mutex_);
  while (!frames_unused_.empty()) {
    delete[] frames_unused_.top();
    frames_unused_.pop();
  }
  while (!frames_queued_.empty()) {
    delete[] frames_queued_.front();
    frames_queued_.pop();
  }
}

}  // namespace ohaudio
}  // namespace apu
}  // namespace xe
