// HarmonyOS 平台 system 接口的最小实现。
//
// 上游 Android 版在 xe_system_xendroid.cpp 里提供这些空实现；HX360E 不编译该
// 文件，故在此补齐，避免 xenia-base/core 链接时缺符号。
#include <string>

#include "xenia/base/system.h"

namespace xe {

void ShowSimpleMessageBox(SimpleMessageBoxType type,
                          std::string_view message) {}

void LaunchFileExplorer(const std::filesystem::path& path) {}

void LaunchWebBrowser(const std::string_view url) {}

bool SetProcessPriorityClass(const uint32_t priority_class) { return true; }

bool IsUseNexusForGameBarEnabled() { return false; }

}  // namespace xe
