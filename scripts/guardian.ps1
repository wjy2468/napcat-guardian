# ============================================================
#  NapCat Guardian - Keep-alive + Auto-recovery
#  ----------------------------------------------------------
#  Solves: a third-party QQ bot (NapCat) that is left idle gets
#  kicked offline by Tencent risk control ("account login has
#  expired"). Local API calls (get_status, ...) do NOT count as
#  protocol activity and cannot keep the session alive; only real
#  messages do.
#
#  This script:
#   1) Keep-alive: at random intervals, the bot sends a short
#      message to ITSELF (a private chat with its own QQ number),
#      which creates real protocol activity and disturbs nobody.
#   2) Watchdog: detects offline and recovers in staged, patient
#      steps (grace period -> quick login -> restart worker ->
#      full relaunch). Only the last step kills QQ.
#   3) If every automatic step fails (saved session expired),
#      it refreshes the QR code and pops up a window asking for a
#      manual scan.
#
#  Recommended: run the installer (install_guardian.bat) once as
#  administrator, which registers this as a HIGHEST-privilege
#  Scheduled Task that starts at logon.
# ============================================================

# ---------------- Configuration (EDIT THESE) ----------------
# Your QQ bot account number (the one NapCat logs in as).
$QQ_UIN     = "YOUR_BOT_QQ"

# Your own (admin) QQ number, used only for the failure popup text.
$ADMIN_UIN  = "YOUR_ADMIN_QQ"

# NapCat / AstrBot directories and the Python executable.
$NAPCAT_DIR = "D:\napcat\NapCat.Shell"
$ASTRBOT_DIR  = "C:\Users\YOUR_NAME\qq-deepseek-bot\astrbot"
$PYTHON_EXE   = "C:\Users\YOUR_NAME\AppData\Local\Programs\Python\Python314\python.exe"

# Local OneBot11 HTTP API and NapCat WebUI (defaults shown).
$HTTP_API   = "http://127.0.0.1:3000"
$WEBUI_API  = "http://127.0.0.1:6099"

# NapCat WebUI token (read it from NapCat config/webui.json).
$WEBUI_TOK  = "YOUR_WEBUI_TOKEN"

# Log file location.
$LOG_FILE   = "D:\napcat\guardian.log"

# Keep-alive interval range (seconds). A kick was observed after
# ~23 min of silence, so keep this well below it.
$KEEPALIVE_MIN = 600    # 10 min
$KEEPALIVE_MAX = 1000   # ~16.7 min

# Watchdog
$CHECK_INTERVAL   = 20    # seconds between status checks
$OFFLINE_LIMIT    = 2     # consecutive offline checks before recovery
$RECOVER_COOLDOWN = 300   # seconds between full recovery attempts
$MAX_RECOVER      = 3     # max full recoveries before waiting for a human

# Optional: add ffmpeg to PATH (needed by some AstrBot plugins).
# Leave as "" if you do not need it.
$FFMPEG_BIN = "D:\tools\ffmpeg\bin"

# Random natural-looking keep-alive messages (sent to self).
$KA_POOL = @(
    "ok",
    "in service",
    "still here",
    "check",
    "running",
    "alive",
    "good",
    "uptime check"
)

# ---------------- Logging ----------------
function Write-Log($msg)
{
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

# ---------------- WebUI auth (returns auth headers) ----------------
function Get-WebUIHeaders
{
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $raw = [System.Text.Encoding]::UTF8.GetBytes($WEBUI_TOK + ".napcat")
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($raw)).Replace("-","").ToLower()
    $body = @{ hash = $hash; totpCode = $null } | ConvertTo-Json
    $login = Invoke-RestMethod -Uri "$WEBUI_API/api/auth/login" -Method Post `
                -Body $body -ContentType "application/json" -TimeoutSec 15
    return @{ Authorization = "Bearer " + $login.data.Credential }
}

# ---------------- Check online via the local HTTP API ----------------
# Returns: $true / $false / $null (no response - worker likely dead)
function Get-Online
{
    try
    {
        $r = Invoke-RestMethod -Uri "$HTTP_API/get_status" -Method Post `
                -Body '{}' -ContentType "application/json" -TimeoutSec 10
        return [bool]$r.data.online
    }
    catch
    {
        return $null
    }
}

