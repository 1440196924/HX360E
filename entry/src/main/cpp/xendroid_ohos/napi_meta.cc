// HX360E NAPI 桥接：meta（Phase 5.2）。
//
// 迁移自上游 emulator_xendroid.cpp 的 JNI 元数据扫描：
//   titleIdFromPath(path, format)  仅读 XEX 头，返回 8 位大写十六进制 title id
//   metaFromPath(path, format)     ISO/ZAR/default.xex -> {name, icon, titleId, ...}
//   metaInfoFromGodPath(path)      STFS/GOD 容器头 -> 同上
//
// format: 0=ISO, 1=XEX_FOLDER(default.xex), 2=ZAR（与 Kotlin GameFormat.titleIdCode 一致）。
//
// 注意：extract_xex_meta 会构造一个临时的 xe::Memory（进程内单例地址空间），
// 因此**不能在游戏运行中调用**。这里在入口处用 hx360e::IsRunning() 兜底。
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include <hilog/log.h>

#include "napi_bridge.h"
#include "ohos_emulator.h"

#include "third_party/fmt/include/fmt/format.h"

#include "xenia/base/mapped_memory.h"
#include "xenia/base/string.h"
#include "xenia/cpu/processor.h"
#include "xenia/cpu/xex_module.h"
#include "xenia/kernel/util/xex2_info.h"
#include "xenia/kernel/xam/xdbf/spa_info.h"
#include "xenia/memory.h"
#include "xenia/vfs/devices/disc_image_device.h"
#include "xenia/vfs/devices/disc_zarchive_device.h"
#include "xenia/vfs/file.h"
#include "xenia/vfs/iso_metadata.h"
#include "xenia/vfs/stfs_metadata.h"
#include "xenia/vfs/xex_metadata.h"
#include "xenia/vfs/zar_metadata.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

