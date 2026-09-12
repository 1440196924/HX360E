# HX360E 开发任务清单（TODO）

> 关联文档：[DESIGN.md](./DESIGN.md)（实施设计）、[鸿蒙移植可行性分析报告](./鸿蒙移植可行性分析报告.md)（可行性论证）、[phase0-result.md](./phase0-result.md)（Phase 0 实测）
> 最后更新：2026-09-12（**Phase 3 音频（OHAudio）接入**；**Phase 7 界面成型**：
> HDS 沉浸光感底栏新主页 + 多槽位游戏库（封面/长按系统菜单）+ 分组设置页（稀疏 TOML
> 持久化）+ 高级选项 110 项 + 子页（控制/目录/关于）；游戏页虚拟摇杆（模拟量、多点触控）、
> 调试浮层、letterbox 拉伸；
> 另修：surface 尺寸转置、MAP_FIXED 覆盖 App 映射导致的堆破坏、tab 读数把整数
> 变成 true、进游戏页的 Vulkan 探测挡住启动）

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
> 以下阶段**本阶段用 nop 或空壳占位**（实际进度见括号）：
> - Phase 3 音频 → 用 `xenia-apu-nop`（**仍未做；用户判断可能正是 guest 停在"按 Start"的原因之一**）
> - Phase 4 输入 → ~~用 `xenia-hid-nop` + `keyEvent` 空壳~~（**已提前实现**：GameControllerKit 物理手柄 + 屏幕覆盖层）
> - Phase 5 完整 NAPI → 只实现 2.5 列出的最小集（**已完成**：config / meta / prompt / content 全部原生桥接 + ArkTS 提示 UI，见 Phase 5）
> - Phase 6 安装器 → 用 picker 选文件直接启动（临时）
> - Phase 7 完整 UI → 只做 2.5 的最小页面
>
> 验收标准：**画面出现并持续呈现，FPS 可测量**。
>
> **当前实际状态（2026-09-12）**：能进游戏、画面与声音正常、手柄可用；「按 Start 卡住」已由
> **自动创建并登录默认档案**解决。Phase 3 音频已接入（OHAudio 驱动，`--apu=ohaudio`）。
> 界面层已成型：新主页（HDS `HdsTabs` 悬浮底栏 + 沉浸光感材质）、游戏库（多槽位
> `games/<id>/` + `.meta/<id>.json`，封面/名称取自 Xbox 元数据，长按走系统上下文菜单）、
> 设置（分组页 + 高级选项 ~110 项，稀疏 TOML 持久化，启动带 `--config`）。
> 已确认**拿不到 GPU 占用**：sysfs 权限被拒、`VK_KHR_performance_query` 不支持
> （`timestamps=1` 但时间戳方案需要改 fork 且收益/风险不划算，已回退）。
> 下一步见「交接快照」与里程碑表。

---

## 里程碑总览

| Phase | 目标 | 验收标志 | 预估 | 状态 |
| --- | --- | --- | --- | --- |
| **0** | 技术验证 | 5 项 spike 通过 | 2–4 周 | `[~]`（0.1 / 0.2 通过；0.3–0.5 未做） |
| **1** | 工程骨架 + 内核编译 | `libhx360e.so` 能编译、dlopen、加载 XEX | 1–1.5 人月 | `[~]`（编译/boot/加载均已跑通） |
| **2** | **图形跑通** | 游戏画面持续呈现 | 1.5–2 人月 | `[~]`（已能进入游戏画面；横屏/缩放已处理，待多机型/多游戏打磨） |
| **3** | 音频 | 有声音、无爆音 | 1 人月 | `[~]`（OHAudio 驱动已接入：48kHz/2ch/256 帧回调，实测有声；欠载恢复/格式协商待打磨） |
| **4** | 输入 | 手柄 + 触摸可操作 | 1 人月 | `[~]`（物理手柄 + 屏幕手柄：真模拟量摇杆、多点触控、按下反馈；待真手柄实测） |
| **5** | NAPI 完整桥接 | 配置 / 内容 / 提示全通 | 1 人月 | `[~]`（config/meta/prompt/content 全通；设置页已落地） |
| **6** | 安装器 + 存储 | 安装 → 游玩 → 卸载闭环 | 1–1.5 人月 | `[~]`（多槽位游戏库：文件夹安装 + 封面/标题元数据 + 长按启动/删除；进度/原子落定/空间管理待做） |
| **7** | 完整 UI | 全部页面可用 | 2–3 人月 | `[~]`（新主页/HDS 沉浸底栏/游戏库/设置/控制/目录/关于/游戏页 已成；内容管理、存档、提示完善待做） |
| **8** | 优化与发布 | 上架 | 2–4 人月 | `[ ]` |


---

## 交接快照（新 session 必读）

> 本节由原 `PROGRESS.md` 合并而来：工程布局、当前状态、已知问题与常用命令。

### A. 一句话状态

**内核已在鸿蒙真机编译、boot；Vulkan 呈现链路端到端打通；能进游戏、有声、手柄可用。**
此前整类崩溃（取指权限、guest 写权限、信号处理器、双击启动、着色器翻译爆栈、
surface 尺寸转置、`MAP_FIXED` 覆盖 App 映射导致的堆破坏）已全部修掉。
本阶段完成：**Phase 3 音频（OHAudio）**、**Phase 6 多槽位游戏库**（封面/标题元数据 +
长按菜单）、**Phase 7 界面**（HDS 沉浸光感底栏新主页、分组设置页 + 高级选项 ~110 项、
稀疏 TOML 持久化、控制/目录/关于子页）、游戏页虚拟摇杆（模拟量/多点触控）与调试浮层。
当前无阻塞性 bug；待办：内容管理/存档页面、安装进度与原子落定、手柄映射编辑、
fork 补丁在下次改动后重新导出。

