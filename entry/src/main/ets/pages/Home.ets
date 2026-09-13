import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window, display, SymbolGlyphModifier } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import testNapi from 'libentry.so';
import { GameLibrary, GameMeta } from '../common/GameLibrary';
import { GameInstall, InstallControl, InstallProgress } from '../common/GameInstall';
import { SettingsStore } from '../common/SettingsStore';
import { AdvancedPage } from './AdvancedPage';
import { ControlsPage } from './ControlsPage';
import { DirectoryPage } from './DirectoryPage';
import { AboutPage } from './AboutPage';
import { LogExport } from '../common/LogExport';
import { Orientation } from '../common/Orientation';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 游戏卡片：封面 + 名称，长按弹系统上下文菜单（背景模糊、卡片预览浮起、菜单贴下方）。
 * 做成独立 @Component，回调不会因 @Builder 闭包捕获而串到别的行。
 */
@Component
struct GameCard {
  item: GameMeta = new GameMeta();
  onStart: (item: GameMeta) => void = (item: GameMeta) => {
  };
  onDelete: (item: GameMeta) => void = (item: GameMeta) => {
  };

  private subtitle(): string {
    const parts: string[] = [];
    if (this.item.titleId !== '') {
      parts.push(this.item.titleId);
    }
    const size: string = GameLibrary.formatSize(this.item.sizeBytes);
    if (size !== '') {
      parts.push(size);
    }
    const date: string = GameLibrary.formatDate(this.item.installedAt);
    if (date !== '') {
      parts.push(date);
    }
    return parts.join(' · ');
  }

