# HX360E 设计文档

| 项目 | 内容 |
| --- | --- |
| 项目名 | HX360E — HarmonyOS Xbox 360 模拟器 |
| 目标平台 | HarmonyOS NEXT（API 24 / 6.1.1 起） |
| 上游 | [XenDroid](https://github.com/rfandango/XenDroid)（Xenia Canary / Edge 分支的 Android 移植） |
| 关联文档 | [鸿蒙移植可行性分析报告](./鸿蒙移植可行性分析报告.md)（以下简称"可行性报告"） |
| 任务清单 | [TODO.md](./TODO.md) — 分阶段任务分解与进度追踪 |
| 版本 | v1.0 — 2026-09-08 |
| 状态 | 设计定稿，待 Phase 0 验证后进入实现 |

---

## 0. 文档说明

本文档回答"怎么做"。可行性报告回答"能不能做"、给出证据与风险清单；本文档给出**分层结构、模块接口、关键实现方案与验收标准**。

两者关系：

| 问题 | 文档 |
| --- | --- |
| 能不能移植？工作量多大？风险在哪？ | 可行性报告 |
| 怎么分层？接口长什么样？先做什么？ | 本文档 |

**设计基线**（来自可行性报告的实测结论，本文档不再重复论证）：

- 编译器：clang 15.0.4（BiSheng 或 Original 二者等价），libc++ 15，C++20 可用但有 6 个调用点需改。
- 图形：`VK_OHOS_surface` + `vkCreateSurfaceOHOS`，surface 来自 XComponent 的 `OHNativeWindow`。
- JIT：四策略运行时探测，XenDroid 已内置文件映射双视图方案。
- 音频：OHAudio（`libohaudio.so`）。
- 输入：GameControllerKit + ArkUI 事件。
- 桥接：NAPI 取代 JNI。
- 兼容性：CPU 侧与 Android 一致；GPU 侧受驱动影响会下降。

---

## 1. 项目目标与范围

### 1.1 目标

1. 在 HarmonyOS NEXT 真机上**运行 Xbox 360 游戏**，图形后端仅 Vulkan。
2. 复用 XenDroid/Xenia 内核（约 39.8 万行 C++）不做大改，平台层重写。
3. 保持与上游 XenDroid 的可同步性：改动以补丁序列管理，可周期性 rebase。
4. 提供可用的 ArkTS 前端：选游戏、进游戏、操作、退出。

### 1.2 非目标（明确不做）

| 不做 | 原因 |
| --- | --- |
| OpenGL / GLES 图形后端 | 需求明确只要 Vulkan；且上游 Android 构建本来就只编 Vulkan |
| D3D12 / Metal 后端 | 平台无关，但不在范围内 |
| 自定义 Vulkan 驱动加载（类 adrenotools） | 鸿蒙无对应机制，删除 |
| 多进程模型（Android 的 `:emu` 进程） | 鸿蒙不支持应用自有子进程；改单进程 |
| x86_64 目标 | AArch64 JIT 无法在 x86_64 上工作 |
| 桌面端功能（wxWidgets UI、调试器 GUI） | 上游 Android 构建已排除 |
| 全盘游戏库扫描 | 鸿蒙无 `MANAGE_EXTERNAL_STORAGE` 等价权限；改为**安装到沙箱**（见 §10） |
| 外部路径直读模式（`persistPermission` 引用） | MVP 不做，作为未来优化（见 §10.1 方案 B） |

### 1.3 交付物

| 产物 | 说明 |
| --- | --- |
| `libhx360e.so` | NAPI 模块 + 模拟器内核（单一 .so，静态链接 libc++） |
| `entry/src/main/ets/**` | ArkTS 前端 |
| `patches/harmony/*.patch` | 对上游的补丁序列 |
| 兼容性列表 | 已验证可运行/有问题的标题清单 |

---

## 2. 总体架构

### 2.1 分层视图

```
┌─────────────────────────────────────────────────────────────┐
│  ArkTS 前端（entry/src/main/ets）                            │
│  · 游戏库 / 设置 / 虚拟手柄 / 提示面板 / 覆盖层              │
│  · 游戏安装器（picker → 预检 → 流式拷贝 → 校验）            │
│  · 存储管理（空间统计 / 卸载 / 存档导出导入）               │
│  · XComponent（渲染表面载体）                                │
└────────────────────────┬────────────────────────────────────┘
                         │ NAPI（C 接口，无 C++ ABI 跨界）
┌────────────────────────┴────────────────────────────────────┐
│  NAPI 桥接层（entry/src/main/cpp/napi/）                     │
│  · 生命周期：boot / pause / resume / quit                    │
│  · 事件：keyEvent / touchEvent                               │
│  · 配置：Config 句柄                                         │
│  · 提示轮询：keyboard / msgbox / discSwap                    │
│  · 元数据：titleId / meta / icon                             │
└────────────────────────┬────────────────────────────────────┘
                         │ C++（同一进程内直接调用）
┌────────────────────────┴────────────────────────────────────┐
│  XenDroid 内核（entry/src/main/cpp/xendroid/，上游 fork）    │
│  · cpu/backend/a64（xbyak_aarch64 JIT）                      │
│  · gpu/vulkan（PM4 → Vulkan 翻译、渲染目标/纹理/管线缓存）   │
│  · kernel / memory / vfs / apu / hid                        │
└────────────────────────┬────────────────────────────────────┘
                         │ 平台接口
┌────────────────────────┴────────────────────────────────────┐
│  OHOS 平台层（entry/src/main/cpp/xendroid_ohos/）            │
│  · 表面/窗口：surface_ohos / window_ohos                     │
│  · 可执行内存：jit_memory_ohos                               │
│  · 音频：ohaudio_audio_driver                                │
│  · 输入：gamepad_ohos / input_driver                         │
│  · 日志：hilog sink                                          │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────┐
│  HarmonyOS 系统能力                                          │
│  libvulkan.so · libnative_window.so · libace_ndk.z.so        │
│  libohaudio.so · libohgame_controller.z.so · libhilog_ndk.z.so│
└─────────────────────────────────────────────────────────────┘
```

**设计要点**：平台层与内核分离。内核只通过少数几个接缝（`platform.h` 宏、`memory_posix.cc` 的分配函数、`ui/surface.h` 的 surface 类型、CMake 源文件选择）感知平台，其余代码零改动。这保证补丁数量可控（目标 15–25 个）。

### 2.2 线程模型

| 线程 | 职责 | 来源 |
| --- | --- | --- |
| ArkUI 主线程 | UI 渲染、XComponent 回调、ArkTS 逻辑 | 系统 |
| 模拟器主线程 | `Emulator::Setup` → `Launch`，驱动 CPU 模拟 | 自建（`std::thread`） |
| GPU 线程 | 命令缓冲提交、呈现 | Xenia 内部 |
| 音频回调线程 | OHAudio 的 `OH_AudioRenderer_OnWriteData` | 系统 |
| 输入线程 | GameControllerKit 回调 | 系统 |

**关键约束**：XComponent 的 `onSurfaceCreated` / `onSurfaceChanged` / `onSurfaceDestroyed` 回调**在 ArkUI 主线程**。而 Vulkan 的 swapchain 创建/销毁必须在 Xenia 的 GPU 线程上。因此需要一个跨线程编组机制。

**方案**：复用 Xenia 已有的 `WindowedAppContext::CallInUIThread()` 抽象（上游 Android 版就是用它把 `AndroidWindow::UpdateSurface()` 编组到 UI 线程）。OHOS 实现类 `OhosWindowedAppContext` 用 `std::mutex` + `std::condition_variable` + 待执行队列实现，语义与上游一致：

```cpp
// entry/src/main/cpp/xendroid_ohos/window_ohos.h
class OhosWindowedAppContext final : public xe::ui::WindowedAppContext {
 public:
  void NotifyUILoopOfPendingFunctions() override;  // 同步：阻塞直到执行完
  void PlatformQuitFromUIThread() override;
  bool CallInUIThread(std::function<void()> fn) override;
  void MainLoop();                                  // 由 ArkUI 主线程驱动或独立循环
 private:
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> pending_;
  std::thread::id ui_thread_id_;
};
```

> 注意：`surface_detach` 必须**同步**编组（上游 `xendroid_emu.cpp:861-888` 的注释明确说明要等 GPU 排空 + `vkDestroySurfaceKHR`），否则会出现 use-after-free。

### 2.3 进程模型

单进程。上游 Android 版用独立 `:emu` 进程是为了 `Process.killProcess()` 硬退出，鸿蒙不需要：

- 退出路径：`Emulator::Shutdown()` → 释放 Vulkan/音频资源 → 通知 ArkTS 关闭页面。
- 崩溃恢复：由 ArkTS 侧捕获 NAPI 异常 + `errorManager`（如可用）记录。
- 兜底：`std::abort()`（上游 `logging.cc:547-555` 在 xendroid 平台就是这么做 `FatalError` 的）。

### 2.4 关键数据流

**启动流程**

```
ArkTS: 游戏库中点击已安装的游戏 → 取 install.json 的沙箱内绝对路径
       → napi.emulator.setupGamePath("<filesDir>/games/<installId>/game.iso")
                                      ↓
C++:  ae::boot_type = BOOT_TYPE_WITH_PATH; ae::boot_game_path = path
ArkTS: 切到游戏页（XComponent 创建）
                                      ↓
C++:  XComponent onSurfaceCreated → OHNativeWindow* → 保存
                                      ↓
ArkTS: napi.emulator.boot()
C++:  std::thread(ae::main_thr) → Emulator::Setup → Launch
                                      ↓
C++:  VulkanInstance 创建 → vkCreateSurfaceOHOS → swapchain → 首帧
```

> 由于游戏已安装到沙箱，`setupGamePath` 收到的是**真实 POSIX 路径**，不需要上游 `Emulator.java:108` 的 fd 变体（`BOOT_TYPE_WITH_FD`）——这条路径在鸿蒙版可以不启用，进一步简化。

**安装流程**

```
ArkTS: @ohos.file.picker 选文件 → 预检（格式/元数据/空间）
       → 流式拷贝到 <filesDir>/games/.tmp-<id>/（带进度上报）
       → 校验 + rename → 写 install.json → 刷新游戏库
C++:   仅在安装完成后被调用（读元数据取 titleId / 图标），不参与拷贝
```

**渲染流程**（与上游一致，无平台差异）

```
Guest 提交 PM4 → VulkanCommandProcessor::IssueSwap
                → presenter->RefreshGuestOutput()
                → vkAcquireNextImageKHR → blit → vkQueuePresentKHR
```

**输入流程**

```
物理手柄 → GameControllerKit 回调 → InputDriver::OnKey(idx, pressed, value)
触摸     → ArkTS 虚拟手柄 Canvas → napi.emulator.keyEvent(...)
按键     → ArkUI onKeyEvent → napi.emulator.keyEvent(...)
                                      ↓
C++:  ae::key_event → xe::hid::android::InputDriver（改名后复用）
```

**音频流程**

```
Guest XMA/WMA 解码（FFmpeg）→ AudioSystem 环形缓冲
                             → OHAudio 回调拉取 → OH_AudioRenderer
```

---

## 3. 仓库与构建

### 3.1 仓库结构

```
HX360E/                                       # 鸿蒙应用仓库
├── AppScope/
├── entry/
│   ├── build-profile.json5                   # abiFilters / cppFlags / nativeCompiler
│   └── src/main/
│       ├── cpp/
│       │   ├── CMakeLists.txt                # 顶层：CMAKE_CXX_STANDARD 20 + 两个子目录
│       │   ├── napi/                         # NAPI 桥接层
│       │   │   ├── napi_init.cpp             #   模块注册
│       │   │   ├── napi_emulator.cpp         #   生命周期与输入
│       │   │   ├── napi_config.cpp           #   配置句柄
│       │   │   ├── napi_content.cpp          #   内容管理
│       │   │   ├── napi_prompt.cpp           #   键盘/对话框/换盘轮询
│       │   │   └── types/libhx360e/
│       │   │       ├── Index.d.ts            #   TS 声明（对外契约）
│       │   │       └── oh-package.json5
│       │   ├── xendroid/                     # git submodule → 上游 fork（含补丁）
│       │   └── xendroid_ohos/                # OHOS 平台层（新增文件）
│       │       ├── surface_ohos.h/.cc
│       │       ├── window_ohos.h/.cc
│       │       ├── xcomponent_bridge.h/.cc
│       │       ├── jit_memory_ohos.h/.cc
│       │       ├── ohaudio_audio_driver.h/.cc
│       │       ├── ohaudio_audio_system.h/.cc
│       │       ├── gamepad_ohos.h/.cc
│       │       ├── hilog_sink.h/.cc
│       │       └── driver_profile.h/.cc
│       ├── ets/                              # ArkTS 前端
│       └── resources/
├── patches/harmony/                          # 对上游的补丁序列
└── docs/
```

**为什么平台层放在 `xendroid/` 之外**：`xendroid/` 是上游 fork，保持"只加补丁、不做结构性重排"，便于 rebase。OHOS 平台层作为**新增目录**存在于我们的仓库里，不进入上游树。

### 3.2 上游同步策略

详见可行性报告 §9。核心约定：

- `xendroid/` 是指向上游 fork 的 **git submodule**，锁定 commit。
- 所有对上游的修改以**补丁**形式存在 `patches/harmony/`，或直接体现在 fork 的 `harmony` 分支上。
- 补丁原则：新增文件优先、条件编译优先、单一职责、总数控制在 15–25 个。

**预期的补丁清单**（初版，实际以实现为准）：

| # | 补丁 | 涉及文件 |
| --- | --- | --- |
| 0001 | 平台宏新增 `__OHOS__` 分支 | `base/platform.h` |
| 0002 | CMake 新增 OHOS 平台分支与源文件 glob | `CMakeLists.txt`、`cmake/XeniaHelpers.cmake` |
| 0003 | 可执行内存多策略分配 | `base/memory_posix.cc`、`cpu/backend/code_cache_base.h` |
| 0004 | `__clear_cache` → `__builtin___clear_cache` | `xe_a64_code_cache_posix.cpp` |
| 0005 | C++20 兼容（6 处） | `base/string_key.h` 等 |
| 0006 | Vulkan surface 类型扩展 | `ui/surface.h`、`ui/vulkan/vulkan_presenter.cc`、`ui/vulkan/vulkan_instance.cc` |
| 0007 | 移除 adrenotools 依赖 | `ui/vulkan/vulkan_instance.cc`、CMake |
| 0008 | 移除 AAudio/OpenSLES 构建项 | CMake |
| 0009 | `/proc` 路径假设修正 | `cpu/backend/a64/a64_code_cache.cc` |
| 0010 | 日志 sink 抽象 | `base/logging.cc` |

### 3.3 CMake 目标结构

```cmake
# entry/src/main/cpp/CMakeLists.txt
cmake_minimum_required(VERSION 3.20)
project(hx360e LANGUAGES C CXX ASM)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# OHOS 平台定义：让 xenia 的 platform.h 走 __OHOS__ 分支
add_compile_definitions(OHOS=1 __OHOS__=1)

# 静态链接 libc++，避免打包 libc++_shared.so（单 .so 场景）
add_link_options(-static-libstdc++)

add_subdirectory(xendroid)          # 产出 xenia-* 静态库

add_library(hx360e SHARED
    napi/napi_init.cpp
    napi/napi_emulator.cpp
    napi/napi_config.cpp
    napi/napi_content.cpp
    napi/napi_prompt.cpp
    xendroid_ohos/surface_ohos.cc
    xendroid_ohos/window_ohos.cc
    xendroid_ohos/xcomponent_bridge.cc
    xendroid_ohos/jit_memory_ohos.cc
    xendroid_ohos/ohaudio_audio_driver.cc
    xendroid_ohos/ohaudio_audio_system.cc
    xendroid_ohos/gamepad_ohos.cc
    xendroid_ohos/hilog_sink.cc
    xendroid_ohos/driver_profile.cc
)

target_link_libraries(hx360e PRIVATE
    xenia-apu xenia-apu-nop xenia-base xenia-core xenia-cpu
    xenia-cpu-backend-a64 xenia-gpu xenia-gpu-vulkan xenia-hid
    xenia-hid-nop xenia-kernel xenia-ui xenia-ui-vulkan xenia-vfs
    fmt capstone xbyak_aarch64 vulkan
    libace_napi.z.so libace_ndk.z.so libnative_window.so
    libohaudio.so libhilog_ndk.z.so libohgame_controller.z.so
    libnative_vsync.so dl z
)

# 只导出 NAPI 入口
target_link_options(hx360e PRIVATE -Wl,--exclude-libs,ALL)
```

**注意**：`xenia` 的 CMake 子目录里，需要把 Android 专属的 `xe_aaudio_*` / `xe_opensles_*` / `libadrenotools` 从源文件列表排除（补丁 0007/0008）。

### 3.4 编译选项与工具链

| 项 | 值 | 说明 |
| --- | --- | --- |
| `nativeCompiler` | `"BiSheng"`（现状）或 `"Original"` | 二者产物 ABI 等价，见可行性报告 §8.3 |
| `cppFlags` | `--std=c++20` | 现状是 `--std=c++14`，必须改 |
| `abiFilters` | `["arm64-v8a"]` | 移除 `x86_64` |
| C++ 运行时 | `-static-libstdc++` | 单 .so 场景，省去打包 `libc++_shared.so` |
| `-march` | `armv8-a` | 与上游一致（保守，运行时派发 LSE） |
| 着色器工具链 | 构建期需 `glslangValidator` / `spirv-opt` / `spirv-dis` + `python3` | 由 `gen_android_spirv.py` 预生成 SPIR-V（OHOS 交叉编译同样跑不了 edge 的 shader 管线） |

---

## 4. 平台抽象层

### 4.1 平台宏（补丁 0001）

```c
// xendroid/src/xenia/base/platform.h
#elif defined(__ANDROID__)
#define XE_PLATFORM_xendroid 1
#define XE_PLATFORM_LINUX 1
#elif defined(__OHOS__)                    // ← 新增
#define XE_PLATFORM_OHOS 1
#define XE_PLATFORM_xendroid 1             // 复用 xendroid 的代码路径
#define XE_PLATFORM_LINUX 1                // 复用 POSIX 路径
#elif defined(__gnu_linux__)
...
```

**为什么同时定义 `XE_PLATFORM_xendroid`**：全树有 113 处 `XE_PLATFORM_xendroid` 判断，其中大部分是分支自有的逻辑（如 audio_system 的 ADPF 提示、FFmpeg XMA 解码）。复用它们能最大限度减少补丁。需要单独区分的少数场景再新增 `XE_PLATFORM_OHOS` 判断（预计 5–10 处）。

### 4.2 平台层文件职责

| 文件 | 职责 | 对应上游文件 |
| --- | --- | --- |
| `surface_ohos.h/.cc` | 持有 `OHNativeWindow*`，实现 `GetSizeImpl` | `ui/surface_android.*` |
| `window_ohos.h/.cc` | `OhosWindow` + `OhosWindowedAppContext` | `xendroid_emu.cpp` 的 `AndroidWindow` |
| `xcomponent_bridge.h/.cc` | 注册 XComponent 回调，把 surface 事件转成窗口事件 | 无（新增） |
| `jit_memory_ohos.h/.cc` | 四策略可执行内存分配器 | `base/memory_posix.cc` 的 `CreateFileMappingHandle` |
| `ohaudio_audio_driver.h/.cc` | OHAudio 渲染驱动 | `xe_aaudio_audio_driver.*` |
| `ohaudio_audio_system.h/.cc` | 音频系统工厂 | `xe_aaudio_audio_system.*` |
| `gamepad_ohos.h/.cc` | GameControllerKit 手柄接入 | `xe_android_input_driver.*` 的事件源 |
| `hilog_sink.h/.cc` | hilog 日志输出 | `base/logging.cc` 的 `AndroidLogSink`（上游死代码） |
| `driver_profile.h/.cc` | 按 GPU 型号预设 cvar | 无（新增） |

---

## 5. 图形子系统

### 5.1 表面获取：XComponent → OHNativeWindow

**设计决策：surface 不经过 NAPI。** Android 版把 `Surface` 对象从 Java 传到 JNI（`ANativeWindow_fromSurface`），鸿蒙可以做得更干净——XComponent 的回调直接给出 `OHNativeWindow*`，全部在 C++ 侧处理。

ArkTS 侧只需声明：

```typescript
// entry/src/main/ets/pages/GameView.ets
XComponent({
  id: 'hx360e_surface',
  type: XComponentType.SURFACE,
  libraryname: 'hx360e'
})
  .onLoad(() => { /* C++ 侧已通过 napi 注册回调，这里无需传 surface */ })
  .width('100%').height('100%')
```

C++ 侧在模块初始化时拿到 `OH_NativeXComponent` 并注册回调：

```cpp
// entry/src/main/cpp/xendroid_ohos/xcomponent_bridge.cc
static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
  // window 即 OHNativeWindow*
  g_bridge->OnSurfaceCreated(static_cast<OHNativeWindow*>(window));
}
static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
  uint64_t w = 0, h = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
  g_bridge->OnSurfaceResized(uint32_t(w), uint32_t(h));
}
static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
  g_bridge->OnSurfaceDestroyed();   // 必须同步等 GPU 排空
}

void XComponentBridge::Init(napi_env env, napi_value exports) {
  napi_value export_instance;
  napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &export_instance);
  napi_unwrap(env, export_instance, reinterpret_cast<void**>(&native_xcomponent_));
  // 注册 OH_NativeXComponent_Callback{ OnSurfaceCreated, OnSurfaceChanged, OnSurfaceDestroyed, DispatchTouchEvent }
}
```

**生命周期契约**：

| 事件 | C++ 侧动作 | 同步性 |
| --- | --- | --- |
| `onSurfaceCreated` | 保存 `OHNativeWindow*`；若已 boot 则编组到 UI 线程创建 surface | 异步 |
| `onSurfaceChanged` | 缓存宽高；swapchain 重建时重新查询 | 异步 |
| `onSurfaceDestroyed` | **同步**编组：等 GPU 排空 → `vkDestroySurfaceKHR` → 释放窗口引用 | **同步（阻塞）** |

> 上游 `xendroid_emu.cpp:861-888` 的 `ae::surface_detach` 就是同步的，注释明确说"blocks until GPU drain + vkDestroySurfaceKHR"。移植时必须保持这个语义，否则会 use-after-free。

### 5.2 Vulkan surface 创建（补丁 0006）

三处改动：

**① `ui/surface.h`** — 新增 surface 类型：

```cpp
enum TypeIndex {
  kTypeIndex_AndroidNativeWindow,
  kTypeIndex_OHOSNativeWindow,        // ← 新增
  kTypeIndex_Win32Hwnd,
  ...
};
```

**② `ui/vulkan/vulkan_instance.cc`** — 请求扩展：

```cpp
#if defined(VK_USE_PLATFORM_OHOS)
  enabled_extensions.push_back(VK_OHOS_SURFACE_EXTENSION_NAME);
#elif XE_PLATFORM_ANDROID || XE_PLATFORM_xendroid
  enabled_extensions.push_back(VK_KHR_ANDROID_SURFACE_EXTENSION_NAME);
#endif
```

以及 `:281-310` 的函数指针加载（现有代码是 `dlsym` / `&::name` / `LoadLibraryW` / `#else #error`），OHOS 走 `dlsym` 分支即可。

**③ `ui/vulkan/vulkan_presenter.cc:597`** — 新增 case：

```cpp
case Surface::kTypeIndex_OHOSNativeWindow: {
  const auto& ohos_surface = static_cast<const ui::OHOSNativeWindowSurface&>(surface);
  VkSurfaceCreateInfoOHOS create_info = {};
  create_info.sType = VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS;
  create_info.window = ohos_surface.window();
  if (ifn.vkCreateSurfaceOHOS(instance, &create_info, nullptr,
                              &paint_context_.vulkan_surface) != VK_SUCCESS) {
    XELOGE("vkCreateSurfaceOHOS failed");
    return false;
  }
  break;
}
```

CMake 需要 `-DVK_USE_PLATFORM_OHOS`，并链接 `libvulkan.so` / `libnative_window.so` / `libace_ndk.z.so`。

### 5.3 呈现器改动

`vulkan_presenter.cc` 的 swapchain 逻辑**不需要改**：它已经从 `VkSurfaceCapabilitiesKHR` 查询 `currentExtent` / `preTransform` / `compositeAlpha`，并做了 `IMMEDIATE → MAILBOX → FIFO_RELAXED → FIFO` 的降级（`:1298-1320`）。鸿蒙的 loader 会返回正确的 capabilities。

**需要验证的点**：`preTransform` 的处理（`:1265-1269` 是 `IDENTITY` 或 `INHERIT`，**没有显式 pre-rotation**）。竖屏设备上可能需要额外处理，Phase 2 验证。

### 5.4 能力探测与降级

XenDroid 的 Vulkan 后端已经是**能力探测式**的，不需要为鸿蒙特殊处理。启动时记录一份能力报告到日志（`simple_device_info()` 的移植版），用于兼容性排查。

**关键能力清单**（可行性报告 §2.2）：Vulkan 1.1+ 必需；`scalarBlockLayout`、`uniformBufferStandardLayout`、`shaderFloat16`、`shaderInt16`、`geometryShader`、`tessellationShader` 等按需；`sparseBinding` 缺失可降级。

### 5.5 设备/驱动 profile（新增）

由于 GPU 调优在 Adreno 上测得，鸿蒙需要按 GPU 型号预设 cvar。设计一个轻量 profile 表：

```cpp
// entry/src/main/cpp/xendroid_ohos/driver_profile.cc
struct DriverProfile {
  const char* gpu_name_pattern;      // 匹配 VkPhysicalDeviceProperties::deviceName
  const char* config_toml;           // 追加到配置的 cvar 段
};

static const DriverProfile kProfiles[] = {
  // {"Maleoon 920", "[Vulkan]\nvulkan_mid_frame_submission_draws = 0\n..."},
  // {"Maleoon 910", "..."},
};
```

启动时按 `deviceName` 匹配并写入默认配置；用户可在设置里覆盖。**Phase 2 实测后再填充具体值**，初版留空表。

---

## 6. JIT 与可执行内存

> **权限前提**：HarmonyOS 默认关闭 JIT。工程已在 `entry/src/main/module.json5` 声明 ACL 受限权限 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`，需在 AGC 申请并配置到签名 Profile。详见 [JIT-PERMISSION.md](./JIT-PERMISSION.md)。
>
> **但不要假设它是唯一路径**：社区 PPSSPP 鸿蒙移植未声明任何 JIT 权限，其 ARM64 JIT 仍正常工作。四策略探测的结果才是准绳。

### 6.1 多策略分配器设计

**目标**：在鸿蒙上找到至少一种能用的可执行内存分配方式。设计成"按保守度排序的探测 + 选中即固定"。

```cpp
// entry/src/main/cpp/xendroid_ohos/jit_memory_ohos.h
enum class JitMemStrategy {
  kFileMappingRxRw,      // ① memfd + 两次 mmap（RX 视图 + RW 视图）——最保守
  kFileMappingExecutable,// ② memfd + mmap(MAP_EXECUTABLE)
  kAnonRwx,              // ③ 匿名 MAP_ANON|MAP_PRIVATE + PROT_READ|WRITE|EXEC
  kAnonRwMprotect,       // ④ 匿名 RW + mprotect 切换
  kNone,                 // 全部失败
};

// 启动时探测一次，结果缓存
JitMemStrategy ProbeJitMemoryStrategy();

// 按策略创建代码缓存映射
bool CreateCodeCacheMapping(const char* name, size_t size,
                            JitMemStrategy strategy,
                            void** exec_out, void** write_out);
```

**探测方法**：分配一页，写入一段 AArch64 机器码，通过函数指针调用，验证返回值：

```cpp
// mov w0, #42 ; ret   →  0x52800540 0xD65F03C0
static const uint32_t kProbeCode[] = { 0x52800540u, 0xD65F03C0u };
using ProbeFn = int (*)();
```

四种策略的探测顺序与理由：

| 顺序 | 策略 | 理由 |
| --- | --- | --- |
| ① | 文件映射双视图 | 无任一映射同时具备 W+X，最符合 XPM 的 W^X 策略；XenDroid 已内置 |
| ② | 文件映射 + `MAP_EXECUTABLE` | mozjs 在 HarmonyOS NEXT Beta 2 上验证过的方式 |
| ③ | 匿名 RWX | PPSSPP 鸿蒙版的做法（其实现在 `Common/MemoryUtil.cpp`） |
| ④ | 匿名 RW + mprotect | 兜底，V8 在无 PKU/MAP_JIT 时的做法 |

**结果落日志**，并在设备信息里展示，便于用户反馈。

### 6.2 代码缓存适配（补丁 0003）

`xenia/base/memory_posix.cc:368-375` 的 `CreateFileMappingHandle` 当前用 Android 的 `ASharedMemory_create`：

```cpp
#if XE_PLATFORM_OHOS
  int fd = memfd_create(path.c_str(), MFD_CLOEXEC);
  if (fd < 0) return kFileMappingHandleInvalid;
  if (ftruncate(fd, off_t(length)) != 0) { close(fd); return kFileMappingHandleInvalid; }
  return fd;
#elif XE_PLATFORM_xendroid
  int sharedmem_fd = ASharedMemory_create(path.c_str(), length);
  ...
```

同时 `IsWritableExecutableMemorySupported()`（`:121-148`）在 OHOS 上**不要无条件返回 true**，改为返回探测结果——否则会走匿名 RWX 快路径。

`cpu/backend/code_cache_base.h:174-319` 的双视图逻辑本身不需要改，它已经支持 `wx_preferred == false` 的路径。

### 6.3 代码缓存的其他适配

| 项 | 改动 |
| --- | --- |
| `__clear_cache` | `xe_a64_code_cache_posix.cpp:15,948` 的 bionic 符号 → `__builtin___clear_cache()` |
| `/proc/self/cmdline` 路径假设 | `a64_code_cache.cc:73-82` 硬编码 `/data/data/<pkg>/`，改为鸿蒙路径或直接跳过 simpleperf map |
| DWARF `.eh_frame` | `__register_frame` / `_Unwind_Backtrace`（`xe_a64_code_cache_posix.cpp`）需验证 OHOS libunwind 可用；不可用则退回上游的 per-function 方案 |

---

## 7. 音频子系统

### 7.1 OHAudio 驱动设计

照搬 `xe_aaudio_audio_driver.cpp`（563 行）的结构，替换 API 层：

| AAudio | OHAudio |
| --- | --- |
| `AAudioStreamBuilder_create` | `OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER)` |
| `AAudioStreamBuilder_setPerformanceMode(LOW_LATENCY)` | `OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST)` |
| `AAudioStreamBuilder_setDataCallback` | `OH_AudioStreamBuilder_SetRendererWriteDataCallback`（回调类型 `OH_AudioRenderer_OnWriteDataCallback`） |
| `AAudioStreamBuilder_setFormat(FLOAT)` | `OH_AudioStreamBuilder_SetSampleFormat(AUDIOSTREAM_SAMPLE_FLOAT32)` |
| `AAudioStream_getTimestamp` | `OH_AudioRenderer_GetAudioTimestampInfo` |
| `AAudioStream_getXRunCount` | `OH_AudioRenderer_GetUnderflowCount` |

> OHAudio 与 AAudio 一样是**回调拉取式**（`OnWriteDataCallback` 由系统线程调用，应用往里填数据），不存在主动 `write` 接口。上游 AAudio 驱动也是回调式，结构可直接照搬。

**保留上游的三个设计**：

1. **软件音量**（避免依赖系统音量 API 的差异）。
2. **欠载恢复线程**（检测 xrun 后重建流）。
3. **格式协商**：优先 FLOAT32，失败则降级 S16。

### 7.2 时序与缓冲

Guest 的音频时钟与宿主需要同步。上游 AAudio 版用 `GetTimestamp` 做时钟对齐，OHAudio 的 `OH_AudioRenderer_GetAudioTimestampInfo` 语义等价，直接映射。

**Phase 1 先用 `xenia-apu-nop`**（已有，可移植），确保画面先跑通；音频在 Phase 3 接入。

---

## 8. 输入子系统

### 8.1 手柄（GameControllerKit）

`libohgame_controller.z.so` 提供逐按键/逐轴的注册式回调：

```cpp
// entry/src/main/cpp/xendroid_ohos/gamepad_ohos.cc
OH_GamePad_LeftShoulder_RegisterButtonInputMonitor(OnButton);   // 每个按键单独注册
OH_GamePad_LeftTrigger_RegisterAxisInputMonitor(OnAxis);
```

**注意**：这是**逐按键注册**的 API，与 Android 的 `onGenericMotionEvent` 一次性给全部轴不同。需要一个映射表把 `GamePad_*` 回调转成 XInput 语义，再喂给 `InputDriver::OnKey(idx, pressed, value)`。

`xe_android_input_driver.cpp`（299 行）**没有 Android API 依赖**，只有 24 项按键状态表 + XInput 语义映射，直接改名复用。

### 8.2 触摸与虚拟手柄

ArkTS 侧用 Canvas 绘制虚拟手柄（对应上游 `GamepadOverlay.kt` 的 643 行），通过 NAPI 把触摸事件转成按键/轴事件：

```typescript
// entry/src/main/ets/gamepad/GamepadEmitter.ets
emitter.emitDigital(code, pressed);   // → napi.emulator.keyEvent(code, pressed, 0)
emitter.emitAxis(code, value);        // → napi.emulator.keyEvent(code, true, value)
```

上游的编码约定（`GamepadEmitter.kt`）直接复用：数字键 0–15，模拟半轴 16–23。

### 8.3 按键映射

上游用 `KeymapStore`（SharedPreferences）存映射。鸿蒙改用 `@ohos.data.preferences`，映射表结构不变。物理键盘走 ArkUI 的 `onKeyEvent`。

---

## 9. NAPI 桥接层

### 9.1 接口设计

替代上游约 40 个 JNI 方法。设计原则：**C 接口、扁平、无 C++ ABI 跨界**（可行性报告 §8.4 的约束）。

```typescript
// entry/src/main/cpp/types/libhx360e/Index.d.ts

