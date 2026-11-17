#Requires -Version 5.1
<#
.SYNOPSIS
    安装后的端到端自检：一条命令确认整条链路是不是真的通了。

.DESCRIPTION
    和 status.ps1 的区别：
        status.ps1   回答"现在健不健康"（给日常用）
        smoke-test   回答"装得对不对"（给刚部署完、或者改完配置之后用）

    它逐项检查：配置文件 / 计划任务 / 看护心跳 / metrics 新鲜度 /
    本地扫码服务 / 公网扫码页 / OneBot 在线 / NapCat WebUI 鉴权 /
    AstrBot 端口与状态文件。只读，不发消息、不重启任何东西。

    退出码 = 失败项数（0 = 全过），方便放进脚本或任务里。

.PARAMETER Root
    NapCat 根目录，默认 D:\napcat。

.PARAMETER Config
    guardian.config.json 路径，默认 $Root\guardian.config.json。

.PARAMETER SkipPublic
    跳过公网扫码页检查（比如隧道没开、或者你在墙外）。

.PARAMETER Json
    输出 JSON。

.EXAMPLE
    .\smoke-test.ps1
    .\smoke-test.ps1 -SkipPublic -Json
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\napcat',
    [string]$Config = '',
    [switch]$SkipPublic,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
# 本机代理配置可能把 localhost 请求错误地送往失效端口；自检全部直连。
[System.Net.WebRequest]::DefaultWebProxy = $null
if (-not $Config) { $Config = Join-Path $Root 'guardian.config.json' }

$results = New-Object System.Collections.ArrayList
function Add-Result([string]$name, [string]$status, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Check = $name; Status = $status; Detail = $detail })
}

# ---------- 1. 配置文件 ----------
$cfg = $null
if (-not (Test-Path -LiteralPath $Config)) {
    Add-Result '配置文件' 'FAIL' "找不到 $Config"
} else {
    try {
        $cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
        $missing = @()
        if (-not $cfg.webuiToken -or $cfg.webuiToken -match 'YOUR_') { $missing += 'webuiToken' }
        if (-not $cfg.qrPageUrl) { $missing += 'qrPageUrl' }
        $hasChannel = ($cfg.notifyEmail -and $cfg.notifyEmail.user -and $cfg.notifyEmail.pass -and $cfg.notifyEmail.to) -or
                      ($cfg.notifyWebhook -and $cfg.notifyWebhook.url) -or
                      ($cfg.notifyNtfy -and $cfg.ntfyTopic)
        if (-not $hasChannel) { $missing += '通知通道(email/webhook/ntfy)' }
        if ($missing.Count -gt 0) {
            Add-Result '配置文件' 'WARN' ('缺少或未填: ' + ($missing -join ', '))
        } else {
            Add-Result '配置文件' 'PASS' "已加载 $Config"
        }
    } catch {
        Add-Result '配置文件' 'FAIL' ("解析失败: " + $_.Exception.Message)
    }
}

# ---------- 2. 计划任务 ----------
$task = $null
try {
    $task = Get-ScheduledTask -TaskName 'NapCatGuardian' -ErrorAction Stop
    if ($task.State -eq 'Running') { Add-Result '计划任务' 'PASS' 'NapCatGuardian Running' }
    else { Add-Result '计划任务' 'WARN' "NapCatGuardian 状态 $($task.State)（未运行）" }
} catch {
    Add-Result '计划任务' 'FAIL' '没有 NapCatGuardian（先跑 install_guardian.ps1）'
}

