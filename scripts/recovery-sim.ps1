# recovery-sim.ps1 —— 恢复决策的行为级模拟测试（不碰 NapCat、不写生产日志）
#
# 为什么需要它：
#   2026-11-15 发现过两次"逻辑走不到"的 bug——被踢快速通道被僵尸态分支抢先、
#   等扫码判据用码龄而不是"码还在刷新"。这些都不是语法错误，-SelfTest 那种
#   单函数测试也覆盖不到，因为它们取决于 Do-Recovery 里各分支的先后顺序。
#
# 做法：把 guardian.ps1 的"函数定义部分"（Main 之前）dot-source 进来，
#   然后把所有会动系统的函数替换成桩（stub），再直接调用 Do-Recovery，
#   断言它返回了什么、日志里出现了哪些关键字。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\recovery-sim.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\recovery-sim.ps1 -Guardian D:\napcat\guardian.ps1
param(
    [string]$Guardian = (Join-Path $PSScriptRoot 'guardian.ps1'),
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Guardian)) { throw "guardian.ps1 not found: $Guardian" }

$src = [IO.File]::ReadAllText($Guardian, [Text.UTF8Encoding]::new($true))
$marker = '# ================= Main ================='
$i = $src.IndexOf($marker)
if ($i -lt 0) { throw 'main loop marker not found - is this guardian.ps1?' }
$body = $src.Substring(0, $i)

$tmp = Join-Path $env:TEMP ('napcat-sim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$bodyFile = Join-Path $tmp 'guardian-body.ps1'
[IO.File]::WriteAllText($bodyFile, $body, [Text.UTF8Encoding]::new($true))

# 沙箱化的路径：所有写文件的地方都落到临时目录
$fakeRoot = Join-Path $tmp 'root'
New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null

. $bodyFile

# ---- 桩：任何会动系统的函数都不许真的执行 ----
$script:SimLog = New-Object System.Collections.Generic.List[string]
function Write-Log { param([string]$m, [string]$level = 'INFO') $script:SimLog.Add([string]$m) }
function Write-Heartbeat { }
function Notify-Admin { $script:SimLog.Add('[stub] Notify-Admin') }
function Send-Notification { param($key, $title, $body, $priority) }
function Send-EmailNotification { param($subject, $body, $attach) }
function Write-Metrics { param([datetime]$nextProbe) }
function Set-BotState { param([string]$s, [string]$n) }

$script:Stub = @{
    WebUI      = $true
    Online     = $false
    Login      = @{ login = $false; err = ''; qr = '' }
    Launch     = 'online'
    WaitLogin  = $false
    WaitScan   = $false
}
function Test-WebUI { return $script:Stub.WebUI }
function Get-Online { return $script:Stub.Online }
function Get-LoginStatus { return $script:Stub.Login }
function Test-ForeignQq { return $null }
function Launch-NapCat { $script:SimLog.Add('[stub] Launch-NapCat'); return $script:Stub.Launch }
function Wait-Login { param([int]$Seconds) $script:SimLog.Add('[stub] Wait-Login'); return $script:Stub.WaitLogin }
function Wait-Scan {
    $script:SimLog.Add('[stub] Wait-Scan')
    if ($script:Stub.WaitScan) { Set-BotState 'online' '已登录' }
    return $script:Stub.WaitScan
}
function Get-WebUIHeaders { return @{} }
function Invoke-RestMethod { param($Uri, $Method, $Headers, $TimeoutSec, $Body, $ContentType) }

# Do-Recovery 会读这些路径，全部指到临时目录
$script:QR_FILE = Join-Path $fakeRoot 'qrcode.png'
$script:LOG_FILE = Join-Path $fakeRoot 'guardian.log'
$script:KICK_LOG = Join-Path $fakeRoot 'kick.log'

$fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("  [PASS] " + $Name) }
    else { Write-Host ("  [FAIL] " + $Name + "  " + $Detail); $script:fail++ }
}

function New-Scenario {
    $script:SimLog.Clear()
    $script:KickSeen = $false
    $script:QrModeSince = [DateTime]::MinValue
    $script:ForeignSince = [DateTime]::MinValue
    $script:SendFailAts.Clear()
    $script:Stub = @{
        WebUI     = $true
        Online    = $false
        Login     = @{ login = $false; err = ''; qr = '' }
        Launch    = 'online'
        WaitLogin = $false
        WaitScan  = $false
    }
    if (Test-Path $script:QR_FILE) { Remove-Item $script:QR_FILE -Force }
}

