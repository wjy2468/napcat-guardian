# NapCat 机器人控制台（web-console）

一个零依赖的中文 Web 控制台，用浏览器远程看住这台 Windows 机器上的 NapCat QQ 机器人：在线状态、登录二维码、被踢历史、AstrBot 与扫码通道健康状况、三份日志的尾部，以及四个需要二次确认的受保护动作。

- 独立服务，**不改动** `D:\napcat\qrsync\*`、`D:\napcat\guardian.ps1` 等生产文件，只读取它们。
- 只用 Node 内置模块，**没有任何 npm 依赖**（`node server.js` 就能跑）。
- 默认监听 `127.0.0.1:8440`，配合 ngrok / Cloudflare 隧道从公网访问。
- 页面源码和接口响应里不会出现 QQ 号、邮箱、WebUI token、ngrok token、完整出口 IP。
> 截图未随仓库分发（含本机运行数据），可自行打开 http://127.0.0.1:8440/?k=<你的key> 查看。

---

## 0. 性能：单文件 + gzip + SSE（2026-11-17 改造）

公网经 ngrok 往返一次要 0.3–1.4 秒，原来的 4 请求 + 3 秒轮询在弱网手机上体验很差。现在：

| 指标 | 改前 | 改后 |
| --- | --- | --- |
| 首屏请求数 | 4（HTML + CSS + JS + 图标） | **1** |
| 首屏传输量 | ~51 KB（无压缩） | **18.2 KB**（gzip） |
| 二维码 | 打开后再请求一次 | 内联在 HTML（data URI），首屏即见 |
| 打开后的网络活动 | 每 3 秒轮询，20 次/分 | **0 次空闲请求**，状态变了才推 |

实现要点：

- `buildInlinePage(nonce)` 把 `style.css` / `app.js` / `favicon.svg` 内联进 HTML，并注入 `window.__BOOT__`（首屏状态 + 二维码 data URI）；
- 所有文本响应按 `Accept-Encoding` 自动 gzip；
- `/api/stream` 是 SSE：服务端每 2 秒比对状态指纹，变化才发 `data:`；客户端 `EventSource` 自动重连，失败时降级回轮询；
- CSP 用**每请求随机 nonce**，不再需要 `unsafe-inline` 放行内联脚本。
## 1. 目录结构

```
web\
├─ server.js             # 服务本体（HTTP、鉴权、数据聚合、动作下发、SSE）
├─ start-console.ps1     # 启动器：互斥体防双开 + 崩溃后逐步退避重启 + console.log
├─ config.example.json   # 配置模板（复制为 config.json 后填 key）
├─ config.json           # 本服务自己的配置（含访问 key，勿提交/外传）
├─ console.log           # 启动器与 node 的输出（由 start-console.ps1 追加）
├─ actions.log           # 受保护动作审计日志（一行一次）
├─ README.md             # 本文
└─ public\
   ├─ index.html         # 页面骨架
   ├─ app.js             # 前端逻辑（SSE 实时推送 + 降级轮询、二次确认、日志筛选）
   ├─ style.css          # 深色主题、响应式布局
   └─ favicon.svg        # 站点图标
```

服务只读取下面这些生产数据（全部是只读）：

| 文件 | 用途 |
| --- | --- |
| `D:\napcat\metrics.json` | 机器人状态快照（守卫每 ~20 秒重写） |
| `D:\napcat\qrsync\login-state.json` | 登录态与说明 |
| `D:\napcat\session-since.txt` | 本次在线会话的起始时间 |
| `D:\napcat\kick.log` | 被踢历史 |
| `D:\napcat\NapCat.Shell\cache\qrcode.png` | 登录二维码 |
| `D:\napcat\astrbot-state.json` | AstrBot 看护状态 |
| `D:\napcat\qrsync\tunnel-state.json` | 扫码通道（ngrok）状态 |
| `D:\napcat\guardian.heartbeat` | 守卫心跳（`pid\|时间`） |
| `D:\napcat\guardian.log`、`astrbot_watchdog.log`、`qrsync\daemon.log` | 日志尾部 |
| `D:\napcat\guardian.config.json` | **仅**在内存里取 WebUI token，用于「重启 worker」 |
| `D:\napcat\qrsync\key.txt` | 首次启动时继承的访问 key |
| `D:\napcat\guardian.ps1`、`restart_napcat.ps1` | 只有你点动作按钮时才会被调用 |

