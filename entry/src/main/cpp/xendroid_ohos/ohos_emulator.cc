#include "ohos_emulator.h"

#include <fcntl.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <hilog/log.h>

// hilog 默认 LOG_TAG 为 NULL，会导致日志被丢弃；显式定义。
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

#include "ohos_window.h"
#include "ohos_input_driver.h"
#include "prompt_providers.h"

#include "third_party/fmt/include/fmt/format.h"

#include "xenia/apu/nop/nop_audio_system.h"
#include "xenia/base/cvar.h"
#include "xenia/base/exception_handler.h"
#include "xenia/base/frame_stats.h"
#include "xenia/base/logging.h"
#include "xenia/base/platform_arm64.h"
#include "xenia/base/shader_compile_counter.h"
#include "xenia/base/threading.h"
#include "xenia/config.h"
#include "xenia/emulator.h"
#include "xenia/gpu/vulkan/vulkan_graphics_system.h"
#include "xenia/hid/nop/nop_hid.h"
#include "xenia/kernel/xam/profile_standalone.h"

// ---------------------------------------------------------------------------
// xenia 启动所需的 cvar（上游定义在 xendroid_emu.cpp / app/xenia_main.cc）。
// ---------------------------------------------------------------------------
DEFINE_string(gpu, "vulkan", "Graphics system. Use: [vulkan, null]", "GPU");
DEFINE_string(apu, "nop", "Audio system. Use: [any, nop]", "APU");
DEFINE_string(hid, "nop", "Input system. Use: [nop]", "HID");
DEFINE_path(storage_root, "",
            "Root path for persistent internal data storage (config, etc.).",
            "Storage");
DEFINE_path(content_root, "",
            "Root path for guest content storage (saves, etc.).", "Storage");
DEFINE_path(cache_root, "",
            "Root path for emulator/game cache files.", "Storage");
DEFINE_transient_path(target, "", "Specifies the target .xex or .iso to run.",
                      "General");
DEFINE_bool(mount_scratch, false, "Enable scratch mount", "Storage");
DEFINE_bool(mount_cache, false, "Enable cache mount", "Storage");
DEFINE_bool(mount_memory_unit, false, "Enable memory unit (MU) mount",
            "Storage");
DEFINE_bool(apu_aaudio_log_stats, false,
            "Log AAudio stream statistics (Android-only; no-op on OHOS).",
            "APU");
// 上游定义在 xendroid_emu.cpp（Android 专用）；OHOS 侧在 ui/presenter.cc 里没有，
// 由这里补上，供 Phase 5.5 的覆盖层开关与设置页使用。
DEFINE_bool(show_touch_overlay, true,
            "Draw the on-screen controller overlay.", "HID");

DECLARE_bool(host_present_from_non_ui_thread);
DECLARE_bool(show_debug_overlay);
DECLARE_bool(show_touch_overlay);
DECLARE_path(log_file);
DECLARE_bool(log_append);
DECLARE_bool(log_to_stdout);
DECLARE_string(logged_profile_slot_0_xuid);

