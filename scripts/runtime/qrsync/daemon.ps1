<#
  daemon.ps1 —— 二维码同步常驻守护（开机自启由计划任务 QRSyncDaemon 调起）

  职责：
    1. 保证本地 qrsync 服务一直活着（:8430）
    2. 保证公网隧道一直活着，断了自动重连（指数退避）
    3. 定期对公网 URL 做一次端到端自检，进程没死但连接假死也能拉起来
    4. 把当前公网地址写进 current-url.txt

  配置：config.json（port / qrFile / providers / ngrok.authToken+domain）

  手动跑（前台看日志）：
    powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\daemon.ps1
  停掉：
    powershell -ExecutionPolicy Bypass -File D:\napcat\qrsync\daemon.ps1 -Stop
#>
param([switch]$Stop)
# 本机代理配置可能把 localhost 请求错误地送往失效端口；看护的本地 API
# 与公网扫码端到端探测都必须直连，避免因此误判掉线或反复重建隧道。
[System.Net.WebRequest]::DefaultWebProxy = $null

# PowerShell 5.1 默认可能只协商 TLS1.0/1.1，而 ngrok 等现代 HTTPS 端点要求 TLS1.2+，
# 不显式打开会在长驻进程里以握手失败告终。SystemDefault 交给操作系统选最高可用版本。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault } catch {}

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $root 'daemon.log'
$cfgPath = Join-Path $root 'config.json'
$stateFile = Join-Path $root 'tunnel-state.json'

function Rotate-Log {
  if (Test-Path $logFile) {
    try { if ((Get-Item $logFile).Length -gt 2MB) { Move-Item $logFile "$logFile.1" -Force } } catch {}
  }
}

function Log([string]$msg, [string]$color = 'Gray') {
  $line = "{0}  {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg
  try { Add-Content -Path $logFile -Value $line -Encoding utf8 } catch {}
  Write-Host $line -ForegroundColor $color
}

