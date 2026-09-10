# HX360E 开发任务清单（TODO）

> 关联文档：[DESIGN.md](./DESIGN.md)（实施设计）、[鸿蒙移植可行性分析报告](./鸿蒙移植可行性分析报告.md)（可行性论证）、[phase0-result.md](./phase0-result.md)（Phase 0 实测）
> 最后更新：2026-09-10

---

## 使用说明

### 优先级

| 标记 | 含义 |
| --- | --- |
| `[P0]` | 阻塞项，不做则后续无法推进 |
| `[P1]` | 核心功能，MVP 必须包含 |
| `[P2]` | 完整移植需要，可后置 |
| `[P3]` | 打磨项，可选 |

### 状态

- `[ ]` 未开始
- `[~]` 进行中
- `[x]` 已完成
- `[!]` 阻塞 / 待定

### 当前焦点

> **目标：先把游戏画面跑通。**
>
> 路径：**Phase 0 的 0.1（JIT）+ 0.2（Vulkan 表面）→ Phase 1（内核能编译、能启动）→ Phase 2（画面呈现）**。
>
> UI 只做最简形态：一个 XComponent 全屏 + 一个"选文件并启动"按钮 + FPS 显示。**不做**游戏库、设置、安装器、虚拟手柄等界面。
>
> 以下阶段**本阶段全部跳过**，用 nop 或空壳占位：
> - Phase 3 音频 → 用 `xenia-apu-nop`
> - Phase 4 输入 → 用 `xenia-hid-nop` + `keyEvent` 空壳
> - Phase 5 完整 NAPI → 只实现 2.5 列出的最小集
> - Phase 6 安装器 → 用 picker 选文件直接启动（临时）
> - Phase 7 完整 UI → 只做 2.5 的最小页面
>
> 验收标准：**画面出现并持续呈现，FPS 可测量**。

---

## 里程碑总览

| Phase | 目标 | 验收标志 | 预估 | 状态 |
| --- | --- | --- | --- | --- |
| **0** | 技术验证 | 5 项 spike 通过 | 2–4 周 | `[ ]` |
| **1** | 工程骨架 + 内核编译 | `libhx360e.so` 能编译、dlopen、加载 XEX | 1–1.5 人月 | `[~]` |
| **2** | **图形跑通（当前焦点）** | 游戏画面持续呈现 | 1.5–2 人月 | `[~]` |
| **3** | 音频 | 有声音、无爆音 | 1 人月 | `[ ]` |
| **4** | 输入 | 手柄 + 触摸可操作 | 1 人月 | `[ ]` |
| **5** | NAPI 完整桥接 | 配置 / 内容 / 提示全通 | 1 人月 | `[ ]` |
| **6** | 安装器 + 存储 | 安装 → 游玩 → 卸载闭环 | 1–1.5 人月 | `[ ]` |
| **7** | 完整 UI | 全部页面可用 | 2–3 人月 | `[ ]` |
| **8** | 优化与发布 | 上架 | 2–4 人月 | `[ ]` |

---

## 交接快照（新 session 必读）

> 本节由原 `PROGRESS.md` 合并而来：工程布局、当前状态、已知问题与常用命令。

### A. 一句话状态

**内核已在鸿蒙真机上编译、boot、并执行 guest 代码；Vulkan 呈现链路已端到端打通
（swapchain 建好、GPU 命令处理器在跑）。当前目标：解决「黑屏」与「guest 运行数秒后崩溃」。**

### B. 工程与源码布局（关键）

| 部分 | 路径 |
| --- | --- |
| 鸿蒙工程（本仓库） | `D:\Code\ArkTs\HX360E` |
| 上游 fork（含全部 OHOS 补丁，**未提交**） | `D:\Code\OpenSource\XenDroid`（main @ `779680a`） |
| xenia 源码树 | `<fork>/emulator-core/src/main/cpp/xenia` |
| 集成方式 | `entry/src/main/cpp/CMakeLists.txt` 的 `XE_XENDROID_ROOT` 缓存变量 → `add_subdirectory(... EXCLUDE_FROM_ALL)` |
| fork 补丁存档 | `patches/harmony/xendroid-ohos-fork.diff` + `patches/harmony/xbyak_aarch64.diff` |

**构建**：`build_project`（hvigor）→ `entry/build/.../libentry.so`；全量约 10–17 分钟，增量几秒。
顶层 CMake：`entry/src/main/cpp/CMakeLists.txt`；仅 `arm64-v8a`；`cppFlags=--std=c++20`；`XENIA_ENABLE_LTO=OFF`。

**真机**：HUAWEI MateBook Pro S（2in1），Maleoon 935，Vulkan 1.3.309，HarmonyOS 6.1.1(24)。
`hdc -t 192.168.31.208:46435`；设备下载目录 `/storage/media/100/local/files/Docs/Download/`。

### C. 已完成（详见下方各 Phase）

- **Phase 0**：0.1 JIT（匿名 RW→mprotect RX）、0.2 Vulkan 表面 ✅；0.3/0.4/0.5 未做。
- **Phase 1**：内核编译/boot、NAPI 启动层、沙箱安装（picker→分块拷贝→启动）；真机跑通 Limbo（STFS/GOD）。
- **Phase 2（进行中）**：Vulkan 呈现链路打通（`VK_OHOS_surface` + `vkCreateSurfaceOHOS` +
  `OhosWindow`/`OhosWindowedAppContext` + swapchain `1324x2090`），guest 已进入 GPU 命令处理器并调用 `VdSwap`。

### D. 已知问题（当前焦点）

1. **黑屏**：swapchain 建好、guest 调了 `VdSwap`，但无画面。
2. **guest 崩溃**（SIGSEGV SEGV_ACCERR，Guest CPU 0）：
   - xenia exception handler 已捕获并打印 `Access Violation: read at 0x...` / `Guest crashed at PC 0x...`；
   - 栈：`GuestFunction::Call`（执行 JIT guest 代码时崩）；
   - 崩溃前 watchdog：`no guest frame presented in 2000 watchdog ticks`，主线程空转、其余线程阻塞（疑似等 GPU/VBlank 中断）；
   - **切 null→vulkan GPU 后仍崩**，故不纯是 GPU 后端问题。

**排查建议**：
- 拿完整 guest crash report（PC/LR/寄存器/callstack）：`hilog -x | grep -A60 'Guest crashed'`，或从 `filesDir/logs/xe.log` / faultlog 取。
- 查 presenter 是否真在画：`VulkanPresenter` paint 线程、`RefreshGuestOutput`、swapchain acquire/present。
- 桌面 Xenia 对照：用 `D:\Code\OpenSource\XenDroid` 跑 Limbo，判断是否上游兼容性问题。
- 关注 `VdSetGraphicsInterruptCallback` / GPU 中断是否被触发。

