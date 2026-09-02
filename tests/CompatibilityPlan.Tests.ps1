<#
.SYNOPSIS
    Unit tests for compatibility smoke and targeted rebuild planning.
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
        [Parameter(Mandatory = $true)][string]$ArtifactFilename,
        [int]$AssetCount = 1,
        [switch]$Draft,
        [switch]$Prerelease
    )
    $assets = @([pscustomobject]@{
        name = "package-$($Tag).zip"
        browser_download_url = "https://github.com/o/r/releases/download/$Tag/package-$($Tag).zip"
    })
    if ($AssetCount -gt 1) {
        $assets += [pscustomobject]@{
            name = "package-extra-$($Tag).zip"
            browser_download_url = "https://github.com/o/r/releases/download/$Tag/package-extra-$($Tag).zip"
        }
    }
    return [pscustomobject]@{
        tag_name = $Tag
        body = "| PostgreSQL exact build version | ``$(([regex]::Match($ArtifactFilename, 'postgresql-[0-9]+\.([0-9]+)-')).Groups[1].Value)`` |`n| EDB binaries archive | ``$ArtifactFilename`` |"
        draft = [bool]$Draft
        prerelease = [bool]$Prerelease
        assets = $assets
    }
}

function New-Result {
    param(
        [string]$Major,
        [string]$Status = 'failed',
        [string]$FailureClass = 'compatibility',
        [string]$PackageTag = "2.4.8-pg$Major-w1",
        [string]$PackageArtifact,
        [string]$ServerArtifact
    )
    return [pscustomobject]@{
        postgresqlMajor = $Major
        status = $Status
        failureClass = $FailureClass
        localReleaseTag = $PackageTag
        localPackageBuildArtifactFilename = $PackageArtifact
        serverEdbArtifactFilename = $ServerArtifact
        packageProvenance = [pscustomobject]@{
            pglogicalVersion = '2.4.8'
            upstreamTag = 'REL2_4_8'
            upstreamCommitSha = '9a0e182745885ad0152ea387988c95a483396a81'
            postgresqlCompatibilityMajor = $Major
        }
    }
}

$serverArtifacts = [ordered]@{
    '14' = New-Artifact -Major '14' -Minor '24' -Revision 1
    '15' = New-Artifact -Major '15' -Minor '19' -Revision 2
    '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
}

Test-Case 'Latest release selection is per major and ignores the global latest major' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg14-w1' -ArtifactFilename 'postgresql-14.23-1-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg14-w2' -ArtifactFilename 'postgresql-14.23-2-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.9-pg14-w1' -ArtifactFilename 'postgresql-14.24-1-windows-x64-binaries.zip'),
        (New-Release -Tag '2.5.0-pg18-w1' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    $latest = Select-LatestReleaseForMajor -Major '14' -Releases $releases
    Assert-Equal '2.4.9-pg14-w1' $latest.tag_name
    Assert-Equal '2.4.9' $latest.pglogicalVersion
}

Test-Case 'Equal upstream versions select the highest packaging revision' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg18-w1' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg18-w3' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg18-w2' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    Assert-Equal '2.4.8-pg18-w3' (Select-LatestReleaseForMajor -Major '18' -Releases $releases).tag_name
}

Test-Case 'Smoke plan marks drift as test, matching artifact as covered, and missing package as pending' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg14-w1' -ArtifactFilename 'postgresql-14.23-1-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg15-w1' -ArtifactFilename 'postgresql-15.19-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-CompatibilitySmokePlan -Majors @('14', '15', '18') -LocalReleases $releases -ServerArtifacts $serverArtifacts)
    Assert-Equal 3 $plan.Count
    Assert-Equal 'test' (@($plan | Where-Object postgresqlMajor -eq '14')[0].status)
    Assert-Equal 'covered' (@($plan | Where-Object postgresqlMajor -eq '15')[0].status)
    Assert-Equal 'pending' (@($plan | Where-Object postgresqlMajor -eq '18')[0].status)
    Assert-Equal '2.4.8-pg14-w1' (@($plan | Where-Object postgresqlMajor -eq '14')[0].localReleaseTag)
}

Test-Case 'Force makes a covered package eligible for smoke testing' {
    $releases = @(
        (New-Release -Tag '2.4.8-pg15-w1' -ArtifactFilename 'postgresql-15.19-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-CompatibilitySmokePlan -Majors @('15') -LocalReleases $releases -ServerArtifacts $serverArtifacts -Force)
    Assert-Equal 'test' $plan[0].status
}

Test-Case 'Targeted rebuild plans only the failed major with the next revision' {
    $local = @(
        (New-Release -Tag '2.4.8-pg17-w1' -ArtifactFilename 'postgresql-17.11-1-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg18-w1' -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip')
    )
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(
        (New-Result -Major '17' -Status 'passed' -FailureClass 'none' -PackageArtifact 'postgresql-17.11-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-17.11-1-windows-x64-binaries.zip'),
        (New-Result -Major '18' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -FailedMajors @('17', '18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 1 $plan.Count
    Assert-Equal '18' $plan[0].postgresqlMajor
    Assert-Equal 2 $plan[0].windowsPackagingRevision
    Assert-Equal 'postgresql-18.6-2-windows-x64-binaries.zip' $plan[0].edbArtifactFilename
}

Test-Case 'Targeted rebuild uses highest existing revision plus one even with gaps' {
    $local = @(
        (New-Release -Tag '2.4.8-pg18-w1' -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip'),
        (New-Release -Tag '2.4.8-pg18-w3' -ArtifactFilename 'postgresql-18.5-1-windows-x64-binaries.zip')
    )
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '18' -Revision 2 }
    $results = @(New-Result -Major '18' -PackageArtifact 'postgresql-18.5-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.18-2-windows-x64-binaries.zip')
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 1 $plan.Count
    Assert-Equal 4 $plan[0].windowsPackagingRevision
}

Test-Case 'Targeted rebuild does not plan when the package already uses the current artifact' {
    $local = @(New-Release -Tag '2.4.8-pg18-w2' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(New-Result -Major '18' -PackageTag '2.4.8-pg18-w2' -PackageArtifact 'postgresql-18.6-2-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 0 $plan.Count
}

Test-Case 'Environment and download failures never create a targeted rebuild' {
    $local = @(New-Release -Tag '2.4.8-pg18-w1' -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip')
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(
        (New-Result -Major '18' -FailureClass 'environment' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip'),
        (New-Result -Major '18' -FailureClass 'download' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 0 $plan.Count
}

Test-Case 'Compatibility failure marker is deterministic' {
    Assert-Equal '<!-- pglogical-compatibility-failure: pg18/2.4.8-pg18-w1/postgresql-18.6-2-windows-x64-binaries.zip -->' (Get-CompatibilityFailureMarker -Major '18' -PackageTag '2.4.8-pg18-w1' -ServerArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
}

Complete-Tests
