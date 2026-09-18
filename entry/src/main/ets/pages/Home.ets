import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  window,
  display,
  LengthMetrics,
  SymbolGlyphModifier,
  UIContext,
  ComponentContent,
} from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsAttribute,
  HdsNavDestination,
  HdsNavDestinationAttribute,
  HdsNavDestinationTitleMode,
  TitleBarStyleOptions,
  HdsNavigationMenuItemOptions,
  HdsNavigationIconOptions,
  hdsMaterial,
} from '@kit.UIDesignKit';
import { TitleBarSupport, TITLE_BAR_CONTENT_HEIGHT } from '../common/TitleBarSupport';
import testNapi from 'libentry.so';
import { GameLibrary, GameMeta } from '../common/GameLibrary';
import { GameInstall, InstallControl, InstallProgress } from '../common/GameInstall';
import { SettingsStore } from '../common/SettingsStore';
import { AdvancedPage } from './AdvancedPage';
import { ControlsPage } from './ControlsPage';
import { AboutPage } from './AboutPage';
import { LogExport } from '../common/LogExport';
import { AppLog } from '../common/AppLog';
import { Orientation } from '../common/Orientation';

const DOMAIN = 0x0000;
const TAG = 'HX360E';
/** 标题栏「+」图标的组件 id：作为导入菜单的锚点。 */
const IMPORT_BTN_ID: string = 'hx360e_import_btn';

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
              .fontColor([$r('app.color.text_on_accent')])
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
/** 导入方式菜单的参数（ComponentContent 走单参数最省事）。 */
class ImportMenuParams {
  apiLevel: number = 0;
  onFolder: () => void = () => {
  };
  onArchive: () => void = () => {
  };
}

/**
 * 导入方式弹出菜单的内容。
 *
 * 必须是**全局** @Builder：openMenu 用的 wrapBuilder 只接受全局 @Builder 函数，
 * 传 struct 成员方法会报「wrapBuilder's parameter should be '@Builder' function」。
 */
@Builder
function ImportMenu(params: ImportMenuParams) {
  Column() {
    ImportMenuRow('从文件夹安装',
      params.apiLevel >= 26
        ? 'GOD / 多 data 文件包'
        : `本机 API ${params.apiLevel} 不支持选文件夹`,
      true, params.onFolder)

    Divider().color($r('app.color.divider')).margin({ left: 12, right: 12 })

    ImportMenuRow('从压缩包安装（zip）',
      '分卷包(.z01/.001 等)请把所有卷一起选中', true, params.onArchive)
  }
  .width(232)
  .padding({ top: 4, bottom: 4 })
  .backgroundColor($r('app.color.card_bg'))
  .borderRadius(12)
}

@Builder
function ImportMenuRow(label: string, hint: string, enabled: boolean,
                       action: () => void) {
  Column({ space: 2 }) {
    Text(label)
      .fontSize(15)
      .fontColor(enabled ? $r('app.color.text_primary')
        : $r('app.color.text_hint'))
    Text(hint).fontSize(11).fontColor($r('app.color.text_hint'))
  }
  .alignItems(HorizontalAlign.Start)
  .width('100%')
  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  .opacity(enabled ? 1 : 0.6)
  .onClick(action)
}