### E. 下一步（建议顺序）

1. **保存 fork 补丁**（提交 fork 或备份 `patches/harmony/`）——最高优先。
2. 定位 guest 崩溃（完整 crash report + 桌面对照）。
3. 定位黑屏（presenter paint / swapchain / GPU 中断）。
4. 回到 Phase 2.6 验收（画面持续呈现、FPS、前后台切换）。

---

## Phase 0：技术验证

> 目标：验证 5 个"一票否决"或"高风险"的技术点。**全部在真机（Kirin 9020 或更新）上验证。**
> 决策门：0.1 的四种策略全部失败 → 项目重评。

### 0.1 JIT 可执行内存 `[P0]` ✅ **已通过**

- [x] **权限准备**（详见 [JIT-PERMISSION.md](./JIT-PERMISSION.md)）
  - [x] 已在 `module.json5` 声明 JIT 权限（3 个生效）
  - [x] ACL 权限已签名并授予（实测 `perms: ALLOW_EXECUTABLE_FORT_MEMORY=G EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY=G ALLOW_WRITABLE_CODE_MEMORY=G`）
- [x] 多策略探测代码已实现（`entry/src/main/cpp/jit_probe.cpp`）
- [x] **真机实测通过**（2026-09-08，HUAWEI MateBook Pro S / Maleoon 935）
  - [x] ⓪ BaselineRw：✅ 通过（基础 mmap 正常）
  - [x] **① AnonRwMprot：✅ 通过 ← 可用路径**
  - [x] ② FileMapRxRw：❌ `errno=13` mmap RX view
  - [ ] ③ AnonNoneExecMprot：未测（写入阶段会崩）
  - [ ] ④ AnonExecRwx：未测（内核剥离 W，写入即 SIGSEGV）
- [x] 探测方法：写入 `mov w0,#42; ret`，函数指针调用验证返回 42

**结论**：鸿蒙上 JIT 可执行内存的可行路径是

```
mmap(PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE)   // 普通 RW，可写
memcpy 写入机器码
mprotect(PROT_READ|PROT_EXEC)                      // 切 RX
执行
```

关键点：
- **不要用 `MAP_EXECUTABLE`** —— 内核会给该映射剥离 W 权限，写入即 `SIGSEGV(SEGV_ACCERR)`
- **不带 `MAP_EXECUTABLE` 的 `PROT_EXEC` 会被直接拒绝**（`EINVAL`）
- 因此必须走 `mprotect` 路径，且需要 `ALLOW_EXECUTABLE_FORT_MEMORY` 权限

- [ ] 补测：`__register_frame` / `_Unwind_Backtrace`（libunwind）是否可用
- [ ] 结论归档到 `docs/phase0-jit-result.md`

### 0.2 Vulkan 表面呈现 `[P0]` ✅ **已通过**

- [x] XComponent（SURFACE + `XComponentController`）→ `getXComponentSurfaceId()`
- [x] `OH_NativeWindow_CreateNativeWindowFromSurfaceId` 创建 `OHNativeWindow`
- [x] `vkCreateInstance` + 启用 `VK_OHOS_surface` 扩展
- [x] `vkCreateSurfaceOHOS` 创建 `VkSurfaceKHR`
- [x] 创建 device + swapchain（MAILBOX 优先、格式协商、显式 imageUsage）
- [x] 清屏并正确上屏 —— **实测 60 FPS，红/绿交替验证通过**
- [x] 独立线程渲染循环（不用 vsync 回调，避免 `fence is not pending` 警告）
- [x] 记录设备能力：`Maleoon 935 | api 1.3.309 | sparse=1 scalarBlock=1 ...`
- [ ] 备选路径验证：`VK_KHR_android_surface` 是否也可用
- [ ] 前后台切换后 surface 销毁/重建路径验证
- [x] 结论归档到 [phase0-result.md](./phase0-result.md)

**踩坑记录（关键）**：
1. **`vkCmdClearColorImage` 必须显式传 `rangeCount=1` + range** —— 传 `rangeCount=0`
   （规范允许的"清除全部"隐含语义）在 Maleoon 驱动上静默失效，且无任何报错。
2. **surface 用 `surfaceId` 路径**，不要用 XComponent 回调的 `window` 参数。
3. **渲染用独立线程**，不要用 `OH_NativeVSync` 回调。

### 0.3 OHAudio 低延迟 `[P0]`

- [ ] 最小工程：`OH_AudioStreamBuilder_Create(RENDERER)` + `AUDIOSTREAM_LATENCY_MODE_FAST`
- [ ] `OH_AudioStreamBuilder_SetRendererWriteDataCallback` 输出 440Hz 正弦波
- [ ] 验证无欠载（`OH_AudioRenderer_GetUnderflowCount`）
- [ ] 验证 `OH_AudioRenderer_GetAudioTimestampInfo` 可用于时钟对齐
- [ ] 记录：实际采样率 / 帧长 / 延迟
- [ ] 结论写入 `docs/phase0-audio-result.md`

### 0.4 Vulkan 能力探测 + 已知游戏矩阵 `[P1]`

- [x] 枚举 `VkPhysicalDeviceFeatures2` / `Vulkan11/12/13Features` 的代码已实现（`vulkan_context.cpp` Init 中，输出到日志与 `deviceInfo`）
- [ ] 真机运行后确认：`scalarBlockLayout`、`uniformBufferStandardLayout`、`shaderFloat16`、`shaderInt16`、`geometryShader`、`tessellationShader`、`dynamicRendering`、`sparseBinding`
- [ ] 枚举支持的设备扩展清单（spike 未做，后续补）
- [ ] 在桌面版 Xenia Edge（Vulkan 后端）上跑 `GAME_COMPAT.md` 中的标题（Ninja Gaiden 2、Fable II），记录基准表现
- [ ] 结论写入 `docs/phase0-gpu-capability.md`

### 0.5 沙箱安装与存储 `[P0]`

- [ ] picker 选文件 → 读头 4KB 识别格式（ISO / ZAR / GOD / XEX 目录）
- [ ] `storageStatistics.getFreeSizeSync()` 空间预检
- [ ] `fs.createReadStream` / `createWriteStream` 流式拷贝 + 进度回调
- [ ] `.tmp-<id>/` → `rename` 原子落定
- [ ] native 侧用沙箱内 POSIX 路径成功 `open` + `read` 大文件
- [ ] **关键验证**：`filesDir` 是否有空间配额？能否拷贝 >10 GB 的文件？
- [ ] 结论写入 `docs/phase0-storage-result.md`

