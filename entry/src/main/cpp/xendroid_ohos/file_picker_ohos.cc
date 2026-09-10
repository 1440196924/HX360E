// HarmonyOS 文件选择器：native 侧不使用。
//
// 上游在 Android 用 file_picker_android.cc 实现 FilePicker::Create()，桌面用
// file_picker_wx.cc。HX360E 的文件选择/安装由 ArkTS 侧 @ohos.file.picker 完成，
// 这里提供一个返回 nullptr 的实现，满足 xenia-core（换盘/头像选择等路径）的链接。
#include "xenia/ui/file_picker.h"

namespace xe {
namespace ui {

std::unique_ptr<FilePicker> FilePicker::Create() { return nullptr; }

}  // namespace ui
}  // namespace xe