# ---------------- Recovery: staged, patient (least -> most disruptive) ----------------
# Returns $true if back online, $false if a manual QR scan is required.
function Do-Recovery
{
    # ---- Phase A: grace period. A brief network blip (WiFi/router) often
    # self-heals and the QQ client reconnects on its own. Do NOT kill it.
    Write-Log "Phase A: grace period, waiting for network self-heal (up to 90s) ..."
    for ($i = 0; $i -lt 6; $i++)
    {
        Start-Sleep -Seconds 15
        $o = Get-Online
        if ($o) { Write-Log "  self-healed during grace period."; return $true }
    }

    # ---- Phase B: in-process quick login (lightweight, no restart).
    # Covers a real kick whose saved session is still valid.
    Write-Log "Phase B: in-process quick login (2 tries) ..."
    for ($i = 0; $i -lt 2; $i++)
    {
        try
        {
            $h = Get-WebUIHeaders
            Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/SetQuickLogin" -Method Post `
                -Headers $h -Body "{`"uin`":`"$QQ_UIN`"}" -ContentType "application/json" `
                -TimeoutSec 30 | Out-Null
        }
        catch { Write-Log ("  quick login call error: " + $_.Exception.Message) }
        Start-Sleep -Seconds 15
        $o = Get-Online
        if ($o) { Write-Log "  quick login succeeded."; return $true }
    }

    # ---- Phase C: restart the worker (restarts NapCat, does NOT kill QQ).
    Write-Log "Phase C: restart worker (RestartNapCat) ..."
    try
    {
        $h = Get-WebUIHeaders
        Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RestartNapCat" -Method Post `
            -Headers $h -TimeoutSec 20 | Out-Null
    }
    catch { Write-Log ("  restart call error: " + $_.Exception.Message) }
    for ($i = 0; $i -lt 4; $i++)
    {
        Start-Sleep -Seconds 15
        $o = Get-Online
        if ($o) { Write-Log "  worker restart succeeded."; return $true }
    }

    # ---- Phase D: full relaunch (QQ frozen or gone). This is the most
    # disruptive step, so it runs last.
    Write-Log "Phase D: full relaunch with quick login ..."
    $qqRunning = Get-Process -Name "QQ" -ErrorAction SilentlyContinue
    if ($qqRunning)
    {
        Write-Log "  QQ process still exists; forcing full kill then relaunch ..."
        taskkill /f /im NapCatWinBootMain.exe 2>$null
        taskkill /f /im QQ.exe 2>$null
        Start-Sleep -Seconds 6
    }
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", `
        "cd /d `"$NAPCAT_DIR`" && launcher.bat $QQ_UIN" -WindowStyle Minimized
    for ($i = 0; $i -lt 5; $i++)
    {
        Start-Sleep -Seconds 15
        $o = Get-Online
        if ($o) { Write-Log "  full relaunch succeeded."; return $true }
    }

    Write-Log "  full relaunch did NOT come online; session likely expired."
    return $false
}

# ---------------- Notify admin (manual QR scan needed) ----------------
function Notify-Admin
{
    Write-Log "ALL AUTO RECOVERY FAILED - login session expired, manual QR scan required"
    # Refresh the QR code so the saved picture is the latest.
    try
    {
        $h = Get-WebUIHeaders
        Invoke-RestMethod -Uri "$WEBUI_API/api/QQLogin/RefreshQRcode" -Method Post `
            -Headers $h -TimeoutSec 15 | Out-Null
    } catch {}
    # Native Windows popup (msg.exe exists on most Windows editions).
    $msg = "NapCat bot ($QQ_UIN) is offline and could not auto-login. " +
           "Please scan the QR code in the NapCat window. " +
           "QR picture: $NAPCAT_DIR\cache\qrcode.png"
    try { msg.exe * $msg } catch {}
}

