# HX360E 内核性能优化报告（代码级修改方案）

| 项目 | 内容 |
| --- | --- |
| 版本 | v1.0 — 2026-09-13 |
| 范围 | **内核代码本身的修改**（非配置开关）。配置级快速项见 [PERFORMANCE.md](./PERFORMANCE.md)，两份文档互补：本文回答"内核模拟效率低在哪、改哪些代码、怎么改"。 |
| 依据 | 逐行阅读：PM4 命令处理器全链（`command_processor.cc` + `pm4_command_processor_implement.h`）、Vulkan 后端全部核心文件、`SpirvShaderTranslator` 取数路径、共享内存一致性协议、`PhysicalHeap` 写监视、A64 JIT 发射与代码缓存、guest 调度器、全局锁结构。所有结论附 `file:line`。 |
| 瓶颈判定 | GPU 侧为主（半分辨率带来 15→30fps 的近线性收益 ⇒ fragment/带宽受限）。CPU 侧问题集中在**翻译时刻的 W^X 税**与**单把全局锁**。 |

---

## 0. 结论摘要（按 预期收益/成本 排序）

| # | 修改点 | 层 | 预期收益 | 成本 | 风险 |
| --- | --- | --- | --- | --- | --- |
| K1 | 直读 resolve 的 den 适配修复并重新启用 | GPU | 高（每 resolve 省一次全带宽 dump pass + GMEM store） | 中 | 中（画面正确性） |
| K2 | **顶点取数特化/本地化**（SSBO 虚拟化的两条替换路径） | GPU | 高（顶点密集场景 VS ALU 与带宽大幅下降） | 中-高 | 中 |
| K3 | MakeCoherent 精确失效（实现 benvanik 的 TODO） | GPU/CPU | 中-高（故障风暴 → 定向失效） | 中 | 中（兼容性需矩阵验证） |
| K4 | 写监视武装的块级快路径 | CPU | 中（该循环被 profiling 标注过热点） | 低 | 低 |
| K5 | JIT W^X 批量放置 | CPU | 中（翻译风暴期放置税 ÷N） | 中 | 中（崩溃高发区） |
| K6 | `gpu_stall_spin_iterations` ARM64 平台默认值 | CPU | 低-中（白烧核 → 让核给渲染/派发线程） | 极低 | 低 |
| K7 | RequestRange/失效的批量加锁（全局锁切分第一步） | CPU | 中（锁竞争画像后定） | 中 | 中 |
| K8 | `a64_perf_map` OHOS 默认关 | CPU | 低（每放置一次 fflush 消失） | 极低 | 无 |
| K9 | write-watch 诊断 snprintf 总开关 | CPU | 低（前 N 次故障路径 µs 级 ×N） | 极低 | 无 |
| K10 | swap 后处理链合并（gamma/FSR/XEG） | GPU | 低-中（每帧省 1-2 个全屏 pass） | 中 | 中（画质） |
| K11 | DeferredCommandBuffer 直录快路径 | CPU | 低（命令流双过消除） | 高 | 中 |
| K12 | 索引/顶点一致性失效粒度收紧 | GPU/CPU | 低-中 | 中 | 中 |

> K1 的开关现状与 K2/K3 的具体设计是本文核心；K4-K9 是低风险"落袋"项。

---

## 1. 顶点取数虚拟化：最大的结构性 GPU 成本（K2）

### 1.1 现状与证据

本后端**完全不使用原生顶点缓冲**：

- 客体 draw 永远不调 `vkCmdBindVertexBuffers`（全后端唯一调用点是 transfer
  全屏矩形，`vulkan_render_target_cache.cc:8226`）；
- 管线的 `VkPipelineVertexInputStateCreateInfo` 恒为空
  （`vulkan_pipeline_cache.cc:2309-2310, 2774`）；
- 每个顶点属性由**顶点着色器里的代码**从共享内存 SSBO 取：
  `SpirvShaderTranslator::ProcessVertexFetchInstruction`
  （`spirv_shader_translator_fetch.cc:28+`）。

每个属性每顶点的着色器成本（翻译产物）：

```
读 fetch 常量 UBO 两次（word0 基址 + word1 大小/端序）
→ 基址移位、stride×索引（含 floor/round-to-nearest 转换）
→ 末界计算并存 vfetch_bound 变量
→ 边界检查（越界读 0，硬件语义）
→ SSBO 载入 1-4 个 dword
→ GpuSwap 端序翻转
→ 格式解包（8/16bit 归一化、10-10-10、snorm…）
→ swizzle 分量
```

 Xbox 360 游戏典型每顶点 8-12 个属性（position + 2×texcoord + normal +
