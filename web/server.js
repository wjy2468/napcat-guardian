#!/usr/bin/env node
/*
 * NapCat Web 控制台 —— 给 Windows 上的 NapCat 守护项目做一个公网可访问的中文面板。
 *
 * 设计要点（和 qrsync.js 保持一致的取舍）：
 *  1. 零依赖：只用 Node 内置模块（http / fs / path / crypto / child_process）。
 *  2. 只读生产数据：metrics.json、kick.log、各类 state 文件全部只读，绝不写入。
 *  3. 鉴权：URL 带 ?k=<key>。校验通过后种一个 HttpOnly 会话 Cookie，
 *     后续轮询不再把 key 放进 URL / Referer；页面源码里也没有 key。
 *     任何未授权的请求一律 404，不给探测者任何提示。
 *  4. 脱敏：返回值里绝不出现 QQ 号、邮箱、WebUI token、ngrok authToken、访问 key。
 *     所有来自日志的自由文本都过一遍 scrub()，日志里夹带的 ?k=... 也会被抹掉。
 *  5. 受保护动作只走"既有脚本 / flag 文件 / NapCat 自己的 WebUI API"：
 *     本服务不杀任何进程，重启一律交给 guardian.ps1 或 NapCat 自身。
 *
 * 环境变量（都可选）：
 *   PORT                监听端口，默认 8440
 *   HOST                监听地址，默认 127.0.0.1（只给隧道用，不暴露到局域网）
 *   NAPCAT_HOME         部署根目录，默认 D:\napcat
 *   WEB_KEY             访问 key，默认按 config.json → qrsync\key.txt → 随机生成
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const { spawn } = require('child_process');

const VERSION = '1.0.0';
const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const CONFIG_FILE = path.join(ROOT, 'config.json');
const ACTION_LOG = path.join(ROOT, 'actions.log');
const STARTED_AT = Date.now();

// ---------------------------------------------------------------- 配置

function stripBom(s) {
  return typeof s === 'string' && s.charCodeAt(0) === 0xfeff ? s.slice(1) : s;
}

function readJsonFile(file) {
  try {
    return JSON.parse(stripBom(fs.readFileSync(file, 'utf8')));
  } catch {
    return null;
  }
}

let cfg = readJsonFile(CONFIG_FILE) || {};
if (!cfg || typeof cfg !== 'object') cfg = {};

const NAPCAT_HOME = process.env.NAPCAT_HOME || cfg.napcatHome || 'D:\\napcat';
const PORT = Number(process.env.PORT || cfg.port || 8440);
const HOST = process.env.HOST || cfg.host || '127.0.0.1';
const GUARDIAN_TASK = cfg.guardianTask || 'NapCatGuardian';

const P = {
  metrics: path.join(NAPCAT_HOME, 'metrics.json'),
  loginState: path.join(NAPCAT_HOME, 'qrsync', 'login-state.json'),
  astrbotState: path.join(NAPCAT_HOME, 'astrbot-state.json'),
  tunnelState: path.join(NAPCAT_HOME, 'qrsync', 'tunnel-state.json'),
  heartbeat: path.join(NAPCAT_HOME, 'guardian.heartbeat'),
  kickLog: path.join(NAPCAT_HOME, 'kick.log'),
  qrFile: cfg.qrFile || path.join(NAPCAT_HOME, 'NapCat.Shell', 'cache', 'qrcode.png'),
  guardianLog: path.join(NAPCAT_HOME, 'guardian.log'),
  astrbotLog: path.join(NAPCAT_HOME, 'astrbot_watchdog.log'),
  qrsyncLog: path.join(NAPCAT_HOME, 'qrsync', 'daemon.log'),
  guardianCfg: path.join(NAPCAT_HOME, 'guardian.config.json'),
  qrsyncCfg: path.join(NAPCAT_HOME, 'qrsync', 'config.json'),
  qrsyncKey: path.join(NAPCAT_HOME, 'qrsync', 'key.txt'),
  sessionSince: path.join(NAPCAT_HOME, 'session-since.txt'),
  guardianScript: path.join(NAPCAT_HOME, 'guardian.ps1'),
  restartScript: path.join(NAPCAT_HOME, 'restart_napcat.ps1'),
  forceFlag: path.join(NAPCAT_HOME, 'force-relaunch.flag'),
};

// ---------------------------------------------------------------- 鉴权

function saveKey(k) {
  try {
    const cur = readJsonFile(CONFIG_FILE) || {};
    cur.key = k;
    cur.port = Number(cur.port || PORT);
    cur.napcatHome = cur.napcatHome || NAPCAT_HOME;
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cur, null, 2) + '\r\n', 'utf8');
    cfg = cur;
  } catch (e) {
    console.error('[web-console] 无法写入 config.json：' + e.message);
  }
}

function resolveKey() {
  if (process.env.WEB_KEY) return process.env.WEB_KEY.trim();
  const fromCfg = String(cfg.key || '').trim();
  if (fromCfg) return fromCfg;
  // 没有自己的配置就继承 qrsync 的 key，运维只需要记一个口令。
  try {
    const k = stripBom(fs.readFileSync(P.qrsyncKey, 'utf8')).trim();
    if (k) {
      saveKey(k);
      return k;
    }
  } catch {
    /* qrsync 没装过，自己生成 */
  }
  const k = crypto.randomBytes(18).toString('base64url');
  saveKey(k);
  return k;
}

