# HX360E 开发进度与交接（新 session 必读）

> 最后更新：2026-09-10
> 关联：[TODO.md](./TODO.md)（任务清单）、[DESIGN.md](./DESIGN.md)（设计）、[phase0-result.md](./phase0-result.md)（Phase 0 实测）

---

## 0. 一句话状态

**内核已在鸿蒙真机上编译、boot、并执行 guest 代码；Vulkan 呈现链路已端到端打通
（swapchain 建好、GPU 命令处理器在跑）。当前目标：解决「黑屏」与「guest 运行数秒后崩溃」。**

---

## 1. 工程与源码布局（关键）

| 部分 | 路径 |
| --- | --- |
| 鸿蒙工程（本仓库） | `D:\Code\ArkTs\HX360E` |
| 上游 fork（含全部 OHOS 补丁，**未提交**） | `D:\Code\OpenSource\XenDroid`（main @ `779680a`） |
| xenia 源码树 | `<fork>/emulator-core/src/main/cpp/xenia` |
| 集成方式 | `entry/src/main/cpp/CMakeLists.txt` 里 `XE_XENDROID_ROOT` 缓存变量指向 fork，`add_subdirectory(... EXCLUDE_FROM_ALL)` |

> ⚠️ **fork 的改动尚未纳入版本管理**（36 个文件修改 + 5 个新增）。新 session 第一件事：
> 要么提交 fork，要么导出补丁。见 §5 补丁清单。

### 构建
- `build_project`（hvigor）→ `entry/build/.../libentry.so`（含完整 xenia 内核）。
- 全量约 10–17 分钟；增量几秒。
- 顶层 CMake：`entry/src/main/cpp/CMakeLists.txt`。
- SDK：DevEco Studio（BiSheng clang 15.0.4），OHOS cmake 3.28.2。
- 目标 ABI：仅 `arm64-v8a`；`cppFlags=--std=c++20`；`XENIA_ENABLE_LTO=OFF`。

### 真机
- HUAWEI MateBook Pro S（2in1），Maleoon 935，Vulkan 1.3.309，HarmonyOS 6.1.1(24)。
- 连接：`hdc -t 192.168.31.208:46435`。
- 设备内部存储下载目录：`/storage/media/100/local/files/Docs/Download/`。

---

## 2. 已完成

### Phase 0（见 phase0-result.md）
- 0.1 JIT：✅ 可行路径 = 匿名 `mmap(RW)` → 写 → `mprotect(RX)`。
- 0.2 Vulkan 表面：✅。
- 0.3/0.4/0.5：未做（0.3 音频在 Phase 3）。

### Phase 1：编译 + boot（✅ 真机验证）
- `libentry.so` 含完整内核（base/cpu/a64/kernel/gpu/gpu-vulkan/ui/ui-vulkan/vfs/apu/hid/patcher + FFmpeg/capstone/glslang...）。
- NAPI 启动层：`emulator.setupGamePath/setupLaunchArgs/boot/pause/resume/quit/isRunning/isPaused/deviceInfo/probeFile`。
- 沙箱安装：ArkTS `@ohos.file.picker` → 分块 `readSync/writeSync` 到 `filesDir/games/<id>/game`。
  - **坑**：`fs.copyFile(fd, dest)` 在本设备上写出全 0 文件，必须自己分块读写。
- 真机跑通 Limbo（XBLA/GOD，STFS 容器）：内核 Setup 全通过 → `LaunchStfsContainer` → 创建 guest 线程 → 执行 JIT 代码。

### Phase 2：Vulkan 呈现链路（✅ 打通，画面待修）
- `VK_OHOS_surface` 扩展启用 + `vkCreateSurfaceOHOS` 加载。
- `OHOSNativeWindowSurface` / `kTypeIndex_OHOSNativeWindow`。
- `OhosWindow` + `OhosWindowedAppContext`（mutex+cv，UI 线程队列）。
- XComponent 的 `OHNativeWindow` → `napi attachSurface` → `hx360e::SetNativeWindow` → `OhosWindow`。
- presenter 连接成功、**swapchain 创建成功**（`1324x2090` format 37 present mode 1）。
- guest 已进入 GPU 命令处理器（`CP: scratch writeback`）并调用 `VdSwap`。

---

## 3. 已知问题（当前焦点）

