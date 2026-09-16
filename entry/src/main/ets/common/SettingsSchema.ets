/**
 * 设置项定义（对照安卓版 SettingsSchema.kt）。
 * 值以字符串保存；读取时缺省回落到 Schema 默认值（稀疏 TOML，只写改过的键）。
 */

/** 列表型设置的一个选项（值 → 显示名）。 */
export class ListOption {
  value: string = '';
  label: string = '';

  static of(value: string, label: string): ListOption {
    const o = new ListOption();
    o.value = value;
    o.label = label;
    return o;
  }
}

/** 一条设置。type: 'bool' | 'int' | 'list'。 */
export class Setting {
  section: string = '';
  name: string = '';
  label: string = '';
  type: string = 'bool';
  /** 默认值（统一用字符串表示，便于比较与写入）。 */
  def: string = '';
  min: number = 0;
  max: number = 0;
  options: ListOption[] = [];

  static bool(section: string, name: string, label: string,
              def: boolean): Setting {
    const s = new Setting();
    s.section = section;
    s.name = name;
    s.label = label;
    s.type = 'bool';
    s.def = def ? 'true' : 'false';
    return s;
  }

  static int(section: string, name: string, label: string, def: number,
             min: number, max: number): Setting {
    const s = new Setting();
    s.section = section;
    s.name = name;
    s.label = label;
    s.type = 'int';
    s.def = `${def}`;
    s.min = min;
    s.max = max;
    return s;
  }

  static list(section: string, name: string, label: string, def: string,
              options: ListOption[]): Setting {
    const s = new Setting();
    s.section = section;
    s.name = name;
    s.label = label;
    s.type = 'list';
    s.def = def;
    s.options = options;
    return s;
  }

  /** NAPI config 用的 "Section|name" 标签。 */
  tag(): string {
    return `${this.section}|${this.name}`;
  }
}

/** 一组设置（对应设置页里的一个分区）。 */
export class SettingsCategory {
  title: string = '';
  settings: Setting[] = [];

  static of(title: string, settings: Setting[]): SettingsCategory {
    const c = new SettingsCategory();
    c.title = title;
    c.settings = settings;
    return c;
  }
}

function opt(value: string, label: string): ListOption {
  return ListOption.of(value, label);
}

/** 内部分辨率可选值（internal_display_resolution）。 */
const DISPLAY_RESOLUTIONS: ListOption[] = [
  opt('0', '640x480'), opt('1', '640x576'), opt('2', '720x480'),
  opt('3', '720x576'), opt('4', '800x600'), opt('5', '848x480'),
  opt('6', '1024x768'), opt('7', '1152x864'), opt('8', '1280x720'),
  opt('9', '1280x768'), opt('10', '1280x960'), opt('11', '1280x1024'),
  opt('12', '1360x768'), opt('13', '1440x900'), opt('14', '1680x1050'),
  opt('15', '1920x540'), opt('16', '1920x1080'),
];

/** 用户语言（Console.user_language）。 */
const USER_LANGUAGES: ListOption[] = [
  opt('1', 'en'), opt('2', 'ja'), opt('3', 'de'), opt('4', 'fr'), opt('5', 'es'),
  opt('6', 'it'), opt('7', 'ko'), opt('8', 'zh'), opt('9', 'pt'), opt('11', 'pl'),
  opt('12', 'ru'), opt('13', 'sv'), opt('14', 'tr'), opt('15', 'nb'),
  opt('16', 'nl'), opt('17', 'zh'),
];

/** 全部设置分区（对照安卓版；Android 专属项——自定义 Vulkan 驱动/Turnip/
 *  adrenotools——未纳入，OHOS 用 ohaudio 替代 aaudio/opensles）。 */
