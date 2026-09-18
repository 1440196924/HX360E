import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 日志导出：读取沙箱内的 native/emulator 日志并另存到用户选定的目录。 */
export class LogExport {
  /**
   * 读取文件尾部 maxBytes 字节。按块显式给 offset 读（本设备上不传 offset 的
   * 读语义不可靠），并在首行写出真实文件大小，便于确认拿到的确实是尾部。
   */
  static readLogTail(path: string, maxBytes: number): string {
    try {
      if (!fs.accessSync(path)) {
        return `(no such file: ${path})\n`;
      }
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const size: number = fs.statSync(f.fd).size;
        const want: number = Math.min(maxBytes, size);
        const decoder = util.TextDecoder.create('utf-8');
        const chunkSize: number = 64 * 1024;
        const buf = new ArrayBuffer(chunkSize);
        const parts: string[] = [];
        let offset: number = size - want;
        let read: number = 0;
        while (read < want) {
          const len: number = Math.min(chunkSize, want - read);
          const n: number = fs.readSync(f.fd, buf, { offset: offset, length: len });
          if (n <= 0) {
            break;
          }
          parts.push(decoder.decodeToString(new Uint8Array(buf, 0, n)));
          read += n;
          offset += n;
        }
        return `# ${path} size=${size} tail=${read}\n${parts.join('')}`;
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'readLogTail failed: %{public}s', JSON.stringify(e));
      return `(read failed: ${path})\n`;
    }
  }

  /** 汇总各日志文件尾部，拼成一份可直接导出的文本。 */
  static buildText(filesDir: string): string {
    const logDir: string = `${filesDir}/logs`;
    let text: string = `HX360E logs ${new Date().toISOString()}\n`;
    // 应用层（ArkTS）日志放最前面：用户反馈时先看这个。
    text += '\n===== app.prev.log (上一份应用日志，tail 256KB) =====\n';
    text += LogExport.readLogTail(`${logDir}/app.prev.log`, 256 * 1024);
    text += '\n===== app.log (应用日志，tail 512KB) =====\n';
    text += LogExport.readLogTail(`${logDir}/app.log`, 512 * 1024);
    text += '\n===== native_fault.prev.log (上次运行，崩溃现场) =====\n';
    text += LogExport.readLogTail(`${logDir}/native_fault.prev.log`, 256 * 1024);
    text += '\n===== native_fault.log (tail 256KB) =====\n';
    text += LogExport.readLogTail(`${logDir}/native_fault.log`, 256 * 1024);
    text += '\n===== xe.log (tail 4MB) =====\n';
    text += LogExport.readLogTail(`${logDir}/xe.log`, 4 * 1024 * 1024);
    return text;
  }

  /** 弹出保存选择器并把日志写入用户选定的位置。返回状态文案。 */
  static async exportLogs(ctx: common.Context, filesDir: string): Promise<string> {
    try {
      const text: string = LogExport.buildText(filesDir);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`hx360e-log-${Date.now()}.txt`];
      const savePicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        return '已取消导出';
      }
      const out = fs.openSync(uris[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(out.fd, text);
      } finally {
        fs.closeSync(out);
      }
      hilog.info(DOMAIN, TAG, 'exportLogs: %{public}s', uris[0]);
      return `已导出 ${text.length} 字符 → ${uris[0]}`;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'exportLogs failed: %{public}s', JSON.stringify(e));
      return '导出失败（见 hilog）';
    }
  }
}
