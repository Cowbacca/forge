Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ForgeJson($Path, $Value) {
    $temporary = "$Path-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Read-ForgeJson($Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-ForgeLog($AppDirectory, $Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'), $Message
    Add-Content -LiteralPath (Join-Path $AppDirectory 'updates.log') -Value $line -Encoding UTF8
    Write-Output $line
}

function Lock-ForgeUpdate($AppDirectory) {
    [IO.File]::Open((Join-Path $AppDirectory 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
}

function Assert-ForgeTag($Tag) {
    if ($Tag -notmatch '^forge-\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw "Invalid stable Forge release '$Tag'."
    }
}

function Invoke-ForgeGit($Repository, [string[]]$Arguments) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -c "safe.directory=$Repository" -c http.sslBackend=schannel `
            -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 -C $Repository @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($code -ne 0) {
        throw "git $($Arguments -join ' ') failed. $($output -join ' ')"
    }
    $output | ForEach-Object { "$_" }
}

function Invoke-ForgeTool($Executable, [string[]]$Arguments, $Directory, $LogPath, $TimeoutSeconds = 900) {
    $quoted = $Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $process = Start-Process -FilePath $Executable -ArgumentList ($quoted -join ' ') `
        -WorkingDirectory $Directory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err"
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "$Executable timed out. See $LogPath."
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        throw "$Executable failed with exit $($process.ExitCode). See $LogPath and $LogPath.err."
    }
}

function Get-ForgeApprovedBuild($AppDirectory, $BuildId) {
    if ($BuildId -notmatch '^forge-\d+\.\d+\.\d+(?:\.\d+)?-commander(?:-[a-f0-9]+)?$') {
        throw "'$BuildId' does not identify a Commander build."
    }
    $directory = Join-Path $AppDirectory "versions\$BuildId"
    $manifest = Read-ForgeJson (Join-Path $directory 'commander-approved.json')
    $config = Read-ForgeJson (Join-Path $AppDirectory 'commander-config.json')
    Assert-ForgeTag $manifest.release
    if ($manifest.patch -ne $config.patchCommit -or $manifest.build -ne $BuildId -or
        $manifest.failed -ne 0 -or $manifest.skipped -ne 0 -or $manifest.passed -lt 19) {
        throw "The approval for $BuildId does not meet the Commander release checks."
    }
    if (-not $BuildId.StartsWith($manifest.release + '-commander')) {
        throw 'The approved build and release identifiers disagree.'
    }
    Assert-ForgePackageFiles $directory $manifest
    $results = Get-ForgeCombatResult (Join-Path $directory 'commander-tests.xml') $config
    if ($results.passed -ne $manifest.passed) {
        throw 'The packaged test report does not support the approval.'
    }
    [pscustomobject]@{ Id = $BuildId; Directory = $directory; Manifest = $manifest }
}

function Assert-ForgePackageFiles($Directory, $Manifest) {
    foreach ($file in $Manifest.files) {
        if ($file.name -notmatch '^[a-zA-Z0-9._-]+$') {
            throw 'Invalid approved package filename.'
        }
        $path = Join-Path $Directory $file.name
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "The tested package file $path changed after approval."
        }
    }
    $version = $Manifest.release.Substring(6)
    $expected = @('forge.exe', "forge-gui-desktop-$version-jar-with-dependencies.jar", 'commander-tests.xml')
    foreach ($name in $expected) {
        if ($name -notin $Manifest.files.name) {
            throw "The approval is missing $name."
        }
    }
}

function Set-ForgePointer($Path, $BuildId) {
    $temporary = "$Path-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $BuildId)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Set-ForgeActiveBuild($AppDirectory, $BuildId) {
    $build = Get-ForgeApprovedBuild $AppDirectory $BuildId
    $currentPath = Join-Path $AppDirectory 'current.txt'
    $previousPath = Join-Path $AppDirectory 'previous.txt'
    $old = (Get-Content -LiteralPath $currentPath -Raw).Trim()
    if ($old -eq $BuildId) {
        return
    }
    [void](Get-ForgeApprovedBuild $AppDirectory $old)
    Set-ForgePointer $previousPath $old
    Set-ForgePointer $currentPath $build.Id
}