#define HXLOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define HXLOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace hx360e {
namespace {

std::mutex g_mutex;
std::unique_ptr<xe::Emulator> g_emulator;
std::thread g_boot_thread;
std::atomic<bool> g_booting{false};
std::atomic<bool> g_running{false};
std::string g_game_path;
std::vector<std::string> g_launch_args;

// UI 线程对象（生命周期由 BootThread 管理），受 g_ui_mutex 保护。
std::mutex g_ui_mutex;
std::unique_ptr<OhosWindowedAppContext> g_app_context;
std::unique_ptr<OhosWindow> g_window;
std::thread g_ui_thread;
OHNativeWindow* g_pending_native_window = nullptr;

std::unique_ptr<xe::apu::AudioSystem> CreateAudioSystem(
    xe::cpu::Processor* processor) {
  return std::make_unique<xe::apu::nop::NopAudioSystem>(processor);
}

std::unique_ptr<xe::gpu::GraphicsSystem> CreateGraphicsSystem() {
  return std::make_unique<xe::gpu::vulkan::VulkanGraphicsSystem>();
}

// 输入驱动由 xenia 的 InputSystem 持有，这里只保留裸指针给 NAPI / 覆盖层。
std::atomic<OhosInputDriver*> g_input_driver{nullptr};

std::vector<std::unique_ptr<xe::hid::InputDriver>> CreateInputDrivers(
    xe::ui::Window* window) {
  std::vector<std::unique_ptr<xe::hid::InputDriver>> drivers;
  auto pad = std::make_unique<OhosInputDriver>(window, /*window_z_order=*/0);
  g_input_driver.store(pad.get());
  drivers.emplace_back(std::move(pad));
  return drivers;
}

void BootThread() {
  HXLOG("HX360E boot: thread start");
  xe::threading::set_name("hx360e-boot");

  // 所有退出路径（包括中途 return）都必须做完整收尾：
  //   1) 先释放 Emulator：它持有 4.5GB guest 地址空间，留着会让下一次启动的
  //      Memory::Initialize() 在固定地址 MapViews 失败 -> assert_always ->
  //      SIGTRAP（实测：第二次按「启动」）。
  //   2) 再让 UI 线程退出主循环并 join。window/app_context 必须由 UI 线程自己
  //      销毁 —— WindowedAppContext 的析构断言 IsInUIThread()，在别的线程销毁
  //      会 raise(SIGTRAP)（实测：首次启动失败后再点启动）。
  //   3) 最后才置 g_booting=false，避免上一次收尾未完成时下一次 Boot 重入。
  struct BootTeardownGuard {
    ~BootTeardownGuard() {
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_emulator) {
          HXLOG("HX360E boot: releasing emulator (guest address space)");
          g_emulator.reset();
        }
      }
      OhosWindowedAppContext* context = nullptr;
      {
        std::lock_guard<std::mutex> lock(g_ui_mutex);
        context = g_app_context.get();
      }
      if (context) {
        // 任意线程可调；UI 循环已退出时入队会被丢弃，不会死等。
        context->RequestDeferredQuit();
      }
      if (g_ui_thread.joinable()) {
        g_ui_thread.join();
      }
      g_running.store(false);
      g_booting.store(false);
      HXLOG("HX360E boot: teardown complete");
    }
  } boot_teardown_guard;
  (void)boot_teardown_guard;

  static std::once_flag parse_args_once;
  std::call_once(parse_args_once, [&]() {
    std::vector<std::string> args = g_launch_args;
    if (!g_game_path.empty()) {
      args.push_back("--target=" + g_game_path);
    }
    std::vector<char*> argv;
    argv.push_back(nullptr);
    for (auto& a : args) {
      argv.push_back(const_cast<char*>(a.c_str()));
    }
    int argc = static_cast<int>(argv.size());
    char** argv_data = argv.data();
    cvar::ParseLaunchArguments(argc, argv_data, "", {});
  });
  HXLOG("HX360E boot: args parsed, storage=%{public}s gpu=%{public}s",
        cvars::storage_root.string().c_str(), cvars::gpu.c_str());
  cvars::target = std::filesystem::path(g_game_path);
  cvars::host_present_from_non_ui_thread = true;

  std::filesystem::path storage = cvars::storage_root;
  if (storage.empty()) {
    HXLOGE("HX360E boot: storage_root is empty; call setupLaunchArgs first");
    return;
  }
  storage = std::filesystem::absolute(storage);
  std::filesystem::path content = cvars::content_root;
  if (content.empty()) {
    content = storage / "content";
  } else if (!content.is_absolute()) {
    content = storage / content;
  }
  std::filesystem::path cache = cvars::cache_root;
  if (cache.empty()) {
    cache = storage / "cache";
  } else if (!cache.is_absolute()) {
    cache = storage / cache;
  }

  std::error_code ec;
  std::filesystem::create_directories(storage, ec);
  std::filesystem::create_directories(content, ec);
  std::filesystem::create_directories(cache, ec);

  HXLOG("HX360E boot: storage=%{public}s", storage.string().c_str());
  HXLOG("HX360E boot: game=%{public}s", g_game_path.c_str());

  std::filesystem::path log_dir = storage.parent_path() / "logs";
  std::filesystem::create_directories(log_dir, ec);

  // 配置必须在日志初始化之前加载：SetupConfig() 会用 xenia-edge.config.toml
  // 覆盖 cvar（包括 log_append），若先初始化日志，它的打开模式会在之后被改回
  // false，logging.cc 就会用 "wt" 截断 xe.log —— 于是每次 boot 只剩本次开头，
  // 上一次运行（尤其是崩溃那次）的日志被丢掉。
  config::SetupConfig(storage);
  cvars::log_file = (log_dir / "xe.log").string();
  cvars::log_append = true;
  cvars::log_to_stdout = true;
  xe::InitializeLogging("hx360e");
  HXLOG("HX360E boot: logging initialized at %{public}s",
        cvars::log_file.string().c_str());
  {
    // 报告日志文件大小：确认确实是追加而不是被截断。
    std::error_code size_ec;
    const auto log_size = std::filesystem::file_size(cvars::log_file, size_ec);
    HXLOG("HX360E boot: log_append=%{public}d log_size=%{public}llu",
          cvars::log_append ? 1 : 0,
          size_ec ? 0ull : static_cast<unsigned long long>(log_size));
  }

  // ---- 崩溃安全诊断（native_fault.log）----
  // 信号处理器里只写这个 fd（write(2)），因此进程被默认动作杀掉时记录不会丢；
  // 上次崩溃的内容在这次（健康的）启动时回显到 hilog，之后清空。
  const std::string fault_log_path = (log_dir / "native_fault.log").string();
  {
    FILE* previous = fopen(fault_log_path.c_str(), "rb");
    if (previous) {
      char buffer[1024];
      size_t read_count;
      while ((read_count = fread(buffer, 1, sizeof(buffer) - 1, previous)) > 0) {
        buffer[read_count] = '\0';
        HXLOG("native_fault[prev]: %{public}s", buffer);
      }
      fclose(previous);
      truncate(fault_log_path.c_str(), 0);
    }
  }
  const int fault_fd =
      open(fault_log_path.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
  if (fault_fd >= 0) {
    xe::SetExceptionHandlerDiagnosticFd(fault_fd);
    // Self-test: proves the sink is wired up before any real fault happens.
    xe::WriteExceptionDiagnostic("OHOS-diag-selftest\n");
    HXLOG("HX360E boot: native fault log fd=%{public}d", fault_fd);
  }

  xe::arm64::InitFeatureFlags();

  // ---- 启动 UI 线程：创建 app context + window + 主循环 ----
  std::mutex ready_mutex;
  std::condition_variable ready_cv;
  bool window_ready = false;
  g_ui_thread = std::thread([&ready_mutex, &ready_cv, &window_ready]() {
    OhosWindowedAppContext* context = nullptr;
    {
      std::lock_guard<std::mutex> lock(g_ui_mutex);
      g_app_context = std::make_unique<OhosWindowedAppContext>();
      context = g_app_context.get();
      g_window = std::make_unique<OhosWindow>(*context, "HX360E", 1280, 720);
      g_window->Open();
      // Surface 可能在启动前就已到达，这里补上。
      if (g_pending_native_window) {
        context->SetWindowSurface(g_pending_native_window);
        g_window->UpdateSurface();
      }
    }
    HXLOG("HX360E boot: window opened");
    {
      std::lock_guard<std::mutex> lock(ready_mutex);
      window_ready = true;
    }
    ready_cv.notify_all();
    context->MainLoop();
    HXLOG("HX360E boot: UI thread exited");
    // 必须由 UI 线程自己销毁：WindowedAppContext 的析构断言 IsInUIThread()。
    {
      std::lock_guard<std::mutex> lock(g_ui_mutex);
      g_window.reset();
      g_app_context.reset();
    }
    HXLOG("HX360E boot: UI window/context destroyed");
  });
  {
    std::unique_lock<std::mutex> lock(ready_mutex);
    ready_cv.wait(lock, [&window_ready] { return window_ready; });
  }

  OhosWindow* window = nullptr;
  OhosWindowedAppContext* app_context = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_ui_mutex);
    window = g_window.get();
    app_context = g_app_context.get();
  }

  // ---- 档案：XBLA/GOD 等标题要求已登录档案，否则 guest 会弹
  // "no gamer profile signed in"。若 content 下无档案则创建一个默认档案，
  // 并让 slot 0 自动登录（ProfileManager 在 Emulator::Setup 期间构造，构造时
  // 读 logged_profile_slot_0_xuid cvar）。 ----
  {
    std::vector<xe::kernel::xam::StandaloneProfile> profiles =
        xe::kernel::xam::ListStandaloneProfiles(content);
    std::string xuid_hex;
    if (profiles.empty()) {
      // language=1(en), country=103(US)，与 Kotlin 的 XConfig 列表一致。
      xuid_hex = xe::kernel::xam::CreateStandaloneProfile(content, "Player", 1,
                                                          103);
      HXLOG("HX360E boot: created default profile xuid=%{public}s",
            xuid_hex.c_str());
    } else {
      xuid_hex = fmt::format("{:016X}", profiles[0].xuid);
      HXLOG("HX360E boot: using existing profile xuid=%{public}s",
            xuid_hex.c_str());
    }
    if (!xuid_hex.empty()) {
      cvars::logged_profile_slot_0_xuid = xuid_hex;
    } else {
      HXLOGE("HX360E boot: no profile available; XBLA/GOD may ask to sign in");
    }
  }

  // ---- 用窗口创建并启动内核 ----
  {
    // 上一次运行可能还留着实例（例如它没有正常结束），先释放其地址空间。
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_emulator) {
      HXLOG("HX360E boot: tearing down previous emulator before boot");
      g_emulator.reset();
    }
  }
  auto emulator = std::make_unique<xe::Emulator>("", storage, content, cache);
  xe::X_STATUS result = emulator->Setup(
      window, /*imgui_drawer=*/nullptr, /*require_cpu_backend=*/true,
      CreateAudioSystem, CreateGraphicsSystem, CreateInputDrivers);
  if (XFAILED(result)) {
    HXLOGE("HX360E boot: emulator Setup failed: 0x%{public}u",
           static_cast<unsigned>(result));
    return;
  }
  result = emulator->SetupSubsystems();
  if (XFAILED(result)) {
    HXLOGE("HX360E boot: SetupSubsystems failed: 0x%{public}u",
           static_cast<unsigned>(result));
    return;
  }

  // 连接 presenter（在 UI 线程上）。
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_emulator = std::move(emulator);
  }
  app_context->CallInUIThreadSynchronous([&]() {
    auto* graphics_system = g_emulator->graphics_system();
    if (graphics_system) {
      window->SetPresenter(graphics_system->presenter());
      HXLOG("HX360E boot: presenter connected");
    }
  });
  g_running.store(true);

  // guest 提示（键盘/对话框/换盘）：guest 线程会阻塞等宿主回答，ArkTS 侧轮询
  // 取请求、回填结果（Phase 5.3）。必须在 LaunchPath 之前安装。
  xendroid::InstallAllPromptProviders();

  if (!g_game_path.empty()) {
    result = g_emulator->LaunchPath(std::filesystem::path(g_game_path));
    if (XFAILED(result)) {
      HXLOGE("HX360E boot: LaunchPath failed: 0x%{public}u",
             static_cast<unsigned>(result));
      return;
    }
  }

  HXLOG("HX360E boot: title launched, entering WaitUntilExit");
  g_emulator->WaitUntilExit();
  HXLOG("HX360E boot: emulator exited");
  // 收尾（释放 Emulator + 退出并 join UI 线程 + 由 UI 线程销毁 window/context）
  // 统一由函数开头的 boot_teardown_guard 完成，覆盖所有 return 路径。
}

}  // namespace

