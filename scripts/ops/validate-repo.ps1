<#
.SYNOPSIS
    Repository self-validation: encoding, syntax, JSON, JavaScript, Python and secret leaks.

.DESCRIPTION
    Every check here exists because it has actually broken this project at least once:

    * a .ps1 written without a UTF-8 BOM          -> Windows PowerShell 5.1 parses it as GBK and dies
    * a .ps1 with a stray brace                   -> the scheduled task exits with LastTaskResult 1
    * invalid JSON in an example config           -> users paste it and the bot will not start
    * a syntax error in qrsync.js                 -> the QR page 404s / the public link dies
    * a real QQ number or token left in a file    -> a public GitHub repository leaks credentials

    Runs offline, writes nothing to the repository (Python is compiled in memory only).

.PARAMETER Root
    Repository root. Defaults to the parent of this script.

.PARAMETER Json
    Emit a machine-readable report.

.EXAMPLE
    .\validate-repo.ps1

.EXAMPLE
    .\validate-repo.ps1 -Json
#>
param(
    [string]$Root = "",
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# 未显式指定时，从脚本目录向上找包含 .github 的目录作为仓库根。
# 这样脚本放在 scripts\ops 或旧的 scripts 平铺位置都能正确定位。
if (-not $Root) {
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path (Join-Path $d '.github'))) {
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { break }
        $d = $parent
    }
    if (-not (Test-Path (Join-Path $d '.github'))) { $d = Split-Path $PSScriptRoot -Parent }
    $Root = $d
}

$failures = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

function Add-Failure([string]$Check, [string]$File, [string]$Message) {
    [void]$failures.Add([ordered]@{ check = $Check; file = $File; message = $Message })
}

function Get-Relative([string]$Full) {
    $base = $Root.TrimEnd('\') + '\'
    if ($Full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $Full.Substring($base.Length) }
    return $Full
}

# ---------------------------------------------------------------- .ps1 checks
$psFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.ps1 |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\__pycache__\\' }

foreach ($f in $psFiles) {
    $rel = Get-Relative $f.FullName
    $bytes = [IO.File]::ReadAllBytes($f.FullName)

    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = $false
    if (-not $hasBom) {
        # a file that is pure ASCII is safe without a BOM; anything else is a trap
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        foreach ($ch in $text.ToCharArray()) { if ([int]$ch -gt 127) { $nonAscii = $true; break } }
        if ($nonAscii) {
            Add-Failure 'bom' $rel 'has non-ASCII text but no UTF-8 BOM (PS 5.1 will parse it as GBK)'
        } else {
            [void]$notes.Add("$rel is ASCII-only, BOM not required")
        }
    }

    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $first = $errors[0]
        Add-Failure 'syntax' $rel ("line {0}: {1}" -f $first.Extent.StartLineNumber, $first.Message)
    }
}

# ---------------------------------------------------------------- JSON checks
$jsonFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.json |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\' }

foreach ($f in $jsonFiles) {
    $rel = Get-Relative $f.FullName
    try {
        $raw = [IO.File]::ReadAllText($f.FullName, [Text.UTF8Encoding]::new($false)).TrimStart([char]0xFEFF)
        [void]($raw | ConvertFrom-Json)
    } catch {
        Add-Failure 'json' $rel $_.Exception.Message
    }
}

# ---------------------------------------------------------------- JavaScript
$node = Get-Command node -ErrorAction SilentlyContinue
$jsFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.js |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\' }

if (-not $node) {
    [void]$notes.Add('node not found - skipped JavaScript syntax check')
} else {
    foreach ($f in $jsFiles) {
        $rel = Get-Relative $f.FullName
        $out = & $node.Source --check $f.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { Add-Failure 'javascript' $rel (($out | Out-String).Trim()) }
    }
}

