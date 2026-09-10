// HX360E OHOS 窗口/UI 上下文（Phase 2）。
//
// XComponent(SURFACE) 的 OHNativeWindow 由 ArkUI 主线程回调给出；Vulkan
// presenter 需要把它包成 ui::Surface 交给 swapchain。这里实现最小的
// OhosWindowedAppContext（mutex+cv 的 UI 线程队列）与 OhosWindow（持有
// OHNativeWindow 并创建 OHOSNativeWindowSurface）。
#ifndef HX360E_XENDROID_OHOS_OHOS_WINDOW_H_
#define HX360E_XENDROID_OHOS_OHOS_WINDOW_H_

#include <native_window/external_window.h>

#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string_view>

#include "xenia/ui/surface.h"
#include "xenia/ui/window.h"
#include "xenia/ui/windowed_app_context.h"

namespace hx360e {

class OhosWindow;

class OhosWindowedAppContext final : public xe::ui::WindowedAppContext {
 public:
  OhosWindowedAppContext() = default;
  ~OhosWindowedAppContext() override;

  void NotifyUILoopOfPendingFunctions() override;
  void PlatformQuitFromUIThread() override;

  // Runs pending UI functions until quit. Must be called on the UI thread.
  void MainLoop();

  // XComponent surface handoff (called from the ArkUI main thread).
  void SetWindowSurface(OHNativeWindow* window_surface);
  OHNativeWindow* window_surface() const;

  void SetActivityWindow(OhosWindow* window);
  OhosWindow* activity_window() const;

 private:
  mutable std::mutex mutex_;
  std::condition_variable cond_;
  bool pending_ = false;
  bool quit_ = false;

  OHNativeWindow* window_surface_ = nullptr;
  OhosWindow* activity_window_ = nullptr;
};

class OhosWindow final : public xe::ui::Window {
 public:
  OhosWindow(xe::ui::WindowedAppContext& app_context,
             const std::string_view title, uint32_t desired_logical_width,
             uint32_t desired_logical_height);
  ~OhosWindow() override;

  // XComponent surface created / changed (marshal to the UI thread).
  void UpdateSurface();

 protected:
  bool OpenImpl() override;
  void RequestCloseImpl() override;
  std::unique_ptr<xe::ui::Surface> CreateSurfaceImpl(
      xe::ui::Surface::TypeFlags allowed_types) override;
  void RequestPaintImpl() override;
};

}  // namespace hx360e

#endif  // HX360E_XENDROID_OHOS_OHOS_WINDOW_H_
