import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, bundleManager, Want } from '@kit.AbilityKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { TitleBarSupport } from '../common/TitleBarSupport';

const DOMAIN = 0x0000;
const TAG = 'HX360E';
/** 作者 B 站主页。 */
const AUTHOR_URL = 'https://space.bilibili.com/297193944';
const AUTHOR_NAME = '山东的大蒜王师傅';
/** 开源仓库地址。 */
const REPO_URL = 'https://github.com/1440196924/HX360E';

/** 关于：应用信息（logo / 名称 / 版本）+ 免责声明。 */
@Component
export struct AboutPage {
  @State version: string = '';

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

          // 求充电：整块可点，跳系统浏览器打开 B 站主页。
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