---

## 2. 快速开始

### 2.1 直接运行（前台）

```powershell
cd web
& "D:\Program Files\nodejs\node.exe" server.js
```

看到下面两行就说明起来了（**不会**回显 key）：

```
[web-console] v1.0.0 listening on http://127.0.0.1:8440
[web-console] key loaded (length 16, 不回显)  home=D:\napcat
```

### 2.2 用启动器运行（推荐，崩溃自动重启）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File web\start-console.ps1
```

- 用 `Global\NapCatWebConsole` 互斥体防双开：已经在跑时第二次启动只会打印 `already running (mutex busy), exit.` 并退出（exit 0）。
- node 意外退出后自动重启：5 秒起退避，最长 60 秒；只有存活不足 30 秒的崩溃才累计失败次数。
- 输出追加到 `web\console.log`。

### 2.3 打开页面

浏览器访问：

```
http://127.0.0.1:8440/?k=<访问key>
```

`<访问key>` 的取值顺序（`server.js:94-113` 的 `resolveKey()`）：

1. 环境变量 `WEB_KEY`（只在内存生效，**不回写** `config.json`）
2. `web\config.json` 里的 `key`
3. `D:\napcat\qrsync\key.txt`（读到就写进 `config.json`，以后只认自己的配置）
4. 都没有时随机生成 24 位（`randomBytes(18).toString('base64url')`）并写回 `config.json`

首次运行会继承 qrsync 的 key，所以现有 `https://.../?k=xxx` 那套 key 直接可用。想换 key：改 `config.json` 的 `key`（或设 `WEB_KEY`）后重启服务；旧 cookie 会立刻失效。

### 2.4 可配置项

`config.json`（不存在也行，会自动创建）：

```json
{
  "key": "16 位访问 key",
  "port": 8440,
  "host": "127.0.0.1",
  "napcatHome": "D:\\napcat",
  "qrFile": "D:\\napcat\\NapCat.Shell\\cache\\qrcode.png",
  "guardianTask": "NapCatGuardian"
}
```

环境变量优先于同名配置：`WEB_KEY`、`PORT`、`HOST`、`NAPCAT_HOME`。

> `host` 默认 `127.0.0.1`：只有本机和隧道能连。除非你清楚风险，不要改成 `0.0.0.0` 直接暴露到局域网/公网。

---

## 3. 页面怎么用

### 3.1 机器人状态卡

| 显示 | 数据来源 | 口径 |
| --- | --- | --- |
| 在线 / 离线 / 在线（数据过期） | `metrics.json` 的 `state`，`login-state.json` 兜底 | `metrics.json` 的 mtime 超过 **180 秒** 判为过期，整卡转黄色 |
| 本次会话时长 | `session-since.txt` + `metrics.json.sessionMin` | 心跳能读到起始时间就按实时计算，否则用守卫写的分钟数 |
| 今日被踢 | `metrics.json.kicksToday` | 守卫自己按本地日期统计 |
| 下次探针 | `metrics.json.nextProbeAt` / `probeMin` | 显示 `14:54（每 10 分钟）` |
| 上次恢复 | `metrics.json.lastRecoverSec / lastRecoverAt / lastCause / lastPath` | 例：`耗时 1 分钟 · 原因 qr_wait / wait_scan · 11-15 14:30:18` |
| 登录记录 | `login-state.json.state/note/at` | `at` 是**状态变化**时间，不是心跳时间，所以会显示「N 分钟前」 |

顶部的橙色横幅汇总所有异常（`warnings[]`）：守卫心跳超时、`metrics.json` 过期、机器人不在线、AstrBot 异常、扫码通道失败、二维码作废等。

### 3.2 登录二维码卡

