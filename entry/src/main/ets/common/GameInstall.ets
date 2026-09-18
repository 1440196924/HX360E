import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import testNapi from 'libentry.so';
import { GameLibrary, GameMeta } from './GameLibrary';
import { copyRanges } from './InstallCopy';
import { AppLog } from './AppLog';
// rar 解压：基于 UnRAR 的 ohpm 包（Apache-2.0），只接受沙箱路径，支持加密包。
import { UnrarApi } from '@ohos/unrar';
import { extractRar } from './RarExtract';

const DOMAIN = 0x0000;
const TAG = 'HX360E';
/** 一个复制批次最多装多少字节（= 一次 taskpool 任务的工作量）。 */
const BATCH_BYTES: number = 16 * 1024 * 1024;
/** 一个批次最多装多少条记录（小文件多时别把批次撑太大）。 */
const BATCH_ITEMS: number = 32;
/** 同时挂到任务池上的复制任务数。 */
const CONCURRENCY: number = 4;
/** 扫描阶段每发现多少个文件刷新一次 UI。 */
const SCAN_REPORT_EVERY: number = 256;

/** 从 Xbox 元数据里读到的标题信息。 */
class TitleMeta {
  name: string = '';
  titleId: string = '';
  iconBytes: ArrayBuffer | undefined = undefined;
}

/** 安装进度：主线程持有的普通对象，回调里直接映射成 @State。 */
export class InstallProgress {
  /** true = 显示进度浮层（扫描/复制/落元数据阶段）。 */
  active: boolean = false;
  title: string = '正在安装';
  /** 当前动作（扫描中 / 正在复制：xxx）。 */
  detail: string = '';
  /** 已复制 / 总量。 */
  stats: string = '';
  percent: number = 0;
  copied: number = 0;
  total: number = 0;
  /** 已解出/已复制的文件数（压缩包安装用）。 */
  files: number = 0;
}

/** 取消开关：UI 线程置 true，安装循环在下一批任务前检查。 */
export class InstallControl {
  canceled: boolean = false;
}

/** 扫描结果：待复制文件清单（相对路径 / 真实路径 / picker URI / 大小）。 */
class InstallPlan {
  rels: string[] = [];
  srcs: string[] = [];
  uris: string[] = [];
  sizes: number[] = [];
  totalBytes: number = 0;
}

/** 一个复制批次（并列数组，直接喂给并发函数）。 */
class CopyBatch {
  label: string = '';
  uris: string[] = [];
  srcs: string[] = [];
  dsts: string[] = [];
  offsets: number[] = [];
  lengths: number[] = [];
  bytes: number = 0;
}

/**
 * 游戏安装：调系统文件选择器 → 扫描源目录 → 建目标文件 → **后台线程分批复
 * 制**（taskpool，4 并发，带进度）→ 解析启动目标 → 写元数据。
 *
 * 复制放到任务池线程上，主线程只做扫描/建文件/汇总进度，所以复制几 GB 的
 * 游戏时 UI 不卡、进度条能动、还能取消。每个批次用并列的基础类型数组传参，
 * 跨线程序列化最省。
 *
 * 注意：本设备上 copyFile 会写出全 0、不显式传 offset 的 read/write 不可靠，
 * 所以源和目标都显式给 offset（在 InstallCopy.copyRanges 里）。
 */
export class GameInstall {
  /** 选「文件夹」安装（GOD / 多 data 文件包必须用文件夹）。返回状态文案。 */
  static async installFolder(ctx: common.Context, filesDir: string,
                             onProgress: (p: InstallProgress) => void,
                             control: InstallControl): Promise<string> {
    const p = new InstallProgress();
    p.active = false;
    p.detail = '请选择游戏文件夹…';
    onProgress(p);

    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    // 打点：把请求的参数记下来。部分设备的文件选择器不支持「选文件夹」，
    // 可能①抛异常 ②静默返回空数组 —— 两种情况都要能从日志区分出来。
    AppLog.i('install', 'folder pick: open picker (mode=FOLDER max=1)');
    let uris: string[] = [];
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      uris = await docPicker.select(options);
    } catch (e) {
      // 「选文件夹」模式在部分设备的文件选择器上不被支持，会抛在这里。
      AppLog.exception('install', 'folder pick failed (picker rejected)', e);
      return '选择文件夹失败（见 hilog）';
    }
    AppLog.i('install', `folder pick: returned ${uris.length} uri(s)`);
    if (uris.length === 0) {
      AppLog.w('install',
        'folder pick: empty result —— 选择器不支持该模式或用户取消');
      return '已取消';
    }