---

## Phase 1：工程骨架与内核编译

> 目标：`libhx360e.so` 能在鸿蒙上编译链接、`dlopen`、加载 XEX 并启动内核（无画面）。
> 音频 / 输入 / 完整 NAPI 此阶段用 nop 或空壳。
>
> **进展（2026-09-09）**：xenia 内核已在 OHOS arm64 上**编译链接并打包成功**
> （`build_project` / `hvigor assembleHap`，10m32s，产物 `libentry.so` 含
> `xenia-base/cpu/cpu-backend-a64/kernel/gpu/gpu-null/ui/ui-vulkan/vfs/apu/apu-nop/hid/hid-nop/patcher`，
> 第三方 `fmt/capstone/aes_128/imgui/snappy/xxhash/pugixml/mspack/dxbc/libav*/zstd/zarchive` 全部编过）。
>
> 关键前提：
> - 源码用**本地 fork** `D:\Code\OpenSource\XenDroid`（尚未固化为 git submodule，见 1.1）。
> - SPIR-V 着色器 bytecode 用 OHOS SDK 自带的 `glslang_validator.exe` 预生成
>   （`spirv-opt`/`spirv-dis` 缺失时脚本自动降级，见 1.3）。
> - `entry/src/main/cpp/CMakeLists.txt` 通过缓存变量 `XE_XENDROID_ROOT` 指向该源码树。
>
> **进展（2026-09-10）**：已补齐 NAPI 启动层与沙箱安装（选文件 → 复制到
> `filesDir/games/<id>/` → headless `boot()`）。真机上内核 `Setup` 全通过
> （Memory/Processor/Kernel/Vulkan Maleoon 935/Audio），`LaunchPath` 已执行到
> 镜像解析；**待用真实 Xbox 360 镜像验证完整启动**。期间解决了 OHOS 特有的
> W^X 代码缓存、`/dev/shm` noexec、host 线程内核初始化断言等问题（见 1.7）。

### 1.1 仓库与上游 `[P0]`

- [~] fork `rfandango/XenDroid` 到自己的仓库（可私有）——当前用本地克隆 `D:\Code\OpenSource\XenDroid`（main @ `779680a`）
- [~] 建立 `harmony` 分支，`origin` → 上游，便于 rebase——补丁暂以工作区改动存在，未提交到 harmony 分支
- [ ] 在 HX360E 中把 `xendroid/` 作为 git submodule 挂载，锁定 commit（当前用 CMake 缓存变量 `XE_XENDROID_ROOT` 指向本地路径）
- [ ] 编写 `patches/harmony/README.md` 说明补丁管理约定（参考 DESIGN.md §3.2）
- [ ] 建立 `scripts/sync-upstream.sh`（fetch + rebase + format-patch 导出）

### 1.2 子模块裁剪 `[P0]`

- [x] 列出鸿蒙必需子模块清单（参考可行性报告 §9.3）
- [~] `git submodule update --init` 仅初始化必需项——本地 fork 已初始化编译所需子模块
- [x] 确认必需项齐全：`fmt` `Vulkan-Headers` `VMA` `SPIRV-Headers/Tools/Cross` `glslang` `xbyak_aarch64` `capstone` `boost_context` `imgui` `pugixml` `rapidjson` `tomlplusplus` `cxxopts` `utfcpp` `cereal` `half` `stb` `xxhash` `snappy` `zlib-ng` `zstd` `zarchive` `mspack` `aes_128` `dxbc` `FidelityFX-CAS/FSR` `microprofile` `disruptorplus` `date` `llvm` `asio` `libusb` `FFmpeg` `patches/xenia-canary`（FFmpeg/capstone/zstd/zarchive/aes_128 等已实际编过）
- [x] 确认**不需要**的子模块不被初始化：`wxWidgets` `MoltenVK` `DirectXShaderCompiler` `DirectX-Headers` `SDL3` `xbyak` `metal-cpp` `catch` `cpplint` `clang-format` `binutils` `discord-rpc` `renderdoc` `miniaudio`（CMake 层已在 OHOS 下跳过 SDL3/discord/wxWidgets/xbyak）

### 1.3 构建系统 `[P0]`

- [x] `entry/build-profile.json5`：
  - [x] `cppFlags`: `--std=c++14` → `--std=c++20`（已是 `--std=c++20`）
  - [x] `abiFilters`: 移除 `x86_64`，只留 `arm64-v8a`
  - [x] 确认 `nativeCompiler`（`BiSheng` 或 `Original`，二者等价）——当前 `BiSheng`
- [x] `entry/src/main/cpp/CMakeLists.txt`（顶层重写）：
  - [x] `cmake_minimum_required(VERSION 3.20)`
  - [x] `set(CMAKE_CXX_STANDARD 20)` + `set(CMAKE_CXX_STANDARD_REQUIRED ON)`
  - [x] `add_compile_definitions(OHOS=1 __OHOS__=1)`
  - [~] `add_link_options(-static-libstdc++)`——改用 OHOS 默认 libc++_shared（已链接成功）
  - [x] `add_subdirectory(xendroid)`——通过 `XE_XENDROID_ROOT` 变量 + `EXCLUDE_FROM_ALL`
  - [x] `add_library(hx360e SHARED ...)` + 链接清单——当前仍叫 `entry`（对应 `libentry.so`），链接清单见 CMakeLists
  - [x] `-Wl,--exclude-libs,ALL` 只导出 NAPI 入口
- [x] 着色器工具链：
  - [~] 确认主机有 `glslangValidator` / `spirv-opt` / `spirv-dis` / `python3`——主机无 `spirv-opt`/`spirv-dis`，改用 OHOS SDK 的 `glslang_validator.exe`，脚本降级（跳过优化与反汇编注释）
  - [x] 确认 `gen_android_spirv.py` 在 OHOS 交叉构建下正常执行——已在构建前**预生成 226 个 bytecode 头**到 `gpu/shaders/bytecode/vulkan_spirv` 与 `ui/shaders/bytecode/vulkan_spirv`
- [x] `-DXENIA_ENABLE_LTO=OFF`（默认 ThinLTO 需 lld）——CMakeLists 已 `set(XENIA_ENABLE_LTO OFF)`
- [x] 移除 `-stdlib=libc++`（OHOS 自带 libc++）

### 1.4 平台层补丁 `[P0]`

