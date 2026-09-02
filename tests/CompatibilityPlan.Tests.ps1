<#
.SYNOPSIS
    Unit tests for compatibility smoke and unified compatibility rebuild planning.
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
        [Parameter(Mandatory = $true)][hashtable]$ArtifactsByMajor,
        [int]$PackagingRevision = 0,
        [switch]$Draft,
        [switch]$Prerelease
    )
    $tagMatch = [regex]::Match($Tag, '^([0-9]+\.[0-9]+\.[0-9]+)(?:-pg[0-9]+)?-w([0-9]+)$')
    $version = $tagMatch.Groups[1].Value
    $revision = if ($PackagingRevision -gt 0) { $PackagingRevision } else { [int]$tagMatch.Groups[2].Value }
    $assets = @()
    $sections = [System.Collections.Generic.List[string]]::new()
    foreach ($major in @($ArtifactsByMajor.Keys | ForEach-Object { [string]$_ } | Sort-Object { [int]$_ })) {
        $artifact = [string]$ArtifactsByMajor[$major]
        $packageName = Get-PackageZipName -PglogicalVersion $version -PostgresqlMajor $major -PackagingRevision $revision
        $assets += [pscustomobject]@{
            name = $packageName
            browser_download_url = "https://github.com/o/r/releases/download/$Tag/$packageName"
        }
        $minor = ([regex]::Match($artifact, 'postgresql-[0-9]+\.([0-9]+)-')).Groups[1].Value
        $sections.Add("### PostgreSQL $major`n`n| Field | Value |`n| --- | --- |`n| PostgreSQL exact build version | ``$major.$minor`` |`n| EDB binaries archive | ``$artifact`` |`n| EDB binaries URL | <https://get.enterprisedb.com/postgresql/$artifact> |")
    }
    return [pscustomobject]@{
        tag_name = $Tag
        body = ($sections -join "`n`n")
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
        [string]$PackageTag = '2.4.8-w1',
        [string]$PackageArtifact,
        [string]$ServerArtifact
    )
    $revision = 1
    if ($PackageTag -match '-w([0-9]+)$') { $revision = [int]$matches[1] }
    return [pscustomobject]@{
        postgresqlMajor = $Major
        status = $Status
        failureClass = $FailureClass
        localReleaseTag = $PackageTag
        localPackageAssetName = Get-PackageZipName -PglogicalVersion '2.4.8' -PostgresqlMajor $Major -PackagingRevision $revision
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
    '17' = New-Artifact -Major '17' -Minor '11' -Revision 1
    '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
}

Test-Case 'Latest release selection uses the newest unified release containing the requested major' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '14' = 'postgresql-14.23-1-windows-x64-binaries.zip'; '18' = 'postgresql-18.5-1-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.4.8-w2' -ArtifactsByMajor @{ '14' = 'postgresql-14.23-2-windows-x64-binaries.zip'; '18' = 'postgresql-18.5-1-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.4.9-w1' -ArtifactsByMajor @{ '14' = 'postgresql-14.24-1-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.5.0-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.6-2-windows-x64-binaries.zip' })
    )
    $latest = Select-LatestReleaseForMajor -Major '14' -Releases $releases
    Assert-Equal '2.4.9-w1' $latest.tag_name
    Assert-Equal '2.4.9' $latest.pglogicalVersion
    Assert-Equal 'pglogical-2.4.9-pg14-w1-x64.zip' $latest.packageAssetName
}

Test-Case 'Equal upstream versions select the highest unified packaging revision' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.6-2-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.4.8-w3' -ArtifactsByMajor @{ '18' = 'postgresql-18.6-2-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.4.8-w2' -ArtifactsByMajor @{ '18' = 'postgresql-18.6-2-windows-x64-binaries.zip' })
    )
    Assert-Equal '2.4.8-w3' (Select-LatestReleaseForMajor -Major '18' -Releases $releases).tag_name
}

