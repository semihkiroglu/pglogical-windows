<#
.SYNOPSIS
    Unit tests for deterministic unified-release and repository-Latest selection.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

function New-Release {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$Version = '2.4.8',
        [int]$PackagingRevision = 1,
        [string[]]$PackageMajors = @(),
        [switch]$Draft,
        [switch]$Prerelease
    )
    $assets = @($PackageMajors | ForEach-Object {
        $name = Get-PackageZipName -PglogicalVersion $Version -PostgresqlMajor $_ -PackagingRevision $PackagingRevision
        [pscustomobject]@{
            name = $name
            browser_download_url = "https://github.com/o/r/releases/download/$Tag/$name"
        }
    })
    return [pscustomobject]@{
        tag_name = $Tag
        draft = [bool]$Draft
        prerelease = [bool]$Prerelease
        body = ''
        assets = $assets
    }
}

$version = '2.4.8'
$majors = @('14', '15', '16', '17', '18')

Test-Case 'Latest: one complete unified release is selected' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: highest unified Windows revision wins' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -PackagingRevision 1 -PackageMajors $majors),
        (New-Release -Tag '2.4.8-w3' -PackagingRevision 3 -PackageMajors $majors),
        (New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w3' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: incomplete unified releases are not eligible' {
    $releases = @(
        (New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -PackageMajors @('14', '15')),
        (New-Release -Tag '2.4.8-w1' -PackagingRevision 1 -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: legacy per-major releases do not win over unified releases' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w9' -PackagingRevision 9 -PackageMajors @('18')),
        (New-Release -Tag '2.4.8-w1' -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: draft and prerelease unified releases are ignored' {
    $releases = @(
        (New-Release -Tag '2.4.8-w3' -PackagingRevision 3 -PackageMajors $majors -Draft),
        (New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -PackageMajors $majors -Prerelease),
        (New-Release -Tag '2.4.8-w1' -PackagingRevision 1 -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: unrelated versions are ignored' {
    $releases = @(
        (New-Release -Tag '2.4.9-w1' -Version '2.4.9' -PackageMajors $majors),
        (New-Release -Tag '2.4.8-w1' -PackageMajors $majors)
    )
    Assert-Equal '2.4.8-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: no complete unified release returns null' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -PackageMajors @('14', '15'))
    )
    Assert-True ($null -eq (Select-LatestRelease -Version $version -Majors $majors -Releases $releases))
}

Test-Case 'Per-major selection chooses the newest unified release containing that asset' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -PackageMajors @('14', '18')),
        (New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -PackageMajors @('14', '18')),
        (New-Release -Tag '2.4.9-w1' -Version '2.4.9' -PackageMajors @('14'))
    )
    $latest = Select-LatestReleaseForMajor -Major '14' -Releases $releases
    Assert-Equal '2.4.9-w1' $latest.tag_name
    Assert-Equal 'pglogical-2.4.9-pg14-w1-x64.zip' $latest.packageAssetName
}

Test-Case 'Per-major selection ignores a unified release missing the requested asset' {
    $releases = @(
        (New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -PackageMajors @('14')),
        (New-Release -Tag '2.4.8-w1' -PackagingRevision 1 -PackageMajors @('18'))
    )
    $latest = Select-LatestReleaseForMajor -Major '18' -Releases $releases
    Assert-Equal '2.4.8-w1' $latest.tag_name
}

Test-Case 'Per-major selection still reads a legacy release during migration' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w1' -PackageMajors @('18'))
    )
    Assert-Equal '2.4.8-pg18-w1' (Select-LatestReleaseForMajor -Major '18' -Releases $releases).tag_name
}

Complete-Tests