const KEY = resolveKey();
const SESSION_TOKEN = crypto.createHmac('sha256', KEY).update('napcat-console|session|v1').digest('hex');
const CSRF_TOKEN = crypto.createHmac('sha256', KEY).update('napcat-console|csrf|v1').digest('hex');

function timingSafeEqualStr(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of String(header).split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (k) out[k] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

// ---------------------------------------------------------------- 脱敏

let secretCache = { at: 0, set: new Set() };

function refreshSecrets() {
  const now = Date.now();
  if (now - secretCache.at < 5000) return secretCache.set;
  const set = new Set();
  const add = (v) => {
    if (typeof v === 'string') {
      const s = v.trim();
      if (s.length >= 6) set.add(s);
      // qrPageUrl 里带的 ?k=xxx 逐个拆出来
      const m = s.match(/[?&]k=([A-Za-z0-9_-]{6,})/g);
      if (m) for (const x of m) set.add(x.replace(/^[?&]k=/, ''));
    }
  };

  const gc = readJsonFile(P.guardianCfg) || {};
  add(gc.webuiToken);
  add(gc.ntfyTopic);
  add(gc.qrPageUrl);
  if (gc.notifyEmail && typeof gc.notifyEmail === 'object') {
    add(gc.notifyEmail.user);
    add(gc.notifyEmail.pass);
    add(gc.notifyEmail.to);
  }

  const qc = readJsonFile(P.qrsyncCfg) || {};
  if (qc.ngrok) add(qc.ngrok.authToken);
  if (qc.cloudflare) add(qc.cloudflare.token);

  try {
    add(stripBom(fs.readFileSync(P.qrsyncKey, 'utf8')).trim());
  } catch {
    /* 没有就算了 */
  }

  // 机器人 QQ 号同样不许出现在页面上
  const m = readJsonFile(P.metrics);
  if (m && m.uin) add(String(m.uin));
  const ls = readJsonFile(P.loginState);
  if (ls && ls.uin) add(String(ls.uin));

  add(KEY); // 自己的 key 也不许回显

  secretCache = { at: now, set };
  return set;
}

function scrub(text) {
  let s = String(text == null ? '' : text);
  for (const secret of refreshSecrets()) s = s.split(secret).join('***');
  s = s.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '***@***');
  s = s.replace(/([?&]k=)[A-Za-z0-9_\-]+/g, '$1***');
  s = s.replace(/\b(uin|qq)["'\s:=]+(\d{5,12})/gi, '$1=***');
  return s;
}

// ---------------------------------------------------------------- 读取状态

function ageOf(iso) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  return Math.max(0, Math.round((Date.now() - t) / 1000));
}

function readFileText(file) {
  return stripBom(fs.readFileSync(file, 'utf8'));
}

function readJsonSafe(file) {
  const j = readJsonFile(file);
  return j && typeof j === 'object' && !Array.isArray(j) ? j : null;
}

function num(v, dflt) {
  // 注意：Number(null) === 0、Number('') === 0，所以空值必须先判掉，否则 limit/lines 的默认值会被 0 顶掉。
  if (v === null || v === undefined || v === '') return dflt;
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
}

function botStatus() {
  const m = readJsonSafe(P.metrics);
  const login = readJsonSafe(P.loginState);
  if (!m && !login) return { available: false, state: 'unknown' };

  const at = m && m.at ? m.at : null;
  const ageSec = at ? ageOf(at) : null;
  const stale = ageSec == null || ageSec > 180; // guardian 每 20 秒重写一次
  const rawState = String((m && m.state) || (login && login.state) || 'unknown');
  const online = rawState === 'online' && !stale;

  let sessionStart = null;
  try {
    const t = Date.parse(stripBom(fs.readFileSync(P.sessionSince, 'utf8')).trim());
    if (Number.isFinite(t)) sessionStart = new Date(t).toISOString();
  } catch {
    /* 没有就算了 */
  }

  return {
    available: true,
    state: rawState,
    online,
    stale,
    at,
    ageSec,
    session: {
      min: m && m.sessionMin != null ? num(m.sessionMin, 0) : null,
      startAt: sessionStart,
      secLive: sessionStart ? Math.max(0, Math.round((Date.now() - Date.parse(sessionStart)) / 1000)) : null,
    },
    kicksToday: m ? num(m.kicksToday, 0) : null,
    lastKick: (m && m.lastKick) || null,
    nextProbeAt: (m && m.nextProbeAt) || null,
    probeMin: m ? num(m.probeMin, 0) || null : null,
    lastRecover: m
      ? {
          sec: m.lastRecoverSec != null ? num(m.lastRecoverSec, null) : null,
          at: m.lastRecoverAt || null,
          cause: m.lastCause || null,
          pathName: m.lastPath || null,
        }
      : null,
    loginState: login
      ? { state: String(login.state || 'unknown'), note: scrub(login.note || ''), at: login.at || null, ageSec: login.at ? ageOf(login.at) : null }
      : null,
  };
}

function lastProbeFromLog() {
  // guardian 每次保活都会写 "keep-alive sent: 14:44  alive (session 14m)"
  try {
    const st = fs.statSync(P.guardianLog);
    const readLen = Math.min(st.size, 256 * 1024);
    const fd = fs.openSync(P.guardianLog, 'r');
    const buf = Buffer.alloc(readLen);
    try {
      fs.readSync(fd, buf, 0, readLen, st.size - readLen);
    } finally {
      fs.closeSync(fd);
    }
    const lines = buf.toString('utf8').split(/\r?\n/);
    for (let i = lines.length - 1; i >= 0; i--) {
      const mm = lines[i].match(/keep-alive sent:\s*(\d{1,2}:\d{2})/);
      if (mm) {
        const day = lines[i].match(/\[(\d{4}-\d{2}-\d{2})[ T]/);
        return { at: mm[1], date: day ? day[1] : null };
      }
    }
  } catch {
    /* 日志还没生成 */
  }
  return null;
}

function qrStatus(botOnline) {
  let st = null;
  try {
    st = fs.statSync(P.qrFile);
  } catch {
    st = null;
  }
  const now = Date.now();
  if (!st || !st.isFile()) {
    // NapCat 登录成功后会把二维码删掉
    return {
      present: false,
      state: botOnline ? 'loggedin' : 'waiting',
      ageSec: null,
      mtime: 0,
      size: 0,
      label: botOnline ? '已登录' : '等待扫码',
      hint: botOnline
        ? '机器人已登录，NapCat 已移除二维码文件。'
        : '还没有二维码：NapCat 未启动或尚未生成登录码。',
      botOnline,
    };
  }
  const ageSec = Math.max(0, Math.round((now - st.mtimeMs) / 1000));
  let state;
  if (ageSec <= 150) state = 'live';
  else if (ageSec <= 300) state = 'stale';
  else if (ageSec <= 900) state = 'expired';
  else state = 'used';

  const map = {
    live: { label: '等待扫码', hint: '二维码有效，用手机 QQ 扫一下即可登录（NapCat 每 2 分钟左右换一次码）。' },
    stale: { label: '二维码即将过期', hint: '已经 ' + Math.round(ageSec / 60) + ' 分钟没有刷新，NapCat 可能正在换码，稍等几秒。' },
    expired: { label: '已作废', hint: '这张码超过 5 分钟没有刷新，已经不能扫了。' },
    used: {
      label: botOnline ? '已登录 · 此码作废' : '已作废',
      hint: botOnline
        ? '机器人已经登录，NapCat 不会再出新码，所以这张码停在最后一次写入的时间。'
        : '这张码很久没有更新，NapCat 登录成功后就不再刷新二维码。',
    },
  };

  return {
    present: true,
    state,
    ageSec,
    mtime: Math.round(st.mtimeMs),
    size: st.size,
    label: map[state].label,
    hint: map[state].hint,
    botOnline,
  };
}

function astrbotStatus() {
  const j = readJsonSafe(P.astrbotState);
  if (!j) return { available: false, state: 'unknown' };
  const ageSec = j.at ? ageOf(j.at) : null;
  const healthy = String(j.state) === 'online' && j.portOk === true && ageSec != null && ageSec <= 300;
  return {
    available: true,
    state: String(j.state || 'unknown'),
    note: scrub(j.note || ''),
    portOk: j.portOk === true,
    restarts: num(j.restarts, 0),
    since: j.since || null,
    at: j.at || null,
    ageSec,
    healthy,
  };
}

function tunnelStatus() {
  const j = readJsonSafe(P.tunnelState);
  if (!j) return { available: false, ok: false };
  return {
    available: true,
    provider: String(j.provider || 'unknown'),
    ok: j.ok === true,
    url: typeof j.url === 'string' && /^https?:\/\//.test(j.url) ? j.url : null,
    failStreak: num(j.failStreak, 0),
    at: j.at || null,
    ageSec: j.at ? ageOf(j.at) : null,
  };
}

function guardianStatus() {
  try {
    const txt = stripBom(fs.readFileSync(P.heartbeat, 'utf8')).trim();
    const parts = txt.split('|');
    const pid = parts[0] ? Number(parts[0]) : null;
    const iso = parts[1] ? new Date(parts[1]).toISOString() : null;
    const ageSec = iso ? ageOf(iso) : null;
    return { available: true, pid: Number.isFinite(pid) ? pid : null, at: iso, ageSec, alive: ageSec != null && ageSec < 180 };
  } catch {
    return { available: false, pid: null, at: null, ageSec: null, alive: false };
  }
}

function kicks(limit) {
  let txt = '';
  try {
    txt = readFileText(P.kickLog);
  } catch {
    return { items: [], total: 0, available: false };
  }
  const lines = txt.split(/\r?\n/).filter((l) => l.trim());
  const items = [];
  let total = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = lines[i].match(/^\[([^\]]+)\]\s*KICKED\s*\|\s*(.*)$/i);
    if (!m) continue;
    total++;
    if (items.length >= limit) continue;
    const rec = { ts: m[1].trim(), at: null, logFile: null, sessionMin: null, quietMin: null, ip: null };
    for (const raw of m[2].split('|')) {
      const part = raw.trim();
      const eq = part.indexOf('=');
      if (eq < 0) continue;
      const k = part.slice(0, eq).trim().toLowerCase();
      const v = part.slice(eq + 1).trim();
      if (k === 'at') rec.at = v;
      else if (k === 'log') rec.logFile = v;
      else if (k === 'session') rec.sessionMin = num(parseInt(v, 10), null);
      else if (k === 'quiet_before_kick') rec.quietMin = num(parseInt(v, 10), null);
      else if (k === 'ip') rec.ip = maskIp(v);
    }
    items.push(rec);
  }
  // 相邻两次被踢的间隔（按时间倒序的 items 里，下一条更早）
  for (let i = 0; i < items.length; i++) {
    const a = Date.parse(items[i].ts.replace(' ', 'T'));
    const b = items[i + 1] ? Date.parse(items[i + 1].ts.replace(' ', 'T')) : NaN;
    items[i].gapMin = Number.isFinite(a) && Number.isFinite(b) ? Math.round((a - b) / 60000) : null;
  }
  const today = new Date();
  const y = today.getFullYear();
  const md = String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
  const kicksToday = items.filter((it) => it.ts.slice(5, 10) === md).length;
  return { items, total, available: true, kicksToday };
}