Test-Case 'Smoke plan selects one package asset from a unified release per major' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{
            '14' = 'postgresql-14.23-1-windows-x64-binaries.zip'
            '15' = 'postgresql-15.19-2-windows-x64-binaries.zip'
        })
    )
    $plan = @(Get-CompatibilitySmokePlan -Majors @('14', '15', '18') -LocalReleases $releases -ServerArtifacts $serverArtifacts)
    Assert-Equal 3 $plan.Count
    Assert-Equal 'test' (@($plan | Where-Object postgresqlMajor -eq '14')[0].status)
    Assert-Equal 'covered' (@($plan | Where-Object postgresqlMajor -eq '15')[0].status)
    Assert-Equal 'pending' (@($plan | Where-Object postgresqlMajor -eq '18')[0].status)
    Assert-Equal '2.4.8-w1' (@($plan | Where-Object postgresqlMajor -eq '14')[0].localReleaseTag)
    Assert-Equal 'pglogical-2.4.8-pg14-w1-x64.zip' (@($plan | Where-Object postgresqlMajor -eq '14')[0].localPackageAssetName)
}

Test-Case 'Smoke plan treats a previously passed package/server pair as covered' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.5-1-windows-x64-binaries.zip' })
    )
    $coverage = @([pscustomobject]@{
        postgresqlMajor = '18'
        localReleaseTag = '2.4.8-w1'
        localPackageAssetName = 'pglogical-2.4.8-pg18-w1-x64.zip'
        localPackageBuildArtifactFilename = 'postgresql-18.5-1-windows-x64-binaries.zip'
        serverEdbArtifactFilename = 'postgresql-18.6-2-windows-x64-binaries.zip'
        serverEdbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.6-2-windows-x64-binaries.zip'
        status = 'passed'
    })
    $plan = @(Get-CompatibilitySmokePlan -Majors @('18') -LocalReleases $releases -ServerArtifacts $serverArtifacts -CoverageEntries $coverage)
    Assert-Equal 'covered' $plan[0].status
    Assert-Equal 'compatibility-smoke' $plan[0].coverageSource

    $nextServerArtifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '7' -Revision 1 }
    $nextPlan = @(Get-CompatibilitySmokePlan -Majors @('18') -LocalReleases $releases -ServerArtifacts $nextServerArtifacts -CoverageEntries $coverage)
    Assert-Equal 'test' $nextPlan[0].status
}

Test-Case 'Compatibility coverage loader accepts a valid common release tag' {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("compatibility-coverage-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [ordered]@{
            schemaVersion = 1
            entries = @([ordered]@{
                postgresqlMajor = '18'
                localReleaseTag = '2.4.8-w1'
                localPackageAssetName = 'pglogical-2.4.8-pg18-w1-x64.zip'
                localPackageBuildArtifactFilename = 'postgresql-18.5-1-windows-x64-binaries.zip'
                serverEdbArtifactFilename = 'postgresql-18.6-2-windows-x64-binaries.zip'
                serverEdbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.6-2-windows-x64-binaries.zip'
                status = 'passed'
            })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        $entries = @(Read-CompatibilityCoverage -Path $path)
        Assert-Equal 1 $entries.Count
        Assert-Equal '2.4.8-w1' $entries[0].localReleaseTag
    }
    finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

Test-Case 'Force makes a covered package eligible for smoke testing' {
    $releases = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '15' = 'postgresql-15.19-2-windows-x64-binaries.zip' })
    )
    $plan = @(Get-CompatibilitySmokePlan -Majors @('15') -LocalReleases $releases -ServerArtifacts $serverArtifacts -Force)
    Assert-Equal 'test' $plan[0].status
}