void SetGamePath(const std::string& path) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_game_path = path;
}

void SetLaunchArgs(const std::vector<std::string>& args) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_launch_args = args;
}

void SetNativeWindow(void* native_window) {
  HXLOG("HX360E: SetNativeWindow(%{public}p)", native_window);
  OHNativeWindow* window_surface =
      reinterpret_cast<OHNativeWindow*>(native_window);
  std::lock_guard<std::mutex> lock(g_ui_mutex);
  g_pending_native_window = window_surface;
  if (g_app_context) {
    g_app_context->SetWindowSurface(window_surface);
    if (g_window) {
      OhosWindowedAppContext* context = g_app_context.get();
      OhosWindow* window = g_window.get();
      context->CallInUIThread([window]() { window->UpdateSurface(); });
    }
  }
}

void OnSurfaceResized() {
  HXLOG("HX360E: OnSurfaceResized");
  std::lock_guard<std::mutex> lock(g_ui_mutex);
  if (g_app_context && g_window) {
    OhosWindowedAppContext* context = g_app_context.get();
    OhosWindow* window = g_window.get();
    context->CallInUIThread([window]() { window->UpdateSurface(); });
  }
}

void Boot() {  HXLOG("HX360E Boot() called, booting=%{public}d", g_booting.load() ? 1 : 0);
  bool expected = false;
  if (!g_booting.compare_exchange_strong(expected, true)) {
    HXLOG("HX360E boot: already booting/running, ignored");
    return;
  }
  g_boot_thread = std::thread(BootThread);
  g_boot_thread.detach();
  HXLOG("HX360E Boot(): thread spawned");
}

