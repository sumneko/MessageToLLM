# game-api.ps1 —— 对外游戏接口
#
# 设计原则：只暴露「手和眼」，不含任何「这是什么面板 / 这个按钮干什么」的判断。
#   observe()            截屏 → 分块；结构未变时直接告知无变化
#   read_block(id)       块内网格与符号
#   symbol_info(id)      符号台账信息（首次出现时附图）
#   symbol_samples(id)   样本图路径
#   click_at(块,行,列)   点格子（含空位）
#   click_at_rel(块,x,y) 点块内相对位置（0-1），用于没有符号的空槽位
#   click_symbol(id)     点某个符号最近一次出现的位置
#   game_state()         running / closed / minimized / not-foreground
#   start_game()         通过 Steam 启动并等到窗口出现
#   merge_symbols / split_symbol  台账纠错
#
# 所有坐标参数都不含分辨率：行号/列号基于块内网格，相对位置是 0-1。

. (Join-Path $PSScriptRoot '..\vision\common.ps1')
. (Join-Path $PSScriptRoot '..\vision\layout.ps1')
. (Join-Path $PSScriptRoot '..\capture\capture.ps1')
. (Join-Path $PSScriptRoot '..\act\mouse.ps1')
. (Join-Path $PSScriptRoot '..\state\glyphbook.ps1')

$script:Api = $null

function Initialize-GameApi {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$BookPath,
        [string]$OutDir,
        [int]$SampleSize = 24
    )
    if (-not $BookPath) { $BookPath = Join-Path $Root 'data\glyphbook.json' }
    if (-not $OutDir) { $OutDir = Join-Path $Root ('runs\api-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $script:Api = @{
        Root          = $Root
        OutDir        = $OutDir
        SampleSize    = $SampleSize
        Book          = Import-GlyphBook -Path $BookPath -Dim $SampleSize
        Step          = 0
        LastSignature = $null
        LastImage     = $null
        LastBitmap    = $null
        Blocks        = @()
        Grids         = @{}
        Slots         = @()
        CellIndex     = @{}
        Win           = $null
    }
    return $script:Api
}

function Get-ApiInstance {
    if (-not $script:Api) { throw '未初始化：先调用 Initialize-GameApi -Root <项目根>' }
    return $script:Api
}

# 截图像素坐标 → SetCursorPos 需要的物理像素
function Convert-ImagePointToScreen {
    param([int]$X, [int]$Y, $Window)
    $ps = if ($Window.PointScale -gt 0) { $Window.PointScale } else { 1.0 }
    return [pscustomobject]@{
        X = [int][Math]::Round(($Window.X + $X) * $ps)
        Y = [int][Math]::Round(($Window.Y + $Y) * $ps)
    }
}

function Get-GameState {
    param([string]$ProcessName = 'MessageFromAliens')
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return 'closed' }
    if ($proc.MainWindowHandle -eq 0) { return 'minimized' }
    $fg = Get-ForegroundInfo
    if ($fg.ProcessName -ne $ProcessName) { return 'not-foreground' }
    return 'running'
}

function Start-Game {
    param([string]$Uri = 'steam://rungameid/1858720', [int]$TimeoutSec = 150)
    if (Get-Process MessageFromAliens -ErrorAction SilentlyContinue) { return 'already-running' }
    Start-Process $Uri
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process MessageFromAliens -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) {
            Start-Sleep -Milliseconds 1500
            return 'started'
        }
        Start-Sleep -Milliseconds 1000
    }
    return 'timeout'
}

