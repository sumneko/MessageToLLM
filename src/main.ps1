# main.ps1 —— P0：只读感知（不碰鼠标）
#
# 用法：
#   .\src\main.ps1 -Image ..\data\samples\p1.png      # 识别一张已有截图
#   .\src\main.ps1 -Live                              # 截当前游戏画面并识别
#
# 截屏失败会以 CAPTURE_FAIL: 报错并退出（不重试、不盲点）。

[CmdletBinding()]
param(
    [string]$Image,
    [switch]$Live,
    [string]$ProcessName = 'MessageFromAliens',
    [string]$LibraryPath,
    [string]$OutDir
)

$root = Split-Path $PSScriptRoot -Parent
if (-not $LibraryPath) { $LibraryPath = Join-Path $root 'data\clusters.json' }
if (-not $OutDir) { $OutDir = Join-Path $root 'runs' }

. (Join-Path $PSScriptRoot 'vision\common.ps1')
. (Join-Path $PSScriptRoot 'vision\classify.ps1')
. (Join-Path $PSScriptRoot 'vision\recognize.ps1')
. (Join-Path $PSScriptRoot 'capture\capture.ps1')
. (Join-Path $PSScriptRoot 'act\mouse.ps1')

function Import-Translations {
    $path = Join-Path $root 'data\translations.csv'
    $map = @{}
    if (Test-Path $path) {
        foreach ($t in (Import-Csv $path -Encoding UTF8)) { if ($t.id) { $map[$t.id] = $t.text } }
    }
    return $map
}

$library = Import-GlyphLibrary -Path $LibraryPath
$trans = Import-Translations
Write-Host ("符号库：{0} 个符号" -f $library.Count) -ForegroundColor Cyan

$target = $Image
if ($Live) {
    try {
        $frame = Capture-GameFrame -ProcessName $ProcessName
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host "已停止。请检查：游戏是否在前台 / 是否无边框窗口 / 窗口是否被移动。" -ForegroundColor Yellow
        exit 2
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $OutDir "$stamp\frame-0001.png"
    Save-Frame -Bitmap $frame.Bitmap -Path $target | Out-Null
    Write-Host ("窗口 {0}x{1} @ ({2},{3})  DPI={4}" -f $frame.Window.Width, $frame.Window.Height, $frame.Window.X, $frame.Window.Y, $frame.Window.Dpi)
    $frame.Bitmap.Dispose()
    Write-Host ("已保存首帧：{0}" -f $target) -ForegroundColor DarkGray
}

if (-not $target) {
    Write-Host "请用 -Image <路径> 指定截图，或 -Live 抓取实时画面。" -ForegroundColor Yellow
    exit 1
}

try {
    $matrix = Get-PanelMatrix -ImagePath $target -Library $library
}
catch {
    Write-Host ("识别失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "若是测验页/未知面板，属于 P0 已知限制（当前只支持带文字标签的笔记页）。" -ForegroundColor Yellow
    exit 3
}

if ($matrix.Rows.Count -eq 0) {
    Write-Host "没有识别到任何行（当前面板可能不是笔记页）。" -ForegroundColor Yellow
    exit 3
}

$md = Format-PanelMatrix -Matrix $matrix -Translations $trans
Write-Host $md
$outMd = Join-Path $OutDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-matrix.md')
$dir = Split-Path $outMd -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$md | Set-Content -Path $outMd -Encoding UTF8
Write-Host ("表格已保存：{0}" -f $outMd) -ForegroundColor DarkGray

$lowCount = 0; $newCount = 0
foreach ($r in $matrix.Rows) { foreach ($c in $r.Cells) { if ($c.Band -eq 'low') { $lowCount++ } elseif ($c.Band -eq 'new') { $newCount++ } } }
if ($lowCount -gt 0 -or $newCount -gt 0) {
    Write-Host ("注意：存疑 {0} 格（标 ?）、库外新符号 {1} 格（标 ‼）" -f $lowCount, $newCount) -ForegroundColor Yellow
}
