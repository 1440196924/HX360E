# HX360E

在 HarmonyOS 上运行 Xbox 360 游戏的模拟器前端，基于 [XenDroid](https://github.com/rfandango/XenDroid)（Xenia 的 Android 移植）做的鸿蒙移植。

- ArkTS 应用外壳（游戏库 / 设置 / 安装 / 手柄 / 诊断）
- 原生层：Xenia 内核（JIT + Vulkan + OHAudio + OHOS 输入）
- 呈现走 `OH_NativeWindow` + Vulkan 交换链，支持 XEngine Kit 空域超分

## 快速开始

上游 XenDroid **不入库**，克隆本仓库后先跑脚本把指定版本的上游拉下来并打补丁：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/setup-upstream.ps1
```

```bash
# Linux / macOS / WSL
bash scripts/setup-upstream.sh
```

脚本做三件事（幂等，可重复执行）：

1. 按 `patches/upstream.json` 里钉死的版本 clone / checkout 上游 XenDroid
2. `git submodule update --init --recursive` 拉子模块（第一次几百 MB~数 GB，很慢）
3. 按顺序打上 `patches/harmony/` 下的补丁

默认克隆到 `third_party/XenDroid/`（已 gitignore），CMake 会自动找到，无需额外配置。
想放别处：

```powershell
scripts/setup-upstream.ps1 -Dest D:\src\XenDroid
# 然后构建时传 -DXE_XENDROID_ROOT=D:\src\XenDroid\emulator-core\src\main\cpp
# 或设环境变量 XE_XENDROID_ROOT 指向该路径
```

> 子模块很大。只想先看看代码结构可以用 `-SkipSubmodules` / `--skip-submodules`，
> 但真正编译前必须补跑 `git submodule update --init --recursive`。

## 构建

用 DevEco Studio（推荐 5.0+，需 HarmonyOS SDK + BiSheng 工具链）打开仓库根目录，
选 `entry` 模块构建即可；或命令行：

```powershell
# 需要 DEVECO_HOME 指向 DevEco Studio 安装目录
hvigorw assembleHap --mode module -p module=entry@default -p buildMode=release
```

`entry/src/main/cpp/CMakeLists.txt` 会在配置阶段校验上游源码树是否存在，
找不到会直接报错并提示先跑 setup 脚本。

## 目录

| 路径 | 说明 |
|---|---|
| `entry/src/main/ets/` | ArkTS 应用层（页面 / 安装 / 设置 / 手柄） |
| `entry/src/main/cpp/xendroid_ohos/` | OHOS 平台适配层（窗口 / 音频 / 输入 / NAPI 桥） |
| `entry/src/main/cpp/` | JIT 探测、Vulkan context、XEngine 超分封装 |
| `patches/harmony/` | 上游补丁（**唯一**的上游改动载体） |
| `patches/upstream.json` | 钉死的上游仓库 / commit / 补丁清单 |
| `scripts/` | 上游拉取与补丁导出脚本 |
| `docs/` | 架构、设计、性能与可行性分析 |

## 补丁说明

上游改动一律以补丁形式维护，本地不要直接提交上游源码：

| 补丁 | 作用域 | 内容 |
|---|---|---|
| `xendroid-ohos-fork.diff` | XenDroid 仓库根 | OHOS 平台移植 + 内核性能优化 + 诊断仪表 |
| `glslang.diff` | `xenia/third_party/glslang` | BiSheng 工具链编译修补 |
| `xbyak_aarch64.diff` | `xenia/third_party/xbyak_aarch64` | OHOS 平台修补 |

维护者改了本地 fork 后重新导出：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/export-patch.ps1 -Fork <本地 XenDroid 路径>
```

## 免责声明

本项目仅用于技术研究与运行**用户自己拥有备份**的游戏，不包含任何游戏内容、
密钥或版权素材。Xbox、Xbox 360 是 Microsoft 的注册商标；本项目与 Microsoft
无任何关联。
