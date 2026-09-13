# HX360E 性能优化点（GPU 瓶颈专题）

| 项目 | 内容 |
| --- | --- |
| 版本 | v1.0 — 2026-09-12 |
| 前提 | 全量通读 xenia 内核与 HX360E 适配层后梳理；**只列证据可查、可验证的优化点**，每条附代码位置、现状、方案、预期收益、风险与验证方法 |
| 关联 | [ARCHITECTURE.md](./ARCHITECTURE.md)（系统架构）、[TODO.md](./TODO.md) |
| 瓶颈判定 | 用户实测与代码推演一致：**当前瓶颈在 GPU 模拟侧**（`--gpu=null` 对照已接好：`xendroid_ohos/ohos_emulator.cc:113-121`，null 下帧时间大幅下降即证 GPU 侧） |

---

## 0. 测量方法论（先于一切优化）

优化前必须能"看见"。本 fork 已内建四层测量，真机（无法用 RenderDoc 系统抓帧时）全部可用：

| 工具 | 开法 | 看什么 |
| --- | --- | --- |
| **GPU 帧时间分解** | 配置 `Logging|log_gpu_frame_time_breakdown=true`（或 TOML 加） | `VkFrameSync:` 每秒一行：awaits/await 时长、submit→fence 延迟、**GPU 执行时间(gpu exec) vs 空隙(gap)**、resolve GPU 时间、draw 数/render pass 数；`VkPassTime:` 按 framebuffer 尺寸分桶的 **GPU 时间**（含 scissor/viewport 上界）——这就是"GPU 到底在哪个 pass 上烧时间"的答案。实现在 `vulkan_command_processor.cc:592-686, 2239-2303`（时间戳全部提交内回读，无 host 阻塞查询） |
| **resolve 直方图** | `GPU|log_resolve_details=true` | 每秒 resolve 次数/字节、direct-host vs dump 路径占比、目的地址跨帧复用（`vulkan_render_target_cache.cc:3250-3366`） |
| **in-pass 命中率** | 自带（512 次一报） | `VkInPass: taken/attempts` + 拒绝原因分布（`vulkan_render_target_cache.cc:2845-2877`） |
| **present 探针** | 自带 | `present probe: paints/s=X guestInstantFps=Y`（`ohos_window.cc:66-84`）——判断瓶颈在上屏还是 guest 产出 |
| **null GPU 对照** | `--gpu=null` | 同场景 CPU 侧帧时间下限；gpu=vulkan 与 null 的差 = GPU 模拟总成本 |
| **调试浮层** | `Display|show_debug_overlay=true` | guest FPS + 帧时间 + **GPU 占用%（时间戳回读）** + 着色器编译中数量 |

> 真机日志通道注意：hilog 对高频/整段会丢弃，用应用内"导出日志"（xe.log 尾 4MB）
> 或 native_fault.log 通道。

---

## 1. 现状基线与瓶颈结构

真机实测（MateBook Pro S / Pura 70 Pro，Maleoon 935/920，注释与提交留档）：

| 配置 | 结果 | 出处 |
| --- | --- | --- |
| 原生 720p 渲染（den=1） | 重场景 ~15 fps | `SettingsSchema.ets:183-188` 注释 |
| 半分辨率 360p + XEG 1.5x | 稳定 30 fps | 同上；XEG 提交 `41e0b68`（1280x640→1920x960 每帧 Render） |
| 强制 FIFO + UI 线程 present | 上屏率 ~8/s（已回退） | `ohos_window.cc:185-193`、提交 `3018154` |

**瓶颈结构推断**（待 §0 工具量化确认）：720p→360p（像素工作 ÷4）带来 15→30fps 的
近乎线性收益 ⇒ 帧时间被**逐像素工作（fragment + ROP + resolve 带宽）**主导。
Xenos GPU 模拟的逐像素成本有三处宿主放大：