export const emulator: {
  // 生命周期
  setupGamePath(path: string): void;
  setupLaunchArgs(args: string[]): void;
  boot(): void;
  pause(): void;
  resume(): void;
  quit(): void;
  isRunning(): boolean;
  isPaused(): boolean;

  // 表面（仅用于通知尺寸变化；surface 本身由 XComponent 回调直接给 C++）
  changeSurface(width: number, height: number): void;

  // 输入
  keyEvent(key: number, pressed: boolean, value: number): void;

  // 状态
  deviceInfo(): string;          // GPU/驱动/Vulkan 能力报告（用于反馈）
  lastFrameTimeMs(): number;
  instantFps(): number;
  averageFps(): number;
  jitStrategy(): string;         // 实际选中的 JIT 内存策略
};

export const config: {
  open(path: string): bigint;
  close(handle: bigint): string;
  loadEntry(handle: bigint, key: string): string;
  saveEntry(handle: bigint, key: string, value: string): void;
  saveToFile(handle: bigint, path: string): void;
  free(handle: bigint): void;
};

export const content: {
  installContent(gamePath: string, contentPath: string): number;
  listDiscContent(gamePath: string): DiscContentItem[];
  contentHeader(path: string): ContentInfo | null;
  listProfiles(storageRoot: string): ProfileInfo[];
  createProfile(storageRoot: string, gamertag: string, lang: number, country: number): string;
};

