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


 private:
    struct Impl;
    Impl* impl_ = nullptr;
    bool ready_ = false;
    uint64_t frame_count_ = 0;
    double fps_ = 0.0;
};

}  // namespace hx360e

#endif  // HX360E_VULKAN_CONTEXT_H
