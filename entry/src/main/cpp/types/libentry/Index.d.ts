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
  probeFile(path: string): string;
  /** keyIndex 见 XPadKey；value 为摇杆 [-32767,32767] 或扳机 [0,255]。 */
  keyEvent(keyIndex: number, pressed: boolean, value: number): void;
  padReleaseAll(): void;
  padStartPhysical(): boolean;
  padStopPhysical(): boolean;
}

export const jitProbe: () => JitProbeResult;
export const vulkanStatus: () => VulkanStatus;
export const attachSurface: (surfaceId: string) => boolean;
export const emulator: EmulatorApi;
