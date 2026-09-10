// vulkan_context.cpp
// Phase 0.2 的呈现链路验证：instance → VK_OHOS_surface → device → swapchain
// → 每帧 transfer 清屏 → present，由 OH_NativeVSync 驱动。
// 同时记录设备能力（Phase 0.4）到日志与 deviceInfo 字符串。
#include "vulkan_context.h"

#include <chrono>
#include <cstring>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_ohos.h>

#include <native_vsync/native_vsync.h>

#include <hilog/log.h>

#define HILOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)

namespace hx360e {

namespace {

// VK_KHR_android_surface：PPSSPP 鸿蒙移植证实 OHOS 的 OHNativeWindow 兼容
// Android 的 surface 创建路径（其文档："OHOS 使用与 Android 相同的 window system"）。
// SDK 只提供了 sType 常量，结构体与函数指针需自行声明。
#define XE_VK_KHR_ANDROID_SURFACE_EXTENSION_NAME "VK_KHR_android_surface"

struct VkAndroidSurfaceCreateInfoKHR_X {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    void* window;  // ANativeWindow* / OHNativeWindow*
};

using PFN_vkCreateAndroidSurfaceKHR_X = VkResult(VKAPI_PTR*)(
    VkInstance instance, const VkAndroidSurfaceCreateInfoKHR_X* pCreateInfo,
    const VkAllocationCallbacks* pAllocator, VkSurfaceKHR* pSurface);

PFN_vkCreateSurfaceOHOS LoadCreateSurfaceOHOS(VkInstance instance) {
    auto fn = reinterpret_cast<PFN_vkCreateSurfaceOHOS>(
        vkGetInstanceProcAddr(instance, "vkCreateSurfaceOHOS"));
    return fn;
}

const char* VkResultStr(VkResult r) {
    switch (r) {
        case VK_SUCCESS: return "VK_SUCCESS";
        case VK_ERROR_OUT_OF_HOST_MEMORY: return "OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED: return "INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST: return "DEVICE_LOST";
        case VK_ERROR_OUT_OF_DATE_KHR: return "OUT_OF_DATE_KHR";
        case VK_SUBOPTIMAL_KHR: return "SUBOPTIMAL_KHR";
        case VK_ERROR_SURFACE_LOST_KHR: return "SURFACE_LOST_KHR";
        case VK_ERROR_NATIVE_WINDOW_IN_USE_KHR: return "NATIVE_WINDOW_IN_USE_KHR";
        default: return "other";
    }
}

}  // namespace

struct VulkanContext::Impl {
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    uint32_t graphics_family = 0;
    uint32_t present_family = 0;
    VkQueue graphics_queue = VK_NULL_HANDLE;
    VkQueue present_queue = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    std::vector<VkImage> swap_images;
    VkFormat swap_format = VK_FORMAT_UNDEFINED;
    VkExtent2D extent{};
    std::vector<VkImageView> image_views;
    VkCommandPool cmd_pool = VK_NULL_HANDLE;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkSemaphore image_available = VK_NULL_HANDLE;
    VkSemaphore render_finished = VK_NULL_HANDLE;
    VkFence in_flight = VK_NULL_HANDLE;
    PFN_vkCreateSurfaceOHOS create_surface_ohos = nullptr;
    PFN_vkAcquireNextImageKHR acquire = nullptr;
    PFN_vkQueuePresentKHR present = nullptr;
    OH_NativeVSync* vsync = nullptr;
    std::thread render_thread;
    std::atomic<bool> render_stop{false};
    std::string device_info;
    std::chrono::steady_clock::time_point fps_t0{};
    uint32_t fps_frames = 0;
    bool shutdown_requested = false;

};

namespace {

bool HasExtension(const std::vector<VkExtensionProperties>& props,
                  const char* name) {
    for (const auto& p : props) {
        if (std::strcmp(p.extensionName, name) == 0) return true;
    }
    return false;
}

void AppendFeatureLine(std::string& s, const char* name, VkBool32 v) {
    s += name;
    s += v ? "=1 " : "=0 ";
}

}  // namespace

bool VulkanContext::Init(OHNativeWindow* window, uint32_t width,
                         uint32_t height) {
    impl_ = new Impl();
    HILOG("VulkanCtx: init begin, window=%{public}p %ux%u", window, width,
          height);

    // ---- Instance ----
    uint32_t n = 0;
    vkEnumerateInstanceExtensionProperties(nullptr, &n, nullptr);
    std::vector<VkExtensionProperties> iext(n);
    if (n) vkEnumerateInstanceExtensionProperties(nullptr, &n, iext.data());
    const bool has_ohos_surface = HasExtension(iext, "VK_OHOS_surface");
    const bool has_android_surface =
        HasExtension(iext, XE_VK_KHR_ANDROID_SURFACE_EXTENSION_NAME);
    HILOG("VulkanCtx: VK_OHOS_surface=%{public}d VK_KHR_android_surface=%{public}d",
          has_ohos_surface, has_android_surface);
    if (!has_ohos_surface && !has_android_surface) {
        HILOG("VulkanCtx: FAIL — 无可用 surface 扩展");
        return false;
    }
    if (!HasExtension(iext, VK_KHR_SURFACE_EXTENSION_NAME)) {
        HILOG("VulkanCtx: FAIL — VK_KHR_surface missing");
        return false;
    }

    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "HX360E";
    app.apiVersion = VK_MAKE_API_VERSION(0, 1, 1, 0);
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    std::vector<const char*> iexts{VK_KHR_SURFACE_EXTENSION_NAME};
    if (has_ohos_surface) iexts.push_back("VK_OHOS_surface");
    if (has_android_surface)
        iexts.push_back(XE_VK_KHR_ANDROID_SURFACE_EXTENSION_NAME);
    ici.enabledExtensionCount = static_cast<uint32_t>(iexts.size());
    ici.ppEnabledExtensionNames = iexts.data();
    if (VkResult r = vkCreateInstance(&ici, nullptr, &impl_->instance);
        r != VK_SUCCESS) {
        HILOG("VulkanCtx: vkCreateInstance FAIL %{public}s", VkResultStr(r));
        return false;
    }

    impl_->create_surface_ohos = LoadCreateSurfaceOHOS(impl_->instance);
    auto create_android = reinterpret_cast<PFN_vkCreateAndroidSurfaceKHR_X>(
        vkGetInstanceProcAddr(impl_->instance, "vkCreateAndroidSurfaceKHR"));
    HILOG("VulkanCtx: vkCreateSurfaceOHOS=%{public}p vkCreateAndroidSurfaceKHR=%{public}p",
          reinterpret_cast<void*>(impl_->create_surface_ohos),
          reinterpret_cast<void*>(create_android));

    // ---- Surface ----
    // 优先走 Android 路径：PPSSPP 鸿蒙移植验证过它可用；OHOS 扩展路径在
    // XComponent 上实测 present 成功但内容不上屏。
    bool surface_ok = false;
    if (create_android) {
        VkAndroidSurfaceCreateInfoKHR_X sci{
            VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR, nullptr, 0,
            window};
        VkResult r = create_android(impl_->instance, &sci, nullptr,
                                    &impl_->surface);
        HILOG("VulkanCtx: vkCreateAndroidSurfaceKHR -> %{public}s",
              VkResultStr(r));
        surface_ok = (r == VK_SUCCESS);
    }
    if (!surface_ok && impl_->create_surface_ohos) {
        VkSurfaceCreateInfoOHOS sci{VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS};
        sci.window = window;
        VkResult r = impl_->create_surface_ohos(impl_->instance, &sci, nullptr,
                                                &impl_->surface);
        HILOG("VulkanCtx: vkCreateSurfaceOHOS -> %{public}s", VkResultStr(r));
        surface_ok = (r == VK_SUCCESS);
    }
    if (!surface_ok) {
        HILOG("VulkanCtx: FAIL — surface 创建失败");
        return false;
    }
    HILOG("VulkanCtx: surface created OK");

    // ---- Physical device ----
    uint32_t pd_count = 0;
    vkEnumeratePhysicalDevices(impl_->instance, &pd_count, nullptr);
    if (pd_count == 0) {
        HILOG("VulkanCtx: FAIL — no physical device");
        return false;
    }
    std::vector<VkPhysicalDevice> pds(pd_count);
    vkEnumeratePhysicalDevices(impl_->instance, &pd_count, pds.data());
    impl_->physical_device = pds[0];  // spike：取第一个

    VkPhysicalDeviceProperties props{};
    vkGetPhysicalDeviceProperties(impl_->physical_device, &props);
    HILOG("VulkanCtx: GPU %{public}s driver=0x%{public}x api=%u.%u.%u",
          props.deviceName, props.driverVersion,
          VK_API_VERSION_MAJOR(props.apiVersion),
          VK_API_VERSION_MINOR(props.apiVersion),
          VK_API_VERSION_PATCH(props.apiVersion));

    // 能力记录（Phase 0.4）
    VkPhysicalDeviceFeatures2 f2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
    VkPhysicalDeviceVulkan11Features f11{
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
    VkPhysicalDeviceVulkan12Features f12{
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    VkPhysicalDeviceVulkan13Features f13{
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    f2.pNext = &f11;
    f11.pNext = &f12;
    f12.pNext = &f13;
    vkGetPhysicalDeviceFeatures2(impl_->physical_device, &f2);

    std::string& info = impl_->device_info;
    info = props.deviceName;
    info += " | api " + std::to_string(VK_API_VERSION_MAJOR(props.apiVersion)) +
            "." + std::to_string(VK_API_VERSION_MINOR(props.apiVersion)) +
            "." + std::to_string(VK_API_VERSION_PATCH(props.apiVersion));
    info += " | sparse=" + std::to_string(f2.features.sparseBinding);
    AppendFeatureLine(info, "scalarBlock", f12.scalarBlockLayout);
    AppendFeatureLine(info, "fragStores", f2.features.fragmentStoresAndAtomics);
    AppendFeatureLine(info, "geo", f2.features.geometryShader);
    AppendFeatureLine(info, "dynRender", f13.dynamicRendering);
    AppendFeatureLine(info, "float16", f12.shaderFloat16);
    AppendFeatureLine(info, "int16", f2.features.shaderInt16);
    HILOG("VulkanCtx: caps %{public}s", info.c_str());
    // ---- Queue family ----
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(impl_->physical_device, &qf_count,
                                             nullptr);
    std::vector<VkQueueFamilyProperties> qfs(qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(impl_->physical_device, &qf_count,
                                             qfs.data());
    bool found = false;
    for (uint32_t i = 0; i < qf_count; ++i) {
        VkBool32 present_ok = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(impl_->physical_device, i,
                                             impl_->surface, &present_ok);
        if ((qfs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present_ok) {
            impl_->graphics_family = impl_->present_family = i;
            found = true;
            break;
        }
    }
    if (!found) {
        HILOG("VulkanCtx: FAIL — no graphics+present queue family");
        return false;
    }

    // ---- Device ----
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = impl_->graphics_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    const char* dexts[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = dexts;
    if (VkResult r = vkCreateDevice(impl_->physical_device, &dci, nullptr,
                                    &impl_->device);
        r != VK_SUCCESS) {
        HILOG("VulkanCtx: vkCreateDevice FAIL %{public}s", VkResultStr(r));
        return false;
    }
    vkGetDeviceQueue(impl_->device, impl_->graphics_family, 0,
                     &impl_->graphics_queue);
    vkGetDeviceQueue(impl_->device, impl_->present_family, 0,
                     &impl_->present_queue);
    impl_->acquire = reinterpret_cast<PFN_vkAcquireNextImageKHR>(
        vkGetDeviceProcAddr(impl_->device, "vkAcquireNextImageKHR"));
    impl_->present = reinterpret_cast<PFN_vkQueuePresentKHR>(
        vkGetDeviceProcAddr(impl_->device, "vkQueuePresentKHR"));

    // ---- Swapchain ----
    VkSurfaceCapabilitiesKHR caps{};
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(impl_->physical_device,
                                              impl_->surface, &caps);
    HILOG("VulkanCtx: caps extent=%ux%u minImg=%u maxImg=%u preTransform=%u "
          "composite=%u",
          caps.currentExtent.width, caps.currentExtent.height,
          caps.minImageCount, caps.maxImageCount, caps.currentTransform,
          caps.supportedCompositeAlpha);

    uint32_t fmt_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(impl_->physical_device,
                                         impl_->surface, &fmt_count, nullptr);
    std::vector<VkSurfaceFormatKHR> fmts(fmt_count);
    vkGetPhysicalDeviceSurfaceFormatsKHR(impl_->physical_device,
                                         impl_->surface, &fmt_count,
                                         fmts.data());
    VkSurfaceFormatKHR chosen = fmts[0];
    for (const auto& f : fmts) {
        if ((f.format == VK_FORMAT_B8G8R8A8_UNORM ||
             f.format == VK_FORMAT_R8G8B8A8_UNORM) &&
            f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            chosen = f;
            break;
        }
    }
    impl_->swap_format = chosen.format;

    impl_->extent = caps.currentExtent;
    if (impl_->extent.width == 0xFFFFFFFFu) {
        impl_->extent.width = width;
        impl_->extent.height = height;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount) {
        image_count = caps.maxImageCount;
    }

    VkSwapchainCreateInfoKHR swci{
        VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    swci.surface = impl_->surface;
    swci.minImageCount = image_count;
    swci.imageFormat = impl_->swap_format;
    swci.imageColorSpace = chosen.colorSpace;
    swci.imageExtent = impl_->extent;
    swci.imageArrayLayers = 1;
    swci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                      VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                      VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    swci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    swci.preTransform = (caps.supportedTransforms &
                         VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
                            ? VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR
                            : caps.currentTransform;
    swci.compositeAlpha = (caps.supportedCompositeAlpha &
                           VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
                              ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
                              : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    // present mode：优先 MAILBOX（shadPS4/HMPS4e 在鸿蒙上的默认值，已实测上屏），
    // 其次 IMMEDIATE，最后 FIFO（规范保证可用）。
    {
        uint32_t pm_count = 0;
        vkGetPhysicalDeviceSurfacePresentModesKHR(impl_->physical_device,
                                                  impl_->surface, &pm_count,
                                                  nullptr);
        std::vector<VkPresentModeKHR> pms(pm_count);
        vkGetPhysicalDeviceSurfacePresentModesKHR(impl_->physical_device,
                                                  impl_->surface, &pm_count,
                                                  pms.data());
        std::string pm_list;
        for (auto m : pms) pm_list += std::to_string(static_cast<int>(m)) + " ";
        HILOG("VulkanCtx: present modes = [%{public}s]", pm_list.c_str());
        swci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        for (auto m : pms) {
            if (m == VK_PRESENT_MODE_MAILBOX_KHR) {
                swci.presentMode = VK_PRESENT_MODE_MAILBOX_KHR;
                break;
            }
        }
        HILOG("VulkanCtx: chosen presentMode = %{public}d",
              static_cast<int>(swci.presentMode));
        impl_->device_info += " pm=" + std::to_string(static_cast<int>(swci.presentMode));
    }
    swci.clipped = VK_TRUE;
    if (VkResult r = vkCreateSwapchainKHR(impl_->device, &swci, nullptr,
                                          &impl_->swapchain);
        r != VK_SUCCESS) {
        HILOG("VulkanCtx: vkCreateSwapchainKHR FAIL %{public}s", VkResultStr(r));
        return false;
    }
    HILOG("VulkanCtx: swapchain OK fmt=%{public}d extent=%ux%u",
          static_cast<int>(impl_->swap_format), impl_->extent.width,
          impl_->extent.height);
    // 把 swapchain 关键参数记入 deviceInfo，便于真机诊断
    impl_->device_info += " | sc " + std::to_string(impl_->extent.width) + "x" +
                          std::to_string(impl_->extent.height) + " fmt=" +
                          std::to_string(static_cast<int>(impl_->swap_format)) +
                          " imgs=" + std::to_string(image_count) +
                          " preTransform=" + std::to_string(swci.preTransform) +
                          " composite=" + std::to_string(swci.compositeAlpha) +
                          " supAlpha=0x" + [&] {
                              char buf[16];
                              snprintf(buf, sizeof(buf), "%x",
                                       caps.supportedCompositeAlpha);
                              return std::string(buf);
                          }() +
                          " supXform=0x" + [&] {
                              char buf[16];
                              snprintf(buf, sizeof(buf), "%x",
                                       caps.supportedTransforms);
                              return std::string(buf);
                          }();

    // ---- Image views ----
    uint32_t img_count = 0;
    vkGetSwapchainImagesKHR(impl_->device, impl_->swapchain, &img_count,
                            nullptr);
    std::vector<VkImage> images(img_count);
    vkGetSwapchainImagesKHR(impl_->device, impl_->swapchain, &img_count,
                            images.data());
    impl_->swap_images = images;
    impl_->image_views.resize(img_count);
    for (uint32_t i = 0; i < img_count; ++i) {
        VkImageViewCreateInfo vci{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        vci.image = images[i];
        vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vci.format = impl_->swap_format;
        vci.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        if (VkResult r = vkCreateImageView(impl_->device, &vci, nullptr,
                                           &impl_->image_views[i]);
            r != VK_SUCCESS) {
            HILOG("VulkanCtx: vkCreateImageView FAIL %{public}s",
                  VkResultStr(r));
            return false;
        }
    }

    // ---- Command / sync ----
    VkCommandPoolCreateInfo pci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = impl_->graphics_family;
    vkCreateCommandPool(impl_->device, &pci, nullptr, &impl_->cmd_pool);
    VkCommandBufferAllocateInfo cai{
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cai.commandPool = impl_->cmd_pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    vkAllocateCommandBuffers(impl_->device, &cai, &impl_->cmd);

    VkSemaphoreCreateInfo sci2{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    vkCreateSemaphore(impl_->device, &sci2, nullptr, &impl_->image_available);
    vkCreateSemaphore(impl_->device, &sci2, nullptr, &impl_->render_finished);
    VkFenceCreateInfo fci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    vkCreateFence(impl_->device, &fci, nullptr, &impl_->in_flight);


    impl_->fps_t0 = std::chrono::steady_clock::now();

    // 渲染线程：独立循环 + 5ms 间隔（参考 HMPS4e 的 PresentLoop）。
    // 不用 OH_NativeVSync 回调驱动 —— 实测该路径下系统报
    // "fence is not pending, return timeout" 且内容不上屏。
    impl_->render_thread = std::thread([this]() {
        Impl* v = impl_;
        while (!v->render_stop.load()) {
            RenderFrame();
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    });

    ready_ = true;
    HILOG("VulkanCtx: init OK");
    return true;
}

void VulkanContext::RenderFrame() {
    if (!ready_ || !impl_) return;
    Impl* v = impl_;

    // FPS 统计
    ++frame_count_;
    ++v->fps_frames;
    auto now = std::chrono::steady_clock::now();
    double secs = std::chrono::duration<double>(now - v->fps_t0).count();
    if (secs >= 1.0) {
        fps_ = v->fps_frames / secs;
        v->fps_frames = 0;
        v->fps_t0 = now;
        HILOG("VulkanCtx: frame %{public}llu fps=%{public}.1f",
              static_cast<unsigned long long>(frame_count_), fps_);
    }

    vkWaitForFences(v->device, 1, &v->in_flight, VK_TRUE, UINT64_MAX);
    vkResetFences(v->device, 1, &v->in_flight);

    uint32_t idx = 0;
    VkResult r = v->acquire(v->device, v->swapchain, UINT64_MAX,
                            v->image_available, VK_NULL_HANDLE, &idx);
    if (r == VK_ERROR_OUT_OF_DATE_KHR || r == VK_SUBOPTIMAL_KHR) {
        return;
    }
    if (r != VK_SUCCESS) {
        return;
    }

    vkResetCommandBuffer(v->cmd, 0);
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(v->cmd, &bi);

    // 用醒目的红/绿交替色，便于肉眼与截图确认呈现链路是否真的上屏
    // （纯色交替，不画几何体：Phase 0.2 只验证 swapchain + present + vsync）
    const bool red_phase = ((frame_count_ / 30) % 2) == 0;
    VkClearColorValue color{};
    color.float32[0] = red_phase ? 1.0f : 0.0f;
    color.float32[1] = red_phase ? 0.0f : 1.0f;
    color.float32[2] = 0.0f;
    color.float32[3] = 1.0f;

    VkImageMemoryBarrier to_dst{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    to_dst.srcAccessMask = 0;
    to_dst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_dst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    to_dst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_dst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.image = v->swap_images[idx];
    to_dst.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(v->cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                         nullptr, 1, &to_dst);
    // 显式传 range（rangeCount=1）。不要依赖 rangeCount=0 的隐含语义：
    // HMPS4e 的 clearColorImage 走的是 rangeCount=1 路径，Maleoon 驱动
    // 对 0 的处理未验证。
    VkImageSubresourceRange clear_range{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(v->cmd, v->swap_images[idx],
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1,
                         &clear_range);

    // 转回 PRESENT_SRC
    VkImageMemoryBarrier to_src = to_dst;
    to_src.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_src.dstAccessMask = 0;
    to_src.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_src.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(v->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr,
                         0, nullptr, 1, &to_src);

    vkEndCommandBuffer(v->cmd);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &v->image_available;
    si.pWaitDstStageMask = &wait_stage;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &v->cmd;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &v->render_finished;
    vkQueueSubmit(v->graphics_queue, 1, &si, v->in_flight);

    VkPresentInfoKHR pi{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &v->render_finished;
    pi.swapchainCount = 1;
    pi.pSwapchains = &v->swapchain;
    pi.pImageIndices = &idx;
    v->present(v->present_queue, &pi);

}

double VulkanContext::Fps() const { return fps_; }

std::string VulkanContext::GetDeviceInfo() const {
    return impl_ ? impl_->device_info : std::string("not initialized");
}


void VulkanContext::Shutdown() {
    if (!impl_) return;
    Impl* v = impl_;
    v->shutdown_requested = true;
    v->render_stop.store(true);
    if (v->render_thread.joinable()) {
        v->render_thread.join();
    }
    if (v->vsync) {
        OH_NativeVSync_Destroy(v->vsync);
        v->vsync = nullptr;
    }
    if (v->device != VK_NULL_HANDLE) vkDeviceWaitIdle(v->device);
    for (auto iv : v->image_views) {
        if (iv != VK_NULL_HANDLE) vkDestroyImageView(v->device, iv, nullptr);
    }
    if (v->swapchain != VK_NULL_HANDLE)
        vkDestroySwapchainKHR(v->device, v->swapchain, nullptr);
    if (v->image_available != VK_NULL_HANDLE)
        vkDestroySemaphore(v->device, v->image_available, nullptr);
    if (v->render_finished != VK_NULL_HANDLE)
        vkDestroySemaphore(v->device, v->render_finished, nullptr);
    if (v->in_flight != VK_NULL_HANDLE)
        vkDestroyFence(v->device, v->in_flight, nullptr);
    if (v->cmd_pool != VK_NULL_HANDLE)
        vkDestroyCommandPool(v->device, v->cmd_pool, nullptr);
    if (v->device != VK_NULL_HANDLE) vkDestroyDevice(v->device, nullptr);
    if (v->surface != VK_NULL_HANDLE)
        vkDestroySurfaceKHR(v->instance, v->surface, nullptr);
    if (v->instance != VK_NULL_HANDLE) vkDestroyInstance(v->instance, nullptr);
    delete v;
    impl_ = nullptr;
    ready_ = false;
    HILOG("VulkanCtx: shutdown OK");
}

}  // namespace hx360e
