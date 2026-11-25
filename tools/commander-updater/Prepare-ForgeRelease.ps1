param(
    [string]$AppDirectory = $PSScriptRoot,
    [Parameter(Mandatory)][string]$Tag,
    [switch]$ResumePort,
    [switch]$Offline,
    [switch]$Retry
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
Assert-ForgeTag $Tag
$lock = Lock-ForgeUpdate $AppDirectory
$step = 'source'
$worktree = $null
$sourceCommit = $null
$run = $null

function Save-PreparationStatus($Phase, $Message) {
    Write-ForgeJson (Join-Path $AppDirectory 'commander-status.json') @{
        release = $Tag; phase = $Phase; message = $Message; worktree = $worktree
        sourceCommit = $sourceCommit; runDirectory = $run
        time = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-ReleaseWorktree($Config, $BaseCommit) {
    $path = Join-Path $Config.worktreeRoot $Tag
    if (Test-Path -LiteralPath $path) {
        if (-not $ResumePort) {
            throw "The source worktree already exists at $path. Inspect it, then use -ResumePort."
        }
        $dirty = @(Invoke-ForgeGit $path @('status', '--porcelain'))
        if ($dirty.Count -gt 0) {
            throw "Finish and commit the port in $path before resuming."
        }
        [void](Invoke-ForgeGit $path @('merge-base', '--is-ancestor', $BaseCommit, 'HEAD'))
        return $path
    }
    $branch = 'codex-commander-' + $Tag
    [void](Invoke-ForgeGit $Config.sourceRepository @('worktree', 'add', '--no-checkout', '-b', $branch, $path, $BaseCommit))
    [void](Invoke-ForgeGit $path @('sparse-checkout', 'set', 'forge-ai/src/main/java', 'forge-gui-desktop/src/test/java'))
    [void](Invoke-ForgeGit $path @('reset', '--hard', 'HEAD'))
    [void](Invoke-ForgeGit $path @('cherry-pick', $Config.patchCommit))
    $path
}

function Build-CommanderJar($Config, $Source, $BaseCommit, $Package, $BuildDirectory) {
    $changed = @(Invoke-ForgeGit $Source @('diff', '--name-only', $BaseCommit, 'HEAD', '--', '*/src/main/java/*.java'))
    if ('forge-ai/src/main/java/forge/ai/CommanderCombatTargets.java' -notin $changed) {
        throw 'The release source does not contain the Commander combat port.'
    }
    $production = @($changed | ForEach-Object { Join-Path $Source $_ })
    $jar = Join-Path $Package "forge-gui-desktop-$($Tag.Substring(6))-jar-with-dependencies.jar"
    $classes = [IO.Directory]::CreateDirectory((Join-Path $BuildDirectory 'classes')).FullName
    $emptySource = [IO.Directory]::CreateDirectory((Join-Path $BuildDirectory 'empty-source')).FullName
    Invoke-ForgeTool $Config.javac (@('--release', '17', '-encoding', 'UTF-8', '-sourcepath', $emptySource,
        '-cp', $jar, '-d', $classes) + $production) $BuildDirectory (Join-Path $BuildDirectory 'compile-patch.log') 120
    Invoke-ForgeTool $Config.jar @('uf', $jar, '-C', $classes, '.') $BuildDirectory (Join-Path $BuildDirectory 'package.log') 120
}

try {
    $config = Read-ForgeJson (Join-Path $AppDirectory 'commander-config.json')
    $download = Join-Path $AppDirectory "downloads\$Tag"
    $release = Read-ForgeJson (Join-Path $download 'release.json')
    if ($release.tag_name -ne $Tag -or $release.draft -or $release.prerelease) {
        throw 'The staged release is not the requested stable release.'
    }
    if (-not $Offline) {
        [void](Invoke-ForgeGit $config.sourceRepository @('fetch', '--depth=1', '--filter=blob:none', '--no-tags',
            'origin', "refs/tags/${Tag}:refs/tags/$Tag"))
    }
    $baseCommit = @(Invoke-ForgeGit $config.sourceRepository @('rev-parse', "$Tag^{commit}"))[0]
    $worktree = Join-Path $config.worktreeRoot $Tag
    $worktree = Get-ReleaseWorktree $config $baseCommit
    $sourceCommit = @(Invoke-ForgeGit $worktree @('rev-parse', 'HEAD'))[0]
    $buildId = "$Tag-commander-$($sourceCommit.Substring(0, 12))"
    $final = Join-Path $AppDirectory "versions\$buildId"
    if (Test-Path -LiteralPath $final) {
        [void](Get-ForgeApprovedBuild $AppDirectory $buildId)
        Set-ForgeActiveBuild $AppDirectory $buildId
        Save-PreparationStatus 'active' "$buildId is active."
        exit 0
    }
    $statusFile = Join-Path $AppDirectory 'commander-status.json'
    if ((Test-Path -LiteralPath $statusFile) -and -not $Retry) {
        $previous = Read-ForgeJson $statusFile
        if ($previous.phase -eq 'failed' -and $previous.release -eq $Tag -and
            $previous.PSObject.Properties['sourceCommit'] -and $previous.sourceCommit -eq $sourceCommit) {
            Write-ForgeLog $AppDirectory "Waiting for attention on $Tag. $($previous.message)"
            exit 1
        }
    }

    $step = 'build'
    $run = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory "builds\$Tag-$([guid]::NewGuid().ToString('N'))")).FullName
    $package = [IO.Directory]::CreateDirectory((Join-Path $run 'package')).FullName
    $archive = Join-Path $download $release.archiveName
    if ((Get-FileHash -LiteralPath $archive).Hash -ne $release.archiveSha256) {
        throw 'The staged official archive changed before the build.'
    }
    Save-PreparationStatus 'building' "Building $sourceCommit for $Tag."
    Invoke-ForgeTool "$env:SystemRoot\System32\tar.exe" @('-xf', $archive, '-C', $package) $run (Join-Path $run 'extract.log') 300
    Build-CommanderJar $config $worktree $baseCommit $package $run
    $step = 'tests'
    Save-PreparationStatus 'testing' "Testing the packaged JAR in $package."
    $tests = Test-ForgePackagedCombat $AppDirectory $worktree $package $run
    $report = Join-Path $run 'results\testng-results.xml'
    Copy-Item -LiteralPath $report -Destination (Join-Path $package 'commander-tests.xml')
    $manifest = @{
        build = $buildId; release = $Tag; baseCommit = $baseCommit; sourceCommit = $sourceCommit
        patch = $config.patchCommit; officialSha256 = $release.archiveSha256
        passed = $tests.passed; failed = $tests.failed; skipped = $tests.skipped
        testedAt = [DateTime]::UtcNow.ToString('o')
        files = @(@('forge.exe', "forge-gui-desktop-$($Tag.Substring(6))-jar-with-dependencies.jar", 'commander-tests.xml') |
            ForEach-Object { @{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $package $_)).Hash } })
    }
    Write-ForgeJson (Join-Path $package 'commander-approved.json') $manifest
    $step = 'activation'
    $versions = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory 'versions')).FullName
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($final)) -ne $versions -or
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($package)) -ne $run) {
        throw 'The package promotion paths are outside the release workspace.'
    }
    [IO.Directory]::Move($package, $final)
    Set-ForgeActiveBuild $AppDirectory $buildId
    Save-PreparationStatus 'active' "$buildId passed $($tests.passed) tests and is active."
    Write-ForgeLog $AppDirectory "Activated $buildId after $($tests.passed) packaged Commander/combat tests."
} catch {
    $failure = "$Tag $step failed. $($_.Exception.Message)"
    Save-PreparationStatus 'failed' $failure
    Write-ForgeLog $AppDirectory "Update failed. $failure"
    exit 1
} finally {
    $lock.Dispose()
}
