# layout.ps1 —— 版面切分：分隔线 → 块 → 块内网格
#
# 只做机械工作，不含任何「这是什么面板」的判断：
#   Get-SeparatorLines  找分隔线（覆盖率高的细长行/列）
#   Get-PanelBlocks     按分隔线把画面切成块；没有分隔线时退回「列空白带」
#   Get-BlockGrid       块内按行投影切行、按列投影切列，输出每格的位置

. (Join-Path $PSScriptRoot 'common.ps1')

# 从投影数组中找「覆盖率达标且厚度有限」的连续段
function Find-CoverageRuns {
    param([int[]]$Prof, [int]$Total, [double]$Coverage = 0.90, [int]$MaxThickness = 12)
    $out = New-Object System.Collections.Generic.List[object]
    if ($Total -le 0) { return $out }
    $i = 0
    while ($i -lt $Prof.Length) {
        if (($Prof[$i] / $Total) -ge $Coverage) {
            $s = $i
            while ($i -lt $Prof.Length -and ($Prof[$i] / $Total) -ge $Coverage) { $i++ }
            if (($i - $s) -le $MaxThickness) {
                $out.Add([pscustomobject]@{ S = $s; E = ($i - 1) })
            }
        }
        else { $i++ }
    }
    return $out
}

function Get-SeparatorLines {
    param($LumBuf, [int]$Thresh = 25, [double]$Coverage = 0.90, [int]$MaxThickness = 12)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $rp = [MtGV5.QuickOps]::RowProfile($LumBuf.Lum, $w, $h, $Thresh)
    $cp = [MtGV5.QuickOps]::ColProfile($LumBuf.Lum, $w, 0, 0, $w, $h, $Thresh)
    return [pscustomobject]@{
        Rows = @(Find-CoverageRuns -Prof $rp -Total $w -Coverage $Coverage -MaxThickness $MaxThickness)
        Cols = @(Find-CoverageRuns -Prof $cp -Total $h -Coverage $Coverage -MaxThickness $MaxThickness)
    }
}

# 统计区域内墨迹密度（0-1），用于判断块是否为空
function Get-RegionInkDensity {
    param($LumBuf, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Threshold = 90)
    if ($W -le 0 -or $H -le 0) { return 0.0 }
    $prof = [MtGV5.QuickOps]::RowProfile(
        [MtGV5.QuickOps]::CropLum($LumBuf.Lum, $LumBuf.Width, $LumBuf.Height, $X, $Y, $W, $H),
        $W, $H, $Threshold)
    $sum = 0
    foreach ($v in $prof) { $sum += $v }
    return [Math]::Round($sum / ([double]$W * $H), 4)
}

# 按分隔线切块；完全没有分隔线时退回「列空白带」（Get-LumBlocks）
function Get-PanelBlocks {
    param($LumBuf, [int]$MinGap = 40, [double]$MaxDensity = 0.02,
        [int]$LineThresh = 25, [double]$LineCoverage = 0.90, [int]$LineMaxThickness = 12,
        [double]$MinInkDensity = 0.0002)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $lines = Get-SeparatorLines -LumBuf $LumBuf -Thresh $LineThresh -Coverage $LineCoverage -MaxThickness $LineMaxThickness

    $blocks = New-Object System.Collections.Generic.List[object]

    if ($lines.Rows.Count -eq 0 -and $lines.Cols.Count -eq 0) {
        # 没有分隔线：按列空白带切，行方向整页一块
        foreach ($cb in @(Get-LumBlocks -LumBuf $LumBuf -MinGap $MinGap -MaxDensity $MaxDensity)) {
            $blocks.Add([pscustomobject]@{ X = $cb.X0; Y = 0; W = $cb.W; H = $h })
        }
    }
    else {
        $yCuts = @(-1) + @($lines.Rows | ForEach-Object { $_.E }) + @($h)
        $xCuts = @(-1) + @($lines.Cols | ForEach-Object { $_.E }) + @($w)
        for ($yi = 0; $yi -lt $yCuts.Count - 1; $yi++) {
            $y0 = $yCuts[$yi] + 1
            $y1 = $yCuts[$yi + 1] - 1
            if ($y1 -lt $y0) { continue }
            for ($xi = 0; $xi -lt $xCuts.Count - 1; $xi++) {
                $x0 = $xCuts[$xi] + 1
                $x1 = $xCuts[$xi + 1] - 1
                if ($x1 -lt $x0) { continue }
                $blocks.Add([pscustomobject]@{ X = $x0; Y = $y0; W = ($x1 - $x0 + 1); H = ($y1 - $y0 + 1) })
            }
        }
    }

    # 过滤空块，并附上相对位置与形状描述
    $out = New-Object System.Collections.Generic.List[object]
    $id = 0
    foreach ($b in $blocks) {
        $density = Get-RegionInkDensity -LumBuf $LumBuf -X $b.X -Y $b.Y -W $b.W -H $b.H
        if ($density -lt $MinInkDensity) { continue }
        $id++
        $out.Add([pscustomobject]@{
                BlockId    = $id
                X          = $b.X
                Y          = $b.Y
                W          = $b.W
                H          = $b.H
                RelX       = [Math]::Round($b.X / $w, 4)
                RelY       = [Math]::Round($b.Y / $h, 4)
                RelW       = [Math]::Round($b.W / $w, 4)
                RelH       = [Math]::Round($b.H / $h, 4)
                Aspect     = [Math]::Round($b.W / [double]$b.H, 3)
                InkDensity = $density
            })
    }
    return $out
}

