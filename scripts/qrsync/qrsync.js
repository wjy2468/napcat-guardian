#!/usr/bin/env node
/*
 * qrsync — 把 NapCat 不断刷新的登录二维码，变成一个"永远显示最新一版"的网页。
 *
 * 设计要点：
 *  1. 强制 no-store + 以 mtime 做 cache-buster，杜绝手机端/CDN 缓存旧码。
 *  2. 校验 PNG 签名，NapCat 覆盖写时读到半截文件就重试，不吐残缺图。
 *  3. 用 mtime 年龄判断二维码新鲜度，登录完成后 NapCat 不再写文件 -> 自动说明并退出。
 *  4. 所有路由都要带 ?k=<KEY>，错误直接 404，不给任何提示。
 *
 * 环境变量：
 *   QR_FILE      二维码路径（默认 NapCat 的 cache/qrcode.png）
 *   PORT         监听端口（默认 8430）
 *   QR_KEY       访问密钥（默认读同目录 key.txt）
 *   IDLE_EXIT_MS 二维码停止刷新多久后自动退出（默认 300000 = 5min）
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const QR_FILE = process.env.QR_FILE || 'D:/napcat/NapCat.Shell/cache/qrcode.png';
const PORT = Number(process.env.PORT || 8430);
const IDLE_EXIT_MS = Number(process.env.IDLE_EXIT_MS || 300000);
const LIVE_MS = 150000;    // 观察到 NapCat 约 2 分钟换一次码
const STALE_MS = 300000;   // 超过这个年纪 = 这张码已经不会被接受了
const USED_MS = 900000;    // 超过 15 分钟还不变 = 这张码是上次登录用的，NapCat 已登录不会再出新码

function readKey() {
  if (process.env.QR_KEY) return process.env.QR_KEY.trim();
  const f = path.join(__dirname, 'key.txt');
  try {
    const k = fs.readFileSync(f, 'utf8').trim();
    if (k) return k;
  } catch { /* 不存在就生成 */ }
  const k = crypto.randomBytes(12).toString('base64url');
  fs.writeFileSync(f, k);
  return k;
}

const KEY = readKey();

