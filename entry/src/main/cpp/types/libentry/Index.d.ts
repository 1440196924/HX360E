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
}

export const jitProbe: () => JitProbeResult;
export const vulkanStatus: () => VulkanStatus;
export const attachSurface: (surfaceId: string) => boolean;
export const emulator: EmulatorApi;
