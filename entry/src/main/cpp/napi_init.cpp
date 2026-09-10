// napi_init.cpp
// NAPI 模块注册 + XComponent 桥接。
// - 暴露 jitProbe() / vulkanStatus() 等 Phase 0 探测接口
// - XComponent(SURFACE) 加载本模块时，通过 __NATIVE_XCOMPONENT_OBJ__
//   拿到 OH_NativeXComponent 并注册回调，surface 创建后启动 Vulkan 呈现。
#include "napi/native_api.h"

#include <cstring>
#include <string>
#include <vector>

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <native_window/external_window.h>

// hilog 默认 LOG_TAG 为 NULL，会导致日志被丢弃；显式定义。
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

#include "jit_probe.h"
#include "vulkan_context.h"
#include "xendroid_ohos/ohos_emulator.h"

#define HILOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)

namespace {

hx360e::VulkanContext g_vulkan;
uint32_t g_surface_w = 0;
uint32_t g_surface_h = 0;

// ---------------- XComponent 回调 ----------------

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    if (component && window) {
        OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    }
    g_surface_w = static_cast<uint32_t>(w);
    g_surface_h = static_cast<uint32_t>(h);
    HILOG("XComponent: surface created %ux%u window=%{public}p", g_surface_w,
          g_surface_h, window);
    // Phase 2: surface 交给 xenia 的 OhosWindow（见 AttachSurface）。
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    if (component && window) {
        OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    }
    HILOG("XComponent: surface changed %ux%u",
          static_cast<uint32_t>(w), static_cast<uint32_t>(h));
    // spike：尺寸变化暂不重建 swapchain，仅记录
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
    HILOG("XComponent: surface destroyed");
    if (g_vulkan.IsReady()) {
        g_vulkan.Shutdown();  // 同步：内部 vkDeviceWaitIdle 后销毁
    }
}

void DispatchTouchEventCB(OH_NativeXComponent* component, void* window) {
    // spike：触摸事件暂不处理（Phase 4 再接入输入驱动）
}

void RegisterXComponent(napi_env env, napi_value exports) {
    napi_value export_instance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ,
                                &export_instance) != napi_ok ||
        export_instance == nullptr) {
        HILOG("XComponent: no __NATIVE_XCOMPONENT_OBJ__ in exports");
        return;
    }
    OH_NativeXComponent* native_xcomponent = nullptr;
    if (napi_unwrap(env, export_instance,
                    reinterpret_cast<void**>(&native_xcomponent)) != napi_ok ||
        native_xcomponent == nullptr) {
        HILOG("XComponent: napi_unwrap failed");
        return;
    }

    static OH_NativeXComponent_Callback cb;
    cb.OnSurfaceCreated = OnSurfaceCreatedCB;
    cb.OnSurfaceChanged = OnSurfaceChangedCB;
    cb.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
    cb.DispatchTouchEvent = DispatchTouchEventCB;
    OH_NativeXComponent_RegisterCallback(native_xcomponent, &cb);
    HILOG("XComponent: callbacks registered");
}

// ---------------- NAPI 接口 ----------------

// jitProbe(): 运行四策略探测，返回结构化结果
napi_value JitProbe(napi_env env, napi_callback_info info) {
    auto report = hx360e::RunJitProbe();

    napi_value result;
    napi_create_object(env, &result);

    for (int i = 0; i < static_cast<int>(hx360e::JitStrategy::kCount); ++i) {
        napi_value item;
        napi_create_object(env, &item);
        napi_value ok, err, step;
        napi_get_boolean(env, report.strategies[i].ok, &ok);
        napi_create_int32(env, report.strategies[i].errno_val, &err);
        napi_create_string_utf8(
            env, report.strategies[i].fail_step ? report.strategies[i].fail_step : "",
            NAPI_AUTO_LENGTH, &step);
        napi_set_named_property(env, item, "ok", ok);
        napi_set_named_property(env, item, "errno", err);
        napi_set_named_property(env, item, "failStep", step);
        napi_set_named_property(env, result, hx360e::JitStrategyName(i), item);
    }

    napi_value fw;
    napi_create_int32(env, report.first_working, &fw);
    napi_set_named_property(env, result, "firstWorking", fw);
    napi_value fw_name;
    napi_create_string_utf8(env, hx360e::JitStrategyName(report.first_working),
                            NAPI_AUTO_LENGTH, &fw_name);
    napi_set_named_property(env, result, "firstWorkingName", fw_name);
    return result;
}

