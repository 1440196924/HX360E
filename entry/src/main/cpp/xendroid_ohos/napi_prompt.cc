// HX360E NAPI 桥接：prompt（Phase 5.3）。
//
// guest 的键盘输入 / 对话框 / 换盘请求由 guest 线程阻塞等待宿主回答；ArkTS
// 侧按约 150ms 轮询 *Request()，用 *Submit() 回填。字符串走 UTF-16，避免
// 模改 UTF-8 对 guest 文本的破坏（DESIGN.md §9.2/§9.3）。
#include <string>
#include <vector>

#include <hilog/log.h>

#include "napi_bridge.h"
#include "prompt_providers.h"

#include "xenia/base/string.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

namespace hx360e {
namespace {

napi_value NewNull(napi_env env) {
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  return null_value;
}

// std::string(UTF-8) -> JS string（UTF-16）。
napi_value NewUtf16(napi_env env, const std::string& utf8) {
  const std::u16string u16 = xe::to_utf16(utf8);
  napi_value result = nullptr;
  napi_create_string_utf16(env, reinterpret_cast<const char16_t*>(u16.data()),
                           u16.size(), &result);
  return result;
}

// JS string(UTF-16) -> std::string(UTF-8)。
std::string GetUtf16(napi_env env, napi_value value) {
  if (value == nullptr) return {};
  size_t len = 0;
  if (napi_get_value_string_utf16(env, value, nullptr, 0, &len) != napi_ok) {
    return {};
  }
  std::u16string u16(len + 1, u'\0');
  size_t copied = 0;
  if (napi_get_value_string_utf16(
          env, value, reinterpret_cast<char16_t*>(u16.data()), len + 1,
          &copied) != napi_ok) {
    return {};
  }
  u16.resize(copied);
  return xe::to_utf8(std::u16string_view(u16));
}

napi_value NewStringArray(napi_env env,
                          const std::vector<std::string>& utf8_list) {
  napi_value arr = nullptr;
  napi_create_array_with_length(env, utf8_list.size(), &arr);
  for (size_t i = 0; i < utf8_list.size(); ++i) {
    napi_set_element(env, arr, static_cast<uint32_t>(i),
                     NewUtf16(env, utf8_list[i]));
  }
  return arr;
}

std::vector<std::string> GetStringArray(napi_env env, napi_value value) {
  std::vector<std::string> out;
  if (value == nullptr) return out;
  uint32_t count = 0;
  if (napi_get_array_length(env, value, &count) != napi_ok) return out;
  out.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    napi_value item = nullptr;
    napi_get_element(env, value, i, &item);
    out.push_back(GetUtf16(env, item));
  }
  return out;
}

void SetId(napi_env env, napi_value obj, uint64_t id) {
  napi_value value = nullptr;
  napi_create_bigint_uint64(env, id, &value);
  napi_set_named_property(env, obj, "id", value);
}

uint64_t GetId(napi_env env, napi_value value) {
  uint64_t id = 0;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, value, &id, &lossless) != napi_ok) {
    return 0;
  }
  return id;
}

// ---------------- 键盘 ----------------

// keyboardRequest(): KeyboardRequest | null
napi_value KeyboardRequest(napi_env env, napi_callback_info info) {
  xendroid::PendingTextInput req;
  if (!xendroid::PeekTextInputRequest(req)) {
    return NewNull(env);
  }
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  SetId(env, obj, req.id);
  napi_set_named_property(env, obj, "title", NewUtf16(env, req.title));
  napi_set_named_property(env, obj, "description",
                          NewUtf16(env, req.description));
  napi_set_named_property(env, obj, "defaultText",
                          NewUtf16(env, req.default_text));
  napi_value number = nullptr;
  napi_create_int32(env, static_cast<int32_t>(req.max_length), &number);
  napi_set_named_property(env, obj, "maxLength", number);
  napi_create_int32(env, static_cast<int32_t>(req.flags), &number);
  napi_set_named_property(env, obj, "flags", number);
  return obj;
}

// keyboardSubmit(id, accepted, text): void
napi_value KeyboardSubmit(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) return nullptr;
  const uint64_t id = GetId(env, args[0]);
  bool accepted = false;
  napi_get_value_bool(env, args[1], &accepted);
  std::string text;
  if (argc >= 3 && accepted) {
    text = GetUtf16(env, args[2]);
  }
  xendroid::SubmitTextInput(id, accepted, text);
  return nullptr;
}

napi_value KeyboardCancelAll(napi_env env, napi_callback_info info) {
  xendroid::CancelAllTextInput();
  return nullptr;
}

