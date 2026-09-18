// ZIP 解压实现（store/deflate + ZipCrypto + WinZip AES）。
//
// 设计要点：
//  - 只用 NDK 自带的 libz：raw deflate 走 inflateInit2(-15)，校验走 crc32。
//  - 先读 EOCD（必要时 Zip64 EOCD/定位器）→ 中央目录全部读进内存 → 预扫描
//    算出总解压大小并判定是否存在加密项 → 再逐条流式解压。
//  - 数据起点必须用**本地头**的 name_len/extra_len 计算：中央目录里的
//    extra 字段和本地头的不一定一样长（这是最容易踩的坑）。
//  - 路径清洗：反斜杠归一、丢弃空段与 "."、遇到 ".." 或含 ':' 的段直接拒绝，
//    避免 zip-slip 写到沙箱外。
#include "zip_extract.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "zip_crypto.h"

namespace hxzip {
namespace {

constexpr uint32_t kSigLocal = 0x04034b50;
constexpr uint32_t kSigCentral = 0x02014b50;
constexpr uint32_t kSigEocd = 0x06054b50;
constexpr uint32_t kSigZip64Loc = 0x07064b50;
constexpr uint32_t kSigZip64Eocd = 0x06064b50;

/** 每次从磁盘读多少（也是 inflate 的输入块大小，uInt 装得下）。 */
constexpr size_t kChunk = 256 * 1024;
/** 进度回调节流：至少前进这么多字节才回报一次（大包别把 UI 打爆）。 */
constexpr uint64_t kReportStep = 4 * 1024 * 1024;
/** 中央目录最大允许 64MB（防御异常包）。 */
constexpr uint64_t kMaxCentralDir = 64ull * 1024 * 1024;

uint16_t Rd16(const uint8_t* p) {
  return uint16_t(uint32_t(p[0]) | (uint32_t(p[1]) << 8));
}

uint32_t Rd32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}

uint64_t Rd64(const uint8_t* p) {
  return uint64_t(Rd32(p)) | (uint64_t(Rd32(p + 4)) << 32);
}

/**
 * 一卷（一个分卷文件）到全局偏移的映射后，按序打开的一组文件。
 *
 * 分卷 ZIP（WinRAR/7-Zip 的"切分卷"）就是把原始 zip 字节流连续切开：
 * 各卷按顺序首尾相接就是一个完整合法的 zip（EOCD 里的偏移也是相对整个流的），
 * 所以这里把"单文件随机读"升级成"跨卷随机读"，其余解析逻辑完全不用改。
 */
struct VolumeSet {
  std::vector<int> fds;
  std::vector<uint64_t> starts;   // 每卷在全局流里的起始偏移
  uint64_t total = 0;

  ~VolumeSet() {
    for (int fd : fds) {
      if (fd >= 0) {
      }
    }
  }

  /** 按给定顺序打开所有卷；全部成功才返回 true。 */
  bool Open(const std::vector<std::string>& parts) {
    for (const std::string& p : parts) {
      const int fd = open(p.c_str(), O_RDONLY);
      if (fd < 0) {
        return false;
      }
      const off_t end = lseek(fd, 0, SEEK_END);
      if (end < 0) {
        return false;
      }
      starts.push_back(total);
      fds.push_back(fd);
      total += uint64_t(end);
    }
    return !fds.empty();
  }

