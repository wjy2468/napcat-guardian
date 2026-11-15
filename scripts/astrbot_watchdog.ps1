# ============================================================
#  AstrBot 看护脚本
#   - 每 30s 检查 WebUI 端口 6185 是否在听
#   - 掉线则用 python main.py 重新拉起（隐藏窗口，输出进 console 日志）
#   - 启动时若没在跑，也会立刻拉起（兼任开机自启）
#   - 日志：D:\napcat\astrbot_watchdog.log（>2MB 轮转为 .1）
#   - 停止：astrbot_watchdog.ps1 -Stop
# ============================================================

param(
    [switch]$Stop
)

$ErrorActionPreference = 'Continue'

# ---------------- Configuration ----------------
$ASTRBOT_DIR   = 'C:\path\to\astrbot'
$PYTHON        = "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe"
$PORT          = 6185
$CHECK_SECONDS = 30
$BOOT_WAIT     = 150      # 拉起后最多等这么多秒让端口起来
$LOG_FILE      = Join-Path $PSScriptRoot 'astrbot_watchdog.log'
$MUTEX_NAME    = 'Local\astrbot-watchdog'
$MAX_LOG_BYTES = 2MB
$KEEP_CONSOLE_LOGS = 10   # $ASTRBOT_DIR 里最多保留几份 astrbot-console-*.log
# 一页状态：给 qrsync 网页 / 外部监控读（AstrBot 死掉时 NapCat 完全不知情，
# 所以这块状态必须由看护自己写出来，否则用户只能靠"机器人不理人"才发现）。
$STATE_FILE    = Join-Path $PSScriptRoot 'astrbot-state.json'
$script:BotSince  = $null
$script:Restarts  = 0

# ---------------- Logging ----------------
function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $LOG_FILE) -and ((Get-Item $LOG_FILE).Length -gt $MAX_LOG_BYTES)) {
            Move-Item $LOG_FILE "$LOG_FILE.1" -Force
        }
        Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    } catch { }
}