function maskIp(ip) {
  // 这是本机出口 IP，公网可见；页面上只留前两段，够定位是同一出口，又不至于把出口 IP 公开。
  const s = String(ip || '');
  const m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return s ? '***' : null;
  return m[1] + '.' + m[2] + '.*.*';
}

// ---------------------------------------------------------------- 日志

const LOGS = {
  guardian: { file: P.guardianLog, label: 'guardian.log', desc: '守卫主日志' },
  astrbot: { file: P.astrbotLog, label: 'astrbot_watchdog.log', desc: 'AstrBot 看护日志' },
  qrsync: { file: P.qrsyncLog, label: 'qrsync\\daemon.log', desc: '扫码通道守护日志' },
};

const LEVEL_RE = {
  err: /(error|fail|fatal|exception|失败|错误|异常|踢|kicked|崩溃|超时|timeout)/i,
  warn: /(warn|警告|告警|⚠|重试|retry)/i,
};

function tailText(file, lines) {
  const st = fs.statSync(file);
  const readLen = Math.min(st.size, 4 * 1024 * 1024);
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(readLen);
  try {
    fs.readSync(fd, buf, 0, readLen, st.size - readLen);
  } finally {
    fs.closeSync(fd);
  }
  let txt = buf.toString('utf8');
  if (st.size > readLen) txt = txt.slice(txt.indexOf('\n') + 1 || 0); // 丢掉被截断的半行
  const all = stripBom(txt).split(/\r?\n/);
  if (all.length && all[all.length - 1] === '') all.pop();
  return { lines: all.slice(Math.max(0, all.length - lines)), size: st.size, mtime: Math.round(st.mtimeMs), truncated: st.size > readLen };
}

