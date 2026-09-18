import { UnrarApi } from '@ohos/unrar';

/**
 * taskpool 任务：解压 rar。
 *
 * 为什么不用库自带的异步接口 `UnrarApi.RarFiles_Extract`：它的实现只是
 * `unrar_napi.RarFiles_Extract(...).then(cb)`，**没有 .catch** —— 底层失败
 * （口令错、包损坏）时回调永远不触发，Promise 会一直挂着 ✗。所以走同步的
 * `extract()`，但必须放到任务池线程，否则几 GB 的包会把 UI 线程卡死。
 *
 * @return '解压成功' 表示成功；'need_password' 表示加密但没给口令；
 *         其余为失败文案。异常也归一成文案（跨线程不抛原始异常）。
 */
@Concurrent
export function extractRar(path: string, dest: string, password: string): string {
  try {
    if (password === '' && UnrarApi.isEncrypted(path) > 0) {
      return 'need_password';
    }
    const r: string = UnrarApi.extract(path, dest, password);
    return r === undefined || r === null ? '解压失败' : r;
  } catch (e) {
    return 'exception';
  }
}
