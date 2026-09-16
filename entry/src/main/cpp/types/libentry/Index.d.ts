export interface JitStrategyResult {
  ok: boolean;
  errno: number;
  failStep: string;
}

export interface JitProbeResult {
  BaselineRw: JitStrategyResult;
  AnonRwMprot: JitStrategyResult;
  FileMapRxRw: JitStrategyResult;
  AnonNoneExecMprot: JitStrategyResult;
  AnonExecRwx: JitStrategyResult;
  firstWorking: number;
  firstWorkingName: string;
}

export interface VulkanStatus {
  ready: boolean;
  frames: number;
  fps: number;
  deviceInfo: string;
}

export interface EmulatorApi {
  setupGamePath(path: string): void;
  setupLaunchArgs(args: string[]): void;
  boot(): void;
  pause(): void;
  resume(): void;
  quit(): void;
  isRunning(): boolean;
  isPaused(): boolean;
  deviceInfo(): string;
  /** XEngine Kit（Maleoon GPU 加速）特性探测；结果同时打到 hilog（HX360E）。 */
  probeXEngine(): string;
  probeFile(path: string): string;
  /** keyIndex 见 XPadKey；value 为摇杆 [-32767,32767] 或扳机 [0,255]。 */
  keyEvent(keyIndex: number, pressed: boolean, value: number): void;
  padReleaseAll(): void;
  padStartPhysical(): boolean;
  padStopPhysical(): boolean;
  changeSurface(width: number, height: number): void;
  lastFrameTimeMs(): number;
  instantFps(): number;
  averageFps(): number;
  debugOverlayText(): string;
  /** 本进程 CPU 占用（占整机百分比，0..100）。 */
  cpuUsagePercent(): number;
  /** GPU 占用百分比；不可读时为 -1（界面显示 n/a）。 */
  gpuBusyPercent(): number;
  showDebugOverlayEnabled(): boolean;
  showTouchOverlayEnabled(): boolean;
  setShowTouchOverlay(value: boolean): void;
  flushGpuCaches(): void;
}

/** TOML 配置句柄桥接（Phase 5.1）。句柄为裸指针，必须 close/free 配对。 */
export interface ConfigApi {
  open(path: string): bigint;
  openString(text: string): bigint;
  loadEntry(handle: bigint, key: string): string | null;
  saveEntry(handle: bigint, key: string, value: string): void;
  saveToFile(handle: bigint, path: string): void;
  serialize(handle: bigint): string;
  close(handle: bigint): string;
  free(handle: bigint): void;
}

/** 镜像元数据（Phase 5.2）。 */
export interface GameInfo {
  uri: string;
  name: string | null;
  titleId: string | null;
  mediaId: string | null;
  discNumber: number;
  discCount: number;
  icon?: ArrayBuffer;
}

export interface MetaApi {
  /** format: 0=ISO, 1=XEX 目录(default.xex), 2=ZAR。 */
  titleIdFromPath(path: string, format: number): string | null;
  metaFromPath(path: string, format: number): GameInfo | null;
  metaInfoFromGodPath(path: string): GameInfo | null;
}

/** Guest 提示轮询（Phase 5.3）。 */
export interface KeyboardRequest {
  id: bigint;
  title: string;
  description: string;
  defaultText: string;
  maxLength: number;
  flags: number;
}

export interface MessageBoxRequest {
  id: bigint;
  title: string;
  text: string;
  buttons: string[];
  activeButton: number;
  flags: number;
}

export interface DiscSwapRequest {
  id: bigint;
  message: string;
  isError: boolean;
  discNumber: number;
  discLabels: string[];
  discPaths: string[];
}

export interface PromptApi {
  keyboardRequest(): KeyboardRequest | null;
  keyboardSubmit(id: bigint, accepted: boolean, text: string): void;
  keyboardCancelAll(): void;
  msgboxRequest(): MessageBoxRequest | null;
  msgboxSubmit(id: bigint, button: number): void;
  msgboxCancelAll(): void;
  discRequest(): DiscSwapRequest | null;
  discSubmit(id: bigint, accepted: boolean, path: string): void;
  discCancelAll(): void;
  discSetKnown(labels: string[], paths: string[]): void;
}

/** 内容管理 / 存档（Phase 5.4）。阻塞操作应放到子线程调用。 */
export interface DiscContentItem {
  innerPath: string;
  displayName: string;
  titleId: number;
  contentType: number;
  size: number;
}

export interface ContentInfo {
  titleId: number;
  contentType: number;
  contentSize: number;
  displayName: string | null;
  icon?: ArrayBuffer;
}

export interface ContentItem {
  pkgDir: string;
  displayName: string;
  size: number;
}

export interface ProfileInfo {
  xuid: string;
  gamertag: string;
  language: number;
  country: number;
  hasAvatar: boolean;
}

export interface ContentApi {
  /** 返回 X_STATUS（0 == 成功）。 */
  compressIsoToZar(isoPath: string, outZarPath: string): number;
  compressProgress(): number;
  installContent(srcPath: string, contentRoot: string): number;
  installProgress(): number;
  listDiscContent(discPath: string): DiscContentItem[];
  installDiscContent(discPath: string, innerPath: string, contentRoot: string,
                     scratchDir: string): number;
  contentHeader(srcPath: string): ContentInfo | null;
  listContent(contentRoot: string, titleId: string,
              contentType: number): ContentItem[];
  deleteContent(contentRoot: string, titleId: string, contentType: number,
                pkgDir: string): number;
  createProfile(contentRoot: string, gamertag: string, language: number,
                country: number): string | null;
  listProfiles(contentRoot: string): ProfileInfo[];
  renameProfile(contentRoot: string, xuid: string, gamertag: string,
                language: number, country: number): number;
}

/** ZIP 解压任务的状态快照（ArkTS 侧轮询用）。 */
export interface ZipPollResult {
  /** 是否有任务在跑。 */
  active: boolean;
  finished: boolean;
  /** 已写出 / 总解压字节数。 */
  done: number;
  total: number;
  /** 当前正在解压的条目名。 */
  name: string;
  ok: boolean;
  files: number;
  /** 失败原因（可直接显示）。 */
  error: string;
  /** 包内有加密项但没有密码 → 需要弹密码框。 */
  needPassword: boolean;
  /** 给了密码但校验不过。 */
  badPassword: boolean;
  canceled: boolean;
}

export interface ZipApi {
  /** 启动解压任务，返回非空句柄表示已启动（同一时刻只允许一个）。 */
  extractStart(zipPath: string, destDir: string, password: string): string;
  /** 轮询任务状态。 */
  extractPoll(): ZipPollResult;
  /** 请求取消（解压器在下一块检查）。 */
  extractCancel(): void;
  /** 收尾：等后台线程结束并释放任务。 */
  extractFinish(): void;
}

export const jitProbe: () => JitProbeResult;
export const vulkanStatus: () => VulkanStatus;
export const attachSurface: (surfaceId: string) => boolean;
export const emulator: EmulatorApi;
export const config: ConfigApi;
export const meta: MetaApi;
export const prompt: PromptApi;
export const content: ContentApi;
export const zip: ZipApi;