export const meta: {
  titleIdFromPath(path: string, mediaType: number): string;
  metaFromPath(path: string, mediaType: number): GameInfo | null;
};

export const prompt: {
  keyboardRequest(): KeyboardRequest | null;
  keyboardSubmit(id: bigint, cancelled: boolean, text: string): void;
  msgboxRequest(): MessageBoxRequest | null;
  msgboxSubmit(id: bigint, button: number): void;
  discRequest(): DiscSwapRequest | null;
  discSubmit(id: bigint, accepted: boolean, path: string): void;
};
```

### 9.2 类型映射

| JNI | NAPI | 备注 |
| --- | --- | --- |
| `String` | `napi_string` | 用 `napi_create_string_utf16` / `napi_get_value_string_utf16`，与上游一致（guest 提示用 UTF-16） |
| `long`（配置句柄） | `bigint` | NAPI 无 int64，用 `napi_create_bigint_uint64` |
| `byte[]`（图标） | `ArrayBuffer` | |
| DTO 对象（`GameInfo` 等） | `napi_object` + 属性 | 用 `napi_create_object` 逐字段设置，替代 `NewObject` + `SetField` |

### 9.3 线程与生命周期

- **NAPI 调用都在 ArkUI 主线程**，与 XComponent 回调同线程 → `OhosWindowedAppContext` 的 UI 线程就是这个线程。
- 模拟器主线程由 `boot()` 内 `std::thread` 创建（上游 `emulator.cpp:444-446` 的做法）。
- **NAPI 环境不能跨线程使用**，`napi_create_*` 只能在主线程调用。因此 guest 提示（键盘/对话框/换盘）沿用上游的**轮询**模式（150ms 一次），而不是回调——这正好规避了跨线程 NAPI 的问题。
- 模块卸载时用 `napi_add_env_cleanup_hook` 注册清理回调，确保模拟器已停止、资源已释放。

### 9.4 配置句柄

上游用 `Emulator$Config` 的 Java 对象持有 TOML 句柄（`long`）。NAPI 侧用 `bigint` 直接传 C++ 指针，更简单：

```cpp
// 打开配置 → 返回 TOML 表指针
napi_value OpenConfig(napi_env env, napi_callback_info info) {
  auto* table = new toml::table(toml::parse_file(path));
  napi_value result;
  napi_create_bigint_uint64(env, reinterpret_cast<uint64_t>(table), &result);
  return result;
}
```

**风险**：裸指针跨 NAPI 边界，需在 ArkTS 侧严格配对 `open` / `free`。设计上把 `ConfigHandle` 封装成 ArkTS 类，用 `try/finally` 保证释放。

---

## 10. 存储与文件访问

### 10.1 设计前提：沙箱化

HarmonyOS 应用只能自由访问自己的沙箱（`context.filesDir`），对外部文件只能通过 picker 获得**临时或持久化的 URI 授权**。这与 Android 的 `MANAGE_EXTERNAL_STORAGE`（全盘读写）有本质区别。

**本项目的设计选择：把游戏文件"安装"到沙箱。**

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| **A. 安装（采用）** | picker 选文件 → 拷贝到沙箱 → 之后只用沙箱内路径 | ✅ 采用 |
| B. 持久化授权 | `@ohos.fileshare.persistPermission` 保留 URI 授权，直接读原位置 | 备选/未来优化 |
| C. 全盘扫描 | —— | ❌ 鸿蒙无对应权限 |

**为什么选 A**：

1. **健壮性**：不受授权撤销、用户移动/删除源文件、外置存储卸载的影响。
2. **路径简单**：沙箱内是真实 POSIX 路径，native 侧零特殊处理（不需要 fd 变体、不需要 URI 转换层）。
3. **存档统一**：游戏、配置、存档全在沙箱内，备份/迁移逻辑统一。
4. **代价可接受**：空间翻倍 + 首次安装耗时。对 7–16 GB 的 Xbox 360 游戏，安装时间在分钟级。

**备选方案 B 的可行性已核实**：`@ohos.fileshare` 提供 `persistPermission` / `checkPersistentPermission` / `revokePermission`（API 11+，需 `ohos.permission.FILE_ACCESS_PERSIST`），并支持 `PERSISTENT_TYPE`（API 15+）。**未来可作为"引用模式"提供给空间紧张的用户**，但 MVP 不做——它会让路径模型分叉（沙箱内 / 沙箱外两套），增加复杂度。

### 10.2 沙箱目录布局

```
<context.filesDir>                    # 沙箱根
├── games/                            # 已安装的游戏
│   ├── <installId>/                  # 一个安装单元（通常 = 一张光盘）
│   │   ├── game.iso                  # 游戏文件（保持原扩展名）
│   │   ├── install.json              # 安装元数据
│   │   └── icon.png                  # 图标（可选，从游戏元数据提取）
│   └── .tmp-<installId>/             # 安装中（未完成）
├── storage/                          # 模拟器 storage_root
│   ├── config/                       # 全局配置 + 每游戏配置
│   │   └── <TITLEID>.config.toml
│   ├── content/                      # 存档 / DLC / 安装内容
│   │   └── <XUID 016X>/<TITLEID 08X>/<ContentType 08X>/...
│   ├── cache/                        # 缓存（可清理）
│   └── patches/                      # 游戏补丁 *.patch.toml
└── logs/                             # 运行日志（供反馈）
```

**启动参数**（对应上游 `EmulatorHostActivity.kt:233-245`）：

```
--storage_root=<filesDir>/storage
--config=<filesDir>/storage/config/xenia-canary.config.toml
--log_file=<filesDir>/logs/xe.log
--log_append=true
```

**存档天然隔离**：Xenia 的存档路径是 `content/<XUID>/<TITLEID>/<ContentType>/`，按玩家档案 + 标题 ID 隔离，无需额外设计。

### 10.3 安装流程

```
① 用户点"安装游戏"
   → @ohos.file.picker（DocumentSelectOptions，可多选）
   → 得到源 URI 列表

