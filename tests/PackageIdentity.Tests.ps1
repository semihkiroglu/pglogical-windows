<#
.SYNOPSIS
    Unit + integration tests for the compatibility-major package identity:
    Get-PackageZipName, New-BuildInfo, and a real Package-PgLogical.ps1 run
    against a synthetic staging directory (ZIP extraction + BUILD-INFO.json
    verification included).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

Test-Case 'Release identity helpers produce the requested title, tag, and package names' {
    Assert-Equal '2.4.8 for PostgreSQL 18 (W1)' (Get-ReleaseTitle -Version '2.4.8' -PgMajor '18' -PackagingRevision 1)
    Assert-Equal '2.4.8-pg18-w1' (Get-LocalReleaseTag -Version '2.4.8' -PgMajor '18' -PackagingRevision 1)
    $name = Get-PackageZipName -PglogicalVersion '2.4.8' -PostgresqlMajor '18' -PackagingRevision 1
    Assert-Equal 'pglogical-2.4.8-pg18-w1-x64.zip' $name
}

Test-Case 'New-BuildInfo emits deterministic, complete JSON' {
    $entry = [pscustomobject]@{
        pglogicalVersion         = '2.4.8'
        upstreamTag              = 'REL2_4_8'
        upstreamCommitSha        = '9a0e182745885ad0152ea387988c95a483396a81'
        postgresqlMajor          = '18'
        postgresqlMinor          = '4'
        postgresqlBuildVersion   = '18.4'
        windowsPackagingRevision = 1
        edbPackagingRevision     = 2
        edbArtifactFilename      = 'postgresql-18.4-2-windows-x64-binaries.zip'
        edbArtifactUrl           = 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip'
    }
    $json1 = New-BuildInfo -Entry $entry -EdbArtifactCalculatedSha256 ('a' * 64)
    $json2 = New-BuildInfo -Entry $entry -EdbArtifactCalculatedSha256 ('a' * 64)
    Assert-Equal $json1 $json2
    $parsed = $json1 | ConvertFrom-Json
    Assert-Equal '2.4.8' $parsed.pglogicalVersion
    Assert-Equal '18.4' $parsed.postgresqlBuildVersion
    Assert-Equal 2 $parsed.edbPackagingRevision
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $parsed.edbArtifactFilename
    Assert-Equal 1 $parsed.windowsPackagingRevision
    Assert-Equal ('a' * 64) $parsed.edbArtifactCalculatedSha256
}

# ---------------------------------------------------------------------------
# Integration: run the real Package-PgLogical.ps1 against a synthetic staging
# directory and verify the produced ZIP (layout, BUILD-INFO.json identity,
# checksum).
# ---------------------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pgl-pkg-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$staging = Join-Path $work 'stage'
try {
    # Synthetic staging layout (the real build produces these artifacts).
    foreach ($rel in @('lib', 'share\extension', 'bin')) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $staging $rel)
    }
    'fake-dll' | Set-Content -Path (Join-Path $staging 'lib\pglogical.dll') -Encoding ascii
    'fake-dll' | Set-Content -Path (Join-Path $staging 'lib\pglogical_output.dll') -Encoding ascii
    'fake-ctl' | Set-Content -Path (Join-Path $staging 'share\extension\pglogical.control') -Encoding ascii
    'fake-ctl' | Set-Content -Path (Join-Path $staging 'share\extension\pglogical_origin.control') -Encoding ascii
    'fake-sql' | Set-Content -Path (Join-Path $staging 'share\extension\pglogical_origin--1.0.0.sql') -Encoding ascii
    'fake-sql' | Set-Content -Path (Join-Path $staging 'share\extension\pglogical--2.4.8.sql') -Encoding ascii
    'fake-exe' | Set-Content -Path (Join-Path $staging 'bin\pglogical_create_subscriber.exe') -Encoding ascii

    $entry = [pscustomobject]@{
        pglogicalVersion         = '2.4.8'
        upstreamTag              = 'REL2_4_8'
        upstreamCommitSha        = '9a0e182745885ad0152ea387988c95a483396a81'
        postgresqlMajor          = '18'
        postgresqlMinor          = '4'
        postgresqlBuildVersion   = '18.4'
        windowsPackagingRevision = 1
        edbPackagingRevision     = 2
        edbArtifactFilename      = 'postgresql-18.4-2-windows-x64-binaries.zip'
        edbArtifactUrl           = 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip'
    }
    $fakeSha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

    Test-Case 'Package-PgLogical.ps1 produces a compatibility-major ZIP with valid BUILD-INFO.json' {
        $outDir = Join-Path $work 'out'
        $zip = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\Package-PgLogical.ps1') `
            -StagingDir $staging `
            -PlanEntry ($entry | ConvertTo-Json -Depth 6 -Compress) `
            -EdbArtifactCalculatedSha256 $fakeSha `
            -OutputDir $outDir `
            -SkipLicense
        if ($LASTEXITCODE -ne 0) { throw "Package-PgLogical.ps1 failed (exit $LASTEXITCODE)" }
        $zip = ($zip | Select-Object -Last 1)
        Assert-Equal 'pglogical-2.4.8-pg18-w1-x64.zip' (Split-Path -Leaf $zip)

        # Extract and verify.
        $extract = Join-Path $work 'extract'
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        Assert-True (Test-Path (Join-Path $extract 'BUILD-INFO.json'))
        Assert-True (Test-Path (Join-Path $extract 'lib\pglogical.dll'))
        Assert-True (Test-Path (Join-Path $extract 'share\extension\pglogical.control'))
        $info = Get-Content (Join-Path $extract 'BUILD-INFO.json') -Raw | ConvertFrom-Json
        Assert-Equal '2.4.8' $info.pglogicalVersion
        Assert-Equal '18.4' $info.postgresqlBuildVersion
        Assert-Equal 2 $info.edbPackagingRevision
        Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $info.edbArtifactFilename
        Assert-Equal '9a0e182745885ad0152ea387988c95a483396a81' $info.upstreamCommitSha
        Assert-Equal $fakeSha $info.edbArtifactCalculatedSha256

        # Checksum line must exist and match the ZIP.
        $sums = Get-Content (Join-Path $outDir 'SHA256SUMS.txt')
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True (($sums | Where-Object { $_ -like "*pglogical-2.4.8-pg18-w1-x64.zip" }) -match "^$actual")
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Complete-Tests
