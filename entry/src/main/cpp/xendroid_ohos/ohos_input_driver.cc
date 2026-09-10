#include "ohos_input_driver.h"

#include <cmath>
#include <cstdint>

#include <GameControllerKit/game_pad.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

#define PADLOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define PADLOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace hx360e {
namespace {

OhosInputDriver* g_pad_driver = nullptr;
std::mutex g_pad_mutex;

// XInput thumb axis convention (xenia): positive Y is up, positive X is right.
constexpr double kStickDeadzone = 0.08;
constexpr double kDpadThreshold = 0.5;
constexpr double kTriggerOn = 0.02;

int16_t ScaleStick(double v) {
  if (v > 1.0) {
    v = 1.0;
  } else if (v < -1.0) {
    v = -1.0;
  }
  return static_cast<int16_t>(std::lround(v * 32767.0));
}

uint8_t ScaleTrigger(double v) {
  if (v < 0.0) {
    v = 0.0;
  } else if (v > 1.0) {
    v = 1.0;
  }
  return static_cast<uint8_t>(std::lround(v * 255.0));
}

OhosInputDriver* pad_driver() {
  std::lock_guard<std::mutex> lock(g_pad_mutex);
  return g_pad_driver;
}

template <int KeyIndex>
void PadButtonCb(const struct GamePad_ButtonEvent* event) {
  OhosInputDriver* driver = pad_driver();
  if (!driver) {
    return;
  }
  GamePad_Button_ActionType action = DOWN;
  if (OH_GamePad_ButtonEvent_GetButtonAction(event, &action) !=
      GAME_CONTROLLER_SUCCESS) {
    return;
  }
  driver->OnKey(KeyIndex, action == DOWN, 0);
}

enum class PadAxisGroup {
  kDpad,
  kLeftStick,
  kRightStick,
  kLeftTrigger,
  kRightTrigger,
};

// Sets the four direction entries of one stick / the d-pad from an x/y pair.
// Only one direction per axis is held down at a time, so GetState can simply
// take the value of the pressed entry.
void ApplyDirections(OhosInputDriver* driver, int left_key, int right_key,
                     int up_key, int down_key, double x, double y,
                     int16_t x_value, int16_t y_value) {
  driver->OnKey(left_key, x < -kStickDeadzone, x_value);
  driver->OnKey(right_key, x > kStickDeadzone, x_value);
  driver->OnKey(down_key, y < -kStickDeadzone, y_value);
  driver->OnKey(up_key, y > kStickDeadzone, y_value);
}

void HandlePadAxis(PadAxisGroup group, const struct GamePad_AxisEvent* event) {
  OhosInputDriver* driver = pad_driver();
  if (!driver) {
    return;
  }
  GamePad_AxisSourceType source = DPAD;
  if (OH_GamePad_AxisEvent_GetAxisSourceType(event, &source) !=
      GAME_CONTROLLER_SUCCESS) {
    return;
  }
  switch (group) {
    case PadAxisGroup::kDpad:
    case PadAxisGroup::kLeftStick:
    case PadAxisGroup::kRightStick: {
      double x = 0.0;
      double y = 0.0;
      OH_GamePad_AxisEvent_GetXAxisValue(event, &x);
      OH_GamePad_AxisEvent_GetYAxisValue(event, &y);
      const int16_t x_value = ScaleStick(x);
      const int16_t y_value = ScaleStick(y);
      (void)source;
      if (group == PadAxisGroup::kDpad) {
        ApplyDirections(driver, kPadDpadLeft, kPadDpadRight, kPadDpadUp,
                        kPadDpadDown, x, y,
                        x < 0 ? int16_t(-32767) : int16_t(32767),
                        y < 0 ? int16_t(-32767) : int16_t(32767));
      } else if (group == PadAxisGroup::kLeftStick) {
        ApplyDirections(driver, kPadLThumbLeft, kPadLThumbRight, kPadLThumbUp,
                        kPadLThumbDown, x, y, x_value, y_value);
      } else {
        ApplyDirections(driver, kPadRThumbLeft, kPadRThumbRight, kPadRThumbUp,
                        kPadRThumbDown, x, y, x_value, y_value);
      }
    } break;
    case PadAxisGroup::kLeftTrigger:
    case PadAxisGroup::kRightTrigger: {
      // The trigger value is exposed through different axes depending on the
      // pad; take the largest of the candidates.
      double z = 0.0;
      double rz = 0.0;
      double gas = 0.0;
      double brake = 0.0;
      OH_GamePad_AxisEvent_GetZAxisValue(event, &z);
      OH_GamePad_AxisEvent_GetRZAxisValue(event, &rz);
      OH_GamePad_AxisEvent_GetGasAxisValue(event, &gas);
      OH_GamePad_AxisEvent_GetBrakeAxisValue(event, &brake);
      double value = std::fmax(std::fmax(z, rz), std::fmax(gas, brake));
      const uint8_t scaled = ScaleTrigger(value);
      const int key = group == PadAxisGroup::kLeftTrigger ? kPadLTrigger
                                                          : kPadRTrigger;
      driver->OnKey(key, value > kTriggerOn, static_cast<short>(scaled));
    } break;
  }
}

template <PadAxisGroup Group>
void PadAxisCb(const struct GamePad_AxisEvent* event) {
  HandlePadAxis(Group, event);
}

struct ButtonMonitor {
  const char* name;
  GameController_ErrorCode (*reg)(GamePad_ButtonInputMonitorCallback);
  GamePad_ButtonInputMonitorCallback cb;
};

const ButtonMonitor kButtonMonitors[] = {
    {"dpad_left", OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor,
     &PadButtonCb<kPadDpadLeft>},
    {"dpad_right", OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor,
     &PadButtonCb<kPadDpadRight>},
    {"dpad_up", OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor,
     &PadButtonCb<kPadDpadUp>},
    {"dpad_down", OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor,
     &PadButtonCb<kPadDpadDown>},
    {"a", OH_GamePad_ButtonA_RegisterButtonInputMonitor, &PadButtonCb<kPadA>},
    {"b", OH_GamePad_ButtonB_RegisterButtonInputMonitor, &PadButtonCb<kPadB>},
    {"x", OH_GamePad_ButtonX_RegisterButtonInputMonitor, &PadButtonCb<kPadX>},
    {"y", OH_GamePad_ButtonY_RegisterButtonInputMonitor, &PadButtonCb<kPadY>},
    // Physical pads expose Menu/Home; map them to the 360 Start/Back pair.
    {"menu", OH_GamePad_ButtonMenu_RegisterButtonInputMonitor,
     &PadButtonCb<kPadStart>},
    {"home", OH_GamePad_ButtonHome_RegisterButtonInputMonitor,
     &PadButtonCb<kPadBack>},
    {"lb", OH_GamePad_LeftShoulder_RegisterButtonInputMonitor,
     &PadButtonCb<kPadLShoulder>},
    {"rb", OH_GamePad_RightShoulder_RegisterButtonInputMonitor,
     &PadButtonCb<kPadRShoulder>},
    {"lthumb", OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor,
     &PadButtonCb<kPadLThumbPress>},
    {"rthumb", OH_GamePad_RightThumbstick_RegisterButtonInputMonitor,
     &PadButtonCb<kPadRThumbPress>},
};

struct AxisMonitor {
  const char* name;
  GameController_ErrorCode (*reg)(GamePad_AxisInputMonitorCallback);
  GamePad_AxisInputMonitorCallback cb;
};

const AxisMonitor kAxisMonitors[] = {
    {"dpad", OH_GamePad_Dpad_RegisterAxisInputMonitor,
     &PadAxisCb<PadAxisGroup::kDpad>},
    {"left_stick", OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor,
     &PadAxisCb<PadAxisGroup::kLeftStick>},
    {"right_stick", OH_GamePad_RightThumbstick_RegisterAxisInputMonitor,
     &PadAxisCb<PadAxisGroup::kRightStick>},
    {"left_trigger", OH_GamePad_LeftTrigger_RegisterAxisInputMonitor,
     &PadAxisCb<PadAxisGroup::kLeftTrigger>},
    {"right_trigger", OH_GamePad_RightTrigger_RegisterAxisInputMonitor,
     &PadAxisCb<PadAxisGroup::kRightTrigger>},
};

}  // namespace