# 观察：截屏 → 分块 → 块内网格；结构未变则直接返回 changed=$false
function Get-GameObservation {
    param([switch]$Force)
    $api = Get-ApiInstance
    $frame = Capture-GameFrame -Method Auto
    try {
        $api.Win = $frame.Window
        $scale = $frame.Bitmap.Height / 1080.0
        $pb = Get-PixelBuffer -Bmp $frame.Bitmap
        $lb = Get-LumBuffer -PB $pb

        # 先检测槽位框（必须在抹边之前），然后抹掉框边，避免框与内容在投影上粘连
        $frames = @(Get-SlotFrames -LumBuf $lb -Scale $scale)
        if ($frames.Count -gt 0) { Clear-FrameBorders -LumBuf $lb -Frames $frames }

        $blocks = @(Get-PanelBlocks -LumBuf $lb -MinGap ([int](40 * $scale)) -MaxDensity 0.02 `
                -LineMaxThickness ([int](6 * $scale)))
        $grids = @{}
        foreach ($b in $blocks) {
            $grids[$b.BlockId] = Get-BlockGrid -LumBuf $lb -Block $b -Scale $scale
        }

        # 全页推断网格（格宽 / 列偏移），然后把同一行内同一列的笔划合并成一个符号。
        # 不合并的话 III 会被拆成 3 个 I——因为笔画间距小于格宽。
        $metrics = $null
        $allCells = @($grids.Values | ForEach-Object { $_.Cells })
        if ($allCells.Count -gt 0) {
            $metrics = Get-CellMetrics -Cells $allCells -ImageWidth $lb.Width
        }
        if ($metrics) {
            foreach ($b in $blocks) {
                $grids[$b.BlockId] = Merge-CellsByGrid -Grid $grids[$b.BlockId] -Metrics $metrics `
                    -BlockX $b.X -ImageWidth $lb.Width -ImageHeight $lb.Height
            }
        }

        # 结构签名：块矩形 + 网格尺寸 + 每格指纹哈希。
        # 必须包含格子内容，否则「同一位置换了符号」会被误判成无变化。
        $vecs = @{}
        $sigParts = foreach ($b in $blocks) {
            $g = $grids[$b.BlockId]
            $hashes = foreach ($cell in $g.Cells) {
                $vec = [MtGV5.QuickOps]::SampleVec($lb.Lum, $lb.Width, $lb.Height,
                    $cell.X, $cell.Y, $cell.W, $cell.H, $api.SampleSize)
                $key = '{0}:{1}:{2}' -f $b.BlockId, $cell.Row, $cell.Col
                $vecs[$key] = $vec
                # 轻量校验和（避免大整数溢出问题），足以判断「这一格是否变了」
                $h1 = 0; $h2 = 0
                foreach ($v in $vec) {
                    $h1 = ($h1 + $v) % 1000003
                    $h2 = ($h2 + $v * (($h1 % 7) + 1)) % 1000003
                }
                '{0}-{1}' -f $h1, $h2
            }
            '{0}:{1},{2},{3},{4}:{5}x{6}:{7}' -f $b.BlockId, $b.X, $b.Y, $b.W, $b.H, $g.Rows, $g.Cols, ($hashes -join ',')
        }
        $sig = ($sigParts -join '|')

        if (-not $Force -and $sig -eq $api.LastSignature) {
            return [pscustomobject]@{
                Changed = $false
                Message = '画面与上次观察完全一致（块、网格、符号位置与形状均未变）'
                Image   = $api.LastImage
            }
        }

        $api.Step++
        $imgPath = Join-Path $api.OutDir ('step-{0:D4}.png' -f $api.Step)
        Save-Frame -Bitmap $frame.Bitmap -Path $imgPath | Out-Null
        $api.LastImage = $imgPath
        if ($api.LastBitmap) { $api.LastBitmap.Dispose() }
        $api.LastBitmap = $frame.Bitmap.Clone()

        # 识别符号（机械查表，不消耗 LLM）
        $cellIndex = @{}
        $newIds = New-Object System.Collections.Generic.List[string]
        foreach ($b in $blocks) {
            $g = $grids[$b.BlockId]
            foreach ($cell in $g.Cells) {
                $key = '{0}:{1}:{2}' -f $b.BlockId, $cell.Row, $cell.Col
                [byte[]]$vec = $vecs[$key]
                $aspect = $cell.W / [double]$cell.H
                $m = Find-GlyphId -Book $api.Book -Vec $vec -Aspect $aspect
                $cell | Add-Member -NotePropertyName SymbolId -NotePropertyValue $m.Id -Force
                $cell | Add-Member -NotePropertyName Band -NotePropertyValue $m.Band -Force
                $cell | Add-Member -NotePropertyName Distance -NotePropertyValue $m.Distance -Force

                $isNew = Add-GlyphSample -Book $api.Book -Id $m.Id -Vec $vec -Aspect $aspect
                if ($isNew) {
                    $symDir = Join-Path $api.OutDir 'symbols'
                    New-Item -ItemType Directory -Path $symDir -Force | Out-Null
                    $symPath = Join-Path $symDir ($m.Id + '.png')
                    $rect = [System.Drawing.Rectangle]::new($cell.X, $cell.Y, $cell.W, $cell.H)
                    $crop = $frame.Bitmap.Clone($rect, $frame.Bitmap.PixelFormat)
                    $crop.Save($symPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $crop.Dispose()
                    $sym = Get-GlyphSymbol -Book $api.Book -Id $m.Id
                    if ($sym) { $sym.Image = $symPath }
                    $newIds.Add($m.Id)
                }

                if (-not $cellIndex.ContainsKey($m.Id)) {
                    $cellIndex[$m.Id] = New-Object System.Collections.Generic.List[object]
                }
                $cellIndex[$m.Id].Add([pscustomobject]@{
                        BlockId = $b.BlockId; Row = $cell.Row; Col = $cell.Col
                        X = $cell.X; Y = $cell.Y; W = $cell.W; H = $cell.H
                    })
            }
        }
        Save-GlyphBook -Book $api.Book

        $api.Blocks = $blocks
        $api.Grids = $grids
        $api.CellIndex = $cellIndex
        $api.LastSignature = $sig

        $blockInfo = foreach ($b in $blocks) {
            $g = $grids[$b.BlockId]
            [pscustomobject]@{
                BlockId    = $b.BlockId
                RelX       = $b.RelX
                RelY       = $b.RelY
                RelW       = $b.RelW
                RelH       = $b.RelH
                Aspect     = $b.Aspect
                InkDensity = $b.InkDensity
                Rows       = $g.Rows
                Cols       = $g.Cols
                CellCount  = $g.Cells.Count
            }
        }

        # 槽位：位置 + 网格行列 + 框内符号（已识别）
        $slotInfo = @()
        foreach ($fr in $frames) {
            $cx = ($fr.X0 + $fr.X1) / 2.0
            $cy = ($fr.Y0 + $fr.Y1) / 2.0
            $hostBlk = $null
            foreach ($bb in $blocks) {
                if ($cx -ge $bb.X -and $cx -le ($bb.X + $bb.W) -and $cy -ge $bb.Y -and $cy -le ($bb.Y + $bb.H)) { $hostBlk = $bb; break }
            }
            if ($null -eq $hostBlk) { continue }

            $inside = @()
            foreach ($cc in $grids[$hostBlk.BlockId].Cells) {
                $mx = $cc.X + $cc.W / 2.0
                $my = $cc.Y + $cc.H / 2.0
                if ($mx -gt $fr.X0 -and $mx -lt $fr.X1 -and $my -gt $fr.Y0 -and $my -lt $fr.Y1) { $inside = @($inside) + @($cc) }
            }
            $rowIdx = 0
            if ($inside.Count -gt 0) { $rowIdx = $inside[0].Row }
            $colIdx = 0
            if ($null -ne $metrics) {
                $baseCol = [int][Math]::Round(($hostBlk.X - $metrics.Offset) / $metrics.CellW)
                $colIdx = ([int][Math]::Round(($cx - $metrics.Offset) / $metrics.CellW)) - $baseCol + 1
            }
            $ids = @()
            foreach ($cc in $inside) { $ids = @($ids) + @([string]$cc.SymbolId) }

            $slotInfo = @($slotInfo) + @([pscustomobject]@{
                    BlockId   = $hostBlk.BlockId
                    Row       = $rowIdx
                    Col       = $colIdx
                    XRel      = [Math]::Round($fr.X0 / $lb.Width, 4)
                    YRel      = [Math]::Round($fr.Y0 / $lb.Height, 4)
                    WRel      = [Math]::Round($fr.W / $lb.Width, 4)
                    HRel      = [Math]::Round($fr.H / $lb.Height, 4)
                    SymbolIds = $ids
                })
        }
        $api.Slots = $slotInfo

        return [pscustomobject]@{
            Changed    = $true
            Step       = $api.Step
            Image      = $imgPath
            Width      = $frame.Bitmap.Width
            Height     = $frame.Bitmap.Height
            Scale      = [Math]::Round($scale, 3)
            Blocks     = @($blockInfo)
            Slots      = @($slotInfo)
            NewSymbols = @($newIds)
        }
    }
    finally {
        $frame.Bitmap.Dispose()
    }
}