### B. 工程与源码布局（关键）

| 部分 | 路径 |
| --- | --- |
| 鸿蒙工程（本仓库） | `D:\Code\ArkTs\HX360E` |
| 上游 fork（含全部 OHOS 补丁，**未提交**） | `D:\Code\OpenSource\XenDroid`（main @ `779680a`） |
| xenia 源码树 | `<fork>/emulator-core/src/main/cpp/xenia` |
| 集成方式 | `entry/src/main/cpp/CMakeLists.txt` 的 `XE_XENDROID_ROOT` 缓存变量 → `add_subdirectory(... EXCLUDE_FROM_ALL)` |
| fork 补丁存档 | `patches/harmony/xendroid-ohos-fork.diff`（xenia 源码树，43 文件）+ `patches/harmony/glslang.diff`（子模块 `third_party/glslang`）+ `patches/harmony/xbyak_aarch64.diff`（子模块）。**2026-09-12 重新导出**（见附录 D）。导出前需先 `git add -N` 那 5 个新增文件，否则 `git diff` 不含它们 |

**构建**：`build_project`（hvigor）→ `entry/build/.../libentry.so`；**增量约 7–25 秒**，
全量（首次 / 清缓存）约 10–17 分钟。debug 构建的 native 编译是 **`-O0 -g`**（见下），
顶层 CMake：`entry/src/main/cpp/CMakeLists.txt`；仅 `arm64-v8a`；`cppFlags=--std=c++20`；
`XENIA_ENABLE_LTO=OFF`；`entry/build-profile.json5` 的 debug 已设 `debugSymbol.strip=false`
（否则设备端崩溃栈没有符号名）。

**真机**：HUAWEI MateBook Pro S（2in1），Maleoon 935，Vulkan 1.3.309，HarmonyOS 6.1.1(24)。
`hdc -t 192.168.31.208:46435`；设备下载目录 `/storage/media/100/local/files/Docs/Download/`。

### C. 已完成（详见下方各 Phase）

- **Phase 0**：0.1 JIT（匿名 RW→mprotect RX）、0.2 Vulkan 表面 ✅。0.3 音频 / 0.4 GPU 能力 /
  0.5 存储 未做（决策门已由 0.1/0.2 通过）。**新结论**：memfd 双视图在本设备不可行
  （`mprotect(PROT_EXEC)` 对文件映射返回 `EACCES`，见附录 F 的探针）。
- **Phase 1**：内核编译/boot、NAPI 启动层、沙箱安装（picker→分块拷贝→启动）；
  真机跑通 Limbo（STFS/GOD）。
- **Phase 2**：2.1–2.5 实质完成（XComponent 桥接走 `attachSurface` 而非独立
  `xcomponent_bridge`；`OHOSNativeWindowSurface`、`OhosWindow`/`OhosWindowedAppContext`、
  Vulkan presenter/swapchain、最小 NAPI+UI）。**已能看到画面**（Xbox logo、游戏标题/加载画面）。
  2.6 验收未过（见 D）。
- **Phase 4（输入，提前完成基础版）**：`OhosInputDriver`（OHOS GameControllerKit 物理手柄：
  14 按键 + 5 组轴注册、摇杆死区、扳机模拟量）+ NAPI `keyEvent/padReleaseAll/padStartPhysical/
  padStopPhysical` + ArkTS 屏幕覆盖层（D-Pad/ABXY/LB·RB/LT·RT/Back·Start/L3·R3/双摇杆）。
- **Phase 5（NAPI 完整桥接，2026-09-11）**：`config` / `meta` / `prompt` / `content`
  四个子对象 + `emulator` 状态/调试方法全部实现（见 Phase 5）。guest 提示 provider 已在
  启动时安装，ArkTS 侧 150ms 轮询 + 模态弹窗应答（键盘/对话框/换盘）。
- **安装器（临时版，Phase 6 雏形）**：单槽位 `games/current/`，支持**选文件**与**选文件夹**；
  文件夹递归复制（多文件 STFS/GOD 必需），启动目标自动解析（default.xex / 有同名 `.data`
  目录的头文件 / 16–40 位十六进制 / game\*）。
- **档案**：启动时若 `content` 下无档案，自动创建默认档案 `Player` 并让 slot 0 登录
  （`logged_profile_slot_0_xuid`），解决 XBLA/GOD "no gamer profile signed in"。
- **诊断设施**：crash-safe `native_fault.log`（信号处理器内只用 `write(2)`，不丢行；下次启动
  回显到 hilog）+ 应用内「导出日志到 Download」按钮（合并 `native_fault.log` 尾 256KB 与
  `xe.log` 尾 4MB，走系统另存为）。

### D. 已知问题（当前焦点）