function Get-ForgeLaunchDirectory($AppDirectory) {
    try {
        $id = (Get-Content -LiteralPath (Join-Path $AppDirectory 'current.txt') -Raw).Trim()
        (Get-ForgeApprovedBuild $AppDirectory $id).Directory
    } catch {
        $id = (Get-Content -LiteralPath (Join-Path $AppDirectory 'previous.txt') -Raw).Trim()
        (Get-ForgeApprovedBuild $AppDirectory $id).Directory
    }
}

function Test-ForgePackagedCombat($AppDirectory, $SourceDirectory, $PackageDirectory, $RunDirectory) {
    $config = Read-ForgeJson (Join-Path $AppDirectory 'commander-config.json')
    $jars = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter 'forge-gui-desktop-*-jar-with-dependencies.jar')
    if ($jars.Count -ne 1) {
        throw 'The candidate must contain exactly one Forge desktop JAR.'
    }
    $jar = $jars[0].FullName
    $before = (Get-FileHash -LiteralPath $jar).Hash
    $classes = [IO.Directory]::CreateDirectory((Join-Path $RunDirectory 'test-classes')).FullName
    $testRoot = Join-Path $SourceDirectory 'forge-gui-desktop\src\test\java'
    $sources = @($config.testSources | ForEach-Object { Join-Path $testRoot $_ })
    $libraries = @($config.testLibraries | ForEach-Object {
        $file = Join-Path $AppDirectory "test-libs\$($_.name)"
        if ((Get-FileHash -LiteralPath $file).Hash -ne $_.sha256) {
            throw "The test dependency $file failed verification."
        }
        $file
    })
    $compilePath = (@($jar) + $libraries) -join ';'
    Invoke-ForgeTool $config.javac (@('--release', '17', '-encoding', 'UTF-8', '-cp', $compilePath,
        '-d', $classes) + $sources) $RunDirectory (Join-Path $RunDirectory 'compile-tests.log') 120
    $profile = [IO.Directory]::CreateDirectory((Join-Path $RunDirectory 'profile')).FullName
    $reports = Join-Path $RunDirectory 'results'
    $runtimePath = (@($jar, $classes) + $libraries) -join ';'
    $savedRoaming = $env:APPDATA
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:APPDATA = [IO.Directory]::CreateDirectory((Join-Path $profile 'Roaming')).FullName
        $env:LOCALAPPDATA = [IO.Directory]::CreateDirectory((Join-Path $profile 'Local')).FullName
        Invoke-ForgeTool $config.java @('-Xmx4096m', '-Djava.awt.headless=true', "-Duser.home=$profile",
            '-cp', $runtimePath, 'org.testng.TestNG', '-testclass', ($config.testClasses -join ','),
            '-d', $reports) $PackageDirectory (Join-Path $RunDirectory 'combat-tests.log')
    } finally {
        $env:APPDATA = $savedRoaming
        $env:LOCALAPPDATA = $savedLocal
    }
    $result = Get-ForgeCombatResult (Join-Path $reports 'testng-results.xml') $config
    if ((Get-FileHash -LiteralPath $jar).Hash -ne $before) {
        throw 'The candidate JAR changed during its tests.'
    }
    $result
}

function Get-ForgeCombatResult($ReportPath, $Config) {
    [xml]$report = Get-Content -LiteralPath $ReportPath -Raw
    $result = $report.'testng-results'
    $testedClasses = @($result.suite.test.class.name)
    $methods = @($result.suite.test.class.'test-method' | Where-Object status -EQ 'PASS' | ForEach-Object name)
    if ([int]$result.failed -ne 0 -or [int]$result.skipped -ne 0 -or [int]$result.passed -lt 19 -or
        @($Config.testClasses | Where-Object { $_ -notin $testedClasses }).Count -gt 0) {
        throw "The packaged Commander/combat regression suite did not pass completely. See $ReportPath."
    }
    foreach ($method in $Config.commanderMethods) {
        if ($method -notin $methods) {
            throw "The required Commander regression $method did not pass."
        }
    }
    [pscustomobject]@{ passed = [int]$result.passed; failed = [int]$result.failed; skipped = [int]$result.skipped }
}

Export-ModuleMember -Function *-Forge*