  // 长按菜单内容（对齐系统闹钟列表的长按菜单：图标 + 文案，红/蓝配色）。
  @Builder
  menu() {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.text_primary')])
        Text('启动')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .padding({ left: 16, right: 22, top: 13, bottom: 13 })
      .onClick(() => {
        this.onStart(this.item);
      })

      Divider()
        .color($r('app.color.divider'))
        .margin({ left: 50 })

      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.trash_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.danger')])
        Text('删除')
          .fontSize(15)
          .fontColor($r('app.color.danger'))
      }
      .width('100%')
      .padding({ left: 16, right: 22, top: 13, bottom: 13 })
      .onClick(() => {
        this.onDelete(this.item);
      })
    }
    .width(190)
  }

  build() {
    Row({ space: 12 }) {
      // 封面（读不到就留一个占位块）
      Stack() {
        Column()
          .width(74)
          .height(74)
          .borderRadius(10)
          .backgroundColor($r('app.color.chip_bg'))
        if (this.item.iconPath !== '') {
          Image(`file://${this.item.iconPath}`)
            .width(74)
            .height(74)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(74)
      .height(74)

      Column({ space: 4 }) {
        Text(this.item.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle())
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    // 点击卡片直接启动游戏
    .onClick(() => {
      this.onStart(this.item);
    })
    // 长按：系统上下文菜单（IMAGE 预览 = 该项快照保持清晰浮起，背景自动模糊）
    .bindContextMenu(this.menu(), ResponseType.LongPress, {
      preview: MenuPreviewMode.IMAGE,
      previewBorderRadius: 12,
      previewAnimationOptions: { scale: [0.9, 1.0] },
    })
  }
}

/**
 * 列表行：点一下启动，左滑露出删除按钮（红色圆 + 白色垃圾桶，对齐系统闹钟列表）。
 * List 的子组件只能是 ListItem / ListItemGroup / 自定义组件，所以整行抽成组件，
 * ListItem 必须是它的根节点；这样 swipeAction 的 builder 也不用带参数。
 */
@Component
struct GameRow {
  item: GameMeta = new GameMeta();
  onStart: (item: GameMeta) => void = (item: GameMeta) => {
  };
  onDelete: (item: GameMeta) => void = (item: GameMeta) => {
  };

  @Builder
  deleteAction() {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.trash_fill'))
          .fontSize(22)
          .fontColor([Color.White])
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor($r('app.color.danger'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onDelete(this.item);
      })
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    ListItem() {
      GameCard({
        item: this.item,
        onStart: this.onStart,
        onDelete: this.onDelete,
      })
    }
    .swipeAction({ end: this.deleteAction() })
  }
}

/**
 * 新主页（App 入口，默认竖屏）：
 *   游戏 —— 游戏库列表（多槽位），每项可启动/删除；右上角进入导入页。
 *   设置 —— 一级菜单：高级选项 / 控制 / 导出日志 / 打开模拟器目录 / 关于。
 *
 * 底部用 HDS 的 HdsTabs 悬浮页签 + barFloatingStyle.systemMaterialEffect，
 * 即系统「沉浸光感」材质（@kit.UIDesignKit，API 23 / HarmonyOS 6.1.0 起生效）。
 * 颜色统一用 app.color.* 资源，深色模式自动跟随系统。
 * 原 demo 首页保留为「导入游戏（调试台）」页（pages/Index）。
 */
@Entry
@Component
struct Home {
  @State currentTab: number = 0;
  @State games: GameMeta[] = [];
  @State statusText: string = '';
  // 状态栏高度（vp），沉浸式下标题不能压到状态栏上。
  @State statusBarVp: number = 0;
  // 安装中（避免重复触发选择器）。
  @State busy: boolean = false;
  // 安装进度浮层（复制在后台线程跑，这里只显示进度）。
  @State installing: boolean = false;
  @State installCanceling: boolean = false;
  @State installPercent: number = 0;
  @State installTitle: string = '正在安装';
  @State installDetail: string = '';
  @State installStats: string = '';
  /** XEngine Kit（Maleoon GPU 加速）特性清单（临时诊断显示，同时见「关于」页）。 */
  @State xengineInfo: string = '';
  private installControl: InstallControl = new InstallControl();
  private hdsTabController: HdsTabsController = new HdsTabsController();
  // 官方路由栈：子页（高级选项/控制/目录/关于）以 NavDestination 推入。
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx !== undefined) {
      Orientation.portrait(ctx);
      this.initSafeArea(ctx);
      // 首次运行写默认配置；旧版本配置按 CONFIG_SCHEMA_VERSION 迁移。
      SettingsStore.ensureDefaults(ctx.filesDir);
    }
    this.reloadGames();
    this.probeXEngine();
  }

  // XEngine Kit（Maleoon GPU 加速）能力探测，只查一次（临时诊断：显示在游戏库底部）。
  private probeXEngine(): void {
    if (this.xengineInfo !== '') {
      return;
    }
    try {
      this.xengineInfo = `XEngine: ${testNapi.emulator.probeXEngine()}`;
      hilog.info(DOMAIN, TAG, 'xengine: %{public}s', this.xengineInfo);
    } catch (e) {
      this.xengineInfo = 'XEngine: 探测失败';
    }
  }

  // 从别的页面返回时刷新（例如导入完游戏回来 / 从横屏的游戏页返回）。
  onPageShow(): void {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx !== undefined) {
      Orientation.portrait(ctx);
    }
    this.reloadGames();
  }

  private appContext(): common.Context | undefined {
    try {
      return getContext(this) as common.Context;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getContext failed: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  private filesDir(): string {
    const ctx: common.Context | undefined = this.appContext();
    return ctx === undefined ? '' : ctx.filesDir;
  }

  // 取状态栏避让高度（px→vp），沉浸式下标题不能压到状态栏上。
  private async initSafeArea(ctx: common.Context): Promise<void> {
    try {
      const win = await window.getLastWindow(ctx);
      const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let density: number = 1;
      try {
        density = display.getDefaultDisplaySync().densityPixels;
      } catch (e) {
        density = 1;
      }
      const px: number = avoid.topRect.height;
      this.statusBarVp = density > 0 ? Math.ceil(px / density) : 0;
      hilog.info(DOMAIN, TAG, 'status bar %{public}d px → %{public}d vp',
        Math.round(px), this.statusBarVp);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getWindowAvoidArea failed: %{public}s',
        JSON.stringify(e));
    }
  }

  reloadGames(): void {
    const dir: string = this.filesDir();
    if (dir === '') {
      return;
    }
    this.games = GameLibrary.list(dir);
    hilog.info(DOMAIN, TAG, 'game library: %{public}d item(s)', this.games.length);
  }

  selectTab(index: number): void {
    this.currentTab = index;
    if (index === 0) {
      this.reloadGames();
    }
  }

  subtitleOf(item: GameMeta): string {
    const parts: string[] = [];
    if (item.titleId !== '') {
      parts.push(item.titleId);
    }
    const size: string = GameLibrary.formatSize(item.sizeBytes);
    if (size !== '') {
      parts.push(size);
    }
    const date: string = GameLibrary.formatDate(item.installedAt);
    if (date !== '') {
      parts.push(date);
    }
    return parts.join(' · ');
  }

  // 次原生渲染倍率（列表型设置：'1' = 原生 720p，'2' = 0.5x 半分辨率，…）。
  // 只读 X 这一个设置项，Y 用同一个值（见 startGame 传参）。
  // 直接读配置文件而不是走 SettingsStore.shared().raw()：后者在游戏启动这个
  // 时刻读不到条目（实测 raw 返回空 → 一直回退成 1，"设置不生效"）。
  private renderScaleDen(filesDir: string): number {
    let result: number = 1;
    let rawShown: string = '(未读到)';
    try {
      const cfg: string = SettingsStore.configPath(filesDir);
      if (fileIo.accessSync(cfg)) {
        const text: string = fileIo.readTextSync(cfg);
        const m: RegExpMatchArray | null =
          text.match(/^\s*hx360e_render_scale_den_x\s*=\s*"?(\d+)"?/m);
        if (m !== null && m.length > 1) {
          rawShown = m[1];
          const v: number = Number.parseInt(m[1], 10);
          if (!Number.isNaN(v) && v >= 1 && v <= 4) {
            result = v;
          }
        }
      }
    } catch (e) {
      rawShown = '(读取异常)';
    }
    hilog.info(DOMAIN, TAG, 'render scale den=%{public}d (raw="%{public}s")',
      result, rawShown);
    return result;
  }

  // 启动游戏：传绝对路径给 native，然后进独立游戏页（横屏）。
  startGame(item: GameMeta): void {
    const filesDir: string = this.filesDir();
    if (filesDir === '') {
      this.statusText = '启动失败：无 context';
      return;
    }
    const target: string = GameLibrary.toAbsolute(filesDir, item);
    const storage: string = `${filesDir}/storage`;
    const args: string[] = [
      `--storage_root=${storage}`,
      `--content_root=${storage}/content`,
      `--cache_root=${storage}/cache`,
      '--gpu=vulkan',
      '--apu=ohaudio',
      '--hid=nop',
      // 呈现模式：允许 IMMEDIATE/MAILBOX（非 FIFO）→ presenter 走
      // kGuestOutputThreadImmediately，由 guest 线程直接 present。
      // 实测：强制 FIFO + UI 线程 paint 会让实际上屏率掉到 ~8 次/秒（体感变卡），
      // 已回退；此处必须与 ohos_window.cc 的空 RequestPaintImpl 成对。
      '--vulkan_allow_present_mode_immediate=true',
      '--vulkan_allow_present_mode_mailbox=true',
      '--vulkan_allow_present_mode_fifo_relaxed=true',
      // 次原生渲染倍率：host 尺寸 = guest / 该值。由设置页的
      // GPU|hx360e_render_scale_den_x 控制（1=原生720p，2=半分辨率360p）。
      // 命令行优先级高于 --config，所以这里读设置再同时传给 X/Y，否则设置页改不动。
      `--hx360e_render_scale_den_x=${this.renderScaleDen(filesDir)}`,
      `--hx360e_render_scale_den_y=${this.renderScaleDen(filesDir)}`,
      // direct-HR 路径对 den 的适配尚未做对（标题层会缩到左上角 1/4）。
      // 我们靠 EDRAM dump 路径（已加升采样换算）即可，且已稳定 30fps 有余量，
      // 不需要这条更快的路径。
      // 全分辨率（原生）为唯一目标：不做半分辨率。
      '--hx360e_render_scale_den_x=1',
      '--hx360e_render_scale_den_y=1',
      // 先回到已知正确的 dump resolve 路径（隔离直读路径这个变量）
      '--vulkan_direct_host_resolve=false',
      // 注意：log_level=2 会让 xenia 的 SPIR-V dump 爆栈崩溃（见 fork 注释），
      // 所以 pass 分桶仪表用不了；这里只保留我们自己的探针。
      '--guest_scheduler_stats=true',
      // 系统级超分（XEngine 1.5x）改由设置项 Vulkan|hx360e_xeg_spatial_upscale
      // 控制（默认开）。这里不再传参：命令行优先级高于 --config，传了就会盖掉
      // 用户在设置页里的选择。
    ];
    // 高级选项里保存过的设置（稀疏 TOML）：存在才带上，否则用 cvar 默认值。
    try {
      const cfg: string = SettingsStore.configPath(filesDir);
      if (fileIo.accessSync(cfg)) {
        args.push(`--config=${cfg}`);
      }
    } catch (e) {
      // 忽略：没有配置文件就用默认值
    }
    try {
      testNapi.emulator.setupLaunchArgs(args);
      testNapi.emulator.setupGamePath(target);
      testNapi.emulator.boot();
      this.statusText = `启动中… ${item.name}`;
      hilog.info(DOMAIN, TAG, 'boot(%{public}s)', target);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/GamePage' })
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'pushUrl GamePage failed: %{public}s', e.message);
        });
    } catch (e) {
      this.statusText = '启动失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'boot failed: %{public}s', JSON.stringify(e));
    }
  }

  deleteGame(item: GameMeta): void {
    const dir: string = this.filesDir();
    if (dir === '') {
      return;
    }
    try {
      GameLibrary.remove(dir, item.id);
      this.statusText = `已删除 ${item.name}`;
      // 让删掉的那行收起来、后面几行平滑归位：数据变更放在 animateTo 里，
      // List 会自己做增删过渡（官方左滑删除示例也是这个写法）。
      const index: number = this.games.findIndex((g: GameMeta) => g.id === item.id);
      if (index < 0) {
        this.reloadGames();
        return;
      }
      this.getUIContext().animateTo({
        duration: 300,
        curve: Curve.FastOutSlowIn,
      }, () => {
        this.games.splice(index, 1);
      });
    } catch (e) {
      this.statusText = '删除失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'delete failed: %{public}s', JSON.stringify(e));
    }
  }

  // 加号：直接弹系统文件夹选择器并安装，不再跳 demo 页。
  async importGame(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.Context | undefined = this.appContext();
    if (ctx === undefined) {
      this.statusText = '导入失败：无 context';
      return;
    }
    this.busy = true;
    this.installCanceling = false;
    this.installPercent = 0;
    this.installControl = new InstallControl();
    try {
      this.statusText = await GameInstall.installFolder(ctx, ctx.filesDir,
        (p: InstallProgress) => {
          this.onInstallProgress(p);
        },
        this.installControl);
      this.reloadGames();
    } catch (e) {
      this.statusText = '导入失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
      this.installing = false;
      this.installCanceling = false;
    }
  }

  // 安装进度回调（复制在 taskpool 线程上，回调回主线程刷新 @State）。
  private onInstallProgress(p: InstallProgress): void {
    this.installing = p.active;
    this.installTitle = p.title;
    this.installDetail = this.installCanceling ? '正在取消…' : p.detail;
    this.installStats = p.stats;
    this.installPercent = p.percent;
  }

  async doExportLogs(): Promise<void> {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx === undefined) {
      this.statusText = '导出失败：无 context';
      return;
    }
    this.statusText = '正在导出日志…';
    this.statusText = await LogExport.exportLogs(ctx, ctx.filesDir);
  }

  private go(name: string): void {
    try {
      const info: NavPathInfo = { name: name };
      this.pathStack.pushPath(info);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pushPath %{public}s failed: %{public}s', name,
        JSON.stringify(e));
    }
  }

  // NavDestination 路由表：子页自带系统标题栏与返回按钮。
  @Builder
  pageMap(name: string, param: Object) {
    if (name === 'advanced') {
      AdvancedPage()
    } else if (name === 'controls') {
      ControlsPage()
    } else if (name === 'directory') {
      DirectoryPage()
    } else if (name === 'about') {
      AboutPage()
    }
  }

  // 页签图标（normal / selected 两态）。系统符号来自 sys.symbol.*。
  private tabSymbol(index: number): TabBarSymbol {
    const symbol: Resource = index === 0
      ? $r('sys.symbol.gamecontroller_fill')
      : $r('sys.symbol.gearshape_fill');
    const normal = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.tab_inactive')]);
    const selected = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.accent')]);
    const sym: TabBarSymbol = { normal: normal, selected: selected };
    return sym;
  }

  // ---- @Builder ----

  // 设置项：左侧图标 + 标题/说明 + 右侧箭头（对齐系统设置/商店的菜单样式）。
  @Builder
  settingRow(label: string, hint: string, symbol: Resource, action: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
      Column({ space: 2 }) {
        Text(label).fontSize(16).fontColor($r('app.color.text_primary'))
        if (hint !== '') {
          Text(hint).fontSize(11).fontColor($r('app.color.text_hint'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›').fontSize(20).fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(action)
  }

  // 卡片内分割线：从图标右侧开始（内缩），与系统设置页一致。
  @Builder
  rowDivider() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ left: 50, right: 16 })
  }

  @Builder
  gamesTab() {
    Column({ space: 8 }) {
      Row() {
        Text('游戏库')
          .fontSize(26)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
        Blank()
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(22)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor($r('app.color.card_bg'))
        .onClick(() => this.importGame())
      }
      .width('100%')
      .padding({
        left: 20,
        right: 16,
        top: this.statusBarVp + 10,
        bottom: 10,
      })

      if (this.games.length === 0) {
        Column({ space: 8 }) {
          Text('还没有游戏')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text('点右上角 + 选择游戏文件夹')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.games, (item: GameMeta) => {
            GameRow({
              item: item,
              onStart: (g: GameMeta) => {
                this.startGame(g);
              },
              onDelete: (g: GameMeta) => {
                this.deleteGame(g);
              },
            })
          }, (item: GameMeta) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 104 })
        .scrollBar(BarState.Off)
      }

      Text(this.statusText)
        .fontSize(11)
        .fontColor($r('app.color.accent'))
        .maxLines(2)
        .padding({ left: 16, right: 16, bottom: 104 })
      // XEngine 能力诊断行已隐藏（原来占列表底部数行，影响游戏列表展示）。
      // 需要时看「关于」页的 XEngine 行。
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  settingsTab() {
    Column() {
      Text('设置')
        .fontSize(26)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({
          left: 20,
          right: 16,
          top: this.statusBarVp + 10,
          bottom: 14,
        })

      Scroll() {
        Column({ space: 12 }) {
          Column() {
            this.settingRow('高级选项', '渲染分辨率 / 后端 / 诊断',
              $r('sys.symbol.gearshape'), () => {
                this.go('advanced');
              })
            this.rowDivider()
            this.settingRow('控制', '虚拟手柄与按键对照',
              $r('sys.symbol.gamecontroller'), () => {
                this.go('controls');
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)

          Column() {
            this.settingRow('导出日志', '运行时日志 / 上次崩溃现场',
              $r('sys.symbol.doc_text'), () => {
                this.doExportLogs();
              })
            this.rowDivider()
            this.settingRow('打开模拟器目录', '浏览沙箱内文件',
              $r('sys.symbol.folder'), () => {
                this.go('directory');
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)

          Column() {
            this.settingRow('关于', 'HX360E 版本与设备信息',
              $r('sys.symbol.info_circle'), () => {
                this.go('about');
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)

          Text(this.statusText)
            .fontSize(11)
            .fontColor($r('app.color.accent'))
            .maxLines(2)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 104 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      // Scroll 设了 layoutWeight 后，内容不足一屏会垂直居中，这里强制顶部对齐。
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  // HDS 底部悬浮页签：systemMaterialEffect 即系统「沉浸光感」材质（API 23 / 6.1.0 起）。
  @Builder
  floatingTabs() {
    HdsTabs({ controller: this.hdsTabController }) {
      TabContent() {
        this.gamesTab()
      }
      .tabBar(new BottomTabBarStyle(this.tabSymbol(0), '游戏'))

      TabContent() {
        this.settingsTab()
      }
      .tabBar(new BottomTabBarStyle(this.tabSymbol(1), '设置'))
    }
    .width('100%')
    .height('100%')
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .barFloatingStyle({
      barBottomMargin: 16,
      gradientMask: {
        maskColor: $r('app.color.scroll_mask'),
        maskHeight: 92,
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    })
    .onChange((index: number) => {
      this.selectTab(index);
    })
  }

  // 安装进度浮层：复制跑在后台线程，这里只显示进度 + 取消（遮住整屏防误触）。
  @Builder
  installOverlay() {
    Column() {
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('app.color.accent'))
          Text(this.installTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(`${Math.floor(this.installPercent)}%`)
            .fontSize(14)
            .fontColor($r('app.color.accent'))
        }
        .width('100%')

        Progress({ value: this.installPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .color($r('app.color.accent'))
          .backgroundColor($r('app.color.chip_bg'))
          .style({ strokeWidth: 6 })

        Text(this.installDetail)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(this.installStats)
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button(this.installCanceling ? '正在取消…' : '取消')
            .fontSize(13)
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.installCanceling)
            .onClick(() => {
              this.installCanceling = true;
              this.installDetail = '正在取消…';
              this.installControl.canceled = true;
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(20)
      .shadow({
        radius: 32,
        color: $r('app.color.mask'),
        offsetX: 0,
        offsetY: 8,
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.mask'))
    .onClick(() => {
    })
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          this.floatingTabs()
        }
        .width('100%')
        .height('100%')

        if (this.installing) {
          this.installOverlay()
        }
      }
      .width('100%')
      .height('100%')
      // 不要在这里 expandSafeArea：它会把推入的 NavDestination（高级选项/
      // 控制/目录/关于）的标题栏也一起顶到状态栏下面。首页自己的标题已按
      // 状态栏高度留白（见 floatingTabs 里的 statusBarVp）。
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
