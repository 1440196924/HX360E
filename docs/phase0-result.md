# Phase 0 验证结果

> 设备：HUAWEI MateBook Pro S（2in1）· GPU Maleoon 935 · Vulkan 1.3.309 · HarmonyOS 6.1.1(24)
> 日期：2026-09-08

---

## 0.1 JIT 可执行内存 ✅ 通过

### 结论：可行路径

```
① mmap(PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE)   // 普通 RW，可写
② memcpy 写入机器码
③ mprotect(PROT_READ | PROT_EXEC)                              // 切 RX
④ 调用（探测码 mov w0,#42; ret 返回 42）
```

### 各策略实测

| 策略 | 结果 | errno / 现象 |
| --- | --- | --- |
| ⓪ BaselineRw（匿名 RW，对照） | ✅ 通过 | — |
| **① AnonRwMprot（RW → mprotect RX）** | **✅ 通过** | — |
| ② FileMapRxRw（memfd 双视图） | ❌ 失败 | `errno=13` EACCES @ mmap RX view |
| ③ AnonNoneExecMprot（PROT_NONE+MAP_EXECUTABLE → RW → RX） | 未测（写入阶段会崩） | — |
| ④ AnonExecRwx（匿名 RWX + MAP_EXECUTABLE） | ❌ 失败 | 映射成功但写入 `SIGSEGV(SEGV_ACCERR)` |

### 关键发现

1. **不带 `MAP_EXECUTABLE` 的 `PROT_EXEC` 被内核直接拒绝**（`EINVAL`）。
   → 必须走 `mprotect` 路径，且需要 `ALLOW_EXECUTABLE_FORT_MEMORY` 权限。
2. **带 `MAP_EXECUTABLE` 的映射会被内核剥离 W 权限**，页变只读，连 `memcpy` 写入都 `SEGV_ACCERR`。
   → 反汇编定位：`str x8, [x9]` 处崩溃，`mprotect` 还没执行到。
3. **`sigsetjmp` 信号保护未能拦截** OHOS 的崩溃处理。
   → 探测顺序必须把"可能崩的策略"放最后。

### 权限

实测授予状态（`abilityAccessCtrl.checkAccessTokenSync`）：

```
ALLOW_EXECUTABLE_FORT_MEMORY=G
EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY=G
ALLOW_WRITABLE_CODE_MEMORY=G
```

---

## 0.2 Vulkan 表面呈现 ✅ 通过

### 结论：呈现链路打通

```
XComponent(controller) → getXComponentSurfaceId()
  → OH_NativeWindow_CreateNativeWindowFromSurfaceId
  → vkCreateSurfaceOHOS
  → swapchain
  → 独立线程渲染循环（5ms 间隔）
  → acquire → 清屏 → present
```

实测：60 FPS 稳定，画面正确上屏（红/绿交替验证）。

### 踩过的坑（按排查顺序）

| # | 现象 | 原因 | 解决 |
| --- | --- | --- | --- |
| 1 | XComponent 回调的 `window` 参数路径下 present 成功但不上屏 | 未定位（改用 surfaceId 路径后正常） | 改用 `XComponentController.getXComponentSurfaceId()` + `OH_NativeWindow_CreateNativeWindowFromSurfaceId`（参考 HMPS4e 已验证路径） |
| 2 | 回读图像像素 = (0,0,0,0) | **`vkCmdClearColorImage` 传 `rangeCount=0`** | 显式传 `rangeCount=1` + `VkImageSubresourceRange` |
| 3 | vsync 回调驱动时系统报 `fence is not pending, return timeout` | vsync 回调路径 | 改为独立线程循环（参考 HMPS4e 的 `PresentLoop`） |

### 核心 bug 详情

```cpp
// ❌ 依赖"rangeCount=0 表示清除全部"的隐含语义 —— Maleoon 驱动不实现
vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                     &color, 0, nullptr);

// ✅ 显式传 range
VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                     &color, 1, &range);
```

**隐蔽性**：命令缓冲录制（`begin=0 end=0 reset=0`）、提交、present 全部返回 `VK_SUCCESS`，
无任何报错 —— 清屏静默失效。

**对照**：shadPS4/HMPS4e 用 vulkan-hpp 的 `clearColorImage(image, layout, color, range)`
重载，展开为 `rangeCount=1`，因此不受影响。

### 设备能力（Phase 0.4 数据）

```
Maleoon 935 | api 1.3.309
sparse=1 scalarBlock=1 fragStores=1 geo=1 dynRender=1 float16=1 int16=1
swapchain: 2090x1324 fmt=37(R8G8B8A8_UNORM) imgs=4
preTransform=1(IDENTITY) composite=8(INHERIT)
supAlpha=0x8 supXform=0x1f
```

**重要**：`sparseBinding=1` —— Maleoon 支持稀疏绑定，XenDroid 的相关特性无需降级。

---

## 0.3 音频、0.4 GPU 矩阵、0.5 沙箱存储

待验证。

---

## 对后续开发的影响

1. **JIT**：`xenia/src/xenia/base/memory_posix.cc` 的 `CreateFileMappingHandle` 在 OHOS 上
   应走 `mmap(RW) → 写 → mprotect(RX)` 路径，不要用 `MAP_EXECUTABLE`。
2. **Vulkan 呈现**：移植 `vulkan_presenter` 时，所有 `vkCmdClearColorImage` 调用
   必须显式传 range（检查 XenDroid 现有代码是否也有 `rangeCount=0` 的写法）。
3. **渲染线程**：用独立线程循环，不要用 `OH_NativeVSync` 回调。
4. **surface 获取**：用 `XComponentController.getXComponentSurfaceId()` 路径。