- [x] **补丁 0001**：`base/platform.h` 新增 `#elif defined(__OHOS__)` 分支，定义 `XE_PLATFORM_OHOS` + `XE_PLATFORM_xendroid` + `XE_PLATFORM_LINUX`（参考 DESIGN.md §4.1）
- [x] **补丁 0002**：`cmake/XeniaHelpers.cmake` 的 `xe_platform_sources` 新增 `OHOS` 分支（走 `_posix`）、`xe_target_defaults` 在 OHOS 下关闭 `-Werror`；`src/xenia/CMakeLists.txt` 在 OHOS 下跳过 `apu/sdl`、`helper/sdl`、`hid/sdl`、`app`；`gpu/vulkan`、`ui/vulkan` 在 OHOS 下跳过 edge 着色器管线（消费预生成 bytecode）
- [x] **补丁 0003**：`base/memory_posix.cc` 的 `ASharedMemory_create` → `memfd_create`；`IsWritableExecutableMemorySupported()` 返回 `false`（走 RW → mprotect RX）
- [x] **补丁 0004**：`__clear_cache` 相关——a64 后端已编译通过，未遇 bionic 符号
- [~] **补丁 0009**：`a64_code_cache.cc` 的 `/data/data/<pkg>/` 路径假设——待真机运行验证时处理
- [ ] **补丁 0010**：日志 sink 抽象（先保持文件日志，hilog 后置）

**额外发现的补丁（编译期，未在初版清单）**：
- `third_party/xbyak_aarch64/src/util_impl_linux.h`：OHOS 无 `_SC_LEVEL*_CACHE_SIZE`，加 `#if defined(...)` 兜底
- `ui/vulkan/vulkan_api.h`：OHOS 定义 `VK_USE_PLATFORM_OHOS`（而非 Android）
- `ui/vulkan/vulkan_instance.cc`：OHOS 下移除 adrenotools/Turnip 分支，loader 用 `libvulkan.so`
- `ui/vulkan/vulkan_presenter.cc`：OHOS 下排除 `surface_android.h` 与 Android surface case；8888 格式沿用 R8G8B8A8
- `kernel/xam/xam_info.cc`：JNI `g_jvm` 分支加 `!XE_PLATFORM_OHOS`
- `kernel/xam/user_property.cc`、`xdbf/gpd_info_profile.cc`：`AttributeKey` 强转 / const 限定修正
- `emulator.cc`、`base/string_key.h`、`kernel/xam/xam_ui.cc`、`xdbf/spa_info.cc`、`ui/imgui_drawer.cc`、`kernel_state.cc`：C++20 ranges / jthread / atomic_ref 兼容
- `ui/profile_dialogs.cc`：clang 15 不支持 lambda 捕获结构化绑定，改为普通局部变量

### 1.5 C++20 兼容 `[P0]`

> 6 个调用点，参考可行性报告 §8.5。

- [x] `base/string_key.h:78`：`std::ranges::equal` → `std::equal`
- [x] `kernel/xam/xdbf/spa_info.cc:510`：`std::ranges::find_if` → `std::find_if`
- [x] `ui/imgui_drawer.cc:739`：`std::ranges::distance` → 显式遍历（filter 手动实现）
- [x] `kernel/xam/xam_ui.cc:90`：`std::jthread` → `std::thread`（保留 `detach()`）
- [x] `kernel/xam/xam_ui.cc:157`：同上
- [x] `cpu/xex_module.h:52`：`std::atomic_ref<uint32_t>` → `__atomic_fetch_or`
- [x] 额外：`emulator.cc`（`std::views::take`）、`gpd_info_*.cc`（`std::views::filter`）、`kernel_state.cc`（`std::views::transform`）、`user_settings.h`（`AttributeKey`）

### 1.6 依赖裁剪 `[P0]`

- [x] **补丁 0007**：移除 `libadrenotools`——OHOS 下 `vulkan_instance.cc` 的 adrenotools/Turnip 分支被 `!XE_PLATFORM_OHOS` 排除，CMake 不构建该子目录
- [x] **补丁 0008**：从构建中排除 `xe_aaudio_*` / `xe_opensles_*`——这些是 emulator-core 的 xendroid 平台文件，HX360E 的 CMake 不引用
- [x] 替换为 nop 实现：音频用 `xenia-apu-nop`，输入用 `xenia-hid-nop`（已链接）
- [x] 确认 `surface_android.cc` / `file_picker_android.cc` 从源列表移除——HX360E 不使用 emulator-core 源列表
- [x] 链接库调整：移除 `android log OpenSLES aaudio adrenotools`，保留 `dl vulkan z`

### 1.7 内核启动验收 `[P0]`

- [x] `libhx360e.so` 编译链接成功——当前产物 `libentry.so`（含完整 xenia 内核），`hvigor assembleHap` 成功
- [x] 能被 `dlopen` 加载，NAPI 模块注册成功——**真机验证通过**（HUAWEI MateBook Pro S，pid 存活、XComponent `hx360e_surface` 触发 onLoad/OnSurfaceCreated、`attachSurface(...) -> 1`）
- [x] NAPI 启动层 + 沙箱安装（本轮新增）：
  - [x] `entry/src/main/cpp/xendroid_ohos/ohos_emulator.{h,cc}`：headless 启动 `xe::Emulator`
  - [x] NAPI `emulator` 对象：`setupGamePath/setupLaunchArgs/boot/pause/resume/quit/isRunning/isPaused/deviceInfo`
  - [x] ArkTS：`@ohos.file.picker` 选文件 → `fs.copyFile` 到 `filesDir/games/<id>/` → 启动时扫描恢复
  - [x] 真机验证：内核 `Setup` 全通过（Memory/Processor/Kernel/Vulkan Maleoon 935/Audio），`LaunchPath` 已执行
- [x] 能加载 XEX 并启动内核（无画面）——**真机验证通过**（Limbo / XBLA GOD）：内核 Setup 全通过 → `LaunchStfsContainer` → 创建 guest 线程（GuestScheduler）→ 执行 guest JIT 代码约 6 秒
- [~] 进入游戏主循环——guest 运行数秒后崩溃：`Access Violation: read at 0x5CB1D2A7D0`（guest 物理 ~0x1D2A7D0），xenia 已捕获并打印 guest crash report；**疑似 null GPU 后端导致**（`PM4_DRAW_INDX_2: Failed in backend` 刷屏），待 Phase 2 Vulkan 后端验证
- [x] 日志能输出到 `filesDir/logs/xe.log`——同时新增 hilog sink（`base/logging.cc`），xenia 日志可在 hilog 查看
- [~] 记录：从进程启动到内核启动的耗时、内存占用