tangent + color + skinning…），120 万顶点/秒的 30fps 场景意味着**每秒上千万次
上述序列**，全部落在 VS 的 ALU/UBO/SSBO 带宽上。tile GPU 的 VS 吞吐恰是
Maleoon 这类移动 GPU 的相对短板。

### 1.2 修改方案 A（推荐先做）：fetch 常量特化（spec constant / 常量烘焙）

**思路**：绝大多数游戏在关卡开始后 fetch 常量（基址/stride/格式/端序）长期不变，
变得每帧重画的只有顶点数据内容。把"不变的常量"从每顶点的 UBO 读取变成
**特化常量（specialization constant）**，驱动会在管线编译时折叠全部地址运算，
每顶点只剩"索引×stride（仍然动态，因为是 gl_VertexIndex）+ SSBO 载入 + 端序/解包"
——UBO 依赖和边界计算链被编译期消掉。

**实现落点**：

1. `VulkanCommandProcessor::IssueDraw`：为每个使用中的 fetch 槽维护
   `<值哈希, 连续未变提交数>`；连续 K（如 120）个提交未变 → 标记该槽"可特化"，
   把 96 个 vfetch 常量（768B）放进 `VkSpecializationInfo`。
2. `SpirvShaderTranslator`：Modification 位域加一位 `fetch_specialized`；
   特化路径下 `ProcessVertexFetchInstruction` 改从 spec constant 数组取
   word0/word1（`builder_` 已有 spec constant 设施，system constants 同构）。
3. 常量变化时（`WriteFetchFromMem` 的 slot_changed 已有精确槽位跟踪，
   `vulkan_command_processor.cc:1996-2054`）：把该槽的位图喂给
   `texture_bindings_changed` 同款机制 → 异步重翻译受影响着色器（管线缓存已有
   异步模型），过渡期用未特化变体渲染。
4. 变体数量控制：只做"全特化/全不特化"两档（per-槽特化会让变体爆炸）。

**收益预估**：每顶点每属性省 ~8-12 条 ALU + 2 次 UBO 访问；VS 受限的 pass
（`VkPassTime` 分桶可辨识）预期 10-30%。**验证**：`log_gpu_frame_time_breakdown`
的 VS-heavy bucket 对比 + shader_profiling（`shader_profiling=true` 已有
SPIR-V 字节数对比）。

**风险**：重翻译风暴（变化窗口期）；边界语义必须逐位保持（越界读 0）。
工作量：约 300-500 行，全部在 fork 已有机制（Modification、异步重翻译、
pipeline storage 版本号 `kVersion` 递增）的延长线上。

### 1.3 修改方案 B（结构级，二期）：宿主顶点缓冲转换缓存

**思路**：把顶点数据在 CPU 侧（NEON，`primitive_processor.cc` 已有同类
索引转换基础设施）预转换成原生 `VkVertexBuffer`，着色器回到硬件属性取数。
缓存键 = `<base_page, size, stride, format 序列, 端序>`，内容变化由
写监视（已有）失效。收益是 VS 里整个虚拟取数层消失；代价是 CPU 转换带宽与
内存占用。

**为什么放二期**：A 方案拿到大部分收益的 70% 而复杂度只有 1/3；B 需要
上传预算管理、假共享页失效策略、大缓冲分块，且与半分辨率/特化路径的
着色器 Modification 组合空间需要收敛（B 直接用无 vfetch 代码的变体）。
**决策判据**：A 落地后若 `VkPassTime` 仍显示 VS-bound 且顶点吞吐是帧时间
主导项，再上 B。

---

## 2. Resolve 链：K1（直读路径修复）+ K3（精确失效）

### 2.1 K1：`vulkan_direct_host_resolve` 的 den 适配

现状：HX360E 强制 `--vulkan_direct_host_resolve=false`
（`Home.ets:380`，"标题层会缩到左上角 1/4"）。fork 里 dump 路径已做 den 回算
（`GetDumpPipeline` 的目的坐标 ÷den，`vulkan_render_target_cache.cc:8820+`），
但直读着色器族（`resolve_host_color_*`，共 2 bpp×3 msaa×2 scaled×2 uint
= 24 个 + full 60 个）的**源采样坐标**没有按 `1/scale × 1/den` 复合缩放——
半分辨率下源纹理是 guest/2 尺寸，直读着色器却按 native 采样。

