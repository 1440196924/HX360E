import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 朝向控制：主页/设置页竖屏，游戏页横屏。
 * 用 window.getLastWindow 拿当前窗口再 setPreferredOrientation。
 */
export class Orientation {
  static apply(ctx: common.Context, orientation: window.Orientation): void {
    window.getLastWindow(ctx).then((win: window.Window) => {
      try {
        win.setPreferredOrientation(orientation);
        hilog.info(DOMAIN, TAG, 'orientation set to %{public}s',
          orientation === window.Orientation.PORTRAIT ? 'portrait' : 'landscape');
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'setPreferredOrientation failed: %{public}s',
          JSON.stringify(e));
      }
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', e.message);
    });
  }

  static portrait(ctx: common.Context): void {
    Orientation.apply(ctx, window.Orientation.PORTRAIT);
  }

  static landscape(ctx: common.Context): void {
    Orientation.apply(ctx, window.Orientation.LANDSCAPE);
  }
}