1. ~~**guest 停在「按 Start」**（原唯一阻塞）~~ —— **疑似已解决**：在「自动创建并登录
   默认档案」+ Phase 5 提示 provider + 多文件安装之后，拳皇13 已能正常进入游戏。此前
   guest 很可能就是在等一个 sign-in / 宿主人机交互（watchdog 报 "every fiber waiting on
   something none of them is producing"）。保留原证据备查：
   - watchdog 原话：`no guest frame presented in 2000 watchdog ticks ... Every fiber below is
     waiting on something none of them is producing`；
   - 主线程 guest `lr≈0x824EB77C` 空转，其余线程阻塞在事件上（deadline 22 / -1 / -1）；
   - `MemoryPollPark` 被 park 的循环：guest `0x82521C4C`(×60)、`0x8219FA68`、`0x821C7BD0`、
     `0x82138900`、`0x8219F9B0`、`0x821C7B18`；
   - 协作信号里周期发生的只有 host 侧 `F8000024`（by_tid=0xFFFFFFFF）与线程 `F800001C` 的
     `F8000034`。
   > 若后续又复现，再按 F 的 GPU 写回/中断方向排查。
2. **尚未实现的机制**（怀疑会影响 guest 行为）：
   - Phase 3 音频未做（`--apu=nop`）；XMA/音频时钟；
   - ~~Phase 5 的 config / 内容管理 / guest 提示轮询 NAPI 未做~~（**已完成**：见 Phase 5；
     guest 提示 provider 已在启动时安装，ArkTS 侧 150ms 轮询并弹窗应答）；
   - 部分内核导出仍是 stub。
3. **次要/待确认**：
   - `MapFileView failed: base=... prot=0x3 flags=0x11 errno=14`（1 条，需确认是否当前运行产生）；
   - `BaseHeap::AllocFixed attempting commit on unreserved page` ×3；
   - `PM4: predicated skip of sync packet opcode=46/54` ×49（多为无害）；
   - `sched_setscheduler set FIFO failed`（GPU 驱动侧，预期内，见 Q9）。
4. **临时诊断改动**（收尾时清理或明确保留）：`native_fault.log` 全套记录、`OHOS-*` 日志、
   `SIG_DFL` 上限（8 次后终止）、`fault-enter` 上限 512、翻译线程栈 32 MiB。

### E. 本轮修复清单（**重要，均已真机验证行为变化**）

> 这些是 fork 侧的改动，全部未提交到 fork，务必随补丁一起保存（附录 D）。

1. `cpu/backend/code_cache_base.h`
   - `EnsureCommitted()`：OHOS 下走 RWX 分支会把整段代码缓存重保护、抹掉已放置代码的 X →
     OHOS 下改为 no-op；
   - `PlaceGuestCode`/`PlaceData`：**每次放置从新页开始**（页对齐），保证 W→X 翻转不会摘掉
     正在被其它线程执行的页的 X（这是 `SIGSEGV SEGV_ACCERR`、ESR `EC=0x20` 取指异常的根因）；
   - OHOS 分支补一条 crash-safe 的 `OHOS-regions:` 记录（代码缓存/间接表基址）。
2. `memory.cc`
   - `PhysicalHeap::TriggerCallbacks`：`!any_watched` 且簿记说 RW 时，返回"重试"前**主动恢复
     宿主机 RW**；
   - **`host_address_offset()` 漏算（三处）**：`TriggerCallbacks` 的 unprotect 块、
     `EnableAccessCallbacksInner`（上锁侧）、read-watch 降级块。vE0000000 的
     `host_address_offset` 就是那个 **4KB 偏移**，漏算会保护/解除"错一页"，导致
     `any_watched=false` 但页确实只读 → fault 循环（`OHOS-TC-refuse guest_access=3`）；
   - `Memory::AccessViolationCallback`：`LookupHeap` 对 GPU 写回窗口 `[0x7F000000,0x80000000)`
     返回 nullptr → 信号处理器里空指针解引用；改为重定向到 `vA0000000` 别名，并把窗口自身页
     `mprotect(RW)`。
3. `base/exception_handler_posix.cc`
   - 新增 crash-safe 诊断 sink（`SetExceptionHandlerDiagnosticFd` /
     `WriteExceptionDiagnostic`，纯 `write(2)`）；
   - 兜底不再无限链式（超过上限走 `SIG_DFL`），避免无限刷平台 DFX；
   - 信号处理器路径**移除会 malloc 的 XELOG**（曾疑似造成 musl `malloc` 堆破坏）。
4. `base/logging.cc`：OHOS 是 `#elif` 分支，`#else` 的文件/标准输出 sink **根本没编译**
   → `xe.log` 一直没写（只有旧构建残留）。现补上文件 sink，`xe.log` 恢复写入。
5. `gpu/vulkan/vulkan_pipeline_cache.cc`：着色器翻译线程栈 4 MiB → **32 MiB**（`-O0` 构建帧大，
   glslang `Builder::dump` 递归遍历 CFG 会爆栈，表现为 `SEGV_MAPERR` 在
   `spv::Instruction::dump`）。
6. `xendroid_ohos/ohos_emulator.cc`
   - 所有退出路径释放 `Emulator`（它持有 4.5GB guest 地址空间；否则第二次按「启动」会在
     `Memory::Initialize()` 的 `MapViews` 上 `assert_always()` → `SIGTRAP`）；
   - `config::SetupConfig()` 提到日志初始化**之前**（否则它会把 `log_append` 覆盖回 false，
     每次 boot 截断 `xe.log`）；
   - 启动时回显上次的 `native_fault.log`。