**修改**：直读着色器的常量打包里已传 `dump_pitch/base`（`TryDirectHostResolveCopy`
的 `constants.` 系列），增加一对 `source_den_x/y` push constant，在源 UV 计算处
乘 `guest_to_host_uv = draw_resolution_scale / den`（与 dump 路径的
`tile_size = (is_64bpp?40:80)*scale/den` 完全同一套坐标约定，
`vulkan_render_target_cache.cc:2491-2530` 已是现成参考实现）。MSAA 变体里
采样索引选择不受 den 影响（样本数不变），只动平面坐标。

**验证**：`--vulkan_direct_host_resolve=true` + den=2 跑目标标题，标题层/全屏
quad 位置正确后，用 `VkInPass`/`log_resolve_details` 看直读占比与
`resolve_gpu_ns` 下降。**预期**：resolve 是每帧 1-5 次的全带宽操作，
省掉的 dump pass 在 tile GPU 上还附带一次 GMEM store/restore。

### 2.2 K3：MakeCoherent 是空实现——把它变成精确失效

现状：guest 通过 `COHER_STATUS_HOST`（VC/TC flush）请求区间一致性时，
`CommandProcessor::MakeCoherent` **只打日志并清状态位**（`command_processor.cc`
的 `// TODO(benvanik): notify resource cache of base->size and type.`）。
所有 CPU→GPU 可见性目前完全依赖写监视 fault：

```
guest 写 GPU 可见页 → SIGSEGV → ucontext 保存 → 双层 handler
→ 全局锁 → 位扫描 → mprotect(RW) → 失效回调 → 页标脏 → 下次重传
```

这个协议对"游戏不通知、直接写"的场景是必需的（语义兜底），但对**规范使用
TC/VC flush 的游戏**（X360 D3D 驱动的标准路径）是双重付费：guest 明明告诉了
精确区间，我们却靠页粒度 fault 逐个发现。

**修改**：

1. `MakeCoherent()` 实现区间通知：
   `shared_memory_->MemoryInvalidationCallback(base, size, /*exact=*/true)`
   （该函数已是 public 语义完整的失效入口，`gpu/shared_memory.cc:695`）；
2. 配合**监视窄化**：对"guest 已正确使用 COHER 协议"的堆区间，不再 arm 写监视
   （`MakeRangeValid` 的 `EnablePhysicalMemoryAccessCallbacks` 增加按堆区间的
   例外位图）。判据：MakeCoherent 命中率统计——启动后前 N 次 flush 覆盖的
   区间与后续 fault 失效区间的重合率 > 阈值（如 95%）则对该区间关 fault。
3. 保守起步：第一期只做 1（通知），不动 2——零行为风险，因为 fault 路径
   依然全部保留，通知只是让失效提前发生（下次 RequestRange 不用等 fault）。

**收益**：fault 风暴型标题（写监视密集的流式纹理/动态顶点）的 CPU 侧失效成本
显著下降；配合 zero-copy 形态时收益缩小（无重传，仅缓存标脏）——所以先做
PERFORMANCE.md P0-2 的形态确认再定 K3 投入。

**风险**：COHER 寄存器的 VC/TC 语义注释本就不完整（R6xx 文档推断，
`MakeCoherent` 头部注释）；个别游戏可能对区间说谎。防御：通知 + fault 双轨
（通知不做窄化就无风险），统计跑一周真机再决定窄化。

---

## 3. 共享内存与写监视的三个低风险内核修改（K4/K7/K12）

### 3.1 K4：`EnableAccessCallbacksInner` 块级快路径

现状：`memory.cc:2293-2295` 有原作者注释："a lot of time is spent in this loop…
profiling shows quite a bit of time spent in this loop, but very little spent
actually calling Protect"。循环逐页（最多数千页）做：页表读 + guest 访问位判断 +
64 位块标志置位 + 偶尔 mprotect。**重复武装**（GPU 每次 Resolve/纹理装载后重新
arm 已解锁的同一批页）是典型场景——此时几乎所有页都已带 watch 位，
循环却在逐页重走。

**修改**：循环外增加 64 页块的预检：

```cpp
// 块内全部已 notify_on_invalidation 且 guest 可写 → 整块跳过
uint64_t block_bits = sys_page_flags[i >> 6].notify_on_invalidation;
if (~(block_bits >> (first&63)) == 0 /*覆盖本段*/) continue; // 无需逐页
```