void Pause() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_emulator) {
    g_emulator->Pause();
  }
}

void Resume() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_emulator) {
    g_emulator->Resume();
  }
}

void Quit() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_emulator && g_emulator->kernel_state()) {
    HXLOG("HX360E quit: terminating title");
    g_emulator->kernel_state()->TerminateTitle();
  }
}

bool IsRunning() { return g_running.load(); }

bool IsPaused() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_emulator ? g_emulator->is_paused() : false;
}

std::string ProbeFile(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) {
    return "open failed";
  }
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);

  const size_t kChunk = 4 * 1024 * 1024;
  std::vector<char> buf(kChunk);
  const char* kMagic = "MICROSOFT*XBOX*MEDIA";
  const size_t kMagicLen = 20;
  long offset = 0;
  long first_nonzero = -1;
  long nonzero = 0;
  long magic_offset = -1;
  size_t n = 0;
  while ((n = fread(buf.data(), 1, kChunk, f)) > 0) {
    for (size_t i = 0; i < n; ++i) {
      if (buf[i] != 0) {
        if (first_nonzero < 0) {
          first_nonzero = offset + static_cast<long>(i);
        }
        ++nonzero;
      }
    }
    if (magic_offset < 0) {
      for (size_t i = 0; i + kMagicLen <= n; ++i) {
        if (memcmp(buf.data() + i, kMagic, kMagicLen) == 0) {
          magic_offset = offset + static_cast<long>(i);
          break;
        }
      }
    }
    offset += static_cast<long>(n);
  }
  fclose(f);
  return fmt::format(
      "size={} first_nonzero={} nonzero_bytes={} xbox_magic={}", size,
      first_nonzero, nonzero, magic_offset);
}

