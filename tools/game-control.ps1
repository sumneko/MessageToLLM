[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'start')]
    [string]$Command,
    [string]$Uri = 'steam://rungameid/1858720',
    [int]$TimeoutSec = 150
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\api\game-api.ps1')

try {
    if ($Command -eq 'status') {
        [ordered]@{
            ok      = $true
            command = $Command
            state   = Get-GameState
        } | ConvertTo-Json -Compress
        exit 0
    }

    $startResult = Start-Game -Uri $Uri -TimeoutSec $TimeoutSec
    $ok = $startResult -ne 'timeout'
    [ordered]@{
        ok      = $ok
        command = $Command
        result  = $startResult
        state   = Get-GameState
    } | ConvertTo-Json -Compress

    if (-not $ok) { exit 1 }
    exit 0
}
catch {
    [ordered]@{
        ok      = $false
        command = $Command
        error   = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
