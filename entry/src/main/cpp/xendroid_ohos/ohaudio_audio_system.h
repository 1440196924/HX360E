/**
 ******************************************************************************
 * HX360E : OHAudio audio system factory (Phase 3).
 * 照搬上游 xe_aaudio_audio_system，工厂换成 OHAudio 驱动。
 ******************************************************************************
 */
#ifndef HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_SYSTEM_H_
#define HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_SYSTEM_H_

#include "xenia/apu/audio_system.h"

namespace xe {
namespace apu {
namespace ohaudio {

class OHaudioAudioSystem : public AudioSystem {
 public:
  explicit OHaudioAudioSystem(cpu::Processor* processor);
  ~OHaudioAudioSystem() override;

  std::string name() const override;
  static bool IsAvailable() { return true; }

  static std::unique_ptr<AudioSystem> Create(cpu::Processor* processor);

  X_STATUS CreateDriver(size_t index, xe::threading::Semaphore* semaphore,
                        AudioDriver** out_driver) override;
  AudioDriver* CreateDriver(xe::threading::Semaphore* semaphore,
                           uint32_t frequency, uint32_t channels,
                           bool need_format_conversion) override;
  void DestroyDriver(AudioDriver* driver) override;
};

}  // namespace ohaudio
}  // namespace apu
}  // namespace xe

#endif  // HX360E_XENDROID_OHOS_OHAUDIO_AUDIO_SYSTEM_H_