Write-Host ''
Write-Host ('recovery-sim   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ('guardian:      ' + $Guardian)
Write-Host ('sandbox:       ' + $tmp)
Write-Host ''

# ---- 场景 1：被踢（loginError 也含"失效"，不能先走僵尸态分支）----
New-Scenario
$script:KickSeen = $true
$script:Stub.Login = @{ login = $false; err = '你的账号当前登录已失效，请重新登录。'; qr = 'https://x' }
$script:Stub.Launch = 'online'
$r1 = Do-Recovery
$joined1 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined1 }
Check 'kick → fast path (skips A/B/C)' (($r1 -eq 'online') -and ($joined1 -match 'Phase A/B/C skipped')) ("result=$r1")
Check 'kick → does NOT restart worker first' (-not ($joined1 -match 'Phase C: restart worker')) ("log=$joined1")

# ---- 场景 2：等扫码（码在刷新、未登录、无错误）→ 不重启，等扫 ----
New-Scenario
$script:Stub.Login = @{ login = $false; err = ''; qr = 'https://x' }
Set-Content -Path $script:QR_FILE -Value 'fake-png' -Encoding ASCII
(Get-Item $script:QR_FILE).LastWriteTime = (Get-Date)
$script:Stub.WaitScan = $true
$r2 = Do-Recovery
$joined2 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined2 }
Check 'qr waiting → wait_scan, no relaunch' (($r2 -eq 'online') -and ($joined2 -match 'QR mode') -and -not ($joined2 -match 'Launch-NapCat')) ("result=$r2")

# ---- 场景 3：僵尸态（没有 [KickedOffLine]，只 loginError 失效）→ 先重启 worker ----
New-Scenario
$script:KickSeen = $false
$script:Stub.Login = @{ login = $true; err = '登录态已失效，请重新登录。'; qr = '' }
$script:Stub.WaitLogin = $true
$r3 = Do-Recovery
$joined3 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined3 }
Check 'zombie → worker restart path' (($r3 -eq 'online') -and ($joined3 -match 'login session invalid')) ("result=$r3")

# ---- 场景 4：NapCat 没在跑 → 直接拉起 ----
New-Scenario
$script:Stub.WebUI = $false
$script:Stub.Launch = 'online'
$r4 = Do-Recovery
$joined4 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined4 }
Check 'webui down → launch directly' (($r4 -eq 'online') -and ($joined4 -match 'launching directly')) ("result=$r4")

# ---- 场景 5：真的需要扫码（重启后仍登录不了）→ 返回 need_scan ----
New-Scenario
$script:KickSeen = $true
$script:Stub.Login = @{ login = $false; err = '你的账号当前登录已失效，请重新登录。'; qr = '' }
$script:Stub.Launch = 'need_scan'
$r5 = Do-Recovery
$joined5 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined5 }
Check 'kick + expired ticket → need_scan' ($r5 -eq 'need_scan') ("result=$r5")
# ---- 场景 6：假在线（1006514）→ 只重启 worker，不杀 QQ ----
New-Scenario
$script:Stub.Login = @{ login = $true; err = ''; qr = '' }
$script:Stub.WaitLogin = $true
$script:SendFailAts.Add((Get-Date))
$r6 = Invoke-ConnectionReset
$joined6 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined6 }
Check 'sendfail → worker restart only' (($r6 -eq $true) -and ($joined6 -match 'send-fail detected') -and ($joined6 -match 'Wait-Login')) ("result=$r6")

# ---- 场景 7：桌面 QQ 开着 → 先让路（deferred），不抢机器人 ----
New-Scenario
$script:Stub.WebUI = $false
$script:ForeignSince = Get-Date
function Test-ForeignQq { return @(4242) }
$r7 = Do-Recovery
$joined7 = $script:SimLog -join ' | '
if ($VerboseLog) { Write-Host $joined7 }
Check 'desktop QQ running → deferred' (($r7 -eq 'deferred') -and ($joined7 -match 'deferring relaunch') -and -not ($joined7 -match 'Launch-NapCat')) ("result=$r7")
function Test-ForeignQq { return $null }

Write-Host ''
if ($fail -eq 0) { Write-Host 'RECOVERY-SIM PASSED (7 scenarios)'; $code = 0 }
else { Write-Host ('RECOVERY-SIM FAILED (' + $fail + ' problem(s))'); $code = 1 }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit $code