OhosInputDriver::OhosInputDriver(xe::ui::Window* window, size_t window_z_order)
    : InputDriver(window, window_z_order),
      key_status_({
          {xe::ui::VirtualKey::kXInputPadDpadLeft, false, 0},
          {xe::ui::VirtualKey::kXInputPadDpadUp, false, 0},
          {xe::ui::VirtualKey::kXInputPadDpadRight, false, 0},
          {xe::ui::VirtualKey::kXInputPadDpadDown, false, 0},
          {xe::ui::VirtualKey::kXInputPadA, false, 0},
          {xe::ui::VirtualKey::kXInputPadB, false, 0},
          {xe::ui::VirtualKey::kXInputPadX, false, 0},
          {xe::ui::VirtualKey::kXInputPadY, false, 0},
          {xe::ui::VirtualKey::kXInputPadBack, false, 0},
          {xe::ui::VirtualKey::kXInputPadStart, false, 0},
          {xe::ui::VirtualKey::kXInputPadLShoulder, false, 0},
          {xe::ui::VirtualKey::kXInputPadRShoulder, false, 0},
          {xe::ui::VirtualKey::kXInputPadLThumbPress, false, 0},
          {xe::ui::VirtualKey::kXInputPadRThumbPress, false, 0},
          {xe::ui::VirtualKey::kXInputPadLTrigger, false, 0},
          {xe::ui::VirtualKey::kXInputPadRTrigger, false, 0},
          {xe::ui::VirtualKey::kXInputPadLThumbLeft, false, 0},
          {xe::ui::VirtualKey::kXInputPadLThumbUp, false, 0},
          {xe::ui::VirtualKey::kXInputPadLThumbRight, false, 0},
          {xe::ui::VirtualKey::kXInputPadLThumbDown, false, 0},
          {xe::ui::VirtualKey::kXInputPadRThumbLeft, false, 0},
          {xe::ui::VirtualKey::kXInputPadRThumbUp, false, 0},
          {xe::ui::VirtualKey::kXInputPadRThumbRight, false, 0},
          {xe::ui::VirtualKey::kXInputPadRThumbDown, false, 0},
      }),
      prev_key_status_(key_status_) {}

