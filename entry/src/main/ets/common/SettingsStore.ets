import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { Setting, SettingsCategory, SettingsSchema } from './SettingsSchema';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 配置结构版本：**改了任何设置的默认值就 +1**，并在 CONFIG_MIGRATIONS 里登记
 * 「旧默认值 → 新默认值」。启动时 ensureDefaults() 会：
 *   1. 文件不存在 → 把 schema 全部默认值写进去（对照安卓版启动写 default_config.toml）；
 *   2. 文件存在但版本落后 → 执行迁移（只替换「还等于旧默认值」的键 = 用户没改过）、
 *      补齐缺失的键、写入新版本号；
 *   3. 版本相同 → 直接返回，不碰文件。
 * 这样默认值的改动能真正生效，又不会覆盖用户自己改过的值。
 */
const CONFIG_SCHEMA_VERSION: number = 7;
const CONFIG_VERSION_TAG: string = 'HX360E|schema_version';
/** [标签, 旧默认值, 新默认值] */
const CONFIG_MIGRATIONS: string[][] = [
  // log_level 默认 info→warning：避免 xenia 日志洪峰触发 hilog 流控、把诊断日志一起丢掉。
  ['Logging|log_level', '2', '1'],
  // GPU 成本 A/B：真实遮挡查询→伪造（tiled GPU 上查询易串行化）；回读解析 uma→none。
  ['GPU|occlusion_query', 'fast', 'fake'],
  ['GPU|readback_resolve', 'uma', 'none'],
  // v3：新增 Vulkan|hx360e_xeg_spatial_upscale(_sharpness) 两个键（系统级超分）。
  // v7：系统级超分默认改为**关闭**（超分不是原生渲染）。上一版默认是 true，
  //   这里把「仍等于旧默认 true = 用户没改过」的配置改回 false。
  ['Vulkan|hx360e_xeg_spatial_upscale', 'true', 'false'],
  // v4：修正上一版实验留下的 Console|internal_display_resolution=5（848x480）。
  // 该设置会**改变告知 guest 的视频模式**，实测会让游戏在切换视频模式时
  // 崩在 guest CPU 线程（SIGSEGV_ACCERR）。渲染分辨率改用独立的
  // GPU|hx360e_render_scale_den_x 设置项控制，这里把它改回 1280x720。
  ['Console|internal_display_resolution', '5', '8'],
  // v6：渲染倍率默认改为原生 720p（den=1）。上一版曾把默认设成 2（半分辨率
  // 360p），这里把配置里仍是 2 的值拉回 1；同时把 v5 误写的 1→2 撤销。
  // 想要 360p 的用户可在设置页 GPU|hx360e_render_scale_den_x 里改成 2。
  ['GPU|hx360e_render_scale_den_x', '2', '1'],
  ['GPU|hx360e_render_scale_den_y', '2', '1'],
];

/**
 * 设置的保存/加载：读写 xenia 的全局 TOML 配置（--config 指向它）。
 *
 * 稀疏存储：只写用户改过的键，其余键由 emulator 用 cvar 默认值；
 * 因此「未设置」= 用 schema 默认值，比较时也要回落到 schema 默认值。
 * 句柄是 native 裸指针，必须 open/close 配对（close 只在 dirty 时落盘）。
 */
export class SettingsStore {
  private static instance: SettingsStore | undefined = undefined;

  /** 单例：页面与各设置行共用同一个句柄。 */
  static shared(): SettingsStore {
    if (SettingsStore.instance === undefined) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  private handle: bigint = BigInt(0);
  private filesDir: string = '';
  private dirty: boolean = false;

  /** 全局配置文件（启动时通过 --config= 传给模拟器）。 */
  static configPath(filesDir: string): string {
    return `${filesDir}/storage/xenia.config.toml`;
  }

  /**
   * 启动时确保配置文件存在且为新版本（详见文件头 CONFIG_SCHEMA_VERSION 说明）。
   * 文件不存在或版本落后才写盘；版本一致时完全不碰文件。
   */
  static ensureDefaults(filesDir: string): void {
    const path: string = SettingsStore.configPath(filesDir);
    const slash: number = path.lastIndexOf('/');
    if (slash > 0) {
      const dir: string = path.substring(0, slash);
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'mkdir storage failed: %{public}s',
          JSON.stringify(e));
      }
    }

    let exists: boolean = false;
    try {
      exists = fs.accessSync(path);
    } catch (e) {
      exists = false;
    }

