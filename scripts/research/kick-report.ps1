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

.PARAMETER Json
    Print the same data as JSON instead of a table (use it to snapshot a baseline
    before an experiment and feed experiment-compare.ps1).

.PARAMETER GuardianLog
    guardian.log, used to measure how long the recovery actually took
    (kick -> recovery start -> logged in again).

.EXAMPLE
    .\kick-report.ps1
    .\kick-report.ps1 -Days 3
#>
[CmdletBinding()]
param(
    [string]$LogDir = 'D:\napcat\NapCat.Shell\logs',
    [string]$KickLog = 'D:\napcat\kick.log',
    [string]$GuardianLog = 'D:\napcat\guardian.log',
    [int]$Days = 0,
    [switch]$Json
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

# guardian.log gives us the other half of the story: how long the recovery took.
# Written format: [yyyy-MM-dd HH:mm:ss] message
$gEvents = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $GuardianLog) {
    foreach ($ln in (Get-Content -LiteralPath $GuardianLog -ErrorAction SilentlyContinue)) {
        if ($ln -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s+(.*)$') {
            $at = $null
            try { $at = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { }
            if ($null -ne $at) {
                [void]$gEvents.Add([pscustomobject]@{ At = $at; Text = $Matches[2] })
            }
        }
    }
}

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

    # --- recovery timing (needs guardian.log) ---
    $detectSec = $null
    $recoverSec = $null
    $path = ''
    if ($gEvents.Count -gt 0) {
        $from = $kick.AddMinutes(-1)
        $to = $kick.AddMinutes(40)
        $win = @($gEvents | Where-Object { $_.At -ge $from -and $_.At -le $to })
        $rec = $win | Where-Object { $_.Text -match 'Recovery attempt #' } | Select-Object -First 1
        $skip = $win | Where-Object { $_.Text -match 'Phase A/B/C skipped|Phase A/B/C/D skipped' } | Select-Object -First 1
        $back = $win | Where-Object { $_.Text -match 'logged in\.|QR scanned - bot is back online' } | Select-Object -First 1
        if ($null -ne $skip) { $path = 'fast' }
        elseif ($win | Where-Object { $_.Text -match 'Phase A:' }) { $path = 'staged' }
        if ($null -ne $rec) { $detectSec = [int]($rec.At - $kick).TotalSeconds }
        if ($null -ne $back) { $recoverSec = [int]($back.At - $kick).TotalSeconds }
    }

    [void]$rows.Add([pscustomobject]@{
        Kicked     = $key
        Log        = $f.Name
        Session    = $sessMin
        Uptime     = ('{0:hh\:mm}' -f ($kick - $first))
        KickAt     = $kick
        DetectSec  = $detectSec
        RecoverSec = $recoverSec
        Path       = $path
        Ip         = $ip
    })
}

function Get-Median([double[]]$v) {
    if ($v.Count -eq 0) { return 0 }
    $s = $v | Sort-Object
    $mid = [int][Math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$mid] }
    return [Math]::Round(($s[$mid - 1] + $s[$mid]) / 2, 1)
}

if ($Json) {
    $js = @($rows | ForEach-Object { [double]$_.Session } | Sort-Object)
    $jcount = $js.Count
    $jmedian = if ($jcount -gt 0) { Get-Median $js } else { 0 }
    $jp90 = if ($jcount -eq 0) { 0 } elseif ($jcount -ge 10) { $js[[int][Math]::Floor($jcount * 0.9)] } else { $js[-1] }
    $jnear = if ($jcount -gt 0) { @($js | Where-Object { [Math]::Abs($_ - $jmedian) -le 15 }).Count } else { 0 }
    $perDay = [ordered]@{}
    foreach ($g in ($rows | Group-Object { $_.Kicked.Substring(0, 5) } | Sort-Object Name)) {
        $perDay[$g.Name] = $g.Count
    }
    [ordered]@{
        at        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        source    = $LogDir
        count     = $jcount
        median    = $jmedian
        p90       = $jp90
        min       = if ($jcount -gt 0) { $js[0] } else { 0 }
        max       = if ($jcount -gt 0) { $js[-1] } else { 0 }
        nearPct   = if ($jcount -gt 0) { [Math]::Round(100 * $jnear / $jcount) } else { 0 }
        perDay    = $perDay
        sessions  = @($rows | Sort-Object Kicked | ForEach-Object {
            [ordered]@{
                kicked     = $_.Kicked
                log        = $_.Log
                sessionMin = $_.Session
                detectSec  = $_.DetectSec
                recoverSec = $_.RecoverSec
                path       = $_.Path
                ip         = $_.Ip
            }
        })
    } | ConvertTo-Json -Depth 5
    return
}

if ($rows.Count -eq 0) {
    Write-Host 'No [KickedOffLine] events found.' -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host ('Kicked sessions: {0}' -f $rows.Count) -ForegroundColor Cyan
$rows | Sort-Object Kicked |
    Select-Object Kicked, Log, Session, Uptime, DetectSec, RecoverSec, Path, Ip |
    Format-Table -AutoSize

# Recovery latency: this is the number that says whether the fast path works.
$rec = @($rows | Where-Object { $null -ne $_.RecoverSec } | ForEach-Object { [double]$_.RecoverSec })
if ($rec.Count -gt 0) {
    $recSorted = $rec | Sort-Object
    Write-Host ''
    Write-Host ('Recovery latency (kick -> online), {0} of {1} kicks matched in guardian.log' -f $rec.Count, $rows.Count) -ForegroundColor Cyan
    Write-Host ('  min {0}s  median {1}s  max {2}s' -f $recSorted[0], (Get-Median $recSorted), $recSorted[-1])
    foreach ($p in ($rows | Group-Object Path | Where-Object { $_.Name })) {
        $vals = @($p.Group | Where-Object { $null -ne $_.RecoverSec } | ForEach-Object { [double]$_.RecoverSec } | Sort-Object)
        if ($vals.Count -gt 0) {
            Write-Host ('  path={0}: {1} kick(s), median {2}s' -f $p.Name, $vals.Count, (Get-Median $vals))
        }
    }
}

$sessions = $rows | ForEach-Object { $_.Session } | Sort-Object
$count = $sessions.Count

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
