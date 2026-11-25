param(
    [Parameter(Mandatory)][string]$VerifiedDirectory,
    [string]$AppDirectory = 'C:\Users\Angus\AppData\Local\Card-Forge'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
$verification = Read-ForgeJson (Join-Path $VerifiedDirectory 'workflow-verification.json')
if ($verification.checks.Count -lt 8) {
    throw 'The isolated success and failure verification has not completed.'
}
$activeId = (Get-Content -LiteralPath (Join-Path $VerifiedDirectory 'current.txt') -Raw).Trim()
if ($verification.active -ne $activeId) {
    throw 'The isolated verification describes a different active build.'
}
$candidate = Get-ForgeApprovedBuild $VerifiedDirectory $activeId
$baselineId = 'forge-2.0.16-commander'
$baseline = Get-ForgeApprovedBuild $VerifiedDirectory $baselineId
$installedBaseline = Join-Path $AppDirectory "versions\$baselineId"
foreach ($name in @('forge.exe', 'forge-gui-desktop-2.0.16-jar-with-dependencies.jar')) {
    if ((Get-FileHash -LiteralPath (Join-Path $installedBaseline $name)).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $baseline.Directory $name)).Hash) {
        throw 'The existing Commander installation changed since its regression checks.'
    }
}
$taskName = 'Card-Forge Daily Update'
$task = Get-ScheduledTask -TaskName $taskName
if ($task.State -eq 'Running') {
    throw 'The existing updater is running. Finish its run before installing the workflow.'
}
$backup = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory ('workflow-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))).FullName
Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $backup 'scheduled-task.xml')
Copy-Item -LiteralPath (Join-Path $AppDirectory 'current.txt'),(Join-Path $AppDirectory 'Update-Forge.ps1'),
    (Join-Path $AppDirectory 'Launch-Forge.ps1') -Destination $backup
$oldPrevious = Join-Path $AppDirectory 'previous.txt'
if (Test-Path -LiteralPath $oldPrevious) {
    Copy-Item -LiteralPath $oldPrevious -Destination $backup
}
$lock = Lock-ForgeUpdate $AppDirectory
try {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        throw 'The updater started during setup. Finish its run before installation.'
    }
    $scripts = @('ForgeUpdate.psm1', 'Update-Forge.ps1', 'Prepare-ForgeRelease.ps1', 'Launch-Forge.ps1',
        'Rollback-Forge.ps1', 'commander-config.json')
    foreach ($name in $scripts) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $AppDirectory $name) -Force
    }
    foreach ($folder in @('test-libs', 'downloads\forge-2.0.16')) {
        $destination = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory $folder)).FullName
        Get-ChildItem -LiteralPath (Join-Path $VerifiedDirectory $folder) -File | Copy-Item -Destination $destination -Force
    }
    Copy-Item -LiteralPath (Join-Path $baseline.Directory 'commander-tests.xml'),
        (Join-Path $baseline.Directory 'commander-approved.json') -Destination $installedBaseline -Force
    $versions = (Get-Item -LiteralPath (Join-Path $AppDirectory 'versions')).FullName
    $destination = [IO.Path]::GetFullPath((Join-Path $versions $activeId))
    $source = [IO.Path]::GetFullPath($candidate.Directory)
    $verifiedVersions = (Get-Item -LiteralPath (Join-Path $VerifiedDirectory 'versions')).FullName
    if ([IO.Path]::GetDirectoryName($source) -ne $verifiedVersions -or
        [IO.Path]::GetDirectoryName($destination) -ne $versions) {
        throw 'The installation paths are outside the verified release folders.'
    }
    [IO.Directory]::Move($source, $destination)
    Set-ForgePointer (Join-Path $AppDirectory 'current.txt') $baselineId
    Set-ForgeActiveBuild $AppDirectory $activeId
    Write-ForgeJson (Join-Path $AppDirectory 'commander-status.json') @{
        release = $candidate.Manifest.release; phase = 'active'; message = "$activeId passed isolated workflow verification."
        sourceCommit = $candidate.Manifest.sourceCommit; time = [DateTime]::UtcNow.ToString('o')
    }
    Write-ForgeLog $AppDirectory "Activated $activeId. Commander release workflow enabled after isolated success and failure checks."
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    Set-ScheduledTask -TaskName $taskName -Settings $settings | Out-Null
} catch {
    Copy-Item -LiteralPath (Join-Path $backup 'Update-Forge.ps1'),(Join-Path $backup 'Launch-Forge.ps1') `
        -Destination $AppDirectory -Force
    $old = (Get-Content -LiteralPath (Join-Path $backup 'current.txt') -Raw).Trim()
    Set-ForgePointer (Join-Path $AppDirectory 'current.txt') $old
    if (Test-Path -LiteralPath (Join-Path $backup 'previous.txt')) {
        $previous = (Get-Content -LiteralPath (Join-Path $backup 'previous.txt') -Raw).Trim()
        Set-ForgePointer $oldPrevious $previous
    }
    throw
} finally {
    $lock.Dispose()
    Enable-ScheduledTask -TaskName $taskName | Out-Null
}
Start-ScheduledTask -TaskName $taskName
Write-Output "Backup saved in $backup."