# ---------------- Ensure AstrBot is running (start if not) ----------------
function Ensure-AstrBot
{
    $py = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "python.exe" -and $_.CommandLine -match "main\.py"
    }
    if (-not $py)
    {
        Write-Log "AstrBot not running, starting it ..."
        $extraPath = ""
        if ($FFMPEG_BIN -ne "") { $extraPath = "set PATH=%PATH%;$FFMPEG_BIN && " }
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", `
            ("cd /d `"$ASTRBOT_DIR`" && " + $extraPath +
             "`"$PYTHON_EXE`" main.py") -WindowStyle Minimized
        Start-Sleep -Seconds 12
        Write-Log "AstrBot start command issued."
    }
}

# ---------------- Keep-alive: send one message to self ----------------
function Send-KeepAlive
{
    try
    {
        $text = $KA_POOL | Get-Random
        $msg = "{0}  {1}" -f (Get-Date -Format "HH:mm"), $text
        $body = @{ user_id = $QQ_UIN; message = $msg } | ConvertTo-Json
        $r = Invoke-RestMethod -Uri "$HTTP_API/send_private_msg" -Method Post `
                -Body $body -ContentType "application/json" -TimeoutSec 15
        if ($r.retcode -eq 0) { Write-Log ("keep-alive sent: " + $msg) }
        else { Write-Log ("keep-alive retcode: " + $r.retcode) }
    }
    catch { Write-Log ("keep-alive error: " + $_.Exception.Message) }
}

# ================= Main =================
Write-Log "============ Guardian started, monitoring $QQ_UIN ============"
Ensure-AstrBot
$offlineCount = 0
$recoverCount = 0
$lastRecover  = [DateTime]::MinValue
$nextKeepAlive = (Get-Date).AddSeconds((Get-Random -Min $KEEPALIVE_MIN -Max $KEEPALIVE_MAX))

while ($true)
{
    # ---- Keep-alive timing ----
    if ((Get-Date) -ge $nextKeepAlive)
    {
        $onlineNow = Get-Online
        if ($onlineNow) { Send-KeepAlive }
        # Schedule next keep-alive with a random interval.
        $nextKeepAlive = (Get-Date).AddSeconds((Get-Random -Min $KEEPALIVE_MIN -Max $KEEPALIVE_MAX))
    }

    # ---- Watchdog check ----
    $online = Get-Online
    if ($online)
    {
        if ($offlineCount -gt 0) { Write-Log "back online" }
        $offlineCount = 0
        $recoverCount = 0
    }
    else
    {
        $offlineCount++
        Write-Log ("offline detected (" + $offlineCount + "/" + $OFFLINE_LIMIT + ")")
    }

    if ($offlineCount -ge $OFFLINE_LIMIT)
    {
        $now = Get-Date
        $since = ($now - $lastRecover).TotalSeconds

        if ($recoverCount -ge $MAX_RECOVER)
        {
            Notify-Admin
            Write-Log ("reached MAX_RECOVER ($MAX_RECOVER); waiting 1 hour before retrying")
            Start-Sleep -Seconds 3600
            $recoverCount = 0
        }
        elseif ($recoverCount -gt 0 -and $since -lt $RECOVER_COOLDOWN)
        {
            # In cooldown; keep quiet.
        }
        else
        {
            $recoverCount++
            $lastRecover = Get-Date
            Write-Log ("========== Recovery attempt #" + $recoverCount + " ==========")
            Ensure-AstrBot

            $ok = Do-Recovery

            if ($ok) { Write-Log ("Recovery attempt #" + $recoverCount + " succeeded.") }
            else { Write-Log ("Recovery attempt #" + $recoverCount + " failed.") }
        }
        $offlineCount = 0
    }

    Start-Sleep -Seconds $CHECK_INTERVAL
}