7. 输入（新增文件）：`xendroid_ohos/ohos_input_driver.{h,cc}`；CMake 链接
   `libohgame_controller.z.so`。
8. `entry/build-profile.json5`：debug 的 `nativeLib.debugSymbol.strip = false`。
9. `kernel/xobject.cc` 的 `XObject::Wait` 主机线程路径（2026-09-11）：
   - `WaitExit()` 里 `XThread::GetCurrentThread()` 换成 `GetCurrentFiberThread()`。
     `WaitEnter` 早已用 `IsInThread()` 守卫，`WaitExit` 没有 → 在主机线程（如
     `~Emulator` → `GraphicsSystem::Shutdown` → `CommandProcessor::Shutdown`
     → `XObject::Wait`）触发 `assert_always` → `raise(SIGTRAP)`。
10. `xendroid_ohos/ohos_emulator.cc` 收尾重构（2026-09-11，**修「第二次按启动崩溃」**）：
   - 原 `EmulatorResetGuard` 只在函数返回时释放 Emulator，**早期 return（Setup /
     LaunchPath 失败）会跳过 UI 线程收尾**，留下 stale 的 window/app_context；
     第二次 Boot 在**新的 UI 线程**上 `g_app_context = ...` 会析构旧 context，
     而 `WindowedAppContext::~WindowedAppContext()` 断言 `IsInUIThread()` →
     `raise(SIGTRAP)`。
   - 改为 `BootTeardownGuard`：覆盖所有 return 路径，顺序为 ①释放 Emulator →
     ②`RequestDeferredQuit()` + join UI 线程 → ③置 `g_booting=false`（避免收尾
     未完成时重入）。
   - `window`/`app_context` 改为**在 UI 线程内销毁**（`MainLoop()` 返回后），
     满足基类析构的 `IsInUIThread()` 断言。
11. `third_party/glslang/SPIRV/InReadableOrder.cpp`（2026-09-11）：把
   `ReadableOrderTraverser::visit` 从**每块递归**改为**显式栈迭代**。`Function::dump`
   → `inReadableOrder` 的递归深度 = CFG 基本块数，大着色器会爆掉 32 MiB 翻译线程栈
   （`SIGSEGV SEGV_MAPERR` 在 `spv::Function/Block/Instruction::dump`）。迭代版保持
   原访问顺序、merge/continue 延迟与 `ReachReason` 语义。
12. 档案自动创建/登录（HX360E 侧 `ohos_emulator.cc`，2026-09-11）：`BootThread` 在创建
   Emulator 前，若 `content` 下无档案则 `CreateStandaloneProfile(content,"Player",1,103)`，
   并置 `cvars::logged_profile_slot_0_xuid`（`ProfileManager` 构造时读它登录 slot 0）。
13. 安装器重写（HX360E 侧 `Index.ets`，2026-09-11）：
   - 单槽位覆盖：安装前清空 `games/*`，写入 `games/current/`（原来按文件名分目录、不删旧，
     `restoreInstalled` 取到的旧目录顺序不定）；
   - 支持**选文件夹**（`DocumentSelectMode.FOLDER`）递归复制（多文件 STFS/GOD 必需）；
   - `fs.copyFile` 在本设备写全 0、不传 offset 的 read/write 不可靠 → 源/目标都显式
     `offset` 分块读写；
   - picker 目录 URI 不能直接喂 `listFileSync`/`statSync`（`13900002/13900019`）→
     先用 `fileUri.FileUri(uri).path` 转真实路径，URI 作兜底；
   - `mkdirSync(path,true)` 对已存在目录抛 `EEXIST(13900015)` → 统一 `ensureDir()`；
   - `resolveLaunchTarget()`：default.xex > 精确 game > 有同名 `.data` 目录的头文件
     > 16–40 位十六进制 > game\* > 递归 > 第一个文件。
14. 画面比例与窗口缩放（HX360E 侧，2026-09-11）：
   - `module.json5` 的 `EntryAbility` 加 `"orientation":"landscape"`（原来竖屏窗口
     1324×2090 → 16:9 画面比例异常）；
   - `OnSurfaceChanged` 原为空实现 → 现 `OnSurfaceResized()` 让 presenter 重新查询尺寸并
     重建 swapchain（否则放大窗口卡死）；ArkTS `tryAttach` 改为持续轮询，surface 换新 id
     时重新 `attachSurface`。

### F. 下一步（建议顺序）

1. **Phase 3 音频**（当前 `--apu=nop`）：`ohaudio_audio_driver` + 时钟对齐，见 Phase 3。
2. **打磨**：多分辨率/多次缩放窗口；验证 guest 提示弹窗（键盘/对话框/换盘）；再跑几个
   不同格式标题（ISO / XEX 目录 / 单文件 STFS / 多文件 GOD）确认安装与启动目标解析。
3. **Phase 6 正式安装器**：安装进度、`.tmp` + `rename` 原子落定、空间预检、多文件包选择、
   残留清理（现在是最简单的单槽位覆盖版）。
