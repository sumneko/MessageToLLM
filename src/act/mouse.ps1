# mouse.ps1 —— 点击原语
#
# 坐标系已实测确认：游戏窗口 (0,0)-(1920,1080)，DPI 96，客户区原点 (0,0)
# 因此 屏幕像素坐标 == 截图坐标 == 点击坐标，1:1，无需换算。

. (Join-Path $PSScriptRoot '..\capture\capture.ps1')

function Set-GameForeground {
    param([string]$ProcessName = 'MessageFromAliens')
    $win = Get-GameWindow -ProcessName $ProcessName
    if (-not $win) { throw "CAPTURE_FAIL: 找不到游戏窗口（进程 $ProcessName）" }
    [void][MtL2.Native]::SetForegroundWindow($win.Handle)
    return $win
}

# 单击。默认 DryRun：只打印坐标不动鼠标（安全默认值）
function Invoke-Click {
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [switch]$DryRun,
        [int]$SettleMs = 120
    )
    if ($DryRun) {
        Write-Host ("[dry-run] click ({0}, {1})" -f $X, $Y) -ForegroundColor DarkGray
        return
    }
    [void][MtL2.Native]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 30
    [MtL2.Native]::mouse_event($script:MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [MtL2.Native]::mouse_event($script:MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $SettleMs
}

# 点击后验证：前后两帧是否发生变化。返回变化像素占比（0-1）
function Get-FrameDiffRatio {
    param([System.Drawing.Bitmap]$Before, [System.Drawing.Bitmap]$After)
    if ($Before.Width -ne $After.Width -or $Before.Height -ne $After.Height) { return 1.0 }
    $diff = 0
    $total = 0
    $step = 4
    for ($y = 0; $y -lt $Before.Height; $y += $step) {
        for ($x = 0; $x -lt $Before.Width; $x += $step) {
            $a = $Before.GetPixel($x, $y)
            $b = $After.GetPixel($x, $y)
            $total++
            if ([Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B) -gt 30) { $diff++ }
        }
    }
    if ($total -eq 0) { return 0.0 }
    return $diff / $total
}
