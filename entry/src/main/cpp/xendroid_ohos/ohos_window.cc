#include "ohos_window.h"

#include <chrono>

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "HX360E"

#include "xenia/ui/surface_ohos.h"

#include "ohos_emulator.h"
#include "xeg_spatial_upscale.h"

#define HXLOG(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)

namespace hx360e {

namespace {

}  // namespace

OhosWindowedAppContext::~OhosWindowedAppContext() = default;

void OhosWindowedAppContext::NotifyUILoopOfPendingFunctions() {
  std::lock_guard<std::mutex> lock(mutex_);
  pending_ = true;
  cond_.notify_one();
}

void OhosWindowedAppContext::PlatformQuitFromUIThread() {
  std::lock_guard<std::mutex> lock(mutex_);
  quit_ = true;
  cond_.notify_one();
}

void OhosWindowedAppContext::MainLoop() {
  while (!HasQuitFromUIThread()) {
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cond_.wait_for(lock, std::chrono::milliseconds(4),
                     [this] { return pending_ || paint_requested_ || quit_; });
      pending_ = false;
    }
    ExecutePendingFunctionsFromUIThread();
    // 呈现请求：presenter 在 PaintMode::kUIThreadOnRequest（FIFO 交换链，见
    // ui/presenter.cc GetDesiredPaintModeFromUIThread）下靠 Window::RequestPaint
    // 让 UI 线程 present —— 这里是它的落地处；安卓走
    // PostInvalidateWindowSurface → Choreographer → PaintActivitySurface。
    // FIFO present 自身阻塞到 vblank，所以不需要额外 vsync 计时。
    bool paint = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      paint = paint_requested_;
      paint_requested_ = false;
    }
    if (paint) {
      OhosWindow* window = activity_window();
      if (window) {
        window->PaintFromUIThread(false);
        ++paint_count_;
      }
    }
    // 诊断探针（每秒一条）：UI 线程 present 次数 vs guest FPS。
    // 若 paints/s ≈ 4 × guestFps，说明一个 guest 帧被 present 了多次，
    // 每次 FIFO present 阻塞一个 vblank → 正好 4×16.6ms ≈ 66.6ms。
    // 若 paints/s ≈ guestFps，则 present 节奏正常，瓶颈在别处。
    {
      auto now = std::chrono::steady_clock::now();
      if (probe_report_time_.time_since_epoch().count() == 0) {
        probe_report_time_ = now;
      } else if (now - probe_report_time_ >= std::chrono::seconds(1)) {
        const uint32_t paints = paint_count_;
        paint_count_ = 0;
        probe_report_time_ = now;
        HXLOG("present probe: paints/s=%{public}u guestInstantFps=%{public}.1f "
              "guestAvgFps=%{public}.1f frameMs=%{public}.1f xeg=[%{public}s]",
              paints, hx360e::InstantFps(), hx360e::AverageFps(),
              hx360e::LastFrameTimeMs(),
              hx360e::XegSpatialUpscale::GetStatusForDisplay().c_str());
      }
    }
  }
  HXLOG("OhosWindowedAppContext: main loop exited");
}

void OhosWindowedAppContext::RequestPaintOnUIThread() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (paint_requested_) {
      return;
    }
    paint_requested_ = true;
  }
  cond_.notify_one();
}

void OhosWindowedAppContext::SetWindowSurface(OHNativeWindow* window_surface) {
  std::lock_guard<std::mutex> lock(mutex_);
  window_surface_ = window_surface;
}

OHNativeWindow* OhosWindowedAppContext::window_surface() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return window_surface_;
}

void OhosWindowedAppContext::SetActivityWindow(OhosWindow* window) {
  std::lock_guard<std::mutex> lock(mutex_);
  activity_window_ = window;
}

OhosWindow* OhosWindowedAppContext::activity_window() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return activity_window_;
}

OhosWindow::OhosWindow(xe::ui::WindowedAppContext& app_context,
                       const std::string_view title,
                       uint32_t desired_logical_width,
                       uint32_t desired_logical_height)
    : Window(app_context, title, desired_logical_width, desired_logical_height) {
}

OhosWindow::~OhosWindow() {
  EnterDestructor();
  auto& context = static_cast<OhosWindowedAppContext&>(app_context());
  if (context.activity_window() == this) {
    context.SetActivityWindow(nullptr);
  }
}

