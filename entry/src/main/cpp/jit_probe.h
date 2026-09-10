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

// 把报告格式化成单行字符串（hilog 连续多条会被缓冲丢弃，故合并输出）
std::string FormatJitReport(const JitProbeReport& report);

// 策略名称（用于日志与 UI 展示）
const char* JitStrategyName(int strategy);

}  // namespace hx360e

#endif  // HX360E_JIT_PROBE_H
