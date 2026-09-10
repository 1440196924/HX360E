// jit_probe.cpp
// 可执行内存探测。
//
// 实测结论（2026-09-08，HUAWEI MateBook Pro S / Maleoon 935 / HarmonyOS 6.1.1）：
//   · 匿名 mmap 不带 MAP_EXECUTABLE → EINVAL（内核 XPM 拒绝 PROT_EXEC）
//   · 匿名 mmap 带 MAP_EXECUTABLE   → 映射成功，但内核把 W 权限去掉，
//     页变成只读，写入即 SIGSEGV(SEGV_ACCERR)
//   ⇒ 正确路径：普通 RW 映射写入，再 mprotect 到 RX。
//
// 因此探测顺序为：普通 RW → mprotect RX 优先；带 MAP_EXECUTABLE 的放最后
// （已知会崩），并全程用 sigsetjmp 保护。
#include "jit_probe.h"

#include <cerrno>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include <sys/mman.h>
#include <unistd.h>

#include <hilog/log.h>

namespace hx360e {

namespace {

// mov w0, #42 ; ret  →  AArch64 编码
constexpr uint32_t kProbeCode[] = {0x52800540u, 0xD65F03C0u};
using ProbeFn = int (*)();

constexpr size_t kPageSize = 4096;

#define HILOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)

// ---- 信号保护：把探测期的 SIGSEGV/SIGBUS 变成可报告的失败 ----

sigjmp_buf g_probe_jmp;
volatile sig_atomic_t g_probe_active = 0;
volatile sig_atomic_t g_probe_stage = 0;  // 1=写，2=执行

struct sigaction g_old_segv;
struct sigaction g_old_bus;

void ProbeSignalHandler(int sig, siginfo_t* /*info*/, void* /*ctx*/) {
    if (g_probe_active) {
        g_probe_active = 0;
        siglongjmp(g_probe_jmp, sig);
    }
    sigaction(SIGSEGV, &g_old_segv, nullptr);
    sigaction(SIGBUS, &g_old_bus, nullptr);
    raise(sig);
}

void InstallProbeHandlers() {
    struct sigaction sa {};
    sa.sa_sigaction = ProbeSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_old_segv);
    sigaction(SIGBUS, &sa, &g_old_bus);
}

void RestoreProbeHandlers() {
    sigaction(SIGSEGV, &g_old_segv, nullptr);
    sigaction(SIGBUS, &g_old_bus, nullptr);
}

void ClearInstructionCache(void* begin, void* end) {
    __builtin___clear_cache(static_cast<char*>(begin), static_cast<char*>(end));
}

// 执行已就绪的代码页（内容需事先写入）。用信号保护执行阶段。
bool ExecProbe(void* exec_base, StrategyResult* out) {
    int sig = sigsetjmp(g_probe_jmp, 1);
    if (sig != 0) {
        g_probe_active = 0;
        g_probe_stage = 0;
        out->errno_val = 0;
        out->fail_step = (sig == SIGSEGV)
                             ? (g_probe_stage == 1 ? "SIGSEGV on write"
                                                   : "SIGSEGV on exec")
                             : "SIGBUS";
        return false;
    }
    g_probe_active = 1;
    g_probe_stage = 2;
    int ret = reinterpret_cast<ProbeFn>(exec_base)();
    g_probe_active = 0;
    g_probe_stage = 0;
    if (ret != 42) {
        out->errno_val = 0;
        out->fail_step = "probe call returned wrong value";
        return false;
    }
    return true;
}

// ⓪ 对照：匿名 RW 映射。
StrategyResult ProbeBaselineRw() {
    StrategyResult r;
    void* base = mmap(nullptr, kPageSize, PROT_READ | PROT_WRITE,
                      MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap anon RW (baseline)";
        return r;
    }
    std::memset(base, 0xA5, kPageSize);
    munmap(base, kPageSize);
    r.ok = true;
    return r;
}

// ① 普通匿名 RW → 写入 → mprotect RX → 执行  ★ 首选
StrategyResult ProbeAnonRwMprotect() {
    StrategyResult r;
    void* base = mmap(nullptr, kPageSize, PROT_READ | PROT_WRITE,
                      MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap anon RW";
        return r;
    }
    std::memcpy(base, kProbeCode, sizeof(kProbeCode));
    if (mprotect(base, kPageSize, PROT_READ | PROT_EXEC) != 0) {
        r.errno_val = errno;
        r.fail_step = "mprotect RW->RX";
        munmap(base, kPageSize);
        return r;
    }
    ClearInstructionCache(base, static_cast<char*>(base) + sizeof(kProbeCode));
    bool ok = ExecProbe(base, &r);
    munmap(base, kPageSize);
    if (ok) r.ok = true;
    return r;
}

// ② memfd + 双视图：RW 写入视图 + RX 执行视图，同一文件对象。
StrategyResult ProbeFileMappingRxRw() {
    StrategyResult r;
    int fd = memfd_create("jit_probe_rxrw", 0);
    if (fd < 0) {
        fd = static_cast<int>(syscall(279, "jit_probe_rxrw", 0));
    }
    if (fd < 0) {
        r.errno_val = errno;
        r.fail_step = "memfd_create";
        return r;
    }
    if (ftruncate(fd, kPageSize) != 0) {
        r.errno_val = errno;
        r.fail_step = "ftruncate";
        close(fd);
        return r;
    }
    void* write_view = mmap(nullptr, kPageSize, PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, 0);
    if (write_view == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap RW view";
        close(fd);
        return r;
    }
    void* exec_view = mmap(nullptr, kPageSize, PROT_READ | PROT_EXEC,
                           MAP_SHARED, fd, 0);
    if (exec_view == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap RX view";
        munmap(write_view, kPageSize);
        close(fd);
        return r;
    }
    std::memcpy(write_view, kProbeCode, sizeof(kProbeCode));
    ClearInstructionCache(exec_view,
                          static_cast<char*>(exec_view) + sizeof(kProbeCode));
    bool ok = ExecProbe(exec_view, &r);
    munmap(write_view, kPageSize);
    munmap(exec_view, kPageSize);
    close(fd);
    if (ok) r.ok = true;
    return r;
}

// ③ PROT_NONE + MAP_EXECUTABLE → mprotect RW → 写 → mprotect RX → 执行
//    （V8 在无 PKU/MAP_JIT 时的三段式；MAP_EXECUTABLE 先声明 JIT 区域）
StrategyResult ProbeAnonNoneExecMprotect() {
    StrategyResult r;
    void* base = mmap(nullptr, kPageSize, PROT_NONE,
                      MAP_ANONYMOUS | MAP_PRIVATE | MAP_EXECUTABLE, -1, 0);
    if (base == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap anon PROT_NONE+MAP_EXECUTABLE";
        return r;
    }
    if (mprotect(base, kPageSize, PROT_READ | PROT_WRITE) != 0) {
        r.errno_val = errno;
        r.fail_step = "mprotect NONE->RW";
        munmap(base, kPageSize);
        return r;
    }
    std::memcpy(base, kProbeCode, sizeof(kProbeCode));
    if (mprotect(base, kPageSize, PROT_READ | PROT_EXEC) != 0) {
        r.errno_val = errno;
        r.fail_step = "mprotect RW->RX";
        munmap(base, kPageSize);
        return r;
    }
    ClearInstructionCache(base, static_cast<char*>(base) + sizeof(kProbeCode));
    bool ok = ExecProbe(base, &r);
    munmap(base, kPageSize);
    if (ok) r.ok = true;
    return r;
}

// ④ 匿名 + MAP_EXECUTABLE + RWX —— 已知内核会去掉 W，写入即崩，放最后。
StrategyResult ProbeAnonExecutableRwx() {
    StrategyResult r;
    void* base = mmap(nullptr, kPageSize,
                      PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_ANONYMOUS | MAP_PRIVATE | MAP_EXECUTABLE, -1, 0);
    if (base == MAP_FAILED) {
        r.errno_val = errno;
        r.fail_step = "mmap anon RWX+MAP_EXECUTABLE";
        return r;
    }
    HILOG("JIT probe: AnonExecRwx mapped at %{public}p", base);

    // 写入阶段也保护起来
    int sig = sigsetjmp(g_probe_jmp, 1);
    if (sig != 0) {
        g_probe_active = 0;
        g_probe_stage = 0;
        r.errno_val = 0;
        r.fail_step = "SIGSEGV on write";
        munmap(base, kPageSize);
        return r;
    }
    g_probe_active = 1;
    g_probe_stage = 1;
    std::memcpy(base, kProbeCode, sizeof(kProbeCode));
    g_probe_active = 0;

    ClearInstructionCache(base, static_cast<char*>(base) + sizeof(kProbeCode));
    bool ok = ExecProbe(base, &r);
    munmap(base, kPageSize);
    if (ok) r.ok = true;
    return r;
}

}  // namespace

