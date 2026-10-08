# NapCat Guardian

> 一套让 Windows 上的第三方 QQ 机器人（NapCat + AstrBot）**稳定长期挂机**的方案：定时保活 + 智能自动恢复，**开机自动拉起**、被踢下线也能自己救回来，真正做到无人值守。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4.svg)](https://github.com/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://github.com/)

---

## 目录

- [这是什么问题](#这是什么问题)
- [工作原理](#工作原理)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [关键踩坑记录](#关键踩坑记录)
- [防风控 / 养号建议](#防风控--养号建议)
- [常见问题](#常见问题)
- [免责声明](#免责声明)

---

## 这是什么问题

用 NapCat（以及 Lagrange 等第三方协议）在自己的电脑上挂 QQ 机器人时，如果**一段时间没有收发消息**，账号会被腾讯风控判定为"异常空闲"，强制踢下线：

```
[KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。
账号状态变更为离线
```

在我们的实测中，这个阈值大约是 **23 分钟无消息活动**。一旦被踢：

- 机器人收不到消息、也不回消息；
- 严重时登录态（saved session）会失效，必须重新扫码；
- 每次都要人工去电脑前处理，无法真正做到 7×24 无人值守。

**本项目就是为了把它变成"无人值守"。**

## 工作原理

### 1. 保活：让机器人定时给自己发消息（核心）

我们通过逆向和实测确认了一个关键事实：

> ⚠️ **本地 OneBot 调用（`get_status`、`get_config` 等）不会产生到腾讯服务器的协议活动，因此不能保活。只有真实的消息收发才行。**

那么怎么"造"一条真实消息、又不打扰任何人？

NapCat 登录后，机器人的**好友列表里包含它自己**。实测 `send_private_msg` 把私聊消息发给自己（`user_id` 填机器人自己的 QQ 号），接口返回 `retcode = 0`：

- 这是一条真实的私聊消息，会产生真实的协议活动；
- 消息只发给自己，**零打扰任何好友、任何群**；
- 每隔 **随机 10–17 分钟**（远低于被踢阈值 23 分钟）发一条，看起来更自然。

### 2. 看门狗：检测离线 → 先判断场景，再对症恢复

每 20 秒检测一次在线状态，连续 2 次离线（约 40 秒）才判定需要恢复。恢复不是无脑杀进程，而是**先判断当前是什么情况，再走对应的路**：

| 当前情况 | 守护脚本的动作 |
|----------|----------------|
| **NapCat 根本没运行**（刚开机 / 崩溃后，WebUI 也连不上） | **立即启动 NapCat**，不做任何无谓等待 |
| **登录态已明确失效**（提示"身份已失效，请重新登录"） | **立即刷新二维码、弹窗请人扫码**，不反复强杀 |
| **在线过、遇到网络抖动**（错误码 `1006514`） | 先等最多 90 秒让它自愈，不杀进程 |
| **真的被踢、但登录态仍有效** | 进程内 `SetQuickLogin` 快速登录（2 次） |
| **worker 卡死** | `RestartNapCat` 重启 worker（不杀 QQ） |
| **以上都无效** | 最后才彻底 kill QQ 重启 |

> 关键原则：**能不杀进程就不杀，能不打断就不打断。**
> - WiFi 短暂波动（`1006514 网络连接异常`）非常常见，几秒到十几秒会自行恢复，一发现离线就强杀 QQ，反而会让快速登录凭证失效、逼你重新扫码；
> - 开机时 NapCat 本来就没跑，空等"宽限期"毫无意义，所以直接拉起；
> - 登录态一旦明确失效，自动恢复注定失败，第一时间弹窗让你扫码，而不是空转几分钟。

### 3. 兜底：需要人工扫码时 → 立即弹窗

当检测到必须人工扫码（登录态失效）时，脚本会：

1. 刷新最新的登录二维码；
2. 用 `msg.exe` 弹出系统提示框（含二维码图片路径），提示你扫码；
3. 等待 1 小时后再自动重试，避免空转。

---

## NapCat 和 AstrBot 各需要改什么

本仓库**只包含优化/稳定部分，不包含 NapCat 与 AstrBot 的基础安装**（假设你已经装好并能正常使用）。两部分的职责如下：

| 部分 | 为了本方案需要做什么 | 是否必须 |
|------|----------------------|----------|
| **NapCat** | 开启**本地 HTTP API**（`127.0.0.1:3000`），守护脚本靠它发保活消息、检测状态；配置 `webui.json` 以便快速登录/重启 | **必须**（保活的前提） |
| **AstrBot** | 配好反向 WebSocket（`6199`）接收 NapCat；配置**模型降级链**（一个模型不可用就切下一个） | 仅对接参考，保活**不依赖**它，**无需整体替换配置** |

> 说明：保活机制完全运行在 NapCat 侧（给机器人自己发私聊消息）。AstrBot 只是被守护脚本顺带拉起、被 NapCat 连接的下游，所以 `config/astrbot/cmd_config.example.json` 只列出了**与对接和稳定性相关的关键字段**，供你在已有 AstrBot 的 WebUI 里对照修改，而不是让你整体覆盖。

---

## 目录结构

```
napcat-guardian/
├── README.md                        # 本文件
├── LICENSE                          # MIT 协议
├── scripts/
│   ├── guardian.ps1                 # 核心：保活 + 看门狗 + 自动恢复
│   ├── install_guardian.ps1         # 安装器（注册为计划任务）
│   ├── install_guardian.bat         # 自提权安装器（右键管理员运行）
│   ├── network_fix.ps1              # 关闭 WiFi 网卡省电，网络更稳
│   └── start_bot.bat                # 可选：手动一键启动 AstrBot + NapCat
├── config/
│   ├── napcat/
│   │   ├── onebot11.example.json    # OneBot11：本地 HTTP API + 反向 WS（保活前提）
│   │   ├── napcat.example.json      # NapCat 运行配置
│   │   └── webui.example.json       # WebUI 配置（token 已脱敏）
│   └── astrbot/
│       └── cmd_config.example.json  # AstrBot 关键配置参考（仅对接/降级，非完整配置）
└── docs/
    ├── 部署指南.md
    ├── 原理说明.md
    └── 常见问题.md
```

## 快速开始

> **前置（本仓库不包含基础安装）**：你已经按照官方文档安装好 [NapCat](https://github.com/NapNeko/NapCatQQ) 和 [AstrBot](https://github.com/AstrBotDevs/AstrBot)，机器人能扫码登录、能正常收发消息。下面只做"让它挂得稳"的优化配置。

### 第 1 步：准备配置

1. 把本仓库下载/克隆到任意位置（建议纯英文路径，如 `D:\napcat-guardian`）。
2. 打开 `scripts/guardian.ps1`，修改顶部 **Configuration 区**：

```powershell
$QQ_UIN     = "你的机器人QQ号"
$ADMIN_UIN  = "你的管理员QQ号"
$NAPCAT_DIR = "D:\napcat\NapCat.Shell"
$ASTRBOT_DIR  = "C:\Users\你的用户名\qq-deepseek-bot\astrbot"
$PYTHON_EXE   = "C:\Users\你的用户名\AppData\Local\Programs\Python\Python314\python.exe"
$WEBUI_TOK  = "你的 NapCat WebUI token"
```

3. 确保 NapCat 已开启**本地 HTTP API**（默认 `http://127.0.0.1:3000`）。可直接参考 `config/napcat/onebot11.example.json`，复制到 NapCat 的 `config/` 目录并改名为 `onebot11_<你的机器人QQ>.json`。

### 第 2 步：安装守护任务

**右键** `scripts/install_guardian.bat` → **以管理员身份运行**。

安装器会：

- 注册一个名为 `NapCatGuardian` 的计划任务（**最高权限、开机自启、隐藏窗口、崩溃自动重启**）；
- 立即启动守护脚本，无需重启。

### 第 3 步：（可选）修复网络

如果你用 WiFi 挂机，建议再以管理员身份运行一次：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\network_fix.ps1
```

它会关闭网卡"空闲断电省电"、把无线适配器调到最高性能，并重启网卡（会断网几秒）。

### 验证

- 计划任务存在且状态为 `Running`：
  ```powershell
  Get-ScheduledTask -TaskName NapCatGuardian
  ```
- 日志文件 `guardian.log` 里出现 `keep-alive sent` 即保活生效。

---

## 配置说明

### guardian.ps1 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `$KEEPALIVE_MIN` / `$KEEPALIVE_MAX` | 600 / 1000 秒 | 保活间隔随机区间（10–17 分钟），务必小于被踢阈值 |
| `$CHECK_INTERVAL` | 20 秒 | 看门狗检测间隔 |
| `$OFFLINE_LIMIT` | 2 | 连续几次离线才判定需要恢复 |
| `$RECOVER_COOLDOWN` | 300 秒 | 两次完整恢复之间的冷却 |
| `$MAX_RECOVER` | 3 | 最多连续自动恢复几次，超过就等人扫码 |
| `$KA_POOL` | 若干短句 | 保活消息内容，可自行改成更自然的 |

### 端口约定（可改）

| 服务 | 端口 | 说明 |
|------|------|------|
| NapCat OneBot11 HTTP API | 3000 | 绑定 127.0.0.1，守护脚本调用它 |
| NapCat WebUI | 6099 | 守护脚本用它做快速登录/重启 |
| AstrBot 反向 WebSocket 服务端 | 6199 | NapCat 主动连过来 |
| AstrBot WebUI | 6185 | 浏览器管理面板 |

> ⚠️ 本地 API 建议只绑定 `127.0.0.1` 且不要对外暴露，也不要使用弱 token。

---

## 关键踩坑记录

这些是我们实际验证过、确认"走不通"的方向，避免你重复踩坑：

1. **本地 API 不能保活**。`get_status` / `get_config` 等调用不经过腾讯服务器，调再勤也会被踢。必须发真实消息。
2. **登录态失效后，进程内 `SetQuickLogin` 无法免扫码**，腾讯返回 `code = -1「登录态已失效」`。
3. **会话已建立时再调 `SetQuickLogin` 会触发 `onUserLoggedIn` 回调**，而该回调只设置错误文案、不真正置上线，导致"底层似登录、逻辑未上线"的卡死中间态。守护脚本通过"仅在离线时调用、且调用后检测真实在线状态"来规避。
4. **网络抖动 ≠ 被踢**。错误码 `1006514 网络连接异常` 是网络层问题，没有 `KickedOffLine` 就不是被踢，等它自愈即可，不要杀进程。
5. **WiFi 网卡省电会导致空闲断流**。注册表 `PnPCapabilities = 16` 表示允许空闲断电，应改为 `24`（见 `network_fix.ps1`）。
6. 普通（非管理员）PowerShell 执行 `taskkill /f /im QQ.exe`、改 `HKLM` 会报 `Access denied`，所以守护任务必须以**最高权限**运行。

## 防风控 / 养号建议

- **保活间隔不要固定、不要太短**。固定整点发消息反而像机器人；建议 10–17 分钟随机。
- 保活消息内容尽量短、自然，可偶尔变化。
- 机器人账号最好有正常使用痕迹（头像、昵称、少量真实好友/群），新号、小号更容易被风控。
- 不要更新到最新版 QQ 后立即挂 NapCat；保持 NapCat 官方推荐的 QQ 版本。
- 长期挂机、条件允许时，**优先用有线网络**，比 WiFi 稳定得多。

## 常见问题

详见 [docs/常见问题.md](docs/常见问题.md)。简要列出：

- **Q：计划任务里脚本不运行？**
  A：确认任务是"最高权限"、触发器是"登录时"，且执行策略允许 `-ExecutionPolicy Bypass`。

- **Q：开机后 NapCat 没自动启动？**
  A：新版检测到 NapCat 没运行会立即拉起；确认用的是最新 `guardian.ps1`。若提示"身份已失效"，扫码一次即可（会自动弹窗）。

- **Q：还是经常需要扫码？**
  A：先看日志是不是被踢（有 `KickedOffLine`）还是网络问题；把保活间隔调小一点，并确认是给自己发消息、`retcode=0`。

- **Q：`msg.exe` 弹窗不出现？**
  A：部分家庭版/精简版 Windows 没有 `msg.exe`，可改用其它通知方式（如发邮件、Server 酱）。

- **Q：AstrBot 没被守护脚本拉起来？**
  A：检查 `$ASTRBOT_DIR`、`$PYTHON_EXE` 路径是否正确，手动执行一次 `python main.py` 看报错。

---

## 免责声明

本项目仅用于**学习与个人运维经验分享**，不包含 QQ / NapCat / AstrBot 的任何官方代码或安装包。

- 使用第三方协议登录 QQ 可能违反腾讯相关服务条款，存在**账号被限制、封禁**的风险，一切后果由使用者自行承担。
- 请勿将本项目用于任何违法违规用途。
- 仓库中的配置示例均为脱敏占位，使用时请替换为你自己的信息，并**妥善保管 API Key、WebUI Token 等敏感信息**，不要提交到公开仓库。

相关项目版权归各自所有：NapCat、AstrBot、QQ。

## License

[MIT License](LICENSE)
