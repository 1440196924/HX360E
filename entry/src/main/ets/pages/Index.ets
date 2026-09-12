import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 主页：安装游戏（文件/文件夹）、启动内核、查看状态、导出日志。
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
      text += '===== native_fault.prev.log (上次运行，崩溃现场) =====\n';
      text += this.readLogTail(`${logDir}/native_fault.prev.log`, 256 * 1024);
      text += '\n===== native_fault.log (tail 256KB) =====\n';
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

  build() {
    Column({ space: 12 }) {
      Text('HX360E').fontSize(20).fontColor('#fff')
      Text(this.status).fontSize(12).fontColor('#8cf')
      Text(this.jitInfo).fontSize(11).fontColor('#9f9')
      Text(this.gpuInfo).fontSize(9).fontColor('#aaa')
      Text(this.installStatus).fontSize(11).fontColor('#ffd')
      Text(this.running ? (this.paused ? '内核：已暂停' : '内核：运行中') : '内核：未运行')
        .fontSize(11)
        .fontColor('#f9a')
      Text(this.exportStatus).fontSize(11).fontColor('#9cf')

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
    .backgroundColor('#101018')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
