# AGENTS.md — 在这个仓库里改代码前的须知

本仓库是 **Windows 上 NapCat/QQ 机器人的常驻守护套件**：PowerShell 脚本 + 一个零依赖 Node 控制台，
直接跑在「唯一一台生产机」上（不是容器、不是 CI 环境）。任何改动都可能让机器人掉线、让扫码页失效，
所以这里优先要求 **可验证、可回滚、一次只动一个变量**。

---

## 1. 硬约束（违反会直接造成生产事故）

1. **绝对不要动 DSH Web（`127.0.0.1:3080`）**。它承载着操作者正在使用的对话界面，杀掉它等于切断工作通道。
2. **所有 `.ps1` 必须保存为 UTF-8 with BOM**。Windows PowerShell 5.1 在无 BOM 时按 GBK 解析含中文的脚本，
   会报 `Missing closing '}'` / `The string is missing the terminator`，而且计划任务只留一行 `LastTaskResult`，
   几乎无法定位。改完立刻自检：
   ```powershell
   $p = 'scripts\runtime\guardian.ps1'
   [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p)), [Text.UTF8Encoding]::new($true))
   $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); $e
   ```
3. **不要升级 QQ 客户端**。当前固定 `QQ NT 9.9.31.49738` + `NapCat 4.18.42`；升级 QQ 历史上会导致 NapCat 无法注入。
4. **不要用 `taskkill /IM QQ.exe`** 之类的映像名杀进程——同一台机器上还有操作者的桌面 QQ。
   只能按进程树杀（见 `Get-NapCatOwnedPids` / `Stop-NapCatOwned`）。
5. **正在进行的实验不要叠加变量**。`o3HookMode` 的单变量对照（`docs/实验-o3HookMode.md`）还在观察期，
   请不要同时改保活间隔、恢复阈值、群主动消息频率。
6. **不要把任何真实凭据写进仓库**：QQ 号、WebUI token、邮箱授权码、ngrok authtoken、内网 IP 一律用占位符
   （`YOUR_BOT_QQ`、`YOUR_WEBUI_TOKEN`、`YOUR_SMTP_AUTH_CODE`、`<lan-ip>`）。

## 2. 环境事实（别按默认值假设）

| 项 | 值 |
|---|---|
| 生产目录 | `D:\napcat`（NapCat 在 `D:\napcat\NapCat.Shell`，守护脚本在 `D:\napcat\guardian.ps1`） |
| 仓库 | `D:\napcat-guardian`（`main` 单分支） |
| PowerShell | Windows PowerShell **5.1**（不是 pwsh 7） |
| Node | `C:\Program Files\nodejs\node.exe`（v24） |
| Python | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe`（AstrBot） |
| 端口 | 3000 OneBot / 6099 NapCat WebUI / 6185+6199 AstrBot / 8430 qrsync / 8440 控制台 / 3080 DSH（禁止触碰） |
| 推送 | 大陆网络需代理：`git -c http.proxy=http://127.0.0.1:7891 -c https.proxy=http://127.0.0.1:7891 push origin main`（7890 已失效） |
| 提交作者 | `wjy2468 <210205876+wjy2468@users.noreply.github.com>`（用真实邮箱会被 GitHub 拒绝：GH007） |

## 3. 改动流程

1. **先读再改**：涉及恢复逻辑时先看 `Do-Recovery` 全部分支和 `docs/原理说明.md`，不要只看一段。
2. **一次一件事**：一个提交只解决一个问题，提交信息写清「为什么」而不只是「改了什么」。
3. **改完必跑**（任一失败就不要提交）：
   ```powershell
   powershell -File scripts\ops\validate-repo.ps1
   powershell -File scripts\runtime\guardian.ps1 -SelfTest
   powershell -File scripts\research\recovery-sim.ps1
   ```
4. **部署到生产是独立一步**：仓库代码与 `D:\napcat` 下的生产副本是两份文件，`check-sync.ps1` 会对比它们。
   未经允许不要直接改生产目录，也不要在没有备份的情况下覆盖。
5. **推送前**：`git status` 必须干净、`git log` 与远端一致；推送后回读远端 raw 确认，不要仅凭本地状态下结论。

## 4. 代码审查时请重点看这些

- **恢复决策树 `Do-Recovery`**：分支可达性（有没有被前面的分支永远遮蔽）、互相重复重启、返回值与调用方 `switch` 是否一致。
- **PowerShell 5.1 兼容**：BOM、`$PID` 等只读变量、`if` 当表达式用、字符串插值里 `$var?` 被当成变量名、`-Encoding` 差异。
- **端口与隧道**：本地 `8430`（qrsync）与公网 `8440`（控制台）不可混用；`daemon.ps1` 的 `$port` / `$tunnelPort` 是两个东西。
- **单实例与并发**：全局互斥体、心跳接管、计划任务重复触发、`-Stop` 是否会误杀别的实例。
- **被吞掉的错误**：`catch {}`、`try { } catch { return $false }` 不记日志的地方，等于故障不可见。
- **时间处理**：本地时间 vs epoch、跨天/跨年、`DateTime.MinValue` 参与运算。

**输出格式**：每条问题给出 `文件:行号`、触发条件、后果、修复建议、严重度（P0 立即致命 / P1 会静默失效 / P2 可改进）。
不要报命名、排版、注释风格类问题，也不要为了「更优雅」重构正在生产运行的脚本。

## 5. 不要建议的方向

- 升级 QQ 客户端或 NapCat 大版本（会破坏兼容性；版本实验需操作者明确同意）
- 把保活间隔改得更频繁、加更多自动重启（历史证明这会加重风控）
- 用按映像名杀进程、`robocopy /MIR` 反向同步、`Remove-Item -Recurse` 通配符这类高风险命令
- 在没有测量数据的情况下「优化」阈值——先取证，再改，再对比（`kick-report.ps1 -Json` + `experiment-compare.ps1`）