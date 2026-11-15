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
- [通知与告警](#通知与告警)
- [关键踩坑记录](#关键踩坑记录)
- [防风控 / 养号建议](#防风控--养号建议)
- [常见问题](#常见问题)
- [掉线取证（docs）](docs/掉线取证.md)
- [o3HookMode 实验 Runbook](docs/实验-o3HookMode.md)
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
  10 min 自聊       get_status.online    NapCat 日志"网络连接异常"  僵尸/断流/被踢
  兼健康检查        + CheckLoginStatus   （最坏 10 分钟发现）      各走各的路
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
- 默认 **每 10 分钟**一条，但只在"距离上次真实收发已经满 10 分钟"时才发（有人聊天时探针没有意义）。

**保活真正的作用已经变了**：它不再是"防静默被踢"的银弹（见上节实测），而是

1. 维持账号的最低活跃度，避免长期零活动被判定异常；
2. **兼做健康探针** —— 这条消息是判断"假在线"的唯一可靠手段：连接死掉时 `retcode` 仍是 200，但响应体里 `status` 会变成 `failed`、`message` 里带 `1006514 网络连接异常`，同时 NapCat 日志落一行同样的错误。探针频率就是故障发现时间的上限，所以**固定 10 分钟**比随机 20–40 分钟更合适（实测随机间隔曾让一次假在线拖了 49 分钟才被发现）。

### 2. 看门狗：先判断场景，再对症恢复

每 20 秒检测一次，连续 2 次异常（约 40 秒）才动手。恢复不是无脑杀进程：

| 当前情况 | 守护脚本的动作 |
|----------|----------------|
| **NapCat 根本没运行**（刚开机 / 崩溃后） | **立即启动**，不做无谓等待 |
| **僵死态**（`isLogin=true` + `loginError` 含"失效/重新登录"） | `RestartNapCat` 重启 worker → 等最多 240 秒缓存登录 |
| **发送失败**（日志出现 `网络连接异常`，600 秒内 2 次） | 不等 `get_status` 翻牌，直接 `RestartNapCat` 复活连接 |
| **在线过、遇到网络抖动**（`1006514`） | 先给最多 90 秒自愈时间，不杀进程 |
| **真的被踢**（日志出现 `[KickedOffLine]`） | **跳过宽限期和快速登录，直接全量重启**（见下） |
| **worker 卡死** | `RestartNapCat`（不杀 QQ，保留登录票） |
| **以上都无效** | 最后才全量重启（按进程树精确杀 + 重新注入） |
| **已有新码在等扫码**（10 分钟内生成） | **绝不重启**，只提示扫码，避免冲掉你正看着的那张码 |
| **登录态确认失效 / 需要扫码** | 停止折腾，写状态文件 + 邮件（带二维码附件）+ 弹窗，等人扫码 |

> 关键原则：**能不杀进程就不杀，能不打断就不打断。**
> - WiFi 短暂波动（`1006514 网络连接异常`）几秒到十几秒会自行恢复，一发现离线就强杀 QQ，反而会让快速登录凭证失效、逼你重新扫码；
> - 开机时 NapCat 本来就没跑，空等"宽限期"毫无意义，所以直接拉起；
> - 登录态一旦明确失效，自动恢复注定失败，第一时间提示你扫码，而不是空转几轮。

**为什么"被踢"要直接全量重启（2026-11-15 实测）**

被踢之后的恢复流程原本是 A（90 秒宽限）→ B（进程内快速登录）→ C（`RestartNapCat`）→ D（全量重启）。实测 14 次被踢，B 和 C **一次都没成功过**，而 C 还会把缓存票据作废：

| 恢复动作 | 结果 |
|----------|------|
| `RestartNapCat`（worker 重启） | `isLogin=false`、`loginError` 为空 → **停在二维码页，必须扫码** |
| 完整重启（杀 QQ → launcher） | 在票据还有效时能直接登回来（07:33、12:52 两次实测），日志 `logged in.` |

这套 14 分钟里有一半花在注定失败的步骤上。所以现在：**看到 `[KickedOffLine]` 就直接跳到 Phase D**，恢复时间从 ~14 分钟压到 3–5 分钟。

**关于"主动续期"（已关闭）**

14 次被踢的会话存活时长：121/137/50/35/26/116/117/18/109/117/121/117/121/112 分钟 —— 中位 117、10/14 落在 109–121，很像登录票据的约 2 小时有效期。于是试过"活满 100 分钟就主动 `RestartNapCat` 续期"，结果 worker 重启后同样停在二维码（票据不被复用），等于强制扫码一次，比被踢更糟。**该功能默认关闭**（`$PROACTIVE_REFRESH_MIN = 0`），代码保留供以后 NapCat 行为变化时再试。

### 3. 安全阀：别把自己折腾进风控

| 机制 | 默认值 | 作用 |
|------|--------|------|
| 单次恢复 + 熔断 | `$MAX_RECOVER = 1`，熔断 `120` 分钟 | 一次掉线只自动救一次；失败就停下来等人，杜绝"重启风暴" → 连续无效登录 → 冻结 |
| 夜间静默 | `02:00–07:00` | 凌晨是风控高发时段，这段时间最多每 3 小时尝试一次 |
| 不杀桌面 QQ | `Test-ForeignQq` | 检测到你自己开的 QQ 就先推迟恢复（最多 30 分钟），避免两边互踢 |
| 无窗口 | `CreateNoWindow` | 所有拉起动作都不产生控制台窗口，关掉窗口不会连带杀死机器人 |

### 4. 兜底：需要人工扫码时

被踢之后如果 120 秒还没用缓存票据登回来，会在**继续等待的同时**先推一条「可能需要扫码」（带扫码页链接和二维码附件），而不是等满 8 分钟才通知。

1. 刷新最新的登录二维码（NapCat 等扫码时会自己每 2 分钟换码）；
2. 写 `login-state.json`（配合网页/通知显示"需要扫码"）；
3. 通知走降级链：ntfy → **邮件（把 `qrcode.png` 作为附件带上，手机里长按就能识别）** → Webhook → Windows Toast → `msg.exe`；
4. 之后每 15 秒查一次登录状态，扫上就自动恢复在线（最多盯 10 分钟，期间**不会**重启 NapCat）。

> 邮件附件是 2026-11-15 加的：ntfy.sh 在国内经常整条超时，而扫码这件事"通知到了却没有码"等于没通知。

### 5. 可观测性：`metrics.json`

每轮循环（20 秒）写一次 `metrics.json`，网页和外部监控读它就够了，不必解析日志：

```json
{"at":"2026-11-15T13:12:57+08:00","state":"online","sessionMin":42,"kicksToday":2,
 "lastKick":"11-15 12:38:10","nextProbeAt":"13:22","probeMin":10,
 "lastRecoverSec":-1,"lastRecoverAt":"","uin":"YOUR_BOT_QQ"}
```

| 字段 | 含义 |
|------|------|
| `sessionMin` | 本次登录（= 当前票据）活了多久；`-1` 表示还没登录 |
| `kicksToday` | 今天被踢次数（只统计 `kick.log` 里的真实 `[KickedOffLine]`，不含假在线） |
| `lastKick` | 最近一次被踢的时间（NapCat 日志里的时间戳） |
| `nextProbeAt` | 下一次保活探针的时间 |
| `lastRecoverSec` | 上一次自动恢复耗时（秒）；`-1` 表示本次运行还没恢复过 |
| `lastRecoverAt` | 上一次自动恢复完成的时刻 |

扫码页页脚还会按 `metrics.at` 判断看护是否还活着：超过 3 分钟没更新就显示红色「⚠ 看护心跳超时」，避免「守护脚本已经挂了、页面还显示在线」。

配合 `qrsync` 的扫码页，页脚会显示"本次登录 N 分钟 · 今日被踢 M 次 · 上次恢复 N 秒 · 下次探针 HH:MM"。

另外，`astrbot_watchdog.ps1` 每 30 秒写一次 `astrbot-state.json`：

```json
{"at":"2026-11-15T13:22:42+08:00","state":"online","note":"ok","pid":22512,
 "portOk":true,"restarts":0,"since":"2026-11-15T10:57:08+08:00"}
```

原因是两套服务互相看不见：NapCat 掉线时 AstrBot 往往还活着，而 AstrBot 的 HTTP 层死掉时（11-13 19:59 那次 proactor `WinError 64`）NapCat 也完全不知情。现在扫码页会把 AstrBot 一起显示成 `AstrBot 正常` 或 `AstrBot 异常(state, N 分钟前)`，超过 5 分钟没更新就判异常。

---

### 6. 一眼看健康：`status.ps1`

不想分别去看 `metrics.json` / `astrbot-state.json` / 计划任务 / OneBot API 时，跑这一个只读脚本就够了：

```
PS> .\scripts\status.ps1

  NapCat 状态速览  2026-11-15 13:40:17
  ----------------------------------------------------------
  机器人      在线（good）
  本次登录    24 分钟
  今日被踢    2 次，最近 11-15 12:38:10
  下次探针    13:47
  看护        Running，心跳 0 分钟前（PID 12256）
  AstrBot     online，pid 22512，重启 0 次，0 分钟前
  登录状态    online — 已登录
  扫码通道    ngrok / 正常，0 分钟前 · https://your-domain.ngrok-free.dev

  [OK] 一切正常
```

- 退出码没用（始终 0），判定看输出最后一行的 `[OK]` / `[WARN]` / `[ERROR]`；
- `-Json` 输出结构化结果，方便接监控；
- `-Root` 指定 NapCat 根目录（默认 `D:\napcat`）。
- 它**不发消息、不重启任何东西**，机器人正在等扫码时也可以放心跑。
- 「扫码通道」那行的数据来自 `qrsync\tunnel-state.json`：公网入口连续不可用超过
  `$TUNNEL_ALERT_MIN`（默认 10 分钟）时，看护会发一封告警邮件——因为扫码页是你唯一
  的远程自救通道，等你要扫码时才发现它打不开就晚了。

### 7. 诊断：这次为什么被踢？

> 想要完整的数据与推论（14 次被踢的会话寿命分布、另一种"假在线"掉线的反例、以及还没被证伪的猜想），见 [`docs/掉线取证.md`](docs/掉线取证.md)。

`scripts/kick-report.ps1` 只读 NapCat 日志，把每次真实 `[KickedOffLine]` 归到它所属的登录会话上：

```
Kicked         Log                          Session Uptime DetectSec RecoverSec Path
11-13 12:24:49 2026-11-13_10-14-31.486.log     109 01:49        31
11-11 13:44:23 2026-11-11_13-18-25.420.log      26 00:25        46        394 staged
11-15 12:38:10 2026-11-15_09-44-57.376.log     112 01:52        27        865 staged

Recovery latency (kick -> online), matched for 4 of 14 kicks
  min 322s  median 463.5s  max 865s
  path=staged: 4 kick(s), median 463.5s

Session length at kick (minutes)
  min 18  median 116.5  p90 121  max 137
  64% of sessions ended within 15 min of the median
  -> sessions cluster tightly around a fixed lifetime: suspect a ticket TTL.
```

多出来的三列读法：

- `DetectSec`：被踢到 guardian 开始恢复的秒数（≈ 轮询间隔，正常 20–50 秒）。
- `RecoverSec`：被踢到重新在线（或扫码回来）的总秒数 —— **这一列才是"恢复快不快"的唯一指标**。
- `Path`：`staged` = 旧的四阶段（A 宽限 → B 快速登录 → C 重启 worker → D 全量重启）；`fast` = 检测到踢线后直接跳到 D。用 `-GuardianLog` 指定 `guardian.log` 才能算出来。

看 **Session** 这一列就够了：

- 集中在一两个值附近（如 109–121）→ 固定寿命，像票据 TTL，别去折腾网络和保活频率；
- 忽长忽短、有 1–2 分钟就死的 → 登录被立刻拒绝，查设备指纹 / 同号多端；
- 都很短且伴随 `1006514` → 那是"假在线"，不是被踢，看 `metrics.json` 的 `kicksToday` 对比。

用法：`.\kick-report.ps1`、`.\kick-report.ps1 -Days 3`。只读，不影响运行中的机器人。

## NapCat 和 AstrBot 各需要改什么

本仓库**只包含优化/稳定部分，不包含 NapCat 与 AstrBot 的基础安装**（假设你已经装好并能正常使用）。

| 部分 | 为了本方案需要做什么 | 是否必须 |
|------|----------------------|----------|
| **NapCat** | 开启**本地 HTTP API**（`127.0.0.1:3000`），守护脚本靠它发保活、查状态；配置 `webui.json` 以使用快速登录/重启；建议打开 `fileLog`（发送失败探测要读日志） | **必须** |
| **AstrBot** | 配好反向 WebSocket（`6199`）接收 NapCat；用附带的 `scripts/astrbot_watchdog.ps1` 以**普通权限**看护 | 可选但对无人值守很实用 |

> AstrBot 由独立的 `astrbot_watchdog.ps1` 看护，**不由 guardian 启动**。原因：guardian 以最高权限运行，而 AstrBot 往往装了"电脑操控"类插件 —— 把它跑在管理员上下文里，等于把整台机器交给任何能给机器人发消息的人。这是有意为之的降权设计。

### AstrBot 侧的两项加固（推荐）

1. **WebUI 只监听本机**：`data/cmd_config.json` 里 `dashboard.host` 默认是 `0.0.0.0`，等于把管理面板暴露给整个局域网。改成 `127.0.0.1` 再重启 AstrBot（约 2 分钟）：
   ```json
   "dashboard": { "host": "127.0.0.1", "port": 6185 }
   ```
   注意 AstrBot 的 dashboard 有**自己的**用户名/密码（pbkdf2），别和 NapCat 的 token 混用。

2. **给 livingmemory 配 embedding（否则启动噪音很大）**：不配时插件每次启动都会「等待 Embedding Provider … 已尝试 60 次」然后初始化失败，记忆向量功能等于残废。以 DashScope 为例，在 `provider_sources` 加一条：
   ```json
   {
     "id": "dashscope_embedding",
     "type": "dashscope_embedding",
     "provider_type": "embedding",
     "provider": "dashscope",
     "embedding_api_key": "你的 key",
     "embedding_api_base": "https://dashscope.aliyuncs.com/api/v1",
     "embedding_model": "text-embedding-v4",
     "embedding_dimensions": 1024,
     "enable": true
   }
   ```
   再在 `provider` 里加 `{"id":"dashscope/text-embedding-v4","provider_source_id":"dashscope_embedding","model":"text-embedding-v4","modalities":["embedding"],"enable":true}`，并把 `astrbot_plugin_livingmemory_config.json` 的 `provider_settings.embedding_provider_id` 指向它。
   **坑**：只写 `embedding_model` 不够，必须显式写 `embedding_dimensions`（如 1024），否则插件报 `无效的嵌入向量维度: 0` 并初始化失败 —— `get_dim()` 只从配置里读这个字段，不会去探测模型。

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

### 8. 单变量实验：把 `o3HookMode` 改成 0

> 完整步骤、观察期判据和回滚都在 [docs/实验-o3HookMode.md](docs/实验-o3HookMode.md)。

社区诊断（[napcat-offline-diagnosis](https://github.com/TomoyoNatsume/dsh-qq-bridge/blob/main/docs/napcat-offline-diagnosis.md)，2026-09）给的唯一建议是**只改一个变量**：把 `config\napcat.json`（以及 `config\napcat_<QQ号>.json`）里的 `o3HookMode` 从 `1` 改成 `0`，其余一律不动，重启扫码后观察 24–48 小时。

仓库里带了个小工具做这件事：

```
PS> .\scripts\set-o3hookmode.ps1 -Mode 0            # 只预演，不写文件
PS> .\scripts\set-o3hookmode.ps1 -Mode 0 -Apply     # 真正写入（自动备份 .bak-o3hook-<时间戳>）
PS> .\scripts\set-o3hookmode.ps1 -Mode 1 -Apply     # 实验结束，改回去
```

- 只替换 `o3HookMode` 这一个键的值，保留原文件的顺序、缩进和其余字段；写回前会再 `ConvertFrom-Json` 校验一次。
- 改完必须重启 NapCat（会掉线一次，大概率要重新扫码）。
- **判断标准是"每次登录能活多久"，不是"重启几次"**：实验前后各跑一次 `.\scripts\kick-report.ps1`，比较会话时长的中位数（本次基线：14 次被踢，median 116.5 分钟）。
- 如果 24–48 小时后 median 没有明显变长，就 `-Mode 1 -Apply` 改回默认，别再折腾——反复改配置本身也是一种异常信号。
> 另一个相关细节（2026-11-15 修）：判断"是不是正等人扫码"看的是 **`qrcode.png` 还在不在刷新**（<180 秒），而不是"码是不是 10 分钟内生成的"。后者会让离开 12 分钟才回来扫码的人遇上"码被重启冲掉"。只有当这种状态持续 30 分钟仍没人扫，才认为登录页卡死、做一次全量重启（`$QR_MODE_MAX_MIN`）。
> 注意一个曾经的实现坑（2026-11-15 修）：这条"被踢直接全量重启"的快速通道，最初放在"僵尸态"分支之后；而踢线时 `loginError` 里同样含"失效"，于是永远先命中僵尸态分支、快速通道成了死代码——`-SelfTest` 现在有第 6 项回归守卫检查这个顺序。
### 9. 判断实验有没有用：`experiment-compare.ps1`

「改完还是掉线」不等于改动无效。只要腾讯的票据策略不变，掉线本身几乎必然发生——该看的是**每次登录能活多久**。所以 `kick-report.ps1 -Json` 存快照、事后对比：

```
# 实验前
PS> .\scripts\kick-report.ps1 -Json | Set-Content D:\napcat\baseline.json -Encoding UTF8

# …… 改配置、重启、扫码，观察 24–48 小时 ……

# 实验后
PS> .\scripts\kick-report.ps1 -Json | Set-Content D:\napcat\after.json -Encoding UTF8
PS> .\scripts\experiment-compare.ps1 -Before D:\napcat\baseline.json -After D:\napcat\after.json
```

输出是一张对照表加一句结论：

```
  被踢次数               14          11
  会话中位数(分)      116.5       138.0
  p90(分)               121         190
  min/max             18/137      35/201
  median±15占比          64%         45%
  恢复耗时中位(秒)      463.5       148.0

  中位数变化：+21.5 分钟（+18.5%）
  [improved] 会话明显变长，这个改动值得保留。
```

判定规则是保守的，宁可说"没变化"：

- 两侧样本各需 ≥ `-MinSamples`（默认 4）次被踢，否则只报「样本不足」；
- 中位数提升 ≥ `-MinDeltaMin`（默认 15 分钟）**且** ≥ 15% → `improved`；
- 下降同样的幅度 → `worse`；
- 其余一律 `no clear change`，此时应当把实验改的那一项改回去，别再叠加变量。

快照是纯 JSON，也可以直接 `Export-Csv` 或喂给别的脚本。
`metrics.json` 还有两个字段说明"最近一次是怎么被救回来的"：

```json
{ "lastRecoverSec": 322, "lastRecoverAt": "2026-11-15 13:15:34",
  "lastCause": "kick", "lastPath": "fast" }
```

`lastCause` ∈ `kick / zombie / sendfail / webui_down / qr_wait / offline`，`lastPath` ∈ `fast / staged / launch / worker / wait_scan`。日志里对应的成功行也带同样信息：`Recovery attempt #1 succeeded in 322s (cause=kick, path=fast).`
### 10. 装完自检：`smoke-test.ps1`

`status.ps1` 回答"现在健不健康"，`smoke-test.ps1` 回答"装得对不对"——部署完、改完配置、换机器之后跑一次，九项一起看：

```
PS> .\scripts\smoke-test.ps1

  NapCat 安装自检
  ----------------------------------------------------------
  [PASS] 配置文件          已加载 D:\napcat\guardian.config.json
  [PASS] 计划任务          NapCatGuardian Running
  [PASS] 看护心跳          PID 12256，0 分钟前
  [PASS] metrics.json      state=online，sessionMin=29
  [PASS] 本地扫码服务      state=used，bot=online
  [PASS] 公网扫码页        HTTP 200，6335 B
  [PASS] OneBot API        online=true good=True
  [PASS] NapCat WebUI      token 鉴权成功
  [PASS] AstrBot           online，pid 22512，6185 在听

  [OK] 全部通过
```

- **退出码 = 失败项数**，可以直接接进脚本/任务里做门禁；
- `-SkipPublic` 跳过公网检查（隧道没开时用），`-Json` 输出结构化结果；
- `-Root` / `-Config` 指定非默认路径；
- 全程只读：不发消息、不重启进程。

| 状态 | 含义 |
|---|---|
| `PASS` | 该项正常 |
| `WARN` | 能继续跑，但有东西没配好（例如没配通知通道、AstrBot 没起） |
| `FAIL` | 这条链路是断的，必须处理（计入退出码） |
| `SKIP` | 参数要求跳过，或缺少前置配置 |
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
│   ├── kick-report.ps1
├── status.ps1
├── set-o3hookmode.ps1
├── experiment-compare.ps1
├── smoke-test.ps1              # 诊断：统计每次被踢时的会话寿命（只读）
│   ├── guardian.config.example.json  # 通知 / token 配置模板（真实文件不进 git）
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
    ├── 审查修复记录.md              # 一份完整的代码审查清单（含"看过但不修"的理由）
    └── 演进方向-web与独立应用.md    # 要不要做网页面板/独立软件：成本与收益对比
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
| `$KEEPALIVE_MIN` / `$KEEPALIVE_MAX` | 600 / 601 秒 | 保活探针固定 10 分钟一条（`Get-NextKeepAliveDelay` 直接返回 `$KEEPALIVE_MIN`）。探针频率 = 故障发现时间的上限，所以不再用长尾随机 |
| `$KEEPALIVE_IDLE_MIN` | 10 分钟 | 距最后一次**真实收发**不足这么久就不发探针 —— 有人聊天时探针没意义，也避免"整点自言自语" |
| `$KEEPALIVE_NIGHT_FROM` / `_TO` | 0 / 0 | 0/0 = 夜间照常探测。探针只发给自己、不打扰任何人，而夜间恰恰最需要自动发现 |
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
| `$SENDFAIL_WINDOW` / `$SENDFAIL_THRESHOLD` | 300 秒 / 1 | 发送失败探测：窗口内出现一条"网络连接异常"即触发复核。`Confirm-SendBroken` 发一条探针，**直接看 OneBot 响应的 `status` 字段**（连接死时 HTTP 与 retcode 仍是 200，但 `status=failed`、`message` 带 `1006514`），不再靠等日志增量 |
| `$SENDFAIL_COOLDOWN` | 600 秒 | 两次"连接重置"的最小间隔 |
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

恢复成功时的消息正文现在包含 **耗时 N 秒** 与 **会话时长 M 分钟**，扫码页页脚也会显示「上次恢复 N 秒」——这两个数字比"重启成功"本身更能说明策略好坏。
## 通知与告警

守护脚本只在**状态跃迁**时推送（同一事件 30 分钟内去重），不会刷屏；三个触发点：需要扫码（附带扫码页链接）、熔断打开、恢复成功。

| 通道 | 适用 | 说明 |
|------|------|------|
| ntfy.sh | 有海外网络时首选 | 手机装 ntfy App 订阅一个随机 topic 即可，零注册。**部分网络下 http/https 都会超时**，所以它排在最前但不是唯一 |
| 邮件 SMTP | 国内最稳 | QQ 邮箱用 `smtp.qq.com` + **587 + SSL**，密码填「授权码」而不是登录密码。注意 465 在 .NET `SmtpClient` 下会报 `net_io_connectionclosed`（它只支持 STARTTLS） |
| 企业微信 / 钉钉 / 飞书 / Server酱 / PushPlus | 想推到群里 | 填 webhook URL 即可，脚本按 `type` 自动组装报文 |
| Windows Toast | 本机在用时 | WinRT `ToastNotificationManager`，家庭版也可用；失败静默 |

敏感配置不写在脚本里，放到 `$NAPCAT_HOME\guardian.config.json`（已被 `.gitignore` 忽略），模板见 `scripts/guardian.config.example.json`：

```json
{
  "webuiToken": "YOUR_WEBUI_TOKEN",
  "qrPageUrl": "https://your-domain.example/?k=YOUR_KEY",
  "ntfyTopic": "change-me",
  "notifyNtfy": true,
  "notifyToast": true,
  "notifyEmail": { "smtp": "smtp.qq.com", "port": 587, "user": "YOUR_QQ@qq.com",
                   "pass": "YOUR_SMTP_AUTH_CODE", "to": "YOUR_QQ@qq.com", "ssl": true },
  "notifyWebhook": { "type": "custom", "url": "" }
}
```

自检（不碰 NapCat，只验证通道）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\napcat\guardian.ps1 -TestNotify
```

---

### 11. 改恢复逻辑前先跑：`recovery-sim.ps1`

`-SelfTest` 只能测单个函数；**分支顺序**类的 bug 它测不到（2026-11-15 真的踩了两次：被踢快速通道被僵尸态分支抢先、等扫码判据用码龄）。这个脚本把 `guardian.ps1` 的函数部分 dot-source 进来，把一切会动系统的函数换成桩，然后直接调 `Do-Recovery` 断言返回值与日志关键字。

```powershell
.\scripts\recovery-sim.ps1                      # 用同目录的 guardian.ps1
.\scripts\recovery-sim.ps1 -Guardian D:\napcat\guardian.ps1
```

八个断言（7 个场景）：

| 场景 | 期望 |
|---|---|
| 被踢（`loginError` 也含"失效"） | 返回 `online`，日志有 `Phase A/B/C skipped`，**没有** `Phase C: restart worker` |
| 码在刷新、未登录、无错误 | 返回 `online`（扫到了）/ `need_scan`，日志有 `QR mode`，**没有** `Launch-NapCat` |
| 僵尸态（无被踢行） | 日志有 `login session invalid`，走 worker 重启 |
| WebUI 不可达 | 日志有 `launching directly` |
| 被踢后票据真的废了 | 返回 `need_scan` |
| 假在线（1006514） | 只 RestartNapCat（日志 send-fail detected），不杀 QQ |
| 桌面 QQ 正在用 | 返回 deferred，日志 deferring relaunch，**不**拉起机器人 |

**它自己是验过的**：把快速通道改成不可达、把"码在刷新"判据改成恒假，模拟测试分别报 2 项 / 1 项 FAIL——也就是说这两个历史 bug 现在会被直接抓住。

### 12. AstrBot 一天烧多少 token：`docs/token-优化效果.md`

机器人本身几乎不花 token，花的是 AstrBot 的 LLM 调用。2026-11-12 做过一轮压缩（群历史 3000 → 80、关掉两套 LLM 摘要、连击概率减半等），单次请求的平均输入从 **13–18 万** 降到 **4 万上下**，日总量从 1350 万降到 200–340 万。

按天数据、每项改动的对照表、以及"缓存命中率为什么反而降了"的解释都在 [docs/token-优化效果.md](docs/token-优化效果.md)。

查自己机器上的数据：

```powershell
python .\scripts\daily-report.py      # 只看不发：填好配置后它会发邮件，也可直接读 provider_stats
```

### 13. 反向看护：谁来看护看护者

`guardian.ps1` 负责救机器人，但它自己挂了没人知道——2026-11-15 就真发生过一次（编辑脚本时丢了 BOM，守护静默退出，网页却还显示"在线"）。

所以 `astrbot_watchdog.ps1` 反过来盯它的心跳：读 `D:\napcat\guardian.heartbeat`，**超过 10 分钟没更新**就先 `Start-ScheduledTask NapCatGuardian` 尝试拉起（限频 30 分钟），再发邮件（用 `guardian.config.json` 里的 `notifyEmail`，一小时内最多一封）。2026-11-15 现场实测：任务停掉 + 心跳伪造 25 分钟前 → 5 秒内任务回到 Running、心跳恢复。

```
# 单独跑一次检查（不发信也可看结论）
.\scripts\astrbot_watchdog.ps1 -CheckGuardian
guardian heartbeat: pid=33808 at=13:58:50 ageMin=0
healthy=True
```

两个进程互相盯着，就不再存在"单点静默死亡"：guardian 死了 AstrBot 看护会喊，AstrBot 死了 guardian 会重启它。邮件里直接给出排查和恢复命令。

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

- **保活探针固定 10 分钟，但只在静默时发**。探针的价值是"发现假在线"，频率就是发现延迟的上限；但有人正在聊天时不必额外发，所以 `KEEPALIVE_IDLE_MIN=10` 拦一层。真正决定会不会被踢的，不是探针频率，而是**别让同一个号多端同时在线**。
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

- **Q：ntfy 通知一条都收不到？**
  A：先 `-TestNotify` 看日志是 `notify(ntfy) sent` 还是 `notify(ntfy) failed: 操作超时`。国内网络下 `ntfy.sh` 的 http/https 都可能整体不可达，此时改用邮件通道（`notifyEmail`），守护脚本会自动按 ntfy → 邮件 → Webhook → Toast 的顺序降级。

- **Q：邮件通道报 `net_io_connectionclosed`？**
  A：端口用了 465。.NET 的 `SmtpClient` 只支持 STARTTLS，必须用 **587 + SSL**；密码填邮箱的「SMTP 授权码」而不是登录密码。

- **Q：扫码提示「你的 QQ 正请求在一个新的设备登录」是被盗了吗？**
  A：多数情况不是。手机 QQ 的「切换账号」**不等于退出登录**，小号会话仍留在后台，服务端认为该号同时在线于两端，于是把 PC 侧置为「登录态已失效」。要彻底避免，就在手机的小号界面点「退出登录」，而不是切回大号。

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

## 每日日报

`scripts/daily-report.py` 把平时散落在日志里的数字汇总成一封邮件：AstrBot token 消耗、被踢记录、AstrBot 看护重启次数，以及最近 24 小时出现次数最多的 `[ERRO]`（按消息归一化聚合，用于发现插件反复报错）。`guardian.ps1` 每天 09:00 之后调用它一次（同一天只成功发一次，失败最多每小时重试一次）。

```
# 只看正文不发送（需配置 astrbotDb / astrbotLog 才能统计 token 与插件错误）
python daily-report.py --config D:\napcat\guardian.config.json --dry-run
```

邮件正文长这样：

```
NapCat / AstrBot 日报告 — 2026-11-15 13:26
==============================================

统计区间：2026-11-14 00:00 起 24 小时

【AstrBot token】
  请求 4 次，合计 143,959 token
  新增输入 100,054 · 命中缓存 42,752 · 输出 1,153
  平均每次 35,989 token
  消耗最多的会话：
    yang:GroupMessage:... — 58,328

【被踢记录】
  [2026-11-15 12:38:37] KICKED | at=11-15 12:38:10 | log=... | quiet_before_kick=2 min
  合计 2 次

【AstrBot 看护】
  僵死强杀重启 0 次

【AstrBot 错误】
  26 条 [ERRO]，按次数排序：
    5× [astrbot_plugin_self_learning] [ERRO] ... [DomainRouter] 连接 Pos…
    5× [astrbot_plugin_livingmemory] [ERRO] ... 完整初始化流程失败: 无效的嵌入向量维度: N…

【当前状态】
  online · 本次登录 8 分钟 · 今日被踢 2 次
```

配置里可选 `pythonExe`（默认 `%LOCALAPPDATA%\Programs\Python\Python314\python.exe`）、`astrbotDb`（AstrBot 的 `data_v4.db` 路径）和 `astrbotLog`（`data\logs\astrbot.log`，用于统计插件 `[ERRO]`）。token 统计以只读方式打开 SQLite（`file:...?mode=ro`），不会和正在运行的 AstrBot 抢锁。

---

### 自检：`-SelfTest`

改完检测逻辑不必等一次真实掉线来验证。`guardian.ps1` 支持离线自检，用临时目录里的假日志跑完整的两条检测链路，全程不碰 NapCat 进程、不写 `kick.log`、不污染生产日志：

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\napcat\guardian.ps1 -SelfTest
```

输出：

```
[1] adopt existing log          KickSeen=False
[2] kick line                   KickSeen=True
[3] send failure                SendFailSeq=1 Test-SendBroken=True
[4] window cleared              healthy=True
[5] last line timestamp         11-15 10:06:00
SELFTEST PASSED (5 checks)
```

五项分别对应：历史日志不会被当成"刚刚被踢"、被踢行能被识别、发送失败计数生效、探测窗口过期后恢复健康、行首时间戳能解析（静默时长依赖它）。退出码 = 失败项数，便于放进任何检查脚本里。

## License

[MIT License](LICENSE)
