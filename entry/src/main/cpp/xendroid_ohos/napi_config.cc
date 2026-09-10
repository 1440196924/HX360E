// HX360E NAPI 桥接：config（Phase 5.1）。
//
// 对应上游 JNI 的 Emulator$Config（emulator.cpp:408-424）。语义：
//   openFile / openString  解析 TOML，返回 toml::table* 的 bigint 句柄（失败 0）
//   loadEntry              读 "Section|name"，按 TOML 类型转成字符串（未设置返回 null）
//   saveEntry              写 "Section|name"，按值形态推断类型（bool/int/double/string）
//   saveToFile             序列化到文件（句柄保留）
//   close                  序列化并释放句柄，返回 TOML 文本
//   free                   直接释放句柄（不序列化）
//
// 句柄是裸 C++ 指针，ArkTS 侧必须严格配对 close/free（DESIGN.md §9.4）。
#include "napi_bridge.h"

#include <cctype>
#include <algorithm>
#include <sstream>
#include <string>

#include <hilog/log.h>

#include "tomlplusplus/include/toml++/toml.hpp"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

namespace hx360e {
namespace {

using Table = toml::table;

Table* TableFromHandle(uint64_t handle) {
  return reinterpret_cast<Table*>(static_cast<uintptr_t>(handle));
}

// "Section|name" -> (section, name)。无 '|' 时 section 为空。
void SplitTag(const std::string& tag, std::string* section,
              std::string* name) {
  const size_t pos = tag.find('|');
  if (pos == std::string::npos) {
    *section = "";
    *name = tag;
  } else {
    *section = tag.substr(0, pos);
    *name = tag.substr(pos + 1);
  }
}

bool IsFloatNumber(const std::string& str) {
  if (std::count(str.begin(), str.end(), '.') != 1) {
    return false;
  }
  try {
    std::stof(str);
    return true;
  } catch (...) {
    return false;
  }
}

bool IsIntNumber(const std::string& str) {
  if (str.empty()) {
    return false;
  }
  if (str.length() > 1 && str[0] == '-') {
    return std::all_of(str.begin() + 1, str.end(),
                       [](char c) { return std::isdigit(c) != 0; });
  }
  return std::all_of(str.begin(), str.end(),
                     [](char c) { return std::isdigit(c) != 0; });
}

// 解析 TOML 文件/文本，失败返回 nullptr。
Table* ParseFile(const std::string& path) {
  try {
    return new Table(toml::parse_file(path));
  } catch (const toml::parse_error& e) {
    const std::string message(e.what());
    OH_LOG_ERROR(LOG_APP, "config.open(%{public}s) parse error: %{public}s",
                 path.c_str(), message.c_str());
    return nullptr;
  } catch (...) {
    return nullptr;
  }
}

Table* ParseString(const std::string& text) {
  try {
    return new Table(toml::parse(text));
  } catch (const toml::parse_error& e) {
    const std::string message(e.what());
    OH_LOG_ERROR(LOG_APP, "config.openString parse error: %{public}s",
                 message.c_str());
    return nullptr;
  } catch (...) {
    return nullptr;
  }
}

std::string Serialize(Table* table) {
  if (!table) {
    return "{}";
  }
  std::ostringstream out;
  out << *table;
  return out.str();
}

// ---------------- NAPI 实现 ----------------

// open(path): bigint
napi_value ConfigOpen(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  Table* table = argc >= 1 ? ParseFile(NapiGetString(env, args[0])) : nullptr;
  napi_value result = nullptr;
  napi_create_bigint_uint64(env, reinterpret_cast<uint64_t>(table), &result);
  return result;
}

// openString(text): bigint
napi_value ConfigOpenString(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  Table* table =
      argc >= 1 ? ParseString(NapiGetString(env, args[0])) : nullptr;
  napi_value result = nullptr;
  napi_create_bigint_uint64(env, reinterpret_cast<uint64_t>(table), &result);
  return result;
}

// loadEntry(handle, key): string | null
napi_value ConfigLoadEntry(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  if (argc < 2) {
    return null_value;
  }
  uint64_t handle = 0;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, args[0], &handle, &lossless) !=
      napi_ok) {
    return null_value;
  }
  Table* table = TableFromHandle(handle);
  if (!table) {
    return null_value;
  }
  std::string section;
  std::string name;
  SplitTag(NapiGetString(env, args[1]), &section, &name);

