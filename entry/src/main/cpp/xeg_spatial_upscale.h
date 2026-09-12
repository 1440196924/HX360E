// HX360E: XEngine Kit 空域超分（XEG_spatial_upscale）封装。
//
// 用途：我们做了次原生渲染（host 渲染目标是 guest 的 1/den），需要一个比
// 最近邻更好的放大来补回清晰度。XEngine 的 Vulkan 空域超分接受
// 「低分 VkImageView -> 高分 VkImageView」，正好对口。
//
// 注意：本 SDK 的 Vulkan 侧只有 xeg_vulkan_spatial_upscale.h（空域 GPU 超分）；
// 文档里的「空域 AI 超分 / neural upscale」的 Vulkan 支持是 API 26.0.0 才加的，
// 本机 SDK 与设备均无（设备查到的扩展是 XEG_spatial_upscale v1）。
//
// 全程 dlopen/dlsym，不硬链接 libxengine.so —— 非 Maleoon / 非中国区设备上
// libentry.so 仍可正常加载。

#ifndef HX360E_XEG_SPATIAL_UPSCALE_H_
#define HX360E_XEG_SPATIAL_UPSCALE_H_

#include <vulkan/vulkan.h>

#include <string>

#if defined(HX360E_HAVE_XENGINE_HEADERS)
#include <xengine/xeg_vulkan_spatial_upscale.h>
#else
extern "C" {
VK_DEFINE_HANDLE(XEG_SpatialUpscale)
typedef struct XEG_SpatialUpscaleCreateInfo {
  VkExtent2D inputSize;
  VkRect2D inputRegion;
  VkExtent2D outputSize;
  VkRect2D outputRegion;
  VkFormat format;
  float sharpness;
} XEG_SpatialUpscaleCreateInfo;
typedef struct XEG_SpatialUpscaleDescription {
  VkImageView inputImage;
  VkImageView outputImage;
} XEG_SpatialUpscaleDescription;
typedef VkResult(VKAPI_PTR* PFN_HMS_XEG_CreateSpatialUpscale)(
    VkDevice device, const XEG_SpatialUpscaleCreateInfo* pCreateInfo,
    XEG_SpatialUpscale* pXegSpatialUpscale);
typedef void(VKAPI_PTR* PFN_HMS_XEG_CmdRenderSpatialUpscale)(
    VkCommandBuffer commandBuffer, XEG_SpatialUpscale xegSpatialUpscale,
    XEG_SpatialUpscaleDescription* pDescription);
typedef void(VKAPI_PTR* PFN_HMS_XEG_DestroySpatialUpscale)(
    XEG_SpatialUpscale xegSpatialUpscale);
}  // extern "C"
#endif

namespace hx360e {

// 空域超分实例。生命周期：Initialize -> 每帧 Render -> Shutdown。
class XegSpatialUpscale {
 public:
  XegSpatialUpscale() = default;
  ~XegSpatialUpscale();

  XegSpatialUpscale(const XegSpatialUpscale&) = delete;
  XegSpatialUpscale& operator=(const XegSpatialUpscale&) = delete;

  // 打开 libxengine.so 并解析符号。可与设备无关地调用，用来判断能力是否可用。
  // 返回值：true 表示符号齐全（不代表本设备一定支持该特性）。
  static bool ProbeSymbols(std::string* detail_out);

  // 运行状态（不依赖日志：日志会被 hilog 的配额/去重整段丢弃）。
  // 形如 "created 1280x720->2560x1440, renders=123" 或失败原因。
  static std::string GetStatusForDisplay();

  // 创建超分对象。input_size / output_size 必须与后续 Render 传入的
  // VkImageView 尺寸一致（否则驱动行为未定义，可能崩溃）。
  bool Initialize(VkDevice device, VkExtent2D input_size,
                  VkExtent2D output_size, VkFormat format, float sharpness);

  // 录制超分命令。input / output 为 VkImageView。
  bool Render(VkCommandBuffer command_buffer, VkImageView input,
              VkImageView output);

  void Shutdown();

  bool is_initialized() const { return handle_ != nullptr; }

 private:
  void* library_ = nullptr;
  XEG_SpatialUpscale handle_ = nullptr;
  PFN_HMS_XEG_CreateSpatialUpscale create_ = nullptr;
  PFN_HMS_XEG_CmdRenderSpatialUpscale render_ = nullptr;
  PFN_HMS_XEG_DestroySpatialUpscale destroy_ = nullptr;
};

}  // namespace hx360e

#endif  // HX360E_XEG_SPATIAL_UPSCALE_H_
