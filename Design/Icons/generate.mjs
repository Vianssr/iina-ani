import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// SVG geometry is the source of truth. Sharp is only used for PNG exports.
const require = createRequire(import.meta.url);
const sharp = require(process.env.ICON_NODE_MODULES
  ? path.join(process.env.ICON_NODE_MODULES, 'sharp') : 'sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const catalog = path.resolve(root, '../../IINA-ANI/Assets/Assets.xcassets/FunctionIcons');
const p = d => `<path d="${d}"/>`;
const l = (x1, y1, x2, y2) => `<path d="M${x1} ${y1}L${x2} ${y2}"/>`;
const c = (cx, cy, r) => `<circle cx="${cx}" cy="${cy}" r="${r}"/>`;
const r = (x, y, w, h, rx = 2) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}"/>`;
const dot = (cx, cy, radius = 0.9) => `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="currentColor" stroke="none"/>`;

const groups = [
  { name: '探索與導航', en: 'EXPLORE', icons: [
    ['discover', '發現', c(12, 12, 8.5) + p('M15.8 8.2L13.5 13.5L8.2 15.8L10.5 10.5Z')],
    ['search', '搜尋', c(10.5, 10.5, 6.75) + l(15.5, 15.5, 20.25, 20.25)],
    ['calendar', '放送日曆', r(3.5, 5, 17, 15.5, 2.75) + p('M7.5 3.5V7M16.5 3.5V7M3.5 10H20.5') + dot(8, 14) + dot(12, 14) + dot(16, 14) + dot(8, 17.5) + dot(12, 17.5)],
    ['favorites', '作品收藏', p('M12 20L4.4 12.8C.2 8.4 6.3 1.5 12 7.3C17.7 1.5 23.8 8.4 19.6 12.8Z')],
    ['history', '繼續觀看', p('M3.75 8.25A8.5 8.5 0 1 1 3.5 15M3.75 3.75V8.25H8.25M12 7.5V12L15 14')],
    ['downloads', '下載任務', p('M12 3.5V15M7.75 10.75L12 15L16.25 10.75M4 15.5V18.5A2 2 0 0 0 6 20.5H18A2 2 0 0 0 20 18.5V15.5')],
    ['settings', '設定', p('M9.9 3.9H14.1L14.5 5.9L16 6.8L18 6.2L20.1 9.8L18.5 11.1V12.9L20.1 14.2L18 17.8L16 17.2L14.5 18.1L14.1 20.1H9.9L9.5 18.1L8 17.2L6 17.8L3.9 14.2L5.5 12.9V11.1L3.9 9.8L6 6.2L8 6.8L9.5 5.9Z') + c(12, 12, 3.05)],
    ['open-link', '開啟網址', p('M13 4H20V11M20 4L10.5 13.5M9 4H6A2 2 0 0 0 4 6V18A2 2 0 0 0 6 20H18A2 2 0 0 0 20 18V15')],
  ]},
  { name: '播放與彈幕', en: 'PLAYBACK', icons: [
    ['play', '播放', p('M8 4.5L20 12L8 19.5Z')],
    ['pause', '暫停', r(6, 4.5, 3.75, 15, 1.2) + r(14.25, 4.5, 3.75, 15, 1.2)],
    ['stop', '停止', r(5, 5, 14, 14, 2.5)],
    ['next', '下一集', p('M5.5 5L15.5 12L5.5 19ZM19 5V19')],
    ['playlist', '播放列表', p('M4 5.5H20M4 11.5H13M4 17.5H10M16.5 13.5L21 16.5L16.5 19.5Z')],
    ['danmaku', '彈幕', r(3, 4.5, 18, 15, 3) + p('M7 8.75H12.5M16 8.75H17M7 12.25H9M12.5 12.25H17M7 15.75H14')],
    ['subtitles', '字幕', r(3, 4.5, 18, 15, 3) + p('M6.75 11.75H11M13.75 11.75H17.25M6.75 15.5H17.25')],
    ['live', '直播', c(12, 12, 2.25) + p('M7.5 7.5A6.36 6.36 0 0 0 7.5 16.5M16.5 7.5A6.36 6.36 0 0 1 16.5 16.5M5 5A9.9 9.9 0 0 0 5 19M19 5A9.9 9.9 0 0 1 19 19')],
  ]},
  { name: '內容與來源', en: 'LIBRARY', icons: [
    ['work', '作品詳情', r(5, 3, 14, 18, 2.5) + p('M10 8L15.5 11.5L10 15ZM9 18H15')],
    ['episodes', '選集', r(3.5, 3.5, 6.5, 6.5, 1.75) + r(14, 3.5, 6.5, 6.5, 1.75) + r(3.5, 14, 6.5, 6.5, 1.75) + r(14, 14, 6.5, 6.5, 1.75)],
    ['bookmark', '連結收藏', p('M7 3.5H17A1.5 1.5 0 0 1 18.5 5V21L12 16.5L5.5 21V5A1.5 1.5 0 0 1 7 3.5Z')],
    ['sync', '收藏同步', p('M4 9A8.25 8.25 0 0 1 18.4 6.4L20.5 8.5M20.5 3.75V8.5H15.75M20 15A8.25 8.25 0 0 1 5.6 17.6L3.5 15.5M3.5 20.25V15.5H8.25')],
    ['source', '播放來源', c(5.5, 5.5, 2) + c(18.5, 7, 2) + c(11.5, 19, 2) + p('M7.5 5.75L16.5 6.75M6.3 7.35L10.7 17.15M17.5 8.75L12.5 17.25')],
    ['subscription', '來源訂閱', p('M5 11.5A7.5 7.5 0 0 1 12.5 19M5 4.5A14.5 14.5 0 0 1 19.5 19') + dot(5.5, 18.5, 1.5)],
    ['account', '帳號', c(12, 7.5, 4) + p('M4.5 20V18.5A5.5 5.5 0 0 1 10 13H14A5.5 5.5 0 0 1 19.5 18.5V20')],
    ['quality', '畫質', r(3, 4.5, 18, 15, 3) + p('M11.25 7.5L12.55 10.45L15.5 11.75L12.55 13.05L11.25 16L9.95 13.05L7 11.75L9.95 10.45ZM17 7.5V10M15.75 8.75H18.25')],
  ]},
  { name: '下載與外觀', en: 'TOOLS', icons: [
    ['torrent', 'BT 傳輸', c(5, 5.5, 2) + c(19, 18.5, 2) + p('M7 5.5H16.5A2.5 2.5 0 0 1 19 8V11M16 8L19 11L22 8M17 18.5H7.5A2.5 2.5 0 0 1 5 16V13M2 16L5 13L8 16')],
    ['magnet', '磁力連結', p('M4.5 4.5H9V12A3 3 0 0 0 15 12V4.5H19.5V12A7.5 7.5 0 0 1 4.5 12ZM4.5 8.5H9M15 8.5H19.5')],
    ['folder', '本地檔案', p('M3 7V18A2 2 0 0 0 5 20H19A2 2 0 0 0 21 18V9A2 2 0 0 0 19 7H11L8.5 4.5H5A2 2 0 0 0 3 6.5ZM3 9.5H21')],
    ['import', '匯入', p('M14 4H18A2 2 0 0 1 20 6V18A2 2 0 0 1 18 20H14M3.5 12H14.5M10 7.5L14.5 12L10 16.5')],
    ['export', '匯出', p('M10 4H6A2 2 0 0 0 4 6V18A2 2 0 0 0 6 20H10M9.5 12H20.5M16 7.5L20.5 12L16 16.5')],
    ['appearance', '外觀主題', p('M20.5 11.5C20.5 6.8 16.7 3.5 12 3.5A8.5 8.5 0 0 0 12 20.5H13.2A2 2 0 0 0 14.7 17.2A1.7 1.7 0 0 1 16 14.4H17.5A3 3 0 0 0 20.5 11.5Z') + dot(7.5, 10, 1) + dot(11.5, 7.25, 1) + dot(16, 9, 1) + dot(7.5, 15, 1)],
    ['layout', '佈局編排', r(3, 4, 18, 16, 2.5) + p('M9.5 4V20M9.5 11.5H21')],
    ['delete', '刪除', p('M3.5 6.5H20.5M9 6.5V3.5H15V6.5M5.5 6.5L6.5 19A1.5 1.5 0 0 0 8 20.5H16A1.5 1.5 0 0 0 17.5 19L18.5 6.5M9.5 10V17M14.5 10V17')],
  ]},
  { name: '通用操作', en: 'ACTIONS', icons: [
    ['add', '新增', p('M12 4.5V19.5M4.5 12H19.5')],
    ['close', '關閉', p('M6 6L18 18M18 6L6 18')],
    ['check', '完成', p('M4.5 12L9.5 17L19.5 7')],
    ['back', '返回', p('M10 5L3 12L10 19M3 12H21')],
    ['refresh', '重新整理', p('M4 9A8.25 8.25 0 1 1 4.5 16.25M4 4.5V9H8.5')],
    ['filter', '篩選', p('M4 6H20L14 13V19L10 21V13Z')],
    ['sort', '排序', p('M7 4V20M3.5 16.5L7 20L10.5 16.5M13 5H21M13 10H19M13 15H17')],
    ['info', '關於', c(12, 12, 8.5) + p('M12 11V16') + dot(12, 7.5, 1)],
  ]},
];

