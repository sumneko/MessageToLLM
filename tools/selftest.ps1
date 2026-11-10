# selftest.ps1 —— 环境自检 + 识图回归测试
#
# 用法：  .\tools\selftest.ps1
#         .\tools\selftest.ps1 -SkipCapture   # 不看实时画面

[CmdletBinding()]
param([switch]$SkipCapture)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

. (Join-Path $root 'src\vision\common.ps1')
. (Join-Path $root 'src\vision\classify.ps1')
. (Join-Path $root 'src\vision\recognize.ps1')
. (Join-Path $root 'src\capture\capture.ps1')
. (Join-Path $root 'src\act\mouse.ps1')

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host ("  [PASS] {0} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("  [FAIL] {0} {1}" -f $name, $detail) -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n=== 1. 运行时 ===" -ForegroundColor Cyan
Check 'PowerShell 版本' ($PSVersionTable.PSVersion.Major -ge 5) $PSVersionTable.PSVersion.ToString()
Check 'System.Drawing 可用' ($null -ne ([System.Drawing.Bitmap])) ''

Write-Host "`n=== 2. 符号库 ===" -ForegroundColor Cyan
$libPath = Join-Path $root 'data\clusters.json'
$lib = Import-GlyphLibrary -Path $libPath
Check '符号库载入' ($lib.Count -gt 0) ("{0} 个符号" -f $lib.Count)

Write-Host "`n=== 3. 识图回归（笔记页） ===" -ForegroundColor Cyan
$expected = @{
    'p1.png' = @(
        'g001,g002,g003,g004,g005'
        'g001,g006,g007,g004,g005'
        'g001,g008,g009,g010,g011'
        'g001,g008,g009,g010,g012,g011'
        'g001,g013,g008,g014,g013,g012,g015'
    )
    'p2.png' = @(
        'g016,g002,g017,g001'
        'g018,g002,g019,g001'
        'g016,g002,g020,g018'
        'g018,g002,g021,g016'
    )
    'p3.png' = @(
        'g011,g002,g022,g023'
        'g011,g004,g024,g022,g002,g025'
        'g011,g004,g026,g022,g002,g027'
        'g028,g002,g029,g025,g030,g027,g004,g031'
        'g032,g010,g004,g025,g002,g033,g034,g035,g036,g027,g002'
        'g033,g034,g035,g037'
        'g010,g011,g029,g025,g030,g027'
        'g010,g011,g004,g028,g002,g038'
    )
    'p4.png' = @(
        'g039,g002,g040,g041,g042'
        'g031,g004,g039,g002,g043'
    )
}

foreach ($file in ($expected.Keys | Sort-Object)) {
    $path = Join-Path $root ("data\samples\{0}" -f $file)
    if (-not (Test-Path $path)) { Check $file $false '样张缺失'; continue }
    $m = Get-PanelMatrix -ImagePath $path -Library $lib
    $actual = @(Get-MatrixIds -Matrix $m | ForEach-Object { ($_ -join ',') })
    $want = $expected[$file]
    $same = ($actual.Count -eq $want.Count)
    if ($same) {
        for ($i = 0; $i -lt $want.Count; $i++) {
            if ($actual[$i] -ne $want[$i]) { $same = $false; Check ("$file r$($i+1)") $false ("期望 $($want[$i]) / 实际 $($actual[$i])"); break }
        }
    }
    Check $file $same ("{0} 行" -f $actual.Count)
}

Write-Host "`n=== 4. 实时截屏 ===" -ForegroundColor Cyan
if ($SkipCapture) {
    Write-Host "  [SKIP] 已指定 -SkipCapture" -ForegroundColor DarkGray
}
else {
    $win = Get-GameWindow
    if (-not $win) {
        Write-Host "  [SKIP] 游戏未运行（进程 MessageFromAliens 没有窗口）" -ForegroundColor DarkGray
    }
    else {
        Check '窗口几何' ($win.Width -gt 0 -and $win.Height -gt 0) ("{0}x{1} @ ({2},{3}) DPI={4}" -f $win.Width, $win.Height, $win.X, $win.Y, $win.Dpi)
        $fg = Test-GameForeground
        Write-Host ("         前台? {0} {1}" -f $fg.Ok, $(if ($fg.Ok) { '' } else { "（当前是 $($fg.Foreground.ProcessName)）" })) -ForegroundColor DarkGray
        try {
            # Auto：前台用 GDI，后台用 PrintWindow
            $frame = Capture-GameFrame -Method Auto
            Check '截屏' $true ("method=$($frame.Method)")
            $outFile = Join-Path $root ("runs\selftest\frame-{0}.png" -f (Get-Date -Format 'HHmmss'))
            Save-Frame -Bitmap $frame.Bitmap -Path $outFile | Out-Null
            Write-Host ("         已保存：{0}" -f $outFile) -ForegroundColor DarkGray
            $frame.Bitmap.Dispose()
        }
        catch {
            Check '截屏' $false $_.Exception.Message
        }
    }
}

Write-Host "`n=== 5. 点击原语（dry-run，不动鼠标） ===" -ForegroundColor Cyan
Invoke-Click -X 960 -Y 540 -DryRun
Check '点击函数可用' $true ''

Write-Host ""
if ($fail -eq 0) {
    Write-Host "全部通过 ✅" -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("$fail 项失败 ❌") -ForegroundColor Red
    exit 1
}
