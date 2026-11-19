param([switch]$SelfTest)
# 本机代理配置可能把 localhost 请求错误地送往失效端口；看护的本地 API
# 与公网扫码端到端探测都必须直连，避免因此误判掉线或反复重建隧道。
[System.Net.WebRequest]::DefaultWebProxy = $null

# ============================================================
#  NapCat Guardian - Keep-alive + Auto-recovery
#  - Keep-alive probe: the bot sends a message to ITSELF after 10 minutes
#    of silence (nobody else is disturbed). Real protocol activity, and the
#    only reliable way to notice a "fake online" state, where get_status
#    still says online but every send fails with 1006514 / 网络连接异常.
#  - Watchdog: detects offline and recovers intelligently:
#      * NapCat not running at all (e.g. after boot) -> launch it
#        immediately, do NOT wait.
#      * Was online, brief network blip -> wait for self-heal.
#      * Saved session clearly expired -> pop up QR code at once,
#        do NOT repeatedly kill/restart.
#      * Send failures while "online" -> restart worker only, which usually
#        logs back in with the cached token (no scan needed).
#
#  Secrets (WebUI token, SMTP auth code, ntfy topic) live in
#  guardian.config.json, which is git-ignored.
#
#  Recommended to run as a Scheduled Task with HIGHEST privileges
#  (run the installer .bat as administrator once).
# ============================================================

# ---------------- Configuration ----------------
# 日常只需要改这三行：机器人 QQ 号、部署根目录、WebUI token。
$QQ_UIN      = "YOUR_BOT_QQ"
$NAPCAT_HOME = "D:\napcat"          # 部署根目录（guardian.ps1 / 日志 / 标志文件都放这里）
$WEBUI_TOK   = ""                   # 留空 = 从 guardian.config.json 的 webuiToken 读取
$PYTHON_EXE  = Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\python.exe"
                                            # 日报用；可在 guardian.config.json 里覆盖

$HTTP_API   = "http://127.0.0.1:3000"
$WEBUI_API  = "http://127.0.0.1:6099"

# 其余路径全部由 $NAPCAT_HOME 派生：以前 D:\napcat 被硬编码了十几次，
# 换目录（或把这套东西搬到另一台机器）时漏改一处就会静默写错文件。
$NAPCAT_DIR     = Join-Path $NAPCAT_HOME "NapCat.Shell"
$LOG_FILE       = Join-Path $NAPCAT_HOME "guardian.log"
$QR_FILE        = Join-Path $NAPCAT_DIR  "cache\qrcode.png"
$KICK_LOG       = Join-Path $NAPCAT_HOME "kick.log"

# 掉线现场快照（incident-snapshot.ps1）：被踢时自动抓一次，10 分钟限频。
# 依次尝试：同目录 -> 兄弟目录 ops（仓库分层结构）-> 部署根目录（生产平铺），三种放法都能用。
$SNAPSHOT_SCRIPT = Join-Path $PSScriptRoot "incident-snapshot.ps1"
if (-not (Test-Path $SNAPSHOT_SCRIPT)) { $SNAPSHOT_SCRIPT = Join-Path $PSScriptRoot "..\ops\incident-snapshot.ps1" }
if (-not (Test-Path $SNAPSHOT_SCRIPT)) { $SNAPSHOT_SCRIPT = Join-Path $NAPCAT_HOME "incident-snapshot.ps1" }
$SNAPSHOT_MIN_GAP_MIN = 10
$script:LastSnapshot = [DateTime]::MinValue
$HEARTBEAT_FILE = Join-Path $NAPCAT_HOME "guardian.heartbeat"
$AB_FLAG        = Join-Path $NAPCAT_HOME "restart-astrbot.flag"
$FORCE_FLAG     = Join-Path $NAPCAT_HOME "force-relaunch.flag"
$REPORT_SCRIPT  = Join-Path $NAPCAT_HOME "daily-report.py"
$REPORT_STAMP   = Join-Path $NAPCAT_HOME "last-report.txt"
$REPORT_LOG     = Join-Path $NAPCAT_HOME "daily-report.log"
$REPORT_ATTEMPT = Join-Path $NAPCAT_HOME "last-report-attempt.txt"
$REPORT_HOUR    = 9
# 机器人登录状态文件：给 qrsync 网页读，用来在页面上显示"需要扫码"提示
$STATE_FILE = Join-Path $NAPCAT_HOME "qrsync\login-state.json"
# 本次登录（= 当前票据）开始的时间，用于主动续期
$SESSION_FILE = Join-Path $NAPCAT_HOME "session-since.txt"
# 可观测性：给 qrsync 网页 / 外部监控读的一页指标（会话时长、今日被踢次数、下次探针时间）
$METRICS_FILE = Join-Path $NAPCAT_HOME "metrics.json"
# 公网扫码入口健康：daemon.ps1 每次公网自检写这里，guardian 读到失败就告警
$TUNNEL_STATE_FILE         = Join-Path $NAPCAT_HOME "qrsync\tunnel-state.json"
$TUNNEL_ALERT_MIN          = 10
$TUNNEL_ALERT_COOLDOWN_MIN = 60
$TUNNEL_ALERT_STAMP        = Join-Path $NAPCAT_HOME "tunnel-alert.last"

# ---------------- 敏感配置：从 guardian.config.json 读取（该文件不进 git） ----------------
# 文件格式（缺项就用本文件里的默认值）：
#   { "webuiToken": "xxx", "qrPageUrl": "https://...", "ntfyTopic": "xxx",
#     "notifyNtfy": true, "notifyToast": true }
$NOTIFY_NTFY       = $true
$NOTIFY_TOAST      = $true
$NOTIFY_NTFY_TOPIC = ""
# ntfy.sh 在国内大概率超时（本机实测每次都 15 秒后才抛错），而它排在邮件之前：
# 每发一条告警都要先白等 15 秒，邮件才发得出去。所以给它加"熔断"：
# 连续失败 3 次就在 6 小时内直接跳过，告警延迟回到秒级。
$NTFY_TIMEOUT_SEC    = 6
$NTFY_FAIL_MAX       = 3
$NTFY_COOLDOWN_H     = 6
$NTFY_DOWN_FILE      = "D:\napcat\ntfy-down.until"
$QR_PAGE_URL       = ""
# 备用通知通道（ntfy.sh 在国内经常超时，必须有不依赖外网的兜底）：
#   notifyEmail   : { "smtp":"smtp.qq.com", "port":465, "user":"xxx@qq.com",
#                     "pass":"SMTP授权码", "to":"xxx@qq.com" }
#   notifyWebhook : { "type":"wecom|dingtalk|feishu|serverchan|pushplus|custom", "url":"..." }
$NOTIFY_EMAIL      = $null
$NOTIFY_WEBHOOK    = $null
$CFG_PATH = Join-Path $NAPCAT_HOME "guardian.config.json"
if (Test-Path $CFG_PATH)
{
    try
    {
        $gcfg = Get-Content $CFG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($gcfg.webuiToken) { $WEBUI_TOK = [string]$gcfg.webuiToken }
        if ($gcfg.ntfyTopic) { $NOTIFY_NTFY_TOPIC = [string]$gcfg.ntfyTopic }
        if ($gcfg.qrPageUrl) { $QR_PAGE_URL = [string]$gcfg.qrPageUrl }
        if ($null -ne $gcfg.notifyNtfy) { $NOTIFY_NTFY = [bool]$gcfg.notifyNtfy }
        if ($null -ne $gcfg.notifyToast) { $NOTIFY_TOAST = [bool]$gcfg.notifyToast }
        if ($gcfg.notifyEmail) { $NOTIFY_EMAIL = $gcfg.notifyEmail }
        if ($gcfg.notifyWebhook) { $NOTIFY_WEBHOOK = $gcfg.notifyWebhook }
        if ($gcfg.pythonExe) { $PYTHON_EXE = [string]$gcfg.pythonExe }
    }
    catch { }
}

# Keep-alive interval (seconds) —— 2026-11-15 改为"固定 10 分钟健康探针"。
# 理由：11-13 那次「假在线」从 16:38 一直拖到 17:27（49 分钟）才被发现，
# 而 20-40 分钟的重尾随机间隔最坏要 40 分钟才探一次。保活本身防不住腾讯踢线
# （6 次被踢全部发生在活跃对话中），它的真正价值是"发一条消息，看内核报不报错"，
# 所以探针频率就等于故障发现的上限：固定 10 分钟 → 最坏 10 分钟发现，
# 成本约 144 条自发消息/天，且这些消息不会进入 LLM（waking_check 拦截），不耗 token。
$KEEPALIVE_MIN       = 600    # 固定 10 分钟（MAX 只用于 Get-Random 上界）
$KEEPALIVE_MAX       = 601
$KEEPALIVE_IDLE_MIN  = 10     # 距最后一次真实收发 < 10 分钟就不发（有人聊天时探针没意义）
$KEEPALIVE_NIGHT_FROM = 0     # 0/0：夜间也探。探针发给机器人自己，不打扰任何人，
$KEEPALIVE_NIGHT_TO   = 0     # 而夜间恰恰是无人值守、最需要自动发现的时间段
$QR_MODE_MAX_MIN     = 30    # NapCat 停在登录页超过这么久仍没人扫，才认为登录页卡死、做一次全量重启

# Watchdog
$CHECK_INTERVAL   = 20    # seconds between status checks
$OFFLINE_LIMIT    = 2     # consecutive offline checks before recovery
$RECOVER_COOLDOWN = 300   # seconds between full recovery attempts
# 每个掉线事件最多自动重启 1 次。社区实测：守护脚本反复重启 = 连续无效登录尝试，
# 是腾讯风控判定"外挂/异常"的主要信号，重启风暴会导致账号被冻结。失败就转人工。
$MAX_RECOVER      = 1
$CIRCUIT_MINUTES  = 120   # 自动重启失败后熔断 2 小时，期间不再碰 NapCat
$NIGHT_QUIET_FROM = 2     # 凌晨 02:00-07:00 是风控高发时段
$NIGHT_QUIET_TO   = 7
$NIGHT_MIN_GAP    = 3     # 夜间只在距上次尝试 >3 小时时才再试

# 缓存 token 登录等待窗口（秒）。实测缓存 token 登录偶尔要 2~5 分钟，
# 以前只等 150 秒就判失败，白白多出一次扫码。
$LOGIN_WAIT_SEC   = 480   # 全量重启（launcher）后等登录
$WORKER_WAIT_SEC  = 240   # RestartNapCat 后等登录
$QUICK_RETRY_SEC  = 90    # 等待期间每隔多少秒补一次 SetQuickLogin

# 发送失败探测：长连接已死时 get_status 仍报 online=true（11-11 16:43 那次
# 假在线整整 50 分钟）。所以额外盯 NapCat 自己的日志：出现"网络连接异常"
# 就说明发不出去，立刻走 RestartNapCat（保留 QQ、用缓存 token，免扫码）。
$NAP_LOG_DIR        = Join-Path $NAPCAT_DIR "logs"
$SENDFAIL_WINDOW    = 300  # 统计窗口（秒）
# 1 次就够：NapCat 日志里的 "网络连接异常 / EventChecker Failed" 是 QQ 内核
# 异步报上来的发送失败，不是 API 层的抖动（API 照样返回 retcode 0）。
# 2026-11-13 09:32 那次只出现了一条，阈值设 2 就永远等不到第二次 → 假在线拖了很久。
# 为了不误杀，命中后先发一条探针消息复核（Confirm-SendBroken），确认是真死才重启。
$SENDFAIL_THRESHOLD = 1
$SENDFAIL_COOLDOWN  = 600  # 两次"连接重置"之间的最小间隔（秒）

# 桌面上手动开的 QQ 和机器人的 QQ 是同一个 exe、同一份用户数据目录，
# 同时开会互相挤掉。检测到"非 NapCat 拉起的 QQ"时先不重拉机器人，
# 避免来回互踢；超过这个分钟数还没关，就恢复机器人（机器人优先）。
$FOREIGN_WAIT_MIN = 30

# QQ 数据目录隔离（可选）。桌面 QQ 和机器人的 QQ 是同一个 exe、同一份用户数据
# 目录（C:\Users\<你>\AppData\Roaming\QQ），Electron 的单实例锁会让两者互踢：
# 你在桌面登大号，机器人的 QQ 就被顶掉；反过来也一样。
# NapCat 4.18+ 支持环境变量 NAPCAT_QQ_DATA_DIR：指到独立目录后，机器人拥有
# 自己的一份 QQ 数据，桌面 QQ 和大号就互不影响了。
# 代价：切换的那一刻机器人要重新扫码登录一次（新目录里没有登录票）。
$QQ_DATA_DIR = Join-Path $NAPCAT_HOME "qqdata"   # 留空 = 不隔离（与桌面 QQ 共用）