# 把隧道健康状态落盘，供 guardian（有邮件通道）判断"公网扫码入口是否已经连不上"。
# 只写这四个字段，页面/脚本读起来不用猜。
function Write-State([string]$provider, [bool]$ok, [string]$url, [int]$streak = 0) {
  try {
    $o = [ordered]@{
      at         = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
      provider   = $provider
      ok         = $ok
      url        = $url
      failStreak = $streak
    }
    [IO.File]::WriteAllText($stateFile, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  }
  catch {}
}

Rotate-Log

# ---------- 停止 ----------
# 旧写法用 '-like *qrsync*' 匹配命令行，范围大得离谱：任何命令行里带 qrsync 字样的
# 进程（编辑器、资源管理器、正在这个目录里调试的终端）都会被无差别 Stop-Process；
# 而且它无条件杀掉机器上所有的 ngrok.exe / cloudflared.exe，把与项目无关的隧道一起干掉。
# 现在只认三件事：本文件路径、qrsync.js、指向本端口的隧道进程。
if ($Stop) {
  $stopPorts = New-Object System.Collections.ArrayList
  [void]$stopPorts.Add(8430)
  try {
    if (Test-Path $cfgPath) {
      $jc = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($jc.port) { [void]$stopPorts.Add([int]$jc.port) }
      if ([int]$jc.publicPort -gt 0) { [void]$stopPorts.Add([int]$jc.publicPort) }
    }
  } catch { }
  $stopPorts = @($stopPorts | Select-Object -Unique)
  $selfRe = [regex]::Escape((Join-Path $root 'daemon.ps1'))

  # node 用"脚本路径必须是最后一个参数"来卡：否则任何命令行里恰好带着 qrsync.js
  # 字样的进程（比如某个 -Command "..." 的一行脚本、调试器包装进程）都会被误杀。
  $nodeRe = '(?i)^"?[^"]*\bnode(\.exe)?"?\s+"?[^\s"]*\\qrsync\.js"?\s*$'

  $targets = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $cl = "$($_.CommandLine)"
      if ($_.ProcessId -eq $PID -or -not $cl) { return $false }
      if ($cl -match '\s-Stop\b') { return $false }
      if ($_.Name -match '^(powershell|pwsh)\.exe$') { return ($cl -match "-File\s+`"?$selfRe`"?\s*$") }
      if ($_.Name -eq 'node.exe') { return ($cl -match $nodeRe) }
      # ngrok http --url=... 8430 / cloudflared tunnel --url http://127.0.0.1:8430 / ssh -R ..:localhost:8430
      if ($_.Name -in @('ngrok.exe', 'cloudflared.exe', 'ssh.exe')) {
        foreach ($sp in $stopPorts) { if ($cl -match "(^|[\s:=])$sp(\s|$)") { return $true } }
        return $false
      }
      return $false
  })

  if ($targets.Count -eq 0) { Log '没有找到在跑的服务/隧道（可能已经停了）' 'Yellow' }
  foreach ($t in $targets) {
    try { Stop-Process -Id $t.ProcessId -Force; Log "已停止 $($t.Name) $($t.ProcessId)" } catch { }
  }
  Log '守护与隧道已停止' 'Yellow'
  exit 0
}

# ---------- 单实例 ----------
# 上一实例被强杀时 WaitOne 会抛 AbandonedMutexException：这其实是好事——
# 内核已经把互斥体交给了我们。旧的 `catch {}` 把"没抢到"和"抢到了但抛异常"
# 混在一起处理，于是可能出现两个守护同时跑、互相抢端口。
try {
  $mutex = New-Object System.Threading.Mutex($false, 'Local\qrsync-daemon')
  if (-not $mutex.WaitOne(0)) { Log '已有守护实例在跑，本次退出' 'Yellow'; exit 0 }
} catch [System.Threading.AbandonedMutexException] {
  Log '上一实例被强杀，接管互斥体继续' 'Yellow'
} catch {
  Log "互斥体不可用（$($_.Exception.Message)），继续运行" 'Yellow'
}

# ---------- 配置 ----------
$cfg = @{
  port = 8430
  qrFile = 'D:/napcat/NapCat.Shell/cache/qrcode.png'
  providers = @('ngrok', 'cloudflare', 'localhost.run', 'pinggy')
  ngrok = @{ authToken = ''; domain = '' }
  cloudflare = @{ namedTunnel = '' }
  healthCheckSeconds = 60
  publicPort = 0
  publicHealthPath = '/status'
}
if (Test-Path $cfgPath) {
  try {
    $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.port) { $cfg.port = [int]$j.port }
    if ($j.qrFile) { $cfg.qrFile = "$($j.qrFile)" }
    if ($j.providers) { $cfg.providers = @($j.providers | ForEach-Object { "$_" }) }
    if ($j.ngrok) { $cfg.ngrok = @{ authToken = "$($j.ngrok.authToken)"; domain = "$($j.ngrok.domain)" } }
    if ($j.cloudflare) { $cfg.cloudflare = @{ namedTunnel = "$($j.cloudflare.namedTunnel)" } }
    if ($j.healthCheckSeconds) { $cfg.healthCheckSeconds = [int]$j.healthCheckSeconds }
    if ($j.publicPort) { $cfg.publicPort = [int]$j.publicPort }
    if ($j.publicHealthPath) { $cfg.publicHealthPath = "$($j.publicHealthPath)" }
  } catch { Log "config.json 解析失败：$($_.Exception.Message)" 'Red' }
}
$port = [int]$cfg.port
$tunnelPort = $port
if ([int]$cfg.publicPort -gt 0) { $tunnelPort = [int]$cfg.publicPort }
$healthPath = "$($cfg.publicHealthPath)"
if (-not $healthPath) { $healthPath = '/status' }
$qrFile = $cfg.qrFile
$services = @($cfg.providers)
$healthEvery = [Math]::Max(30, [int]$cfg.healthCheckSeconds)

$keyFile = Join-Path $root 'key.txt'
if (-not (Test-Path $keyFile)) {
  $k = -join ((1..24) | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[(Get-Random -Maximum 62)] })
  Set-Content -Path $keyFile -Value $k -NoNewline -Encoding ascii
}
$key = (Get-Content $keyFile -Raw).Trim()
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) {
  foreach ($cand in @(
      (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
    if ($cand -and (Test-Path $cand)) { $nodeExe = $cand; break }
  }
}
if (-not $nodeExe) { Log '找不到 node.exe（装 Node.js 或把 node 加进 PATH）' 'Red'; exit 1 }
$sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if (-not $sshExe) { $sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }

Log "守护启动  port=$port  providers=$($services -join ',')" 'Cyan'

function Test-Port([int]$p) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p); $c.Close(); $true } catch { $false }
}

function Stop-Proc($p) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }

# ---------- 本地服务 ----------
function Start-Node {
  $env:PORT = "$port"
  $env:QR_FILE = $qrFile
  $env:NO_EXIT = '1'
  $p = Start-Process -FilePath $nodeExe -ArgumentList (Join-Path $root 'qrsync.js') `
    -WorkingDirectory $root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'server.out.log') `
    -RedirectStandardError  (Join-Path $root 'server.err.log')
  for ($i = 0; $i -lt 40; $i++) { if (Test-Port $port) { break }; Start-Sleep -Milliseconds 250 }
  if (Test-Port $port) { Log "本地服务就绪 http://127.0.0.1:$port" 'Green' } else { Log '本地服务没起来，看 server.err.log' 'Red' }
  $p
}

# ---------- 隧道 ----------
function Read-Url([string]$logPath, [string]$regex, [int]$tries = 30) {
  for ($i = 0; $i -lt $tries; $i++) {
    Start-Sleep -Milliseconds 1500
    $txt = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content "$logPath.err" -Raw -ErrorAction SilentlyContinue)
    if ($txt -match $regex) { return $Matches[0] }
  }
  return $null
}

function Start-Tunnel {
  foreach ($name in $services) {
    $proc = $null
    $url = $null
    $logPath = Join-Path $root "tunnel-$name.log"
    Remove-Item $logPath, "$logPath.err" -Force -ErrorAction SilentlyContinue
    $started = $false

    if ($name -eq 'ngrok') {
      $exe = Join-Path $root 'ngrok.exe'
      if (-not (Test-Path $exe)) { Log '  ngrok.exe 不存在，跳过' 'Yellow' }
      elseif (-not $cfg.ngrok.authToken) { Log '  ngrok 未配置 authToken，跳过' 'Yellow' }
      elseif (-not $cfg.ngrok.domain) { Log '  ngrok 未配置固定域名，跳过' 'Yellow' }
      else {
        & $exe config add-authtoken $cfg.ngrok.authToken 2>&1 | Out-Null
        $ngArgs = @('http', "--url=$($cfg.ngrok.domain)", "$tunnelPort", '--log=stdout', '--log-format=logfmt', '--log-level=info')
        $proc = Start-Process -FilePath $exe -ArgumentList $ngArgs `
          -WorkingDirectory $root -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
        $url = "https://$($cfg.ngrok.domain)"
        Start-Sleep -Seconds 5
        if ($proc.HasExited) {
          # 常见坑：守护上次被杀（任务结束/机器没重启）但 ngrok 还挂着同一个固定域名，
          # 新进程会立刻 ERR_NGROK_334 退出，然后静默退到 cloudflare —— 域名就变了，
          # 用户手里的扫码链接直接失效。这里把占着域名的旧 ngrok 干掉再试一次。
          $logTxt = ''
          try { $logTxt = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue) + (Get-Content "$logPath.err" -Raw -ErrorAction SilentlyContinue) } catch {}
          if ($logTxt -match 'ERR_NGROK_334|is already online') {
            Log '  固定域名被残留的 ngrok 进程占用，清理后重试' 'Yellow'
            try {
              Get-CimInstance Win32_Process -Filter "Name='ngrok.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $proc.Id -and $_.CommandLine -and $_.CommandLine -like "*$($cfg.ngrok.domain)*" } |
                ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Log ("  已结束残留 ngrok PID " + $_.ProcessId) 'Yellow' } catch {} }
            } catch {}
            Start-Sleep -Seconds 2
            Remove-Item $logPath, "$logPath.err" -Force -ErrorAction SilentlyContinue
            $proc = Start-Process -FilePath $exe -ArgumentList $ngArgs `
              -WorkingDirectory $root -WindowStyle Hidden -PassThru `
              -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
            Start-Sleep -Seconds 5
          }
          if ($proc.HasExited) { Log '  ngrok 启动即退出，看 tunnel-ngrok.log' 'Yellow'; $proc = $null } else { $started = $true }
        } else { $started = $true }
      }
    }
    elseif ($name -eq 'cloudflare') {
      $exe = Join-Path $root 'cloudflared.exe'
      if (-not (Test-Path $exe)) { Log '  cloudflared.exe 不存在，跳过' 'Yellow' }
      elseif ($cfg.cloudflare.namedTunnel) {
        $proc = Start-Process -FilePath $exe -ArgumentList @('tunnel', 'run', $cfg.cloudflare.namedTunnel, '--no-autoupdate') `
          -WorkingDirectory $root -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
        Start-Sleep -Seconds 8
        if ($proc.HasExited) { Log '  named tunnel 启动失败' 'Yellow'; $proc = $null } else { $started = $true }
      }
      else {
        $proc = Start-Process -FilePath $exe -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$tunnelPort", '--no-autoupdate', '--loglevel', 'info') `
          -WorkingDirectory $root -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
        $url = Read-Url $logPath 'https://[a-z0-9-]+\.trycloudflare\.com'
        if ($proc.HasExited) { $proc = $null }
        if ($url -and $proc) { $started = $true }
        elseif (-not $url) { Log '  cloudflare 快速隧道没拿到地址' 'Yellow' }
      }
    }
    elseif ($name -eq 'localhost.run') {
      $proc = Start-Process -FilePath $sshExe -ArgumentList @('-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$root\known_hosts", '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3', '-o', 'ExitOnForwardFailure=yes', '-R', "80:localhost:$tunnelPort", 'nokey@localhost.run') `
        -WorkingDirectory $root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
      $url = Read-Url $logPath 'https://[a-z0-9]+\.lhr\.life'
      if ($proc.HasExited) { $proc = $null }
      if ($url -and $proc) { $started = $true }
    }
    elseif ($name -eq 'pinggy') {
      $proc = Start-Process -FilePath $sshExe -ArgumentList @('-p', '443', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$root\known_hosts", '-o', 'ServerAliveInterval=30', '-o', 'ExitOnForwardFailure=yes', '-R0', "localhost:$tunnelPort", 'a.pinggy.io') `
        -WorkingDirectory $root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
      $url = Read-Url $logPath 'https?://[a-z0-9-]+\.(?:free\.)?pinggy\.link'
      if ($proc.HasExited) { $proc = $null }
      if ($url -and $proc) { $started = $true }
    }

    if ($started -and $proc) {
      Log "隧道就绪（$name） $url" 'Green'
      return @{ name = $name; proc = $proc; url = $url; log = $logPath }
    }
    Stop-Proc $proc
  }
  return $null
}

