param([switch]$ResolveOnly)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
    $directory = Get-ForgeLaunchDirectory $PSScriptRoot
    if ($ResolveOnly) {
        Write-Output $directory
        exit 0
    }
    Start-Process -FilePath (Join-Path $directory 'forge.exe') -WorkingDirectory $directory -WindowStyle Normal
} catch {
    if (-not $ResolveOnly) {
        (New-Object -ComObject WScript.Shell).Popup($_.Exception.Message, 0, 'Forge', 16) | Out-Null
    }
    Write-Error $_
    exit 1
}
