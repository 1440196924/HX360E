import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window, display, SymbolGlyphModifier } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import testNapi from 'libentry.so';
import { GameLibrary, GameMeta } from '../common/GameLibrary';
import { GameInstall } from '../common/GameInstall';
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
    // 长按：系统上下文菜单（IMAGE 预览 = 该项快照保持清晰浮起，背景自动模糊）
    .bindContextMenu(this.menu(), ResponseType.LongPress, {
      preview: MenuPreviewMode.IMAGE,
      previewBorderRadius: 12,
      previewAnimationOptions: { scale: [0.9, 1.0] },
    })
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
  private hdsTabController: HdsTabsController = new HdsTabsController();
  // 官方路由栈：子页（高级选项/控制/目录/关于）以 NavDestination 推入。
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.appContext();
    if (ctx !== undefined) {
      Orientation.portrait(ctx);
      this.initSafeArea(ctx);
    }
    this.reloadGames();
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
    try {
      GameLibrary.remove(this.filesDir(), item.id);
      this.statusText = `已删除 ${item.name}`;
      this.reloadGames();
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
    try {
      this.statusText = await GameInstall.installFolder(ctx, ctx.filesDir,
        (text: string) => {
          this.statusText = text;
        });
      this.reloadGames();
    } catch (e) {
      this.statusText = '导入失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
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
            ListItem() {
              GameCard({
                item: item,
                onStart: (g: GameMeta) => {
                  this.startGame(g);
                },
                onDelete: (g: GameMeta) => {
                  this.deleteGame(g);
                },
              })
            }
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

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          this.floatingTabs()
        }
        .width('100%')
        .height('100%')

      }
      .width('100%')
      .height('100%')
      // 沉浸：首页内容延伸到状态栏下方（标题里已按 statusBarVp 留白）。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
