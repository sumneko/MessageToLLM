# tools/page-dump.ps1 —— 页面导出工具（只读）
#
# 观察当前画面，把每个块渲染成「符号ID(已知译文)」的紧凑文本，
# 方便人工/模型快速阅读页面内容，而不必反复翻截图。
#
# 用法：
#   .\tools\page-dump.ps1                # 抓当前画面并打印
#   .\tools\page-dump.ps1 -NoCapture     # 用上次的观察结果（不重新截图）
#   .\tools\page-dump.ps1 -SaveText      # 额外把文本渲染存到 runs/dump-<时间>.txt

[CmdletBinding()]
param(
    [switch]$NoCapture,
    [switch]$SaveText,
    [string]$TransFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\api\game-api.ps1')

if (-not $TransFile) { $TransFile = Join-Path $root 'data\translations-s.json' }
$trans = @{}
if (Test-Path $TransFile) {
    $json = Get-Content $TransFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $trans[$p.Name] = $p.Value }
}

$api = Initialize-GameApi -Root $root -OutDir (Join-Path $root ('runs\dump-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if (-not $NoCapture) {
    $null = Set-GameForeground
    $obs = Get-GameObservation -Force
}
else {
    $obs = Get-GameObservation
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('image: ' + $obs.Image))
$lines.Add(("blocks: {0}  slots: {1}  （灰色条目后缀 `）" -f @($obs.Blocks).Count, @($obs.Slots).Count))
$lines.Add('')

foreach ($b in $obs.Blocks) {
    $blk = Get-GameBlock -BlockId $b.BlockId
    $lines.Add(("── block {0}  ({1}x{2} 格, {3} 符号) ──" -f $b.BlockId, $blk.Rows, $blk.Cols, @($blk.Cells).Count))
    $rows = @($blk.Cells | Group-Object Row | Sort-Object { [int]$_.Name })
    foreach ($r in $rows) {
        $tokens = foreach ($c in ($r.Group | Sort-Object Col)) {
            $t = $trans[$c.SymbolId]
            $tone = $(if ($c.Tone -eq 'gray') { '`' } else { '' })
            if ($t) { "$($c.SymbolId)[$t]$tone" } else { "$($c.SymbolId)$tone" }
        }
        $lines.Add(("r{0}: {1}" -f $r.Name, ($tokens -join ' ')))
    }
    if (@($blk.Slots).Count -gt 0) {
        foreach ($s in $blk.Slots) {
            $lines.Add(("  slot: r{0}c{1} x={2} y={3} ids={4}" -f $s.Row, $s.Col, $s.XRel, $s.YRel, ($s.SymbolIds -join ',')))
        }
    }
    $lines.Add('')
}

$unknown = @($obs.Blocks | ForEach-Object { (Get-GameBlock -BlockId $_.BlockId).Cells } |
    Where-Object { -not $trans[$_.SymbolId] } |
    Select-Object -ExpandProperty SymbolId -Unique | Sort-Object)
$lines.Add(("未知符号（{0} 个）：{1}" -f @($unknown).Count, ($unknown -join ' ')))

$text = $lines -join "`n"
Write-Output $text

if ($SaveText) {
    $out = Join-Path $api.OutDir 'page.txt'
    $text | Set-Content -Path $out -Encoding UTF8
    Write-Host "已保存：$out" -ForegroundColor DarkGray
}
