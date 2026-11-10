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

    $raw = [MtGV5.QuickOps]::FindFrames($LumBuf.Lum, $LumBuf.Width, $LumBuf.Height, $InkThreshold, $minLen, $maxThick, $tol)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $raw.Length; $i += 4) {
        $out.Add([pscustomobject]@{
                X0 = $raw[$i]; Y0 = $raw[$i + 1]; X1 = $raw[$i + 2]; Y1 = $raw[$i + 3]
                W  = $raw[$i + 2] - $raw[$i] + 1
                H  = $raw[$i + 3] - $raw[$i + 1] + 1
            })
    }
    return $out
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

# ---------------------------------------------------------------- 网格归并
#
# 游戏 UI 是固定网格：符号在格内居中，一行内相邻符号的中心差是格宽的整数倍。
# 但笔画之间（例如 III 的三根竖线）的中心差只有格宽的 1/3 左右，必须先归列再合并，
# 否则 III 会被拆成 3 个 I。
#
# 格宽推断：对「同一行内相邻符号中心的差」做聚类，取成员最多的簇作为格宽；
# 再用「画面宽 / 格宽」取整修正（格宽通常是窗口宽的 1/24）。

function Get-CellMetrics {
    param($Cells, [int]$ImageWidth, [double]$Tolerance = 0.05)
    $diffs = New-Object System.Collections.Generic.List[double]
    $byRow = $Cells | Group-Object Row
    foreach ($r in $byRow) {
        $items = @($r.Group | Sort-Object X)
        $centers = @($items | ForEach-Object { $_.X + $_.W / 2.0 })
        for ($i = 1; $i -lt $centers.Count; $i++) {
            $d = $centers[$i] - $centers[$i - 1]
            if ($d -gt 2) { $diffs.Add($d) }
        }
    }
    if ($diffs.Count -eq 0) { return $null }

    # 按容差聚类，取最大簇
    $clusters = New-Object System.Collections.Generic.List[object]
    foreach ($d in ($diffs | Sort-Object)) {
        $hit = $null
        foreach ($c in $clusters) {
            if ([Math]::Abs($c.Center - $d) -le $c.Center * $Tolerance) { $hit = $c; break }
        }
        if ($hit) {
            $hit.Sum += $d
            $hit.N++
            $hit.Center = $hit.Sum / $hit.N
        }
        else {
            $clusters.Add([pscustomobject]@{ Center = $d; Sum = $d; N = 1 })
        }
    }
    $best = $clusters | Sort-Object N -Descending | Select-Object -First 1
    if (-not $best -or $best.Center -lt 4) { return $null }

    # 用「画面宽 / 格宽」取整修正：格宽应整除画面宽
    $cols = [Math]::Max(1, [int][Math]::Round($ImageWidth / $best.Center))
    $cellW = $ImageWidth / $cols

    # 列内偏移：所有中心对格宽取模后的众数
    $buckets = @{}
    foreach ($c in $Cells) {
        $mod = ((($c.X + $c.W / 2.0) % $cellW) + $cellW) % $cellW
        $key = [int][Math]::Round($mod / 2) * 2
        if (-not $buckets.ContainsKey($key)) { $buckets[$key] = New-Object System.Collections.Generic.List[double] }
        $buckets[$key].Add($mod)
    }
    $topBucket = $buckets.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 1
    $offset = 0.0
    if ($topBucket) {
        $sum = 0.0
        foreach ($v in $topBucket.Value) { $sum += $v }
        $offset = $sum / $topBucket.Value.Count
    }

    return [pscustomobject]@{
        CellW    = [Math]::Round($cellW, 3)
        Offset   = [Math]::Round($offset, 3)
        Cols     = $cols
        Confidence = [Math]::Round($best.N / [double]$diffs.Count, 3)
    }
}

