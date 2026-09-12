import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 安装时的后台复制函数（taskpool 并发函数，跑在任务池线程上）。
 *
 * 参数全部用并列的基础类型数组（string[] / number[]），跨线程序列化最省，
 * 也避免自定义类实例跨线程丢原型的问题。一次调用 = 一个「批次」，
 * 批次里可以混装多个文件、也可以是一个大文件被切开的某一段：
 *   srcUris[i]   picker URI（优先用，失败退回 srcPaths[i]）
 *   srcPaths[i]  源真实路径
 *   dstPaths[i]  沙箱内目标文件（调用前已建好，所以这里不带 CREATE/TRUNC）
 *   offsets[i]   起始偏移（大文件分段复制靠它）
 *   lengths[i]   要复制的字节数
 * 返回：实际写入的字节数（用于主线程累加进度）。
 *
 * 函数体内只引用入参和字面量，不碰模块级变量/闭包，保证并发函数可正常序列化。
 */
@Concurrent
export function copyRanges(srcUris: string[], srcPaths: string[], dstPaths: string[],
                           offsets: number[], lengths: number[]): number {
  const chunkSize: number = 4 * 1024 * 1024;
  const buf: ArrayBuffer = new ArrayBuffer(chunkSize);
  let written: number = 0;
  for (let i = 0; i < dstPaths.length; i++) {
    const want: number = lengths[i];
    if (want <= 0) {
      continue;
    }
    let srcFd: number = -1;
    try {
      srcFd = fs.openSync(srcUris[i], fs.OpenMode.READ_ONLY).fd;
    } catch (e) {
      srcFd = fs.openSync(srcPaths[i], fs.OpenMode.READ_ONLY).fd;
    }
    try {
      const dstFd: number = fs.openSync(dstPaths[i], fs.OpenMode.READ_WRITE).fd;
      try {
        let done: number = 0;
        while (done < want) {
          const step: number = Math.min(chunkSize, want - done);
          const off: number = offsets[i] + done;
          const rd: number = fs.readSync(srcFd, buf, { offset: off, length: step });
          if (rd <= 0) {
            throw new Error(`read short: ${srcPaths[i]} @${off} want=${step}`);
          }
          const wr: number = fs.writeSync(dstFd, buf, { offset: off, length: rd });
          if (wr !== rd) {
            throw new Error(`write short: ${dstPaths[i]} @${off} ${wr}/${rd}`);
          }
          done += rd;
          written += rd;
        }
      } finally {
        fs.closeSync(dstFd);
      }
    } finally {
      fs.closeSync(srcFd);
    }
  }
  return written;
}
