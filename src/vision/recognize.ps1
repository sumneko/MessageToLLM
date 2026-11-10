# recognize.ps1 —— 把一整页截图变成「ID 矩阵」
#
# 已在前 4 张笔记页上验证：文字标签段数 == 符号数（100% 命中）
# 因此：用文字标签中心反推网格 → 每格取包围盒 → 指纹 → 分类。

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'classify.ps1')

function Get-PanelMatrix {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)]$Library,
        [int]$InkThreshold = 90,
        [int]$LabelMinGap = 8,
        [int]$RowMergeGap = 8,
        [int]$SampleSize = 24
    )
    $bmp = Open-ImagePlain -Path $ImagePath
    try {
        $pb = Get-PixelBuffer -Bmp $bmp
        $lb = Get-LumBuffer -PB $pb
        Remove-SeparatorLines -LumBuf $lb | Out-Null
        $W = $bmp.Width

        $layout = @(Get-RowLayout -LumBuf $lb -Threshold $InkThreshold -MinGap 2 -RowMergeGap $RowMergeGap)
        $glyphRows = @($layout | Where-Object { $_.Kind -eq 'glyph' })

        $rows = New-Object System.Collections.Generic.List[object]
        $rowIndex = 0
        foreach ($gr in $glyphRows) {
            $rowIndex++
            $bandTop = $gr.Y0
            $bandBot = $gr.Y1 + 1
            $bandHH = $bandBot - $bandTop

            # 该行的网格标尺 = 下面那行文字标签
            $centers = @()
            if ($gr.TextIndex -ge 0) {
                $tb = $layout[$gr.TextIndex]
                $labelRuns = @(Get-InkColumnRuns -LumBuf $lb -X0 0 -Y0 $tb.Y0 -W $W `
                        -H ($tb.Y1 - $tb.Y0 + 1) -Threshold $InkThreshold -MinGap $LabelMinGap -MinRun 3)
                foreach ($r in $labelRuns) { $centers += ($r.X + $r.W / 2.0) }
            }
            if ($centers.Count -eq 0) { continue }   # 测验页等无标签页面：P0 暂不支持

            $rects = @(Get-GridRects -Centers $centers -Width $W)

            $cells = New-Object System.Collections.Generic.List[object]
            $col = 0
            foreach ($rc in $rects) {
                $col++
                $bb = Get-InkBounds -LumBuf $lb -X0 $rc.X -Y0 $bandTop -W $rc.W -H $bandHH -Threshold $InkThreshold
                if ($null -eq $bb) { continue }
                $vec = Get-SampleVector -LumBuf $lb -X $bb.X -Y $bb.Y -W $bb.W -H $bb.H -N $SampleSize
                $m = Get-GlyphMatch -Library $Library -Vector $vec
                $cells.Add([pscustomobject]@{
                        Col      = $col
                        Id       = $m.Id
                        Distance = $m.Distance
                        Margin   = $m.Margin
                        Band     = $m.Band
                        BBox     = [pscustomobject]@{ X = $bb.X; Y = $bb.Y; W = $bb.W; H = $bb.H }
                    })
            }
            $rows.Add([pscustomobject]@{ Row = $rowIndex; Y0 = $bandTop; Y1 = $gr.Y1; Cells = $cells })
        }

        return [pscustomobject]@{
            Image  = (Split-Path $ImagePath -Leaf)
            Width  = $W
            Height = $bmp.Height
            Rows   = $rows
        }
    }
    finally {
        $bmp.Dispose()
    }
}

# ID 矩阵（纯字符串二维数组），便于断言与比较
function Get-MatrixIds {
    param($Matrix)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Matrix.Rows) {
        $line = New-Object System.Collections.Generic.List[string]
        foreach ($c in $r.Cells) { $line.Add($c.Id) }
        $out.Add($line.ToArray())
    }
    return $out.ToArray()
}

# 渲染成 markdown 表格
function Format-PanelMatrix {
    param($Matrix, $Translations = @{})
    $maxCol = 0
    foreach ($r in $Matrix.Rows) { foreach ($c in $r.Cells) { if ($c.Col -gt $maxCol) { $maxCol = $c.Col } } }
    if ($maxCol -eq 0) { return "（没有识别到任何格子）" }

    $sb = New-Object System.Collections.Generic.List[string]
    $sb.Add($Matrix.Image)
    $sb.Add('')
    $sb.Add('| 行 |' + (((1..$maxCol) | ForEach-Object { " c$_ |" }) -join ''))
    $sb.Add('|---|' + (((1..$maxCol) | ForEach-Object { '---|' }) -join ''))
    foreach ($r in $Matrix.Rows) {
        $cells = ''
        for ($c = 1; $c -le $maxCol; $c++) {
            $hit = $r.Cells | Where-Object { $_.Col -eq $c } | Select-Object -First 1
            if (-not $hit) { $cells += ' |'; continue }
            $txt = if ($Translations.Contains($hit.Id) -and $Translations[$hit.Id]) { $Translations[$hit.Id] } else { $hit.Id }
            $mark = if ($hit.Band -eq 'high') { '' } elseif ($hit.Band -eq 'low') { '?' } else { '‼' }
            $cells += (' `{0}`<br>{1}{2} |' -f $hit.Id, $txt, $mark)
        }
        $sb.Add(('| r{0} |{1}' -f $r.Row, $cells))
    }
    return ($sb -join [Environment]::NewLine)
}