const esc = s => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
function svg(body, { color = 'currentColor', title = '', size = 24 } = {}) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"${title ? ' role="img"' : ' aria-hidden="true"'}>${title ? `<title>${esc(title)}</title>` : ''}${body}</svg>\n`;
}

const palettes = {
  light: { bg: '#F6F7F9', fg: '#202A35', muted: '#73808E', line: '#DCE2E8', accent: '#087F72', panel: '#E5F1EE' },
  dark: { bg: '#12181F', fg: '#E8EDF2', muted: '#96A4B3', line: '#303B47', accent: '#7DE0C8', panel: '#203C3A' },
};

function board(theme) {
  const t = palettes[theme];
  const font = "'PingFang TC', 'Noto Sans CJK TC', sans-serif";
  const text = (x, y, value, size, color = t.fg, weight = 400, extra = '') => `<text x="${x}" y="${y}" fill="${color}" font-family="${font}" font-size="${size}" font-weight="${weight}" ${extra}>${esc(value)}</text>`;
  let body = `<rect width="1600" height="1500" fill="${t.bg}"/>`;
  body += text(64, 64, 'IINA-ANI', 24, t.fg, 650);
  body += text(1536, 63, 'FUNCTION ICONS / 01', 14, t.muted, 500, 'text-anchor="end" letter-spacing="2"');
  body += `<path d="M64 90H1536" stroke="${t.line}"/>`;
  body += text(64, 162, '功能，清晰可見。', 48, t.fg, 600);
  body += text(66, 206, '40 個圓角線性圖標，為探索、播放與日常追番而設。', 19, t.muted);
  body += text(66, 246, '24 × 24 GRID    /    1.75 px STROKE    /    SVG + PNG    /    TEMPLATE READY', 13, t.muted, 500);
  for (const [i, id] of ['discover', 'play', 'danmaku'].entries()) {
    const x = 1268 + i * 96;
    const icon = groups.flatMap(g => g.icons).find(a => a[0] === id);
    body += `<rect x="${x}" y="128" width="76" height="76" rx="22" fill="${t.panel}"/>`;
    body += `<g transform="translate(${x + 17} 145) scale(1.75)" fill="none" stroke="${t.accent}" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" color="${t.accent}">${icon[2]}</g>`;
  }
  groups.forEach((group, row) => {
    const y = 308 + row * 218;
    body += `<path d="M64 ${y}H1536" stroke="${t.line}"/>`;
    body += text(64, y + 32, `0${row + 1}`, 13, t.accent, 600);
    body += text(100, y + 33, group.name, 16, t.fg, 600);
    body += text(1536, y + 32, group.en, 12, t.muted, 500, 'text-anchor="end" letter-spacing="2"');
    group.icons.forEach(([id, label, shape], col) => {
      const x = 64 + col * 184 + 84;
      body += `<g transform="translate(${x - 21} ${y + 65}) scale(1.75)" fill="none" stroke="${t.fg}" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" color="${t.fg}">${shape}</g>`;
      body += text(x, y + 142, label, 16, t.fg, 500, 'text-anchor="middle"');
      body += text(x, y + 168, id, 12, t.muted, 400, 'text-anchor="middle"');
    });
  });
  body += `<path d="M64 1410H1536" stroke="${t.line}"/>`;
  body += text(64, 1454, 'IINA-ANI  /  功能圖標資產', 13, t.muted);
  body += text(1536, 1454, 'ROUND CAPS · OPTICAL ALIGNMENT · TRANSPARENT EXPORTS', 12, t.muted, 500, 'text-anchor="end" letter-spacing="1"');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1500" viewBox="0 0 1600 1500">${body}</svg>`;
}

