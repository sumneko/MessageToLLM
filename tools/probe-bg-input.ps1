# probe-bg-input.ps1 —— 后台点击/输入可行性探针
#
# 目的：不切前台、不动物理鼠标，用窗口消息（WM_LBUTTONDOWN 等）把点击投递给游戏，
#       再用 PrintWindow 前后帧差判断游戏到底吃不吃这些消息。
#       这是「能不能全后台玩」的唯一判据 —— 帧差有反应 => 能；没反应 => 引擎走 RawInput，只能上 VM。
#
# 用法（与仓库其它脚本一致，用 pwsh 7 跑；5.1 读 UTF-8 注释会串行）：
#   pwsh -NoProfile -File .\tools\probe-bg-input.ps1
#   .\tools\probe-bg-input.ps1                        # 点客户区中心（1920x1080 参考坐标 960,540）
#   .\tools\probe-bg-input.ps1 -RefX 300 -RefY 820    # 点一个有反馈的位置（菜单按钮/可交互物）
#   .\tools\probe-bg-input.ps1 -TestKey 32            # 额外试一次按键（32 = VK_SPACE）
#
# 判读：
#   Noise   基线噪声，必须足够小（≈0），否则结论不可信
#   Clicks  依次尝试：PostMessage → PostMessage+伪造激活 → SendMessage
#   帧差 > max(0.0005, Noise×10)  =>  接受（该点击被游戏处理了）
#   全部 ≈ Noise                  =>  不接受（换 VM / 独立会话）