1. **EDRAM resolve 链**：guest 每次换帧缓冲都触发 resolve（大多数游戏每帧 1–5 次）。
   当前 HX360E 实际走的是**最慢的第三条路**：`DumpRenderTargets`（RT→EDRAM buffer
   compute）+ resolve 拷贝（EDRAM→guest 内存 compute）——两次全带宽 pass + 一次
   render pass 打断（tile GPU 上还有 GMEM store/restore）。§2.1/§2.2 直击这里。
2. **宿主 render target 的实际渲染面积**：EDRAM 布局使 framebuffer 高度可达数千行
   （80×16 tile 线性寻址，pitch 2 tile → 8192 行），render area = 整个 framebuffer
   extent。tile GPU 的 binning/GMEM 按 render area 工作，不是按 draw 裁剪。
   §2.3 有现成开关。
3. **像素填充率本身**：Xbox 360 游戏为 720p 设计，在移动 GPU 上跑原生 720p +
   guest MSAA 已经贴满；半分辨率/VRS 是仅有的两个"不减逻辑就减像素"的手段（§2.4/§2.5）。

次要放大项：CPU 侧每帧的 draw 准备（着色器常量上传/描述符/barrier 录制）、
页写监视失效引起的纹理重传、以及 present/guest 节奏错配（§2.9）。

---

## 2. GPU 侧优化点（按优先级）

### P0-1 修复并重新启用 direct host resolve（最快路径被人为关闭）

- **现状**：`vulkan_direct_host_resolve=true` 是 fork 默认（免 RT→EDRAM 落地、免
  render pass 打断，`vulkan_render_target_cache.cc:97-105`），但 HX360E 启动参数
  **强制关闭**：`--vulkan_direct_host_resolve=false`
  （`entry/src/main/ets/pages/Home.ets:378-381`，注释："direct-HR 路径对 den 的适配
  尚未做对（标题层会缩到左上角 1/4）"）。
- **代价**：每次 resolve 多付一次 dump pass（宿主 RT 全量读 + EDRAM tile 写）+
  tile GPU 上一次 GMEM store。设置页 den=2 时 dump 路径虽已做除法回算
  （`TryDirectHostResolveCopy` 的 `tile_size_* / den` 与 dump 着色器的
  nearest-upsample，fork 补丁 `vulkan_render_target_cache.cc` 两处），但直读路径
  仍有漏适配。
- **方案**：用 §0 的 `log_resolve_details` + `VkPassTime` 找出 direct-HR 差异面：
  1) 在 direct-HR 着色器族（`resolve_host_color_*` / `resolve_host_color_full_*` /
     `resolve_host_depth_*`）里补 source 侧的 `scale_native × 1/den` 混算
     —— dump 路径在 `GetDumpPipeline` 里做的是**目的坐标 ÷ den**
     （fork 补丁 `vulkan_render_target_cache.cc:8820+`），direct 路径需要的是
     **源 UV × den 的映射一致性**，两者必须用同一套坐标约定；
  2) A/B：`--vulkan_direct_host_resolve=true` + 半分辨率，对比
     `VkFrameSync` 的 resolve_ms 与整体 gpu exec。
- **预期**：resolve 是每帧多次的全带宽操作，省一次 dump pass 在 tile GPU 上
  通常值 1–3ms/帧级别（有 `resolve_gpu_ns` 可直接量化）。
- **风险**：格式转换族（gamma/uint）漏适配会花屏——有
  `vulkan_in_pass_resolve_debug_*` 探针族可隔离验证。

### P0-2 确认 shared memory 实际形态（zero-copy 是否生效）

- **现状**：ARM64 上 `shared_memory_zero_copy=true` 是默认（`gpu_flags.cc:12-26`），
  生效时 CPU→GPU 上传**完全消失**（guest RAM 直接 import 成 VkBuffer，
  `vulkan_shared_memory.cc:317-470`）。但它需要 Maleoon 支持
  `VK_EXT_external_memory_host` 且对齐满足；**不满足会静默回退** sparse/host-visible。