// ---------------- 对话框 ----------------

// msgboxRequest(): MessageBoxRequest | null
napi_value MsgboxRequest(napi_env env, napi_callback_info info) {
  xendroid::PendingMessageBox req;
  if (!xendroid::PeekMessageBoxRequest(req)) {
    return NewNull(env);
  }
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  SetId(env, obj, req.id);
  napi_set_named_property(env, obj, "title", NewUtf16(env, req.title));
  napi_set_named_property(env, obj, "text", NewUtf16(env, req.text));
  napi_set_named_property(env, obj, "buttons", NewStringArray(env, req.buttons));
  napi_value number = nullptr;
  napi_create_int32(env, static_cast<int32_t>(req.active_button), &number);
  napi_set_named_property(env, obj, "activeButton", number);
  napi_create_int32(env, static_cast<int32_t>(req.flags), &number);
  napi_set_named_property(env, obj, "flags", number);
  return obj;
}

// msgboxSubmit(id, button): void
napi_value MsgboxSubmit(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) return nullptr;
  const uint64_t id = GetId(env, args[0]);
  int32_t button = 0;
  napi_get_value_int32(env, args[1], &button);
  xendroid::SubmitMessageBox(id, static_cast<uint32_t>(button));
  return nullptr;
}

napi_value MsgboxCancelAll(napi_env env, napi_callback_info info) {
  xendroid::CancelAllMessageBox();
  return nullptr;
}

// ---------------- 换盘 ----------------

// discRequest(): DiscSwapRequest | null
napi_value DiscRequest(napi_env env, napi_callback_info info) {
  xendroid::PendingDiscSwap req;
  if (!xendroid::PeekDiscSwapRequest(req)) {
    return NewNull(env);
  }
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  SetId(env, obj, req.id);
  napi_set_named_property(env, obj, "message", NewUtf16(env, req.message));
  napi_value flag = nullptr;
  napi_get_boolean(env, req.is_error, &flag);
  napi_set_named_property(env, obj, "isError", flag);
  napi_value number = nullptr;
  napi_create_int32(env, static_cast<int32_t>(req.disc_number), &number);
  napi_set_named_property(env, obj, "discNumber", number);
  napi_set_named_property(env, obj, "discLabels",
                          NewStringArray(env, req.disc_labels));
  napi_set_named_property(env, obj, "discPaths",
                          NewStringArray(env, req.disc_paths));
  return obj;
}

// discSubmit(id, accepted, path): void
napi_value DiscSubmit(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) return nullptr;
  const uint64_t id = GetId(env, args[0]);
  bool accepted = false;
  napi_get_value_bool(env, args[1], &accepted);
  std::string path;
  if (argc >= 3 && accepted) {
    path = GetUtf16(env, args[2]);
  }
  xendroid::SubmitDiscSwap(id, accepted, path);
  return nullptr;
}

napi_value DiscCancelAll(napi_env env, napi_callback_info info) {
  xendroid::CancelAllDiscSwap();
  return nullptr;
}

// discSetKnown(labels, paths): void
napi_value DiscSetKnown(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  std::vector<std::string> labels;
  std::vector<std::string> paths;
  if (argc >= 1) labels = GetStringArray(env, args[0]);
  if (argc >= 2) paths = GetStringArray(env, args[1]);
  xendroid::SetKnownDiscs(std::move(labels), std::move(paths));
  return nullptr;
}

}  // namespace

void RegisterPrompt(napi_env env, napi_value exports) {
  napi_value prompt = nullptr;
  napi_create_object(env, &prompt);
  napi_property_descriptor desc[] = {
      {"keyboardRequest", nullptr, KeyboardRequest, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"keyboardSubmit", nullptr, KeyboardSubmit, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"keyboardCancelAll", nullptr, KeyboardCancelAll, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"msgboxRequest", nullptr, MsgboxRequest, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"msgboxSubmit", nullptr, MsgboxSubmit, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"msgboxCancelAll", nullptr, MsgboxCancelAll, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"discRequest", nullptr, DiscRequest, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"discSubmit", nullptr, DiscSubmit, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"discCancelAll", nullptr, DiscCancelAll, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"discSetKnown", nullptr, DiscSetKnown, nullptr, nullptr, nullptr,
       napi_default, nullptr},
  };
  napi_define_properties(env, prompt, sizeof(desc) / sizeof(desc[0]), desc);
  napi_set_named_property(env, exports, "prompt", prompt);
}

}  // namespace hx360e
