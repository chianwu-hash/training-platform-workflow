import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
const exec = promisify(execFile);
const script = fileURLToPath(new URL('../scripts/lease.ps1', import.meta.url));

export async function lease(action, config, id, worker = false) {
  if (process.send) return new Promise((resolve, reject) => {
    const requestId = `${process.pid}-${Date.now()}-${Math.random()}`;
    const receive = message => {
      if (message.requestId !== requestId) return;
      process.off('message', receive);
      if (message.error) { const error = Error(message.error); error.busy = message.busy; reject(error); }
      else resolve(message.result);
    };
    process.on('message', receive);
    process.send({ requestId, action, config, id });
  });
  const args = ['-NoProfile', '-File', script, '-Action', action, '-Instance', config.instance, '-Owner', config.owner];
  if (id) args.push('-LeaseId', id);
  if (worker) args.push('-WorkerProcessId', String(typeof worker === 'number' ? worker : process.pid));
  let stdout;
  try { ({ stdout } = await exec(process.env.TRAINING_PWSH || 'pwsh', args, { windowsHide: true, timeout: 30000 })); }
  catch (error) {
    if (action === 'Acquire' && error.code === 2) { const busy = Error('瀏覽器忙碌，略過本次檢查'); busy.busy = true; throw busy; }
    throw Error(`瀏覽器占用 ${action} 失敗；停止操作`);
  }
  const result = JSON.parse(stdout.trim());
  if (action === 'Acquire' && (!result.LeaseId || result.Instance !== config.instance || !result.CdpUrl)) throw Error('占用回傳內容不符');
  return result;
}

export function assertLocalEndpoint(endpoint) {
  const u = new URL(endpoint);
  if (u.protocol !== 'http:' || !['localhost', '127.0.0.1', '[::1]'].includes(u.hostname) || u.username || u.password) {
    throw Error('僅允許本機註冊瀏覽器端點');
  }
}
