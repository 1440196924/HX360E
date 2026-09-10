// HX360E NAPI 桥接：content（Phase 5.4）。
//
// 迁移自上游 emulator_xendroid.cpp 的内容管理 JNI：
//   installContent / installDiscContent / listDiscContent / listContent /
//   deleteContent / contentHeader / listProfiles / createProfile /
//   renameProfile / compressIsoToZar / installProgress / compressProgress
//
// 这些操作是阻塞的（磁盘/解压），ArkTS 侧应放到子线程调用。
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <hilog/log.h>

#include "napi_bridge.h"

#include "third_party/fmt/include/fmt/format.h"

#include "xenia/emulator.h"
#include "xenia/kernel/xam/profile_standalone.h"
#include "xenia/vfs/content_install_standalone.h"
#include "xenia/vfs/devices/disc_image_device.h"
#include "xenia/vfs/stfs_metadata.h"
#include "xenia/xbox.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

namespace hx360e {
namespace {

// xbox.h 的 X_STATUS_SUCCESS 等是无命名空间前缀的宏，展开为 ((X_STATUS)0x..)，
// 需要 X_STATUS 类型名在作用域内。
using namespace xe;

napi_value NewNull(napi_env env) {
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  return null_value;
}

napi_value NewStringOrNull(napi_env env, const std::string& s) {
  if (s.empty()) return NewNull(env);
  return NapiNewString(env, s);
}

void SetInt64(napi_env env, napi_value obj, const char* name, int64_t value) {
  napi_value number = nullptr;
  napi_create_int64(env, value, &number);
  napi_set_named_property(env, obj, name, number);
}

void SetUint32(napi_env env, napi_value obj, const char* name, uint32_t value) {
  napi_value number = nullptr;
  napi_create_int32(env, static_cast<int32_t>(value), &number);
  napi_set_named_property(env, obj, name, number);
}

// ---------------- 进度（文件级静态，供进度 getter 并发读取） ----------------

std::atomic<uint64_t> g_zar_progress_done{0};
std::atomic<uint64_t> g_zar_progress_total{0};
xe::vfs::ContentProgress g_content_progress;

bool ParseTitleIdHex(const std::string& s, uint32_t* out) {
  if (s.empty()) return false;
  return sscanf(s.c_str(), "%8x", out) == 1;
}

bool ParseXuidHex(const std::string& s, uint64_t* out) {
  if (s.empty()) return false;
  unsigned long long value = 0;
  if (sscanf(s.c_str(), "%16llx", &value) != 1) return false;
  *out = static_cast<uint64_t>(value);
  return true;
}

// ---------------- NAPI 实现 ----------------

// compressIsoToZar(isoPath, outZarPath): number (X_STATUS)
napi_value CompressIsoToZar(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) return nullptr;

  const std::filesystem::path in =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  const std::filesystem::path out =
      std::filesystem::u8path(NapiGetString(env, args[1]));

  auto dev = std::make_unique<xe::vfs::DiscImageDevice>("\\Device\\Cdrom0", in);
  if (!dev->Initialize()) {
    napi_value result = nullptr;
    napi_create_int32(env, static_cast<int32_t>(X_STATUS_UNSUCCESSFUL),
                      &result);
    return result;
  }
  auto emulator = std::make_unique<xe::Emulator>("", "", "", "");
  g_zar_progress_total.store(0);
  g_zar_progress_done.store(0);
  const xe::X_STATUS status = emulator->CompressDiscToZarchive(
      dev.get(), out, &g_zar_progress_done, &g_zar_progress_total);
  napi_value result = nullptr;
  napi_create_int32(env, static_cast<int32_t>(status), &result);
  return result;
}

// compressProgress(): number [0,1]
napi_value CompressProgress(napi_env env, napi_callback_info info) {
  const uint64_t total = g_zar_progress_total.load();
  const double value =
      total ? static_cast<double>(g_zar_progress_done.load()) /
                  static_cast<double>(total)
            : 0.0;
  napi_value result = nullptr;
  napi_create_double(env, value, &result);
  return result;
}

// installContent(srcPath, contentRoot): number (X_STATUS)
napi_value InstallContent(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value result = nullptr;
  if (argc < 2) {
    napi_create_int32(env, static_cast<int32_t>(X_STATUS_INVALID_PARAMETER),
                      &result);
    return result;
  }
  const std::filesystem::path src =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[1]));
  g_content_progress.current.store(0);
  g_content_progress.total.store(0);
  const xe::X_STATUS status =
      xe::vfs::InstallContentPackageStandalone(src, root, g_content_progress);
  napi_create_int32(env, static_cast<int32_t>(status), &result);
  return result;
}

