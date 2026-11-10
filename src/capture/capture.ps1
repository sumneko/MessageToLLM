# capture.ps1 —— 截屏 + 窗口存活校验
#
# 设计原则（用户要求）：截不到图就立刻停，不重试、不猜测、不盲点。
# 所有失败都以 CAPTURE_FAIL: 前缀抛出，调用方负责熔断与通知。

. (Join-Path $PSScriptRoot '..\vision\common.ps1')

if (-not ([System.Management.Automation.PSTypeName]'MtL4.Native').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MtL4 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public class Native {
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    }
}
'@ -ErrorAction Stop
}

$script:MOUSEEVENTF_LEFTDOWN = 0x0002
$script:MOUSEEVENTF_LEFTUP = 0x0004
$script:MOUSEEVENTF_RIGHTDOWN = 0x0008
$script:MOUSEEVENTF_RIGHTUP = 0x0010
$script:DPI_AWARENESS_INIT = $null

# 尝试把进程提升到 PER_MONITOR_AWARE_V2（-4）。
# 成功 => 所有窗口/截屏/鼠标 API 都用物理像素；失败 => 可能已被主程序 manifest 锁定。
# 真正的换算判据不看返回值，而是 Get-GameWindow 里的 PointScale。
function Initialize-DpiAwareness {
    if ($null -ne $script:DPI_AWARENESS_INIT) { return $script:DPI_AWARENESS_INIT }
    $script:DPI_AWARENESS_INIT = [MtL4.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))
    return $script:DPI_AWARENESS_INIT
}

# 点源即尝试一次（越早越可能成功；失败也不影响，靠 PointScale 适配）
Initialize-DpiAwareness | Out-Null

# 找到游戏窗口并返回几何信息；找不到返回 $null
#
# X / Y / Width / Height 是「客户区」的屏幕位置与尺寸 —— 截屏和点击都用它，
# 这样无论无边框全屏、有边框窗口还是 4K 缩放，都不需要额外的偏移补偿。
function Get-GameWindow {
    param([string]$ProcessName = 'MessageFromAliens')
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { return $null }

    $wr = New-Object MtL4.RECT
    if (-not [MtL4.Native]::GetWindowRect($proc.MainWindowHandle, [ref]$wr)) { return $null }
    $cr = New-Object MtL4.RECT
    if (-not [MtL4.Native]::GetClientRect($proc.MainWindowHandle, [ref]$cr)) { return $null }
    $pt = New-Object MtL4.POINT
    $pt.X = 0; $pt.Y = 0
    [void][MtL4.Native]::ClientToScreen($proc.MainWindowHandle, [ref]$pt)

    $winW = $wr.Right - $wr.Left
    $winH = $wr.Bottom - $wr.Top
    $cliW = $cr.Right - $cr.Left
    $cliH = $cr.Bottom - $cr.Top

    # 坐标虚拟化判据：窗口 DPI / 系统 DPI。
    #   已 aware: 窗口 DPI 144 / 系统 DPI 144 = 1     => 坐标即物理像素
    #   unaware : 窗口 DPI 144 / 系统 DPI 96  = 1.5   => SetCursorPos 需要物理像素，点前乘 1.5
    $dpiWin = [MtL4.Native]::GetDpiForWindow($proc.MainWindowHandle)
    $dpiSys = [MtL4.Native]::GetDpiForSystem()
    $pointScale = if ($dpiSys -gt 0 -and $dpiWin -gt 0) { [double]$dpiWin / [double]$dpiSys } else { 1.0 }

    return [pscustomobject]@{
        ProcessName    = $proc.ProcessName
        Pid            = $proc.Id
        Handle         = $proc.MainWindowHandle
        X              = $pt.X                # 客户区屏幕原点
        Y              = $pt.Y
        Width          = $cliW                # 客户区尺寸
        Height         = $cliH
        WindowX        = $wr.Left
        WindowY        = $wr.Top
        WindowWidth    = $winW
        WindowHeight   = $winH
        HasBorder      = (($winW -ne $cliW) -or ($winH -ne $cliH) -or ($wr.Left -ne $pt.X) -or ($wr.Top -ne $pt.Y))
        Dpi            = $dpiWin
        SystemDpi      = $dpiSys
        PointScale     = [Math]::Round($pointScale, 4)   # 截图/客户区坐标 → SetCursorPos 物理像素
    }
}