namespace hx360e {
namespace {

enum : int { kFmtIso = 0, kFmtXexFolder = 1, kFmtZar = 2 };

// ---- 从上游原样迁移的轻量解析辅助 ----

// Light, boot-free XEX2 header walk -> execution_info.title_id.
static bool ReadXexTitleId(const uint8_t* data, size_t size, uint32_t* out,
                           uint32_t* media_id_out = nullptr,
                           uint32_t* disc_number_out = nullptr,
                           uint32_t* disc_count_out = nullptr) {
  using namespace xe;
  using namespace xe::cpu;

  if (!data || size < sizeof(xex2_header)) return false;
  auto* h = reinterpret_cast<const xex2_header*>(data);
  const uint32_t magic = h->magic.get();
  if (magic != kXEX2Signature && magic != kXEX1Signature) return false;

  const uint32_t count = h->header_count.get();
  if (0x18ull + uint64_t(count) * sizeof(xex2_opt_header) > size) return false;

  void* exec_raw = nullptr;
  if (!XexModule::GetOptHeader(h, XEX_HEADER_EXECUTION_INFO, &exec_raw)) {
    return false;
  }
  if (!exec_raw) return false;

  const auto* p = reinterpret_cast<const uint8_t*>(exec_raw);
  if (p < data || p + sizeof(xex2_opt_execution_info) > data + size) {
    return false;
  }

  auto* exec_info = reinterpret_cast<const xex2_opt_execution_info*>(p);
  *out = exec_info->title_id.get();
  if (media_id_out) *media_id_out = exec_info->media_id.get();
  if (disc_number_out) *disc_number_out = exec_info->disc_number;
  if (disc_count_out) *disc_count_out = exec_info->disc_count;
  return true;
}

struct XexMeta {
  std::string name;
  std::vector<uint8_t> icon;
  uint32_t title_id = 0;
  uint32_t media_id = 0;
  uint32_t disc_number = 0;
  uint32_t disc_count = 0;
};

static bool IsWellFormedUtf8(const std::string& s) {
  const auto* p = reinterpret_cast<const unsigned char*>(s.data());
  const size_t n = s.size();
  for (size_t i = 0; i < n;) {
    const unsigned char c = p[i];
    if (c == 0x00) return false;
    size_t extra;
    if (c < 0x80) {
      extra = 0;
    } else if ((c & 0xE0) == 0xC0) {
      if (c < 0xC2) return false;
      extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
      extra = 2;
    } else {
      return false;
    }
    if (i + extra >= n) return false;
    for (size_t k = 1; k <= extra; k++) {
      if ((p[i + k] & 0xC0) != 0x80) return false;
    }
    i += extra + 1;
  }
  return true;
}

static std::string ReadSpaTitleForLanguage(
    const xe::kernel::xam::SpaInfo& spa, xe::XLanguage lang) {
  using namespace xe::kernel::xam;

  const Entry* section = spa.GetEntry(
      static_cast<uint16_t>(SpaSection::kStringTable),
      static_cast<uint64_t>(lang));
  if (!section) return "";

  const uint8_t* const begin = section->data.data();
  const size_t avail = section->data.size();
  if (avail < sizeof(XdbfSectionHeaderEx)) return "";

  const auto* header = reinterpret_cast<const XdbfSectionHeaderEx*>(begin);
  if (header->magic != kXdbfSignatureXstr) return "";

  const uint8_t* ptr = begin + sizeof(XdbfSectionHeaderEx);
  const uint8_t* const end = begin + avail;
  const uint16_t count = header->count;

  for (uint16_t i = 0; i < count; i++) {
    if (ptr + sizeof(XdbfStringTableEntry) > end) return "";
    const auto* entry = reinterpret_cast<const XdbfStringTableEntry*>(ptr);
    const uint16_t str_len = entry->string_length;
    const uint8_t* str_ptr = ptr + sizeof(XdbfStringTableEntry);
    if (str_ptr + str_len > end) return "";

    if (entry->id == static_cast<uint16_t>(kXdbfIdTitle)) {
      std::string result(reinterpret_cast<const char*>(str_ptr), str_len);
      const size_t nul = result.find('\0');
      if (nul != std::string::npos) result.resize(nul);
      if (result.empty() || !IsWellFormedUtf8(result)) return "";
      return result;
    }
    ptr = str_ptr + str_len;
  }
  return "";
}

static std::string ReadSpaTitleNameBounded(
    const xe::kernel::xam::SpaInfo& spa) {
  std::string name = ReadSpaTitleForLanguage(spa, xe::XLanguage::kEnglish);
  if (!name.empty()) return name;

  const xe::XLanguage def = spa.default_language();
  if (def != xe::XLanguage::kEnglish) {
    name = ReadSpaTitleForLanguage(spa, def);
  }
  return name;
}

// Decompress default.xex into a transient guest address space and pull both the
// XDBF/SPA title name and icon. 详见上游注释（bounds guards）。
static XexMeta ExtractXexMeta(const uint8_t* base, size_t size) {
  using namespace xe;
  using namespace xe::cpu;

  XexMeta out;
  if (!base || size < sizeof(xex2_header)) return out;

  auto* hdr = reinterpret_cast<const xex2_header*>(base);
  const uint32_t magic = hdr->magic.get();
  if (magic != kXEX2Signature && magic != kXEX1Signature) return out;
  if (hdr->header_size.get() > size) return out;

  static std::atomic<bool> s_memory_in_use{false};
  bool expected = false;
  if (!s_memory_in_use.compare_exchange_strong(expected, true)) return out;
  struct MemoryGuard {
    ~MemoryGuard() { s_memory_in_use.store(false); }
  } mem_guard;

  xe::Memory memory;
  if (!memory.Initialize()) return out;
  xe::cpu::Processor processor(&memory, nullptr);

  auto xex_module = std::make_unique<XexModule>(&processor, nullptr);

  bool loaded = false;
  try {
    loaded = xex_module->Load("default", "default.xex", base, size);
  } catch (...) {
    loaded = false;
  }
  if (!loaded) return out;

  void* res_raw = nullptr;
  if (!XexModule::GetOptHeader(hdr, XEX_HEADER_RESOURCE_INFO, &res_raw) ||
      !res_raw) {
    return out;
  }
  const uint8_t* rp = reinterpret_cast<const uint8_t*>(res_raw);
  if (rp < base || rp + sizeof(xex2_opt_resource_info) > base + size) {
    return out;
  }
  auto* res_hdr = reinterpret_cast<const xex2_opt_resource_info*>(rp);
  const uint32_t res_blob_size = res_hdr->size.get();
  if (res_blob_size < 4) return out;
  const uint32_t count = (res_blob_size - 4) / uint32_t(sizeof(xex2_resource));
  if (uint64_t(rp - base) + 4 + uint64_t(count) * sizeof(xex2_resource) > size) {
    return out;
  }

  uint32_t title_id = 0;
  uint32_t media_id = 0;
  uint32_t disc_number = 0;
  uint32_t disc_count = 0;
  if (!ReadXexTitleId(base, size, &title_id, &media_id, &disc_number,
                      &disc_count) ||
      title_id == 0) {
    return out;
  }
  out.title_id = title_id;
  out.media_id = media_id;
  out.disc_number = disc_number;
  out.disc_count = disc_count;
  const std::string res_name = fmt::format("{:08X}", title_id);

  uint32_t res_addr = 0;
  uint32_t res_size = 0;
  for (uint32_t i = 0; i < count; i++) {
    const xex2_resource& r = res_hdr->resources[i];
    if (std::memcmp(r.name, res_name.data(), 8) == 0) {
      res_addr = r.address.get();
      res_size = r.size.get();
      break;
    }
  }
  if (res_addr == 0 || res_size == 0) return out;

  if (uint64_t(res_addr) + res_size < res_addr) return out;
  const uint32_t img_base = xex_module->base_address();
  const uint64_t img_end = uint64_t(img_base) + xex_module->image_size();
  if (res_addr < img_base || uint64_t(res_addr) + res_size > img_end) {
    return out;
  }
  if (!memory.LookupHeap(res_addr)) return out;
  uint8_t* res_ptr = memory.TranslateVirtual(res_addr);
  if (!res_ptr) return out;

  try {
    xe::kernel::xam::SpaInfo spa(std::span<uint8_t>(res_ptr, res_size));
    std::span<const uint8_t> icon = spa.title_icon();
    if (!icon.empty()) {
      out.icon.assign(icon.begin(), icon.end());
    }
    out.name = ReadSpaTitleNameBounded(spa);
  } catch (...) {
    out.icon.clear();
    out.name.clear();
  }
  return out;
}

static std::vector<uint8_t> ReadVfsEntryBytes(xe::vfs::Entry* e) {
  using namespace xe;
  std::vector<uint8_t> out;
  if (!e) return out;
  vfs::File* in = nullptr;
  if (e->Open(vfs::FileAccess::kFileReadData, &in) != X_STATUS_SUCCESS || !in) {
    return out;
  }
  const size_t size = e->size();
  out.resize(size);
  size_t total = 0;
  while (total < size) {
    size_t got = 0;
    if (in->ReadSync(std::span<uint8_t>(out.data() + total, size - total),
                     total, &got) != X_STATUS_SUCCESS ||
        got == 0) {
      break;
    }
    total += got;
  }
  in->Destroy();
  out.resize(total);
  return out;
}

static std::vector<uint8_t> ReadDiscDefaultXex(const std::filesystem::path& p,
                                               int format) {
  using namespace xe;
  std::vector<uint8_t> out;
  if (format == kFmtIso) {
    vfs::DiscImageDevice dev("\\Device\\Cdrom0", p);
    if (!dev.Initialize()) return out;
    out = ReadVfsEntryBytes(dev.ResolvePath("default.xex"));
  } else if (format == kFmtZar) {
    vfs::DiscZarchiveDevice dev("\\Device\\Cdrom0", p);
    if (!dev.Initialize()) return out;
    out = ReadVfsEntryBytes(dev.ResolvePath("default.xex"));
  }
  return out;
}

std::optional<xe::vfs::XexMetadata> ExtractHeaderMeta(
    const std::filesystem::path& p, int format) {
  switch (format) {
    case kFmtIso:
      return xe::vfs::ExtractIsoMetadata(p);
    case kFmtXexFolder:
      return xe::vfs::ExtractXexMetadata(p);
    case kFmtZar:
      return xe::vfs::ExtractZarMetadata(p);
    default:
      return std::nullopt;
  }
}

std::string FormatTitleId(uint32_t title_id) {
  return title_id == 0 ? std::string() : fmt::format("{:08X}", title_id);
}

napi_value NewStringOrNull(napi_env env, const std::string& s) {
  if (s.empty()) {
    napi_value null_value = nullptr;
    napi_get_null(env, &null_value);
    return null_value;
  }
  return NapiNewString(env, s);
}

// 构造 GameInfo 对象（字段与 Kotlin xendroid.compose.Emulator$GameInfo 对齐）。
napi_value MakeGameInfo(napi_env env, const std::string& uri,
                        const std::string& name, uint32_t title_id,
                        uint32_t media_id, uint32_t disc_number,
                        uint32_t disc_count, const std::vector<uint8_t>& icon) {
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  napi_set_named_property(env, obj, "uri", NapiNewString(env, uri));
  napi_set_named_property(env, obj, "name", NewStringOrNull(env, name));
  napi_set_named_property(env, obj, "titleId",
                          NewStringOrNull(env, FormatTitleId(title_id)));
  napi_set_named_property(env, obj, "mediaId",
                          NewStringOrNull(env, FormatTitleId(media_id)));
  napi_value number = nullptr;
  napi_create_int32(env, static_cast<int32_t>(disc_number), &number);
  napi_set_named_property(env, obj, "discNumber", number);
  napi_create_int32(env, static_cast<int32_t>(disc_count), &number);
  napi_set_named_property(env, obj, "discCount", number);

  if (!icon.empty()) {
    void* data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, icon.size(), &data, &buffer) == napi_ok &&
        data) {
      std::memcpy(data, icon.data(), icon.size());
      napi_set_named_property(env, obj, "icon", buffer);
    }
  }
  return obj;
}