@Entry
@Component
struct Home {
  @State currentTab: number = 0;
  @State games: GameMeta[] = [];
  @State statusText: string = '';
  // 状态栏高度（vp），沉浸式下标题不能压到状态栏上。
  @State statusBarVp: number = 0;
  /** 底部避让高度（小横条/导航栏），给悬浮页签留位。 */
  @State bottomInsetVp: number = 0;
  /**
   * 沉浸光感材质档位：默认最精美，设备不支持 IMMERSIVE 时降级到 SMOOTH
   * （官方建议的降级路径，见 pickMaterialLevel）。
   */
  @State materialLevel: hdsMaterial.MaterialLevel =
    hdsMaterial.MaterialLevel.EXQUISITE;
  // 安装中（避免重复触发选择器）。
  @State busy: boolean = false;
  // 安装进度浮层（复制在后台线程跑，这里只显示进度）。
  @State installing: boolean = false;
  @State installCanceling: boolean = false;
  @State installPercent: number = 0;
  @State installTitle: string = '正在安装';
  @State installDetail: string = '';
  @State installStats: string = '';
  // 压缩包加密时的密码浮层。
  @State passwordVisible: boolean = false;
  /** 系统 API 等级；「选文件夹」需要 26+，低版本只能走压缩包。 */
  private apiLevel: number = 0;
  /** 当前打开的导入菜单（closeMenu 需要同一个 ComponentContent 句柄）。 */
  private importMenuContent: ComponentContent<ImportMenuParams> | undefined =
    undefined;
  @State passwordPrompt: string = '';
  @State passwordInput: string = '';
  private passwordResolver: ((v: string) => void) | undefined = undefined;
  /** XEngine Kit（Maleoon GPU 加速）特性清单（临时诊断显示，同时见「关于」页）。 */
  @State xengineInfo: string = '';
  private installControl: InstallControl = new InstallControl();
  private hdsTabController: HdsTabsController = new HdsTabsController();
  // 官方路由栈：子页（高级选项/控制/目录/关于）以 NavDestination 推入。
  private pathStack: NavPathStack = new NavPathStack();
  /** 外壳是否已作为栈底页推入（只推一次）。 */
  private shellPushed: boolean = false;
  /** 游戏列表的 Scroller：给标题栏做滚动联动（bindToScrollable）。 */
  private homeScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx !== undefined) {
      Orientation.portrait(getContext(this) as common.UIAbilityContext);
      this.initSafeArea(ctx);
      // 首次运行写默认配置；旧版本配置按 CONFIG_SCHEMA_VERSION 迁移。
      SettingsStore.ensureDefaults(ctx.filesDir);
    }
    try {
      this.apiLevel = deviceInfo.sdkApiVersion;
    } catch (e) {
      this.apiLevel = 0;
    }
    this.reloadGames();
    this.probeXEngine();
    this.pickMaterialLevel();
    // 外壳（HDS 标题栏 + 底部悬浮页签）作为栈底 NavDestination 推入，
    // 这样标题栏才能吃到系统「沉浸光感」材质（与官方范式一致）。
    if (!this.shellPushed) {
      this.shellPushed = true;
      this.pathStack.pushPath({ name: 'shell' }, false);
    }
  }

  /**
   * 标题栏总占位高度（状态栏避让区 + 标题栏内容 56vp）。
   *
   * 内容区是 ignoreLayoutSafeArea 铺满全屏的，标题栏浮在内容之上，
   * 所以每个页签的内容都要自己让出这一段。
   */
  private titleBarHeightVp(): number {
    return this.statusBarVp + TITLE_BAR_CONTENT_HEIGHT;
  }

  /**
   * 标题栏右侧的图标按钮（HDS 系统级 titleBar content.menu）。
   *
   * ArkTS 严格模式不允许无类型对象字面量，所以这里显式声明每一项的类型；
   * 只在「游戏库」页签显示「导入」，设置页签返回空数组。
   */
  private titleBarMenu(): Array<HdsNavigationMenuItemOptions> {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    if (this.currentTab !== 0) {
      return items;
    }
    // 图标颜色跟主题走：浅色模式用深色 text_primary，深色模式自动变浅。
    const glyph: SymbolGlyphModifier =
      new SymbolGlyphModifier($r('sys.symbol.plus'))
        .fontColor([$r('app.color.text_primary')]);
    const icon: HdsNavigationIconOptions = {
      icon: glyph,
      isEnabled: true,
      action: () => {
        // 打开锚定在「+」下方的弹出菜单（系统推荐接口：
        // UIContext.PromptAction.openMenu + HDS 图标项的 componentId 作锚点）。
        // 背景：系统的「选择文件夹」要 API 26+，API 24 上选择器会秒退返回空，
        // 所以菜单里同时给出「压缩包」这条路。
        this.openImportMenu();
      },
      // 作为 openMenu 的锚点：菜单会弹在这个图标下方。
      componentId: IMPORT_BTN_ID,
    };
    const item: HdsNavigationMenuItemOptions = { content: icon };
    items.push(item);
    return items;
  }

  // 标题栏样式走公共模块（材质档位 + 渐次磨砂 + 不设背景色）。
  private titleBarStyle(): TitleBarStyleOptions {
    return TitleBarSupport.style($r('app.color.text_primary'));
  }

  /**
   * 选沉浸光感材质档位。
   *
   * hdsMaterial 的 IMMERSIVE 材质需要设备算力支持，先查系统支持的材质类型；
   * 不支持就退回 SMOOTH（更省性能的薄档），避免在低端机上强制开精致档导致掉帧。
   */
  private pickMaterialLevel(): void {
    this.materialLevel = TitleBarSupport.materialLevel();
    hilog.info(DOMAIN, TAG, 'material level: %{public}d', this.materialLevel);
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
    // 从游戏页（横屏）返回时切回竖屏——必须走主窗口，否则上下文菜单等子窗
    // 会成为"最后窗口"导致朝向设不上。
    Orientation.portrait(getContext(this) as common.UIAbilityContext);
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
      // 底部：优先取「小横条」高度，取不到再退回系统导航栏高度。
      let bottomPx: number = 0;
      try {
        const indicator = win.getWindowAvoidArea(
          window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        bottomPx = indicator.bottomRect.height;
      } catch (e) {
        bottomPx = 0;
      }
      if (bottomPx <= 0) {
        bottomPx = avoid.bottomRect.height;
      }
      this.bottomInsetVp = density > 0 ? Math.ceil(bottomPx / density) : 0;
      hilog.info(DOMAIN, TAG, 'status bar %{public}d px 鈫?%{public}d vp',
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
      // 全分辨率（原生）为唯一目标：不做半分辨率。
      '--hx360e_render_scale_den_x=1',
      '--hx360e_render_scale_den_y=1',
      // 直读 resolve（默认值 true）：eliminate 每帧 19 次 EDRAM dump。
      '--vulkan_direct_host_resolve=true',
      // 把每个 pass 的 renderArea 缩到实际画到的范围（已验证收缩生效、画面无裁剪，
      // 实测 LIMBO 66.5ms -> 50.2ms）。
      '--render_area_dirty_extent=true',
      // 安全带：之前实验值被 app 写进 xenia.config.toml，命令行优先级最高，这里钉住。
      '--vulkan_in_pass_resolve=false',
      '--log_gpu_frame_time_breakdown=false',
      '--log_resolve_details=false',
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
      AppLog.i('game', `boot target=${target} name=${item.name}`);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/GamePage' })
        .catch((e: Error) => {
          AppLog.exception('game', 'pushUrl GamePage failed', e);
        });
    } catch (e) {
      this.statusText = '启动失败（见 hilog）';
      AppLog.exception('game', 'boot failed', e);
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
      AppLog.i('install', `folder install done: ${this.statusText}`);
      this.toast(this.statusText);
      this.reloadGames();
    } catch (e) {
      this.statusText = '导入失败（见 hilog）';
      AppLog.exception('install', 'folder install threw', e);
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

  // ---- 压缩包安装 ----

  // 从压缩包安装：解压进沙箱，加密包会弹密码框（最多重试 3 次）。
  async importArchive(): Promise<void> {
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
      this.statusText = await GameInstall.installArchive(ctx, ctx.filesDir,
        (p: InstallProgress) => {
          this.onInstallProgress(p);
        },
        this.installControl,
        (retry: boolean) => this.askArchivePassword(retry));
      AppLog.i('install', `archive install done: ${this.statusText}`);
      this.toast(this.statusText);
      this.reloadGames();
    } catch (e) {
      this.statusText = '导入失败（见 hilog）';
      AppLog.exception('install', 'archive install threw', e);
    } finally {
      this.busy = false;
      this.installing = false;
      this.installCanceling = false;
    }
  }

  // 弹密码框并等用户输入（同一次安装里可能被调多次：口令错要重试）。
  private askArchivePassword(retry: boolean): Promise<string> {
    this.passwordPrompt = retry ? '密码错误，请重新输入' : '该压缩包已加密，请输入密码';
    this.passwordInput = '';
    this.passwordVisible = true;
    return new Promise<string>((resolve: (v: string) => void) => {
      this.passwordResolver = resolve;
    });
  }

  private finishPasswordInput(value: string): void {
    this.passwordVisible = false;
    const resolver: ((v: string) => void) | undefined = this.passwordResolver;
    this.passwordResolver = undefined;
    if (resolver !== undefined) {
      resolver(value);
    }
  }

  /**
   * 打开「导入方式」弹出菜单，锚定在标题栏「+」下方。
   *
   * 用官方接口 UIContext.PromptAction.openMenu(content, target)：content 是
   * ComponentContent（包一份 @Builder），target 用 HDS 图标项的 componentId
   * 作锚点，菜单默认贴在锚点下方，不需要自己算坐标。
   *
   * 注意：wrapBuilder 只接受**全局** @Builder 函数，所以菜单内容写在文件顶部
   * 的 ImportMenu（不是本 struct 的成员方法）。
   */
  private openImportMenu(): void {
    try {
      const ui: UIContext = this.getUIContext();
      const params = new ImportMenuParams();
      params.apiLevel = this.apiLevel;
      params.onFolder = () => {
        this.closeImportMenu();
        if (this.folderModeSupported()) {
          this.importGame();
        } else {
          this.statusText = '本机不支持选择文件夹，请改用「从压缩包安装」';
        }
      };
      params.onArchive = () => {
        this.closeImportMenu();
        this.importArchive();
      };
      const content: ComponentContent<ImportMenuParams> =
        new ComponentContent(ui, wrapBuilder(ImportMenu), params);
      this.importMenuContent = content;
      ui.getPromptAction().openMenu(content, { id: IMPORT_BTN_ID })
        .catch((err: Error) => {
          AppLog.e('ui', `openMenu failed: ${err.message}`);
        });
      AppLog.i('ui', 'import menu opened');
    } catch (e) {
      AppLog.exception('ui', 'openImportMenu failed', e);
    }
  }

  private closeImportMenu(): void {
    const content: ComponentContent<ImportMenuParams> | undefined =
      this.importMenuContent;
    this.importMenuContent = undefined;
    if (content === undefined) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().closeMenu(content);
    } catch (e) {
      AppLog.exception('ui', 'closeImportMenu failed', e);
    }
  }

  /** 「选择文件夹」需要系统 API 26+（实测 API 24 上选择器秒退返回空）。 */
  private folderModeSupported(): boolean {
    return this.apiLevel >= 26;
  }

  // 密码浮层：解压暂停在等密码，取消等同于放弃安装。
  @Builder
  passwordOverlay() {
    Column({ space: 12 }) {
      Text('压缩包密码')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.passwordPrompt)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      TextInput({ text: this.passwordInput, placeholder: '请输入密码' })
        .type(InputType.Password)
        .height(42)
        .onChange((v: string) => {
          this.passwordInput = v;
        })
        .onSubmit(() => {
          this.finishPasswordInput(this.passwordInput);
        })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.finishPasswordInput('');
          })
        Button('确定')
          .fontSize(14)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          // 彩底上的文字必须用 text_on_accent：用 text_primary 在浅色模式
          // 会变成深灰字压深蓝底，几乎看不清。
          .fontColor($r('app.color.text_on_accent'))
          .onClick(() => {
            this.finishPasswordInput(this.passwordInput);
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

  async doExportLogs(): Promise<void> {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx === undefined) {
      this.statusText = '导出失败：无 context';
      return;
    }
    this.statusText = '正在导出日志…';
    this.statusText = await LogExport.exportLogs(ctx, ctx.filesDir);
    AppLog.i('log', `export logs: ${this.statusText}`);
  }

  /** 首页按返回 = 退到后台（不退出进程，也不 pop 出栈底的空白根内容）。 */
  private moveToBackground(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.moveAbilityToBackground().catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'moveAbilityToBackground failed: %{public}s',
          err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'moveToBackground failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /**
   * 把结果用系统 toast 提示一下。
   *
   * 底部那条常驻提示控件已经去掉（用户要求），所以导入/安装的成功或失败必须
   * 另找出口——否则失败时用户看到的就是"什么都没发生"。
   */
  private toast(msg: string): void {
    if (msg === '') {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: msg,
        duration: 3000,
      });
    } catch (e) {
      AppLog.exception('ui', 'showToast failed', e);
    }
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
    if (name === 'shell') {
      this.mainShell()
    } else if (name === 'advanced') {
      AdvancedPage()
    } else if (name === 'controls') {
      ControlsPage()
    } else if (name === 'about') {
      AboutPage()
    }
  }

  /**
   * 栈底外壳：HDS 标题栏 + 底部悬浮页签。
   *
   * 走官方范式——标题栏由 HdsNavDestination 自带（avoidLayoutSafeArea 自己避让
   * 状态栏），用 systemMaterialEffect 拿到系统「沉浸光感」材质；内容区
   * ignoreLayoutSafeArea 铺满全屏，滚动联动靠 bindToScrollable。
   */
  @Builder
  mainShell() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          this.floatingTabs()
        }
        .width('100%')
        .height('100%')

        if (this.installing) {
          this.installOverlay()
        }
        if (this.passwordVisible) {
          this.passwordOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      padding: {
        start: LengthMetrics.vp(16),
        end: LengthMetrics.vp(16),
      },
      avoidLayoutSafeArea: true,
      style: this.titleBarStyle(),
      content: {
        title: { mainTitle: this.currentTab === 0 ? '游戏库' : '设置' },
        // 「导入」做成标题栏的系统级图标按钮（只在游戏库页签显示）。
        menu: {
          value: this.titleBarMenu(),
        },
      },
    })
    .hideBackButton(true)
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.homeScroller])
    // 栈底页面：消费返回键，否则会 pop 掉外壳、露出 Navigation 的空根内容
    // （表现就是"按返回进了一个空白页"）。这里改为退到后台，符合首页的预期。
    .onBackPressed((): boolean => {
      this.moveToBackground();
      return true;
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
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
        List({ space: 8, scroller: this.homeScroller }) {
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
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        // 初始让开悬浮的 HDS 标题栏；上滑时列表从标题栏下方穿过，被沉浸材质糊掉。
        .contentStartOffset(this.titleBarHeightVp())
        // 末尾给悬浮页签 + 小横条留出余量（用 offset 而不是 padding，
        // 这样内容能滚到页签下面被材质糊住，而不是被硬生生截断）。
        .contentEndOffset(this.bottomInsetVp + 96)
        // 上下划到尽头时的回弹（内容不足一屏时也能拖出弹性）。
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  settingsTab() {
    Column() {
      Scroll() {        Column({ space: 12 }) {
          Column() {
            this.settingRow('高级选项', '渲染分辨率 / 后端 / 诊断',
              $r('sys.symbol.gearshape'), () => {
                this.go('advanced');
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
      // 让出浮在上面的 HDS 标题栏高度。
      .padding({ top: this.titleBarHeightVp() })
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
      // 不要 gradientMask：它会在列表底部画一条半透明色带，看着像有东西挡住列表。
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: this.materialLevel,
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
      Column()
        .width('100%')
        .height('100%')
    }
    // 外壳自带标题栏（在 mainShell 里），根容器不显示标题栏
    .hideTitleBar(true)
    .hideBackButton(true)
    // 内容铺满全屏，各页自己避让状态栏
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .mode(NavigationMode.Stack)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
