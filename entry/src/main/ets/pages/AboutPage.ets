import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, bundleManager } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 关于：应用信息（logo / 名称 / 版本）+ 免责声明。 */
@Component
export struct AboutPage {
  /** 沉浸式窗口下需要自己让出状态栏高度，否则自带标题栏被状态栏挡住。 */
  @State statusBarVp: number = 0;
  @State version: string = '';

  aboutToAppear(): void {
    this.applyStatusBarInset();
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.version = info.versionName;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read version failed: %{public}s', JSON.stringify(e));
      this.version = '(未知)';
    }
  }

  // 取系统状态栏高度（与 Home.ets / AdvancedPage.ets 的做法一致）。
  private applyStatusBarInset(): void {
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        const avoid: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const px: number = avoid.topRect.height;
        const density: number = display.getDefaultDisplaySync().densityPixels;
        this.statusBarVp = density > 0 ? Math.ceil(px / density) : 0;
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyStatusBarInset failed: %{public}s',
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

  build() {
    NavDestination() {
      Column() {

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

          Divider().color($r('app.color.divider'))

          Text('本程序仅用于技术研究与自有备份运行，不包含任何游戏内容。')
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 24 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .title('关于')
    // 沉浸式窗口下把整页往下让出状态栏高度，否则自带的标题栏被状态栏挡住。
    .margin({ top: this.statusBarVp })
  }
}
