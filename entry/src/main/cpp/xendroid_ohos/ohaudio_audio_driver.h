/**
 ******************************************************************************
 * HX360E : OHAudio audio driver (Phase 3).
 *
 * 结构照搬上游 Android 的 xe_aaudio_audio_driver.{h,cc}（见 DESIGN.md §7），
 * 只把 API 层从 AAudio 换成 OHOS OHAudio：
 *   AAudioStreamBuilder_*          -> OH_AudioStreamBuilder_*
 *   AAudioStream_*                 -> OH_AudioRenderer_*
 *   FLOAT32 / LOW_LATENCY / xrun   -> F32LE / AUDIOSTREAM_LATENCY_MODE_FAST /
 *                                     OH_AudioRenderer_GetUnderflowCount
 * 保留上游三个设计：软件音量、欠载/换设备重建、以及 6ch(BE 顺序) -> 立体声的重采样。
 ******************************************************************************
 */
#ifndef HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_DRIVER_H_
#define HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_DRIVER_H_

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <queue>
#include <stack>
#include <thread>
#include <vector>

#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

#include "xenia/apu/audio_driver.h"
#include "xenia/base/threading.h"

namespace xe {
namespace apu {
namespace ohaudio {

class OHaudioAudioDriver : public AudioDriver {
 public:
  // channels 选择提交契约（对齐 SDLAudioDriver）：6 = 游戏路径，每声道 256 个
  // 顺序排列的大端 5.1 样本；2 = 媒体播放器，768 帧交错主机端序立体声。
  // 两者每 SubmitFrame 都是 1536 个 float。
  OHaudioAudioDriver(Memory* memory, xe::threading::Semaphore* semaphore,
                     uint32_t frequency = 48000, uint32_t channels = 6,
                     bool need_format_conversion = true);
  ~OHaudioAudioDriver() override;

  bool Initialize();
  void Pause() override;
  void Resume() override;
  void SetVolume(float volume) override;
  size_t GetQueuedFrameCount() override;
  void SubmitFrame(float* frame) override;
  void Shutdown();

 protected:
  // OHAudio 旧式回调（一次 SetRendererCallback 同时装上 data/中断/错误）。
  static int32_t AudioCallback(OH_AudioRenderer* renderer, void* userdata,
                               void* audio_data, int32_t length);
  static int32_t AudioInterruptCallback(OH_AudioRenderer* renderer,
                                        void* userdata,
                                        OH_AudioInterrupt_ForceType type,
                                        OH_AudioInterrupt_Hint hint);
  static int32_t AudioErrorCallback(OH_AudioRenderer* renderer, void* userdata,
                                    OH_AudioStream_Result error);

  // 仅回调线程。
  void ApplyFadeIn();
  // OHAudio 不走系统音量，这里在软件里做。
  // 仅回调线程。
  void ApplyGainAndClamp();

  // 在当前默认设备上(重新)打开流；调用方持有 renderer_mutex_。
  bool BuildRenderer();
  // 重建流；只在 recovery_thread_ 上跑。
  bool RestartRenderer();
  void RecoveryThreadMain();
  // 回调线程/任意线程：置重建请求并唤醒恢复线程。
  void RequestRestart(const char* reason);

  xe::threading::Semaphore* semaphore_ = nullptr;

  OH_AudioStreamBuilder* builder_ = nullptr;
  OH_AudioRenderer* renderer_ = nullptr;
  bool renderer_initialized_ = false;
  // 序列化流的生命周期。数据回调用它的 renderer 参数，不取这把锁。
  std::mutex renderer_mutex_ = {};

  // 换输出设备恢复：错误/中断回调只置标志，recovery_thread_ 负责 close+reopen
  // （OHAudio 同样不允许在回调线程里 Release）。
  std::thread recovery_thread_ = {};
  std::mutex recovery_mutex_ = {};
  std::condition_variable recovery_cv_ = {};
  bool restart_requested_ = false;
  bool recovery_quit_ = false;
  std::atomic<bool> shutting_down_{false};

  static constexpr uint32_t host_frame_channels_ = 2;
  const uint32_t frame_frequency_;
  const uint32_t frame_channels_;
  const bool need_format_conversion_;
  const uint32_t channel_samples_;
  const uint32_t submit_samples_;
  const uint32_t host_block_samples_;
  std::queue<float*> frames_queued_ = {};
  std::stack<float*> frames_unused_ = {};
  std::mutex frames_mutex_ = {};

  // 欠载掩盖：直接给静音会在每段间隙两端产生阶跃（5.3ms 块 → 约 187Hz 的咔哒声）。
  // 仅回调线程。
  std::vector<float> last_block_;
  bool last_block_valid_ = false;
  // last_block_ 中已交给设备的帧数。
  uint32_t last_block_pos_ = channel_samples_;
  uint32_t gap_blocks_ = 0;

  bool fade_in_pending_ = false;

  // 速率控制；仅回调线程。
  float rate_ = 1.0f;
  float resample_frac_ = 0.0f;
  float prev_l_ = 0.0f, prev_r_ = 0.0f;
  float cur_l_ = 0.0f, cur_r_ = 0.0f;
  float conceal_gain_ = 1.0f;

  void LoadNextBlock(uint32_t& releases, bool& gapped);
  void ConcealNextBlock();

  // 实时回调写、recovery_thread_ 读：只用 relaxed 原子，不做可能阻塞的操作。
  std::atomic<uint64_t> stat_callbacks_{0};
  std::atomic<uint64_t> stat_gaps_{0};
  std::atomic<uint64_t> stat_queue_depth_sum_{0};
  std::atomic<uint32_t> stat_queue_depth_max_{0};
  std::atomic<int32_t> stat_unexpected_frames_{0};
  std::atomic<uint64_t> stat_clipped_{0};
  std::atomic<uint32_t> stat_rate_milli_{1000};
  void LogAndResetStats();

  // 每驱动音量（XMP）：其它线程写，回调读。
  std::atomic<float> driver_volume_{1.0f};
};

}  // namespace ohaudio
}  // namespace apu
}  // namespace xe

#endif  // HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_DRIVER_H_