    const uri: string = uris[0];
    const srcPath: string = GameInstall.uriToPath(uri);
    const displayName: string = GameInstall.uriBaseName(srcPath);
    hilog.info(DOMAIN, TAG, 'install folder: uri=%{public}s path=%{public}s',
      uri, srcPath);

    // 1) 扫描源目录：先拿到文件清单和总字节数，进度条才有分母。
    p.active = true;
    p.detail = '正在扫描源文件夹…';
    p.percent = 0;
    onProgress(p);
    const plan: InstallPlan = GameInstall.scan(srcPath, uri, p, onProgress);
    if (plan.rels.length === 0) {
      return '文件夹里没有可复制的文件';
    }

    const id: string = GameLibrary.makeId(displayName, Date.now());
    const dir: string = GameLibrary.gameDir(filesDir, id);
    GameLibrary.ensureDir(dir);

    // 2) 在主线程把所有目标文件建好（TRUNC），后台线程只做 READ_WRITE。
    //    这样同一个大文件的多个分段并发写也不会互相截断。
    try {
      for (const rel of plan.rels) {
        const dst: string = `${dir}/${rel}`;
        const slash: number = dst.lastIndexOf('/');
        if (slash > 0) {
          GameLibrary.ensureDir(dst.substring(0, slash));
        }
        fs.closeSync(fs.openSync(dst, fs.OpenMode.READ_WRITE
          | fs.OpenMode.CREATE | fs.OpenMode.TRUNC));
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create dest failed: %{public}s', JSON.stringify(e));
      GameInstall.cleanup(filesDir, id);
      return '创建目标文件失败（见 hilog）';
    }

    // 3) 后台分批复制。
    const batches: CopyBatch[] = GameInstall.planBatches(plan, dir);
    hilog.info(DOMAIN, TAG,
      'install: %{public}d files / %{public}d bytes / %{public}d batches',
      plan.rels.length, plan.totalBytes, batches.length);
    p.total = plan.totalBytes;
    p.copied = 0;
    p.percent = 0;
    p.detail = '正在复制…';
    p.stats = `${GameLibrary.formatSize(plan.totalBytes)} 待复制`;
    onProgress(p);

    let copied: number = 0;
    let next: number = 0;
    while (next < batches.length) {
      if (control.canceled) {
        break;
      }
      const wave: CopyBatch[] = batches.slice(next, next + CONCURRENCY);
      next += wave.length;
      const group: taskpool.TaskGroup = new taskpool.TaskGroup();
      for (const b of wave) {
        group.addTask(new taskpool.Task(copyRanges, b.uris, b.srcs, b.dsts,
          b.offsets, b.lengths));
      }
      try {
        const ret: Object = await taskpool.execute(group);
        const nums: number[] = ret as number[];
        for (const n of nums) {
          copied += n;
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'copy failed: %{public}s', JSON.stringify(e));
        GameInstall.cleanup(filesDir, id);
        return '复制失败（见 hilog）';
      }
      p.copied = copied;
      p.percent = plan.totalBytes > 0
        ? Math.min(99, copied * 100 / plan.totalBytes) : 99;
      p.detail = `正在复制：${wave[0].label}`;
      p.stats = `${GameLibrary.formatSize(copied)} / ` +
        `${GameLibrary.formatSize(plan.totalBytes)}`;
      onProgress(p);
      hilog.info(DOMAIN, TAG, 'install: %{public}d/%{public}d bytes',
        copied, plan.totalBytes);
    }
    if (control.canceled) {
      GameInstall.cleanup(filesDir, id);
      return '已取消安装';
    }

    // 4) 收尾：找启动目标 + 读标题/封面 + 落元数据。
    p.detail = '正在读取游戏信息…';
    p.percent = 99;
    onProgress(p);
    const target: string = GameLibrary.resolveTarget(dir, 0);
    if (target === '') {
      GameInstall.cleanup(filesDir, id);
      return '已复制但未找到可启动文件（default.xex / STFS / game*）';
    }

    const tm: TitleMeta = GameInstall.readTitleMeta(target);
    const meta = new GameMeta();
    meta.id = id;
    meta.name = tm.name !== '' ? tm.name : GameInstall.displayNameFor(displayName);
    meta.titleId = tm.titleId;
    meta.target = GameLibrary.toRelative(dir, target);
    meta.kind = 'folder';
    meta.fileCount = plan.rels.length;
    meta.sizeBytes = copied;
    meta.installedAt = Date.now();
    if (tm.iconBytes !== undefined && tm.iconBytes.byteLength > 0) {
      const iconPath: string = GameLibrary.iconPathOf(filesDir, id);
      if (GameInstall.writeBytes(iconPath, tm.iconBytes)) {
        meta.iconPath = iconPath;
        hilog.info(DOMAIN, TAG, 'icon exported (%{public}d bytes)',
          tm.iconBytes.byteLength);
      }
    }
    if (meta.titleId === '') {
      meta.titleId = GameInstall.titleIdFor(target);
    }
    GameLibrary.saveMeta(filesDir, meta);
    hilog.info(DOMAIN, TAG, 'installed slot=%{public}s target=%{public}s files=%{public}d',
      id, target, plan.rels.length);
    hilog.info(DOMAIN, TAG, 'install: target head=%{public}s',
      GameInstall.readHeadHex(target, 16));

    p.active = false;
    p.percent = 100;
    p.copied = copied;
    p.detail = meta.name;
    p.stats = `${GameLibrary.formatSize(copied)} · ${plan.rels.length} 个文件`;
    onProgress(p);
    return `已安装：${meta.name}（${plan.rels.length} 个文件）`;
  }