- 数据源：`D:\napcat\NapCat.Shell\cache\qrcode.png`；首屏二维码由服务端内联进 HTML（`window.__BOOT__.qr`），之后只在 `mtime`/`size` 变化时通过 SSE 推新的 data URI，不会白刷流量。
- 状态阈值（与 qrsync 完全一致）：

| 文件年龄 | 状态 | 文案 |
| --- | --- | --- |
| ≤ 150 秒 | live | 等待扫码 |
| ≤ 300 秒 | stale | 二维码即将过期 |
| ≤ 900 秒 | expired | 已作废（码被模糊处理，防止误扫） |
| > 900 秒 | used | 已作废 / 已登录 · 此码作废 |
| 文件不存在 | loggedin / waiting | 已登录（NapCat 登录成功会删掉二维码）/ 等待扫码 |

- `/api/qr.png` 会先校验 PNG 文件头，文件正在被写入（半张图）时返回 503，前端自动重试；带 `ETag`，未变化时返回 `304`。

### 3.3 被踢历史表

解析 `kick.log` 里这种行（`at=`、`session=`、`ip=` 都是可选的，早期记录没有）：

```
[2026-11-15 14:28:18] KICKED | at=11-15 14:27:55 | log=2026-11-15_13-08-58.343.log | session=72 min | quiet_before_kick=9 min | ip=26.15.34.205
```

- 列：被踢时间 / 间隔（与上一条的分钟差）/ 会话 / 静默 / 出口 IP / QQ 日志文件名。
- **出口 IP 打码成 `26.15.*.*`** 才下发到前端。
- 显示条数可选 20 / 50 / 100 条，表格记录总数与今日次数。

### 3.4 AstrBot、扫码通道、守卫进程卡

| 卡 | 数据源 | 判定 |
| --- | --- | --- |
| AstrBot | `astrbot-state.json` | `state=online` 且 `portOk=true` 且写入时间 ≤ 300 秒 = 在线；显示端口是否正常、累计重启次数、启动时间 |
| 扫码通道 | `qrsync/tunnel-state.json` | `ok=true` = 正常；显示 provider、公网地址、连续失败次数 |
| 守卫进程 | `guardian.heartbeat` | `pid\|时间`，心跳 < 180 秒 = 运行中；超过 3 分钟顶部横幅报警 |

### 3.5 日志查看

三份日志任选一份，尾部 N 行（1–1000，默认 200），支持关键字过滤与级别过滤：

| 日志 | 路径 |
| --- | --- |
| guardian.log | `D:\napcat\guardian.log` |
| astrbot_watchdog.log | `D:\napcat\astrbot_watchdog.log` |
| qrsync daemon.log | `D:\napcat\qrsync\daemon.log` |

- 服务端只读文件**尾部最多 4 MB**，从中取最近 4000 行再过滤，避免把 400 MB 日志读进内存。
- 级别：`全部` / `错误`（error|fail|fatal|exception|失败|错误|异常|踢|kicked|崩溃|超时|timeout）/ `警告`（warn|警告|告警|⚠|重试|retry）。
- 命中关键字的那一行会高亮；勾选「自动刷新」每 5 秒重取一次。
- 所有日志文本在返回前经过脱敏（见第 7 节）。

### 3.6 受保护动作（必须二次确认）

四个动作都**不直接杀进程**，只调用既有脚本 / flag / NapCat 自己的接口：

| 动作 | 实现方式 | 风险 | 需手打 |
| --- | --- | --- | --- |
| 重启 NapCat worker | `POST /api/auth/login`（`sha256(webuiToken + ".napcat")`）取 Credential，再 `POST /api/QQLogin/RestartNapCat`；只重启 worker，不杀 QQ 进程 | 中 | `重启` |
| 触发通知自检 | 拉起 `guardian.ps1 -TestNotify`，发一条自检通知（ntfy → 邮件，与守卫同一条链路） | 低 | `自检` |
| 重新拉起守卫任务 | `schtasks /run /tn NapCatGuardian`；守卫内部有互斥体，心跳正常时服务直接拒绝（返回 `skipped`） | 中 | `拉起` |
| 全量重启 NapCat | 拉起既有脚本 `restart_napcat.ps1`（它投递 `force-relaunch.flag`，由守卫完成杀 QQ + 重新注入），1~3 分钟，可能要扫码 | 高 | `全量重启` |