准确说：先把 `[system_page_first, system_page_last]` 与 64 位块对齐切三段
（头/整块/尾），整块段用块掩码判断"已全部武装且 SystemPageGuestAccess==RW"
（后者需要一个块级缓存：每块 1 字节记录"全块可写"的缓存态，在 Protect/解除时
失效）——实现约 60 行，行为不变。

**验证**：native_fault.log 的 `OHOS-TC-hit` 频率不变（行为等价性）+
简单 perf：武装调用耗时（可临时加 SCOPE_profile 计数）。

### 3.2 K7：全局锁的画像与切分

现状：`global_critical_region::mutex()` 是**进程单例**
（`base/mutex.h:259-270`，`memory.h`/`gpu/shared_memory.h` 里的成员都只是
 façade）。同一把递归锁串行化了：内存页保护、共享内存页标志、**JIT 代码缓存
放置**、EntryTable 函数查找、纹理/RT 缓存的失效回调。6 条 guest 派发线程 +
GPU 线程 + 4 条着色器翻译线程 + I/O 线程的任何交叉都会在这里排队。翻译风暴期
（K5 相关）与纹理流送期的冲突最严重。

**修改（分两步）**：

1. **先画像**：`global_critical_region::Acquire` 加一个可选的持锁时长采样
   （每 256 次采样一次 max-hold，写进 frame_stats）——一个下午的工作，
   量化"锁上到底浪费了多少"；
2. **再切分**：共享内存的页标志位图（`system_page_flags_*` 三个数组）与
   GPU 侧失效回调可以迁到**独立的自旋/互斥锁**：它不保护 JIT/页表结构，
   只保护自己的位图一致性。回调链（FireWatches → 纹理缓存失效）需要声明
   "持共享内存锁时不再取全局锁"（现有代码已是这个顺序，天然满足反向锁序）。
   EntryTable 与代码缓存维持全局锁（正确性关键）。

**预期**：多线程干扰型卡顿（转场加载、新关卡）削减；稳态帧内影响小。
**风险**：锁序回归——必须以"共享内存锁 → 全局锁"单向为不变式写注释与断言。

### 3.3 K12：失效范围与上传的合并

现状两处可收紧：

- `SharedMemory::MemoryInvalidationCallback` 的 256KB 外扩
  （`gpu/shared_memory.cc:710-733`）以 CPU 故障换上传带宽——在**零拷贝形态**
  （无上传成本）下这个外扩是纯负收益（把本来无关的纹理一起标脏，触发多余的
  解块重跑）。**修改**：外扩逻辑按 `zero_copy_` 分支禁用（一行级）。
- `IssueDraw` 的 vfetch `RequestRange` 已做批量持锁
  （`vulkan_command_processor.cc:4595-4608`），但 resolve 目的区间、纹理
  base/mips 的 RequestRange 仍是逐次获取全局锁——把它们收进同一个
  hoisted-lock 块（模式照抄 vfetch 处）。

---

## 4. JIT 后端（K5/K6/K8/K9）

### 4.1 K5：W^X 批量放置

现状（OHOS 特有路径，`code_cache_base.h` fork 补丁）：每函数放置 =
页对齐（平均浪费半页）→ `mprotect(RW)` → memcpy → `mprotect(RX)` →
`__builtin___clear_cache`，全程持全局锁（§3.2）。单函数固定税 ~2-10µs。
翻译风暴期（新关卡、着色器密集标题首跑）每秒数百次放置 = 毫秒级/秒的全局锁占用
+ TLB shootdown 风暴。

**修改**：引入放置批次（translation batch）：

```
翻译线程每编译完一批（如 16 个函数 / 64KB）：
  1. 在临时 RW 暂存区汇编（A64Emitter 已是暂存缓冲模型，天然支持）
  2. OhosMakeWritable(代码区目标段, 批量总长)   ← 1 次
  3. 逐函数 memcpy + PlaceCode（eh_frame 注册不变）
  4. OhosMakeExecutable(批量总长) + FlushCodeRange(批量)  ← 各 1 次
  5. 逐函数更新间接表槽位（槽位更新本来就是锁外原子写）
```

落点：`Processor::ResolveFunction` 的单函数路径保留为回退；
`A64Backend::CommitExecutableRange` 批量化。批量边界必须整页对齐（现状的
页对齐不变式保留在批次边界）。**页对齐浪费同时消失**（批内连续布置，
4KB/16 函数 → 浪费从 ~50% 降到 ~3%）。

