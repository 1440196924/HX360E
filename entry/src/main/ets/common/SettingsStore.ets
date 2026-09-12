import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { Setting } from './SettingsSchema';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

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