保护链条：

1. 点「执行…」只打开确认弹窗，弹窗里写明风险与确认词；
2. 必须在输入框里**一字不差**打出确认词（空格会被忽略），否则确认按钮保持禁用并提示「确认词不匹配」；
3. 请求头必须带 `/api/status` 下发的 `x-csrf`，否则 `403`；
4. 服务端再次校验确认词（前端被绕也发不出去）；
5. 同一动作 15 秒冷却（失败也计入），超频返回 `429`；
6. 每次结果写入 `actions.log` 并显示在页面「最近动作」里。

---

## 4. 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/?k=<key>` | 页面；成功后种 `nc_session` HttpOnly Cookie（30 天） |
| GET | `/app.js`、`/style.css`、`/favicon.svg` | 静态资源（同样要求鉴权；`/` 返回的是内联版单文件页，这些路由供调试用） |
| GET | `/api/status` | 全部状态聚合 + `csrf` |
| GET | `/api/kicks?limit=50` | 被踢历史（1–500 条） |
| GET | `/api/logs?name=guardian&lines=200&q=kick&level=err` | 日志尾部（`name`∈ guardian/astrbot/qrsync） |
| GET | `/api/qr.png` | 当前二维码；支持 `ETag`/`If-None-Match` |
| POST | `/api/action` | 受保护动作，body `{"action":"guardian-start","phrase":"拉起"}`，需 `x-csrf` 头 |

鉴权方式（满足其一）：`?k=<key>`、请求头 `x-key: <key>`、Cookie `nc_session`。未通过一律返回 **404**（不暴露服务存在）。

PowerShell 5.1 调用示例：