- **动作（一次真机启动即可判定）**：查 xe.log：
  - `Shared memory: using zero-copy guest RAM aliasing` → zero-copy 生效；
  - `Shared memory host import: …`（各失败原因行）→ 回退了，看具体原因；
  - `Shared memory: host-map decision: …` → dense host-visible 决策。
- **若未生效**：回退形态下每帧的 dirty 页上传 = `memcpy + vkCmdCopyBuffer`，
  对统一内存 GPU 是纯浪费。可考虑的替代：
  a) 扩 `CreateImportedGuestRamBuffer` 的对齐兜底（guest RAM 分配基址本身可控——
     `memory.cc` 的 `mmap_address_high` 扫描若能约束到 `minImportedHostPointerAlignment`
     对齐，import 就能成立）；
  b) 保持 sparse device-local + 收紧失效粒度（现状 256KB 外扩对上传有利，
     但对带宽不利——两边有 `log_gpu_frame_time_breakdown` 数据后权衡）。
- **预期**：zero-copy 生效与否直接决定"CPU 写一页 → GPU 重传"这一最大带宽项的
  存在性；未生效时修复它是数量级级别的收益。

### P0-3 `render_area_dirty_extent=true` 在 Maleoon 上重测（现成开关）

- **现状**：每个 render pass 的 render area = **整个 framebuffer extent**
  （EDRAM pitch 派生，最坏 80×8192；`SubmitBarriersAndEnterRenderTargetCacheRenderPass`
  注释，`vulkan_command_processor.cc:3366-3379`）。fork 已实现把 render area 收缩到
  实际被画的矩形（`DeferredCommandBuffer::ShrinkRenderAreaToDrawn`，
  cvar `render_area_dirty_extent`，默认 **off**）——注释说 Adreno 650/Turnip 上
  测过"pass 时间与 RB 计数无变化，驱动本来就会跳过空 tile"。
- **逻辑**：Maleoon 是另一套驱动，binning 行为未知；**这个 cvar 是零代码收益**，
  一次 A/B 即可定论。半分辨率下该效应还会放大（面积小时对齐量化占比更高）。
- **动作**：TOML 加 `render_area_dirty_extent=true`，对比 `VkPassTime` 的
  分桶 GPU 时间与总 gpu exec。
- **预期**：若 Maleoon 不跳过空 tile，收益可达每 pass 0.1–1ms；若无效也无损失。

### P0-4 VRS 着色率真机 A/B（管线侧已全部就绪）

- **现状**：fork 已启用 `VK_KHR_fragment_shading_rate`（`vulkan_device.cc` fork 补丁）、
  在**每条图形管线**上挂 uniform 着色率 state
  （`vulkan_pipeline_cache.cc:2737-2774`），设置页 `Vulkan|hx360e_vrs_rate`
  （off/1x2/2x1/2x2，默认 off）。
- **逻辑**：2x2 = fragment 调用数 ÷4。它和半分辨率（÷4）是**可叠加**的两个旋钮；
  差异在于 VRS 保留宿主 RT 原分辨率（混合/深度精度不变），只是片元稀疏，
  对透明混合/粒子密集场景画质损失比降分辨率更温和。
- **动作**：`hx360e_vrs_rate=2x2` + 半分辨率关/开各测一档；
  观察 `VkPassTime` 逐 pass 收益（预期 fragment 受限的 pass 线性下降，
  顶点受限的 pass 不变——这同时是"哪些 pass 是 fragment 受限"的诊断）。
- **风险**：Maleoon 驱动的 VRS 实现质量未知（phase0 探测 `fsr/subpass_shading`
  支持，提交 `7f7d26d`）；画面糊需用户可接受。后续可升级为 XEngine
  自适应 VRS（rate image，fork 注释已预留）。