Test-Case 'Compatibility rebuild plans all majors in one next unified revision' {
    $local = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{
            '17' = 'postgresql-17.11-1-windows-x64-binaries.zip'
            '18' = 'postgresql-18.4-1-windows-x64-binaries.zip'
        })
    )
    $artifacts = [ordered]@{
        '17' = New-Artifact -Major '17' -Minor '11' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '6' -Revision 2
    }
    $results = @(
        (New-Result -Major '17' -Status 'passed' -FailureClass 'none' -PackageArtifact 'postgresql-17.11-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-17.11-1-windows-x64-binaries.zip'),
        (New-Result -Major '18' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -Majors @('17', '18') -FailedMajors @('17', '18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 2 $plan.Count
    Assert-Equal '2.4.8-w2' $plan[0].localTag
    Assert-Equal '2.4.8-w2' $plan[1].localTag
    Assert-Equal '17' $plan[0].postgresqlMajor
    Assert-Equal '18' $plan[1].postgresqlMajor
    Assert-Equal 2 $plan[0].windowsPackagingRevision
    Assert-Equal 'postgresql-18.6-2-windows-x64-binaries.zip' $plan[1].edbArtifactFilename
}

Test-Case 'Unified compatibility rebuild uses highest existing revision plus one' {
    $local = @(
        (New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.4-1-windows-x64-binaries.zip' }),
        (New-Release -Tag '2.4.8-w3' -PackagingRevision 3 -ArtifactsByMajor @{ '18' = 'postgresql-18.5-1-windows-x64-binaries.zip' })
    )
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '18' -Revision 2 }
    $results = @(New-Result -Major '18' -PackageArtifact 'postgresql-18.5-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.18-2-windows-x64-binaries.zip')
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -Majors @('18') -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 1 $plan.Count
    Assert-Equal '2.4.8-w4' $plan[0].localTag
}

Test-Case 'Unified compatibility rebuild does not plan when the package already uses the current artifact' {
    $local = @(New-Release -Tag '2.4.8-w2' -PackagingRevision 2 -ArtifactsByMajor @{ '18' = 'postgresql-18.6-2-windows-x64-binaries.zip' })
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(New-Result -Major '18' -PackageTag '2.4.8-w2' -PackageArtifact 'postgresql-18.6-2-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -Majors @('18') -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 0 $plan.Count
}

Test-Case 'Environment and download failures never create a compatibility rebuild' {
    $local = @(New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.4-1-windows-x64-binaries.zip' })
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(
        (New-Result -Major '18' -FailureClass 'environment' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip'),
        (New-Result -Major '18' -FailureClass 'download' -PackageArtifact 'postgresql-18.4-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    )
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -Majors @('18') -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results)
    Assert-Equal 0 $plan.Count
}

Test-Case 'Unified compatibility rebuild does not jump past an in-flight candidate' {
    $local = @(New-Release -Tag '2.4.8-w1' -ArtifactsByMajor @{ '18' = 'postgresql-18.5-1-windows-x64-binaries.zip' })
    $artifacts = [ordered]@{ '18' = New-Artifact -Major '18' -Minor '6' -Revision 2 }
    $results = @(New-Result -Major '18' -PackageArtifact 'postgresql-18.5-1-windows-x64-binaries.zip' -ServerArtifact 'postgresql-18.6-2-windows-x64-binaries.zip')
    $plan = @(Get-TargetedRebuildPlan -Version '2.4.8' -UpstreamTag 'REL2_4_8' -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' -Majors @('18') -FailedMajors @('18') -Artifacts $artifacts -LocalReleases $local -CompatibilityResults $results -InFlightTags @('2.4.8-w2'))
    Assert-Equal 0 $plan.Count
}

Test-Case 'Compatibility failure marker is deterministic with a unified release tag' {
    Assert-Equal '<!-- pglogical-compatibility-failure: pg18/2.4.8-w1/postgresql-18.6-2-windows-x64-binaries.zip -->' (Get-CompatibilityFailureMarker -Major '18' -PackageTag '2.4.8-w1' -ServerArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
}

Test-Case 'In-flight rebuild detection accepts unified and legacy tag formats' {
    $rebuildScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Get-CompatibilityRebuildPlan.ps1') -Raw
    Assert-True ($rebuildScript.Contains('(?:-pg[0-9]+)?-w[0-9]+'))
    Assert-False ($rebuildScript.Contains('-windows\.[0-9]+'))
}

Complete-Tests
