# tools/preview-crops.ps1 —— 把每格「固定内缩后的裁剪图」拼成一张对照图
#
# 用途：肉眼核对「符号是否正好贴住裁剪框的边」。
# 每个裁剪图单独放大，四周画红框（=实际裁剪边界），下方标 ID/行列/尺寸。
#
# 用法：
#   .\tools\preview-crops.ps1                # 重新抓帧
#   .\tools\preview-crops.ps1 -NoCapture     # 用上次观察缓冲
#   .\tools\preview-crops.ps1 -BlockId 3     # 只看某一块

[CmdletBinding()]
param(
    [switch]$NoCapture,
    [int]$BlockId = 0,
    [int]$Tile = 200,
    [int]$Cols = 8
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\api\game-api.ps1')
Add-Type -AssemblyName System.Drawing

$api = Initialize-GameApi -Root $root -OutDir (Join-Path $root ('runs\crops-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if (-not $NoCapture) {
    $null = Set-GameForeground
    $obs = Get-GameObservation -Force
}
else {
    $obs = Get-GameObservation
}

$src = [System.Drawing.Bitmap]::FromFile($obs.Image)
$blocks = @($obs.Blocks | Where-Object { $BlockId -eq 0 -or $_.BlockId -eq $BlockId })

$items = New-Object System.Collections.Generic.List[object]
foreach ($b in $blocks) {
    foreach ($c in @($api.Grids[$b.BlockId].Cells)) { $items.Add($c) }
}
if ($items.Count -eq 0) { $src.Dispose(); throw '没有格子' }

$rows = [int][Math]::Ceiling($items.Count / [double]$Cols)
$pad = 6
$labelH = 26
$tileW = $Tile
$tileH = $Tile + $labelH
$outW = $Cols * ($tileW + $pad) + $pad
$outH = $rows * ($tileH + $pad) + $pad
$canvas = New-Object System.Drawing.Bitmap $outW, $outH
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.Clear([System.Drawing.Color]::FromArgb(24, 24, 24))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Crimson), 1
$font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$brushGray = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Silver)

$i = 0
foreach ($c in $items) {
    $col = $i % $Cols
    $row = [int][Math]::Floor($i / $Cols)
    $x = $pad + $col * ($tileW + $pad)
    $y = $pad + $row * ($tileH + $pad)
    $rect = [System.Drawing.Rectangle]::new($c.CropX, $c.CropY, $c.CropW, $c.CropH)
    $crop = $src.Clone($rect, $src.PixelFormat)
    $g.DrawImage($crop, (New-Object System.Drawing.Rectangle $x, $y, $tileW, $Tile))
    $crop.Dispose()
    $g.DrawRectangle($pen, $x, $y, $tileW - 1, $Tile - 1)
    $toneMark = $(if ($c.Tone -eq 'gray') { '`' } else { '' })
    $text = '{0} {1}x{2}{3}' -f $c.SymbolId, $c.CropW, $c.CropH, $toneMark
    $g.DrawString($text, $font, $(if ($c.Tone -eq 'gray') { $brushGray } else { $brush }), $x, ($y + $Tile + 4))
    $i++
}

$g.Dispose()
$out = Join-Path $api.OutDir 'crops.png'
$canvas.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose()
$src.Dispose()
Write-Output $out