JitProbeReport RunJitProbe() {
    JitProbeReport report;
    InstallProbeHandlers();

    // 顺序：安全且最可能成功的在前。
    // ③④ 暂不执行：实测它们会在写入阶段 SIGSEGV（内核给 MAP_EXECUTABLE
    // 映射剥离 W 权限），且 sigsetjmp 保护未能拦截，会中断整个探测。
    report.strategies[0] = ProbeBaselineRw();
    report.strategies[1] = ProbeAnonRwMprotect();
    report.strategies[2] = ProbeFileMappingRxRw();
    // report.strategies[3] = ProbeAnonNoneExecMprotect();
    // report.strategies[4] = ProbeAnonExecutableRwx();

    RestoreProbeHandlers();

    for (int i = 1; i < static_cast<int>(JitStrategy::kCount); ++i) {
        if (report.strategies[i].ok) {
            report.first_working = i;
            break;
        }
    }

    std::string line = "JIT probe: ";
    for (int i = 0; i < static_cast<int>(JitStrategy::kCount); ++i) {
        const auto& s = report.strategies[i];
        line += JitStrategyName(i);
        if (s.ok) {
            line += "=PASS ";
        } else {
            line += "=FAIL(" + std::to_string(s.errno_val) + "," +
                    (s.fail_step ? s.fail_step : "-") + ") ";
        }
    }
    line += "| firstWorking=" + std::to_string(report.first_working) + " (" +
            JitStrategyName(report.first_working) + ")";
    HILOG("%{public}s", line.c_str());
    return report;
}

