// ZIP 解压的 NAPI 桥接。
//
// 为什么是"启动 + 轮询"而不是回调：解压要在后台线程跑（几 GB 不能占 UI 线程），
// 而后台线程不能直接调 ArkTS 回调（NAPI 只能在 JS 线程用）。所以这里把解压
// 放在 std::thread 里，状态挂在 job 上由 ArkTS 定时 poll，取消走原子标志。
// 同一时刻只允许一个 job（安装 UI 本身也是单实例的）。
#include "napi/native_api.h"

#include <hilog/log.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include "zip_extract.h"

namespace hx360e {
namespace {

constexpr char kTag[] = "HX360E";

/** 一个解压任务的共享状态（后台线程写、JS 线程读）。 */
struct ZipJob {
  std::thread worker;
  std::atomic<bool> cancel{false};
  std::atomic<bool> finished{false};

  std::mutex mu;
  uint64_t done = 0;
  uint64_t total = 0;
  std::string name;
  std::string error;
  uint32_t files = 0;
  bool ok = false;
  bool need_password = false;
  bool bad_password = false;
  bool canceled = false;
};

ZipJob* g_job = nullptr;
std::mutex g_job_mu;

std::string GetString(napi_env env, napi_value v) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
    return std::string();
  }
  std::string s(len, '\0');
  size_t out = 0;
  if (napi_get_value_string_utf8(env, v, &s[0], len + 1, &out) != napi_ok) {
    return std::string();
  }
  s.resize(out);
  return s;
}

napi_value MakeString(napi_env env, const std::string& s) {
  napi_value v = nullptr;
  napi_create_string_utf8(env, s.c_str(), s.size(), &v);
  return v;
}

napi_value MakeBool(napi_env env, bool b) {
  napi_value v = nullptr;
  napi_get_boolean(env, b, &v);
  return v;
}

napi_value MakeUint(napi_env env, uint64_t n) {
  napi_value v = nullptr;
  // 字节数可能超过 int32（几 GB），统一用 double 传，JS 侧 number 足够精确。
  napi_create_double(env, double(n), &v);
  return v;
}

napi_value ExtractStart(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return MakeString(env, "");
  }
  const std::string zip = GetString(env, args[0]);
  const std::string dest = GetString(env, args[1]);
  const std::string password = argc >= 3 ? GetString(env, args[2]) : std::string();

  std::lock_guard<std::mutex> lock(g_job_mu);
  if (g_job != nullptr) {
    return MakeString(env, "");
  }
  auto* job = new ZipJob();
  job->worker = std::thread([job, zip, dest, password]() {
    const hxzip::ExtractResult r = hxzip::Extract(
      zip, dest, password, [job](const hxzip::ExtractProgress& p) {
        std::lock_guard<std::mutex> l(job->mu);
        job->done = p.done;
        job->total = p.total;
        job->name = p.name;
        return !job->cancel.load();
      });
    {
      std::lock_guard<std::mutex> l(job->mu);
      job->done = r.written;
      job->ok = r.ok;
      job->error = r.error;
      job->files = r.files;
      job->need_password = r.need_password;
      job->bad_password = r.bad_password;
      job->canceled = r.canceled;
    }
    job->finished.store(true);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, kTag,
                 "zip: done ok=%{public}d files=%{public}u bytes=%{public}llu err=%{public}s",
                 r.ok ? 1 : 0, r.files, (unsigned long long)r.written,
                 r.error.c_str());
  });
  g_job = job;
  return MakeString(env, "zip");
}

napi_value ExtractPoll(napi_env env, napi_callback_info info) {
  std::lock_guard<std::mutex> lock(g_job_mu);
  napi_value o = nullptr;
  napi_create_object(env, &o);
  if (g_job == nullptr) {
    napi_set_named_property(env, o, "active", MakeBool(env, false));
    napi_set_named_property(env, o, "finished", MakeBool(env, true));
    return o;
  }
  ZipJob* job = g_job;
  std::unique_lock<std::mutex> l(job->mu);
  const uint64_t done = job->done;
  const uint64_t total = job->total;
  const std::string name = job->name;
  l.unlock();
  napi_set_named_property(env, o, "active", MakeBool(env, true));
  napi_set_named_property(env, o, "finished", MakeBool(env, job->finished.load()));
  napi_set_named_property(env, o, "done", MakeUint(env, done));
  napi_set_named_property(env, o, "total", MakeUint(env, total));
  napi_set_named_property(env, o, "name", MakeString(env, name));
  napi_set_named_property(env, o, "ok", MakeBool(env, job->ok));
  napi_set_named_property(env, o, "files", MakeUint(env, job->files));
  napi_set_named_property(env, o, "error", MakeString(env, job->error));
  napi_set_named_property(env, o, "needPassword", MakeBool(env, job->need_password));
  napi_set_named_property(env, o, "badPassword", MakeBool(env, job->bad_password));
  napi_set_named_property(env, o, "canceled", MakeBool(env, job->canceled));
  return o;
}

/** 请求取消（后台线程会在下一块检查）。 */
napi_value ExtractCancel(napi_env env, napi_callback_info info) {
  std::lock_guard<std::mutex> lock(g_job_mu);
  if (g_job != nullptr) {
    g_job->cancel.store(true);
  }
  return nullptr;
}

/** 收尾：等线程结束并销毁 job。必须在 poll 到 finished 之后调用。 */
napi_value ExtractFinish(napi_env env, napi_callback_info info) {
  ZipJob* job = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_job_mu);
    if (g_job == nullptr) {
      return nullptr;
    }
    job = g_job;
    g_job = nullptr;
  }
  if (job->worker.joinable()) {
    job->worker.join();
  }
  delete job;
  return nullptr;
}

}  // namespace

void RegisterZip(napi_env env, napi_value exports) {
  napi_value zip = nullptr;
  napi_create_object(env, &zip);
  napi_property_descriptor desc[] = {
    {"extractStart", nullptr, ExtractStart, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"extractPoll", nullptr, ExtractPoll, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"extractCancel", nullptr, ExtractCancel, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"extractFinish", nullptr, ExtractFinish, nullptr, nullptr, nullptr,
     napi_default, nullptr},
  };
  napi_define_properties(env, zip, sizeof(desc) / sizeof(desc[0]), desc);
  napi_set_named_property(env, exports, "zip", zip);
}

}  // namespace hx360e