② 预检（每个文件）
   · 读头 4KB 识别格式（ISO / ZAR / GOD / XEX 目录）
   · 从源文件读元数据（titleId、显示名、图标）——用于展示与去重
   · fs.statSync(uri).size 取大小
   · storageStatistics.getFreeSizeSync() 查剩余空间
   · 空间不足 → 提示（可选：引导压缩或卸载其他游戏）

③ 拷贝（带进度）
   · 目标：<filesDir>/games/.tmp-<installId>/game.<ext>
   · fs.createReadStream / createWriteStream 分块拷贝
   · 每块回调进度 → 通过 NAPI 上报给 ArkTS 进度条
   · 失败/取消 → 删除 .tmp 目录

④ 校验与落定
   · 大小比对（必须一致）
   · 读目标文件头 4KB 比对格式
   · fs.renameSync(.tmp-<installId> → <installId>)   # 原子提交
   · 写入 install.json

⑤ 入库
   · 追加到游戏库索引（preferences 或沙箱内 JSON）
   · 刷新游戏库列表
```

**原子性**：拷贝到 `.tmp-<installId>/`，成功后整体 rename。启动时扫描并清理残留的 `.tmp-*` 目录。

**installId 生成**：优先用 `titleId`（同一游戏重复安装会覆盖/提示），无 titleId 时用 `sha1(文件名+大小+mtime)`。

### 10.4 安装元数据

```jsonc
// <filesDir>/games/<installId>/install.json
{
  "schemaVersion": 1,
  "installId": "4D5307F1",
  "titleId": "4D5307F1",
  "displayName": "Fable II",
  "mediaId": "0A1B2C3D",
  "discNumber": 1,
  "discCount": 1,
  "fileName": "game.iso",
  "fileSize": 7838315312,
  "format": "iso",              // iso | zar | god | xex-folder
  "sourceHint": "Fable2.iso",   // 原始文件名（仅用于展示）
  "installedAt": 1757300000000,
  "lastPlayedAt": 1757400000000,
  "sha1Head": "..."             // 头 4KB 的哈希，用于快速校验
}
```

游戏库索引可**直接扫描 `games/*/install.json`** 重建，不需要独立数据库——避免索引与实际文件不一致。

### 10.5 去重与多光盘

| 场景 | 处理 |
| --- | --- |
| 同一游戏重复安装 | 检测到 `titleId` 已存在 → 提示"已安装，是否覆盖？" |
| 多光盘游戏 | 各光盘独立安装（`discNumber` 区分），但**共享同一 titleId 的配置与存档**。换盘时从已安装列表按 `discNumber` 匹配 |
| ZAR 与 ISO 同时存在 | 视为不同安装单元，各自独立 |

**多光盘的安装体验**：picker 支持多选，一次安装多张盘；按 titleId 分组展示为一条游戏记录，展开可见各光盘。

### 10.6 卸载与空间管理

| 功能 | 实现 |
| --- | --- |
| 卸载游戏 | 删除 `games/<installId>/`；询问是否保留存档（存档在 `storage/content/`，独立于游戏文件） |
| 空间占用统计 | 扫描 `games/` + `storage/` 汇总，按游戏/存档/缓存分类展示 |
| 清理缓存 | 删除 `storage/cache/` |
| 剩余空间预警 | 安装前检查；设置页显示 `getFreeSizeSync()` |

**注意**：鸿蒙应用沙箱在 `filesDir` 下**没有硬配额**（受设备剩余空间限制），但应在设置页展示用量。此项需在 Phase 0.5 实测确认设备行为。

### 10.7 存档的导出与导入

**沙箱化的副作用**：用户无法通过文件管理器直接看到存档。因此**必须**提供导出/导入，否则用户换机或重装会丢档。

| 功能 | 实现 |
| --- | --- |
| 导出存档 | 把 `storage/content/<XUID>/<TITLEID>/` 打包 → `@ohos.file.picker` 的 `DocumentSaveOptions` 保存到公共目录 |
| 导入存档 | picker 选 zip → 解包到 `storage/content/` |
| 全量备份 | 打包 `storage/` 下的 config + content + patches |

对应上游 `DocumentsProvider.java`（519 行，暴露应用数据目录给系统文件管理器）的功能——**鸿蒙无等价机制，改为应用内的导出/导入界面**。

### 10.8 与 Android 版的差异小结

| 能力 | Android | HX360E |
| --- | --- | --- |
| 游戏文件位置 | 任意路径（SD 卡） | 沙箱 `filesDir/games/` |
| 添加游戏 | 扫描目录 / 选文件 | **安装（拷贝）** |
| 首次可用时间 | 立即 | 安装完成后 |
| 空间占用 | 1× | 2×（源文件 + 沙箱副本） |
| 存档可见性 | 可通过 DocumentsProvider 看到 | 需应用内导出 |
| ZAR 压缩的价值 | 节省 SD 卡空间 | **更重要**（沙箱空间紧张），建议在安装后提示可压缩 |

> 由于沙箱空间更紧张，上游的 `compressIsoToZar`（`GameCompressViewModel.kt`，143 行）在鸿蒙版中的价值**高于** Android 版——建议纳入 P1 优先级，并在空间不足时主动引导。

---

## 11. 前端（ArkTS）

### 11.1 页面结构

| 页面 | 对应上游 | 优先级 |
| --- | --- | --- |
| `GameLibraryPage` | `GameLibraryScreen.kt`（606 行） | P0 |
| `GameInstallPage` | 无对应（新增，见 §10.3） | **P0** |
| `GameViewPage` | `EmulatorHostActivity.kt`（835 行） | P0 |
| `SettingsPage` | `SettingsScreen.kt` + `SettingsSchema.kt`（421 行） | P0 |
| `GamepadOverlay` | `GamepadOverlay.kt`（643 行） | P0 |
| `PauseMenuPanel` | `PauseMenuPanel.kt`（89 行） | P0 |
| `GuestPromptPanels` | 键盘/对话框/换盘（362 行） | P1 |
| `ProfilesPage` | `ProfilesScreen.kt`（368 行） | P1 |
| `KeymapPage` | `KeymapScreen.kt`（94 行） | P1 |
| `StoragePage` | 无对应（新增：空间统计 / 卸载 / 导出存档） | P1 |
| `CompressPage` | `GameCompressViewModel.kt`（143 行） | P1（沙箱下价值更高） |
| `ContentManagerPage` | `ContentManagerScreen.kt`（158 行） | P2 |
| `GamepadEditorPage` | `GamepadEditorScreen.kt`（328 行） | P2 |

**P0 是最小可用集**：能安装游戏、能进游戏、能操作、能退出、能改基本设置。

**`GameInstallPage` 的必要性**：鸿蒙没有"扫描目录"这一选项，安装是**唯一**的入游戏路径，因此它和游戏库一样属于 P0。页面要素：picker 选文件 → 预检结果（格式/大小/空间）→ 进度条 → 完成/失败。

### 11.2 状态管理

上游用手动 DI（`AppContainer.kt`）+ ViewModel + DataStore。鸿蒙侧：

| 上游 | 鸿蒙 |
| --- | --- |
| `AppContainer`（手动 DI） | `AppContainer` 单例（ArkTS 类） |
| `ViewModel` + `StateFlow` | `@Observed` / `@State` + `AppStorage` |
| DataStore Preferences | `@ohos.data.preferences` |
| `SharedPreferences` | `@ohos.data.preferences` |

### 11.3 与原生层的交互

```typescript
// entry/src/main/ets/core/EmulatorSession.ets
import hx360e from 'libhx360e.so';

export class EmulatorSession {
  private booted = false;

  attachSurface(): void { /* XComponent 由 C++ 侧直接接管，这里只记录状态 */ }

  boot(gamePath: string): void {
    hx360e.emulator.setupLaunchArgs(this.buildArgs());
    hx360e.emulator.setupGamePath(gamePath);
    hx360e.emulator.boot();
    this.booted = true;
  }

  keyEvent(key: number, pressed: boolean, value: number): void {
    if (this.booted) hx360e.emulator.keyEvent(key, pressed, value);
  }
}
```

**轮询 guest 提示**（150ms）：

```typescript
setInterval(() => {
  const req = hx360e.prompt.keyboardRequest();
  if (req) this.showKeyboardPanel(req);
}, 150);
```

---

## 12. 里程碑与验收标准

### Phase 0：技术验证（2–4 周）

| # | 验证项 | 通过标准 |
| --- | --- | --- |
| 0.1 | JIT 可执行内存 | 四策略中至少一种探测通过（写入 `mov w0,#42; ret` 并调用返回 42） |
| 0.2 | Vulkan 呈现 | XComponent → `vkCreateSurfaceOHOS` → swapchain → 清屏纯色正确显示 |
| 0.3 | OHAudio | `AUDIOSTREAM_LATENCY_MODE_FAST` 播放正弦波无欠载 |
| 0.4 | Vulkan 能力 + 已知游戏矩阵 | 能力清单完整记录；`GAME_COMPAT.md` 中的标题有初步表现记录 |
| 0.5 | 安装与沙箱存储 | picker 选文件 → 流式拷贝到 `filesDir/games/`（含进度）→ 校验 → native 侧用 POSIX 路径成功打开并读取；同时确认 `filesDir` 无硬配额 |