**本轮新增 OHOS 适配补丁（超出初版清单）**：
- `kernel/xevent.cc`、`kernel/xobject.cc`：`RecordCreator/RecordSetter/RecordCooperativeSignal` 改用 `GetCurrentFiberThread()`，避免 host 线程初始化内核时的 `assert_always`
- `emulator.cc`：OHOS 跳过 `/dev/shm` noexec 检查（OHOS 用 `memfd_create`）
- `base/memory_posix.cc`：OHOS 下 exec 视图「先 RW 映射再 mprotect RX」；memfd 文件映射不可执行
- `cpu/backend/code_cache_base.h`：OHOS 用**单块匿名 RW 区域 + 每次放置按页 mprotect 切换 W^X**（文件映射/匿名 RWX 均不可行）
- `base/logging.cc`：新增 `OhosLogSink`（hilog）
- `third_party/zlib-ng`：`-march=armv8-a+crc`（`__crc32*` 内在函数）
- `xendroid_ohos/file_picker_ohos.cc`、`system_ohos.cc`：补齐 `FilePicker::Create` / `ShowSimpleMessageBox` / `SetProcessPriorityClass` 等符号

---

## Phase 2：图形跑通 ← **当前焦点**

> 目标：**游戏画面持续呈现**。UI 只做最简：一个 XComponent + 一个"选文件并启动"按钮。
> 音频 / 输入用 nop，其余 NAPI 接口留空壳。
>
> **进展（2026-09-10）**：Vulkan 呈现链路已打通（真机 Maleoon 935）：
> - `VK_OHOS_surface` 扩展启用、`vkCreateSurfaceOHOS` 加载成功
> - `OhosWindow`/`OhosWindowedAppContext` 实现，XComponent 的 `OHNativeWindow` 经
>   `attachSurface → SetNativeWindow` 接入；`OHOSNativeWindowSurface` 创建成功
> - presenter 连接、**swapchain 创建成功**（`1324x2090`，format 37，present mode 1）
> - guest 已进入 GPU 命令处理器（`CP: scratch writeback`），并调用 `VdSwap`
>
> 待解决：画面仍黑屏、guest 运行数秒后崩溃（guest 内存读违规）。watchdog 显示
> guest 主线程在事件循环里空转、其余线程阻塞——疑似 GPU 中断/VBlank 或同步语义问题。

### 2.1 XComponent 桥接 `[P0]`

- [ ] `xendroid_ohos/xcomponent_bridge.h/.cc`：
  - [ ] `napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, ...)` 拿到原生对象
  - [ ] `napi_unwrap` 取 `OH_NativeXComponent*`
  - [ ] 注册 `OH_NativeXComponent_Callback`（Created / Changed / Destroyed / DispatchTouchEvent）
  - [ ] `OnSurfaceCreated`：保存 `OHNativeWindow*`
  - [ ] `OnSurfaceChanged`：`OH_NativeXComponent_GetXComponentSize` 取宽高
  - [ ] `OnSurfaceDestroyed`：**同步**等待 GPU 排空后销毁 surface
- [ ] ArkTS 侧：`XComponent({ id, type: XComponentType.SURFACE, libraryname: 'hx360e' })`

### 2.2 Surface 实现 `[P0]`

- [ ] **补丁 0006a**：`ui/surface.h` 新增 `kTypeIndex_OHOSNativeWindow`
- [ ] `xendroid_ohos/surface_ohos.h/.cc`：`OHOSNativeWindowSurface : Surface`，实现 `GetSizeImpl`（参考上游 `surface_android.*`）

### 2.3 窗口与事件循环 `[P0]`

- [ ] `xendroid_ohos/window_ohos.h/.cc`：
  - [ ] `OhosWindow : xe::ui::Window`，实现 `OpenImpl` / `CreateSurfaceImpl` / `RequestPaintImpl`
  - [ ] `OhosWindowedAppContext : xe::ui::WindowedAppContext`，`std::mutex` + `condition_variable` + 待执行队列
  - [ ] `CallInUIThread()` 语义与上游一致（`NotifyUILoopOfPendingFunctions` 同步）
  - [ ] `surface_attach` / `surface_detach` 的编组逻辑（参考上游 `xendroid_emu.cpp:861-925`）
- [ ] 确认 `host_present_from_non_ui_thread` 的取值（上游强制 `true`，`xendroid_emu.cpp:335`）

### 2.4 Vulkan 呈现 `[P0]`

- [x] **补丁 0006b**：`ui/vulkan/vulkan_instance.cc` 请求 `VK_OHOS_surface`；新增 `instance_ohos_surface.inc` + `ext_OHOS_surface`
- [x] **补丁 0006c**：`ui/vulkan/vulkan_presenter.cc` 新增 `kTypeIndex_OHOSNativeWindow` case → `vkCreateSurfaceOHOS` + 类型探测
- [x] CMake 加 `-DVK_USE_PLATFORM_OHOS`，链接 `xenia-gpu-vulkan` / `glslang-spirv`
- [x] 验证 swapchain 创建（真机 `1324x2090` format 37）与 presenter 连接
- [ ] 验证呈现循环（guest 调用了 `VdSwap`，但画面仍黑屏，待查）

### 2.5 最小 NAPI 与 UI `[P0]`

- [ ] NAPI 最小集：
  - [ ] `emulator.setupGamePath(path)`
  - [ ] `emulator.setupLaunchArgs(args)`（含 `--storage_root` / `--config` / `--log_file`）
  - [ ] `emulator.boot()` / `pause()` / `resume()` / `quit()`
  - [ ] `emulator.isRunning()` / `isPaused()`
  - [ ] `emulator.changeSurface(w, h)`
  - [ ] `emulator.keyEvent(key, pressed, value)`（空壳，Phase 4 实现）
  - [ ] `emulator.deviceInfo()`（GPU / 驱动 / JIT 策略报告）
  - [ ] `emulator.lastFrameTimeMs()` / `instantFps()` / `averageFps()`
- [ ] `types/libhx360e/Index.d.ts` 最小声明
- [ ] 最小 ArkTS 页面：
  - [ ] 一个按钮 → picker 选文件（临时方案，Phase 6 换成正式安装器）
  - [ ] 一个 XComponent 全屏
  - [ ] 启动 / 暂停 / 退出按钮
  - [ ] FPS 显示（验证渲染在跑）

### 2.6 验收 `[P0]`

- [ ] 画面出现并可持续呈现（不是黑屏 / 不是卡住）
- [ ] FPS 可测量，记录数值
- [ ] 前台切后台再切回，surface 重建正常（不崩溃）
- [ ] 记录首帧时间
- [ ] 在 Kirin 9020 与 Kirin 9010 各测一遍

---

## Phase 3：音频

> 目标：有声音、无爆音。参考 DESIGN.md §7。

### 3.1 OHAudio 驱动 `[P1]`