# ---------------------------------------------------------------- 槽位框
#
# 游戏用细线方框标记「待填空的槽位」。方框有四条边，与字形的一两条横线不同，
# 因此先找横/竖线段带，再配对成闭合矩形；框内的符号归入槽位，框边本身不算符号。
function Get-SlotFrames {
    param(
        $LumBuf, [double]$Scale = 1.0, [int]$InkThreshold = 90,
        [int]$MinLenBase = 50, [int]$MaxThickBase = 8, [int]$TolBase = 6
    )
    $minLen = [Math]::Max(20, [int][Math]::Round($MinLenBase * $Scale))
    $maxThick = [Math]::Max(3, [int][Math]::Round($MaxThickBase * $Scale))
    $tol = [Math]::Max(2, [int][Math]::Round($TolBase * $Scale))

    $raw = [MtGV9.SlotFrames]::Find($LumBuf.Lum, $LumBuf.Width, $LumBuf.Height, $InkThreshold, $minLen, $maxThick, $tol)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $raw.Length; $i += 4) {
        $out.Add([pscustomobject]@{
                X0 = $raw[$i]; Y0 = $raw[$i + 1]; X1 = $raw[$i + 2]; Y1 = $raw[$i + 3]
                W  = $raw[$i + 2] - $raw[$i] + 1
                H  = $raw[$i + 3] - $raw[$i + 1] + 1
            })
    }

    # 去重：上下横线连成一条时会把相邻两个框误检成一个大框，
    # 凡是被别的框完全包含的，只保留面积更小的那个。
    $kept = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $out.Count; $i++) {
        $a = $out[$i]
        $drop = $false
        for ($j = 0; $j -lt $out.Count; $j++) {
            if ($i -eq $j) { continue }
            $b = $out[$j]
            if ($a.X0 -le $b.X0 -and $a.X1 -ge $b.X1 -and $a.Y0 -le $b.Y0 -and $a.Y1 -ge $b.Y1) {
                if (($a.W * $a.H) -gt ($b.W * $b.H)) { $drop = $true; break }
            }
        }
        if (-not $drop) { $kept.Add($a) }
    }
    return $kept
}

