import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 元数据目录（放在 games/ 下、以 . 开头，避免被当成游戏目录列出）。 */
const META_DIR = '.meta';

/**
 * 一个已安装游戏的元数据。
 * 目录结构：<filesDir>/games/<id>/        游戏内容（复制自 picker 选中的文件/文件夹）
 *          <filesDir>/games/.meta/<id>.json  本文件序列化后的内容
 */
export class GameMeta {
  id: string = '';
  /** 显示名（picker 选中的名字，或 meta 读出的标题名）。 */
  name: string = '';
  /** Xbox 360 Title ID（读不出时为空串）。 */
  titleId: string = '';
  /** 相对 games/<id>/ 的可启动文件，如 'default.xex'。 */
  target: string = '';
  /** 'file' | 'folder' */
  kind: string = 'file';
  fileCount: number = 0;
  sizeBytes: number = 0;
  installedAt: number = 0;
  /** 封面文件绝对路径（安装时从 Xbox 元数据里导出；没有则为空串）。 */
  iconPath: string = '';
}

/** 游戏库：多槽位安装目录 + 元数据 + 列表/删除/启动目标解析。 */
export class GameLibrary {
  static gamesDir(filesDir: string): string {
    return `${filesDir}/games`;
  }

  static metaDir(filesDir: string): string {
    return `${filesDir}/games/${META_DIR}`;
  }

  static gameDir(filesDir: string, id: string): string {
    return `${filesDir}/games/${id}`;
  }

  // ---- 文件系统小工具 ----