bool ReadPathArg(napi_env env, napi_callback_info info, std::string* path,
                 int* format) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) return false;
  *path = NapiGetString(env, args[0]);
  if (path->empty()) return false;
  if (format && argc >= 2) {
    napi_get_value_int32(env, args[1], format);
  }
  return true;
}

// ---------------- NAPI 实现 ----------------

// titleIdFromPath(path, format): string | null
napi_value MetaTitleIdFromPath(napi_env env, napi_callback_info info) {
  std::string path;
  int format = 0;
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  if (!ReadPathArg(env, info, &path, &format)) return null_value;

  const std::filesystem::path p = std::filesystem::u8path(path);
  std::optional<xe::vfs::XexMetadata> meta = ExtractHeaderMeta(p, format);
  if (!meta || meta->title_id == 0) return null_value;
  return NapiNewString(env, fmt::format("{:08X}", meta->title_id));
}

// metaFromPath(path, format): GameInfo | null
napi_value MetaFromPath(napi_env env, napi_callback_info info) {
  std::string path;
  int format = 0;
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  if (!ReadPathArg(env, info, &path, &format)) return null_value;
  if (IsRunning()) {
    OH_LOG_WARN(LOG_APP,
                "meta.metaFromPath 在游戏运行中被调用，跳过（避免 Memory 单例冲突）");
    return null_value;
  }

  const std::filesystem::path p = std::filesystem::u8path(path);
  XexMeta meta;

  switch (format) {
    case kFmtXexFolder: {
      std::unique_ptr<xe::MappedMemory> mmap =
          xe::MappedMemory::Open(p, xe::MappedMemory::Mode::kRead);
      if (!mmap) break;
      meta = ExtractXexMeta(mmap->data(), mmap->size());
      break;
    }
    case kFmtIso:
    case kFmtZar: {
      std::vector<uint8_t> xex = ReadDiscDefaultXex(p, format);
      if (!xex.empty()) meta = ExtractXexMeta(xex.data(), xex.size());
      break;
    }
    default:
      break;
  }

  if (meta.title_id == 0) {
    std::optional<xe::vfs::XexMetadata> hdr = ExtractHeaderMeta(p, format);
    if (hdr) {
      meta.title_id = hdr->title_id;
      meta.media_id = hdr->media_id;
      meta.disc_number = hdr->disc_number;
      meta.disc_count = hdr->disc_count;
    }
  }

  if (meta.name.empty() && meta.icon.empty() && meta.title_id == 0) {
    return null_value;
  }
  return MakeGameInfo(env, path, meta.name, meta.title_id, meta.media_id,
                      meta.disc_number, meta.disc_count, meta.icon);
}