# 把同一行内落到同一列的多个墨迹块合并成一个符号（III 的三根竖线 → 一个 III）
function Merge-CellsByGrid {
    param($Grid, $Metrics, [int]$BlockX = 0, [int]$ImageWidth = 1, [int]$ImageHeight = 1)
    $out = New-Object System.Collections.Generic.List[object]
    $byRow = $Grid.Cells | Group-Object Row
    $maxCol = 0
    # 块起点对应的全局列号，扣掉后得到块内列号（从 1 开始）
    $baseCol = [int][Math]::Round(($BlockX - $Metrics.Offset) / $Metrics.CellW)
    foreach ($r in $byRow) {
        $groups = @{}
        foreach ($c in $r.Group) {
            $cx = $c.X + $c.W / 2.0
            $col0 = [int][Math]::Round(($cx - $Metrics.Offset) / $Metrics.CellW)
            if (-not $groups.ContainsKey($col0)) { $groups[$col0] = New-Object System.Collections.Generic.List[object] }
            $groups[$col0].Add($c)
        }
        foreach ($col0 in ($groups.Keys | Sort-Object)) {
            $items = $groups[$col0]
            if ($items.Count -eq 1) {
                $it = $items[0]
                $x0 = $it.X; $y0 = $it.Y; $x1 = $it.X + $it.W; $y1 = $it.Y + $it.H
                $gap = $it.GapPrev
            }
            else {
                $x0 = ($items | Measure-Object X -Minimum).Minimum
                $y0 = ($items | Measure-Object Y -Minimum).Minimum
                $x1 = ($items | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
                $y1 = ($items | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
                $gap = 0
            }
            $w = $x1 - $x0
            $hh = $y1 - $y0
            $col1 = $col0 - $baseCol + 1
            if ($col1 -gt $maxCol) { $maxCol = $col1 }
            $out.Add([pscustomobject]@{
                    Row        = [int]$r.Name
                    Col        = $col1
                    X          = $x0
                    Y          = $y0
                    W          = $w
                    H          = $hh
                    XRel       = [Math]::Round($x0 / $ImageWidth, 4)
                    YRel       = [Math]::Round($y0 / $ImageHeight, 4)
                    WRel       = [Math]::Round($w / $ImageWidth, 4)
                    HRel       = [Math]::Round($hh / $ImageHeight, 4)
                    GapPrev    = $gap
                    GapPrevRel = [Math]::Round($gap / $ImageWidth, 4)
                    InBlockX   = 0
                    InBlockY   = 0
                })
        }
    }
    $sorted = @($out | Sort-Object Row, Col)

    return [pscustomobject]@{
        BlockId = $Grid.BlockId
        Rows    = $(if ($sorted.Count -gt 0) { ($sorted | Measure-Object Row -Maximum).Maximum } else { 0 })
        Cols    = $maxCol
        Cells   = $sorted
    }
}

#
# 注意：不同行的符号数可以不同（6/8/5 …），所以「列」不是全局网格列，
# 而是**行内序号**；需要判断是否对齐时用 XRel/YRel（相对整屏的归一化位置）。
function Get-BlockGrid {
    param(
        $LumBuf, $Block, [double]$Scale = 1.0,
        [int]$InkThreshold = 90,
        [int]$RowMinGap = 2, [int]$RowMergeGap = 8,
        [int]$SymMinGap = 10, [int]$SymMinRun = 4
    )
    $s = { param([double]$v) [Math]::Max(1, [int][Math]::Round($v * $Scale)) }

    $sub = [pscustomobject]@{
        Lum    = [MtGV5.QuickOps]::CropLum($LumBuf.Lum, $LumBuf.Width, $LumBuf.Height, $Block.X, $Block.Y, $Block.W, $Block.H)
        Width  = $Block.W
        Height = $Block.H
    }

    # 块内残留的分隔线先抹掉（块边界本身已在线外侧，但抗锯齿可能有残留）
    Remove-SeparatorLines -LumBuf $sub -MaxThickness (& $s 6) | Out-Null

    $layout = @(Get-RowLayout -LumBuf $sub -Threshold $InkThreshold -MinGap (& $s $RowMinGap) -RowMergeGap (& $s $RowMergeGap))
    $glyphRows = @($layout | Where-Object { $_.Kind -eq 'glyph' })

    $imgW = $LumBuf.Width
    $imgH = $LumBuf.Height
    $cells = New-Object System.Collections.Generic.List[object]
    $rowIdx = 0
    foreach ($gr in $glyphRows) {
        $rowIdx++
        $bandH = $gr.Y1 - $gr.Y0 + 1
        $symRuns = @(Get-InkColumnRuns -LumBuf $sub -X0 0 -Y0 $gr.Y0 -W $Block.W -H $bandH `
                -Threshold $InkThreshold -MinGap (& $s $SymMinGap) -MinRun (& $s $SymMinRun))
        $colIdx = 0
        $prevRight = $null
        foreach ($sr in $symRuns) {
            $bb = Get-InkBounds -LumBuf $sub -X0 $sr.X -Y0 $gr.Y0 -W $sr.W -H $bandH -Threshold $InkThreshold
            if ($null -eq $bb) { continue }
            $colIdx++
            $gx = $Block.X + $bb.X
            $gy = $Block.Y + $bb.Y
            # 与前一个符号的横向间距：纯机械事实，用来区分「同一组笔划」与「不同符号」
            $gapPrev = if ($null -eq $prevRight) { 0 } elseif ($gx -gt $prevRight) { $gx - $prevRight } else { 0 }
            $prevRight = $gx + $bb.W
            $cells.Add([pscustomobject]@{
                    Row        = $rowIdx
                    Col        = $colIdx
                    X          = $gx
                    Y          = $gy
                    W          = $bb.W
                    H          = $bb.H
                    XRel       = [Math]::Round($gx / $imgW, 4)
                    YRel       = [Math]::Round($gy / $imgH, 4)
                    WRel       = [Math]::Round($bb.W / $imgW, 4)
                    HRel       = [Math]::Round($bb.H / $imgH, 4)
                    GapPrev    = $gapPrev
                    GapPrevRel = [Math]::Round($gapPrev / $imgW, 4)
                    InBlockX   = $bb.X
                    InBlockY   = $bb.Y
                })
        }
    }

    return [pscustomobject]@{
        BlockId = $Block.BlockId
        Rows    = $rowIdx
        Cols    = $(if ($cells.Count -gt 0) { ($cells | Measure-Object -Property Col -Maximum).Maximum } else { 0 })
        Cells   = $cells
    }
}