**收益**：翻译风暴期放置系统调用数 ÷16、全局锁持有时长 ÷约 10；
对"进关卡瞬间掉帧"类卡顿直接有效。**风险**：这是取指崩溃的高发区
（fork 在这里修过 SEGV_ACCERR），需要真机回归矩阵；建议做成 cvar
`a64_batch_placement` 灰度。

### 4.2 K6：ARM64 自旋默认值（一行）

`gpu_stall_spin_iterations=32` 的 cvar 描述自己写着："on ARM64 the yield is a
WFE that does not actually park on a busy SoC, so every iteration burns a core
at full clock"（`command_processor.cc:45-54`）。GPU 空闲期（30fps 游戏的
vblank 等待、加载）每帧最多 32×N 次满核空转。**修改**：OHOS/ARM64 分支默认 4
（保留少量自旋躲唤醒延迟；0 立即 park 也是安全的——事件由
`UpdateWritePointer` 的 `SetBoostPriority` 触发，无丢唤醒窗口）。设置页已暴露
该项（`SettingsSchema.ets:215`）。

### 4.3 K8/K9：两个零风险减法

- `a64_perf_map=true`（`a64_code_cache.cc:30`）：每次函数放置写
  `perf-<pid>.map` 并 `fflush`。OHOS 上无 simpleperf 用例 → 平台分支默认 false。
- write-watch 诊断（`OHOS-fault-enter` ≤512、`OHOS-TC-hit` ≤512、
  `OHOS-forceRW` ≤128 等，`memory.cc`/`exception_handler_posix.cc` fork 补丁）：
  信号/热路径上的 `snprintf+write(2)`，前 N 次每次 µs 级。加一个
  `ohos_diag_verbose` cvar 总开关（默认 false，只保留 `OHOS-regions` 与
  崩溃必需记录）。

---

## 5. 呈现链（K10）与命令录制（K11）

### 5.1 K10：swap 后处理链合并

现状每次 swap 的全屏操作序列（`vulkan_command_processor.cc:2226-2887`）：
gamma compute（或 gamma+FXAA luma 合并版）→ [FXAA compute] → guest 输出图
→ presenter flow（bilinear / CAS / FSR-EASU+RCAS 两 pass / XEG 替代段）
→ letterbox clear render pass → present。**每帧固定 3-6 个全屏 pass**。

**修改（按性价比）**：

1. gamma → presenter 首段合并：gamma ramp 是 256 项 LUT，EASU/bilinear 首段
   采样后过 LUT 再输出，省整帧一次纹理写入+读取（1280×720×4B×2 = 7MB/帧带宽）。
   落点：`VulkanPresenter` 的 guest output flow 增加一个
   `kGammaInFirstPass` 效果位；PWL/表两种 LUT 用纹理数组采样实现。
   注意 FXAA luma 需要线性域——FXAA 开启时不合并。
2. letterbox clear 并入首段 render pass 的 `clearRect`（API 已支持多 clear
   rect；`present_render_pass_clear=true` 只清全屏）。
3. XEG 路径：输出图直接建成窗口尺寸（省第二段 bilinear）——已在
   PERFORMANCE.md P1-10，此处不重复。

**预期**：每帧省 1-2 个全屏 pass（30fps 下 ≈0.3-0.8ms GPU）；对 60fps 冲刺
场景价值更大。

### 5.2 K11：DeferredCommandBuffer 直录快路径（诚实评估：暂缓）

所有 Vulkan 命令先录 arena、提交时回放（`deferred_command_buffer.h`）。
这是为"异步管线完成前可整体重放/丢弃"与"barrier 需要重排 render pass 边界"
服务的。直录快路径（无未决管线时直接录 primary）能省一次命令流 memcpy+回放
分支，但要把 ~60 个 Cmd* 调用点改成双后端。**结论**：CPU 收益在 µs 级/帧，
工程量与回归面大，放在 K1/K2 收益兑现之后再评估。记录于此是为了闭环——
它是"每 draw CPU 开销"里最后一个结构性项。

---

## 6. PM4 层微观项（已核实无大鱼，记录结论）

逐行过完 `pm4_command_processor_implement.h` 后，前人（chrispy）已把热层做透：
分支按概率重排、Type-0/3 内联化、RingBuffer 读路径无分支化、trace_writer
关态只多一个可预测分支（`trace_writer.cc:120-134`）、寄存器区段写已有
`vulkan_fast_register_ranges` 批量路径、同值 fetch 常量已有跳过
（`vulkan_skip_redundant_fetch_constant_writes`）。剩余可做但收益小的：

