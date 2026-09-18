// jit_probe.h
// Phase 0.1: 探测鸿蒙上可用的 JIT 可执行内存分配策略。
//
// 策略依据（按优先级）：
//   ① 匿名 + MAP_EXECUTABLE + RWX  —— mozjs 在 HarmonyOS NEXT 上的方案
//      (servo/mozjs commit 9e070eb: flags = MAP_PRIVATE|MAP_ANON|MAP_EXECUTABLE)
//   ② 匿名 + MAP_EXECUTABLE + RW → mprotect RX —— 同上的 W^X 变体
//   ③ memfd + 双视图（RW 视图 + RX 视图）—— XenDroid code_cache 方案
//   ④ 匿名 RWX（不带 MAP_EXECUTABLE）—— 对照，验证该标志是否必需
//
// 详见 docs/DESIGN.md §6.1 与 docs/JIT-PERMISSION.md。
#ifndef HX360E_JIT_PROBE_H
#define HX360E_JIT_PROBE_H

#include <cstddef>
#include <cstdint>
#include <string>

namespace hx360e {

enum class JitStrategy {
    kBaselineRw = 0,             // ⓪ 对照：匿名 RW（不涉及执行权限）
    kAnonRwMprotect = 1,         // ① 匿名 RW → mprotect RX  ★ 首选
    kFileMappingRxRw = 2,        // ② memfd 双视图（RW + RX）
    kAnonNoneExecMprotect = 3,   // ③ PROT_NONE+MAP_EXECUTABLE → RW → RX
    kAnonExecutableRwx = 4,      // ④ 匿名 + MAP_EXECUTABLE + RWX（内核去掉 W，放最后）
    kCount = 5,
};

struct StrategyResult {
    bool ok = false;         // 探测通过（写入机器码并调用返回 42）
    int errno_val = 0;       // 失败时的 errno
    const char* fail_step = nullptr; // 失败步骤描述；成功为 nullptr
};

struct JitProbeReport {
    StrategyResult strategies[static_cast<size_t>(JitStrategy::kCount)];
    int first_working = -1;  // 第一个可用的 JIT 策略索引；-1 = 全部失败
};

// 运行全部策略探测。每次调用都会重新探测（开销：毫秒级）。
JitProbeReport RunJitProbe();

/** 用非标 prctl(0x6a6974) 申请 JIT 权限；0=内核接受，-1 看 errno。 */
int EnableJitViaPrctl();

// 把报告格式化成单行字符串（hilog 连续多条会被缓冲丢弃，故合并输出）
std::string FormatJitReport(const JitProbeReport& report);

// 策略名称（用于日志与 UI 展示）
const char* JitStrategyName(int strategy);

// memfd 双视图探测（代码缓存改双视图方案的前置验证）。
//
// 与策略 ② 的区别：执行视图不是 mmap(PROT_EXEC)（鸿蒙会拒），而是
// 「先 mmap(RW) 再 mprotect(RX)」—— 即 MapFileView 的 OHOS 分支所用的路径。
// 验证两点：
//   1) 通过写视图写入、经执行视图执行能成功；
//   2) 执行视图已经是 RX 之后，再通过写视图写入第二个函数并能执行
//      （这正是单区域 W^X 方案会丢 X 的场景）。
// 返回单行报告字符串（hilog 多行会被丢，故合并）。
std::string RunMemfdTwoViewProbe();

}  // namespace hx360e

#endif  // HX360E_JIT_PROBE_H
