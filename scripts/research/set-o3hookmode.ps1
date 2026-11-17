#Requires -Version 5.1
<#
.SYNOPSIS
    切换 NapCat 的 o3HookMode（风控单变量实验用）。

.DESCRIPTION
    社区诊断（dsh-qq-bridge/docs/napcat-offline-diagnosis.md）建议：
    只把 o3HookMode 从 1 改成 0、其他变量全部不动，重启 NapCat 并扫码，
    观察 24–48 小时，记录"每次登录能活多久"，而不是重启次数。

    本脚本只改 config\napcat.json 与 config\napcat_<QQ号>.json 里的 o3HookMode 字段，
    自动备份原文件，并在没有 -Apply 时只打印将要发生的改动。

.PARAMETER Mode
    0 = 关闭 hook 模式（实验组）；1 = 恢复默认（对照组）。

.PARAMETER Root
    NapCat 根目录，默认 D:\napcat。

.EXAMPLE
    .\set-o3hookmode.ps1 -Mode 0            # 预演
    .\set-o3hookmode.ps1 -Mode 0 -Apply     # 真正写入
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('0', '1')][string]$Mode,
    [string]$Root = 'D:\napcat',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$configDir = Join-Path $Root 'NapCat.Shell\config'
if (-not (Test-Path -LiteralPath $configDir)) {
    $configDir = Join-Path $Root 'config'
}
if (-not (Test-Path -LiteralPath $configDir)) {
    throw "config directory not found under $Root"
}

$targets = @(Get-ChildItem -LiteralPath $configDir -Filter 'napcat*.json' -File | Where-Object { $_.Name -notlike '*.bak*' })
if ($targets.Count -eq 0) { throw "no napcat*.json under $configDir" }

foreach ($f in $targets) {
    $raw = [IO.File]::ReadAllText($f.FullName, [Text.UTF8Encoding]::new($false))
    $hasBom = $raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF
    $text = if ($hasBom) { $raw.Substring(1) } else { $raw }

    $obj = $text | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'o3HookMode')) {
        Write-Host ("skip {0}: no o3HookMode field" -f $f.Name) -ForegroundColor DarkGray
        continue
    }

    $old = [string]$obj.o3HookMode
    if ($old -eq $Mode) {
        Write-Host ("{0}: already o3HookMode={1}" -f $f.Name, $Mode) -ForegroundColor DarkGray
        continue
    }

    # 只替换这一个键的值，保留原文件的顺序、缩进与其余字段
    $newText = [regex]::Replace($text, '("o3HookMode"\s*:\s*)(\d+)', { param($m) $m.Groups[1].Value + $Mode }, 'None')
    if ($newText -eq $text) { throw ("cannot patch o3HookMode in {0}" -f $f.Name) }

    # 写回前校验仍然是合法 JSON
    $null = $newText | ConvertFrom-Json

    Write-Host ("{0}: o3HookMode {1} -> {2}" -f $f.Name, $old, $Mode)
    if (-not $Apply) { Write-Host '  (dry run, add -Apply to write)' -ForegroundColor DarkGray; continue }

    $backup = "{0}.bak-o3hook-{1:yyyyMMdd-HHmmss}" -f $f.FullName, (Get-Date)
    Copy-Item -LiteralPath $f.FullName -Destination $backup -Force
    [IO.File]::WriteAllText($f.FullName, $newText, [Text.UTF8Encoding]::new($hasBom))
    Write-Host ("  written, backup: {0}" -f (Split-Path -Leaf $backup)) -ForegroundColor Green
}

if ($Apply) {
    Write-Host ''
    Write-Host '下一步：重启 NapCat，重新扫码，并记录这次登录活了多久。' -ForegroundColor Yellow
    Write-Host '  .\scripts\ops\status.ps1          # 随时看本次登录已多久'
    Write-Host '  .\scripts\research\kick-report.ps1     # 24–48 小时后看会话时长分布'
}