  /**
   * 选「压缩包」安装（.zip → 直接解压进沙箱）。
   *
   * 解压在原生后台线程跑（几 GB 不能占 UI 线程），这里用 200ms 轮询刷新进度。
   * 加密包的处理：第一次不带密码试跑，原生侧扫到加密项会立刻返回 needPassword
   * （此时一个文件都没落），再调 askPassword 拿密码重跑；口令错可重试。
   *
   * @param askPassword 需要密码时的回调（retry=true 表示上次口令不对）。
   */
  static async installArchive(ctx: common.Context, filesDir: string,
                              onProgress: (p: InstallProgress) => void,
                              control: InstallControl,
                              askPassword: (retry: boolean) => Promise<string>):
                              Promise<string> {
    const p = new InstallProgress();
    p.active = false;
    p.detail = '请选择压缩包…';
    onProgress(p);

    const options = new picker.DocumentSelectOptions();
    // 多选：分卷包（.z01/.z02/…/.zip 或 .001/.002/…）必须一次把各卷都选上
    // —— 选择器只授权被选中的文件，同目录里没选中的分卷我们读不到。
    // 注意**不设 fileSuffixFilters**：分卷的尾缀是 .001/.002/.z01 之类，
    // 用 '压缩包|.zip' 过滤会让这些卷根本选不中（而且过滤会作用于每一次多选）。
    options.maxSelectNumber = 32;
    AppLog.i('install', 'archive pick: open picker (mode=FILE multi, no suffix filter)');
    let uris: string[] = [];
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      uris = await docPicker.select(options);
    } catch (e) {
      AppLog.exception('install', 'archive pick failed (picker rejected)', e);
      return '选择压缩包失败（见 hilog）';
    }
    AppLog.i('install', `archive pick: returned ${uris.length} uri(s)`);
    if (uris.length === 0) {
      AppLog.w('install', 'archive pick: empty result（取消或选择器异常）');
      return '已取消';
    }

    // 1) 把选中的文件按卷序排好（分卷 zip 各卷按序拼接才是完整 zip）。
    const ordered: string[] = GameInstall.orderVolumes(uris);
    const volNames: string[] = [];
    for (const u of ordered) {
      volNames.push(GameInstall.uriBaseName(u));
    }
    AppLog.i('install',
      `archive volumes(${ordered.length}): ${volNames.join(' | ')}`);
    const displayName: string = GameInstall.displayNameForArchive(volNames[0]);

    const id: string = GameLibrary.makeId(displayName, Date.now());
    const dir: string = GameLibrary.gameDir(filesDir, id);
    GameLibrary.ensureDir(dir);