# 当前前台窗口是谁
function Get-ForegroundInfo {
    $h = [MtL4.Native]::GetForegroundWindow()
    $fgPid = [uint32]0
    [void][MtL4.Native]::GetWindowThreadProcessId($h, [ref]$fgPid)
    $name = "PID $fgPid"
    try { $name = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { }
    return [pscustomobject]@{ Handle = $h; Pid = $fgPid; ProcessName = $name }
}

# 游戏是否在前台。不在前台就不允许截图/点击（否则会截到别的窗口）
function Test-GameForeground {
    param([string]$ProcessName = 'MessageFromAliens')
    $fg = Get-ForegroundInfo
    $game = Get-GameWindow -ProcessName $ProcessName
    if (-not $game) {
        return [pscustomobject]@{ Ok = $false; Reason = '找不到游戏窗口'; Foreground = $fg }
    }
    $ok = ($fg.Handle -eq $game.Handle) -or ($fg.ProcessName -eq $ProcessName)
    $reason = if ($ok) { '' } else { "当前前台是 $($fg.ProcessName)" }
    return [pscustomobject]@{ Ok = $ok; Reason = $reason; Foreground = $fg }
}

# 画面存活判定：直接统计像素缓冲里的「亮像素数」与「颜色种类数」。
# 注意：不能用稀疏 GetPixel 采样 —— 这个游戏的笔画很细，隔 40px 采样会全部落在黑底上，
# 把正常画面误判成黑屏（第一版就踩了这个坑）。
function Test-FrameAlive {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [int]$MinInkPixels = 400,        # 1920x1080 下的下限（全屏 2M 像素，正常画面约 1-3 万），按面积等比缩放
        [int]$MinDistinctColors = 4,
        [int]$Step = 4,
        [int]$ReferenceHeight = 1080
    )
    # 4K 下像素数是 4 倍，阈值与采样步长都跟着缩放，否则阈值偏高、耗时翻倍
    $scale = $Bitmap.Height / $ReferenceHeight
    if ($scale -le 0) { $scale = 1.0 }
    $minInk = [int]($MinInkPixels * $scale * $scale)
    $step = [Math]::Max(1, [int][Math]::Round($Step * $scale))

    $pb = Get-PixelBuffer -Bmp $Bitmap
    $st = [MtGV5.QuickOps]::InkStats($pb.Buf, $pb.Width, $pb.Height, $pb.Stride, $step, 60)
    if ($st[1] -lt $MinDistinctColors) { return $false }
    return ($st[0] -ge $minInk)
}

# 截取游戏窗口当前帧。失败一律 throw CAPTURE_FAIL:...
#
# Method:
#   GDI         屏幕抓取（CopyFromScreen）—— 必须在前台，否则截到别的窗口
#   PrintWindow 向窗口要一幅渲染结果 —— 可以截后台窗口，但硬件合成（D3D）窗口常返回黑帧
#   Auto        前台时用 GDI；后台时尝试 PrintWindow
function Capture-GameFrame {
    param(
        [string]$ProcessName = 'MessageFromAliens',
        [ValidateSet('GDI', 'PrintWindow', 'Auto')][string]$Method = 'Auto'
    )

    $win = Get-GameWindow -ProcessName $ProcessName
    if (-not $win) {
        throw "CAPTURE_FAIL: 找不到游戏窗口（进程 $ProcessName）"
    }
    if ($win.Width -le 0 -or $win.Height -le 0) {
        throw "CAPTURE_FAIL: 窗口尺寸异常 $($win.Width)x$($win.Height)"
    }

    $fgCheck = Test-GameForeground -ProcessName $ProcessName
    $inFront = $fgCheck.Ok
    $used = $null
    $bmp = $null

    if ($Method -eq 'GDI' -or ($Method -eq 'Auto' -and $inFront)) {
        if (-not $inFront) {
            throw "CAPTURE_FAIL: 游戏不在前台（$($fgCheck.Reason)），GDI 截屏会截到别的窗口。请切回游戏，或用 -Method PrintWindow。"
        }
        $bmp = [System.Drawing.Bitmap]::new($win.Width, $win.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.CopyFromScreen($win.X, $win.Y, 0, 0, [System.Drawing.Size]::new($win.Width, $win.Height))
        }
        catch {
            $g.Dispose()
            $bmp.Dispose()
            throw "CAPTURE_FAIL: CopyFromScreen 失败（可能是独占全屏） - $($_.Exception.Message)"
        }
        finally {
            $g.Dispose()
        }
        $used = 'GDI'
    }
    else {
        # 后台截屏：向窗口索取渲染内容（PrintWindow 只能整窗，有边框时再裁到客户区）
        $bmp = [System.Drawing.Bitmap]::new($win.WindowWidth, $win.WindowHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        try {
            $ok = [MtL4.Native]::PrintWindow($win.Handle, $hdc, 2)   # 2 = PW_RENDERFULLCONTENT
        }
        finally {
            $g.ReleaseHdc($hdc)
            $g.Dispose()
        }
        $used = 'PrintWindow'
        if (-not $ok) {
            $bmp.Dispose()
            throw "CAPTURE_FAIL: PrintWindow 调用失败（窗口可能拒绝渲染）"
        }
        if ($win.HasBorder) {
            $ox = $win.X - $win.WindowX
            $oy = $win.Y - $win.WindowY
            $cw = [Math]::Min($win.Width, $win.WindowWidth - $ox)
            $ch = [Math]::Min($win.Height, $win.WindowHeight - $oy)
            if ($cw -le 0 -or $ch -le 0) {
                $bmp.Dispose()
                throw "CAPTURE_FAIL: 客户区几何异常（$cw x $ch）"
            }
            $crop = $bmp.Clone([System.Drawing.Rectangle]::new($ox, $oy, $cw, $ch), $bmp.PixelFormat)
            $bmp.Dispose()
            $bmp = $crop
        }
    }

    if (-not (Test-FrameAlive -Bitmap $bmp)) {
        $bmp.Dispose()
        if ($used -eq 'PrintWindow') {
            throw "CAPTURE_FAIL: PrintWindow 拿到黑帧（该游戏是硬件合成窗口）。后台截屏需要 Windows Graphics Capture，请先把游戏切到前台。"
        }
        throw "CAPTURE_FAIL: 画面近似空白/全黑，可能没截到内容"
    }

    return [pscustomobject]@{
        Bitmap       = $bmp
        Window       = $win
        Method       = $used
        InForeground = $inFront
        Scale        = $bmp.Height / 1080.0    # 参考空间（1920x1080）→ 截图像素的倍数
    }
}

function Save-Frame {
    param([System.Drawing.Bitmap]$Bitmap, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $Path
}
