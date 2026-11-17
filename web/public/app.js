/* NapCat Web 控制台前端 —— 无依赖，3 秒轮询 /api/status
   所有数据都走同源接口，页面里不保存 key（key 只在第一次 ?k= 时换成 HttpOnly Cookie）。 */
'use strict';

(function () {
  const $ = (id) => document.getElementById(id);

  const POLL_MS = 3000;
  const KICKS_EVERY_MS = 15000;
  const LOG_AUTO_MS = 5000;

  const state = {
    csrf: '',
    paused: false,
    timer: null,
    lastKicksAt: 0,
    logTimer: null,
    logName: 'guardian',
    qrKey: '',
    lastStatus: null,
    failure: 0,
    dialogAction: null,
    syncingNotify: false,
  };

  /* ------------------------------------------------------------ 工具 */

  function pad(n) {
    return String(n).padStart(2, '0');
  }

  function fmtDuration(sec) {
    if (sec == null || !Number.isFinite(sec)) return '—';
    const s = Math.max(0, Math.round(sec));
    if (s < 60) return s + ' 秒';
    const m = Math.floor(s / 60);
    if (m < 60) return m + ' 分钟';
    const h = Math.floor(m / 60);
    const rm = m % 60;
    if (h < 24) return h + ' 小时' + (rm ? ' ' + rm + ' 分' : '');
    const d = Math.floor(h / 24);
    return d + ' 天 ' + (h % 24) + ' 小时';
  }

  function fmtAgo(sec) {
    if (sec == null || !Number.isFinite(sec)) return '—';
    if (sec < 10) return '刚刚';
    if (sec < 60) return Math.round(sec) + ' 秒前';
    if (sec < 3600) return Math.round(sec / 60) + ' 分钟前';
    if (sec < 86400) return Math.round(sec / 3600) + ' 小时前';
    return Math.round(sec / 86400) + ' 天前';
  }

  function fmtLocal(iso) {
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return '—';
    const d = new Date(t);
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  function fmtClock(iso) {
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return '—';
    const d = new Date(t);
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  function fmtBytes(n) {
    if (n == null) return '—';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1024 / 1024).toFixed(1) + ' MB';
  }

  function setText(el, text) {
    if (!el) return;
    const v = text == null ? '' : String(text);
    if (el.textContent !== v) el.textContent = v;
  }

  function setPill(el, kind) {
    if (!el) return;
    el.classList.remove('live', 'warn', 'bad');
    if (kind) el.classList.add(kind);
  }

  function toast(msg, kind) {
    const box = $('toasts');
    if (!box) return;
    const div = document.createElement('div');
    div.className = 'toast' + (kind ? ' ' + kind : '');
    div.textContent = msg;
    box.appendChild(div);
    setTimeout(() => {
      div.remove();
    }, kind === 'bad' ? 8000 : 5000);
  }

  function stateLabel(s) {
    const map = {
      online: '在线',
      offline: '离线',
      kicked: '被踢下线',
      logging: '登录中',
      unknown: '未知',
    };
    return map[s] || s || '未知';
  }

  /* ------------------------------------------------------------ 状态渲染 */

  function renderBot(st) {
    const bot = st.bot || {};
    const big = $('botBig');
    const label = !bot.available ? '无数据' : bot.stale ? stateLabel(bot.state) + '（数据过期）' : stateLabel(bot.state);
    big.classList.remove('online', 'offline', 'unknown');
    // 过期数据不能算“在线”，也不能算“离线”，用 unknown 的琥珀色更诚实
    big.classList.add(!bot.available || bot.stale ? 'unknown' : bot.online ? 'online' : 'offline');
    setText($('botState'), label);
    setText($('botUnit'), '');

    const noteBits = [];
    if (!bot.available) noteBits.push('读不到 metrics.json / login-state.json');
    else {
      noteBits.push('状态采样 ' + fmtAgo(bot.ageSec));
      if (bot.loginState) noteBits.push('登录记录「' + (bot.loginState.note || bot.loginState.state) + '」' + fmtAgo(bot.loginState.ageSec));
    }
    setText($('botNote'), noteBits.join(' · '));

    const sess = bot.session || {};
    const sessSec = sess.secLive != null ? sess.secLive : sess.min != null ? sess.min * 60 : null;
    setText($('k-session'), sessSec == null ? '—' : fmtDuration(sessSec) + (sess.startAt ? '（' + fmtLocal(sess.startAt) + ' 起）' : ''));

    setText($('k-kicks'), st.kicksToday != null ? st.kicksToday + ' 次' + (bot.lastKick ? '（最近 ' + bot.lastKick + '）' : '') : '—');

    const probe = st.probe || {};
    setText(
      $('k-probe'),
      probe.next ? probe.next + (probe.intervalMin ? '（每 ' + probe.intervalMin + ' 分钟）' : '') : '—'
    );

    const rec = bot.lastRecover;
    if (rec && (rec.sec != null || rec.at)) {
      const cause = rec.cause ? '原因 ' + rec.cause + (rec.pathName ? ' / ' + rec.pathName : '') : '';
      const when = rec.at ? fmtLocal(rec.at) : '';
      setText($('k-recover'), [rec.sec != null ? '耗时 ' + fmtDuration(rec.sec) : '', cause, when].filter(Boolean).join(' · ') || '—');
    } else setText($('k-recover'), '—');

    setText($('k-login'), bot.loginState ? (bot.loginState.state === 'online' ? '已登录' : stateLabel(bot.loginState.state)) + ' · ' + fmtAgo(bot.loginState.ageSec) : '—');

    // 小标签：探针 / 会话 / 今日被踢
    const chips = $('botChips');
    chips.textContent = '';
    // 一个 chip 形如：<b>3</b> 今日被踢
    const add = (value, caption, cls) => {
      const s = document.createElement('span');
      s.className = 'chip' + (cls ? ' ' + cls : '');
      const b = document.createElement('b');
      b.textContent = value;
      s.appendChild(b);
      s.appendChild(document.createTextNode(' ' + caption));
      chips.appendChild(s);
    };
    if (st.kicksToday != null) add(String(st.kicksToday), '今日被踢', st.kicksToday >= 5 ? 'bad' : st.kicksToday > 0 ? 'warn' : 'ok');
    if (probe.last) add(probe.last, '上次探针' + (probe.lastDate ? ' ' + probe.lastDate.slice(5) : ''), '');
    if (sessSec != null) add(fmtDuration(sessSec), '会话', '');
    if (bot.stale) add('!', '状态已过期', 'warn');
  }

  function renderQr(st) {
    const qr = st.qr || {};
    const box = $('qrBox');
    const img = $('qrImg');
    const empty = $('qrEmpty');

    const key = qr.present ? String(qr.mtime) + '-' + String(qr.size) : 'none';
    if (qr.present && state.qrKey !== key) {
      // 优先用服务端推送的 data: URI（SSE / 首屏内联），省掉一次图片请求
      if (state.pushedQr) img.src = state.pushedQr;
      else img.src = '/api/qr.png?v=' + encodeURIComponent(key);
      state.qrKey = key;
      state.pushedQr = '';
    }
    if (!qr.present) state.qrKey = 'none';

    img.hidden = !qr.present;
    empty.hidden = !!qr.present;
    if (!qr.present) setText(empty, qr.botOnline ? '已登录，NapCat 已移除二维码' : '还没有二维码');

    const spent = qr.state === 'expired' || qr.state === 'used';
    box.classList.toggle('spent', spent);
    box.setAttribute('data-overlay', spent ? (qr.botOnline ? '已登录' : '已作废') : '');

    const stEl = $('qrState');
    stEl.classList.remove('live', 'stale', 'expired', 'used', 'loggedin');
    stEl.classList.add(qr.state || 'waiting');
    setText($('qrStateText'), qr.label || '—');
    setText($('qrHint'), qr.hint || '');
    setText($('qrTag'), qr.present ? '更新于 ' + fmtAgo(qr.ageSec) : qr.state === 'loggedin' ? '已登录' : '');
  }

  function renderAstrbot(st) {
    const ab = st.astrbot || {};
    const big = $('abBig');
    big.classList.remove('online', 'offline', 'unknown');
    big.classList.add(!ab.available ? 'unknown' : ab.healthy ? 'online' : 'offline');
    setText($('abState'), !ab.available ? '无数据' : ab.healthy ? '在线' : stateLabel(ab.state));
    setText($('abTag'), ab.available ? fmtAgo(ab.ageSec) : '');
    setText($('k-abport'), ab.available ? (ab.portOk ? '正常' : '不通') + (ab.note ? ' · ' + ab.note : '') : '—');
    setText($('k-abrestart'), ab.available ? ab.restarts + ' 次' : '—');
    setText($('k-absince'), ab.since ? fmtLocal(ab.since) : '—');
    setText($('k-abat'), ab.at ? fmtLocal(ab.at) : '—');
  }

  function renderTunnel(st) {
    const tn = st.tunnel || {};
    const big = $('tnBig');
    big.classList.remove('online', 'offline', 'unknown');
    big.classList.add(!tn.available ? 'unknown' : tn.ok ? 'online' : 'offline');
    setText($('tnState'), !tn.available ? '无数据' : tn.ok ? '正常' : '异常');
    setText($('tnTag'), tn.available ? fmtAgo(tn.ageSec) : '');
    setText($('k-tnprov'), tn.provider || '—');
    const url = $('k-tnurl');
    if (tn.url) {
      url.textContent = '';
      const a = document.createElement('a');
      a.href = tn.url;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      a.textContent = tn.url.replace(/^https?:\/\//, '');
      url.appendChild(a);
    } else setText(url, '—');
    setText($('k-tnfail'), tn.available ? tn.failStreak + ' 次' : '—');
    setText($('k-tnat'), tn.at ? fmtLocal(tn.at) : '—');
  }

  function renderGuardian(st) {
    const gd = st.guardian || {};
    const big = $('gdBig');
    big.classList.remove('online', 'offline', 'unknown');
    big.classList.add(!gd.available ? 'unknown' : gd.alive ? 'online' : 'offline');
    setText($('gdState'), !gd.available ? '无数据' : gd.alive ? '运行中' : '心跳中断');
    setText($('gdTag'), gd.at ? fmtAgo(gd.ageSec) : '');
    setText($('k-gdpid'), gd.pid != null ? String(gd.pid) : '—');
    setText($('k-gdbeat'), gd.at ? fmtLocal(gd.at) + '（' + fmtAgo(gd.ageSec) + '）' : '—');
    setText($('k-uptime'), st.server ? fmtDuration(st.server.uptimeSec) : '—');
  }

  function renderNotify(st) {
    const nf = st.notify || {};
    // 邮件是主通道，只显示状态，不提供关闭开关。
    setText($('nfEmail'), nf.email ? '已启用' : '未配置');
    // 程序化写 checkbox 时先置标志，避免触发 change 误发请求。
    state.syncingNotify = true;
    $('nfNtfy').checked = !!nf.ntfy;
    $('nfToast').checked = !!nf.toast;
    state.syncingNotify = false;
  }

  function renderWarnings(st) {
    const box = $('banner');
    const list = $('bannerList');
    const ws = Array.isArray(st.warnings) ? st.warnings : [];
    list.textContent = '';
    if (!ws.length) {
      box.hidden = true;
      return;
    }
    for (const w of ws) {
      const li = document.createElement('li');
      li.textContent = w;
      list.appendChild(li);
    }
    box.hidden = false;
  }

  function renderActionsHistory(st) {
    const ul = $('actHistory');
    const ring = Array.isArray(st.actions) ? st.actions : [];
    ul.textContent = '';
    if (!ring.length) {
      const li = document.createElement('li');
      li.className = 'dim';
      li.textContent = '还没有执行过动作';
      ul.appendChild(li);
      return;
    }
    for (const a of ring.slice(0, 8)) {
      const li = document.createElement('li');
      const mark = document.createElement('span');
      mark.className = a.ok ? 'ok' : 'no';
      mark.textContent = a.ok ? '✓' : '✕';
      const time = document.createElement('time');
      time.textContent = fmtLocal(a.at);
      const label = document.createElement('span');
      label.textContent = a.label || a.action;
      const msg = document.createElement('span');
      msg.className = 'dim';
      msg.textContent = a.message || '';
      li.append(mark, time, label, msg);
      ul.appendChild(li);
    }
  }

  function renderLogMeta(st) {
    const meta = $('logMeta');
    const logs = Array.isArray(st.logs) ? st.logs : [];
    const cur = logs.find((l) => l.name === state.logName);
    if (!cur) {
      setText(meta, '');
      return;
    }
    setText(meta, cur.label + ' · ' + fmtBytes(cur.size) + (cur.mtime ? ' · ' + fmtAgo(Math.round((Date.now() - cur.mtime) / 1000)) + '写入' : ''));
  }

  function renderStatus(st) {
    state.lastStatus = st;
    state.csrf = st.csrf || state.csrf;
    setText($('ver'), 'v' + (st.version || '—'));
    setText($('sub'), '服务 PID ' + (st.server ? st.server.pid : '—') + ' · 端口 ' + (st.server ? st.server.port : '—'));

    renderBot(st);
    renderQr(st);
    renderAstrbot(st);
    renderTunnel(st);
    renderGuardian(st);
    renderNotify(st);
    renderWarnings(st);
    renderActionsHistory(st);
    renderLogMeta(st);
  }

  /* ------------------------------------------------------------ 网络 */

  async function getJson(url) {
    const res = await fetch(url, { credentials: 'same-origin', cache: 'no-store' });
    if (res.status === 404) throw new Error('会话已失效，请用带 ?k= 的链接重新打开页面');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
  }

  async function pollStatus() {
    if (state.paused) return;
    try {
      const st = await getJson('/api/status');
      state.failure = 0;
      setPill($('conn'), 'live');
      setText($('connText'), '实时连接');
      renderStatus(st);
      if (Date.now() - state.lastKicksAt > KICKS_EVERY_MS) loadKicks();
    } catch (e) {
      state.failure++;
      setPill($('conn'), 'bad');
      setText($('connText'), state.failure > 2 ? '连接中断' : '重试中…');
      if (state.failure === 1) toast('状态刷新失败：' + e.message, 'bad');
    }
    setText($('clock'), fmtClock(new Date().toISOString()));
  }

  function schedule() {
    if (state.timer) clearInterval(state.timer);
    startStream();
  }

  // SSE：只有状态变化时才推，避免弱网下每 3 秒一次往返；不支持时退回轮询
  function startStream() {
    if (typeof EventSource !== 'function') {
      state.timer = setInterval(pollStatus, POLL_MS);
      return;
    }
    let es;
    try {
      es = new EventSource('/api/stream');
    } catch (e) {
      state.timer = setInterval(pollStatus, POLL_MS);
      return;
    }
    state.es = es;
    es.onopen = () => {
      state.failure = 0;
      setPill($('conn'), 'live');
      setText($('connText'), '实时推送');
    };
    es.onmessage = (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      if (!msg || !msg.st) return;
      state.failure = 0;
      setPill($('conn'), 'live');
      setText($('connText'), '实时推送');
      if (msg.qr) state.pushedQr = msg.qr;
      renderStatus(msg.st);
      if (Date.now() - state.lastKicksAt > KICKS_EVERY_MS) loadKicks();
      setText($('clock'), fmtClock(new Date().toISOString()));
    };
    es.onerror = () => {
      setPill($('conn'), 'bad');
      setText($('connText'), '推送中断，重连中…');
    };
  }

  /* ------------------------------------------------------------ 被踢历史 */

  async function loadKicks() {
    state.lastKicksAt = Date.now();
    const limit = Number($('kickLimit').value) || 50;
    const body = $('kickBody');
    try {
      const data = await getJson('/api/kicks?limit=' + limit);
      setText($('kickMeta'), data.available ? '共 ' + data.total + ' 条记录 · 今日 ' + (data.kicksToday || 0) + ' 次' : '读不到 kick.log');
      body.textContent = '';
      if (!data.items || !data.items.length) {
        const tr = document.createElement('tr');
        tr.className = 'empty-row';
        const td = document.createElement('td');
        td.colSpan = 6;
        td.textContent = data.available ? '还没有被踢记录' : 'kick.log 不存在或为空';
        tr.appendChild(td);
        body.appendChild(tr);
        return;
      }
      const today = new Date();
      const md = pad(today.getMonth() + 1) + '-' + pad(today.getDate());
      for (const it of data.items) {
        const tr = document.createElement('tr');
        const cells = [
          it.at || (it.ts ? it.ts.slice(5) : '—'),
          it.gapMin != null ? it.gapMin + ' 分' : '—',
          it.sessionMin != null ? it.sessionMin + ' 分' : '—',
          it.quietMin != null ? it.quietMin + ' 分' : '—',
          it.ip || '—',
          it.logFile || '—',
        ];
        cells.forEach((c, i) => {
          const td = document.createElement('td');
          td.textContent = c;
          if (i === 2 || i === 3) td.className = 'num';
          if (i === 5) td.className = 'mono dim';
          tr.appendChild(td);
        });
        if (it.ts && it.ts.slice(5, 10) === md) tr.title = '今天：' + it.ts;
        body.appendChild(tr);
      }
    } catch (e) {
      body.textContent = '';
      const tr = document.createElement('tr');
      tr.className = 'empty-row';
      const td = document.createElement('td');
      td.colSpan = 6;
      td.textContent = '加载失败：' + e.message;
      tr.appendChild(td);
      body.appendChild(tr);
    }
  }

  /* ------------------------------------------------------------ 日志 */

  function renderLog(data, q) {
    const view = $('logView');
    view.textContent = '';
    const lines = Array.isArray(data.lines) ? data.lines : [];
    if (!lines.length) {
      view.textContent = data.available ? '没有匹配的日志行' : '日志文件不存在';
      return;
    }
    const needle = q ? q.toLowerCase() : '';
    const frag = document.createDocumentFragment();
    for (const line of lines) {
      const span = document.createElement('span');
      span.className = 'ln';
      if (/\[\s*(ERROR|FATAL)\s*\]|失败|错误|异常|崩溃/i.test(line)) span.classList.add('err');
      else if (/\[\s*WARN(ING)?\s*\]|警告|告警|重试/i.test(line)) span.classList.add('warn');
      if (needle && line.toLowerCase().includes(needle)) span.classList.add('hit');
      span.textContent = line;
      frag.appendChild(span);
    }
    view.appendChild(frag);
    view.scrollTop = view.scrollHeight;
  }

  async function loadLog() {
    const name = state.logName;
    const q = $('logQ').value.trim();
    const level = $('logLevel').value;
    const lines = $('logLines').value;
    const view = $('logView');
    try {
      const url = '/api/logs?name=' + encodeURIComponent(name) + '&lines=' + encodeURIComponent(lines) + '&level=' + encodeURIComponent(level) + '&q=' + encodeURIComponent(q);
      const data = await getJson(url);
      renderLog(data, q);
      setText($('logMeta'), (data.label || name) + ' · 显示 ' + data.shown + ' 行 · 文件 ' + fmtBytes(data.size) + (data.truncated ? ' · 只读了尾部' : ''));
    } catch (e) {
      view.textContent = '加载失败：' + e.message;
    }
  }

  function setLogAuto(on) {
    if (state.logTimer) {
      clearInterval(state.logTimer);
      state.logTimer = null;
    }
    if (on) state.logTimer = setInterval(loadLog, LOG_AUTO_MS);
  }

  /* ------------------------------------------------------------ 受保护动作 */

  const ACTIONS = [
    {
      name: 'restart-worker',
      label: '重启 NapCat worker',
      phrase: '重启',
      risk: 'medium',
      desc: '调用 NapCat WebUI 的 RestartNapCat 接口，只重启 worker、不杀进程，一般用缓存票据直接登回来（约 20~60 秒）。',
      warn: '正在收发消息时执行会短暂掉线；如果票据失效会转为扫码登录。',
    },
    {
      name: 'notify-test',
      label: '触发通知自检',
      phrase: '自检',
      risk: 'low',
      desc: '运行既有脚本 guardian.ps1 -TestNotify，往已配置的通知渠道发一条“通知自检”消息，验证告警链路是否通。',
      warn: '会给你的手机 / 邮箱推一条测试消息，不影响机器人。',
    },
    {
      name: 'guardian-start',
      label: '重新拉起守卫任务',
      phrase: '拉起',
      risk: 'medium',
      desc: '用 schtasks 启动计划任务 NapCatGuardian，由 Windows 重新拉起 guardian.ps1。',
      warn: '守卫进程还在跑时会被互斥体挡住；心跳正常时本服务会直接拒绝。',
    },
    {
      name: 'full-restart',
      label: '全量重启 NapCat',
      phrase: '全量重启',
      risk: 'high',
      desc: '运行既有脚本 restart_napcat.ps1：投递 force-relaunch.flag，守卫会杀掉 QQ 并重新注入，耗时 1~3 分钟。',
      warn: '需要完整重登，可能要重新扫码，期间机器人完全不可用。',
    },
  ];

  function renderActions() {
    const box = $('actions');
    box.textContent = '';
    for (const a of ACTIONS) {
      const card = document.createElement('div');
      card.className = 'action';

      const t = document.createElement('div');
      t.className = 't';
      const name = document.createElement('span');
      name.textContent = a.label;
      const badge = document.createElement('span');
      badge.className = 'badge ' + a.risk;
      badge.textContent = a.risk === 'low' ? '低风险' : a.risk === 'medium' ? '中风险' : '高风险';
      t.append(name, badge);

      const d = document.createElement('div');
      d.className = 'd';
      d.textContent = a.desc;

      const row = document.createElement('div');
      row.className = 'row';
      const hint = document.createElement('span');
      hint.className = 'small dim';
      hint.textContent = '需要手打「' + a.phrase + '」';
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = a.risk === 'high' ? 'danger small' : 'small';
      btn.textContent = '执行…';
      btn.setAttribute('aria-label', '执行动作：' + a.label);
      btn.addEventListener('click', () => openDialog(a));
      row.append(hint, btn);

      card.append(t, d, row);
      box.appendChild(card);
    }
  }

  const dlg = $('dlg');
  const dlgPhrase = $('dlgPhrase');
  const dlgOk = $('dlgOk');
  const dlgMsg = $('dlgMsg');

  function normPhrase(s) {
    return String(s || '').replace(/\s+/g, '');
  }

  function openDialog(a) {
    state.dialogAction = a;
    setText($('dlgTitle'), '确认：' + a.label);
    setText($('dlgDesc'), a.desc);
    setText($('dlgWarn'), '⚠ ' + a.warn);
    setText($('dlgLabel'), '请手打「' + a.phrase + '」以确认');
    dlgPhrase.value = '';
    dlgOk.disabled = true;
    dlgOk.textContent = '确认执行';
    dlgMsg.textContent = '';
    dlgMsg.className = 'dlg-msg';
    if (typeof dlg.showModal === 'function') dlg.showModal();
    else dlg.setAttribute('open', 'open');
    setTimeout(() => dlgPhrase.focus(), 30);
  }

  function closeDialog() {
    state.dialogAction = null;
    if (typeof dlg.close === 'function') dlg.close();
    else dlg.removeAttribute('open');
  }

  dlgPhrase.addEventListener('input', () => {
    const a = state.dialogAction;
    const ok = !!a && normPhrase(dlgPhrase.value) === a.phrase;
    dlgOk.disabled = !ok;
    if (!ok && dlgPhrase.value.trim() && a) {
      setText(dlgMsg, '确认词不匹配：需要一字不差地手打「' + a.phrase + '」');
      dlgMsg.className = 'dlg-msg warn';
    } else if (dlgMsg.classList.contains('warn')) {
      setText(dlgMsg, '');
      dlgMsg.className = 'dlg-msg';
    }
  });

  dlgPhrase.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      if (!dlgOk.disabled) dlgOk.click();
    }
  });

  $('dlgCancel').addEventListener('click', closeDialog);

  dlgOk.addEventListener('click', async () => {
    const a = state.dialogAction;
    if (!a) return;
    if (normPhrase(dlgPhrase.value) !== a.phrase) {
      dlgMsg.textContent = '确认词不正确';
      dlgMsg.className = 'dlg-msg bad';
      return;
    }
    dlgOk.disabled = true;
    dlgOk.textContent = '执行中…';
    dlgMsg.textContent = '正在下发指令…';
    dlgMsg.className = 'dlg-msg';
    let done = false;
    try {
      const res = await fetch('/api/action', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json', 'x-csrf': state.csrf },
        body: JSON.stringify({ action: a.name, phrase: normPhrase(dlgPhrase.value) }),
      });
      const data = await res.json().catch(() => ({ ok: false, message: 'HTTP ' + res.status }));
      if (res.ok && data.ok) {
        done = true;
        dlgMsg.textContent = '✓ ' + (data.message || '已执行');
        dlgMsg.className = 'dlg-msg good';
        toast(a.label + '：' + (data.message || '已执行'), 'ok');
        dlgOk.textContent = '完成';
        setTimeout(() => {
          closeDialog();
          pollStatus();
          loadKicks();
        }, 1400);
        return;
      }
      dlgMsg.textContent = '✕ ' + (data.message || '执行失败');
      dlgMsg.className = 'dlg-msg bad';
      toast(a.label + '失败：' + (data.message || '未知错误'), 'bad');
    } catch (e) {
      dlgMsg.textContent = '✕ ' + e.message;
      dlgMsg.className = 'dlg-msg bad';
    } finally {
      if (!done) {
        dlgOk.textContent = '确认执行';
        dlgOk.disabled = false;
      }
    }
  });

  /* ------------------------------------------------------------ 事件绑定 */

  async function saveNotify(changes) {
    try {
      const res = await fetch('/api/notify-config', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json', 'x-csrf': state.csrf },
        body: JSON.stringify(changes),
      });
      const data = await res.json().catch(() => ({ ok: false }));
      if (res.ok && data.ok) {
        toast('通知设置已保存，重启守卫后生效', 'ok');
        return;
      }
      toast('保存失败：' + (data.message || '未知错误'), 'bad');
    } catch (e) {
      toast('保存失败：' + e.message, 'bad');
    }
    // 失败后立即拉一次状态，把开关还原到服务端真实值。
    pollStatus();
  }

  $('nfNtfy').addEventListener('change', () => {
    if (state.syncingNotify) return;
    saveNotify({ ntfy: $('nfNtfy').checked });
  });

  $('nfToast').addEventListener('change', () => {
    if (state.syncingNotify) return;
    saveNotify({ toast: $('nfToast').checked });
  });

  $('pauseBtn').addEventListener('click', () => {
    state.paused = !state.paused;
    const b = $('pauseBtn');
    b.setAttribute('aria-pressed', state.paused ? 'true' : 'false');
    b.textContent = state.paused ? '继续刷新' : '暂停刷新';
    setPill($('conn'), state.paused ? 'warn' : 'live');
    setText($('connText'), state.paused ? '已暂停' : '实时连接');
    if (!state.paused) pollStatus();
  });

  $('kickLimit').addEventListener('change', loadKicks);
  $('kickRefresh').addEventListener('click', loadKicks);

  document.querySelectorAll('[data-log]').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('[data-log]').forEach((b) => b.setAttribute('aria-pressed', b === btn ? 'true' : 'false'));
      state.logName = btn.getAttribute('data-log');
      renderLogMeta(state.lastStatus || {});
      loadLog();
    });
  });

  $('logRefresh').addEventListener('click', loadLog);
  $('logLevel').addEventListener('change', loadLog);
  $('logLines').addEventListener('change', loadLog);
  $('logQ').addEventListener('change', loadLog);
  let qTimer = null;
  $('logQ').addEventListener('input', () => {
    if (qTimer) clearTimeout(qTimer);
    qTimer = setTimeout(loadLog, 350);
  });
  $('logAuto').addEventListener('change', (e) => setLogAuto(e.target.checked));

  // 页面回到前台时立刻刷新一次，避免看到的是几分钟前的状态
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !state.paused) pollStatus();
  });

  // Esc 关对话框（<dialog> 原生就支持，这里兜住非原生实现）
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && state.dialogAction) closeDialog();
  });

  /* ------------------------------------------------------------ 启动 */

  renderActions();
  setText($('clock'), fmtClock(new Date().toISOString()));

  // 单文件页面会把首屏状态和二维码内联进来：先画出来，不等任何网络
  if (window.__BOOT__ && window.__BOOT__.st) {
    try {
      if (window.__BOOT__.qr) state.pushedQr = window.__BOOT__.qr;
      renderStatus(window.__BOOT__.st);
      setPill($('conn'), 'live');
      setText($('connText'), '实时推送');
    } catch (e) {
      /* 首屏渲染失败就靠后面的推送 */
    }
  } else {
    pollStatus();
  }
  schedule();
  loadKicks();
  loadLog();
})();
