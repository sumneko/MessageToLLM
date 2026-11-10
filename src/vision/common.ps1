# common.ps1 —— 图形切格 / 裁剪 / 最近邻放大 公共函数
# 由 zoom.ps1 / dedupe.ps1 点源引入：   . "$PSScriptRoot\common.ps1"
# 依赖：Windows + .NET System.Drawing（PowerShell 自带，无需安装任何包）

$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
}

# ---------------------------------------------------------------- 读图

function Open-ImagePlain {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = [System.IO.MemoryStream]::new($bytes)
    $src = [System.Drawing.Bitmap]::FromStream($ms)
    $bmp = [System.Drawing.Bitmap]::new($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
    $g.Dispose()
    $src.Dispose()
    $ms.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- 像素缓冲

function Get-PixelBuffer {
    param([System.Drawing.Bitmap]$Bmp)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bmp.Width, $Bmp.Height)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $len = $data.Stride * $Bmp.Height
    $buf = [byte[]]::new($len)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
    $stride = $data.Stride
    $Bmp.UnlockBits($data)
    return [pscustomobject]@{ Buf = $buf; Stride = $stride; Width = $Bmp.Width; Height = $Bmp.Height }
}

# 预计算亮度表（0-255），后面所有判定都基于它
function Get-LumBuffer {
    param($PB)
    $w = $PB.Width
    $h = $PB.Height
    $buf = $PB.Buf
    $stride = $PB.Stride
    $lum = [byte[]]::new($w * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $rowOff = $y * $stride
        $lumOff = $y * $w
        for ($x = 0; $x -lt $w; $x++) {
            $i = $rowOff + $x * 4
            # BGRA
            $lum[$lumOff + $x] = [byte](0.114 * $buf[$i] + 0.587 * $buf[$i + 1] + 0.299 * $buf[$i + 2])
        }
    }
    return [pscustomobject]@{ Lum = $lum; Width = $w; Height = $h }
}

# ---------------------------------------------------------------- 墨迹包围盒

function Get-InkBounds {
    param($LumBuf, [int]$X0, [int]$Y0, [int]$W, [int]$H, [int]$Threshold = 90)
    $minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = -1; $maxY = -1
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $xEnd = [Math]::Min($X0 + $W, $imgW)
    $yEnd = [Math]::Min($Y0 + $H, $imgH)
    for ($y = [Math]::Max(0, $Y0); $y -lt $yEnd; $y++) {
        $rowOff = $y * $imgW
        for ($x = [Math]::Max(0, $X0); $x -lt $xEnd; $x++) {
            if ($LumBuf.Lum[$rowOff + $x] -ge $Threshold) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return $null }
    return [pscustomobject]@{ X = $minX; Y = $minY; W = ($maxX - $minX + 1); H = ($maxY - $minY + 1) }
}

# ---------------------------------------------------------------- 按列投影切分字符

function Get-InkColumnRuns {
    param($LumBuf, [int]$X0, [int]$Y0, [int]$W, [int]$H,
        [int]$Threshold = 90, [int]$MinGap = 3, [int]$MinRun = 6)
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $prof = [int[]]::new($W)
    $yEnd = [Math]::Min($Y0 + $H, $imgH)
    $xEnd = [Math]::Min($X0 + $W, $imgW)
    for ($y = [Math]::Max(0, $Y0); $y -lt $yEnd; $y++) {
        $rowOff = $y * $imgW
        for ($x = [Math]::Max(0, $X0); $x -lt $xEnd; $x++) {
            if ($LumBuf.Lum[$rowOff + $x] -ge $Threshold) { $prof[$x - $X0]++ }
        }
    }
    $runs = New-Object System.Collections.Generic.List[object]
    $inRun = $false; $start = 0; $lastInk = -1
    for ($x = 0; $x -lt $W; $x++) {
        if ($prof[$x] -gt 0) {
            if (-not $inRun) { $inRun = $true; $start = $x }
            $lastInk = $x
        } elseif ($inRun) {
            if (($x - $lastInk) -ge $MinGap) {
                $inRun = $false
                $rw = $lastInk - $start + 1
                if ($rw -ge $MinRun) { $runs.Add([pscustomobject]@{ X = $X0 + $start; W = $rw }) }
            }
        }
    }
    if ($inRun) {
        $rw = $lastInk - $start + 1
        if ($rw -ge $MinRun) { $runs.Add([pscustomobject]@{ X = $X0 + $start; W = $rw }) }
    }
    return $runs
}

# ---------------------------------------------------------------- 按行投影切分行带（图形行/文字行）

function Get-InkRowBands {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$MinBand = 4)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $prof = [int[]]::new($h)
    for ($y = 0; $y -lt $h; $y++) {
        $rowOff = $y * $w
        $c = 0
        for ($x = 0; $x -lt $w; $x++) {
            if ($LumBuf.Lum[$rowOff + $x] -ge $Threshold) { $c++ }
        }
        $prof[$y] = $c
    }
    $bands = New-Object System.Collections.Generic.List[object]
    $inBand = $false; $start = 0; $lastInk = -1
    for ($y = 0; $y -lt $h; $y++) {
        if ($prof[$y] -gt 0) {
            if (-not $inBand) { $inBand = $true; $start = $y }
            $lastInk = $y
        } elseif ($inBand) {
            if (($y - $lastInk) -ge $MinGap) {
                $inBand = $false
                if (($lastInk - $start + 1) -ge $MinBand) {
                    $bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $lastInk })
                }
            }
        }
    }
    if ($inBand -and (($lastInk - $start + 1) -ge $MinBand)) {
        $bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $lastInk })
    }
    return $bands
}