std::string FormatJitReport(const JitProbeReport& report) {
    std::string line;
    for (int i = 0; i < static_cast<int>(JitStrategy::kCount); ++i) {
        const auto& s = report.strategies[i];
        line += JitStrategyName(i);
        line += s.ok ? "=PASS " : "=FAIL(" + std::to_string(s.errno_val) + ") ";
    }
    return line;
}

const char* JitStrategyName(int strategy) {
    switch (strategy) {
        case 0: return "BaselineRw";
        case 1: return "AnonRwMprot";
        case 2: return "FileMapRxRw";
        case 3: return "AnonNoneExecMprot";
        case 4: return "AnonExecRwx";
        default: return "None";
    }
}

std::string RunMemfdTwoViewProbe() {
    // 每个函数留 64B 槽位：第二个函数是在执行视图**已经是 RX** 之后才写入的，
    // 这正是单区域 W^X 方案会丢 X 的场景。
    constexpr size_t kSlotBytes = 64;
    bool memfd_ok = false;
    bool write_view_ok = false;
    bool exec_view_ok = false;
    bool exec_mprotect_ok = false;
    bool exec_first_ok = false;
    bool exec_second_ok = false;
    int err = 0;
    const char* fail = nullptr;
    const char* fail2 = nullptr;

    int fd = -1;
    void* write_view = MAP_FAILED;
    void* exec_view = MAP_FAILED;

    InstallProbeHandlers();

    fd = memfd_create("hx360e_memfd2v", 0);
    if (fd < 0) {
        err = errno;
        fail = "memfd_create";
    } else {
        memfd_ok = true;
        if (ftruncate(fd, kPageSize) != 0) {
            err = errno;
            fail = "ftruncate";
        } else {
            write_view = mmap(nullptr, kPageSize, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
            if (write_view == MAP_FAILED) {
                err = errno;
                fail = "mmap write view RW";
            } else {
                write_view_ok = true;
                // 与 MapFileView 的 OHOS 分支一致：先 RW 再 mprotect(RX)。
                exec_view = mmap(nullptr, kPageSize, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, 0);
                if (exec_view == MAP_FAILED) {
                    err = errno;
                    fail = "mmap exec view RW";
                } else {
                    exec_view_ok = true;
                    if (mprotect(exec_view, kPageSize,
                                 PROT_READ | PROT_EXEC) != 0) {
                        err = errno;
                        fail = "mprotect exec view RW->RX";
                    } else {
                        exec_mprotect_ok = true;

                        // 1) 第一次放置：写视图写入 → 执行视图执行。
                        std::memcpy(write_view, kProbeCode, sizeof(kProbeCode));
                        ClearInstructionCache(
                            exec_view,
                            static_cast<char*>(exec_view) + kSlotBytes);
                        StrategyResult r1;
                        exec_first_ok = ExecProbe(exec_view, &r1);
                        if (!exec_first_ok) {
                            fail = r1.fail_step ? r1.fail_step : "exec first";
                        }

                        // 2) 执行视图已是 RX 之后再放置第二个函数。
                        std::memcpy(
                            static_cast<char*>(write_view) + kSlotBytes,
                            kProbeCode, sizeof(kProbeCode));
                        ClearInstructionCache(
                            static_cast<char*>(exec_view) + kSlotBytes,
                            static_cast<char*>(exec_view) + 2 * kSlotBytes);
                        StrategyResult r2;
                        exec_second_ok = ExecProbe(
                            static_cast<char*>(exec_view) + kSlotBytes, &r2);
                        if (!exec_second_ok) {
                            fail2 = r2.fail_step ? r2.fail_step : "exec second";
                        }
                    }
                }
            }
        }
    }

    if (exec_view != MAP_FAILED) {
        munmap(exec_view, kPageSize);
    }
    if (write_view != MAP_FAILED) {
        munmap(write_view, kPageSize);
    }
    if (fd >= 0) {
        close(fd);
    }
    RestoreProbeHandlers();

    char report[360];
    std::snprintf(
        report, sizeof(report),
        "memfd2v: memfd=%d write_view=%d exec_view_rw=%d mprot_rx=%d exec1=%d "
        "exec2_after_rx=%d errno=%d fail=%s/%s",
        memfd_ok ? 1 : 0, write_view_ok ? 1 : 0, exec_view_ok ? 1 : 0,
        exec_mprotect_ok ? 1 : 0, exec_first_ok ? 1 : 0,
        exec_second_ok ? 1 : 0, err, fail ? fail : "-", fail2 ? fail2 : "-");
    return std::string(report);
}

}  // namespace hx360e
