#include "ohos_emulator.h"

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

#include "third_party/fmt/include/fmt/format.h"

#include "xenia/apu/nop/nop_audio_system.h"
#include "xenia/base/cvar.h"
#include "xenia/base/logging.h"
#include "xenia/base/platform_arm64.h"
#include "xenia/base/threading.h"
#include "xenia/config.h"
#include "xenia/emulator.h"
#include "xenia/gpu/vulkan/vulkan_graphics_system.h"
#include "xenia/hid/nop/nop_hid.h"

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

DECLARE_bool(host_present_from_non_ui_thread);
DECLARE_path(log_file);
DECLARE_bool(log_append);
DECLARE_bool(log_to_stdout);

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

std::vector<std::unique_ptr<xe::hid::InputDriver>> CreateInputDrivers(
    xe::ui::Window* window) {
  std::vector<std::unique_ptr<xe::hid::InputDriver>> drivers;
  drivers.emplace_back(xe::hid::nop::Create(window, /*window_z_order=*/0));
  return drivers;
}

void BootThread() {
  HXLOG("HX360E boot: thread start");
  xe::threading::set_name("hx360e-boot");

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
    g_booting.store(false);
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
  cvars::log_file = (log_dir / "xe.log").string();
  cvars::log_append = true;
  cvars::log_to_stdout = true;
  xe::InitializeLogging("hx360e");
  HXLOG("HX360E boot: logging initialized at %{public}s",
        cvars::log_file.string().c_str());

  config::SetupConfig(storage);
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

  // ---- 用窗口创建并启动内核 ----
  auto emulator = std::make_unique<xe::Emulator>("", storage, content, cache);
  xe::X_STATUS result = emulator->Setup(
      window, /*imgui_drawer=*/nullptr, /*require_cpu_backend=*/true,
      CreateAudioSystem, CreateGraphicsSystem, CreateInputDrivers);
  if (XFAILED(result)) {
    HXLOGE("HX360E boot: emulator Setup failed: 0x%{public}u",
           static_cast<unsigned>(result));
    g_booting.store(false);
    return;
  }
  result = emulator->SetupSubsystems();
  if (XFAILED(result)) {
    HXLOGE("HX360E boot: SetupSubsystems failed: 0x%{public}u",
           static_cast<unsigned>(result));
    g_booting.store(false);
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

  if (!g_game_path.empty()) {
    result = g_emulator->LaunchPath(std::filesystem::path(g_game_path));
    if (XFAILED(result)) {
      HXLOGE("HX360E boot: LaunchPath failed: 0x%{public}u",
             static_cast<unsigned>(result));
      g_running.store(false);
      g_booting.store(false);
      return;
    }
  }

  HXLOG("HX360E boot: title launched, entering WaitUntilExit");
  g_emulator->WaitUntilExit();
  HXLOG("HX360E boot: emulator exited");
  g_running.store(false);
  g_booting.store(false);

  // 退出 UI 循环。
  app_context->CallInUIThreadSynchronous(
      [&]() { app_context->QuitFromUIThread(); });
  if (g_ui_thread.joinable()) {
    g_ui_thread.join();
  }
  {
    std::lock_guard<std::mutex> lock(g_ui_mutex);
    g_window.reset();
    g_app_context.reset();
  }
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

void Boot() {
  HXLOG("HX360E Boot() called, booting=%{public}d", g_booting.load() ? 1 : 0);
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

}  // namespace hx360e
