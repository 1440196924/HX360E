// HX360E guest 提示 provider 实现（Phase 5.3）。
// 迁移自上游 xe_android_text_input.cpp / xe_android_message_box.cpp /
// xe_android_disc_swap.cpp（逻辑逐行一致，仅合并到一个 TU）。
#include "prompt_providers.h"

#include <algorithm>
#include <condition_variable>
#include <mutex>

#include "xenia/ui/host_disc_swap.h"
#include "xenia/ui/host_message_box.h"
#include "xenia/ui/host_text_input.h"

namespace xendroid {
namespace {

// ============================ 键盘 ============================

std::mutex g_text_mutex;
std::condition_variable g_text_cv;
uint64_t g_text_next_id = 1;
bool g_text_busy = false;
bool g_text_answered = false;
bool g_text_accepted = false;
uint64_t g_text_cancel_epoch = 0;
PendingTextInput g_text_request;
std::string g_text_answer;

bool ProvideText(const xe::ui::HostTextInputRequest& request,
                 xe::ui::HostTextInputResult& out_result) {
  std::unique_lock<std::mutex> lock(g_text_mutex);
  const uint64_t epoch = g_text_cancel_epoch;

  g_text_cv.wait(lock, [&] { return !g_text_busy || g_text_cancel_epoch != epoch; });
  if (g_text_cancel_epoch != epoch) {
    return false;
  }

  g_text_busy = true;
  g_text_answered = false;
  g_text_accepted = false;
  g_text_answer.clear();
  g_text_request = PendingTextInput{g_text_next_id++, request.title,
                                    request.description, request.default_text,
                                    request.max_length, request.flags};

  g_text_cv.wait(lock, [&] { return g_text_answered || g_text_cancel_epoch != epoch; });

  const bool answered = g_text_answered;
  out_result.accepted = answered && g_text_accepted;
  out_result.text = answered ? g_text_answer : std::string();

  g_text_busy = false;
  g_text_request = PendingTextInput{};
  g_text_answer.clear();
  g_text_cv.notify_all();
  return answered;
}

// ============================ 对话框 ============================

std::mutex g_box_mutex;
std::condition_variable g_box_cv;
uint64_t g_box_next_id = 1;
bool g_box_busy = false;
bool g_box_answered = false;
uint32_t g_box_answer = 0;
uint64_t g_box_cancel_epoch = 0;
PendingMessageBox g_box_request;

bool ProvideMessageBox(const xe::ui::HostMessageBoxRequest& request,
                       xe::ui::HostMessageBoxResult& out_result) {
  std::unique_lock<std::mutex> lock(g_box_mutex);
  const uint64_t epoch = g_box_cancel_epoch;

  g_box_cv.wait(lock, [&] { return !g_box_busy || g_box_cancel_epoch != epoch; });
  if (g_box_cancel_epoch != epoch) {
    return false;
  }

  g_box_busy = true;
  g_box_answered = false;
  g_box_answer = 0;
  g_box_request = PendingMessageBox{};
  g_box_request.id = g_box_next_id++;
  g_box_request.title = request.title;
  g_box_request.text = request.text;
  g_box_request.buttons = request.buttons;
  g_box_request.active_button = request.active_button;
  g_box_request.flags = request.flags;

  g_box_cv.wait(lock, [&] { return g_box_answered || g_box_cancel_epoch != epoch; });

  const bool answered = g_box_answered;
  if (answered) {
    out_result.chosen_button = g_box_answer;
  }

  g_box_busy = false;
  g_box_request = PendingMessageBox{};
  g_box_answer = 0;
  g_box_cv.notify_all();
  return answered;
}

// ============================ 换盘 ============================

std::mutex g_disc_mutex;
std::condition_variable g_disc_cv;
uint64_t g_disc_next_id = 1;
bool g_disc_busy = false;
bool g_disc_answered = false;
bool g_disc_accepted = false;
uint64_t g_disc_cancel_epoch = 0;
PendingDiscSwap g_disc_request;
std::string g_disc_answer;
std::vector<std::string> g_disc_known_labels;
std::vector<std::string> g_disc_known_paths;

bool ProvideDiscSwap(const xe::ui::HostDiscSwapRequest& request,
                     xe::ui::HostDiscSwapResult& out_result) {
  std::unique_lock<std::mutex> lock(g_disc_mutex);
  const uint64_t epoch = g_disc_cancel_epoch;

  g_disc_cv.wait(lock, [&] { return !g_disc_busy || g_disc_cancel_epoch != epoch; });
  if (g_disc_cancel_epoch != epoch) {
    return false;
  }

  g_disc_busy = true;
  g_disc_answered = false;
  g_disc_accepted = false;
  g_disc_answer.clear();
  g_disc_request = PendingDiscSwap{};
  g_disc_request.id = g_disc_next_id++;
  g_disc_request.message = request.message;
  g_disc_request.is_error = request.is_error;
  g_disc_request.disc_number = request.disc_number;
  if (!request.discs.empty()) {
    for (const auto& disc : request.discs) {
      g_disc_request.disc_labels.push_back(disc.label);
      g_disc_request.disc_paths.push_back(disc.path_utf8);
    }
  } else {
    g_disc_request.disc_labels = g_disc_known_labels;
    g_disc_request.disc_paths = g_disc_known_paths;
  }

  g_disc_cv.wait(lock, [&] { return g_disc_answered || g_disc_cancel_epoch != epoch; });

  const bool answered = g_disc_answered;
  out_result.accepted = answered && g_disc_accepted;
  out_result.path_utf8 = answered ? g_disc_answer : std::string();

  g_disc_busy = false;
  g_disc_request = PendingDiscSwap{};
  g_disc_answer.clear();
  g_disc_cv.notify_all();
  return answered;
}

}  // namespace

// ============================ 公开 API ============================

void InstallTextInputProvider() {
  xe::ui::SetHostTextInputProvider(&ProvideText, &CancelAllTextInput);
}

bool PeekTextInputRequest(PendingTextInput& out_request) {
  std::lock_guard<std::mutex> lock(g_text_mutex);
  if (!g_text_busy || g_text_answered) {
    return false;
  }
  out_request = g_text_request;
  return true;
}

void SubmitTextInput(uint64_t id, bool accepted, const std::string& text_utf8) {
  std::lock_guard<std::mutex> lock(g_text_mutex);
  if (!g_text_busy || g_text_answered || g_text_request.id != id) {
    return;
  }
  g_text_answered = true;
  g_text_accepted = accepted;
  g_text_answer = text_utf8;
  g_text_cv.notify_all();
}

void CancelAllTextInput() {
  std::lock_guard<std::mutex> lock(g_text_mutex);
  ++g_text_cancel_epoch;
  g_text_cv.notify_all();
}

void InstallMessageBoxProvider() {
  xe::ui::SetHostMessageBoxProvider(&ProvideMessageBox, &CancelAllMessageBox);
}

bool PeekMessageBoxRequest(PendingMessageBox& out_request) {
  std::lock_guard<std::mutex> lock(g_box_mutex);
  if (!g_box_busy || g_box_answered) {
    return false;
  }
  out_request = g_box_request;
  return true;
}

void SubmitMessageBox(uint64_t id, uint32_t chosen_button) {
  std::lock_guard<std::mutex> lock(g_box_mutex);
  if (!g_box_busy || g_box_answered || g_box_request.id != id) {
    return;
  }
  g_box_answered = true;
  g_box_answer = chosen_button < g_box_request.buttons.size()
                     ? chosen_button
                     : g_box_request.active_button;
  g_box_cv.notify_all();
}

void CancelAllMessageBox() {
  std::lock_guard<std::mutex> lock(g_box_mutex);
  ++g_box_cancel_epoch;
  g_box_cv.notify_all();
}

void InstallDiscSwapProvider() {
  xe::ui::SetHostDiscSwapProvider(&ProvideDiscSwap, &CancelAllDiscSwap);
}

void SetKnownDiscs(std::vector<std::string> labels,
                   std::vector<std::string> paths) {
  std::lock_guard<std::mutex> lock(g_disc_mutex);
  const size_t count = std::min(labels.size(), paths.size());
  labels.resize(count);
  paths.resize(count);
  g_disc_known_labels = std::move(labels);
  g_disc_known_paths = std::move(paths);
}

bool PeekDiscSwapRequest(PendingDiscSwap& out_request) {
  std::lock_guard<std::mutex> lock(g_disc_mutex);
  if (!g_disc_busy || g_disc_answered) {
    return false;
  }
  out_request = g_disc_request;
  return true;
}

void SubmitDiscSwap(uint64_t id, bool accepted, const std::string& path_utf8) {
  std::lock_guard<std::mutex> lock(g_disc_mutex);
  if (!g_disc_busy || g_disc_answered || g_disc_request.id != id) {
    return;
  }
  g_disc_answered = true;
  g_disc_accepted = accepted && !path_utf8.empty();
  g_disc_answer = path_utf8;
  g_disc_cv.notify_all();
}

void CancelAllDiscSwap() {
  std::lock_guard<std::mutex> lock(g_disc_mutex);
  ++g_disc_cancel_epoch;
  g_disc_cv.notify_all();
}

void InstallAllPromptProviders() {
  InstallTextInputProvider();
  InstallMessageBoxProvider();
  InstallDiscSwapProvider();
}

}  // namespace xendroid
