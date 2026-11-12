# NapCat Guardian

> 一套让 Windows 上的第三方 QQ 机器人（NapCat + AstrBot）**稳定长期挂机**的方案：保活探针 + 分场景自动恢复 + 防重启风暴熔断，**开机自动拉起**、被踢下线也能自己救回来，真正做到无人值守。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4.svg)](https://github.com/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://github.com/)

---

## 目录

- [这是什么问题](#这是什么问题)
- [工作原理](#工作原理)
- [NapCat 和 AstrBot 各需要改什么](#napcat-和-astrbot-各需要改什么)
- [桌面 QQ 与机器人共存](#桌面-qq-与机器人共存)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [关键踩坑记录](#关键踩坑记录)
- [防风控 / 养号建议](#防风控--养号建议)
- [常见问题](#常见问题)
- [免责声明](#免责声明)

---

## 这是什么问题

用 NapCat（以及 Lagrange 等第三方协议）在自己的电脑上挂 QQ 机器人，掉线有三种完全不同的形态，**混为一谈是绝大多数守护脚本越救越糟的原因**：

| 形态 | 日志特征 | 真实原因 | 正确处理 |
|------|----------|----------|----------|
| **网络层断流** | `EventChecker Failed ... {"result": 1006514, "errMsg": "网络连接异常!"}`，随后 `账号状态变更为离线`，**没有** `KickedOffLine` | NAT/路由器回收空闲长连接、WiFi 抖动 | 复活连接（重启 worker，保留 QQ 与登录票，免扫码） |
| **服务端踢线** | `[KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。` | 同账号在别处登录（手机切号最常见）、风控判定异常 | 快速登录；不行就扫码，**不要反复重启** |
| **僵死态** | `CheckLoginStatus` 返回 `isLogin: true` 但 `loginError: "登录态已失效"`，`get_status` 仍是 `online: true` | 登录态已废但客户端没意识到，**收不到也发不出消息** | `RestartNapCat` 重启 worker，用缓存 token 登回 |

> 网上流传的"**23 分钟无消息就被踢**"只对第一种形态的早期版本成立。我们连续记录了 6 次真正的 `KickedOffLine`，**全部发生在正在聊天的时段**，最近一次距上一条保活消息只有 4 分钟 —— 可见"静默被踢"不是主因，把保活间隔调到 3 分钟也救不了切号造成的踢线。

此外还有两个**自己折腾自己**的坑，社区里大量"越挂越容易被踢、最后被冻结"的案例都出在这里：

- **重启风暴**：守护脚本靠扫（累积的）日志关键字判断状态 → 误判 → 每几分钟杀一次进程 → 连续无效登录尝试 → 腾讯风控直接冻结账号。
- **杀错进程**：`taskkill /f /im QQ.exe` 会把用户桌面上正在用的大号 QQ 一起杀掉。

本项目就是把这些坑全部填掉，让机器人真正无人值守。

## 工作原理

```
┌──────────────────────────────────────────────────────────────┐
│  Plan Task: NapCatGuardian (Highest, AtLogOn, Restart x999)  │
└───────────────────────────┬──────────────────────────────────┘
                            │
                  ┌─────────▼─────────┐
                  │   guardian.ps1    │  每 20 秒一轮
                  └─────────┬─────────┘
        ┌───────────────────┼────────────────────┬───────────────────┐
        ▼                   ▼                    ▼                   ▼
  ① 保活探针         ② 在线判定           ③ 发送失败探测        ④ 分场景恢复
  30–45 min 自聊   get_status.online    NapCat 日志"网络连接异常"  僵尸/断流/被踢
  兼健康检查        + CheckLoginStatus   （假在线最多 50 分钟）    各走各的路
        │                   │                    │                   │
        └───────────────────┴────────┬───────────┴───────────────────┘
                                     ▼
                          ④ 安全阀：单次恢复 + 120 min 熔断
                             + 02:00–07:00 夜间静默
                             + 绝不杀桌面 QQ
```

### 1. 保活：让机器人定时给自己发消息

先纠正一个常见误解：

> ⚠️ **本地 OneBot 调用（`get_status`、`get_config` 等）不会产生到腾讯服务器的协议活动，因此不能保活。只有真实的消息收发才行。**

怎么"造"一条真实消息又不打扰任何人？机器人的好友列表里包含它自己，`send_private_msg` 发给自己的 QQ 号会返回 `retcode = 0`：

- 是一条真实的私聊消息，产生真实协议活动；
- 只发给自己，**零打扰任何好友、任何群**；
- 默认 **随机 30–45 分钟**一条。

**保活真正的作用已经变了**：它不再是"防静默被踢"的银弹（见上节实测），而是

1. 维持账号的最低活跃度，避免长期零活动被判定异常；
2. **兼做健康探针** —— 发给自己时 `retcode != 0` 就说明连接已经死了，比 `get_status` 早得多。

### 2. 看门狗：先判断场景，再对症恢复

每 20 秒检测一次，连续 2 次异常（约 40 秒）才动手。恢复不是无脑杀进程：

| 当前情况 | 守护脚本的动作 |
|----------|----------------|
| **NapCat 根本没运行**（刚开机 / 崩溃后） | **立即启动**，不做无谓等待 |
| **僵死态**（`isLogin=true` + `loginError` 含"失效/重新登录"） | `RestartNapCat` 重启 worker → 等最多 240 秒缓存登录 |
| **发送失败**（日志出现 `网络连接异常`，600 秒内 2 次） | 不等 `get_status` 翻牌，直接 `RestartNapCat` 复活连接 |
| **在线过、遇到网络抖动**（`1006514`） | 先给最多 90 秒自愈时间，不杀进程 |
| **真的被踢、登录态可能仍有效** | 进程内 `SetQuickLogin` 快速登录（2 次） |
| **worker 卡死** | `RestartNapCat`（不杀 QQ，保留登录票） |
| **以上都无效** | 最后才全量重启（按进程树精确杀 + 重新注入） |
| **登录态确认失效 / 需要扫码** | 停止折腾，写状态文件 + 弹窗，等人扫码 |

> 关键原则：**能不杀进程就不杀，能不打断就不打断。**
> - WiFi 短暂波动（`1006514 网络连接异常`）几秒到十几秒会自行恢复，一发现离线就强杀 QQ，反而会让快速登录凭证失效、逼你重新扫码；
> - 开机时 NapCat 本来就没跑，空等"宽限期"毫无意义，所以直接拉起；
> - 登录态一旦明确失效，自动恢复注定失败，第一时间提示你扫码，而不是空转几轮。

### 3. 安全阀：别把自己折腾进风控

| 机制 | 默认值 | 作用 |
|------|--------|------|
| 单次恢复 + 熔断 | `$MAX_RECOVER = 1`，熔断 `120` 分钟 | 一次掉线只自动救一次；失败就停下来等人，杜绝"重启风暴" → 连续无效登录 → 冻结 |
| 夜间静默 | `02:00–07:00` | 凌晨是风控高发时段，这段时间最多每 3 小时尝试一次 |
| 不杀桌面 QQ | `Test-ForeignQq` | 检测到你自己开的 QQ 就先推迟恢复（最多 30 分钟），避免两边互踢 |
| 无窗口 | `CreateNoWindow` | 所有拉起动作都不产生控制台窗口，关掉窗口不会连带杀死机器人 |

### 4. 兜底：需要人工扫码时

1. 刷新最新的登录二维码（NapCat 等扫码时会自己每 2 分钟换码）；
2. 写 `login-state.json`（配合网页/通知显示"需要扫码"）；
3. `msg.exe` 弹系统提示框，提示二维码路径；
4. 之后每 15 秒查一次登录状态，扫上就自动恢复在线。

---

## NapCat 和 AstrBot 各需要改什么

本仓库**只包含优化/稳定部分，不包含 NapCat 与 AstrBot 的基础安装**（假设你已经装好并能正常使用）。

| 部分 | 为了本方案需要做什么 | 是否必须 |
|------|----------------------|----------|
| **NapCat** | 开启**本地 HTTP API**（`127.0.0.1:3000`），守护脚本靠它发保活、查状态；配置 `webui.json` 以使用快速登录/重启；建议打开 `fileLog`（发送失败探测要读日志） | **必须** |
| **AstrBot** | 配好反向 WebSocket（`6199`）接收 NapCat；用附带的 `scripts/astrbot_watchdog.ps1` 以**普通权限**看护 | 可选但对无人值守很实用 |

> AstrBot 由独立的 `astrbot_watchdog.ps1` 看护，**不由 guardian 启动**。原因：guardian 以最高权限运行，而 AstrBot 往往装了"电脑操控"类插件 —— 把它跑在管理员上下文里，等于把整台机器交给任何能给机器人发消息的人。这是有意为之的降权设计。

## 桌面 QQ 与机器人共存

症状：桌面 QQ 登着大号，机器人的 QQ 忽然掉线；或者反过来，你一开 QQ，两个一起死。

原因是**两者是同一个 `QQ.exe`、同一份用户数据目录**（`%APPDATA%\QQ`），Electron 的单实例锁让它们互踢。两个解决方案：

1. **数据目录隔离（推荐）**：NapCat 4.18+ 支持 `NAPCAT_QQ_DATA_DIR`。在 `guardian.ps1` 里设
   ```powershell
   $QQ_DATA_DIR = "D:\napcat\qqdata"   # 留空 = 不隔离
   ```
   guardian 启动 NapCat 时会带上这个环境变量，机器人从此拥有自己的一份 QQ 数据，与桌面 QQ 完全独立。
   代价：**切换的那一刻需要重新扫码登录一次**（新目录里没有登录票），之后就不会再互踢。

2. **只靠推迟恢复**：不隔离时，`Test-ForeignQq` 会检测到你手动开的 QQ，先推迟恢复最多 30 分钟；但两边仍然会周期性互顶，只适合偶尔用一次桌面 QQ 的场景。

---

## 目录结构

```
napcat-guardian/
├── README.md                        # 本文件
├── LICENSE                          # MIT 协议
├── scripts/
│   ├── guardian.ps1                 # 核心：保活 + 看门狗 + 分场景恢复（最高权限）
│   ├── astrbot_watchdog.ps1         # AstrBot 看护（普通权限，独立进程）
│   ├── install_guardian.ps1         # 安装器（注册为计划任务）
│   ├── install_guardian.bat         # 自提权安装器（右键管理员运行）
│   ├── network_fix.ps1              # 关闭 WiFi 网卡省电，网络更稳
│   ├── start_bot.bat                # 可选：手动一键启动 AstrBot + NapCat
│   └── qrsync/                      # 可选：把二维码同步成网页，人在外面也能扫
│       ├── qrsync.js                # 本地二维码网页（:8430，带访问密钥）
│       ├── daemon.ps1               # 常驻守护：保活服务 + 公网隧道 + 端到端自检
│       ├── start-qr.ps1             # 一次性前台模式（扫完 Ctrl+C 即收摊）
│       └── config.example.json      # 配置示例（端口/二维码路径/隧道供应商）
├── config/
│   ├── napcat/
│   │   ├── onebot11.example.json    # OneBot11：本地 HTTP API + 反向 WS（保活前提）
│   │   ├── napcat.example.json      # NapCat 运行配置（含 fileLog）
│   │   └── webui.example.json       # WebUI 配置（token 已脱敏）
│   └── astrbot/
│       └── cmd_config.example.json  # AstrBot 关键配置参考（仅对接/降级）
└── docs/
    ├── 部署指南.md
    ├── 原理说明.md
    ├── 常见问题.md
    └── 审查修复记录.md              # 一份完整的代码审查清单（含"看过但不修"的理由）
```

## 快速开始

> **前置**：已按官方文档安装好 [NapCat](https://github.com/NapNeko/NapCatQQ) 和 [AstrBot](https://github.com/AstrBotDevs/AstrBot)，机器人能扫码登录、正常收发消息。下面只做"让它挂得稳"的优化配置。

### 第 1 步：准备配置

1. 把本仓库下载/克隆到任意位置（建议纯英文路径，如 `D:\napcat-guardian`）。
2. 打开 `scripts/guardian.ps1`，改顶部 **Configuration 区**这几项（其余保持默认即可）：

```powershell
$QQ_UIN      = "YOUR_BOT_QQ"        # 机器人 QQ 号
$NAPCAT_HOME = "D:\napcat"          # 部署根目录：日志/心跳/标志文件都写在这里
$WEBUI_TOK   = "YOUR_WEBUI_TOKEN"   # NapCat WebUI token（在 NapCat 的 config/webui.json 里）
```

其余路径（`NapCat.Shell\cache\qrcode.png`、`guardian.log`、`guardian.heartbeat`、
`force-relaunch.flag`、`qrsync\login-state.json`、`qqdata` …）全部由 `$NAPCAT_HOME`
自动派生，**不用再逐个改**；换机器只需要改上面第 2 行。

3. 敏感项不要写进脚本，放到同目录的 `guardian.config.json`（该文件已被 `.gitignore` 忽略）：

```json
{
  "webuiToken": "你的 NapCat WebUI token",
  "ntfyTopic": "你的 ntfy 主题名",
  "qrPageUrl": "https://你的域名/?k=你的密钥",
  "notifyNtfy": true,
  "notifyToast": true
}
```

4. 确保 NapCat 已开启**本地 HTTP API**（默认 `http://127.0.0.1:3000`），参考 `config/napcat/onebot11.example.json`，复制到 NapCat 的 `config/` 并改名为 `onebot11_<你的机器人QQ>.json`。
5. 建议在 `config/napcat_<QQ>.json` 里把 `fileLog` 设为 `true`，否则"发送失败探测"读不到日志（会退化回只看 `get_status`）。

### 第 2 步：安装守护任务

**右键** `scripts/install_guardian.bat` → **以管理员身份运行**。

安装器会注册计划任务 `NapCatGuardian`（最高权限、登录时自启、隐藏窗口、崩溃自动重启），并立即启动。

### 第 3 步：（可选）看护 AstrBot

编辑 `scripts/astrbot_watchdog.ps1` 顶部的 `$ASTRBOT_DIR` 与 `$PYTHON`，然后在**普通权限**下运行一次：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\astrbot_watchdog.ps1
```

开机自启：给这个脚本建一个快捷方式，丢进
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`，目标参数为
`-NoProfile -WindowStyle Hidden -File "<脚本完整路径>"`。

停掉它：`powershell -NoProfile -File scripts\astrbot_watchdog.ps1 -Stop`
（早期版本要"先抢到互斥体才停"，而互斥体恰恰被正在跑的那份占着 —— 结果 `-Stop`
一次也停不掉，只能去任务管理器里找 PID；现在改为按命令行精确匹配本脚本进程后结束。）

### 第 4 步：（可选）修复网络

用 WiFi 挂机的话，以管理员身份再跑一次：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\network_fix.ps1
```

它会关闭网卡"空闲断电省电"、把无线适配器调到最高性能，并重启网卡（会断网几秒）。

### 第 5 步：（可选）人在外面也能扫码

NapCat 掉了登录态需要扫码时，人往往不在电脑前。`scripts/qrsync/` 把 `cache\qrcode.png`
变成一张"永远显示最新一版"的网页，再套一条公网隧道，手机在任何地方都能扫：

```powershell
# 一次性：前台跑，扫完按 Ctrl+C，服务和隧道一起收干净
powershell -ExecutionPolicy Bypass -File scripts\qrsync\start-qr.ps1

# 或者注册成计划任务常驻（daemon.ps1），断了自动重连
```

页面用 `?k=<密钥>` 校验（`key.txt` 自动生成 24 位随机串），错误一律 404，不给任何提示。
隧道按 `ngrok → cloudflare → localhost.run → pinggy` 顺序尝试，见 `config.example.json`。

> 为什么值得做：被踢下线后"及时扫码"是唯一真正有效的人工补救。等你有空回家再扫，
> 机器人已经掉线一整天了。

### 验证

```powershell
Get-ScheduledTask -TaskName NapCatGuardian        # State 应为 Running
Get-Content D:\napcat\guardian.log -Tail 20       # 应能看到 started / keep-alive sent
```

---

## 配置说明

### guardian.ps1 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `$KEEPALIVE_MIN` / `$KEEPALIVE_MAX` | 1200 / 2400 秒 | 保活间隔随机区间（20–40 分钟），长尾分布，少数拉长到几小时。实测踢线并非由静默触发，间隔不必很短；太频繁反而更像脚本 |
| `$KEEPALIVE_IDLE_MIN` | 25 分钟 | 距最后一次**真实收发**不足这么久就不发保活 —— 空闲驱动，避免"天天整点自言自语" |
| `$KEEPALIVE_NIGHT_FROM` / `_TO` | 1 / 7 | 凌晨 01:00–07:00 完全不发 |
| `$CHECK_INTERVAL` | 20 秒 | 看门狗检测间隔 |
| `$OFFLINE_LIMIT` | 2 | 连续几次异常才判定需要恢复 |
| `$RECOVER_COOLDOWN` | 300 秒 | 两次恢复动作之间的最小间隔 |
| `$MAX_RECOVER` | 1 | 每个掉线事件最多自动恢复几次；失败即熔断等人（**不要调大**） |
| `$CIRCUIT_MINUTES` | 120 | 熔断时长，期间绝不再碰 NapCat |
| `$NIGHT_QUIET_FROM` / `$NIGHT_QUIET_TO` | 2 / 7 | 夜间静默时段（02:00–07:00） |
| `$NIGHT_MIN_GAP` | 3 小时 | 夜间两次尝试之间的最小间隔 |
| `$LOGIN_WAIT_SEC` | 480 秒 | 全量重启后等缓存 token 登录的上限 |
| `$WORKER_WAIT_SEC` | 240 秒 | `RestartNapCat` 后等缓存登录的上限 |
| `$QUICK_RETRY_SEC` | 90 秒 | 等待登录期间补一次 `SetQuickLogin` 的间隔 |
| `$SENDFAIL_WINDOW` / `$SENDFAIL_THRESHOLD` | 600 秒 / 2 | 发送失败探测：窗口内累计几次"网络连接异常"判定连接已死 |
| `$SENDFAIL_COOLDOWN` | 900 秒 | 两次"连接重置"的最小间隔 |
| `$FOREIGN_WAIT_MIN` | 30 分钟 | 检测到桌面 QQ 时，推迟恢复的最长时间 |
| `$QQ_DATA_DIR` | 你的路径 | QQ 数据目录隔离，留空则不隔离 |
| `$KA_POOL` | 若干短句 | 保活消息内容，可自行改得更自然 |

### 端口约定（可改）

| 服务 | 端口 | 说明 |
|------|------|------|
| NapCat OneBot11 HTTP API | 3000 | 绑定 127.0.0.1，守护脚本调用它 |
| NapCat WebUI | 6099 | 守护脚本用它做快速登录/重启 |
| AstrBot 反向 WebSocket 服务端 | 6199 | NapCat 主动连过来 |
| AstrBot WebUI | 6185 | 浏览器管理面板（astrbot_watchdog 用它判断存活） |

> ⚠️ 本地 API 建议只绑定 `127.0.0.1` 且不要对外暴露，也不要使用弱 token。

---

## 关键踩坑记录

这些是我们实际验证过、确认"走不通"的方向，避免你重复踩坑：

1. **本地 API 不能保活**。`get_status` / `get_config` 等调用不经过腾讯服务器，调再勤也会被踢。必须发真实消息。
2. **`get_status.online` 会假在线**。长连接断掉后它仍可能报 `online: true` 长达几十分钟（我们实测 50 分钟）。真正的判据是 `CheckLoginStatus` 的 `loginError` 和 NapCat 自己日志里的发送失败。
3. **重启风暴 = 风控触发器**。守护脚本反复重启会形成连续的无效登录尝试，社区大量案例因此被直接冻结。必须"一次失败就熔断"。
4. **`taskkill /f /im QQ.exe` 会杀掉用户的大号**。只能按进程树精确终止 NapCat 自己拉起的那些 PID。
5. **桌面 QQ 与机器人共用 `%APPDATA%\QQ`**，Electron 单实例锁导致互踢 —— 用 `NAPCAT_QQ_DATA_DIR` 隔离。
6. **登录态失效后，进程内 `SetQuickLogin` 无法免扫码**，腾讯返回 `code = -1「登录态已失效」`。
7. **会话已建立时再调 `SetQuickLogin` 会触发 `onUserLoggedIn` 回调**，该回调只设置错误文案、不真正置上线，形成"底层似登录、逻辑未上线"的僵死态。规避方式：只在离线时调用，调用后必须用真实在线状态校验。
8. **网络抖动 ≠ 被踢**。错误码 `1006514 网络连接异常` 是网络层问题，没有 `KickedOffLine` 就不是被踢。
9. **WiFi 网卡省电会导致空闲断流**。注册表 `PnPCapabilities = 16` 表示允许空闲断电，应改为 `24`（见 `network_fix.ps1`）。
10. **控制台窗口的隐藏方式很讲究**。`Start-Process -WindowStyle Hidden` 在某些 Win11 环境下会被 Windows Terminal 接管而强制显示窗口；用 `ProcessStartInfo` + `CreateNoWindow = $true` 才可靠，且用户关掉窗口不会连带杀死进程。
11. **普通（非管理员）PowerShell 注册计划任务会 `Access denied`**，所以安装器需要管理员；但 `Start-ScheduledTask` / `Stop-ScheduledTask` 在普通权限下可用。
12. **PowerShell 脚本里的中文必须先存成 UTF-8 with BOM**，否则 Windows PowerShell 5.1 按 GBK 解析，报 `The string is missing the terminator` 之类莫名其妙的语法错误。
13. **`Invoke-RestMethod` 用字符串 Body 发中文，会被按 ASCII 编码成 `?`**。PowerShell 5.1 取不到 charset 时默认用 ASCII（不是 UTF-8、也不是系统 ANSI），一个汉字变一个 `?`，`Content-Length` 恰好等于字符数；只加 `-ContentType 'text/plain'` 也**不会**修好，必须显式声明 charset。正确写法：

    ```powershell
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri $url -Method Post -Body $bytes `
        -ContentType 'text/plain; charset=utf-8'
    ```

    顺带：ntfy 的自定义 `Title` 头只接受 ASCII/URL 编码，中文标题要转 RFC 2047（`=?UTF-8?B?<base64>?=`），否则整个请求会被拒。
14. **日志"增量读"遇到文件被重建会永久失明**。记录已读偏移 `pos` 的写法，如果判断成 `if (len -le pos) { return }`，那么日志被截断/重建（NapCat 重启就会）之后 `len` 永远小于 `pos`，从此一条新日志都读不到，发送失败探测静默失效。正确做法是 `len < pos` 时把 `pos` 归零重读；首次见到文件时把 `pos` 设成文件末尾，否则会把几天前的旧报错当成"刚刚发生"。

## 防风控 / 养号建议

- **保活间隔不必很短**。实测踢线多发生在聊天中，把间隔放到 30–45 分钟既能维持活跃度，也不像固定周期的脚本。固定整点发消息最假。
- **别让同一个 QQ 号在手机和电脑上"同时在线"**。手机 QQ 的「切换账号」不等于退出登录，小号会话仍在后台；服务端看到两端同时在线，就把 PC 侧判为"登录态已失效"——这是最常见的踢线原因。用完就在小号界面**退出登录**，而不是切回大号。
- 机器人账号最好有正常使用痕迹（头像、昵称、少量真实好友/群），新号、小号更容易被风控。
- 不要更新到最新版 QQ 后立即挂 NapCat；保持 NapCat 官方推荐的 QQ 版本，NapCat 本身也建议保持新版（老 Shell 会被判为外挂强制下线）。
- 开通 QQ 会员**不能**防风控：风控看的是设备指纹、登录地、行为模式，与会员等级无关；反复触发验证本身反而是异常信号。
- 长期挂机、条件允许时优先用**有线网络**，比 WiFi 稳定得多。

## 常见问题

详见 [docs/常见问题.md](docs/常见问题.md)。简要列出：

- **Q：计划任务里脚本不运行？**
  A：确认任务是"最高权限"、触发器是"登录时"，且执行策略允许 `-ExecutionPolicy Bypass`；脚本必须是 UTF-8 with BOM。

- **Q：开机后 NapCat 没自动启动？**
  A：新版检测到 NapCat 没运行会立即拉起；若提示"身份已失效"，扫码一次即可（会自动弹窗）。

- **Q：还是经常需要扫码？**
  A：先看日志里是 `KickedOffLine`（服务端踢线，多为同号多端登录）还是 `1006514 网络连接异常`（网络层）。前者改掉手机切号习惯；后者看 `network_fix.ps1` 与路由器/NAT 的空闲超时。

- **Q：为什么不再频繁自动重启？**
  A：这是刻意设计。`$MAX_RECOVER = 1` + 120 分钟熔断，失败就等人工，避免重启风暴把自己送进风控。

- **Q：`msg.exe` 弹窗不出现？**
  A：部分家庭版/精简版 Windows 没有 `msg.exe`，可改用其它通知方式（如发邮件、Server 酱、读 `login-state.json` 的网页）。

- **Q：手机收到的通知里中文全变成 `?`？**
  A：发送端编码问题，不是接收端。`Invoke-RestMethod` 传字符串正文时会按 ASCII 编码，见[踩坑记录第 13 条](#关键踩坑记录)。本仓库已修复：正文先 `UTF8.GetBytes()`，再带 `charset=utf-8` 发出。

- **Q：人不在家，机器人要扫码怎么办？**
  A：用 `scripts/qrsync/`。它把二维码变成网页 + 公网隧道，手机随时能扫；页面上还会显示看护写出的 `login-state.json` 状态（需要扫码 / 已上线 / 正在恢复）。

- **Q：AstrBot 没被拉起来？**
  A：检查 `scripts/astrbot_watchdog.ps1` 里的 `$ASTRBOT_DIR`、`$PYTHON`，并确认它是以**普通权限**运行的。

- **Q：桌面 QQ 一开，机器人就掉？**
  A：见[桌面 QQ 与机器人共存](#桌面-qq-与机器人共存)，设 `$QQ_DATA_DIR` 隔离数据目录。

---

## 免责声明

本项目仅用于**学习与个人运维经验分享**，不包含 QQ / NapCat / AstrBot 的任何官方代码或安装包。

- 使用第三方协议登录 QQ 可能违反腾讯相关服务条款，存在**账号被限制、封禁**的风险，一切后果由使用者自行承担。
- 请勿将本项目用于任何违法违规用途。
- 仓库中的配置示例均为脱敏占位，使用时请替换为你自己的信息，并**妥善保管 API Key、WebUI Token 等敏感信息**，不要提交到公开仓库。

相关项目版权归各自所有：NapCat、AstrBot、QQ。

## License

[MIT License](LICENSE)
