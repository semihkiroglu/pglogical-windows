<#
.SYNOPSIS
    Unit tests for the normal unified upstream-release planner.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

function New-Artifact {
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [Parameter(Mandatory = $true)][int]$Revision
    )
    $filename = "postgresql-$Major.$Minor-$Revision-windows-x64-binaries.zip"
    return [pscustomobject]@{
        major = $Major
        minor = $Minor
        revision = $Revision
        filename = $filename
        url = "https://get.enterprisedb.com/postgresql/$filename"
    }
}

function New-Release {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string[]]$Majors,
        [string]$Version = '2.4.9',
        [int]$PackagingRevision = 1,
        [switch]$Draft,
        [switch]$Prerelease
    )
    $assets = @($Majors | ForEach-Object {
        $name = Get-PackageZipName -PglogicalVersion $Version -PostgresqlMajor $_ -PackagingRevision $PackagingRevision
        [pscustomobject]@{ name = $name; browser_download_url = "https://example.invalid/$name" }
    })
    return [pscustomobject]@{
        tag_name = $Tag
        body = ''
        draft = [bool]$Draft
        prerelease = [bool]$Prerelease
        assets = $assets
    }
}

$base = @{
    Version     = '2.4.9'
    UpstreamTag = 'REL2_4_9'
    CommitSha   = '9a0e182745885ad0152ea387988c95a483396a81'
}

function Invoke-Plan {
    param(
        [string[]]$Majors,
        [System.Collections.IDictionary]$Artifacts,
        [object[]]$LocalReleases
    )
    return @(Get-ReleasePlan `
        -Version $base.Version `
        -UpstreamTag $base.UpstreamTag `
        -CommitSha $base.CommitSha `
        -Majors $Majors `
        -Artifacts $Artifacts `
        -LocalReleases $LocalReleases)
}

Test-Case 'A brand-new upstream version plans one common w1 tag for every major' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @()
    Assert-Equal 2 $plan.Count
    Assert-Equal 1 $plan[0].windowsPackagingRevision
    Assert-Equal '2.4.9-w1' $plan[0].localTag
    Assert-Equal '2.4.9-w1' $plan[1].localTag
    Assert-Equal 'postgresql-18.6-2-windows-x64-binaries.zip' $plan[1].edbArtifactFilename
}

Test-Case 'A complete unified release covers every major without artifact resolution' {
    $releases = @(
        (New-Release -Tag '2.4.9-w1' -Majors @('14', '18'))
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'A partial unified release plans a complete next revision for every major' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $releases = @(
        (New-Release -Tag '2.4.9-w1' -Majors @('14'))
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 2 $plan.Count
    Assert-Equal 2 $plan[0].windowsPackagingRevision
    Assert-Equal '2.4.9-w2' $plan[0].localTag
    Assert-Equal '2.4.9-w2' $plan[1].localTag
}

Test-Case 'An explicit unified migration ignores complete legacy coverage' {
    $legacy = @(New-Release -Tag '2.4.9-pg14-w1' -Version '2.4.9' -Majors @('14'))
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $plan = @(Get-ReleasePlan -Version '2.4.9' -UpstreamTag 'REL2_4_9' -CommitSha ('a' * 40) -Majors @('14', '18') -Artifacts $artifacts -LocalReleases $legacy -ForceUnified)
    Assert-Equal 2 $plan.Count
    Assert-Equal '2.4.9-w1' $plan[0].localTag
    Assert-Equal '2.4.9-w1' $plan[1].localTag
}

Test-Case 'A current minor or EDB revision drift produces an empty normal plan' {
    $releases = @(
        (New-Release -Tag '2.4.9-w1' -Majors @('14', '18'))
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'A missing artifact fails closed when a unified release is required' {
    Assert-Throws {
        Invoke-Plan -Majors @('18') -Artifacts ([ordered]@{}) -LocalReleases @() | Out-Null
    } -MessagePattern 'no exact EDB artifact identity was resolved'
}

Test-Case 'Draft and prerelease releases do not count as normal coverage' {
    $draft = New-Release -Tag '2.4.9-w1' -Majors @('14', '18') -Draft
    $pre = New-Release -Tag '2.4.9-w2' -Majors @('14', '18') -PackagingRevision 2 -Prerelease
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @($draft, $pre)
    Assert-Equal 2 $plan.Count
    Assert-Equal '2.4.9-w3' $plan[0].localTag
    Assert-Equal '2.4.9-w3' $plan[1].localTag
}

Test-Case 'A higher existing unified packaging revision still counts as covered' {
    $releases = @(New-Release -Tag '2.4.9-w7' -Majors @('18') -PackagingRevision 7)
    $plan = Invoke-Plan -Majors @('18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'Legacy per-major releases remain coverage during migration' {
    $releases = @(
        (New-Release -Tag '2.4.9-pg14-w1' -Majors @('14')),
        (New-Release -Tag '2.4.9-pg18-w1' -Majors @('18'))
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Complete-Tests
