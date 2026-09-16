// ZIP 解密所需的密码学原语（自包含，无外部依赖）。
//
// 只服务 ZIP 解压的两条加密路径：
//   1) ZipCrypto  —— 传统 PKWARE 流密码，用 crc32 表打乱三个 32 位 key，
//                    不需要 AES/SHA，见 zip_stream_* 。
//   2) WinZip AES —— AES-128/192/256 的 CTR 模式 + HMAC-SHA1 校验 + 
//                    PBKDF2-HMAC-SHA1(1000 轮) 派生 key/校验值/MAC key。
//   3) 7z 的 AES 用 CBC，这里用不到，所以只需要 AES 的**加密块**（CTR 只用正向）。
//
// 算法都是公开标准（FIPS-197 / RFC 3174 / RFC 2104 / RFC 2898），
// 实现按 ZIP 场景裁剪：单一调用方、无并发、不做侧信道加固。
#pragma once

#include <cstdint>
#include <cstring>

namespace hxzip {

// ---------------------------------------------------------------------------
// AES（FIPS-197）—— 只实现加密方向
// ---------------------------------------------------------------------------

struct AesKey {
  // AES-256 是 14 轮 + 1，共 15 组轮密钥 × 16 字节 = 240。
  uint8_t rk[240];
  int rounds;
};

inline const uint8_t* AesSbox() {
  static const uint8_t kSbox[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
  };
  return kSbox;
}

// 轮常量 Rcon[1..10]，AES-256 最多用到第 7 个。
inline uint8_t AesRcon(int i) {
  static const uint8_t kRcon[11] = {
    0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,
  };
  return kRcon[i];
}

// 16 字节块加密（FIPS-197 正向密码）。
inline void AesEncryptBlock(const AesKey& k, const uint8_t in[16],
                            uint8_t out[16]) {
  uint8_t s[16];
  const uint8_t* sb = AesSbox();
  for (int i = 0; i < 16; i++) {
    s[i] = in[i] ^ k.rk[i];
  }
  for (int round = 1; round <= k.rounds; round++) {
    uint8_t t[16];
    // SubBytes + ShiftRows（列主序：state[r + 4c]）。
    for (int c = 0; c < 4; c++) {
      for (int r = 0; r < 4; r++) {
        t[r + 4 * c] = sb[s[((r + c) & 3) + 4 * c]];
      }
    }
    // MixColumns（最后一轮不做）。
    if (round != k.rounds) {
      for (int c = 0; c < 4; c++) {
        const uint8_t a0 = t[0 + 4 * c], a1 = t[1 + 4 * c];
        const uint8_t a2 = t[2 + 4 * c], a3 = t[3 + 4 * c];
        const uint8_t x = a0 ^ a1 ^ a2 ^ a3;
        s[0 + 4 * c] = a0 ^ x ^ ((a0 << 1) ^ ((a0 >> 7) * 0x1b));
        s[1 + 4 * c] = a1 ^ x ^ ((a1 << 1) ^ ((a1 >> 7) * 0x1b));
        s[2 + 4 * c] = a2 ^ x ^ ((a2 << 1) ^ ((a2 >> 7) * 0x1b));
        s[3 + 4 * c] = a3 ^ x ^ ((a3 << 1) ^ ((a3 >> 7) * 0x1b));
      }
    } else {
      memcpy(s, t, 16);
    }
    // AddRoundKey
    for (int i = 0; i < 16; i++) {
      s[i] ^= k.rk[round * 16 + i];
    }
  }
  memcpy(out, s, 16);
}

// 轮密钥扩展；key_len ∈ {16,24,32}。
inline void AesExpandKey(AesKey& k, const uint8_t* key, int key_len) {
  const int nk = key_len / 4;         // 4 / 6 / 8
  k.rounds = nk + 6;                  // 10 / 12 / 14
  const int total = 4 * (k.rounds + 1);
  memcpy(k.rk, key, key_len);
  const uint8_t* sb = AesSbox();
  for (int i = nk; i < total; i++) {
    uint8_t t[4];
    memcpy(t, k.rk + (i - 1) * 4, 4);
    if (i % nk == 0) {
      // RotWord + SubWord + Rcon
      const uint8_t b0 = t[0];
      t[0] = uint8_t(sb[t[1]] ^ AesRcon(i / nk));
      t[1] = sb[t[2]];
      t[2] = sb[t[3]];
      t[3] = sb[b0];
    } else if (nk > 6 && i % nk == 4) {
      for (int j = 0; j < 4; j++) {
        t[j] = uint8_t(sb[t[j]]);
      }
    }
    for (int j = 0; j < 4; j++) {
      k.rk[i * 4 + j] = uint8_t(k.rk[(i - nk) * 4 + j] ^ t[j]);
    }
  }
}

// ---------------------------------------------------------------------------
// SHA-1（RFC 3174）—— WinZip AES 用它做 HMAC 与 PBKDF2
// ---------------------------------------------------------------------------

struct Sha1Ctx {
  uint32_t h[5];
  uint8_t buf[64];
  uint64_t len;   // 已入缓冲的字节数（以 64 取模由 buf_len 处理）
  size_t buf_len;
};

inline uint32_t Sha1Rotl(uint32_t v, int n) {
  return (v << n) | (v >> (32 - n));
}

inline void Sha1Init(Sha1Ctx& c) {
  c.h[0] = 0x67452301u; c.h[1] = 0xEFCDAB89u; c.h[2] = 0x98BADCFEu;
  c.h[3] = 0x10325476u; c.h[4] = 0xC3D2E1F0u;
  c.len = 0; c.buf_len = 0;
}

inline void Sha1Block(Sha1Ctx& c, const uint8_t* p) {
  uint32_t w[80];
  for (int i = 0; i < 16; i++) {
    w[i] = (uint32_t(p[i * 4]) << 24) | (uint32_t(p[i * 4 + 1]) << 16) |
           (uint32_t(p[i * 4 + 2]) << 8) | uint32_t(p[i * 4 + 3]);
  }
  for (int i = 16; i < 80; i++) {
    w[i] = Sha1Rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  }
  uint32_t a = c.h[0], b = c.h[1], d = c.h[2], e = c.h[3], f = c.h[4];
  for (int i = 0; i < 80; i++) {
    uint32_t g, kk;
    if (i < 20) { g = (b & d) | ((~b) & e); kk = 0x5A827999u; }
    else if (i < 40) { g = b ^ d ^ e; kk = 0x6ED9EBA1u; }
    else if (i < 60) { g = (b & d) | (b & e) | (d & e); kk = 0x8F1BBCDCu; }
    else { g = b ^ d ^ e; kk = 0xCA62C1D6u; }
    const uint32_t tmp = Sha1Rotl(a, 5) + g + f + kk + w[i];
    f = e; e = d; d = Sha1Rotl(b, 30); b = a; a = tmp;
  }
  c.h[0] += a; c.h[1] += b; c.h[2] += d; c.h[3] += e; c.h[4] += f;
}

inline void Sha1Update(Sha1Ctx& c, const uint8_t* p, size_t n) {
  c.len += n;
  while (n > 0) {
    const size_t take = (n < 64 - c.buf_len) ? n : 64 - c.buf_len;
    memcpy(c.buf + c.buf_len, p, take);
    c.buf_len += take; p += take; n -= take;
    if (c.buf_len == 64) { Sha1Block(c, c.buf); c.buf_len = 0; }
  }
}

inline void Sha1Final(Sha1Ctx& c, uint8_t out[20]) {
  const uint64_t bits = c.len * 8;
  uint8_t pad = 0x80;
  Sha1Update(c, &pad, 1);
  const uint8_t zero = 0;
  while (c.buf_len != 56) {
    Sha1Update(c, &zero, 1);
  }
  uint8_t lenbe[8];
  for (int i = 0; i < 8; i++) {
    lenbe[i] = uint8_t(bits >> (56 - i * 8));
  }
  Sha1Update(c, lenbe, 8);
  for (int i = 0; i < 5; i++) {
    out[i * 4] = uint8_t(c.h[i] >> 24);
    out[i * 4 + 1] = uint8_t(c.h[i] >> 16);
    out[i * 4 + 2] = uint8_t(c.h[i] >> 8);
    out[i * 4 + 3] = uint8_t(c.h[i]);
  }
}

inline void Sha1(const uint8_t* p, size_t n, uint8_t out[20]) {
  Sha1Ctx c; Sha1Init(c); Sha1Update(c, p, n); Sha1Final(c, out);
}

// HMAC-SHA1（RFC 2104）。WinZip AES 只需要一次性校验整段密文，
// 所以不做流式版本，直接一次性算。
inline void HmacSha1PrepareKey(uint8_t k[64], const uint8_t* key,
                               size_t key_len) {
  memset(k, 0, 64);
  if (key_len > 64) {
    Sha1(key, key_len, k);
  } else {
    memcpy(k, key, key_len);
  }
}
inline void HmacSha1(const uint8_t* key, size_t key_len,
                     const uint8_t* msg, size_t msg_len, uint8_t out[20]) {
  uint8_t k[64];
  HmacSha1PrepareKey(k, key, key_len);
  uint8_t pad[64];
  Sha1Ctx c;
  for (int i = 0; i < 64; i++) {
    pad[i] = uint8_t(k[i] ^ 0x36);
  }
  Sha1Init(c);
  Sha1Update(c, pad, 64);
  Sha1Update(c, msg, msg_len);
  uint8_t inner[20];
  Sha1Final(c, inner);
  for (int i = 0; i < 64; i++) {
    pad[i] = uint8_t(k[i] ^ 0x5c);
  }
  Sha1Init(c);
  Sha1Update(c, pad, 64);
  Sha1Update(c, inner, 20);
  Sha1Final(c, out);
}

// PBKDF2-HMAC-SHA1（RFC 2898），WinZip AES 固定 1000 轮。
inline void Pbkdf2HmacSha1(const uint8_t* pw, size_t pw_len,
                           const uint8_t* salt, size_t salt_len,
                           uint32_t iters, uint8_t* out, size_t out_len) {
  uint8_t k[64];
  HmacSha1PrepareKey(k, pw, pw_len);
  uint8_t ipad[64];
  for (int i = 0; i < 64; i++) {
    ipad[i] = uint8_t(k[i] ^ 0x36);
  }
  uint32_t block = 1;
  size_t done = 0;
  while (done < out_len) {
    const uint8_t idx[4] = {
      uint8_t(block >> 24), uint8_t(block >> 16),
      uint8_t(block >> 8), uint8_t(block),
    };
    // U1 = HMAC(pw, salt || block_index)
    uint8_t u[20];
    Sha1Ctx c;
    Sha1Init(c);
    Sha1Update(c, ipad, 64);
    Sha1Update(c, salt, salt_len);
    Sha1Update(c, idx, 4);
    {
      uint8_t inner[20];
      Sha1Final(c, inner);
      HmacSha1(k, 64, inner, 20, u);
    }
    uint8_t t[20];
    memcpy(t, u, 20);
    for (uint32_t it = 1; it < iters; it++) {
      HmacSha1(k, 64, u, 20, u);
      for (int i = 0; i < 20; i++) {
        t[i] = uint8_t(t[i] ^ u[i]);
      }
    }
    const size_t take = (out_len - done < 20) ? (out_len - done) : 20;
    memcpy(out + done, t, take);
    done += take;
    block++;
  }
}

// ---------------------------------------------------------------------------
// ZipCrypto（传统 PKWARE 加密）—— ZIP 规范 6.1 节
// ---------------------------------------------------------------------------

struct ZipCrypto {
  uint32_t k0, k1, k2;
  // 解密时用 crc32 表的低 8 位做替换表。
  const uint32_t* crc_table;

