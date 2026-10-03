'use strict';

// Swift Video Server のブラウザ版クライアント。
//
// サーバは一覧 (/api) と動画 (HLS か MP4) を配るだけで、
// 再生と UI はすべてブラウザ側で行う。画面を映像として送るのではないので、
// 二重エンコードによる劣化も往復遅延も無い。

// ===== 共通 =====

const $ = (id) => document.getElementById(id);

async function api(path, options) {
  const res = await fetch(path, options);
  // PIN が要るのに通っていない。入力画面に戻す。
  if (res.status === 401) {
    showGate();
    throw new Error('認証が必要です');
  }
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

function formatTime(sec) {
  if (!isFinite(sec) || sec < 0) return '0:00';
  const s = Math.floor(sec % 60);
  const m = Math.floor(sec / 60) % 60;
  const h = Math.floor(sec / 3600);
  const mm = h > 0 ? String(m).padStart(2, '0') : String(m);
  return (h > 0 ? `${h}:` : '') + `${mm}:${String(s).padStart(2, '0')}`;
}

function formatSize(bytes) {
  if (!bytes) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytes, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function formatDate(value) {
  const t = Date.parse(value);
  if (!t) return '';
  const d = new Date(t);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())}`;
}

// 拡張子を動画形式として使う。判定のためにファイルを開く必要がない。
function formatKind(name) {
  const i = name.lastIndexOf('.');
  if (i <= 0 || i === name.length - 1) return '';
  return name.slice(i + 1).toUpperCase();
}

// ===== 一覧 =====

const listEl = $('list');
const titleEl = $('title');
const upEl = $('up');

const filterEl = $('filter');
const sortKeyEl = $('sortKey');
const sortDirEl = $('sortDir');
const viewModeEl = $('viewMode');

// パンくず。末尾が現在地で、null は共有フォルダ一覧を表す。
let stack = [];

// いま表示しているフォルダの中身 (絞り込み前)。
let currentItems = [];
let sortKey = 'name';
let sortAsc = true;
// 'grid' はサムネイル中心の格子、'list' は一行一件の縦並び。
// 名前が長いものは格子だと切れてしまうので、その場合はリストが読みやすい。
let viewMode = 'grid';

// 並べ替えの好みは端末ごとの都合なので localStorage に覚える。
// プライベートウィンドウなどでは読み書きが例外を投げるため、
// 取れなくても既定値で動くようにしておく。
try {
  const saved = JSON.parse(localStorage.getItem('svs.view') || '{}');
  if (saved.sortKey === 'name' || saved.sortKey === 'date') sortKey = saved.sortKey;
  if (typeof saved.sortAsc === 'boolean') sortAsc = saved.sortAsc;
  if (saved.viewMode === 'grid' || saved.viewMode === 'list') viewMode = saved.viewMode;
} catch { /* 既定のまま使う */ }

function saveView() {
  try {
    localStorage.setItem('svs.view', JSON.stringify({ sortKey, sortAsc, viewMode }));
  } catch { /* 覚えられなくても動作に影響はない */ }
}

function syncControls() {
  sortKeyEl.value = sortKey;
  sortDirEl.innerHTML = sortAsc ? '&#8593;' : '&#8595;';
  sortDirEl.title = sortAsc ? '昇順' : '降順';
  // ボタンには今の並べ方を出す。押すともう一方に変わる。
  viewModeEl.innerHTML = viewMode === 'grid' ? '&#9638;' : '&#9776;';
  viewModeEl.title = viewMode === 'grid' ? 'グリッド表示' : 'リスト表示';
  listEl.classList.toggle('as-list', viewMode === 'list');
}

// 絞り込みと並べ替えを適用して描き直す。
// サーバへの問い合わせは伴わないので、入力のたびに呼んでよい。
function applyView() {
  const q = filterEl.value.trim().toLowerCase();
  const items = currentItems.filter((i) => !q || i.name.toLowerCase().includes(q));
  const dir = sortAsc ? 1 : -1;

  items.sort((a, b) => {
    // フォルダは常に先頭側に集める。
    // 並べ替えても置き場所が動かない方が辿りやすい。
    if ((a.kind === 'folder') !== (b.kind === 'folder')) {
      return a.kind === 'folder' ? -1 : 1;
    }
    if (sortKey === 'date') {
      const d = (Date.parse(a.modified) || 0) - (Date.parse(b.modified) || 0);
      if (d !== 0) return d * dir;
    }
    // 名前順のときと、日付が同じときは名前で比べる。
    // numeric を立てて "file2" が "file10" より前に来るようにする。
    return a.name.localeCompare(b.name, 'ja', { numeric: true }) * dir;
  });

  draw(items, currentItems.length);
}

filterEl.addEventListener('input', applyView);

sortKeyEl.addEventListener('change', () => {
  sortKey = sortKeyEl.value;
  saveView();
  applyView();
});

sortDirEl.addEventListener('click', () => {
  sortAsc = !sortAsc;
  syncControls();
  saveView();
  applyView();
});

viewModeEl.addEventListener('click', () => {
  viewMode = viewMode === 'grid' ? 'list' : 'grid';
  syncControls();
  saveView();
  applyView();
});

upEl.addEventListener('click', () => {
  stack.pop();
  render();
});

async function render() {
  const here = stack[stack.length - 1];
  upEl.hidden = stack.length === 0;
  titleEl.textContent = here ? here.name : 'Swift Video Server';
  // 絞り込みはフォルダを移ると意味が変わるので、移動のたびに外す。
  filterEl.value = '';
  // 取り直しの回数はフォルダごとに数え直す。
  refreshTries = 0;
  clearTimeout(refreshTimer);
  refreshTimer = null;
  listEl.innerHTML = '<div class="empty">読み込み中…</div>';

  try {
    let items;
    if (!here) {
      const data = await api('/api/shares');
      titleEl.textContent = data.serverName || 'Swift Video Server';
      items = data.items;
    } else {
      const data = await api(`/api/list?item=${encodeURIComponent(here.id)}`);
      items = data.children;
    }
    currentItems = items || [];
    applyView();
  } catch (e) {
    listEl.innerHTML = `<div class="error">読み込めませんでした: ${e.message}</div>`;
  }
}

function draw(items, total) {
  listEl.innerHTML = '';
  if (items.length === 0) {
    listEl.innerHTML = total > 0
      ? '<div class="empty">該当するものがありません</div>'
      : '<div class="empty">動画がありません</div>';
    return;
  }

  for (const item of items) {
    listEl.appendChild(makeCard(item));
  }

  if (hasPending()) scheduleRefresh();
}

// 解析待ちの動画があるか。
function hasPending() {
  return currentItems.some((i) => i.kind === 'video' && (!i.hasSnapshot || i.duration == null));
}

function makeCard(item) {
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.id = item.id;

    const thumb = document.createElement('div');
    thumb.className = 'thumb';

    if (item.kind === 'folder') {
      thumb.innerHTML = '<span class="glyph">&#128193;</span>';
    } else if (item.hasSnapshot) {
      thumb.appendChild(makeThumb(item));
    } else {
      // サムネイルはサーバ側で生成中。出来たら一覧の取り直しで載る。
      thumb.innerHTML = '<span class="glyph">&#127916;</span>';
    }

    if (item.duration != null) {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = formatTime(item.duration);
      thumb.appendChild(badge);
    }

    const meta = document.createElement('div');
    meta.className = 'meta';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = item.name;
    const sub = document.createElement('div');
    sub.className = 'sub';
    sub.textContent = item.kind === 'folder'
      ? 'フォルダ'
      : [formatSize(item.size), item.width ? `${item.width}x${item.height}` : '']
          .filter(Boolean).join(' · ');
    meta.append(name, sub);

    // リスト表示で右端に出す欄。尺・形式・更新日を縦に積む。
    // グリッド表示では CSS で隠す (同じ内容がサムネイルの帯と sub に出る)。
    const side = document.createElement('div');
    side.className = 'side';
    const lines = item.kind === 'folder'
      ? ['フォルダ', formatDate(item.modified)]
      : [item.duration != null ? formatTime(item.duration) : '',
         formatKind(item.name),
         formatDate(item.modified)];
    for (const text of lines.filter(Boolean)) {
      const span = document.createElement('span');
      span.textContent = text;
      side.appendChild(span);
    }

    card.append(thumb, meta, side);
    card.addEventListener('click', () => {
      if (item.kind === 'folder') {
        stack.push({ id: item.id, name: item.name });
        render();
      } else {
        play(item);
      }
    });
    if (item.kind === 'video') attachDiagnoseGesture(card, side, item);
    return card;
}

// 一覧から形式を見る入口。右端の情報欄 (尺・形式・更新日) を叩くと開く。
//
// 長押しにすると iOS がテキスト選択を始めてしまい、押したつもりが
// 選択モードになる。触る場所を分けて、ただのタップで開くようにする。
// PC では右クリックでも開く (情報欄はリスト表示のときだけ出るため)。
function attachDiagnoseGesture(card, side, item) {
  side.classList.add('tappable');
  side.setAttribute('role', 'button');
  side.setAttribute('aria-label', 'この動画の形式を見る');
  side.addEventListener('click', (e) => {
    // 同じカードの click は再生なので、そちらへ渡さない。
    e.stopPropagation();
    openDiagnose(item);
  });
  card.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    openDiagnose(item);
  });
}

function makeThumb(item) {
  const img = document.createElement('img');
  img.loading = 'lazy';
  img.decoding = 'async';
  img.alt = '';
  img.src = `/api/snapshot?item=${encodeURIComponent(item.id)}&w=480`;
  // 生成が間に合っていないと 404 が返る。少し置いて一度だけ取り直す。
  img.addEventListener('error', () => {
    setTimeout(() => { img.src = img.src.split('&r=')[0] + '&r=' + Date.now(); }, 4000);
  }, { once: true });
  return img;
}

// 解析待ちがある間だけ、一覧を控えめに取り直す。
//
// 以前は一覧を丸ごと描き直していたため、そのたびに「読み込み中」が出て
// サムネイルも取り直していた。今は変わったカードだけ差し替える。
// 読めないファイルがあると永遠に揃わないので、間隔を広げつつ回数に上限を設ける。
let refreshTimer = null;
let refreshTries = 0;
const REFRESH_LIMIT = 20;

function scheduleRefresh() {
  if (refreshTimer || refreshTries >= REFRESH_LIMIT) return;
  const delay = Math.min(5000 + refreshTries * 2000, 30000);
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    refreshTries++;
    // 再生中は裏で書き換えない。閉じたときに取り直す。
    if (playerEl.hidden) refreshPending();
  }, delay);
}

async function refreshPending() {
  const here = stack[stack.length - 1];
  if (!here) return;
  let data;
  try {
    data = await api(`/api/list?item=${encodeURIComponent(here.id)}`);
  } catch { return; }
  // 取得の間に別のフォルダへ移っていたら捨てる。
  if (stack[stack.length - 1] !== here) return;

  const fresh = new Map((data.children || []).map((i) => [i.id, i]));
  currentItems = currentItems.map((old) => {
    const now = fresh.get(old.id);
    if (!now) return old;
    const changed = now.hasSnapshot !== old.hasSnapshot || now.duration !== old.duration;
    if (changed) {
      const card = listEl.querySelector(`.card[data-id="${CSS.escape(old.id)}"]`);
      if (card) card.replaceWith(makeCard(now));
    }
    return now;
  });
  if (hasPending()) scheduleRefresh();
}

// ===== プレーヤー =====

const playerEl = $('player');
const video = $('video');
const seek = $('seek');
const curEl = $('cur');
const durEl = $('dur');
const playBtn = $('playpause');
const seekHint = $('seekHint');
const spinner = $('spinner');

// スクラブ中に出すコマ画像。#seekHint の中に組み立てる。
const seekThumb = document.createElement('div');
seekThumb.id = 'seekThumb';
seekThumb.hidden = true;
const seekLabel = document.createElement('div');
seekLabel.id = 'seekLabel';
seekHint.append(seekThumb, seekLabel);

// --- 可視領域に合わせる ---
//
// ブラウザのバーがある状態でも、操作 UI と映像がちょうど収まるようにする。
// iOS Safari の position:fixed はバーを含む大きい方の領域が基準なので、
// inset: 0 に任せると下端の操作列がバーの裏に入り、指で送るとページごと動く。
// 実際に見えている範囲を visualViewport から貰い、その寸法を CSS へ渡す。
// 操作 UI の大きさもこの高さから決まるので、窓に合わせて拡大縮小する。

const viewport = window.visualViewport;

function syncViewport() {
  const h = viewport ? viewport.height : window.innerHeight;
  const top = viewport ? viewport.offsetTop : 0;
  playerEl.style.setProperty('--ph', `${Math.round(h)}px`);
  playerEl.style.setProperty('--pt', `${Math.round(top)}px`);
}

if (viewport) {
  viewport.addEventListener('resize', syncViewport);
  viewport.addEventListener('scroll', syncViewport);
}
window.addEventListener('resize', syncViewport);
// 向きの変更は、変わり終わってからでないと新しい寸法が取れない。
window.addEventListener('orientationchange', () => setTimeout(syncViewport, 300));

// HLS のときだけセッションを畳む必要がある。
let playbackId = null;
// シークバーを操作している間は再生位置で上書きしない。
let scrubbing = false;
// 再生中の動画のスプライトシート情報。まだ生成できていなければ null。
let preview = null;

// スプライトシートはサーバ側で背後で作られるため、最初の要求では
// 間に合わないことがある。その場合は間を置いて数回だけ取り直す。
async function loadPreview(itemId, attempt = 0) {
  try {
    const meta = await api(`/api/preview?item=${encodeURIComponent(itemId)}`);
    // 取得の間に別の動画へ移っていたら捨てる。
    if (currentItemId && currentItemId !== itemId) return;
    if (meta.ready) {
      // シートは粗い順に段階的に作られる。段階が進んだら画像を取り直す。
      if (!preview || preview.version !== meta.version) {
        seekThumb.style.backgroundImage =
          `url("/api/preview/sheet?item=${encodeURIComponent(itemId)}&v=${meta.version}")`;
        seekThumb.style.width = `${meta.tileWidth}px`;
        seekThumb.style.height = `${meta.tileHeight}px`;
      }
      preview = meta;
      if (meta.complete) return;
    }
  } catch { /* 生成待ち。下で取り直す */ }
  // NAS 上の大きな動画では完成まで数十秒以上かかる。以前は約 30 秒で
  // 諦めていたため、完成しても表示されなかった。再生中で同じ動画を
  // 見ている間は、間隔を広げながら問い合わせ続ける。
  if (playerEl.hidden || (currentItemId && currentItemId !== itemId) || attempt >= 80) return;
  const delay = Math.min(3000 + attempt * 1500, 15000);
  setTimeout(() => loadPreview(itemId, attempt + 1), delay);
}

// 送り先の時刻と、用意できていればその位置のコマを出す。
function updateSeekHint(target, from) {
  seekHint.hidden = false;
  const diff = (from == null) ? null : target - from;
  seekLabel.textContent = formatTime(target)
    + (diff == null ? '' : `  (${diff >= 0 ? '+' : '-'}${formatTime(Math.abs(diff))})`);

  if (!preview) { seekThumb.hidden = true; return; }
  const raw = Math.max(0, Math.min(preview.count - 1, Math.floor(target / preview.interval)));
  // 揃っているのは stride の倍数番だけ。その中で一番近いコマを出す。
  const s = preview.stride || 1;
  let i = Math.round(raw / s) * s;
  if (i > preview.count - 1) i -= s;
  const col = i % preview.columns;
  const row = Math.floor(i / preview.columns);
  seekThumb.hidden = false;
  seekThumb.style.backgroundPosition =
    `-${col * preview.tileWidth}px -${row * preview.tileHeight}px`;
}

async function play(item) {
  playerEl.hidden = false;
  // 裏の一覧が動くとプレーヤーの位置もずれるので、動かないようにする。
  document.documentElement.classList.add('playing');
  document.body.classList.add('playing');
  syncViewport();
  syncFullscreen();
  $('nowPlaying').textContent = item.name;
  spinner.hidden = false;
  preview = null;
  seekThumb.hidden = true;
  seek.value = 0;
  curEl.textContent = '0:00';
  durEl.textContent = item.duration != null ? formatTime(item.duration) : '0:00';

  hidePlayError();
  currentItem = item;
  playbackMode = null;

  try {
    const res = await api('/api/play', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item: item.id, mode: 'auto' }),
    });
    playbackId = res.kind === 'hls' ? res.playbackId : null;
    playbackMode = res.kind;
    video.src = res.url;
    loadPreview(item.id);
    currentItemId = item.id;
    restoreVrMode(item.id);
    video.play().catch((e) => {
      // 自動再生が拒まれただけなら再生ボタンを待てばよい。
      // それ以外 (対応していない形式など) は黙って黒画面になるので出す。
      if (e && e.name === 'NotAllowedError') return;
      showPlayError('再生開始', e);
    });
    showControls();
  } catch (e) {
    spinner.hidden = true;
    showPlayError('再生の要求', e);
  }
}

// ===== 再生エラーの表示 =====
//
// 黒画面のままでは、ブラウザが形式を扱えないのか、変換している ffmpeg が
// 転んだのか、NAS から読めていないのかが分からない。
// 分かることを全部並べ、そのまま診断へ進めるようにする。

const playErrorEl = $('playError');
const playErrorBody = $('playErrorBody');
// 今の再生方式。direct はブラウザが元ファイルをそのまま読む、hls は変換。
let playbackMode = null;
// 直近に出したエラーの本文。コピー用に持っておく。
let playErrorText = '';

const MEDIA_ERROR = {
  1: ['MEDIA_ERR_ABORTED', '読み込みが中断されました'],
  2: ['MEDIA_ERR_NETWORK', 'ネットワークが途切れました (サーバまで届いていません)'],
  3: ['MEDIA_ERR_DECODE', 'データは届いたがデコードできません (形式か、壊れている疑い)'],
  4: ['MEDIA_ERR_SRC_NOT_SUPPORTED', 'この形式をブラウザが扱えません'],
};

async function showPlayError(stage, cause) {
  spinner.hidden = true;

  const rows = [['つまずいた所', stage]];
  const err = video.error;
  if (err) {
    const [name, text] = MEDIA_ERROR[err.code] || ['不明', ''];
    rows.push(['ブラウザ', `${name} (code ${err.code})`]);
    if (text) rows.push(['意味', text]);
    if (err.message) rows.push(['ブラウザの説明', err.message]);
  } else if (cause) {
    rows.push(['ブラウザ', `${cause.name || 'Error'}: ${cause.message || cause}`]);
  }
  rows.push(['再生方式', playbackMode === 'hls' ? 'サーバで変換 (HLS)'
    : playbackMode === 'direct' ? 'そのまま再生 (ダイレクト)' : '開始前']);
  rows.push(['読み込み状態', `readyState ${video.readyState} / networkState ${video.networkState}`]);
  if (currentItem) rows.push(['動画', currentItem.name]);

  // 変換して再生している間は、サーバ側の ffmpeg が何を言ったかも出す。
  if (playbackId) {
    try {
      const st = await api(`/api/playback/status?playbackId=${encodeURIComponent(playbackId)}`);
      rows.push(['サーバの変換', `${st.mode} / ${st.completedSegments} 本作成済み`
        + (st.exitCode != null ? ` / 終了コード ${st.exitCode}` : '')]);
      for (const m of (st.messages || []).slice(0, 5)) rows.push(['ffmpeg', m]);
      if (!(st.messages || []).length) rows.push(['ffmpeg', '指摘はありません']);
    } catch {
      rows.push(['サーバの変換', 'セッションが見つかりません (サーバ側で畳まれた後)']);
    }
  }

  playErrorBody.innerHTML = '';
  for (const [label, value] of rows) {
    const row = document.createElement('div');
    row.className = 'row';
    const k = document.createElement('span');
    k.className = 'k';
    k.textContent = label;
    const v = document.createElement('span');
    v.className = 'v';
    v.textContent = value;
    row.append(k, v);
    playErrorBody.appendChild(row);
  }
  playErrorText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  playErrorEl.hidden = false;
}

function hidePlayError() {
  playErrorEl.hidden = true;
  playErrorText = '';
}

$('playErrorClose').addEventListener('click', hidePlayError);
$('playErrorCopy').addEventListener('click', () => copyText(playErrorText));
$('playErrorDiagnose').addEventListener('click', () => {
  if (currentItem) openDiagnose(currentItem);
});

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // クリップボードが使えない状況 (http や古い Safari) では選んで貰う。
    window.prompt('コピーしてください', text);
  }
}

// ===== 診断 =====
//
// 動画の形式をそのまま見せ、壊れていないかを ffmpeg に調べさせる。
// 再生できない動画に当たったとき、形式のせいなのかファイルが壊れているのかは
// 症状 (黒画面) が同じで区別できないため、ここで切り分ける。

const diagEl = $('diag');
const diagBody = $('diagBody');
const diagTitle = $('diagTitle');
// 今開いている動画。閉じるまで検査の状態を取り直す。
let diagItem = null;
let diagTimer = null;
let diagText = '';

async function openDiagnose(item) {
  diagItem = item;
  diagEl.hidden = false;
  diagTitle.textContent = item.name;
  diagBody.innerHTML = '<div class="note">調べています…</div>';
  await refreshDiagnose();
}

function closeDiagnose() {
  clearTimeout(diagTimer);
  diagTimer = null;
  diagEl.hidden = true;
  // 走っている検査を止める。見るのをやめた動画に ffmpeg を張り付かせない。
  if (diagItem) {
    const id = diagItem.id;
    fetch('/api/diagnose/check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item: id, cancel: true }),
    }).catch(() => { /* 止められなくても実害はない */ });
  }
  diagItem = null;
}

async function refreshDiagnose() {
  const item = diagItem;
  if (!item) return;
  let data;
  try {
    data = await api(`/api/diagnose?item=${encodeURIComponent(item.id)}`);
  } catch (e) {
    diagBody.innerHTML = `<div class="note bad">調べられませんでした: ${e.message}</div>`;
    return;
  }
  if (diagItem !== item) return;
  drawDiagnose(data);

  // 検査が走っている間だけ取り直す。
  clearTimeout(diagTimer);
  if (data.check && data.check.state === 'running') {
    diagTimer = setTimeout(refreshDiagnose, 2000);
  }
}

function drawDiagnose(d) {
  const lines = [];
  diagBody.innerHTML = '';

  const section = (title) => {
    const h = document.createElement('h3');
    h.textContent = title;
    diagBody.appendChild(h);
    lines.push(`[${title}]`);
  };
  const row = (label, value, kind) => {
    if (value === '' || value == null) return;
    const el = document.createElement('div');
    el.className = 'row' + (kind ? ` ${kind}` : '');
    const k = document.createElement('span');
    k.className = 'k';
    k.textContent = label;
    const v = document.createElement('span');
    v.className = 'v';
    v.textContent = value;
    el.append(k, v);
    diagBody.appendChild(el);
    lines.push(`${label}: ${value}`);
  };

  section('ファイル');
  row('名前', d.name);
  row('大きさ', formatSize(d.size));
  row('更新', d.modified);

  if (d.fatal) {
    section('開けません');
    row('ffprobe', d.fatal, 'bad');
  }

  const c = d.container || {};
  section('コンテナ');
  row('形式', c.format + (c.formatName ? ` (${c.formatName})` : ''));
  row('尺', c.duration ? formatTime(c.duration) : '不明');
  row('ビットレート', c.bitrate ? `${Math.round(c.bitrate / 1000)} kbps` : '');
  row('ストリーム数', c.streamCount);

  (d.video || []).forEach((v, i) => {
    section(`映像 ${i + 1}`);
    row('コーデック', v.codecLong || v.codec);
    row('プロファイル', [v.profile, v.level ? `Level ${v.level}` : ''].filter(Boolean).join(' / '));
    row('解像度', v.width ? `${v.width}x${v.height}` : '');
    row('画素形式', v.pixelFormat + (v.bitDepth ? ` (${v.bitDepth} bit)` : ''));
    row('フレームレート', v.frameRate ? `${v.frameRate.toFixed(3)} fps` : '');
    row('ビットレート', v.bitrate ? `${Math.round(v.bitrate / 1000)} kbps` : '');
    row('走査', v.fieldOrder && v.fieldOrder !== 'progressive' ? v.fieldOrder : '');
  });

  (d.audio || []).forEach((a, i) => {
    section(`音声 ${i + 1}`);
    row('コーデック', a.codecLong || a.codec);
    row('プロファイル', a.profile);
    row('チャンネル', a.channels ? `${a.channels} (${a.channelLayout || ''})`.trim() : '');
    row('サンプリング', a.sampleRate ? `${a.sampleRate} Hz` : '');
    row('ビットレート', a.bitrate ? `${Math.round(a.bitrate / 1000)} kbps` : '');
    row('言語', a.language);
  });

  if ((d.other || []).length) {
    section('その他のストリーム');
    for (const o of d.other) row(o.type, o.codec || '');
  }

  const p = d.playback || {};
  section('再生の見立て');
  row('方式', p.direct ? 'ブラウザにそのまま渡せます' : 'サーバで変換してから渡します');
  for (const r of (p.reasons || [])) row('理由', r, 'warn');

  if ((d.probeMessages || []).length) {
    section('ffprobe の指摘');
    for (const m of d.probeMessages) row('', m, 'warn');
  }

  section('壊れていないかの検査');
  const check = d.check || { state: 'none' };
  if (check.state === 'none') {
    row('状態', 'まだ調べていません');
  } else if (check.state === 'running') {
    row('状態', `検査中… (${check.depth === 'deep' ? '全編' : '先頭と末尾'}、`
      + `${Math.round(check.elapsed || 0)} 秒経過)`);
  } else {
    row('範囲', check.scope);
    row('かかった時間', `${(check.elapsed || 0).toFixed(1)} 秒`);
    row('結果', check.ok ? '異常は見つかりませんでした' : '異常があります',
        check.ok ? 'good' : 'bad');
    for (const m of (check.messages || [])) row('', m, 'bad');
  }

  diagText = lines.join('\n');
}

async function startCheck(depth) {
  if (!diagItem) return;
  try {
    await api('/api/diagnose/check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item: diagItem.id, depth }),
    });
  } catch (e) {
    diagBody.insertAdjacentHTML('beforeend',
      `<div class="note bad">検査を始められませんでした: ${e.message}</div>`);
    return;
  }
  refreshDiagnose();
}

$('diagClose').addEventListener('click', closeDiagnose);
$('diagQuick').addEventListener('click', () => startCheck('quick'));
$('diagDeep').addEventListener('click', () => startCheck('deep'));
$('diagCopy').addEventListener('click', () => copyText(diagText));
// 背景を触ったら閉じる。中身の上では閉じない。
diagEl.addEventListener('click', (e) => { if (e.target === diagEl) closeDiagnose(); });
$('info').addEventListener('click', () => { if (currentItem) openDiagnose(currentItem); });

// 閉じるときにサーバへ伝える動画。currentItemId は直後に消すので控えておく。
let stoppingItemId = null;

async function closePlayer() {
  // 全画面のまま隠すと戻り先が見えない。先に抜けてから閉じる。
  // これで全画面からでも、このボタン一つで一覧へ戻れる。
  try { await leaveFullscreen(); } catch { /* 抜けられなくてもそのまま閉じる */ }

  Vr.stop();
  vrProj.value = 'off';
  syncVrControls();
  stoppingItemId = currentItemId;
  currentItemId = null;
  currentItem = null;
  playbackMode = null;
  hidePlayError();

  video.pause();
  video.removeAttribute('src');
  video.load();
  playerEl.hidden = true;
  document.documentElement.classList.remove('playing');
  document.body.classList.remove('playing');
  spinner.hidden = true;

  // 変換中の ffmpeg とスプライト生成を止めさせる。
  // ダイレクト再生にはセッションが無いので、動画の指定も一緒に送る。
  const id = playbackId;
  const item = stoppingItemId;
  playbackId = null;
  stoppingItemId = null;
  if (id || item) {
    try {
      await fetch('/api/stop', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playbackId: id, item }),
      });
    } catch { /* 片付けはサーバ側の停止時にも行われる */ }
  }
  // 一覧はそのまま残っているので、描き直さず変わった所だけ取り直す。
  refreshPending();
}

$('close').addEventListener('click', closePlayer);

// --- 再生状態 ---

video.addEventListener('loadedmetadata', () => {
  if (isFinite(video.duration)) {
    seek.max = video.duration;
    durEl.textContent = formatTime(video.duration);
  }
});

video.addEventListener('timeupdate', () => {
  if (scrubbing) return;
  seek.value = video.currentTime;
  curEl.textContent = formatTime(video.currentTime);
});

// 停止中は操作 UI を消さない。再生に戻ったところから数え直す。
video.addEventListener('play', () => { playBtn.innerHTML = '&#10073;&#10073;'; showControls(); });
video.addEventListener('pause', () => { playBtn.innerHTML = '&#9654;'; showControls(); });
video.addEventListener('waiting', () => { spinner.hidden = false; });
video.addEventListener('playing', () => { spinner.hidden = true; });
video.addEventListener('canplay', () => { spinner.hidden = true; });
video.addEventListener('ended', closePlayer);

video.addEventListener('error', () => { showPlayError('デコード'); });

// --- 操作 ---

playBtn.addEventListener('click', () => {
  if (video.paused) video.play(); else video.pause();
});

$('back30').addEventListener('click', () => jump(-30));
$('fwd30').addEventListener('click', () => jump(30));

function jump(delta) {
  const max = isFinite(video.duration) ? video.duration : Infinity;
  video.currentTime = Math.max(0, Math.min(max - 0.5, video.currentTime + delta));
  showControls();
}

seek.addEventListener('input', () => {
  scrubbing = true;
  curEl.textContent = formatTime(Number(seek.value));
  // シークバーを掴んでいる間も同じコマ画像を出す。
  updateSeekHint(Number(seek.value));
  showControls();
});

seek.addEventListener('change', () => {
  video.currentTime = Number(seek.value);
  scrubbing = false;
  seekHint.hidden = true;
});

$('rate').addEventListener('change', (e) => {
  video.playbackRate = Number(e.target.value);
  showControls();
});

// --- 全画面 ---
//
// iPad Safari と macOS は要素フルスクリーンに対応する。
// iPhone Safari は非対応なので、その場合は動画自体を全画面にする
// (このときは OS 側の再生画面になるので、こちらの操作 UI は出ない)。
//
// 抜けるのはスワイプでもできるため、この切り替えボタンは小さいままでよい。
// 一覧へ戻るのは上段の大きなボタンで、全画面からでも一手で済む。

function fullscreenOn() {
  return !!(document.fullscreenElement || document.webkitFullscreenElement
            || video.webkitDisplayingFullscreen);
}

async function enterFullscreen() {
  if (playerEl.requestFullscreen) await playerEl.requestFullscreen();
  else if (playerEl.webkitRequestFullscreen) playerEl.webkitRequestFullscreen();
  else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
}

async function leaveFullscreen() {
  if (document.fullscreenElement && document.exitFullscreen) {
    await document.exitFullscreen();
  } else if (document.webkitFullscreenElement && document.webkitExitFullscreen) {
    document.webkitExitFullscreen();
  } else if (video.webkitDisplayingFullscreen && video.webkitExitFullscreen) {
    video.webkitExitFullscreen();
  }
}

// 全画面かどうかで画面の作りが変わる。CSS へは class で伝える。
function syncFullscreen() {
  const on = fullscreenOn();
  playerEl.classList.toggle('fs', on);
  $('full').setAttribute('aria-label', on ? '全画面を終える' : '全画面');
  syncViewport();
  showControls();
}

document.addEventListener('fullscreenchange', syncFullscreen);
document.addEventListener('webkitfullscreenchange', syncFullscreen);
video.addEventListener('webkitbeginfullscreen', syncFullscreen);
video.addEventListener('webkitendfullscreen', syncFullscreen);

$('full').addEventListener('click', async () => {
  try {
    if (fullscreenOn()) await leaveFullscreen();
    else await enterFullscreen();
  } catch { /* 拒まれたらそのまま */ }
  showControls();
});

// --- 操作 UI の自動消去 ---

let hideTimer = null;

function showControls() {
  playerEl.classList.remove('ui-hidden');
  clearTimeout(hideTimer);
  // 消すのは全画面のときだけ。
  // メニューバーがある状態では操作 UI は映像の外に並んでいるので、
  // 消しても映像は広がらず、大きさが変わって落ち着かないだけになる。
  // 停止中も消さない (操作する手掛かりが無くなるため)。
  if (fullscreenOn() && !video.paused) {
    hideTimer = setTimeout(() => playerEl.classList.add('ui-hidden'), 3000);
  }
}

// --- タップで操作 UI、ダブルタップで送り戻し ---
//
// 映像の領域だけで拾う。上段と操作列のタップはそれぞれのボタンに任せる。
// 一回目のタップは操作 UI の表示切り替え。消えていればすぐ出し、出ているときは
// 少し待ってから消す (続けてタップされたら取り消す)。
// 二回目のタップで、画面の左半分なら戻し、右半分なら送る。
// 送り戻した直後に続けてタップすると、そのたびさらに送り戻す。
// ブラウザのダブルタップ拡大は、映像の領域に touch-action: none を付けて止めている。
//
// タップでは再生・停止しない。全画面で操作 UI を出したいだけのときに
// 再生まで止まってしまい、競合するため。再生・停止は操作列のボタンで行う。

const stage = $('stage');
// 二回目のタップを待つ時間 (ミリ秒)。
const TAP_WAIT = 280;
// ダブルタップで送り戻す秒数。
const TAP_SEEK_SECONDS = 10;
let lastTapAt = 0;
let hideTapTimer = null;
let tapHintTimer = null;

stage.addEventListener('click', (e) => {
  if (e.target.closest('button, input, select')) return;
  const rect = stage.getBoundingClientRect();
  const direction = (e.clientX - rect.left) < rect.width / 2 ? -1 : 1;
  const now = performance.now();
  const second = now - lastTapAt < TAP_WAIT;
  lastTapAt = now;

  if (second) {
    // 消す予定を取り消してから送り戻す。
    clearTimeout(hideTapTimer);
    hideTapTimer = null;
    seekByTap(direction);
    return;
  }
  if (playerEl.classList.contains('ui-hidden')) {
    showControls();
  } else if (fullscreenOn()) {
    clearTimeout(hideTapTimer);
    hideTapTimer = setTimeout(() => {
      hideTapTimer = null;
      playerEl.classList.add('ui-hidden');
    }, TAP_WAIT);
  }
});

function seekByTap(direction) {
  const from = video.currentTime;
  const target = clampTime(from + direction * TAP_SEEK_SECONDS);
  video.currentTime = target;
  updateSeekHint(target, from);
  clearTimeout(tapHintTimer);
  tapHintTimer = setTimeout(() => {
    if (!scrubbing && !(touch && touch.active)) seekHint.hidden = true;
  }, 700);
  showControls();
}

// --- 左右スワイプでシーク ---

let touch = null;
// VR 表示中の二本指操作。ずらすと視点が回り、指の間隔を変えると拡大・縮小、
// ひねると視線を軸に回る。一本指はシークのまま残す。
let camera = null;

// 拡大・縮小と回転を効かせ始める変化量。ずらしている最中の指の小さなぶれで
// 意図せず拡大や回転が起きないよう、はっきり変えたときだけ効かせる。
// 一度効き始めたら、指を離すまで続けて効かせる。
const PINCH_START = Math.log(1.1);        // 指の間隔が 1 割変わったら
const TWIST_START = 10 * Math.PI / 180;   // 指の角度が 10° 変わったら

function twoFingers(e) {
  const a = e.touches[0], b = e.touches[1];
  return {
    x: (a.clientX + b.clientX) / 2,
    y: (a.clientY + b.clientY) / 2,
    dist: Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY),
    // 画面座標は下向きが正なので、時計回りに増える。
    angle: Math.atan2(b.clientY - a.clientY, b.clientX - a.clientX),
  };
}

// 角度の差を -π〜π に収める。
function angleDiff(a, b) {
  let d = a - b;
  while (d > Math.PI) d -= 2 * Math.PI;
  while (d < -Math.PI) d += 2 * Math.PI;
  return d;
}

playerEl.addEventListener('touchstart', (e) => {
  if (e.target.closest('button, input, select')) return;
  if (Vr.active && e.touches.length === 2) {
    const g = twoFingers(e);
    camera = { ...g, startDist: g.dist, startAngle: g.angle, zooming: false, twisting: false };
    touch = null;
    return;
  }
  if (e.touches.length !== 1) return;
  touch = { x: e.touches[0].clientX, y: e.touches[0].clientY, from: video.currentTime, active: false };
}, { passive: true });

playerEl.addEventListener('touchmove', (e) => {
  if (camera && e.touches.length === 2) {
    const g = twoFingers(e);
    Vr.drag(g.x - camera.x, g.y - camera.y);

    if (!camera.zooming && camera.startDist > 0
        && Math.abs(Math.log(g.dist / camera.startDist)) > PINCH_START) {
      camera.zooming = true;
    }
    if (!camera.twisting && Math.abs(angleDiff(g.angle, camera.startAngle)) > TWIST_START) {
      camera.twisting = true;
    }
    if (camera.zooming && camera.dist > 0) Vr.zoom(g.dist / camera.dist);
    if (camera.twisting) Vr.twist(angleDiff(g.angle, camera.angle));

    Object.assign(camera, { x: g.x, y: g.y, dist: g.dist, angle: g.angle });
    return;
  }
  if (!touch || e.touches.length !== 1) return;
  const dx = e.touches[0].clientX - touch.x;
  const dy = e.touches[0].clientY - touch.y;
  // 縦方向の動きが勝っているうちは画面のスクロールとみなして拾わない。
  if (!touch.active && (Math.abs(dx) < 24 || Math.abs(dx) < Math.abs(dy))) return;
  touch.active = true;

  // 画面幅いっぱいのスワイプで尺の 1/4 だけ動かす。
  const span = Math.min(video.duration || 0, 600) / 4 || 60;
  const target = clampTime(touch.from + (dx / playerEl.clientWidth) * span * 4);
  touch.target = target;

  updateSeekHint(target, touch.from);
}, { passive: true });

playerEl.addEventListener('touchend', () => {
  if (touch && touch.active && touch.target != null) {
    video.currentTime = touch.target;
    showControls();
  }
  touch = null;
  camera = null;
  seekHint.hidden = true;
}, { passive: true });

function clampTime(t) {
  const max = isFinite(video.duration) ? video.duration - 0.5 : t;
  return Math.max(0, Math.min(max, t));
}

// ===== VR =====

const vrCanvas = $('vrCanvas');
const vrProj = $('vrProj');
const vrStereo = $('vrStereo');
const vrSensor = $('vrSensor');
const vrCenter = $('vrCenter');
const vrNote = $('vrNote');

// いま再生している項目の id。投影方式を項目ごとに覚えるために使う。
let currentItemId = null;
// 再生中の動画そのもの。診断とエラー表示で名前や id を使う。
let currentItem = null;

Vr.init(video, vrCanvas, (message) => {
  vrNote.textContent = message;
  vrNote.hidden = false;
  setTimeout(() => { vrNote.hidden = true; }, 5000);
});

// 投影方式は素材ごとに決まるものなので、項目ごとに覚える。
// 同じ動画を開き直すたびに選び直すのは煩わしい。
function savedVrMode(itemId) {
  try {
    const all = JSON.parse(localStorage.getItem('svs.vr') || '{}');
    return all[itemId] || null;
  } catch { return null; }
}

function saveVrMode(itemId, mode) {
  if (!itemId) return;
  try {
    const all = JSON.parse(localStorage.getItem('svs.vr') || '{}');
    if (mode.projection === 'off') delete all[itemId];
    else all[itemId] = mode;
    localStorage.setItem('svs.vr', JSON.stringify(all));
  } catch { /* 覚えられなくても動作に影響はない */ }
}

function syncVrControls() {
  const on = vrProj.value !== 'off';
  vrStereo.hidden = !on;
  vrSensor.hidden = !on;
  vrCenter.hidden = !on;
  vrSensor.classList.toggle('on', Vr.sensorEnabled);
}

function applyVrMode() {
  Vr.setMode(vrProj.value, vrStereo.value);
  syncVrControls();
  saveVrMode(currentItemId, { projection: vrProj.value, stereo: vrStereo.value });
}

// 再生開始時に、覚えている設定を復元する。
function restoreVrMode(itemId) {
  const saved = savedVrMode(itemId);
  vrProj.value = saved ? saved.projection : 'off';
  vrStereo.value = saved ? saved.stereo : 'mono';
  Vr.setMode(vrProj.value, vrStereo.value);
  syncVrControls();
}

vrProj.addEventListener('change', () => { applyVrMode(); showControls(); });
vrStereo.addEventListener('change', () => { applyVrMode(); showControls(); });
vrCenter.addEventListener('click', () => { Vr.recenter(); showControls(); });

vrSensor.addEventListener('click', async () => {
  // iOS は利用者の操作を起点とした許可要求でないと通らない。
  await Vr.setSensor(!Vr.sensorEnabled);
  syncVrControls();
  showControls();
});

// 離脱時に変換を止めさせる。閉じ忘れで ffmpeg が回り続けるのを防ぐ。
window.addEventListener('pagehide', () => {
  if (!playbackId) return;
  const body = JSON.stringify({ playbackId });
  navigator.sendBeacon('/api/stop', new Blob([body], { type: 'application/json' }));
});

// ===== PIN =====
//
// 受け渡しは Cookie なので、いったん通れば動画やサムネイルの要求にも
// 自動で付く。トークンはサーバのメモリにしか無いため、
// サーバを止めると入力し直しになる。

const gate = $('gate');
const gateForm = $('gateForm');
const gatePin = $('gatePin');
const gateError = $('gateError');

function showGate(message) {
  gate.hidden = false;
  gateError.hidden = !message;
  if (message) gateError.textContent = message;
  gatePin.value = '';
  gatePin.focus();
}

function hideGate() {
  gate.hidden = true;
  gateError.hidden = true;
}

gateForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const pin = gatePin.value.trim();
  if (!pin) return;
  try {
    const res = await fetch('/api/auth', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin }),
    });
    if (!res.ok) {
      showGate('PIN が違います');
      return;
    }
    hideGate();
    render();
  } catch {
    showGate('サーバに接続できませんでした');
  }
});

async function start() {
  try {
    const res = await fetch('/api/session');
    const s = await res.json();
    if (s.pinRequired && !s.authenticated) {
      showGate();
      return;
    }
  } catch { /* 問い合わせられなくても一覧の取得で分かる */ }
  hideGate();
  render();
}

syncControls();
syncViewport();
start();