std::string DeviceInfo() {
  std::string info;
  info += "gpu=";
  info += cvars::gpu;
  info += " apu=";
  info += cvars::apu;
  info += " hid=";
  info += cvars::hid;
  info += " storage=";
  info += cvars::storage_root.string();
  return info;
}

// ---------------------------------------------------------------------------
// 状态 / 调试（Phase 5.5）。
// ---------------------------------------------------------------------------
void ChangeSurface(int width, int height) {
  HXLOG("HX360E changeSurface: %{public}dx%{public}d", width, height);
  OnSurfaceResized();
}

float LastFrameTimeMs() {
  float instant_ms = 0.f;
  float avg_ms = 0.f;
  float fps = 0.f;
  xe::GetFrameStats(instant_ms, avg_ms, fps);
  return instant_ms;
}

float InstantFps() {
  float instant_ms = 0.f;
  float avg_ms = 0.f;
  float fps = 0.f;
  xe::GetFrameStats(instant_ms, avg_ms, fps);
  return instant_ms > 0.f ? (1000.0f / instant_ms) : 0.f;
}

float AverageFps() {
  float instant_ms = 0.f;
  float avg_ms = 0.f;
  float fps = 0.f;
  xe::GetFrameStats(instant_ms, avg_ms, fps);
  return fps;
}