[CmdletBinding()]
param(
    [string]$ProcessName = 'MessageFromAliens',
    [double]$RefX = 960,
    [double]$RefY = 540,
    [double]$RefWidth = 1920,
    [double]$RefHeight = 1080,
    [int]$WaitMs = 400,
    [int]$TestKey = 0,
    [ValidateSet('Left', 'Right')][string]$Button = 'Left',
    [switch]$ActivateOnly,      # 只投 WM_ACTIVATE/WM_SETFOCUS，不点 —— 用来隔离「激活」本身的影响
    [switch]$TestAll,           # 不因首个有反应的方式提前退出，全部试完
    [int]$RawMsg = 0,           # 单条消息模式：只 Post 这一条（十进制或 0x 前缀）
    [int64]$RawWParam = 0,
    [switch]$HoldClick,         # 按住模式：Post 下压 → 等待 → 拍帧 → 再弹起（捕捉「按住才显示」的反馈）
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\act\mouse.ps1')   # 同时带出 capture.ps1 / common.ps1 / Get-FrameDiffRatio

if (-not ([System.Management.Automation.PSTypeName]'MtPI.Wm').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MtPI {
    public class Wm {
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    }
}
'@ -ErrorAction Stop
}

# MSG 常量
$script:WM_ACTIVATE    = 0x0006
$script:WM_SETFOCUS    = 0x0007
$script:WM_KEYDOWN     = 0x0100
$script:WM_KEYUP       = 0x0101
$script:WM_MOUSEMOVE   = 0x0200
$script:WM_LBUTTONDOWN = 0x0201
$script:WM_LBUTTONUP   = 0x0202
$script:WM_RBUTTONDOWN = 0x0204
$script:WM_RBUTTONUP   = 0x0205
$script:MK_LBUTTON     = 1
$script:MK_RBUTTON     = 2

if (-not $OutDir) {
    $OutDir = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'runs\probe') (Get-Date -Format 'yyyyMMdd-HHmmss')
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Pack-LParam {
    param([int]$X, [int]$Y)
    return [IntPtr]::new(([int64]($Y -band 0xFFFF) -shl 16) -bor [int64]($X -band 0xFFFF))
}

# 投递一次点击。返回消息是否被窗口收下（Post 看返回值，Send 不抛异常即算）
function Invoke-WmClick {
    param(
        [IntPtr]$Handle,
        [int]$ClientX,
        [int]$ClientY,
        [ValidateSet('Post', 'Send', 'None')][string]$Mode = 'Post',
        [switch]$Activate
    )
    $lp = Pack-LParam -X $ClientX -Y $ClientY
    $posted = $true
    $call = {
        param([uint32]$Msg, [IntPtr]$W, [IntPtr]$L)
        if ($Mode -eq 'None') { return $true }
        if ($Mode -eq 'Send') {
            [void][MtPI.Wm]::SendMessage($Handle, $Msg, $W, $L)
            return $true
        }
        $r = [MtPI.Wm]::PostMessage($Handle, $Msg, $W, $L)
        return ($r -ne [IntPtr]::Zero)
    }

    if ($Activate) {
        # 有些引擎只在窗口「认为自己激活」时才处理输入：先伪造激活再点
        [void](& $call $script:WM_ACTIVATE ([IntPtr]::new(1)) ([IntPtr]::Zero))
        [void](& $call $script:WM_SETFOCUS ([IntPtr]::Zero) ([IntPtr]::Zero))
        Start-Sleep -Milliseconds 60
    }

    [void](& $call $script:WM_MOUSEMOVE ([IntPtr]::Zero) $lp)
    Start-Sleep -Milliseconds 30
    $downMsg = if ($Button -eq 'Right') { $script:WM_RBUTTONDOWN } else { $script:WM_LBUTTONDOWN }
    $upMsg = if ($Button -eq 'Right') { $script:WM_RBUTTONUP } else { $script:WM_LBUTTONUP }
    $mk = if ($Button -eq 'Right') { $script:MK_RBUTTON } else { $script:MK_LBUTTON }
    $downOk = & $call $downMsg ([IntPtr]::new($mk)) $lp
    Start-Sleep -Milliseconds 40
    $upOk = & $call $upMsg ([IntPtr]::Zero) $lp
    $posted = ([bool]$downOk -and [bool]$upOk)

    return [pscustomobject]@{
        Mode     = $(if ($Activate) { "$Button-$Mode+Activate" } else { "$Button-$Mode" })
        Posted   = $posted
        ClientX  = $ClientX
        ClientY  = $ClientY
    }
}

function Invoke-WmKey {
    param([IntPtr]$Handle, [int]$VirtualKey, [ValidateSet('Post', 'Send')][string]$Mode = 'Post')
    $scan = [MtPI.Wm]::MapVirtualKey([uint32]$VirtualKey, 0)
    $lpDown = [IntPtr]::new(([int64]1 -shl 16) -bor [int64]($scan -band 0xFF))
    $lpUp = [IntPtr]::new(([int64]1 -shl 30) -bor ([int64]3 -shl 16) -bor [int64]($scan -band 0xFF))
    if ($Mode -eq 'Send') {
        [void][MtPI.Wm]::SendMessage($Handle, $script:WM_KEYDOWN, [IntPtr]::new($VirtualKey), $lpDown)
        Start-Sleep -Milliseconds 40
        [void][MtPI.Wm]::SendMessage($Handle, $script:WM_KEYUP, [IntPtr]::new($VirtualKey), $lpUp)
        return $true
    }
    $a = [MtPI.Wm]::PostMessage($Handle, $script:WM_KEYDOWN, [IntPtr]::new($VirtualKey), $lpDown)
    Start-Sleep -Milliseconds 40
    $b = [MtPI.Wm]::PostMessage($Handle, $script:WM_KEYUP, [IntPtr]::new($VirtualKey), $lpUp)
    return (($a -ne [IntPtr]::Zero) -and ($b -ne [IntPtr]::Zero))
}

function Get-ProbeFrame {
    param([string]$ProcessName)
    return (Capture-GameFrame -ProcessName $ProcessName -Method PrintWindow)
}

# ---------- 前置检查 ----------

$win = Get-GameWindow -ProcessName $ProcessName
if (-not $win) {
    Write-Host "FAIL: 找不到游戏窗口（进程 $ProcessName）" -ForegroundColor Red
    exit 2
}

$fg = Get-ForegroundInfo
$gameInFront = ($fg.Handle -eq $win.Handle) -or ($fg.ProcessName -eq $ProcessName)

Write-Host "== 窗口 ==" -ForegroundColor Cyan
$win | Format-List ProcessName, Pid, Handle, X, Y, Width, Height, HasBorder, Dpi, SystemDpi, PointScale

if ($gameInFront) {
    Write-Host "警告: 游戏当前在前台。为了验证「真后台」，请先点一下别的窗口（比如这个终端）再跑。" -ForegroundColor Yellow
}

$sx = $win.Width / $RefWidth
$sy = $win.Height / $RefHeight
$cx = [int][Math]::Round($RefX * $sx)
$cy = [int][Math]::Round($RefY * $sy)
Write-Host "目标点: 参考($RefX,$RefY) => 客户区($cx,$cy)" -ForegroundColor Cyan

# ---------- 后台可观测性（没有它什么都测不了） ----------

try {
    $f0 = Get-ProbeFrame -ProcessName $ProcessName
    Save-Frame -Bitmap $f0.Bitmap -Path (Join-Path $OutDir 'alive.png') | Out-Null
    $f0.Bitmap.Dispose()
    Write-Host "后台截图: OK（PrintWindow 拿到活帧）" -ForegroundColor Green
}
catch {
    Write-Host "STOP: 后台截不到活帧 —— $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "没有后台观测手段，就无法验证后台输入。先解决 WM 消息 / Windows Graphics Capture 再看输入。" -ForegroundColor Yellow
    exit 3
}

# ---------- 基线噪声：不发任何输入，连拍两帧 ----------

$b1 = Get-ProbeFrame -ProcessName $ProcessName
Start-Sleep -Milliseconds $WaitMs
$b2 = Get-ProbeFrame -ProcessName $ProcessName
$noise = Get-FrameDiffRatio -Before $b1.Bitmap -After $b2.Bitmap
$b1.Bitmap.Dispose(); $b2.Bitmap.Dispose()

$threshold = [Math]::Max(0.0005, $noise * 10)
Write-Host ("基线噪声: {0:P4}    判定阈值: {1:P4}" -f $noise, $threshold) -ForegroundColor Cyan

# ---------- 按住模式：下压 → 拍帧 → 弹起（"按住才显示"的反馈只有这样才能看到） ----------

if ($HoldClick) {
    $lp = Pack-LParam -X $cx -Y $cy
    $downMsg = if ($Button -eq 'Right') { $script:WM_RBUTTONDOWN } else { $script:WM_LBUTTONDOWN }
    $upMsg = if ($Button -eq 'Right') { $script:WM_RBUTTONUP } else { $script:WM_LBUTTONUP }
    $mk = if ($Button -eq 'Right') { $script:MK_RBUTTON } else { $script:MK_LBUTTON }
    $before = Get-ProbeFrame -ProcessName $ProcessName
    [void][MtPI.Wm]::PostMessage($win.Handle, $script:WM_MOUSEMOVE, [IntPtr]::Zero, $lp)
    Start-Sleep -Milliseconds 30
    [void][MtPI.Wm]::PostMessage($win.Handle, [uint32]$downMsg, [IntPtr]::new($mk), $lp)
    Start-Sleep -Milliseconds $WaitMs
    $mid = Get-ProbeFrame -ProcessName $ProcessName
    [void][MtPI.Wm]::PostMessage($win.Handle, [uint32]$upMsg, [IntPtr]::Zero, $lp)
    $diff = Get-FrameDiffRatio -Before $before.Bitmap -After $mid.Bitmap
    $before.Bitmap.Dispose()
    Save-Frame -Bitmap $mid.Bitmap -Path (Join-Path $OutDir 'held.png') | Out-Null
    $mid.Bitmap.Dispose()
    Write-Host ("按住({0},{1}) {2}ms 后帧差: {3:P4}    阈值: {4:P4}    => {5}" -f $cx, $cy, $WaitMs, $diff, $threshold, $(if ($diff -gt $threshold) { 'CHANGED' } else { 'no change' }))
    if ($diff -gt $threshold) { exit 0 } else { exit 1 }
}

# ---------- 单条消息模式：隔离变量用（比如只投 WM_LBUTTONUP 看是否「按键卡住」） ----------

if ($RawMsg -gt 0) {
    $before = Get-ProbeFrame -ProcessName $ProcessName
    $lp = Pack-LParam -X $cx -Y $cy
    $r = [MtPI.Wm]::PostMessage($win.Handle, [uint32]$RawMsg, [IntPtr]::new($RawWParam), $lp)
    Start-Sleep -Milliseconds $WaitMs
    $after = Get-ProbeFrame -ProcessName $ProcessName
    $diff = Get-FrameDiffRatio -Before $before.Bitmap -After $after.Bitmap
    $before.Bitmap.Dispose()
    Save-Frame -Bitmap $after.Bitmap -Path (Join-Path $OutDir ("after-raw-0x{0:X}.png" -f $RawMsg)) | Out-Null
    $after.Bitmap.Dispose()
    Write-Host ("单条消息 WM=0x{0:X} wParam={1} lParam=(x={2},y={3})  Post 返回={4}" -f $RawMsg, $RawWParam, $cx, $cy, $r) -ForegroundColor Cyan
    Write-Host ("帧差: {0:P4}    阈值: {1:P4}    => {2}" -f $diff, $threshold, $(if ($diff -gt $threshold) { 'CHANGED' } else { 'no change' }))
    if ($diff -gt $threshold) { exit 0 } else { exit 1 }
}

# ---------- 逐个尝试投递方式 ----------

$results = @()

function Test-Action {
    param(
        [string]$Label,
        [scriptblock]$Deliver,
        [System.Drawing.Bitmap]$Before
    )
    $accepted = $false
    try { $accepted = [bool](& $Deliver) } catch { $accepted = $false }
    Start-Sleep -Milliseconds $WaitMs
    $after = Get-ProbeFrame -ProcessName $ProcessName
    $diff = Get-FrameDiffRatio -Before $Before -After $after.Bitmap
    return [pscustomobject]@{
        Action   = $Label
        Accepted = $accepted
        FrameDiff = $diff
        Bitmap   = $after.Bitmap
    }
}

$attempts = @(
    @{ Label = "$Button(Post)";          Mode = 'Post'; Activate = $false },
    @{ Label = "$Button(Post+Activate)"; Mode = 'Post'; Activate = $true },
    @{ Label = "$Button(Send)";          Mode = 'Send'; Activate = $false }
)
if ($ActivateOnly) {
    $attempts = @(@{ Label = 'ActivateOnly(no click)'; Mode = 'None'; Activate = $true })
}

foreach ($a in $attempts) {
    $before = Get-ProbeFrame -ProcessName $ProcessName
    $r = Test-Action -Label $a.Label -Before $before.Bitmap -Deliver ({
                (Invoke-WmClick -Handle $win.Handle -ClientX $cx -ClientY $cy -Mode $a.Mode -Activate:$a.Activate).Posted
            }).GetNewClosure()
    $before.Bitmap.Dispose()
    Save-Frame -Bitmap $r.Bitmap -Path (Join-Path $OutDir ("after-{0}.png" -f ($a.Label -replace '[^A-Za-z]', '-'))) | Out-Null
    $r.Bitmap.Dispose()
    $results += $r
    if ($r.FrameDiff -gt $threshold -and -not $TestAll) { break }   # 已经有反应，不用再试更激进的方式
}

if ($TestKey -gt 0 -and (($results | Measure-Object -Property FrameDiff -Maximum).Maximum -le $threshold)) {
    $before = Get-ProbeFrame -ProcessName $ProcessName
    $r = Test-Action -Label "Key($TestKey)" -Before $before.Bitmap -Deliver ({
                Invoke-WmKey -Handle $win.Handle -VirtualKey $TestKey -Mode 'Post'
            }).GetNewClosure()
    $before.Bitmap.Dispose()
    Save-Frame -Bitmap $r.Bitmap -Path (Join-Path $OutDir 'after-key.png') | Out-Null
    $r.Bitmap.Dispose()
    $results += $r
}

# ---------- 结论 ----------

Write-Host "`n== 结果 ==" -ForegroundColor Cyan
$results | Format-Table Action, Accepted, @{ n = 'FrameDiff'; e = { '{0:P4}' -f $_.FrameDiff } }, @{ n = 'Verdict'; e = { if ($_.FrameDiff -gt $threshold) { 'CHANGED' } else { 'no change' } } } -AutoSize

$hit = $results | Where-Object { $_.FrameDiff -gt $threshold } | Select-Object -First 1
Write-Host "" 
if ($hit) {
    Write-Host "结论: 接受 —— '$($hit.Action)' 让画面变化 $('{0:P4}' -f $hit.FrameDiff)（阈值 $('{0:P4}' -f $threshold)）" -ForegroundColor Green
    Write-Host "=> 可以全后台驱动：用该方式实现 Invoke-GameClickAt，前台/抢鼠标都不再需要。" -ForegroundColor Green
    Write-Host "   注意确认变化确实来自点击（看一眼 $OutDir 里的 after-*.png），而不是游戏自身的循环动画。" -ForegroundColor DarkGray
    exit 0
}

Write-Host "结论: 不接受 —— 消息被收下（Accepted）但画面没反应，引擎大概率走 RawInput / 轮询，忽略 WM_* 输入。" -ForegroundColor Red
Write-Host "=> 后台点击这条路在这款游戏上关死。要「不占电脑」，改走隔离会话：" -ForegroundColor Yellow
Write-Host "   Hyper-V 虚拟机 / 独立 RDP 会话里跑游戏，输入注入发生在那个会话，物理桌面不受影响。" -ForegroundColor Yellow
Write-Host "   证据帧已存: $OutDir" -ForegroundColor DarkGray
exit 1