// installProgress(): number [0,1]
napi_value InstallProgress(napi_env env, napi_callback_info info) {
  const uint64_t total = g_content_progress.total.load();
  const double value =
      total ? static_cast<double>(g_content_progress.current.load()) /
                  static_cast<double>(total)
            : 0.0;
  napi_value result = nullptr;
  napi_create_double(env, value, &result);
  return result;
}

// listDiscContent(discPath): DiscContentItem[]
napi_value ListDiscContent(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value arr = nullptr;
  if (argc < 1) {
    napi_create_array_with_length(env, 0, &arr);
    return arr;
  }
  const std::filesystem::path disc =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  std::vector<xe::vfs::DiscContentItem> items = xe::vfs::ListDiscContent(disc);
  napi_create_array_with_length(env, items.size(), &arr);
  for (size_t i = 0; i < items.size(); ++i) {
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "innerPath",
                            NapiNewString(env, items[i].inner_path));
    napi_set_named_property(env, obj, "displayName",
                            NapiNewString(env, items[i].display_name));
    SetUint32(env, obj, "titleId", items[i].title_id);
    SetUint32(env, obj, "contentType", items[i].content_type);
    SetInt64(env, obj, "size", static_cast<int64_t>(items[i].size));
    napi_set_element(env, arr, static_cast<uint32_t>(i), obj);
  }
  return arr;
}

// installDiscContent(discPath, innerPath, contentRoot, scratchDir): number
napi_value InstallDiscContent(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value result = nullptr;
  if (argc < 4) {
    napi_create_int32(env, static_cast<int32_t>(X_STATUS_INVALID_PARAMETER),
                      &result);
    return result;
  }
  const std::filesystem::path disc =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  const std::string inner = NapiGetString(env, args[1]);
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[2]));
  const std::filesystem::path scratch =
      std::filesystem::u8path(NapiGetString(env, args[3]));
  g_content_progress.current.store(0);
  g_content_progress.total.store(0);
  const xe::X_STATUS status = xe::vfs::InstallDiscContentPackage(
      disc, inner, root, scratch, g_content_progress);
  napi_create_int32(env, static_cast<int32_t>(status), &result);
  return result;
}

// contentHeader(srcPath): ContentInfo | null
napi_value ContentHeader(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) return NewNull(env);
  const std::filesystem::path p =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  std::optional<xe::vfs::StfsMetadata> meta =
      xe::vfs::ExtractStfsMetadata(p, xe::XLanguage::kEnglish);
  if (!meta) return NewNull(env);

  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  SetUint32(env, obj, "titleId", meta->title_id);
  SetUint32(env, obj, "contentType", meta->content_type);
  SetInt64(env, obj, "contentSize", static_cast<int64_t>(meta->content_size));
  const std::string& name =
      !meta->display_name.empty() ? meta->display_name : meta->title_name;
  napi_set_named_property(env, obj, "displayName", NewStringOrNull(env, name));
  if (!meta->icon_data.empty()) {
    void* data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, meta->icon_data.size(), &data, &buffer) ==
            napi_ok &&
        data) {
      std::memcpy(data, meta->icon_data.data(), meta->icon_data.size());
      napi_set_named_property(env, obj, "icon", buffer);
    }
  }
  return obj;
}

// listContent(contentRoot, titleId, contentType): ContentItem[]
napi_value ListContent(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value arr = nullptr;
  uint32_t tid = 0;
  if (argc < 3 || !ParseTitleIdHex(NapiGetString(env, args[1]), &tid)) {
    napi_create_array_with_length(env, 0, &arr);
    return arr;
  }
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  int32_t content_type = 0;
  napi_get_value_int32(env, args[2], &content_type);

  std::vector<xe::vfs::InstalledContentItem> items =
      xe::vfs::ListInstalledContent(root, tid,
                                    static_cast<uint32_t>(content_type));
  napi_create_array_with_length(env, items.size(), &arr);
  for (size_t i = 0; i < items.size(); ++i) {
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "pkgDir",
                            NapiNewString(env, items[i].pkg_dir));
    napi_set_named_property(env, obj, "displayName",
                            NapiNewString(env, items[i].display_name));
    SetInt64(env, obj, "size", static_cast<int64_t>(items[i].size));
    napi_set_element(env, arr, static_cast<uint32_t>(i), obj);
  }
  return arr;
}

