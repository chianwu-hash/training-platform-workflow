import test from 'node:test';
import assert from 'node:assert/strict';
import { start, selectNext } from '../src/browser.js';

test('已播放暫停影片不碰播放控制', async () => {
  const page = { frames() { throw Error('不應讀取控制'); } };
  await assert.rejects(start(page, {}, async () => ({ video: { paused: true, currentTime: 30, ended: false } })), /僅可啟動/);
});
test('同名影片控制不唯一時不切章', async () => {
  let clicked = false;
  const handle = { evaluate: async () => true, click: async () => { clicked = true; } };
  const page = { frames: () => [{ $$: async () => [handle, handle] }] };
  await assert.rejects(selectNext(page, { chapterSelector: 'a' }, '影片'), /唯一辨識/);
  assert.equal(clicked, false);
});