4. **归档** ✅（2026-09-12 已重新导出）：`patches/harmony/xendroid-ohos-fork.diff`
   （43 文件，含 `xobject.cc` / `memory_posix.cc` / `code_cache_base.h` /
   `vulkan_pipeline_cache.cc` / `surface_ohos.*`）、`patches/harmony/glslang.diff`
   （`InReadableOrder.cpp` 迭代遍历）、`patches/harmony/xbyak_aarch64.diff`。
   临时诊断日志暂时保留（D.4）。


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
> **进展（2026-09-10 后续）**：**画面已出来**（真机看到 Xbox logo 与游戏标题/加载画面）；
> 此前的整类崩溃已修完 —— 取指权限错误（代码缓存 W^X）、guest 内存写权限（
> `host_address_offset` 漏算）、glslang SPIR-V dump 爆栈、重复启动 `SIGTRAP`，详见
> 「交接快照 E. 本轮修复清单」。
>
> **待解决（唯一阻塞）**：按 Start 后 guest 不再前进 —— watchdog 报"每个 fiber 都在等没人
> 产生的东西"，主线程被 `MemoryPollPark` 停在 guest `0x82521C4C` 等轮询循环里。
> 不是崩溃，是稳定的卡住。详见「交接快照 D. 已知问题」。

### 2.1 XComponent 桥接 `[P0]` ✅（改用 surfaceId 方案）

- [x] 不新建 `xcomponent_bridge`，改为 ArkTS 侧 `XComponentController.getXComponentSurfaceId()`
      → NAPI `attachSurface(id)` → native `OH_NativeWindow_CreateNativeWindowFromSurfaceId`
      （Phase 0.2 已验证该路径比回调 `window` 参数可靠）
- [x] `OnSurfaceCreated` 等价物：`AttachSurface` 保存 `OHNativeWindow*`（`HX360E: AttachSurface: window=…`）
- [x] 尺寸：`OH_NativeWindow_NativeWindowHandleOpt(..., GET_BUFFER_GEOMETRY, ...)`（实测 `1324x2090`）
- [ ] `OnSurfaceDestroyed`：同步等待 GPU 排空后销毁 surface（前后台切换，见 2.6）
- [x] ArkTS：`XComponent({ id, type: XComponentType.SURFACE, controller })`

### 2.2 Surface 实现 `[P0]` ✅

- [x] **补丁 0006a**：`ui/surface.h` 新增 `kTypeIndex_OHOSNativeWindow`
- [x] `ui/surface_ohos.h/.cc`（fork 内）：`OHOSNativeWindowSurface : Surface` + `GetSizeImpl`

### 2.3 窗口与事件循环 `[P0]` ✅

- [x] `xendroid_ohos/ohos_window.h/.cc`：
  - [x] `OhosWindow : xe::ui::Window`（`OpenImpl` / `CreateSurfaceImpl` / `RequestPaintImpl`）
  - [x] `OhosWindowedAppContext : xe::ui::WindowedAppContext`（mutex + condvar + 待执行队列）
  - [x] `CallInUIThread()` 语义（`NotifyUILoopOfPendingFunctions`）
  - [x] `UpdateSurface()`（surface 晚到时补 `OnSurfaceChanged` + `OnActualSizeUpdate`）
- [x] `host_present_from_non_ui_thread = true`（presenter 自线程上屏，`RequestPaintImpl` 为空实现）

### 2.4 Vulkan 呈现 `[P0]`

- [x] **补丁 0006b**：`ui/vulkan/vulkan_instance.cc` 请求 `VK_OHOS_surface`；新增 `instance_ohos_surface.inc` + `ext_OHOS_surface`
- [x] **补丁 0006c**：`ui/vulkan/vulkan_presenter.cc` 新增 `kTypeIndex_OHOSNativeWindow` case → `vkCreateSurfaceOHOS` + 类型探测
- [x] CMake 加 `-DVK_USE_PLATFORM_OHOS`，链接 `xenia-gpu-vulkan` / `glslang-spirv`
- [x] 验证 swapchain 创建（真机 `1324x2090` format 37）与 presenter 连接
- [x] 验证呈现循环：**画面已出来**（Xbox logo、游戏标题/加载画面）—— 真机确认
- [ ] FPS 可测量（`emulator.lastFrameTimeMs/instantFps/averageFps` 尚未实现，见 2.5）

### 2.5 最小 NAPI 与 UI `[P0]` ✅（FPS 接口除外）

- [x] NAPI 最小集：
  - [x] `emulator.setupGamePath(path)`
  - [x] `emulator.setupLaunchArgs(args)`
  - [x] `emulator.boot()` / `pause()` / `resume()` / `quit()`
  - [x] `emulator.isRunning()` / `isPaused()`
  - [x] `emulator.deviceInfo()`（GPU / 驱动 / JIT 策略报告）
  - [x] `emulator.probeFile(path)`（镜像头识别，诊断用）
  - [x] `emulator.keyEvent(key, pressed, value)` + `padReleaseAll/padStartPhysical/padStopPhysical`
        （**Phase 4 已实现**，不再是空壳）
  - [ ] `emulator.changeSurface(w, h)`
  - [ ] `emulator.lastFrameTimeMs()` / `instantFps()` / `averageFps()`
- [x] `types/libentry/Index.d.ts` 声明
- [x] 最小 ArkTS 页面：
  - [x] 按钮 → picker 选文件（临时方案，Phase 6 换成正式安装器）
  - [x] XComponent 全屏
  - [x] 启动 / 暂停 / 退出按钮、手柄覆盖层开关、**导出日志到 Download**
  - [ ] FPS 显示（当前显示的是 Phase 0 的 `vulkanStatus()`，非内核帧率）

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

### 4.1 手柄 `[P1]` ✅ 基础完成