1. **黑屏**：swapchain 建好、guest 调了 `VdSwap`，但无画面。
2. **guest 崩溃**（SIGSEGV SEGV_ACCERR，Guest CPU 0 线程）：
   - guest 读一个未映射/受保护地址后崩溃，xenia 的 exception handler 已捕获并打印
     `Access Violation: read at 0x...` / `Guest crashed at PC 0x...`。
   - 崩溃前 `GuestScheduler` watchdog：`no guest frame presented in 2000 watchdog ticks`，
     主线程在事件循环里反复 signal 事件、其余线程阻塞（疑似等 GPU/VBlank 中断）。
   - 栈：`GuestFunction::Call`（即在执行 JIT guest 代码时崩）。
   - **切换 null→vulkan GPU 后仍崩**，故不纯是 GPU 后端问题。

### 排查建议（新 session 从这里开始）
- 拿**完整 guest crash report**（guest PC/LR/寄存器/callstack）：hilog 会打印，但易被
  `XEvent`/`MemoryPollPark` 刷掉；可从 `filesDir/logs/xe.log` 或 faultlog 取。
  过滤建议：`hilog -x | grep -A60 'Guest crashed'`。
- 查 presenter 是否真的在画：`VulkanPresenter` paint 线程、`RefreshGuestOutput`、swapchain acquire/present。
- 桌面 Xenia 对照：用 `D:\Code\OpenSource\XenDroid` 桌面版跑 Limbo，判断是否上游兼容性问题。
- 关注 `VdSetGraphicsInterruptCallback` / GPU 中断是否真的被触发（guest 可能在等它）。

---

## 4. HX360E 侧新增/关键文件

```
entry/src/main/cpp/
├── CMakeLists.txt                     # 集成 xenia；XE_XENDROID_ROOT；链接 xenia-gpu-vulkan
├── napi_init.cpp                      # NAPI 模块 + XComponent 桥接 + emulator 对象
├── jit_probe.cpp/.h                   # Phase 0 JIT 探测
├── vulkan_context.cpp/.h              # Phase 0 呈现 spike（Phase 2 起不再用于游戏画面）
├── types/libentry/Index.d.ts          # NAPI 类型声明
└── xendroid_ohos/
    ├── ohos_emulator.h/.cc            # 启动层：headless→带窗口，UI 线程 + Emulator Setup/Launch
    ├── ohos_window.h/.cc              # OhosWindow + OhosWindowedAppContext + OHNativeWindow surface
    ├── file_picker_ohos.cc            # FilePicker::Create 桩
    └── system_ohos.cc                 # ShowSimpleMessageBox/SetProcessPriorityClass 等桩

entry/src/main/ets/pages/Index.ets     # 选文件→安装到沙箱→启动；扫描恢复已安装游戏
```

启动参数（ArkTS 传给 `setupLaunchArgs`）：
```
--storage_root=<filesDir>/storage
--content_root=<storage>/content
--cache_root=<storage>/cache
--gpu=vulkan        # 排查黑屏时可临时切 --gpu=null
--apu=nop
--hid=nop
```

---

## 5. XenDroid fork 补丁清单（**未提交，务必保留**）

### 5.1 CMake / 平台选择
- `xenia/CMakeLists.txt`：`XE_PLATFORM_NAME` 加 OHOS 分支。
- `cmake/XeniaHelpers.cmake`：`XE_PLATFORM_SUFFIXES` 加 `_ohos`；`xe_platform_sources`
  加 OHOS 分支（`_posix` + `_ohos`）；`xe_target_defaults` 在 OHOS 下关闭 `-Werror`。
- `xenia/src/xenia/CMakeLists.txt`：OHOS 下跳过 `apu/sdl`、`helper/sdl`、`hid/sdl`、`app`。
- `gpu/vulkan/CMakeLists.txt`、`ui/vulkan/CMakeLists.txt`：OHOS 下跳过 edge 着色器管线。
- `third_party/CMakeLists.txt`：OHOS 下跳过 SDL3 / discord / wxWidgets；zlib-ng 加 `-march=armv8-a+crc`。
- `ui/CMakeLists.txt`：OHOS 下排除 wx 文件。

