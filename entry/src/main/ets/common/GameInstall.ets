import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { GameLibrary, GameMeta } from './GameLibrary';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 游戏安装：调系统文件选择器 → 复制进沙箱槽位 → 解析启动目标 → 写元数据。
 * 逻辑与 Index（demo 页）一致；本设备上 copyFile 会写出全 0、不显式传 offset 的
 * read/write 不可靠，所以源和目标都显式给 offset。
 */
export class GameInstall {
  /** 选「文件夹」安装（GOD / 多 data 文件包必须用文件夹）。返回状态文案。 */
  static async installFolder(ctx: common.Context, filesDir: string,
                             onStatus: (text: string) => void): Promise<string> {
    onStatus('请选择游戏文件夹…');
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    let uris: string[] = [];
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      uris = await docPicker.select(options);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'folder pick failed: %{public}s', JSON.stringify(e));
      return '选择文件夹失败（见 hilog）';
    }
    if (uris.length === 0) {
      return '已取消';
    }

    const uri: string = uris[0];
    const srcPath: string = GameInstall.uriToPath(uri);
    const displayName: string = GameInstall.uriBaseName(srcPath);
    hilog.info(DOMAIN, TAG, 'install folder: uri=%{public}s path=%{public}s',
      uri, srcPath);
    onStatus('复制到沙箱中…（大文件请耐心等待）');

    const id: string = GameLibrary.makeId(displayName, Date.now());
    const dir: string = GameLibrary.gameDir(filesDir, id);
    GameLibrary.ensureDir(dir);

    let count: number = 0;
    try {
      count = await GameInstall.copyRecursive(srcPath, uri, dir);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'copy failed: %{public}s', JSON.stringify(e));
      try {
        GameLibrary.remove(filesDir, id);
      } catch (e2) {
        // 清理失败不影响结果
      }
      return '复制失败（见 hilog）';
    }

    const target: string = GameLibrary.resolveTarget(dir, 0);
    if (target === '') {
      GameLibrary.remove(filesDir, id);
      return '已复制但未找到可启动文件（default.xex / STFS / game*）';
    }

    const meta = new GameMeta();
    meta.id = id;
    meta.name = GameInstall.displayNameFor(displayName);
    meta.titleId = GameInstall.titleIdFor(target);
    meta.target = GameLibrary.toRelative(dir, target);
    meta.kind = 'folder';
    meta.fileCount = count;
    meta.sizeBytes = GameLibrary.dirSize(dir);
    meta.installedAt = Date.now();
    GameLibrary.saveMeta(filesDir, meta);
    hilog.info(DOMAIN, TAG, 'installed slot=%{public}s target=%{public}s files=%{public}d',
      id, target, count);
    hilog.info(DOMAIN, TAG, 'install: target head=%{public}s',
      GameInstall.readHeadHex(target, 16));
    return `已安装：${meta.name}（${count} 个文件）`;
  }

  // ---- 内部工具 ----

  // picker 的 docs URI → 真实路径（fs 的目录接口只接受路径）。
  private static uriToPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      return uri;
    }
  }

  private static uriBaseName(uri: string): string {
    let name: string = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // URI 未编码时保持原样
    }
    return name;
  }

  private static displayNameFor(pickedName: string): string {
    const dot: number = pickedName.lastIndexOf('.');
    return dot > 0 ? pickedName.substring(0, dot) : pickedName;
  }

  // 尽量读出 Xbox Title ID；读不出返回空串（列表用显示名兜底）。
  private static titleIdFor(path: string): string {
    try {
      const god = testNapi.meta.metaInfoFromGodPath(path);
      if (god !== null && god.titleId !== null) {
        return god.titleId;
      }
    } catch (e) {
      // 非 GOD 包，继续
    }
    try {
      const lower: string = path.toLowerCase();
      const format: number = lower.endsWith('.iso') ? 0
        : (lower.endsWith('.zar') ? 2 : 1);
      const id: string | null = testNapi.meta.titleIdFromPath(path, format);
      return id ?? '';
    } catch (e) {
      return '';
    }
  }

  private static readHeadHex(path: string, length: number): string {
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(length);
        const n: number = fs.readSync(f.fd, buf, { offset: 0, length: length });
        const u = new Uint8Array(buf);
        let hex: string = '';
        for (let i = 0; i < n; i++) {
          hex += u[i].toString(16).padStart(2, '0');
        }
        return hex;
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      return '(read failed)';
    }
  }

  // 递归复制目录/文件到沙箱，返回文件数。
  private static async copyRecursive(srcPath: string, srcUri: string,
                                     destPath: string): Promise<number> {
    let isDir: boolean = true;
    let names: string[] = [];
    try {
      names = fs.listFileSync(srcPath);
    } catch (e1) {
      try {
        names = fs.listFileSync(srcUri);
      } catch (e2) {
        isDir = false;
      }
    }
    if (!isDir) {
      const bytes: number = await GameInstall.copyFileAny(srcPath, srcUri, destPath);
      hilog.info(DOMAIN, TAG, 'install: file %{public}s (%{public}d bytes)',
        GameInstall.uriBaseName(srcPath), bytes);
      return 1;
    }
    GameLibrary.ensureDir(destPath);
    let count: number = 0;
    for (const name of names) {
      count += await GameInstall.copyRecursive(`${srcPath}/${name}`,
        `${srcUri}/${name}`, `${destPath}/${name}`);
    }
    return count;
  }

  // 复制单个文件：源优先用 picker URI，失败退回真实路径；两端都显式给 offset。
  private static async copyFileAny(srcPath: string, srcUri: string,
                                   destPath: string): Promise<number> {
    let srcFd: number = -1;
    try {
      srcFd = fs.openSync(srcUri, fs.OpenMode.READ_ONLY).fd;
    } catch (e1) {
      try {
        srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'open src failed: %{public}s', srcPath);
        throw new Error(`open src failed: ${srcPath}`);
      }
    }
    try {
      const size: number = fs.statSync(srcFd).size;
      const dstFd: number = fs.openSync(destPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
      try {
        const chunk: number = 4 * 1024 * 1024;
        const buf = new ArrayBuffer(chunk);
        let copied: number = 0;
        while (copied < size) {
          const want: number = Math.min(chunk, size - copied);
          const rd: number = fs.readSync(srcFd, buf,
            { offset: copied, length: want });
          if (rd <= 0) {
            break;
          }
          fs.writeSync(dstFd, buf, { offset: copied, length: rd });
          copied += rd;
        }
        if (copied !== size) {
          hilog.error(DOMAIN, TAG, 'copy short: %{public}s %{public}d/%{public}d',
            destPath, copied, size);
        }
        return copied;
      } finally {
        fs.closeSync(dstFd);
      }
    } finally {
      fs.closeSync(srcFd);
    }
  }
}