# ---- 主动会话续期（2026-11-15 取证后新增）----
# 14 次被踢的会话存活时长：121/137/50/35/26/116/117/18/109/117/121/117/121/112 分钟，
# 中位 117，10/14 落在 109-121 区间；被踢前 30 行没有任何网络告警、也没有发送失败，
# 且被踢时常常正在正常收发消息 —— 这不是"静默超时"，更像登录票据的约 2 小时有效期。
# 既然有效期从登录那一刻开始算，那就在到期前主动 RestartNapCat 重新登录一次
# （刷新票据），把"随时可能被踢 + 需要等恢复"变成"计划内的 30 秒重启"。
# 只在没人聊天时做（$PROACTIVE_IDLE_MIN），避免打断对话。0 = 关闭。
# 2026-11-15 13:03 实测：按 100 分钟主动 RestartNapCat 续期，worker 起来后
# 直接停在二维码（isLogin=False、无 loginError），票据并没有被复用 ——
# 也就是说这条路会强制一次扫码，比被踢还糟。所以默认关闭（0）。
# 2026-11-17 实测 3 次主动续期只成功 1 次，且成功后新会话仅 85 分钟又被踢，
# 无法突破服务端 TTL，失败的两次反而强制扫码。故停用（0 = 关闭），回到被动快速恢复。
# 保留 $PROACTIVE_IDLE_MIN 与相关函数，后续若需要重新启用，把此值改回 105 即可。
$PROACTIVE_REFRESH_MIN = 0
$PROACTIVE_IDLE_MIN    = 15

# Random natural-looking keep-alive messages (sent to self)
$KA_POOL = @(
    "ok",
    "in service",
    "still here",
    "check",
    "running",
    "alive",
    "good",
    "uptime check"
)