// vulkanStatus(): { ready, frames, fps, deviceInfo }
napi_value VulkanStatus(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    napi_value ready, frames, fps, dev;
    napi_get_boolean(env, g_vulkan.IsReady(), &ready);
    napi_create_int64(env, static_cast<int64_t>(g_vulkan.FrameCount()),
                      &frames);
    napi_create_double(env, g_vulkan.Fps(), &fps);
    std::string dev_info = g_vulkan.GetDeviceInfo();
    napi_create_string_utf8(env, dev_info.c_str(), NAPI_AUTO_LENGTH, &dev);
    napi_set_named_property(env, result, "ready", ready);
    napi_set_named_property(env, result, "frames", frames);
    napi_set_named_property(env, result, "fps", fps);
    napi_set_named_property(env, result, "deviceInfo", dev);
    return result;
}

// attachSurface(surfaceId: string): 用 XComponent 的 surfaceId 创建 OHNativeWindow
// 并初始化 Vulkan 呈现链路。
// 路径参考 HMPS4e（已真机验证）：controller.getXComponentSurfaceId()
//   → OH_NativeWindow_CreateNativeWindowFromSurfaceId → vkCreateSurfaceOHOS。
// 不走 XComponent 回调的 window 参数（实测该路径 present 成功但内容不上屏）。
napi_value AttachSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        HILOG("AttachSurface: no arg");
        napi_value f;
        napi_get_boolean(env, false, &f);
        return f;
    }

    char id_buf[64] = {0};
    size_t id_len = 0;
    napi_get_value_string_utf8(env, args[0], id_buf, sizeof(id_buf), &id_len);

    uint64_t surface_id = 0;
    try {
        surface_id = std::stoull(std::string(id_buf, id_len));
    } catch (...) {
        HILOG("AttachSurface: bad surfaceId '%{public}s'", id_buf);
        napi_value f;
        napi_get_boolean(env, false, &f);
        return f;
    }

    OHNativeWindow* native_window = nullptr;
    int32_t err = OH_NativeWindow_CreateNativeWindowFromSurfaceId(
        surface_id, &native_window);
    if (err != 0 || native_window == nullptr) {
        HILOG("AttachSurface: CreateNativeWindowFromSurfaceId err=%{public}d", err);
        napi_value f;
        napi_get_boolean(env, false, &f);
        return f;
    }
    HILOG("AttachSurface: window=%{public}p surfaceId=%{public}llu",
          native_window, static_cast<unsigned long long>(surface_id));

    // 查询实际尺寸
    int32_t w = 0, h = 0;
    OH_NativeWindow_NativeWindowHandleOpt(native_window, GET_BUFFER_GEOMETRY, &w,
                                          &h);
    HILOG("AttachSurface: buffer geometry %{public}dx%{public}d", w, h);

    // Phase 2：把 OHNativeWindow 交给 xenia 的 OhosWindow，由其创建
    // vkCreateSurfaceOHOS + swapchain（不再走 Phase 0 的独立 Vulkan 呈现）。
    hx360e::SetNativeWindow(native_window);

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// ---------------- emulator 对象（Phase 1.7 headless 启动） ----------------

std::string GetStringArg(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::vector<char> buf(len + 1, '\0');
    napi_get_value_string_utf8(env, v, buf.data(), buf.size(), &len);
    return std::string(buf.data(), len);
}

napi_value EmulatorSetupGamePath(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        std::string path = GetStringArg(env, args[0]);
        hx360e::SetGamePath(path);
        HILOG("emulator.setupGamePath(%{public}s)", path.c_str());
    }
    return nullptr;
}

napi_value EmulatorSetupLaunchArgs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::vector<std::string> out;
    if (argc >= 1) {
        uint32_t count = 0;
        napi_get_array_length(env, args[0], &count);
        for (uint32_t i = 0; i < count; ++i) {
            napi_value item = nullptr;
            napi_get_element(env, args[0], i, &item);
            out.push_back(GetStringArg(env, item));
        }
    }
    hx360e::SetLaunchArgs(out);
    HILOG("emulator.setupLaunchArgs(count=%{public}zu)", out.size());
    return nullptr;
}

