<#
.SYNOPSIS
    Unit tests for Select-LatestRelease: deterministic GitHub Latest selection
    across ALL published releases for a pglogical version.
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
    return [pscustomobject]@{ tag_name = $Tag; draft = [bool]$Draft; prerelease = [bool]$Prerelease }
}

$version = '2.4.8'
$majors = @('14', '15', '16', '17', '18')

Test-Case 'Latest: full PG14-18 set selects PG18' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg14-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg15-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg16-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg17-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg18-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: only PG15 rebuilt but PG18 already exists -> PG18' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg15-windows.2'),
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg18-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: PG18 absent, PG17 exists -> PG17' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg14-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg17-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg17-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: draft PG18 is ignored' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Draft),
        (New-Release -Tag 'pglogical-2.4.8-pg17-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg17-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: prerelease PG18 is ignored' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Prerelease),
        (New-Release -Tag 'pglogical-2.4.8-pg16-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg16-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: unrelated pglogical versions are ignored' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.7-pg18-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg14-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg14-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: unconfigured higher major is ignored' {
    # PG19 exists as a release but is not in the configured majors list.
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg19-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1')
    )
    Assert-Equal 'pglogical-2.4.8-pg18-windows.1' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Test-Case 'Latest: no matching release returns null' {
    Assert-True ($null -eq (Select-LatestRelease -Version $version -Majors $majors -Releases @()))
}

Test-Case 'Latest: for one major with multiple revisions, the newest revision wins' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.1'),
        (New-Release -Tag 'pglogical-2.4.8-pg18-windows.2')
    )
    Assert-Equal 'pglogical-2.4.8-pg18-windows.2' (Select-LatestRelease -Version $version -Majors $majors -Releases $releases)
}

Complete-Tests