  // mkdirSync(path, true) 对已存在目录会抛 EEXIST(13900015)，所以先探测。
  static ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  static removeDirRecursive(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const entries: string[] = fs.listFileSync(path);
      for (const name of entries) {
        const child: string = `${path}/${name}`;
        if (fs.statSync(child).isDirectory()) {
          GameLibrary.removeDirRecursive(child);
        } else {
          fs.unlinkSync(child);
        }
      }
      fs.rmdirSync(path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'removeDirRecursive failed: %{public}s : %{public}s',
        path, JSON.stringify(e));
      throw new Error(`removeDirRecursive ${path} ${JSON.stringify(e)}`);
    }
  }

  // ---- id / 名称 ----

  // 把用户可见名字压成安全的目录名（保留中文/字母数字，其他转 '-'）。
  static sanitize(name: string): string {
    let out: string = '';
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      const code: number = name.charCodeAt(i);
      const isDigit: boolean = code >= 48 && code <= 57;
      const isUpper: boolean = code >= 65 && code <= 90;
      const isLower: boolean = code >= 97 && code <= 122;
      const isCjk: boolean = code >= 0x4e00 && code <= 0x9fff;
      if (isDigit || isUpper || isLower || isCjk) {
        out += c;
      } else if (out.length > 0 && !out.endsWith('-')) {
        out += '-';
      }
    }
    while (out.endsWith('-')) {
      out = out.substring(0, out.length - 1);
    }
    if (out.length === 0) {
      out = 'game';
    }
    return out.length > 40 ? out.substring(0, 40) : out;
  }

  // 名字 + 时间戳保证唯一（同名游戏可装多份）。
  static makeId(name: string, at: number): string {
    return `${GameLibrary.sanitize(name)}-${at}`;
  }

  // ---- 元数据读写 ----

  static metaPath(filesDir: string, id: string): string {
    return `${GameLibrary.metaDir(filesDir)}/${id}.json`;
  }

  /** 封面文件路径（安装时写在这里）。 */
  static iconPathOf(filesDir: string, id: string): string {
    return `${GameLibrary.metaDir(filesDir)}/${id}.png`;
  }

  static saveMeta(filesDir: string, meta: GameMeta): void {
    GameLibrary.ensureDir(GameLibrary.metaDir(filesDir));
    const path: string = GameLibrary.metaPath(filesDir, meta.id);
    const fd = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(fd.fd, JSON.stringify(meta));
    } finally {
      fs.closeSync(fd);
    }
  }

  static loadMeta(filesDir: string, id: string): GameMeta | undefined {
    const path: string = GameLibrary.metaPath(filesDir, id);
    try {
      if (!fs.accessSync(path)) {
        return undefined;
      }
      const text: string = fs.readTextSync(path);
      const parsed: GameMeta = JSON.parse(text) as GameMeta;
      const meta = new GameMeta();
      meta.id = parsed.id ?? id;
      meta.name = parsed.name ?? meta.id;
      meta.titleId = parsed.titleId ?? '';
      meta.target = parsed.target ?? '';
      meta.kind = parsed.kind ?? 'file';
      meta.fileCount = parsed.fileCount ?? 0;
      meta.sizeBytes = parsed.sizeBytes ?? 0;
      meta.installedAt = parsed.installedAt ?? 0;
      // 封面在不在由文件系统决定（元数据里不存路径）。
      const icon: string = GameLibrary.iconPathOf(filesDir, meta.id);
      try {
        meta.iconPath = fs.accessSync(icon) ? icon : '';
      } catch (e) {
        meta.iconPath = '';
      }
      return meta;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadMeta failed: %{public}s : %{public}s',
        id, JSON.stringify(e));
      return undefined;
    }
  }

  /**
   * 列出全部游戏（新装的在前）。没有元数据的目录会按目录名兜底，
   * 这样手工拷进来的目录也能出现在列表里。
   */
  static list(filesDir: string): GameMeta[] {
    const out: GameMeta[] = [];
    const dir: string = GameLibrary.gamesDir(filesDir);
    try {
      if (!fs.accessSync(dir)) {
        return out;
      }
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        if (name.startsWith('.')) {
          continue;
        }
        if (!fs.statSync(`${dir}/${name}`).isDirectory()) {
          continue;
        }
        const meta: GameMeta | undefined = GameLibrary.loadMeta(filesDir, name);
        if (meta !== undefined) {
          out.push(meta);
        } else {
          const fallback = new GameMeta();
          fallback.id = name;
          fallback.name = name;
          out.push(fallback);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'list failed: %{public}s', JSON.stringify(e));
    }
    out.sort((a: GameMeta, b: GameMeta) => b.installedAt - a.installedAt);
    return out;
  }

  /** 删除游戏（内容目录 + 元数据）。 */
  static remove(filesDir: string, id: string): void {
    GameLibrary.removeDirRecursive(GameLibrary.gameDir(filesDir, id));
    const metaPath: string = GameLibrary.metaPath(filesDir, id);
    try {
      if (fs.accessSync(metaPath)) {
        fs.unlinkSync(metaPath);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'remove meta failed: %{public}s : %{public}s',
        id, JSON.stringify(e));
    }
  }

  /** 递归累计目录占用字节数（只 stat，不读内容）。 */
  static dirSize(path: string): number {
    let total: number = 0;
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      const st = fs.statSync(path);
      if (!st.isDirectory()) {
        return st.size;
      }
      const names: string[] = fs.listFileSync(path);
      for (const name of names) {
        total += GameLibrary.dirSize(`${path}/${name}`);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'dirSize failed: %{public}s : %{public}s',
        path, JSON.stringify(e));
    }
    return total;
  }

  // ---- 启动目标解析 ----

  /**
   * 在目录中找可启动文件，返回绝对路径（找不到返回 ''）。
   * 优先级：default.xex > 精确 game > 有同名 .data 目录的文件（多文件
   * STFS/SVOD 头）> 16~40 位十六进制文件名（STFS 内容 ID）> game* >
   * 递归子目录 > 第一个文件。点开头的文件（元数据/隐藏文件）跳过。
   */
  static resolveTarget(dir: string, depth: number): string {
    try {
      if (depth > 8 || !fs.accessSync(dir)) {
        return '';
      }
      const names: string[] = fs.listFileSync(dir).filter(
        (n: string) => !n.startsWith('.'));
      for (const n of names) {
        if (n.toLowerCase() === 'default.xex') {
          return `${dir}/${n}`;
        }
      }
      for (const n of names) {
        if (n === 'game' && !fs.statSync(`${dir}/${n}`).isDirectory()) {
          return `${dir}/${n}`;
        }
      }
      for (const n of names) {
        if (fs.statSync(`${dir}/${n}`).isDirectory()) {
          continue;
        }
        const dataDir: string = `${dir}/${n}.data`;
        if (fs.accessSync(dataDir) && fs.statSync(dataDir).isDirectory()) {
          return `${dir}/${n}`;
        }
      }
      // STFS 包的文件名是十六进制，长度随内容类型而定：GOD 常见 16 位，
    // XBLA（000D0000）实测是 42 位，所以上限要放宽（原来写死 40 会漏掉）。
    const hexName = new RegExp('^[0-9A-Fa-f]{16,64}$');
      for (const n of names) {
        if (!fs.statSync(`${dir}/${n}`).isDirectory() && hexName.test(n)) {
          return `${dir}/${n}`;
        }
      }
      for (const n of names) {
        if (n.startsWith('game') && !fs.statSync(`${dir}/${n}`).isDirectory()) {
          return `${dir}/${n}`;
        }
      }
      for (const n of names) {
        if (fs.statSync(`${dir}/${n}`).isDirectory()) {
          const t: string = GameLibrary.resolveTarget(`${dir}/${n}`, depth + 1);
          if (t !== '') {
            return t;
          }
        }
      }
      for (const n of names) {
        if (!fs.statSync(`${dir}/${n}`).isDirectory()) {
          return `${dir}/${n}`;
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'resolveTarget failed: %{public}s',
        JSON.stringify(e));
    }
    return '';
  }

  /** 绝对路径 → 相对游戏目录的路径（存进元数据）。 */
  static toRelative(gameDir: string, absPath: string): string {
    const prefix: string = `${gameDir}/`;
    return absPath.startsWith(prefix) ? absPath.substring(prefix.length) : absPath;
  }

  /** 元数据里的相对路径 → 绝对路径。 */
  static toAbsolute(filesDir: string, meta: GameMeta): string {
    const dir: string = GameLibrary.gameDir(filesDir, meta.id);
    return meta.target.length > 0 ? `${dir}/${meta.target}` : dir;
  }

  // ---- 展示用格式化 ----

  static formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '';
    }
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    }
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${(bytes / 1024).toFixed(0)} KB`;
  }

  static formatDate(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d = new Date(ms);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
}
