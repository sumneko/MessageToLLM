# mouse.ps1 —— 点击原语
#
# 坐标系：Get-GameWindow 返回的是「客户区」屏幕坐标，截图像素与客户区像素 1:1。
# 高 DPI 下若 Initialize-DpiAwareness 失败，坐标可能被系统虚拟化，
# 此时 SetCursorPos 需物理像素 —— 点击前会复核（见 P1）。
#
# 参考空间：所有识别结果都可以换算到 1920x1080 的「参考坐标」，
# 确需点击时再用 ConvertFrom-ReferencePoint 换回当前屏幕像素。

. (Join-Path $PSScriptRoot '..\capture\capture.ps1')

function Set-GameForeground {
    param([string]$ProcessName = 'MessageFromAliens')
    $win = Get-GameWindow -ProcessName $ProcessName
    if (-not $win) { throw "CAPTURE_FAIL: 找不到游戏窗口（进程 $ProcessName）" }
    [void][MtL4.Native]::SetForegroundWindow($win.Handle)
    Start-Sleep -Milliseconds 120
    $fg = Test-GameForeground -ProcessName $ProcessName
    if (-not $fg.Ok) { throw "CAPTURE_FAIL: 无法把游戏切到前台（当前是 $($fg.Foreground.ProcessName)）" }
    return $win
}

# 参考坐标（1920x1080 空间）→ SetCursorPos 需要的物理像素坐标
function ConvertFrom-ReferencePoint {
    param(
        [Parameter(Mandatory)][double]$RefX,
        [Parameter(Mandatory)][double]$RefY,
        [Parameter(Mandatory)]$Window,
        [double]$RefWidth = 1920,
        [double]$RefHeight = 1080
    )
    $sx = $Window.Width / $RefWidth       # 参考空间 → 截图像素
    $sy = $Window.Height / $RefHeight
    $ps = $(if ($Window.PointScale -gt 0) { $Window.PointScale } else { 1.0 })   # 截图像素 → 物理像素
    return [pscustomobject]@{
        X = [int][Math]::Round(($Window.X + $RefX * $sx) * $ps)
        Y = [int][Math]::Round(($Window.Y + $RefY * $sy) * $ps)
    }
}

# 坐标虚拟化警告：只有 PointScale ≠ 1 才需要提醒（已 aware 的高 DPI 屏幕不需要）
function Get-DpiWarning {
    param($Window)
    if (-not $Window) { return $null }
    if ($Window.PointScale -eq 1) { return $null }
    return "DPI 坐标虚拟化：窗口 DPI=$($Window.Dpi) / 系统 DPI=$($Window.SystemDpi) ⇒ 点击坐标需 ×$($Window.PointScale)（ConvertFrom-ReferencePoint 已自动处理）。"
}

# 单击。默认 DryRun：只打印坐标不动鼠标（安全默认值）
function Invoke-Click {
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [switch]$DryRun,
        [int]$SettleMs = 120
    )
    if ($DryRun) {
        Write-Host ("[dry-run] {0} click ({1}, {2})" -f $Button, $X, $Y) -ForegroundColor DarkGray
        return
    }
    [void][MtL4.Native]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 30
    $down = if ($Button -eq 'Right') { $script:MOUSEEVENTF_RIGHTDOWN } else { $script:MOUSEEVENTF_LEFTDOWN }
    $up = if ($Button -eq 'Right') { $script:MOUSEEVENTF_RIGHTUP } else { $script:MOUSEEVENTF_LEFTUP }
    [MtL4.Native]::mouse_event($down, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [MtL4.Native]::mouse_event($up, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $SettleMs
}

# 点击后验证：前后两帧是否发生变化。返回变化像素占比（0-1）
# 用像素缓冲而不是 GetPixel：4K 下 GetPixel 逐个采样要好几秒。
function Get-FrameDiffRatio {
    param([System.Drawing.Bitmap]$Before, [System.Drawing.Bitmap]$After,
        [int]$Step = 4, [int]$PixelTolerance = 30)
    if ($Before.Width -ne $After.Width -or $Before.Height -ne $After.Height) { return 1.0 }

    $a = Get-PixelBuffer -Bmp $Before
    $b = Get-PixelBuffer -Bmp $After
    # 分辨率提高时放大步长，保持采样点数不变（耗时稳定）
    $stepNow = [Math]::Max($Step, [int][Math]::Round($Step * ($a.Height / 1080.0)))

    $st = [MtGV5.QuickOps]::DiffStats($a.Buf, $b.Buf, $a.Width, $a.Height, $a.Stride, $stepNow, $PixelTolerance)
    if ($st[1] -eq 0) { return 0.0 }
    return $st[0] / $st[1]
}