// metaInfoFromGodPath(path): GameInfo | null
napi_value MetaInfoFromGodPath(napi_env env, napi_callback_info info) {
  std::string path;
  napi_value null_value = nullptr;
  napi_get_null(env, &null_value);
  if (!ReadPathArg(env, info, &path, nullptr)) return null_value;

  const std::filesystem::path p = std::filesystem::u8path(path);
  std::optional<xe::vfs::StfsMetadata> meta =
      xe::vfs::ExtractStfsMetadata(p, xe::XLanguage::kEnglish);
  if (!meta) return null_value;

  const std::string& name =
      !meta->title_name.empty() ? meta->title_name : meta->display_name;
  return MakeGameInfo(env, path, name, meta->title_id, meta->media_id,
                      meta->disc_number, meta->disc_count, meta->icon_data);
}

}  // namespace

void RegisterMeta(napi_env env, napi_value exports) {
  napi_value meta = nullptr;
  napi_create_object(env, &meta);
  napi_property_descriptor desc[] = {
      {"titleIdFromPath", nullptr, MetaTitleIdFromPath, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"metaFromPath", nullptr, MetaFromPath, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"metaInfoFromGodPath", nullptr, MetaInfoFromGodPath, nullptr, nullptr,
       nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, meta, sizeof(desc) / sizeof(desc[0]), desc);
  napi_set_named_property(env, exports, "meta", meta);
}

}  // namespace hx360e
