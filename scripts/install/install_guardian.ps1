# Install guardian as a Scheduled Task (highest privileges, at logon).
# Must be run as administrator. The installer locates guardian.ps1 next
# to itself, so you can put this folder anywhere.
$ErrorActionPreference = "Stop"

# Resolve paths relative to this script's folder.
$scriptDir = $PSScriptRoot
# guardian.ps1 在兄弟目录 runtime（仓库分层结构）；若同目录能找到则兼容旧的平铺放法。
$guardian = Join-Path $scriptDir "..\runtime\guardian.ps1"
if (-not (Test-Path -LiteralPath $guardian)) { $guardian = Join-Path $scriptDir "guardian.ps1" }
$guardian = [IO.Path]::GetFullPath($guardian)
$log      = Join-Path $scriptDir "install_guardian.log"
"=== install guardian started ===" | Set-Content $log -Encoding ASCII

# --- verify administrator ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    "ERROR: not running as administrator" | Add-Content $log -Encoding ASCII
    Write-Host "Please right-click install_guardian.bat and 'Run as administrator'." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $guardian)) {
    "ERROR: guardian.ps1 not found next to installer: $guardian" | Add-Content $log -Encoding ASCII
    exit 1
}

# --- Guardian task: keep-alive + watchdog (highest, at logon) ---
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guardian`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 2) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "NapCatGuardian" -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
"registered task: NapCatGuardian" | Add-Content $log -Encoding ASCII

# Note: guardian.ps1 starts NapCat (if not running) but deliberately does
# NOT start AstrBot - AstrBot holds desktop-control plugins and must run as
# a normal user. Use scripts\runtime\astrbot_watchdog.ps1 plus a Startup shortcut.

# --- Start the guardian now (no need to wait for the next logon) ---
Start-ScheduledTask -TaskName "NapCatGuardian"
"started guardian task now" | Add-Content $log -Encoding ASCII

"=== done ===" | Add-Content $log -Encoding ASCII
Write-Host "Install complete. Guardian is running and will auto-start on boot." -ForegroundColor Green