# 识别"图形行"：字形主体很高，文字行很矮，贴在图上的小横线更矮。
# 步骤：1) 切所有墨迹带；2) 间距很小的带先合并（把贴着的横线并进字形行）；
#      3) 只保留高度≥最高的 HeightRatio 倍的带（= 图形行，排除文字行）；
#      4) 再按 PadRatio 略微外扩，但不越过相邻墨迹带。
function Get-GlyphRowBands {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$RowMergeGap = 8,
        [double]$HeightRatio = 0.55, [double]$PadRatio = 0.10)
    $raw = @(Get-InkRowBands -LumBuf $LumBuf -Threshold $Threshold -MinGap $MinGap -MinBand 1)
    if ($raw.Count -eq 0) { return @() }

    # ---- 合并挨得很近的带（横线 + 字形）
    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($b in $raw) {
        if ($merged.Count -gt 0) {
            $last = $merged[$merged.Count - 1]
            $gap = $b.Y0 - $last.Y1 - 1
            if ($gap -le $RowMergeGap) {
                $merged[$merged.Count - 1] = [pscustomobject]@{ Y0 = $last.Y0; Y1 = $b.Y1 }
                continue
            }
        }
        $merged.Add([pscustomobject]@{ Y0 = $b.Y0; Y1 = $b.Y1 })
    }

    $maxH = 0
    foreach ($b in $merged) {
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -gt $maxH) { $maxH = $h }
    }

    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $b = $merged[$i]
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -lt ($maxH * $HeightRatio)) { continue }

        $pad = [int][Math]::Round($h * $PadRatio)
        $y0 = [Math]::Max(0, $b.Y0 - $pad)
        $y1 = [Math]::Min($LumBuf.Height - 1, $b.Y1 + $pad)
        if ($i -gt 0 -and ($merged[$i - 1].Y1 + 2) -gt $y0) { $y0 = [Math]::Max($b.Y0, $merged[$i - 1].Y1 + 2) }
        if ($i -lt ($merged.Count - 1) -and ($merged[$i + 1].Y0 - 2) -lt $y1) { $y1 = [Math]::Min($b.Y1, $merged[$i + 1].Y0 - 2) }
        if ($y1 -lt $b.Y1) { $y1 = $b.Y1 }
        $out.Add([pscustomobject]@{ Y0 = $y0; Y1 = $y1; Body0 = $b.Y0; Body1 = $b.Y1 })
    }
    return $out
}

# ---------------------------------------------------------------- 剥掉分隔线