- [x] `xendroid_ohos/ohos_input_driver.h/.cc`（不用单独 `gamepad_ohos`）：OHOS
      `GameControllerKit`（`libohgame_controller.z.so`，API 21+）逐控件注册
      —— 14 个按键 monitor + 5 组轴 monitor（D-Pad / 左右摇杆 / 左右扳机）
- [x] 逐按键注册 → 映射表 → `InputDriver::OnKey(idx, pressed, value)`
- [x] 按 `xe_android_input_driver.cpp` 结构移植（`OhosInputDriver : xe::hid::InputDriver`，
      `EnumerateDevices()` 上报 1 个"始终存在"的手柄，让 InputSystem 自动绑定 P1）；
      摇杆带死区、扳机给模拟量（`GetState` 里 `left/right_trigger` 用模拟值）
- [x] NAPI：`emulator.keyEvent(keyIndex, pressed, value)` / `padReleaseAll` /
      `padStartPhysical` / `padStopPhysical`
- [ ] 验证 XInput 语义映射（数字键 0–15 / 模拟半轴 16–23）—— 需要真手柄 + 进游戏实测

### 4.2 触摸与虚拟手柄 `[P1]`（简化版完成）

- [x] ArkTS 屏幕覆盖层（不用 Canvas）：D-Pad / ABXY / LB·RB / LT·RT / Back·Start /
      L3·R3 / 左右摇杆 4 向，触摸 `Down/Up/Cancel` 直接驱动 `keyEvent`
- [x] `键位索引表`：ArkTS `XPadKey` 与 native `OhosPadKey`（`ohos_input_driver.h`）顺序必须一致
- [x] 覆盖层开关（`HitTestMode.None`，避免挡住下层按钮）
- [ ] 摇杆模拟量（当前是 4 向满偏近似）
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
>
> **进展（2026-09-11）**：原生桥接已全部完成并在真机验证模块可加载（无崩溃）。
> 新增文件：`napi_bridge.h`（共享辅助）、`napi_config.cc`、`napi_meta.cc`、
> `napi_prompt.cc`、`napi_content.cc`、`prompt_providers.{h,cc}`（迁移自上游
> `xe_android_*`，逻辑逐行一致）。`napi_init.cpp` 注册 `config` / `meta` /
> `prompt` / `content` 四个子对象，并给 `emulator` 加上状态/调试方法。
> ArkTS 侧 `Index.ets` 已加 150ms 提示轮询 + 模态 UI（键盘/对话框/换盘）。
>
> **待补**：ArkTS 的 `ConfigStore`/`ConfigHandle` 封装类与设置页、内容管理页
> 属 Phase 7（原生接口已就绪，见 Phase 7.1/7.2）。

### 5.1 配置 `[P1]` ✅ 原生完成

- [x] `config.open(path)` / `openString(text)` → 返回 `bigint` 句柄（失败 0）
- [x] `config.loadEntry(handle, "Section|name")` → `string | null`
- [x] `config.saveEntry(handle, tag, value)`（按值形态推断 bool/int/double/string）
- [x] `config.saveToFile(handle, path)`（保留句柄）/ `serialize(handle)`
- [x] `config.close(handle)` → 序列化 + 释放，返回 TOML 文本
- [x] `config.free(handle)` → 直接释放（不序列化）
- [x] 句柄用 `bigint` 传 C++ 指针（`toml::table*`），ArkTS 侧须配对 close/free
- [ ] ArkTS `ConfigHandle` 类 + `ConfigStore`（对应上游 `ConfigHandle.kt` /
      `ConfigStore.kt`）——归 Phase 7 设置页

### 5.2 元数据 `[P1]` ✅

- [x] `meta.titleIdFromPath(path, format)`（0=ISO / 1=XEX 目录 / 2=ZAR）
- [x] `meta.metaFromPath(path, format)` → `GameInfo | null`
- [x] `meta.metaInfoFromGodPath(path)`（STFS/GOD）→ `GameInfo | null`
- [x] DTO 用 `napi_create_object` 逐字段构造（替代 JNI `NewObject` + `SetField`）
- [x] 图标用 `ArrayBuffer` 传
- [x] 迁移上游 `extract_xex_meta`（含 SPA 有界读取、解压路径三重边界保护）
- [x] 安全：`metaFromPath` 在游戏运行中直接返回 null（避免 `xe::Memory`
      进程单例冲突；上游靠独立进程，我们靠该守卫 + 库页在未运行时扫描）

### 5.3 Guest 提示轮询 `[P1]` ✅

- [x] `prompt.keyboardRequest` / `keyboardSubmit` / `keyboardCancelAll`
- [x] `prompt.msgboxRequest` / `msgboxSubmit` / `msgboxCancelAll`
- [x] `prompt.discRequest` / `discSubmit` / `discCancelAll` / `discSetKnown`
- [x] 字符串用 UTF-16（`napi_create_string_utf16` + `xe::to_utf16/to_utf8`）
- [x] `prompt_providers.cc`：三个 host provider（自动安装于 BootThread 的
      `LaunchPath` 之前）
- [x] ArkTS 侧 150ms 轮询 + 模态 UI（键盘 TextInput / 对话框按钮 / 换盘列表 /
      取消）；退出与页面销毁时 `*CancelAll` 释放阻塞的 guest 线程

### 5.4 内容管理 `[P2]` ✅ 原生完成

