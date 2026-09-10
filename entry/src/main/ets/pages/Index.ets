import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 手柄控件索引，顺序必须与 native 侧 OhosPadKey（ohos_input_driver.h）一致。
 */
class XPadKey {
  static readonly DpadLeft: number = 0;
  static readonly DpadUp: number = 1;
  static readonly DpadRight: number = 2;
  static readonly DpadDown: number = 3;
  static readonly A: number = 4;
  static readonly B: number = 5;
  static readonly X: number = 6;
  static readonly Y: number = 7;
  static readonly Back: number = 8;
  static readonly Start: number = 9;
  static readonly LShoulder: number = 10;
  static readonly RShoulder: number = 11;
  static readonly LThumbPress: number = 12;
  static readonly RThumbPress: number = 13;
  static readonly LTrigger: number = 14;
  static readonly RTrigger: number = 15;
  static readonly LThumbLeft: number = 16;
  static readonly LThumbUp: number = 17;
  static readonly LThumbRight: number = 18;
  static readonly LThumbDown: number = 19;
  static readonly RThumbLeft: number = 20;
  static readonly RThumbUp: number = 21;
  static readonly RThumbRight: number = 22;
  static readonly RThumbDown: number = 23;
}

/**
 * Phase 1.7 页面：把本地游戏文件复制到沙箱，然后启动内核（headless，无画面）。
 *   · XComponent：保留 Phase 0 的渲染表面（Phase 2 接 Vulkan 时复用）
 *   · 选择文件 → @ohos.file.picker → fs.copyFile 到 filesDir/games/<id>/
 *   · 启动 → emulator.setupLaunchArgs / setupGamePath / boot()
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
  @State padVisible: boolean = true;
  @State padPhysical: boolean = false;
  @State exportStatus: string = '';
  // ---- guest 提示（Phase 5.3）：'' | 'keyboard' | 'msgbox' | 'disc' ----
  @State promptKind: string = '';
  @State promptTitle: string = '';
  @State promptMessage: string = '';
  @State promptInput: string = '';
  @State promptButtons: string[] = [];
  @State promptDiscLabels: string[] = [];
  @State promptDiscPaths: string[] = [];
  private promptId: bigint = BigInt(0);
  private lastSurfaceId: string = '';
  private promptTimer: number = -1;
  private pollTimer: number = -1;
  private attachTimer: number = -1;
  private xcompController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.runJitProbe();
    try {
      hilog.info(DOMAIN, TAG, 'emulator.deviceInfo: %{public}s',
        testNapi.emulator.deviceInfo());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'emulator API missing: %{public}s', JSON.stringify(e));
    }
    this.restoreInstalled();
    this.attachTimer = setInterval(() => this.tryAttach(), 200);
    this.pollTimer = setInterval(() => this.refresh(), 500);
    this.promptTimer = setInterval(() => this.pollPrompt(), 150);
  }

  // 启动时恢复沙箱内的「当前游戏」（单槽位：games/current/game*）。
  restoreInstalled(): void {
    try {
      const ctx = getContext(this);
      const dir: string = `${ctx.filesDir}/games/current`;
      if (!fs.accessSync(dir)) {
        return;
      }
      const target: string = this.resolveLaunchTarget(dir, 0);
      if (target !== '') {
        this.gamePath = target;
        this.installStatus = `已安装：${this.gamePath}`;
        hilog.info(DOMAIN, TAG, 'restored game: %{public}s', this.gamePath);
        try {
          hilog.info(DOMAIN, TAG, 'probe: %{public}s',
            testNapi.emulator.probeFile(this.gamePath));
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'probe failed: %{public}s', JSON.stringify(e));
        }
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
    if (this.attachTimer >= 0) {
      clearInterval(this.attachTimer);
      this.attachTimer = -1;
    }
    if (this.promptTimer >= 0) {
      clearInterval(this.promptTimer);
      this.promptTimer = -1;
    }
    this.cancelAllPrompts();
  }

  // ---- guest 提示（Phase 5.3）----

  // ArkTS 侧 150ms 轮询 guest 的键盘/对话框/换盘请求（DESIGN.md §9.3）。
  pollPrompt(): void {
    if (this.promptKind !== '') {
      return;
    }
    try {
      const kb = testNapi.prompt.keyboardRequest();
      if (kb !== null) {
        this.promptId = kb.id;
        this.promptTitle = kb.title;
        this.promptMessage = kb.description;
        this.promptInput = kb.defaultText;
        this.promptKind = 'keyboard';
        return;
      }
      const mb = testNapi.prompt.msgboxRequest();
      if (mb !== null) {
        this.promptId = mb.id;
        this.promptTitle = mb.title;
        this.promptMessage = mb.text;
        this.promptButtons = mb.buttons;
        this.promptKind = 'msgbox';
        return;
      }
      const d = testNapi.prompt.discRequest();
      if (d !== null) {
        this.promptId = d.id;
        this.promptTitle = '请更换光盘';
        this.promptMessage = d.message;
        this.promptDiscLabels = d.discLabels;
        this.promptDiscPaths = d.discPaths;
        this.promptKind = 'disc';
      }
    } catch (e) {
      // 模块未就绪时忽略
    }
  }

  clearPrompt(): void {
    this.promptKind = '';
    this.promptTitle = '';
    this.promptMessage = '';
    this.promptInput = '';
    this.promptButtons = [];
    this.promptDiscLabels = [];
    this.promptDiscPaths = [];
  }

  submitKeyboard(accepted: boolean): void {
    try {
      testNapi.prompt.keyboardSubmit(this.promptId, accepted, this.promptInput);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'keyboardSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  submitMsgbox(index: number): void {
    try {
      testNapi.prompt.msgboxSubmit(this.promptId, index);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'msgboxSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  submitDisc(accepted: boolean, path: string): void {
    try {
      testNapi.prompt.discSubmit(this.promptId, accepted, path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'discSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  // 退出/卸载时释放所有阻塞在提示上的 guest 线程。
  cancelAllPrompts(): void {
    try {
      testNapi.prompt.keyboardCancelAll();
      testNapi.prompt.msgboxCancelAll();
      testNapi.prompt.discCancelAll();
    } catch (e) {
      // 忽略
    }
    this.clearPrompt();
  }

  // Phase 0.1：JIT 可执行内存探测
  runJitProbe(): void {
    try {
      const r = testNapi.jitProbe();
      this.jitInfo = r.firstWorking >= 0 ? `JIT: ${r.firstWorkingName} ✅` : 'JIT: 不可用 ❌';
    } catch (e) {
      this.jitInfo = 'JIT 探测异常';
    }
  }

  // 取 surfaceId 并交给 native（Phase 0.2 呈现链路）。持续轮询：surface 在窗口
  // 尺寸变化时可能被重建并换新 id，需要重新 attach（否则放大窗口会卡死）。
  tryAttach(): void {
    try {
      const id: string = this.xcompController.getXComponentSurfaceId();
      if (id === '' || id === '0' || id === this.lastSurfaceId) {
        return;
      }
      const ok: boolean = testNapi.attachSurface(id);
      this.lastSurfaceId = id;
      hilog.info(DOMAIN, TAG, 'attachSurface(%{public}s) -> %{public}d', id, ok ? 1 : 0);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'attach failed: %{public}s', JSON.stringify(e));
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
      const dir: string = this.prepareCurrentDir(ctx.filesDir);
      let count: number = 0;
      if (folder) {
        count = await this.copyRecursive(srcPath, uri, dir);
      } else {
        const name: string = this.uriBaseName(srcPath);
        const dot: number = name.lastIndexOf('.');
        const ext: string = dot >= 0 ? name.substring(dot) : '';
        const bytes: number = await this.copyFileAny(srcPath, uri,
          `${dir}/game${ext}`);
        count = bytes > 0 ? 1 : 0;
      }
      const dest: string = this.resolveLaunchTarget(dir, 0);
      if (dest === '') {
        this.gamePath = '';
        this.installStatus = '已复制但未找到可启动文件（default.xex / STFS / game*）';
        hilog.error(DOMAIN, TAG, 'install: no launch target in %{public}s', dir);
        return;
      }
      this.gamePath = dest;
      this.installStatus = `已安装（${count} 个文件）：${dest}`;
      hilog.info(DOMAIN, TAG, 'installed to %{public}s (files=%{public}d)',
        dest, count);
      hilog.info(DOMAIN, TAG, 'install: target head=%{public}s',
        this.readHeadHex(dest, 16));
    } catch (e) {
      this.installStatus = '安装失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'install failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  // 递归删除目录（@ohos.file.fs 的 rmdirSync 只能删空目录）。
  removeDirRecursive(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const entries: string[] = fs.listFileSync(path);
      for (const name of entries) {
        const child: string = `${path}/${name}`;
        if (fs.statSync(child).isDirectory()) {
          this.removeDirRecursive(child);
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

  // 建目录（本设备 mkdirSync(path, true) 对已存在目录会抛 EEXIST 13900015）。
  ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  // 单槽位：清空 games/ 下的旧目录并创建 games/current，返回其沙箱路径。
  prepareCurrentDir(filesDir: string): string {
    const gamesDir: string = `${filesDir}/games`;
    if (fs.accessSync(gamesDir)) {
      const olds: string[] = fs.listFileSync(gamesDir);
      hilog.info(DOMAIN, TAG, 'prepare: cleaning %{public}d old entries',
        olds.length);
      for (const old of olds) {
        this.removeDirRecursive(`${gamesDir}/${old}`);
      }
    }
    const dir: string = `${gamesDir}/current`;
    this.ensureDir(dir);
    return dir;
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
    this.ensureDir(destPath);
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

  // 在已安装目录中找可启动文件。优先级：default.xex > 精确 game >
  // 有同名 .data 目录的文件（多文件 STFS/SVOD 头）> 16~40 位十六进制文件名
  // （STFS 内容 ID）> game* > 递归子目录 > 第一个文件。
  resolveLaunchTarget(dir: string, depth: number): string {
    try {
      if (depth > 8 || !fs.accessSync(dir)) {
        return '';
      }
      const names: string[] = fs.listFileSync(dir);
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
      // 多文件 SVOD/STFS：头部文件旁边有同名 <name>.data 目录。
      for (const n of names) {
        if (fs.statSync(`${dir}/${n}`).isDirectory()) {
          continue;
        }
        const dataDir: string = `${dir}/${n}.data`;
        if (fs.accessSync(dataDir) && fs.statSync(dataDir).isDirectory()) {
          return `${dir}/${n}`;
        }
      }
      const hexName = new RegExp('^[0-9A-Fa-f]{16,40}$');
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
          const t: string = this.resolveLaunchTarget(`${dir}/${n}`, depth + 1);
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
      hilog.error(DOMAIN, TAG, 'resolveLaunchTarget failed: %{public}s',
        JSON.stringify(e));
    }
    return '';
  }

  // 启动内核（headless：null GPU + nop 音频/输入）
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
        '--apu=nop',
        '--hid=nop',
      ];
      testNapi.emulator.setupLaunchArgs(args);
      testNapi.emulator.setupGamePath(this.gamePath);
      testNapi.emulator.boot();
      this.installStatus = '启动中…（headless，看 hilog）';
      hilog.info(DOMAIN, TAG, 'boot(%{public}s)', this.gamePath);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'boot failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---- 手柄输入（Phase 4）----

  // 摇杆方向 / 扳机需要带模拟值，其余按键只需按下与否。
  private keyValue(key: number): number {
    if (key === XPadKey.LTrigger || key === XPadKey.RTrigger) {
      return 255;
    }
    if (key === XPadKey.LThumbLeft || key === XPadKey.LThumbDown ||
      key === XPadKey.RThumbLeft || key === XPadKey.RThumbDown) {
      return -32767;
    }
    if (key === XPadKey.LThumbRight || key === XPadKey.LThumbUp ||
      key === XPadKey.RThumbRight || key === XPadKey.RThumbUp) {
      return 32767;
    }
    return 0;
  }

  padPress(key: number, pressed: boolean): void {
    try {
      testNapi.emulator.keyEvent(key, pressed, this.keyValue(key));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'keyEvent failed: %{public}s', JSON.stringify(e));
    }
  }

  padTogglePhysical(): void {
    try {
      if (this.padPhysical) {
        testNapi.emulator.padStopPhysical();
        this.padPhysical = false;
      } else {
        this.padPhysical = testNapi.emulator.padStartPhysical();
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'gamepad toggle failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---- 日志导出（沙箱内的运行日志 → 用户选择的目录，默认 Download）----

  // 读取文件尾部 maxBytes 字节。按块显式给 offset 读（本设备上不传 offset 的
  // 读语义不可靠），并在首行写出真实文件大小，便于确认拿到的确实是尾部。
  readLogTail(path: string, maxBytes: number): string {
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

  async exportLogs(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.exportStatus = '正在导出日志…';
    try {
      const ctx = getContext(this);
      const logDir: string = `${ctx.filesDir}/logs`;
      let text: string = `HX360E logs ${new Date().toISOString()}\n`;
      text += '===== native_fault.log (tail 256KB) =====\n';
      text += this.readLogTail(`${logDir}/native_fault.log`, 256 * 1024);
      text += '\n===== xe.log (tail 4MB) =====\n';
      text += this.readLogTail(`${logDir}/xe.log`, 4 * 1024 * 1024);

      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`hx360e-log-${Date.now()}.txt`];
      const savePicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        this.exportStatus = '已取消导出';
        return;
      }
      const out = fs.openSync(uris[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(out.fd, text);
      } finally {
        fs.closeSync(out);
      }
      this.exportStatus = `已导出 ${text.length} 字符 → ${uris[0]}`;
      hilog.info(DOMAIN, TAG, 'exportLogs: %{public}s', uris[0]);
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

  // 按住生效的手柄按钮（触摸 Down/Up，而不是点击）。
  @Builder
  padBtn(label: string, key: number) {
    Button(label)
      .fontSize(11)
      .fontColor('#fff')
      .backgroundColor('#6600aaff')
      .borderRadius(6)
      .width(46)
      .height(34)
      .padding(0)
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          this.padPress(key, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.padPress(key, false);
        }
      })
  }

  @Builder
  dpadPad() {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('D↑', XPadKey.DpadUp)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('D←', XPadKey.DpadLeft)
        this.padBtn('D↓', XPadKey.DpadDown)
        this.padBtn('D→', XPadKey.DpadRight)
      }
    }
    .width(132)
  }

  @Builder
  facePad() {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('Y', XPadKey.Y)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('X', XPadKey.X)
        this.padBtn('B', XPadKey.B)
        this.padBtn('A', XPadKey.A)
      }
    }
    .width(132)
  }

  // 摇杆用 4 向按钮近似（满偏），够跑通输入链路；模拟量后续再做。
  @Builder
  stickPad(isLeft: boolean) {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('↑', isLeft ? XPadKey.LThumbUp : XPadKey.RThumbUp)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('←', isLeft ? XPadKey.LThumbLeft : XPadKey.RThumbLeft)
        this.padBtn(isLeft ? 'L3' : 'R3',
          isLeft ? XPadKey.LThumbPress : XPadKey.RThumbPress)
        this.padBtn('→', isLeft ? XPadKey.LThumbRight : XPadKey.RThumbRight)
      }

      Row() {
        this.padBtn('↓', isLeft ? XPadKey.LThumbDown : XPadKey.RThumbDown)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width(132)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      XComponent({
        id: 'hx360e_surface',
        type: XComponentType.SURFACE,
        controller: this.xcompController,
      })
        .width('100%')
        .height('100%')

      Column({ space: 3 }) {
        Text(this.status).fontSize(12).fontColor('#8cf')
        Text(this.jitInfo).fontSize(11).fontColor('#9f9')
        Text(this.gpuInfo).fontSize(9).fontColor('#aaa')
        Text(this.installStatus).fontSize(11).fontColor('#ffd')
        Text(this.running ? (this.paused ? '内核：已暂停' : '内核：运行中') : '内核：未运行')
          .fontSize(11)
          .fontColor('#f9a')
        Text(this.exportStatus).fontSize(11).fontColor('#9cf')
      }
      .width('100%')
      .padding(6)
      .backgroundColor('#99000000')

      Column({ space: 8 }) {
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
        Row({ space: 8 }) {
          this.actionButton(this.padVisible ? '隐藏手柄' : '显示手柄', () => {
            this.padVisible = !this.padVisible;
            if (!this.padVisible) {
              testNapi.emulator.padReleaseAll();
            }
          })
          this.actionButton(this.padPhysical ? '物理手柄:开' : '物理手柄:关', () => {
            this.padTogglePhysical();
          })
        }
        Row({ space: 8 }) {
          this.actionButton('导出日志到 Download', () => {
            this.exportLogs();
          })
        }
      }
      .width('100%')
      .padding(10)
      .position({ x: 0, y: '100%' })
      .translate({ y: -192 })

      if (this.padVisible) {
        Column() {
          Row({ space: 6 }) {
            this.padBtn('LB', XPadKey.LShoulder)
            this.padBtn('LT', XPadKey.LTrigger)
            this.padBtn('BK', XPadKey.Back)
            this.padBtn('ST', XPadKey.Start)
            this.padBtn('RT', XPadKey.RTrigger)
            this.padBtn('RB', XPadKey.RShoulder)
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')

          Row({ space: 8 }) {
            this.stickPad(true)
            this.dpadPad()
            this.facePad()
            this.stickPad(false)
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: 160 })
        // None：覆盖层容器自身不参与命中测试，只有里面的手柄按钮响应，
        // 下层「启动/暂停」按钮仍可点击。
        .hitTestBehavior(HitTestMode.None)
      }

      // guest 提示模态层（Phase 5.3）：键盘 / 对话框 / 换盘。
      if (this.promptKind !== '') {
        Column() {
          Column({ space: 10 }) {
            Text(this.promptTitle)
              .fontSize(16)
              .fontColor('#fff')
              .width('100%')
            Text(this.promptMessage)
              .fontSize(13)
              .fontColor('#ddd')
              .width('100%')

            if (this.promptKind === 'keyboard') {
              TextInput({ placeholder: '请输入…', text: this.promptInput })
                .width('100%')
                .onChange((value: string) => {
                  this.promptInput = value;
                })
              Row({ space: 8 }) {
                Button('确定')
                  .layoutWeight(1)
                  .onClick(() => this.submitKeyboard(true))
                Button('取消')
                  .layoutWeight(1)
                  .onClick(() => this.submitKeyboard(false))
              }
              .width('100%')
            } else if (this.promptKind === 'msgbox') {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                ForEach(this.promptButtons, (label: string, index: number) => {
                  Button(label)
                    .margin(4)
                    .onClick(() => this.submitMsgbox(index))
                })
              }
              .width('100%')
            } else {
              Column({ space: 6 }) {
                ForEach(this.promptDiscLabels, (label: string, index: number) => {
                  Button(label)
                    .width('100%')
                    .onClick(() => this.submitDisc(true, this.promptDiscPaths[index]))
                })
                Button('取消')
                  .width('100%')
                  .onClick(() => this.submitDisc(false, ''))
              }
              .width('100%')
            }
          }
          .width('80%')
          .padding(16)
          .backgroundColor('#ee202020')
          .borderRadius(10)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