# ---------------- 状态文件 ----------------
function Write-BotState([string]$state, [string]$note = '') {
    try {
        $proc = Get-BotProcesses | Sort-Object CreationDate | Select-Object -First 1
        if ($proc -and (-not $script:BotSince -or $script:BotSince -lt $proc.CreationDate)) {
            $script:BotSince = $proc.CreationDate
        }
        $obj = [ordered]@{
            at       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
            state    = $state
            note     = $note
            pid      = if ($proc) { [int]$proc.ProcessId } else { 0 }
            portOk   = [bool](Test-Port)
            restarts = $script:Restarts
            since    = if ($script:BotSince) { $script:BotSince.ToString('yyyy-MM-ddTHH:mm:sszzz') } else { '' }
        }
        [IO.File]::WriteAllText($STATE_FILE, ($obj | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
# ---------------- -Stop：直接结束正在跑的那个实例 ----------------
# 旧写法是"抢到互斥体才停"，可正在跑的时候互斥体恰恰是被它自己占着的：
# 于是 -Stop 会走进"本实例不是主实例"分支直接退出，一次也停不掉，
# 想停只能去任务管理器里摸 PID。现在改成按命令行找进程。
if ($Stop) {
    $self = $PID
    # 用正则卡住 "-File ...astrbot_watchdog.ps1" 这个形状，而不是简单 -like 子串匹配：
    # 否则任何"命令行里提到这个文件名的进程"（编辑器、带 -Command 的一行命令、
    # 甚至做同样检查的另一个脚本）都会被误杀。
    $targets = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $self -and
            $_.CommandLine -and
            $_.CommandLine -match '-File\s+"?[^"]*astrbot_watchdog\.ps1' -and
            $_.CommandLine -notmatch '\s-Stop\b'
        })
    if ($targets.Count -eq 0) {
        Write-Log '-Stop：没有找到正在运行的看护实例（可能已经停了）'
        exit 0
    }
    foreach ($t in $targets) {
        Write-Log "-Stop：结束看护进程 PID $($t.ProcessId)"
        Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# ---------------- 单实例 ----------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $MUTEX_NAME, [ref]$createdNew)
if (-not $createdNew) {
    Write-Log '已有看护实例在运行（互斥体被占用），本实例退出'
    exit 0
}

# ---------------- 工具函数 ----------------
function Test-Port {
    $c = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue
    return [bool]$c
}

function Get-BotProcesses {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $PYTHON -and $_.CommandLine -match 'main\.py' }
}

# 每次重启都写两个新文件（stdout/stderr），一年下来能把 AstrBot 目录塞满。
function Remove-OldConsoleLogs {
    try {
        $logs = @(Get-ChildItem -Path $ASTRBOT_DIR -Filter 'astrbot-console-*.log' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($logs.Count -le $KEEP_CONSOLE_LOGS) { return }
        foreach ($old in ($logs | Select-Object -Skip $KEEP_CONSOLE_LOGS)) {
            Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Start-Bot {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $ASTRBOT_DIR "astrbot-console-$stamp.log"
    $errLog = Join-Path $ASTRBOT_DIR "astrbot-console-$stamp.err.log"
    try {
        $p = Start-Process -FilePath $PYTHON -ArgumentList 'main.py' `
            -WorkingDirectory $ASTRBOT_DIR -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        Write-Log "已拉起 AstrBot，PID=$($p.Id)，输出 $outLog"
        Remove-OldConsoleLogs
        return $p
    } catch {
        Write-Log "拉起失败：$($_.Exception.Message)"
        return $null
    }
}

function Wait-Up([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port) { return $true }
        Start-Sleep -Seconds 3
    }
    return (Test-Port)
}

# ---------------- 主循环 ----------------
Write-Log '================ 看护启动 ================'

if (-not (Test-Path $PYTHON)) {
    Write-Log "找不到 python：$PYTHON"
    $mutex.ReleaseMutex()
    exit 1
}

if (-not (Test-Port)) {
    $existing = Get-BotProcesses
    if ($existing) {
        Write-Log "已有 AstrBot 进程（PID $($existing.ProcessId -join ',')），等端口起来"
        [void](Wait-Up 60)
    } else {
        Write-Log '首次检查：AstrBot 未运行，立即拉起'
        [void](Start-Bot)
        if (Wait-Up $BOOT_WAIT) { Write-Log "启动成功，端口 $PORT 已就绪" }
        else { Write-Log "启动后 ${BOOT_WAIT}s 端口仍未就绪，继续观察" }
    }
} else {
    Write-Log "AstrBot 已在运行，端口 $PORT 正常"
}
$initState = if (Test-Port) { 'online' } else { 'starting' }
Write-BotState $initState 'watchdog started'

$lastHeartbeat = Get-Date
$failStreak = 0

while ($true) {
    Start-Sleep -Seconds $CHECK_SECONDS

    # 心跳（每 10 分钟一条，避免日志无限增长）
    if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
        $portNow = Test-Port
        Write-Log "心跳：端口 $PORT $(if ($portNow) { '正常' } else { '无监听' })"
        $hbState = if ($portNow) { 'online' } else { 'down' }
        Write-BotState $hbState 'heartbeat'
        $lastHeartbeat = Get-Date
    }

    if (Test-Port) {
        $failStreak = 0
        # 每轮都刷新状态文件：网页用「多久以前的状态」判断是否新鲜，
        # 只靠 10 分钟一次的心跳会让它误报「AstrBot 异常」。
        Write-BotState 'online' 'ok'
        continue
    }

    # 端口没了：可能是进程挂了，也可能是正在重启
    $proc = Get-BotProcesses
    Write-Log "检测到端口 $PORT 无监听（python 进程数：$(($proc | Measure-Object).Count)）"

    if ($proc) {
        # 2026-11-15：端口没了但进程还在，可能是「正在慢慢启动/初始化」，也可能是
        # 「HTTP 层死了但核心还活着」（11-13 19:59 就是后者：proactor accept 循环抛
        # WinError 64 退出，6185/6199 一起没了，但 AstrBot 还在正常处理消息）。
        # 旧逻辑只等 20 秒就 Stop-Process，会把「只是在忙」的进程误杀。
        # 新逻辑：最多观察 90 秒，同时采样 CPU 时间与最新日志长度增量；
        #   - 观察期内端口恢复 → 正常，继续循环；
        #   - 进程启动未满 $BOOT_WAIT 且 CPU 还在涨 → 还在初始化，本轮不杀，下轮再看；
        #   - 否则判僵死，强杀重启。
        $oldest = $proc | Sort-Object CreationDate | Select-Object -First 1
        $ageSec = ((Get-Date) - $oldest.CreationDate).TotalSeconds
        $ids = @($proc | ForEach-Object { $_.ProcessId })
        $logDir = Join-Path $ASTRBOT_DIR 'data\logs'
        $newest = Get-ChildItem -Path $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $lenBefore = if ($newest) { $newest.Length } else { 0 }
        $cpuBefore = 0.0
        foreach ($procId in $ids) {
            $pr = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($pr) { $cpuBefore += $pr.CPU }
        }
        Write-Log ("进程还在（年龄 {0}s），观察 90s 并采样 CPU/日志活动 ..." -f [int]$ageSec)

        $recovered = $false
        for ($i = 0; $i -lt 6; $i++) {
            if (Wait-Up 15) { $recovered = $true; break }
        }
        if ($recovered) { Write-Log '端口已恢复'; continue }

        $cpuAfter = 0.0
        foreach ($procId in $ids) {
            $pr = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($pr) { $cpuAfter += $pr.CPU }
        }
        $newest2 = Get-ChildItem -Path $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $lenAfter = if ($newest2) { $newest2.Length } else { 0 }
        $cpuDelta = [Math]::Round($cpuAfter - $cpuBefore, 2)
        $logDelta = $lenAfter - $lenBefore
        Write-Log ("观察 90s 端口仍未恢复（CPU +{0}s，日志 +{1}B，进程年龄 {2}s）" -f $cpuDelta, $logDelta, [int]$ageSec)

        if ($ageSec -lt $BOOT_WAIT -and $cpuDelta -gt 0) {
            Write-Log '进程仍在初始化（未满 BOOT_WAIT 且 CPU 有增长），本轮不杀，下一轮再判断'
            continue
        }

        Write-Log '判定为僵死（端口长时间不回且已过初始化期），强制结束进程'
        $proc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
    }

    $failStreak++
    if ($failStreak -gt 1) {
        $backoff = [Math]::Min(60 * $failStreak, 300)
        Write-Log "连续第 $failStreak 次拉起失败，退避 ${backoff}s"
        Start-Sleep -Seconds $backoff
    }

    [void](Start-Bot)
    if (Wait-Up $BOOT_WAIT) {
        Write-Log '恢复成功'
        $script:Restarts++
        Write-BotState 'online' 'restarted by watchdog'
        $failStreak = 0
    } else {
        Write-Log '恢复失败（端口未起来），下轮重试'
        Write-BotState 'failed' 'restart did not bring the port up'
    }
}
