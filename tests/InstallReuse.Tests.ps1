<#
.SYNOPSIS
    Unit tests for exact-artifact installation reuse: Test-InstallMetadataIdentity
    (EDB-INSTALL-INFO.json identity checks) and Test-PgConfigVersion (exact
    major.minor from pg_config.h).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

function New-Info {
    param(
        [string]$Major = '18',
        [string]$Minor = '4',
        [int]$EdbRevision = 2,
        [string]$Filename = 'postgresql-18.4-2-windows-x64-binaries.zip',
        [string]$Url = 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip',
        [string]$Sha = 'abc123'
    )
    return [pscustomobject]@{
        postgresqlMajor      = $Major
        postgresqlMinor      = $Minor
        postgresqlBuildVersion = "$Major.$Minor"
        edbPackagingRevision = $EdbRevision
        edbArtifactFilename  = $Filename
        edbArtifactUrl       = $Url
        calculatedSha256     = $Sha
        installedAtUtc       = '2026-08-06T00:00:00Z'
    }
}

$Url = 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip'
$File = 'postgresql-18.4-2-windows-x64-binaries.zip'

Test-Case 'Reuse: exact same artifact identity -> reuse' {
    Assert-True (Test-InstallMetadataIdentity -Info (New-Info) -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url)
}

Test-Case 'Reuse: same major, older minor -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -Minor '3' -Filename 'postgresql-18.3-1-windows-x64-binaries.zip' -Url 'https://get.enterprisedb.com/postgresql/postgresql-18.3-1-windows-x64-binaries.zip') -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: same major/minor, older EDB revision -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -EdbRevision 1 -Filename 'postgresql-18.4-1-windows-x64-binaries.zip' -Url 'https://get.enterprisedb.com/postgresql/postgresql-18.4-1-windows-x64-binaries.zip') -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: metadata missing (null) -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info $null -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: filename mismatch -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -Filename 'postgresql-18.4-9-windows-x64-binaries.zip') -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: URL mismatch -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -Url 'https://get.enterprisedb.com/postgresql/other.zip') -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: revision mismatch -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -EdbRevision 1) -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

Test-Case 'Reuse: major mismatch -> reinstall' {
    Assert-True (-not (Test-InstallMetadataIdentity -Info (New-Info -Major '17' -Filename 'postgresql-17.10-1-windows-x64-binaries.zip' -Url 'https://get.enterprisedb.com/postgresql/postgresql-17.10-1-windows-x64-binaries.zip') -Major '18' -Minor '4' -EdbRevision 2 -ArtifactFilename $File -ArtifactUrl $Url))
}

# ---------------------------------------------------------------------------
# Test-PgConfigVersion
# ---------------------------------------------------------------------------
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pgl-install-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $tmpDir
$header = Join-Path $tmpDir 'pg_config.h'
try {
    Test-Case 'Test-PgConfigVersion matches exact major.minor' {
        @(
            '#define PG_VERSION "18.4"',
            '#define PG_VERSION_NUM 180004'
        ) | Set-Content -Path $header -Encoding ascii
        Assert-True (Test-PgConfigVersion -PgConfigHeader $header -ExpectedMajor '18' -ExpectedMinor '4')
        Assert-True (-not (Test-PgConfigVersion -PgConfigHeader $header -ExpectedMajor '18' -ExpectedMinor '5'))
        Assert-True (-not (Test-PgConfigVersion -PgConfigHeader $header -ExpectedMajor '17' -ExpectedMinor '4'))
    }

    Test-Case 'Test-PgConfigVersion fails on a missing or unparseable header' {
        Assert-True (-not (Test-PgConfigVersion -PgConfigHeader (Join-Path $tmpDir 'missing.h') -ExpectedMajor '18' -ExpectedMinor '4'))
        'not a header' | Set-Content -Path $header -Encoding ascii
        Assert-True (-not (Test-PgConfigVersion -PgConfigHeader $header -ExpectedMajor '18' -ExpectedMinor '4'))
    }
}
finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Complete-Tests