function previewHTML() {
  const sections = groups.map((g, i) => `<section><header><h2><span>0${i + 1}</span>${g.name}</h2><small>${g.en}</small></header><div class="grid">${g.icons.map(([id, label, body]) => `<button class="icon" type="button" data-id="${id}" data-search="${id} ${label}" title="複製素材名稱 ani-${id}"><span class="glyph">${svg(body)}</span><strong>${label}</strong><code>${id}</code></button>`).join('')}</div></section>`).join('');
  return `<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>IINA-ANI 功能圖標</title>
<style>
:root{color-scheme:light;--bg:#f6f7f9;--fg:#202a35;--muted:#73808e;--line:#dce2e8;--accent:#087f72;--hover:#e5f1ee;--size:32px}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,BlinkMacSystemFont,'PingFang TC',sans-serif}body.dark{color-scheme:dark;--bg:#12181f;--fg:#e8edf2;--muted:#96a4b3;--line:#303b47;--accent:#7de0c8;--hover:#203c3a}main{max-width:1400px;margin:auto;padding:32px 40px 48px}.masthead{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line);padding-bottom:20px;font-weight:650;letter-spacing:.04em}.masthead small{font-weight:500;font-size:11px;color:var(--muted);letter-spacing:.14em}h1{font-size:clamp(30px,5vw,46px);letter-spacing:-.04em;margin:42px 0 12px}p{color:var(--muted);line-height:1.8;margin:0}nav{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin:28px 0 32px}input,select,nav button{font:inherit;border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:10px;padding:9px 12px}input{flex:1;min-width:170px}select{cursor:pointer}nav button{cursor:pointer}nav label{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--muted)}input[type=color]{width:38px;min-width:38px;height:38px;padding:4px;flex:none;cursor:pointer}section{border-top:1px solid var(--line);margin-top:20px}header{display:flex;align-items:center;justify-content:space-between;padding:20px 0 12px}h2{font-size:15px;margin:0;font-weight:600}h2 span{color:var(--accent);font-size:12px;padding-right:18px}header small{color:var(--muted);font-size:10px;letter-spacing:.15em}.grid{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:6px}.icon{background:none;color:var(--fg);border:0;border-radius:14px;min-height:155px;padding:20px 5px;cursor:pointer;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px}.icon:hover{background:var(--hover)}.icon:focus-visible,button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:3px}.glyph{display:grid;place-items:center;width:64px;height:52px;color:var(--icon-color,var(--fg))}.glyph svg{width:var(--size);height:var(--size);flex-shrink:0}.icon strong{font-size:13px;font-weight:500}.icon code{font:11px ui-monospace,monospace;color:var(--muted)}footer{margin-top:36px;padding-top:20px;border-top:1px solid var(--line);font-size:12px;display:flex;justify-content:space-between;gap:20px;color:var(--muted)}[hidden]{display:none!important}#status{min-height:24px;font-size:13px;color:var(--accent)}@media(max-width:900px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}main{padding:24px}}@media(max-width:480px){.grid{grid-template-columns:repeat(3,minmax(0,1fr))}.masthead small{display:none}footer{flex-direction:column}.icon{min-height:140px}}
</style></head><body><main>
<div class="masthead"><span>IINA-ANI</span><small>FUNCTION ICONS / 01</small></div>
<h1>功能，清晰可見。</h1><p>40 個圓角線性圖標 · 24 × 24 網格 · 1.75 px 線寬 · 點選圖標可複製 Xcode 素材名稱</p>
<nav aria-label="預覽控制"><input id="search" type="search" placeholder="搜尋圖標，例如：彈幕、torrent" aria-label="搜尋圖標"><label>尺寸<select id="size"><option>16</option><option>20</option><option>24</option><option selected>32</option><option>48</option></select></label><label>顏色<input id="color" type="color" value="#202a35" aria-label="圖標顏色"></label><button id="reset" type="button">重設顏色</button><button id="theme" type="button" aria-pressed="false">深色預覽</button></nav>
<div id="status" role="status" aria-live="polite"></div>${sections}
<footer><span>原始 SVG 與透明 PNG 已隨附，Xcode 素材採 Template 著色。</span><span>IINA-ANI · 2026</span></footer></main>
<script>
const $=id=>document.getElementById(id);
$('search').addEventListener('input',e=>{const q=e.target.value.toLowerCase().trim();document.querySelectorAll('.icon').forEach(el=>el.hidden=!el.dataset.search.toLowerCase().includes(q));document.querySelectorAll('section').forEach(s=>s.hidden=![...s.querySelectorAll('.icon')].some(el=>!el.hidden));});
$('size').addEventListener('change',e=>document.documentElement.style.setProperty('--size',e.target.value+'px'));
$('color').addEventListener('input',e=>document.documentElement.style.setProperty('--icon-color',e.target.value));
$('reset').addEventListener('click',()=>{document.documentElement.style.removeProperty('--icon-color');$('color').value=document.body.classList.contains('dark')?'#e8edf2':'#202a35';});
$('theme').addEventListener('click',()=>{const dark=document.body.classList.toggle('dark');$('theme').setAttribute('aria-pressed',String(dark));$('theme').textContent=dark?'淺色預覽':'深色預覽';if(!document.documentElement.style.getPropertyValue('--icon-color'))$('color').value=dark?'#e8edf2':'#202a35';});
document.querySelectorAll('.icon').forEach(el=>el.addEventListener('click',async()=>{const name='ani-'+el.dataset.id;try{await navigator.clipboard.writeText(name);$('status').textContent='已複製：'+name;}catch{$('status').textContent='素材名稱：'+name;}}));
</script></body></html>\n`;
}

