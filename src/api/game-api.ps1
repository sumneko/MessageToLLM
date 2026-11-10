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
#   set_translation()    给符号写游戏内译文（剪贴板粘贴；空文本 = 清除）
#   get_translation()    读符号当前的游戏内译文（点译文栏 → Ctrl+A/C → Esc）
#   sync_translations()  读当前页面所有符号的译文，写回本地台账 json
#                         Method=Crop（默认，裁剪译文框做像素比对，毫秒级、不碰鼠标）
#                         Method=Ocr / Clipboard 为备选
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

        # 结构签名：块矩形 + 网格尺寸 + 每格指纹哈希。
        # 必须包含格子内容，否则「同一位置换了符号」会被误判成无变化。
        $vecs = @{}
        $sigParts = foreach ($b in $blocks) {
            $g = $grids[$b.BlockId]
            $hashes = foreach ($cell in $g.Cells) {
                # 采样用固定内缩后的裁剪框（Crop*）：格子 160 内缩 12 → 136，正好贴住符号边
                $vec = [MtGV5.QuickOps]::SampleVec($lb.Lum, $lb.Width, $lb.Height,
                    $cell.CropX, $cell.CropY, $cell.CropW, $cell.CropH, $api.SampleSize)
                # 亮度归一化：灰色条目（max≈130）与白色条目（max≈255）应是同一符号，
                # 把向量线性缩放到 max=255，指纹就与色调无关（色调另由 Tone 字段表达）
                $maxV = 0
                foreach ($v in $vec) { if ($v -gt $maxV) { $maxV = $v } }
                if ($maxV -gt 20 -and $maxV -lt 250) {
                    $k = 255.0 / $maxV
                    for ($vi = 0; $vi -lt $vec.Length; $vi++) {
                        $nvv = [int][Math]::Round($vec[$vi] * $k)
                        if ($nvv -gt 255) { $nvv = 255 }
                        $vec[$vi] = [byte]$nvv
                    }
                }
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
                # 固定裁剪后所有符号同尺寸，宽高比不再作为身份特征
                $aspect = 0
                $m = Find-GlyphId -Book $api.Book -Vec $vec -Aspect $aspect
                $cell | Add-Member -NotePropertyName SymbolId -NotePropertyValue $m.Id -Force
                $cell | Add-Member -NotePropertyName Band -NotePropertyValue $m.Band -Force
                $cell | Add-Member -NotePropertyName Distance -NotePropertyValue $m.Distance -Force
                # 白/灰判定：裁剪框内墨迹平均亮度（白 ≈ 231，灰 ≈ 109）
                $toneStats = [MtGV6.InkTone]::CellStats($lb.Lum, $lb.Width, $lb.Height,
                    $cell.CropX, $cell.CropY, $cell.CropW, $cell.CropH, 60)
                $tone = 'none'
                if ($toneStats[0] -gt 8) { $tone = $(if ($toneStats[1] -ge 170) { 'white' } else { 'gray' }) }
                $cell | Add-Member -NotePropertyName Tone -NotePropertyValue $tone -Force
                $cell | Add-Member -NotePropertyName InkLum -NotePropertyValue ([Math]::Round($toneStats[1], 1)) -Force

                $isNew = Add-GlyphSample -Book $api.Book -Id $m.Id -Vec $vec -Aspect $aspect
                if ($isNew) {
                    $symDir = Join-Path $api.OutDir 'symbols'
                    New-Item -ItemType Directory -Path $symDir -Force | Out-Null
                    $symPath = Join-Path $symDir ($m.Id + '.png')
                    $rect = [System.Drawing.Rectangle]::new($cell.CropX, $cell.CropY, $cell.CropW, $cell.CropH)
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
            $gCellW = [Math]::Max(1, [int][Math]::Round(80 * $scale))
            $colIdx = [int][Math]::Floor($cx / $gCellW) - [int][Math]::Floor($hostBlk.X / $gCellW) + 1
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
    $trans = Import-GameTranslationMap
    $cells = foreach ($c in $g.Cells) {
        $t = if ($trans.ContainsKey($c.SymbolId)) { $trans[$c.SymbolId] } else { $null }
        [pscustomobject]@{
            Row         = $c.Row
            Col         = $c.Col
            SymbolId    = $c.SymbolId
            Translation = $t
            Band        = $c.Band
            Distance    = $c.Distance
            Tone        = $c.Tone
            InkLum      = $c.InkLum
            InkW        = $c.InkW
            InkH        = $c.InkH
            XRel        = $c.XRel
            YRel        = $c.YRel
            WRel        = $c.WRel
            HRel        = $c.HRel
            GapPrevRel  = $c.GapPrevRel
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

# ───────────────────────── 译文读写 ─────────────────────────
# 游戏把译文渲染在每个符号正下方（默认占位符为半角 '?'）。
# 读法：点译文栏 → Ctrl+A → Ctrl+C → 读剪贴板 → Esc 退出编辑。
# 本地台账（data\translations-s.json）只是游戏内译文的镜像，不作真相源。

function Get-GameTranslationPath {
    param([string]$Path)
    if ($Path) { return $Path }
    $api = Get-ApiInstance
    return (Join-Path $api.Root 'data\translations-s.json')
}

function Import-GameTranslationMap {
    param([string]$Path)
    $p = Get-GameTranslationPath -Path $Path
    $map = @{}
    if (Test-Path $p) {
        try {
            $json = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            # 值为空串 = 已确认游戏内无译文；键缺失 = 从未同步过
            foreach ($prop in $json.PSObject.Properties) {
                $map[$prop.Name] = if ($null -eq $prop.Value) { '' } else { [string]$prop.Value }
            }
        }
        catch { }
    }
    return $map
}

function Save-GameTranslationMap {
    param([hashtable]$Map, [string]$Path)
    $p = Get-GameTranslationPath -Path $Path
    $dir = Split-Path $p -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ordered = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $ordered[$k] = $Map[$k] }
    ($ordered | ConvertTo-Json -Depth 4) | Set-Content -Path $p -Encoding UTF8
    return $p
}

# 译文栏中心点（参考空间坐标 + 屏幕坐标）
function Get-TranslationSlotPoint {
    param([int]$BlockId, [int]$Row, [int]$Col)
    $api = Get-ApiInstance
    if (-not $api.Win) { throw '还没有窗口几何：先跑一次观察' }
    if (-not $api.Grids.ContainsKey($BlockId)) { throw "块不存在：$BlockId" }
    $rowCells = @($api.Grids[$BlockId].Cells | Where-Object { $_.Row -eq $Row })
    if ($rowCells.Count -eq 0) { throw "行不存在：块 $BlockId 行 $Row" }
    $cell = $rowCells | Where-Object { $_.Col -eq $Col } | Select-Object -First 1
    if (-not $cell) { throw "格不存在：块 $BlockId 行 $Row 列 $Col" }
    # 以整行最高格子的底边为准（矮符号的墨迹底边不可靠）
    $rowBottom = ($rowCells | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
    $scale = $api.Win.Height / 1080.0
    $ix = $cell.X + [int]($cell.W / 2)
    $iy = [int]$rowBottom + [int][Math]::Round(26 * $scale)
    return [pscustomobject]@{ X = $ix; Y = $iy; Screen = (Convert-ImagePointToScreen -X $ix -Y $iy -Window $api.Win) }
}

# ─── OCR 读译文（不点鼠标、不抢焦点）──────────────────────────────
# 走 Windows.Media.Ocr，只能由 PowerShell 5.1 调用（pwsh 7 没有 WinRT 投影）。
# 实测要点：
#   · 占位符 '?' 常被识别成 '7'，但它的 bbox 固定（4K 下 18x27）→ 用「尺寸 + 内容」双重判空
#   · 外星符号本身也会被 OCR 成汉字乱码，用 y 带过滤掉（只取译文栏那一层）
#   · 游戏不在前台时译文不渲染，整页都会是占位符 —— 这是游戏特性，不是 OCR 的错
function Invoke-WinRtOcr {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [double]$Scale = 2.0,
        [string]$Region = ''
    )
    $api = Get-ApiInstance
    $script = Join-Path $api.Root 'tools\ocr-winrt.ps1'
    if (-not (Test-Path $script)) { throw "缺少 OCR 脚本：$script" }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $tmpJson = Join-Path ([IO.Path]::GetTempPath()) ('ocr-' + [Guid]::NewGuid().ToString('N') + '.json')
    $argList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script,
        '-Image', $ImagePath, '-Scale', $Scale, '-Out', $tmpJson)
    if ($Region) { $argList += @('-Region', $Region) }
    try {
        $null = & $exe @argList 2>&1
        if (-not (Test-Path $tmpJson)) { throw 'OCR 没有产出结果' }
        return (Get-Content $tmpJson -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    finally {
        Remove-Item $tmpJson -Force -ErrorAction SilentlyContinue
    }
}

# 用一次 OCR 读出当前画面所有符号的译文；返回 @{ 符号ID = 文本 }
function Get-GameTranslationsByOcr {
    param(
        [int[]]$BlockId,
        [double]$Scale = 2.0
    )
    $api = Get-ApiInstance
    if (-not $api.LastImage) { throw '还没有截图：先跑一次观察' }
    $ocr = Invoke-WinRtOcr -ImagePath $api.LastImage -Scale $Scale

    $words = @()
    foreach ($ln in @($ocr.Lines)) {
        $wl = @($ln.Words)
        if ($wl.Count -gt 0) { $words += $wl }
        elseif ($ln.Text) {
            $words += [pscustomobject]@{ T = $ln.Text; X = $ln.X; Y = $ln.Y; W = $ln.W; H = $ln.H }
        }
    }

    $winScale = $api.Win.Height / 1080.0
    $band = 30.0 * $winScale
    $out = @{}
    $blocks = if ($BlockId) { @($BlockId) } else { @($api.Grids.Keys | Sort-Object) }
    foreach ($bid in $blocks) {
        if (-not $api.Grids.ContainsKey($bid)) { continue }
        $rows = @($api.Grids[$bid].Cells | Group-Object Row | Sort-Object { [int]$_.Name })
        foreach ($r in $rows) {
            $rowCells = @($r.Group | Sort-Object Col)
            $rowBottom = ($rowCells | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
            $slotY = $rowBottom + 26 * $winScale
            $buckets = @{}
            foreach ($w in $words) {
                $cy = $w.Y + $w.H / 2.0
                if ($cy -lt ($slotY - $band) -or $cy -gt ($slotY + $band)) { continue }
                $cx = $w.X + $w.W / 2.0
                foreach ($c in $rowCells) {
                    if ($cx -ge ($c.X - $c.W * 0.25) -and $cx -lt ($c.X + $c.W * 1.25)) {
                        if (-not $buckets.ContainsKey($c.SymbolId)) { $buckets[$c.SymbolId] = New-Object System.Collections.Generic.List[object] }
                        $buckets[$c.SymbolId].Add($w)
                        break
                    }
                }
            }
            foreach ($c in $rowCells) {
                if ($out.ContainsKey($c.SymbolId)) { continue }
                $text = ''
                if ($buckets.ContainsKey($c.SymbolId)) {
                    $ws = @($buckets[$c.SymbolId] | Sort-Object X)
                    $joined = ((($ws | ForEach-Object { $_.T }) -join '') -replace ' ', '')
                    if ($ws.Count -eq 1) {
                        $w0 = $ws[0]
                        $isPlaceholder = ($w0.W -le (12 * $winScale)) -and ($w0.H -le (18 * $winScale)) -and ($joined -match '^[?？7]$')
                        if ($isPlaceholder) { $joined = '' }
                    }
                    $text = $joined
                }
                $out[$c.SymbolId] = $text
            }
        }
    }
    return $out
}

# ─── 译文框裁剪识别（默认方案：最快、零干扰）────────────────────
# 译文就渲染在符号正下方固定偏移处，且游戏字体固定 ⇒ 同一字符的图像签名几乎完全一致。
# 因此「判空」和「已知字符识别」都只需像素比对：不调 OCR、不碰鼠标。
# 实测：同页所有 '?' 的签名距离 = 0；'?' 与最近的非空字符（「是」）= 0.492。

function Get-GameTranslationTemplatePath {
    $api = Get-ApiInstance
    return (Join-Path $api.Root 'data\translation-templates.json')
}

function Import-TranslationTemplates {
    $p = Get-GameTranslationTemplatePath
    $tpl = @{ Placeholder = ''; Chars = @{}; N = 16; Threshold = 70 }
    if (Test-Path $p) {
        try {
            $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.Placeholder) { $tpl.Placeholder = [string]$j.Placeholder }
            if ($j.N) { $tpl.N = [int]$j.N }
            if ($j.Threshold) { $tpl.Threshold = [int]$j.Threshold }
            if ($j.Chars) { foreach ($pr in $j.Chars.PSObject.Properties) { $tpl.Chars[$pr.Name] = [string]$pr.Value } }
        }
        catch { }
    }
    return $tpl
}

function Save-TranslationTemplates {
    param([hashtable]$Templates)
    $p = Get-GameTranslationTemplatePath
    $dir = Split-Path $p -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{
        N           = $Templates.N
        Threshold   = $Templates.Threshold
        Placeholder = $Templates.Placeholder
        Chars       = $Templates.Chars
    }
    ($obj | ConvertTo-Json -Depth 4) | Set-Content -Path $p -Encoding UTF8
    return $p
}

# 把截图读成亮度表（整图一次，后续裁剪走 C#）
function Get-LumSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $rect = [System.Drawing.Rectangle]::new(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = $data.Stride
        $bytes = [byte[]]::new($stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $bmp.UnlockBits($data)
        $w = $bmp.Width; $h = $bmp.Height
    }
    finally { $bmp.Dispose() }
    $lum = [MtGV5.QuickOps]::Lum($bytes, $w, $h, $stride)
    return [pscustomobject]@{ Lum = $lum; W = $w; H = $h }
}

# 译文框 = 格子横向范围、行底边下方 16 参考像素起、高 21 参考像素
# 4K 实测：文字落在 rowBottom+36..70，而 rowBottom+75 起是「整格宽」的分隔白线，
# 框高必须收在 74 以内，否则分隔线会混进签名（宽 136 = 满格宽，一眼可辨）。
function Get-TranslationSignature {
    param($Snap, $Cell, [int]$RowBottom, [int]$N, [int]$Thr)
    $api = Get-ApiInstance
    $scale = $api.Win.Height / 1080.0
    $x = [int]$Cell.X
    $y = [int]($RowBottom + 16 * $scale)
    $w = [int]$Cell.W
    $h = [int][Math]::Round(21 * $scale)
    if ($x -lt 0) { $w += $x; $x = 0 }
    if ($y -lt 0) { $h += $y; $y = 0 }
    if ($x + $w -gt $Snap.W) { $w = $Snap.W - $x }
    if ($y + $h -gt $Snap.H) { $h = $Snap.H - $y }
    if ($w -lt 4 -or $h -lt 4) { return [pscustomobject]@{ Sig = ''; InkW = 0; InkH = 0; InkCount = 0 } }
    $iw = 0; $ih = 0; $ic = 0
    $sig = [MtGV8.TransBox]::Sign($Snap.Lum, $Snap.W, $x, $y, $w, $h, $N, $Thr, [ref]$iw, [ref]$ih, [ref]$ic)
    return [pscustomobject]@{ Sig = $sig; InkW = $iw; InkH = $ih; InkCount = $ic }
}

# 用像素比对读当前画面所有符号的译文
#   值 = ''        无译文（等同于占位符 ?）
#   值 = 字符串    命中了字符模板库
#   值 = $null     有内容但识别不出（调用方决定怎么处理）
function Get-GameTranslationsByCrop {
    param(
        [int[]]$BlockId,
        [int]$N = 0,
        [int]$Thr = 0,
        [double]$Tol = 0.1,
        [switch]$RelearnPlaceholder
    )
    $api = Get-ApiInstance
    if (-not $api.LastImage) { throw '还没有截图：先跑一次观察' }
    $tpl = Import-TranslationTemplates
    if ($N -le 0) { $N = $tpl.N }
    if ($Thr -le 0) { $Thr = $tpl.Threshold }
    $snap = Get-LumSnapshot -Path $api.LastImage

    $blocks = if ($BlockId) { @($BlockId) } else { @($api.Grids.Keys | Sort-Object) }
    $sigs = @{}
    $meta = @{}
    foreach ($bid in $blocks) {
        if (-not $api.Grids.ContainsKey($bid)) { continue }
        $rows = @($api.Grids[$bid].Cells | Group-Object Row | Sort-Object { [int]$_.Name })
        foreach ($r in $rows) {
            $rowCells = @($r.Group | Sort-Object Col)
            $rowBottom = ($rowCells | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
            foreach ($c in $rowCells) {
                $s = Get-TranslationSignature -Snap $snap -Cell $c -RowBottom $rowBottom -N $N -Thr $Thr
                if (-not $sigs.ContainsKey($c.SymbolId)) {
                    $sigs[$c.SymbolId] = $s.Sig
                    $meta[$c.SymbolId] = $s
                }
            }
        }
    }

    # 占位符模板：显式重学，或模板库里还没有时自动检测（取出现次数最多的非空签名）
    if ($RelearnPlaceholder -or -not $tpl.Placeholder) {
        $counts = @{}
        foreach ($k in $sigs.Keys) {
            $v = $sigs[$k]
            if ($v) { if ($counts.ContainsKey($v)) { $counts[$v] = $counts[$v] + 1 } else { $counts[$v] = 1 } }
        }
        if ($counts.Count -gt 0) {
            $best = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
            $tpl.Placeholder = $best.Key
            $tpl.N = $N
            $tpl.Threshold = $Thr
            $null = Save-TranslationTemplates -Templates $tpl
        }
    }

    $out = @{}
    $unknown = New-Object System.Collections.Generic.List[string]
    $scale = $api.Win.Height / 1080.0
    $minInkH = 6 * $scale     # 低于这个高度的是分隔横线 / 下划线，不是字
    foreach ($k in $sigs.Keys) {
        $sig = $sigs[$k]
        if (-not $sig) { $out[$k] = ''; continue }
        $m = $meta[$k]
        if ($m.InkH -gt 0 -and $m.InkH -lt $minInkH) { $out[$k] = ''; continue }
        if ($tpl.Placeholder -and ([MtGV8.TransBox]::Dist($sig, $tpl.Placeholder) -le $Tol)) { $out[$k] = ''; continue }
        $hit = ''
        $bestD = 1.0
        foreach ($ch in $tpl.Chars.Keys) {
            $d = [MtGV8.TransBox]::Dist($sig, $tpl.Chars[$ch])
            if ($d -lt $bestD) { $bestD = $d; $hit = $ch }
        }
        if ($hit -and $bestD -le $Tol) { $out[$k] = $hit }
        else { $out[$k] = $null; $unknown.Add($k) }
    }
    return [pscustomobject]@{ Map = $out; Unknown = @($unknown); Placeholder = $tpl.Placeholder; Templates = $tpl }
}

# 把「符号 → 文本」登记进字符模板库（用当前画面里的图像），用于以后自动识别
function Register-GameTranslationTemplate {
    param(
        [Parameter(Mandatory)][hashtable]$Pairs,
        [int]$N = 0,
        [int]$Thr = 0
    )
    $api = Get-ApiInstance
    if (-not $api.LastImage) { throw '还没有截图：先跑一次观察' }
    $tpl = Import-TranslationTemplates
    if ($N -le 0) { $N = $tpl.N }
    if ($Thr -le 0) { $Thr = $tpl.Threshold }
    $snap = Get-LumSnapshot -Path $api.LastImage
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($id in $Pairs.Keys) {
        $text = [string]$Pairs[$id]
        if (-not $text) { continue }
        $loc = $null
        foreach ($bid in ($api.Grids.Keys | Sort-Object)) {
            $hit = @($api.Grids[$bid].Cells | Where-Object { $_.SymbolId -eq $id })
            if ($hit.Count -gt 0) { $loc = @{ BlockId = $bid; Cell = $hit[0] }; break }
        }
        if (-not $loc) { continue }
        $rowCells = @($api.Grids[$loc.BlockId].Cells | Where-Object { $_.Row -eq $loc.Cell.Row })
        $rowBottom = ($rowCells | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
        $s = Get-TranslationSignature -Snap $snap -Cell $loc.Cell -RowBottom $rowBottom -N $N -Thr $Thr
        if (-not $s.Sig) { continue }
        foreach ($ch in $text.ToCharArray()) {
            $key = [string]$ch
            if (-not $tpl.Chars.ContainsKey($key)) { $tpl.Chars[$key] = $s.Sig; $added.Add($key) }
        }
    }
    $tpl.N = $N
    $tpl.Threshold = $Thr
    $null = Save-TranslationTemplates -Templates $tpl
    return [pscustomobject]@{ Added = @($added); Total = $tpl.Chars.Count }
}

# 读一个符号当前的游戏内译文；无译文返回空串（剪贴板法：精确但会抢焦点）
function Get-GameTranslationText {
    param(
        [Parameter(Mandatory)][string]$SymbolId,
        [switch]$DryRun
    )
    $api = Get-ApiInstance
    if (-not $api.CellIndex.ContainsKey($SymbolId)) { throw "该符号本次画面里没出现：$SymbolId" }
    $c = $api.CellIndex[$SymbolId][0]
    $slot = Get-TranslationSlotPoint -BlockId $c.BlockId -Row $c.Row -Col $c.Col
    if ($DryRun) {
        return [pscustomobject]@{ SymbolId = $SymbolId; Text = $null; SlotX = $slot.X; SlotY = $slot.Y; DryRun = $true }
    }
    $null = Set-GameForeground
    $sh = New-Object -ComObject WScript.Shell
    $sentinel = [string][char]1 + 'SENTINEL'
    Set-Clipboard -Value $sentinel
    Start-Sleep -Milliseconds 60
    Invoke-Click -X $slot.Screen.X -Y $slot.Screen.Y -Button Left -SettleMs 200
    Start-Sleep -Milliseconds 120
    $sh.SendKeys('^a'); Start-Sleep -Milliseconds 110
    $sh.SendKeys('^c'); Start-Sleep -Milliseconds 200
    $raw = Get-Clipboard -Raw
    $sh.SendKeys('{ESC}'); Start-Sleep -Milliseconds 240
    $text = ''
    if ($raw -and $raw -ne $sentinel) { $text = ([string]$raw).Replace($sentinel, '').Trim() }
    if ($text -eq '?' -or $text -eq '？') { $text = '' }
    return [pscustomobject]@{ SymbolId = $SymbolId; Text = $text; SlotX = $slot.X; SlotY = $slot.Y; DryRun = $false }
}

# 同步整页译文：读游戏内译文栏，写回本地台账并返回映射
#   -Method Crop      裁剪译文框做像素比对（默认，几十毫秒、不碰鼠标；未知字符不覆盖台账）
#   -Method Ocr       整页 OCR（能读陌生中文，但满屏占位符时几乎无输出）
#   -Method Clipboard 逐格点进译文栏 Ctrl+A/C 读取（最精确，但会占用鼠标和焦点）
function Sync-GameTranslations {
    param(
        [int[]]$BlockId,
        [string]$Path,
        [switch]$OnlyNew,
        [ValidateSet('Crop', 'Ocr', 'Clipboard')][string]$Method = 'Crop',
        [switch]$Force,
        [switch]$PassThru
    )
    $api = Get-ApiInstance
    if (-not $api.Win) { throw '还没有窗口几何：先跑一次观察' }
    $map = Import-GameTranslationMap -Path $Path
    $unknown = @()

    if ($Method -eq 'Crop') {
        $null = Set-GameForeground
        if (-not $api.LastImage) { $null = Get-GameObservation -Force }
        $crop = Get-GameTranslationsByCrop -BlockId $BlockId
        $readMap = $crop.Map
        $unknown = @($crop.Unknown)
    }
    elseif ($Method -eq 'Ocr') {
        $null = Set-GameForeground   # 译文只在游戏前台渲染
        if (-not $api.LastImage) { $null = Get-GameObservation -Force }
        $readMap = Get-GameTranslationsByOcr -BlockId $BlockId
    }
    else {
        $readMap = @{}
        $order = if ($BlockId) { @($BlockId) } else { @($api.Grids.Keys | Sort-Object) }
        $ids = New-Object System.Collections.Generic.List[string]
        $seen = @{}
        foreach ($bid in $order) {
            if (-not $api.Grids.ContainsKey($bid)) { continue }
            foreach ($cc in ($api.Grids[$bid].Cells | Sort-Object Row, Col)) {
                if (-not $seen.ContainsKey($cc.SymbolId)) { $seen[$cc.SymbolId] = $true; $ids.Add($cc.SymbolId) }
            }
        }
        $i = 0
        foreach ($id in $ids) {
            $i++
            Write-Progress -Activity '同步游戏内译文（剪贴板）' -Status "$id ($i/$($ids.Count))" -PercentComplete (100.0 * $i / [Math]::Max(1, $ids.Count))
            $r = Get-GameTranslationText -SymbolId $id
            $readMap[$id] = $r.Text
        }
        Write-Progress -Activity '同步游戏内译文（剪贴板）' -Completed
    }

    $changed = 0
    $read = 0
    $skipped = 0
    foreach ($id in $readMap.Keys) {
        if ($OnlyNew -and $map.ContainsKey($id)) { continue }
        $read++
        $raw = $readMap[$id]
        if ($null -eq $raw) { $skipped++; continue }   # 有内容但识别不出：不动台账
        $text = [string]$raw
        if ($text) {
            if (-not $map.ContainsKey($id) -or $map[$id] -ne $text) { $map[$id] = $text; $changed++ }
        }
        elseif (-not $map.ContainsKey($id) -or $map[$id] -ne '') {
            $map[$id] = ''; $changed++
        }
    }

    # 保护：读到 0 个非空译文但台账本来有内容 —— 多半是游戏失焦（译文不渲染）或切档，
    # 直接覆盖会把已有数据清光。确认要清就用 -Force。
    $knownBefore = @($map.Keys | Where-Object { $map[$_] }).Count
    $incoming = @($readMap.Keys | Where-Object { $readMap[$_] }).Count
    if ($incoming -eq 0 -and $changed -gt 0 -and -not $Force) {
        return [pscustomobject]@{ Method = $Method; Read = $read; Changed = 0; Known = $knownBefore; Total = $map.Count; Path = ''; Skipped = 'all-empty'; Unknown = @($unknown) }
    }

    $savedPath = Save-GameTranslationMap -Map $map -Path $Path
    $known = @($map.Keys | Where-Object { $map[$_] }).Count
    $out = [pscustomobject]@{ Method = $Method; Read = $read; Changed = $changed; Known = $known; Total = $map.Count; Path = $savedPath; Skipped = $(if ($skipped -gt 0) { "$skipped-unknown" } else { '' }); Unknown = @($unknown) }
    if ($PassThru) { $out | Add-Member -NotePropertyName Map -NotePropertyValue $map }
    return $out
}

# 写译文：点译文栏 → 清空 → 粘贴 → 回车；同时更新本地台账
function Set-GameTranslation {
    param(
        [Parameter(Mandatory)][string]$SymbolId,
        [AllowEmptyString()][string]$Text = '',
        [switch]$DryRun
    )
    $api = Get-ApiInstance
    if (-not $api.CellIndex.ContainsKey($SymbolId)) { throw "该符号本次画面里没出现：$SymbolId" }
    $c = $api.CellIndex[$SymbolId][0]
    $slot = Get-TranslationSlotPoint -BlockId $c.BlockId -Row $c.Row -Col $c.Col

    if ($DryRun) {
        Write-Host ("[dry-run] 写译文 {0} = '{1}' @ ({2},{3})" -f $SymbolId, $Text, $slot.X, $slot.Y) -ForegroundColor DarkGray
        return [pscustomobject]@{ SymbolId = $SymbolId; Text = $Text; X = $slot.X; Y = $slot.Y; DryRun = $true }
    }

    $null = Set-GameForeground
    Invoke-Click -X $slot.Screen.X -Y $slot.Screen.Y -Button Left -SettleMs 250
    $sh = New-Object -ComObject WScript.Shell
    Start-Sleep -Milliseconds 150
    if ($Text.Length -gt 0) {
        Set-Clipboard -Value $Text
        Start-Sleep -Milliseconds 80
        $sh.SendKeys('^v')
        Start-Sleep -Milliseconds 250
    }
    else {
        $sh.SendKeys('^a')
        Start-Sleep -Milliseconds 100
        $sh.SendKeys('{BACKSPACE}')
        Start-Sleep -Milliseconds 100
    }
    $sh.SendKeys('{ENTER}')
    Start-Sleep -Milliseconds 300

    $map = Import-GameTranslationMap
    if ($Text.Length -gt 0) { $map[$SymbolId] = $Text }
    elseif ($map.ContainsKey($SymbolId)) { $map.Remove($SymbolId) }
    $savedPath = Save-GameTranslationMap -Map $map

    return [pscustomobject]@{ SymbolId = $SymbolId; Text = $Text; X = $slot.X; Y = $slot.Y; DryRun = $false; Book = $savedPath }
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
