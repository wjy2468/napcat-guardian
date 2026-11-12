# ============================================================
#  NapCat Guardian v2 - Keep-alive + staged auto-recovery
#  ----------------------------------------------------------
#  1) Keep-alive: the bot sends a short message to ITSELF at random
#     intervals (30-45 min by default). This creates real protocol
#     activity without disturbing anyone, and doubles as a health
#     probe: a non-zero retcode means the connection is already dead.
#
#  2) Watchdog (every 20 s, 2 consecutive failures = recover):
#       * NapCat not running (boot/crash)  -> launch immediately
#       * zombie session (isLogin=true but -> RestartNapCat, then
#         loginError="登录态已失效")            wait for cached login
#       * send failures in NapCat log      -> restart worker before
#         ("网络连接异常")                      get_status notices
#       * worker dead / stuck              -> RestartNapCat
#       * still offline after that         -> full relaunch
#       * login invalid / needs QR         -> wait for a scan
#
#  3) Safety rails (learned from real restart storms that got
#     accounts frozen by Tencent risk control):
#       * at most ONE auto-recovery per outage, then 120-min circuit
#       * 02:00-07:00 quiet window, at most one attempt every 3 h
#       * never kill a desktop QQ the user started manually
#       * no console windows (CreateNoWindow), close-safe
#
#  Recommended: install as a Scheduled Task with HIGHEST privileges
#  (run scripts\install_guardian.bat as administrator once).
# ============================================================

# ---------------- Configuration ----------------
$QQ_UIN     = "YOUR_BOT_QQ"
$HTTP_API   = "http://127.0.0.1:3000"
$WEBUI_API  = "http://127.0.0.1:6099"
$WEBUI_TOK  = "YOUR_WEBUI_TOKEN"
$NAPCAT_DIR = "D:\napcat\NapCat.Shell"
$LOG_FILE   = "D:\napcat\guardian.log"
$QR_FILE    = "D:\napcat\NapCat.Shell\cache\qrcode.png"
# 机器人登录状态文件：给 qrsync 网页读，用来在页面上显示"需要扫码"提示
$STATE_FILE = "D:\napcat\qrsync\login-state.json"

