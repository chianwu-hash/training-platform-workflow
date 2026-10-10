import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { lease } from './lease.js';

// 監督程序持有占用；子程序完成斷線並退出後，才可釋放登記的 PID。
const worker = fork(fileURLToPath(new URL('./cli.js', import.meta.url)), process.argv.slice(2), {
  stdio: ['inherit', 'inherit', 'inherit', 'ipc'], windowsHide: true
});
let acquired, config, pending = Promise.resolve();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => worker.kill(signal));
worker.on('message', message => {
  pending = pending.then(async () => {
    try {
      let result;
      if (message.action === 'Acquire') {
        config = message.config;
        acquired = await lease('Acquire', config);
        await lease('Heartbeat', config, acquired.LeaseId, worker.pid);
        result = acquired;
      } else if (message.action === 'Heartbeat') {
        if (!acquired || message.id !== acquired.LeaseId) throw Error('占用識別不符');
        result = await lease('Heartbeat', config, acquired.LeaseId, worker.pid);
      } else if (message.action === 'Release') {
        // 子程序仍活著時僅確認斷線流程；真實釋放放在 exit 後。
        result = { Action: 'deferred_until_worker_exit' };
      } else throw Error('未知占用操作');
      if (worker.connected) worker.send({ requestId: message.requestId, result });
    } catch (error) {
      if (worker.connected) worker.send({ requestId: message.requestId, error: error.message, busy: error.busy });
    }
  });
});
worker.on('exit', async code => {
  await pending;
  try { if (acquired) await lease('Release', config, acquired.LeaseId); }
  catch { console.error('釋放占用失敗，請核對占用狀態'); process.exitCode = 1; }
  process.exitCode ||= code ?? 1;
});
