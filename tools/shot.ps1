# shot.ps1 —— 后台截一帧（不抢前台），可选裁出某个格子的符号图形
#
# 用法：
#   pwsh -NoProfile -File .\tools\shot.ps1                          # 整屏 -> runs\shot\frame.png
#   pwsh -NoProfile -File .\tools\shot.ps1 -Out runs\shot\a.png      # 指定输出
#   pwsh -NoProfile -File .\tools\shot.ps1 -Rect 1040,360,80,80      # 裁格子（坐标取自 slots 的 sp）
#   pwsh -NoProfile -File .\tools\shot.ps1 -Rect 1040,360,80,80 -Scale 4   # 放大 4 倍便于看清
#
# 坐标一律用 slots 返回的 sp{sx,sy,w,h}，左上原点，与截图 1:1。

[CmdletBinding()]
param(
    [string]$Out = 'runs\shot\frame.png',
    [string[]]$Rect,        # sx,sy,w,h（可写成 "1040,360,80,80" 或 1040,360,80,80）
    [int]$Scale = 3,        # 仅裁图时放大
    [string]$ProcessName = 'MessageFromAliens'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\act\mouse.ps1')

$full = Join-Path (Split-Path $PSScriptRoot -Parent) ($Out -replace '^\.\\', '')
New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null

$frame = Capture-GameFrame -ProcessName $ProcessName -Method PrintWindow
$bmp = $frame.Bitmap
try {
    if (-not $Rect) {
        Save-Frame -Bitmap $bmp -Path $full | Out-Null
        Write-Host $full
        return
    }

    $p = ($Rect -join ',') -split ','
    if ($p.Count -ne 4) { throw "Rect 需要 sx,sy,w,h 四个数字" }
    $r = New-Object System.Drawing.Rectangle ([int]$p[0]), ([int]$p[1]), ([int]$p[2]), ([int]$p[3])
    if ($r.Right -gt $bmp.Width -or $r.Bottom -gt $bmp.Height) { throw "Rect 超出画面 $($bmp.Width)x$($bmp.Height)" }

    $crop = $bmp.Clone($r, $bmp.PixelFormat)
    $big = New-Object System.Drawing.Bitmap ($r.Width * $Scale), ($r.Height * $Scale)
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = 'NearestNeighbor'
    $g.DrawImage($crop, 0, 0, $big.Width, $big.Height)
    $g.Dispose()
    $big.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()
    $crop.Dispose()
    Write-Host $full
}
finally {
    $bmp.Dispose()
}