# ---------------------------------------------------------------- Python
$pythonExe = $null
$pythonCandidates = New-Object System.Collections.Generic.List[string]
foreach ($name in @('py.exe', 'python.exe', 'python')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { [void]$pythonCandidates.Add($cmd.Source) }
}
foreach ($candidate in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    (Join-Path $env:ProgramFiles 'Python314\python.exe'),
    (Join-Path $env:ProgramFiles 'Python313\python.exe'),
    (Join-Path $env:ProgramFiles 'Python312\python.exe')
)) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { [void]$pythonCandidates.Add($candidate) }
}
foreach ($candidate in $pythonCandidates | Select-Object -Unique) {
    try {
        $probe = (& $candidate -c 'import sys; sys.exit(0)' 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $probe -notmatch 'Failed to find real location') { $pythonExe = $candidate; break }
    } catch { }
}
$pyFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.py |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\__pycache__\\' }

if (-not $pythonExe) {
    [void]$notes.Add('runnable Python interpreter not found - skipped Python syntax check')
} else {
    # A helper file avoids the Windows command-line quoting rules that eat the
    # double quotes inside a python -c one-liner.  compile() only parses, so no
    # __pycache__ is ever written into the repository.
    $checker = Join-Path $env:TEMP 'napcat-guardian-pysyntax.py'
    $checkerSource = @(
        'import sys, pathlib'
        'bad = 0'
        'for p in sys.argv[1:]:'
        '    try:'
        '        compile(pathlib.Path(p).read_text(encoding="utf-8"), p, "exec")'
        '    except SyntaxError as e:'
        '        bad += 1'
        '        print(f"{p}:{e.lineno}: {e.msg}")'
        'sys.exit(1 if bad else 0)'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($checker, $checkerSource, [Text.UTF8Encoding]::new($false))

    foreach ($f in $pyFiles) {
        $rel = Get-Relative $f.FullName
        $out = & $pythonExe $checker $f.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { Add-Failure 'python' $rel (($out | Out-String).Trim()) }
    }
}

# ---------------------------------------------------------------- secret scan
# Assembled from fragments on purpose: if the literals were written out in full,
# this checker would report itself and every future copy of it.
$secretPatterns = @(
    ('3888' + '169425')
    ('8a91' + 'ccbb67a2')
    ('0uVJ' + 'kFHf')
    ('umax' + 'fzdjhcgjdhai')
    ('Jin' + ' Yang')
    ('2775' + '626803@')
    ('swampland' + '-abacus')
    ('tTWT' + 'j6')
    ('napcat' + '-jy-fmrlvqsxdi')
)

$textFiles = Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '\\\.git\\|\\node_modules\\|\\__pycache__\\' -and
        $_.Extension -in @('.ps1', '.py', '.js', '.md', '.json', '.bat', '.txt', '.yml', '.yaml', '.example')
    }

foreach ($f in $textFiles) {
    $rel = Get-Relative $f.FullName
    $text = [IO.File]::ReadAllText($f.FullName, [Text.UTF8Encoding]::new($false))
    foreach ($p in $secretPatterns) {
        if ($text.Contains($p)) {
            Add-Failure 'secret' $rel "contains a private value: $p"
        }
    }
}

# ---------------------------------------------------------------- report
$ok = $failures.Count -eq 0

if ($Json) {
    [ordered]@{
        at       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        root     = $Root
        ps1      = $psFiles.Count
        json     = $jsonFiles.Count
        js       = $jsFiles.Count
        py       = $pyFiles.Count
        failures = $failures
        notes    = $notes
        ok       = $ok
    } | ConvertTo-Json -Depth 6
} else {
    Write-Output ''
    Write-Output ("checked: {0} ps1, {1} json, {2} js, {3} py" -f $psFiles.Count, $jsonFiles.Count, $jsFiles.Count, $pyFiles.Count)
    foreach ($n in $notes) { Write-Output "  note: $n" }
    if ($ok) {
        Write-Output ''
        Write-Output '[OK] every check passed'
    } else {
        Write-Output ''
        foreach ($x in $failures) {
            Write-Output ("  [FAIL] {0,-10} {1}: {2}" -f $x.check, $x.file, $x.message)
        }
        Write-Output ''
        Write-Output ("[FAIL] {0} problem(s) found" -f $failures.Count)
    }
}

exit $failures.Count
