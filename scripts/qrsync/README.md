# NapCat 登录二维码公网同步（常驻版）

把 NapCat 每次登录时生成、**每约 2 分钟自动刷新**的 `qrcode.png` 实时投到公网上，
手机在任意网络下都能扫码登录电脑上的 QQ 机器人。

## 现在的形态

```
NapCat 写 qrcode.png
        │
        ▼
  qrsync.js (:8430 本机 HTTP，按 mtime 判新鲜度)
        │
        ▼
  隧道（ngrok 固定域名 / cloudflared / localhost.run）
        │
        ▼
  手机浏览器 https://<固定域名>/?k=<密钥>
        ▲
        └── daemon.ps1 守护：服务挂了重启、隧道断了重连、假死自检
              ↳ 计划任务 QRSyncDaemon（登录时自启，静默）
```

- **开机自启**：计划任务 `QRSyncDaemon`，登录后 30 秒拉起，窗口全隐藏。
- **掉线自动重连**：守护进程每 5 秒看一次进程、每 60 秒对公网 URL 做端到端自检；
  隧道断了按 5s→10s→30s→60s 退避重连，进程活着但连接假死也会被拉起来。
- **域名固定**：配好 ngrok 固定域名后，地址永远是同一个（见下）。

## 首次配置（只需一次）

### 1. ngrok 固定域名（已配置好）

当前固定地址：`https://your-subdomain.ngrok-free.dev`

凭据在 `config.json` 的 `ngrok` 段里（`authToken` + `domain`），ngrok 自己也存了一份在
`C:\Users\<你>\AppData\Local\ngrok\ngrok.yml`。要换域名就改 `config.json` 的 `domain`，
然后 `daemon.ps1 -Stop` + `schtasks /run /tn QRSyncDaemon`。

没配 ngrok 时会自动退回 cloudflared 快速隧道：连接稳，但**每次重连域名都会变**。

> **免费版有个提示页**：手机浏览器第一次访问会看到 ngrok 的 "You are about to visit…" 页面，
> 点一次 **Visit Site** 就进正文，之后同浏览器有 cookie 不再拦。
> 脚本自己的健康检查会带 `ngrok-skip-browser-warning` 头绕过它，所以自检不受影响。

### 2. 在哪看当前地址

- `D:\napcat\qrsync\current-url.txt`（守护每次地址变化都会更新）
- 或前台跑一次看输出：`powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\start-qr.ps1`

## 日常使用

- 平时不用管，服务常驻。
- 要登录 / 换号时：打开 NapCat WebUI `http://127.0.0.1:6099` 触发登录 →
  手机打开固定域名 → 看到二维码 → 扫。二维码刷新时页面自动换图，不用刷新。
- 页面底部「结束并关闭」会关掉**本地服务和页面**（守护进程几秒内会重新拉起，除非用 `-Stop`）。

## 管理命令

```powershell
# 停止守护 + 服务 + 隧道
powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\daemon.ps1 -Stop

# 重新启动
schtasks /run /tn QRSyncDaemon

# 看日志
Get-Content D:\napcat\qrsync\daemon.log -Tail 30 -Wait

# 临时关闭开机自启
schtasks /change /tn QRSyncDaemon /disable
schtasks /change /tn QRSyncDaemon /enable
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `daemon.ps1` | 守护进程：保活 + 重连 + 自检 + 写 `current-url.txt` |
| `qrsync.js` | 本地 HTTP 服务，路由 `/`、`/qrcode.png`、`/status`、`/close` |
| `config.json` | 端口、二维码路径、隧道优先级、ngrok 凭据 |
| `key.txt` | 访问密钥（换掉即作废旧链接） |
| `start-qr.ps1` / `start-qr.bat` | 前台手动模式（调试用） |
| `cloudflared.exe` / `ngrok.exe` | 隧道客户端 |
| `daemon.log` / `server.*.log` / `tunnel-*.log` | 排查用 |

## 安全

- 公网只暴露一个**只读**页面，不碰 NapCat 的 6099 WebUI 和 OneBot 端口。
- 所有路径都要求 `?k=` 密钥，密钥错直接 404。
- 二维码本身有时效，扫完即废；页面不缓存（`no-store`）。
- 换密钥：改 `key.txt` → `daemon.ps1 -Stop` → `schtasks /run /tn QRSyncDaemon`。

## 排错

| 现象 | 处理 |
| --- | --- |
| 页面超时 / 502 | 隧道在重连，等 1 分钟；看 `daemon.log` |
| 一直 `expired` | 当前没有待扫码的登录，去 NapCat WebUI 触发一次 |
| 二维码路径不同 | 改 `config.json` 的 `qrFile` |
| 端口冲突 | 改 `config.json` 的 `port`（常驻时注意同步 `key`/URL） |
| 想彻底不用隧道 | 删 `config.json` 里的 `providers` 只留空数组，只走本机 |