  bool ReadAt(uint64_t off, void* buf, size_t len) const {
    uint8_t* p = static_cast<uint8_t*>(buf);
    if (off + len > total) {
      return false;
    }
    size_t got = 0;
    while (got < len) {
      const uint64_t g = off + got;
      // 定位到卷（卷数很少，线性找足够）。
      size_t i = fds.size() - 1;
      for (size_t k = 0; k + 1 < fds.size(); k++) {
        if (g < starts[k + 1]) {
          i = k;
          break;
        }
      }
      const uint64_t in_vol = g - starts[i];
      const uint64_t vol_avail = (i + 1 < fds.size() ? starts[i + 1] : total) -
        starts[i];
      const size_t chunk = size_t(std::min<uint64_t>(len - got,
        vol_avail - in_vol));
      const ssize_t n = pread(fds[i], p + got, chunk, off_t(in_vol));
      if (n <= 0) {
        return false;
      }
      got += size_t(n);
    }
    return true;
  }
};

/** 顺序读文件（大文件不能用一次 read，会被信号打断）。 */
bool ReadAt(int fd, uint64_t off, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t got = 0;
  while (got < len) {
    const ssize_t n = pread(fd, p + got, len - got, off_t(off + got));
    if (n <= 0) {
      return false;
    }
    got += size_t(n);
  }
  return true;
}

/** 递归建目录（mkdir 已存在会失败，忽略即可）。 */
void MakeDirs(const std::string& dir) {
  if (dir.empty()) {
    return;
  }
  for (size_t i = 1; i <= dir.size(); i++) {
    if (i == dir.size() || dir[i] == '/') {
      const std::string sub = dir.substr(0, i);
      if (!sub.empty() && sub != "/") {
        mkdir(sub.c_str(), 0755);
      }
    }
  }
}

/** 把条目名清洗成安全相对路径；不合法（逃逸/盘符）返回 false。 */
bool SanitizeName(const std::string& raw, std::string* out) {
  std::string s = raw;
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '\\') {
      s[i] = '/';
    }
  }
  std::vector<std::string> parts;
  size_t i = 0;
  while (i < s.size()) {
    size_t j = s.find('/', i);
    if (j == std::string::npos) {
      j = s.size();
    }
    const std::string comp = s.substr(i, j - i);
    i = j + 1;
    if (comp.empty() || comp == ".") {
      continue;
    }
    if (comp == ".." || comp.find(':') != std::string::npos) {
      return false;
    }
    parts.push_back(comp);
  }
  std::string clean;
  for (size_t k = 0; k < parts.size(); k++) {
    if (k) {
      clean += '/';
    }
    clean += parts[k];
  }
  *out = clean;
  return !clean.empty();
}

/** 标准 crc32 表（ZipCrypto 的密钥扰动表，与 zlib 的多项式一致）。 */
const uint32_t* CrcTable() {
  static uint32_t table[256];
  static bool built = false;
  if (!built) {
    for (uint32_t n = 0; n < 256; n++) {
      uint32_t c = n;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      }
      table[n] = c;
    }
    built = true;
  }
  return table;
}

/** 流式 HMAC-SHA1（WinZip AES 要对整段密文做 MAC，不能一次性放内存）。 */
struct HmacSha1Stream {
  Sha1Ctx ctx;
  uint8_t opad[64];

  void Init(const uint8_t* key, size_t key_len) {
    uint8_t k[64];
    HmacSha1PrepareKey(k, key, key_len);
    uint8_t ipad[64];
    for (int i = 0; i < 64; i++) {
      ipad[i] = uint8_t(k[i] ^ 0x36);
      opad[i] = uint8_t(k[i] ^ 0x5c);
    }
    Sha1Init(ctx);
    Sha1Update(ctx, ipad, 64);
  }

  void Update(const uint8_t* p, size_t n) {
    Sha1Update(ctx, p, n);
  }

  void Final(uint8_t out[20]) {
    uint8_t inner[20];
    Sha1Final(ctx, inner);
    Sha1Ctx c2;
    Sha1Init(c2);
    Sha1Update(c2, opad, 64);
    Sha1Update(c2, inner, 20);
    Sha1Final(c2, out);
  }
};

/** 中央目录里的一条记录。 */
struct Entry {
  std::string name;
  uint16_t flags = 0;
  uint16_t method = 0;
  uint16_t dostime = 0;
  uint32_t crc = 0;
  uint64_t comp_size = 0;
  uint64_t uncomp_size = 0;
  uint64_t local_off = 0;
  bool dir = false;
  bool encrypted = false;
  bool aes = false;
  int aes_strength = 0;      // 1=128 / 2=192 / 3=256
  uint16_t aes_method = 0;   // 真实压缩方法（AES 时 method 字段是 99）

  int AesKeyLen() const { return 16 + (aes_strength - 1) * 8; }
  int AesSaltLen() const { return 8 + (aes_strength - 1) * 4; }
};

