import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window, display, LengthMetrics } from '@kit.ArkUI';
import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuItemOptions,
  HdsNavigationIconOptions,
} from '@kit.UIDesignKit';
import { SettingsSchema, SettingsCategory, Setting } from '../common/SettingsSchema';
import { SettingsStore } from '../common/SettingsStore';
import { TitleBarSupport, TITLE_BAR_CONTENT_HEIGHT } from '../common/TitleBarSupport';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

/**
 * 一行设置。做成独立 @Component（而不是 @Builder + 闭包）：
 * @Builder 的参数在回调里捕获会串行（ArkUI 已知行为），
 * 独立组件每行各持一个 setting 实例，回调不会写错键。
 */
@Component
struct SettingRow {
  setting: Setting = new Setting();
  @State localRev: number = 0;

  private store(): SettingsStore {
    return SettingsStore.shared();
  }

  private step(): number {
    const span: number = this.setting.max - this.setting.min;
    if (span > 512) {
      return 64;
    }
    if (span > 64) {
      return 16;
    }
    return 1;
  }

  private selectOptions(): Array<SelectOption> {
    const out: Array<SelectOption> = [];
    for (const o of this.setting.options) {
      const item: SelectOption = { value: o.label };
      out.push(item);
    }
    return out;
  }

  private selectedIndex(): number {
    const cur: string = this.store().valueOf(this.setting);
    for (let i = 0; i < this.setting.options.length; i++) {
      if (this.setting.options[i].value === cur) {
        return i;
      }
    }
    return -1;
  }

  private selectedLabel(): string {
    const idx: number = this.selectedIndex();
    return idx >= 0 ? this.setting.options[idx].label
      : this.store().valueOf(this.setting);
  }

  @Builder
  label() {
    Row({ space: 6 }) {
      Text(this.setting.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.store().isModified(this.setting)) {
        Text('●').fontSize(9).fontColor($r('app.color.accent'))
      }
    }
    .alignItems(VerticalAlign.Center)
    .layoutWeight(1)
  }

  build() {
    Column() {
      if (this.setting.type === 'bool') {
        Row() {
          this.label()
          Toggle({
            type: ToggleType.Switch,
            isOn: this.store().valueOf(this.setting) === 'true',
          })
            .onChange((on: boolean) => {
              // 只在值真变化时写入：挂载/刷新触发的回调不回写。
              const next: string = on ? 'true' : 'false';
              if (this.store().valueOf(this.setting) !== next) {
                this.store().set(this.setting, next);
                this.localRev++;
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      } else if (this.setting.type === 'int') {
        Row({ space: 8 }) {
          this.label()
          Button('−')
            .fontSize(16)
            .width(34)
            .height(30)
            .padding(0)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              const cur: number =
                Number.parseInt(this.store().valueOf(this.setting));
              const next: number = Number.isNaN(cur) ? this.setting.min
                : Math.max(this.setting.min, cur - this.step());
              this.store().set(this.setting, `${next}`);
              this.localRev++;
            })
          Text(this.store().valueOf(this.setting))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .width(64)
            .textAlign(TextAlign.Center)
          Button('+')
            .fontSize(16)
            .width(34)
            .height(30)
            .padding(0)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              const cur: number =
                Number.parseInt(this.store().valueOf(this.setting));
              const next: number = Number.isNaN(cur) ? this.setting.min
                : Math.min(this.setting.max, cur + this.step());
              this.store().set(this.setting, `${next}`);
              this.localRev++;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      } else {
        Row({ space: 8 }) {
          this.label()
          Select(this.selectOptions())
            .selected(this.selectedIndex())
            .value(this.selectedLabel())
            .font({ size: 13 })
            .onSelect((index: number, value?: string) => {
              if (index < 0 || index >= this.setting.options.length) {
                return;
              }
              const next: string = this.setting.options[index].value;
              if (this.store().valueOf(this.setting) !== next) {
                this.store().set(this.setting, next);
                this.localRev++;
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      }
    }
    .width('100%')
  }
}

/**
 * 高级选项：按分区列出设置（对照安卓版 SettingsSchema）。
 * bool = 开关；int = −/+ 步进；list = 下拉选择。
 * 改动即时写入内存中的 TOML，离开页面时落盘（storage/xenia.config.toml），
 * 下次启动游戏通过 --config= 生效。标题栏用 NavDestination 自带（含返回按钮）。
 */
@Component
export struct AdvancedPage {
  @State statusText: string = '';
  @State deviceInfo: string = '';
  // 状态栏高度（vp）。窗口是沉浸式全屏，NavDestination 自带的标题栏会被状态栏
  // 挡住，所以整页往下让出这个高度（标题栏/返回键随之可见）。
  @State statusBarVp: number = 0;
  private store: SettingsStore = SettingsStore.shared();

  aboutToAppear(): void {
    this.applyStatusBarInset();
    try {
      const ctx = getContext(this) as common.Context;
      this.store.open(ctx.filesDir);
      this.statusText = this.store.isOpen() ? '设置已加载（改动自动保存）'
        : '设置不可用（见 hilog）';
      this.store.dumpToLog();
    } catch (e) {
      this.statusText = '设置不可用（见 hilog）';
      hilog.error(DOMAIN, TAG, 'settings open failed: %{public}s',
        JSON.stringify(e));
    }
  }

  // 取系统状态栏高度（与 Home.ets 的做法一致）。
  private applyStatusBarInset(): void {
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        const avoid: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const px: number = avoid.topRect.height;
        const density: number = display.getDefaultDisplaySync().densityPixels;
        this.statusBarVp = density > 0 ? Math.ceil(px / density) : 0;
        hilog.info(DOMAIN, TAG, 'AdvancedPage status bar inset: %{public}d vp',
          this.statusBarVp);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyStatusBarInset failed: %{public}s',
        JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    // dirty 时落盘；未改动则直接释放。
    this.store.close();
  }

  @Builder
  categoryCard(cat: SettingsCategory) {
    Column() {
      Text(cat.title)
        .fontSize(13)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 6 })

      ForEach(cat.settings, (s: Setting) => {
        SettingRow({ setting: s })
      }, (s: Setting) => s.tag())
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }

  build() {
    HdsNavDestination() {
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(SettingsSchema.categories(), (cat: SettingsCategory) => {
              this.categoryCard(cat)
            }, (cat: SettingsCategory) => cat.title)

            Text(this.deviceInfo)
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        // 让开浮在上面的 HDS 标题栏（状态栏避让区 + 标题栏内容高）。
        .contentStartOffset(this.statusBarVp + TITLE_BAR_CONTENT_HEIGHT)

        Text(this.statusText)
          .fontSize(11)
          .fontColor($r('app.color.accent'))
          .maxLines(2)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 10 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .titleBar({
      padding: {
        start: LengthMetrics.vp(16),
        end: LengthMetrics.vp(16),
      },
      avoidLayoutSafeArea: true,
      style: TitleBarSupport.style($r('app.color.text_primary')),
      content: {
        title: { mainTitle: '高级选项' },
        menu: {
          value: this.titleBarMenu(),
        },
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

  /** 标题栏右侧的「重置」按钮（HDS 系统级菜单项）。 */
  private titleBarMenu(): Array<HdsNavigationMenuItemOptions> {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    const item: HdsNavigationIconOptions = {
      label: '重置',
      isEnabled: true,
      action: () => {
        this.store.resetAll();
        this.statusText = '已恢复默认（返回时保存）';
      },
    };
    const menuItem: HdsNavigationMenuItemOptions = { content: item };
    items.push(menuItem);
    return items;
  }
}
