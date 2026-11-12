# ============================================================
#  AstrBot 看护脚本（用户级，普通权限运行）
#   - 每 30s 检查 WebUI 端口 6185 是否在听
#   - 掉线则用 python main.py 重新拉起（隐藏窗口，输出进 console 日志）
#   - 启动时若没在跑，也会立刻拉起（兼任开机自启）
#   - 日志：脚本同目录 astrbot_watchdog.log（>2MB 轮转为 .1）
#
#  与 guardian.ps1 的分工：
#   guardian 只管 NapCat（以最高权限运行）；AstrBot 带电脑操控类插件，
#   绝不能跑在管理员上下文里，所以由本脚本以普通用户身份看护。
#
#  开机自启：把本脚本的快捷方式丢进
#   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
#   目标：powershell.exe -NoProfile -WindowStyle Hidden -File "<本文件>"
# ============================================================

param(
    [switch]$Stop
)

$ErrorActionPreference = 'Continue'

# ---------------- Configuration ----------------
# ← 改成你的 AstrBot 根目录（含 main.py 的那一层）
$ASTRBOT_DIR   = 'C:\path\to\astrbot'
# ← 改成运行 AstrBot 的 python.exe
$PYTHON        = "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe"
$PORT          = 6185
$CHECK_SECONDS = 30
$BOOT_WAIT     = 150      # 拉起后最多等这么多秒让端口起来
$LOG_FILE      = Join-Path $PSScriptRoot 'astrbot_watchdog.log'
$MUTEX_NAME    = 'Local\astrbot-watchdog'
$MAX_LOG_BYTES = 2MB

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

# ---------------- 单实例 ----------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $MUTEX_NAME, [ref]$createdNew)
if (-not $createdNew) {
    if ($Stop) {
        Write-Log '收到 -Stop，但本实例不是主实例，退出'
    }
    exit 0
}

if ($Stop) {
    Write-Log '收到 -Stop，看护退出'
    $mutex.ReleaseMutex()
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

function Start-Bot {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $ASTRBOT_DIR "astrbot-console-$stamp.log"
    $errLog = Join-Path $ASTRBOT_DIR "astrbot-console-$stamp.err.log"
    try {
        $p = Start-Process -FilePath $PYTHON -ArgumentList 'main.py' `
            -WorkingDirectory $ASTRBOT_DIR -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        Write-Log "已拉起 AstrBot，PID=$($p.Id)，输出 $outLog"
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

$lastHeartbeat = Get-Date
$failStreak = 0

while ($true) {
    Start-Sleep -Seconds $CHECK_SECONDS

    # 心跳（每 10 分钟一条，避免日志无限增长）
    if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
        Write-Log "心跳：端口 $PORT $(if (Test-Port) { '正常' } else { '无监听' })"
        $lastHeartbeat = Get-Date
    }

    if (Test-Port) {
        $failStreak = 0
        continue
    }

    # 端口没了：可能是进程挂了，也可能是正在重启
    $proc = Get-BotProcesses
    Write-Log "检测到端口 $PORT 无监听（python 进程数：$(($proc | Measure-Object).Count)）"

    if ($proc) {
        Write-Log '进程还在但端口没起来，等待 20s 让启动流程完成'
        if (Wait-Up 20) { Write-Log '端口已恢复'; continue }
        Write-Log '端口仍未恢复，判定为僵死，强制结束进程'
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
        $failStreak = 0
    } else {
        Write-Log '恢复失败（端口未起来），下轮重试'
    }
}
