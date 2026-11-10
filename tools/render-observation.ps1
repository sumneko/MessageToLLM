# tools/render-observation.ps1 —— 把 API 观察结果画成网格图（校验用）
#
# 在截图上叠加：
#   块边框（彩色的粗框 + B<id> 标签）
#   格子边框（黄绿 = high 置信 / 橙 = low / 红 = new）
#   每格左上角标签：r<行>c<列> <符号ID>[<已知译文>]
#   槽位框（品红）
#   左上角图例：图像尺寸 / 缩放 / 块数 / 格数 / 槽位数
#
# 用法：
#   .\tools\render-observation.ps1            # 重新抓帧并渲染
#   .\tools\render-observation.ps1 -NoCapture # 用上次观察缓冲渲染（不重新截图）

[CmdletBinding()]
param(
    [switch]$NoCapture,
    [string]$TransFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\api\game-api.ps1')
Add-Type -AssemblyName System.Drawing

if (-not $TransFile) { $TransFile = Join-Path $root 'data\translations-s.json' }
$trans = @{}
if (Test-Path $TransFile) {
    $json = Get-Content $TransFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $trans[$p.Name] = $p.Value }
}

$api = Initialize-GameApi -Root $root -OutDir (Join-Path $root ('runs\render-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if (-not $NoCapture) {
    $null = Set-GameForeground
    $obs = Get-GameObservation -Force
}
else {
    $obs = Get-GameObservation
}

$bmp = [System.Drawing.Bitmap]::FromFile($obs.Image)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$scale = $bmp.Height / 1080.0

$fontCell = New-Object System.Drawing.Font('Consolas', [float](12 * $scale), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fontBlock = New-Object System.Drawing.Font('Consolas', [float](22 * $scale), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$bgBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 0, 0, 0))
$textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

$palette = @(
    [System.Drawing.Color]::DeepSkyBlue,
    [System.Drawing.Color]::Lime,
    [System.Drawing.Color]::Gold,
    [System.Drawing.Color]::OrangeRed,
    [System.Drawing.Color]::Violet,
    [System.Drawing.Color]::Turquoise,
    [System.Drawing.Color]::HotPink,
    [System.Drawing.Color]::White
)

$cellColors = @{
    high = [System.Drawing.Color]::YellowGreen
    low  = [System.Drawing.Color]::Orange
    new  = [System.Drawing.Color]::Red
}

function Draw-Label {
    param($Graphics, [string]$Text, $Font, [int]$X, [int]$Y)
    $sz = $Graphics.MeasureString($Text, $Font)
    $w = [int][Math]::Ceiling($sz.Width) + 4
    $h = [int][Math]::Ceiling($sz.Height)
    $Graphics.FillRectangle($script:bgBrush, $X, $Y, $w, $h)
    $Graphics.DrawString($Text, $Font, $script:cellBrush ?? $script:textBrush, $X + 2, $Y)
}

$cellTotal = 0
$i = 0
foreach ($b in $obs.Blocks) {
    $color = $palette[$i % $palette.Count]
    $i++
    $penBlock = New-Object System.Drawing.Pen $color, ([float](4 * $scale))
    $g.DrawRectangle($penBlock, $b.X, $b.Y, $b.W - 1, $b.H - 1)
    $penBlock.Dispose()
    Draw-Label -Graphics $g -Text ("B{0}" -f $b.BlockId) -Font $fontBlock -X ($b.X + 4) -Y ($b.Y + 2)

    $grid = $api.Grids[$b.BlockId]
    if ($grid) {
        foreach ($c in $grid.Cells) {
            $cellTotal++
            $cc = $cellColors[$c.Band]
            if (-not $cc) { $cc = [System.Drawing.Color]::White }
            # 淡色细线 = 网格格子（只做定位参考）
            $penGrid = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 90, 90, 90)), ([float](1 * $scale))
            $g.DrawRectangle($penGrid, $c.X, $c.Y, $c.W - 1, $c.H - 1)
            $penGrid.Dispose()
            # 亮色粗线 = 实际裁剪框（采样/裁图/色调都用的它）
            $penCell = New-Object System.Drawing.Pen $cc, ([float](3 * $scale))
            if ($c.Tone -eq 'gray') { $penCell.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash }
            $g.DrawRectangle($penCell, $c.CropX, $c.CropY, $c.CropW - 1, $c.CropH - 1)
            $penCell.Dispose()
            $t = $trans[$c.SymbolId]
            $toneMark = $(if ($c.Tone -eq 'gray') { '`' } else { '' })
            $label = if ($t) { "{0}[{1}]{2}" -f $c.SymbolId, $t, $toneMark }
                     else { "{0}{1}" -f $c.SymbolId, $toneMark }
            $sz = $g.MeasureString($label, $fontCell)
            $lx = $c.CropX
            $ly = $c.CropY
            $g.FillRectangle($bgBrush, $lx, $ly, ([int][Math]::Ceiling($sz.Width) + 4), ([int][Math]::Ceiling($sz.Height)))
            $brushCell = New-Object System.Drawing.SolidBrush $cc
            $g.DrawString($label, $fontCell, $brushCell, $lx + 2, $ly)
            $brushCell.Dispose()
        }
    }
}

foreach ($s in @($obs.Slots)) {
    $x0 = [int][Math]::Round($s.XRel * $bmp.Width)
    $y0 = [int][Math]::Round($s.YRel * $bmp.Height)
    $w = [int][Math]::Round($s.WRel * $bmp.Width)
    $h = [int][Math]::Round($s.HRel * $bmp.Height)
    $penSlot = New-Object System.Drawing.Pen ([System.Drawing.Color]::Magenta), ([float](3 * $scale))
    $g.DrawRectangle($penSlot, $x0, $y0, $w, $h)
    $penSlot.Dispose()
    Draw-Label -Graphics $g -Text ("SLOT B{0}r{1}c{2}" -f $s.BlockId, $s.Row, $s.Col) -Font $fontCell -X $x0 -Y ([Math]::Max(0, $y0 - [int](16 * $scale)))
}

$legend = "img {0}x{1}  scale={2}  blocks={3}  cells={4}  slots={5}" -f $bmp.Width, $bmp.Height, $obs.Scale, @($obs.Blocks).Count, $cellTotal, @($obs.Slots).Count
Draw-Label -Graphics $g -Text $legend -Font $fontBlock -X 8 -Y 8
Draw-Label -Graphics $g -Text '粗框=实际裁剪区(Crop)  细线=网格格子  虚线/后缀`=灰色' -Font $fontCell -X 8 -Y ([int](34 * $scale))

$g.Dispose()
$out = Join-Path $api.OutDir 'grid.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Output $out