function Get-GameBlock {
    param([Parameter(Mandatory)][int]$BlockId)
    $api = Get-ApiInstance
    if (-not $api.Grids.ContainsKey($BlockId)) { throw "块不存在：$BlockId（先跑一次观察）" }
    $g = $api.Grids[$BlockId]
    $cells = foreach ($c in $g.Cells) {
        [pscustomobject]@{
            Row        = $c.Row
            Col        = $c.Col
            SymbolId   = $c.SymbolId
            Band       = $c.Band
            Distance   = $c.Distance
            XRel       = $c.XRel
            YRel       = $c.YRel
            WRel       = $c.WRel
            HRel       = $c.HRel
            GapPrevRel = $c.GapPrevRel
        }
    }
    return [pscustomobject]@{
        BlockId = $BlockId
        Rows    = $g.Rows
        Cols    = $g.Cols
        Cells   = @($cells)
        Slots   = @($api.Slots | Where-Object { $_.BlockId -eq $BlockId })
    }
}

function Get-SymbolInfo {
    param([Parameter(Mandatory)][string]$SymbolId)
    $api = Get-ApiInstance
    $sym = Get-GlyphSymbol -Book $api.Book -Id $SymbolId
    if (-not $sym) { throw "未知符号：$SymbolId" }
    return [pscustomobject]@{
        Id        = $sym.Id
        Count     = $sym.Count
        FirstSeen = $sym.FirstSeen
        Image     = $sym.Image
        Samples   = @($sym.Samples).Count
    }
}