    let handle: bigint = BigInt(0);
    let storedVersion: string = '(none)';
    try {
      handle = exists ? testNapi.config.open(path)
                      : testNapi.config.openString('');
      if (handle === BigInt(0)) {
        hilog.error(DOMAIN, TAG, 'config open failed for %{public}s', path);
        return;
      }
      const v: string | null = exists
        ? testNapi.config.loadEntry(handle, CONFIG_VERSION_TAG) : null;
      storedVersion = v === null ? '(none)' : v;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'config read failed: %{public}s', JSON.stringify(e));
      return;
    }

    const current: string = `${CONFIG_SCHEMA_VERSION}`;
    if (exists && storedVersion === current) {
      hilog.info(DOMAIN, TAG, 'config up to date (v%{public}s)', current);
      testNapi.config.free(handle);
      return;
    }

    try {
      let updated: number = 0;
      // 1) 迁移：只替换「还是旧默认值」的键（用户改过的值不动）。
      //    关键：**版本标记缺失时（(none)）不重放迁移**。xenia 自己 SaveConfig
      //    回写整个配置文件时会把我们的版本标记丢掉，若此时重放迁移，用户刚
      //    在设置页改过的值（恰好等于旧默认值）会被强行改回新默认值 —— 实测
      //    表现为"退出游戏后设置又变回去了"。
      const replayMigrations: boolean = storedVersion !== '(none)';
      if (replayMigrations) {
        for (const m of CONFIG_MIGRATIONS) {
          const cur: string | null = testNapi.config.loadEntry(handle, m[0]);
          if (cur !== null && cur === m[1]) {
            testNapi.config.saveEntry(handle, m[0], m[2]);
            updated++;
            hilog.info(DOMAIN, TAG, 'migrate %{public}s: %{public}s → %{public}s',
              m[0], m[1], m[2]);
          }
        }
      } else {
        hilog.info(DOMAIN, TAG,
          'config version tag missing; skipping migrations (only filling defaults)');
      }
      // 2) 补齐缺失的键（默认值）。
      const cats: SettingsCategory[] = SettingsSchema.categories();
      let filled: number = 0;
      for (const cat of cats) {
        for (const s of cat.settings) {
          if (s.def === '') {
            continue;
          }
          const cur: string | null = testNapi.config.loadEntry(handle, s.tag());
          if (cur === null) {
            testNapi.config.saveEntry(handle, s.tag(), s.def);
            filled++;
          }
        }
      }
      testNapi.config.saveEntry(handle, CONFIG_VERSION_TAG, current);
      testNapi.config.saveToFile(handle, path);
      const ll: string | null = testNapi.config.loadEntry(handle, 'Logging|log_level');
      hilog.info(DOMAIN, TAG,
        'config %{public}s → v%{public}s: %{public}d migrated, %{public}d filled, log_level=%{public}s',
        exists ? 'migrated' : 'seeded', current, updated, filled,
        ll === null ? '(unset)' : ll);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'config write failed: %{public}s', JSON.stringify(e));
    } finally {
      testNapi.config.free(handle);
    }
  }

  open(filesDir: string): void {
    if (this.handle !== BigInt(0)) {
      return;
    }
    this.filesDir = filesDir;
    const path: string = SettingsStore.configPath(filesDir);
    try {
      if (fs.accessSync(path)) {
        this.handle = testNapi.config.open(path);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'config open failed: %{public}s', JSON.stringify(e));
      this.handle = BigInt(0);
    }
    if (this.handle === BigInt(0)) {
      // 文件不存在/损坏：用空表，保存时再创建（稀疏）。
      this.handle = testNapi.config.openString('');
    }
    hilog.info(DOMAIN, TAG, 'settings opened (%{public}s)',
      this.handle === BigInt(0) ? 'failed' : 'ok');
  }

  isOpen(): boolean {
    return this.handle !== BigInt(0);
  }

  /** 原始值（未设置返回 undefined）。 */
  raw(tag: string): string | undefined {
    if (this.handle === BigInt(0)) {
      return undefined;
    }
    try {
      const v: string | null = testNapi.config.loadEntry(this.handle, tag);
      return v === null ? undefined : v;
    } catch (e) {
      return undefined;
    }
  }

  /** 当前值（未设置回落到 schema 默认值）。 */
  valueOf(s: Setting): string {
    const v: string | undefined = this.raw(s.tag());
    return v === undefined ? s.def : v;
  }

  /** 与默认值不同（只算真正改过的项）。 */
  isModified(s: Setting): boolean {
    const v: string | undefined = this.raw(s.tag());
    return v !== undefined && v !== s.def;
  }

  set(s: Setting, value: string): void {
    if (this.handle === BigInt(0)) {
      return;
    }
    try {
      testNapi.config.saveEntry(this.handle, s.tag(), value);
      this.dirty = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'config set failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 单项恢复默认。 */
  reset(s: Setting): void {
    this.set(s, s.def);
  }

  /** 全部恢复默认：换成空表（文件里只剩之后又改过的键）。 */
  resetAll(): void {
    if (this.handle === BigInt(0)) {
      return;
    }
    try {
      testNapi.config.free(this.handle);
    } catch (e) {
      // 忽略
    }
    this.handle = testNapi.config.openString('');
    this.dirty = true;
  }

  /** 把当前配置内容打到日志（诊断用）。 */
  dumpToLog(): void {
    if (this.handle === BigInt(0)) {
      return;
    }
    try {
      const text: string = testNapi.config.serialize(this.handle);
      hilog.info(DOMAIN, TAG, 'config dump >>>\n%{public}s\n<<< config dump',
        text);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'config dump failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** 落盘（保留句柄）。 */
  flush(): boolean {
    if (this.handle === BigInt(0)) {
      return false;
    }
    if (!this.dirty) {
      return true;
    }
    try {
      const path: string = SettingsStore.configPath(this.filesDir);
      const slash: number = path.lastIndexOf('/');
      if (slash > 0) {
        const dir: string = path.substring(0, slash);
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
      }
      testNapi.config.saveToFile(this.handle, path);
      this.dirty = false;
      hilog.info(DOMAIN, TAG, 'settings saved to %{public}s', path);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'settings flush failed: %{public}s',
        JSON.stringify(e));
      return false;
    }
  }

  /** 关闭（dirty 时先落盘）。 */
  close(): void {
    if (this.handle === BigInt(0)) {
      return;
    }
    this.flush();
    try {
      testNapi.config.free(this.handle);
    } catch (e) {
      // 忽略
    }
    this.handle = BigInt(0);
  }
}
