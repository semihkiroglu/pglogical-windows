<#
.SYNOPSIS
    Unit tests for deterministic per-major and repository-Latest selection.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

function New-Release {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [switch]$Draft,
        [switch]$Prerelease
    )
    return [pscustomobject]@{ tag_name = $Tag; draft = [bool]$Draft; prerelease = [bool]$Prerelease; body = ''; assets = @() }
}

$version = '2.4.8'
$majors = @('14', '15', '16', '17', '18')

Test-Case 'Latest: full PG14-18 set selects PG18' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg14-w1'),
        (New-Release -Tag '2.4.8-pg15-w1'),
        (New-Release -Tag '2.4.8-pg16-w1'),
        (New-Release -Tag '2.4.8-pg17-w1'),
        (New-Release -Tag '2.4.8-pg18-w1')
    )
    Assert-Equal '2.4.8-pg18-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: only PG15 rebuilt but PG18 already exists -> PG18' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg15-w2'),
        (New-Release -Tag '2.4.8-pg18-w1')
    )
    Assert-Equal '2.4.8-pg18-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: PG18 absent, PG17 exists -> PG17' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg14-w1'),
        (New-Release -Tag '2.4.8-pg17-w1')
    )
    Assert-Equal '2.4.8-pg17-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: draft PG18 is ignored' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w1' -Draft),
        (New-Release -Tag '2.4.8-pg17-w1')
    )
    Assert-Equal '2.4.8-pg17-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: prerelease PG18 is ignored' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w1' -Prerelease),
        (New-Release -Tag '2.4.8-pg16-w1')
    )
    Assert-Equal '2.4.8-pg16-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: unrelated pglogical versions are ignored' {
    $releases = @(
        (New-Release -Tag '2.4.7-pg18-w1'),
        (New-Release -Tag '2.4.8-pg14-w1')
    )
    Assert-Equal '2.4.8-pg14-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: unconfigured higher major is ignored' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg19-w1'),
        (New-Release -Tag '2.4.8-pg18-w1')
    )
    Assert-Equal '2.4.8-pg18-w1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: no matching release returns null' {
    Assert-True ($null -eq (Select-LatestRelease -Version $version -Majors $majors -Releases @()))
}

Test-Case 'Latest: for one major with multiple revisions, the newest revision wins' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w1'),
        (New-Release -Tag '2.4.8-pg18-w2')
    )
    Assert-Equal '2.4.8-pg18-w2' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Per-major selection chooses a higher upstream version before revision' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg14-w9'),
        (New-Release -Tag '2.4.9-pg14-w1')
    )
    $latest = Select-LatestReleaseForMajor -Major '14' -Releases $releases
    Assert-Equal '2.4.9-pg14-w1' $latest.tag_name
}

Complete-Tests