OhosInputDriver::~OhosInputDriver() {
  StopPhysicalGamepad();
  std::lock_guard<std::mutex> lock(g_pad_mutex);
  if (g_pad_driver == this) {
    g_pad_driver = nullptr;
  }
}

xe::X_STATUS OhosInputDriver::Setup() {
  {
    std::lock_guard<std::mutex> lock(g_pad_mutex);
    g_pad_driver = this;
  }
  StartPhysicalGamepad();
  return X_STATUS_SUCCESS;
}

// Registers the GameControllerKit monitors. Registering succeeds even with no
// pad attached; callbacks simply never fire until one is connected.
void OhosInputDriver::StartPhysicalGamepad() {
  if (physical_pad_started_) {
    return;
  }
  physical_pad_started_ = true;

  int ok_buttons = 0;
  for (const auto& monitor : kButtonMonitors) {
    const GameController_ErrorCode rc = monitor.reg(monitor.cb);
    if (rc == GAME_CONTROLLER_SUCCESS) {
      ++ok_buttons;
    } else {
      PADLOGE("gamepad: register button '%{public}s' failed: %{public}d",
              monitor.name, static_cast<int>(rc));
    }
  }
  int ok_axes = 0;
  for (const auto& monitor : kAxisMonitors) {
    const GameController_ErrorCode rc = monitor.reg(monitor.cb);
    if (rc == GAME_CONTROLLER_SUCCESS) {
      ++ok_axes;
    } else {
      PADLOGE("gamepad: register axis '%{public}s' failed: %{public}d",
              monitor.name, static_cast<int>(rc));
    }
  }
  PADLOG("gamepad: GameControllerKit monitors registered: buttons=%{public}d/%{public}d axes=%{public}d/%{public}d",
         ok_buttons, static_cast<int>(sizeof(kButtonMonitors) / sizeof(kButtonMonitors[0])),
         ok_axes, static_cast<int>(sizeof(kAxisMonitors) / sizeof(kAxisMonitors[0])));
}

void OhosInputDriver::StopPhysicalGamepad() {
  if (!physical_pad_started_) {
    return;
  }
  physical_pad_started_ = false;
  OH_GamePad_Dpad_UnregisterAxisInputMonitor();
  OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor();
  OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor();
  OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor();
  OH_GamePad_RightTrigger_UnregisterAxisInputMonitor();
  OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor();
  OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor();
  OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor();
  OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonA_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonB_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonX_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonY_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor();
  OH_GamePad_ButtonHome_UnregisterButtonInputMonitor();
  OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor();
  OH_GamePad_RightShoulder_UnregisterButtonInputMonitor();
  OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor();
  OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor();
}

