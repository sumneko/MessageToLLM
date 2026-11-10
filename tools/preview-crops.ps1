# tools/preview-crops.ps1 —— 把每格裁剪图拼成一张对照图
#
# 用途：肉眼核对「符号是否正好贴住裁剪框的边」。
# 每个裁剪图单独放大，四周画红框（=实际裁剪边界），下方标 ID/尺寸。
#
# 用法：
#   .\tools\preview-crops.ps1                # 重新抓帧
#   .\tools\preview-crops.ps1 -NoCapture     # 用上次观察缓冲
#   .\tools\preview-crops.ps1 -BlockId 3     # 只看某一块

[CmdletBinding()]
param(
    [switch]$NoCapture,
    [int]$BlockId = 0,
    [int]$TileSize = 180,
    [int]$Cols = 8
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\api\game-api.ps1')

$api = Initialize-GameApi -Root $root -OutDir (Join-Path $root ('runs\crops-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if (-not $NoCapture) {
    $null = Set-GameForeground
    $obs = Get-GameObservation -Force
}
else {
    $obs = Get-GameObservation
}

$src = [System.Drawing.Bitmap]::FromFile($obs.Image)
$items = @()
foreach ($b in $obs.Blocks) {
    if ($BlockId -ne 0 -and $b.BlockId -ne $BlockId) { continue }
    $gc = $api.Grids[$b.BlockId].Cells
    foreach ($c in $gc) {
        if ($null -ne $c) { $items += $c }
    }
}
if ($items.Count -eq 0) { $src.Dispose(); throw '没有格子' }

$rows = [int][Math]::Ceiling($items.Count / [double]$Cols)
$pad = 8
$labelH = 24
$tileW = $TileSize
$tileH = $TileSize + $labelH
$outW = $Cols * ($tileW + $pad) + $pad
$outH = $rows * ($tileH + $pad) + $pad

$canvas = [System.Drawing.Bitmap]::new([int]$outW, [int]$outH)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.Clear([System.Drawing.Color]::FromArgb(28, 28, 28))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor

$pen = [System.Drawing.Pen]::new([System.Drawing.Color]::Crimson, [float]1)
$font = [System.Drawing.Font]::new('Consolas', [float]12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$brushWhite = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$brushGray = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Silver)

$i = 0
foreach ($c in $items) {
    $col = $i % $Cols
    $row = [int][Math]::Floor($i / $Cols)
    $dx = $pad + $col * ($tileW + $pad)
    $dy = $pad + $row * ($tileH + $pad)

    $srcRect = [System.Drawing.Rectangle]::new([int]$c.CropX, [int]$c.CropY, [int]$c.CropW, [int]$c.CropH)
    $dstRect = [System.Drawing.Rectangle]::new([int]$dx, [int]$dy, [int]$tileW, [int]$TileSize)
    $g.DrawImage($src, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawRectangle($pen, [int]$dx, [int]$dy, [int]($tileW - 1), [int]($TileSize - 1))

    $mark = $(if ($c.Tone -eq 'gray') { '`' } else { '' })
    $text = '{0} {1}{2}' -f $c.SymbolId, [int]$c.CropW, $mark
    $br = $(if ($c.Tone -eq 'gray') { $brushGray } else { $brushWhite })
    $g.DrawString($text, $font, $br, [float]$dx, [float]($dy + $TileSize + 2))
    $i++
}

$g.Dispose()
$out = Join-Path $api.OutDir 'crops.png'
$canvas.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose()
$src.Dispose()
Write-Output $out
