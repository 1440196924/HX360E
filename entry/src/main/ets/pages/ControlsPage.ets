import { XPadKey } from '../common/PadKey';

/** 控制：虚拟手柄按键 ↔ native 键位索引对照（映射编辑后续再做）。 */
@Entry
@Component
struct ControlsPage {
  @Builder
  keyRow(label: string, index: number) {
    Row() {
      Text(label).fontSize(14).fontColor($r('app.color.text_primary'))
      Blank()
      Text(`#${index}`).fontSize(12).fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor('#6cf')
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor($r('app.color.accent'))
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Blank()
        Text('控制').fontSize(16).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Bold)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column() {
          this.sectionTitle('方向键 / 摇杆')
          this.keyRow('十字键 上', XPadKey.DpadUp)
          this.keyRow('十字键 下', XPadKey.DpadDown)
          this.keyRow('十字键 左', XPadKey.DpadLeft)
          this.keyRow('十字键 右', XPadKey.DpadRight)
          this.keyRow('左摇杆（近似为 4 向）', XPadKey.LThumbUp)
          this.keyRow('右摇杆（近似为 4 向）', XPadKey.RThumbUp)

          this.sectionTitle('按键')
          this.keyRow('A', XPadKey.A)
          this.keyRow('B', XPadKey.B)
          this.keyRow('X', XPadKey.X)
          this.keyRow('Y', XPadKey.Y)
          this.keyRow('Back', XPadKey.Back)
          this.keyRow('Start', XPadKey.Start)

          this.sectionTitle('肩键 / 扳机 / 摇杆按下')
          this.keyRow('LB', XPadKey.LShoulder)
          this.keyRow('RB', XPadKey.RShoulder)
          this.keyRow('LT', XPadKey.LTrigger)
          this.keyRow('RT', XPadKey.RTrigger)
          this.keyRow('L3（左摇杆按下）', XPadKey.LThumbPress)
          this.keyRow('R3（右摇杆按下）', XPadKey.RThumbPress)

          Text('索引与 native 侧 OhosPadKey 一一对应；自定义按键映射待实现。')
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
