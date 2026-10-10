import test from 'node:test';
import assert from 'node:assert/strict';
import { naturalEnd, assertObservation, nextCheckAt, validateConfig } from '../src/policy.js';
const video = { src: 'video-a', duration: 100, currentTime: 100, ended: true, paused: true };
const config = { platform: 'moocs', instance: '01', owner: 'test-owner', targetId: 'test-target', courseUrl: 'https://example.org/learning/1', courseTitle: '課程', accountMarker: '測試帳號', stopAt: '2030-01-01T09:00:00+08:00', stateFile: 'runtime/test.json', chapters: ['影片一'], chapterIndex: 0 };
const observation = { url: config.courseUrl, courseMatched: true, accountMatched: true, loginExpired: false, dialogs: [], video };
test('估算或接近片尾不足以宣稱自然播完', () => {
  assert.equal(naturalEnd({ ...video, ended: false }), false);
  assert.equal(naturalEnd({ ...video, currentTime: 90 }), false);
  assert.equal(naturalEnd({ ...video, duration: null }), false);
});
test('來源不符的被動 ended 紀錄不能取代現場證據', () => {
  assert.equal(naturalEnd({ ...video, ended: false, endEvidence: { src: 'other', time: 100 } }), false);
  assert.equal(naturalEnd({ ...video, ended: false, endEvidence: { src: 'video-a', time: 100 } }), true);
});
test('提示、帳號錯誤、進度回退與已播放暫停都停止', () => {
  assert.throws(() => assertObservation(config, { ...observation, dialogs: ['提醒'] }));
  assert.throws(() => assertObservation(config, { ...observation, accountMatched: false }));
  assert.throws(() => assertObservation(config, { ...observation, video: { ...video, currentTime: 50 } }, { currentTime: 90 }));
  assert.throws(() => assertObservation(config, { ...observation, video: { ...video, ended: false, currentTime: 50 } }));
});
test('到 25 分鐘窗口前先檢查，窗口通過後重排片尾', () => {
  const v = { ...video, duration: 2200, currentTime: 1300, ended: false, paused: false };
  assert.equal(nextCheckAt(v, 0, 0), 110000);
  assert.equal(nextCheckAt({ ...v, currentTime: 1540 }, 1540000, 0, true), 2110000);
});
test('拒絕未填範本、無時區與查詢憑證網址', () => {
  assert.doesNotThrow(() => validateConfig(structuredClone(config)));
  assert.throws(() => validateConfig({ ...config, targetId: 'REPLACE_WITH_TARGET' }));
  assert.throws(() => validateConfig({ ...config, stopAt: '2030-01-01T09:00:00' }));
  assert.throws(() => validateConfig({ ...config, courseUrl: 'https://example.org/?token=secret' }));
});