bool OhosWindow::OpenImpl() {
  auto& context = static_cast<OhosWindowedAppContext&>(app_context());
  context.SetActivityWindow(this);

  // Report the initial size if the XComponent surface is already available.
  OHNativeWindow* window_surface = context.window_surface();
  if (window_surface) {
    int32_t width = 0, height = 0;
    // GET_BUFFER_GEOMETRY's variable parameters are (height, width), not
    // (width, height) - see native_window/external_window.h. Reading them the
    // other way round transposes the surface (1280x720 -> 720x1280), which
    // makes xenia create a portrait swapchain and the game appear stretched.
    if (OH_NativeWindow_NativeWindowHandleOpt(window_surface,
                                              GET_BUFFER_GEOMETRY, &height,
                                              &width) == 0 &&
        width > 0 && height > 0) {
      HXLOG("HX360E OpenImpl: initial buffer geometry %{public}dx%{public}d",
            width, height);
      WindowDestructionReceiver destruction_receiver(this);
      OnActualSizeUpdate(uint32_t(width), uint32_t(height),
                         destruction_receiver);
    }
  }
  return true;
}

void OhosWindow::RequestCloseImpl() {
  WindowDestructionReceiver destruction_receiver(this);
  OnBeforeClose(destruction_receiver);
  if (destruction_receiver.IsWindowDestroyed()) {
    return;
  }
  OnAfterClose();
}

std::unique_ptr<xe::ui::Surface> OhosWindow::CreateSurfaceImpl(
    xe::ui::Surface::TypeFlags allowed_types) {
  if (!(allowed_types & xe::ui::Surface::kTypeFlag_OHOSNativeWindow)) {
    return nullptr;
  }
  auto& context = static_cast<OhosWindowedAppContext&>(app_context());
  OHNativeWindow* window_surface = context.window_surface();
  if (!window_surface) {
    HXLOG("OhosWindow::CreateSurfaceImpl: no surface yet");
    return nullptr;
  }
  HXLOG("OhosWindow::CreateSurfaceImpl: window=%{public}p", window_surface);
  return std::make_unique<xe::ui::OHOSNativeWindowSurface>(window_surface);
}

void OhosWindow::RequestPaintImpl() {
  // 保持空实现：启动参数允许 IMMEDIATE/MAILBOX（非 FIFO），presenter 走
  // PaintMode::kGuestOutputThreadImmediately，呈现连接状态归 guest 输出线程独占，
  // UI 线程调 OnPaint 会 SIGSEGV（实测）。
  // 注意：之前尝试「强制 FIFO + UI 线程 paint」虽然让静态画面到 59fps，但实际上屏
  // 率掉到 ~8 次/秒（探针 paints/s=8，与 profiler 抓到的 8fps 一致），体感变卡，
  // 已回退。若将来要重做，必须先解决 UI 线程 paint 循环的吞吐（例如去掉 4ms
  // 轮询、按 vsync 驱动、并确认 XComponent buffer 数量足够）。
}

void OhosWindow::UpdateSurface() {
  // Called on the UI thread once the XComponent surface is available.
  if (phase() == Phase::kOpen) {
    WindowDestructionReceiver destruction_receiver(this);
    OnSurfaceChanged(true);
    if (destruction_receiver.IsWindowDestroyedOrClosed()) {
      return;
    }
    OHNativeWindow* window_surface =
        static_cast<OhosWindowedAppContext&>(app_context()).window_surface();
    if (window_surface) {
        int32_t width = 0, height = 0;
      // (height, width) - see the note in OpenImpl.
      if (OH_NativeWindow_NativeWindowHandleOpt(window_surface,
                                                GET_BUFFER_GEOMETRY, &height,
                                                &width) == 0 &&
          width > 0 && height > 0) {
        HXLOG("HX360E UpdateSurface: buffer geometry %{public}dx%{public}d",
              width, height);
        OnActualSizeUpdate(uint32_t(width), uint32_t(height),
                           destruction_receiver);
      } else {
        HXLOG("HX360E UpdateSurface: geometry query failed (%{public}d,%{public}d)",
              width, height);
      }
    }
  }
}

}  // namespace hx360e
