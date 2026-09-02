<#
.SYNOPSIS
    Downloads and validates one published pglogical release package.

.DESCRIPTION
    The package is selected by release tag, not by a mutable "latest" alias.
    Exactly one ZIP and one SHA256SUMS.txt asset are required. The ZIP is
    checksum-verified, safely extracted into an isolated staging directory, and
    its BUILD-INFO.json is checked against the tag, PostgreSQL major, and exact
    package asset identity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReleaseTag,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+$')][string]$PostgresqlMajor,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$PackageAssetName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $release = Get-GitHubReleaseByTag -Repository $Repository -Tag $ReleaseTag
    if ($null -eq $release) {
        throw "Published release for tag '$ReleaseTag' was not found."
    }
    if ([bool]$release.draft -or [bool]$release.prerelease) {
        throw "Release '$ReleaseTag' is draft or prerelease; compatibility tests require a published stable release."
    }

    $selectedAssets = Get-ReleasePackageAssets -Assets @($release.assets)
    $selectedPackageName = [string]$selectedAssets.Package.name
    if ($PackageAssetName -and $PackageAssetName -ne $selectedPackageName) {
        throw "Requested package asset '$PackageAssetName' is not the release's selected package asset '$selectedPackageName'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$selectedAssets.Package.browser_download_url) -or [string]::IsNullOrWhiteSpace([string]$selectedAssets.Checksums.browser_download_url)) {
        throw 'Selected release assets do not have download URLs; failing closed.'
    }

    $root = [System.IO.Path]::GetFullPath($OutputDir)
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $root
    $zipPath = Join-Path $root $selectedPackageName
    $checksumsPath = Join-Path $root 'SHA256SUMS.txt'
    $stagingDir = Join-Path $root 'staging'

    $null = Invoke-ReleasePackageDownload -Url ([string]$selectedAssets.Package.browser_download_url) -OutFile $zipPath
    $null = Invoke-ReleasePackageDownload -Url ([string]$selectedAssets.Checksums.browser_download_url) -OutFile $checksumsPath
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) { throw 'Downloaded package ZIP is missing or empty.' }
    if (-not (Test-Path -LiteralPath $checksumsPath -PathType Leaf) -or (Get-Item -LiteralPath $checksumsPath).Length -eq 0) { throw 'Downloaded SHA256SUMS.txt is missing or empty.' }

    $packageSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumsText = Get-Content -LiteralPath $checksumsPath -Raw
    $expectedPackageSha256 = Get-ChecksumForAsset -ChecksumsText $checksumsText -AssetName $selectedPackageName -ActualSha256 $packageSha256
    $archive = Expand-ReleasePackageArchive -ZipPath $zipPath -OutputDir $stagingDir
    Test-ReleasePackageProvenance -Info $archive.BuildInfo -ReleaseTag $ReleaseTag -PostgresqlMajor $PostgresqlMajor -PackageAssetName $selectedPackageName | Out-Null

    $result = [ordered]@{
        status = 'success'
        releaseTag = $ReleaseTag
        releaseId = [string]$release.id
        postgresqlMajor = $PostgresqlMajor
        packageAssetName = $selectedPackageName
        packageAssetUrl = [string]$selectedAssets.Package.browser_download_url
        checksumAssetName = [string]$selectedAssets.Checksums.name
        packageSha256 = $packageSha256
        expectedPackageSha256 = $expectedPackageSha256
        zipPath = $zipPath
        checksumsPath = $checksumsPath
        stagingDir = $archive.StagingDir
        packageProvenance = $archive.BuildInfo
    }
    $resultPath = Join-Path $root 'package-install.json'
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8
    Write-Output ($result | ConvertTo-Json -Depth 20 -Compress)
}
catch {
    Write-Error $_
    exit 1
}