/** 解析中央目录，失败返回 false 并填 error。 */
bool ParseCentralDir(const std::vector<uint8_t>& cd, std::vector<Entry>* out,
                     std::string* error) {
  size_t p = 0;
  while (p + 46 <= cd.size()) {
    if (Rd32(&cd[p]) != kSigCentral) {
      break;
    }
    Entry e;
    e.flags = Rd16(&cd[p + 8]);
    e.method = Rd16(&cd[p + 10]);
    e.dostime = Rd16(&cd[p + 12]);
    e.crc = Rd32(&cd[p + 16]);
    e.comp_size = Rd32(&cd[p + 20]);
    e.uncomp_size = Rd32(&cd[p + 24]);
    const uint16_t nlen = Rd16(&cd[p + 28]);
    const uint16_t elen = Rd16(&cd[p + 30]);
    const uint16_t clen = Rd16(&cd[p + 32]);
    const uint32_t ext_attr = Rd32(&cd[p + 38]);
    e.local_off = Rd32(&cd[p + 42]);
    if (p + 46 + nlen + elen + clen > cd.size()) {
      *error = "压缩包中央目录损坏";
      return false;
    }
    e.name.assign(reinterpret_cast<const char*>(&cd[p + 46]), nlen);
    const uint8_t* extra = &cd[p + 46 + nlen];

    // Zip64 扩展：只补那些在 32 位字段里被写成全 1 的值，顺序固定。
    size_t q = 0;
    while (q + 4 <= elen) {
      const uint16_t id = Rd16(extra + q);
      const uint16_t sz = Rd16(extra + q + 2);
      if (q + 4 + sz > elen) {
        break;
      }
      const uint8_t* d = extra + q + 4;
      if (id == 0x0001) {
        size_t r = 0;
        if (e.uncomp_size == 0xFFFFFFFFull && r + 8 <= sz) {
          e.uncomp_size = Rd64(d + r);
          r += 8;
        }
        if (e.comp_size == 0xFFFFFFFFull && r + 8 <= sz) {
          e.comp_size = Rd64(d + r);
          r += 8;
        }
        if (e.local_off == 0xFFFFFFFFull && r + 8 <= sz) {
          e.local_off = Rd64(d + r);
          r += 8;
        }
      } else if (id == 0x9901 && sz >= 7) {
        // WinZip AES：version(2) vendor(2) strength(1) real_method(2)
        e.aes = true;
        e.aes_strength = d[4];
        e.aes_method = Rd16(d + 5);
        if (e.aes_strength < 1 || e.aes_strength > 3) {
          *error = "压缩包使用了不支持的 AES 强度";
          return false;
        }
      }
      q += 4 + sz;
    }

    e.encrypted = (e.flags & 0x0001) != 0;
    if (e.aes) {
      e.encrypted = true;
      e.method = e.aes_method;
    }
    e.dir = (e.name.size() > 0 && e.name[e.name.size() - 1] == '/') ||
            ((ext_attr & 0x10) != 0 && e.comp_size == 0 &&
             e.uncomp_size == 0 && e.method == 0);
    out->push_back(e);
    p += 46 + size_t(nlen) + elen + clen;
  }
  return true;
}

/** 找到 EOCD（必要时升级到 Zip64）并解析出 total/cd_size/cd_off。 */
bool ReadDirectoryInfo(const VolumeSet& vols, uint64_t file_size, uint64_t* total_out,
                       uint64_t* cd_size_out, uint64_t* cd_off_out,
                       std::string* error) {
  const uint64_t tail_len = std::min<uint64_t>(file_size, 22 + 65535);
  if (tail_len < 22) {
    *error = "文件太小，不是有效的 zip";
    return false;
  }
  std::vector<uint8_t> tail;
  tail.resize(static_cast<size_t>(tail_len));
  if (!vols.ReadAt(file_size - tail_len, tail.data(), tail.size())) {
    *error = "读取压缩包失败";
    return false;
  }
  int64_t rel = -1;
  for (int64_t i = int64_t(tail_len) - 22; i >= 0; i--) {
    if (Rd32(&tail[size_t(i)]) == kSigEocd) {
      rel = i;
      break;
    }
  }
  if (rel < 0) {
    *error = "不是有效的 zip（找不到中央目录结尾）";
    return false;
  }
  const uint8_t* eocd = &tail[size_t(rel)];
  const uint64_t eocd_abs = file_size - tail_len + uint64_t(rel);
  uint64_t total = Rd16(eocd + 10);
  uint64_t cd_size = Rd32(eocd + 12);
  uint64_t cd_off = Rd32(eocd + 16);

  // 32 位字段满值 → 尝试 Zip64。
  const bool need64 = total == 0xFFFFull || cd_size == 0xFFFFFFFFull ||
                      cd_off == 0xFFFFFFFFull;
  if (need64 && eocd_abs >= 20) {
    uint8_t loc[20];
    if (vols.ReadAt(eocd_abs - 20, loc, sizeof(loc)) &&
        Rd32(loc) == kSigZip64Loc) {
      const uint64_t z64_off = Rd64(loc + 8);
      uint8_t z64[56];
      if (vols.ReadAt(z64_off, z64, sizeof(z64)) &&
          Rd32(z64) == kSigZip64Eocd) {
        total = Rd64(z64 + 32);
        cd_size = Rd64(z64 + 40);
        cd_off = Rd64(z64 + 48);
      }
    }
  }
  if (cd_size == 0 || cd_size > kMaxCentralDir || cd_off + cd_size > file_size) {
    *error = "压缩包中央目录越界（文件可能损坏）";
    return false;
  }
  *total_out = total;
  *cd_size_out = cd_size;
  *cd_off_out = cd_off;
  return true;
}

}  // namespace