function readLog(name, opts) {
  const meta = LOGS[name];
  if (!meta) return null;
  const lines = Math.max(1, Math.min(1000, num(opts.lines, 200)));
  const q = String(opts.q || '').trim();
  const level = ['all', 'err', 'warn'].includes(opts.level) ? opts.level : 'all';
  let t;
  try {
    t = tailText(meta.file, 4000);
  } catch (e) {
    return { name, label: meta.label, desc: meta.desc, available: false, error: scrub(e.message), lines: [] };
  }
  let picked = t.lines;
  if (level !== 'all') picked = picked.filter((l) => LEVEL_RE[level].test(l));
  if (q) {
    const needle = q.toLowerCase();
    picked = picked.filter((l) => l.toLowerCase().includes(needle));
  }
  const matched = picked.length;
  picked = picked.slice(Math.max(0, picked.length - lines));
  return {
    name,
    label: meta.label,
    desc: meta.desc,
    available: true,
    size: t.size,
    mtime: t.mtime,
    truncated: t.truncated,
    matched,
    shown: picked.length,
    filter: { lines, q, level },
    lines: picked.map(scrub),
  };
}

// ---------------------------------------------------------------- 动作

const ACTIONS = {
  'restart-worker': {
    label: '重启 NapCat worker',
    phrase: '重启',
    risk: 'medium',
    desc: '调用 NapCat WebUI 的 /api/QQLogin/RestartNapCat：只重启 worker，不杀 QQ 进程，通常用缓存票据免扫码直接登回来。',
  },
  'notify-test': {
    label: '触发通知自检',
    phrase: '自检',
    risk: 'low',
    desc: '调用既有脚本 guardian.ps1 -TestNotify：发一条“NapCat 通知自检”，不会改动机器人状态。',
  },
  'guardian-start': {
    label: '重新拉起守卫任务',
    phrase: '拉起',
    risk: 'medium',
    desc: '用 schtasks 启动计划任务 NapCatGuardian。守卫内部有互斥体，已在跑时不会重复启动；心跳正常时本服务会拒绝执行。',
  },
  'full-restart': {
    label: '全量重启 NapCat',
    phrase: '全量重启',
    risk: 'high',
    desc: '调用既有脚本 restart_napcat.ps1：投递 force-relaunch.flag，由守卫杀 QQ 并重新注入，需要 1~3 分钟，可能要重新扫码。',
  },
};

const actionState = { last: {}, ring: [] };

function recordAction(entry) {
  actionState.ring.unshift(entry);
  actionState.ring = actionState.ring.slice(0, 20);
  try {
    fs.appendFileSync(
      ACTION_LOG,
      '[' + entry.at + '] ' + entry.action + ' ' + (entry.ok ? 'OK' : 'FAIL') + ' from ' + entry.ip + ' :: ' + scrub(entry.message) + '\r\n',
      'utf8'
    );
  } catch {
    /* 日志写不进去不影响主流程 */
  }
}

function webuiToken() {
  const gc = readJsonFile(P.guardianCfg) || {};
  return String(gc.webuiToken || '').trim();
}

async function postJson(url, body, timeoutMs, headers) {
  const res = await fetch(url, {
    method: 'POST',
    headers: Object.assign({ 'content-type': 'application/json' }, headers || {}),
    body: JSON.stringify(body || {}),
    signal: AbortSignal.timeout(timeoutMs || 10000),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* 不是 JSON 就返回原文 */
  }
  if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + scrub(text).slice(0, 200));
  return json != null ? json : text;
}