/** 常数时间比较：普通 !== 会在第一个不同的字符上提前返回，把密钥"一位一位地"漏出去。 */
function keyMatches(given) {
  if (typeof given !== 'string') return false;
  const a = Buffer.from(given, 'utf8');
  const b = Buffer.from(KEY, 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

/** 读二维码；文件正在被覆盖写时可能拿到半截，校验 PNG 头后再用。 */
function readQr() {
  for (let i = 0; i < 3; i++) {
    try {
      const b = fs.readFileSync(QR_FILE);
      if (b.length > 300 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return b;
    } catch { /* 文件暂时不存在 */ }
    const until = Date.now() + 40;
    while (Date.now() < until) { /* 40ms 忙等，比 setTimeout 少一层异步 */ }
  }
  return null;
}

const state = { seenEver: false, goneAt: 0, lastMtime: 0, lastSize: 0, refreshObserved: false, exitsAt: 0 };

// 机器人登录状态：由 D:\napcat\guardian.ps1 写入，判断"码是新的但机器人其实没登录"这类情况
const BOT_STATE_FILE = path.join(__dirname, 'login-state.json');
const BOT_STATE_STALE_MS = 15 * 60 * 1000;   // 记录超过这么久就不再当作"当前在线"
function botState() {
  try {
    const j = JSON.parse(fs.readFileSync(BOT_STATE_FILE, 'utf8'));
    const age = Date.parse(j.at);
    const ageMs = Number.isFinite(age) ? Date.now() - age : null;
    return {
      state: String(j.state || 'unknown'),
      note: String(j.note || ''),
      at: j.at || null,
      ageMs,
      // guardian 只在状态**变化**时写这个文件，所以 online 只代表"自 at 起在线"。
      // 页面必须知道记录有多旧，否则掉线半小时了还在显示"在线运行中"。
      stale: ageMs == null || ageMs > BOT_STATE_STALE_MS,
    };
  } catch { return null; }
}

// AstrBot 看护每 30 秒写一次的状态（两套服务互相独立，谁挂了都要能看见）
const ASTRBOT_STATE = path.join(__dirname, '..', 'astrbot-state.json');
function astrbot() {
  try { return JSON.parse(fs.readFileSync(ASTRBOT_STATE, 'utf8')); } catch { return null; }
}

// guardian 每 20 秒写一次的一页指标（会话时长 / 今日被踢次数 / 下次探针）
const METRICS_FILE = path.join(__dirname, '..', 'metrics.json');
function metrics() {
  try { return JSON.parse(fs.readFileSync(METRICS_FILE, 'utf8')); } catch { return null; }
}

function snapshot() {
  let st = null;
  try { st = fs.statSync(QR_FILE); } catch { st = null; }
  const now = Date.now();
  if (!st) {
    if (state.seenEver && !state.goneAt) state.goneAt = now;
    return { state: state.goneAt ? 'loggedin' : 'waiting', ageMs: null, mtime: 0, size: 0, now };
  }
  state.seenEver = true;
  state.goneAt = 0;
  if (state.lastMtime && st.mtimeMs !== state.lastMtime) state.refreshObserved = true;
  state.lastMtime = st.mtimeMs;
  state.lastSize = st.size;
  const age = now - st.mtimeMs;
  const s = age <= LIVE_MS ? 'live' : age <= STALE_MS ? 'stale' : age <= USED_MS ? 'expired' : 'used';
  return { state: s, ageMs: Math.round(age), mtime: st.mtimeMs, size: st.size, now };
}

function shutdown(why) {
  console.log(`[qrsync] 退出：${why}`);
  try { process.exit(0); } catch { /* noop */ }
}

// 每 2 秒看一次，负责"登录完成 / 二维码长期不刷新"的自动收尾。
// 只有先观察到 NapCat 确实在换码（refreshObserved），才允许用"停止刷新"推断登录完成；
// 否则一启动就因旧码过期而自杀，反而没法用。
const NO_EXIT = !!process.env.NO_EXIT;
setInterval(() => {
  const s = snapshot();
  if (NO_EXIT) return;
  if (s.state === 'loggedin' && Date.now() - state.goneAt > 15000) shutdown('二维码已被移除（通常意味着登录成功）');
  if ((s.state === 'expired' || s.state === 'used') && state.refreshObserved && s.ageMs > IDLE_EXIT_MS)
    shutdown(`二维码 ${Math.round(s.ageMs / 1000)}s 未刷新`);
}, 2000).unref();

function page() {
  return `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>NapCat 扫码登录</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0d12;
       font:15px/1.5 -apple-system,"Segoe UI",system-ui,sans-serif;color:#e7e9ee}
  .wrap{display:flex;flex-direction:column;align-items:center;gap:16px;padding:24px}
  .frame{background:#fff;padding:14px;border-radius:18px;box-shadow:0 12px 40px #0009;position:relative}
  .frame img{display:block;width:min(76vw,300px);height:auto;image-rendering:pixelated}
  .frame.dead img{filter:blur(6px);opacity:.25}
  .frame.dead::after{content:"二维码已失效";position:absolute;inset:0;display:grid;place-items:center;
       color:#111;font-weight:700;font-size:18px}
  .frame.used img{filter:blur(6px);opacity:.18}
  .frame.used::after{content:"已登录 · 此码作废";position:absolute;inset:0;display:grid;place-items:center;
       color:#111;font-weight:700;font-size:17px;padding:0 14px;text-align:center}
  .dot.used{background:#3b82f6;box-shadow:0 0 0 4px #3b82f62e}
  .status{display:flex;align-items:center;gap:8px;font-weight:600}
  .dot{width:9px;height:9px;border-radius:50%;background:#555}
  .dot.live{background:#22c55e;box-shadow:0 0 0 4px #22c55e2e}
  .dot.stale{background:#f59e0b;box-shadow:0 0 0 4px #f59e0b2e}
  .dot.loggedin{background:#3b82f6;box-shadow:0 0 0 4px #3b82f62e}
  .hint{color:#8b93a7;font-size:13px;text-align:center;max-width:22em}
  .banner{max-width:22em;text-align:center;font-size:13px;padding:8px 12px;border-radius:10px;
          background:#3a1d1d;color:#ffb4b4;border:1px solid #6b2b2b}
  .banner.ok{background:#12301d;color:#9be3b4;border-color:#245c37}
  button{margin-top:4px;background:#1b2030;color:#c9cfe0;border:1px solid #2a3245;border-radius:10px;
         padding:8px 16px;font-size:13px;cursor:pointer}
  button:active{transform:scale(.97)}
</style></head>
<body><div class="wrap">
  <div class="banner" id="b" style="display:none"></div>
  <div class="frame" id="f"><img id="q" alt="QQ 登录二维码"></div>
  <div class="status"><span class="dot" id="d"></span><span id="t">连接中…</span></div>
  <div class="hint" id="h">用手机 QQ 扫码即可登录电脑上的 NapCat 机器人</div>
  <div class="hint" id="m" style="font-size:12px;opacity:.75"></div>
  <button onclick="fetch('close?k='+K).then(()=>document.body.innerHTML='<p style=color:#8b93a7>已关闭同步</p>')">结束并关闭</button>
</div>
<script>
const K=${JSON.stringify(KEY)};
const $=id=>document.getElementById(id);
let last=0, fails=0;
async function tick(){
  try{
    const r=await fetch('status?k='+K,{cache:'no-store'});
    const s=await r.json();
    fails=0;
    $('f').classList.toggle('dead', s.state==='expired'||s.state==='loggedin');
    $('f').classList.toggle('used', s.state==='used');
    $('d').className='dot '+s.state;
    if(s.state==='live'){ $('t').textContent='二维码有效 · 每 '+Math.max(1,Math.round((s.now-s.mtime)/1000))+'s 前刚刷新'; }
    else if(s.state==='stale'){ $('t').textContent='等待 NapCat 换新码…'; }
    else if(s.state==='loggedin'){ $('t').textContent='已登录'; $('h').textContent='扫码成功，可以关闭这个页面了'; }
    else if(s.state==='expired'){ $('t').textContent='二维码已过期'; }
    else if(s.state==='used'){
      const hm=new Date(s.mtime).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'});
      $('t').textContent='这张码是 '+hm+' 的，已经用过了';
      $('h').textContent='NapCat 登录成功后就不再出新码，所以不会刷新。想重新扫码：退出机器人 QQ 或重启 NapCat，新码会自动出现在这里。';
    }
    else { $('t').textContent='等待二维码出现…'; }
    const b=s.bot, bd=$('b');
    const mins = (b && b.ageMs!=null) ? Math.round(b.ageMs/60000) : null;
    if(b && b.state!=='online'){
      const label = b.state==='need_scan' ? '⚠ 机器人尚未登录：请扫下面的码'
                  : b.state==='starting' ? '看护刚启动，正在检查登录状态…'
                  : '机器人状态：'+b.state;
      bd.textContent = label + (mins!==null && mins>0 ? '（'+mins+' 分钟前）' : '');
      bd.className='banner'; bd.style.display='';
    } else if(b && b.stale){
      // guardian 只在状态变化时写这条记录，'online' 只能说明"自 at 起在线"。
      // 记录太旧时必须说实话，否则页面会一直显示"在线运行中"，而机器人其实已经掉了。
      bd.textContent = '登录状态记录已过期（' + (mins!==null ? mins : '?') + ' 分钟前），机器人可能已掉线';
      bd.className='banner'; bd.style.display='';
    } else if(b){
      bd.textContent='机器人已登录，在线运行中';
      bd.className='banner ok'; bd.style.display='';
    } else { bd.style.display='none'; }
    const mt=s.metrics, ml=$('m');
    if(mt){
      const parts=[];
      if(mt.sessionMin>=0) parts.push('本次登录 '+mt.sessionMin+' 分钟');
      parts.push('今日被踢 '+mt.kicksToday+' 次');
      if(mt.lastRecoverSec>0) parts.push('上次恢复 '+mt.lastRecoverSec+' 秒');
      if(mt.nextProbeAt) parts.push('下次探针 '+mt.nextProbeAt);
      const ab=s.astrbot;
      if(ab){
        const ageMin=Math.round((Date.now()-Date.parse(ab.at))/60000);
        const ok=ab.state==='online'&&ab.portOk&&ageMin<=5;
        parts.push('AstrBot '+(ok?'正常':'异常('+ab.state+', '+ageMin+' 分钟前)'));
      }
      ml.textContent=parts.join(' · ');
    } else { ml.textContent=''; }
    if(s.mtime && s.mtime!==last){ last=s.mtime; $('q').src='qrcode.png?k='+K+'&t='+s.mtime; }
  }catch(e){ $('t').textContent='连接中断，重试中…'; $('d').className='dot'; }
}
tick(); setInterval(tick,1000);
</script></body></html>`;
}

function handle(req, res) {
  const u = new URL(req.url, 'http://local');
  if (!keyMatches(u.searchParams.get('k'))) {
    res.writeHead(404, { 'content-type': 'text/plain', 'cache-control': 'no-store' }).end('Not Found');
    return;
  }
  const noStore = { 'cache-control': 'no-store, no-cache, must-revalidate, max-age=0', pragma: 'no-cache', expires: '0' };

  if (u.pathname === '/qrcode.png') {
    const b = readQr();
    if (!b) return res.writeHead(503, { ...noStore, 'content-type': 'text/plain' }).end('waiting');
    return res.writeHead(200, { ...noStore, 'content-type': 'image/png', 'content-length': b.length }).end(b);
  }
  if (u.pathname === '/status') {
    const s = snapshot();
    s.bot = botState();
    s.metrics = metrics();
    s.astrbot = astrbot();
    return res.writeHead(200, { ...noStore, 'content-type': 'application/json' }).end(JSON.stringify(s));
  }
  if (u.pathname === '/close') {
    res.writeHead(200, { ...noStore, 'content-type': 'text/plain' }).end('closed');
    setTimeout(() => shutdown('调用方手动关闭'), 100);
    return;
  }
  res.writeHead(200, { ...noStore, 'content-type': 'text/html; charset=utf-8' }).end(page());
}

const server = http.createServer((req, res) => {
  // 一个畸形请求（例如 `GET http://[`）会让 new URL() 抛 ERR_INVALID_URL，
  // 在 http 回调里抛出的异常 = uncaughtException = 整个进程退出。
  // 这个端口挂着公网隧道，任何人都能发这行字节，所以必须兜住。
  try {
    handle(req, res);
  } catch (e) {
    console.error(`[qrsync] 请求处理失败 ${req.method} ${req.url}: ${e && e.message}`);
    try { res.writeHead(400, { 'content-type': 'text/plain', 'cache-control': 'no-store' }).end('Bad Request'); } catch { /* 连接已断 */ }
  }
});

server.listen(PORT, '::', () => {
  console.log(`[qrsync] listening on :${PORT}  key=${KEY.slice(0, 4)}****  qr=${QR_FILE}`);
  const s = snapshot();
  console.log(`[qrsync] 初始状态 ${s.state} age=${s.ageMs === null ? 'n/a' : s.ageMs + 'ms'}`);
});
