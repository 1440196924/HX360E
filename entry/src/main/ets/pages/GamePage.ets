import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import testNapi from 'libentry.so';
import { XPadKey } from '../common/PadKey';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 游戏运行页：只显示游戏画面（XComponent）与虚拟手柄按钮。
 * 由 Index 的「启动」通过 router 进入；游戏本身跑在 native 线程，切换页面不影响。
 * guest 提示（键盘/对话框/换盘）仍以模态层覆盖在此页上（仅在有请求时出现）。
 */
@Entry
@Component
struct GamePage {
  // ---- guest 提示（Phase 5.3）：'' | 'keyboard' | 'msgbox' | 'disc' ----
  @State promptKind: string = '';
  @State promptTitle: string = '';
  @State promptMessage: string = '';
  @State promptInput: string = '';
  @State promptButtons: string[] = [];
  @State promptDiscLabels: string[] = [];
  @State promptDiscPaths: string[] = [];
  private promptId: bigint = BigInt(0);
  private lastSurfaceId: string = '';
  private promptTimer: number = -1;
  private attachTimer: number = -1;
  private xcompController: XComponentController = new XComponentController();
  // 画面源分辨率固定 1280x720；用统一系数放大到窗口（contain：保持比例、不裁边、不拉伸）。
  @State fitScale: number = 1;

  // contain：横纵取较小的系数，画面完整放进窗口且不变形（不足处留黑边）。
  updateFitScale(stageW: number, stageH: number): void {
    if (stageW <= 0 || stageH <= 0) {
      return;
    }
    this.fitScale = Math.min(stageW / 1280, stageH / 720);
  }

  aboutToAppear(): void {
    this.attachTimer = setInterval(() => this.tryAttach(), 200);
    this.promptTimer = setInterval(() => this.pollPrompt(), 150);
  }

  aboutToDisappear(): void {
    if (this.attachTimer >= 0) {
      clearInterval(this.attachTimer);
      this.attachTimer = -1;
    }
    if (this.promptTimer >= 0) {
      clearInterval(this.promptTimer);
      this.promptTimer = -1;
    }
    // 离开游戏页时释放虚拟手柄按键并放行阻塞在提示上的 guest 线程。
    try {
      testNapi.emulator.padReleaseAll();
    } catch (e) {
      // 忽略
    }
    this.cancelAllPrompts();
  }

