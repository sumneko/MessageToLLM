# glyphbook.ps1 —— 符号台账：分配唯一 ID、维护「同形即同 ID」、支持合并与拆分
#
# 判同形由本模块用指纹（24×24 block-max → RMS 距离）完成，不消耗 LLM 的视觉预算；
# LLM 只在「存疑 / 新符号」时才会拿到图，并可用 Merge / Split 纠正。
#
# 台账文件（默认 data/glyphbook.json）：
#   { dim, nextNum, symbols: [{ id, vec, count, firstSeen, image, samples:[vec...] }] }

. (Join-Path $PSScriptRoot '..\vision\common.ps1')

# 阈值实测（4K，固定网格裁剪 + 亮度归一化）：
#   同形（含灰/白、跨位置）≤ 0.014；实测异形最近对（加/减镜像）= 0.0775
#   但同一字形在不同渲染瞬间可能漂移到 0.05~0.06，故 high 取 0.06、max 取 0.072：
#   既能把同形并稳定，又不跨到 0.0775 的异形对
$script:DistanceHighConf = 0.060 * 255     # 0-1 尺度的阈值换算到 0-255
$script:DistanceMax = 0.072 * 255

function New-GlyphBook {
    param([string]$Path, [int]$Dim = 24)
    return @{
        Path    = $Path
        Dim     = $Dim
        NextNum = 1
        Symbols = New-Object System.Collections.Generic.List[object]
    }
}

function Import-GlyphBook {
    param([Parameter(Mandatory)][string]$Path, [int]$Dim = 24)
    $book = New-GlyphBook -Path $Path -Dim $Dim
    if (-not (Test-Path $Path)) { return $book }

    $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw.dim) { $book.Dim = [int]$raw.dim }
    if ($raw.nextNum) { $book.NextNum = [int]$raw.nextNum }
    foreach ($s in @($raw.symbols)) {
        if (-not $s.id) { continue }
        $book.Symbols.Add([pscustomobject]@{
                Id        = $s.id
                Vec       = [Convert]::FromBase64String($s.vec)
                Aspect    = if ($s.aspect) { [double]$s.aspect } else { 0.0 }
                Count     = [int]$s.count
                FirstSeen = $s.firstSeen
                Image     = $s.image
                Samples   = @(@($s.samples) | Where-Object { $_ } | ForEach-Object { [Convert]::FromBase64String($_) })
            })
    }
    return $book
}

function Save-GlyphBook {
    param([Parameter(Mandatory)]$Book)
    $dir = Split-Path $Book.Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $symbols = foreach ($s in $Book.Symbols) {
        [pscustomobject]@{
            id        = $s.Id
            vec       = [Convert]::ToBase64String($s.Vec)
            aspect    = $s.Aspect
            count     = $s.Count
            firstSeen = $s.FirstSeen
            image     = $s.Image
            samples   = @($s.Samples | ForEach-Object { [Convert]::ToBase64String($_) })
        }
    }
    [pscustomobject]@{
        dim     = $Book.Dim
        nextNum = $Book.NextNum
        symbols = @($symbols)
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $Book.Path -Encoding UTF8
}

function ConvertTo-GlyphBytes {
    param([double[]]$Vector)
    $bytes = [byte[]]::new($Vector.Length)
    for ($i = 0; $i -lt $Vector.Length; $i++) {
        $bytes[$i] = [byte][Math]::Max(0, [Math]::Min(255, [int][Math]::Round($Vector[$i] * 255)))
    }
    return $bytes
}

# 在台账里查这个指纹是谁。
# 返回 { Id, Distance, Margin, Band(high|low|new), IsNew }；
# IsNew 时已经分配好新 ID（但尚未入库，由调用方 Add-GlyphSample 落库）
function Find-GlyphId {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][byte[]]$Vec,
        [double]$Aspect = 0,
        [double]$AspectTol = 0.12,
        [double]$HighConf = $script:DistanceHighConf,
        [double]$MaxDist = $script:DistanceMax
    )
    $count = $Book.Symbols.Count
    if ($count -eq 0) {
        return [pscustomobject]@{
            Id = ('s{0:D3}' -f $Book.NextNum); Distance = 0.0; Margin = 0.0; Band = 'new'; IsNew = $true; Vec = $vec
        }
    }

    $dim = $Book.Dim * $Book.Dim
    $lib = [byte[]]::new($count * $dim)
    for ($c = 0; $c -lt $count; $c++) {
        [Array]::Copy($Book.Symbols[$c].Vec, 0, $lib, $c * $dim, $dim)
    }

    $res = [MtGV5.QuickOps]::Nearest($lib, $count, $dim, $vec)
    $idx = [int]$res[0]
    $dist = [double]$res[1]
    $secondDist = [double]$res[2]

    $band = if ($dist -le $HighConf) { 'high' } elseif ($dist -le $MaxDist) { 'low' } else { 'new' }
    # 宽高比是独立的身份特征：包围盒归一化会把 | 与 ||| 抹成一样，必须单独判
    if ($band -ne 'new' -and $Aspect -gt 0 -and $Book.Symbols[$idx].Aspect -gt 0) {
        if ([Math]::Abs($Aspect - $Book.Symbols[$idx].Aspect) -gt $AspectTol) { $band = 'new' }
    }
    $isNew = ($band -eq 'new')
    $id = if ($isNew) { 's{0:D3}' -f $Book.NextNum } else { $Book.Symbols[$idx].Id }
    $margin = if ([double]::IsPositiveInfinity($secondDist) -or [double]::IsNaN($secondDist)) { 0.0 } else { $secondDist - $dist }

    return [pscustomobject]@{
        Id       = $id
        Distance = [Math]::Round($dist / 255.0, 4)
        Margin   = [Math]::Round($margin / 255.0, 4)
        Band     = $band
        IsNew    = $isNew
        Vec      = $vec
    }
}