    // 2) 先把压缩包复制进沙箱：选择器给的是 URI/公共目录路径，只有 ArkTS 的 fs
    //    认 URI，native 的 open() 读不了；rar 库也明确要求沙箱路径。所以统一落盘。
    //    注意**保留原文件名**并放在独立子目录里：多卷 rar（.part1.rar / .r00…）
    //    要靠"同目录同名的相邻卷"去找后续卷，改名就找不到了。
    p.active = true;
    p.detail = ordered.length > 1
      ? `正在复制 ${ordered.length} 个分卷到沙箱…`
      : '正在复制压缩包到沙箱…';
    p.percent = 0;
    onProgress(p);
    const stageDir: string = `${dir}/__in`;
    GameLibrary.ensureDir(stageDir);
    const staged: string[] = [];
    try {
      for (let i = 0; i < ordered.length; i++) {
        const dst: string = `${stageDir}/${GameInstall.uriBaseName(ordered[i])}`;
        // 不能用 fs.copyFileSync(uri, path)：选择器给的是 file://docs/... URI，
        // copyFileSync 会报 13900002（文件不存在）。必须先用 openSync(uri) 拿到
        // fd 再按显式 offset 读写 —— 与本文件下半部分 copyRanges 的做法一致
        // （本设备上不显式传 offset 的 read/write 会写出全 0）。
        const n: number = GameInstall.copyInto(ordered[i], dst);
        AppLog.i('install', `archive staged[${i}]: ${n} bytes -> ${GameInstall.uriBaseName(ordered[i])}`);
        staged.push(dst);
      }
    } catch (e) {
      AppLog.exception('install', 'stage archive failed', e);
      GameInstall.cleanup(filesDir, id);
      return '复制压缩包到沙箱失败（见导出日志）';
    }
    AppLog.i('install', `archive staged: ${staged.length} file(s)`);

    // 3) 认内容格式：分卷命名只说明"怎么切的"，内容可能是 zip 也可能是 rar。
    const magic: string = GameInstall.readMagic(staged[0]);
    AppLog.i('install', `archive magic=${magic}`);
    if (magic !== 'zip' && magic !== 'rar') {
      GameInstall.cleanup(filesDir, id);
      if (magic === '7z') {
        return '这是 7z 包，暂不支持；请先解压后重新打包成 zip';
      }
      return '无法识别的压缩包格式（目前支持 zip / rar）';
    }

    // 4) 解压（可能需要密码，最多让用户重试 3 次）。
    let password: string = '';
    let attempts: number = 0;
    while (true) {
      const r: string = await GameInstall.extractOnce(magic, staged, dir, password,
        p, onProgress, control);
      if (r === '') {
        break;   // 解压成功
      }
      if (r === 'canceled') {
        GameInstall.cleanup(filesDir, id);
        return '已取消安装';
      }
      if ((r === 'need_password' || r === 'bad_password') && attempts < 3) {
        attempts++;
        password = await askPassword(r === 'bad_password');
        if (password === '') {
          GameInstall.cleanup(filesDir, id);
          return '已取消（未输入密码）';
        }
        continue;
      }
      GameInstall.cleanup(filesDir, id);
      return r === 'bad_password' ? '密码错误（已尝试多次）' : r;
    }

    // 2) 收尾：删掉沙箱里的临时分卷副本（只是解压用的中转，别留在游戏目录里
    //    占空间、也别被当成游戏内容），再找启动目标 + 读标题/封面 + 落元数据。
    for (const s of staged) {
      try {
        fs.unlinkSync(s);
      } catch (e) {
        // 删不掉不影响安装
      }
    }
    p.detail = '正在读取游戏信息…';
    p.percent = 99;
    onProgress(p);
    // 解压后把目录树打进 app.log：装不上时这一份就是最直接的现场（能看出
    // 条目名解码对不对、启动文件到底叫什么）。
    GameInstall.logTree('install', dir, 1, 4);
    const target: string = GameLibrary.resolveTarget(dir, 0);
    if (target === '') {
      AppLog.e('install', `未找到启动目标，目录=${dir}`);
      GameInstall.cleanup(filesDir, id);
      return '已解压但未找到可启动文件（default.xex / STFS / game*）';
    }
    AppLog.i('install', `target=${target}`);

