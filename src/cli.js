import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { lease } from './lease.js';
import { connect, observe, start, selectNext } from './browser.js';
import { validateConfig, assertObservation, naturalEnd, endKey, nextCheckAt } from './policy.js';

const [command, file] = process.argv.slice(2);
if (!['observe', 'watch', 'start', 'advance'].includes(command) || !file) {
  console.error('用法：npm run training -- observe|watch|start|advance local/course.json');
  process.exit(1);
}
let connection, acquired, lock, lockPath, config, state, writableState = false, cancelled = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { cancelled = true; });
const hash = value => createHash('sha256').update(value).digest('hex');
const output = data => console.log(JSON.stringify(data));
function save() {
  const temp = `${config.stateFile}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(temp, config.stateFile);
}
function deadline() {
  if (cancelled) throw Error('使用者已停止');
  if (Date.now() >= Date.parse(config.stopAt)) throw Error('已達最晚停止時間');
}
function bind(observation, previous = true) {
  assertObservation(config, observation, previous ? { currentTime: state.currentTime } : {});
  if (!Number.isFinite(observation.video.duration) || observation.video.duration <= 0) throw Error('影片長度尚未載入');
  if (previous && state.srcDigest && state.srcDigest !== hash(observation.video.src)) throw Error('影片來源與保存章節不符');
  return observation;
}
function record(o) {
  const v = o.video;
  state = { ...state, at: o.at, chapter: config.chapters[state.chapterIndex],
    srcDigest: hash(v.src), currentTime: v.currentTime, duration: v.duration, paused: v.paused, ended: v.ended,
    // 不保存來源網址、整頁本文或彈窗本文；來源只存雜湊供一致性核對。
    naturalEnd: naturalEnd(v), status: naturalEnd(v) ? 'ready_to_advance' : v.paused ? 'new_video_paused' : 'playing' };
  if (!v.paused && !state.firstPlaybackAt) state.firstPlaybackAt = o.at;
  state.nextCheckAt = new Date(nextCheckAt(v, Date.parse(o.at), Date.parse(state.lastConfirmationAt || state.courseOpenedAt), state.windowPassed)).toISOString();
  save();
}
try {
  config = validateConfig(JSON.parse(fs.readFileSync(path.resolve(file), 'utf8')));
  config.stateFile = path.resolve(config.stateFile);
  fs.mkdirSync(path.dirname(config.stateFile), { recursive: true });
  lockPath = `${config.stateFile}.lock`;
  try { lock = fs.openSync(lockPath, 'wx'); } catch { throw Error('同一狀態已有流程執行；先核對舊程序，不自動刪鎖'); }
  fs.writeSync(lock, String(process.pid));
  const binding = hash(JSON.stringify([config.platform, config.instance, config.owner, config.targetId, config.courseUrl, config.courseTitle, config.accountMarker, config.chapters]));
  state = fs.existsSync(config.stateFile) ? JSON.parse(fs.readFileSync(config.stateFile, 'utf8')) : {
    binding, chapterIndex: config.chapterIndex, completed: [], handledEnds: [], courseOpenedAt: new Date().toISOString()
  };
  if (state.binding !== binding) throw Error('設定與既有狀態不符；新課須使用新的狀態檔');
  writableState = true;
  if (state.status === 'stopped') throw Error('監看已停止；使用者確認後以新的狀態檔接續');
  deadline();
  if (state.status === 'completed') { output({ status: 'completed', note: '影片完成紀錄不代表課程通過或時數入帳' }); }
  else if (command === 'watch' && Date.parse(state.nextCheckAt) > Date.now()) {
    output({ status: 'not_due', nextCheckAt: state.nextCheckAt });
  } else {
    acquired = await lease('Acquire', config);
    // Node 本身為工作程序，先登記真實 PID，再連 CDP。
    await lease('Heartbeat', config, acquired.LeaseId, true);
    connection = await connect(config, acquired.CdpUrl);
    const read = async (previous = true) => { deadline(); return bind(await observe(connection.page, config), previous); };
    let current = await read();
    if (command === 'start') current = await start(connection.page, config, read);
    if (command === 'advance') {
      if (!naturalEnd(current.video)) throw Error('現場尚無自然播完證據');
      const key = hash(endKey(current.video));
      if (state.handledEnds.includes(key)) throw Error('此播完紀錄已處理');
      await lease('Heartbeat', config, acquired.LeaseId, true);
      if (state.chapterIndex === config.chapters.length - 1) {
        state.handledEnds.push(key); state.completed.push(config.chapters[state.chapterIndex]);
        record(current); state.status = 'completed'; state.nextCheckAt = null; save();
      } else {
        const oldSrc = current.video.src;
        await selectNext(connection.page, config, config.chapters[state.chapterIndex + 1]);
        current = await read(false);
        if (current.video.src === oldSrc) throw Error('下一影片未載入');
        state.handledEnds.push(key); state.completed.push(config.chapters[state.chapterIndex]);
        state.chapterIndex++; state.firstPlaybackAt = null; state.windowPassed = false;
        state.srcDigest = hash(current.video.src); state.currentTime = current.video.currentTime;
        if (current.video.paused && current.video.currentTime <= 1) current = await start(connection.page, config, () => read(false));
        record(current);
      }
    } else {
      record(current);
      if (command === 'watch') {
        while (!naturalEnd(current.video) && !current.video.paused && Date.parse(state.nextCheckAt) <= Date.now()) {
          // 每次只有短等待；每段瀏覽器讀取前驗證占用。
          await new Promise(r => setTimeout(r, config.pollMs));
          deadline();
          await lease('Heartbeat', config, acquired.LeaseId, true);
          current = await read();
          if (current.video.currentTime > 1530 && Date.now() > Date.parse(state.courseOpenedAt) + 1530000) state.windowPassed = true;
          record(current);
        }
      }
    }
    output({ status: state.status, chapter: state.chapter, currentTime: state.currentTime, duration: state.duration, nextCheckAt: state.nextCheckAt });
  }
} catch (error) {
  if (config && state && writableState && !error.busy) {
    state.status = 'stopped'; state.nextCheckAt = null; state.stoppedAt = new Date().toISOString();
    // 錯誤文字為固定程式訊息，不包含框架網址或原始提示內容。
    state.stopReason = error.message; save();
  }
  if (error.busy) output({ status: 'busy', nextCheckAt: state?.nextCheckAt });
  else { console.error(error.message); process.exitCode = 1; }
} finally {
  try { if (connection) await connection.browser.disconnect(); }
  finally {
    try { if (acquired) await lease('Release', config, acquired.LeaseId); }
    catch (e) { console.error('釋放占用失敗，請核對占用狀態'); process.exitCode = 1; }
    finally { if (lock !== undefined) { fs.closeSync(lock); fs.unlinkSync(lockPath); } }
  }
}