napi_value EmulatorBoot(napi_env env, napi_callback_info info) {
    HILOG("emulator.boot() invoked");
    hx360e::Boot();
    HILOG("emulator.boot() returned");
    return nullptr;
}

napi_value EmulatorPause(napi_env env, napi_callback_info info) {
    hx360e::Pause();
    return nullptr;
}

napi_value EmulatorResume(napi_env env, napi_callback_info info) {
    hx360e::Resume();
    return nullptr;
}

napi_value EmulatorQuit(napi_env env, napi_callback_info info) {
    hx360e::Quit();
    return nullptr;
}

napi_value EmulatorIsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, hx360e::IsRunning(), &result);
    return result;
}

napi_value EmulatorIsPaused(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, hx360e::IsPaused(), &result);
    return result;
}

napi_value EmulatorDeviceInfo(napi_env env, napi_callback_info info) {
    std::string info_str = hx360e::DeviceInfo();
    napi_value result;
    napi_create_string_utf8(env, info_str.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value EmulatorProbeFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path;
    if (argc >= 1) {
        path = GetStringArg(env, args[0]);
    }
    std::string report = hx360e::ProbeFile(path);
    napi_value result;
    napi_create_string_utf8(env, report.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// ---- 输入（Phase 4）----
// keyEvent(keyIndex, pressed, value)：keyIndex 为 OhosPadKey，
// value 为摇杆 [-32767,32767] 或扳机 [0,255]（布尔量传 0 即可）。
napi_value EmulatorKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t key_index = -1;
    bool pressed = false;
    int32_t value = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &key_index);
    }
    if (argc >= 2) {
        napi_get_value_bool(env, args[1], &pressed);
    }
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &value);
    }
    hx360e::PadKey(key_index, pressed, value);
    return nullptr;
}

napi_value EmulatorPadReleaseAll(napi_env env, napi_callback_info info) {
    hx360e::PadReleaseAll();
    return nullptr;
}

napi_value EmulatorPadStartPhysical(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, hx360e::PadStartPhysical(), &result);
    return result;
}

napi_value EmulatorPadStopPhysical(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, hx360e::PadStopPhysical(), &result);
    return result;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"jitProbe", nullptr, JitProbe, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"vulkanStatus", nullptr, VulkanStatus, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"attachSurface", nullptr, AttachSurface, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // emulator 子对象：生命周期 + 启动参数。
    napi_value emulator;
    napi_create_object(env, &emulator);
    napi_property_descriptor emu_desc[] = {
        {"setupGamePath", nullptr, EmulatorSetupGamePath, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"setupLaunchArgs", nullptr, EmulatorSetupLaunchArgs, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"boot", nullptr, EmulatorBoot, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"pause", nullptr, EmulatorPause, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"resume", nullptr, EmulatorResume, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"quit", nullptr, EmulatorQuit, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"isRunning", nullptr, EmulatorIsRunning, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"isPaused", nullptr, EmulatorIsPaused, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"deviceInfo", nullptr, EmulatorDeviceInfo, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"probeFile", nullptr, EmulatorProbeFile, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"keyEvent", nullptr, EmulatorKeyEvent, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"padReleaseAll", nullptr, EmulatorPadReleaseAll, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"padStartPhysical", nullptr, EmulatorPadStartPhysical, nullptr,
         nullptr, nullptr, napi_default, nullptr},
        {"padStopPhysical", nullptr, EmulatorPadStopPhysical, nullptr, nullptr,
         nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, emulator,
                           sizeof(emu_desc) / sizeof(emu_desc[0]), emu_desc);
    napi_set_named_property(env, exports, "emulator", emulator);

    RegisterXComponent(env, exports);

    // 模块加载时自动跑一次 JIT 探测，结果进 hilog（便于真机诊断）
    auto report = hx360e::RunJitProbe();
    HILOG("HX360E: JIT probe done, firstWorking=%{public}d (%{public}s)",
          report.first_working,
          hx360e::JitStrategyName(report.first_working));
    // memfd 双视图（写视图 RW + 执行视图 RW→mprotect(RX)）探测：代码缓存
    // 改双视图方案的前置验证。
    std::string memfd_report = hx360e::RunMemfdTwoViewProbe();
    HILOG("HX360E: %{public}s", memfd_report.c_str());
    return exports;
}
EXTERN_C_END

static napi_module hx360e_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHx360eModule(void) {
    napi_module_register(&hx360e_module);
}
