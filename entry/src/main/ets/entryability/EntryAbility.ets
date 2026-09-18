import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppLog } from '../common/AppLog';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用级日志：写到 <filesDir>/logs/app.log，可用「设置 → 导出日志」带出来。
    AppLog.init(this.context.filesDir);
    AppLog.i('ability', 'onCreate');
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Home', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // 沉浸式：布局全屏，页面里再对需要的组件用 expandSafeArea 延伸到状态栏下方。
    // 同时按当前深浅色设置状态栏文字颜色，保证可读。
    windowStage.getMainWindow().then((win: window.Window) => {
      try {
        win.setWindowLayoutFullScreen(true);
        const dark: boolean =
          this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        win.setWindowSystemBarProperties({
          statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        });
        hilog.info(DOMAIN, 'testTag', 'immersive on, dark=%{public}d', dark ? 1 : 0);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'fullscreen failed: %{public}s', JSON.stringify(e));
      }
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'getMainWindow failed: %{public}s', e.message);
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}