# HX360E 架构文档（基于全量代码通读）

| 项目 | 内容 |
| --- | --- |
| 版本 | v1.0 — 2026-09-12 |
| 依据 | 本轮对 xenia 内核全部核心子系统（GPU Vulkan 后端、CPU/JIT、内存、内核层、呈现层）与 HX360E 适配层（xendroid_ohos / napi / ArkTS）的**逐文件通读** |
| 关联 | [DESIGN.md](./DESIGN.md)（移植设计）、[TODO.md](./TODO.md)（进度）、[PERFORMANCE.md](./PERFORMANCE.md)（性能优化点） |
| 源码布局 | 鸿蒙工程 `D:\Code\ArkTs\HX360E`；内核 fork `D:\Code\OpenSource\XenDroid\emulator-core\src\main\cpp\xenia`（经 `XE_XENDROID_ROOT` 集成，改动以 `patches/harmony/xendroid-ohos-fork.diff` 存档，43 文件） |

> 本文回答"**系统实际是怎么工作的**"。所有结论都标注代码位置（`file:line`）；
> xenia 侧路径省略前缀 `emulator-core/src/main/cpp/xenia/src/xenia/`。

---

## 目录

1. [系统总览与分层](#1-系统总览与分层)
2. [进程与线程模型](#2-进程与线程模型)
3. [启动与生命周期](#3-启动与生命周期)
4. [内存系统（4.5GB guest + W^X 代码缓存 + 写监视）](#4-内存系统)
5. [CPU 子系统：PPC → AArch64 JIT](#5-cpu-子系统)
6. [GPU 子系统（重点）](#6-gpu-子系统)
7. [内核层（guest 调度器 / 中断 / 等待原语）](#7-内核层)
8. [音频子系统](#8-音频子系统)
9. [输入子系统](#9-输入子系统)
10. [NAPI 桥接与 ArkTS 前端](#10-napi-桥接与-arkts-前端)
11. [存储模型](#11-存储模型)
12. [设置系统与 cvar 流](#12-设置系统与-cvar-流)
13. [构建系统与补丁管理](#13-构建系统与补丁管理)
14. [与 Android 版的结构性差异](#14-与-android-版的结构性差异)

---

## 1. 系统总览与分层

HX360E 是 XenDroid（Xenia Canary/Edge 分支的 Android 移植）到 HarmonyOS NEXT 的移植，
单进程、单 .so（`libentry.so`）、仅 Vulkan 图形后端、仅 arm64。

```
┌──────────────────────────────────────────────────────────────────┐
│ ArkTS 前端 (entry/src/main/ets)                                   │
│  Home(游戏库+设置入口) / GamePage(XComponent+虚拟手柄+调试浮层)    │
│  SettingsStore/SettingsSchema(~110 项, 稀疏 TOML) / AdvancedPage  │
└──────────────┬───────────────────────────────────────────────────┘
               │ NAPI（C 接口；emulator/config/meta/prompt/content 五个子对象）
┌──────────────┴───────────────────────────────────────────────────┐
│ HX360E 原生层 (entry/src/main/cpp)                                │
│  napi_init.cpp + napi_*.cc      NAPI 桥 + guest 提示轮询          │
│  xendroid_ohos/ohos_emulator    启动线程/生命周期/档案/诊断        │
│  xendroid_ohos/ohos_window      OhosWindow + WindowedAppContext   │
│  xendroid_ohos/ohos_input       GameControllerKit 手柄           │
│  xendroid_ohos/ohaudio_*        OHAudio 音频驱动                  │
│  xeg_spatial_upscale            XEngine 1.5x 空域超分(dlopen)     │
└──────────────┬───────────────────────────────────────────────────┘
               │ C++ 同进程直接调用
┌──────────────┴───────────────────────────────────────────────────┐
│ Xenia 内核 fork (XE_XENDROID_ROOT)                                │
│  emulator.cc       Emulator::Setup/Launch                         │
│  cpu/   PPC→HIR→AArch64 JIT (xbyak_aarch64)，代码缓存 W^X          │
│  gpu/   PM4 命令处理器 + Vulkan 后端 (34k 行)                      │
│  ui/    Presenter/swapchain/OHOS surface                          │
│  kernel/ guest 调度器(fiber) / XThread / XObject / XAM            │
│  memory.cc 4.5GB guest 地址空间 + 物理别名 + 写监视                │
│  apu/   AudioSystem/XMA(FFmpeg)                                   │
└──────────────┬───────────────────────────────────────────────────┘
               │ 平台接缝（全树仅 ~15 处 XE_PLATFORM_OHOS 分支）
┌──────────────┴───────────────────────────────────────────────────┐
│ HarmonyOS 系统能力                                                │
│  libvulkan.so(VK_OHOS_surface) libnative_window.so libace_ndk.z.so│
│  libohaudio.so libohgame_controller.z.so libhilog_ndk.z.so        │
│  libxengine.so (XEngine Kit 空域超分, dlopen 可选)                 │
└──────────────────────────────────────────────────────────────────┘
```

**平台接缝原则**：OHOS 上同时定义 `XE_PLATFORM_OHOS` + `XE_PLATFORM_xendroid` +
`XE_PLATFORM_LINUX`（`base/platform.h:41-46`），113 处 xendroid 分支代码（ADPF、FFmpeg
XMA 等）与 77 处 POSIX 路径全部复用；真正必须不同的只有 JIT 内存分配、surface 创建、
音频驱动、日志 sink 四类，收敛在 `*_ohos.cc` 新文件与少量 `#if XE_PLATFORM_OHOS` 分支。

---

## 2. 进程与线程模型

运行态线程清单（游戏运行中，实测代码推演）：

| 线程 | 创建者 | 职责与节奏 | 代码位置 |
| --- | --- | --- | --- |
| ArkUI 主线程 | 系统 | NAPI 调用、XComponent 回调、设置 UI、guest 提示轮询(150ms) | `napi_init.cpp` |
| hx360e-boot | `Boot()` | boot 全流程：参数解析→日志→UI 线程→Emulator::Setup→LaunchPath→WaitUntilExit | `xendroid_ohos/ohos_emulator.cc:135` |
| HX360E-UI | BootThread | `OhosWindowedAppContext::MainLoop`：4ms 超时轮询 + pending 函数 + paint 请求 | `ohos_window.cc:39-87` |
| Guest CPU 0..5 (×6) | GuestScheduler | fiber 派发线程：同核 fiber 协作切换，异核真并行 | `kernel/guest_scheduler.cc:216-233` |
| 调度 watchdog | GuestScheduler | 1ms quantum 抢占检查、stall/no-progress 诊断 | `guest_scheduler.cc:1622-1696` |
| Guest I/O (×1) | GuestScheduler | 所有 guest 文件读写的串行卸载线程（fiber park 等待） | `guest_scheduler.cc:863-956` |
| Kernel Dispatch | KernelState | kernel 派发队列（deferred overlapped 完成等） | `kernel_state.cc:548-577` |
| GPU Commands | CommandProcessor | PM4 主循环：ring buffer 解析 → IssueDraw/IssueCopy/IssueSwap | `gpu/command_processor.cc:313-323,652-732` |
| GPU Frame limiter | GraphicsSystem | 60/50Hz vblank 时钟 + guest ISR 执行（CPU2 上 DPC 假扮） | `gpu/graphics_system.cc:157-265` |
| Vulkan Pipelines (×N) | VulkanPipelineCache | 异步着色器翻译 + 管线创建（默认 75% 核心数） | `gpu/vulkan/vulkan_pipeline_cache.cc:360-378` |
| Audio Worker | AudioSystem | 5.33ms 节拍泵音频帧、直接执行 guest XAudio 回调 | `apu/audio_system.cc:312-400` |
| XMA Decoder | XmaDecoder | FFmpeg XMA 解码（320 context 扫描） | `apu/xma_decoder.cc` |
| OHAudio 回调线程 | 系统 | OnWriteData 回调拉取 48kHz/2ch/256 帧数据 | `xendroid_ohos/ohaudio_audio_driver.cc` |
| OHOS 回调线程 | GameControllerKit | 物理手柄事件 → InputDriver::OnKey | `xendroid_ohos/ohos_input_driver.cc` |

关键规则：
- **NAPI 环境只在 ArkUI 主线程使用**；guest 对话框走"native 请求队列 + ArkTS 150ms
  轮询 + 应答回填"的宿主 provider 模式（`prompt_providers.cc`），规避跨线程 NAPI。
- **XComponent surface 生命周期在 ArkUI 主线程**，swapchain 销毁必须 GPU 排空后进行；
  本移植的 surface 挂接走 `XComponentController.getXComponentSurfaceId()` →
  `OH_NativeWindow_CreateNativeWindowFromSurfaceId` 路径（Phase 0 验证可靠）。
- UI 线程销毁 window/context（`WindowedAppContext` 析构断言 `IsInUIThread()`），
  收尾顺序由 `BootTeardownGuard` 统一保证（`ohos_emulator.cc:147-173`）。

---

## 3. 启动与生命周期

```
ArkTS Home.startGame()
  ├─ 组装启动参数（附录见 §12）：--storage_root/--gpu=vulkan/--apu=ohaudio
  │   --vulkan_allow_present_mode_immediate/mailbox=true
  │   --hx360e_render_scale_den_x/y=<设置页>  --vulkan_direct_host_resolve=false
  │   --config=<filesDir>/storage/config/xenia-edge.config.toml
  ├─ napi.emulator.setupLaunchArgs/setupGamePath/boot()
│
C++ BootThread (ohos_emulator.cc:135)
  ├─ cvar::ParseLaunchArguments（std::call_once）
  ├─ config::SetupConfig(storage)  ← 必须在日志初始化前（会改 log_append）
  ├─ InitializeLogging（OhosLogSink(hilog) + FileLogSink(xe.log)）
  ├─ native_fault.log 崩溃安全诊断 fd（write(2) only）
  ├─ arm64::InitFeatureFlags（HWCAP：LSE 等）
  ├─ 启动 UI 线程（OhosWindowedAppContext + OhosWindow 1280x720）
  ├─ 档案自动创建/登录（CreateStandaloneProfile("Player") + logged_profile_slot_0_xuid）
  ├─ xe::Emulator::Setup(window, ..., CreateAudioSystem, CreateGraphicsSystem, CreateInputDrivers)
  │    ├─ Memory::Initialize（4.5GB 映射，基址 mmap_address_high<<32 失败则扫 2^n）
  │    ├─ Processor（A64Backend + 代码缓存）
  │    ├─ KernelState + ProfileManager（读 slot0 XUID 登录）
  │    ├─ GraphicsSystem = VulkanGraphicsSystem（gpu=null 时 NullGraphicsSystem，用于对照测量）
  │    │    └─ CommandProcessor 线程 + vblank 线程 + presenter(UIThread 连接)
  │    ├─ AudioSystem = OHaudioAudioSystem
  │    └─ InputSystem（OhosInputDriver）
  ├─ presenter 强制 FSR 后处理链（开 XEG 时，ohos_emulator.cc:394-402）
  ├─ InstallAllPromptProviders（guest 键盘/对话框/换盘）
  ├─ LaunchPath(game) → 加载 XEX → guest 线程跑起来
  └─ WaitUntilExit → BootTeardownGuard（释放 Emulator→UI 线程退出 join→g_booting=false）
```

surface 挂接：ArkTS `GamePage` 的 `XComponentController` 轮询 surfaceId →
`attachSurface(id)` → native `OH_NativeWindow_CreateNativeWindowFromSurfaceId` →
`OhosWindowedAppContext::SetWindowSurface` + `window->UpdateSurface()`（UI 线程）→
`OnSurfaceChanged/OnActualSizeUpdate` → presenter 在 GPU 线程连接/重建 swapchain。
窗口几何读取必须 `(height, width)` 顺序（GET_BUFFER_GEOMETRY 参数序），读反会转置
（`ohos_window.cc:143-157` 注释，实测踩坑）。

---

## 4. 内存系统

### 4.1 Guest 地址空间（4.5GB 直映射）

`memory.cc:204-409`：一块 4GB+512MB 的宿主保留区（`mmap_address_high<<32`，默认 8 →
0x2_00000000；失败回退扫 2^n 基址，fork 补丁），9 个视图映射进 guest 虚拟布局：

| guest 范围 | 用途 |
| --- | --- |
| 0x00000000–0x7EFFFFFF | 虚拟内存（4 虚拟 heap：0/4k、4/64k、8/4k、C/4k…） |
| [0x7F000000,0x80000000) | GPU writeback 窗口 → 文件偏移 0x100000000（物理 0–16MB 别名），**无自己的 heap**；fork 为它补了 AccessViolation 重定向（`memory.cc:765-803`） |
| 0x80000000–0x9FFFFFFF | XEX 模块（可执行） |
| 0xA/0xC/0xE0000000 | 物理内存三个别名 heap（64KB/16MB/4KB 页；E 带 0x1000 host_address_offset） |

- JIT 把 guest 内存基址常驻 x21，所有 LOAD/STORE 直发
  `ldr/str [x21, addr]`，**无软件 TLB**；字节序 `rev` 内联。
- `MAP_FIXED_NOREPLACE` 替代 `MAP_FIXED`（fork 补丁）：内存视图落点靠扫描，
  绝不允许静默覆盖 App 自己的堆/线程栈（曾致 shader 翻译期 malloc 堆破坏）。
- OHOS 内核页 4KB（与 guest 一致），`ShouldSkipHostCommit` 的"大页跳过"分支不触发。

### 4.2 JIT 代码缓存（W^X，OHOS 特有路径）

`cpu/backend/code_cache_base.h`：

- 代码区 256MB + 间接表 512MB + 外部目标表 64K×u64。
- OHOS 内核拒绝文件映射可执行、剥匿名 RWX 的 W → 用**一块匿名 RW 区域同作写/执行
  视图**，每次函数放置：offset 页对齐 → `mprotect(RW)` → memcpy →
  `mprotect(R|X)` → `__builtin___clear_cache`（每放置 **2 次 mprotect + 1 次 icache
  flush**，全程持 `global_critical_region` 全局递归锁）。页对齐防"翻转摘掉活代码的 X"
  （曾是 SEGV_ACCERR 指令中止的根因）。`EnsureCommitted` 在 OHOS 是 no-op。
- 间接表强制 encoded 模式（`encoded_indirection_=true`）：guest 间接调用 =
  7–8 条内联指令的槽位查找（fast 模式 2–3 条在本平台不可用）。
- 槽初值 = resolve thunk → 首调触发 C++ `ResolveFunction` → `EntryTable` 全局锁查找
  → 全量 JIT 编译 → 回填槽位；后续调用纯内联，无锁 O(1)。
- DWARF `.eh_frame` 放独立 128MB bump 缓冲，每 FDE 单独 `__register_frame`，
  支撑 `FiberReentryException` 沿 JIT 帧展开（xthread 栈重入）。

### 4.3 写监视（write-watch）：CPU 写 GPU 可见内存的失效链

```
GPU RequestRange/MakeRangeValid
  └─ EnablePhysicalMemoryAccessCallbacks → 对 A/C/E 三个别名 heap 的页
       置 notify_on_invalidation 位 + mprotect(RO)
guest store 命中 RO 页
  ├─ SIGSEGV → 异常处理器（解析 ESR 读写位；OHOS 写 crash-safe 诊断行）
  ├─ MMIOHandler::ExceptionCallback（handler 内禁 XELOG——日志会 malloc）
  ├─ Memory::AccessViolationCallback
  │    · [0x7F000000,0x80000000) 无 heap：mprotect 窗口自身页 + 重定向到 0xA 别名（fork 修复）
  ├─ PhysicalHeap::TriggerCallbacks
  │    · 位扫描 watch 位 → 触发注册的失效回调（= SharedMemory::MemoryInvalidationCallback
  │      → GPU 页失效 + 纹理/顶点缓存失效）→ 批量 mprotect(RW) + 清位
  └─ 内核重执行 store
```

一次性语义：解锁后直达，直到 GPU 下次 arm。失效范围在无 GPU-written 数据相邻时可
外扩至 256KB（`gpu/shared_memory.cc:710-733` 的注释给出量化理由：4KB 粒度 vs 256KB
粒度对某软件渲染游戏是 4fps vs 0.7ms/帧的差别）。

---

## 5. CPU 子系统

### 5.1 JIT 流水线

```
PPC → PPCScanner(划界) → PPCHIRBuilder(降为 HIR) → 编译 pass 链 → A64Assembler(序列选择发射)
```

Pass 链（`cpu/ppc/ppc_translator.cc:68-183`）：ControlFlowAnalysis →
Simplification+ConstantPropagation(不动点) → **PreemptCheckInjection**（协作调度
safepoint）→ ContextPromotion → **SpinLoopBackoff / DelayCountdownCollapse /
MemoryPollPark**（自旋折叠，默认全开）→ MemorySequenceCombination（AArch64 支持
ext load/store）→ DCE → **RegisterAllocationPass**（线性扫描，GPR 仅 x22-x28 七个
可分配，x19/x20/x21 保留为上下文/基址寄存器；VEC 28 个）→ Finalization。

发射层 `A64Emitter`（xbyak_aarch64 CodeGenerator，4MiB 自动增长缓冲）：
- 序列库 ~226 个 Emit（`a64_sequences.cc` 4859 行 + memory/vector/control 分件）。
- LSE 原子（HWCAP 探测，`casal` 单条）；lwarx/stwcx 走"普通读+捕获 / 单条 CASAL"
  原生路径（`a64_native_reserved_ops=true`，避免 ldaxr/stlxr 跨窗活锁）。
- 每函数 prolog `PushStackpoint`（~10 条）、每次 call 后 host/guest 栈同步检查、
  块首 FPCR 按需重载；guest→host thunk 每次保存 28 个 Q 寄存器（464B 帧）。
- 远条件分支"反转+b±128MB"影子；64 位立即数 movz+movk 展开。

### 5.2 Guest 线程与协作调度（当前生效配置）

**HX360E 上 `guest_scheduler=true` 生效**（fork DEFINE true；`UPDATE_from_bool(…,
2026-8-1, false)` 是"旧默认 false → 新默认 true"的迁移；且设置页
`Kernel|guest_scheduler=true` 显式播种进 TOML，`SettingsSchema.ets:259`）：

- 6 条派发线程（每逻辑核一条），guest 线程 = 16MiB fiber 钉在
  `KTHREAD::current_cpu` 对应派发线程上；同核 fiber 协作切换，异核并行。
- 就绪队列 32 级优先级 + lzcnt 位图；阻塞记录"等待形状"：
  单对象等待走 **epoch 门控**（信号到来才重轮询），多对象 ≤8 个用集合 epoch，
  纯延时睡到 deadline，未门控等待 1ms 轮询 + 64ms 兜底。
- `XObject::WakeCooperativeWaiters` = epoch `fetch_add` + **定向唤醒**
  （只 poke 持有等待者的 CPU；semaphore 只唤醒队首）——注释记载广播式唤醒曾使
  《Eternal Sonata》69% CPU 烧在 futex 与空调度（`xobject.cc:400-410`）。
- 抢占：watchdog 超 quantum（1ms）置 JIT 的 `preempt_requested`，JIT safepoint
  （块首 `CHECK_PREEMPT`）让出；持全局锁/高 IRQL 延后。
- 阻塞宿主调用（文件读等）卸载到单条 Guest I/O 线程，fiber park。
- ARM64 `MaybeYield` 用 WFE（10kHz 事件流）替代 sched_yield（`wfe_yield=true`）。

关闭该调度器时回退为"一 guest 线程一 OS 线程（16MiB）+ FiberReentryException 展栈"。

### 5.3 已知 CPU 侧成本（详见 PERFORMANCE.md §3）

OHOS W^X 每放置 2 mprotect + 页对齐浪费；encoded 间接查找多 ~5 条指令；g2h thunk
28×Q；`a64_perf_map=true` 每放置写 perf map 并 fflush；write-watch 故障路径的
诊断 snprintf（限量）。

---

## 6. GPU 子系统

Xenos GPU（Xbox 360 的 R500 系）模拟 = **PM4 命令流翻译** + **四大缓存**
（共享内存/渲染目标/纹理/管线）+ **呈现**。以下按帧内数据流展开。

### 6.1 命令处理器与 PM4 主循环

- 宿主侧"GPU Commands"线程（`command_processor.cc:652-732`）：
  ring buffer 空（`write_ptr==0xBAADF00D` 或 read==write）时**自旋
  `gpu_stall_spin_iterations`(=32) 次 MaybeYield，之后 2ms 事件等待**；
  guest 写 `write_ptr` 触发事件唤醒（`SetBoostPriority`）。
- `ExecutePrimaryBuffer` 解析 PM4：Type-0 寄存器写走**快速区段路径**
  （`vulkan_fast_register_ranges=true`：无副作用的寄存器一次
  `copy_and_swap`，fetch/bool-loop/float-constant 家族做区段级脏标记 +
  同值跳过 `vulkan_skip_redundant_fetch_constant_writes`；
  `vulkan_command_processor.cc:2089-2201`）。
- Type-3 包分派：`ISSUE_DRAW`→IssueDraw、`EVENT_WRITE_ZPD`→遮挡查询、
  `COPY_*`→IssueCopy（EDRAM resolve）、swap 包→IssueSwap。
- **帧中提交**：`vulkan_mid_frame_submission_draws=1300` —— 每 1300 个真实 draw
  结束当前提交让 GPU 提前开工（`vulkan_command_processor.cc:4788-4794`）；
  `submit_on_primary_buffer_end=true` 在 guest 主命令缓冲结束时也可切分。
- `WAIT_REG_MEM` 不满足：wait≥0x100 且 `guest_display_refresh_cap` 时按 guest
  指定毫秒睡，否则纯自旋（`pm4_command_processor_implement.h:857-937`）。
- IssueSwap 后 `ThrottlePresentation()`（`framerate_limit=60`：
  spin+NanoSleep 到目标帧时长，落后 >2 帧重同步；`command_processor.cc:594-650`）。

### 6.2 共享内存（CPU→GPU 的数据通道）

512MB guest 物理内存的 GPU 侧镜像，`gpu/vulkan/vulkan_shared_memory.cc` 有四种
后端形态（按优先级）：

| 形态 | 条件 | 语义 |
| --- | --- | --- |
| **zero-copy**（ARM64 默认 `shared_memory_zero_copy=true`） | `VK_EXT_external_memory_host` + 对齐满足 | **直接把 guest RAM import 成 VkBuffer**（`CreateImportedGuestRamBuffer:317-458`）。CPU 写天然可见，`UploadRanges` 退化为打 valid 位，无任何拷贝。副作用：import pin 住 guest RAM，物理 heap 的 host mprotect 跳过（`SetPhysicalAliasSkipHostProtect(true)`）；**另外会派生第二个 host-imported buffer 专供 memexport 双缓冲路由**（`TryInitializeHostBuffer`，需 `memexport_enable`） |
| sparse 绑定 | `vulkan_sparse_shared_memory=true` 且 `sparseResidencyBuffer` | 512MB 稀疏 buffer，页按需绑 device-local 内存（Phase 0 实测 Maleoon `sparse=1`） |
| host-visible dense | `vulkan_shared_memory_host_visible=true`（统一内存 GPU） | 完整 512MB host-visible cached buffer + 持久映射，resolve 回读免拷贝（Adreno 830 实测 +11.6%） |
| 普通 dense | 兜底 | 512MB device-local |

脏页上传（非 zero-copy 形态）：页粒度 valid 位图（4KB/页，64 页一块便于位扫描）+
`RequestRange` 的**无锁全-valid 快路径**（`gpu/shared_memory.cc:493-518`）→
upload buffer pool 收集 → `vkCmdCopyBuffer`。**upload 提升出 render pass**：
本提交内未被失效的页录进 `deferred_setup_command_buffer`（提交头部执行），
避免破坏 render pass —— `vulkan_hoist_shmem_uploads=true`（tile GPU 关键优化，
`vulkan_shared_memory.cc:786-825`）。

CPU 失效 → GPU 重新上传：§4.3 的写监视 → `MemoryInvalidationCallback` 清 valid 位
→ 下次 `RequestRange` 重传。

GPU 写回 CPU（resolve 输出/memexport）：`readback_resolve` 模式决定。
**HX360E 设置页默认 `none`**（原生 fork 默认 `uma`）：跳过全部回读拷贝。
`uma` 模式在 zero-copy/host-mapped 下由 CPU 直接读 GPU 写过的内存
（`vulkan_command_processor.cc:4939-5014`），每次目的地址只读一次（submission
退役后），无 staging 拷贝。

**memexport 双缓冲路由**（`command_processor_memexport.inc`）：
写 memexport 的 draw 及其几何消费者绑定 host-imported buffer（= guest RAM，
CPU 一致），采样消费者按需 `EnsureMemexportRangeInDeviceBuffer` 用一次
vkCopyBuffer 拉进 device buffer——解决页假共享 clobber，同时保持 device 侧快。

### 6.3 渲染目标缓存（EDRAM 模拟）

Xenos 的 10MB EDRAM 是 tile 式片上显存，(pitch, base) 定义 80×16 采样 tile 的
线性寻址。`Path::kHostRenderTargets`（`render_target_path="performance"`，
默认）把每个 (base,pitch,format,msaa) 组合映射成一张宿主 VkImage；
`kPixelShaderInterlock`（"accuracy"）用 SSBO + fragment shader interlock 逐像素
模拟 ROP（慢，兼容性兜底）。

- **RenderPassKey**（32 位：msaa + 深度/4 色 RT 使用位 + 各格式 +
  loadOp-DONT_CARE 位）与 **FramebufferKey**（+ pitch + 各 base tiles）缓存
  VkRenderPass/VkFramebuffer；`vulkan_dynamic_rendering=true`（Maleoon 1.3 支持）
  时用 VK_KHR_dynamic_rendering，无 RenderPass 对象，DONT_CARE 位可从 key 归一化掉
  （`vulkan_normalize_dontcare_keys`）避免无谓的 pass 打断。
- **所有权转移（transfer）**：guest 换 RT 组合时，旧 owner 的内容要搬到新 owner。
  fork 的 **in-pass transfers**（`vulkan_in_pass_transfers=true`）把兼容的转移
  **编进 guest draw 自己的 render pass**（`EncodePendingDrawPassTransfers`），
  完全覆盖时还把 loadOp 置 DONT_CARE —— 避免 tile GPU 的 GMEM store/restore。
  不兼容才回退为独立 pass（`vulkan_render_target_cache.cc:3423-3490`）。
- **Resolve（IssueCopy）三级路径**（`vulkan_render_target_cache.cc:2756-3248`）：
  1. **in-pass resolve**（`vulkan_in_pass_resolve`，HX360E 设置页默认 true，
     native 默认 false）：需要 `VK_KHR_dynamic_rendering_local_read`，
     颜色附件用 RENDERING_LOCAL_READ 布局，fragment 里用 input attachment
     直接把解析结果写进 guest 内存/目的纹理 —— **不结束 pass、不落 EDRAM**。
     命中率有诊断计数（`VkInPass: taken/attempts …`）。
  2. **direct host resolve**（`vulkan_direct_host_resolve=true` 默认；
     **HX360E 启动参数强制 false**，见 §12）：跳过"dump RT→EDRAM buffer"一步，
     compute 着色器直接从宿主 RT 读像素写入 guest 内存（格式打包一族
     `resolve_host_color_*` 着色器）。
  3. **EDRAM dump 路径**（兜底，也是 HX360E 当前实际路径）：
     `DumpRenderTargets` compute 把宿主 RT 写回 10MB EDRAM buffer 的 tile 布局 →
     `resolve_full/fast_*` compute 把 EDRAM 搬到 guest 内存（半分辨率渲染时
     dump/搬运着色器里做了 den 除法回算，fork 补丁）。
- 解析完成 → `RangeWrittenByGpu`（触发 watch 让纹理缓存重新装载）+
  resolve-dest 纹理直存/直取（`vulkan_resolve_to_texture` 三件套：
  promote/store/serve，把解析结果直接写进将来会被采样的那张纹理，
  跳过"写 guest 内存再整块重传"；HX360E 设置页默认全开）。
- MSAA：`native_2x_msaa=true` —— guest 2x 用宿主真 2x；4x 用样本率着色或
  2x-as-4x。半分辨率除数 den 与宿主 extent 的关系：
  `host = guest × draw_resolution_scale / den`（`GetHostExtentX/Y`，
  `gpu/render_target_cache.h` fork 补丁；`scale_native` 的面保持 1x）。

### 6.4 纹理缓存

- guest 纹理 = 共享内存里的 tiled/字节序特殊布局 → 首次使用时**compute 解块**
  （`texture_load_*` 着色器，8–128 bytes/block 各一族）→ scratch buffer →
  `vkCmdCopyBufferToImage`（`vulkan_texture_cache.cc:1631-2350`）。
  每纹理按 `TextureKey` 哈希缓存，LRU 软上限 384MB / 硬上限 768MB
  （`texture_cache_memory_limit_*`）。
- **resolve-dest 提升**：被解析命中的纹理直接获得 storage view，后续
  `TryServeFromResolveDest` 跳过装载（§6.3 的三件套）。
- **半分辨率纹理**：den<1 时纹理图像与解块 dispatch 都按
  `size × scale / den` 收缩（`LoadTextureDataFromResidentMemoryImpl` 内
  `texture_resolution_scale_*` 混算）。
- **缩放解析缓冲**（`draw_resolution_scale>1` 时）：稀疏 2x/3x 地址空间 +
  独立页表（`scaled_resolve_pages_` + L2 位图 + global watch）。
- 采样器：跨 draw 参数缓存（`vulkan_cache_sampler_parameters=true`，fetch 常量
  脏位增量重推导）+ `sampler_destroy_generation` 防句柄复用冲突。
- swap 前台纹理 `RequestSwapTexture`（分辨率缩放或原尺寸）。

### 6.5 管线缓存与着色器翻译

- **翻译**：Xenos 微码 → SPIR-V（`SpirvShaderTranslator`，glslang spv::Builder
  序列化）。Modification 位域（采样数量/插值/深度模式/RT blend 预乘等）派生
  变体。**异步模型**（`vulkan_placeholder_pipelines=false`，fork 默认）：
  draw 线程从不翻译——管线槽保持 VK_NULL_HANDLE，命令缓冲录"槽指针延迟绑定"
  （replay 时解析），提交边界默认**等待创建完成**（不丢 draw）；
  `vulkan_async_skip_draws=true`（HX360E 设置页默认）改为丢弃未就绪 draw（poppin 换流畅）。
- **管线排列坍缩**：VK_EXT_extended_dynamic_state 1/2/3（`vulkan_dynamic_pipeline_state=true`）
  把拓扑/面朝向/剔除/深度模板/混合/写掩码移出动态状态，`CanonicalizePipelineDescription`
  把这些字段归零 —— 同类 draw 共享一条 VkPipeline。FSI 路径禁用 EDS。
- **磁盘缓存**：`shader_storage`（ucode + SPIR-V + 管线描述，
  mmap 索引）+ `pipeline_storage_precreate=true`（开局后台预建上次用过的全部
  管线）+ 驱动 VkPipelineCache 每 20s 落盘（fork，`MaybeSaveVkPipelineCache`）。
- **着色器翻译线程栈 32MiB**（fork：-O0 构建 + glslang CFG dump 递归曾爆栈）。
- HX360E 插件：`VK_KHR_fragment_shading_rate` 探测启用 + 全管线挂
  `VkPipelineFragmentShadingRateStateCreateInfoKHR`（`hx360e_vrs_rate`，默认 off）
  —— fragment 降频的管线级实现（fork 补丁 `vulkan_pipeline_cache.cc:2737-2774`）。

### 6.6 图元处理器

索引缓冲归一化（`gpu/primitive_processor.cc`，NEON 加速）：
fan/line-loop/quad → list/strip、big-endian 字节序交换、primitive-reset 指数
改写、24bit→32bit 展开。产物类型：直接 DMA（shared memory 当 index buffer）、
宿主转换缓存（LRU，跨帧复用）、内置 adapter 索引。点列表/矩形列表在无几何着色器
时退化为 VS 展开（`kPointListAsTriangleStrip` 等 host vertex shader 类型）。

### 6.7 命令录制与提交模型

- 所有 Vulkan 命令先录进 **DeferredCommandBuffer**（线性 arena，
  `deferred_command_buffer.h`），`EndSubmission` 时一次性回放进真实
  VkCommandBuffer —— 为了"提交边界等待异步管线"语义和 render-pass 内命令重排
  （如 barrier 需要结束 pass 时把命令挪前）。setup 上传流与主命令流分开
  （`deferred_setup_command_buffer_`）。
- **提交节制**：`CanEndSubmissionImmediately` 有未完成管线创建时拒绝切分；
  `kMaxFramesInFlight=3` 帧护栏。
- **barrier 去重/合并**（`pending_barriers_`）：相同范围相同 mask 的 barrier
  合并，重叠范围强制分裂；`SubmitBarriers(force_end_render_pass)` 统一发射。
- 资源生命周期按 submission 编号延迟销毁（destroy_* deques +
  `CheckSubmissionCompletionAndDeviceLoss` 统一回收；fence 经
  `VulkanGPUCompletionTimeline` 管理，避免 Turnip 上的阻塞 fence 轮询问题）。

### 6.8 遮挡查询（ZPD）

`EVENT_WRITE_ZPD`（guest 可见性测试结果写回）：
`occlusion_query="fake"`（HX360E 设置页默认）直接写 fake 样本数（80–100 窗口，
`occlusion_query_fake_*`），零 GPU 成本；"fast" 用 Vulkan query pool +
in-render-pass 分段 + 提交内 `vkCmdCopyQueryPoolResults(WAIT_BIT)` 回读到
host 可读 buffer（无 host 侧阻塞轮询）；FSI 路径用 SSBO 计数器。

### 6.9 呈现链路（present path）

```
guest swap 包 → IssueSwap
  ├─ texture_cache_->RequestSwapTexture（前台纹理）
  ├─ gamma ramp compute（256 表/PWL；可选 FXAA luma 合并）
  │    [+ FXAA compute] → guest 输出图（presenter 3 图 mailbox 的 writable 槽）
  ├─ presenter->RefreshGuestOutput(...)：
  │    guest 输出后处理 flow（按 guest_output_paint_config）：
  │      bilinear / CAS / FSR(EASU+RCAS) ；HX360E 开 XEG 时
  │      第 0 段（EASU）被 HMS_XEG_CmdRenderSpatialUpscale 取代（1.5x，
  │      输出到自建 RGBA8 图，描述符重写让第 1 段 bilinear 采样 XEG 输出）
  │    → PaintAndPresent（线程取决于 PaintMode）
  └─ EndSubmission(true)（关帧）
```

- **PaintMode 选择**（`ui/presenter.cc:1091-1121`）：连接不可画→kNone；
  swapchain 为 FIFO/FIFO_RELAXED（隐式 vsync）或 Wayland 或有 UI drawer→
  UI 线程 paint；否则 **kGuestOutputThreadImmediately** —— GPU 仿真线程直接
  present（最低延迟）。HX360E：`host_present_from_non_ui_thread=true` +
  `--vulkan_allow_present_mode_immediate/mailbox=true` → 走立即模式；
  **已回退的实验**：强制 FIFO + UI 线程 paint 实测上屏率仅 ~8/s（体感更卡，
  `ohos_window.cc:185-193` 注释留档）。
- 3 图 mailbox、**最新帧胜出**（CAS 替换 ready 槽，丢旧帧换低延迟）；
  `guest_output_refresh_count_` 供 UI 判断"本帧由 guest 驱动"避免 UI 超前刷屏。
- swapchain 呈现模式优先级 IMMEDIATE > MAILBOX > FIFO_RELAXED > FIFO
  （`vulkan_presenter.cc:1342-1364`）；格式 R8G8B8A8 优先（OHOS 分支）。
- OHOS UI 线程主循环（`ohos_window.cc:39-87`）：4ms 超时 condvar + pending 函数 +
  paint 请求（立即模式下 `RequestPaintImpl` 为空，paint 路径实际闲置）+
  每秒一条 `present probe` 诊断（paints/s vs guest FPS + XEG 状态）。

### 6.10 GPU 侧诊断设施（fork 内建）

- `log_gpu_frame_time_breakdown=true`：每提交 2 个 GPU 时间戳（TOP/BOTTOM）+
  resolve 区域时间戳对（48 对/提交 ring）+ render pass 时间戳对（96 对/提交 ring，
  按 framebuffer 尺寸分桶，含 scissor/viewport 上界）——全部**提交内
  vkCmdCopyQueryPoolResults 回读到 mapped buffer，无 host 阻塞查询**；
  每秒汇总 `VkFrameSync:`（awaits/sub_latency/gpu exec/gpu gap/resolve_ms/
  draws/pass_begins）与 `VkPassTime:`（每桶 GPU 时间）。
  时间戳结果还喂给 `xe::RecordGpuTime` → 调试浮层的"GPU 占用%"
  （`frame_stats.h` fork 补丁 + `GpuBusyPercent()`）。
- `log_resolve_details=true`：每秒 resolve 直方图（大小/格式/MSAA/路径/目的地址
  复用统计）。
- RenderDoc 抓帧：`gpu_debug_markers` + `hx360e` 转储；仓库根的 `.rdc` 已 gitignore。

---

## 7. 内核层

- **vblank 时钟**："GPU Frame limiter" 宿主线程（kNormal——曾被 kLowest 饿死），
  `guest_display_refresh_cap=true` 时按 50/60Hz 绝对截止期
  （Linux 锚点前移 + NanoSleepPrecise 只睡余量）`MarkVblank()`：
  自由扫描线计数（guest 读 `D1MODE_V_COUNTER`）+ CP 计数器++ +
  `DispatchInterruptCallback` → **静态互斥锁串行化**后在该线程上以 DPC 假扮
  （IRQL=2, CPU2）执行 guest ISR（`kernel_state.cc:1326-1376`）。
  guest ISR 里 KeSetEvent → `WakeForSignal` 定向唤醒等待 fiber。
- **KeTimeStampBundle**：1ms HighResolutionTimer 刷新 interrupt/system/tick
  时间（`kernel_state.cc:1633-1636`）——guest 可见时间粒度 1ms。
- **等待原语**：CooperativeWait 模板（epoch 门控 + park）；semaphore/auto-reset
  event 的队首公平（CooperativeWaiterFifo）；Pulse 对有等待者的 auto-reset 按
  Set 投递（防错过）；WaitMultiple ≤64 句柄；XTimer 回调以 APC 投回创建线程。
- **XThread**：16MiB fiber/线程栈；无 proc_mask 时继承父线程 CPU（保留 360
  隐式串行化语义）；`precise_guest_delays=true`（帧步进 sleep 用精确睡眠，
  普通睡眠过冲会放大帧时间）；`fiber_reentry_longjmp=true`（setjmp/longjmp
  替代完整 DWARF unwind，省 ~10% CPU）。
- **VFS**：挂载路径 → 内存 entry 树解析（纯内存 + 全局锁）；读 = Guest I/O 线程
  `ReadSync` 直入 guest 物理内存 + `TriggerCallbacks`（触发 GPU 失效）。
  ISO=mmap memcpy；zarchive 透明解压；STFS/SVOD 按 block list 分段 pread。
- **XEX 指令信息缓存**：按 XEX SHA-1 的 mmap 文件
  `modules/<sha>/executable_addr_flags.bin`（`xex_module.cc:1327-1383`）——
  唯一跨运行的 CPU 侧缓存（只缓存扫描结果，不缓存机器码）。

---

## 8. 音频子系统

```
guest XAudio2 → XMA/WMA (FFmpeg, "XMA Decoder" 线程) 
  → AudioSystem client（semaphore credit，apu_max_queued_frames=8）
  → "Audio Worker" 5.33ms 节拍泵 → driver->SubmitFrame
  → OHAudio（48kHz/2ch/256 帧/FAST 延迟模式）回调拉取 → 扬声器
```

- OHAudio 驱动（`xendroid_ohos/ohaudio_audio_driver.cc`）照 AAudio 驱动结构移植：
  软件音量、欠载恢复线程、FLOAT32→S16 协商。
- 背压：输出槽 credit（queued frames）用尽即丢帧（已充分缓冲）；
  `apu_pump_topup=true` 欠载时每 interval 多补 1 帧。
- `--apu=ohaudio`（HX360E 默认）；nop 驱动保留（信号量立即归还，防 guest 卡死）。

---

## 9. 输入子系统

- 物理手柄：GameControllerKit 逐控件注册（14 按键 + 5 组轴）→
  `OhosInputDriver : xe::hid::InputDriver`（`EnumerateDevices` 常驻 1 手柄自动绑 P1；
  摇杆死区、扳机模拟量）。
- 屏幕虚拟手柄：ArkTS 覆盖层（真模拟量摇杆/多点触控 claim）→ NAPI
  `emulator.keyEvent(idx, pressed, value)`（编码 0–15 数字键 / 16–23 模拟半轴，
  与 native `OhosPadKey` 顺序一致）。

---

## 10. NAPI 桥接与 ArkTS 前端

- `napi_init.cpp` 注册五个子对象：`emulator`（生命周期/输入/状态/调试）、
  `config`（TOML 句柄 bigint：open/loadEntry/saveEntry/saveToFile/close）、
  `meta`（ISO/XEX/ZAR/STFS 元数据+封面）、`prompt`（键盘/对话框/换盘轮询）、
  `content`（内容管理/档案/压缩）。
- 状态读数：`instantFps/averageFps/lastFrameTimeMs`（`frame_stats.h`，
  `RecordGuestPresent` 由 IssueSwap 计数——**guest 真实帧率与 present 路径解耦**）；
  `CpuUsagePercent`（进程 CPU 时间差分）；`GpuBusyPercent`（GPU 时间戳回读
  ÷ 帧间隔，回退 sysfs devfreq）；`debugOverlayText`（FPS + 着色器编译中数量）。
- ArkTS：Home（HDS 底栏 + 多槽位游戏库 `games/<id>/` + `.meta/<id>.json` 封面）、
  GamePage（XComponent SURFACE + 虚拟手柄 + 可拖动调试浮层 + 提示弹窗）、
  AdvancedPage（~110 项分组设置）。

---

## 11. 存储模型

```
<context.filesDir>/
├── games/<installId>/     游戏文件（picker 选文件/文件夹 → 分块拷贝）
├── games/.meta/<id>.json  封面/标题元数据缓存
└── storage/
    ├── config/xenia-edge.config.toml   设置（稀疏 TOML + HX360E 版本标记）
    ├── content/<XUID>/<TITLEID>/...    存档（天然按档案+标题隔离）
    ├── cache/  (shader_storage / vk pipeline cache / xex info cache)
    └── patches/                     guest 补丁 *.patch.toml
```

- 全部 POSIX 真实路径，内核 VFS 零特殊处理。
- 诊断：`logs/xe.log`（hilog + 文件双 sink）、`logs/native_fault.log`
  （crash-safe，下次启动回显）、应用内"导出日志到 Download"。

---

## 12. 设置系统与 cvar 流

```
SettingsSchema.ets（~110 项，含 HX360E 专属：hx360e_render_scale_den_x、
                    hx360e_vrs_rate、hx360e_xeg_spatial_upscale[_sharpness]）
   ↓ SettingsStore：稀疏 TOML 写入 + CONFIG_SCHEMA_VERSION(=6) 迁移表
   ↓     （版本标记缺失时不重放迁移——防 xenia SaveConfig 丢标记后把用户值改回默认）
   ↓ configPath(filesDir) = storage/config/xenia-edge.config.toml
启动时 Home.startGame() 把其中"命令行优先级更高"的项（render_scale_den、
direct_host_resolve、present mode 白名单）再以 --flag 传一遍
   ↓
C++ ParseLaunchArguments → cvar 默认 ← TOML ←（低优先）—— 命令行最高
```

与性能直接相关的设置默认值（HX360E 生效值）：

| cvar | HX360E 默认 | 原生 fork 默认 | 备注 |
| --- | --- | --- | --- |
| `hx360e_render_scale_den_x/y` | 1（原生 720p） | 1 | 2=半分辨率 360p，启动命令行传入 |
| `vulkan_direct_host_resolve` | **false（强制）** | true | den 适配 bug 待修（标题层缩 1/4） |
| `vulkan_in_pass_resolve` | true | false | 需 Maleoon 支持 local_read（待真机确认） |
| `vulkan_resolve_to_texture_{promote,store,serve}` | 全 true | — | 解析直存纹理 |
| `hx360e_xeg_spatial_upscale` | true | false | 失败自动退回 FSR |
| `hx360e_vrs_rate` | off | off | 管线已挂 VRS state |
| `readback_resolve` | **none** | uma | 关闭全部回读拷贝 |
| `occlusion_query` | **fake** | fast | 零 GPU 成本 |
| `vulkan_async_skip_draws` | true | false | 编译期丢 draw 换流畅 |
| `vulkan_mid_frame_submission_draws` | 1300 | 1300 | 帧中提交 |
| `guest_scheduler` | true（显式播种） | true(迁移后) | fiber 协作调度 |
| `framerate_limit` | 60 | 60 | IssueSwap 后节流 |
| `guest_display_refresh_cap` | true | true | 60Hz vblank 时钟 |
| `texture_cache_memory_limit_soft/hard` | 384/768 MB | 同 | LRU 上限 |

---

## 13. 构建系统与补丁管理

- 顶层 `entry/src/main/cpp/CMakeLists.txt`：`XE_XENDROID_ROOT` 缓存变量 +
  `add_subdirectory(... EXCLUDE_FROM_ALL)`；C++20、仅 arm64、`XENIA_ENABLE_LTO=OFF`；
  debug 构建 `-O0 -g` 且 `debugSymbol.strip=false`（真机栈可符号化）。
- SPIR-V 预生成：OHOS SDK `glslang_validator.exe` 跑 `gen_android_spirv.py`
  （`spirv-opt/dis` 可选降级——fork 对 `compile_shader_spirv.py` 的改造），
  产物提交在 `gpu/shaders/bytecode/vulkan_spirv/`。
- 补丁存档 `patches/harmony/xendroid-ohos-fork.diff`（43 文件）+
  `glslang.diff`（InReadableOrder 递归→迭代）+ `xbyak_aarch64.diff`；
  导出前需 `git add -N` 新增文件。
- OHOS 工具链：BiSheng/Original 均 clang 15.0.4 + libc++ 15（`std::__n1`），
  C++20 仅 6 处调用点需改（fork 已改，见 fork 补丁 `string_key.h`/
  `xam_ui.cc`/`xex_module.h`/ranges→显式循环等）。

---

## 14. 与 Android 版的结构性差异

| 维度 | Android (XenDroid) | HX360E |
| --- | --- | --- |
| 进程 | 双进程（:emu 硬杀） | 单进程 + BootTeardownGuard 优雅退出 |
| 桥接 | JNI ~40 方法 | NAPI 五子对象；guest 提示改为轮询 |
| 表面 | ANativeWindow/Choreographer | surfaceId→OHNativeWindow；UI 线程 4ms 轮询循环 |
| JIT 内存 | memfd 双视图（RX/RW） | 单块匿名 RW + 每放置页对齐 W^X 翻转（内核限制，Phase 0 实测） |
| 音频 | AAudio/OpenSLES + ADPF | OHAudio（ADPF 会话代码保留但 OHOS 无 ADPF） |
| 自定义 GPU 驱动 | adrenotools/Turnip | 无，只吃 Maleoon 系统驱动（风险项） |
| 游戏获取 | 全盘扫描 | 沙箱安装（picker→拷贝） |
| 诊断 | logcat/RenderDoc | hilog + xe.log + native_fault.log + GPU 时间戳 breakdown（RenderDoc 可用） |
| 呈现实验 | — | FIFO+UI paint 已回退（8fps）、set_buffer_count 无 API、refresh_cap 强制关无效——全部留档见 PERFORMANCE.md §5 |