# ---------------- Logging ----------------
# 实测 11.2 KB/天（约 4 MB/年），正常不会爆；但重启风暴/熔断期会突然放量，
# 所以按 4 MB 轮转，最多占 8 MB（guardian.log + guardian.log.1）。
$LOG_MAX_BYTES = 4MB
function Write-Log($msg)
{
    # 自检进程的日志只打到控制台，避免污染生产 guardian.log（否则会留下假记录）。
    if ($script:SelfTestMode) { Write-Host ("[selftest] " + $msg); return }
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try
    {
        if (Test-Path $LOG_FILE)
        {
            if ((Get-Item $LOG_FILE).Length -gt $LOG_MAX_BYTES)
            {
                Move-Item -Path $LOG_FILE -Destination "$LOG_FILE.1" -Force
            }
        }
    }
    catch { }
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

# 心跳：<pid>|<时间>。另一个实例靠它判断"这个 guardian 还活着吗"。
# 必须尽早定义 —— 恢复流程里有几段长达 10 分钟的等待（Launch-NapCat 等 WebUI、
# Wait-Scan 等扫码），如果那段时间不写心跳，第二个实例会以为它是僵死进程而杀掉它。
function Write-Heartbeat
{
    try
    {
        $txt = "{0}|{1}" -f $PID, (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        [System.IO.File]::WriteAllText($HEARTBEAT_FILE, $txt, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------- 通知通道（ntfy.sh 推送 + 本机 toast），按状态跃迁去重 ----------------
# 家庭版没有 msg.exe，所以原来那条"弹窗提醒"其实大概率没送达。
$script:NotifyLast = @{}

function Show-Toast([string]$title, [string]$body)
{
    if (-not $NOTIFY_TOAST) { return }
    try
    {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $tpl.GetElementsByTagName("text")
        $texts.Item(0).AppendChild($tpl.CreateTextNode($title)) | Out-Null
        $texts.Item(1).AppendChild($tpl.CreateTextNode($body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("NapCat Guardian").Show($toast)
    }
    catch { }
}

# HTTP 头只允许 ASCII：标题里的中文如果直接塞进 Title 头，.NET 会抛异常或写成 '?'。
# ntfy 支持 RFC 2047 的 encoded-word（=?UTF-8?B?<base64>?=），用它承载非 ASCII 标题。
function ConvertTo-NtfyHeaderText([string]$s)
{
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $ascii = $true
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 127) { $ascii = $false; break } }
    if ($ascii) { return $s }
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
    return "=?UTF-8?B?" + $b64 + "?="
}

# ---------------- 备用通道 1：邮件（国内可达，最稳） ----------------
function Send-EmailNotification([string]$title, [string]$body, [string]$attachPath = "")
{
    if (-not $NOTIFY_EMAIL) { return $false }
    try
    {
        $cfg = $NOTIFY_EMAIL
        if (-not $cfg.smtp -or -not $cfg.user -or -not $cfg.pass) { return $false }
        $to = [string]$cfg.to
        if (-not $to) { $to = [string]$cfg.user }
        # 注意：.NET 的 SmtpClient 只支持 STARTTLS（显式 TLS），用 465 会报
        # "Unable to read data from the transport connection: net_io_connectionclosed"
        # （2026-11-13 实测）。QQ 邮箱用 587 + EnableSsl 才能发出去。
        $port = 587
        if ($cfg.port) { $port = [int]$cfg.port }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress([string]$cfg.user)
        foreach ($addr in ($to -split '[;,]')) { if ($addr.Trim()) { $msg.To.Add($addr.Trim()) } }
        $msg.Subject = $title
        $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
        $msg.Body = $body
        $msg.BodyEncoding = [System.Text.Encoding]::UTF8
        $msg.IsBodyHtml = $false
        # 需要扫码时把二维码图片作为附件带上：手机邮件里直接长按识别，
        # 不用再切浏览器/找链接（ntfy 在国内经常超时，邮件才是主通道）。
        if ($attachPath -and (Test-Path $attachPath))
        {
            try
            {
                # 两个参数的 ctor 在 PS 5.1 上会抛 NullReferenceException（2026-11-15 实测），
                # 改成单参数 ctor；先复制一份到 %TEMP%，避免 NapCat 正在写这个文件。
                $tmpAtt = Join-Path $env:TEMP ("qrcode-" + (Get-Date -Format "HHmmss") + ".png")
                Copy-Item -LiteralPath $attachPath -Destination $tmpAtt -Force
                $att = New-Object System.Net.Mail.Attachment($tmpAtt)
                $att.Name = "qrcode.png"
                $msg.Attachments.Add($att) | Out-Null
            }
            catch { Write-Log ("email attachment error: " + $_.Exception.Message) }
        }
        $client = New-Object System.Net.Mail.SmtpClient([string]$cfg.smtp, $port)
        $client.EnableSsl = $true
        $client.Timeout = 20000
        $client.Credentials = New-Object System.Net.NetworkCredential([string]$cfg.user, [string]$cfg.pass)
        $client.Send($msg)
        $client.Dispose(); $msg.Dispose()
        Write-Log "notify(email) sent: $title"
        return $true
    }
    catch { Write-Log ("notify(email) failed: " + $_.Exception.Message) ; return $false }
}

# ---------------- 备用通道 2：Webhook（企业微信/钉钉/飞书/Server酱/PushPlus） ----------------
function Send-WebhookNotification([string]$title, [string]$body)
{
    if (-not $NOTIFY_WEBHOOK) { return $false }
    try
    {
        $cfg  = $NOTIFY_WEBHOOK
        $type = "custom"
        if ($cfg.type) { $type = ([string]$cfg.type).ToLower() }
        $url  = [string]$cfg.url
        if (-not $url) { return $false }
        $text = "$title`n`n$body"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $jsonType = "application/json; charset=utf-8"
        switch ($type)
        {
            "wecom"     { $payload = @{ msgtype = "text"; text = @{ content = $text } } | ConvertTo-Json -Depth 5 -Compress }
            "dingtalk"  { $payload = @{ msgtype = "text"; text = @{ content = $text } } | ConvertTo-Json -Depth 5 -Compress }
            "feishu"    { $payload = @{ msg_type = "text"; content = @{ text = $text } } | ConvertTo-Json -Depth 5 -Compress }
            "serverchan"{
                $u = $url
                if ($u -notmatch '\?') { $u = $u.TrimEnd('/') + ".send?title=" + [uri]::EscapeDataString($title) + "&desp=" + [uri]::EscapeDataString($body) }
                Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 15 | Out-Null
                Write-Log "notify(webhook:serverchan) sent: $title"
                return $true
            }
            "pushplus"  {
                $payload = @{ token = [string]$cfg.token; title = $title; content = $body; template = "txt" } | ConvertTo-Json -Depth 5 -Compress
            }
            default     { $payload = $null }
        }
        if ($payload)
        {
            Invoke-RestMethod -Uri $url -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) `
                -ContentType $jsonType -TimeoutSec 15 | Out-Null
        }
        else
        {
            Invoke-RestMethod -Uri $url -Method Post -Body $bytes -ContentType "text/plain; charset=utf-8" -TimeoutSec 15 | Out-Null
        }
        Write-Log ("notify(webhook:" + $type + ") sent: " + $title)
        return $true
    }
    catch { Write-Log ("notify(webhook) failed: " + $_.Exception.Message) ; return $false }
}

# ---------------- ntfy 熔断 ----------------
function Test-NtfySuppressed([string]$Path = "")
{
    if (-not $Path) { $Path = $NTFY_DOWN_FILE }
    try
    {
        if (-not (Test-Path $Path)) { return $false }
        $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
        $until = [datetime]::ParseExact($raw, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        return ((Get-Date) -lt $until)
    }
    catch { return $false }
}

function Register-NtfyFailure([string]$Path = "")
{
    if (-not $Path) { $Path = $NTFY_DOWN_FILE }
    $script:NtfyFails++
    if ($script:NtfyFails -ge $NTFY_FAIL_MAX)
    {
        $until = (Get-Date).AddHours($NTFY_COOLDOWN_H)
        try
        {
            [IO.File]::WriteAllText($Path, $until.ToString('yyyy-MM-ddTHH:mm:ss'),
                (New-Object System.Text.UTF8Encoding($false)))
            Write-Log ("ntfy disabled until " + $until.ToString('HH:mm') + " (" + $script:NtfyFails + " consecutive failures)")
        }
        catch { }
    }
}

function Clear-NtfyFailure([string]$Path = "")
{
    if (-not $Path) { $Path = $NTFY_DOWN_FILE }
    $script:NtfyFails = 0
    if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Send-Notification([string]$key, [string]$title, [string]$body, [string]$priority = "default", [string]$attach = "")
{
    $now = Get-Date
    # 同一类事件 30 分钟内只推一次，避免熔断期刷屏
    if ($script:NotifyLast.ContainsKey($key) -and (($now - $script:NotifyLast[$key]).TotalMinutes -lt 30))
    {
        Write-Log ("notify(" + $key + ") suppressed (dedupe 30min)")
        return
    }
    $script:NotifyLast[$key] = $now

    if ($NOTIFY_NTFY -and $NOTIFY_NTFY_TOPIC -and (Test-NtfySuppressed))
    {
        Write-Log "notify(ntfy) skipped: circuit open (ntfy has been failing)"
    }
    elseif ($NOTIFY_NTFY -and $NOTIFY_NTFY_TOPIC)
    {
        try
        {
            # ---- 中文变「?」的根因（2026-11-12 实测） ----
            # Invoke-RestMethod 拿到的是 .NET String：它按 ContentType 里的 charset 编码请求体，
            # 没写 charset 时退回 ASCII（单字节），于是每个中文字符都变成 '?'，
            # 而且 Content-Length 恰好等于字符数（69 字节）—— 看上去"发出去了"，其实是问号。
            # 只写 ContentType "text/plain" 而漏掉 charset 也一样是 '?'（同样实测过）。
            # 正确做法：自己把正文编成 UTF-8 字节数组，并显式声明 charset=utf-8。
            $bytes  = [System.Text.Encoding]::UTF8.GetBytes($body)
            $header = @{
                Title    = (ConvertTo-NtfyHeaderText $title)   # HTTP 头只能是 ASCII，中文按 RFC 2047 编码
                Priority = $priority
                Tags     = "robot"
            }
            Invoke-RestMethod -Uri ("https://ntfy.sh/" + $NOTIFY_NTFY_TOPIC) -Method Post `
                -Body $bytes -ContentType "text/plain; charset=utf-8" -TimeoutSec $NTFY_TIMEOUT_SEC `
                -Headers $header | Out-Null
            Write-Log ("notify(ntfy) sent: " + $title)
            Clear-NtfyFailure
        }
        catch
        {
            Write-Log ("notify(ntfy) failed: " + $_.Exception.Message)
            Register-NtfyFailure
        }
    }
    # ntfy.sh 在国内经常超时（2026-11-13 实测 07:34 推送超时），所以兜底通道必须独立可用：
    # 邮件（smtp.qq.com:465 可用）/ 企业微信、钉钉、飞书 webhook 均实测可达。
    $null = Send-EmailNotification $title $body $attach
    $null = Send-WebhookNotification $title $body
    if ($NOTIFY_TOAST) { Show-Toast $title $body }
}

# ---------------- 最近一次真实收发时间（用来判断"空闲"） ----------------
function Get-NapCatLastActivity
{
    try
    {
        $f = Get-ChildItem -Path $NAP_LOG_DIR -Filter *.log -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { return $f.LastWriteTime }
    }
    catch { }
    # 没有日志目录（NapCat 关掉了 fileLog、或还没跑起来）时返回 MinValue。
    # 以前这里返回 Get-Date，等于宣称"刚刚还有收发"，空闲时间永远是 0，
    # 保活（健康探针）就再也不会发出去 —— 日志不存在恰恰是最需要探活的时候。
    return [DateTime]::MinValue
}

# ---------------- 会话起点（主动续期用） ----------------
# session-since.txt 只存一行 "yyyy-MM-ddTHH:mm:ss"（本地时间，无时区后缀）。
# guardian 自己重启（计划任务拉起、手动 -TestNotify 之外的重启）不应该把
# 会话时长清零：票据还是那张票据，续期时间点也不应该被推迟。
$script:SessionSince = [DateTime]::MinValue
function Set-SessionSince([DateTime]$t)
{
    $script:SessionSince = $t
    try
    {
        [IO.File]::WriteAllText($SESSION_FILE, $t.ToString("yyyy-MM-ddTHH:mm:ss"),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log ("session file write error: " + $_.Exception.Message) }
}
function Confirm-SessionSince
{
    if ($script:SessionSince -ne [DateTime]::MinValue) { return }
    $t = [DateTime]::MinValue
    if (Test-Path $SESSION_FILE)
    {
        try
        {
            $raw = (Get-Content $SESSION_FILE -Raw).Trim()
            $t = [DateTime]::ParseExact($raw, "yyyy-MM-ddTHH:mm:ss", $null)
        }
        catch { $t = [DateTime]::MinValue }
    }
    if ($t -eq [DateTime]::MinValue) { $t = Get-Date }
    $script:SessionSince = $t
}
function Get-SessionMinutes
{
    if ($script:SessionSince -eq [DateTime]::MinValue) { return -1 }
    return [int]((Get-Date) - $script:SessionSince).TotalMinutes
}

# 一页指标：网页/监控读这个文件就够了，不必去解析日志。
# kicksToday 只来自 kick.log（每次被踢一行），所以它统计的是"真实被踢"，
# 不包含假在线/网络抖动 —— 后者在日志里是另一类事件，混在一起会误导。
function Write-Metrics([datetime]$nextProbe)
{
    try
    {
        $today = (Get-Date).ToString("yyyy-MM-dd")
        $kicksToday = 0
        $lastKick = ""
        if (Test-Path $KICK_LOG)
        {
            foreach ($ln in (Get-Content $KICK_LOG -Tail 200 -ErrorAction SilentlyContinue))
            {
                if ($ln -match '^\[(\d{4}-\d{2}-\d{2})')
                {
                    if ($Matches[1] -eq $today) { $kicksToday++ }
                    if ($ln -match 'at=([0-9]{2}-[0-9]{2} [0-9:]+)') { $lastKick = $Matches[1] }
                }
            }
        }
        # 恢复信息要跨进程存活：守护每重启一次，$script:LastRecoverSec 就回到 -1，
        # 页面上的"上次恢复 N 秒"会凭空消失。这里从上一份 metrics.json 里继承。
        $prevRecoverSec = -1
        $prevRecoverAt = ""
        $prevCause = ""
        $prevPath = ""
        if (Test-Path $METRICS_FILE)
        {
            try
            {
                $prev = Get-Content $METRICS_FILE -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($prev -and $prev.lastRecoverSec -gt 0)
                {
                    $prevRecoverSec = [int]$prev.lastRecoverSec
                    $prevRecoverAt = [string]$prev.lastRecoverAt
                    $prevCause = [string]$prev.lastCause
                    $prevPath = [string]$prev.lastPath
                }
            }
            catch { }
        }
        $recoverSec = $script:LastRecoverSec
        $recoverAt = $script:LastRecoverAt
        $cause = $script:RecoveryCause
        $path = $script:RecoveryPath
        if ($recoverSec -lt 0 -and $prevRecoverSec -gt 0)
        {
            $recoverSec = $prevRecoverSec
            $recoverAt = $prevRecoverAt
            $cause = $prevCause
            $path = $prevPath
        }
        $obj = [ordered]@{
            at          = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
            state       = $script:LastState
            sessionMin  = (Get-SessionMinutes)
            kicksToday  = $kicksToday
            lastKick    = $lastKick
            nextProbeAt = $nextProbe.ToString("HH:mm")
            probeMin    = [int]($KEEPALIVE_MIN / 60)
            lastRecoverSec = $recoverSec
            lastRecoverAt  = $recoverAt
            lastCause   = $cause
            lastPath    = $path
            uin         = $QQ_UIN
        }
        [IO.File]::WriteAllText($METRICS_FILE, ($obj | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------- 下一次保活时间：重尾分布 ----------------
function Get-NextKeepAliveDelay
{
    # 2026-11-15：固定间隔。原来按 70/20/10 抽 20-40min / 1-2h / 3-6h 的重尾分布，
    # 真正的代价是"最长要等 6 小时才发现假在线"，而探针本身不花钱也不扰人。
    return $KEEPALIVE_MIN
}

# ---------------- 被踢事件记录（供后续统计"多久被踢一次"） ----------------
function Add-KickLog([string]$detail)
{
    # 自检模式下不往真实的 kick.log 里写假记录。
    if ($script:SelfTestMode) { return }
    try
    {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $detail
        Add-Content -Path $KICK_LOG -Value $line -Encoding UTF8
    }
    catch { }
}


$script:LastState = ""
$script:LastStateWrite = [DateTime]::MinValue
# 最近一次自动恢复耗时（被踢/掉线 -> 重新在线），写进 metrics.json 供看板与复盘用。
$script:LastRecoverSec = -1
$script:LastRecoverAt = ""
function Set-BotState([string]$state, [string]$note)
{
    $nowSt = Get-Date
    # 状态没变化时也要周期性刷新 at 时间戳（5 分钟），否则 qrsync 页面会把一个明明
    # 在线的机器人显示成「登录状态记录已过期（N 分钟前），可能已掉线」——2026-11-13
    # 实测就误报了 132 分钟，原因是只在状态变化时写文件。
    $fresh = (($nowSt - $script:LastStateWrite).TotalSeconds -lt 300)
    if ($script:LastState -eq $state -and $fresh) { return }
    $script:LastState = $state
    $script:LastStateWrite = $nowSt
    $obj = [ordered]@{
        state = $state
        note  = $note
        uin   = $QQ_UIN
        at    = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
    }
    try
    {
        $json = $obj | ConvertTo-Json -Compress
        $stDir = Split-Path $STATE_FILE -Parent
        if ($stDir -and -not (Test-Path $stDir)) { New-Item -ItemType Directory -Force -Path $stDir | Out-Null }
        $tmp  = "$STATE_FILE.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $STATE_FILE -Force
    }
    catch { Write-Log ("state file write error: " + $_.Exception.Message) }
}

# ---------------- WebUI auth (returns auth headers) ----------------
function Get-WebUIHeaders
{
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $raw = [System.Text.Encoding]::UTF8.GetBytes($WEBUI_TOK + ".napcat")
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($raw)).Replace("-","").ToLower()
    $body = @{ hash = $hash; totpCode = $null } | ConvertTo-Json
    $login = Invoke-RestMethod -Uri "$WEBUI_API/api/auth/login" -Method Post `
                -Body $body -ContentType "application/json" -TimeoutSec 15
    return @{ Authorization = "Bearer " + $login.data.Credential }
}

# ---------------- Is the WebUI reachable? ----------------
function Test-QuickLoginAvailable {
    try {
        $h = Get-WebUIHeaders
        $r = Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/GetQuickLoginList" -Method Post `
            -Headers $h -Body '{}' -ContentType 'application/json' -TimeoutSec 10
        $items = @($r.data | ForEach-Object { [string]$_ })
        $ok = $items -contains [string]$QQ_UIN
        Write-Log ("quick-login ticket probe: " + ($(if($ok){'available'}else{'missing'})) +
                   " (entries=" + $items.Count + ")")
        return $ok
    } catch {
        Write-Log ("quick-login ticket probe failed: " + $_.Exception.Message)
        return $false
    }
}
function Test-WebUI
{
    try { $null = Get-WebUIHeaders; return $true }
    catch { return $false }
}

# ---------------- Login status (isLogin + loginError) ----------------
function Get-LoginStatus
{
    try
    {
        $h = Get-WebUIHeaders
        $s = Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/CheckLoginStatus" -Method Post `
                -Headers $h -TimeoutSec 10
        return @{ login = [bool]$s.data.isLogin; err = [string]$s.data.loginError; qr = [string]$s.data.qrcodeurl }
    }
    catch { return $null }
}

# ---------------- Check online via HTTP 3000 ----------------
# Returns: $true / $false / $null (no response - worker likely dead)
function Get-Online
{
    try
    {
        $r = Invoke-RestMethod -Uri "$HTTP_API/get_status" -Method Post `
                -Body '{}' -ContentType "application/json" -TimeoutSec 10
        if ($null -eq $r -or $null -eq $r.data) { return $false }
        return [bool]$r.data.online
    }
    catch
    {
        # 2026-11-15：以前这里 return $null，日志里就写成 "online="（后面空白），
        # 分不清是"探不到状态"还是"状态就是 false"。统一返回 $false，
        # 探不到和掉线在决策上本来就等价（都要进入恢复流程）。
        return $false
    }
}

# ---------------- 谁才是"我们的" QQ ----------------
# 桌面 QQ 与机器人的 QQ 是同一个 exe、同一份用户数据目录，同时开必然互挤。
# 所以要能区分 NapCatWinBootMain.exe 拉起来的 QQ 和用户手动打开的 QQ：
# 只看 exe 名字会把用户的 QQ 一起杀掉（这正是"两个进程一起被杀"的来源）。
function Get-NapCatOwnedPids
{
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe' OR Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    # A process name is not an ownership proof.  A normal desktop QQ.exe can
    # coexist with NapCat, so only trust launcher processes whose executable
    # path or command line points into the configured NapCat installation.
    $napcatRoot = ([IO.Path]::GetFullPath($NAPCAT_DIR)).TrimEnd('\') + '\'
    $homeRoot = ([IO.Path]::GetFullPath($NAPCAT_HOME)).TrimEnd('\') + '\'
    $trustedBoots = @($procs | Where-Object {
        if ($_.Name -ne 'NapCatWinBootMain.exe') { return $false }
        $exe = [string]$_.ExecutablePath
        $cmd = [string]$_.CommandLine
        ($exe -and $exe.StartsWith($napcatRoot, [StringComparison]::OrdinalIgnoreCase)) -or
            ($cmd -and ($cmd.IndexOf($napcatRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $cmd.IndexOf($homeRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0))
    })
    if ($trustedBoots.Count -eq 0) {
        if (@($procs | Where-Object { $_.Name -eq 'NapCatWinBootMain.exe' }).Count -gt 0) {
            Write-Log 'NapCat launcher found but rejected by installation-path filter; no NapCat process will be stopped.' 'Yellow'
        }
        return @()
    }

    $byParent = @{}
    foreach ($p in $procs)
    {
        $pp = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = New-Object System.Collections.ArrayList }
        [void]$byParent[$pp].Add([int]$p.ProcessId)
    }

    $owned = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    foreach ($b in $trustedBoots)
    {
        $bid = [int]$b.ProcessId
        if (-not $owned.Contains($bid)) { [void]$owned.Add($bid); $stack.Push($bid) }
    }
    while ($stack.Count -gt 0)
    {
        $cur = $stack.Pop()
        if ($byParent.ContainsKey($cur))
        {
            foreach ($c in $byParent[$cur])
            {
                if (-not $owned.Contains($c)) { [void]$owned.Add($c); $stack.Push($c) }
            }
        }
    }
    return @($owned)
}

# 返回"用户自己开的 QQ" pid 列表；没有则返回 $null
function Test-ForeignQq
{
    $qq = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction SilentlyContinue |
                ForEach-Object { [int]$_.ProcessId })
    if ($qq.Count -eq 0) { return $null }
    $owned = @(Get-NapCatOwnedPids)
    $foreign = @($qq | Where-Object { $owned -notcontains $_ })
    if ($foreign.Count -eq 0) { return $null }
    return $foreign
}

# 只杀 NapCat 自己拉起来的那棵树，绝不碰用户手动开的 QQ
function Stop-NapCatOwned
{
    $owned = @(Get-NapCatOwnedPids)
    if ($owned.Count -eq 0) { return }

    $boots = @(Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue |
                  ForEach-Object { [int]$_.ProcessId })
    $qqOwned = @($owned | Where-Object { $boots -notcontains $_ })
    $bootOwned = @($owned | Where-Object { $boots -contains $_ })

    foreach ($id in $qqOwned)
    {
        try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 800
    foreach ($id in $bootOwned)
    {
        try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {}
    }
    Write-Log ("  stopped NapCat-owned pids: " + ($owned -join ","))
}

# ---------------- 发送失败探测：读 NapCat 自己的日志 ----------------
# 用增量读取（记住文件偏移），避免每轮都从头扫一遍几十 KB 的日志。
$script:NapLogPath  = $null
$script:NapLogPos   = 0
$script:NapLogPrevWrite = $null
$script:NapLastLineTs = $null   # 最后一行日志自带的时间戳（算"被踢前安静多久"用）
$script:SendFailAts = New-Object System.Collections.ArrayList
$script:NtfyFails   = 0
# 单调递增计数：确认探针用它判断"这次探测有没有产生新的失败行"，
# 比数 ArrayList 长度可靠（窗口裁剪会改变长度）。
$script:SendFailSeq = 0

function Read-NewNapCatLog
{
    if (-not (Test-Path $NAP_LOG_DIR)) { return }
    $f = Get-ChildItem $NAP_LOG_DIR -Filter *.log -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return }

    if ($script:NapLogPath -ne $f.FullName)
    {
        # 第一次看到这个日志文件（guardian 刚起来 / 日志轮转成新名字）：
        # 直接把读指针放到文件末尾。以前这里是 0，于是启动后第一轮就把整份历史
        # 日志重读一遍，里面几天前的"网络连接异常"被当成刚刚发生，
        # 立刻凑够 2 条触发一次假的 connection reset，还往 kick.log 里写假记录。
        $script:NapLogPath      = $f.FullName
        $script:NapLogPos       = $f.Length
        $script:NapLogPrevWrite = $f.LastWriteTime
        return
    }
    if ($f.Length -lt $script:NapLogPos)
    {
        # 文件变短了 = 被截断/删除重建（NapCat 重启时会重开日志）。
        # 以前的写法直接 return，从此这个文件长度永远 <= 记住的偏移量，
        # 等于永久失明，发送失败探测彻底失效。这里重置为从头读新内容。
        $script:NapLogPos       = 0
        $script:NapLogPrevWrite = $null
    }
    if ($f.Length -eq $script:NapLogPos) { return }

    $txt = $null
    try
    {
        $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try
        {
            [void]$fs.Seek($script:NapLogPos, [IO.SeekOrigin]::Begin)
            $len = [int]($fs.Length - $script:NapLogPos)
            $buf = New-Object byte[] $len
            $read = $fs.Read($buf, 0, $len)
            $script:NapLogPos = $fs.Position
            $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        finally { $fs.Dispose() }
    }
    catch { return }

    if (-not $txt) { return }
    $now = Get-Date
    # 本次新增内容之前，日志静了多久（用于分析"被踢前安静了多长时间"）
    $gapMin = $null
    if ($script:NapLogPrevWrite) { $gapMin = [int]($f.LastWriteTime - $script:NapLogPrevWrite).TotalMinutes }
    $script:NapLogPrevWrite = $f.LastWriteTime
    foreach ($line in ($txt -split "`n"))
    {
        # 2026-11-15：解析行首时间戳 "MM-DD HH:mm:ss"（NapCat 日志格式），
        # 用来算"被踢前真正安静了多久"。旧算法用文件 mtime 差，日志换文件 /
        # 缓冲刷新都会失真（实测 09:37 的被踢被记成 quiet 122min，实际只静了 23min）。
        $lineTs = $null
        if ($line -match '^\s*(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})')
        {
            try
            {
                $lineTs = New-Object DateTime($now.Year, [int]$Matches[1], [int]$Matches[2],
                                              [int]$Matches[3], [int]$Matches[4], [int]$Matches[5])
                # 跨年：12-31 之后读到 01-01 会算出"未来"，往前退一年
                if ($lineTs -gt $now.AddMinutes(1)) { $lineTs = $lineTs.AddYears(-1) }
            }
            catch { $lineTs = $null }
        }
        if ($line -match '网络连接异常|EventChecker Failed')
        {
            [void]$script:SendFailAts.Add($now)
            $script:SendFailSeq++
        }
        if ($line -match 'KickedOffLine|下线通知')
        {
            if ($null -ne $lineTs -and $null -ne $script:NapLastLineTs)
            {
                $gapTxt = "$([int](($lineTs - $script:NapLastLineTs).TotalMinutes)) min"
            }
            elseif ($null -ne $gapMin) { $gapTxt = "$gapMin min (file-level)" }
            else { $gapTxt = "unknown" }
            $kickAt = if ($lineTs) { $lineTs.ToString("MM-dd HH:mm:ss") } else { "unknown" }
            # 取证三件套：这张票据活了多久 / 被踢前静了多久 / 当时出口 IP。
            # 有了 session= 这一列，才能验证"约 2 小时 TTL"这个假设成立与否。
            $sessTxt = "unknown"
            $sm = Get-SessionMinutes
            if ($sm -ge 0) { $sessTxt = "$sm min" }
            $ipTxt = "unknown"
            try
            {
                # 取"默认路由所在网卡"的地址：Get-NetIPAddress 的第一条经常是 Radmin/VPN 的虚拟网卡，
                # 2026-11-15 14:28 那次被踢就记成了 26.15.34.205（Radmin），对排查毫无帮助。
                $cands = @()
                foreach ($r in (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                                Sort-Object RouteMetric, ifMetric))
                {
                    $a = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $r.ifIndex -ErrorAction SilentlyContinue |
                         Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" } |
                         Select-Object -First 1
                    if ($a) { $cands += [string]$a.IPAddress }
                }
                if (-not $cands) {
                    $cands = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                             Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" } |
                             ForEach-Object { [string]$_.IPAddress }
                }
                if ($cands) { $ipTxt = $cands[0] }
            }
            catch { }
            Add-KickLog ("KICKED | at=" + $kickAt + " | log=" + $f.Name + " | session=" + $sessTxt +
                         " | quiet_before_kick=" + $gapTxt + " | ip=" + $ipTxt)
            Write-Log ("kick detected in NapCat log (session " + $sessTxt + ", quiet before kick: " + $gapTxt + ")")
            $script:KickSeen = $true
            Invoke-IncidentSnapshot "kick"
        }
        if ($null -ne $lineTs) { $script:NapLastLineTs = $lineTs }
    }
}

# 窗口内"发送失败"次数达到阈值 = 长连接已经死了（哪怕 online 还是 true）
function Test-SendBroken
{
    $now = Get-Date
    $alive = @($script:SendFailAts | Where-Object { ($now - $_).TotalSeconds -le $SENDFAIL_WINDOW })
    $script:SendFailAts.Clear()
    foreach ($t in $alive) { [void]$script:SendFailAts.Add($t) }
    return ($alive.Count -ge $SENDFAIL_THRESHOLD)
}

# 命中"发送失败"后先复核：给机器人自己发一条探针消息，若 5 秒内日志里又出现
# 一条"网络连接异常" → 说明长连接真死了；若没有 → 视为偶发抖动，不动 NapCat。
function Confirm-SendBroken
{
    $seqBefore = $script:SendFailSeq
    $resp = $null
    try
    {
        $probe = "{0}  link probe" -f (Get-Date -Format "HH:mm")
        $body  = @{ user_id = $QQ_UIN; message = $probe } | ConvertTo-Json
        $resp  = Invoke-RestMethod -Uri "$HTTP_API/send_private_msg" -Method Post `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -ContentType "application/json; charset=utf-8" -TimeoutSec 10
    }
    catch
    {
        # API 本身都发不出去，基本可以确定连接已死
        Write-Log ("  probe failed to dispatch: " + $_.Exception.Message)
        return $true
    }

    # 2026-11-13 实测：长连接已死（"假在线"）时，OneBot 仍然 HTTP 200、
    # retcode 200，但响应体是 status="failed"，message 里带
    # "EventChecker Failed ... {\"result\": 1006514, \"errMsg\": \"网络连接异常!\"}"。
    # 原来的做法是等 5 秒看日志增量，探针的失败行稍晚落盘就会被误判成"偶发"
    # （17:27:17 那次就是这么漏掉的）。直接读响应 status 才是确定判据。
    $probeStatus  = [string]$resp.status
    $probeMessage = [string]$resp.message
    if ($probeStatus -and $probeStatus -ne "ok")
    {
        Write-Log ("  probe rejected by kernel: status=" + $probeStatus +
                   " msg=" + ($probeMessage -replace "\s+", " "))
        return $true
    }
    if (-not $probeStatus)
    {
        # 响应里没有 status 字段（老版本/异常返回）时才回退到日志增量判断
        Start-Sleep -Seconds 5
        Read-NewNapCatLog
        return ($script:SendFailSeq -gt $seqBefore)
    }
    return $false
}

# 连接复活：只重启 worker（不杀 QQ、不重新注入），走缓存 token 免扫码
function Invoke-ConnectionReset
{
    $script:RecoveryCause = "sendfail"; $script:RecoveryPath = "worker"
    Write-Log ("send-fail detected (" + $script:SendFailAts.Count + " in " + [int]($SENDFAIL_WINDOW/60) +
               "min) - restarting worker only, cached token should log in without a scan ...")
    try
    {
        $h = Get-WebUIHeaders
        Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RestartNapCat" -Method Post `
            -Headers $h -TimeoutSec 20 | Out-Null
    }
    catch { Write-Log ("  restart call error: " + $_.Exception.Message) }

    return (Wait-Login $WORKER_WAIT_SEC)
}

# 等登录恢复：返回 $true 表示已登录，$false 表示超时/需要扫码
function Wait-Login
{
    param([int]$Seconds)
    $waited = 0
    $lastQuick = 0
    while ($waited -lt $Seconds)
    {
        Start-Sleep -Seconds 15
        $waited += 15
        Write-Heartbeat
        $online = Get-Online
        if ($online) { return $true }
        $ls = Get-LoginStatus
        if ($ls -and $ls.login) { return $true }
        # 中途补一次快速登录：NapCat 有时要等 worker 完全就绪才认缓存票
        if ($waited - $lastQuick -ge $QUICK_RETRY_SEC)
        {
            $lastQuick = $waited
            try
            {
                $h = Get-WebUIHeaders
                Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/SetQuickLogin" -Method Post `
                    -Headers $h -Body ("{`"uin`":`"" + $QQ_UIN + "`"}") -ContentType "application/json" `
                    -TimeoutSec 30 | Out-Null
                Write-Log ("  retried quick login at +" + $waited + "s")
            }
            catch { Write-Log ("  quick login call error: " + $_.Exception.Message) }
        }
    }
    return $false
}

# ---------------- 无窗口启动：不产生任何可见控制台窗口 ----------------
# 用 Start-Process -WindowStyle Minimized 会留下一个可见的 cmd 窗口，
# 关掉它就会连带把 NapCat / AstrBot 一起杀掉。CreateNoWindow 才是真正的
# "没有窗口"：进程连控制台都不分配。
# 掉线现场快照：把六份状态文件与四路日志尾部抓进 incidents\<时间戳>\。
# 只在"确认被踢"时触发，且 10 分钟限频；用独立进程跑，绝不让取证拖慢主循环。
function Invoke-IncidentSnapshot([string]$reason)
{
    try
    {
        if (-not $SNAPSHOT_SCRIPT -or -not (Test-Path $SNAPSHOT_SCRIPT))
        {
            Write-Log "incident snapshot skipped: script not found ($SNAPSHOT_SCRIPT)"
            return
        }
        $now = Get-Date
        if ($script:LastSnapshot -ne [DateTime]::MinValue -and ($now - $script:LastSnapshot).TotalMinutes -lt $SNAPSHOT_MIN_GAP_MIN)
        {
            Write-Log ("incident snapshot skipped: last one " + [int]($now - $script:LastSnapshot).TotalMinutes + " min ago")
            return
        }
        $script:LastSnapshot = $now
        $snapArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$SNAPSHOT_SCRIPT`" -Root `"$NAPCAT_HOME`""
        $null = Start-Hidden "powershell.exe" $snapArgs $NAPCAT_HOME
        Write-Log ("incident snapshot started (" + $reason + "): " + $SNAPSHOT_SCRIPT)
    }
    catch
    {
        Write-Log ("incident snapshot failed: " + $_.Exception.Message)
    }
}

function Start-Hidden
{
    param(
        [string]$FileName,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$ExtraPath,
        [hashtable]$Env
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $FileName
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WindowStyle     = 'Hidden'
    if ($ExtraPath)
    {
        $psi.EnvironmentVariables["PATH"] = [string]$psi.EnvironmentVariables["PATH"] + ";" + $ExtraPath
    }
    if ($Env)
    {
        foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    }
    try
    {
        return [System.Diagnostics.Process]::Start($psi)
    }
    catch
    {
        Write-Log ("hidden start failed (" + $FileName + "): " + $_.Exception.Message)
        return $null
    }
}

# ---------------- Launch NapCat (used when it is not running) ----------------
# Returns: "online" / "need_scan" / "timeout"
function Launch-NapCat
{
    $foreign = Test-ForeignQq
    if ($foreign)
    {
        # 用户自己开着 QQ 时，绝对不 taskkill /im QQ.exe：那会把大号一起杀掉。
        Write-Log ("desktop QQ is running (pid " + ($foreign -join ",") + ") - leaving it alone")
    }
    $owned = @(Get-NapCatOwnedPids)
    if ($owned.Count -gt 0)
    {
        Write-Log "  killing NapCat-owned QQ tree before launch ..."
        Stop-NapCatOwned
        Start-Sleep -Seconds 6
    }

    Write-Log "  starting NapCat launcher (hidden, no console window) ..."
    # 不经过可见的 cmd 窗口：任务本身以 Highest 运行，launcher.bat 里的
    # net session 提权分支不会命中，也不需要弹 Windows Terminal。
    $envMap = $null
    if ($QQ_DATA_DIR)
    {
        # NAPCAT_WORKDIR 让 config/logs/cache 继续留在 NapCat 目录，
        # NAPCAT_QQ_DATA_DIR 让 QQ 账号数据另存一份 —— 与桌面 QQ 彻底分开。
        $envMap = @{
            NAPCAT_WORKDIR     = $NAPCAT_DIR
            NAPCAT_QQ_DATA_DIR = $QQ_DATA_DIR
        }
        Write-Log ("  QQ data dir isolated: " + $QQ_DATA_DIR)
    }
    $null = Start-Hidden "cmd.exe" ("/c launcher.bat " + $QQ_UIN) $NAPCAT_DIR $null $envMap

    # 1) Wait for WebUI (6099) to come up (up to ~120s).
    $webuiUp = $false
    for ($i = 0; $i -lt 8; $i++)
    {
        Start-Sleep -Seconds 15
        Write-Heartbeat
        if (Test-WebUI) { $webuiUp = $true; break }
    }
    if (-not $webuiUp)
    {
        Write-Log "  WebUI did not start in time."
        return "timeout"
    }
    Write-Log "  WebUI is up, waiting for login ..."

    # 2) Wait for login with the extended window: cached-token login can take
    #    minutes on a cold start, and giving up early forces an unnecessary scan.
    $waited = 0
    $lastQuick = 0
    $earlyNotified = $false
    while ($waited -lt $LOGIN_WAIT_SEC)
    {
        Start-Sleep -Seconds 15
        $waited += 15
        Write-Heartbeat
        $ls = Get-LoginStatus
        if ($ls -and $ls.login) { Write-Log "  logged in."; return "online" }
        if ($ls -and $ls.err -match "失效|重新登录|expired|过期")
        {
            Write-Log ("  session expired: " + $ls.err)
            return "need_scan"
        }
        # 被踢之后票据大概率已经作废：只要二维码已经在刷新，就没必要让人干等完整的
        # 8 分钟登录窗口才收到通知——120 秒还登不上就先把码推给用户，同时继续等缓存票。
        if (-not $earlyNotified -and $script:KickSeen -and $waited -ge 120)
        {
            $qrFresh = $false
            try
            {
                if (Test-Path $QR_FILE)
                {
                    $ageSecQr = ((Get-Date) - (Get-Item $QR_FILE).LastWriteTime).TotalSeconds
                    $qrFresh = ($ageSecQr -lt 300)
                }
            }
            catch { }
            if ($qrFresh)
            {
                $earlyNotified = $true
                Write-Log "  early needs-scan notice: QR is fresh, but the cached ticket has not logged in yet."
                $nb = "机器人 QQ $QQ_UIN 被踢后 120 秒内没能用缓存票据登回，可能很快需要扫码。`n"
                if ($QR_PAGE_URL) { $nb += "扫码页（自动换码）: $QR_PAGE_URL`n" }
                $nb += "如果稍后自动登回，会再收到一条 recovered 通知。"
                Send-Notification "need_scan" "NapCat bot may need a QR scan" $nb "default" $QR_FILE
            }
        }
        if ($waited - $lastQuick -ge $QUICK_RETRY_SEC)
        {
            $lastQuick = $waited
            try
            {
                $h = Get-WebUIHeaders
                Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/SetQuickLogin" -Method Post `
                    -Headers $h -Body ("{`"uin`":`"" + $QQ_UIN + "`"}") -ContentType "application/json" `
                    -TimeoutSec 30 | Out-Null
                Write-Log ("  retried quick login at +" + $waited + "s")
            }
            catch { Write-Log ("  quick login call error: " + $_.Exception.Message) }
        }
    }
    Write-Log "  login did not complete in time."
    # 登录窗口用完却没报"登录态失效" = 客户端停在二维码页等人扫
    # （NapCat 只有需要扫码时才出新码）。以前这里返回 "timeout"，
    # 主循环当成失败、下一轮又走一遍恢复，把用户正在扫的那张码冲掉。
    $qrFresh = $false
    if (Test-Path $QR_FILE)
    {
        $qrFresh = ((Get-Date) - (Get-Item $QR_FILE).LastWriteTime).TotalMinutes -lt 10
    }
    if ($qrFresh)
    {
        Write-Log "  a fresh QR code is waiting - asking the user to scan instead of restarting."
        Notify-Admin
        return "need_scan"
    }
    return "timeout"
}

# ---------------- Recovery: choose the right path ----------------
# Returns $true if back online, $false if a manual QR scan is required.
function Test-QrModeWaiting([int]$QrAgeSec, $LoginStatus)
{
    # "NapCat 正停在登录页等人扫码"的纯判定：码还在刷新 + 没登录 + 没有登录错误。
    # 抽成函数是为了能在 -SelfTest 里跑（Do-Recovery 本身会重启进程，不能直接测）。
    if ($null -eq $LoginStatus) { return $false }
    if ($LoginStatus.login) { return $false }
    if ($LoginStatus.err) { return $false }
    return ($QrAgeSec -ge 0 -and $QrAgeSec -lt 180)
}
function Do-Recovery
{
    $webUiUp = Test-WebUI
    $script:RecoveryCause = ""
    $script:RecoveryPath = ""

    # ---- Case 0: 已经有一张新码在等人扫 ----
    # NapCat 只在"需要扫码"时才生成新码，所以 10 分钟内的码 = 用户正看着的那张。
    # 这时再走恢复流程（重启 worker / 全量重启）只会把码冲掉、让用户白扫一次。
    if (Test-Path $QR_FILE)
    {
        $qrAgeSec = [int]((Get-Date) - (Get-Item $QR_FILE).LastWriteTime).TotalSeconds
        $lsq = Get-LoginStatus
        # 判据是"码还在刷新"，不是"码有多新"：
        # NapCat 停在登录页时会每 ~2 分钟重写一次 qrcode.png，只要 mtime 还很新，
        # 就说明它正在等人扫；此时重启 worker / 全量重启只会把码冲掉，让用户白扫一次。
        # （旧判据用"10 分钟内"，用户离开 12 分钟回来扫码就会失配。）
        if (Test-QrModeWaiting $qrAgeSec $lsq)
        {
            $script:RecoveryCause = "qr_wait"; $script:RecoveryPath = "wait_scan"
            if ($script:QrModeSince -eq [DateTime]::MinValue) { $script:QrModeSince = Get-Date }
            $qrModeMin = [int]((Get-Date) - $script:QrModeSince).TotalMinutes
            if ($qrModeMin -lt $QR_MODE_MAX_MIN)
            {
                Write-Log ("QR mode: code refreshed " + $qrAgeSec + "s ago (" + $qrModeMin + " min waiting) - waiting for a scan, not restarting.")
                if (Wait-Scan) { return "online" }
                return "need_scan"
            }
            Write-Log ("QR mode has lasted " + $qrModeMin + " min without a scan - login page may be stuck; one full relaunch.")
        }
    }
    else { $script:QrModeSince = [DateTime]::MinValue }
    # ---- Case 1: WebUI unreachable -> NapCat is NOT running at all
    # (typical right after boot / after a crash). Launch it immediately;
    # waiting through the grace period here would waste minutes.
    if (-not $webUiUp)
    {
        # 桌面 QQ 正开着：同一个 exe、同一份用户数据目录，此时拉机器人必然互踢。
        # 先让用户的 QQ 用着，关掉后自动恢复；超过上限才强行抢回。
        $foreign = Test-ForeignQq
        if ($foreign)
        {
            if ($script:ForeignSince -eq [DateTime]::MinValue)
            {
                $script:ForeignSince = Get-Date
            }
            $mins = [int]((Get-Date) - $script:ForeignSince).TotalMinutes
            if ($mins -lt $FOREIGN_WAIT_MIN)
            {
                Write-Log ("desktop QQ is running (pid " + ($foreign -join ",") + ") - deferring relaunch (" +
                           $mins + "/" + $FOREIGN_WAIT_MIN + " min); bot resumes after that QQ closes")
                return "deferred"
            }
            Write-Log ("desktop QQ still running after " + $mins + " min - relaunching the bot anyway")
        }
        $script:ForeignSince = [DateTime]::MinValue

        $script:RecoveryCause = "webui_down"; $script:RecoveryPath = "launch"
        Write-Log "NapCat not running (WebUI unreachable), launching directly ..."
        $r = Launch-NapCat
        if ($r -eq "online") { Write-Log "  launch succeeded."; return "online" }
        if ($r -eq "need_scan") { Notify-Admin; return "need_scan" }
        return "failed"
    }

    # ---- 被踢（[KickedOffLine]）：必须排在"僵尸态"判断之前
    # 踢线时 loginError 同样含"失效"，若先走 Case 2，就会先白做一次 worker 重启
    # （2026-11-15 实测：RestartNapCat 不复用票据，仍停在二维码上，只能再全量重启）。
    if ($script:KickSeen)
    {
        $script:RecoveryCause = "kick"; $script:RecoveryPath = "fast"
        Write-Log "Phase A/B/C skipped: [KickedOffLine] - ticket revoked; only a full relaunch can reuse the cached token."
        Write-Log "Phase D: full relaunch ..."
        $rk = Launch-NapCat
        # 清标记必须放在 Launch-NapCat 之后：它内部的登录等待会用 $script:KickSeen
        # 决定是否在 +120 秒先推一条"可能要扫码"的通知。提前清掉，这条通知永远不发。
        $script:KickSeen = $false
        if ($rk -eq "online") { Write-Log "  full relaunch succeeded."; return "online" }
        if ($rk -eq "need_scan") { Write-Log "  session expired after relaunch."; Notify-Admin; return "need_scan" }
        return "failed"
    }
    # ---- Case 2: WebUI is up (NapCat started) but the bot is not really usable.
    # 关键场景：isLogin=true 但 loginError 非空 = 登录态已失效的"僵尸态"，
    # 它仍然自报 online=true，所以只看 Get-Online 永远发现不了。
    $ls = Get-LoginStatus
    if ($ls -and $ls.err -match "失效|重新登录|expired|过期")
    {
        $script:RecoveryCause = "zombie"; $script:RecoveryPath = "worker_restart"
        Write-Log ("login session invalid: " + $ls.err + "  (isLogin=" + $ls.login + ")")
        # 先原地重启 worker：能清掉失效会话并重新生成二维码，
        # 如果缓存 token 还有效，worker 起来就自己登录回去了。
        Write-Log "Phase C: restart worker (RestartNapCat) to clear the invalid session ..."
        try
        {
            $h = Get-WebUIHeaders
            Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RestartNapCat" -Method Post `
                -Headers $h -TimeoutSec 20 | Out-Null
        }
        catch { Write-Log ("  restart call error: " + $_.Exception.Message) }

        if (Wait-Login $WORKER_WAIT_SEC)
        {
            Write-Log "  session restored after worker restart."
            Set-BotState "online" "已登录"
            return "online"
        }

        # token 已彻底失效，只能人工扫码
        if (Wait-Scan) { return "online" }
        return "need_scan"
    }

    # ---- Case 3: NapCat is up, not logged in, and this was not a kick.
    # Phase A: grace period first (wait for self-heal, do NOT kill).
        if (-not $script:RecoveryCause) { $script:RecoveryCause = "offline"; $script:RecoveryPath = "staged" }
        Write-Log "Phase A: grace period, waiting for network self-heal (up to 90s) ..."
        for ($i = 0; $i -lt 6; $i++)
        {
            Start-Sleep -Seconds 15
            Write-Heartbeat
            $o = Get-Online
            if ($o) { Write-Log "  self-healed during grace period."; return "online" }
        }

    # Phase B: in-process quick login (lightweight, no restart).
    Write-Log "Phase B: in-process quick login (2 tries) ..."
    for ($i = 0; $i -lt 2; $i++)
    {
        try
        {
            $h = Get-WebUIHeaders
            Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/SetQuickLogin" -Method Post `
                -Headers $h -Body ("{`"uin`":`"" + $QQ_UIN + "`"}") -ContentType "application/json" `
                -TimeoutSec 30 | Out-Null
        }
        catch { Write-Log ("  quick login call error: " + $_.Exception.Message) }
        Start-Sleep -Seconds 15
        Write-Heartbeat
        $o = Get-Online
        if ($o) { Write-Log "  quick login succeeded."; return "online" }
    }

    # Phase C: restart the worker (restarts NapCat, does NOT kill QQ).
    Write-Log "Phase C: restart worker (RestartNapCat) ..."
    try
    {
        $h = Get-WebUIHeaders
        Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RestartNapCat" -Method Post `
            -Headers $h -TimeoutSec 20 | Out-Null
    }
    catch { Write-Log ("  restart call error: " + $_.Exception.Message) }
    if (Wait-Login $WORKER_WAIT_SEC) { Write-Log "  worker restart succeeded."; return "online" }

    # Phase D: last resort - full relaunch.
    Write-Log "Phase D: full relaunch ..."
    $r = Launch-NapCat
    if ($r -eq "online") { Write-Log "  full relaunch succeeded."; return "online" }
    if ($r -eq "need_scan") { Write-Log "  session expired after relaunch."; Notify-Admin; return "need_scan" }
    return "failed"
}
# ---------------- Notify admin (manual QR scan needed) ----------------
function Notify-Admin
{
    Write-Log "AUTO LOGIN FAILED - manual QR scan required"
    Set-BotState "need_scan" "登录态失效，等待扫码"
    # refresh QR code so the saved picture is the latest
    try
    {
        $h = Get-WebUIHeaders
        Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RefreshQRcode" -Method Post `
            -Headers $h -TimeoutSec 15 | Out-Null
    } catch {}
    # 通知：ntfy.sh 推送（手机收到就能点开扫码）+ 本机 toast。
    # msg.exe 只在专业/企业版的终端服务里存在，家庭版没有，所以降级为"顺带试一下"。
    $body = "机器人 QQ $QQ_UIN 离线，自动登录失败，需要扫码。`n"
    if ($QR_PAGE_URL) { $body += "扫码页（自动换码）: $QR_PAGE_URL`n" }
    $body += "本机图片: $NAPCAT_DIR\cache\qrcode.png"
    # 邮件附件走同一个调用：既避免"两条邮件重复"，也保证被 30 分钟去重时不会只丢掉其中一封。
    Send-Notification "need_scan" "NapCat bot needs QR scan" $body "high" $QR_FILE
    try { msg.exe * $body } catch {}
}

# ---------------- 等人扫码：盯着登录状态，扫上就恢复 ----------------
# NapCat 在等待扫码时会每 2 分钟自动换一张新码，所以这里不需要自己刷新。
function Wait-Scan
{
    Notify-Admin
    for ($i = 0; $i -lt 40; $i++)     # 最多盯 10 分钟
    {
        Start-Sleep -Seconds 15
        Write-Heartbeat
        $qrAge = 9999
        if (Test-Path $QR_FILE) { $qrAge = ((Get-Date) - (Get-Item $QR_FILE).LastWriteTime).TotalSeconds }
        $ls = Get-LoginStatus
        if ($ls -and $ls.login -and -not $ls.err)
        {
            Write-Log "QR scanned - bot is back online."
            Set-BotState "online" "已登录"
            return $true
        }
        if ($i % 4 -eq 0)
        {
            Write-Log ("  waiting for scan ... (QR age " + [int]$qrAge + "s)")
        }
    }
    Write-Log "still not scanned after 10 min; will retry on next watchdog round."
    return $false
}

# ---------------- AstrBot 为什么不在这里起 ----------------
# 这个文件曾经有个 Ensure-AstrBot()，但从来没被调用过（AstrBot 由用户级
# astrbot_watchdog.ps1 负责拉起，见下面主流程里的注释）。它里面还硬编码了
# "C:\Users\<用户名>\...\pythonw.exe" 这种本机路径，既误导读者又泄露隐私，已删除。
# 如果你想把 AstrBot 也交给 guardian 管，请用 $NAPCAT_HOME 派生路径并加上权限考量，
# 不要用 Highest 权限去跑带"电脑操控"插件的东西。
# ---------------- Keep-alive: send one message to self ----------------
function Send-KeepAlive
{
    try
    {
        $text = $KA_POOL | Get-Random
        $msg = "{0}  {1}" -f (Get-Date -Format "HH:mm"), $text
        $body = @{ user_id = $QQ_UIN; message = $msg } | ConvertTo-Json
        # 同样的 UTF-8 陷阱：字符串 body + ContentType 不带 charset 会被按 ASCII 编码。
        # 现在正文是纯 ASCII 看不出问题，但改一个字就会变成 '?'，一起修掉。
        $r = Invoke-RestMethod -Uri "$HTTP_API/send_private_msg" -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        # 失败判据要同时看 retcode 和 status：假在线（1006514）时 HTTP 仍是 200，
        # 响应体里 retcode=200、status="failed"。旧代码只判断 retcode -eq 0，失败时
        # 仅打一条日志、不计入 SendFailAts，只能等 Read-NewNapCatLog 去读异步落盘的
        # winston 日志，实测 18:48 失败拖到 19:10 才发现（延迟 22 分钟）。
        # 此刻拿到响应就已能确定成败，直接计入，让同一轮的 Test-SendBroken 立刻命中。
        $kaStatus = [string]$r.status
        $kaFailed = ($r.retcode -ne 0) -or ($kaStatus -and $kaStatus -ne "ok")
        if (-not $kaFailed)
        {
            $sessKA = Get-SessionMinutes
            $sessTxt = if ($sessKA -ge 0) { " (session " + $sessKA + "m)" } else { "" }
            Write-Log ("keep-alive sent: " + $msg + $sessTxt)
        }
        else
        {
            # 同步确定假在线：计入发送失败时间戳与单调计数。
            # 进入分支后 Confirm-SendBroken 会再发一条探针复核，单次抖动不会误重启。
            [void]$script:SendFailAts.Add((Get-Date))
            $script:SendFailSeq++
            Write-Log ("keep-alive failed: status=" + $kaStatus + " retcode=" + $r.retcode)
        }
    }
    catch { Write-Log ("keep-alive error: " + $_.Exception.Message) }
}

# ---------------- 自检：只发一条测试通知然后退出 ----------------
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File guardian.ps1 -TestNotify
if ($args -contains "-TestNotify")
{
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Send-Notification ("selftest-" + (Get-Date -Format "HHmmss")) "NapCat 通知自检" ("这是 guardian.ps1 的通道自检。`n时间: " + $stamp + "`n收到即表示该通道可用。")
    Write-Log "selftest notification dispatched"
    exit 0
}

# ---- 每日日报：把 token 消耗、被踢记录、看护重启汇总成一封邮件 ----
# 为什么放在 guardian 里：注册新的计划任务需要管理员权限（会 Access denied），
# 而"每天 09:00 之后发一次"这种逻辑用几十行脚本就能自洽。
function Invoke-DailyReport
{
    param([string]$Today)

    if (-not (Test-Path $REPORT_SCRIPT))
    {
        Write-Log "daily report skipped: $REPORT_SCRIPT not found"
        return
    }
    if (-not (Test-Path $PYTHON_EXE))
    {
        Write-Log "daily report skipped: python not found at $PYTHON_EXE"
        return
    }

    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $PYTHON_EXE
        $psi.Arguments              = '"' + $REPORT_SCRIPT + '" --config "' + $CFG_PATH + '"'
        $psi.WorkingDirectory       = $NAPCAT_HOME
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = 'Hidden'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000))
        {
            try { $proc.Kill() } catch { }
            Write-Log "daily report timed out after 120s"
            return
        }
        $out = ([string]$outTask.Result).Trim()
        $err = ([string]$errTask.Result).Trim()
        $stamp = "[" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "] exit=" + $proc.ExitCode +
                 " stdout=" + $out + " stderr=" + $err + [Environment]::NewLine
        [IO.File]::AppendAllText($REPORT_LOG, $stamp, [Text.UTF8Encoding]::new($false))
        # 只有成功才记"今天已发"；失败留着下轮重试，但由 $REPORT_STAMP_ATTEMPT 限频。
        Set-Content -Path $REPORT_ATTEMPT -Value ((Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")) -NoNewline -Encoding ASCII

        if ($proc.ExitCode -eq 0) { Set-Content -Path $REPORT_STAMP -Value $Today -NoNewline -Encoding ASCII; Write-Log "daily report sent ($out)" }
        else { Write-Log ("daily report failed (exit " + $proc.ExitCode + "): " + $err) }
    }
    catch
    {
        Write-Log ("daily report error: " + $_.Exception.Message)
    }
}
# ---- 离线自检：-SelfTest ----
# 用临时目录里的假日志验证两条检测链路（被踢检测 / 发送失败检测），
# 全程不碰真实 NapCat 进程，也不写真实 kick.log。
function Invoke-SelfTest
{
    $fail = 0
    $tmp = Join-Path $env:TEMP ("napcat-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $savedDir = $NAP_LOG_DIR
    $utf8 = [Text.UTF8Encoding]::new($false)
    try
    {
        $script:NAP_LOG_DIR  = $tmp
        $script:SelfTestMode = $true
        $script:KickSeen     = $false
        $script:SendFailAts.Clear()

        $log = Join-Path $tmp '2026-11-15_10-00-00.000.log'
        [IO.File]::AppendAllText($log, "11-15 10:00:00 [info] boot`n", $utf8)

        # 第一次读：只接管文件，不把历史当成刚发生
        $script:NapLogPath = $null; $script:NapLogPos = 0; $script:NapLogPrevWrite = $null
        Read-NewNapCatLog
        Write-Host ("[1] adopt existing log          KickSeen=" + $script:KickSeen)
        if ($script:KickSeen) { Write-Host '    FAIL: replayed old history'; $fail++ }

        # 追加一行"被踢"
        [IO.File]::AppendAllText($log, "11-15 10:05:00 [error] lepori | [KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。`n", $utf8)
        Read-NewNapCatLog
        Write-Host ("[2] kick line                   KickSeen=" + $script:KickSeen)
        if (-not $script:KickSeen) { Write-Host '    FAIL: kick not detected'; $fail++ }

        # 追加一行"发送失败"
        [IO.File]::AppendAllText($log, "11-15 10:06:00 [error] EventChecker Failed: NTEvent serviceAndMethod:NodeIKernelMsgService/sendMsg ... {`"result`": 1006514, `"errMsg`": `"网络连接异常!`"}`n", $utf8)
        Read-NewNapCatLog
        $broken = Test-SendBroken
        Write-Host ("[3] send failure                SendFailSeq=" + $script:SendFailSeq + " Test-SendBroken=" + $broken)
        if (-not $broken) { Write-Host '    FAIL: send failure not detected'; $fail++ }

        # 探测窗口清空后应当回到 healthy
        $script:SendFailAts.Clear()
        $healthy = -not (Test-SendBroken)
        Write-Host ("[4] window cleared              healthy=" + $healthy)
        if (-not $healthy) { Write-Host '    FAIL: window did not expire'; $fail++ }

        # 静默时长解析：被踢行应有 MM-DD HH:mm:ss 时间戳
        $ts = $script:NapLastLineTs
        Write-Host ("[5] last line timestamp         " + $(if ($ts) { $ts.ToString('MM-dd HH:mm:ss') } else { '<null>' }))
        if (-not $ts) { Write-Host '    FAIL: timestamp not parsed'; $fail++ }

        # [6] 扫码等待判定：码在刷新 + 未登录 + 无错误 → 应当等，不要重启
        $qr1 = Test-QrModeWaiting 30  @{ login = $false; err = '' }
        $qr2 = Test-QrModeWaiting 30  @{ login = $true;  err = '' }
        $qr3 = Test-QrModeWaiting 30  @{ login = $false; err = '登录态已失效' }
        $qr4 = Test-QrModeWaiting 300 @{ login = $false; err = '' }
        $qr5 = Test-QrModeWaiting 30  $null
        Write-Host ("[6] qr-mode waiting            fresh=" + $qr1 + " loggedin=" + $qr2 + " err=" + $qr3 + " stale=" + $qr4 + " null=" + $qr5)
        if (-not ($qr1 -and (-not $qr2) -and (-not $qr3) -and (-not $qr4) -and (-not $qr5)))
        {
            Write-Host '    FAIL: Test-QrModeWaiting logic is wrong'
            $fail++
        }

        # [7] 回归守卫：被踢快速通道必须排在"僵尸态"判断之前。
        # 踢线时 loginError 里也含"失效"，若被 Case 2 抢先，快速通道就变成死代码。
        $src = [IO.File]::ReadAllText($PSCommandPath, [Text.UTF8Encoding]::new($true))
        $kickIdx = $src.IndexOf('if ($script:KickSeen)')
        $zombieIdx = $src.IndexOf('# ---- Case 2:')
        Write-Host ("[7] kick before zombie          kick=" + $kickIdx + " zombie=" + $zombieIdx)
        if ($kickIdx -lt 0 -or $zombieIdx -lt 0 -or $kickIdx -gt $zombieIdx)
        {
            Write-Host '    FAIL: kick fast-path sits after the zombie branch'
            $fail++
        }

        # [8] 回归守卫：KickSeen 必须在 Launch-NapCat 之后才清。
        # 提前清掉 → Launch-NapCat 里 +120s 的"可能要扫码"通知永远不发。
        $branchIdx = $src.IndexOf('Phase A/B/C skipped')
        $launchIdx = $src.IndexOf('$rk = Launch-NapCat')
        if ($launchIdx -ge 0) { $resetIdx = $src.IndexOf('$script:KickSeen = $false', $launchIdx) } else { $resetIdx = -1 }
        Write-Host ("[8] kick flag cleared after launch  branch=" + $branchIdx + " launch=" + $launchIdx + " reset=" + $resetIdx)
        if ($branchIdx -lt 0 -or $launchIdx -lt 0 -or $resetIdx -lt $launchIdx)
        {
            Write-Host '    FAIL: KickSeen is cleared before Launch-NapCat (early notice would never fire)'
            $fail++
        }
        # [9] ntfy 熔断：连续失败到阈值后应跳过，成功后应清掉
        $ntfyTest = Join-Path $env:TEMP ("ntfy-down-" + [guid]::NewGuid().ToString('N') + ".txt")
        $script:NtfyFails = 0
        $sup0 = Test-NtfySuppressed $ntfyTest
        for ($i = 0; $i -lt $NTFY_FAIL_MAX; $i++) { Register-NtfyFailure $ntfyTest }
        $sup1 = Test-NtfySuppressed $ntfyTest
        Clear-NtfyFailure $ntfyTest
        $sup2 = Test-NtfySuppressed $ntfyTest
        Remove-Item -LiteralPath $ntfyTest -Force -ErrorAction SilentlyContinue
        Write-Host ("[9] ntfy circuit                open0=" + $sup0 + " open_after_" + $NTFY_FAIL_MAX + "=" + $sup1 + " cleared=" + $sup2)
        if ($sup0 -or (-not $sup1) -or $sup2)
        {
            Write-Host '    FAIL: ntfy circuit breaker logic is wrong'
            $fail++
        }

    }
    finally
    {
        $script:NAP_LOG_DIR  = $savedDir
        $script:SelfTestMode = $false
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($fail -eq 0) { Write-Host 'SELFTEST PASSED (9 checks)' }
    else { Write-Host ("SELFTEST FAILED (" + $fail + " problem(s))") }
    return $fail
}
if ($SelfTest)
{
    exit (Invoke-SelfTest)
}

# ---------------- 公网扫码入口健康 ----------------
# 扫码页是唯一的远程自救通道：机器人掉线时，用户只能靠它扫码。
# daemon.ps1 每次公网自检都会写 tunnel-state.json；这里读它，连续不可用超过
# $TUNNEL_ALERT_MIN 分钟就发告警——否则用户要等到真正需要扫码那一刻才发现页面打不开。
function Test-TunnelAlert
{
    if (-not (Test-Path $TUNNEL_STATE_FILE)) { return $false }
    try
    {
        $st = Get-Content -LiteralPath $TUNNEL_STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { return $false }

    $ok = $true
    if ($null -ne $st.ok) { $ok = [bool]$st.ok }
    if ($ok) { return $false }

    $at = [DateTime]::MinValue
    if ($st.at) { try { $at = [DateTime]::Parse([string]$st.at) } catch { $at = [DateTime]::MinValue } }
    if ($at -eq [DateTime]::MinValue) { return $false }
    if (((Get-Date) - $at).TotalMinutes -lt $TUNNEL_ALERT_MIN) { return $false }

    if (Test-Path $TUNNEL_ALERT_STAMP)
    {
        try
        {
            $last = [DateTime]::Parse((Get-Content -LiteralPath $TUNNEL_ALERT_STAMP -Raw).Trim())
            if (((Get-Date) - $last).TotalMinutes -lt $TUNNEL_ALERT_COOLDOWN_MIN) { return $false }
        }
        catch {}
    }
    return $true
}

# ================= Main =================

# ---- 单实例保护：互斥体 + 心跳 ----
# 计划任务的 -MultipleInstances IgnoreNew 只能防"任务被再次触发"，
# 防不住手动运行，也防不住旧实例僵死（那时 IgnoreNew 会让新实例永远等）。
# 做法：抢 Global 互斥体；抢不到就看心跳文件 ——
#   心跳 <3 分钟 → 另一实例正常在跑，直接退出；
#   心跳 >=3 分钟 → 旧实例僵死，杀掉它再接管。
$mutexName = "Global\NapCatGuardian"
$script:Mutex = $null
$gotMutex = $false
try
{
    $script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
}
catch
{
    $mutexName = "Local\NapCatGuardian"
    $script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
}
try { $gotMutex = $script:Mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException]
{
    # 上一个持有者被强杀/崩溃退出，内核已把所有权直接转给我们。
    # "杀掉僵死实例再接管"走的正是这条路径，必须算抢到，否则接管永远失败。
    $gotMutex = $true
}
catch { $gotMutex = $false }

if (-not $gotMutex)
{
    $hbAge = [double]::MaxValue
    $hbPid = 0
    if (Test-Path $HEARTBEAT_FILE)
    {
        $hbAge = ((Get-Date) - (Get-Item $HEARTBEAT_FILE).LastWriteTime).TotalMinutes
        try
        {
            $hbTxt = Get-Content $HEARTBEAT_FILE -Raw
            if ($hbTxt -match '^\s*(\d+)\s*\|') { $hbPid = [int]$Matches[1] }
        }
        catch { }
    }
    if ($hbAge -lt 3)
    {
        Write-Log ("another guardian instance is alive (pid " + $hbPid + ", heartbeat " +
                   [int]($hbAge * 60) + "s ago) - exiting to avoid double-start.")
        exit 0
    }
    if ($hbPid -gt 0)
    {
        # 心跳过期只说明"那个 pid 很久没写心跳了"，不等于"那个 pid 还是 guardian"。
        # Windows 会回收 PID：隔几天再来看，同一个号很可能已经是 QQ / 浏览器 /
        # 系统的某个进程。以前这里直接 Stop-Process -Force，等于随机杀进程 ——
        # 最坏情况正好把正在扫码的 QQ 杀掉。所以先确认它的命令行里确实是 guardian。
        $isGuardian = $false
        try
        {
            $hbProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $hbPid) -ErrorAction Stop
            if ($hbProc -and $hbProc.CommandLine -like '*guardian.ps1*') { $isGuardian = $true }
        }
        catch { }
        if ($isGuardian)
        {
            Write-Log ("stale guardian instance detected (pid " + $hbPid + ", no heartbeat for " +
                       [int]$hbAge + " min) - terminating it and taking over.")
            Stop-Process -Id $hbPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        else
        {
            Write-Log ("heartbeat points at pid " + $hbPid + " but that process is not guardian " +
                       "(recycled pid?) - not touching it, taking over anyway.")
        }
    }
    else
    {
        Write-Log "mutex is held but heartbeat is missing - exiting to be safe."
        exit 0
    }
}

Write-Log "============ Guardian started, monitoring $QQ_UIN ============"
Write-Heartbeat
Set-BotState "starting" "看护启动"
# 注意：AstrBot 不在这里启动。它由用户级 astrbot_watchdog.ps1 负责拉起，
# 这样 AstrBot 以普通权限运行 —— 它带着"电脑操控"类插件，用管理员权限跑
# 等于把整台机器交给任何能给它发消息的人，而且它执行的命令会弹管理员窗口。

# ---- 一次性清理：把跑在可见 cmd 窗口里的 AstrBot 换成无窗口实例 ----
# 旧版本用 `Start-Process cmd -WindowStyle Minimized` 起 AstrBot，那个 cmd 窗口
# 就是开机后残留的"astrbot 终端"，关掉它会连带杀死 AstrBot。这里允许通过
# 标志文件让看护把自己顺手替换成 pythonw 无窗口实例。
$abFlag = $AB_FLAG
if (Test-Path $abFlag)
{
    Remove-Item $abFlag -Force -ErrorAction SilentlyContinue
    Write-Log "restart-astrbot requested: stopping the visible-console AstrBot instance ..."
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
        Where-Object { $_.ExecutablePath -like '*Python314*' -and $_.CommandLine -match 'main\.py' } |
        ForEach-Object {
            Write-Log ("  stop AstrBot pid " + $_.ProcessId + " (parent " + $_.ParentProcessId + ")")
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Seconds 5
    # 不在这里重新拉起：交给用户级 astrbot_watchdog 用普通权限启动
}
$offlineCount = 0
$recoverCount = 0
$lastRecover  = [DateTime]::MinValue
$circuitUntil = [DateTime]::MinValue   # 熔断到期时间：此时间前不再自动重启
$lastQuietLog = [DateTime]::MinValue   # 熔断/夜间提示的限频时间戳
$nextKeepAlive = (Get-Date).AddSeconds((Get-NextKeepAliveDelay))
$script:ForeignSince = [DateTime]::MinValue   # 桌面 QQ 已运行多久（超过上限才强行抢回机器人）
$script:QrModeSince = [DateTime]::MinValue   # 从什么时候开始停在登录页等人扫码
$script:RecoveryCause = ""                        # 本次恢复的触发原因（kick/zombie/sendfail/webui_down/qr_wait/offline）
$script:RecoveryPath = ""                         # 本次恢复走的路径（fast/staged/launch/worker/wait_scan）
$script:LastResetAt  = [DateTime]::MinValue   # 上次"连接重置"的时间（发送失败探测限频）
$script:KickSeen     = $false                 # 本掉线事件里是否已从日志确认 [KickedOffLine]
$script:WasHealthy   = $null                  # 上一轮的健康状态（$null = 本进程还没判断过）（用于检测 false->true 跃迁，重置会话起点）
$script:UnhealthyLogged   = $false            # 本次掉线是否已经记过 unhealthy 日志（限频用）
$script:LastUnhealthyLog  = [DateTime]::MinValue

# 最后一层保护：未被局部 catch 捕获的终止异常不能让看护进程静默退出。
# 记录异常、刷新心跳后继续下一轮；计划任务重启仍作为第二层兜底。
trap {
    $e = $_.Exception
    try { Write-Log ("UNHANDLED guardian exception: " + $e.Message) } catch { }
    try { Write-Heartbeat } catch { }
    try { Start-Sleep -Seconds 5 } catch { }
    continue
}

while ($true)
{
    # ---- 每日 09:00 之后发一次日报 ----
    if ((Get-Date).Hour -ge $REPORT_HOUR)
    {
        $todayStamp = (Get-Date).ToString('yyyy-MM-dd')
        $lastReport = ''
        if (Test-Path $REPORT_STAMP)
        {
            try { $lastReport = ([string](Get-Content $REPORT_STAMP -Raw)).Trim() } catch { }
        }
        $tooSoon = $false
        if (Test-Path $REPORT_ATTEMPT)
        {
            try { $tooSoon = (((Get-Date) - [datetime]::ParseExact(([string](Get-Content $REPORT_ATTEMPT -Raw)).Trim(), "yyyy-MM-ddTHH:mm:ss", $null)).TotalMinutes -lt 60) } catch { }
        }
        if ($lastReport -ne $todayStamp -and -not $tooSoon) { Invoke-DailyReport $todayStamp }
    }
    # ---- 手动强制重启开关：在 $NAPCAT_HOME 下新建 force-relaunch.flag 即可 ----
    # 用途：升级 NapCat、换版本、注入失效时，用"完整重启"（杀 QQ + 重新注入）
    # 而不是 RestartNapCat（只重启 worker，注入的 DLL 还是旧的）。
    $forceFile = $FORCE_FLAG
    if (Test-Path $forceFile)
    {
        Remove-Item $forceFile -Force -ErrorAction SilentlyContinue
        Write-Log "force relaunch requested (flag file) - full restart, re-injecting NapCat ..."
        $fr = Launch-NapCat
        if ($fr -eq "online") { Write-Log "  forced relaunch: online."; Set-BotState "online" "已登录" }
        elseif ($fr -eq "need_scan") { Write-Log "  forced relaunch: waiting for a QR scan."; $null = Wait-Scan }
        else { Write-Log ("  forced relaunch: " + $fr) }
        $offlineCount = 0
        $recoverCount = 0
    }

    # ---- Keep-alive timing：固定 10 分钟探针（静默满 10 分钟才发） ----
    if ((Get-Date) -ge $nextKeepAlive)
    {
        $nowKA   = Get-Date
        $idleMin = ($nowKA - (Get-NapCatLastActivity)).TotalMinutes
        $nightKA = ($nowKA.Hour -ge $KEEPALIVE_NIGHT_FROM -and $nowKA.Hour -lt $KEEPALIVE_NIGHT_TO)
        if ($nightKA)
        {
            $nextKeepAlive = $nowKA.AddMinutes(30)
        }
        elseif ($idleMin -lt $KEEPALIVE_IDLE_MIN)
        {
            # 刚有真实收发（有人聊天），保活没有意义，10 分钟后再看
            $nextKeepAlive = $nowKA.AddMinutes(10)
        }
        else
        {
            if (Get-Online) { Send-KeepAlive }
            $nextKeepAlive = $nowKA.AddSeconds((Get-NextKeepAliveDelay))
        }
    }

    # ---- Watchdog check ----
    # 只看 get_status.online 不够：登录态失效（僵尸态）时它依然返回 true。
    $online = Get-Online
    $lsNow  = Get-LoginStatus

    # ---- 发送失败探测：长连接已死时 get_status 仍报 online=true ----
    # 11-11 16:43 那次"假在线"持续了 50 分钟，只看 online 完全发现不了。
    # 这里盯 NapCat 自己的日志：出现"网络连接异常"就立刻 RestartNapCat ——
    # 只重启 worker，保留 QQ 进程与缓存 token，正常情况下免扫码就登回来。
    Read-NewNapCatLog
    if ((Test-SendBroken) -and $online)
    {
        $nowReset = Get-Date
        if ($circuitUntil -gt $nowReset)
        {
            if (($nowReset - $lastQuietLog).TotalMinutes -ge 10)
            {
                $lastQuietLog = $nowReset
                Write-Log "send-fail seen but circuit is open - not restarting"
            }
        }
        elseif (($nowReset - $script:LastResetAt).TotalSeconds -lt $SENDFAIL_COOLDOWN)
        {
            # 刚重置过，给缓存 token 一点时间，不重复重启
        }
        elseif (-not (Confirm-SendBroken))
        {
            Write-Log "send-fail was transient (probe ok) - ignoring"
            $script:SendFailAts.Clear()
        }
        else
        {
            $script:LastResetAt = $nowReset
            $script:SendFailAts.Clear()
            Write-Log "========== connection reset (send-fail) =========="
            if (Invoke-ConnectionReset)
            {
                Write-Log "  connection reset ok: back online with cached token (no scan)."
                Set-BotState "online" "已登录"
                $online = $true
                $offlineCount = 0
                $recoverCount = 0
            }
            else
            {
                Write-Log "  connection reset failed - falling through to normal recovery."
                $offlineCount = $OFFLINE_LIMIT
            }
        }
    }
    $zombie = ($null -ne $lsNow) -and $lsNow.login -and ($lsNow.err -match "失效|重新登录|expired|过期")
    $healthy = $online -and (-not $zombie)

    if ($healthy)
    {
        # 会话起点：guardian 自己重启后从 session-since.txt 恢复（票据没变，
        # 续期时间点也不该被推迟）；只有"掉线 -> 在线"的真跃迁才重置为现在。
        if ($null -eq $script:WasHealthy) { Confirm-SessionSince }
        elseif (-not $script:WasHealthy) { Set-SessionSince (Get-Date) }
        if ($offlineCount -gt 0) { Write-Log "back online" }
        Set-BotState "online" "已登录"
        $offlineCount = 0
        $recoverCount = 0
        $circuitUntil = [DateTime]::MinValue
        $script:UnhealthyLogged = $false
        $script:QrModeSince = [DateTime]::MinValue
    }
    else
    {
        $offlineCount++
        $why = if ($zombie) {
                   "zombie login state: " + $lsNow.err
               }
               elseif ($null -eq $lsNow) {
                   "cannot read login status (NapCat WebUI unreachable?)"
               }
               else {
                   "online=" + [string][bool]$online
               }
        # 掉线期间每 20 秒就走到这里，而熔断可以开 2 小时 = 360 行重复日志。
        # 改成：每次掉线开头记一行，之后每 5 分钟记一行。
        $nowU = Get-Date
        if ((-not $script:UnhealthyLogged) -or (($nowU - $script:LastUnhealthyLog).TotalMinutes -ge 5))
        {
            $script:UnhealthyLogged  = $true
            $script:LastUnhealthyLog = $nowU
            Write-Log ("unhealthy detected (" + $offlineCount + "/" + $OFFLINE_LIMIT + "): " + $why)
        }
    }

    # ---- 主动会话续期：在"约 2 小时被踢"之前主动重新登录 ----
    if ($healthy -and $PROACTIVE_REFRESH_MIN -gt 0)
    {
        Confirm-SessionSince
        $sessMin  = Get-SessionMinutes
        $idlePro  = ((Get-Date) - (Get-NapCatLastActivity)).TotalMinutes
        if ($sessMin -ge $PROACTIVE_REFRESH_MIN -and $idlePro -ge $PROACTIVE_IDLE_MIN -and (Test-QuickLoginAvailable))
        {
            Write-Log ("proactive session refresh: session " + $sessMin + " min old, idle " +
                       [int]$idlePro + " min - restarting worker to renew the ticket ...")
            try
            {
                $hpr = Get-WebUIHeaders
                Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RestartNapCat" -Method Post `
                    -Headers $hpr -TimeoutSec 20 | Out-Null
            }
            catch { Write-Log ("  refresh call error: " + $_.Exception.Message) }
            if (Wait-Login $WORKER_WAIT_SEC)
            {
                Set-SessionSince (Get-Date)
                Set-BotState "online" "已登录"
                Write-Log "  session refreshed (new ticket); no scan needed."
            }
            else
            {
                Write-Log "  proactive refresh did not log back in - handing over to normal recovery."
                $offlineCount = $OFFLINE_LIMIT
                $script:UnhealthyLogged = $false
                $healthy = $false
            }
        }
    }

    if ($offlineCount -ge $OFFLINE_LIMIT)
    {
        $now   = Get-Date
        $since = ($now - $lastRecover).TotalSeconds
        $night = ($now.Hour -ge $NIGHT_QUIET_FROM -and $now.Hour -lt $NIGHT_QUIET_TO)

        if ($circuitUntil -gt $now)
        {
            # 熔断中：只记录，绝不碰 NapCat（反复重启才是触发风控的真正原因）
            if (($now - $lastQuietLog).TotalMinutes -ge 10)
            {
                $lastQuietLog = $now
                Write-Log ("circuit open until " + $circuitUntil.ToString("MM-dd HH:mm") +
                           " - no auto restart, waiting for manual scan / self-heal")
            }
        }
        elseif ($night -and ($now - $lastRecover).TotalHours -lt $NIGHT_MIN_GAP)
        {
            if (($now - $lastQuietLog).TotalMinutes -ge 10)
            {
                $lastQuietLog = $now
                Write-Log ("night quiet hours (" + $NIGHT_QUIET_FROM + ":00-" + $NIGHT_QUIET_TO +
                           ":00) - no auto restart, waiting for self-heal / manual scan")
            }
        }
        elseif ($recoverCount -ge $MAX_RECOVER)
        {
            $circuitUntil = $now.AddMinutes($CIRCUIT_MINUTES)
            $lastQuietLog = $now
            Write-Log ("reached MAX_RECOVER (" + $MAX_RECOVER + "); opening circuit for " + $CIRCUIT_MINUTES + " min")
        }
        elseif ($recoverCount -gt 0 -and $since -lt $RECOVER_COOLDOWN)
        {
            # in cooldown; keep quiet
        }
        else
        {
            $recoverCount++
            $lastRecover = Get-Date
            Write-Log ("========== Recovery attempt #" + $recoverCount + " ==========")

            $result = Do-Recovery
            switch ($result)
            {
                "online"
                {
                    $tookSec = [int]((Get-Date) - $lastRecover).TotalSeconds
                    $script:LastRecoverSec = $tookSec
                    $script:LastRecoverAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    Write-Log ("Recovery attempt #" + $recoverCount + " succeeded in " + $tookSec + "s (cause=" + $script:RecoveryCause + ", path=" + $script:RecoveryPath + ").")
                    Set-BotState "online" "已登录"
                    Send-Notification "recovered" "NapCat bot recovered" `
                        ("机器人 QQ $QQ_UIN 已自动恢复在线（无需扫码）。`n耗时: " + $tookSec + " 秒`n会话时长: " + (Get-SessionMinutes) + " 分钟") "default"
                    $recoverCount = 0
                }
                "need_scan"
                {
                    # 已经弹过通知、盯了 10 分钟扫码。别再自动重启，给用户留时间扫。
                    Write-Log ("Recovery attempt #" + $recoverCount +
                               " -> waiting for manual QR scan (no more auto restarts for 15 min).")
                    $recoverCount = 0
                    $circuitUntil = (Get-Date).AddMinutes(15)
                    $lastQuietLog = Get-Date
                }
                "deferred"
                {
                    # 桌面 QQ 正开着，等它关掉再拉机器人（避免互踢）
                    if (($(Get-Date)) - $lastQuietLog -gt [TimeSpan]::FromMinutes(10))
                    {
                        $lastQuietLog = Get-Date
                        Write-Log "recovery deferred: desktop QQ is in use; bot resumes when it closes."
                    }
                    $recoverCount = 0
                }
                default
                {
                    # 一次失败就熔断：不再"5 分钟后再试一次"，避免连续无效登录
                    Write-Log ("Recovery attempt #" + $recoverCount +
                               " failed - opening " + $CIRCUIT_MINUTES + " min circuit, waiting for manual action.")
                    $circuitUntil = (Get-Date).AddMinutes($CIRCUIT_MINUTES)
                    $lastQuietLog = Get-Date
                    $nb = "机器人 QQ $QQ_UIN 自动恢复失败，已熔断 $CIRCUIT_MINUTES 分钟，需要人工处理。`n"
                    if ($QR_PAGE_URL) { $nb += "扫码页: $QR_PAGE_URL" }
                    Send-Notification "circuit" "NapCat bot circuit opened" $nb "high"
                }
            }
        }
        $offlineCount = 0
    }

    if (Test-TunnelAlert)
    {
        [IO.File]::WriteAllText($TUNNEL_ALERT_STAMP, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (New-Object Text.UTF8Encoding($false)))
        $tb = "扫码页的公网通道自检失败已超过 " + $TUNNEL_ALERT_MIN + " 分钟，手机可能打不开二维码页面。`n"
        try
        {
            $stx = Get-Content -LiteralPath $TUNNEL_STATE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            $tb += "隧道供应商: " + [string]$stx.provider + "`n最后状态时间: " + [string]$stx.at + "`n连续失败: " + [string]$stx.failStreak + " 次`n"
        }
        catch {}
        if ($QR_PAGE_URL) { $tb += "扫码页: " + $QR_PAGE_URL }
        Write-Log ("tunnel health alert: public QR page failing for more than " + $TUNNEL_ALERT_MIN + " min")
        Send-Notification "tunnel" "NapCat QR page unreachable" $tb "high"
    }

    $script:WasHealthy = $healthy
    Write-Metrics $nextKeepAlive
    Write-Heartbeat
    Start-Sleep -Seconds $CHECK_INTERVAL
}