ExtractResult Extract(const std::vector<std::string>& parts,
                      const std::string& dest_dir, const std::string& password,
                      const ProgressFn& on_progress) {
  ExtractResult res;
  // 分卷 ZIP：各卷按顺序拼接就是一个完整 zip，所以这里统一按"卷集合"打开，
  // 单卷就是只有一卷的特例。
  VolumeSet vols;
  if (!vols.Open(parts)) {
    res.error = "打开压缩包失败";
    return res;
  }

  // 先认内容格式。分卷命名（.001/.z01）只是"怎么切的"，不代表内容是什么：
  // 拼接后是 zip 才能用本解压器；若是 7z/rar 分卷，必须给出明确提示，
  // 而不是让用户看到含混的"不是有效的 zip"。
  {
    uint8_t sig[6] = {0};
    const size_t n = size_t(std::min<uint64_t>(sizeof(sig), vols.total));
    if (n >= 4 && vols.ReadAt(0, sig, n)) {
      const bool is_zip = sig[0] == 'P' && sig[1] == 'K';
      const bool is_7z = n >= 6 && sig[0] == 0x37 && sig[1] == 0x7A &&
        sig[2] == 0xBC && sig[3] == 0xAF && sig[4] == 0x27 && sig[5] == 0x1C;
      const bool is_rar = sig[0] == 'R' && sig[1] == 'a' && sig[2] == 'r' &&
        sig[3] == '!';
      if (!is_zip) {
        if (is_7z) {
          res.error = "这是 7z 分卷包（.7z.001 之类），暂不支持；"
            "请在电脑上解压后重新打包成 zip";
        } else if (is_rar) {
          res.error = "这是 RAR 包，暂不支持；请在电脑上解压后重新打包成 zip";
        } else {
          res.error = "内容不是 zip（分卷命名不影响格式判定，但内容得是 zip）";
        }
        return res;
      }
    }
  }

  std::vector<Entry> entries;
  uint64_t total_bytes = 0;
  bool has_encrypted = false;

  {
    const uint64_t end = vols.total;
    if (end == 0) {
      res.error = "压缩包为空或无法读取";
      return res;
    }
    uint64_t total = 0, cd_size = 0, cd_off = 0;
    std::string err;
    if (!ReadDirectoryInfo(vols, end, &total, &cd_size, &cd_off, &err)) {
      res.error = err;
      return res;
    }
    std::vector<uint8_t> cd;
    cd.resize(static_cast<size_t>(cd_size));
    if (!vols.ReadAt(cd_off, cd.data(), cd.size())) {
      res.error = "读取中央目录失败";
      return res;
    }
    if (!ParseCentralDir(cd, &entries, &err)) {
      res.error = err;
      return res;
    }
  }
  if (entries.empty()) {
    res.error = "压缩包里没有文件";
    return res;
  }

  // 预扫描：总解压量（进度分母）与是否需要密码。
  for (const Entry& e : entries) {
    if (e.dir) {
      continue;
    }
    total_bytes += e.uncomp_size;
    if (e.encrypted) {
      has_encrypted = true;
    }
  }
  if (has_encrypted && password.empty()) {
    res.need_password = true;
    res.error = "该压缩包已加密，请输入密码";
    return res;
  }

  const uint32_t* crc_table = CrcTable();
  const char* pw = password.c_str();
  const size_t pw_len = password.size();
  uint64_t written = 0;
  uint64_t last_report = 0;
  uint32_t file_count = 0;
  std::vector<uint8_t> in(kChunk);
  std::vector<uint8_t> out(kChunk);

  for (size_t idx = 0; idx < entries.size(); idx++) {
    const Entry& e = entries[idx];
    std::string clean;
    if (!SanitizeName(e.name, &clean)) {
      res.error = "压缩包内含有非法路径：" + e.name;
      return res;
    }
    const std::string dst = dest_dir + "/" + clean;
    if (e.dir) {
      MakeDirs(dst);
      continue;
    }

    // 本地头：数据起点要用本地头的 name/extra 长度算（可能与中央目录不同）。
    uint8_t lh[30];
    if (!vols.ReadAt(e.local_off, lh, sizeof(lh)) || Rd32(lh) != kSigLocal) {
      res.error = "压缩包条目损坏：" + clean;
      return res;
    }
    const uint16_t l_nlen = Rd16(lh + 26);
    const uint16_t l_elen = Rd16(lh + 28);
    uint64_t data_off = e.local_off + 30 + l_nlen + l_elen;

    // 按加密方式算出真正的压缩数据长度与解密器。
    uint64_t payload = e.comp_size;
    int aes_key_len = 0;
    uint8_t aes_key[32] = {0};
    uint8_t mac_key[32] = {0};
    int mac_key_len = 0;
    AesCtr ctr;
    ZipCrypto zc;
    bool use_zipcrypto = false;

    if (e.aes) {
      const int salt_len = e.AesSaltLen();
      aes_key_len = e.AesKeyLen();
      mac_key_len = 10;   // WinZip AES 的 MAC key 长度固定 10（截断的 SHA1）
      if (e.comp_size < uint64_t(salt_len) + 2 + 10) {
        res.error = "加密条目长度异常：" + clean;
        return res;
      }
      uint8_t salt[16];
      if (!vols.ReadAt(data_off, salt, size_t(salt_len))) {
        res.error = "读取压缩包失败";
        return res;
      }
      data_off += uint64_t(salt_len);
      // derived = key(aes_key_len) || verifier(2) || mac_key(10)
      uint8_t derived[44];
      Pbkdf2HmacSha1(reinterpret_cast<const uint8_t*>(pw), pw_len, salt,
                     size_t(salt_len), 1000, derived,
                     size_t(aes_key_len) + 2 + 10);
      uint8_t verifier[2];
      if (!vols.ReadAt(data_off, verifier, 2)) {
        res.error = "读取压缩包失败";
        return res;
      }
      data_off += 2;
      if (verifier[0] != derived[aes_key_len] ||
          verifier[1] != derived[aes_key_len + 1]) {
        res.bad_password = true;
        res.error = "密码错误";
        return res;
      }
      memcpy(aes_key, derived, size_t(aes_key_len));
      memcpy(mac_key, derived + aes_key_len + 2, size_t(mac_key_len));
      ctr.Init(aes_key, aes_key_len);
      payload = e.comp_size - uint64_t(salt_len) - 2 - 10;
    } else if (e.encrypted) {
      if (e.comp_size < 12) {
        res.error = "加密条目长度异常：" + clean;
        return res;
      }
      uint8_t hdr[12];
      if (!vols.ReadAt(data_off, hdr, sizeof(hdr))) {
        res.error = "读取压缩包失败";
        return res;
      }
      data_off += 12;
      zc.Init(pw, pw_len, crc_table);
      zc.Decrypt(hdr, sizeof(hdr));
      // 12 字节头最后一字节 = crc 最高字节（有 data descriptor 时用时间戳高位）。
      const uint8_t check = (e.flags & 0x0008)
        ? uint8_t(e.dostime >> 8) : uint8_t(e.crc >> 24);
      if (hdr[11] != check) {
        res.bad_password = true;
        res.error = "密码错误";
        return res;
      }
      use_zipcrypto = true;
      payload = e.comp_size - 12;
    }

    MakeDirs(dst.substr(0, dst.find_last_of('/')));
    FILE* fp = fopen(dst.c_str(), "wb");
    if (fp == nullptr) {
      res.error = "无法写入文件：" + clean;
      return res;
    }

    // 逐块：读 → 解密 → inflate/store → 写。
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    const bool inflate_used = (e.method == 8);
    if (inflate_used && inflateInit2(&zs, -15) != Z_OK) {
      fclose(fp);
      res.error = "初始化解压器失败";
      return res;
    }

    HmacSha1Stream mac;
    const bool mac_used = e.aes;
    if (mac_used) {
      mac.Init(mac_key, size_t(mac_key_len));
    }
    uint32_t crc_run = uint32_t(crc32(0L, Z_NULL, 0));
    uint64_t remain = payload;
    bool failed = false;
    std::string fail_msg;

    while (remain > 0 && !failed) {
      const size_t want = size_t(std::min<uint64_t>(remain, kChunk));
      if (!vols.ReadAt(data_off, in.data(), want)) {
        failed = true;
        fail_msg = "压缩包数据残缺：" + clean;
        break;
      }
      data_off += want;
      remain -= want;

      if (mac_used) {
        mac.Update(in.data(), want);
      }
      if (use_zipcrypto) {
        zc.Decrypt(in.data(), want);
      } else if (e.aes) {
        ctr.Xor(in.data(), want);
      }

      if (inflate_used) {
        zs.next_in = in.data();
        zs.avail_in = uInt(want);
        while (zs.avail_in > 0) {
          zs.next_out = out.data();
          zs.avail_out = uInt(out.size());
          const int r = inflate(&zs, Z_NO_FLUSH);
          if (r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR) {
            failed = true;
            fail_msg = (r == Z_DATA_ERROR) && (e.encrypted)
              ? "密码错误或数据损坏：" + clean
              : "解压数据损坏：" + clean;
            break;
          }
          const size_t got = out.size() - zs.avail_out;
          if (got > 0) {
            if (fwrite(out.data(), 1, got, fp) != got) {
              failed = true;
              fail_msg = "写入沙箱失败（存储空间不足？）";
              break;
            }
            crc_run = uint32_t(crc32(crc_run, out.data(), uInt(got)));
            written += got;
          }
          if (r == Z_STREAM_END) {
            break;
          }
          if (r == Z_BUF_ERROR && got == 0) {
            break;  // 需要更多输入
          }
        }
      } else {
        if (fwrite(in.data(), 1, want, fp) != want) {
          failed = true;
          fail_msg = "写入沙箱失败（存储空间不足？）";
          break;
        }
        crc_run = uint32_t(crc32(crc_run, in.data(), uInt(want)));
        written += want;
      }

      if (on_progress && written - last_report >= kReportStep) {
        last_report = written;
        ExtractProgress ep;
        ep.done = written;
        ep.total = total_bytes;
        ep.name = clean;
        if (!on_progress(ep)) {
          res.canceled = true;
          res.error = "已取消解压";
        }
      }
      if (res.canceled) {
        break;
      }
    }

    if (inflate_used) {
      inflateEnd(&zs);
    }

    // 收尾校验：AES 看 HMAC，其余看 crc32。
    if (!failed && !res.canceled && mac_used) {
      uint8_t expect[10];
      if (!vols.ReadAt(data_off, expect, sizeof(expect))) {
        failed = true;
        fail_msg = "压缩包数据残缺：" + clean;
      } else {
        uint8_t digest[20];
        mac.Final(digest);
        if (memcmp(digest, expect, 10) != 0) {
          failed = true;
          fail_msg = "密码错误或数据损坏：" + clean;
          res.bad_password = true;
        }
      }
    }
    if (!failed && !res.canceled && !mac_used && !e.dir && e.crc != 0 &&
        crc_run != e.crc) {
      failed = true;
      fail_msg = "数据校验失败（crc32 不匹配）：" + clean;
    }

    fclose(fp);
    if (failed) {
      unlink(dst.c_str());
      res.error = fail_msg;
      return res;
    }
    if (res.canceled) {
      unlink(dst.c_str());
      return res;
    }
    file_count++;
    res.written = written;
    res.files = file_count;
  }
  if (on_progress) {
    ExtractProgress ep;
    ep.done = total_bytes;
    ep.total = total_bytes;
    ep.name = "";
    on_progress(ep);
  }
  res.ok = true;
  res.written = written;
  res.files = file_count;
  return res;
}

}  // namespace hxzip