function Test-Public([string]$url) {
  if (-not $url) { return $true }
  try {
    # ngrok 免费版会给浏览器类请求塞一个 "You are about to visit..." 提示页，
    # 带上这个头才能拿到真实响应；没有它会被误判成"隧道挂了"而反复重建。
    # 注意：必须用 ${healthPath} 定界。PowerShell 双引号里 ? 可属于变量名，
    # 写成 "$healthPath?k" 会被当成未定义变量 $healthPath?k（插值为空），URI 因此损坏。
    $r = Invoke-WebRequest -Uri "$url${healthPath}?k=$key" -UseBasicParsing -TimeoutSec 15 `
      -Headers @{ 'ngrok-skip-browser-warning' = '1'; 'User-Agent' = 'qrsync-healthcheck' } -ErrorAction Stop
    if ($r.StatusCode -ne 200) { return $false }
    return ($r.Content -match '"state"|"ok"')
  } catch {
    # 不再吞掉异常：把真实原因写进日志，下次自检失败可直接定位（TLS/代理/超时/HTTP码）。
    Log ("公网自检异常: " + $_.Exception.Message) 'Yellow'
    return $false
  }
}

# ---------- 主循环 ----------
$node = $null
$tunnel = $null
$publicUrl = $null
$lastHealth = Get-Date
$failStreak = 0
$backoff = 5

while ($true) {
  # 1) 本地服务
  if (-not (Test-Port $port)) {
    if ($node) { Log '本地服务掉线，重启' 'Yellow' }
    Stop-Proc $node
    $node = Start-Node
  }

  # 2) 隧道
  $needTunnel = $false
  if (-not $tunnel) { $needTunnel = $true }
  elseif ($tunnel.proc.HasExited) {
    Log "隧道（$($tunnel.name)）断开，重连" 'Yellow'
    $needTunnel = $true
  }

  if ($needTunnel) {
    if ($tunnel) { Stop-Proc $tunnel.proc }
    $tunnel = Start-Tunnel
    if ($tunnel) {
      $shown = if ($tunnel.url) { "$($tunnel.url)/?k=$key" } else { "http://127.0.0.1:$port/?k=$key" }
      if ($shown -ne $publicUrl) {
        $publicUrl = $shown
        # 不用 Set-Content -Encoding utf8：PS 5.1 会写 BOM + 结尾换行，
        # 而 current-url.txt 常常被脚本/手机端直接当 URL 读，BOM 会让拼接出来的地址打不开。
        [IO.File]::WriteAllText((Join-Path $root 'current-url.txt'), $shown, (New-Object Text.ASCIIEncoding))
        Log "公网地址：$shown" 'Cyan'
      }
      $failStreak = 0
      $backoff = 5
      Write-State $tunnel.name $true $tunnel.url 0
    }
    else {
      Log "没有可用隧道，${backoff}s 后重试" 'Red'
      Write-State '' $false '' 0
      Start-Sleep -Seconds $backoff
      $backoff = [Math]::Min(60, $backoff * 2)
      continue
    }
  }

  # 3) 端到端自检：进程活着但连接假死时也要能发现
  if (((Get-Date) - $lastHealth).TotalSeconds -ge $healthEvery) {
    $lastHealth = Get-Date
    if ($tunnel -and $tunnel.url -and $tunnel.proc -and -not $tunnel.proc.HasExited) {
      if (Test-Public $tunnel.url) {
        $failStreak = 0
        Write-State $tunnel.name $true $tunnel.url 0
      }
      else {
        $failStreak++
        Write-State $tunnel.name $false $tunnel.url $failStreak
        Log "公网自检失败（连续 $failStreak 次）" 'Yellow'
        if ($failStreak -ge 10) {
          Log '判定隧道假死（连续 10 次），重建' 'Red'
          Stop-Proc $tunnel.proc
          $tunnel = $null
          $failStreak = 0
        }
      }
    }
  }

  Start-Sleep -Seconds 5
}