export class SettingsSchema {
  static categories(): SettingsCategory[] {
    return [
      SettingsCategory.of('视频', [
        Setting.bool('Console', 'widescreen', '宽屏（16:9）', true),
        Setting.list('Console', 'video_standard', '视频制式', '1',
          [opt('1', 'NTSC'), opt('2', 'NTSC-J'), opt('3', 'PAL-60')]),
        Setting.list('Console', 'internal_display_resolution',
          '报告给游戏的显示模式', '8', DISPLAY_RESOLUTIONS),
        Setting.bool('Console', 'use_50Hz_mode', '使用 50Hz 模式', false),
        Setting.list('Video', 'avpack', 'AV 包', '8', [
          opt('0', 'PAL-60 Component (SD)'), opt('2', 'PAL-60 SCART'),
          opt('3', '480p Component (HD)'), opt('4', 'HDMI+A'),
          opt('5', 'PAL-60 Composite/S-Video'), opt('6', 'VGA'),
          opt('7', 'TV PAL-60'), opt('8', 'HDMI'),
        ]),
        Setting.bool('Video', 'interlaced', '隔行扫描', false),
        Setting.bool('Video', 'enable_3d_mode', '启用 3D 模式', false),
      ]),

      SettingsCategory.of('显示', [
        Setting.bool('Display', 'present_letterbox', '保持宽高比（letterbox）',
          true),
        Setting.bool('Display', 'postprocess_dither', '后处理抖动', true),
        Setting.list('Display', 'postprocess_scaling_and_sharpening',
          '缩放与锐化', '', [
            opt('bilinear', 'bilinear'), opt('cas', 'cas'), opt('fsr', 'fsr'),
          ]),
        Setting.bool('Display', 'present_render_pass_clear', '呈现前清屏', true),
        Setting.list('Display', 'postprocess_antialiasing', '抗锯齿', '', [
          opt('none', 'none'), opt('fxaa', 'fxaa'),
          opt('fxaa_extreme', 'fxaa_extreme'),
        ]),
        Setting.bool('Display', 'show_debug_overlay', '显示调试浮层', false),
      ]),

      SettingsCategory.of('图形', [
        Setting.list('GPU', 'gpu', 'GPU 后端', 'vulkan',
          [opt('vulkan', 'vulkan'), opt('null', 'null')]),
        Setting.list('GPU', 'framerate_limit', '帧率上限', '60', [
          opt('60', '60 FPS'), opt('30', '30 FPS'), opt('45', '45 FPS'),
          opt('90', '90 FPS'), opt('120', '120 FPS'), opt('0', '不限'),
        ]),
        Setting.bool('GPU', 'guest_display_refresh_cap', '限制 guest 刷新率（VSync）',
          true),
        Setting.bool('GPU', 'store_shaders', '保存着色器', true),
        Setting.list('GPU', 'readback_resolve', '回读解析模式', 'none', [
          opt('uma', 'UMA（直接映射，无拷贝）'),
          opt('fast', 'Fast（拷贝 CPU 读取的解析）'),
          opt('all', 'All（每次解析都拷贝）'),
          opt('none', 'None（关闭）'),
        ]),
        Setting.list('GPU', 'occlusion_query', '遮挡查询模式', 'fake', [
          opt('fake', 'Fake（最快，不查 GPU）'),
          opt('fast', 'Fast（异步查询，不阻塞）'),
          opt('fast-alt', 'Fast-alt（异步，精确零）'),
          opt('strict', 'Strict（真实查询，阻塞）'),
        ]),
        Setting.list('GPU', 'render_target_path', '渲染目标路径', 'performance',
          [opt('performance', 'performance'), opt('accuracy', 'accuracy')]),
        Setting.bool('GPU', 'native_2x_msaa', '原生 2x MSAA', true),
        Setting.bool('GPU', 'half_pixel_offset', '半像素偏移', true),
        Setting.bool('GPU', 'vulkan_in_pass_resolve', 'Pass 内解析 EDRAM', true),
        Setting.bool('GPU', 'vulkan_resolve_to_texture_promote',
          'Resolve-to-texture：提升', true),
        Setting.bool('GPU', 'vulkan_resolve_to_texture',
          'Resolve-to-texture：存储', true),
        Setting.bool('GPU', 'vulkan_resolve_to_texture_serve',
          'Resolve-to-texture：跳过上传', true),
        Setting.bool('GPU', 'vulkan_async_skip_draws', '异步跳过绘制', true),
        Setting.bool('GPU', 'vulkan_dynamic_pipeline_state', '扩展动态状态', true),
          Setting.int('GPU', 'vulkan_pipeline_creation_threads', '管线创建线程数',          4, 0, 5),
          // 次原生渲染：host 尺寸 = guest / 该值。
          //   1 = 原生 720p（最清晰；实测本机只能到 ~15fps）
          //   2 = 半分辨率 360p（推荐；配合系统级超分 1.5x，实测稳定 30fps）
          // X / Y 需一致，启动时两者都会按 X 的值传入（见 Home.startGame）。
          // 次原生渲染倍率：host 尺寸 = guest × 该倍率（用列表以便下拉选择）。
          //   1.0x = 原生 720p（最清晰；重场景实测约 15fps）
          //   0.5x = 半分辨率 360p（配合系统级超分，重场景可稳 30fps）
          // 只暴露一个项；启动时 X/Y 都用它的值（见 Home.startGame）。
          Setting.list('GPU', 'hx360e_render_scale_den_x', '渲染分辨率', '1', [
            opt('1', '1.0x（原生 720p）'),
            opt('2', '0.5x（半分辨率 360p）'),
            opt('3', '0.33x（720p 的三分之一）'),
          ]),
          Setting.list('Vulkan', 'hx360e_vrs_rate', 'VRS 着色率（fragment 降频）',
            'off', [
              opt('off', '关闭'), opt('1x2', '1x2'), opt('2x1', '2x1'),
              opt('2x2', '2x2（最省，最糊）'),
            ]),
          // 系统级超分：XEngine 空域超分（XEG_spatial_upscale），把 guest 输出
          // 以 1.5x 交给系统的 AI/GPU 超分再上屏。仅 Maleoon 设备可用，创建失败
          // 会自动退回 FSR 链。
          Setting.bool('Vulkan', 'hx360e_xeg_spatial_upscale',
            '系统级超分（XEngine 1.5x）', true),
          Setting.int('Vulkan', 'hx360e_xeg_spatial_upscale_sharpness',
            '系统级超分锐度（0-100）', 30, 0, 100),
          Setting.bool('GPU', 'vulkan_cache_texture_descriptors',
          '缓存纹理描述符', true),
        Setting.int('GPU', 'vulkan_mid_frame_submission_draws',
          '帧中提交（绘制数，0=关）', 1300, 0, 4096),
        Setting.int('GPU', 'texture_cache_memory_limit_soft',
          '纹理缓存软上限（MB）', 384, 384, 4096),
        Setting.int('GPU', 'texture_cache_memory_limit_hard',
          '纹理缓存硬上限（MB）', 768, 512, 4096),
        Setting.int('GPU', 'gpu_stall_spin_iterations', 'GPU 停顿自旋次数', 32, 0,
          512),
        Setting.bool('GPU', 'snorm16_render_target_full_range',
          'snorm16 渲染目标全范围', true),
        Setting.bool('GPU', 'mrt_edram_used_range_clamp_to_min',
          'MRT EDRAM 使用范围收缩到最小', true),
        Setting.bool('GPU', 'gpu_allow_invalid_fetch_constants',
          '允许无效取指常量', true),
        Setting.bool('GPU', 'non_seamless_cube_map', '非无缝立方体贴图', true),
        Setting.bool('GPU', 'depth_transfer_not_equal_test',
          '深度传输非等值测试', true),
        Setting.bool('GPU', 'force_convert_quad_lists_to_triangle_lists',
          '四边形列表转三角形列表', false),
        Setting.bool('GPU', 'execute_unclipped_draw_vs_on_cpu',
          'CPU 执行未裁剪绘制 VS', true),
        Setting.bool('GPU', 'draw_resolution_scaled_texture_offsets',
          '渲染分辨率缩放纹理偏移', true),
        Setting.bool('GPU', 'readback_memexport', '回读 memexport', false),
        Setting.bool('GPU', 'clear_memory_page_state', '清除内存页状态', false),
      ]),

      SettingsCategory.of('CPU', [
        Setting.bool('CPU', 'break_condition_truncate', '断点条件截断', true),
        Setting.bool('CPU', 'inline_mmio_access', '内联 MMIO 访问', true),
        Setting.bool('CPU', 'collapse_memory_delay_spins',
          '折叠内存延迟倒计时', true),
        Setting.bool('CPU', 'clock_no_scaling', '时钟不缩放', false),
        Setting.bool('CPU', 'clock_source_raw', '原始时钟源', false),
        Setting.bool('CPU', 'disable_context_promotion', '禁用上下文提升', false),
        Setting.bool('CPU', 'break_on_unimplemented_instructions',
          '遇到未实现指令中断', true),
        Setting.bool('CPU', 'break_on_start', '启动即中断', false),
        Setting.bool('CPU', 'store_all_context_values', '保存所有上下文值', false),
        Setting.bool('CPU', 'trace_function_references', '跟踪函数引用', false),
        Setting.bool('CPU', 'trace_function_coverage', '跟踪函数覆盖', false),
        Setting.bool('CPU', 'validate_hir', '校验 HIR', false),
      ]),

      SettingsCategory.of('内核', [
        Setting.bool('Kernel', 'staging_mode', 'Staging 模式', false),
        Setting.bool('Kernel', 'guest_scheduler', 'guest 调度器（协作式纤程）', true),
        Setting.int('Kernel', 'guest_scheduler_quantum_us',
          'guest 调度时间片（us）', 1000, 250, 8000),
        Setting.bool('Kernel', 'guest_scheduler_stats', 'guest 调度统计日志', false),
        Setting.bool('Kernel', 'ignore_thread_affinities', '忽略线程亲和性', true),
        Setting.bool('Kernel', 'ignore_thread_priorities', '忽略线程优先级', true),
        Setting.bool('Kernel', 'allow_incompatible_title_update',
          '允许不兼容的标题更新', true),
        Setting.bool('Kernel', 'apply_title_update', '应用标题更新', true),
        Setting.list('Kernel', 'kernel_display_gamma_type', '显示 gamma 类型',
          '2', [opt('0', 'linear'), opt('1', 'sRGB (CRT)'),
            opt('2', 'BT.709 (HDTV)')]),
        Setting.bool('Kernel', 'network_enabled', '网络', true),
        Setting.bool('Kernel', 'kernel_pix', 'Kernel PIX', false),
        Setting.bool('Kernel', 'kernel_cert_monitor', 'Kernel 证书监视', false),
        Setting.bool('Kernel', 'kernel_debug_monitor', 'Kernel 调试监视', false),
        Setting.bool('Logging', 'log_high_frequency_kernel_calls',
          '记录高频内核调用', false),
      ]),

      SettingsCategory.of('内存', [
        Setting.int('Memory', 'mmap_address_high', 'mmap 高位地址', 8, 2, 63),
        Setting.bool('Memory', 'protect_zero', '保护零页', true),
        Setting.bool('Memory', 'writable_executable_memory', '可写可执行内存',
          true),
        Setting.bool('Memory', 'scribble_heap', '涂鸦堆（调试）', false),
        Setting.bool('Memory', 'protect_on_release', '释放时保护', false),
        Setting.bool('Memory', 'ignore_offset_for_ranged_allocations',
          '忽略范围分配的偏移', false),
      ]),

      SettingsCategory.of('音频', [
        Setting.list('APU', 'apu', '音频后端', 'ohaudio',
          [opt('nop', 'nop（无音频）'), opt('ohaudio', 'ohaudio')]),
        Setting.bool('APU', 'enable_xmp', '启用 XMP', true),
        Setting.list('APU', 'xma_decoder', 'XMA 解码器', 'new',
          [opt('new', 'new'), opt('old', 'old'), opt('master', 'master'),
            opt('fake', 'fake')]),
        Setting.bool('APU', 'use_dedicated_xma_thread', '独立 XMA 线程', true),
        Setting.int('APU', 'xmp_default_volume', 'XMP 默认音量', 70, 0, 100),
        Setting.bool('APU', 'mute', '静音', false),
        Setting.int('APU', 'apu_max_queued_frames', '最大排队帧数', 8, 4, 64),
        Setting.bool('APU', 'apu_pump_topup', '音频泵补足', true),
        Setting.bool('APU', 'ffmpeg_verbose', 'FFmpeg 详细日志', false),
      ]),

      SettingsCategory.of('界面', [
        Setting.bool('UI', 'show_achievement_notification', '成就通知', true),
        Setting.bool('UI', 'storage_selection_dialog', '存储选择对话框', false),
        Setting.bool('UI', 'headless', '无窗口模式', true),
        Setting.bool('UI', 'android_soft_keyboard', '游戏文本输入用系统键盘',
          true),
        Setting.bool('UI', 'android_message_box', '游戏消息框用系统对话框', true),
      ]),

      SettingsCategory.of('输入', [
        Setting.bool('HID', 'show_touch_overlay', '显示屏幕手柄', true),
        Setting.list('HID', 'hid', 'HID 后端', 'nop',
          [opt('nop', 'nop'), opt('android', 'android')]),
      ]),

      SettingsCategory.of('存储', [
        Setting.bool('Storage', 'mount_scratch', '挂载 scratch', false),
        Setting.bool('Storage', 'mount_cache', '挂载 cache', false),
        Setting.list('Content', 'license_mask', '许可掩码', '0',
          [opt('0', 'disable'), opt('1', 'first'), opt('-1', 'all')]),
      ]),

      SettingsCategory.of('日志', [
        Setting.list('Logging', 'log_level', '日志级别', '1', [
          opt('0', 'error'), opt('1', 'warning'), opt('2', 'info'),
          opt('3', 'debug'),
        ]),
        Setting.bool('Logging', 'flush_log', '每次写完刷新', true),
        Setting.int('Logging', 'log_sessions_keep', '保留的历史日志会话数', 4, 1,
          16),
        Setting.bool('Logging', 'log_string_format_kernel_calls',
          '记录字符串格式化内核调用', false),
      ]),

      SettingsCategory.of('区域', [
        Setting.list('Console', 'user_language', '用户语言', '1',
          USER_LANGUAGES),
        Setting.list('Console', 'user_country', '用户国家', '103',
          [opt('1', 'US'), opt('44', 'CN'), opt('82', 'JP'), opt('86', 'GB'),
            opt('103', 'US (default)')]),
      ]),

      SettingsCategory.of('常规', [
        Setting.int('General', 'time_scalar', '时间倍率', 1, 1, 8),
        Setting.bool('General', 'allow_plugins', '允许插件', false),
        Setting.bool('General', 'apply_patches', '应用补丁', true),
      ]),
    ];
  }

  /** 拍平后的全部设置（按 tag 索引）。 */
  static allByTag(): Map<string, Setting> {
    const map = new Map<string, Setting>();
    const cats: SettingsCategory[] = SettingsSchema.categories();
    for (const cat of cats) {
      for (const s of cat.settings) {
        map.set(s.tag(), s);
      }
    }
    return map;
  }
}