### P1-5 半分辨率策略升级：自适应 + 非 1/2 档位

- **现状**：`hx360e_render_scale_den_x/y` 只支持整数除数（1/2/3，
  `GetHostExtentX/Y`），设置默认 **1（原生 720p）**；实测 720p 15fps / 360p 30fps
  ——当前只能"全有或全无"。
- **方案**（由轻到重）：
  a) **首帧自适应**：boot 后跑 2–3 秒，用 `GetGpuStats`（GPU 时间戳回读已接
     `frame_stats.h`）测 gpu_ms/frame，超过阈值（如 20ms）自动落到 den=2 并提示
     （纯 HX360E 层逻辑，改 `ohos_emulator.cc` 启动参数即可——den 是 boot 时
     定死的一次性 cvar，`render_target_cache.cc:InitializeCommon`）；
  b) **1.5 档（2/3 分辨率）**：den 语义改为"分子/分母"或直接支持
     `den=1.5`（宿主 extent = guest×2/3），着色器常量本来就走整数除法，
     需要把 `draw_resolution_scale_den_*` 换成 scale×1024 定点（改动集中在
     `GetHostExtentX/Y`、viewport/scissor 除法、dump/direct 着色器常量——
     约 6 处，fork 补丁已圈定全部落点）；
  c) **按 pass 分辨率**（重）：深度/不透明 pass 原生、透明/UI pass 半分辨率
     —— guest 不感知 RT 尺寸，技术上可行但 ownership transfer 会变频繁，
     先不做。
- **预期**：在画质与帧率之间补上连续档位；对 45fps 级游戏（当前 15 或 30 二选一）
  有直接体感。

### P1-6 `vulkan_dynamic_constant_buffers=true` 在 Maleoon 上 A/B

- **现状**：关闭（native 默认）。原因记录在 cvar 描述里：**高通专有驱动**
  （Adreno 650/740/830）经动态偏移 UBO 读到全零（RenderDoc 像素历史二分证明），
  Mesa/Turnip 正常（`vulkan_command_processor.cc:138-150`）。
- **逻辑**：开启后每 draw 只换 dynamic offset，描述符集仅在 upload pool 页翻转时
  重写（`UpdateBindings` 的 `constants_descriptor_set_valid_` 值缓存）——省每 draw
  一次 transient descriptor 分配 + `vkUpdateDescriptorSets` + 重绑定。
- **动作**：Maleoon 上开 A/B；**验证正确性**（着色器常量读零=花屏/黑屏，立即可见），
  对照 CPU 侧 draw 准备时间（`SCOPE_profile_cpu "gpu"` 或帧时间差）。
- **预期**：draw 密集标题每 draw 省 ~µs 级 CPU；GPU 时间不受影响——
  只在 CPU 侧成为次要瓶颈时有意义。

### P1-7 纹理缓存上限与抖动

- **现状**：软 384MB / 硬 768MB（`texture_cache_memory_limit_soft/hard`，
  HX360E 设置页默认同 fork）。超软上限后 30 秒未用的纹理被销毁，下次再见到 =
  **完整的解块+上传重来**。游戏（尤其开放世界）纹理集常在 500MB–1GB 级。
- **逻辑**：Maleoon 935 设备有 12–16GB 统一内存，模拟器自身 4.5GB guest + 512MB
  shared memory + RT/纹理缓存都在其中；768MB 硬上限过于保守。
- **动作**：设置页调到 1024/2048 观察：纹理重传频率（间接指标：`VkFrameSync`
  的 gpu exec 抖动、转场/镜头切换时的帧尖峰）与内存压力（OOM 边界）。
  另可加"重传字节/秒"诊断（在 `LoadTextureDataFromResidentMemoryImpl` 计数）。
- **预期**：消除周期性纹理重传尖峰；对平均帧率影响小、对 1% low 帧率影响大。

### P1-8 `framerate_limit` 与 30fps 游戏的空转