xe::X_RESULT OhosInputDriver::GetCapabilities(uint32_t user_index, uint32_t flags,
                                          xe::hid::X_INPUT_CAPABILITIES* out_caps) {
  if (user_index != 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  out_caps->type = 0x01;      // XINPUT_DEVTYPE_GAMEPAD
  out_caps->sub_type = 0x01;  // XINPUT_DEVSUBTYPE_GAMEPAD
  out_caps->flags = 0;
  out_caps->gamepad.buttons = 0xFFFF;
  out_caps->gamepad.left_trigger = 0xFF;
  out_caps->gamepad.right_trigger = 0xFF;
  out_caps->gamepad.thumb_lx = int16_t(0xFFFFu);
  out_caps->gamepad.thumb_ly = int16_t(0xFFFFu);
  out_caps->gamepad.thumb_rx = int16_t(0xFFFFu);
  out_caps->gamepad.thumb_ry = int16_t(0xFFFFu);
  out_caps->vibration.left_motor_speed = 0;
  out_caps->vibration.right_motor_speed = 0;
  return X_ERROR_SUCCESS;
}

xe::X_RESULT OhosInputDriver::GetState(uint32_t user_index,
                                   xe::hid::X_INPUT_STATE* out_state) {
  if (user_index != 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  packet_number_++;

  uint16_t buttons = 0;
  uint8_t left_trigger = 0;
  uint8_t right_trigger = 0;
  int16_t thumb_lx = 0;
  int16_t thumb_ly = 0;
  int16_t thumb_rx = 0;
  int16_t thumb_ry = 0;

  std::lock_guard<std::mutex> key_lock(key_status_mutex_);
  for (const KeyStatus& ks : key_status_) {
    if (!ks.pressed) {
      continue;
    }
    switch (ks.id) {
      case xe::ui::VirtualKey::kXInputPadA:
        buttons |= 0x1000;  // XINPUT_GAMEPAD_A
        break;
      case xe::ui::VirtualKey::kXInputPadB:
        buttons |= 0x2000;  // XINPUT_GAMEPAD_B
        break;
      case xe::ui::VirtualKey::kXInputPadX:
        buttons |= 0x4000;  // XINPUT_GAMEPAD_X
        break;
      case xe::ui::VirtualKey::kXInputPadY:
        buttons |= 0x8000;  // XINPUT_GAMEPAD_Y
        break;
      case xe::ui::VirtualKey::kXInputPadDpadLeft:
        buttons |= 0x0004;
        break;
      case xe::ui::VirtualKey::kXInputPadDpadRight:
        buttons |= 0x0008;
        break;
      case xe::ui::VirtualKey::kXInputPadDpadDown:
        buttons |= 0x0002;
        break;
      case xe::ui::VirtualKey::kXInputPadDpadUp:
        buttons |= 0x0001;
        break;
      case xe::ui::VirtualKey::kXInputPadRThumbPress:
        buttons |= 0x0080;
        break;
      case xe::ui::VirtualKey::kXInputPadLThumbPress:
        buttons |= 0x0040;
        break;
      case xe::ui::VirtualKey::kXInputPadBack:
        buttons |= 0x0020;
        break;
      case xe::ui::VirtualKey::kXInputPadStart:
        buttons |= 0x0010;
        break;
      case xe::ui::VirtualKey::kXInputPadLShoulder:
        buttons |= 0x0100;
        break;
      case xe::ui::VirtualKey::kXInputPadRShoulder:
        buttons |= 0x0200;
        break;
      case xe::ui::VirtualKey::kXInputPadLTrigger:
        left_trigger = static_cast<uint8_t>(
            ks.value < 0 ? 0 : (ks.value > 255 ? 255 : ks.value));
        break;
      case xe::ui::VirtualKey::kXInputPadRTrigger:
        right_trigger = static_cast<uint8_t>(
            ks.value < 0 ? 0 : (ks.value > 255 ? 255 : ks.value));
        break;
      case xe::ui::VirtualKey::kXInputPadLThumbLeft:
      case xe::ui::VirtualKey::kXInputPadLThumbRight:
        thumb_lx = ks.value;
        break;
      case xe::ui::VirtualKey::kXInputPadLThumbUp:
      case xe::ui::VirtualKey::kXInputPadLThumbDown:
        thumb_ly = ks.value;
        break;
      case xe::ui::VirtualKey::kXInputPadRThumbUp:
      case xe::ui::VirtualKey::kXInputPadRThumbDown:
        thumb_ry = ks.value;
        break;
      case xe::ui::VirtualKey::kXInputPadRThumbLeft:
      case xe::ui::VirtualKey::kXInputPadRThumbRight:
        thumb_rx = ks.value;
        break;
      default:
        break;
    }
  }

  out_state->packet_number = packet_number_;
  out_state->gamepad.buttons = buttons;
  out_state->gamepad.left_trigger = left_trigger;
  out_state->gamepad.right_trigger = right_trigger;
  out_state->gamepad.thumb_lx = thumb_lx;
  out_state->gamepad.thumb_ly = thumb_ly;
  out_state->gamepad.thumb_rx = thumb_rx;
  out_state->gamepad.thumb_ry = thumb_ry;
  return X_ERROR_SUCCESS;
}

xe::X_RESULT OhosInputDriver::SetState(uint32_t user_index,
                                   xe::hid::X_INPUT_VIBRATION* vibration) {
  if (user_index != 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  // Vibration is Phase 4.4 (`libohvibrator.z.so`); accept and ignore for now.
  return X_ERROR_SUCCESS;
}

xe::X_RESULT OhosInputDriver::GetKeystroke(uint32_t user_index, uint32_t flags,
                                       xe::hid::X_INPUT_KEYSTROKE* out_keystroke) {
  if (user_index != 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }

  xe::X_RESULT result = X_ERROR_EMPTY;
  xe::ui::VirtualKey xinput_virtual_key = xe::ui::VirtualKey::kNone;
  int key_status_index = -1;

  {
    std::lock_guard<std::mutex> key_lock(key_status_mutex_);
    if (key_status_mask_ == 0) {
      return X_ERROR_EMPTY;
    }
    // One keystroke per call, lowest index first; the guest drains the rest by
    // polling until EMPTY.
    for (size_t i = 0; i < key_status_.size(); i++) {
      if (key_status_mask_ & (1u << i)) {
        xinput_virtual_key = key_status_[i].id;
        key_status_index = static_cast<int>(i);
        key_status_mask_ &= ~(1u << i);
        break;
      }
    }
  }

  uint16_t keystroke_flags = 0;
  if (xinput_virtual_key != xe::ui::VirtualKey::kNone &&
      key_status_index >= 0) {
    if (key_status_[key_status_index].pressed) {
      keystroke_flags |= 0x0001;  // XINPUT_KEYSTROKE_KEYDOWN
    } else {
      keystroke_flags |= 0x0002;  // XINPUT_KEYSTROKE_KEYUP
    }
    if (prev_key_status_[key_status_index].pressed ==
        key_status_[key_status_index].pressed) {
      keystroke_flags |= 0x0004;  // XINPUT_KEYSTROKE_REPEAT
    }
    result = X_ERROR_SUCCESS;
  }

  out_keystroke->virtual_key = uint16_t(xinput_virtual_key);
  out_keystroke->unicode = 0;
  out_keystroke->flags = keystroke_flags;
  out_keystroke->user_index = 0;
  out_keystroke->hid_code = 0;
  return result;
}

void OhosInputDriver::OnKey(int key_index, bool pressed, short value) {
  if (key_index < 0 || key_index >= kPadKeyCount) {
    return;
  }
  std::lock_guard<std::mutex> key_lock(key_status_mutex_);
  const bool was_pressed = key_status_[key_index].pressed;
  prev_key_status_[key_index] = key_status_[key_index];
  key_status_[key_index].pressed = pressed;
  key_status_[key_index].value = value;
  // Transitions only: analog axes resend every motion sample, which would keep
  // GetKeystroke from ever reaching EMPTY.
  if (was_pressed != pressed) {
    key_status_mask_ |= (1u << key_index);
  }
}

void OhosInputDriver::ReleaseAll() {
  std::lock_guard<std::mutex> key_lock(key_status_mutex_);
  for (size_t i = 0; i < key_status_.size(); ++i) {
    if (!key_status_[i].pressed) {
      continue;
    }
    prev_key_status_[i] = key_status_[i];
    key_status_[i].pressed = false;
    key_status_[i].value = 0;
    key_status_mask_ |= (1u << i);
  }
}

xe::hid::InputType OhosInputDriver::GetInputType() const {
  return xe::hid::InputType::Controller;
}

std::vector<xe::hid::InputDeviceInfo> OhosInputDriver::EnumerateDevices() {
  std::vector<xe::hid::InputDeviceInfo> out;
  xe::hid::InputDeviceInfo info{};
  info.driver_slot = 0;
  info.stable_id = "ohos-gamepad";
  info.display_name = "OHOS Controller";
  info.preferred_slot = 0;  // player 1
  out.push_back(std::move(info));
  return out;
}

}  // namespace hx360e
