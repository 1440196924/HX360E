import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 关于：应用信息 + 设备/后端信息 + JIT 结论。 */
@Entry
@Component
struct AboutPage {
  @State deviceInfo: string = '';
  @State jitInfo: string = '';

  aboutToAppear(): void {
    try {
      this.deviceInfo = testNapi.emulator.deviceInfo();
    } catch (e) {
      this.deviceInfo = '(不可用)';
      hilog.error(DOMAIN, TAG, 'deviceInfo failed: %{public}s', JSON.stringify(e));
    }
    try {
      const r = testNapi.jitProbe();
      this.jitInfo = r.firstWorking >= 0 ? `${r.firstWorkingName}` : '不可用';
    } catch (e) {
      this.jitInfo = '(探测失败)';
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
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor($r('app.color.accent'))
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Blank()
        Text('关于').fontSize(16).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column() {
          Column({ space: 6 }) {
            Text('HX360E').fontSize(24).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
            Text('HarmonyOS 上的 Xbox 360 模拟器（Xenia 移植）')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().color($r('app.color.divider'))

          this.infoRow('包名', 'com.sddswsf.hx360e')
          this.infoRow('后端', this.deviceInfo)
          this.infoRow('JIT', this.jitInfo)

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
}
