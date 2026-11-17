# Network stability fix - disable WiFi adapter power saving.
# Must run as administrator.
# ----------------------------------------------------------
# A WiFi adapter is often allowed to "turn off to save power"
# while idle, which can cause brief disconnects (and a bot that
# briefly cannot send/receive). This script:
#   1) Finds the active WiFi adapter and disables "Allow the
#      computer to turn off this device to save power"
#      (PnPCapabilities = 0x18 / 24).
#   2) Sets the wireless adapter power saving to maximum
#      performance (if the driver exposes that setting).
#   3) Restarts the adapter so the change takes effect.
$ErrorActionPreference = "Stop"

# Adapter name (run `Get-NetAdapter` to see yours). Usually "WLAN".
$ADAPTER_NAME = "WLAN"
$log = Join-Path $PSScriptRoot "network_fix.log"
"=== network fix started ===" | Set-Content $log -Encoding ASCII

# --- verify administrator ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    "ERROR: not administrator" | Add-Content $log -Encoding ASCII
    Write-Host "Please run as administrator." -ForegroundColor Red
    exit 1
}

# 1) Locate the WiFi adapter's class registry key by matching its driver
#    description, then set PnPCapabilities = 24 (0x18):
#    bit 0x08 = disable power-down, bit 0x10 = disable wake-on-LAN.
$adapter = Get-NetAdapter -Name $ADAPTER_NAME -ErrorAction Stop
$driverDesc = $adapter.InterfaceDescription
"adapter: $driverDesc" | Add-Content $log -Encoding ASCII

$classBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
$found = $false
0..19 | ForEach-Object {
    $key = Join-Path $classBase ("{0:0000}" -f $_)
    if (Test-Path $key) {
        $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($p.DriverDesc -eq $driverDesc) {
            Set-ItemProperty -Path $key -Name "PnPCapabilities" -Value 24 -Type DWord
            "set PnPCapabilities = 24 on key " + ("{0:0000}" -f $_) | Add-Content $log -Encoding ASCII
            $script:found = $true
        }
    }
}
if (-not $found) { "WARNING: adapter class registry key not found" | Add-Content $log -Encoding ASCII }

# 2) Wireless adapter power saving -> maximum performance (if present).
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setactive SCHEME_CURRENT 2>$null
"powercfg wireless = max performance" | Add-Content $log -Encoding ASCII

# 3) Restart the WiFi adapter so the change takes effect.
Restart-NetAdapter -Name $ADAPTER_NAME -Confirm:$false
"restarted adapter" | Add-Content $log -Encoding ASCII

Start-Sleep -Seconds 8
"=== done ===" | Add-Content $log -Encoding ASCII
Write-Host "Network fix complete. WiFi power saving disabled." -ForegroundColor Green