- **现状**：`framerate_limit=60`（设置页默认）。`ThrottlePresentation`
  在每次 IssueSwap 后 spin + NanoSleep 到 16.67ms 目标帧时长
  （`command_processor.cc:594-650`）。当游戏本身 30fps（帧长 33ms）时它不工作——
  无害；但**当游戏 45–60fps 且 GPU 吃满时**，throttle 的 spin 段白白烧核，
  且 `gpu_stall_spin_iterations=32` 的 CP 自旋（`WorkerThreadMain`）在 GPU 忙时
  也在烧核（注释明言 ARM64 上 WFE 不真 park）。
- **动作**：
  a) 30fps 锁帧的标题把 `framerate_limit` 设 30（设置页已有档位）——
     让 throttle 提前介入反而稳定；
  b) 观察 `gpu_stall_spin_iterations` 对 CPU 占用的影响（设置页可调 0–512），
     GPU 受限时把 CP 让出 CPU 给渲染线程可能反而提升帧率（真机 A/B）。
- **预期**：CPU 侧让核；在大小核调度（Maleoon 平台）上效果可能显著。

### P1-9 帧中提交调参（per-title）

- **现状**：`vulkan_mid_frame_submission_draws=1300`（fork 默认，设置页 0–4096）。
  作用：draw 数超过阈值就把命令流提交给 GPU，渲染与命令构建重叠
  （cvar 描述：建议取"该标题每帧 draw 数的一半"）。
- **逻辑**：对每帧 <1300 draw 的标题该参数完全不生效（一帧一提交，已经最优）；
  对 draw 密集标题（2000+）生效。**方向应该反过来**：若 `VkFrameSync` 显示
  gpu gap 大（GPU 等命令）→ 减小该值；若 sub_latency 小且 pass 被
  强制切分（splits 计数高）→ 增大。
- **动作**：用 `VkFrameSync` 的 `splits` / `gpu gap` 两个数对目标标题调参。
- **预期**：GPU 吃满的标题收益小；GPU 空泡明显的标题（gap>1ms/帧）收益直接。

### P1-10 XEG 呈现链精简

- **现状**：开 XEG 时 flow = XEG(1.5x) → **bilinear 放大到窗口** → present；
  XEG 段输出到自建 RGBA8 中间图（`vulkan_presenter.cc` fork 补丁：
  输入/输出图 + 两个 barrier + 描述符重写）。
- **浪费点**：
  a) 半分辨率 360p × 1.5 = 540p，再 bilinear 到 1280×720 —— 中间分辨率与
     窗口尺寸不匹配导致 XEG 算力花在"还要被再采样"的中间图上。**XEG 输出尺寸
     直接做成窗口尺寸**（XEG 支持任意 outputSize，`xeg_spatial_upscale.cc`
     的 Initialize 参数本来就是窗口可变的）可省掉第二段 bilinear 采样与一次
     中间图带宽——当前 1.5x 是探针期的保守值（创建失败自动退回 FSR 链，可改）；
  b) 每帧两个全图 barrier（UNDEFINED→COLOR_ATTACHMENT→SHADER_READ）可合并为
     一个（XEG 段自带输出 layout 管理，观察驱动行为后收敛）。
- **预期**：省一次全屏采样 pass（1280×720 的 bilinear 很便宜但不是零）+
  中间图带宽减半（540p→720p）。
- **风险**：XEG 输出非 1.5x 的画质/性能特性未实测；保持 1.5x+链路现状亦可接受。

### P2-11 in-pass resolve / local-read 在 Maleoon 上落地确认

- **现状**：设置页把 `vulkan_in_pass_resolve` 默认**开**（native fork 默认关），
  但它要求 `VK_KHR_dynamic_rendering_local_read`（`vulkan_render_target_cache.cc:497-506`）。
  Maleoon 若不支持，该开关静默无效（日志 `local-read color attachment mode on`
  不出现），颜色附件不会进 RENDERING_LOCAL_READ，每次 resolve 都要打断 pass。
