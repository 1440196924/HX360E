// HX360E: XEngine Kit 空域超分封装实现。见 xeg_spatial_upscale.h。

#include "xeg_spatial_upscale.h"

#include <dlfcn.h>

#include <hilog/log.h>

#define XEG_LOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define XEG_LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace hx360e {

namespace {

constexpr const char* kLibraryName = "libxengine.so";

}  // namespace

bool XegSpatialUpscale::ProbeSymbols(std::string* detail_out) {
  void* library = dlopen(kLibraryName, RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    const char* error = dlerror();
    if (detail_out) {
      *detail_out = std::string("libxengine.so 不可用（非 Maleoon / 非中国区设备）: ") +
                    (error != nullptr ? error : "?");
    }
    return false;
  }
  auto create =
      reinterpret_cast<PFN_HMS_XEG_CreateSpatialUpscale>(dlsym(
          library, "HMS_XEG_CreateSpatialUpscale"));
  auto render =
      reinterpret_cast<PFN_HMS_XEG_CmdRenderSpatialUpscale>(dlsym(
          library, "HMS_XEG_CmdRenderSpatialUpscale"));
  auto destroy =
      reinterpret_cast<PFN_HMS_XEG_DestroySpatialUpscale>(dlsym(
          library, "HMS_XEG_DestroySpatialUpscale"));
  dlclose(library);
  const bool ok = create != nullptr && render != nullptr && destroy != nullptr;
  if (detail_out) {
    *detail_out = ok ? "spatial_upscale 符号齐全"
                     : "spatial_upscale 符号缺失（Create/CmdRender/Destroy）";
  }
  return ok;
}

XegSpatialUpscale::~XegSpatialUpscale() { Shutdown(); }

bool XegSpatialUpscale::Initialize(VkDevice device, VkExtent2D input_size,
                                   VkExtent2D output_size, VkFormat format,
                                   float sharpness) {
  Shutdown();
  if (device == VK_NULL_HANDLE || input_size.width == 0 ||
      input_size.height == 0 || output_size.width == 0 ||
      output_size.height == 0) {
    XEG_LOGE("XegSpatialUpscale: invalid arguments");
    return false;
  }

  library_ = dlopen(kLibraryName, RTLD_NOW | RTLD_LOCAL);
  if (library_ == nullptr) {
    const char* error = dlerror();
    XEG_LOG("XegSpatialUpscale: libxengine.so unavailable: %{public}s",
            error != nullptr ? error : "?");
    return false;
  }
  create_ = reinterpret_cast<PFN_HMS_XEG_CreateSpatialUpscale>(
      dlsym(library_, "HMS_XEG_CreateSpatialUpscale"));
  render_ = reinterpret_cast<PFN_HMS_XEG_CmdRenderSpatialUpscale>(
      dlsym(library_, "HMS_XEG_CmdRenderSpatialUpscale"));
  destroy_ = reinterpret_cast<PFN_HMS_XEG_DestroySpatialUpscale>(
      dlsym(library_, "HMS_XEG_DestroySpatialUpscale"));
  if (create_ == nullptr || render_ == nullptr || destroy_ == nullptr) {
    XEG_LOGE("XegSpatialUpscale: symbols missing");
    Shutdown();
    return false;
  }

  XEG_SpatialUpscaleCreateInfo create_info{};
  create_info.inputSize = input_size;
  create_info.inputRegion.offset = {0, 0};
  create_info.inputRegion.extent = input_size;
  create_info.outputSize = output_size;
  create_info.outputRegion.offset = {0, 0};
  create_info.outputRegion.extent = output_size;
  create_info.format = format;
  create_info.sharpness = sharpness;

  const VkResult result = create_(device, &create_info, &handle_);
  if (result != VK_SUCCESS || handle_ == nullptr) {
    XEG_LOGE(
        "XegSpatialUpscale: HMS_XEG_CreateSpatialUpscale failed (%{public}d), "
        "%{public}ux%{public}u -> %{public}ux%{public}u",
        int(result), input_size.width, input_size.height, output_size.width,
        output_size.height);
    Shutdown();
    return false;
  }
  XEG_LOG(
      "XegSpatialUpscale: created %{public}ux%{public}u -> "
      "%{public}ux%{public}u sharpness=%{public}f",
      input_size.width, input_size.height, output_size.width,
      output_size.height, sharpness);
  return true;
}

bool XegSpatialUpscale::Render(VkCommandBuffer command_buffer,
                               VkImageView input, VkImageView output) {
  if (handle_ == nullptr || render_ == nullptr) {
    return false;
  }
  if (command_buffer == VK_NULL_HANDLE || input == VK_NULL_HANDLE ||
      output == VK_NULL_HANDLE) {
    return false;
  }
  XEG_SpatialUpscaleDescription description{};
  description.inputImage = input;
  description.outputImage = output;
  render_(command_buffer, handle_, &description);
  return true;
}

void XegSpatialUpscale::Shutdown() {
  if (handle_ != nullptr && destroy_ != nullptr) {
    destroy_(handle_);
  }
  handle_ = nullptr;
  create_ = nullptr;
  render_ = nullptr;
  destroy_ = nullptr;
  if (library_ != nullptr) {
    dlclose(library_);
    library_ = nullptr;
  }
}

}  // namespace hx360e