await fs.mkdir(catalog, { recursive: true });
await fs.mkdir(path.join(root, 'svg'), { recursive: true });
await fs.writeFile(path.join(catalog, 'Contents.json'), JSON.stringify({ info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
const manifest = { name: 'IINA-ANI Function Icons', version: 1, grid: 24, strokeWidth: 1.75, linecap: 'round', linejoin: 'round', assetPrefix: 'ani-', icons: [] };
for (const group of groups) {
  for (const [id, label, body] of group.icons) {
    const asset = `ani-${id}`;
    await fs.writeFile(path.join(root, 'svg', `${id}.svg`), svg(body, { title: label }));
    const native = svg(body.replaceAll('currentColor', '#000000'), { color: '#000000' });
    const imageset = path.join(catalog, `${asset}.imageset`);
    await fs.mkdir(imageset, { recursive: true });
    await fs.writeFile(path.join(imageset, `${asset}.svg`), native);
    await fs.writeFile(path.join(imageset, 'Contents.json'), JSON.stringify({
      images: [{ filename: `${asset}.svg`, idiom: 'universal' }],
      info: { author: 'xcode', version: 1 },
      properties: { 'preserves-vector-representation': true, 'template-rendering-intent': 'template' },
    }, null, 2) + '\n');
    for (const size of [24, 48, 96]) {
      const output = path.join(root, 'png', String(size));
      await fs.mkdir(output, { recursive: true });
      await sharp(Buffer.from(native), { density: 72 * size / 24 }).resize(size, size).png().toFile(path.join(output, `${id}.png`));
    }
    manifest.icons.push({ id, label, category: group.name, asset, svg: `svg/${id}.svg` });
  }
}
await fs.writeFile(path.join(root, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
await fs.writeFile(path.join(root, 'preview.html'), previewHTML());
for (const theme of ['light', 'dark']) {
  const source = board(theme);
  await fs.writeFile(path.join(root, `preview-${theme}.svg`), source + '\n');
  await sharp(Buffer.from(source)).png().toFile(path.join(root, `preview-${theme}.png`));
}
console.log(`Exported ${manifest.icons.length} SVGs, ${manifest.icons.length * 3} PNGs, 40 Xcode image sets, and previews.`);
