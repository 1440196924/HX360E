import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const HL_TAG = 'HX360E';
/** 单个日志文件上限；超了轮转成 app.prev.log（用户反馈时两份都会被导出）。 */
const MAX_BYTES: number = 2 * 1024 * 1024;

/**
 * 应用级日志：写 `<filesDir>/logs/app.log`，并镜像一份到 hilog。
 *
 * 为什么要自己写文件：ArkTS 侧读不了 hilog（只能写），用户反馈问题时只能靠
 * 「设置 → 导出日志」把沙箱里的文件导出来。native 侧本来就有 native_fault*.log /
 * xe.log，这里补齐应用层（ArkTS）这一路。
 *
 * 用法：EntryAbility 启动时 init(filesDir)，之后各处用 i/w/e/exception。
 * 关键节点（启动、导入、启动游戏、退出、异常）都要留一行，用户反馈时就能从
 * "最后一条日志"定位到卡在哪一步。
 */
export class AppLog {
  private static dir: string = '';
  private static file: string = '';
  private static prevFile: string = '';
  private static started: boolean = false;

  /** 由 EntryAbility 在拿到 context 后调用一次。 */
  static init(filesDir: string): void {
    if (AppLog.started) {
      return;
    }
    AppLog.started = true;
    AppLog.dir = `${filesDir}/logs`;
    AppLog.file = `${AppLog.dir}/app.log`;
    AppLog.prevFile = `${AppLog.dir}/app.prev.log`;
    try {
      if (!fs.accessSync(AppLog.dir)) {
        fs.mkdirSync(AppLog.dir, true);
      }
    } catch (e) {
      // 目录建不出来就只走 hilog
    }
    AppLog.rotateIfNeeded();
    let api: number = 0;
    let model: string = '?';
    let os: string = '?';
    let display: string = '?';
    try {
      api = deviceInfo.sdkApiVersion;
      model = deviceInfo.productModel;
      os = deviceInfo.osFullName;
      display = deviceInfo.displayVersion;
    } catch (e) {
      // 取不到就留默认值
    }
    AppLog.i('app', `=== HX360E start === api=${api} model=${model} os=${os}` +
      ` display=${display}`);
  }

  static i(tag: string, msg: string): void {
    hilog.info(DOMAIN, HL_TAG, '[%{public}s] %{public}s', tag, msg);
    AppLog.append('I', tag, msg);
  }

  static w(tag: string, msg: string): void {
    hilog.warn(DOMAIN, HL_TAG, '[%{public}s] %{public}s', tag, msg);
    AppLog.append('W', tag, msg);
  }

  static e(tag: string, msg: string): void {
    hilog.error(DOMAIN, HL_TAG, '[%{public}s] %{public}s', tag, msg);
    AppLog.append('E', tag, msg);
  }

  /** 记录一个异常对象（含 stack），用户反馈时最有用。 */
  static exception(tag: string, what: string, e: Object): void {
    let detail: string = '';
    try {
      detail = JSON.stringify(e);
    } catch (err) {
      detail = `${e}`;
    }
    AppLog.e(tag, `${what}: ${detail}`);
  }

  static append(level: string, tag: string, msg: string): void {
    if (AppLog.file === '') {
      return;
    }
    const line: string = `${AppLog.now()} ${level} ${tag}: ${msg}\n`;
    try {
      const f = fs.openSync(AppLog.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(f.fd, line);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      // 写不进去就算了，hilog 那份还在
    }
  }

  private static now(): string {
    const d: Date = new Date();
    const p = (n: number, w: number): string => n.toString().padStart(w, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1, 2)}-${p(d.getDate(), 2)} ` +
      `${p(d.getHours(), 2)}:${p(d.getMinutes(), 2)}:${p(d.getSeconds(), 2)}.` +
      `${p(d.getMilliseconds(), 3)}`;
  }

  /** 超过上限就把当前文件挪成 app.prev.log，重新开一份。 */
  private static rotateIfNeeded(): void {
    try {
      if (!fs.accessSync(AppLog.file)) {
        return;
      }
      const size: number = fs.statSync(AppLog.file).size;
      if (size <= MAX_BYTES) {
        return;
      }
      fs.copyFileSync(AppLog.file, AppLog.prevFile);
      fs.truncateSync(AppLog.file, 0);
    } catch (e) {
      // 轮转失败不影响写日志
    }
  }
}
