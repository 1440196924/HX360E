// HX360E OHOS 模拟器启动层（Phase 1.7）。
//
// 目标：把 XenDroid/Xenia 内核以「无窗口 / 无画面」方式启动，先跑通
// 「加载 XEX → 启动内核」。GPU 用 null 后端，音频/输入用 nop。
// Phase 2 再把 Vulkan 后端与 OHOS surface 接进来。
//
// 与上游 Android 的 xendroid_emu.cpp 的区别：不创建 WindowedApp /
// EmulatorWindow / UI 线程，直接构造 xe::Emulator 并 Setup(nullptr, ...)，
// 走 xenia 的 headless 路径（with_presentation=false）。
#ifndef HX360E_XENDROID_OHOS_OHOS_EMULATOR_H_
#define HX360E_XENDROID_OHOS_OHOS_EMULATOR_H_

#include <string>
#include <vector>

namespace hx360e {

// 设置要启动的游戏文件（沙箱内绝对路径）。
void SetGamePath(const std::string& path);

// 设置启动参数（如 --storage_root=... --gpu=null），交给 xenia 的 cvar 解析器。
void SetLaunchArgs(const std::vector<std::string>& args);

// XComponent(SURFACE) 的 OHNativeWindow 到达时调用（ArkUI 主线程）。
void SetNativeWindow(void* native_window);

// 在独立线程里启动内核（headless）。重复调用会被忽略。
void Boot();

void Pause();
void Resume();

// 终止当前 title（guest 主线程退出，WaitUntilExit 返回）。
void Quit();

bool IsRunning();
bool IsPaused();

// 返回设备/后端信息（用于 UI 展示与反馈）。
std::string DeviceInfo();

// 扫描文件头部，报告识别到的镜像格式（诊断用）。
std::string ProbeFile(const std::string& path);

// ---- 输入（Phase 4）----
// 喂入一个手柄控件状态。key_index 见 ohos_input_driver.h 的 OhosPadKey
// （与 ArkTS 侧 XPadKey 一一对应）；value 为摇杆有符号值 [-32767,32767]
// 或扳机 [0,255]。可在任意线程调用。
void PadKey(int key_index, bool pressed, int value);

// 释放全部按键（覆盖层消失 / 游戏退出时调用）。
void PadReleaseAll();

// 打开/关闭物理手柄（OHOS GameControllerKit）监听。
bool PadStartPhysical();
bool PadStopPhysical();

}  // namespace hx360e

#endif  // HX360E_XENDROID_OHOS_OHOS_EMULATOR_H_