- [x] `content.installContent` / `listDiscContent` / `installDiscContent`
- [x] `content.contentHeader` / `listContent` / `deleteContent`
- [x] `content.listProfiles` / `createProfile` / `renameProfile`
- [x] 进度：`installProgress` / `compressProgress` + `compressIsoToZar`
- [ ] 内容管理页面（`ContentManagerPage`）——归 Phase 7.3

### 5.5 调试与状态 `[P2]` ✅

- [x] `emulator.debugOverlayText` / `lastFrameTimeMs` / `instantFps` / `averageFps`
- [x] `emulator.showDebugOverlayEnabled` / `showTouchOverlayEnabled` /
      `setShowTouchOverlay`
- [x] `emulator.changeSurface(w, h)`
- [x] `emulator.flushGpuCaches`（当前基线无 `FlushPipelineCache`，占位）


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
| Q12 | guest 被 park 在轮询循环、按 Start 无法前进 | 2.6 | 先试 `--park_memory_poll_loops=false`；再查 GPU 写回/中断（见交接快照 F） |
| Q13 | 文件映射上的 `mprotect(PROT_EXEC)` 被拒（`EACCES`） | 2.x | 已确认：双视图方案不可行，改用单块匿名 + 页对齐（已实施） |
| Q14 | 未实现机制（audio=nop、config/content NAPI）是否影响 guest | 2.6 / 3.x / 5.x | 对照 Android（`XE_PLATFORM_xendroid` 分支在 OHOS 同样生效）逐项核对 |
| Q15 | 启动失败「游戏没运行」 | 2.6 / 6.1 | 2026-09-11 实测为**镜像文件问题**，非内核问题：① 多文件 STFS/GOD 只拷了主文件（`game`），缺 `game.data` → `STFS container is multi-file, but ... game.data does not exist`；② 非 Xbox 360 镜像（如 PS3 ISO）→ `Failed to verify disc image header: -30`、`GetFileSignature: (00000000)`。**Phase 6 安装器必须支持多文件包（整目录/全部 part）**；picker 目前单选单文件 |

## 附录 D：XenDroid fork 补丁清单（**未提交，务必保留**）

> 已存档为 `patches/harmony/xendroid-ohos-fork.diff`（36 个修改 + 5 个新增）与
> `patches/harmony/xbyak_aarch64.diff`（子模块内修复）。
>
> ⚠️ **该存档已过期**：2026-09-10 又改了一批（见 D.5），收尾时必须重新导出
> （`git -C D:\Code\OpenSource\XenDroid diff > patches/harmony/xendroid-ohos-fork.diff`）。

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

### D.5 崩溃修复 / 诊断（2026-09-10 追加，**未存档**）

> 详细原因与证据见「交接快照 E. 本轮修复清单」，这里只列改动落点。

- `cpu/backend/code_cache_base.h`：`EnsureCommitted` OHOS no-op；`PlaceGuestCode`/`PlaceData`
  **页对齐**（每次放置从新页开始）；新增 crash-safe `OHOS-regions:` 记录。
- `memory.cc`：`TriggerCallbacks` 无 watch 时强制恢复 RW；**`host_address_offset()` 补漏（3 处：
  `TriggerCallbacks` unprotect 块、`EnableAccessCallbacksInner`、read-watch 降级块）**；
  `AccessViolationCallback` 对 GPU 写回窗口 `[0x7F000000,0x80000000)` 的 `LookupHeap == nullptr`
  做重定向 + 窗口页 mprotect(RW)；新增 crash-safe 诊断记录（`OHOS-TC-hit/refuse`、
  `OHOS-forceRW`、`OHOS-AV-repeat`、`OHOS-window`）。
- `base/exception_handler_posix.cc`：新增 crash-safe 诊断 sink
  （`SetExceptionHandlerDiagnosticFd` / `WriteExceptionDiagnostic`，纯 `write(2)`）；
  兜底超过 8 次走 `SIG_DFL`；入口/兜底/链式记录（`OHOS-fault-enter` 上限 512）；
  **移除信号处理器内会 malloc 的 XELOG**。
- `base/exception_handler.h`：上述两个 sink 接口声明。
- `base/logging.cc`：OHOS 分支补回**文件 sink**（原来 `#elif` 导致 `xe.log` 从未写入）。
- `gpu/vulkan/vulkan_pipeline_cache.cc`：着色器翻译线程栈 4 MiB → **32 MiB**。
- `kernel/xobject.cc`：`WaitExit()` 用 `GetCurrentFiberThread()`（原 `GetCurrentThread()`
  在主机线程 teardown 时 `assert_always` → SIGTRAP）。
- `third_party/glslang/SPIRV/InReadableOrder.cpp`：`ReadableOrderTraverser::visit` 递归 → **显式栈迭代**
  （`Function::dump` 的 CFG 遍历按块递归，大着色器爆翻译线程栈）。
- `xendroid_ohos/`（HX360E 侧，不在 fork）：`ohos_emulator.cc` 的 BootTeardownGuard、
  档案自动创建/登录、`OnSurfaceResized`；`napi_*.cc` / `prompt_providers.*`；`Index.ets` 安装器重写。
- `entry/build-profile.json5`（HX360E 侧）：debug `nativeLib.debugSymbol.strip=false`。