async function doRestartWorker() {
  const tok = webuiToken();
  if (!tok) throw new Error('没读到 WebUI token（guardian.config.json 缺失或为空）');
  // 与 guardian.ps1 的 Get-WebUIHeaders 完全一致：hash = sha256(token + ".napcat")
  const hash = crypto.createHash('sha256').update(tok + '.napcat', 'utf8').digest('hex');
  const login = await postJson('http://127.0.0.1:6099/api/auth/login', { hash, totpCode: null }, 8000);
  const cred = login && login.data && login.data.Credential;
  if (!cred) throw new Error('NapCat WebUI 登录失败（token 可能已更换）');
  await postJson('http://127.0.0.1:6099/api/QQLogin/RestartNapCat', {}, 25000, { authorization: 'Bearer ' + cred });
  return '已请求 NapCat 重启 worker；通常 15~60 秒内用缓存票据登回来，状态会在本页自动刷新。';
}

function spawnDetached(exe, args) {
  const child = spawn(exe, args, { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
  return child.pid;
}

function doNotifyTest() {
  if (!fs.existsSync(P.guardianScript)) throw new Error('找不到 guardian.ps1');
  const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  spawnDetached(ps, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', P.guardianScript, '-TestNotify']);
  return '已调用 guardian.ps1 -TestNotify，通知会在几秒到几十秒内发出（ntfy 超时时要等它走到邮件通道）。';
}

function doGuardianStart() {
  const hb = guardianStatus();
  if (hb.alive) {
    return { skipped: true, message: '守卫心跳正常（' + (hb.ageSec == null ? '?' : hb.ageSec) + ' 秒前，pid ' + (hb.pid || '?') + '），已在运行，未重复拉起。' };
  }
  const r = require('child_process').spawnSync('schtasks.exe', ['/run', '/tn', GUARDIAN_TASK], { windowsHide: true, encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error('schtasks 启动失败：' + scrub((r.stderr || r.stdout || '').trim() || 'exit ' + r.status));
  }
  return '已请求启动计划任务 ' + GUARDIAN_TASK + '，守卫启动后会重写 guardian.heartbeat。';
}

function doFullRestart() {
  if (!fs.existsSync(P.restartScript)) throw new Error('找不到 restart_napcat.ps1');
  const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  spawnDetached(ps, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', P.restartScript]);
  return '已投递 force-relaunch.flag（由 restart_napcat.ps1 完成）。守卫下一轮会杀 QQ 并重新注入，1~3 分钟，期间可能要扫码。';
}

async function runAction(name, req) {
  const def = ACTIONS[name];
  if (!def) return { status: 404, body: { ok: false, message: '未知动作' } };

  const now = Date.now();
  const last = actionState.last[name] || 0;
  if (now - last < 15000) {
    return {
      status: 429,
      body: { ok: false, message: '动作太频繁：' + Math.ceil((15000 - (now - last)) / 1000) + ' 秒后再试' },
    };
  }
  actionState.last[name] = now;

  const ip = req.socket && req.socket.remoteAddress ? req.socket.remoteAddress : '?';
  const entry = { at: new Date().toISOString(), action: name, label: def.label, ok: false, message: '', ip: scrub(ip) };
  try {
    let out = '';
    if (name === 'restart-worker') out = await doRestartWorker();
    else if (name === 'notify-test') out = doNotifyTest();
    else if (name === 'guardian-start') out = doGuardianStart();
    else if (name === 'full-restart') out = doFullRestart();

    if (out && typeof out === 'object' && out.skipped) {
      entry.ok = true;
      entry.message = out.message;
      recordAction(entry);
      return { status: 200, body: { ok: true, skipped: true, action: name, message: out.message, at: entry.at } };
    }
    entry.ok = true;
    entry.message = String(out);
    recordAction(entry);
    return { status: 200, body: { ok: true, action: name, message: String(out), at: entry.at } };
  } catch (e) {
    entry.message = e && e.message ? e.message : String(e);
    recordAction(entry);
    return { status: 502, body: { ok: false, action: name, message: '执行失败：' + entry.message, at: entry.at } };
  }
}

// ---------------------------------------------------------------- 汇总

function notifyConfig() {
  // 只返回各通道的开关状态，不返回邮箱地址、token、topic 等敏感值。
  const gc = readJsonFile(P.guardianCfg) || {};
  return {
    ntfy: gc.notifyNtfy === true,
    toast: gc.notifyToast === true,
    email: !!(gc.notifyEmail && gc.notifyEmail.to),
    webhook: !!(gc.notifyWebhook && gc.notifyWebhook.url),
  };
}

function setNotifyConfig(changes) {
  // 读出现有配置，只改传入的开关，其余字段原样保留，再整体写回。
  if (!changes || typeof changes !== 'object') throw new Error('没有要修改的开关');
  const gc = readJsonFile(P.guardianCfg);
  // 读不到配置时绝不用空对象写入，否则会把 webuiToken、邮箱等全部覆盖丢失。
  if (!gc) throw new Error('读不到 guardian.config.json，已拒绝写入');
  if (typeof changes.ntfy === 'boolean') gc.notifyNtfy = changes.ntfy;
  if (typeof changes.toast === 'boolean') gc.notifyToast = changes.toast;
  // 先写临时文件再改名，避免写一半进程被杀导致配置损坏。
  const tmp = P.guardianCfg + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(gc, null, 2) + '\r\n', 'utf8');
  fs.renameSync(tmp, P.guardianCfg);
  return notifyConfig();
}

function buildStatus() {
  const bot = botStatus();
  const qr = qrStatus(bot.online);
  const ab = astrbotStatus();
  const tn = tunnelStatus();
  const gd = guardianStatus();
  const ks = kicks(1);
  const probe = lastProbeFromLog();

  const warnings = [];
  if (gd.available && !gd.alive) warnings.push('守卫心跳超时（' + Math.round((gd.ageSec || 0) / 60) + ' 分钟没有更新）');
  if (!gd.available) warnings.push('读不到 guardian.heartbeat，守卫可能没在运行');
  if (bot.available && bot.stale) warnings.push('metrics.json 超过 3 分钟没更新，机器人状态可能已过期');
  if (bot.available && !bot.online && bot.state !== 'online') warnings.push('机器人当前不是在线状态：' + bot.state);
  if (ab.available && !ab.healthy) warnings.push('AstrBot 异常（' + ab.state + (ab.portOk ? '' : '，端口不通') + '）');
  if (!ab.available) warnings.push('读不到 astrbot-state.json');
  if (tn.available && !tn.ok) warnings.push('扫码通道不可用（' + tn.provider + '，连续失败 ' + tn.failStreak + ' 次）');
  if (qr.state === 'stale' || qr.state === 'expired') warnings.push('二维码需要重新生成：' + qr.label);

  return {
    ok: true,
    version: VERSION,
    now: new Date().toISOString(),
    server: { uptimeSec: Math.round((Date.now() - STARTED_AT) / 1000), pid: process.pid, port: PORT },
    bot,
    qr,
    astrbot: ab,
    tunnel: tn,
    guardian: gd,
    probe: { last: probe ? probe.at : null, lastDate: probe ? probe.date : null, next: bot.nextProbeAt, intervalMin: bot.probeMin },
    kicksToday: bot.kicksToday != null ? bot.kicksToday : ks.kicksToday || 0,
    warnings,
    logs: Object.keys(LOGS).map((k) => {
      let size = null;
      let mtime = null;
      try {
        const st = fs.statSync(LOGS[k].file);
        size = st.size;
        mtime = Math.round(st.mtimeMs);
      } catch {
        /* 文件不存在 */
      }
      return { name: k, label: LOGS[k].label, desc: LOGS[k].desc, size, mtime };
    }),
    actions: actionState.ring,
    notify: notifyConfig(),
    csrf: CSRF_TOKEN,
  };
}

// ---------------------------------------------------------------- HTTP

const STATIC = {
  '/': { file: 'index.html', type: 'text/html; charset=utf-8' },
  '/index.html': { file: 'index.html', type: 'text/html; charset=utf-8' },
  '/app.js': { file: 'app.js', type: 'text/javascript; charset=utf-8' },
  '/style.css': { file: 'style.css', type: 'text/css; charset=utf-8' },
  '/favicon.svg': { file: 'favicon.svg', type: 'image/svg+xml' },
};

const BASE_HEADERS = {
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'x-frame-options': 'DENY',
  'cross-origin-opener-policy': 'same-origin',
  'content-security-policy':
    "default-src 'none'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

function send(res, status, headers, body) {
  const h = Object.assign({}, BASE_HEADERS, headers);
  let out = body;
  // 弱网优化：文本类响应按需 gzip（页面 8.8 KB → 约 2.5 KB）。
  try {
    const ct = String(h['content-type'] || '');
    const compressible = /^(text\/|application\/(json|javascript)|image\/svg)/.test(ct);
    const acceptsGzip =
      res.req && /\bgzip\b/i.test(String(res.req.headers['accept-encoding'] || ''));
    if (compressible && acceptsGzip && body != null && body !== '') {
      const raw = Buffer.isBuffer(body) ? body : Buffer.from(String(body), 'utf8');
      if (raw.length > 400) {
        out = zlib.gzipSync(raw, { level: 9 });
        h['content-encoding'] = 'gzip';
        h.vary = 'accept-encoding';
      }
    }
  } catch {
    out = body;
  }
  if (out === body && (Buffer.isBuffer(body) || typeof body === 'string')) {
    h['content-length'] = Buffer.byteLength(body);
  } else {
    h['content-length'] = out.length;
  }
  res.writeHead(status, h);
  res.end(out);
}

function sendJson(res, status, obj) {
  send(res, status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }, JSON.stringify(obj));
}

function notFound(res) {
  send(res, 404, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' }, 'Not Found');
}

// ---------------------------------------------------------------- 单文件页面 + SSE
//
// 弱网下的取舍：公网链路 RTT ≈ 250 ms，每多一个请求就多一次往返。
// 所以 / 直接吐一个自包含页面（CSS/JS 内联、favicon 内联、首屏二维码用 data: URI），
// 之后的实时更新走 SSE（只在状态变化时推），不再 3 秒轮询。

function readPublic(name) {
  try {
    return fs.readFileSync(path.join(PUBLIC_DIR, name), 'utf8');
  } catch {
    return '';
  }
}

function qrDataUri() {
  try {
    const buf = fs.readFileSync(P.qrFile);
    if (!buf.length || buf.length > 512 * 1024) return '';
    return 'data:image/png;base64,' + buf.toString('base64');
  } catch {
    return '';
  }
}

function buildInlinePage(nonce) {
  const html = readPublic('index.html');
  const css = readPublic('style.css');
  const js = readPublic('app.js');
  const fav = readPublic('favicon.svg');

  let boot = '';
  try {
    boot = JSON.stringify({ st: buildStatus(), qr: qrDataUri() });
  } catch {
    boot = '{}';
  }

  let out = html
    .replace(
      /<link rel="stylesheet" href="style\.css">/,
      () => '<style>\n' + css + '\n</style>'
    )
    .replace(
      /<link rel="icon" href="favicon\.svg" type="image\/svg\+xml">/,
      () =>
        fav
          ? '<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,' +
            Buffer.from(fav, 'utf8').toString('base64') +
            '">'
          : ''
    )
    .replace(
      /<script src="app\.js" defer><\/script>/,
      () =>
        '<script nonce="' +
        nonce +
        '">window.__BOOT__=' +
        boot +
        ';</script>\n<script nonce="' +
        nonce +
        '">\n' +
        js +
        '\n</script>'
    );

  if (!/window\.__BOOT__/.test(out)) {
    // 兜底：万一 index.html 结构变了，至少把脚本挂上去
    out = out.replace('</body>', '<script nonce="' + nonce + '">' + js + '</script></body>');
  }
  return out;
}

const SSE_CLIENTS = new Set();
let sseSig = '';
let sseQrSig = '';
let sseTimer = null;

function sseStatusPayload() {
  const st = buildStatus();
  const qr = st.qr || {};
  const qrSig = qr.present ? String(qr.mtime) + ':' + String(qr.size) : 'none';
  const out = { st: st };
  if (qrSig !== sseQrSig) {
    sseQrSig = qrSig;
    out.qr = qr.present ? qrDataUri() : '';
  }
  return out;
}

function sseBroadcast() {
  if (!SSE_CLIENTS.size) return;
  let payload;
  try {
    payload = sseStatusPayload();
  } catch {
    return;
  }
  const sig = crypto.createHash('sha1').update(JSON.stringify(payload.st)).digest('hex');
  if (sig === sseSig && !payload.qr) return;
  sseSig = sig;
  const line = 'data: ' + JSON.stringify(payload) + '\n\n';
  for (const res of SSE_CLIENTS) {
    try {
      res.write(line);
    } catch {
      SSE_CLIENTS.delete(res);
    }
  }
}

function sseStart() {
  if (sseTimer) return;
  sseTimer = setInterval(() => {
    try {
      sseBroadcast();
    } catch {
      /* 忽略单次失败 */
    }
  }, 2000);
  if (sseTimer.unref) sseTimer.unref();
}

function handleStream(req, res, nonce) {
  const csp =
    "default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
    "script-src 'nonce-" +
    nonce +
    "'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
    'content-security-policy': csp,
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  });
  res.write('retry: 4000\n\n');
  try {
    const first = sseStatusPayload();
    sseSig = crypto.createHash('sha1').update(JSON.stringify(first.st)).digest('hex');
    res.write('data: ' + JSON.stringify(first) + '\n\n');
  } catch {
    /* 首帧失败不致命 */
  }
  SSE_CLIENTS.add(res);
  sseStart();
  const ka = setInterval(() => {
    try {
      res.write(': keep-alive\n\n');
    } catch {
      clearInterval(ka);
    }
  }, 20000);
  if (ka.unref) ka.unref();
  const done = () => {
    clearInterval(ka);
    SSE_CLIENTS.delete(res);
  };
  req.on('close', done);
  req.on('error', done);
}

function isHttps(req) {
  return String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim() === 'https';
}

function sessionCookie(req) {
  const attrs = ['nc_session=' + SESSION_TOKEN, 'Path=/', 'HttpOnly', 'SameSite=Strict', 'Max-Age=' + 60 * 60 * 24 * 30];
  if (isHttps(req)) attrs.push('Secure');
  return attrs.join('; ');
}

function authorized(req, url) {
  const given = url.searchParams.get('k');
  if (given && timingSafeEqualStr(given, KEY)) return 'key';
  const hdr = req.headers['x-key'];
  if (typeof hdr === 'string' && timingSafeEqualStr(hdr, KEY)) return 'header';
  const cookies = parseCookies(req.headers.cookie);
  if (cookies.nc_session && timingSafeEqualStr(cookies.nc_session, SESSION_TOKEN)) return 'cookie';
  return null;
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > (limit || 64 * 1024)) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://local');
  const via = authorized(req, url);
  if (!via) return notFound(res);

  // 带 key 进来就顺手换成 Cookie，之后页面里的 fetch / <img> 都不再暴露 key。
  if (via === 'key') res.setHeader('set-cookie', sessionCookie(req));

  const p = url.pathname;

  // 浏览器会自动请求 /favicon.ico；给空的 204，避免落进 404 日志噪音。
  if (p === '/favicon.ico') return send(res, 204, { 'cache-control': 'no-store' }, '');

  // 单文件页面：一次请求就把 HTML/CSS/JS/首屏二维码全部带过去（弱网少跳几次往返）
  if ((p === '/' || p === '/index.html') && (req.method === 'GET' || req.method === 'HEAD')) {
    const nonce = crypto.randomBytes(12).toString('base64');
    const csp =
      "default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
      "script-src 'nonce-" +
      nonce +
      "'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
    let page = '';
    try {
      page = buildInlinePage(nonce);
    } catch {
      page = '';
    }
    if (!page) return notFound(res);
    return send(
      res,
      200,
      {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'content-security-policy': csp,
      },
      req.method === 'HEAD' ? '' : page
    );
  }

  if (p === '/api/stream' && req.method === 'GET') {
    return handleStream(req, res, crypto.randomBytes(12).toString('base64'));
  }

  if (req.method === 'GET' || req.method === 'HEAD') {
    const s = STATIC[p];
    if (s) {
      let buf;
      try {
        buf = fs.readFileSync(path.join(PUBLIC_DIR, s.file));
      } catch {
        return notFound(res);
      }
      return send(res, 200, { 'content-type': s.type, 'cache-control': 'no-store' }, req.method === 'HEAD' ? '' : buf);
    }
  }

  if (p === '/api/status' && req.method === 'GET') {
    return sendJson(res, 200, buildStatus());
  }

  if (p === '/api/kicks' && req.method === 'GET') {
    const limit = Math.max(1, Math.min(500, num(url.searchParams.get('limit'), 50)));
    const data = kicks(limit);
    data.items = data.items.map((it) => Object.assign({}, it, { logFile: it.logFile ? scrub(it.logFile) : null }));
    return sendJson(res, 200, data);
  }

  if (p === '/api/logs' && req.method === 'GET') {
    const data = readLog(url.searchParams.get('name') || 'guardian', {
      lines: url.searchParams.get('lines'),
      q: url.searchParams.get('q'),
      level: url.searchParams.get('level'),
    });
    if (!data) return sendJson(res, 404, { ok: false, message: '没有这个日志' });
    return sendJson(res, 200, data);
  }

  if (p === '/api/qr.png' && req.method === 'GET') {
    let buf = null;
    let st = null;
    for (let i = 0; i < 3 && !buf; i++) {
      try {
        st = fs.statSync(P.qrFile);
        const b = fs.readFileSync(P.qrFile);
        if (b.length > 100 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) buf = b;
      } catch {
        /* 正在被覆盖写 */
      }
      if (!buf) {
        const until = Date.now() + 40;
        while (Date.now() < until) {
          /* 40ms 忙等，和 qrsync 一样 */
        }
      }
    }
    if (!buf) return send(res, 503, { 'content-type': 'text/plain', 'cache-control': 'no-store' }, 'waiting');
    const etag = '"' + Math.round(st.mtimeMs) + '-' + buf.length + '"';
    if (req.headers['if-none-match'] === etag) {
      return send(res, 304, { etag, 'cache-control': 'no-store' }, '');
    }
    return send(res, 200, { 'content-type': 'image/png', 'content-length': buf.length, 'cache-control': 'no-store', etag }, buf);
  }

  if (p === '/api/notify-config' && req.method === 'POST') {
    // 通知开关是低风险设置：只校验 CSRF，不需要危险动作那样的手打确认词。
    const csrf = req.headers['x-csrf'];
    if (typeof csrf !== 'string' || !timingSafeEqualStr(csrf, CSRF_TOKEN)) {
      return sendJson(res, 403, { ok: false, message: '会话校验失败，请刷新页面重试' });
    }
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return sendJson(res, 400, { ok: false, message: '请求体不是合法 JSON' });
    }
    try {
      const updated = setNotifyConfig(body);
      return sendJson(res, 200, { ok: true, notify: updated });
    } catch (e) {
      return sendJson(res, 502, { ok: false, message: '写入失败：' + (e && e.message) });
    }
  }

  if (p === '/api/action' && req.method === 'POST') {
    const csrf = req.headers['x-csrf'];
    if (typeof csrf !== 'string' || !timingSafeEqualStr(csrf, CSRF_TOKEN)) {
      return sendJson(res, 403, { ok: false, message: '会话校验失败，请刷新页面重试' });
    }
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return sendJson(res, 400, { ok: false, message: '请求体不是合法 JSON' });
    }
    const name = String(body.action || '');
    const def = ACTIONS[name];
    if (!def) return sendJson(res, 404, { ok: false, message: '未知动作' });
    // 二次确认：前端要求手打提示词，服务端再核对一遍，防止有人直接打接口。
    const phrase = String(body.phrase || '').replace(/\s+/g, '');
    if (phrase !== def.phrase) {
      return sendJson(res, 400, { ok: false, message: '确认词不正确：请手打「' + def.phrase + '」' });
    }
    const out = await runAction(name, req);
    return sendJson(res, out.status, out.body);
  }

  return notFound(res);
}