function Get-SymbolSamples {
    param([Parameter(Mandatory)][string]$SymbolId, [int]$Count = 3)
    $api = Get-ApiInstance
    $cells = @()
    if ($api.CellIndex.ContainsKey($SymbolId)) { $cells = @($api.CellIndex[$SymbolId]) }
    return @($cells | Select-Object -First $Count | ForEach-Object {
            [pscustomobject]@{ BlockId = $_.BlockId; Row = $_.Row; Col = $_.Col }
        })
}

function Invoke-GameClickAt {
    param(
        [Parameter(Mandatory)][int]$BlockId,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Col,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [switch]$DryRun
    )
    $api = Get-ApiInstance
    if (-not $api.Grids.ContainsKey($BlockId)) { throw "块不存在：$BlockId" }
    $cell = $api.Grids[$BlockId].Cells | Where-Object { $_.Row -eq $Row -and $_.Col -eq $Col } | Select-Object -First 1
    if (-not $cell) { throw "格不存在：块 $BlockId 行 $Row 列 $Col（可能为空位，改用 clic_at_rel）" }

    $win = $api.Win
    if (-not $win) { throw '还没有窗口几何：先跑一次观察' }
    $pt = Convert-ImagePointToScreen -X ($cell.X + [int]($cell.W / 2)) -Y ($cell.Y + [int]($cell.H / 2)) -Window $win

    if (-not $DryRun) { $null = Set-GameForeground }
    Invoke-Click -X $pt.X -Y $pt.Y -Button $Button -DryRun:$DryRun
    return [pscustomobject]@{ X = $pt.X; Y = $pt.Y; BlockId = $BlockId; Row = $Row; Col = $Col; SymbolId = $cell.SymbolId }
}

# 点块内相对位置（0-1）—— 空槽位没有符号，只能用这个
function Invoke-GameClickAtRel {
    param(
        [Parameter(Mandatory)][int]$BlockId,
        [Parameter(Mandatory)][double]$RelX,
        [Parameter(Mandatory)][double]$RelY,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [switch]$DryRun
    )
    $api = Get-ApiInstance
    $blk = $api.Blocks | Where-Object { $_.BlockId -eq $BlockId } | Select-Object -First 1
    if (-not $blk) { throw "块不存在：$BlockId" }
    $win = $api.Win
    if (-not $win) { throw '还没有窗口几何：先跑一次观察' }

    $ix = $blk.X + [int][Math]::Round($RelX * $blk.W)
    $iy = $blk.Y + [int][Math]::Round($RelY * $blk.H)
    $pt = Convert-ImagePointToScreen -X $ix -Y $iy -Window $win

    if (-not $DryRun) { $null = Set-GameForeground }
    Invoke-Click -X $pt.X -Y $pt.Y -Button $Button -DryRun:$DryRun
    return [pscustomobject]@{ X = $pt.X; Y = $pt.Y; BlockId = $BlockId; RelX = $RelX; RelY = $RelY }
}

function Invoke-GameClickSymbol {
    param(
        [Parameter(Mandatory)][string]$SymbolId,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [switch]$DryRun
    )
    $api = Get-ApiInstance
    if (-not $api.CellIndex.ContainsKey($SymbolId)) { throw "该符号本次画面里没出现：$SymbolId" }
    $c = $api.CellIndex[$SymbolId][0]
    return Invoke-GameClickAt -BlockId $c.BlockId -Row $c.Row -Col $c.Col -Button $Button -DryRun:$DryRun
}

function Merge-GameSymbols {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $api = Get-ApiInstance
    $ok = Merge-GlyphId -Book $api.Book -From $From -To $To
    Save-GlyphBook -Book $api.Book
    $api.CellIndex = @{}
    return [pscustomobject]@{ Merged = $From; Into = $To; Ok = $ok }
}

function Split-GameSymbol {
    param([Parameter(Mandatory)][string]$SymbolId, [double]$MinGap = 0.06)
    $api = Get-ApiInstance
    $newId = Split-GlyphId -Book $api.Book -Id $SymbolId -MinGap $MinGap
    if ($newId) { Save-GlyphBook -Book $api.Book; $api.CellIndex = @{} }
    return [pscustomobject]@{ Split = $SymbolId; NewId = $newId; Ok = [bool]$newId }
}