- **动作**：真机确认该日志行；不支持则此设置项应灰掉（避免"以为开了"）；
  支持则用 `VkInPass:` 命中率 + 拒绝原因统计评估收益，并考虑把拒绝大户
  （pitch/格式不匹配）逐个补进直写族。
- **预期**：in-pass resolve 每次命中省一个 pass 打断 + EDRAM 落地，
  是 resolve 侧的最优解；命中率决定收益上限。

### P2-12 MSAA 形态核对

- **现状**：`native_2x_msaa=true`（guest 2x→宿主真 2x）。Maleoon 的 2x attachments
  支持与否影响带宽（4x-as-2x 会 ×2 带宽）。`msaa_2x_attachments_supported_` /
  `msaa_2x_no_attachments_supported_` 在初始化时探测（`vulkan_render_target_cache.cc:510+`）。
- **动作**：日志确认探测结果；若 2x 不支持且游戏用 2x MSAA，
  考虑 guest MSAA 强制 1x 的画质换带宽档位（新增 cvar，改 `RB_SURFACE_INFO`
  归一化一处）。

### P2-13 呈现路径的 vsync 对齐（长期项）

- **现状**：IMMEDIATE/MAILBOX + guest 线程直接 present（`kGuestOutputThreadImmediately`）。
  曾实验 FIFO+UI 线程 paint：静态画面 59fps 但实际上屏 8/s——UI 线程 paint 循环
  吞吐不足（4ms 轮询 + XComponent buffer 数未知）。已回退留档
  （`ohos_window.cc:185-193`）。
- **方向**（若未来出现撕裂/抖动投诉）：
  1) 用 `OH_NativeVSync_RequestFrame` 驱动 **present**（不是渲染）——
     Phase 0 踩过"fence is not pending"坑（vsync 回调里做 Vulkan 提交），
     只把"请求 paint"放 vsync、渲染仍在 guest 线程可避开；
  2) 确认 XComponent buffer 数（若为 2，MAILBOX 语义退化——这是 8fps 实验
     的头号嫌疑），`OH_NativeWindow_NativeWindowHandleOpt(SET_BUFFER_COUNT)`
     在当前 SDK 无对应 API（提交 `2109657` 结论），只能靠窗口侧。
- **预期**：该路径已可用，属体验打磨而非帧率项。

### P2-14 着色器/管线创建的运行时停顿监控

- **现状**：异步管线 + `vulkan_async_skip_draws=true`（HX360E 默认）——
  编译期丢 draw（poppin）而非等待。游戏中途出现新着色器时会有短时几何缺失。
- **动作**：`store_shaders=true` 已默认开（ucode+SPIR-V+管线描述磁盘缓存 +
  开局 precreate）。跑完一个游戏再跑第二遍，确认 `Draw skipped` 日志消失
  （缓存命中）。`vulkan_pipeline_creation_threads` 设置页默认 4（native -1=75% 核），
  大小核上 4 条创建线程会抢渲染核——创建停顿期与帧率波动做相关观察。

---

## 3. CPU 侧优化点（次要，但与 GPU 争核）

### C-1 JIT W^X 放置成本（OHOS 固有，可减半）

- **现状**：每函数放置 = 页对齐 + 2×mprotect + icache flush，全程持
  `global_critical_region` 全局锁（`code_cache_base.h:569-676`）；
  页对齐平均浪费半页。单次 mprotect 含 mmap_lock 写锁 + 可能的 TLB shootdown，
  ~1–5µs。翻译风暴期（新关卡/新过场）每秒可能数百次放置。
- **方案**：**批量放置**——翻译线程把多个函数的机器码在暂存区连续生成，
  一次 `OhosMakeWritable(整段)` → 连续 memcpy → 一次
  `OhosMakeExecutable(整段)` → 一次 flush。改动集中在 `PlaceGuestCode`
  的调用方（`Processor::ResolveFunction` 的单函数路径需要保留，
  增加预翻译队列即可）。页对齐浪费也随之消失。
