<#
.SYNOPSIS
    Unit tests for unified release asset aggregation and release-body generation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')
$prepareScript = Join-Path $repoRoot 'scripts/Prepare-UnifiedReleaseAssets.ps1'

function New-TestPlanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$ArtifactFilename
    )
    return [ordered]@{
        pglogicalVersion = '2.4.8'
        upstreamTag = 'REL2_4_8'
        upstreamCommitSha = '9a0e182745885ad0152ea387988c95a483396a81'
        postgresqlMajor = $Major
        postgresqlMinor = ($ArtifactFilename -replace "^postgresql-$Major\.([0-9]+)-.*$", '$1')
        postgresqlBuildVersion = "$Major.$(($ArtifactFilename -replace "^postgresql-$Major\.([0-9]+)-.*$", '$1'))"
        windowsPackagingRevision = 1
        edbPackagingRevision = 2
        edbArtifactFilename = $ArtifactFilename
        edbArtifactUrl = "https://get.enterprisedb.com/postgresql/$ArtifactFilename"
        localTag = '2.4.8-w1'
    }
}

function Invoke-PrepareTest {
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )
    $output = & pwsh -NoProfile -File $prepareScript `
        -PlanJson (Get-Content -LiteralPath $PlanPath -Raw) `
        -ArtifactsRoot $ArtifactsRoot `
        -OutputDirectory $OutputDirectory `
        -TemplatePath (Join-Path $repoRoot '.github/release-body-template.md') `
        -Version '2.4.8' `
        -UpstreamRepository '2ndQuadrant/pglogical' `
        -UpstreamTag 'REL2_4_8' `
        -CommitSha '9a0e182745885ad0152ea387988c95a483396a81' `
        -RunUrl 'https://github.com/semihkiroglu/pglogical-windows/actions/runs/1' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Prepare-UnifiedReleaseAssets failed.' }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function New-TestPackage {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$ArtifactFilename
    )
    $directory = Join-Path $ArtifactsRoot "packages-pg$Major"
    $null = New-Item -ItemType Directory -Force -Path $directory
    $packageName = Get-PackageZipName -PglogicalVersion '2.4.8' -PostgresqlMajor $Major -PackagingRevision 1
    $packagePath = Join-Path $directory $packageName
    [System.IO.File]::WriteAllBytes($packagePath, [byte[]](65, 66, [int]$Major.Substring($Major.Length - 1)))
    $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$packageHash  $packageName" | Set-Content -LiteralPath (Join-Path $directory 'SHA256SUMS.txt') -Encoding ascii
    (('a' * 64) + "  $ArtifactFilename") | Set-Content -LiteralPath (Join-Path $directory 'edb-artifact.txt') -Encoding ascii
}

Test-Case 'Unified release preparation aggregates all major ZIPs and renders one body' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("pglogical-unified-assets-" + [guid]::NewGuid().ToString('N'))
    $artifacts = Join-Path $root 'artifacts'
    $output = Join-Path $root 'release-assets'
    $plan = Join-Path $root 'plan.json'
    try {
        $null = New-Item -ItemType Directory -Force -Path $artifacts
        $entries = @(
            (New-TestPlanEntry -Major '14' -ArtifactFilename 'postgresql-14.24-2-windows-x64-binaries.zip'),
            (New-TestPlanEntry -Major '18' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
        )
        $entries | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $plan -Encoding utf8
        New-TestPackage -ArtifactsRoot $artifacts -Major '14' -ArtifactFilename $entries[0].edbArtifactFilename
        New-TestPackage -ArtifactsRoot $artifacts -Major '18' -ArtifactFilename $entries[1].edbArtifactFilename

        $summary = Invoke-PrepareTest -PlanPath $plan -ArtifactsRoot $artifacts -OutputDirectory $output
        Assert-Equal '2.4.8-w1' $summary.releaseTag
        Assert-Equal '2.4.8 for Windows (W1)' $summary.releaseTitle
        Assert-Equal 2 $summary.packageCount
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'pglogical-2.4.8-pg14-w1-x64.zip'))
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'pglogical-2.4.8-pg18-w1-x64.zip'))
        $checksumText = Get-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Raw
        Assert-True ($checksumText -match 'pglogical-2\.4\.8-pg14-w1-x64\.zip')
        Assert-True ($checksumText -match 'pglogical-2\.4\.8-pg18-w1-x64\.zip')
        $body = Get-Content -LiteralPath (Join-Path $output 'release-body.md') -Raw
        $pg14Hash = (Get-FileHash -LiteralPath (Join-Path $output 'pglogical-2.4.8-pg14-w1-x64.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($body -match [regex]::Escape($pg14Hash))
        Assert-True ($body -match '### PostgreSQL 14')
        Assert-True ($body -match '### PostgreSQL 18')
        Assert-True ($body -match 'postgresql-14\.24-2-windows-x64-binaries\.zip')
        Assert-False ($body -match '\{\{[A-Z_]+\}\}')
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Test-Case 'Unified release preparation fails closed when a planned major artifact is missing' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("pglogical-unified-assets-missing-" + [guid]::NewGuid().ToString('N'))
    try {
        $artifacts = Join-Path $root 'artifacts'
        $output = Join-Path $root 'release-assets'
        $plan = Join-Path $root 'plan.json'
        $null = New-Item -ItemType Directory -Force -Path $artifacts
        $entries = @(
            (New-TestPlanEntry -Major '14' -ArtifactFilename 'postgresql-14.24-2-windows-x64-binaries.zip'),
            (New-TestPlanEntry -Major '18' -ArtifactFilename 'postgresql-18.6-2-windows-x64-binaries.zip')
        )
        $entries | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $plan -Encoding utf8
        New-TestPackage -ArtifactsRoot $artifacts -Major '14' -ArtifactFilename $entries[0].edbArtifactFilename
        Assert-Throws { Invoke-PrepareTest -PlanPath $plan -ArtifactsRoot $artifacts -OutputDirectory $output | Out-Null } -MessagePattern 'Prepare-UnifiedReleaseAssets failed'
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Complete-Tests