> **预生成产物**（git-ignored，换机需重新生成）：
> `gpu/shaders/bytecode/vulkan_spirv/`（214 个）+ `ui/shaders/bytecode/vulkan_spirv/`（12 个），
> 用 OHOS SDK 的 `glslang_validator.exe` 跑 `gen_android_spirv.py` 生成。

## 附录 E：HX360E 侧关键文件与启动参数

```
entry/src/main/cpp/
├── CMakeLists.txt                 # 集成 xenia；XE_XENDROID_ROOT；链接 xenia-gpu-vulkan + libohgame_controller
├── napi_init.cpp                  # NAPI 模块 + XComponent 桥接 + emulator 对象（生命周期/输入/状态）+ memfd 探针
├── jit_probe.cpp/.h               # Phase 0 JIT 探测 + `RunMemfdTwoViewProbe()`
├── vulkan_context.cpp/.h          # Phase 0 呈现 spike（Phase 2 起不用于游戏画面）
├── types/libentry/Index.d.ts      # NAPI 类型声明（emulator / config / meta / prompt / content）
└── xendroid_ohos/
    ├── ohos_emulator.h/.cc        # 启动层：UI 线程 + Emulator Setup/Launch + native_fault.log + 状态/调试
    ├── ohos_window.h/.cc          # OhosWindow + OhosWindowedAppContext + OHNativeWindow surface
    ├── ohos_input_driver.h/.cc    # OhosInputDriver（GameControllerKit 物理手柄）+ OhosPadKey 索引表
    ├── napi_bridge.h              # Phase 5 NAPI 共享辅助（字符串/数组/bigint 句柄）
    ├── napi_config.cc             # Phase 5.1 TOML 配置句柄
    ├── napi_meta.cc               # Phase 5.2 镜像元数据（ISO/XEX/ZAR/STFS）
    ├── napi_prompt.cc             # Phase 5.3 guest 提示轮询
    ├── napi_content.cc            # Phase 5.4 内容管理/存档/压缩
    ├── prompt_providers.h/.cc     # Phase 5.3 host provider（迁移自上游 xe_android_*）
    ├── file_picker_ohos.cc        # FilePicker::Create 桩
    └── system_ohos.cc             # ShowSimpleMessageBox/SetProcessPriorityClass 等桩
entry/src/main/ets/pages/Index.ets # 选文件→安装到沙箱→启动；手柄覆盖层；提示弹窗；导出日志到 Download
```

启动参数（`setupLaunchArgs`）：

```
--storage_root=<filesDir>/storage
--content_root=<storage>/content
--cache_root=<storage>/cache
--gpu=vulkan        # 排查呈现问题时可临时切 --gpu=null
--apu=nop           # Phase 3 未做
--hid=nop           # 实际输入驱动由 CreateInputDrivers() 直接提供（nop 仅占位）
```

## 附录 F：常用命令

```powershell
# ---- 构建 / 运行 ----
build_project                                   # 构建（或 hvigor assembleHap）；增量约 7–25 秒
start_app --hvd "HUAWEI MateBook Pro S"         # 安装启动
hdc -t <sn> shell "aa start -a EntryAbility -b com.sddswsf.hx360e"   # 重启应用（不重装）
hdc -t <sn> shell "aa force-stop com.sddswsf.hx360e"
hdc -t <sn> shell "hilog -r"                    # 清日志后重跑（排查崩溃）

# ---- 看上游内核日志（xe.log 已恢复写入；也可直接看 hilog）----
hdc -t <sn> shell "hilog -x" | Select-String 'sddswsf.hx360e/HX360E'
# 行内 i>/w>/!> 为级别，`f:0000000 F8000008` 为函数 id + guest 线程 handle

# ---- 崩溃符号化（用未 strip 的 .so；设备端栈也已带符号）----
& "<DevEco>\sdk\default\openharmony\native\llvm\bin\llvm-addr2line.exe" -f -C -e `
  "entry\build\default\intermediates\cmake\default\obj\arm64-v8a\libentry.so" 0xADDR ...

# ---- 取"导出日志"（应用内第 4 行按钮写的文件；Download 可被 shell 读取）----
hdc -t <sn> shell "ls -t /storage/media/100/local/files/Docs/Download/ | grep hx360e-log"
hdc -t <sn> file recv "/storage/media/100/local/files/Docs/Download/hx360e-log-<ts>.txt" .

# ---- 应用内 diagnostics 记录（crash-safe，信号处理器内 write(2)）----
# native_fault.log 关键记录：OHOS-regions / OHOS-TC-hit / OHOS-TC-refuse /
# OHOS-forceRW / OHOS-AV-repeat / OHOS-window / OHOS-fault-enter / OHOS-unhandled
```

**JIT / 可执行内存探针结论（真机实测，重要）**
- 可用：匿名 `mmap(RW)` → 写 → `mprotect(PROT_READ|PROT_EXEC)` → 执行（Phase 0 策略①）。
- **不可用**：`mmap(PROT_EXEC)` 匿名（`EINVAL`，需 `MAP_EXECUTABLE`，而后者会被内核剥离 W）；
  **文件映射（memfd）上的 `mprotect(PROT_EXEC)` 返回 `EACCES`（errno 13）** ⇒ 上游"独立 RW 写视图 +
  RX 执行视图"的双视图方案在本设备**不可行**（应用内 `RunMemfdTwoViewProbe()` 每次启动都会打印
  `memfd2v: ...` 结果，可直接查看）。
