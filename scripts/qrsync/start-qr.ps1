<#
  start-qr.ps1 —— 一条命令：本地起二维码网页 + 打一条公网隧道，手机在世任何地方都能扫。

  用法：
    powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\start-qr.ps1
    powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\start-qr.ps1 -Local   # 只开本地端口，不开隧道

  退出：Ctrl+C。脚本会把本地服务、隧道一起收干净。
#>
param(
  [int]$Port = 8430,
  [switch]$Local
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$nodeExe = (Get-Command node -ErrorAction Stop).Source
$keyFile = Join-Path $root 'key.txt'

# 二维码路径优先取 config.json（daemon.ps1 也读它），保持两个入口一致
$cfgPath = Join-Path $root 'config.json'
$qrFile = 'D:/napcat/NapCat.Shell/cache/qrcode.png'
if (Test-Path $cfgPath) {
  try {
    $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.qrFile) { $qrFile = "$($j.qrFile)" }
  } catch { Write-Host "config.json 解析失败，用默认二维码路径" -ForegroundColor Yellow }
}

if (-not (Test-Path $keyFile)) {
  $k = -join ((1..24) | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[(Get-Random -Maximum 62)] })
  Set-Content -Path $keyFile -Value $k -NoNewline -Encoding ascii
}
$key = (Get-Content $keyFile -Raw).Trim()

function Test-Port([int]$p) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p); $c.Close(); return $true } catch { return $false }
}

# ---------- 1) 本地服务 ----------
Write-Host "[1/2] 启动二维码服务 :$Port ..." -ForegroundColor Cyan
$env:PORT = "$Port"
$env:QR_FILE = $qrFile
$node = Start-Process -FilePath $nodeExe -ArgumentList (Join-Path $root 'qrsync.js') `
  -WorkingDirectory $root -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput (Join-Path $root 'server.out.log') `
  -RedirectStandardError  (Join-Path $root 'server.err.log')

for ($i = 0; $i -lt 40; $i++) { if (Test-Port $Port) { break }; Start-Sleep -Milliseconds 250 }
if (-not (Test-Port $Port)) { Write-Host "二维码服务没起来，看 $root\server.err.log" -ForegroundColor Red; exit 1 }

$localUrl = "http://127.0.0.1:$Port/?k=$key"
Write-Host "      本地可用: $localUrl" -ForegroundColor DarkGray

# ---------- 2) 公网隧道 ----------
$providers = @(
  @{ name = 'localhost.run'; exe = 'ssh.exe';
     args = @('-o','StrictHostKeyChecking=no','-o',"UserKnownHostsFile=$root\known_hosts",'-o','ServerAliveInterval=30','-o','ExitOnForwardFailure=yes','-R',"80:localhost:$Port",'nokey@localhost.run');
     regex = 'https://[a-z0-9]+\.lhr\.life' }
  @{ name = 'pinggy'; exe = 'ssh.exe';
     args = @('-p','443','-o','StrictHostKeyChecking=no','-o',"UserKnownHostsFile=$root\known_hosts",'-o','ServerAliveInterval=30','-o','ExitOnForwardFailure=yes','-R0',"localhost:$Port",'a.pinggy.io');
     regex = 'https?://[a-z0-9-]+\.(?:free\.)?pinggy\.link' }
)
$cf = Join-Path $root 'cloudflared.exe'
if (Test-Path $cf) {
  $providers += @{ name = 'cloudflare'; exe = $cf; args = @('tunnel','--url',"http://127.0.0.1:$Port",'--no-autoupdate'); regex = 'https://[a-z0-9-]+\.trycloudflare\.com' }
}

$tunnel = $null
$tunnelLog = $null
$tunnelBase = $null   # 显式记下真正建起来的那条隧道的地址，不再依赖 foreach 循环变量 $url 泄漏
if (-not $Local) {
  foreach ($p in $providers) {
    Write-Host "[2/2] 建立隧道（$($p.name)）..." -ForegroundColor Cyan
    $log = Join-Path $root "tunnel-$($p.name).log"
    Remove-Item $log, "$log.err" -Force -ErrorAction SilentlyContinue
    $tp = Start-Process -FilePath $p.exe -ArgumentList $p.args `
      -WorkingDirectory $root -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $url = $null
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Milliseconds 1500
      if ($tp.HasExited) { break }
      $txt = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)
      if ($txt -match $p.regex) { $url = $Matches[0]; break }
    }
    if ($url) { $tunnel = $tp; $tunnelLog = $log; $tunnelBase = $url; break }
    Write-Host "      $($p.name) 没拿到地址，换下一个" -ForegroundColor Yellow
    if (-not $tp.HasExited) { try { $tp.Kill() } catch {} }
  }
  if (-not $tunnel) { Write-Host "所有隧道都没建立成功，只能本地用：$localUrl" -ForegroundColor Red }
}

$publicUrl = if ($tunnelBase) { "$tunnelBase/?k=$key" } else { $localUrl }
# 不用 Set-Content -Encoding utf8：PS 5.1 会加 BOM 和结尾换行，把 URL 文件弄脏
[IO.File]::WriteAllText((Join-Path $root 'current-url.txt'), $publicUrl, (New-Object Text.ASCIIEncoding))
try { Set-Clipboard -Value $publicUrl } catch {}

Write-Host ""
Write-Host "  ==============================================" -ForegroundColor Green
Write-Host "   手机打开（已复制到剪贴板）：" -ForegroundColor Green
Write-Host "   $publicUrl" -ForegroundColor White
Write-Host "  ==============================================" -ForegroundColor Green
Write-Host "  扫完就按 Ctrl+C，隧道会一起关掉。" -ForegroundColor DarkGray
Write-Host ""

# ---------- 3) 看护：进程挂了就收尾 ----------
try {
  while ($true) {
    Start-Sleep -Seconds 2
    if ($node.HasExited) { Write-Host "二维码服务已退出（通常=已登录成功）" -ForegroundColor Yellow; break }
    if ($tunnel -and $tunnel.HasExited) { Write-Host "隧道断开，重新连一次…" -ForegroundColor Yellow; break }
  }
} finally {
  Write-Host "清理中..." -ForegroundColor DarkGray
  foreach ($p in @($node, $tunnel)) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }
}
