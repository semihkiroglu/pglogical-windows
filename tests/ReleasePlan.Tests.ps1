<#
.SYNOPSIS
    Unit tests for Get-ReleasePlan: EDB artifact identity tracking, the
    packaging-revision policy, and the fail-closed conditions.
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
        major    = $Major
        minor    = $Minor
        revision = $Revision
        filename = $filename
        url      = "https://get.enterprisedb.com/postgresql/$filename"
    }
}

function New-ReleaseBody {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactFilename,
        [switch]$Legacy
    )
    if ($Legacy) {
        # Pre-recreation bodies embed "<sha256>  <filename>" in the SHA row.
        return "| Field | Value |`n| --- | --- |`n| EDB binaries SHA-256 | ``1234567890abcdef  $ArtifactFilename`` |"
    }
    return "| Field | Value |`n| --- | --- |`n| EDB binaries archive | ``$ArtifactFilename`` |"
}

function New-Release {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Body
    )
    return [pscustomobject]@{ tag_name = $Tag; body = $Body }
}

$base = @{
    Version     = '2.4.8'
    UpstreamTag = 'REL2_4_8'
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

Test-Case 'A brand-new upstream version plans windows.1 for every major' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '23' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @()
    Assert-Equal 2 @($plan).Count
    $pg14 = @($plan | Where-Object { $_.pgMajor -eq '14' })[0]
    $pg18 = @($plan | Where-Object { $_.pgMajor -eq '18' })[0]
    Assert-Equal 1 $pg14.packagingRevision
    Assert-Equal 'pglogical-2.4.8-pg14-windows.1' $pg14.localTag
    Assert-Equal 1 $pg18.packagingRevision
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $pg18.edbArtifactFilename
}

Test-Case 'An unchanged EDB artifact produces no new release action' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '23' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg14-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-14.23-1-windows-x64-binaries.zip')
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip')
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'A -1 to -2 artifact change marks only the affected major' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '23' -Revision 1
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg14-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-14.23-1-windows-x64-binaries.zip')
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip')
    )
    $plan = Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 1 @($plan).Count
    Assert-Equal '18' $plan[0].pgMajor
    Assert-Equal 2 $plan[0].packagingRevision
    Assert-Equal 'pglogical-2.4.8-pg18-windows.2' $plan[0].localTag
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $plan[0].edbArtifactFilename
}

Test-Case 'An unresolved EDB artifact fails closed' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '23' -Revision 1
        # '18' intentionally missing: resolution failed upstream.
    }
    Assert-Throws {
        Invoke-Plan -Majors @('14', '18') -Artifacts $artifacts -LocalReleases @() | Out-Null
    } -MessagePattern 'no exact EDB artifact identity was resolved'
}

Test-Case 'An incomplete resolved artifact identity fails closed' {
    $artifacts = [ordered]@{
        '14' = [pscustomobject]@{ major = '14'; minor = '23'; revision = 1; filename = ''; url = 'https://example.invalid/x.zip' }
    }
    Assert-Throws {
        Invoke-Plan -Majors @('14') -Artifacts $artifacts -LocalReleases @() | Out-Null
    } -MessagePattern 'incomplete'
}

Test-Case 'A resolved artifact older than the recorded one fails closed' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 1
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip')
    )
    Assert-Throws {
        Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases | Out-Null
    } -MessagePattern 'older than the artifact recorded'
}

Test-Case 'An older resolved minor fails closed (no silent minor downgrade)' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '3' -Revision 4
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip')
    )
    Assert-Throws {
        Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases | Out-Null
    } -MessagePattern 'older than the artifact recorded'
}

Test-Case 'A release without a recorded EDB artifact fails closed' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body '| Field | Value |' 
    )
    Assert-Throws {
        Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases | Out-Null
    } -MessagePattern 'records no EDB binaries archive filename'
}

Test-Case 'Multiple changed majors are handled without rebuilding unchanged majors' {
    $artifacts = [ordered]@{
        '14' = New-Artifact -Major '14' -Minor '23' -Revision 1
        '15' = New-Artifact -Major '15' -Minor '18' -Revision 2
        '16' = New-Artifact -Major '16' -Minor '14' -Revision 1
        '17' = New-Artifact -Major '17' -Minor '10' -Revision 2
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 1
    }
    $releases = @()
    foreach ($majorMinor in @(@('14', '23', '1'), @('15', '18', '1'), @('16', '14', '1'), @('17', '10', '1'), @('18', '4', '1'))) {
        $releases += New-Release `
            -Tag "pglogical-2.4.8-pg$($majorMinor[0])-windows.1" `
            -Body (New-ReleaseBody -ArtifactFilename "postgresql-$($majorMinor[0]).$($majorMinor[1])-$($majorMinor[2])-windows-x64-binaries.zip")
    }
    $plan = Invoke-Plan -Majors @('14', '15', '16', '17', '18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 2 @($plan).Count
    $plannedMajors = @($plan | ForEach-Object { $_.pgMajor } | Sort-Object)
    Assert-Equal '15,17' ($plannedMajors -join ',')
    foreach ($entry in $plan) {
        Assert-Equal 2 $entry.packagingRevision
        Assert-Equal "pglogical-2.4.8-pg$($entry.pgMajor)-windows.2" $entry.localTag
    }
}

Test-Case 'The next packaging revision is the highest existing revision plus one' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 3
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip')
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.2' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip')
    )
    $plan = Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 1 @($plan).Count
    Assert-Equal 3 $plan[0].packagingRevision
    Assert-Equal 'pglogical-2.4.8-pg18-windows.3' $plan[0].localTag
}

Test-Case 'A newer minor of the same major triggers a rebuild (revision resets to 1 within the new minor)' {
    # pg.org bumps 18.4 -> 18.5: the resolved artifact is 18.5-1, which is a
    # legitimate upgrade even though its packaging revision (1) is lower than
    # the recorded 18.4-2. Only the (minor, revision) tuple decides.
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '5' -Revision 1
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.2' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip')
    )
    $plan = Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 1 @($plan).Count
    Assert-Equal 3 $plan[0].packagingRevision
    Assert-Equal 'postgresql-18.5-1-windows-x64-binaries.zip' $plan[0].edbArtifactFilename
}

Test-Case 'A legacy release body (pre-recreation format) is still understood' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-2-windows-x64-binaries.zip' -Legacy)
    )
    $plan = Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 0 @($plan).Count
}

Test-Case 'Draft and unrelated releases are ignored' {
    $artifacts = [ordered]@{
        '18' = New-Artifact -Major '18' -Minor '4' -Revision 2
    }
    # The planner itself does not filter drafts (the caller does); it filters
    # by version: unrelated tags must not influence the plan.
    $releases = @(
        New-Release -Tag 'pglogical-2.4.8-pg17-windows.9' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-17.10-9-windows-x64-binaries.zip')
        New-Release -Tag 'pglogical-2.4.7-pg18-windows.1' -Body (New-ReleaseBody -ArtifactFilename 'postgresql-18.4-1-windows-x64-binaries.zip')
    )
    $plan = Invoke-Plan -Majors @('18') -Artifacts $artifacts -LocalReleases $releases
    Assert-Equal 1 @($plan).Count
    Assert-Equal 'pglogical-2.4.8-pg18-windows.1' $plan[0].localTag
}

Complete-Tests