  void Init(const char* password, size_t pw_len, const uint32_t* table) {
    k0 = 0x12345678u; k1 = 0x23456789u; k2 = 0x34567890u;
    crc_table = table;
    for (size_t i = 0; i < pw_len; i++) {
      UpdateKeys(uint8_t(password[i]));
    }
  }

  uint8_t DecryptByte(uint8_t c) {
    const uint16_t temp = uint16_t((k2 & 0xffff) | 2);
    return uint8_t(c ^ uint8_t((temp * (temp ^ 1)) >> 8));
  }

  void UpdateKeys(uint8_t plain) {
    k0 = Crc32Update(k0, plain);
    k1 = k1 + (k0 & 0xff);
    k1 = k1 * 134775813u + 1u;
    k2 = Crc32Update(k2, uint8_t(k1 >> 24));
  }

  uint32_t Crc32Update(uint32_t crc, uint8_t b) const {
    return (crc >> 8) ^ crc_table[(crc ^ b) & 0xff];
  }

  // 原地解密，密文进、明文出。
  void Decrypt(uint8_t* buf, size_t n) {
    for (size_t i = 0; i < n; i++) {
      const uint8_t plain = DecryptByte(buf[i]);
      buf[i] = plain;
      UpdateKeys(plain);
    }
  }
};

// ---------------------------------------------------------------------------
// WinZip AES 的 CTR 模式密钥流
// ---------------------------------------------------------------------------

/**
 * WinZip AES 用的是"计数器递增"的 AES-CTR：
 *  - 初始计数器 = 1（写在第 0..3 字节，小端）
 *  - 每产生 16 字节，把整个 16 字节块当作小端整数 +1
 *  - 密文与密钥流异或（加密解密同构）
 */
struct AesCtr {
  AesKey key;
  uint8_t nonce[16];
  uint8_t stream[16];
  size_t used;   // stream 里已被消费的字节数

  void Init(const uint8_t* aes_key, int key_len) {
    AesExpandKey(key, aes_key, key_len);
    memset(nonce, 0, 16);
    nonce[0] = 1;          // 计数器从 1 开始
    memset(stream, 0, 16);
    used = 16;             // 强制第一次调用就生成新块
  }

  void NextBlock() {
    AesEncryptBlock(key, nonce, stream);
    // 整个块当小端整数 +1（只加低 8 字节就够用，ZIP 单文件不会超过 2^64）。
    for (int i = 0; i < 16; i++) {
      if (++nonce[i] != 0) {
        break;
      }
    }
    used = 0;
  }

  void Xor(uint8_t* buf, size_t n) {
    for (size_t i = 0; i < n; i++) {
      if (used == 16) {
        NextBlock();
      }
      buf[i] ^= stream[used++];
    }
  }
};

}  // namespace hxzip