# 记一次出现：新 ID 入库；旧 ID 累加计数与样本（最多 8 个）
function Add-GlyphSample {
    param(
        [Parameter(Mandatory)]$Book,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][byte[]]$Vec,
        [double]$Aspect = 0,
        [string]$ImagePath
    )
    $hit = $Book.Symbols | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $hit) {
        $Book.Symbols.Add([pscustomobject]@{
                Id        = $Id
                Vec       = $Vec
                Aspect    = $Aspect
                Count     = 1
                FirstSeen = (Get-Date -Format 'o')
                Image     = $ImagePath
                Samples   = @($Vec)
            })
        $num = [int]($Id -replace '\D', '')
        if ($num -ge $Book.NextNum) { $Book.NextNum = $num + 1 }
        return $true
    }

    $hit.Count++
    if ($hit.Samples.Count -lt 8) {
        $hit.Samples = @($hit.Samples) + @(, $Vec)
    }
    return $false
}

function Get-GlyphSymbol {
    param([Parameter(Mandatory)]$Book, [Parameter(Mandatory)][string]$Id)
    return ($Book.Symbols | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# 合并：把所有指向 From 的记录改成 To
function Merge-GlyphId {
    param([Parameter(Mandatory)]$Book, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $a = Get-GlyphSymbol -Book $Book -Id $From
    $b = Get-GlyphSymbol -Book $Book -Id $To
    if (-not $a -or -not $b) { throw "合并失败：ID 不存在（$From / $To）" }
    $b.Count += $a.Count
    $b.Samples = @(@($b.Samples) + @($a.Samples) | Select-Object -First 8)
    $Book.Symbols.Remove($a) | Out-Null
    return $true
}

# 拆分：把某个 ID 的样本按「最远两点」一分为二；分得开才拆，返回新 ID 或 $null
function Split-GlyphId {
    param([Parameter(Mandatory)]$Book, [Parameter(Mandatory)][string]$Id, [double]$MinGap = 0.06)
    $sym = Get-GlyphSymbol -Book $Book -Id $Id
    if (-not $sym -or $sym.Samples.Count -lt 2) { return $null }

    $dim = $sym.Samples[0].Length
    # 找最远的一对样本作为两个种子
    $bestA = 0; $bestB = 1; $bestD = -1.0
    for ($i = 0; $i -lt $sym.Samples.Count; $i++) {
        for ($j = $i + 1; $j -lt $sym.Samples.Count; $j++) {
            $s = 0.0
            for ($k = 0; $k -lt $dim; $k++) { $d = $sym.Samples[$i][$k] - $sym.Samples[$j][$k]; $s += $d * $d }
            $d2 = [Math]::Sqrt($s / $dim) / 255.0
            if ($d2 -gt $bestD) { $bestD = $d2; $bestA = $i; $bestB = $j }
        }
    }
    if ($bestD -lt $MinGap) { return $null }

    $groupA = New-Object System.Collections.Generic.List[object]
    $groupB = New-Object System.Collections.Generic.List[object]
    foreach ($v in $sym.Samples) {
        $sa = 0.0; $sb = 0.0
        for ($k = 0; $k -lt $dim; $k++) {
            $da = $v[$k] - $sym.Samples[$bestA][$k]; $sa += $da * $da
            $db = $v[$k] - $sym.Samples[$bestB][$k]; $sb += $db * $db
        }
        if ($sa -le $sb) { $groupA.Add($v) } else { $groupB.Add($v) }
    }
    if ($groupA.Count -eq 0 -or $groupB.Count -eq 0) { return $null }

    $newId = 's{0:D3}' -f $Book.NextNum
    $Book.NextNum++
    $sym.Samples = @($groupA)
    $sym.Vec = $groupA[0]
    $sym.Count = $groupA.Count
    $Book.Symbols.Add([pscustomobject]@{
            Id        = $newId
            Vec       = $groupB[0]
            Count     = $groupB.Count
            FirstSeen = (Get-Date -Format 'o')
            Image     = $null
            Samples   = @($groupB)
        })
    return $newId
}
