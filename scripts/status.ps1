#Requires -Version 5.1
<#
.SYNOPSIS
    一眼看清 NapCat 机器人 + AstrBot + 看护的健康状况。

.DESCRIPTION
    只读脚本：不改任何文件、不发消息、不动 NapCat，可以在任何时候跑。
    数据来源：metrics.json / astrbot-state.json / qrsync\login-state.json /
    kick.log / guardian.heartbeat / 计划任务状态 / OneBot HTTP API。

.PARAMETER Root
    NapCat 根目录，默认 D:\napcat。

.PARAMETER Json
    输出 JSON（给别的脚本/监控用）而不是文本报表。

.EXAMPLE
    .\status.ps1
    .\status.ps1 -Json
#>
param(
    [string]$Root = 'D:\napcat',
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-AgeMinutes([string]$iso) {
    if (-not $iso) { return $null }
    try { return [int]((Get-Date) - [datetime]::Parse($iso)).TotalMinutes } catch { return $null }
}

$metrics   = Read-JsonFile (Join-Path $Root 'metrics.json')
$astrbot   = Read-JsonFile (Join-Path $Root 'astrbot-state.json')
$loginSt   = Read-JsonFile (Join-Path $Root 'qrsync\login-state.json')

# --- 看护心跳 ---
$hbPid = $null
$hbAgeMin = $null
$hbFile = Join-Path $Root 'guardian.heartbeat'
if (Test-Path -LiteralPath $hbFile) {
    $raw = (Get-Content -LiteralPath $hbFile -Raw -ErrorAction SilentlyContinue)
    if ($raw -match '^\s*(\d+)\|(.+?)\s*$') {
        $hbPid = [int]$Matches[1]
        $hbAgeMin = Get-AgeMinutes $Matches[2].Trim()
    }
}
$hbAlive = $false
if ($hbPid) { $hbAlive = [bool](Get-Process -Id $hbPid -ErrorAction SilentlyContinue) }

$task = $null
try { $task = (Get-ScheduledTask -TaskName 'NapCatGuardian' -ErrorAction Stop).State } catch { $task = 'missing' }

# --- OneBot ---
$online = $null
$good = $null
$apiError = ''
try {
    $st = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/get_status' -TimeoutSec 6
    if ($st.data) { $online = [bool]$st.data.online; $good = [bool]$st.data.good }
} catch { $apiError = $_.Exception.Message }

# --- 最近被踢 ---
$recentKicks = @()
if (Test-Path -LiteralPath (Join-Path $Root 'kick.log')) {
    # 注意：Get-Content 返回的是带 PSPath/PSDrive 的字符串对象，直接 ConvertTo-Json
    # 会把整个 D: 盘和 FileSystem provider 序列化进去（实测 12 MB）。必须转成纯 string。
    $recentKicks = @(Get-Content -LiteralPath (Join-Path $Root 'kick.log') -Tail 3 -Encoding UTF8 | ForEach-Object { [string]$_ })
}

# --- 结论 ---
$verdict = 'OK'
$reasons = New-Object System.Collections.ArrayList
if ($task -ne 'Running') { $verdict = 'ERROR'; [void]$reasons.Add("看护任务未运行（$task）") }
if ($null -eq $hbPid) {
    $verdict = 'ERROR'; [void]$reasons.Add("找不到心跳文件（$hbFile），看护可能从未启动")
}
elseif (-not $hbAlive) {
    $verdict = 'ERROR'; [void]$reasons.Add("看护进程不存在（心跳里的 PID $hbPid 已退出）")
}
elseif ($null -ne $hbAgeMin -and $hbAgeMin -gt 3) { $verdict = 'ERROR'; [void]$reasons.Add("看护心跳 $hbAgeMin 分钟未更新") }
if ($online -eq $false) {
    if ($verdict -ne 'ERROR') { $verdict = 'WARN' }
    [void]$reasons.Add('机器人当前离线（需要扫码或正在恢复）')
}
elseif ($online -eq $null -and $apiError) {
    if ($verdict -ne 'ERROR') { $verdict = 'WARN' }
    [void]$reasons.Add("OneBot API 不可达：$apiError")
}
if ($astrbot -and $astrbot.state -ne 'online') {
    if ($verdict -eq 'OK') { $verdict = 'WARN' }
    [void]$reasons.Add("AstrBot 状态为 $($astrbot.state)")
}
if ($loginSt -and $loginSt.state -eq 'need_scan') {
    if ($verdict -eq 'OK') { $verdict = 'WARN' }
    [void]$reasons.Add('登录态失效，等扫码')
}

if ($Json) {
    [ordered]@{
        at            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        verdict       = $verdict
        reasons       = @($reasons)
        guardian      = [ordered]@{ task = [string]$task; heartbeatPid = $hbPid; heartbeatAgeMin = $hbAgeMin; alive = $hbAlive }
        bot           = [ordered]@{ online = $online; good = $good; apiError = $apiError }
        session       = $metrics
        astrbot       = $astrbot
        loginState    = $loginSt
        recentKicks   = @($recentKicks)
    } | ConvertTo-Json -Depth 6
    return
}

# --- 文本报表 ---
$color = @{ OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }[$verdict]
Write-Host ''
Write-Host ('  NapCat 状态速览  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray

$botText = if ($online -eq $true) { '在线' } elseif ($online -eq $false) { '离线' } else { '不可达' }
Write-Host ('  机器人      ' + $botText + $(if ($good -eq $true) { '（good）' } else { '' })) -ForegroundColor $(if ($online -eq $true) { 'Green' } else { 'Yellow' })

if ($metrics) {
    $sess = if ($metrics.sessionMin -ge 0) { "$($metrics.sessionMin) 分钟" } else { '未登录' }
    Write-Host ('  本次登录    ' + $sess)
    Write-Host ('  今日被踢    ' + $metrics.kicksToday + ' 次' + $(if ($metrics.lastKick) { '，最近 ' + $metrics.lastKick } else { '' }))
    if ($metrics.lastRecoverSec -gt 0) {
        $how = ''
        if ($metrics.lastCause -and $metrics.lastPath) { $how = "（$($metrics.lastCause) / $($metrics.lastPath)）" }
        elseif ($metrics.lastPath) { $how = "（$($metrics.lastPath)）" }
        Write-Host ('  上次恢复    ' + $metrics.lastRecoverSec + ' 秒' + $how + ' @ ' + $metrics.lastRecoverAt)
    }
    Write-Host ('  下次探针    ' + $metrics.nextProbeAt)
}

Write-Host ('  看护        ' + $task + $(if ($hbPid) { "，心跳 $hbAgeMin 分钟前（PID $hbPid）" } else { '，无心跳文件' })) -ForegroundColor $(if ($hbAlive -and $hbAgeMin -le 3) { 'Green' } else { 'Red' })

if ($astrbot) {
    $abAge = Get-AgeMinutes $astrbot.at
    Write-Host ('  AstrBot     ' + $astrbot.state + '，pid ' + $astrbot.pid + '，重启 ' + $astrbot.restarts + ' 次，' + $abAge + ' 分钟前')
} else {
    Write-Host '  AstrBot     状态文件缺失（watchdog 没在写 astrbot-state.json）' -ForegroundColor Yellow
}

if ($loginSt) { Write-Host ('  登录状态    ' + $loginSt.state + ' — ' + $loginSt.note) }

if ($recentKicks.Count -gt 0) {
    Write-Host ''
    Write-Host '  最近被踢' -ForegroundColor DarkGray
    foreach ($k in $recentKicks) { Write-Host ('    ' + $k) -ForegroundColor DarkGray }
}

Write-Host ''
if ($reasons.Count -gt 0) {
    Write-Host ('  [' + $verdict + '] ' + ($reasons -join '；')) -ForegroundColor $color
} else {
    Write-Host '  [OK] 一切正常' -ForegroundColor Green
}
Write-Host ''
