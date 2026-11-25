param([string]$AppDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ForgeUpdate.psm1') -Force -DisableNameChecking
$lock = $null
$tag = 'release discovery'

try {
    try {
        $lock = Lock-ForgeUpdate $AppDirectory
    } catch [IO.IOException] {
        Write-Output 'A Forge update or port already owns the update lock.'
        exit 0
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Card-Forge/forge/releases/latest' `
        -UserAgent 'Card-Forge-Commander-Updater' -UseBasicParsing -TimeoutSec 30
    $tag = $release.tag_name
    Assert-ForgeTag $tag
    if ($release.draft -or $release.prerelease) {
        throw 'GitHub did not return a stable release.'
    }
    $active = Get-ForgeApprovedBuild $AppDirectory ((Get-Content -LiteralPath (Join-Path $AppDirectory 'current.txt') -Raw).Trim())
    if ($active.Manifest.release -eq $tag) {
        Write-ForgeLog $AppDirectory "Up to date ($tag, Commander patch verified)."
        exit 0
    }

    $version = $tag.Substring(6)
    $name = "forge-installer-$version.tar.bz2"
    $asset = @($release.assets | Where-Object name -EQ $name)
    $url = "https://github.com/Card-Forge/forge/releases/download/$tag/$name"
    if ($asset.Count -ne 1 -or $asset[0].browser_download_url -cne $url -or
        $asset[0].digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "The verified official desktop archive for $tag is unavailable."
    }
    $directory = [IO.Directory]::CreateDirectory((Join-Path $AppDirectory "downloads\$tag")).FullName
    $archive = Join-Path $directory $name
    if (-not (Test-Path -LiteralPath $archive)) {
        $temporary = "$archive.part"
        Invoke-ForgeTool "$env:SystemRoot\System32\curl.exe" @('--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '--connect-timeout', '20',
            '--speed-limit', '1024', '--speed-time', '60', '--max-time', '600', '--output', $temporary, $url) `
            $directory (Join-Path $directory 'download.log') 1900
        if ((Get-Item -LiteralPath $temporary).Length -ne $asset[0].size -or
            'sha256:' + (Get-FileHash -LiteralPath $temporary).Hash -ne $asset[0].digest) {
            throw 'The downloaded Forge archive failed size or SHA-256 verification.'
        }
        [IO.File]::Move($temporary, $archive)
    }
    if ((Get-Item -LiteralPath $archive).Length -ne $asset[0].size -or
        'sha256:' + (Get-FileHash -LiteralPath $archive).Hash -ne $asset[0].digest) {
        throw 'The staged official archive failed verification.'
    }
    $release | Add-Member -NotePropertyName archiveName -NotePropertyValue $name
    $release | Add-Member -NotePropertyName archiveSha256 -NotePropertyValue $asset[0].digest.Substring(7)
    Write-ForgeJson (Join-Path $directory 'release.json') $release
    Write-ForgeLog $AppDirectory "Verified $tag. Preparing the Commander port before activation."
} catch {
    $failure = "$tag download/discovery failed. $($_.Exception.Message)"
    Write-ForgeJson (Join-Path $AppDirectory 'commander-status.json') @{
        release = $tag; phase = 'failed'; message = $failure; time = [DateTime]::UtcNow.ToString('o')
    }
    Write-ForgeLog $AppDirectory "Update failed. $failure"
    exit 1
} finally {
    if ($lock) {
        $lock.Dispose()
    }
}
& (Join-Path $PSScriptRoot 'Prepare-ForgeRelease.ps1') -AppDirectory $AppDirectory -Tag $tag -ResumePort
exit $LASTEXITCODE
