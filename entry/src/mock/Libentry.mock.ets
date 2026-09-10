const NativeMock: Record<string, Object> = {
  'jitProbe': () => {
    const okStrategy = { ok: true, errno: 0, failStep: '' };
    const failStrategy = { ok: false, errno: 13, failStep: 'mock' };
    return {
      FileMappingRxRw: okStrategy,
      FileMappingExecutable: okStrategy,
      AnonRwx: failStrategy,
      AnonRwMprotect: okStrategy,
      firstWorking: 0,
      firstWorkingName: 'FileMappingRxRw',
    };
  },
  'vulkanStatus': () => {
    return { ready: false, frames: 0, fps: 0, deviceInfo: 'mock' };
  },
};

export default NativeMock;
