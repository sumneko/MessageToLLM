# tools/page-dump.ps1 —— 页面导出工具（只读；-Sync 时逐格读游戏内译文）
#
# 观察当前画面，把每个块渲染成「符号ID[译文]」的紧凑文本，
# 译文来自本地台账（data\translations-s.json），它是游戏内译文栏的镜像。
#
# 用法：
#   .\tools\page-dump.ps1                # 抓当前画面，用本地台账显示译文（快）
#   .\tools\page-dump.ps1 -Sync          # 先逐格读取游戏内译文（慢，约 1 秒/符号）
#   .\tools\page-dump.ps1 -NoCapture     # 用上次的观察结果（不重新截图）
#   .\tools\page-dump.ps1 -SaveText      # 额外把文本渲染存到 runs/dump-<时间>/page.txt

[CmdletBinding()]
param(
    [switch]$NoCapture,
    [switch]$Sync,
    [switch]$OnlyNew,
    [switch]$SaveText,
    [switch]$ShowSlots,
    [string]$TransFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\api\game-api.ps1')

$api = Initialize-GameApi -Root $root -OutDir (Join-Path $root ('runs\dump-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
if (-not $NoCapture) {
    $null = Set-GameForeground
    $obs = Get-GameObservation -Force
}
else {
    $obs = Get-GameObservation
}

# 本地台账 = 上次读到的游戏内译文；-Sync 时重新逐格读一遍
$trans = Import-GameTranslationMap -Path $TransFile
$syncInfo = $null
if ($Sync) {
    Write-Host '正在逐格读取游戏内译文…' -ForegroundColor DarkGray
    $syncInfo = Sync-GameTranslations -Path $TransFile -OnlyNew:$OnlyNew
    $trans = Import-GameTranslationMap -Path $TransFile
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('image: ' + $obs.Image))
$lines.Add(("blocks: {0}  slots: {1}  （灰=灰色条目 `）" -f @($obs.Blocks).Count, @($obs.Slots).Count))
if ($syncInfo) {
    $lines.Add(("译文同步：读 {0} 个符号，变化 {1} 个，台账有译文 {2} 个 / 已确认 {3} 个" -f $syncInfo.Read, $syncInfo.Changed, $syncInfo.Known, $syncInfo.Total))
}
$lines.Add('译文记法：[x]=游戏内译文  [空]=译文栏为空  [?]=台账无记录')
$lines.Add('')

foreach ($b in $obs.Blocks) {
    $blk = Get-GameBlock -BlockId $b.BlockId
    $cellList = @($blk.Cells)
    $knownInBlock = @($cellList | Where-Object { $trans.ContainsKey($_.SymbolId) } | Select-Object -ExpandProperty SymbolId -Unique).Count
    $lines.Add(("── block {0}  ({1}x{2} 格, {3} 符号, {4} 个有译文) ──" -f $b.BlockId, $blk.Rows, $blk.Cols, $cellList.Count, $knownInBlock))
    $rows = @($cellList | Group-Object Row | Sort-Object { [int]$_.Name })
    foreach ($r in $rows) {
        $tokens = foreach ($c in ($r.Group | Sort-Object Col)) {
            $tone = $(if ($c.Tone -eq 'gray') { '`' } else { '' })
            if (-not $trans.ContainsKey($c.SymbolId)) { "$($c.SymbolId)[?]$tone" }
            elseif ($trans[$c.SymbolId]) { "$($c.SymbolId)[$($trans[$c.SymbolId])]$tone" }
            else { "$($c.SymbolId)[空]$tone" }
        }
        $lines.Add(("r{0}: {1}" -f $r.Name, ($tokens -join ' ')))
    }
    if ($ShowSlots -and @($blk.Slots).Count -gt 0) {
        foreach ($s in $blk.Slots) {
            $lines.Add(("  slot: r{0}c{1} x={2} y={3} ids={4}" -f $s.Row, $s.Col, $s.XRel, $s.YRel, ($s.SymbolIds -join ',')))
        }
    }
    $lines.Add('')
}

$unknown = @($obs.Blocks | ForEach-Object { (Get-GameBlock -BlockId $_.BlockId).Cells } |
    Where-Object { -not $trans.ContainsKey($_.SymbolId) } |
    Select-Object -ExpandProperty SymbolId -Unique | Sort-Object)
$emptyIds = @($obs.Blocks | ForEach-Object { (Get-GameBlock -BlockId $_.BlockId).Cells } |
    Where-Object { $trans.ContainsKey($_.SymbolId) -and -not $trans[$_.SymbolId] } |
    Select-Object -ExpandProperty SymbolId -Unique | Sort-Object)
if (@($emptyIds).Count -gt 0) {
    $lines.Add(("游戏内无译文（{0} 个）：{1}" -f @($emptyIds).Count, ($emptyIds -join ' ')))
}
if (@($unknown).Count -gt 0) {
    $lines.Add(("从未同步（{0} 个）：{1}" -f @($unknown).Count, ($unknown -join ' ')))
    $lines.Add('提示：加 -Sync 可逐格读取游戏内译文并写入台账。')
}

$text = $lines -join "`n"
Write-Output $text

if ($SaveText) {
    $out = Join-Path $api.OutDir 'page.txt'
    $text | Set-Content -Path $out -Encoding UTF8
    Write-Host "已保存：$out" -ForegroundColor DarkGray
}
