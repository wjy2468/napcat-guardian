<#
.SYNOPSIS
    Capture a snapshot of everything needed to explain a drop, into one folder.

.DESCRIPTION
    When the bot goes offline the useful evidence is spread across six files and
    three log streams, and the interesting log lines get pushed out within hours.
    This script copies a consistent slice of all of it into one timestamped
    folder so a later analysis does not depend on guesswork.

    Read-only with respect to the running system: it only copies files and makes
    two HTTP queries.

.PARAMETER Root
    Deployment root (contains guardian.ps1, qrsync\, metrics.json ...).

.PARAMETER Out
    Output folder. Default: <Root>\incidents\yyyyMMdd-HHmmss

.PARAMETER TailLines
    How many lines to keep from each log tail.

.PARAMETER AstrBotDir
    AstrBot installation directory; used to locate data\logs\astrbot.log and data_v4.db.

.EXAMPLE
    .\incident-snapshot.ps1

.EXAMPLE
    .\incident-snapshot.ps1 -Root 'D:\napcat' -TailLines 400
#>
param(
    [string]$Root = 'D:\napcat',
    [string]$Out = '',
    [int]$TailLines = 200,
    [string]$AstrBotDir = ''
)

$ErrorActionPreference = 'Continue'

# Locate AstrBot without hard-coding a user name: prefer the path recorded in
# guardian.config.json (astrbotLog), then fall back to the conventional layout.
if ([string]::IsNullOrWhiteSpace($AstrBotDir)) {
    $cfgCandidate = Join-Path $Root 'guardian.config.json'
    if (Test-Path -LiteralPath $cfgCandidate) {
        try {
            $logPath = (Get-Content -LiteralPath $cfgCandidate -Raw | ConvertFrom-Json).astrbotLog
            if ($logPath) {
                # <astrbot>\data\logs\astrbot.log -> <astrbot>
                $AstrBotDir = Split-Path (Split-Path (Split-Path $logPath -Parent) -Parent) -Parent
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($AstrBotDir)) {
        $AstrBotDir = Join-Path $env:USERPROFILE 'qq-deepseek-bot\astrbot'
    }
}

if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $Root ('incidents\' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$written = New-Object System.Collections.ArrayList

function Save-Text([string]$Name, [string]$Text) {
    $path = Join-Path $Out $Name
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    [void]$written.Add([pscustomobject]@{ file = $Name; bytes = (Get-Item $path).Length })
}

function Save-JsonCopy([string]$Source) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $name = Split-Path $Source -Leaf
    Copy-Item -LiteralPath $Source -Destination (Join-Path $Out $name) -Force
    [void]$written.Add([pscustomobject]@{ file = $name; bytes = (Get-Item $Source).Length })
}

function Save-LogTail([string]$Source, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $lines = Get-Content -LiteralPath $Source -Tail $TailLines -ErrorAction SilentlyContinue
    Save-Text $Name (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

# ---------------------------------------------------------------- summary
$summary = New-Object System.Collections.ArrayList
[void]$summary.Add("snapshot at : " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))
[void]$summary.Add("root       : $Root")

$hb = Join-Path $Root 'guardian.heartbeat'
if (Test-Path -LiteralPath $hb) {
    $hbText = (Get-Content -LiteralPath $hb -Raw).Trim()
    [void]$summary.Add("heartbeat  : $hbText")
    $hbTime = $null
    if ($hbText -match '\|(.+)$') { $hbTime = $Matches[1] }
    if ($hbTime) {
        try {
            $age = [int]((Get-Date) - [datetime]::ParseExact($hbTime, 'yyyy-MM-ddTHH:mm:ss', $null)).TotalMinutes
            [void]$summary.Add("heartbeat age: $age min")
        } catch { }
    }
}

$task = Get-ScheduledTask -TaskName 'NapCatGuardian' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'NapCatGuardian' -ErrorAction SilentlyContinue
    [void]$summary.Add("task       : state=$([string]$task.State) lastResult=$($info.LastTaskResult) lastRun=$($info.LastRunTime)")
} else {
    [void]$summary.Add("task       : NOT REGISTERED")
}

$accepted = [System.Net.SecurityProtocolType]::Tls12
try {
    $st = Invoke-RestMethod 'http://127.0.0.1:3000/get_status' -TimeoutSec 5
    [void]$summary.Add("onebot     : status=$($st.status) retcode=$($st.retcode) online=$($st.data.online) good=$($st.data.good)")
} catch {
    [void]$summary.Add("onebot     : unreachable ($($_.Exception.Message))")
}

try {
    $cfgPath = Join-Path $Root 'guardian.config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cfg.webuiToken + '.napcat'))).Replace('-', '').ToLower()
        $cred = (Invoke-RestMethod 'http://127.0.0.1:6099/api/auth/login' -Method Post -TimeoutSec 8 `
            -Body (@{ hash = $hash; totpCode = $null } | ConvertTo-Json) -ContentType 'application/json').data.Credential
        $ls = Invoke-RestMethod 'http://127.0.0.1:6099/api/QQLogin/CheckLoginStatus' -Method Post -TimeoutSec 8 `
            -Headers @{ Authorization = 'Bearer ' + $cred }
        [void]$summary.Add("qq login   : isLogin=$($ls.data.isLogin) offline=$($ls.data.isOffline) err='$($ls.data.loginError)'")
    }
} catch {
    [void]$summary.Add("qq login   : query failed ($($_.Exception.Message))")
}

$napLogs = Get-ChildItem -LiteralPath (Join-Path $Root 'NapCat.Shell\logs') -Filter *.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($napLogs) {
    [void]$summary.Add("napcat logs:")
    foreach ($l in $napLogs) {
        [void]$summary.Add(("  {0}  {1:yyyy-MM-dd HH:mm:ss}  {2} B" -f $l.Name, $l.LastWriteTime, $l.Length))
    }
}

Save-Text 'summary.txt' (($summary -join [Environment]::NewLine) + [Environment]::NewLine)

# ---------------------------------------------------------------- state files
foreach ($name in @('metrics.json', 'kick.log', 'login-state.json', 'astrbot-state.json', 'tunnel-state.json', 'current-url.txt', 'key.txt', 'ntfy-down.until')) {
    Save-JsonCopy (Join-Path $Root $name)
}
Save-JsonCopy (Join-Path $Root 'qrsync\login-state.json')
Save-JsonCopy (Join-Path $Root 'qrsync\tunnel-state.json')

# ---------------------------------------------------------------- logs
Save-LogTail (Join-Path $Root 'guardian.log') 'guardian.log.tail.txt'
Save-LogTail (Join-Path $Root 'astrbot_watchdog.log') 'astrbot_watchdog.log.tail.txt'
Save-LogTail (Join-Path $Root 'qrsync\daemon.log') 'daemon.log.tail.txt'
Save-LogTail (Join-Path $Root 'daily-report.log') 'daily-report.log.tail.txt'

if ($napLogs) {
    foreach ($l in $napLogs) {
        Save-LogTail $l.FullName ("napcat-" + $l.Name + ".tail.txt")
    }
}

if ($AstrBotDir) {
    Save-LogTail (Join-Path $AstrBotDir 'data\logs\astrbot.log') 'astrbot.log.tail.txt'
}

# ---------------------------------------------------------------- scheduled tasks
$lines = Get-ScheduledTask | Where-Object { $_.TaskName -match 'NapCat|DSH|QRSync|ComfyUI|AstrBot' } |
    ForEach-Object {
        $i = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        "{0,-22} {1,-12} lastResult={2} lastRun={3}" -f $_.TaskName, [string]$_.State, $i.LastTaskResult, $i.LastRunTime
    }
Save-Text 'tasks.txt' (($lines -join [Environment]::NewLine) + [Environment]::NewLine)

# ---------------------------------------------------------------- report
Write-Output ''
Write-Output ("snapshot: {0}" -f $Out)
foreach ($w in $written) { Write-Output ("  {0,-34} {1,8} B" -f $w.file, $w.bytes) }
Write-Output ''
Write-Output ("{0} file(s), all evidence in one place." -f @($written).Count)

exit 0
