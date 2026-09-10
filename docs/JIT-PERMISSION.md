# JIT 可执行内存权限说明

> 关联：[DESIGN.md §6](./DESIGN.md)、[TODO.md Phase 0.1](./TODO.md)
> 最后更新：2026-09-08（含真机实测结论）

---

## 1. 已在工程中声明的权限（6 个）

`entry/src/main/module.json5` 的 `requestPermissions`：

| # | 权限 | 级别 | 起始 | `provisionEnable` | 设备 | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | system_basic | 14 | ✅ | 通用 | 申请可执行内存 |
| 2 | `ohos.permission.kernel.EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY` | normal | 23 | ❌ | 仅 2in1 | 允许声明匿名可执行内存（系统自动授予，无需 ACL） |
| 3 | `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | system_basic | 14 | ✅ | 通用 | 申请可写代码内存（RWX） |
| 4 | `ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION` | system_basic | 14 | ✅ | 通用 | **禁用代码内存保护**（关闭 W^X 剥离） |
| 5 | `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` | system_basic | 16 | ✅ | 通用 | 使用 JIT 相关内核接口 |
| 6 | `ohos.permission.RUN_ANY_CODE` | system_basic | 10 | ✅ | 通用 | 运行未签名代码 |

`reason` 文案在 `entry/src/main/resources/base/element/string.json` 的 `reason_executable_memory`。

**其中 1/3/4/5/6 是 ACL 受限权限**，必须：
1. 在 AGC 申请并通过审核
2. 审核通过后重新下载签名 Profile（.p7b）
3. 用新 Profile 重新签名打包

> ⚠️ **若 Profile 中未包含某个 ACL 权限却声明了它，应用会安装失败**：
> `9568289 install failed due to grant request permissions failed`
> 实测 `ALLOW_WRITABLE_CODE_MEMORY` 会触发该错误。

---

## 2. 真机实测结论（2026-09-08）

**设备**：HUAWEI MateBook Pro S（2in1），GPU Maleoon 935，Vulkan 1.3.309

### 2.1 现象

| 策略 | 结果 |
| --- | --- |
| 匿名 `mmap(PROT_READ\|WRITE)`（对照） | ✅ 成功 |
| 匿名 `mmap(RWX)`，**不带** `MAP_EXECUTABLE` | ❌ `EINVAL` |
| 匿名 `mmap(RW)` + `MAP_EXECUTABLE` | ❌ 映射成功，但**写入时 `SIGSEGV(SEGV_ACCERR)`** |
| 匿名 `mmap(RWX)` + `MAP_EXECUTABLE` | ❌ 映射成功，但**写入时 `SIGSEGV(SEGV_ACCERR)`** |
| memfd + `mmap(PROT_READ\|PROT_EXEC, MAP_SHARED)` | ❌ `EACCES` |
| 匿名 `mmap(RW)` → `mprotect(RX)` | 待测（需 ACL 权限生效） |

### 2.2 关键判读

1. **不带 `MAP_EXECUTABLE` 的 `PROT_EXEC` 一律被内核 XPM 拒绝**（`EINVAL`）。
   —— 这解释了为什么必须申请权限。
2. **带上 `MAP_EXECUTABLE` 后映射能成功，但内核把 W 权限剥离**，
   页变成只读，因此连 `memcpy` 写入都会 `SEGV_ACCERR`。
   —— 这是 W^X 强制策略的体现。
3. **反汇编定位**（`libentry.so` 偏移 `0x1876c`）：
   ```
   1875c: ldur x9, [x29, #-32]   ; x9 = mmap 返回地址
   18764: adr  x8, kProbeCode
   18768: ldr  x8, [x8]
   1876c: str  x8, [x9]          ; ← SIGSEGV(SEGV_ACCERR)：页不可写
   1877c: bl   mprotect           ; 还没执行到
   ```
4. **`sigsetjmp` 信号保护未能拦截** —— OHOS 的崩溃处理可能在用户 handler
   之前介入，或 handler 安装被系统覆盖。因此探测顺序必须把"可能崩的策略"
   放最后，避免挡住后续探测。

### 2.3 推论：正确路径

参考 mozjs（Servo）在 HarmonyOS NEXT Beta 2 的补丁：

```c
int flags = MAP_FIXED | MAP_PRIVATE | MAP_ANON;
flags |= MAP_EXECUTABLE;          // 关键标志
void* p = MozTaggedAnonymousMmap(addr, bytes, prot_flags, flags, -1, 0, "js-executable-memory");
```

**mozjs 的 `prot_flags` 来自 `ProtectionSettingToFlags()`**，写入阶段用
`PROT_READ | PROT_WRITE`，执行阶段用 `PROT_READ | PROT_EXEC`，
即**先 RW 分配、写入，再 mprotect 到 RX**，从不写 RWX 页。

因此 XenDroid 应采用：

```
① mmap(PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE)   ← 普通 RW，可写
② memcpy 写入机器码
③ mprotect(PROT_READ|PROT_EXEC)                      ← 切 RX
④ 执行
```

这条路径**不需要 `MAP_EXECUTABLE`**，因此不会触发 W 剥离。
它需要的是 `ALLOW_EXECUTABLE_FORT_MEMORY`（允许 `mprotect` 到 RX）。

---

## 3. 权限图谱（SDK 权威定义）

数据提取自 `DevEco Studio/sdk/default/openharmony/toolchains/lib/PermissionDefinitions.json`（735 个权限定义）。

### 3.1 与 JIT / 可执行内存相关的权限（全量）

| 权限名 | 级别 | 起始 | `provisionEnable` | 设备 |
| --- | --- | --- | --- | --- |
| `kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | system_basic | 14 | ✅ | 通用 |
| `kernel.ALLOW_WRITABLE_CODE_MEMORY` | system_basic | 14 | ✅ | 通用 |
| `kernel.DISABLE_CODE_MEMORY_PROTECTION` | system_basic | 14 | ✅ | 通用 |
| `kernel.ALLOW_USE_JITFORT_INTERFACE` | system_basic | 16 | ✅ | 通用 |
| `kernel.DISABLE_GOTPLT_RO_PROTECTION` | system_basic | 17 | ✅ | 通用 |
| `kernel.EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY` | normal | 23 | ❌ | 仅 2in1 |
| `ALLOW_EXTERNAL_NATIVE_CODE` | system_basic | 23 | ✅ | 仅 2in1 |
| `RUN_ANY_CODE` | system_basic | 10 | ✅ | 通用 |
| `RUN_DYN_CODE` | normal | 11 | ✅ | 通用 |

**`provisionEnable` 是分水岭**：
- `true` → 可通过 **ACL** 在签名 Profile 中申请。
- `false` → 无法通过 Profile 授予，由系统在安装时按级别自动授予。

### 3.2 未声明但可能相关的

| 权限 | 是否声明 | 理由 |
| --- | --- | --- |
| `kernel.DISABLE_GOTPLT_RO_PROTECTION` | ❌ | 关闭 GOT/PLT 只读保护，与 JIT 代码页无关，暂不需要 |
| `ALLOW_EXTERNAL_NATIVE_CODE` | ❌ | 仅 2in1，用于加载外部原生代码；若后续要支持 dlopen 用户提供的 .so 再加 |

---

## 4. ACL 申请流程

### 4.1 AGC 侧

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
2. 进入「项目设置」→「ACL 权限」
3. 逐个搜索并申请 §1 表中 `provisionEnable` 为 ✅ 的 5 个权限
4. 填写申请理由（见 §4.2 模板）
5. 等待审核（通常 1–3 个工作日）
6. 审核通过后，回到 AGC **重新下载签名 Profile（.p7b）**

### 4.2 申请理由模板

> 本应用是 Xbox 360 游戏模拟器。为在 ARM64 设备上运行 Xbox 360 的 PowerPC 指令，必须采用动态二进制翻译（JIT）：在运行时把 guest 指令翻译为 ARM64 机器码并放入可执行内存执行。
>
> - **用途边界**：仅翻译并执行**用户自行导入的本地游戏文件**中的代码，不下载、不执行任何远程代码。
> - **内存管理**：采用 W^X 安全的双阶段方案 —— 先以只读写权限（`PROT_READ|PROT_WRITE`）分配内存并写入机器码，写入完成后立即用 `mprotect` 切换为只读可执行（`PROT_READ|PROT_EXEC`）。任何时刻同一内存区域都不会同时具备写与执行权限。
> - **不涉及**：不加载第三方动态库、不执行网络下发的字节码、不做热更新。
> - **必要性**：无 JIT 则只能走解释执行，性能不足以运行任何 3D 游戏，产品无法成立。

### 4.3 调试阶段

参考华为《受限权限调试解决方案》：

- 配置好权限后可用**自动签名重签**直接安装调试，不必等 AGC 流程走完。
- 注意：Profile、`bundleName`、签名证书、安装包必须**严格匹配**。当前
  `bundleName` 为 `com.sddswsf.hx360e`，不要随意改包名，否则要重新申请。

---

## 5. 常见报错

| 错误码 | 含义 | 排查 |
| --- | --- | --- |
| `9568289` | `install failed due to grant request permissions failed` | Profile 未包含声明的 ACL 权限；实测由 `ALLOW_WRITABLE_CODE_MEMORY` 触发 |
| `9568259` | 签名校验失败 | 检查证书 / Profile / bundleName 是否匹配 |
| `9568305` | 权限声明格式错误 | 检查 `reason` 资源是否存在、`usedScene.abilities` 是否指向真实 ability |

**排查顺序**：确认 Profile 里确实有该权限 → 确认 bundleName 未变 → 重新生成签名 → 重新安装。

---

## 6. 如果权限拿不到：退路

DESIGN.md §6.1 设计了多策略运行时探测。基于实测，各策略对权限的依赖如下：

| 优先级 | 策略 | 需要的权限 |
| --- | --- | --- |
| ① | 匿名 RW → `mprotect` RX | `ALLOW_EXECUTABLE_FORT_MEMORY` |
| ② | memfd + 双视图（RW + RX） | `ALLOW_EXECUTABLE_FORT_MEMORY` |
| ③ | `PROT_NONE` + `MAP_EXECUTABLE` → RW → RX | 上述 + `DISABLE_CODE_MEMORY_PROTECTION` |
| ④ | 匿名 RWX + `MAP_EXECUTABLE` | 全部（且实测仍被剥 W，不可用） |

**策略①②是主路径**，只需 `ALLOW_EXECUTABLE_FORT_MEMORY` 一个 ACL 权限。

### 6.1 一个重要的反证

社区已有 PPSSPP / melonDS / RetroArch 的鸿蒙原生移植（[richshaw2015](https://github.com/richshaw2015/ppsspp)），其 `entry/src/main/module.json5` 中 `requestPermissions` **只有** `INTERNET` 和 `VIBRATE`，`deviceTypes` 为 `["phone", "tablet"]`，**未声明任何 JIT 权限**，而 PPSSPP 的 ARM64 JIT 确实在编译并被使用。

这说明：**至少在部分 HarmonyOS 版本/设备上，JIT 不需要这些权限也能工作**。

可能的原因：
- 权限策略随系统版本收紧（PPSSPP 的 `compatibleSdkVersion` 是 `5.0.0(12)`）；
- 或不同内存分配方式受策略影响不同。

**结论：声明权限是保险，但不要假设它是唯一路径。Phase 0.1 的实测结果才是准绳。**

---

## 7. 待办

- [x] 在 `module.json5` 声明 6 个权限
- [x] 真机实测定位失败原因（W 被剥离）
- [ ] AGC 申请 5 个 ACL 权限并配置 Profile
- [ ] 用生效的权限重跑探测，确认策略① 或 ② 通过
- [ ] 根据实测结果精简权限列表（能少则少）
- [ ] 结论写入 `docs/phase0-jit-result.md`
