import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/** 高级选项：目前是只读信息 + 少数可切换项（都用已有的 native 接口）。 */
@Entry
@Component
struct AdvancedPage {
  @State deviceInfo: string = '';
  @State jitInfo: string = '';
  @State fpsInfo: string = '';
  @State touchOverlayOn: boolean = false;
  @State statusText: string = '';

  aboutToAppear(): void {
    this.refresh();
    try {
      this.touchOverlayOn = testNapi.emulator.showTouchOverlayEnabled();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'touchOverlay query failed: %{public}s', JSON.stringify(e));
    }
  }

  onPageShow(): void {
    this.refresh();
  }

  refresh(): void {
    try {
      this.deviceInfo = testNapi.emulator.deviceInfo();
    } catch (e) {
      this.deviceInfo = '(不可用)';
    }
    try {
      const r = testNapi.jitProbe();
      this.jitInfo = r.firstWorking >= 0 ? `${r.firstWorkingName} ✅` : '不可用 ❌';
    } catch (e) {
      this.jitInfo = '(探测失败)';
    }
    try {
      const fps: number = testNapi.emulator.averageFps();
      const ms: number = testNapi.emulator.lastFrameTimeMs();
      this.fpsInfo = `平均 ${fps.toFixed(1)} FPS · 上一帧 ${ms.toFixed(1)} ms`;
    } catch (e) {
      this.fpsInfo = '(未运行)';
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
        Text('高级选项').fontSize(16).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column() {
          this.infoRow('GPU / 音频 / 输入后端', this.deviceInfo)
          this.infoRow('JIT 可执行内存', this.jitInfo)
          this.infoRow('性能', this.fpsInfo)

          Divider().color($r('app.color.divider')).margin({ top: 4, bottom: 4 })

          Row() {
            Column({ space: 2 }) {
              Text('显示虚拟手柄').fontSize(15).fontColor($r('app.color.text_primary'))
              Text('游戏页底部的手柄按钮覆盖层').fontSize(11).fontColor($r('app.color.text_hint'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.touchOverlayOn })
              .onChange((isOn: boolean) => {
                this.touchOverlayOn = isOn;
                try {
                  testNapi.emulator.setShowTouchOverlay(isOn);
                  this.statusText = isOn ? '已显示虚拟手柄' : '已隐藏虚拟手柄';
                } catch (e) {
                  this.statusText = '设置失败（见 hilog）';
                  hilog.error(DOMAIN, TAG, 'setShowTouchOverlay failed: %{public}s',
                    JSON.stringify(e));
                }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })

          Divider().color($r('app.color.divider')).margin({ top: 4, bottom: 4 })

          Row() {
            Column({ space: 2 }) {
              Text('刷新 GPU 缓存').fontSize(15).fontColor($r('app.color.text_primary'))
              Text('画面异常时清空着色器/管线缓存').fontSize(11).fontColor($r('app.color.text_hint'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('执行')
              .fontSize(13)
              .height(32)
              .onClick(() => {
                try {
                  testNapi.emulator.flushGpuCaches();
                  this.statusText = '已刷新 GPU 缓存';
                } catch (e) {
                  this.statusText = '刷新失败（见 hilog）';
                }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })

          Text(this.statusText)
            .fontSize(11)
            .fontColor($r('app.color.accent'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 16 })
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