const server = http.createServer((req, res) => {
  // 一个畸形请求（例如 `GET http://[`）会让 new URL() 抛异常；这个端口挂在公网隧道上，
  // 任何人都能发这行字节，所以必须兜住，不能让整个进程退出。
  Promise.resolve()
    .then(() => handle(req, res))
    .catch((e) => {
      console.error('[web-console] 请求处理失败 ' + req.method + ' ' + req.url + ': ' + (e && e.message));
      try {
        if (!res.headersSent) send(res, 400, { 'content-type': 'text/plain', 'cache-control': 'no-store' }, 'Bad Request');
        else res.end();
      } catch {
        /* 连接已断 */
      }
    });
});

process.on('uncaughtException', (e) => console.error('[web-console] uncaughtException: ' + (e && e.stack ? e.stack : e)));
process.on('unhandledRejection', (e) => console.error('[web-console] unhandledRejection: ' + (e && e.stack ? e.stack : e)));

server.listen(PORT, HOST, () => {
  console.log('[web-console] v' + VERSION + ' listening on http://' + HOST + ':' + PORT);
  console.log('[web-console] key loaded (length ' + KEY.length + ', 不回显)  home=' + NAPCAT_HOME);
  console.log('[web-console] 打开 http://127.0.0.1:' + PORT + '/?k=<key> 即可');
  for (const k of Object.keys(LOGS)) {
    try {
      fs.accessSync(LOGS[k].file);
    } catch {
      console.log('[web-console] 警告：日志不存在 ' + LOGS[k].file);
    }
  }
});
