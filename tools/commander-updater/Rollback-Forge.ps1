$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
$lock = Lock-ForgeUpdate $PSScriptRoot
try {
    $previous = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'previous.txt') -Raw).Trim()
    Set-ForgeActiveBuild $PSScriptRoot $previous
    Write-ForgeLog $PSScriptRoot "Rolled back to $previous. Open games can finish in their existing installation."
} finally {
    $lock.Dispose()
}