    const tm: TitleMeta = GameInstall.readTitleMeta(target);
    const meta = new GameMeta();
    meta.id = id;
    meta.name = tm.name !== '' ? tm.name : GameInstall.displayNameFor(displayName);
    meta.titleId = tm.titleId;
    meta.target = GameLibrary.toRelative(dir, target);
    meta.kind = 'folder';
    meta.fileCount = p.files;
    meta.sizeBytes = p.copied;
    meta.installedAt = Date.now();
    if (tm.iconBytes !== undefined && tm.iconBytes.byteLength > 0) {
      const iconPath: string = GameLibrary.iconPathOf(filesDir, id);
      if (GameInstall.writeBytes(iconPath, tm.iconBytes)) {
        meta.iconPath = iconPath;
      }
    }
    if (meta.titleId === '') {
      meta.titleId = GameInstall.titleIdFor(target);
    }
    GameLibrary.saveMeta(filesDir, meta);
    hilog.info(DOMAIN, TAG,
      'installed from archive slot=%{public}s target=%{public}s files=%{public}d',
      id, target, p.files);

    p.active = false;
    p.percent = 100;
    p.detail = meta.name;
    p.stats = `${GameLibrary.formatSize(p.copied)} · ${p.files} 个文件`;
    onProgress(p);
    return `已安装：${meta.name}（${p.files} 个文件）`;
  }

  /**
   * 跑一次解压任务并轮询到结束。
   *
   * @return 空串 = 成功；'canceled' / 'need_password' / 'bad_password' / 其他错误文案。
   */
  private static async runExtract(zipPath: string, destDir: string,
                                  password: string, p: InstallProgress,
                                  onProgress: (p: InstallProgress) => void,
                                  control: InstallControl): Promise<string> {
    p.active = true;
    p.detail = '正在解压…';
    p.percent = 0;
    p.stats = '';
    onProgress(p);

    let handle: string = '';
    try {
      handle = testNapi.zip.extractStart(zipPath, destDir, password);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'extractStart failed: %{public}s', JSON.stringify(e));
      return '解压失败（见 hilog）';
    }
    if (handle === '') {
      return '已有解压任务在进行';
    }

    let canceled: boolean = false;
    while (true) {
      const st = testNapi.zip.extractPoll();
      if (st.active && !st.finished && !canceled) {
        p.copied = st.done;
        p.total = st.total;
        p.percent = st.total > 0
          ? Math.min(99, st.done * 100 / st.total) : 0;
        if (st.name !== '') {
          p.detail = `正在解压：${st.name}`;
        }
        if (st.total > 0) {
          p.stats = `${GameLibrary.formatSize(st.done)} / ` +
            `${GameLibrary.formatSize(st.total)}`;
        }
        onProgress(p);
      }
      if (control.canceled && !canceled) {
        canceled = true;
        testNapi.zip.extractCancel();
      }
      if (st.finished) {
        break;
      }
      if (!st.active) {
        break;
      }
      await GameInstall.sleep(200);
    }

    const st = testNapi.zip.extractPoll();
    const error: string = st.error;
    const ok: boolean = st.ok;
    const files: number = st.files;
    const done: number = st.done;
    const total: number = st.total;
    const needPw: boolean = st.needPassword;
    const badPw: boolean = st.badPassword;
    const wasCanceled: boolean = st.canceled || canceled;
    testNapi.zip.extractFinish();

    if (wasCanceled) {
      return 'canceled';
    }
    if (ok) {
      p.copied = done;
      p.total = total > 0 ? total : done;
      p.files = files;
      return '';
    }
    if (needPw) {
      return 'need_password';
    }
    if (badPw) {
      return 'bad_password';
    }
    return error !== '' ? error : '解压失败';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // ---- 内部工具 ----

  /** 读文件头判格式：zip / rar / 7z / unknown。 */
  private static readMagic(path: string): string {
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(6);
        const n: number = fs.readSync(f.fd, buf, { offset: 0, length: 6 });
        const u = new Uint8Array(buf);
        if (n >= 2 && u[0] === 0x50 && u[1] === 0x4B) {
          return 'zip';
        }
        if (n >= 4 && u[0] === 0x52 && u[1] === 0x61 && u[2] === 0x72 &&
          u[3] === 0x21) {
          return 'rar';
        }
        if (n >= 6 && u[0] === 0x37 && u[1] === 0x7A && u[2] === 0xBC &&
          u[3] === 0xAF && u[4] === 0x27 && u[5] === 0x1C) {
          return '7z';
        }
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      AppLog.exception('install', 'readMagic failed', e);
    }
    return 'unknown';
  }

  /** 按格式分发一次解压；返回 '' = 成功。 */
  private static async extractOnce(magic: string, staged: string[],
                                  dir: string, password: string,
                                  p: InstallProgress,
                                  onProgress: (p: InstallProgress) => void,
                                  control: InstallControl): Promise<string> {
    if (magic === 'rar') {
      // 压缩包已解压字节数要从"目标目录大小"里扣掉（暂存副本也在目标目录下）。
      let archiveBytes: number = 0;
      for (const s of staged) {
        const st = GameLibrary.stat(s);
        if (st !== undefined) {
          archiveBytes += st.size;
        }
      }
      return GameInstall.runRarExtract(staged[0], dir, password, archiveBytes, p,
        onProgress, control);
    }
    // zip：多卷按顺序用 '\n' 拼给 native（各卷按序拼接才是完整 zip）。
    return GameInstall.runExtract(staged.join('\n'), dir, password, p,
      onProgress, control);
  }

  /**
   * 用 @ohos/unrar 解压 rar（含加密包）。
   *
   * 该库没有进度回调，只能整包 await 完再置 100%；取消也无法中断（解压期间
   * 只记录取消请求，完成后由上层丢弃目录）。
   */
  private static async runRarExtract(path: string, destDir: string,
                                     password: string, archiveBytes: number,
                                     p: InstallProgress,
                                     onProgress: (p: InstallProgress) => void,
                                     control: InstallControl): Promise<string> {
    p.active = true;
    p.detail = '正在解压 rar…';
    p.percent = 0;
    p.stats = '';
    onProgress(p);

    let encrypted: number = 0;
    try {
      encrypted = UnrarApi.isEncrypted(path);
    } catch (e) {
      AppLog.exception('install', 'rar isEncrypted failed', e);
      encrypted = 0;
    }
    AppLog.i('install',
      `rar: encrypted=${encrypted} password=${password !== '' ? 'yes' : 'no'}`);
    if (encrypted > 0 && password === '') {
      return 'need_password';
    }
    if (control.canceled) {
      return 'canceled';
    }
    try {
      // 同步 extract() 放到任务池线程（见 RarExtract.ets 的说明：自带的异步
      // 接口没有 .catch，失败时会永久挂起）。
      //
      // 进度：这个库没有任何进度回调，也没有"总解压量"可查，所以只能在解压期间
      // 每秒看一次目标目录长大了多少，显示「已解压 xx MB」。这是动态反馈，
      // 不是百分比 —— 想要真进度条得自己接 UnRAR 的 CALLBACK/UCM_PROCESSDATA。
      let finished: boolean = false;
      let result: string = 'exception';
      taskpool.execute(extractRar, path, destDir, password)
        .then((v: Object) => {
          result = v as string;
          finished = true;
        })
        .catch((e: Error) => {
          AppLog.exception('install', 'rar extract rejected', e);
          finished = true;
        });
      while (!finished) {
        await GameInstall.sleep(1000);
        const grown: number = GameLibrary.dirSize(destDir) - archiveBytes;
        p.stats = `已解压 ${GameLibrary.formatSize(grown > 0 ? grown : 0)}`;
        onProgress(p);
      }
      const r: string = result;
      AppLog.i('install', `rar: extract returned [${r}]`);
      if (r === 'need_password') {
        return 'need_password';
      }
      // 成功时返回固定文案「解压成功」；其余（含口令错）都视为失败。
      if (r !== '解压成功') {
        return encrypted > 0
          ? 'bad_password'
          : (r !== '' && r !== 'exception' ? r : '解压失败（见导出日志）');
      }
    } catch (e) {
      AppLog.exception('install', 'rar extract failed', e);
      return encrypted > 0 ? 'bad_password' : '解压失败（见导出日志）';
    }
    p.percent = 99;
    p.detail = '正在解压 rar…';
    onProgress(p);
    return '';
  }

  /**
   * 把选择器给的 URI 文件复制到沙箱路径，返回复制的字节数。
   *
   * 关键两点（都是本设备实测踩出来的）：
   *  1. 源必须用 `fs.openSync(uri)` 打开成 fd —— 直接对 URI 调 copyFileSync 会
   *     报 13900002（文件不存在），选择器的授权是按 URI 走的。
   *  2. read/write 都必须显式传 offset，否则会写出全 0。
   */
  /**
   * 把目录树打进 app.log（诊断用）。
   *
   * 安装失败时最需要的就是"磁盘上到底有什么"：条目名解码是否正常、启动文件
   * 叫什么名字。装不上时不用再让用户复现，直接看这份。
   */
  static logTree(tag: string, dir: string, level: number, maxLevel: number): void {
    if (level > maxLevel) {
      return;
    }
    let names: string[] = [];
    try {
      // 同样跳过非法名字（含 U+FFFD），否则打印树时自己就抛 13900002。
      names = fs.listFileSync(dir).filter(
        (n: string) => n.indexOf('\uFFFD') < 0);
    } catch (e) {
      AppLog.w(tag, `list failed: ${dir}`);
      return;
    }
    for (const n of names) {
      const full: string = `${dir}/${n}`;
      let isDir: boolean = false;
      let size: number = 0;
      try {
        const st = fs.statSync(full);
        isDir = st.isDirectory();
        size = st.size;
      } catch (e) {
        AppLog.w(tag, `stat failed: ${n}`);
        continue;
      }
      AppLog.i(tag, `  ${'  '.repeat(level)}${n}${isDir ? '/' : ` [${size}]`}`);
      if (isDir) {
        GameInstall.logTree(tag, full, level + 1, maxLevel);
      }
    }
  }

  private static copyInto(srcUri: string, dstPath: string): number {
    const inFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    const outFile = fs.openSync(dstPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const chunk: number = 4 * 1024 * 1024;
      const buf = new ArrayBuffer(chunk);
      let off: number = 0;
      while (true) {
        const n: number = fs.readSync(inFile.fd, buf,
          { offset: off, length: chunk });
        if (n <= 0) {
          break;
        }
        fs.writeSync(outFile.fd, buf, { offset: off, length: n });
        off += n;
      }
      return off;
    } finally {
      fs.closeSync(inFile);
      fs.closeSync(outFile);
    }
  }

  /**
   * 把选中的文件按「分卷顺序」排好。
   *
   * 支持两种常见命名：
   *   - WinRAR/7-Zip 切分卷：`X.z01`、`X.z02`…`X.zip`（最后一个卷是 .zip）
   *   - 数字卷：`X.001`、`X.002`…（部分工具这么切）
   * 其余情况按原顺序返回（单卷就是原样一个）。
   */
  private static orderVolumes(uris: string[]): string[] {
    if (uris.length <= 1) {
      return uris;
    }
    const names: string[] = [];
    for (const u of uris) {
      names.push(GameInstall.uriBaseName(u));
    }
    // 用「去掉卷后缀」的基名分组，组内按卷序号排；.zip（最后一卷）排最后。
    const idxOf = (name: string): number => {
      const lower: string = name.toLowerCase();
      if (lower.endsWith('.zip')) {
        return 100000;   // 最后一卷
      }
      const m = lower.match(/\.z(\d{2,})$/);
      if (m !== null) {
        return parseInt(m[1], 10);
      }
      const m2 = lower.match(/\.(\d{3,})$/);
      if (m2 !== null) {
        return parseInt(m2[1], 10);
      }
      const m3 = lower.match(/\.part(\d+)\.zip$/);
      if (m3 !== null) {
        return parseInt(m3[1], 10);
      }
      return 0;
    };
    const idx: number[] = [];
    for (let i = 0; i < uris.length; i++) {
      idx.push(i);
    }
    idx.sort((a: number, b: number) => idxOf(names[a]) - idxOf(names[b]));
    const out: string[] = [];
    for (const i of idx) {
      out.push(uris[i]);
    }
    return out;
  }

  /** 分卷包名 → 显示名（去掉 .z01 / .001 / .part1 这类卷后缀）。 */
  private static displayNameForArchive(name: string): string {
    let n: string = name.replace(/\.zip$/i, '');
    n = n.replace(/\.z\d{2,}$/i, '');
    n = n.replace(/\.\d{3,}$/i, '');
    n = n.replace(/\.part\d+$/i, '');
    return n === '' ? name : n;
  }

  private static cleanup(filesDir: string, id: string): void {
    try {
      GameLibrary.remove(filesDir, id);
    } catch (e) {
      // 清理失败不影响结果
    }
  }

  // 扫描源目录（只 list/stat，不读内容）。会定期回调刷新「已发现 N 个文件」。
  private static scan(srcPath: string, srcUri: string, p: InstallProgress,
                      onProgress: (p: InstallProgress) => void): InstallPlan {
    const plan = new InstallPlan();
    GameInstall.walk(srcPath, srcUri, '', plan, p, onProgress, 0);
    p.detail = `已发现 ${plan.rels.length} 个文件`;
    p.stats = GameLibrary.formatSize(plan.totalBytes);
    onProgress(p);
    return plan;
  }

  private static walk(srcPath: string, srcUri: string, rel: string,
                      plan: InstallPlan, p: InstallProgress,
                      onProgress: (p: InstallProgress) => void,
                      depth: number): void {
    if (depth > 16) {
      return;
    }
    let names: string[] = [];
    let isDir: boolean = true;
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
      let size: number = 0;
      try {
        size = fs.statSync(srcPath).size;
      } catch (e1) {
        try {
          size = fs.statSync(srcUri).size;
        } catch (e2) {
          size = 0;
        }
      }
      plan.rels.push(rel);
      plan.srcs.push(srcPath);
      plan.uris.push(srcUri);
      plan.sizes.push(size);
      plan.totalBytes += size;
      if (plan.rels.length % SCAN_REPORT_EVERY === 0) {
        p.detail = `已发现 ${plan.rels.length} 个文件`;
        p.stats = GameLibrary.formatSize(plan.totalBytes);
        onProgress(p);
      }
      return;
    }
    for (const name of names) {
      const childRel: string = rel === '' ? name : `${rel}/${name}`;
      GameInstall.walk(`${srcPath}/${name}`, `${srcUri}/${name}`, childRel,
        plan, p, onProgress, depth + 1);
    }
  }

  // 把清单切成复制批次：大文件按段切（每段 4~16MB），小文件攒批。
  private static planBatches(plan: InstallPlan, dir: string): CopyBatch[] {
    const out: CopyBatch[] = [];
    // 目标：整盘大约 128 次进度刷新，所以单段 = 总大小/128，夹在 4~16MB。
    const seg: number = Math.max(4 * 1024 * 1024,
      Math.min(BATCH_BYTES, Math.floor(plan.totalBytes / 128)));
    let cur = new CopyBatch();
    for (let i = 0; i < plan.rels.length; i++) {
      const size: number = plan.sizes[i];
      if (size <= 0) {
        continue;
      }
      const dst: string = `${dir}/${plan.rels[i]}`;
      for (let off = 0; off < size; off += seg) {
        const len: number = Math.min(seg, size - off);
        if (cur.bytes > 0 && cur.bytes + len > BATCH_BYTES) {
          out.push(cur);
          cur = new CopyBatch();
        }
        if (cur.label === '') {
          cur.label = plan.rels[i];
        }
        cur.uris.push(plan.uris[i]);
        cur.srcs.push(plan.srcs[i]);
        cur.dsts.push(dst);
        cur.offsets.push(off);
        cur.lengths.push(len);
        cur.bytes += len;
        if (cur.bytes >= BATCH_BYTES || cur.lengths.length >= BATCH_ITEMS) {
          out.push(cur);
          cur = new CopyBatch();
        }
      }
    }
    if (cur.lengths.length > 0) {
      out.push(cur);
    }
    return out;
  }

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

  // 读标题名 / TitleID / 封面（先按 GOD 包，再按 ISO/ZAR/XEX 目录）。
  private static readTitleMeta(target: string): TitleMeta {
    const out = new TitleMeta();
    try {
      const god = testNapi.meta.metaInfoFromGodPath(target);
      if (god !== null) {
        out.name = god.name ?? '';
        out.titleId = god.titleId ?? '';
        out.iconBytes = god.icon;
      }
    } catch (e) {
      // 非 GOD 包，继续
    }
    if (out.name === '' || out.iconBytes === undefined) {
      try {
        const lower: string = target.toLowerCase();
        const format: number = lower.endsWith('.iso') ? 0
          : (lower.endsWith('.zar') ? 2 : 1);
        const info = testNapi.meta.metaFromPath(target, format);
        if (info !== null) {
          if (out.name === '') {
            out.name = info.name ?? '';
          }
          if (out.titleId === '') {
            out.titleId = info.titleId ?? '';
          }
          if (out.iconBytes === undefined) {
            out.iconBytes = info.icon;
          }
        }
      } catch (e) {
        // 忽略：没有元数据就用显示名兜底
      }
    }
    return out;
  }

  private static writeBytes(path: string, bytes: ArrayBuffer): boolean {
    try {
      const fd = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fd.fd, bytes);
      } finally {
        fs.closeSync(fd);
      }
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'write icon failed: %{public}s',
        JSON.stringify(e));
      return false;
    }
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
}
