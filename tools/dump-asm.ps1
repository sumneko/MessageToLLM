# dump-asm.ps1 —— 只读枚举 Unity 游戏托管程序集
#
# 不注入、不改游戏：用反射把类型/字段/属性/方法签名全摊开，输出可 grep 的文本。
# 用途：注入前先摸清「有哪些内部接口可调」。
#
# 用法：
#   pwsh -NoProfile -File .\tools\dump-asm.ps1
#   pwsh -NoProfile -File .\tools\dump-asm.ps1 -Type 'Global|AdvGameState'
#   pwsh -NoProfile -File .\tools\dump-asm.ps1 -Dll TxtLoader.dll

[CmdletBinding()]
param(
    [string]$Dll = 'Assembly-CSharp.dll',
    [string]$GameDir = 'D:\steam\steamapps\common\Message From Aliens',
    [string]$Type,          # 类型名过滤（正则）
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$managed = Join-Path $GameDir 'MessageFromAliens_Data\Managed'

# 依赖解析：同目录按程序集名加载（UnityEngine.* 等按需拉进来）。
# 必须吞掉所有异常：资源卫星程序集（*.resources）也会走这里，抛出会把整个枚举打断。
$handler = [System.ResolveEventHandler] {
    param($s, $e)
    try {
        $name = ($e.Name -split ',')[0]
        if ($name -like '*.resources') { return $null }
        $p = Join-Path $managed "$name.dll"
        if (Test-Path $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
    }
    catch { }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($handler)

$asm = [System.Reflection.Assembly]::LoadFrom((Join-Path $managed $Dll))
try { $types = $asm.GetTypes() }
catch [System.Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ } }

if ($Type) { $types = $types | Where-Object { $_.FullName -match $Type } }
$types = $types | Sort-Object FullName

$sb = [System.Text.StringBuilder]::new()
function W { param([string]$s = '') [void]$sb.AppendLine($s) }

W "// $Dll   types=$($types.Count)   dumped=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
W ""

foreach ($t in $types) {
    $kind = if ($t.IsEnum) { 'enum' } elseif ($t.IsInterface) { 'interface' } elseif ($t.IsValueType) { 'struct' } else { 'class' }
    $mods = @()
    if ($t.IsAbstract -and $t.IsSealed) { $mods += 'static' }
    elseif ($t.IsAbstract) { $mods += 'abstract' }

    $base = ''
    if ($t.BaseType -and $t.BaseType.FullName -ne 'System.Object') { $base = " : $($t.BaseType.FullName)" }
    $prefix = (@($mods) + $kind | Where-Object { $_ }) -join ' '
    W ("{0} {1}{2} {{" -f $prefix, $t.FullName, $base)

    if ($t.IsEnum) {
        $names = [Enum]::GetNames($t)
        $vals = [Enum]::GetValues($t)
        for ($i = 0; $i -lt $names.Count; $i++) { W ("    {0} = {1}," -f $names[$i], [int64]$vals[$i]) }
    }
    else {
        $bf = [System.Reflection.BindingFlags]'Public,NonPublic,Static,Instance,DeclaredOnly'

        foreach ($f in ($t.GetFields($bf) | Sort-Object Name)) {
            $sm = if ($f.IsStatic) { 'static ' } else { '' }
            W ("    field  {0}{1} {2}" -f $sm, $f.FieldType.Name, $f.Name)
        }
        foreach ($p in ($t.GetProperties($bf) | Sort-Object Name)) {
            $acc = @()
            if ($p.GetMethod) { $acc += 'get' }
            if ($p.SetMethod) { $acc += 'set' }
            W ("    prop   {0} {1} [{2}]" -f $p.PropertyType.Name, $p.Name, ($acc -join '/'))
        }
        foreach ($m in ($t.GetMethods($bf) | Where-Object { -not $_.IsSpecialName } | Sort-Object Name)) {
            $sm = if ($m.IsStatic) { 'static ' } else { '' }
            $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', '
            W ("    method {0}{1} {2}({3})" -f $sm, $m.ReturnType.Name, $m.Name, $ps)
        }
        foreach ($n in ($t.GetNestedTypes([System.Reflection.BindingFlags]'Public,NonPublic') | Sort-Object Name)) {
            W ("    nested {0}" -f $n.Name)
        }
    }
    W "}"
    W ""
}

if (-not $Out) {
    $Out = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'runs\asm') ("{0}.{1}.txt" -f [System.IO.Path]::GetFileNameWithoutExtension($Dll), (Get-Date -Format 'HHmmss'))
}
New-Item -ItemType Directory -Path (Split-Path $Out -Parent) -Force | Out-Null
Set-Content -Path $Out -Value $sb.ToString() -Encoding utf8
Write-Host ("types={0}  ->  {1}" -f $types.Count, $Out)