// deleteContent(contentRoot, titleId, contentType, pkgDir): number
napi_value DeleteContent(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value result = nullptr;
  uint32_t tid = 0;
  if (argc < 4 || !ParseTitleIdHex(NapiGetString(env, args[1]), &tid)) {
    napi_create_int32(env, static_cast<int32_t>(X_STATUS_INVALID_PARAMETER),
                      &result);
    return result;
  }
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  int32_t content_type = 0;
  napi_get_value_int32(env, args[2], &content_type);
  const std::string pkg = NapiGetString(env, args[3]);
  const xe::X_STATUS status = xe::vfs::DeleteInstalledContent(
      root, tid, static_cast<uint32_t>(content_type), pkg);
  napi_create_int32(env, static_cast<int32_t>(status), &result);
  return result;
}

// createProfile(contentRoot, gamertag, language, country): string | null
napi_value CreateProfile(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) return NewNull(env);
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  const std::string gamertag = NapiGetString(env, args[1]);
  int32_t language = 0;
  int32_t country = 0;
  if (argc >= 3) napi_get_value_int32(env, args[2], &language);
  if (argc >= 4) napi_get_value_int32(env, args[3], &country);
  const std::string xuid = xe::kernel::xam::CreateStandaloneProfile(
      root, gamertag, static_cast<uint32_t>(language),
      static_cast<uint32_t>(country));
  return NewStringOrNull(env, xuid);
}

// listProfiles(contentRoot): ProfileInfo[]
napi_value ListProfiles(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value arr = nullptr;
  if (argc < 1) {
    napi_create_array_with_length(env, 0, &arr);
    return arr;
  }
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  std::vector<xe::kernel::xam::StandaloneProfile> profiles =
      xe::kernel::xam::ListStandaloneProfiles(root);
  napi_create_array_with_length(env, profiles.size(), &arr);
  for (size_t i = 0; i < profiles.size(); ++i) {
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(
        env, obj, "xuid",
        NapiNewString(env, fmt::format("{:016X}", profiles[i].xuid)));
    napi_set_named_property(env, obj, "gamertag",
                            NapiNewString(env, profiles[i].gamertag));
    SetUint32(env, obj, "language", profiles[i].language);
    SetUint32(env, obj, "country", profiles[i].country);
    napi_value has_avatar = nullptr;
    napi_get_boolean(env, profiles[i].has_avatar, &has_avatar);
    napi_set_named_property(env, obj, "hasAvatar", has_avatar);
    napi_set_element(env, arr, static_cast<uint32_t>(i), obj);
  }
  return arr;
}

// renameProfile(contentRoot, xuid, gamertag, language, country): number
napi_value RenameProfile(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value result = nullptr;
  uint64_t xuid = 0;
  if (argc < 3 || !ParseXuidHex(NapiGetString(env, args[1]), &xuid)) {
    napi_create_int32(env, static_cast<int32_t>(X_STATUS_INVALID_PARAMETER),
                      &result);
    return result;
  }
  const std::filesystem::path root =
      std::filesystem::u8path(NapiGetString(env, args[0]));
  const std::string gamertag = NapiGetString(env, args[2]);
  int32_t language = 0;
  int32_t country = 0;
  if (argc >= 4) napi_get_value_int32(env, args[3], &language);
  if (argc >= 5) napi_get_value_int32(env, args[4], &country);
  const xe::X_STATUS status = xe::kernel::xam::RenameStandaloneProfile(
      root, xuid, gamertag, static_cast<uint32_t>(language),
      static_cast<uint32_t>(country));
  napi_create_int32(env, static_cast<int32_t>(status), &result);
  return result;
}

}  // namespace

void RegisterContent(napi_env env, napi_value exports) {
  napi_value content = nullptr;
  napi_create_object(env, &content);
  napi_property_descriptor desc[] = {
      {"compressIsoToZar", nullptr, CompressIsoToZar, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"compressProgress", nullptr, CompressProgress, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"installContent", nullptr, InstallContent, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"installProgress", nullptr, InstallProgress, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"listDiscContent", nullptr, ListDiscContent, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"installDiscContent", nullptr, InstallDiscContent, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"contentHeader", nullptr, ContentHeader, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"listContent", nullptr, ListContent, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"deleteContent", nullptr, DeleteContent, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"createProfile", nullptr, CreateProfile, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"listProfiles", nullptr, ListProfiles, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"renameProfile", nullptr, RenameProfile, nullptr, nullptr, nullptr,
       napi_default, nullptr},
  };
  napi_define_properties(env, content, sizeof(desc) / sizeof(desc[0]), desc);
  napi_set_named_property(env, exports, "content", content);
}

}  // namespace hx360e
