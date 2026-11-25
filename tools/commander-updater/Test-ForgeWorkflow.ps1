param([Parameter(Mandatory)][string]$AppDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
$currentFile = Join-Path $AppDirectory 'current.txt'
$activeId = (Get-Content -LiteralPath $currentFile -Raw).Trim()
$active = Get-ForgeApprovedBuild $AppDirectory $activeId
$config = Read-ForgeJson (Join-Path $AppDirectory 'commander-config.json')
$checks = [Collections.Generic.List[string]]::new()

function Assert-ActiveUnchanged {
    if ((Get-Content -LiteralPath $currentFile -Raw).Trim() -ne $activeId) {
        throw 'A failed candidate changed the active release.'
    }
}

function Assert-Rejected($Action, $Label) {
    $rejected = $false
    try {
        & $Action
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "$Label was incorrectly accepted."
    }
    Assert-ActiveUnchanged
    $checks.Add($Label)
}

Assert-Rejected { Set-ForgeActiveBuild $AppDirectory 'forge-2.0.16' } 'Official unpatched activation rejected'
$lock = Lock-ForgeUpdate $AppDirectory
try {
    Assert-Rejected { $unexpected = Lock-ForgeUpdate $AppDirectory; $unexpected.Dispose() } 'Concurrent update lock rejected'
} finally {
    $lock.Dispose()
}

$badId = 'forge-2.0.16-commander-deadbeef'
$bad = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory "versions\$badId")).FullName
$manifest = Read-ForgeJson (Join-Path $active.Directory 'commander-approved.json')
$manifest.build = $badId
foreach ($file in $manifest.files) {
    Copy-Item -LiteralPath (Join-Path $active.Directory $file.name) -Destination (Join-Path $bad $file.name) -Force
}
Write-ForgeJson (Join-Path $bad 'commander-approved.json') $manifest
$badJar = Join-Path $bad 'forge-gui-desktop-2.0.16-jar-with-dependencies.jar'
[IO.File]::AppendAllText($badJar, 'changed after tests')
Assert-Rejected { Set-ForgeActiveBuild $AppDirectory $badId } 'Changed packaged JAR rejected'

$previousId = (Get-Content -LiteralPath (Join-Path $AppDirectory 'previous.txt') -Raw).Trim()
Set-ForgeActiveBuild $AppDirectory $previousId
if ((Get-ForgeLaunchDirectory $AppDirectory) -ne (Get-ForgeApprovedBuild $AppDirectory $previousId).Directory) {
    throw 'The launcher did not resolve the rollback release.'
}
Set-ForgeActiveBuild $AppDirectory $activeId
$checks.Add('Rollback and reactivation preserved both approved copies')
Set-ForgePointer $currentFile 'forge-2.0.16'
try {
    if ((Get-ForgeLaunchDirectory $AppDirectory) -ne (Get-ForgeApprovedBuild $AppDirectory $previousId).Directory) {
        throw 'The launcher did not fall back to the approved previous release.'
    }
    $checks.Add('Launcher recovered from an invalid current pointer')
} finally {
    Set-ForgePointer $currentFile $activeId
}

$source = Join-Path $config.worktreeRoot 'forge-2.0.16'
$originalCommit = @(Invoke-ForgeGit $source @('rev-parse', 'HEAD'))[0]
$policyFile = Join-Path $source 'forge-ai\src\main\java\forge\ai\CommanderCombatTargets.java'
$originalPolicy = [IO.File]::ReadAllText($policyFile)
try {
    [IO.File]::WriteAllText($policyFile, $originalPolicy + "`n")
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $prepare = Join-Path $PSScriptRoot 'Prepare-ForgeRelease.ps1'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $prepare -AppDirectory $AppDirectory -Tag forge-2.0.16 -ResumePort -Offline
    if ($LASTEXITCODE -eq 0) {
        throw 'An unfinished source port was accepted.'
    }
    Assert-ActiveUnchanged
    $checks.Add('Unfinished source port preserved the active release')
    $disabledPolicy = $originalPolicy.Replace('GameRules rules = ai.getGame().getRules();', @'
if (ai.getGame() != null) {
            return null;
        }
        GameRules rules = ai.getGame().getRules();
'@)
    if ($disabledPolicy -eq $originalPolicy) {
        throw 'Could not construct the deliberate Commander regression.'
    }
    [IO.File]::WriteAllText($policyFile, $disabledPolicy)
    [void](Invoke-ForgeGit $source @('add', 'forge-ai/src/main/java/forge/ai/CommanderCombatTargets.java'))
    [void](Invoke-ForgeGit $source @('commit', '-m', 'Exercise release gate with a deliberately disabled Commander policy'))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $prepare -AppDirectory $AppDirectory -Tag forge-2.0.16 -ResumePort -Offline
    if ($LASTEXITCODE -eq 0) {
        throw 'The deliberate Commander regression was accepted.'
    }
    Assert-ActiveUnchanged
    $failure = Read-ForgeJson (Join-Path $AppDirectory 'commander-status.json')
    if ($failure.phase -ne 'failed' -or $failure.message -notmatch 'tests failed') {
        throw 'The regression failure did not produce the expected release diagnostic.'
    }
    $checks.Add('Real packaged Commander regression failure preserved the active release')
} finally {
    [IO.File]::WriteAllText($policyFile, $originalPolicy)
    [void](Invoke-ForgeGit $source @('reset', '--hard', $originalCommit))
}
& $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $prepare -AppDirectory $AppDirectory -Tag forge-2.0.16 -ResumePort -Offline
if ($LASTEXITCODE -ne 0) {
    throw 'The approved release did not recover after the deliberate test failure.'
}
Assert-ActiveUnchanged
$checks.Add('Successful retry recovered the approved release')
Write-ForgeJson (Join-Path $AppDirectory 'workflow-verification.json') @{
    time = [DateTime]::UtcNow.ToString('o'); active = $activeId; checks = $checks.ToArray()
}
$checks