- [ ] `xendroid_ohos/ohaudio_audio_driver.h/.cc`，照搬 `xe_aaudio_audio_driver.cpp`（563 行）结构
- [ ] API 映射（DESIGN.md §7.1 表）
- [ ] 保留上游三个设计：软件音量 / 欠载恢复线程 / 格式协商（FLOAT32 → S16 降级）
- [ ] `ohaudio_audio_system.h/.cc` 工厂
- [ ] 注册到 `create_audio_system`（cvar `apu` 默认改 `ohaudio`）
- [ ] 时钟对齐：`OH_AudioRenderer_GetAudioTimestampInfo`

### 3.2 验收 `[P1]`

- [ ] 游戏中能听到 BGM 与音效
- [ ] `GetUnderflowCount` 保持低位
- [ ] 前后台切换后音频恢复
- [ ] 无爆音 / 无变调

---

## Phase 4：输入

> 目标：手柄 + 触摸可操作。参考 DESIGN.md §8。

### 4.1 手柄 `[P1]`

- [ ] `xendroid_ohos/gamepad_ohos.h/.cc`：`OH_GamePad_*_RegisterButtonInputMonitor` / `RegisterAxisInputMonitor`
- [ ] 逐按键注册 → 映射表 → `InputDriver::OnKey(idx, pressed, value)`
- [ ] 复用 `xe_android_input_driver.cpp`（299 行，无 Android API 依赖），改名 `xe_ohos_input_driver.*`
- [ ] 验证 XInput 语义映射（数字键 0–15 / 模拟半轴 16–23）

### 4.2 触摸与虚拟手柄 `[P1]`

- [ ] ArkTS Canvas 虚拟手柄（对应上游 `GamepadOverlay.kt` 643 行）
- [ ] `GamepadEmitter.ets`：`emitDigital(code, pressed)` / `emitAxis(code, value)` → NAPI
- [ ] 多点触控 claim 机制、命中测试
- [ ] 布局编辑模式（对应 `GamepadEditorScreen.kt` 328 行）`[P2]`

### 4.3 按键映射 `[P1]`

- [ ] 物理键盘走 ArkUI `onKeyEvent` → NAPI
- [ ] `KeymapStore` → `@ohos.data.preferences` 重写（对应上游 `KeymapStore.kt` 60 行）
- [ ] 映射编辑界面 `[P2]`

### 4.4 振动 `[P2]`

- [ ] `libohvibrator.z.so` 接入（对应上游 `Vibrator` 用法）

### 4.5 验收 `[P1]`

- [ ] 物理手柄可操作游戏
- [ ] 触摸虚拟手柄可操作游戏
- [ ] 按键映射可自定义并持久化

---

## Phase 5：NAPI 完整桥接

> 目标：把上游约 40 个 JNI 方法全部补齐。参考 DESIGN.md §9。

### 5.1 配置 `[P1]`

- [ ] `config.open` / `close` / `loadEntry` / `saveEntry` / `saveToFile` / `free`
- [ ] 句柄用 `bigint` 传 C++ 指针，ArkTS 侧封装 `ConfigHandle` 类保证配对释放
- [ ] `ConfigStore` / `ConfigHandle` 重写（对应上游 `ConfigStore.kt` / `ConfigHandle.kt`）

### 5.2 元数据 `[P1]`

- [ ] `meta.titleIdFromPath` / `meta.metaFromPath` / `meta.metaInfoFromGodPath`
- [ ] DTO 用 `napi_create_object` 逐字段构造（替代 JNI 的 `NewObject` + `SetField`）
- [ ] 图标用 `ArrayBuffer` 传

### 5.3 Guest 提示轮询 `[P1]`

- [ ] `prompt.keyboardRequest` / `keyboardSubmit` / `keyboardCancelAll`
- [ ] `prompt.msgboxRequest` / `msgboxSubmit` / `msgboxCancelAll`
- [ ] `prompt.discRequest` / `discSubmit` / `discCancelAll` / `discSetKnown`
- [ ] 字符串用 UTF-16（`napi_create_string_utf16`），与上游一致
- [ ] ArkTS 侧 150ms 轮询（对应上游 `EmulatorHostActivity.kt:317-395`）

### 5.4 内容管理 `[P2]`

- [ ] `content.installContent` / `listDiscContent` / `installDiscContent`
- [ ] `content.contentHeader` / `listContent` / `deleteContent`
- [ ] `content.listProfiles` / `createProfile` / `renameProfile`
- [ ] 进度：`installProgress` / `compressProgress`

### 5.5 调试与状态 `[P2]`

- [ ] `emulator.debugOverlayText`
- [ ] `emulator.showDebugOverlayEnabled` / `setShowTouchOverlay`
- [ ] `emulator.flushGpuCaches`

---

## Phase 6：安装器与存储

> 目标：安装 → 游玩 → 卸载闭环。参考 DESIGN.md §10。

### 6.1 安装器 `[P1]`

- [ ] `GameInstaller`（ArkTS）：
  - [ ] picker 选文件（`DocumentSelectOptions`，支持多选）
  - [ ] 预检：读头 4KB 识别格式、读元数据、`statSync().size`、`getFreeSizeSync()` 空间检查
  - [ ] 流式拷贝 + 进度回调 → `napi` 上报或直接 ArkTS 内上报
  - [ ] `.tmp-<id>/` → `renameSync` 原子落定
  - [ ] 校验：大小比对 + 头 4KB 比对
  - [ ] 写 `install.json`
- [ ] `installId` 生成规则（titleId 优先，否则 `sha1(名+大小+mtime)`）
- [ ] 启动时清理残留 `.tmp-*`
- [ ] 中断/取消处理

### 6.2 游戏库 `[P1]`

- [ ] 扫描 `games/*/install.json` 重建索引（不建独立数据库）
- [ ] `GameLibraryPage`（对应上游 `GameLibraryScreen.kt` 606 行）
- [ ] 去重：同 titleId 提示覆盖
- [ ] 多光盘：按 titleId 分组，展开可见各盘
- [ ] 元数据缓存与图标提取

### 6.3 存储管理 `[P1]`

- [ ] `StoragePage`：空间统计（游戏 / 存档 / 缓存分类）、卸载、清理缓存
- [ ] 卸载时询问是否保留存档
- [ ] 空间不足引导（提示压缩或卸载）

### 6.4 存档导出导入 `[P1]`

- [ ] 导出：打包 `storage/content/<XUID>/<TITLEID>/` → `DocumentSaveOptions` 保存
- [ ] 导入：picker 选 zip → 解包到 `storage/content/`
- [ ] 全量备份：打包 config + content + patches
- [ ] 替代上游 `DocumentsProvider.java`（519 行）的功能

### 6.5 ZAR 压缩 `[P1]`