# Keep-alive interval range (seconds).
# 2026-11-12: 实测 6 次被踢全部发生在活跃对话中（最近一次距上条保活仅 4 分钟），
# 说明"静默被踢"不是当前的主要掉线形态；保活只剩健康探针作用，因此放宽到 30-45 分钟。
$KEEPALIVE_MIN = 1800   # 30 min
$KEEPALIVE_MAX = 2700   # 45 min

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
$SENDFAIL_WINDOW    = 600  # 统计窗口（秒）
$SENDFAIL_THRESHOLD = 2    # 窗口内累计几次就判定连接已死
$SENDFAIL_COOLDOWN  = 900  # 两次"连接重置"之间的最小间隔（秒）

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
$QQ_DATA_DIR = "D:\napcat\qqdata"   # 留空 = 不隔离（与桌面 QQ 共用）

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
function Write-Log($msg)
{
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

# ---------------- 对外公布登录状态（qrsync 页面读这个文件） ----------------
$script:LastState = ""
function Set-BotState([string]$state, [string]$note)
{
    if ($script:LastState -eq $state) { return }
    $script:LastState = $state
    $obj = [ordered]@{
        state = $state
        note  = $note
        uin   = $QQ_UIN
        at    = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
    }
    try
    {
        $json = $obj | ConvertTo-Json -Compress
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
        return [bool]$r.data.online
    }
    catch
    {
        return $null
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

    $byParent = @{}
    foreach ($p in $procs)
    {
        $pp = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = New-Object System.Collections.ArrayList }
        [void]$byParent[$pp].Add([int]$p.ProcessId)
    }

    $owned = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    foreach ($b in @($procs | Where-Object { $_.Name -eq 'NapCatWinBootMain.exe' }))
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
$script:SendFailAts = New-Object System.Collections.ArrayList

function Read-NewNapCatLog
{
    if (-not (Test-Path $NAP_LOG_DIR)) { return }
    $f = Get-ChildItem $NAP_LOG_DIR -Filter *.log -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return }

    if ($script:NapLogPath -ne $f.FullName)
    {
        $script:NapLogPath = $f.FullName
        $script:NapLogPos  = 0
    }
    if ($f.Length -le $script:NapLogPos) { return }

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
    foreach ($line in ($txt -split "`n"))
    {
        if ($line -match '网络连接异常|EventChecker Failed')
        {
            [void]$script:SendFailAts.Add((Get-Date))
        }
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

# 连接复活：只重启 worker（不杀 QQ、不重新注入），走缓存 token 免扫码
function Invoke-ConnectionReset
{
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
    while ($waited -lt $LOGIN_WAIT_SEC)
    {
        Start-Sleep -Seconds 15
        $waited += 15
        $ls = Get-LoginStatus
        if ($ls -and $ls.login) { Write-Log "  logged in."; return "online" }
        if ($ls -and $ls.err -match "失效|重新登录|expired|过期")
        {
            Write-Log ("  session expired: " + $ls.err)
            return "need_scan"
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
    return "timeout"
}

# ---------------- Recovery: choose the right path ----------------
# Returns $true if back online, $false if a manual QR scan is required.
function Do-Recovery
{
    # ---- Case 1: WebUI unreachable -> NapCat is NOT running at all
    # (typical right after boot / after a crash). Launch it immediately;
    # waiting through the grace period here would waste minutes.
    if (-not (Test-WebUI))
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

        Write-Log "NapCat not running (WebUI unreachable), launching directly ..."
        $r = Launch-NapCat
        if ($r -eq "online") { Write-Log "  launch succeeded."; return "online" }
        if ($r -eq "need_scan") { Notify-Admin; return "need_scan" }
        return "failed"
    }

    # ---- Case 2: WebUI is up (NapCat started) but the bot is not really usable.
    # 关键场景：isLogin=true 但 loginError 非空 = 登录态已失效的"僵尸态"，
    # 它仍然自报 online=true，所以只看 Get-Online 永远发现不了。
    $ls = Get-LoginStatus
    if ($ls -and $ls.err -match "失效|重新登录|expired|过期")
    {
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

    # ---- Case 3: NapCat is up, probably a brief network blip or a kick.
    # Phase A: grace period first (wait for self-heal, do NOT kill).
    Write-Log "Phase A: grace period, waiting for network self-heal (up to 90s) ..."
    for ($i = 0; $i -lt 6; $i++)
    {
        Start-Sleep -Seconds 15
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
    # native Windows popup (msg.exe is available on most Windows editions)
    $msg = "NapCat bot ($QQ_UIN) is offline and could not auto-login. " +
           "Please scan the QR code in the NapCat window. " +
           "QR picture: $NAPCAT_DIR\cache\qrcode.png"
    try { msg.exe * $msg } catch {}
}

# ---------------- 等人扫码：盯着登录状态，扫上就恢复 ----------------
# NapCat 在等待扫码时会每 2 分钟自动换一张新码，所以这里不需要自己刷新。
function Wait-Scan
{
    Notify-Admin
    for ($i = 0; $i -lt 40; $i++)     # 最多盯 10 分钟
    {
        Start-Sleep -Seconds 15
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

# ---------------- Keep-alive: send one message to self ----------------
function Send-KeepAlive
{
    try
    {
        $text = $KA_POOL | Get-Random
        $msg = "{0}  {1}" -f (Get-Date -Format "HH:mm"), $text
        $body = @{ user_id = $QQ_UIN; message = $msg } | ConvertTo-Json
        $r = Invoke-RestMethod -Uri "$HTTP_API/send_private_msg" -Method Post `
                -Body $body -ContentType "application/json" -TimeoutSec 15
        if ($r.retcode -eq 0) { Write-Log ("keep-alive sent: " + $msg) }
        else { Write-Log ("keep-alive retcode: " + $r.retcode) }
    }
    catch { Write-Log ("keep-alive error: " + $_.Exception.Message) }
}

# ================= Main =================
Write-Log "============ Guardian started, monitoring $QQ_UIN ============"
Set-BotState "starting" "看护启动"
# 注意：AstrBot 不在这里启动。它由用户级 astrbot_watchdog.ps1 负责拉起，
# 这样 AstrBot 以普通权限运行 —— 它带着"电脑操控"类插件，用管理员权限跑
# 等于把整台机器交给任何能给它发消息的人，而且它执行的命令会弹管理员窗口。

# ---- 一次性清理：把跑在可见 cmd 窗口里的 AstrBot 换成无窗口实例 ----
# 旧版本用 `Start-Process cmd -WindowStyle Minimized` 起 AstrBot，那个 cmd 窗口
# 就是开机后残留的"astrbot 终端"，关掉它会连带杀死 AstrBot。这里允许通过
# 标志文件让看护把自己顺手替换成 pythonw 无窗口实例。
$abFlag = "D:\napcat\restart-astrbot.flag"
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
$nextKeepAlive = (Get-Date).AddSeconds((Get-Random -Min $KEEPALIVE_MIN -Max $KEEPALIVE_MAX))
$script:ForeignSince = [DateTime]::MinValue   # 桌面 QQ 已运行多久（超过上限才强行抢回机器人）
$script:LastResetAt  = [DateTime]::MinValue   # 上次"连接重置"的时间（发送失败探测限频）

while ($true)
{
    # ---- 手动强制重启开关：在 D:\napcat 下新建 force-relaunch.flag 即可 ----
    # 用途：升级 NapCat、换版本、注入失效时，用"完整重启"（杀 QQ + 重新注入）
    # 而不是 RestartNapCat（只重启 worker，注入的 DLL 还是旧的）。
    $forceFile = "D:\napcat\force-relaunch.flag"
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

    # ---- Keep-alive timing ----
    if ((Get-Date) -ge $nextKeepAlive)
    {
        $onlineNow = Get-Online
        if ($onlineNow) { Send-KeepAlive }
        # schedule next keep-alive with a random interval
        $nextKeepAlive = (Get-Date).AddSeconds((Get-Random -Min $KEEPALIVE_MIN -Max $KEEPALIVE_MAX))
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
        if ($offlineCount -gt 0) { Write-Log "back online" }
        Set-BotState "online" "已登录"
        $offlineCount = 0
        $recoverCount = 0
        $circuitUntil = [DateTime]::MinValue
    }
    else
    {
        $offlineCount++
        $why = if ($zombie) { "zombie login state: " + $lsNow.err } else { "online=" + $online }
        Write-Log ("unhealthy detected (" + $offlineCount + "/" + $OFFLINE_LIMIT + "): " + $why)
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
                    Write-Log ("Recovery attempt #" + $recoverCount + " succeeded.")
                    Set-BotState "online" "已登录"
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
                }
            }
        }
        $offlineCount = 0
    }

    Start-Sleep -Seconds $CHECK_INTERVAL
}
