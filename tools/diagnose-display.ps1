# diagnose-display.ps1 —— 显示器 / DPI / 游戏窗口几何诊断（只读，不改任何状态）
#
# 用法： pwsh -NoProfile -File .\tools\diagnose-display.ps1
#        可选 -ProcessName <游戏进程名>
#
# 输出的关键三行：
#   awareness  进程当前的 DPI 感知级别（0=unaware 1=system 2=per-monitor）
#   scale      「截图坐标 → 物理像素」的换算因子（1 = 1:1，无需换算）
#   client     客户区尺寸与屏幕位置（截屏/点击都用它）

[CmdletBinding()]
param([string]$ProcessName = 'MessageFromAliens')

$ErrorActionPreference = 'Stop'

if (-not ([System.Management.Automation.PSTypeName]'MtLD.Display').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MtLD {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcRect, IntPtr dwData);

    public class Display {
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
    }
}
'@ -ErrorAction Stop
}

function Get-AwarenessName([int]$level) {
    switch ($level) {
        0 { 'unaware（坐标被系统虚拟化，需要换算）' }
        1 { 'system（按主屏 DPI 虚拟化，需要换算）' }
        2 { 'per-monitor（物理像素，1:1）' }
        default { "未知($level)" }
    }
}

Write-Host "`n=== 运行时 ===" -ForegroundColor Cyan
Write-Host ("PowerShell      : {0}" -f $PSVersionTable.PSVersion.ToString())
Write-Host ("OS              : {0}" -f [Environment]::OSVersion.VersionString)

$before = [MtLD.Display]::GetAwarenessFromDpiAwarenessContext([MtLD.Display]::GetThreadDpiAwarenessContext())
Write-Host "`n=== DPI ===" -ForegroundColor Cyan
Write-Host ("awareness（启动时）: {0} = {1}" -f $before, (Get-AwarenessName $before))
Write-Host ("GetDpiForSystem : {0}" -f [MtLD.Display]::GetDpiForSystem())
Write-Host ("主屏分辨率      : {0} x {1}" -f [MtLD.Display]::GetSystemMetrics(0), [MtLD.Display]::GetSystemMetrics(1))

$monitors = New-Object System.Collections.Generic.List[object]
$cb = [MtLD.MonitorEnumProc] {
    param([IntPtr]$hMonitor, [IntPtr]$hdc, [IntPtr]$lprc, [IntPtr]$data)
    $mi = New-Object MtLD.MONITORINFOEX
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][MtLD.MONITORINFOEX])
    if ([MtLD.Display]::GetMonitorInfo($hMonitor, [ref]$mi)) {
        $monitors.Add([pscustomobject]@{
                Device = $mi.szDevice
                X      = $mi.rcMonitor.Left
                Y      = $mi.rcMonitor.Top
                Width  = ($mi.rcMonitor.Right - $mi.rcMonitor.Left)
                Height = ($mi.rcMonitor.Bottom - $mi.rcMonitor.Top)
                Primary = (($mi.dwFlags -band 1) -ne 0)
            })
    }
    return $true
}
[void][MtLD.Display]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)

Write-Host "`n=== 显示器 ===" -ForegroundColor Cyan
foreach ($m in $monitors) {
    Write-Host ("{0,-20} {1}x{2} @ ({3},{4}) {5}" -f $m.Device, $m.Width, $m.Height, $m.X, $m.Y, $(if ($m.Primary) { '[主屏]' } else { '' }))
}

Write-Host "`n=== 游戏窗口 ===" -ForegroundColor Cyan
$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) {
    Write-Host ("进程 {0} 没有窗口（游戏未运行）" -f $ProcessName) -ForegroundColor DarkGray
}
else {
    $h = $proc.MainWindowHandle
    $wr = New-Object MtLD.RECT
    [void][MtLD.Display]::GetWindowRect($h, [ref]$wr)
    $cr = New-Object MtLD.RECT
    [void][MtLD.Display]::GetClientRect($h, [ref]$cr)
    $pt = New-Object MtLD.POINT
    [void][MtLD.Display]::ClientToScreen($h, [ref]$pt)

    $winW = $wr.Right - $wr.Left
    $winH = $wr.Bottom - $wr.Top
    $cliW = $cr.Right - $cr.Left
    $cliH = $cr.Bottom - $cr.Top
    $hasBorder = ($winW -ne $cliW) -or ($winH -ne $cliH) -or ($wr.Left -ne $pt.X) -or ($wr.Top -ne $pt.Y)

    Write-Host ("窗口 rect   : {0}x{1} @ ({2},{3})" -f $winW, $winH, $wr.Left, $wr.Top)
    Write-Host ("客户区      : {0}x{1} @ ({2},{3})  非客户区= {4}" -f $cliW, $cliH, $pt.X, $pt.Y, $(if ($hasBorder) { '有（截屏要按客户区）' } else { '无（无边框全屏）' }))
    $dpiWin = [MtLD.Display]::GetDpiForWindow($h)
    $dpiSys = [MtLD.Display]::GetDpiForSystem()
    $pointScale = if ($dpiSys -gt 0 -and $dpiWin -gt 0) { [double]$dpiWin / [double]$dpiSys } else { 1.0 }
    Write-Host ("窗口 DPI    : {0}   系统 DPI: {1}   点缩放: {2:N3}" -f $dpiWin, $dpiSys, $pointScale)

    $refW = 1920
    Write-Host ("相对 1920x1080 的缩放: {0:N4} x {1:N4}" -f ($cliW / $refW), ($cliH / 1080))

    Write-Host "`n=== 建议 ===" -ForegroundColor Cyan
    if ($before -lt 2) {
        Write-Host "进程启动时不是 per-monitor DPI aware，但坐标是否会被虚拟化要看「点缩放」：" -ForegroundColor Yellow
        Write-Host "  = 1   坐标即物理像素，截图/点击 1:1" -ForegroundColor Yellow
        Write-Host "  ≠ 1   坐标被虚拟化（如 4K@150% 的 unaware 进程 = 1.5），点击需 ×点缩放" -ForegroundColor Yellow
    }
    else {
        Write-Host "✓ per-monitor DPI aware：截图坐标 == 屏幕物理像素，点击 1:1" -ForegroundColor Green
    }
}