- [ ] `compressIsoToZar` 接入（对应上游 `GameCompressViewModel.kt` 143 行）
- [ ] 安装后提示可压缩（沙箱空间紧张，价值高于 Android 版）

### 6.6 验收 `[P1]`

- [ ] 安装 16 GB 游戏成功，进度可见
- [ ] 中断安装后可清理残留
- [ ] 卸载释放空间
- [ ] 存档可导出并重新导入

---

## Phase 7：完整 UI

> 目标：全部页面可用。参考 DESIGN.md §11。

### 7.1 P0 页面 `[P1]`

- [ ] `GameLibraryPage`（606 行对应）
- [ ] `GameInstallPage`
- [ ] `GameViewPage`（835 行对应，含覆盖层 / 暂停菜单）
- [ ] `SettingsPage`（含 `SettingsSchema` 421 行对应）
- [ ] `GamepadOverlay`（643 行对应）
- [ ] `PauseMenuPanel`

### 7.2 P1 页面 `[P1]`

- [ ] `GuestPromptPanels`（键盘 / 对话框 / 换盘）
- [ ] `ProfilesPage`（368 行对应）+ 头像选择
- [ ] `KeymapPage`
- [ ] `StoragePage`
- [ ] `CompressPage`

### 7.3 P2 页面 `[P2]`

- [ ] `ContentManagerPage`
- [ ] `GamepadEditorPage`
- [ ] `AboutPage`
- [ ] `FpsOverlay`（可拖动定位）
- [ ] `SessionLogs` 日志查看（对应上游 239 行，`logcat` → hilog）

### 7.4 应用框架 `[P1]`

- [ ] `module.json5` 声明权限
- [ ] 沉浸式全屏 / 屏幕常亮 / 方向锁定
- [ ] 状态管理（`@Observed` / `AppStorage` / `@ohos.data.preferences`）
- [ ] 手动 DI 容器（对应 `AppContainer.kt` 150 行）
- [ ] 后台保活策略（模拟器运行时的生命周期处理）

### 7.5 非移植项 `[P3]`

- [ ] 更新器（对应 `updater.kt` 281 行，Retrofit → `@kit.NetworkKit`）
- [ ] 屏幕亮度采样（对应 `ScreenBrightnessSampler.kt`，鸿蒙无 `PixelCopy` 等价，评估是否删）
- [ ] 游戏补丁界面（对应 `GamePatchesScreen.kt` 119 行）

---

## Phase 8：优化与发布

### 8.1 性能 `[P2]`

- [ ] 建立帧率基准（记录 Kirin 9020 / 9010 的典型游戏帧率）
- [ ] `driver_profile`：按 GPU 型号预设 cvar（参考 DESIGN.md §5.5）
- [ ] 调优 Adreno 导向的 cvar：`vulkan_mid_frame_submission_draws` / `vulkan_dynamic_constant_buffers` / `depth_float24_convert_in_pixel_shader` / `vulkan_shared_memory_host_visible`
- [ ] 内存占用优化（Xbox 360 模拟器内存需求高）
- [ ] 启动时间优化

### 8.2 兼容性 `[P2]`

- [ ] 建立兼容性测试矩阵（按 `GAME_COMPAT.md` 的标题）
- [ ] 区分"上游本来就有的问题"与"鸿蒙引入的问题"（用桌面 Xenia Edge 做对照）
- [ ] 输出用户可见的兼容性列表
- [ ] 崩溃上报（对应上游 `SessionLogs.kt`）

### 8.3 稳定性 `[P1]`

- [ ] 前后台切换 / 来电中断 / 分屏的健壮性
- [ ] 长时间运行的内存泄漏检查
- [ ] 设备休眠/唤醒后的恢复

### 8.4 发布 `[P2]`

- [ ] `module.json5` 权限与能力声明完备
- [ ] 应用图标 / 启动图 / 名称
- [ ] 隐私政策（模拟器类应用需说明文件访问用途）
- [ ] 上架材料：JIT 使用必要性说明、大内存说明
- [ ] 签名与打包（`hvigorw assembleApp`）

---

## 附录 A：任务统计

| Phase | 任务数 | P0 | P1 | P2/P3 |
| --- | --- | --- | --- | --- |
| 0 技术验证 | 5 组 | 4 | 1 | — |
| 1 工程骨架 | 7 组 | 7 | — | — |
| 2 图形跑通 | 6 组 | 6 | — | — |
| 3 音频 | 2 组 | — | 2 | — |
| 4 输入 | 5 组 | — | 3 | 2 |
| 5 NAPI 桥接 | 5 组 | — | 3 | 2 |
| 6 安装器存储 | 6 组 | — | 6 | — |
| 7 完整 UI | 5 组 | — | 4 | 1 |
| 8 优化发布 | 4 组 | — | 1 | 3 |

## 附录 B：关键依赖关系

```
0.1 JIT ────────┐
0.2 Vulkan 表面 ─┼──→ 1.x 内核编译 ──→ 2.x 图形跑通 ──→ 3.x 音频
0.5 沙箱存储 ────┘                          │             4.x 输入
                                            ↓
                                    5.x NAPI 桥接 ──→ 6.x 安装器 ──→ 7.x 完整 UI
                                                                        ↓
                                                                    8.x 发布
```

**关键路径**：0.1 / 0.2 → 1.x → 2.x。这三段完成前，其余工作都是可并行的旁支。

## 附录 C：未决问题追踪

| # | 问题 | 阻塞阶段 | 处理 |
| --- | --- | --- | --- |
| Q1 | JIT 四策略哪种可用 | 0.1 / 全部 | Phase 0 验证 |
| Q2 | Maleoon 兼容性与性能 | 0.4 / 2.6 | Phase 0/2 验证 |
| Q3 | `preTransform` / 竖屏旋转 | 2.4 | Phase 0.2 预判，Phase 2 处理 |
| Q4 | OHOS libunwind `__register_frame` | 1.4 | Phase 1 验证，不可用则退回上游方案 |
| Q5 | 沙箱配额 / 大文件拷贝 | 0.5 / 6.1 | Phase 0.5 验证 |
| Q6 | `persistPermission` 引用模式 | 6.x（未来） | MVP 不做 |
| Q7 | 拷贝中断残留清理 | 6.1 | 已设计 `.tmp` + 启动清理 |
| Q8 | 存档导出打包格式 | 6.4 | 建议 zip |
| Q9 | `SCHED_FIFO` 实时优先级 | 1.x | 静默降级 |
| Q10 | `/proc` 可见性 | 1.4 | 不可用则替代实现 |
| Q11 | 上架审核 | 8.4 | 提前沟通 |

