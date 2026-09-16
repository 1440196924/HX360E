#ifndef HX360E_XENDROID_OHOS_OHOS_INPUT_DRIVER_H_
#define HX360E_XENDROID_OHOS_OHOS_INPUT_DRIVER_H_

#include <mutex>
#include <vector>

#include "xenia/hid/input_driver.h"
#include "xenia/ui/virtual_key.h"

namespace hx360e {

// xbox.h 的 X_STATUS_SUCCESS / X_ERROR_* 宏在展开时使用未限定名 X_STATUS /
// X_RESULT（宏体不受命名空间影响），把名字引入本命名空间后宏才能展开。
using xe::X_RESULT;
using xe::X_STATUS;

// Index into OhosInputDriver::key_status_. The order MUST match the vector
// built in the constructor, because InputSystem addresses slots by index and
// the ArkTS overlay / NAPI keyEvent passes these values through verbatim.
enum OhosPadKey {
  kPadDpadLeft = 0,
  kPadDpadUp,
  kPadDpadRight,
  kPadDpadDown,
  kPadA,
  kPadB,
  kPadX,
  kPadY,
  kPadBack,
  kPadStart,
  kPadLShoulder,
  kPadRShoulder,
  kPadLThumbPress,
  kPadRThumbPress,
  kPadLTrigger,
  kPadRTrigger,
  kPadLThumbLeft,
  kPadLThumbUp,
  kPadLThumbRight,
  kPadLThumbDown,
  kPadRThumbLeft,
  kPadRThumbUp,
  kPadRThumbRight,
  kPadRThumbDown,
  kPadKeyCount
};

// XenDroid's InputSystem only routes guest input to drivers bound to a slot,
// and bindings are built from EnumerateDevices(), so the driver advertises one
// always-present controller (same trick as xe_android_input_driver.cpp).
class OhosInputDriver : public xe::hid::InputDriver {
 public:
  OhosInputDriver(xe::ui::Window* window, size_t window_z_order);
  ~OhosInputDriver() override;

  xe::X_STATUS Setup() override;
  xe::X_RESULT GetCapabilities(uint32_t user_index, uint32_t flags,
                               xe::hid::X_INPUT_CAPABILITIES* out_caps) override;
  xe::X_RESULT GetState(uint32_t user_index,
                        xe::hid::X_INPUT_STATE* out_state) override;
  xe::X_RESULT SetState(uint32_t user_index,
                        xe::hid::X_INPUT_VIBRATION* vibration) override;
  xe::X_RESULT GetKeystroke(uint32_t user_index, uint32_t flags,
                            xe::hid::X_INPUT_KEYSTROKE* out_keystroke) override;

  xe::hid::InputType GetInputType() const override;
  std::vector<xe::hid::InputDeviceInfo> EnumerateDevices() override;

  // Feeds one control state change. Safe to call from any thread (the NAPI
  // keyEvent and the GameControllerKit monitors both land here).
  // `key_index` is an OhosPadKey; `value` is the signed analog value in
  // [-32767, 32767] for sticks and [0, 255] for triggers (ignored otherwise).
  void OnKey(int key_index, bool pressed, short value);

  // Physical pad via OHOS GameControllerKit (libohgame_controller.z.so).
  void StartPhysicalGamepad();
  void StopPhysicalGamepad();

  // Test hook: release every control (used when the overlay disappears).
  void ReleaseAll();

 private:
  struct KeyStatus {
    xe::ui::VirtualKey id;
    bool pressed;
    short value;
  };

  std::vector<KeyStatus> key_status_;
  std::vector<KeyStatus> prev_key_status_;
  std::mutex key_status_mutex_;
  // One pending keystroke per key, drained by GetKeystroke.
  uint32_t key_status_mask_ = 0;
  uint32_t packet_number_ = 0;

  bool physical_pad_started_ = false;
};

// --- 物理手柄诊断（每秒探针用）-----------------------------------------
// 注册成功的监视器数量与累计收到的事件数。ev 一直为 0 说明事件没来（注册/系统
// 侧问题）；ev 在涨但游戏没反应说明映射/注入环节的问题。
uint32_t PadRegisteredButtonMonitors();
uint32_t PadRegisteredAxisMonitors();
uint64_t PadEventCount();
const char* PadLastEvent();
// 重新武装监视器（把手柄在启动前就插好的场景也覆盖到）。
void PadRearmPhysical();

}  // namespace hx360e

#endif  // HX360E_XENDROID_OHOS_OHOS_INPUT_DRIVER_H_
