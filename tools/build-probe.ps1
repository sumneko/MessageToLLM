# build-probe.ps1 —— 编译并安装只读探针（BepInEx 5 插件）
#
# 为什么用 BepInEx：本机没有 native 编译器（无 cl/clang/gcc），
# 而 Unity 6 的真实脚本程序集名单嵌在 globalgamemanagers.assets 里，改 ScriptingAssemblies.json 无效。
# BepInEx 自带预编译的 winhttp.dll 代理 + doorstop，无需我们编译 native，插件用 csc 编译即可。
#
# 用法（游戏需先退出，BepInEx 只在启动时挂钩）：
#   pwsh -NoProfile -File .\tools\build-probe.ps1              # 编译 + 安装插件
#   pwsh -NoProfile -File .\tools\build-probe.ps1 -Uninstall   # 只删插件
#   pwsh -NoProfile -File .\tools\build-probe.ps1 -Purge       # 连 BepInEx 一起删干净

[CmdletBinding()]
param(
    [string]$GameDir = 'D:\steam\steamapps\common\Message From Aliens',
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$managed = Join-Path $GameDir 'MessageFromAliens_Data\Managed'
$core = Join-Path $GameDir 'BepInEx\core'
$plugins = Join-Path $GameDir 'BepInEx\plugins'
$pluginDll = Join-Path $plugins 'MtLProbe.dll'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if ($Uninstall -or $Purge) {
    if (Test-Path $pluginDll) { Remove-Item $pluginDll -Force; Write-Host "removed MtLProbe.dll" }
    if ($Purge) {
        foreach ($f in 'winhttp.dll', 'doorstop_config.ini', '.doorstop_version') {
            $p = Join-Path $GameDir $f
            if (Test-Path $p) { Remove-Item $p -Force; Write-Host "removed $f" }
        }
        $b = Join-Path $GameDir 'BepInEx'
        if (Test-Path $b) { Remove-Item $b -Recurse -Force; Write-Host "removed BepInEx\" }
    }
    exit 0
}

if ((Get-Process -Name MessageFromAliens -ErrorAction SilentlyContinue) -and -not $Force) {
    Write-Host "STOP: 游戏在运行。退出游戏，或加 -Force 先装好、下次启动生效。" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $csc)) { Write-Host "STOP: 找不到 csc.exe" -ForegroundColor Red; exit 2 }
if (-not (Test-Path (Join-Path $core 'BepInEx.dll'))) {
    Write-Host "STOP: BepInEx 未安装（$core 下没有 BepInEx.dll）。先解压 BepInEx 5 x64 到游戏根目录。" -ForegroundColor Red
    exit 2
}

# 编译插件
$src = Join-Path $PSScriptRoot 'probe-inject\Plugin.cs'
$bin = Join-Path $PSScriptRoot 'probe-inject\bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$outDll = Join-Path $bin 'MtLProbe.dll'

& $csc /nologo /target:library /platform:x64 /optimize+ /out:$outDll `
    /r:"$(Join-Path $core 'BepInEx.dll')" `
    /r:"$(Join-Path $core '0Harmony.dll')" `
    /r:"$(Join-Path $managed 'UnityEngine.dll')" `
    /r:"$(Join-Path $managed 'UnityEngine.CoreModule.dll')" `
    /r:"$(Join-Path $managed 'UnityEngine.MathematicsModule.dll')" `
    /r:"$(Join-Path $managed 'UnityEngine.InputLegacyModule.dll')" `
    /r:"$(Join-Path $managed 'netstandard.dll')" `
    /r:"$(Join-Path $managed 'Assembly-CSharp.dll')" `
    $src
if ($LASTEXITCODE -ne 0) { Write-Host "STOP: 编译失败" -ForegroundColor Red; exit 3 }

New-Item -ItemType Directory -Path $plugins -Force | Out-Null
Copy-Item $outDll $pluginDll -Force
Write-Host "installed $pluginDll"
Write-Host ""
Write-Host "启动游戏后看：runs\inject\state.json（1Hz）、runs\inject\probe.log" -ForegroundColor Cyan
Write-Host "BepInEx 自身日志：$GameDir\BepInEx\LogOutput.log" -ForegroundColor DarkGray