# 截图边缘经常带进游戏的细长分隔线。它们会：
#   1) 把整行行的包围盒拉大  2) 让列投影处处有墨迹（切成 1 格）
# 判定标准：某一行（列）的墨迹覆盖率 ≥ Coverage，且连续厚度 ≤ MaxThickness → 视为分隔线，直接抹成背景。
# 字形不可能有 45% 以上的整行/整列覆盖，所以不会误伤。
function Remove-SeparatorLines {
    param($LumBuf, [int]$Thresh = 25, [double]$Coverage = 0.90, [int]$MaxThickness = 6)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $lum = $LumBuf.Lum
    $rowTarget = [int]($Coverage * $w)
    $colTarget = [int]($Coverage * $h)
    $killedRows = 0
    $killedCols = 0

    # ---- 水平线
    $rowCov = [double[]]::new($h)
    for ($y = 0; $y -lt $h; $y++) {
        $off = $y * $w
        $c = 0
        for ($x = 0; $x -lt $w; $x++) {
            if ($lum[$off + $x] -ge $Thresh) { $c++ }
        }
        $rowCov[$y] = $c / $w
    }
    $y = 0
    while ($y -lt $h) {
        if ($rowCov[$y] -ge $Coverage) {
            $y0 = $y
            while ($y -lt $h -and $rowCov[$y] -ge $Coverage) { $y++ }
            $y1 = $y - 1
            # 隔离校验：上下邻行不能也很密集（否则是字形本身的密集行）
            $okAbove = ($y0 -eq 0) -or ($rowCov[$y0 - 1] -lt 0.5)
            $okBelow = ($y1 -eq $h - 1) -or ($rowCov[$y1 + 1] -lt 0.5)
            if (($y - $y0) -le $MaxThickness -and $okAbove -and $okBelow) {
                for ($yy = $y0; $yy -le $y1; $yy++) {
                    $off = $yy * $w
                    for ($x = 0; $x -lt $w; $x++) { $lum[$off + $x] = 0 }
                }
                $killedRows += ($y1 - $y0 + 1)
            }
        } else { $y++ }
    }

    # ---- 垂直线
    $colCov = [double[]]::new($w)
    for ($x = 0; $x -lt $w; $x++) {
        $c = 0
        for ($y = 0; $y -lt $h; $y++) {
            if ($lum[$y * $w + $x] -ge $Thresh) { $c++ }
        }
        $colCov[$x] = $c / $h
    }
    $x = 0
    while ($x -lt $w) {
        if ($colCov[$x] -ge $Coverage) {
            $x0 = $x
            while ($x -lt $w -and $colCov[$x] -ge $Coverage) { $x++ }
            $x1 = $x - 1
            $okLeft = ($x0 -eq 0) -or ($colCov[$x0 - 1] -lt 0.5)
            $okRight = ($x1 -eq $w - 1) -or ($colCov[$x1 + 1] -lt 0.5)
            if (($x - $x0) -le $MaxThickness -and $okLeft -and $okRight) {
                for ($xx = $x0; $xx -le $x1; $xx++) {
                    for ($y = 0; $y -lt $h; $y++) { $lum[$y * $w + $xx] = 0 }
                }
                $killedCols += ($x1 - $x0 + 1)
            }
        } else { $x++ }
    }

    return [pscustomobject]@{ Rows = $killedRows; Cols = $killedCols }
}