# 把框的四条边抹成背景（保留框内内容）。
# 不抹的话，框边会让整行/整列投影都有墨迹，框和内容会被切成一个整体。
function Clear-FrameBorders {
    param($LumBuf, $Frames)
    $w = $LumBuf.Width
    $h = $LumBuf.Height
    $lum = $LumBuf.Lum
    foreach ($fr in $Frames) {
        $t = [Math]::Max(4, [int][Math]::Round($fr.W * 0.06))
        $yA0 = [Math]::Max(0, $fr.Y0 - $t); $yA1 = [Math]::Min($h - 1, $fr.Y0 + 2)
        $yB0 = [Math]::Max(0, $fr.Y1 - 2); $yB1 = [Math]::Min($h - 1, $fr.Y1 + $t)
        for ($y = $yA0; $y -le $yA1; $y++) { for ($x = $fr.X0; $x -le $fr.X1; $x++) { $lum[$y * $w + $x] = 0 } }
        for ($y = $yB0; $y -le $yB1; $y++) { for ($x = $fr.X0; $x -le $fr.X1; $x++) { $lum[$y * $w + $x] = 0 } }
        $xA0 = [Math]::Max(0, $fr.X0 - $t); $xA1 = [Math]::Min($w - 1, $fr.X0 + 2)
        $xB0 = [Math]::Max(0, $fr.X1 - 2); $xB1 = [Math]::Min($w - 1, $fr.X1 + $t)
        for ($x = $xA0; $x -le $xA1; $x++) { for ($y = $fr.Y0; $y -le $fr.Y1; $y++) { $lum[$y * $w + $x] = 0 } }
        for ($x = $xB0; $x -le $xB1; $x++) { for ($y = $fr.Y0; $y -le $fr.Y1; $y++) { $lum[$y * $w + $x] = 0 } }
    }
}

#
# 纯网格扫描：符号全部对齐固定网格，中心点直接由公式算出，不做任何墨迹推断。
#   格中心 X = CellW/2 + n × CellW
#   格中心 Y = CellW/2 + m × RowPitch
#   裁剪框   = 中心 ± Half（所有符号同一尺寸）
# 1080p 基准：CellW=80、RowPitch=120、Half=34（即 4K 的 160 / 240 / 68）
function Get-BlockGrid {
    param(
        $LumBuf, $Block, [double]$Scale = 1.0,
        [int]$InkThreshold = 30, [double]$MinInkRatio = 0.005
    )
    $s = { param([double]$v) [Math]::Max(1, [int][Math]::Round($v * $Scale)) }
    $cellW = & $s 80
    $rowPitch = & $s 120
    $half = & $s 34
    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $side = $half * 2
    $minInk = [int][Math]::Max(8, [Math]::Round($side * $side * $MinInkRatio))

    $raw = [MtGV7.GridScan]::Scan($LumBuf.Lum, $imgW, $imgH, $cellW, $rowPitch, $half,
        $InkThreshold, $Block.X, $Block.Y, $Block.W, $Block.H, $minInk)

    $cells = New-Object System.Collections.Generic.List[object]
    $rowMap = @{}
    $rowIdx = 0
    $maxCol = 0
    for ($i = 0; $i -lt $raw.Length; $i += 7) {
        $m = $raw[$i]; $x0 = $raw[$i + 2]; $y0 = $raw[$i + 3]
        $cw = $raw[$i + 4]; $ch = $raw[$i + 5]
        if (-not $rowMap.ContainsKey($m)) { $rowIdx++; $rowMap[$m] = @{ Row = $rowIdx; Count = 0 } }
        $rowMap[$m].Count++
        $colIdx = $rowMap[$m].Count
        if ($colIdx -gt $maxCol) { $maxCol = $colIdx }
        $cells.Add([pscustomobject]@{
                Row        = $rowMap[$m].Row
                Col        = $colIdx
                GridCol    = $raw[$i + 1]
                X          = $x0
                Y          = $y0
                W          = $cw
                H          = $ch
                XRel       = [Math]::Round($x0 / $imgW, 4)
                YRel       = [Math]::Round($y0 / $imgH, 4)
                WRel       = [Math]::Round($cw / $imgW, 4)
                HRel       = [Math]::Round($ch / $imgH, 4)
                CropX      = $x0
                CropY      = $y0
                CropW      = $cw
                CropH      = $ch
                InkW       = 0
                InkH       = 0
                InkX       = 0
                InkY       = 0
                GapPrev    = 0
                GapPrevRel = 0
                RowCenterY = $y0 + $ch / 2.0
                InBlockX   = $x0 - $Block.X
                InBlockY   = $y0 - $Block.Y
            })
    }

    return [pscustomobject]@{
        BlockId = $Block.BlockId
        Rows    = $rowIdx
        Cols    = $maxCol
        Cells   = $cells
    }
}
