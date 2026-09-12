// vulkan_context.h
// Phase 0.2: XComponent → OHNativeWindow → vkCreateSurfaceOHOS → swapchain 清屏。
// 详见 docs/DESIGN.md §5。
#ifndef HX360E_VULKAN_CONTEXT_H
#define HX360E_VULKAN_CONTEXT_H

#include <cstdint>
#include <string>

// 与 vulkan_ohos.h 一致的前置声明（不能写成 struct OHNativeWindow，否则 typedef 冲突）
typedef struct NativeWindow OHNativeWindow;

namespace hx360e {

class VulkanContext {
 public:
    // 用 XComponent 回调给出的 OHNativeWindow 初始化整条呈现链路：
    // instance → surface → device → swapchain → 同步对象 → vsync 循环。
    bool Init(OHNativeWindow* window, uint32_t width, uint32_t height);
    void Shutdown();

    // vsync 回调里调用：acquire → 清屏 → present
    void RenderFrame();

    bool IsReady() const { return ready_; }
    uint64_t FrameCount() const { return frame_count_; }
    double Fps() const;

    // 设备能力报告（Phase 0.4），用于 UI 展示与日志
    std::string GetDeviceInfo() const;

    // XEngine Kit（Maleoon GPU 加速）能力探测：临时建一个 instance 只为拿到
    // VkPhysicalDevice，然后用 HMS_XEG_EnumerateDeviceExtensionProperties 查询
    // 设备支持的 XEG 特性（libxengine.so 用 dlopen，不硬链接）。
    // 返回可读的特性清单；不支持时返回原因文本。
    static std::string ProbeXEngineExtensions();


 private:
    struct Impl;
    Impl* impl_ = nullptr;
    bool ready_ = false;
    uint64_t frame_count_ = 0;
    double fps_ = 0.0;
};

}  // namespace hx360e

#endif  // HX360E_VULKAN_CONTEXT_H
