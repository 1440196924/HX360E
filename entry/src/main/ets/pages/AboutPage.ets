import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import testNapi from 'libentry.so';
import { common, bundleManager, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { TitleBarSupport, TITLE_BAR_CONTENT_HEIGHT } from '../common/TitleBarSupport';

const DOMAIN = 0x0000;
const TAG = 'HX360E';
/** 作者 B 站主页。 */
const AUTHOR_URL = 'https://space.bilibili.com/297193944';
const AUTHOR_NAME = '山东大蒜王师傅';
/** 开源仓库地址。 */
const REPO_URL = 'https://github.com/1440196924/HX360E';

/** 关于：应用信息（logo / 名称 / 版本）+ 免责声明。 */
@Component
export struct AboutPage {
  @State version: string = '';
  /** 状态栏避让高度（沉浸式窗口下标题栏浮在内容之上）。 */
  @State statusBarVp: number = 0;
  /** 设备信息。 */
  @State deviceLine: string = '-';
  @State osLine: string = '-';
  @State apiLine: string = '-';
  /** 运行环境：JIT / Vulkan / 启动配置。 */
  @State jitLine: string = '-';
  @State jitProbeLine: string = '-';
  @State vkLine: string = '-';
  @State backendLine: string = '-';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.version = info.versionName;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read version failed: %{public}s', JSON.stringify(e));
      this.version = '(未知)';
    }
    this.collectDeviceInfo();
    this.collectRuntimeInfo();
    this.applyStatusBarInset();
  }

  /** 取状态栏高度（与 AdvancedPage 的做法一致）。 */
  private applyStatusBarInset(): void {
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        const avoid: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const density: number = display.getDefaultDisplaySync().densityPixels;
        this.statusBarVp = density > 0
          ? Math.ceil(avoid.topRect.height / density) : 0;
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyStatusBarInset failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** 设备信息（机型 / 系统 / API 等级）。 */
  private collectDeviceInfo(): void {
    try {
      this.deviceLine = deviceInfo.productModel;
      this.osLine = `${deviceInfo.osFullName} · ${deviceInfo.displayVersion}`;
      this.apiLine = `${deviceInfo.sdkApiVersion}`;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read deviceInfo failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /**
   * 运行环境：JIT 能力 / Vulkan 状态 / 启动配置。
   *
   * JIT 这块尤其要显示清楚：部分设备的系统不允许申请可执行内存，模拟器
   * **任何游戏都跑不起来**（表现为黑屏/崩溃），而用户往往以为是游戏包的问题。
   * 这里把结论和探测明细都摆出来，反馈问题时一眼可辨。
   */
  private collectRuntimeInfo(): void {
    try {
      const r = testNapi.jitProbe();
      const ok: boolean = r.firstWorking >= 0;
      this.jitLine = ok
        ? `可用（${r.firstWorkingName}）`
        : '不可用 —— 本机系统不允许申请可执行内存，游戏无法运行';
      const parts: string[] = [];
      parts.push(`Baseline=${r.BaselineRw.ok ? '✓' : `✗${r.BaselineRw.errno}`}`);
      parts.push(`AnonMprot=${r.AnonRwMprot.ok ? '✓' : `✗${r.AnonRwMprot.errno}`}`);
      parts.push(`FileMap=${r.FileMapRxRw.ok ? '✓' : `✗${r.FileMapRxRw.errno}`}`);
      parts.push(`AnonNone=${r.AnonNoneExecMprot.ok ? '✓' : `✗${r.AnonNoneExecMprot.errno}`}`);
      parts.push(`AnonRwx=${r.AnonExecRwx.ok ? '✓' : `✗${r.AnonExecRwx.errno}`}`);
      this.jitProbeLine = parts.join('  ');
    } catch (e) {
      this.jitLine = '(探测失败)';
      this.jitProbeLine = '-';
    }
    try {
      // 能力信息（GPU 名 / Vulkan 版本 / 驱动）：临时建 instance 枚举，跟游戏无关，
      // 所以没进过游戏也能显示。
      const info: string = testNapi.vulkanInfo();
      const v = testNapi.vulkanStatus();
      this.vkLine = v.ready ? `${info} · 呈现已就绪` : info;
    } catch (e) {
      this.vkLine = '(探测失败)';
    }
    try {
      this.backendLine = testNapi.emulator.deviceInfo();
    } catch (e) {
      this.backendLine = '(不可用)';
    }
  }

  /** 小节标题。 */
  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_hint'))
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 2 })
  }

  /** 用系统浏览器打开链接。 */
  private openUrl(url: string): void {
    try {
      // 与 GamePage.ets:103 同款：getContext 返回的是基类 Context，
      // 起 Ability 需要 UIAbilityContext。
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      };
      ctx.startAbility(want).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'openUrl failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'openUrl failed: %{public}s',
        JSON.stringify(e));
    }
  }

  @Builder
  infoRow(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(value).fontSize(13).fontColor($r('app.color.text_primary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  // 可点的一行：值用强调色，点击跳系统浏览器。
  @Builder
  linkRow(label: string, value: string, url: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(value).fontSize(13).fontColor($r('app.color.accent'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick(() => {
      this.openUrl(url);
    })
  }

  // 支持作者卡片：整块可点，跳系统浏览器打开 B 站主页。
  @Builder
  authorCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Text('支持作者')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Text('用爱发电不易，如果这个模拟器对你有帮助，欢迎到 B 站关注 / 充电支持，你的支持就是我更新最大的动力～')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 4 }) {
        Text(`B 站：${AUTHOR_NAME}`)
          .fontSize(13)
          .fontColor($r('app.color.accent'))
        Blank()
        Text('前往充电 ›')
          .fontSize(13)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.openUrl(AUTHOR_URL);
    })
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          Column({ space: 10 }) {
            Image($r('app.media.app_icon'))
              .width(96)
              .height(96)
              .borderRadius(22)
              .interpolation(ImageInterpolation.High)
            Text('HX360E').fontSize(24).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
            Text('HarmonyOS 上的 Xbox 360 模拟器（Xenia 移植）')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 24, bottom: 18 })

          Divider().color($r('app.color.divider'))

          this.infoRow('包名', 'com.sddswsf.hx360e')
          this.infoRow('版本', this.version)
          this.linkRow('开源地址', REPO_URL, REPO_URL)

          Divider().color($r('app.color.divider'))

          this.authorCard()

          Divider().color($r('app.color.divider'))

          this.sectionTitle('设备')
          this.infoRow('机型', this.deviceLine)
          this.infoRow('系统', this.osLine)
          this.infoRow('API 等级', this.apiLine)

          Divider().color($r('app.color.divider'))

          this.sectionTitle('运行环境')
          this.infoRow('JIT', this.jitLine)
          this.infoRow('JIT 探测', this.jitProbeLine)
          this.infoRow('Vulkan', this.vkLine)
          this.infoRow('后端', this.backendLine)

          Divider().color($r('app.color.divider'))

          Text('本程序仅用于技术研究与自有备份运行，不包含任何游戏内容。')
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 24 })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 让开浮在上面的 HDS 标题栏，否则第一行（开源地址）会被标题栏压住。
      .contentStartOffset(this.statusBarVp + TITLE_BAR_CONTENT_HEIGHT)
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      style: TitleBarSupport.style($r('app.color.text_primary')),
      content: {
        title: { mainTitle: '关于' },
      },
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    // 内容铺满全屏（状态栏区域也盖住），标题栏自己避让状态栏。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
