// HX360E guest 提示（键盘/对话框/换盘）provider（Phase 5.3）。
//
// 逻辑与上游 `xe_android_text_input.*` / `xe_android_message_box.*` /
// `xe_android_disc_swap.*` 完全一致（它们其实与 Android 无关，只依赖
// xenia/ui/host_*.h）。为避免与 Android 命名混淆，这里合并到 OHOS 侧。
//
// guest 线程会在 Provide() 里阻塞等待宿主回答；ArkTS 侧通过 NAPI 轮询
// *Request() 取请求、*Submit() 回填结果（DESIGN.md §9.3）。
#ifndef HX360E_XENDROID_OHOS_PROMPT_PROVIDERS_H_
#define HX360E_XENDROID_OHOS_PROMPT_PROVIDERS_H_

#include <cstdint>
#include <string>
#include <vector>

namespace xendroid {

// ---------------- 键盘 ----------------
struct PendingTextInput {
  uint64_t id = 0;
  std::string title;
  std::string description;
  std::string default_text;
  uint32_t max_length = 0;
  uint32_t flags = 0;
};
void InstallTextInputProvider();
bool PeekTextInputRequest(PendingTextInput& out_request);
void SubmitTextInput(uint64_t id, bool accepted, const std::string& text_utf8);
void CancelAllTextInput();

// ---------------- 对话框 ----------------
struct PendingMessageBox {
  uint64_t id = 0;
  std::string title;
  std::string text;
  std::vector<std::string> buttons;
  uint32_t active_button = 0;
  uint32_t flags = 0;
};
void InstallMessageBoxProvider();
bool PeekMessageBoxRequest(PendingMessageBox& out_request);
void SubmitMessageBox(uint64_t id, uint32_t chosen_button);
void CancelAllMessageBox();

// ---------------- 换盘 ----------------
struct PendingDiscSwap {
  uint64_t id = 0;
  std::string message;
  bool is_error = false;
  uint32_t disc_number = 0;
  std::vector<std::string> disc_labels;
  std::vector<std::string> disc_paths;
};
void InstallDiscSwapProvider();
void SetKnownDiscs(std::vector<std::string> labels,
                   std::vector<std::string> paths);
bool PeekDiscSwapRequest(PendingDiscSwap& out_request);
void SubmitDiscSwap(uint64_t id, bool accepted, const std::string& path_utf8);
void CancelAllDiscSwap();

// 一次性安装三个 provider（BootThread 在 LaunchPath 之前调用）。
void InstallAllPromptProviders();

}  // namespace xendroid

#endif  // HX360E_XENDROID_OHOS_PROMPT_PROVIDERS_H_
