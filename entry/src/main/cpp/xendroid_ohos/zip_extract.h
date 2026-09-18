// ZIP 解压（store/deflate + ZipCrypto + WinZip AES）。
//
// 只用 NDK 自带的 libz 做 raw deflate（inflateInit2(-15)）与 crc32，
// 密码学原语自带（见 zip_crypto.h）。7z / RAR 不在范围内。
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace hxzip {

/** 解压结果：UI 直接拿 need_password / bad_password 决定要不要弹密码框。 */
struct ExtractResult {
  bool ok = false;
  /** 失败原因（已是可直接显示的中文）。 */
  std::string error;
  /** 已写出字节数 / 文件数。 */
  uint64_t written = 0;
  uint32_t files = 0;
  /** 包内有加密项但没给密码（需要弹框询问）。 */
  bool need_password = false;
  /** 给了密码但校验不过（口令错，或 ZipCrypto/AES 校验失败）。 */
  bool bad_password = false;
  /** 用户取消。 */
  bool canceled = false;
};

/** 进度回调：返回 false 表示取消（安装浮层的取消按钮）。 */
struct ExtractProgress {
  uint64_t done = 0;    // 已写出
  uint64_t total = 0;   // 总解压后大小（预扫描得到）
  std::string name;     // 当前条目
};
using ProgressFn = std::function<bool(const ExtractProgress&)>;

/**
 * 把 zip（可多卷）解压到 dest_dir（内部会按需建子目录）。
 *
 * @param part_paths 分卷文件路径，**必须按卷顺序**给出（WinRAR/7-Zip 的
 *                   `.z01/.z02/.../.zip`、`.001/.002/...` 都是连续切分，
 *                   按序拼接即一个完整 zip）。单卷就传一个元素。
 * @param password 空串 = 没有密码。包内若有加密项且 password 为空，直接返回
 *                 need_password=true（不落任何文件）。
 * @return 结果；ok=false 时看 error / need_password / bad_password。
 */
ExtractResult Extract(const std::vector<std::string>& part_paths,
                      const std::string& dest_dir, const std::string& password,
                      const ProgressFn& on_progress);

/** 单卷便捷重载。 */
inline ExtractResult Extract(const std::string& zip_path,
                             const std::string& dest_dir,
                             const std::string& password,
                             const ProgressFn& on_progress) {
  std::vector<std::string> one;
  one.push_back(zip_path);
  return Extract(one, dest_dir, password, on_progress);
}

}  // namespace hxzip
