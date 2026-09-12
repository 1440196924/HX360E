/**
 ******************************************************************************
 * HX360E : OHAudio audio system factory (Phase 3).
 ******************************************************************************
 */
#include "ohaudio_audio_system.h"

#include "ohaudio_audio_driver.h"

namespace xe {
namespace apu {
namespace ohaudio {

OHaudioAudioSystem::OHaudioAudioSystem(cpu::Processor* processor)
    : AudioSystem(processor) {}

OHaudioAudioSystem::~OHaudioAudioSystem() = default;

std::string OHaudioAudioSystem::name() const { return "OHAudio"; }

std::unique_ptr<AudioSystem> OHaudioAudioSystem::Create(
    cpu::Processor* processor) {
  return std::make_unique<OHaudioAudioSystem>(processor);
}

X_STATUS OHaudioAudioSystem::CreateDriver(
    size_t index, xe::threading::Semaphore* semaphore,
    AudioDriver** out_driver) {
  auto driver = std::make_unique<OHaudioAudioDriver>(memory_, semaphore);
  if (!driver->Initialize()) {
    driver->Shutdown();
    return X_STATUS_UNSUCCESSFUL;
  }

  *out_driver = driver.release();
  return X_STATUS_SUCCESS;
}

void OHaudioAudioSystem::DestroyDriver(AudioDriver* driver) {
  assert_not_null(driver);
  auto ohaudio_driver = dynamic_cast<OHaudioAudioDriver*>(driver);
  assert_not_null(ohaudio_driver);
  ohaudio_driver->Shutdown();
  delete ohaudio_driver;
}

AudioDriver* OHaudioAudioSystem::CreateDriver(xe::threading::Semaphore* semaphore,
                                              uint32_t frequency,
                                              uint32_t channels,
                                              bool need_format_conversion) {
  // 媒体播放器按歌曲自己的速率创建：交错、主机端序、立体声。忽略这些并按 5.1
  // 做字节交换会把游戏音频当满幅噪声播放。
  return new OHaudioAudioDriver(memory_, semaphore, frequency, channels,
                                 need_format_conversion);
}

}  // namespace ohaudio
}  // namespace apu
}  // namespace xe
