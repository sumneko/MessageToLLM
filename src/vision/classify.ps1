# classify.ps1 —— 把「符号指纹」映射到「已知符号 ID」
#
# 与 glyphs 工程里 dedupe.ps1 的区别：
#   dedupe.ps1    = 聚类（无监督，发现"哪些格子长得一样"）
#   classify.ps1  = 分类（有监督，查已知库"这个格子是哪个符号"）
#
# 依赖：common.ps1（Get-VecDistance / Get-SampleVector 等）

. (Join-Path $PSScriptRoot 'common.ps1')

# 不含平移搜索的快速距离，只用于预筛候选
function Get-VecDistanceFast {
    param([double[]]$A, [double[]]$B)
    $s = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $d = $A[$i] - $B[$i]
        $s += $d * $d
    }
    return [Math]::Sqrt($s / $A.Length)
}

# 载入符号库：{ id -> 24x24 指纹向量 }
function Import-GlyphLibrary {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "符号库不存在：$Path" }
    $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $lib = [ordered]@{}
    foreach ($c in @($raw)) {
        $bytes = [Convert]::FromBase64String($c.vec)
        $vec = [double[]]::new($bytes.Length)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $vec[$i] = $bytes[$i] / 255.0 }
        $lib[$c.id] = $vec
    }
    return $lib
}

# 单格分类：一阶快速预筛 + 二阶精确匹配（含 ±1 格平移容差）
#
# 返回 Band：
#   high  dist <= HighConf      可以用于推理
#   low   HighConf < dist <= MaxDist   记录但不可用于推理（存疑）
#   new   dist > MaxDist        视为库外新符号，需要登记并请模型命名
function Get-GlyphMatch {
    param(
        [Parameter(Mandatory)]$Library,
        [Parameter(Mandatory)][double[]]$Vector,
        [double]$HighConf = 0.08,
        [double]$MaxDist = 0.11,
        [int]$TopK = 3
    )
    $scores = foreach ($k in $Library.Keys) {
        [pscustomobject]@{ Id = $k; Fast = (Get-VecDistanceFast -A $Library[$k] -B $Vector) }
    }
    $cand = @($scores | Sort-Object Fast | Select-Object -First $TopK)

    $best = $null
    $bestD = [double]::MaxValue
    $secondD = [double]::MaxValue
    foreach ($c in $cand) {
        $d = Get-VecDistance -A $Library[$c.Id] -B $Vector
        if ($d -lt $bestD) { $secondD = $bestD; $bestD = $d; $best = $c.Id }
        elseif ($d -lt $secondD) { $secondD = $d }
    }

    $band = if ($bestD -le $HighConf) { 'high' } elseif ($bestD -le $MaxDist) { 'low' } else { 'new' }
    return [pscustomobject]@{
        Id       = $best
        Distance = [Math]::Round($bestD, 4)
        Margin   = [Math]::Round(($secondD - $bestD), 4)
        Band     = $band
    }
}
