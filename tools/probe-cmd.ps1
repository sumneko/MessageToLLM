# probe-cmd.ps1 —— 往探针发一条界面命令并打印结果
#
# 用法：
#   pwsh -NoProfile -File .\tools\probe-cmd.ps1 pages
#   pwsh -NoProfile -File .\tools\probe-cmd.ps1 slots
#   pwsh -NoProfile -File .\tools\probe-cmd.ps1 "click 40 160 R"
#
# 命令白名单（只有界面读写，别的一概没有）
#   读：pages / slots / state
#   写：click <x> <y> [L|R]   —— 屏幕坐标（左上原点），交给游戏自己的点击逻辑
#
# click 不移动真实鼠标、不需要前台：插件临时改写 Unity 的输入查询，
# 游戏自己认为有人点了一下。

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Command,
    [string]$Dir = 'runs\inject',
    [int]$TimeoutSec = 10
)

$ErrorActionPreference = 'Stop'
$cmdPath = Join-Path $Dir 'cmd.txt'
$resPath = Join-Path $Dir 'result.json'

if (-not (Test-Path $Dir)) { Write-Host "STOP: 没找到 $Dir，探针没跑过？" -ForegroundColor Red; exit 2 }
if (Test-Path $resPath) { Remove-Item $resPath -Force }

Set-Content -Path $cmdPath -Value $Command -Encoding utf8

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resPath) {
        Start-Sleep -Milliseconds 120      # 等写入落盘
        $raw = Get-Content $resPath -Raw
        if ($raw -and $raw.Trim().Length -gt 0) { $raw.Trim(); exit 0 }
    }
    Start-Sleep -Milliseconds 150
}

Write-Host "STOP: ${TimeoutSec}s 内没有结果（插件没加载？看 runs\inject\probe.log）" -ForegroundColor Red
exit 3