- **预期**：翻译风暴期的放置开销 ÷N（N=批大小）；稳态无影响。
- **风险**：中低；放置路径是崩溃高发区（W^X 语义），需要真机回归。

### C-2 `a64_perf_map` 关闭

- **现状**：`a64_perf_map=true`（`a64_code_cache.cc:30`）——每次函数放置写
  `perf-<pid>.map` 并 `fflush`。OHOS 上 simpleperf 场景不存在，纯开销。
- **动作**：fork 里 OHOS 分支默认改 false（一行）。

### C-3 write-watch 诊断的 snprintf

- **现状**：fork 的诊断（`OHOS-fault-enter` ≤512、`OHOS-AV-repeat` 2 的幂次、
  `OHOS-TC-hit` ≤512、`OHOS-forceRW` ≤128）都在信号/热路径上做
  `snprintf + write(2)`。虽然限量，**前 N 次**每次 ~µs 级，且 `OHOS-TC-hit`
  在每次正常 watch 命中时都会走（前 512 次）。
- **动作**：加 `HX360E_DIAG` 总开关 cvar，稳定后默认关（诊断 fd 仍保留给
  `OHOS-regions` / 崩溃路径）。

### C-4 guest→host thunk 的 28×Q 保存

- **现状**：每次 guest 调 host（MMIO/helper/中断）保存 28 个 Q 寄存器
  （464B 帧，`a64_backend.cc:230-339`）。调用频率高的标题（每帧数千次
  memexport/writeback 回调）构成固定税。
- **方案**（长期）：按被调函数的实际寄存器使用面生成特化 thunk
  （xenia 上游 x64 后端有先例）；或减少回调频率（合并 scratch writeback）。

### C-5 渲染/游戏线程的核亲和与优先级

- **现状**：`ignore_thread_affinities=true`、`ignore_thread_priorities=true`、
  vblank 线程 kNormal、Audio Worker nice -12（ADPF 路径 OHOS 无效）。
  Maleoon 平台大小核 + GPU 驱动线程（`sched_setscheduler FIFO failed` 说明
  驱动侧有自己的线程）共存。
- **动作**：真机观察 `guest_scheduler_stats=true`（每秒调度统计）+
  hilog 线程 CPU 占用，考虑把 "GPU Commands" 线程 hint 到大核
  （OHOS 有 `qos_attach` API 可用——fork 的 `SetProcessPriorityClass`
  桩 `system_ohos.cc` 是落点）。

---

## 4. 启动与内存（非帧率但影响体验）

| 项 | 现状 | 动作 |
| --- | --- | --- |
| 管线/着色器磁盘缓存 | ucode+SPIR-V+管线描述 mmap 缓存 + 开局 precreate + VkPipelineCache 20s 落盘 | 已就绪；验证二启 `Draw skipped` 归零即可 |
| 翻译线程栈 32MiB | fork 为 -O0 构设（正式包 -O2 后可回 8MiB，省内存） | 发布构建时改回并观察 |
| XEX 指令信息缓存 | 按 SHA-1 mmap（唯一跨运行 CPU 缓存） | 无动作 |
| guest 内存映射基址 | `mmap_address_high=8` 失败自动扫 2^n | 无动作（每次启动日志确认） |

---

## 5. 已实验并排除的方向（留档，勿重复）

