<#
.SYNOPSIS
    Unit tests for the normal upstream-only release planner.
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
        [string]$Body = ''
    )
    return [pscustomobject]@{ tag_name = $Tag; body = $Body; draft = $false; prerelease = $false }
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

Test-Case 'A brand-new upstream version plans windows.1 for every missing major' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @()
    Assert-Equal 2 $plan.Count
    Assert-Equal 1 $plan[0].windowsPackagingRevision
    Assert-Equal 'pglogical-2.4.9-pg14-windows.1' $plan[0].localTag
    Assert-Equal 1 $plan[1].windowsPackagingRevision
    Assert-Equal 'postgresql-18.6-2-windows-x64-binaries.zip' $plan[1].edbArtifactFilename
}

Test-Case 'Only the missing major is planned; existing majors do not need artifact resolution' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.9-pg14-windows.1' -Body 'malformed legacy body'),
        (New-Release -Tag 'pglogical-2.4.9-pg18-windows.1')
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'A current minor or EDB revision drift produces an empty normal plan' {
    $releases = @(
        (New-Release -Tag 'pglogical-2.4.9-pg14-windows.1'),
        (New-Release -Tag 'pglogical-2.4.9-pg18-windows.1')
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'A missing artifact fails closed only for a missing release entry' {
    Assert-Throws {
        Invoke-Plan -Majors @('18') -Artifacts ([ordered]@{}) -LocalReleases @() | Out-Null
    } -MessagePattern 'no exact EDB artifact identity was resolved'
}

Test-Case 'Draft and prerelease releases do not count as normal coverage' {
    $draft = New-Release -Tag 'pglogical-2.4.9-pg18-windows.1'
    $draft.draft = $true
    $pre = New-Release -Tag 'pglogical-2.4.9-pg14-windows.1'
    $pre.prerelease = $true
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @($draft, $pre)
    Assert-Equal 2 $plan.Count
    Assert-Equal 'pglogical-2.4.9-pg14-windows.1' $plan[0].localTag
    Assert-Equal 'pglogical-2.4.9-pg18-windows.1' $plan[1].localTag
}

Test-Case 'A higher existing packaging revision still counts as covered in normal mode' {
    $releases = @(New-Release -Tag 'pglogical-2.4.9-pg18-windows.7')
    $plan = Invoke-Plan -Majors @('18') -Artifacts ([ordered]@{}) -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Complete-Tests
