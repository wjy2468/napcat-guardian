<#
.SYNOPSIS
    Check that the scripts in the repository match the ones actually running in production.

.DESCRIPTION
    The repository copies are sanitised (placeholders instead of the operator's
    QQ number / WebUI token) and one file uses a self-relative log path, so a
    plain file hash never matches.  This script normalises those known and
    intended differences and then compares line by line.

    Anything else that differs is drift: the repository would hand a user a
    script that behaves differently from the one that has been tested.

.PARAMETER Repo
    Repository root. Defaults to the parent directory of this script.

.PARAMETER Root
    Production root that contains guardian.ps1, astrbot_watchdog.ps1 and qrsync\.

.EXAMPLE
    .\check-sync.ps1

.EXAMPLE
    .\check-sync.ps1 -Root 'D:\napcat' -Json
#>
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Root = 'D:\napcat',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# production path -> repository path
$pairs = @(
    @{ Name = 'guardian.ps1';         Prod = Join-Path $Root 'guardian.ps1';         Repo = Join-Path $RepoRoot 'scripts\guardian.ps1' }
    @{ Name = 'astrbot_watchdog.ps1'; Prod = Join-Path $Root 'astrbot_watchdog.ps1'; Repo = Join-Path $RepoRoot 'scripts\astrbot_watchdog.ps1' }
    @{ Name = 'daemon.ps1';           Prod = Join-Path $Root 'qrsync\daemon.ps1';    Repo = Join-Path $RepoRoot 'scripts\qrsync\daemon.ps1' }
    @{ Name = 'qrsync.js';            Prod = Join-Path $Root 'qrsync\qrsync.js';    Repo = Join-Path $RepoRoot 'scripts\qrsync\qrsync.js' }
)

# Lines that are expected to differ (placeholders and deliberately different paths).
$ignorePatterns = @(
    'YOUR_BOT_QQ'
    'YOUR_WEBUI_TOKEN'
    'YOUR_SMTP_AUTH_CODE'
    '\$ASTRBOT_DIR\s*='
    '\$LOG_FILE\s*='
    'C:\\path\\to\\astrbot'
)

function Test-Ignored([string]$Line) {
    foreach ($p in $ignorePatterns) {
        if ($Line -match $p) { return $true }
    }
    return $false
}

function Get-ComparableLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    # files written with UTF-8 BOM keep the BOM as U+FEFF on the first line
    $text = $text.TrimStart([char]0xFEFF)
    # normalise placeholders that the repository uses instead of real values
    $text = $text -replace 'YOUR_BOT_QQ', '3888169425'
    $text = $text -replace 'YOUR_WEBUI_TOKEN', 'REDACTED'
    $text = $text -replace "`r`n", "`n"
    return @($text -split "`n" | Where-Object { -not (Test-Ignored $_) })
}

$results = @()
foreach ($pair in $pairs) {
    $prodLines = Get-ComparableLines $pair.Prod
    $repoLines = Get-ComparableLines $pair.Repo

    $entry = [ordered]@{
        file    = $pair.Name
        status  = ''
        detail  = ''
        prodLen = if ($null -eq $prodLines) { -1 } else { $prod.Count }
        repoLen = if ($null -eq $repoLines) { -1 } else { $repoLines.Count }
    }

    if ($null -eq $prodLines) {
        $entry.status = 'MISSING-PROD'
        $entry.detail = "not found: $($pair.Prod)"
    } elseif ($null -eq $repoLines) {
        $entry.status = 'MISSING-REPO'
        $entry.detail = "not found: $($pair.Repo)"
    } else {
        $max = [Math]::Max($prodLines.Count, $repoLines.Count)
        $firstDiff = 0
        $diffCount = 0
        for ($i = 0; $i -lt $max; $i++) {
            $a = if ($i -lt $prodLines.Count) { $prodLines[$i] } else { '<EOF>' }
            $b = if ($i -lt $repoLines.Count) { $repoLines[$i] } else { '<EOF>' }
            if ($a -ne $b) {
                $diffCount++
                if ($firstDiff -eq 0) { $firstDiff = $i + 1 }
            }
        }
        if ($diffCount -eq 0) {
            $entry.status = 'OK'
        } else {
            $entry.status = 'DRIFT'
            $entry.detail = "$diffCount differing line(s), first at comparable line $firstDiff"
        }
    }
    $results += $entry
}

if ($Json) {
    [ordered]@{
        at     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        repo   = $RepoRoot
        root   = $Root
        drift  = @($results | Where-Object { $_.status -ne 'OK' }).Count
        files  = $results
    } | ConvertTo-Json -Depth 5
} else {
    Write-Output ''
    Write-Output ("{0,-22} {1,-12} {2}" -f 'FILE', 'STATUS', 'DETAIL')
    Write-Output ("{0,-22} {1,-12} {2}" -f ('-' * 22), ('-' * 12), ('-' * 40))
    foreach ($r in $results) {
        Write-Output ("{0,-22} {1,-12} {2}" -f $r.file, $r.status, $r.detail)
    }
    Write-Output ''
    $bad = @($results | Where-Object { $_.status -ne 'OK' }).Count
    if ($bad -eq 0) {
        Write-Output '[OK] repository scripts match production (after normalising placeholders)'
    } else {
        Write-Output "[WARN] $bad file(s) out of sync - regenerate the repository copy before tagging a release"
    }
}

exit $bad
