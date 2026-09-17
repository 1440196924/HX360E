import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 朝向控制：主页/设置页竖屏，游戏页横屏。
 *
 * **必须拿主窗口**：`window.getLastWindow()` 返回的是"最后创建的窗口"，
 * 长按游戏弹出的上下文菜单、半模态等子窗都算"最后窗口"——朝子窗设朝向
 * 等于没设，主窗口仍停在竖屏。这正是"长按菜单里启动游戏不横屏"的原因。
 * 所以这里优先用 UIAbilityContext 的 windowStage.getMainWindowSync()，
 * 拿不到再退回 getLastWindow。
 */
export class Orientation {
  private static nameOf(o: window.Orientation): string {
    if (o === window.Orientation.PORTRAIT) {
      return 'portrait';
    }
    if (o === window.Orientation.LANDSCAPE) {
      return 'landscape';
    }
    if (o === window.Orientation.AUTO_ROTATION_LANDSCAPE) {
      return 'auto_rotation_landscape';
    }
    return `orientation(${o})`;
  }

  static apply(ctx: common.UIAbilityContext, orientation: window.Orientation): void {
    try {
      const win: window.Window = ctx.windowStage.getMainWindowSync();
      win.setPreferredOrientation(orientation);
      hilog.info(DOMAIN, TAG, 'orientation set to %{public}s',
        Orientation.nameOf(orientation));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getMainWindowSync failed, fallback: %{public}s',
        JSON.stringify(e));
      window.getLastWindow(ctx).then((win: window.Window) => {
        try {
          win.setPreferredOrientation(orientation);
        } catch (e2) {
          hilog.error(DOMAIN, TAG, 'setPreferredOrientation failed: %{public}s',
            JSON.stringify(e2));
        }
      }).catch((e3: Error) => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', e3.message);
      });
    }
  }

  static portrait(ctx: common.UIAbilityContext): void {
    Orientation.apply(ctx, window.Orientation.PORTRAIT);
  }

  static landscape(ctx: common.UIAbilityContext): void {
    Orientation.apply(ctx, window.Orientation.LANDSCAPE);
  }

  /**
   * 横屏自动翻转：只在 LANDSCAPE(90°) 与 LANDSCAPE_INVERTED(270°) 之间跟随
   * 重力切换，不会转成竖屏。游戏页用这个——把手机转 180° 画面跟着正过来。
   */
  static autoLandscape(ctx: common.UIAbilityContext): void {
    Orientation.apply(ctx, window.Orientation.AUTO_ROTATION_LANDSCAPE);
  }
}