```powershell
$key = Get-Content -Raw D:\napcat\qrsync\key.txt
$s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-WebRequest "http://127.0.0.1:8440/?k=$($key.Trim())" -WebSession $s -UseBasicParsing | Out-Null
(Invoke-WebRequest "http://127.0.0.1:8440/api/status" -WebSession $s -UseBasicParsing).Content

# 受保护动作（先取 csrf；中文 body 必须用 UTF8 字节）
$st = (Invoke-WebRequest "http://127.0.0.1:8440/api/status" -WebSession $s -UseBasicParsing).Content | ConvertFrom-Json
$body = [System.Text.Encoding]::UTF8.GetBytes('{"action":"guardian-start","phrase":"拉起"}')
try {
  Invoke-WebRequest "http://127.0.0.1:8440/api/action" -WebSession $s -Method POST -Body $body `
    -ContentType 'application/json; charset=utf-8' -Headers @{ 'x-csrf' = $st.csrf } -UseBasicParsing
} catch { $r = $_.Exception.Response; (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd() }
```

---

## 5. 公网暴露（ngrok 固定域名）

### 5.1 先看清楚现状

- 扫码通道 `qrsync` 已经占用了账号下的**唯一**免费静态域名 `your-domain.ngrok-free.dev`（见 `D:\napcat\qrsync\config.json` 的 `ngrok.domain`），映射到 8430。
- `%LOCALAPPDATA%\ngrok\ngrok.yml` 里只有 `authtoken`，没有 `tunnels` 配置。
- 同一个 ngrok 免费账号**不能**把同一个静态域名同时给 8430 和 8440，所以控制台必须换域名（三选一）。

### 5.2 方案 A：第二个静态域名（最省事，推荐）

免费账号每个账号 1 个静态域名。任选其一拿到第二个域名：

1. 用**另一个 ngrok 账号**（另一个邮箱）创建静态域名，得到新的 `authtoken` + 形如 `xxxx.ngrok-free.dev` 的域名；
2. 或在原账号上升级/增购静态域名。

然后启动控制台隧道（新账号的 authtoken 用 `--authtoken` 传入，不覆盖既有配置）：

```powershell
ngrok http 8440 --url https://<你的第二个静态域名>.ngrok-free.dev --authtoken <新账号authtoken> --log stdout
```

公网访问：

```
https://<你的第二个静态域名>.ngrok-free.dev/?k=<访问key>
```

> 免费版浏览器首次访问会先看到 ngrok 的提示页，点 **Visit Site** 即可继续；`?k=` 会保留。

### 5.3 方案 B：临时地址（不改任何配置，适合临时看一眼）

```powershell
ngrok http 8440 --log stdout
```

输出里的 `https://xxxx-xx-xx-xx-xx.ngrok-free.app` 就是临时地址，**每次重启都会变**。适合出差时临时用，不适合长期。

### 5.4 方案 C：Cloudflare 命名隧道（有自己域名时最稳）

```powershell
# 一次性：登录并创建命名隧道
cloudflared tunnel login
cloudflared tunnel create napcat-console

# 绑定域名（例：console.example.com）
cloudflared tunnel route dns napcat-console console.example.com

# 常驻运行（把 8440 暴露到该域名）
cloudflared tunnel run --url http://127.0.0.1:8440 napcat-console
```

访问 `https://console.example.com/?k=<访问key>`。Cloudflare 不会插提示页，也不会像 ngrok 免费版那样每 2 小时换地址。

### 5.5 与既有扫码通道共存

- 两套隧道互不影响：qrsync 继续用自己的域名指向 8430，控制台指向 8440。
- 建议给控制台单独一个进程/计划任务，别塞进 qrsync 的 provider 列表里（那是给扫码页用的，改动会影响扫码）。
- 反向代理时服务端靠 `x-forwarded-proto` 判断是否加 `Secure` Cookie，ngrok/cloudflared 都会正确带上。

---

## 6. 开机自启

### 6.1 任务计划程序（推荐，管理员 PowerShell）

```powershell
schtasks /create /tn NapCatWebConsole `
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"web\start-console.ps1\"" `
  /sc onstart /ru SYSTEM /rl highest /delay 0001:00 /f
```

- `/sc onstart`：开机即起（不需要登录）；`/delay 0001:00` 等 1 分钟，避开开机时的磁盘/网络抢占。
- 想改成「登录后才起」：`/sc onlogon /ru <你的用户名>`（不需要 `highest`）。
- 验证：

```powershell
schtasks /query /tn NapCatWebConsole /v /fo list
schtasks /run  /tn NapCatWebConsole        # 手动触发一次
Get-Content -Tail 5 web\console.log
```

- SYSTEM 身份运行时 `%USERPROFILE%` 是 `C:\Windows\system32\config\systemprofile`；如果你把 ngrok / cloudflared 也做成 SYSTEM 服务，注意它们读不到用户目录下的 `ngrok.yml`，要显式 `--config` 指定。

### 6.2 启动文件夹（没有管理员权限时）

`Win+R` → `shell:startup` → 放一个快捷方式，目标：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "web\start-console.ps1"
```

缺点：必须登录才启动，且窗口在用户会话里。

### 6.3 隧道也自启

把第 5 节选定的 `ngrok http ...` 或 `cloudflared tunnel run ...` 同样做成一个 `onstart` 任务（或包一层小 ps1，掉线后循环重启），与 `NapCatWebConsole` 分开，互不牵连。

---

## 7. 安全设计

| 项 | 做法 |
| --- | --- |
| 地址栏 key | 校验后立刻换成 HttpOnly + SameSite=Strict 的 `nc_session` Cookie，之后页面里的 fetch / `<img>` 都不再携带 key；走 https 时自动加 `Secure` |
| 未授权请求 | 统一返回纯文本 `404 Not Found`，不区分「服务存在但没权限」 |
| 越权写操作 | `/api/action` 必须带 `/api/status` 下发的 `x-csrf`（HMAC 派生，随 key 变化），并再次校验确认词 |
| 注入与点击劫持 | 严格 CSP：`default-src 'none'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`；无内联脚本/样式；`x-frame-options: DENY`、`x-content-type-options: nosniff`、`referrer-policy: no-referrer` |
| 敏感值脱敏 | 返回前统一 `scrub()`：`guardian.config.json` 里的 webuiToken / ntfy topic / 邮箱账号密码 / ngrok authtoken / 二维码链接里的 `?k=` / QQ 号（`metrics.json`、`login-state.json` 的 `uin`）/ 访问 key 本身，全部替换为 `***`；再用正则兜底邮箱、`?k=`、`uin=`；`kick.log` 的出口 IP 打码成 `x.y.*.*` |
| 不碰生产文件 | 仅只读；动作全部交给既有脚本、flag 文件或 NapCat 自身 API，服务本身不 `Stop-Process`、不杀 QQ |
| 审计 | 每次动作写 `actions.log`（时间、动作、成功/失败、来源 IP、结果），页面保留最近 20 条 |
| 日志读取 | 只读文件尾部 4 MB / 4000 行，避免大文件拖垮内存 |

**已知风险，请自行评估：**

- 这是「知道地址 + key 就能操作机器人」的模型。key 泄露 = 别人可以重启机器人。请勿把带 `?k=` 的链接发到群里、贴进工单或截图；浏览器历史、代理日志都会留下 key。
- ngrok 免费版会把请求日志展示在它自己的后台；如需更私密，用 Cloudflare 隧道 + 自己的域名。
- 服务默认只监听 `127.0.0.1`；不要在没有额外防护（防火墙、限速、IP 白名单）的情况下直接 `HOST=0.0.0.0` 暴露到公网。
- `config.json` 含明文 key，注意目录权限；本 README 与截图里均未包含 key、QQ 号或邮箱。

---

## 8. 自测记录（本次真实执行）

环境：Windows，Node v24.18.1，PowerShell 5.1，Chrome（headless）。

### 8.1 启动与页面

| 项 | 命令 / 动作 | 结果 |
| --- | --- | --- |
| 语法检查 | `node --check server.js`、`node --check public/app.js` | 均通过 |
| 启动 | `start-console.ps1` | 监听 `http://127.0.0.1:8440`；`console.log` 出现 listening 行与 `key loaded (length 16, 不回显)` |
| 首页 | `GET /?k=<key>` | `200`，8659 字节，`Set-Cookie: nc_session=…; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000`；页面内不含 key |
| 首页 | `GET /?k=…` | `200`，未压缩 55,093 B → gzip **18,176 B**（内联 CSS/JS/图标/首屏二维码） |
| favicon 兜底 | `GET /favicon.ico` | `204`（空响应，避免 404 噪音） |
| 双开保护 | 再执行一次 `start-console.ps1` | 打印 `already running (mutex busy), exit.`，exit 0，原进程不受影响 |
| 崩溃自愈 | 强杀 node 进程（pid 8780） | 5 秒后自动拉起新进程（pid 13384）并重新监听 8440，页面仍 `200`；`console.log` 记录 `node exited with -1` → `restarting in 5s` |
| 端口覆盖 | `PORT=8450 node server.js` | `/api/status` 返回 `server.port = 8450`，测完已停止 |

### 8.2 鉴权与安全头

| 项 | 结果 |
| --- | --- |
| 未授权 `/`、`/api/status`、`/app.js`、`/api/qr.png`、`/?k=wrongkey123` | 全部 `404`，响应体只有 `Not Found` |
| 鉴权后仅用 Cookie 访问 `/api/status`、`/api/kicks`、`/api/logs` | 全部 `200` |
| 安全响应头 | `content-security-policy`（见第 7 节）、`x-content-type-options: nosniff`、`x-frame-options: DENY`、`referrer-policy: no-referrer`、`cross-origin-opener-policy: same-origin`、`cache-control: no-store` |
| 敏感串扫描 | 把 `/api/status` + `/api/kicks` + 三份日志的完整响应拼起来，搜索 QQ 号（`metrics.json` / `login-state.json` 的 `uin` 字段原值）、邮箱地址与邮箱域名、qrsync key、`webuiToken`、`ntfyTopic`、ngrok authtoken：**全部未命中**；`index.html` / `app.js` 源码同样未命中（本文档也不含这些原值） |

### 8.3 接口数值（自测当时的真实响应）

| 接口 | 结果摘要 |
| --- | --- |
| `GET /api/status` | `200`；`bot.state=online`、`bot.stale=true`（`ageSec=611`）、`kicksToday=3`、`lastRecover.sec=98`、`loginState.state=need_scan`；`qr.present=true`；`astrbot.healthy=true`；`tunnel.ok=true`；`guardian.alive=true`（`pid` 有值）；`warnings` 至少含「metrics.json 超过 3 分钟没更新，机器人状态可能已过期」 |
| （同一接口，隔几分钟再取） | 二维码码龄涨到 303 秒后 `qr.state` 从 `live` → `expired`（`label=已作废`、`botOnline=false`），`warnings` 变成 2 条、多出「二维码需要重新生成：已作废」——说明阈值判定与横幅是实时的，不是写死的 |
| `GET /api/kicks?limit=5` | `total=8`、`kicksToday=3`；首条 `ts=2026-11-15 14:28:18`、`at=11-15 14:27:55`、`sessionMin=72`、`quietMin=9`、`ip=26.15.*.*`、`gapMin=110`；早期记录缺字段时返回 `null`（页面显示 `—`） |
| `GET /api/kicks`（不带 limit） | 默认 50 条上限生效，本次返回 `items=8`（= 全部记录） |
| `GET /api/logs?name=guardian&lines=5` | `shown=5`、`matched=4000`、`size=482779` 字节、`truncated=false` |
| `GET /api/logs?name=guardian`（不带 lines） | 默认 200 行：`shown=200`、`filter.lines=200` |
| `GET /api/logs?name=guardian&level=err&lines=1000` | `matched=202` |
| `GET /api/logs?name=guardian&q=kick` | `matched=13`、`shown=13` |
| `GET /api/logs?name=guardian&q=alive` | `matched=373`、`shown=200` |
| `GET /api/logs?name=../server` | `404`（日志名白名单，不能路径穿越） |
| `GET /api/qr.png` | `200 image/png`，593 字节，`ETag "1794725862261-593"`；带 `If-None-Match` → `304` |

### 8.4 受保护动作

| 用例 | 结果 |
| --- | --- |
| 缺 `x-csrf` | `403 {"ok":false,"message":"会话校验失败，请刷新页面重试"}` |
| 确认词错误 | `400`「确认词不正确：请手打「拉起」」（服务端二次校验生效） |
| 未知动作 `rm-rf` | `404`「未知动作」 |
| 合法 `guardian-start`（心跳正常） | `200 {"ok":true,"skipped":true,"message":"守卫心跳正常（4 秒前，pid 16940），已在运行，未重复拉起。"}` |
| 15 秒内重放同一动作 | `429`「动作太频繁：15 秒后再试」 |
| 非法 JSON body | `400`「请求体不是合法 JSON」 |
| 审计 | `actions.log` 落一行：`[2026-11-15T06:53:51.993Z] guardian-start OK from 127.0.0.1 :: 守卫心跳正常（4 秒前，pid 16940），已在运行，未重复拉起。` |

> **未真实执行**的动作：`restart-worker`（会让机器人短暂掉线）、`notify-test`（会真的发一条通知）、`full-restart`（1~3 分钟停机且可能要扫码）。为避免影响线上，只验证了它们的鉴权 / 校验 / 冷却路径；三个动作的实现与 `guardian.ps1` 已跑通的同款逻辑逐行对齐（登录接口、`-TestNotify`、`force-relaunch.flag`）。

### 8.5 页面渲染与交互（Chrome headless + CDP）

| 项 | 结果 |
| --- | --- |
| 1280px 视口 | `scrollWidth=1280`（无横向溢出）；8 行被踢记录；200 行日志；4 个动作按钮；状态「在线（数据过期）」「等待扫码」 |
| 390px 视口 | `scrollWidth=390`（无横向溢出，表格在卡片内横向滚动）；布局单列 |
| 控制台报错 | **0 条**（含 CSP 违规、JS 异常；`favicon` 与内联样式问题已修掉） |
| 二次确认弹窗 | 点「执行…」→ 弹窗标题「确认：重启 NapCat worker」，提示「请手打「重启」以确认」，风险文案齐全 |
| 错误确认词 | 输入「随便写写」→ 确认按钮保持禁用，提示「确认词不匹配：需要一字不差地手打「重启」」 |
| 取消 | 点「取消」→ 弹窗关闭，未发出任何请求 |
| 日志切换 | 切到 `astrbot_watchdog.log` → 元信息与 200 行内容更新 |
| 关键字过滤 | `guardian` + `kick` → 13 行，元信息显示「显示 13 行」 |
| 暂停刷新 | 点「暂停刷新」→ 按钮变「继续刷新」、顶栏变「已暂停」；再点恢复「实时连接」 |
| 截图 | 未随仓库分发（含本机运行数据），自行打开页面查看 |

> 自测时正好赶上守卫在 14:49 做了一次全量重启：`metrics.json` 停在 14:48:49 不再更新，页面如实显示了「在线（数据过期）」+ 顶部黄色横幅，二维码仍是新生成的 `live` 状态——恰好是这套控制台最该起作用的场景。

---

## 9. 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| 打开页面 404 | 没带 `?k=` 或 key 不对；key 见 `config.json`、`qrsync\key.txt` 或 `WEB_KEY`。换过 key 后旧链接全部失效 |
| 页面空白、控制台有 CSP 报错 | 你改过 `index.html` 加了内联 `<script>`/`style="..."`；服务端给每个请求生成随机 nonce，只信任它注入的那两个 script，手写的内联脚本会被拦下，请放进 `app.js`/`style.css` |
| 二维码不刷新 | 看 `qrcode.png` 的 mtime；NapCat 登录成功后会删除该文件，此时显示「已登录」 |
| 顶部一直提示「metrics.json 超过 3 分钟没更新」 | 守卫卡住或正在重启：看 `guardian.log` 尾部，必要时用「重新拉起守卫任务」 |
| 端口被占用（`EADDRINUSE`） | `Get-NetTCPConnection -LocalPort 8440 -State Listen` 找进程；本服务自己的 node 命令行是 `node server.js` |
| 「重启 worker」返回 502 | NapCat WebUI 6099 没起来，或 `guardian.config.json` 的 `webuiToken` 变了；先看日志确认 6099 是否 200 |
| ngrok 打开 502 | 隧道指向的端口不对（应 `8440`），或控制台没在跑；`ngrok http 8440` 的输出里能看到转发目标 |
| 动作返回 429 | 同一动作 15 秒冷却，等一会儿再点 |
| 动作返回 403 | 页面开了太久、`csrf` 过期（重启服务后也会变），刷新页面重试 |

---

## 10. 只读保证

本次开发**没有修改**任何生产文件：

- 未写入 `D:\napcat\qrsync\*`、`D:\napcat\guardian.ps1`、`D:\napcat\guardian.config.json`、`D:\napcat\restart_napcat.ps1`、`D:\napcat\metrics.json`、`D:\napcat\kick.log` 等；这些文件的更新时间变化来自既有守护任务自身的写入。
- 新服务只写自己的目录：`config.json`、`actions.log`、`console.log`。
- 唯一会**间接**影响生产的行为是你在页面上确认执行的动作：`schtasks /run`、调用 `guardian.ps1 -TestNotify`、调用 `restart_napcat.ps1`（由它写 `force-relaunch.flag`）、调用 NapCat WebUI 的 `RestartNapCat`。

---

## 11. 版本

- **v1.0.0**（2026-11-15）：首个版本。状态 / 二维码 / 被踢历史 / 三方健康 / 日志尾部 / 四个受保护动作；零依赖；Cookie + CSRF + 强 CSP；README 含自测记录。

字体、配色与响应式断点：深色主题，≥1080px 四列（二维码卡跨两行、扫码通道跨两列），760–1080px 两列，<700px 单列。
