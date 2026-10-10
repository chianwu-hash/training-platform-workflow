export function naturalEnd(video) {
  if (!video || !Number.isFinite(video.duration) || video.duration <= 0 ||
      !Number.isFinite(video.currentTime) || video.currentTime < video.duration - 0.2) return false;
  return video.ended === true || Boolean(video.endEvidence?.src === video.src &&
    Number.isFinite(video.endEvidence.time) && video.endEvidence.time >= video.duration - 0.2);
}

export function endKey(video) {
  return `${video.src}|${video.endEvidence?.at ?? 'ended'}`;
}

export function assertObservation(config, observation, state = {}) {
  if (observation.url !== config.courseUrl) throw Error('固定分頁網址已變更');
  if (!observation.courseMatched || !observation.accountMatched) throw Error('課程或帳號標示不符');
  if (observation.loginExpired) throw Error('登入已失效，請使用者處理');
  if (observation.dialogs.length) throw Error('出現提示：需先依 SOP 通知與判斷');
  if (!observation.video || !observation.video.src) throw Error('未找到唯一影片');
  if (observation.video.error) throw Error('影片載入錯誤');
  if (state.src && state.src !== observation.video.src) throw Error('影片來源與保存章節不符');
  if (state.currentTime != null && observation.video.currentTime < state.currentTime - 0.5) {
    throw Error('影片進度回退');
  }
  if (observation.video.paused && !naturalEnd(observation.video) && observation.video.currentTime > 1) {
    throw Error('已播放影片暫停，不能自行恢復');
  }
}

export function nextCheckAt(video, now, base, windowPassed = false) {
  if (video.paused || naturalEnd(video)) return now;
  const checks = [now + Math.max(0, video.duration - video.currentTime - 90) * 1000];
  if (!windowPassed && video.currentTime <= 1530) checks.push(now + Math.max(0, 1410 - video.currentTime) * 1000);
  if (!windowPassed && Number.isFinite(base) && now <= base + 1530000) checks.push(Math.max(now, base + 1410000));
  return Math.min(...checks);
}

export function validateConfig(c) {
  if (!['moocs', 'elearn'].includes(c.platform)) throw Error('平台設定不符');
  for (const key of ['instance', 'owner', 'targetId', 'courseUrl', 'courseTitle', 'accountMarker', 'stopAt', 'stateFile']) {
    if (typeof c[key] !== 'string' || !c[key] || c[key].includes('REPLACE')) throw Error(`請設定 ${key}`);
  }
  if (!['main', '01', '02'].includes(c.instance)) throw Error('未註冊的實例');
  if (!Number.isFinite(Date.parse(c.stopAt)) || !/(Z|[+-]\d\d:\d\d)$/.test(c.stopAt)) throw Error('停止期限必須包含時區');
  const url = new URL(c.courseUrl);
  if (url.protocol !== 'https:' || url.username || url.password || url.search) throw Error('課程網址不得包含查詢憑證');
  if (!Array.isArray(c.chapters) || !c.chapters.length || c.chapters.some(x => typeof x !== 'string' || !x || x.includes('REPLACE') || /100pt|未測驗/.test(x))) throw Error('請設定純影片章節');
  if (new Set(c.chapters).size !== c.chapters.length) throw Error('影片章節名稱必須唯一');
  if (!Number.isInteger(c.chapterIndex) || c.chapterIndex < 0 || c.chapterIndex >= c.chapters.length) throw Error('章節索引不符');
  c.pollMs ??= 5000;
  if (!Number.isFinite(c.pollMs) || c.pollMs < 5000 || c.pollMs > 8000) throw Error('輪詢間隔須為 5000–8000 ms');
  return c;
}
