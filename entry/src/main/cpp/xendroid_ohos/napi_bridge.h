// HX360E NAPI 桥接（Phase 5）。
//
// 用扁平 C 接口替代上游 XenDroid 的约 40 个 JNI 方法（见 DESIGN.md §9）。
// 这里集中放共享的 NAPI 辅助函数与各子命名空间的注册入口：
//   config  —— TOML 配置句柄（Phase 5.1）
//   meta    —— 镜像元数据（Phase 5.2）
//   prompt  —— guest 文本/对话框/换盘（Phase 5.3）
//   content —— 内容管理/存档（Phase 5.4）
#ifndef HX360E_XENDROID_OHOS_NAPI_BRIDGE_H_
#define HX360E_XENDROID_OHOS_NAPI_BRIDGE_H_

#include <string>
#include <vector>

#include "napi/native_api.h"

namespace hx360e {

// ---------------- 共享辅助 ----------------

// napi_value -> UTF-8 std::string（非字符串返回空串）。
inline std::string NapiGetString(napi_env env, napi_value value) {
  if (value == nullptr) {
    return {};
  }
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return {};
  }
  std::string out(len + 1, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, out.data(), len + 1, &copied) !=
      napi_ok) {
    return {};
  }
  out.resize(copied);
  return out;
}

// 字符串数组 -> std::vector<std::string>（非数组返回空）。
inline std::vector<std::string> NapiGetStringArray(napi_env env,
                                                  napi_value value) {
  std::vector<std::string> out;
  if (value == nullptr) {
    return out;
  }
  uint32_t count = 0;
  if (napi_get_array_length(env, value, &count) != napi_ok) {
    return out;
  }
  out.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    napi_value item = nullptr;
    napi_get_element(env, value, i, &item);
    out.push_back(NapiGetString(env, item));
  }
  return out;
}

// UTF-8 std::string -> napi_value（napi_create_string_utf8）。
inline napi_value NapiNewString(napi_env env, const std::string& utf8) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, utf8.c_str(), utf8.size(), &result);
  return result;
}

// 读第 index 个参数为 bigint 句柄；缺省返回 0。
inline uint64_t NapiGetHandle(napi_env env, napi_callback_info info,
                              size_t index, uint64_t fallback = 0) {
  size_t argc = index + 1;
  std::vector<napi_value> args(argc, nullptr);
  if (napi_get_cb_info(env, info, &argc, args.data(), nullptr, nullptr) !=
          napi_ok ||
      argc <= index) {
    return fallback;
  }
  uint64_t value = fallback;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, args[index], &value, &lossless) !=
      napi_ok) {
    return fallback;
  }
  return value;
}

// ---------------- 子命名空间注册 ----------------

void RegisterConfig(napi_env env, napi_value exports);
void RegisterMeta(napi_env env, napi_value exports);
void RegisterPrompt(napi_env env, napi_value exports);
void RegisterContent(napi_env env, napi_value exports);

}  // namespace hx360e

#endif  // HX360E_XENDROID_OHOS_NAPI_BRIDGE_H_
