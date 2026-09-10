import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

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
  }

  // 启动时扫描沙箱内已安装的游戏（games/<id>/game*），恢复 gamePath。
  restoreInstalled(): void {
    try {
      const ctx = getContext(this);
      const gamesDir: string = `${ctx.filesDir}/games`;
      if (!fs.accessSync(gamesDir)) {
        return;
      }
      const ids: string[] = fs.listFileSync(gamesDir);
      for (const id of ids) {
        const dir: string = `${gamesDir}/${id}`;
        const files: string[] = fs.listFileSync(dir);
        for (const f of files) {
          if (f.startsWith('game')) {
            this.gamePath = `${dir}/${f}`;
            this.installStatus = `已安装：${this.gamePath}`;
            hilog.info(DOMAIN, TAG, 'restored game: %{public}s', this.gamePath);
            try {
              hilog.info(DOMAIN, TAG, 'probe: %{public}s',
                testNapi.emulator.probeFile(this.gamePath));
            } catch (e) {
              hilog.error(DOMAIN, TAG, 'probe failed: %{public}s', JSON.stringify(e));
            }
            return;
          }
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

  // 取 surfaceId 并交给 native（Phase 0.2 呈现链路）
  tryAttach(): void {
    try {
      const id: string = this.xcompController.getXComponentSurfaceId();
      if (id === '' || id === '0') {
        return;
      }
      if (this.attachTimer >= 0) {
        clearInterval(this.attachTimer);
        this.attachTimer = -1;
      }
      const ok: boolean = testNapi.attachSurface(id);
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

  // 选文件 → 复制到沙箱
  async pickAndInstall(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.installStatus = '请选择游戏文件…';
    try {
      const ctx = getContext(this);
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await docPicker.select(options);
      if (uris.length === 0) {
        this.installStatus = '已取消';
        return;
      }
      const uri: string = uris[0];
      hilog.info(DOMAIN, TAG, 'install: uri=%{public}s', uri);
      this.installStatus = '复制到沙箱中…（大文件请耐心等待）';
      const dest: string = await this.copyToSandbox(ctx.filesDir, uri);
      this.gamePath = dest;
      this.installStatus = `已安装：${dest}`;
      hilog.info(DOMAIN, TAG, 'installed to %{public}s', dest);
    } catch (e) {
      this.installStatus = '安装失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'install failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  async copyToSandbox(filesDir: string, uri: string): Promise<string> {
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const srcStat = fs.statSync(src.fd);
      hilog.info(DOMAIN, TAG, 'install: src size=%{public}d isDir=%{public}d',
        srcStat.size, srcStat.isDirectory() ? 1 : 0);
      if (srcStat.isDirectory()) {
        throw new Error('选择的是文件夹，请选择游戏镜像文件');
      }
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      try {
        name = decodeURIComponent(name);
      } catch (e) {
        // URI 未编码时保持原样
      }
      const dot: number = name.lastIndexOf('.');
      const ext: string = dot >= 0 ? name.substring(dot) : '';
      const base: string = dot >= 0 ? name.substring(0, dot) : name;
      const installId: string = base.replace(/[^A-Za-z0-9._-]/g, '_');
      const dir: string = `${filesDir}/games/${installId}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const dest: string = `${dir}/game${ext}`;
      // 重复安装同一文件时目标已存在，先删除再拷贝。
      if (fs.accessSync(dest)) {
        fs.unlinkSync(dest);
      }

      // 源文件前 32 字节（用独立 fd，避免影响拷贝 fd 的读取位置）。
      try {
        const hf = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const hb = new ArrayBuffer(32);
        const hn = fs.readSync(hf.fd, hb, { length: 32 });
        fs.closeSync(hf);
        const hu = new Uint8Array(hb);
        let hx: string = '';
        for (let i = 0; i < hn; i++) {
          hx += hu[i].toString(16).padStart(2, '0');
        }
        hilog.info(DOMAIN, TAG, 'install: src head=%{public}s', hx);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'install: src head read failed: %{public}s',
          JSON.stringify(e));
      }

      // 分块拷贝：本设备上 fs.copyFile(fd, dest) 会写出全 0 文件，改用
      // 顺序 read/write（fd 位置自动前进，不传 offset 以免歧义）。
      const dst = fs.openSync(dest,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const chunk: number = 4 * 1024 * 1024;
      const buf = new ArrayBuffer(chunk);
      let copied: number = 0;
      while (copied < srcStat.size) {
        const want: number = Math.min(chunk, srcStat.size - copied);
        const rd: number = fs.readSync(src.fd, buf, { length: want });
        if (rd <= 0) {
          break;
        }
        fs.writeSync(dst.fd, buf, { length: rd });
        copied += rd;
      }
      fs.closeSync(dst);
      hilog.info(DOMAIN, TAG, 'install: copied=%{public}d/%{public}d',
        copied, srcStat.size);
      return dest;
    } finally {
      fs.closeSync(src);
    }
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
      }
      .width('100%')
      .padding(6)
      .backgroundColor('#99000000')

      Column({ space: 8 }) {
        Row({ space: 8 }) {
          this.actionButton('选择并安装', () => {
            this.pickAndInstall();
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
            testNapi.emulator.quit();
          })
        }
      }
      .width('100%')
      .padding(10)
      .position({ x: 0, y: '100%' })
      .translate({ y: -110 })
    }
    .width('100%')
    .height('100%')
  }
}