# ---------- 3. 看护心跳 ----------
$hbFile = Join-Path $Root 'guardian.heartbeat'
if (-not (Test-Path -LiteralPath $hbFile)) {
    Add-Result '看护心跳' 'FAIL' "找不到 $hbFile"
} else {
    $raw = Get-Content -LiteralPath $hbFile -Raw
    if ($raw -match '^\s*(\d+)\|(.+?)\s*$') {
        $hbPid = [int]$Matches[1]
        $hbAt = $null
        try { $hbAt = [datetime]::Parse($Matches[2].Trim()) } catch { }
        $ageMin = if ($hbAt) { [int]((Get-Date) - $hbAt).TotalMinutes } else { 999 }
        $alive = [bool](Get-Process -Id $hbPid -ErrorAction SilentlyContinue)
        if (-not $alive) { Add-Result '看护心跳' 'FAIL' "心跳里的 PID $hbPid 已退出" }
        elseif ($ageMin -gt 3) { Add-Result '看护心跳' 'FAIL' "心跳 $ageMin 分钟未更新" }
        else { Add-Result '看护心跳' 'PASS' "PID $hbPid，$ageMin 分钟前" }
    } else {
        Add-Result '看护心跳' 'FAIL' '心跳文件格式不对（应为 pid|时间）'
    }
}

# ---------- 4. metrics 新鲜度 ----------
$mf = Join-Path $Root 'metrics.json'
if (-not (Test-Path -LiteralPath $mf)) {
    Add-Result 'metrics.json' 'WARN' '还没生成（守护刚启动会在 20 秒内写）'
} else {
    try {
        $mt = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [int]((Get-Date) - [datetime]::Parse($mt.at)).TotalMinutes
        if ($age -gt 3) { Add-Result 'metrics.json' 'WARN' "$age 分钟未更新" }
        else { Add-Result 'metrics.json' 'PASS' ("state=" + $mt.state + "，sessionMin=" + $mt.sessionMin) }
    } catch {
        Add-Result 'metrics.json' 'FAIL' ('解析失败: ' + $_.Exception.Message)
    }
}

# ---------- 5. 本地扫码服务 ----------
$localOk = $false
if ($cfg -and $cfg.qrPageUrl -and ($cfg.qrPageUrl -match 'k=([^&]+)')) {
    $key = $Matches[1]
    try {
        $st = Invoke-RestMethod ("http://127.0.0.1:8430/status?k=" + $key) -TimeoutSec 8
        $localOk = $true
        Add-Result '本地扫码服务' 'PASS' ("state=" + $st.state + "，bot=" + $st.bot.state)
    } catch {
        Add-Result '本地扫码服务' 'FAIL' ('127.0.0.1:8430 不可达: ' + $_.Exception.Message)
    }
} else {
    Add-Result '本地扫码服务' 'WARN' '配置里没有可用的 qrPageUrl（含 ?k=）'
}

# ---------- 6. 公网扫码页 ----------
if ($SkipPublic) {
    Add-Result '公网扫码页' 'SKIP' '按 -SkipPublic 跳过'
} elseif ($cfg -and $cfg.qrPageUrl) {
    try {
        $u = [Uri]$cfg.qrPageUrl
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 20 -Headers @{ 'ngrok-skip-browser-warning' = '1' }
        if ($r.StatusCode -eq 200) { Add-Result '公网扫码页' 'PASS' ("HTTP 200，" + $r.RawContentLength + ' B') }
        else { Add-Result '公网扫码页' 'WARN' ("HTTP " + $r.StatusCode) }
    } catch {
        Add-Result '公网扫码页' 'FAIL' ('不可达: ' + $_.Exception.Message)
    }
} else {
    Add-Result '公网扫码页' 'SKIP' '没有配置 qrPageUrl'
}

# ---------- 7. OneBot 在线 ----------
try {
    $gs = Invoke-RestMethod 'http://127.0.0.1:3000/get_status' -TimeoutSec 8
    $online = $gs.data.online
    if ($online -eq $true) { Add-Result 'OneBot API' 'PASS' ("online=true good=" + $gs.data.good) }
    else { Add-Result 'OneBot API' 'WARN' ("online=" + $online + "（未登录？）") }
} catch {
    Add-Result 'OneBot API' 'FAIL' ('127.0.0.1:3000 不可达: ' + $_.Exception.Message)
}

