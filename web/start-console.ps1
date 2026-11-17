# NapCat Web 控制台启动器（零依赖）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <repo>\web\start-console.ps1
# 行为：前台运行 node server.js；进程意外退出时自动重启（5s 起，最多 60s），输出追加到 console.log。
# 说明：这是 web-console 自己的守护外壳，与 guardian.ps1 无关，互不影响。

$ErrorActionPreference = 'Stop'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Dir 'console.log'
# node 输出的是 UTF-8，Windows PowerShell 默认按 GBK 解码会把中文写花
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Node = Join-Path $env:ProgramFiles 'nodejs\node.exe'
if (-not (Test-Path $Node)) { $Node = 'node' }

function Write-Log([string]$msg) {
  $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $msg
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

# 单实例：同名互斥体，重复启动直接退出（否则两个 node 抢 8440 会陷入重启循环）
$mutex = New-Object System.Threading.Mutex($false, 'Global\NapCatWebConsole')
if (-not $mutex.WaitOne(0)) {
  Write-Log 'already running (mutex busy), exit.'
  exit 0
}

Set-Location $Dir
Write-Log 'launcher started'

$fails = 0
while ($true) {
  $started = Get-Date
  try {
    & $Node server.js 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding UTF8 }
    $code = $LASTEXITCODE
    Write-Log ('node exited with ' + $code)
  } catch {
    Write-Log ('node failed: ' + $_.Exception.Message)
  }

  # 起来不到 30 秒就挂，多半是配置/端口问题：逐步退避，别把日志刷爆
  if (((Get-Date) - $started).TotalSeconds -lt 30) { $fails++ } else { $fails = 0 }
  $wait = [Math]::Min(60, 5 * [Math]::Max(1, $fails))
  Write-Log ('restarting in ' + $wait + 's')
  Start-Sleep -Seconds $wait
}
