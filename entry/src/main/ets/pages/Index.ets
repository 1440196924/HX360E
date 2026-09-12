import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { GameLibrary, GameMeta } from '../common/GameLibrary';
import { LogExport } from '../common/LogExport';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 本次安装占用的槽位（一个游戏 = games/<id>/）。 */
class InstallSlot {
  id: string = '';
  dir: string = '';
}

/**
 * 导入页（原 demo 首页，保留）：安装游戏（文件/文件夹）、启动内核、查看状态、
 * 导出日志。安装到 games/<id>/ 多槽位，游戏列表见主页 pages/Home。
 * 点「启动」后跳转到独立游戏页 GamePage（只显示游戏 + 虚拟手柄）。
 */
@Entry
@Component
struct Index {
  @State status: string = '初始化中…';
  @State gpuInfo: string = '';
  @State jitInfo: string = 'JIT 探测中…';
  @State installStatus: string = '未安装游戏';
  @State gamePath: string = '';
  @State running: boolean = false;
  @State paused: boolean = false;
  @State busy: boolean = false;
  @State exportStatus: string = '';
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.runJitProbe();
    try {
      hilog.info(DOMAIN, TAG, 'emulator.deviceInfo: %{public}s',
        testNapi.emulator.deviceInfo());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'emulator API missing: %{public}s', JSON.stringify(e));
    }
    this.restoreInstalled();
    this.pollTimer = setInterval(() => this.refresh(), 500);
  }

  // 启动时恢复游戏库里最近安装的那个游戏（多槽位，最新在前）。
  restoreInstalled(): void {
    try {
      const ctx = getContext(this) as common.Context;
      const list: GameMeta[] = GameLibrary.list(ctx.filesDir);
      if (list.length === 0) {
        return;
      }
      const newest: GameMeta = list[0];
      const target: string = GameLibrary.toAbsolute(ctx.filesDir, newest);
      this.gamePath = target;
      this.installStatus = `已安装：${newest.name} → ${target}`;
      hilog.info(DOMAIN, TAG, 'restored game: %{public}s', this.gamePath);
      try {
        hilog.info(DOMAIN, TAG, 'probe: %{public}s',
          testNapi.emulator.probeFile(this.gamePath));
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'probe failed: %{public}s', JSON.stringify(e));
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'restoreInstalled failed: %{public}s', JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  // 退出时释放所有阻塞在提示上的 guest 线程（提示 UI 在 GamePage）。
  cancelAllPrompts(): void {
    try {
      testNapi.prompt.keyboardCancelAll();
      testNapi.prompt.msgboxCancelAll();
      testNapi.prompt.discCancelAll();
    } catch (e) {
      // 忽略
    }
  }

  // ---- guest 提示相关的轮询/提交已移到 GamePage ----

  // Phase 0.1：JIT 可执行内存探测
  runJitProbe(): void {
    try {
      const r = testNapi.jitProbe();
      this.jitInfo = r.firstWorking >= 0 ? `JIT: ${r.firstWorkingName} ✅` : 'JIT: 不可用 ❌';
    } catch (e) {
      this.jitInfo = 'JIT 探测异常';
    }
  }

  refresh(): void {
    try {
      const s = testNapi.vulkanStatus();
      this.status = s.ready
        ? `呈现中 · ${s.frames} 帧 · ${s.fps.toFixed(1)} FPS`
        : '等待 surface…';
      if (s.deviceInfo.length > 0) {
        this.gpuInfo = s.deviceInfo;
      }
      this.running = testNapi.emulator.isRunning();
      this.paused = testNapi.emulator.isPaused();
    } catch (e) {
      // 忽略轮询异常
    }
  }

  // 选游戏（文件或文件夹）→ 复制到沙箱单槽位 games/current/。
  // folder=true 用「文件夹」模式（GOD / 多 data 文件包必须用它）。
  async pickAndInstall(folder: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.installStatus = folder ? '请选择游戏文件夹…' : '请选择游戏文件…';
    try {
      const ctx = getContext(this);
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      if (folder) {
        options.selectMode = picker.DocumentSelectMode.FOLDER;
      }
      const uris: string[] = await docPicker.select(options);
      if (uris.length === 0) {
        this.installStatus = '已取消';
        return;
      }
      const uri: string = uris[0];
      const srcPath: string = this.uriToPath(uri);
      hilog.info(DOMAIN, TAG,
        'install: uri=%{public}s path=%{public}s folder=%{public}d',
        uri, srcPath, folder ? 1 : 0);
      this.installStatus = '复制到沙箱中…（大文件请耐心等待）';
      const displayName: string = this.uriBaseName(srcPath);
      const slot: InstallSlot = this.prepareNewGameDir(ctx.filesDir, displayName);
      const dir: string = slot.dir;
      let count: number = 0;
      if (folder) {
        count = await this.copyRecursive(srcPath, uri, dir);
      } else {
        const dot: number = displayName.lastIndexOf('.');
        const ext: string = dot >= 0 ? displayName.substring(dot) : '';
        const bytes: number = await this.copyFileAny(srcPath, uri,
          `${dir}/game${ext}`);
        count = bytes > 0 ? 1 : 0;
      }
      const dest: string = GameLibrary.resolveTarget(dir, 0);
      if (dest === '') {
        this.gamePath = '';
        this.installStatus = '已复制但未找到可启动文件（default.xex / STFS / game*）';
        hilog.error(DOMAIN, TAG, 'install: no launch target in %{public}s', dir);
        GameLibrary.remove(ctx.filesDir, slot.id);
        return;
      }
      // 写元数据：主页的「游戏库」列表据此显示。
      const meta = new GameMeta();
      meta.id = slot.id;
      meta.name = this.displayNameFor(displayName);
      meta.titleId = this.titleIdFor(dest);
      meta.target = GameLibrary.toRelative(dir, dest);
      meta.kind = folder ? 'folder' : 'file';
      meta.fileCount = count;
      meta.sizeBytes = GameLibrary.dirSize(dir);
      meta.installedAt = Date.now();
      GameLibrary.saveMeta(ctx.filesDir, meta);
      this.gamePath = dest;
      this.installStatus = `已安装（${count} 个文件）：${meta.name}`;
      hilog.info(DOMAIN, TAG, 'installed slot=%{public}s target=%{public}s files=%{public}d',
        slot.id, dest, count);
      hilog.info(DOMAIN, TAG, 'install: target head=%{public}s',
        this.readHeadHex(dest, 16));
    } catch (e) {
      this.installStatus = '安装失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'install failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  // 显示名：去掉扩展名。
  displayNameFor(pickedName: string): string {
    const dot: number = pickedName.lastIndexOf('.');
    if (dot > 0) {
      return pickedName.substring(0, dot);
    }
    return pickedName;
  }

  // 尽量读出 Xbox Title ID；读不出返回空串（列表用显示名兜底）。
  titleIdFor(path: string): string {
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

  // 新建一个游戏槽位 games/<id>/。不再清空 games/，多游戏共存。
  prepareNewGameDir(filesDir: string, displayName: string): InstallSlot {
    const gamesDir: string = GameLibrary.gamesDir(filesDir);
    GameLibrary.ensureDir(gamesDir);
    const id: string = GameLibrary.makeId(displayName, Date.now());
    const dir: string = GameLibrary.gameDir(filesDir, id);
    GameLibrary.ensureDir(dir);
    const slot = new InstallSlot();
    slot.id = id;
    slot.dir = dir;
    hilog.info(DOMAIN, TAG, 'prepare: new slot %{public}s', id);
    return slot;
  }

  // picker 的 docs URI → 真实路径。fs 的目录接口（listFileSync/statSync）只接受
  // 路径：直接传 URI 会 13900019(ENOTDIR)/13900002(ENOENT)。
  uriToPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      return uri;
    }
  }

  // 读取文件开头 length 字节的十六进制串（诊断用）。
  readHeadHex(path: string, length: number): string {
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
      return `(read failed: ${JSON.stringify(e)})`;
    }
  }

  // 复制单个文件到沙箱。源优先用 picker URI（单文件实测可用），失败退回真实路径。
  // 本设备上 copyFile 会写出全 0，且不显式传 offset 的 read/write 不可靠，
  // 因此源和目标都显式指定文件 offset。
  async copyFileAny(srcPath: string, srcUri: string,
                    destPath: string): Promise<number> {
    let srcFd: number = -1;
    try {
      srcFd = fs.openSync(srcUri, fs.OpenMode.READ_ONLY).fd;
    } catch (e1) {
      hilog.error(DOMAIN, TAG, 'open src uri failed: %{public}s : %{public}s',
        srcUri, JSON.stringify(e1));
      try {
        srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'open src path failed: %{public}s : %{public}s',
          srcPath, JSON.stringify(e2));
        throw new Error(`open src failed: ${srcPath} ${JSON.stringify(e2)}`);
      }
    }
    try {
      const size: number = fs.statSync(srcFd).size;
      let dstFd: number = -1;
      try {
        dstFd = fs.openSync(destPath,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'open dst failed: %{public}s : %{public}s',
          destPath, JSON.stringify(e));
        throw new Error(`open dst failed: ${destPath} ${JSON.stringify(e)}`);
      }
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
          hilog.error(DOMAIN, TAG,
            'copy short: %{public}s %{public}d/%{public}d',
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

  // 递归复制目录/文件到沙箱，返回文件数。srcPath 为真实路径，srcUri 为对应 URI
  // （文件打开优先 URI）。destPath 是**本条目**在沙箱中的目标路径（目录或文件）。
  async copyRecursive(srcPath: string, srcUri: string,
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
      const bytes: number = await this.copyFileAny(srcPath, srcUri, destPath);
      hilog.info(DOMAIN, TAG, 'install: file %{public}s (%{public}d bytes)',
        this.uriBaseName(srcPath), bytes);
      return 1;
    }
    GameLibrary.ensureDir(destPath);
    hilog.info(DOMAIN, TAG, 'install: dir %{public}s (%{public}d entries)',
      this.uriBaseName(srcPath), names.length);    let count: number = 0;
    for (const name of names) {
      count += await this.copyRecursive(`${srcPath}/${name}`,
        `${srcUri}/${name}`, `${destPath}/${name}`);
    }
    return count;
  }

  uriBaseName(uri: string): string {
    let name: string = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // URI 未编码时保持原样
    }
    return name;
  }

  // 启动内核并进入独立游戏页。
  bootGame(): void {
    if (this.gamePath === '') {
      this.installStatus = '请先安装游戏';
      return;
    }
    try {
      const ctx = getContext(this);
      const storage: string = `${ctx.filesDir}/storage`;
      const args: string[] = [
        `--storage_root=${storage}`,
        `--content_root=${storage}/content`,
        `--cache_root=${storage}/cache`,
        '--gpu=vulkan',
        '--apu=ohaudio',
        '--hid=nop',
      ];
      testNapi.emulator.setupLaunchArgs(args);
      testNapi.emulator.setupGamePath(this.gamePath);
      testNapi.emulator.boot();
      this.installStatus = '启动中…（见游戏页）';
      hilog.info(DOMAIN, TAG, 'boot(%{public}s)', this.gamePath);
      // 切到独立游戏页：只显示画面 + 虚拟手柄。
      this.getUIContext().getRouter().pushUrl({ url: 'pages/GamePage' })
        .then(() => {
          hilog.info(DOMAIN, TAG, 'entered GamePage');
        })
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'pushUrl failed: %{public}s', e.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'boot failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---- 日志导出（共享实现见 common/LogExport.ets）----

  async exportLogs(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.exportStatus = '正在导出日志…';
    try {
      const ctx = getContext(this) as common.Context;
      this.exportStatus = await LogExport.exportLogs(ctx, ctx.filesDir);
    } catch (e) {
      this.exportStatus = '导出失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'exportLogs failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  @Builder
  actionButton(label: string, action: () => void) {
    Button(label)
      .fontSize(13)
      .height(34)
      .layoutWeight(1)
      .enabled(!this.busy)
      .onClick(action)
  }

  build() {
    Column({ space: 12 }) {
      Text('HX360E').fontSize(20).fontColor($r('app.color.text_primary'))
      Text(this.status).fontSize(12).fontColor($r('app.color.accent'))
      Text(this.jitInfo).fontSize(11).fontColor($r('app.color.accent'))
      Text(this.gpuInfo).fontSize(9).fontColor($r('app.color.text_secondary'))
      Text(this.installStatus).fontSize(11).fontColor($r('app.color.text_secondary'))
      Text(this.running ? (this.paused ? '内核：已暂停' : '内核：运行中') : '内核：未运行')
        .fontSize(11)
        .fontColor($r('app.color.accent'))
      Text(this.exportStatus).fontSize(11).fontColor($r('app.color.accent'))

      Row({ space: 8 }) {
        this.actionButton('安装文件', () => {
          this.pickAndInstall(false);
        })
        this.actionButton('安装文件夹', () => {
          this.pickAndInstall(true);
        })
        this.actionButton('启动', () => {
          this.bootGame();
        })
      }
      .width('100%')

      Row({ space: 8 }) {
        this.actionButton(this.paused ? '继续' : '暂停', () => {
          if (this.paused) {
            testNapi.emulator.resume();
          } else {
            testNapi.emulator.pause();
          }
        })
        this.actionButton('退出', () => {
          this.cancelAllPrompts();
          testNapi.emulator.quit();
        })
      }
      .width('100%')

      Row({ space: 8 }) {
        this.actionButton('导出日志到 Download', () => {
          this.exportLogs();
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
