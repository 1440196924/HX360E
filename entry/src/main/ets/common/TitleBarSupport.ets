import { LengthMetrics } from '@kit.ArkUI';
import {
  TitleBarStyleOptions,
  HdsNavigationIconItemStyle,
  HdsNavigationTitleBarStyle,
  HdsTitleBarContentStyle,
  hdsMaterial,
  BlurStrategy,
  ScrollEffectType,
} from '@kit.UIDesignKit';

/** 系统单行标题栏的内容高度（不含状态栏避让区）。 */
export const TITLE_BAR_CONTENT_HEIGHT: number = 56;

/**
 * HDS 标题栏的公共配置。
 *
 * 页面统一用 HdsNavDestination + titleBar({ avoidLayoutSafeArea: true })：
 * 标题栏自己避让状态栏，内容区 ignoreLayoutSafeArea 铺满全屏。样式上这里
 * 只给文字颜色 + 系统「沉浸光感」材质，**不设任何背景色**——一旦设了不透明
 * 底色，材质就被盖住、光感消失。
 */
export class TitleBarSupport {
  private static level: hdsMaterial.MaterialLevel | undefined = undefined;

  /**
   * 沉浸光感材质档位：设备支持 IMMERSIVE 用最精美的 EXQUISITE，
   * 否则按官方建议降级 SMOOTH（更省算力的薄档）。结果缓存，只探测一次。
   */
  static materialLevel(): hdsMaterial.MaterialLevel {
    if (TitleBarSupport.level === undefined) {
      try {
        const types: Array<hdsMaterial.MaterialType> =
          hdsMaterial.getSystemMaterialTypes();
        TitleBarSupport.level =
          types.includes(hdsMaterial.MaterialType.IMMERSIVE)
            ? hdsMaterial.MaterialLevel.EXQUISITE
            : hdsMaterial.MaterialLevel.SMOOTH;
      } catch (e) {
        TitleBarSupport.level = hdsMaterial.MaterialLevel.SMOOTH;
      }
    }
    return TitleBarSupport.level;
  }

  /**
   * 标题栏样式：材质 + 滚动时的渐次磨砂（IMMERSIVE_GRADIENT_BLUR）。
   *
   * 注意：`contentStyle.titleStyle` 只管**标题文字**，返回箭头是
   * `backIconStyle`、右侧图标菜单是 `menuStyle`——只设标题色的话，返回箭头
   * 会一直用系统默认色（浅色模式下偏白，在浅底上看不清）。
   */
  static style(titleColor: ResourceColor): TitleBarStyleOptions {
    // 返回箭头 / 菜单图标 / 标题统一同一套色，浅色深色都跟随主题。
    const iconStyle: HdsNavigationIconItemStyle = {
      iconColor: titleColor,
      textColor: titleColor,
    };
    const contentStyle: HdsTitleBarContentStyle = {
      titleStyle: { mainTitleColor: titleColor },
      backIconStyle: iconStyle,
      menuStyle: iconStyle,
    };
    // originalStyle / scrollEffectStyle 的类型是 HdsNavigationTitleBarStyle
    // （里面才装 HdsTitleBarContentStyle），别把两者搞混。
    const barStyle: HdsNavigationTitleBarStyle = { contentStyle: contentStyle };
    const style: TitleBarStyleOptions = {
      originalStyle: barStyle,
      scrollEffectStyle: barStyle,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: TitleBarSupport.materialLevel(),
      },
      blurStrategy: BlurStrategy.ADAPTIVE,
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(TITLE_BAR_CONTENT_HEIGHT),
      },
    };
    return style;
  }
}