  // 取 surfaceId 并交给 native。持续轮询：surface 在窗口尺寸变化时可能被重建并
  // 换新 id，需要重新 attach（否则放大窗口会卡死）。
  tryAttach(): void {
    try {
      const id: string = this.xcompController.getXComponentSurfaceId();
      if (id === '' || id === '0' || id === this.lastSurfaceId) {
        return;
      }
      const ok: boolean = testNapi.attachSurface(id);
      this.lastSurfaceId = id;
      hilog.info(DOMAIN, TAG, 'attachSurface(%{public}s) -> %{public}d', id, ok ? 1 : 0);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'attach failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---- guest 提示（Phase 5.3）----

  // 150ms 轮询 guest 的键盘/对话框/换盘请求（DESIGN.md §9.3）。
  pollPrompt(): void {
    if (this.promptKind !== '') {
      return;
    }
    try {
      const kb = testNapi.prompt.keyboardRequest();
      if (kb !== null) {
        this.promptId = kb.id;
        this.promptTitle = kb.title;
        this.promptMessage = kb.description;
        this.promptInput = kb.defaultText;
        this.promptKind = 'keyboard';
        return;
      }
      const mb = testNapi.prompt.msgboxRequest();
      if (mb !== null) {
        this.promptId = mb.id;
        this.promptTitle = mb.title;
        this.promptMessage = mb.text;
        this.promptButtons = mb.buttons;
        this.promptKind = 'msgbox';
        return;
      }
      const d = testNapi.prompt.discRequest();
      if (d !== null) {
        this.promptId = d.id;
        this.promptTitle = '请更换光盘';
        this.promptMessage = d.message;
        this.promptDiscLabels = d.discLabels;
        this.promptDiscPaths = d.discPaths;
        this.promptKind = 'disc';
      }
    } catch (e) {
      // 模块未就绪时忽略
    }
  }

  clearPrompt(): void {
    this.promptKind = '';
    this.promptTitle = '';
    this.promptMessage = '';
    this.promptInput = '';
    this.promptButtons = [];
    this.promptDiscLabels = [];
    this.promptDiscPaths = [];
  }

  submitKeyboard(accepted: boolean): void {
    try {
      testNapi.prompt.keyboardSubmit(this.promptId, accepted, this.promptInput);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'keyboardSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  submitMsgbox(index: number): void {
    try {
      testNapi.prompt.msgboxSubmit(this.promptId, index);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'msgboxSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  submitDisc(accepted: boolean, path: string): void {
    try {
      testNapi.prompt.discSubmit(this.promptId, accepted, path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'discSubmit failed: %{public}s', JSON.stringify(e));
    }
    this.clearPrompt();
  }

  cancelAllPrompts(): void {
    try {
      testNapi.prompt.keyboardCancelAll();
      testNapi.prompt.msgboxCancelAll();
      testNapi.prompt.discCancelAll();
    } catch (e) {
      // 忽略
    }
    this.clearPrompt();
  }

  // ---- 虚拟手柄输入 ----

  // 摇杆方向 / 扳机需要带模拟值，其余按键只需按下与否。
  private keyValue(key: number): number {
    if (key === XPadKey.LTrigger || key === XPadKey.RTrigger) {
      return 255;
    }
    if (key === XPadKey.LThumbLeft || key === XPadKey.LThumbDown ||
      key === XPadKey.RThumbLeft || key === XPadKey.RThumbDown) {
      return -32767;
    }
    if (key === XPadKey.LThumbRight || key === XPadKey.LThumbUp ||
      key === XPadKey.RThumbRight || key === XPadKey.RThumbUp) {
      return 32767;
    }
    return 0;
  }

  padPress(key: number, pressed: boolean): void {
    try {
      testNapi.emulator.keyEvent(key, pressed, this.keyValue(key));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'keyEvent failed: %{public}s', JSON.stringify(e));
    }
  }

  // 按住生效的手柄按钮（触摸 Down/Up，而不是点击）。
  @Builder
  padBtn(label: string, key: number) {
    Button(label)
      .fontSize(11)
      .fontColor('#fff')
      .backgroundColor('#6600aaff')
      .borderRadius(6)
      .width(46)
      .height(34)
      .padding(0)
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          this.padPress(key, true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.padPress(key, false);
        }
      })
  }

  @Builder
  dpadPad() {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('D↑', XPadKey.DpadUp)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('D←', XPadKey.DpadLeft)
        this.padBtn('D↓', XPadKey.DpadDown)
        this.padBtn('D→', XPadKey.DpadRight)
      }
    }
    .width(132)
  }

  @Builder
  facePad() {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('Y', XPadKey.Y)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('X', XPadKey.X)
        this.padBtn('B', XPadKey.B)
        this.padBtn('A', XPadKey.A)
      }
    }
    .width(132)
  }

  // 摇杆用 4 向按钮近似（满偏），够跑通输入链路；模拟量后续再做。
  @Builder
  stickPad(isLeft: boolean) {
    Column({ space: 2 }) {
      Row() {
        this.padBtn('↑', isLeft ? XPadKey.LThumbUp : XPadKey.RThumbUp)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 2 }) {
        this.padBtn('←', isLeft ? XPadKey.LThumbLeft : XPadKey.RThumbLeft)
        this.padBtn(isLeft ? 'L3' : 'R3',
          isLeft ? XPadKey.LThumbPress : XPadKey.RThumbPress)
        this.padBtn('→', isLeft ? XPadKey.LThumbRight : XPadKey.RThumbRight)
      }

      Row() {
        this.padBtn('↓', isLeft ? XPadKey.LThumbDown : XPadKey.RThumbDown)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width(132)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'hx360e_surface_game',
        type: XComponentType.SURFACE,
        // libraryname 必须设置，系统才会把 __NATIVE_XCOMPONENT_OBJ__ 注入该
        // native 模块的 exports —— 否则 OnSurfaceCreated/Changed 回调不会注册，
        // 窗口缩放时就没法重建 swapchain。
        libraryname: 'entry',
        controller: this.xcompController,
      })
        // 画面就是 1280x720（guest 输出分辨率），单位显式写 px（ArkTS 默认 vp）。
        .width('1280px')
        .height('720px')
        // 等比放大放进窗口（contain）：横纵统一系数，保持比例、不裁边、不拉伸，居中。
        .scale({
          x: this.fitScale,
          y: this.fitScale,
          centerX: '50%',
          centerY: '50%',
        })
        .onSizeChange((old: SizeOptions, now: SizeOptions) => {
          hilog.info(DOMAIN, TAG,
            'xcomponent size %{public}d x %{public}d (was %{public}d x %{public}d)',
            Math.round(now.width as number), Math.round(now.height as number),
            Math.round(old.width as number), Math.round(old.height as number));
        })

      // 虚拟手柄覆盖层（始终显示）。
      Column() {
        Row({ space: 6 }) {
          this.padBtn('LB', XPadKey.LShoulder)
          this.padBtn('LT', XPadKey.LTrigger)
          this.padBtn('BK', XPadKey.Back)
          this.padBtn('ST', XPadKey.Start)
          this.padBtn('RT', XPadKey.RTrigger)
          this.padBtn('RB', XPadKey.RShoulder)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')

        Row({ space: 8 }) {
          this.stickPad(true)
          this.dpadPad()
          this.facePad()
          this.stickPad(false)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .padding({ bottom: 40 })
      // None：覆盖层容器自身不参与命中测试，只有里面的手柄按钮响应。
      .hitTestBehavior(HitTestMode.None)

      // guest 提示模态层（仅在有请求时出现）。
      if (this.promptKind !== '') {
        Column() {
          Column({ space: 10 }) {
            Text(this.promptTitle)
              .fontSize(16)
              .fontColor('#fff')
              .width('100%')
            Text(this.promptMessage)
              .fontSize(13)
              .fontColor('#ddd')
              .width('100%')

            if (this.promptKind === 'keyboard') {
              TextInput({ placeholder: '请输入…', text: this.promptInput })
                .width('100%')
                .onChange((value: string) => {
                  this.promptInput = value;
                })
              Row({ space: 8 }) {
                Button('确定')
                  .layoutWeight(1)
                  .onClick(() => this.submitKeyboard(true))
                Button('取消')
                  .layoutWeight(1)
                  .onClick(() => this.submitKeyboard(false))
              }
              .width('100%')
            } else if (this.promptKind === 'msgbox') {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                ForEach(this.promptButtons, (label: string, index: number) => {
                  Button(label)
                    .margin(4)
                    .onClick(() => this.submitMsgbox(index))
                })
              }
              .width('100%')
            } else {
              Column({ space: 6 }) {
                ForEach(this.promptDiscLabels, (label: string, index: number) => {
                  Button(label)
                    .width('100%')
                    .onClick(() => this.submitDisc(true, this.promptDiscPaths[index]))
                })
                Button('取消')
                  .width('100%')
                  .onClick(() => this.submitDisc(false, ''))
              }
              .width('100%')
            }
          }
          .width('80%')
          .padding(16)
          .backgroundColor('#ee202020')
          .borderRadius(10)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // Area 宽高是 vp；densityPixels = px/vp，换算成 px。
      let density: number = 1;
      let screenW: number = 0;
      let screenH: number = 0;
      try {
        const d = display.getDefaultDisplaySync();
        density = d.densityPixels;
        screenW = d.width;
        screenH = d.height;
      } catch (e) {
        density = 1;
      }
      const w: number = Math.round((newArea.width as number) * density);
      const h: number = Math.round((newArea.height as number) * density);
      this.updateFitScale(w, h);
      hilog.info(DOMAIN, TAG,
        'stage %{public}d x %{public}d px; screen %{public}d x %{public}d density=%{public}d',
        w, h, Math.round(screenW), Math.round(screenH), Math.round(density * 1000));
    })
  }
}