# 行布局：把图形行和它下面那行文字配成对。游戏里两者都是对齐到同一网格的。
function Get-RowLayout {
    param($LumBuf, [int]$Threshold = 90, [int]$MinGap = 2, [int]$RowMergeGap = 8,
        [double]$HeightRatio = 0.55, [double]$PadRatio = 0.10)
    $raw = @(Get-InkRowBands -LumBuf $LumBuf -Threshold $Threshold -MinGap $MinGap -MinBand 1)
    if ($raw.Count -eq 0) { return @() }

    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($b in $raw) {
        if ($merged.Count -gt 0 -and ($b.Y0 - $merged[$merged.Count - 1].Y1 - 1) -le $RowMergeGap) {
            $merged[$merged.Count - 1] = [pscustomobject]@{ Y0 = $merged[$merged.Count - 1].Y0; Y1 = $b.Y1 }
        } else {
            $merged.Add([pscustomobject]@{ Y0 = $b.Y0; Y1 = $b.Y1 })
        }
    }

    $maxH = 0
    foreach ($b in $merged) {
        $h = $b.Y1 - $b.Y0 + 1
        if ($h -gt $maxH) { $maxH = $h }
    }

    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $b = $merged[$i]
        $h = $b.Y1 - $b.Y0 + 1
        $isGlyph = $h -ge ($maxH * $HeightRatio)

        # 紧随其后、更矮的那个带 = 这行字的翻译栏
        $textIdx = -1
        if ($isGlyph -and ($i + 1) -lt $merged.Count) {
            $nb = $merged[$i + 1]
            $nh = $nb.Y1 - $nb.Y0 + 1
            if ($nh -lt $h -and ($nb.Y0 - $b.Y1) -lt $h) { $textIdx = $i + 1 }
        }

        $pad = [int][Math]::Round($h * $PadRatio)
        $y0 = [Math]::Max(0, $b.Y0 - $pad)
        $y1 = [Math]::Min($LumBuf.Height - 1, $b.Y1 + $pad)
        if ($i -gt 0 -and ($merged[$i - 1].Y1 + 2) -gt $y0) { $y0 = [Math]::Max($b.Y0, $merged[$i - 1].Y1 + 2) }
        if (($i + 1) -lt $merged.Count -and ($merged[$i + 1].Y0 - 2) -lt $y1) { $y1 = [Math]::Min($b.Y1, $merged[$i + 1].Y0 - 2) }
        if ($y1 -lt $b.Y1) { $y1 = $b.Y1 }

        $out.Add([pscustomobject]@{
                Y0        = $y0
                Y1        = $y1
                Kind      = $(if ($isGlyph) { 'glyph' } else { 'text' })
                Body0     = $b.Y0
                Body1     = $b.Y1
                TextIndex = $textIdx
            })
    }
    return $out
}

# 用「标签中心点」反推网格：相邻中心连线取中点当格边界，首尾各向外扩半格。
function Get-GridRects {
    param([double[]]$Centers, [int]$Width)
    $rects = New-Object System.Collections.Generic.List[object]
    $n = $Centers.Count
    if ($n -eq 0) { return $rects }
    for ($i = 0; $i -lt $n; $i++) {
        if ($n -eq 1) {
            $left = 0.0; $right = [double]$Width
        } else {
            if ($i -eq 0) { $left = $Centers[0] - ($Centers[1] - $Centers[0]) / 2 }
            else { $left = ($Centers[$i - 1] + $Centers[$i]) / 2 }
            if ($i -eq $n - 1) { $right = $Centers[$i] + ($Centers[$i] - $Centers[$i - 1]) / 2 }
            else { $right = ($Centers[$i] + $Centers[$i + 1]) / 2 }
        }
        $x0 = [int][Math]::Max(0, [Math]::Round($left))
        $x1 = [int][Math]::Min($Width, [Math]::Round($right))
        if ($x1 -le $x0) { $x1 = [Math]::Min($Width, $x0 + 1) }
        $rects.Add([pscustomobject]@{ X = $x0; W = ($x1 - $x0) })
    }
    return $rects
}

# ---------------------------------------------------------------- 网格坐标

function Get-CellRect {
    param([int]$ImgW, [int]$ImgH, [int]$Rows, [int]$Cols, [int]$Row, [int]$Col, [double]$Inset = 0.02)
    $cellW = $ImgW / $Cols
    $cellH = $ImgH / $Rows
    $x0 = [int][Math]::Round($Col * $cellW + $cellW * $Inset)
    $y0 = [int][Math]::Round($Row * $cellH + $cellH * $Inset)
    $x1 = [int][Math]::Round(($Col + 1) * $cellW - $cellW * $Inset)
    $y1 = [int][Math]::Round(($Row + 1) * $cellH - $cellH * $Inset)
    return [pscustomobject]@{ X = $x0; Y = $y0; W = [Math]::Max(1, $x1 - $x0); H = [Math]::Max(1, $y1 - $y0) }
}