std::string DebugOverlayText() {
  if (!cvars::show_debug_overlay) {
    return {};
  }
  float instant_ms = 0.f;
  float avg_ms = 0.f;
  float fps = 0.f;
  xe::GetFrameStats(instant_ms, avg_ms, fps);
  const uint32_t compiling = xe::shader_compiles_in_flight_count();

  char buf[256];
  const int n = std::snprintf(buf, sizeof(buf), "FPS %.0f\n%.1f ms (avg %.1f ms)",
                              fps, instant_ms, avg_ms);
  if (compiling > 0 && n > 0 && n < static_cast<int>(sizeof(buf))) {
    std::snprintf(buf + n, sizeof(buf) - n, "\ncompiling %u", compiling);
  }
  return std::string(buf);
}

bool ShowDebugOverlay() { return cvars::show_debug_overlay; }

bool ShowTouchOverlay() { return cvars::show_touch_overlay; }

void SetShowTouchOverlay(bool value) { cvars::show_touch_overlay = value; }

void FlushGpuCaches() {
  // 与上游一致：当前 xenia 基线没有 GraphicsSystem::FlushPipelineCache，
  // 保留接口占位（拿到 graphics_system 只为将来接上）。
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_emulator && g_emulator->graphics_system()) {
    // g_emulator->graphics_system()->FlushPipelineCache(1500);
  }
}

// ---------------------------------------------------------------------------
// 输入（Phase 4）：覆盖层 / NAPI 与物理手柄都汇总到 OhosInputDriver。
// ---------------------------------------------------------------------------
void PadKey(int key_index, bool pressed, int value) {
  OhosInputDriver* driver = g_input_driver.load();
  if (!driver) {
    return;
  }
  if (value < -32768) {
    value = -32768;
  } else if (value > 32767) {
    value = 32767;
  }
  driver->OnKey(key_index, pressed, static_cast<short>(value));
}

void PadReleaseAll() {
  OhosInputDriver* driver = g_input_driver.load();
  if (driver) {
    driver->ReleaseAll();
  }
}

bool PadStartPhysical() {
  OhosInputDriver* driver = g_input_driver.load();
  if (!driver) {
    return false;
  }
  driver->StartPhysicalGamepad();
  return true;
}

bool PadStopPhysical() {
  OhosInputDriver* driver = g_input_driver.load();
  if (!driver) {
    return false;
  }
  driver->StopPhysicalGamepad();
  return true;
}

}  // namespace hx360e