## 附录 D：XenDroid fork 补丁清单（**未提交，务必保留**）

> 已存档为 `patches/harmony/xendroid-ohos-fork.diff`（36 个修改 + 5 个新增）与
> `patches/harmony/xbyak_aarch64.diff`（子模块内修复）。

### D.1 CMake / 平台选择

- `xenia/CMakeLists.txt`：`XE_PLATFORM_NAME` 加 OHOS 分支。
- `cmake/XeniaHelpers.cmake`：`XE_PLATFORM_SUFFIXES` 加 `_ohos`；`xe_platform_sources`
  加 OHOS 分支（`_posix` + `_ohos`）；`xe_target_defaults` OHOS 下关闭 `-Werror`。
- `xenia/src/xenia/CMakeLists.txt`：OHOS 下跳过 `apu/sdl`、`helper/sdl`、`hid/sdl`、`app`。
- `gpu/vulkan/CMakeLists.txt`、`ui/vulkan/CMakeLists.txt`：OHOS 下跳过 edge 着色器管线。
- `third_party/CMakeLists.txt`：OHOS 下跳过 SDL3 / discord / wxWidgets；zlib-ng 加 `-march=armv8-a+crc`。
- `ui/CMakeLists.txt`：OHOS 下排除 wx 文件。

### D.2 平台 / 内存 / JIT

- `base/platform.h`：`__OHOS__` 分支（定义 `XE_PLATFORM_OHOS` + `xendroid` + `LINUX`）。
- `base/memory_posix.cc`：`CreateFileMappingHandle` → `memfd_create`；
  `IsWritableExecutableMemorySupported()` 返回 false；`MapFileView` OHOS 下 exec 视图「先 RW 再 mprotect RX」。
- `cpu/backend/code_cache_base.h`：OHOS **单块匿名 RW 区域 + 每次放置按页 mprotect 切换 W^X**
  （文件映射/匿名 RWX 在 OHOS 均不可行），含 `OhosMakeWritable/OhosMakeExecutable`。
- `third_party/xbyak_aarch64/src/util_impl_linux.h`：OHOS 无 `_SC_LEVEL*_CACHE_SIZE`，加兜底。

### D.3 图形

- `ui/surface.h`：新增 `kTypeIndex_OHOSNativeWindow` / `kTypeFlag_OHOSNativeWindow`。
- `ui/surface_ohos.h/.cc`（**新增**）：`OHOSNativeWindowSurface`。
- `ui/vulkan/vulkan_api.h`：OHOS 定义 `VK_USE_PLATFORM_OHOS`（非 Android）。
- `ui/vulkan/vulkan_instance.h/.cc` + `functions/instance_ohos_surface.inc`（**新增**）：
  启用 `VK_OHOS_surface` + 加载 `vkCreateSurfaceOHOS`。
- `ui/vulkan/vulkan_presenter.cc`：OHOS surface 类型探测 + `vkCreateSurfaceOHOS` case。

### D.4 运行期正确性 / 日志

- `base/logging.cc`：**新增 `OhosLogSink`**（xenia 日志转发 hilog）。
- `kernel/xevent.cc`、`kernel/xobject.cc`：`RecordCreator/RecordSetter/RecordCooperativeSignal`
  改用 `GetCurrentFiberThread()`（host 线程初始化内核时 `GetCurrentThread()` 会 assert）。
- `emulator.cc`：OHOS 跳过 `/dev/shm` noexec 检查；`display_window_` 为空时跳过 UI 线程派发
  与 `SetIcon`（headless）；修 `properties_list_limit`/`stats_views_limit` 残留引用。
- `apu/nop/nop_audio_system.cc` + `nop_audio_driver.h/.cc`（**新增**）：nop 音频驱动（归还信号量，
  避免 `RegisterClient` 断言）。
- 兼容修复：`base/string_key.h`、`kernel/xam/xam_ui.cc`、`kernel_state.cc`、`xdbf/spa_info.cc`、
  `xdbf/gpd_info_*.cc`、`ui/imgui_drawer.cc`、`ui/profile_dialogs.cc`、`cpu/xex_module.h`、
  `kernel/xam/user_property.cc`、`kernel/xam/user_settings.h`、`kernel/xam/xam_info.cc`
  （C++20 ranges / jthread / atomic_ref / clang15 结构化绑定 / AttributeKey 等）。
- `tools/build/compile_shader_spirv.py`：`glslang_validator` 兼容 + `spirv-opt/dis` 可选降级。

> **预生成产物**（git-ignored，换机需重新生成）：
> `gpu/shaders/bytecode/vulkan_spirv/`（214 个）+ `ui/shaders/bytecode/vulkan_spirv/`（12 个），
> 用 OHOS SDK 的 `glslang_validator.exe` 跑 `gen_android_spirv.py` 生成。

## 附录 E：HX360E 侧关键文件与启动参数

```
entry/src/main/cpp/
├── CMakeLists.txt                 # 集成 xenia；XE_XENDROID_ROOT；链接 xenia-gpu-vulkan
├── napi_init.cpp                  # NAPI 模块 + XComponent 桥接 + emulator 对象
├── jit_probe.cpp/.h               # Phase 0 JIT 探测
├── vulkan_context.cpp/.h          # Phase 0 呈现 spike（Phase 2 起不用于游戏画面）
├── types/libentry/Index.d.ts      # NAPI 类型声明
└── xendroid_ohos/
    ├── ohos_emulator.h/.cc        # 启动层：UI 线程 + Emulator Setup/Launch
    ├── ohos_window.h/.cc          # OhosWindow + OhosWindowedAppContext + OHNativeWindow surface
    ├── file_picker_ohos.cc        # FilePicker::Create 桩
    └── system_ohos.cc             # ShowSimpleMessageBox/SetProcessPriorityClass 等桩
entry/src/main/ets/pages/Index.ets # 选文件→安装到沙箱→启动；扫描恢复已安装游戏
```

启动参数（`setupLaunchArgs`）：

```
--storage_root=<filesDir>/storage
--content_root=<storage>/content
--cache_root=<storage>/cache
--gpu=vulkan        # 排查黑屏时可临时切 --gpu=null
--apu=nop
--hid=nop
```

## 附录 F：常用命令

```powershell
build_project                                   # 构建（或 hvigor assembleHap）
start_app --hvd "HUAWEI MateBook Pro S"         # 安装启动
hdc -t <sn> shell "aa force-stop com.sddswsf.hx360e"
hdc -t <sn> shell "hilog -r"                    # 清日志后重跑（排查崩溃）
& "<BiSheng>\bin\llvm-addr2line.exe" -f -C -e libentry.so 0xADDR ...   # 符号化崩溃栈
```
