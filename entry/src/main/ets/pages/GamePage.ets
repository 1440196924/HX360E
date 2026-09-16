import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import gamePerformance from '@hms.core.gameservice.gameperformance';
import { gamePlayer } from '@kit.GameServiceKit';
import { common } from '@kit.AbilityKit';
import testNapi from 'libentry.so';
import { XPadKey } from '../common/PadKey';
import { inputDevice } from '@kit.InputKit';
import { Orientation } from '../common/Orientation';
import { VirtualStick, VirtualDpad, PadButton } from '../common/VirtualStick';
import { SettingsStore } from '../common/SettingsStore';

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
  /** 返回键触发：离开页面后再退出游戏。 */
  private quitAfterLeave: boolean = false;
  private lastSurfaceId: string = '';
  private promptTimer: number = -1;
  private attachTimer: number = -1;
  private xcompController: XComponentController = new XComponentController();
  // 画面源分辨率固定 1280x720；缩放系数见 updateFitScale：
  // 保持宽高比 = 等比 contain；关闭 = 横竖各算系数，直接拉伸满屏。
  @State scaleX: number = 1;
  @State scaleY: number = 1;
  // 保持宽高比（Display|present_letterbox，默认开）。
  private letterbox: boolean = true;
  // 虚拟手柄覆盖层开关（设置 → 高级选项 → 显示虚拟手柄）。
  @State showPad: boolean = true;
  // 调试浮层（设置 → 高级选项 → 显示调试浮层）：FPS / 帧时间，可拖动。
  @State showDebug: boolean = false;
  @State dbgFps: string = 'FPS --';
  @State dbgX: number = 12;
  @State dbgY: number = 12;
  private dbgPanX: number = 0;
  private dbgPanY: number = 0;
  private debugTimer: number = -1;

  // 保持宽高比：等比 contain；关闭：横竖各算系数（拉伸满屏、不变形）。
  updateFitScale(stageW: number, stageH: number): void {
    if (stageW <= 0 || stageH <= 0) {
      return;
    }
    if (this.letterbox) {
      const s: number = Math.min(stageW / 1280, stageH / 720);
      this.scaleX = s;
      this.scaleY = s;
    } else {
      this.scaleX = stageW / 1280;
      this.scaleY = stageH / 720;
    }
  }

  // 游戏页沉浸式：隐藏状态栏与导航条（含底部小横条），让系统按全屏游戏合成，
  // 也避免系统栏参与每帧合成。离开本页时恢复。
  private setImmersive(on: boolean): void {
    try {
      const ctx = getContext(this) as common.Context;
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.setWindowSystemBarEnable(on ? [] : ['status', 'navigation'])
          .catch((e: Error) => {
            hilog.error(DOMAIN, TAG, 'setWindowSystemBarEnable failed: %{public}s',
              e.message);
          });
        win.setSpecificSystemBarEnabled('navigationIndicator', !on)
          .catch((e: Error) => {
            hilog.error(DOMAIN, TAG, 'setSpecificSystemBarEnabled failed: %{public}s',
              e.message);
          });
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'immersive failed: %{public}s', JSON.stringify(e));
    }
  }

  // 向系统声明"我们正在渲染游戏帧"（Game Service Kit 游戏场景感知）。
  // 系统据此调整调度/频率策略；失败（例如未在应用市场登记为游戏会返回
  // Auth failed 1010300002）只记日志，不影响游戏运行。
  private declareGameScene(): void {
    // Game Service Kit 的初始化：系统据此把本应用识别为游戏（触发游戏助手/
    // 游戏级调度）。需要 UIAbilityContext。
    try {
      const uiCtx = getContext(this) as common.UIAbilityContext;
      gamePlayer.init(uiCtx).then(() => {
        hilog.info(DOMAIN, TAG, 'gamePlayer.init ok');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'gamePlayer.init failed: %{public}d %{public}s',
          e.code, e.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'gamePlayer unavailable: %{public}s', JSON.stringify(e));
    }
    try {
      gamePerformance.init({
        messageType: 0,
        bundleName: 'com.sddswsf.hx360e',
        appVersion: '1.0.0',
      }).then(() => {
        hilog.info(DOMAIN, TAG, 'gamePerformance.init ok');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'gamePerformance.init failed: %{public}d %{public}s',
          e.code, e.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'gamePerformance unavailable: %{public}s',
        JSON.stringify(e));
    }
  }

  aboutToAppear(): void {
    // 游戏是 16:9 横屏：进入本页请求横屏，离开时由 aboutToDisappear 切回竖屏。
    try {
      const ctx = getContext(this) as common.Context;
      Orientation.landscape(ctx);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'landscape failed: %{public}s', JSON.stringify(e));
    }
    this.setImmersive(true);
    this.declareGameScene();
    // 物理手柄：进入游戏页时重新武装一次 GameControllerKit 监视器（在游戏启动
    // 之前就连好的手柄也能收到事件），并注册系统热插拔监听，插入/拔出后再次
    // 武装 —— 否则监视器只在开局注册那一刻有效，后插的手柄不会有任何输入。
    this.rearmPhysicalPad('enter');
    try {
      inputDevice.on('change', this.deviceWatcher);
      hilog.info(DOMAIN, TAG, 'gamepad hot-plug watcher registered');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'gamepad watcher failed: %{public}s',
        JSON.stringify(e));
    }
    try {
      this.showPad = testNapi.emulator.showTouchOverlayEnabled();
    } catch (e) {
      this.showPad = true;
    }
    this.refreshDebugEnabled();
    this.debugTimer = setInterval(() => this.refreshDebugText(), 600);
    this.attachTimer = setInterval(() => this.tryAttach(), 200);
    this.promptTimer = setInterval(() => this.pollPrompt(), 150);
  }

  // 调试浮层开关：优先读设置里的 Display|show_debug_overlay，再退化到 native cvar。
  refreshDebugEnabled(): void {
    let on: boolean = false;
    try {
      const ss: SettingsStore = SettingsStore.shared();
      const ctx = getContext(this) as common.Context;
      ss.open(ctx.filesDir);
      on = ss.raw('Display|show_debug_overlay') === 'true';
      // 保持宽高比（默认开；设置里只有显式关掉才为 false）。
      this.letterbox = ss.raw('Display|present_letterbox') !== 'false';
    } catch (e) {
      on = false;
    }
    if (!on) {
      try {
        on = testNapi.emulator.showDebugOverlayEnabled();
      } catch (e) {
        on = false;
      }
    }
    this.showDebug = on;
  }

  refreshDebugText(): void {
    if (!this.showDebug) {
      return;
    }
    try {
      const fps: number = testNapi.emulator.averageFps();
      const ms: number = testNapi.emulator.lastFrameTimeMs();
      this.dbgFps = `FPS ${fps.toFixed(1)} · ${ms.toFixed(1)}ms`;
    } catch (e) {
      this.dbgFps = '统计不可用';
    }
  }

  /**
   * 物理手柄热插拔监听：系统上报 add/remove 时重新武装 GameControllerKit 的
   * 按键/摇杆监视器。GameControllerKit 的监视器需要在手柄已连接时注册才会
   * 持续回调，因此每次插拔都重来一遍（Stop + Start）。
   */
  private deviceWatcher: (data: inputDevice.DeviceListener) => void =
    (data: inputDevice.DeviceListener) => {
      hilog.info(DOMAIN, TAG, 'input device %{public}s (id=%{public}d)',
        data.type, data.deviceId);
      this.rearmPhysicalPad(data.type);
    };

  /** 重新武装物理手柄监视器（幂等：原生侧自己处理已启动的情况）。 */
  private rearmPhysicalPad(reason: string): void {
    try {
      testNapi.emulator.padStopPhysical();
      testNapi.emulator.padStartPhysical();
      hilog.info(DOMAIN, TAG, 'physical pad monitors re-armed (%{public}s)',
        reason);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 're-arm physical pad failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /**
   * 从游戏界面返回 = 退出游戏。
   *
   * 注意顺序：不能在 onBackPress 里直接 quit —— 那时页面与 XComponent(surface)
   * 都还活着，原生侧拆 Vulkan/window 会用到正在被销毁的 surface，实测直接闪退。
   * 正确做法是先让系统完成返回（页面销毁、surface detach），再延迟停模拟器。
   */
  onBackPress(): boolean {
    this.quitAfterLeave = true;
    return false;  // 交给系统返回
  }

  aboutToDisappear(): void {
    try {
      inputDevice.off('change', this.deviceWatcher);
    } catch (e) {
      // 忽略
    }
    // 返回退出：等页面（含 XComponent surface）真正销毁后再停模拟器，
    // 避免在 surface 仍被使用时拆 Vulkan/window（实测会闪退）。
    if (this.quitAfterLeave) {
      this.quitAfterLeave = false;
      setTimeout(() => {
        try {
          hilog.info(DOMAIN, TAG, 'game quit after leaving page');
          testNapi.emulator.quit();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'quit after leave failed: %{public}s',
            JSON.stringify(e));
        }
      }, 400);
    }
    try {
      const ctx = getContext(this) as common.Context;
      Orientation.portrait(ctx);
    } catch (e) {
      // 忽略
    }
    // 恢复系统栏（离开游戏页）。
    this.setImmersive(false);
    if (this.debugTimer >= 0) {
      clearInterval(this.debugTimer);
      this.debugTimer = -1;
    }
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

  // 摇杆：归一化 (x,y) → 4 个方向键（只在越过死区时按下并带符号轴值）。
  stickToKeys(isLeft: boolean, x: number, y: number): void {
    const dz: number = 0.12;
    const ax: number = Math.round(Math.abs(x) * 32767);
    const ay: number = Math.round(Math.abs(y) * 32767);
    const leftKey: number = isLeft ? XPadKey.LThumbLeft : XPadKey.RThumbLeft;
    const rightKey: number = isLeft ? XPadKey.LThumbRight : XPadKey.RThumbRight;
    const upKey: number = isLeft ? XPadKey.LThumbUp : XPadKey.RThumbUp;
    const downKey: number = isLeft ? XPadKey.LThumbDown : XPadKey.RThumbDown;
    const leftDown: boolean = x < -dz;
    const rightDown: boolean = x > dz;
    const upDown: boolean = y > dz;
    const downDown: boolean = y < -dz;
    try {
      testNapi.emulator.keyEvent(leftKey, leftDown, leftDown ? -ax : 0);
      testNapi.emulator.keyEvent(rightKey, rightDown, rightDown ? ax : 0);
      testNapi.emulator.keyEvent(upKey, upDown, upDown ? ay : 0);
      testNapi.emulator.keyEvent(downKey, downDown, downDown ? -ay : 0);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stick keyEvent failed: %{public}s',
        JSON.stringify(e));
    }
  }

  dpadToKeys(up: boolean, down: boolean, left: boolean, right: boolean): void {
    this.padPress(XPadKey.DpadUp, up);
    this.padPress(XPadKey.DpadDown, down);
    this.padPress(XPadKey.DpadLeft, left);
    this.padPress(XPadKey.DpadRight, right);
  }

  /**
   * 物理手柄按键 → 360 手柄按键。
   * USB 有线手柄在鸿蒙上**不经过 GameControllerKit**（实测监视器注册成功
   * reg=14/5 但事件 ev=0），而是以 HID 按键事件派发，码就是
   * KEYCODE_BUTTON_*（2301~2315）与 KEYCODE_DPAD_*（2012~2015）。
   */
  private physicalPadKey(keyCode: number): number {
    switch (keyCode) {
      case 2301: return XPadKey.A;
      case 2302: return XPadKey.B;
      case 2304: return XPadKey.X;
      case 2305: return XPadKey.Y;
      case 2307: return XPadKey.LShoulder;
      case 2308: return XPadKey.RShoulder;
      case 2309: return XPadKey.LTrigger;
      case 2310: return XPadKey.RTrigger;
      case 2311: return XPadKey.Back;     // SELECT
      case 2312: return XPadKey.Start;    // START
      case 2313: return XPadKey.Back;     // MODE
      case 2314: return XPadKey.LThumbPress;
      case 2315: return XPadKey.RThumbPress;
      case 2012: return XPadKey.DpadUp;
      case 2013: return XPadKey.DpadDown;
      case 2014: return XPadKey.DpadLeft;
      case 2015: return XPadKey.DpadRight;
      default: return -1;
    }
  }

  /** 轴事件 → 摇杆（蓝牙手柄经 GameControllerKit/轴事件时会走这里）。 */
  private handlePhysicalAxis(event: AxisEvent): void {
    try {
      const ax: number = event.getHorizontalAxisValue();
      const ay: number = event.getVerticalAxisValue();
      if (ax !== 0 || ay !== 0) {
        this.stickToKeys(true, ax, ay);
      }
    } catch (e) {
      // 忽略：某些设备不提供轴取值接口
    }
  }

  private handlePhysicalKey(event: KeyEvent): void {
    const key: number = this.physicalPadKey(event.keyCode);
    if (key < 0) {
      return;
    }
    const pressed: boolean = event.type === KeyType.Down;
    this.padPress(key, pressed);
    hilog.info(DOMAIN, TAG, 'physical pad keyCode=%{public}d -> %{public}d %{public}s',
      event.keyCode, key, pressed ? 'down' : 'up');
  }

  // 圆形按键（ABXY / L3 / R3 / Back / Start）：按住生效，自带按下反馈。
  @Builder
  roundBtn(label: string, key: number, size: number, fill: ResourceColor,
           pressedFill: ResourceColor) {
    PadButton({
      label: label,
      btnWidth: size,
      btnHeight: size,
      round: true,
      fontSize: size * 0.40,
      fill: fill,
      pressedFill: pressedFill,
      onPress: (pressed: boolean) => {
        this.padPress(key, pressed);
      },
    })
  }

  // 扳机 / 肩键（圆角矩形）。
  @Builder
  rectBtn(label: string, key: number, w: number, h: number) {
    PadButton({
      label: label,
      btnWidth: w,
      btnHeight: h,
      round: false,
      fontSize: 15,
      fill: '#59000000',
      pressedFill: '#8C000000',
      onPress: (pressed: boolean) => {
        this.padPress(key, pressed);
      },
    })
  }

  // ABXY 菱形（Y 上 / X 左 / B 右 / A 下），配色对齐参考图；四键收紧。
  @Builder
  abxyPad() {
    Column({ space: 0 }) {
      Row() {
        this.roundBtn('Y', XPadKey.Y, 44, '#8A7A2E', '#C9B03A')
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      Row({ space: 0 }) {
        this.roundBtn('X', XPadKey.X, 44, '#2F5DA8', '#4E86D8')
        Column().width(24).height(44)
        this.roundBtn('B', XPadKey.B, 44, '#8E2B2B', '#C24242')
      }

      Row() {
        this.roundBtn('A', XPadKey.A, 44, '#2E7D32', '#49A44F')
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width(112)
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
          x: this.scaleX,
          y: this.scaleY,
          centerX: '50%',
          centerY: '50%',
        })
        .onSizeChange((old: SizeOptions, now: SizeOptions) => {
          hilog.info(DOMAIN, TAG,
            'xcomponent size %{public}d x %{public}d (was %{public}d x %{public}d)',
            Math.round(now.width as number), Math.round(now.height as number),
            Math.round(old.width as number), Math.round(old.height as number));
        })

      // 虚拟手柄覆盖层（可在 设置 → 高级选项 里关闭）。
      // 布局对齐参考图：顶左 LT/LB，顶右 RT/RB；左簇 = 左摇杆 + L3 + 十字键；
      // 右簇 = ABXY 菱形 + R3 + 右摇杆；底部中间 Back / Start。
      if (this.showPad) {
        // 顶部：扳机与肩键
        Row() {
          Column({ space: 6 }) {
            this.rectBtn('LT', XPadKey.LTrigger, 104, 44)
            this.rectBtn('LB', XPadKey.LShoulder, 92, 38)
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Column({ space: 6 }) {
            this.rectBtn('RT', XPadKey.RTrigger, 104, 44)
            this.rectBtn('RB', XPadKey.RShoulder, 92, 38)
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: 10, right: 10, top: 6 })
        .hitTestBehavior(HitTestMode.None)

        // 底部中间：Back / Start
        Row({ space: 56 }) {
          this.roundBtn('◀', XPadKey.Back, 40, '#59000000', '#8C000000')
          this.roundBtn('▶', XPadKey.Start, 40, '#59000000', '#8C000000')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Bottom)
        .padding({ bottom: 14 })
        .hitTestBehavior(HitTestMode.None)

        // 左侧：左摇杆 + L3，下方十字键（固定上边距避开 LB，十字键再下移一点）
        Column({ space: 34 }) {
          Row({ space: 10 }) {
            VirtualStick({
              diameter: 118,
              knobDiameter: 48,
              onStick: (x: number, y: number) => {
                this.stickToKeys(true, x, y);
              },
            })
            this.roundBtn('L3', XPadKey.LThumbPress, 40, '#59000000', '#8C000000')
          }
          .alignItems(VerticalAlign.Center)

          VirtualDpad({
            diameter: 118,
            onDir: (up: boolean, down: boolean, left: boolean, right: boolean) => {
              this.dpadToKeys(up, down, left, right);
            },
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .padding({ left: 12, top: 104, bottom: 40 })
        .hitTestBehavior(HitTestMode.None)

        // 右侧：ABXY + R3 + 右摇杆
        Column({ space: 20 }) {
          this.abxyPad()
          Row({ space: 10 }) {
            this.roundBtn('R3', XPadKey.RThumbPress, 40, '#59000000', '#8C000000')
            VirtualStick({
              diameter: 118,
              knobDiameter: 48,
              onStick: (x: number, y: number) => {
                this.stickToKeys(false, x, y);
              },
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.End)
        .justifyContent(FlexAlign.Start)
        .padding({ right: 12, top: 104, bottom: 40 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 调试浮层（设置 → 高级选项 → 显示调试浮层）：三项横排，可拖动。
      if (this.showDebug) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 12 }) {
            Text(this.dbgFps).fontSize(12).fontColor('#E6FFFFFF')
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#8C000000')
          .borderRadius(8)
          .position({ x: this.dbgX, y: this.dbgY })
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.dbgPanX = this.dbgX;
                this.dbgPanY = this.dbgY;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.dbgX = Math.max(0, this.dbgPanX + event.offsetX);
                this.dbgY = Math.max(0, this.dbgPanY + event.offsetY);
              })
          )
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

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
    // 游戏页背景纯黑（黑边/拉伸时露出的区域也是黑的）。
    .backgroundColor('#000000')
    // 物理手柄：USB 有线手柄以 HID 按键事件进来，在这里映射成 360 手柄按键。
    .onKeyEvent((event: KeyEvent) => {
      this.handlePhysicalKey(event);
    })
    // 摇杆是模拟轴，走轴事件（USB 手柄实测不派发，保留映射入口以便蓝牙手柄可用）。
    .onAxisEvent((event: AxisEvent) => {
      this.handlePhysicalAxis(event);
    })
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