**决策门**：0.1 全失败则项目重评。

### Phase 1：内核编译通过（1–1.5 人月）

- 平台宏、CMake 分支、子模块裁剪就绪。
- 剥离 adrenotools / AAudio / OpenSLES / JNI，用 nop 音频 + nop 输入占位。
- **验收**：`libhx360e.so` 编译链接成功，能 `dlopen`，能加载 XEX 并启动内核（无画面）。

### Phase 2：图形打通（1.5–2 人月）

- `surface_ohos` / `window_ohos` / `xcomponent_bridge` 实现。
- `vulkan_presenter` 新增 OHOS surface 分支。
- **验收**：游戏画面出现并可持续呈现；记录首帧时间与帧率。

### Phase 3：音频 + 输入（1 人月）

- OHAudio 驱动；GameControllerKit 手柄；ArkTS 触摸/按键转发。
- **验收**：有声音、可操作、无爆音。

### Phase 4：ArkTS 前端（3–5 人月）

- P0 页面完成。
- **验收**：完整走通"选游戏 → 进游戏 → 操作 → 退出 → 回列表"。

### Phase 5：优化与打磨（2–4 人月）

- 性能调优、驱动兼容性处理、崩溃恢复、上架合规。

---

## 13. 风险与未决问题

| # | 问题 | 状态 | 处理 |
| --- | --- | --- | --- |
| Q1 | JIT 可执行内存哪种策略可用？ | **未决，Phase 0 验证** | 四策略探测 |
| Q2 | Maleoon GPU 的实际兼容性与性能 | **未决，Phase 0/2 验证** | 建立设备 profile + 已知游戏矩阵 |
| Q3 | `preTransform` / 竖屏 pre-rotation | 未决 | Phase 2 验证，必要时在 presenter 加处理 |
| Q4 | OHOS libunwind 的 `__register_frame` 是否可用 | 未决 | Phase 1 验证；不可用则退回上游 per-function 方案 |
| Q5 | 沙箱 `filesDir` 是否有空间配额？大文件（>10 GB）拷贝是否受限？ | **未决，Phase 0.5 验证** | `getFreeSizeSync()` 预检 + 实测 |
| Q6 | `persistPermission` 作为"引用模式"的可行性 | 已核实 API 存在，未实测 | 未来优化，MVP 不做 |
| Q7 | 拷贝中断（进程被杀）后的残留清理 | 已设计 | `.tmp-<id>` + 启动时清理（§10.3） |
| Q8 | 存档导出/导入的打包格式 | 待定 | 建议 zip，兼容上游 `SessionLogs.kt` 的打包逻辑 |
| Q9 | `SCHED_FIFO` 实时优先级权限 | 低风险 | 静默降级即可 |
| Q10 | `/proc/self/maps`、`/proc/cpuinfo` 可见性 | 低风险 | 不可用则用替代实现或跳过 |
| Q11 | 上架审核（JIT / 大内存） | 待沟通 | 提前准备必要性说明 |

