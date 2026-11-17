#Requires -Version 5.1
<#
.SYNOPSIS
    比较两次 kick-report 快照，判断某个改动（例如 o3HookMode 1->0）有没有让会话活得更久。

.DESCRIPTION
    "为什么还是掉线" 不是判断实验成败的正确指标 —— 只要腾讯的票据策略不变，
    掉线本身几乎必然发生。真正该看的是**每次登录能活多久**：
    会话时长的中位数有没有变大。

    用法是三步：
        1) 改配置之前：  .\kick-report.ps1 -Json | Set-Content baseline.json -Encoding UTF8
        2) 观察 24–48 小时，让改动生效
        3) 再取一次：    .\kick-report.ps1 -Json | Set-Content after.json -Encoding UTF8
           .\experiment-compare.ps1 -Before baseline.json -After after.json

    判断规则（保守，宁可说"没变化"也不夸大）：
        - 两侧样本都 >= -MinSamples 才下结论，否则报"样本不足"；
        - 中位数提升 >= -MinDeltaMin 分钟且 >= 15% 才判 "improved"；
        - 中位数下降 >= -MinDeltaMin 分钟且 >= 15% 才判 "worse"；
        - 其余都判 "no clear change"（此时应该把实验配置改回去，不要加码折腾）。

.PARAMETER Before
    实验前的 kick-report -Json 快照。

.PARAMETER After
    实验后的同格式快照。

.PARAMETER MinSamples
    每一侧至少要有多少次被踢才给结论，默认 4。

.PARAMETER MinDeltaMin
    中位数至少要变化多少分钟才算"有效果"，默认 15。

.EXAMPLE
    .\experiment-compare.ps1 -Before D:\napcat\baseline.json -After D:\napcat\after.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Before,
    [Parameter(Mandatory = $true)][string]$After,
    [int]$MinSamples = 4,
    [double]$MinDeltaMin = 15
)

$ErrorActionPreference = 'Stop'

function Read-Snapshot([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "snapshot not found: $path" }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj.PSObject.Properties['median']) {
        throw "not a kick-report JSON snapshot (missing 'median'): $path"
    }
    return $obj
}

$b = Read-Snapshot $Before
$a = Read-Snapshot $After

$fmt = { param($v) if ($null -eq $v) { 'n/a' } else { '{0}' -f $v } }

Write-Host ''
Write-Host '  kick-report 快照对比' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
Write-Host ('  {0,-14}{1,12}{2,12}' -f '', 'before', 'after')
Write-Host ('  {0,-14}{1,12}{2,12}' -f '被踢次数', $b.count, $a.count)
Write-Host ('  {0,-14}{1,12}{2,12}' -f '会话中位数(分)', (& $fmt $b.median), (& $fmt $a.median))
Write-Host ('  {0,-14}{1,12}{2,12}' -f 'p90(分)', (& $fmt $b.p90), (& $fmt $a.p90))
Write-Host ('  {0,-14}{1,12}{2,12}' -f 'min/max', ("{0}/{1}" -f $b.min, $b.max), ("{0}/{1}" -f $a.min, $a.max))
Write-Host ('  {0,-14}{1,12}{2,12}' -f 'median±15占比', ("$($b.nearPct)%"), ("$($a.nearPct)%"))

# --- 恢复耗时（如果有） ---
function Get-RecoverMedian($snap) {
    $vals = @()
    if ($snap.PSObject.Properties['sessions']) {
        $vals = @($snap.sessions | Where-Object { $null -ne $_.recoverSec } | ForEach-Object { [double]$_.recoverSec })
    }
    if ($vals.Count -eq 0) { return $null }
    $s = $vals | Sort-Object
    $mid = [int][Math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$mid] }
    return [Math]::Round(($s[$mid - 1] + $s[$mid]) / 2, 1)
}
$bRec = Get-RecoverMedian $b
$aRec = Get-RecoverMedian $a
if ($null -ne $bRec -or $null -ne $aRec) {
    Write-Host ('  {0,-14}{1,12}{2,12}' -f '恢复耗时中位(秒)', (& $fmt $bRec), (& $fmt $aRec))
}

# --- 结论 ---
Write-Host ''
if ($b.count -lt $MinSamples -or $a.count -lt $MinSamples) {
    Write-Host ("  [样本不足] 需要两侧各 >= {0} 次被踢，当前 {1} / {2}。继续观察。" -f $MinSamples, $b.count, $a.count) -ForegroundColor Yellow
    exit 0
}

$delta = [double]$a.median - [double]$b.median
$pct = if ([double]$b.median -gt 0) { [Math]::Round(100 * $delta / [double]$b.median, 1) } else { 0 }
$sign = if ($delta -ge 0) { '+' } else { '' }

Write-Host ("  中位数变化：{0}{1} 分钟（{2}{3}%）" -f $sign, $delta, $sign, $pct)

if ($delta -ge $MinDeltaMin -and $pct -ge 15) {
    Write-Host '  [improved] 会话明显变长，这个改动值得保留。' -ForegroundColor Green
    Write-Host '  下一步：继续观察 24 小时，若维持则更新 README 的基线数字。' -ForegroundColor Gray
} elseif ($delta -le (-1 * $MinDeltaMin) -and $pct -le -15) {
    Write-Host '  [worse] 会话反而更短了，建议把实验配置改回去。' -ForegroundColor Red
} else {
    Write-Host '  [no clear change] 差异在噪声范围内，没有证据表明这个改动有效。' -ForegroundColor Yellow
    Write-Host '  建议：把这次实验改动的那一项改回原值（o3HookMode 实验用 .\scripts\research\set-o3hookmode.ps1 -Mode 1 -Apply），别再叠加变量。' -ForegroundColor Gray
}
