import puppeteer from 'puppeteer-core';
import { assertLocalEndpoint } from './lease.js';

export async function connect(config, endpoint) {
  assertLocalEndpoint(endpoint);
  const browser = await puppeteer.connect({ browserURL: endpoint, defaultViewport: null });
  try {
    const target = browser.targets().find(t => t._targetId === config.targetId);
    if (!target) throw Error('固定分頁不存在；不可自行選其他分頁');
    const page = await target.page();
    if (page.url() !== config.courseUrl) throw Error('固定分頁網址不符');
    return { browser, page };
  } catch (e) { await browser.disconnect(); throw e; }
}

export async function observe(page, config) {
  const frames = [];
  for (const frame of page.frames()) {
    frames.push(await frame.evaluate(({ videoSelector }) => {
      const text = document.body?.innerText || '';
      const visible = e => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
      const videos = [...document.querySelectorAll(videoSelector)].filter(visible);
      for (const v of videos) if (!v.__trainingObserver) {
        v.__trainingObserver = true;
        v.addEventListener('ended', () => { v.__trainingEnd = { src: v.currentSrc, time: v.currentTime, duration: v.duration, at: Date.now() }; });
      }
      const dialogs = [...document.querySelectorAll('[role=dialog],mat-dialog-container,dialog[open],.bootbox,.sweet-alert,.ui-dialog')].filter(visible).map(e => e.innerText.trim()).filter(Boolean);
      if (window.name === 's_dialog' || window.frameElement?.id === 's_dialog') {
        if (text.trim()) dialogs.push(text.trim());
      }
      return { text, dialogs, videos: videos.map(v => ({ src: v.currentSrc, currentTime: v.currentTime,
        duration: Number.isFinite(v.duration) ? v.duration : null, paused: v.paused, ended: v.ended,
        error: v.error?.message || null, endEvidence: v.__trainingEnd || null })) };
    }, { videoSelector: config.videoSelector || 'video' }));
  }
  const videos = frames.flatMap(f => f.videos);
  const texts = frames.map(f => f.text).join('\n');
  // 框架網址與整頁本文不寫入紀錄，避免登入憑證與不相關個資。
  return { at: new Date().toISOString(), url: page.url(),
    courseMatched: texts.includes(config.courseTitle), accountMatched: texts.includes(config.accountMarker),
    loginExpired: /您的驗證已經過期|請重新登入|登入逾時/.test(texts),
    dialogs: [...new Set(frames.flatMap(f => f.dialogs))], video: videos.length === 1 ? videos[0] : null };
}

export async function start(page, config, read) {
  const before = await read();
  if (!before.video.paused || before.video.currentTime > 1 || before.video.ended) throw Error('僅可啟動剛載入起點的影片');
  let found = 0;
  let button;
  for (const frame of page.frames()) {
    if (!await frame.$(config.videoSelector || 'video')) continue;
    if (config.hoverSelector) {
      const h = await frame.$(config.hoverSelector); if (!h) throw Error('找不到已設定播放器'); await h.hover();
    }
    for (const h of await frame.$$(config.playSelector)) {
      if (await h.evaluate((e, expected) => e.getClientRects().length && e.textContent.trim() === expected, config.playText)) { found++; button = h; }
    }
  }
  if (found !== 1) throw Error('未找到唯一可見播放控制');
  await button.click();
  await new Promise(r => setTimeout(r, 1500));
  const after = await read();
  if (after.video.paused || after.video.currentTime <= before.video.currentTime || after.video.src !== before.video.src) throw Error('播放未確認');
  return after;
}

export async function selectNext(page, config, title) {
  const matches = [];
  for (const frame of page.frames()) for (const h of await frame.$$(config.chapterSelector)) {
    if (await h.evaluate((e, t) => e.getClientRects().length && e.innerText.trim() === t, title)) matches.push(h);
  }
  if (matches.length !== 1) throw Error('無法唯一辨識下一影片；不得選同名測驗');
  await matches[0].click();
  await new Promise(r => setTimeout(r, 1500));
}