---

## 附录 A：关键接口速查

| 能力 | OHOS API | 头文件 |
| --- | --- | --- |
| 渲染表面 | `OH_NativeXComponent_RegisterCallback` | `ace/xcomponent/native_interface_xcomponent.h` |
| 原生窗口 | `OH_NativeWindow_NativeWindowHandleOpt` | `native_window/external_window.h` |
| Vulkan surface | `vkCreateSurfaceOHOS` | `vulkan/vulkan_ohos.h` |
| 帧同步 | `OH_NativeVSync_RequestFrame` | `native_vsync/native_vsync.h` |
| 音频渲染 | `OH_AudioStreamBuilder_Create` | `ohaudio/native_audiostreambuilder.h` |
| 手柄 | `OH_GamePad_*_RegisterButtonInputMonitor` | `GameControllerKit/game_pad.h` |
| 日志 | `OH_LOG_INFO` / `OH_LOG_ERROR` | `hilog/log.h` |
| 可执行内存 | `memfd_create` + `mmap` | `sys/mman.h` |
| 配置存储 | `OH_Preferences_*` | `@ohos.data.preferences`（ArkTS 侧） |
| 文件访问 | `@ohos.file.fs`：`createReadStream` / `createWriteStream` / `copyFileSync` / `statSync` / `renameSync` | `@ohos.file.fs`（ArkTS 侧） |
| 文件选择 | `@ohos.file.picker`：`DocumentSelectOptions` / `DocumentSaveOptions` | `@ohos.file.picker`（ArkTS 侧） |
| 空间查询 | `storageStatistics.getFreeSizeSync()` / `getTotalSizeSync()` | `@ohos.file.storageStatistics` |
| 持久化授权 | `fileshare.persistPermission`（备选方案，需 `FILE_ACCESS_PERSIST`） | `@ohos.fileshare` |

## 附录 B：相关文档

- [鸿蒙移植可行性分析报告](./鸿蒙移植可行性分析报告.md) — 证据、风险、工作量
- [上游 XenDroid](https://github.com/rfandango/XenDroid) — `BUILD.md` / `GAME_COMPAT.md` / `docs/`
- [OpenHarmony Vulkan 开发指南](https://gitee.com/openharmony/docs/blob/bbfa9a314e22a8d4fba8024477b159bc9910417f/en/application-dev/reference/native-lib/vulkan-guidelines.md)
- [华为官方：C/C++ 标准库机制概述](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/c-cpp-overview)