# ---------------------------------------------------------------- 采样向量（用于形状聚类）

function Get-SampleVector {
    param($LumBuf, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$N = 24)
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $v = [double[]]::new($N * $N)
    for ($j = 0; $j -lt $N; $j++) {
        $by0 = $Y + [int][Math]::Floor($j * $H / $N)
        $by1 = $Y + [int][Math]::Floor(($j + 1) * $H / $N) - 1
        if ($by1 -lt $by0) { $by1 = $by0 }
        if ($by1 -ge $imgH) { $by1 = $imgH - 1 }
        for ($i = 0; $i -lt $N; $i++) {
            $bx0 = $X + [int][Math]::Floor($i * $W / $N)
            $bx1 = $X + [int][Math]::Floor(($i + 1) * $W / $N) - 1
            if ($bx1 -lt $bx0) { $bx1 = $bx0 }
            if ($bx1 -ge $imgW) { $bx1 = $imgW - 1 }
            # 块内取最大值：细线不会被点采样漏掉
            $mx = 0
            for ($yy = $by0; $yy -le $by1; $yy++) {
                $rowOff = $yy * $imgW
                for ($xx = $bx0; $xx -le $bx1; $xx++) {
                    $val = $LumBuf.Lum[$rowOff + $xx]
                    if ($val -gt $mx) { $mx = $val }
                }
            }
            $v[$j * $N + $i] = $mx / 255.0
        }
    }
    return , $v
}

function Get-VecDistance {
    param([double[]]$A, [double[]]$B, [double]$FastPath = 0.05)
    # RMS（均方根）距离：结构性差异（多/少一条横线）会被放大，抗锯齿噪声影响小。
    # 另做 ±1 格的平移容差搜索，吸收不同截图的缩放/相位差异。
    $n = [int][Math]::Round([Math]::Sqrt($A.Length))
    $sum = 0.0
    for ($k = 0; $k -lt $A.Length; $k++) {
        $d = $A[$k] - $B[$k]
        $sum += $d * $d
    }
    $base = [Math]::Sqrt($sum / $A.Length)
    if ($base -le $FastPath) { return $base }   # 已经足够像，不必搜平移

    $best = $base
    foreach ($dy in -1, 0, 1) {
        foreach ($dx in -1, 0, 1) {
            if ($dx -eq 0 -and $dy -eq 0) { continue }
            $s = 0.0; $c = 0
            for ($j = 0; $j -lt $n; $j++) {
                $jj = $j + $dy
                if ($jj -lt 0 -or $jj -ge $n) { continue }
                $rowA = $jj * $n
                $rowB = $j * $n
                for ($i = 0; $i -lt $n; $i++) {
                    $ii = $i + $dx
                    if ($ii -lt 0 -or $ii -ge $n) { continue }
                    $d = $A[$rowA + $ii] - $B[$rowB + $i]
                    $s += $d * $d; $c++
                }
            }
            if ($c -gt 0) {
                $r = [Math]::Sqrt($s / $c)
                if ($r -lt $best) { $best = $r }
            }
        }
    }
    return $best
}

# ---------------------------------------------------------------- 输出图片

function Save-CropScaled {
    param(
        [System.Drawing.Bitmap]$Bmp,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [int]$Scale = 1,
        [Parameter(Mandatory)][string]$Path
    )
    if ($W -lt 1) { $W = 1 }
    if ($H -lt 1) { $H = 1 }
    $dw = $W * $Scale
    $dh = $H * $Scale
    $dst = [System.Drawing.Bitmap]::new($dw, $dh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    # 关键：最近邻。双线性/双三次会把 1-2px 的横线糊掉
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $dstRect = [System.Drawing.Rectangle]::new(0, 0, $dw, $dh)
    $srcRect = [System.Drawing.Rectangle]::new($X, $Y, $W, $H)
    $g.DrawImage($Bmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $dst.Dispose()
}
