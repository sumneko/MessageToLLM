# capture.ps1 —— 截屏 + 窗口存活校验
#
# 设计原则（用户要求）：截不到图就立刻停，不重试、不猜测、不盲点。
# 所有失败都以 CAPTURE_FAIL: 前缀抛出，调用方负责熔断与通知。

. (Join-Path $PSScriptRoot '..\vision\common.ps1')

if (-not ([System.Management.Automation.PSTypeName]'MtL2.Native').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MtL2 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public class Native {
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
    }
}
'@ -ErrorAction Stop
}

$script:MOUSEEVENTF_LEFTDOWN = 0x0002
$script:MOUSEEVENTF_LEFTUP = 0x0004

# 找到游戏窗口并返回几何信息；找不到返回 $null
function Get-GameWindow {
    param([string]$ProcessName = 'MessageFromAliens')
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { return $null }

    $rect = New-Object MtL2.RECT
    if (-not [MtL2.Native]::GetWindowRect($proc.MainWindowHandle, [ref]$rect)) { return $null }

    return [pscustomobject]@{
        ProcessName = $proc.ProcessName
        Pid         = $proc.Id
        Handle      = $proc.MainWindowHandle
        X           = $rect.Left
        Y           = $rect.Top
        Width       = ($rect.Right - $rect.Left)
        Height      = ($rect.Bottom - $rect.Top)
        Dpi         = [MtL2.Native]::GetDpiForWindow($proc.MainWindowHandle)
    }
}

# 当前前台窗口是谁
function Get-ForegroundInfo {
    $h = [MtL2.Native]::GetForegroundWindow()
    $fgPid = [uint32]0
    [void][MtL2.Native]::GetWindowThreadProcessId($h, [ref]$fgPid)
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
        [int]$MinInkPixels = 400,        # 亮度≥60 的像素数下限（全屏 2M 像素，正常画面约 1-3 万）
        [int]$MinDistinctColors = 4,
        [int]$Step = 4
    )
    $pb = Get-PixelBuffer -Bmp $Bitmap
    $buf = $pb.Buf
    $stride = $pb.Stride
    $w = $pb.Width
    $h = $pb.Height
    $ink = 0
    $colors = New-Object System.Collections.Generic.HashSet[int]
    for ($y = 0; $y -lt $h; $y += $Step) {
        $rowOff = $y * $stride
        for ($x = 0; $x -lt $w; $x += $Step) {
            $i = $rowOff + $x * 4
            $b = $buf[$i]; $g = $buf[$i + 1]; $r = $buf[$i + 2]
            if ((0.114 * $b + 0.587 * $g + 0.299 * $r) -ge 60) { $ink++ }
            $null = $colors.Add((($r -shr 4) -shl 8) -bor (($g -shr 4) -shl 4) -bor ($b -shr 4))
        }
    }
    if ($colors.Count -lt $MinDistinctColors) { return $false }
    return ($ink -ge $MinInkPixels)
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
        # 后台截屏：向窗口索取渲染内容
        $bmp = [System.Drawing.Bitmap]::new($win.Width, $win.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        try {
            $ok = [MtL2.Native]::PrintWindow($win.Handle, $hdc, 2)   # 2 = PW_RENDERFULLCONTENT
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
    }
}

function Save-Frame {
    param([System.Drawing.Bitmap]$Bitmap, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $Path
}