### 5.2 平台 / 内存 / JIT
- `base/platform.h`：`__OHOS__` 分支（定义 `XE_PLATFORM_OHOS` + `xendroid` + `LINUX`）。
- `base/memory_posix.cc`：
  - `CreateFileMappingHandle` → `memfd_create`；
  - `IsWritableExecutableMemorySupported()` 返回 false；
  - `MapFileView` OHOS 下 exec 视图「先 RW 映射再 mprotect RX」。
- `cpu/backend/code_cache_base.h`：**OHOS 单块匿名 RW 区域 + 每次放置按页 mprotect 切换 W^X**
  （文件映射/匿名 RWX 在 OHOS 均不可行）。含 `OhosMakeWritable/OhosMakeExecutable`。
- `third_party/xbyak_aarch64/src/util_impl_linux.h`：OHOS 无 `_SC_LEVEL*_CACHE_SIZE`，加兜底。

### 5.3 图形
- `ui/surface.h`：新增 `kTypeIndex_OHOSNativeWindow` / `kTypeFlag_OHOSNativeWindow`。
- `ui/surface_ohos.h/.cc`：**新增** `OHOSNativeWindowSurface`。
- `ui/vulkan/vulkan_api.h`：OHOS 定义 `VK_USE_PLATFORM_OHOS`（非 Android）。
- `ui/vulkan/vulkan_instance.h/.cc` + `functions/instance_ohos_surface.inc`（**新增**）：
  启用 `VK_OHOS_surface` + 加载 `vkCreateSurfaceOHOS`。
- `ui/vulkan/vulkan_presenter.cc`：OHOS surface 类型探测 + `vkCreateSurfaceOHOS` case；
  排除 `surface_android.h`。

### 5.4 运行期正确性 / 日志
- `base/logging.cc`：**新增 `OhosLogSink`**（xenia 日志转发 hilog）。
- `kernel/xevent.cc`、`kernel/xobject.cc`：`RecordCreator/RecordSetter/RecordCooperativeSignal`
  改用 `GetCurrentFiberThread()`（host 线程初始化内核时 `GetCurrentThread()` 会 assert）。
- `emulator.cc`：OHOS 跳过 `/dev/shm` noexec 检查；`display_window_` 为空时跳过 UI 线程派发
  与 `SetIcon`（headless）；修 `properties_list_limit`/`stats_views_limit` 残留引用。
- `apu/nop/nop_audio_system.cc` + `nop_audio_driver.h/.cc`（**新增**）：nop 音频驱动
  （归还信号量，避免 `RegisterClient` 断言）。
- `base/string_key.h`、`kernel/xam/xam_ui.cc`、`kernel_state.cc`、`xdbf/spa_info.cc`、
  `xdbf/gpd_info_*.cc`、`ui/imgui_drawer.cc`、`ui/profile_dialogs.cc`、`cpu/xex_module.h`、
  `kernel/xam/user_property.cc`、`kernel/xam/user_settings.h`、`kernel/xam/xam_info.cc`：
  C++20 ranges / jthread / atomic_ref / clang15 结构化绑定 / AttributeKey 等兼容修复。
- `tools/build/compile_shader_spirv.py`：`glslang_validator` 兼容 + `spirv-opt/dis` 可选降级。

> **预生成产物**（git-ignored，需在换机时重新生成）：
> `gpu/shaders/bytecode/vulkan_spirv/`（214 个）+ `ui/shaders/bytecode/vulkan_spirv/`（12 个），
> 用 OHOS SDK 的 `glslang_validator.exe` 跑 `gen_android_spirv.py` 生成。

---

## 6. 下一步（建议顺序）

1. **保存 fork 补丁**（提交 fork 或导出 `patches/`）——最高优先，否则改动易丢。
2. 定位 guest 崩溃：拿完整 crash report + 桌面 Xenia 对照。
3. 定位黑屏：presenter paint / swapchain acquire / GPU 中断。
4. 之后回到 TODO：Phase 2.6 验收（画面持续呈现、FPS、前后台切换）。

---

## 7. 常用命令

```powershell
# 构建
build_project            # 或 hvigor assembleHap
# 安装启动
start_app --hvd "HUAWEI MateBook Pro S"
# 清日志后重跑（排查崩溃）
hdc -t <sn> shell "aa force-stop com.sddswsf.hx360e"
hdc -t <sn> shell "hilog -r"
# 符号化崩溃栈（用未 strip 的 .so）
& "<BiSheng>\bin\llvm-addr2line.exe" -f -C -e libentry.so 0xADDR ...
```