| 实验 | 结果 | 结论 |
| --- | --- | --- |
| 强制 FIFO + UI 线程 present | 静态画面 59fps 但上屏 8/s，体感更卡 | 回退；UI 线程 paint 循环吞吐不足（疑 XComponent buffer 数），需 vsync 驱动+buffer 数确认才可重试（`ohos_window.cc:185-193`、提交 `3018154`） |
| `SET_BUFFER_COUNT` | SDK 无对应 API | 无法手动加 buffer（提交 `2109657`） |
| `guest_display_refresh_cap=false`（vblank 不封顶） | guest 节奏与呈现解耦无收益 | 恢复默认 60Hz |
| GPU 时间戳 host 侧 `vkGetQueryPoolResults` 方案 | 需改 fork + 阻塞轮询风险 | 回退；现有"提交内 copyQueryPoolResults 回读"方案已覆盖需求（TODO 记录） |
| hilog 高频日志 | 整段丢弃 | 诊断改走 native_fault.log / 每秒聚合行 |

---

## 6. 建议的执行顺序（最小验证成本优先）

1. **一周内的零代码验证**（全部只需改配置 + 真机日志）：
   `log_gpu_frame_time_breakdown` + `log_resolve_details` 建立基线 →
   `render_area_dirty_extent=true` A/B（P0-3）→ `hx360e_vrs_rate=2x2` A/B（P0-4）→
   zero-copy 形态确认（P0-2）→ `vulkan_dynamic_constant_buffers` A/B（P1-6）。
2. **第一个代码级目标**：修 direct host resolve 的 den 适配并重新启用（P0-1），
   用 1 中建立的基线量化。
3. **第二个代码级目标**：半分辨率自适应/1.5 档（P1-5），补齐画质-帧率曲线。
4. **并行低风险项**：`a64_perf_map` 关闭（C-2）、诊断开关（C-3）、
   UI 线程轮询周期 4ms→16ms（呈现立即模式下 paint 闲置，`ohos_window.cc:43`）。
5. **收益再评估**：P0-1/2/3/4 落地后重新跑 `--gpu=null` 对照，
   判断瓶颈是否迁移（若迁到 CPU 侧，转 §3 清单）。

---

## 附：关键 cvar 速查（本档涉及）

| cvar | 默认 | 作用 | 位置 |
| --- | --- | --- | --- |
| hx360e_render_scale_den_x/y | 1 | 次原生渲染除数 | `gpu/render_target_cache.h`（fork） |
| vulkan_direct_host_resolve | true（HX360E 强制 false） | resolve 免 dump | `vulkan_render_target_cache.cc:97` |
| vulkan_in_pass_resolve | false（HX360E true） | pass 内解析 | `vulkan_render_target_cache.cc:89` |
| vulkan_resolve_to_texture_* | true | 解析直存纹理 | 同文件 61-72 |
| vulkan_in_pass_transfers | true | 转移编进 pass | 同文件 74-81 |
| render_area_dirty_extent | false | render area 收缩 | `vulkan_command_processor.cc:49` |
| hx360e_vrs_rate | off | 全管线 VRS | `vulkan_pipeline_cache.cc:86` |
| vulkan_dynamic_constant_buffers | false | 动态常量 UBO | `vulkan_command_processor.cc:138` |
| vulkan_mid_frame_submission_draws | 1300 | 帧中提交 | `vulkan_command_processor.cc:60` |
| vulkan_hoist_shmem_uploads | true | 上传出 pass | `vulkan_shared_memory.cc:36` |
| shared_memory_zero_copy | ARM64 true | guest RAM 直映 | `gpu_flags.cc:12` |
| vulkan_shared_memory_host_visible | true | 统一内存直映 | `vulkan_shared_memory.cc:43` |
| readback_resolve | uma（HX360E none） | resolve 回读 | `command_processor.cc:100` |
| render_area_dirty_extent 之外的诊断 | log_gpu_frame_time_breakdown / log_resolve_details | GPU 时间戳 / resolve 直方图 | 同前 |
| guest_scheduler | true | fiber 协作调度 | `kernel_flags.cc:23` |
| framerate_limit | 60 | host 限帧 | `gpu_flags.cc:53` |
| a64_perf_map | true | perf map 写盘 | `a64_code_cache.cc:30` |