# ---------- 8. NapCat WebUI 鉴权 ----------
if ($cfg -and $cfg.webuiToken) {
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cfg.webuiToken + '.napcat'))).Replace('-', '').ToLower()
        $cred = (Invoke-RestMethod 'http://127.0.0.1:6099/api/auth/login' -Method Post `
                -Body (@{ hash = $hash; totpCode = $null } | ConvertTo-Json) `
                -ContentType 'application/json' -TimeoutSec 10).data.Credential
        if ($cred) { Add-Result 'NapCat WebUI' 'PASS' 'token 鉴权成功' }
        else { Add-Result 'NapCat WebUI' 'FAIL' '登录返回空 Credential' }
    } catch {
        Add-Result 'NapCat WebUI' 'FAIL' ('6099 鉴权失败: ' + $_.Exception.Message)
    }
} else {
    Add-Result 'NapCat WebUI' 'SKIP' '没有 webuiToken'
}

# ---------- 9. AstrBot ----------
$ab = $null
$abFile = Join-Path $Root 'astrbot-state.json'
if (Test-Path -LiteralPath $abFile) {
    try { $ab = Get-Content -LiteralPath $abFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$listening = [bool](Get-NetTCPConnection -LocalPort 6185 -State Listen -ErrorAction SilentlyContinue)
if ($ab -and $ab.state -eq 'online' -and $listening) {
    Add-Result 'AstrBot' 'PASS' ("online，pid " + $ab.pid + '，6185 在听')
} elseif ($listening) {
    Add-Result 'AstrBot' 'WARN' '6185 在听，但状态文件缺失或不是 online'
} else {
    Add-Result 'AstrBot' 'WARN' '6185 没有监听（AstrBot 没在跑？）'
}

# ---------- 10. 日报配置 ----------
# 这组键缺失不会让看护出问题，但日报会静默退化成「读取失败」——所以单独查一次。
$drDb    = [string]$cfg.astrbotDb
$drLog   = [string]$cfg.astrbotLog
$drTunnel = [string]$cfg.tunnelState
$missingKeys = @()
if (-not $drDb)     { $missingKeys += 'astrbotDb' }
if (-not $drLog)    { $missingKeys += 'astrbotLog' }
if (-not $drTunnel) { $missingKeys += 'tunnelState' }
if ($missingKeys.Count -gt 0) {
    Add-Result '日报配置' 'WARN' ('缺少 ' + ($missingKeys -join '/') + '，日报会显示「读取失败」')
} else {
    $bad = @()
    if (-not (Test-Path -LiteralPath $drDb))     { $bad += 'astrbotDb' }
    if (-not (Test-Path -LiteralPath $drLog))    { $bad += 'astrbotLog' }
    if (-not (Test-Path -LiteralPath $drTunnel)) { $bad += 'tunnelState' }
    if ($bad.Count -eq 0) {
        Add-Result '日报配置' 'PASS' 'astrbotDb / astrbotLog / tunnelState 都在'
    } else {
        Add-Result '日报配置' 'WARN' ('路径不存在：' + ($bad -join '、'))
    }
}
# ---------- 输出 ----------
$fails = @($results | Where-Object { $_.Status -eq 'FAIL' })

if ($Json) {
    [ordered]@{
        at      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        root    = $Root
        fails   = $fails.Count
        checks  = @($results)
    } | ConvertTo-Json -Depth 5
    exit $fails.Count
}

Write-Host ''
Write-Host '  NapCat 安装自检' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
$color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
foreach ($r in $results) {
    $tag = '{0,-4}' -f $r.Status
    Write-Host ('  [' + $tag + '] ' + $r.Check.PadRight(14) + $r.Detail) -ForegroundColor $color[$r.Status]
}
Write-Host ''
if ($fails.Count -eq 0) {
    Write-Host '  [OK] 全部通过' -ForegroundColor Green
} else {
    Write-Host ("  [FAIL] $($fails.Count) 项未通过——先看上面红色那几行") -ForegroundColor Red
}
exit $fails.Count
