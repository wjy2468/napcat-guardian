<#
.SYNOPSIS
    Summarise every real [KickedOffLine] event from NapCat logs.

.DESCRIPTION
    Reads NapCat's own log files (and optionally kick.log written by guardian.ps1)
    and prints, for every login session that ended with a kick:

        start time | kick time | session minutes | quiet-before-kick | IP

    Why this exists: the question "why does my bot get kicked" cannot be answered
    from one log entry. You need the *session age at kick* to tell a short-lived
    ticket (a few minutes) from a ~2 hour TTL, and you need it across many kicks.

    Nothing here touches the running bot - it is a read-only analysis.

.PARAMETER LogDir
    NapCat log directory. Default: D:\napcat\NapCat.Shell\logs

.PARAMETER KickLog
    Optional kick.log produced by guardian.ps1 (used for the IP column).

.PARAMETER Days
    Only show kicks from the last N days (0 = all).

.EXAMPLE
    .\kick-report.ps1
    .\kick-report.ps1 -Days 3
#>
[CmdletBinding()]
param(
    [string]$LogDir = 'D:\napcat\NapCat.Shell\logs',
    [string]$KickLog = 'D:\napcat\kick.log',
    [int]$Days = 0
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $LogDir)) {
    Write-Host "Log directory not found: $LogDir" -ForegroundColor Red
    exit 1
}

# Kick lines look like:
#   11-15 12:38:10 [error] lepori | [KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。
$kickPattern = '\[KickedOffLine\]|\[下线通知\]'
# Every NapCat log line starts with "MM-dd HH:mm:ss"
$tsPattern = '^\s*(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})'

$cutoff = if ($Days -gt 0) { (Get-Date).AddDays(-$Days) } else { [DateTime]::MinValue }

# Optional IP lookup: kick.log is written by guardian right when it sees the kick.
$ipByTime = @{}
if (Test-Path $KickLog) {
    foreach ($ln in (Get-Content -LiteralPath $KickLog -ErrorAction SilentlyContinue)) {
        if ($ln -match 'at=([0-9]{2}-[0-9]{2} [0-9:]+)') {
            $at = $Matches[1]
            $ip = ''
            if ($ln -match 'ip=([^ |]+)') { $ip = $Matches[1] }
            $ipByTime[$at] = $ip
        }
    }
}

$rows = New-Object System.Collections.ArrayList

foreach ($f in (Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
    $first = $null
    $last = $null
    $kick = $null

    foreach ($ln in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
        if ($ln -match $tsPattern) {
            $ts = $null
            try {
                $ts = [datetime]('{0}-{1}-{2} {3}:{4}:{5}' -f (Get-Date).Year, $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5])
                # A December -> January boundary would make the year wrong; nudge it back.
                if ($ts -gt (Get-Date).AddDays(2)) { $ts = $ts.AddYears(-1) }
            } catch { }

            if ($null -ne $ts) {
                if ($null -eq $first) { $first = $ts }
                $last = $ts
            }
        }
        if ($ln -match $kickPattern) {
            if ($null -ne $last) { $kick = $last }
            else { $kick = $first }
            break   # one kick per session file is enough
        }
    }

    if ($null -eq $kick -or $null -eq $first) { continue }
    if ($kick -lt $cutoff) { continue }

    $sessMin = [int]($kick - $first).TotalMinutes
    $key = $kick.ToString('MM-dd HH:mm:ss')
    $ip = if ($ipByTime.ContainsKey($key)) { $ipByTime[$key] } else { '' }

    [void]$rows.Add([pscustomobject]@{
        Kicked  = $key
        Log     = $f.Name
        Session = $sessMin
        Uptime  = ('{0:hh\:mm}' -f ($kick - $first))
        Ip      = $ip
    })
}

if ($rows.Count -eq 0) {
    Write-Host 'No [KickedOffLine] events found.' -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host ('Kicked sessions: {0}' -f $rows.Count) -ForegroundColor Cyan
$rows | Sort-Object Kicked | Format-Table -AutoSize

$sessions = $rows | ForEach-Object { $_.Session } | Sort-Object
$count = $sessions.Count

function Get-Median([double[]]$v) {
    if ($v.Count -eq 0) { return 0 }
    $s = $v | Sort-Object
    $mid = [int][Math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$mid] }
    return [Math]::Round(($s[$mid - 1] + $s[$mid]) / 2, 1)
}

$median = Get-Median $sessions
$p90 = if ($count -ge 10) { $sessions[[int][Math]::Floor($count * 0.9)] } else { $sessions[-1] }

Write-Host ''
Write-Host 'Session length at kick (minutes)' -ForegroundColor Cyan
Write-Host ('  min {0}  median {1}  p90 {2}  max {3}' -f $sessions[0], $median, $p90, $sessions[-1])

# A tight cluster around one value means a fixed lifetime (TTL), not random drops.
# Use the share of sessions within +-15 min of the median: a couple of short
# "quick login reused an old ticket" sessions must not hide the cluster.
$near = @($sessions | Where-Object { [Math]::Abs($_ - $median) -le 15 }).Count
$nearPct = if ($count -gt 0) { [Math]::Round(100 * $near / $count) } else { 0 }
Write-Host ('  {0}% of sessions ended within 15 min of the median' -f $nearPct)
if ($median -gt 90 -and $nearPct -ge 60) {
    Write-Host '  -> sessions cluster tightly around a fixed lifetime: suspect a ticket TTL.' -ForegroundColor Yellow
} elseif ($median -lt 30) {
    Write-Host '  -> most sessions die within half an hour: suspect an immediate kick / login loop.' -ForegroundColor Yellow
} else {
    Write-Host '  -> no obvious fixed lifetime; look at the individual rows above.' -ForegroundColor Gray
}

Write-Host ''
Write-Host 'Per day' -ForegroundColor Cyan
$rows | Group-Object { $_.Kicked.Substring(0, 5) } | Sort-Object Name |
    ForEach-Object { '  {0}  {1}' -f $_.Name, $_.Count }
