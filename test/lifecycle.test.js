import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);

test('隔離占用：連線失敗後子程序退出，再由監督程序釋放', { skip: process.platform !== 'win32' }, async () => {
  // 全部使用本 repo 被忽略的 runtime；不啟動 Chrome、不接觸真實占用登錄。
  const dir = path.resolve('runtime', `lease-test-${process.pid}-${Date.now()}`);
  fs.mkdirSync(dir, { recursive: true });
  const quote = s => s.replaceAll("'", "''");
  const registry = path.join(dir, 'registry');
  const leaseConfig = path.join(dir, 'browser.json');
  fs.writeFileSync(leaseConfig, JSON.stringify({ allocation: { pool: ['01'], leaseSeconds: 900 }, instances: { '01': { port: 1 } } }));
  const wrapper = `param([switch]$Acquire,[switch]$Heartbeat,[switch]$Release,[switch]$Json,[string]$Owner,[string]$Instance='01',[string]$LeaseId,[int]$WorkerProcessId=0)\n. '${quote(path.resolve('browser-launcher/ai-browser-leases.ps1'))}'\n$action = if($Acquire){'Acquire'}elseif($Heartbeat){'Heartbeat'}else{'Release'}\nInvoke-AiBrowserLease -Action $action -Owner $Owner -Instance $Instance -LeaseId $LeaseId -WorkerProcessId $WorkerProcessId -StateDir '${quote(registry)}' -ConfigPath '${quote(leaseConfig)}' | ConvertTo-Json -Depth 8\n`;
  fs.writeFileSync(path.join(dir, 'ai-browser-launch.ps1'), wrapper);
  const course = path.join(dir, 'course.json');
  fs.writeFileSync(course, JSON.stringify({ platform: 'moocs', instance: '01', owner: 'isolated-test', targetId: 'test-target', courseUrl: 'https://example.org/learning/1', courseTitle: 'test', accountMarker: 'test', stopAt: new Date(Date.now() + 60000).toISOString(), stateFile: path.join(dir, 'progress.json'), chapters: ['test'], chapterIndex: 0 }));
  await assert.rejects(exec(process.execPath, ['src/runner.js', 'observe', course], {
    env: { ...process.env, PATH: `${dir};${process.env.PATH}` }, windowsHide: true, timeout: 45000
  }));
  const state = JSON.parse(fs.readFileSync(path.join(registry, 'leases.json'), 'utf8'));
  assert.deepEqual(state.leases, []);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'progress.json'), 'utf8')).status, 'stopped');
});