  toml::node* node = table->get(section);
  if (!node || !node->is_table()) {
    return null_value;
  }
  toml::node* value = node->as_table()->get(name);
  if (!value) {
    return null_value;
  }
  std::string out;
  if (auto v = value->value<bool>()) {
    out = *v ? "true" : "false";
  } else if (auto v = value->value<int64_t>()) {
    out = std::to_string(*v);
  } else if (auto v = value->value<double>()) {
    out = std::to_string(*v);
  } else if (auto v = value->value<std::string>()) {
    out = *v;
  } else {
    return null_value;
  }
  return NapiNewString(env, out);
}

// saveEntry(handle, key, value): void
napi_value ConfigSaveEntry(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return nullptr;
  }
  uint64_t handle = 0;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, args[0], &handle, &lossless) !=
      napi_ok) {
    return nullptr;
  }
  Table* table = TableFromHandle(handle);
  if (!table) {
    return nullptr;
  }
  std::string section;
  std::string name;
  SplitTag(NapiGetString(env, args[1]), &section, &name);
  const std::string val = NapiGetString(env, args[2]);

  toml::table* target = nullptr;
  toml::node* node = table->get(section);
  if (node && node->is_table()) {
    target = node->as_table();
  } else {
    target = table->emplace<toml::table>(section).first->second.as_table();
  }
  if (!target) {
    return nullptr;
  }
  if (val == "true" || val == "false") {
    target->insert_or_assign(name, val == "true");
  } else if (IsFloatNumber(val)) {
    try {
      target->insert_or_assign(name, std::stod(val));
    } catch (...) {
      target->insert_or_assign(name, val);
    }
  } else if (IsIntNumber(val)) {
    try {
      target->insert_or_assign(name, std::stoi(val));
    } catch (...) {
      target->insert_or_assign(name, val);
    }
  } else {
    target->insert_or_assign(name, val);
  }
  return nullptr;
}

// saveToFile(handle, path): void
napi_value ConfigSaveToFile(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return nullptr;
  }
  uint64_t handle = 0;
  bool lossless = false;
  if (napi_get_value_bigint_uint64(env, args[0], &handle, &lossless) !=
      napi_ok) {
    return nullptr;
  }
  Table* table = TableFromHandle(handle);
  if (!table) {
    return nullptr;
  }
  const std::string path = NapiGetString(env, args[1]);
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) {
    OH_LOG_ERROR(LOG_APP, "config.saveToFile open failed: %{public}s",
                 path.c_str());
    return nullptr;
  }
  const std::string text = Serialize(table);
  fwrite(text.data(), 1, text.size(), f);
  fclose(f);
  return nullptr;
}

// serialize(handle): string
napi_value ConfigSerialize(napi_env env, napi_callback_info info) {
  uint64_t handle = NapiGetHandle(env, info, 0);
  return NapiNewString(env, Serialize(TableFromHandle(handle)));
}

// close(handle): string —— 序列化后释放句柄
napi_value ConfigClose(napi_env env, napi_callback_info info) {
  uint64_t handle = NapiGetHandle(env, info, 0);
  Table* table = TableFromHandle(handle);
  const std::string text = Serialize(table);
  delete table;
  return NapiNewString(env, text);
}

// free(handle): void
napi_value ConfigFree(napi_env env, napi_callback_info info) {
  delete TableFromHandle(NapiGetHandle(env, info, 0));
  return nullptr;
}

}  // namespace

void RegisterConfig(napi_env env, napi_value exports) {
  napi_value config = nullptr;
  napi_create_object(env, &config);
  napi_property_descriptor desc[] = {
      {"open", nullptr, ConfigOpen, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"openString", nullptr, ConfigOpenString, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"loadEntry", nullptr, ConfigLoadEntry, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"saveEntry", nullptr, ConfigSaveEntry, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"saveToFile", nullptr, ConfigSaveToFile, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"serialize", nullptr, ConfigSerialize, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"close", nullptr, ConfigClose, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"free", nullptr, ConfigFree, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, config, sizeof(desc) / sizeof(desc[0]), desc);
  napi_set_named_property(env, exports, "config", config);
}

}  // namespace hx360e