| 项 | 现状 | 可做的 |
| --- | --- | --- |
| `WAIT_REG_MEM` 睡眠 | 非 Win32 走 `threading::Sleep(wait_ms)` 整毫秒 | OHOS 可用 `NanoSleepPrecise`（fork 已有）睡 90%+自旋尾，降 vblank 等待过冲（延迟项非吞吐项） |
| `ExecutePacketType0` | `XE_NOINLINE`（作者 TODO 注释说它最热） | 把 `trace_writer_` 两调用折叠成 `if (file_)` 单分支；收益 ~ns/包级 |
| `MakeCoherent` 轮询 | `COHER_STATUS_HOST` 轮询每次读 volatile 寄存器 | 见 K3，真正的解法在语义层 |
| `ExecutePacket` 包头扫描 | 每 dword `ReadAndSwap`（字节序翻转必须） | 无动作 |

---

## 7. 实施路线图（与 PERFORMANCE.md §6 衔接）

```
第一周（零代码基线，PERFORMANCE.md §6.1）
  └─ log_gpu_frame_time_breakdown + log_resolve_details 建立
     pass 分桶 GPU 时间基线 + zero-copy 形态确认
第二周（低风险落袋，本文）
  ├─ K6 自旋默认值（一行）
  ├─ K8 perf_map 平台默认（一行）
  ├─ K9 诊断开关（~50 行）
  └─ K4 武装块级快路径（~60 行）
第三~五周（主攻）
  ├─ K1 直读 resolve den 适配（~200 行，着色器常量+验证）
  ├─ K2A fetch 常量特化（~400 行，Modification+异步重翻译）
  └─ K3 第一期：MakeCoherent 精确通知（~80 行，零行为风险）
第六周起（按基线数据决策）
  ├─ K5 W^X 批量放置（cvar 灰度）
  ├─ K10 gamma 合并（画质 A/B）
  ├─ K7 第二步：全局锁切分（画像数据达标才做）
  └─ K2B 原生顶点缓冲（K2A 后仍有 VS 瓶颈才做）
```

每一步的验收都回到同一组仪表：`VkFrameSync`（gpu exec / gap / resolve_ms）、
`VkPassTime`（分桶）、`log_resolve_details`（路径占比）、
`guest_scheduler_stats`（调度/锁）、native_fault.log（行为等价性）。

---

## 附 A：本报告与现有内核机制的关系

fork 已内建的优化（本报告不再重复，避免重复造轮子）：

| 机制 | 位置 |
| --- | --- |
| 寄存器区段批量写 + 同值跳过 | `vulkan_command_processor.cc:1933-2201` |
| 描述符集值缓存（XXH3 门）/ 纹理绑定 in-sync 位图 | `vulkan_command_processor.cc:7947-8081`、`texture_cache.cc:374-470` |
| 采样器跨 draw 缓存 | `vulkan_command_processor.cc:4024-4178` |
| EDS 管线排列坍缩 | `vulkan_pipeline_cache.cc:1677-1759` |
| 异步管线 + 延迟绑定 | `vulkan_pipeline_cache.cc:909-947` |
| 共享内存上传出 pass / 无锁快路径 | `vulkan_shared_memory.cc:786-825`、`gpu/shared_memory.cc:493-518` |
| in-pass transfers / DONT_CARE 推导 | `vulkan_render_target_cache.cc:3423-3490` |
| resolve-to-texture 三件套 | 设置页默认全开 |
| 中帧提交 / primary-buffer-end 提交 | `vulkan_command_processor.cc:4788-4794` |
| epoch 门控 + 定向唤醒的 guest 调度 | `kernel/guest_scheduler.cc`、`kernel/xobject.cc:400-410` |
| 自旋折叠三 pass（Spin/Delay/MemoryPollPark） | `cpu/ppc/ppc_translator.cc:123-142` |
| LSE 原子 / WFE 让出 / longjmp 重入 | `a64_seq_memory.cc`、`threading_posix.cc:232-253`、`xthread.cc:53-59` |

这份清单正是上一轮"只看表面"批评的答案的另一面：**配置层面的开关大多是
这些内核机制的入口**；本文 K1-K12 则是这些机制尚未覆盖到的、需要写代码的
增量。
