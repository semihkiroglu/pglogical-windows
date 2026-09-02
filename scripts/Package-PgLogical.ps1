<#
.SYNOPSIS
    Packages a staged pglogical build into an installation-oriented ZIP whose
    name identifies the PostgreSQL compatibility major and Windows packaging
    revision, embeds BUILD-INFO.json, and computes the package SHA-256.

.DESCRIPTION
    Produces, for one validated plan entry:

      pglogical-<version>-pg<major>-w<revision>-x64.zip

    with the layout:

      BUILD-INFO.json
      lib/
        pglogical.dll
        pglogical_output.dll
      share/extension/
        pglogical.control
        pglogical--*.sql
        pglogical_origin.control
        pglogical_origin--1.0.0.sql
      bin/
        pglogical_create_subscriber.exe

    BUILD-INFO.json is generated ONLY from the validated/pinned plan entry
    plus the project-calculated EDB archive SHA-256; no version is
    rediscovered while packaging. The ZIP filename is verified against the
    BUILD-INFO content before the checksum is appended to SHA256SUMS.txt.

    The upstream pglogical COPYRIGHT/LICENSE file is included in the ZIP when
    present in the source checkout. The ZIP content is determined by the
    staging directory; archive bytes are not normalized (timestamps), so
    reproducibility is content-level, not byte-for-byte. No PostgreSQL/EDB
    binaries are bundled.

.PARAMETER StagingDir
    The staged package directory (lib/, share/, bin/).

.PARAMETER PlanEntry
    The validated plan entry (pglogicalVersion, upstreamTag, upstreamCommitSha,
    postgresqlMajor, postgresqlMinor, postgresqlBuildVersion,
    windowsPackagingRevision, edbPackagingRevision, edbArtifactFilename,
    edbArtifactUrl).

.PARAMETER EdbArtifactCalculatedSha256
    SHA-256 of the EDB binaries archive, calculated by this project after
    download (never a vendor-published checksum).

.PARAMETER SourceDir
    The upstream pglogical checkout (used to include the COPYRIGHT notice).

.PARAMETER OutputDir
    Directory for the ZIP and checksum file. Defaults to
    <repo>/.build/packages.

.PARAMETER ChecksumsFile
    Checksums file to append to. Defaults to <OutputDir>/SHA256SUMS.txt.

.OUTPUTS
    Writes the ZIP path.

.EXAMPLE
    pwsh ./scripts/Package-PgLogical.ps1 -StagingDir .build\stage -PlanEntry $entry -EdbArtifactCalculatedSha256 abc...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StagingDir,
    [Parameter(Mandatory = $true)]$PlanEntry,
    [Parameter(Mandatory = $true)][string]$EdbArtifactCalculatedSha256,
    [string]$SourceDir,
    [string]$OutputDir,
    [string]$ChecksumsFile,
    [switch]$SkipLicense
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Accept both a plan-entry object and a serialized JSON string (the
# workflow passes an object; a subprocess boundary may deliver JSON text).
if ($PlanEntry -is [string]) {
    try {
        $PlanEntry = $PlanEntry | ConvertFrom-Json
    }
    catch {
        throw "PlanEntry is not valid JSON: $($_.Exception.Message)"
    }
}
if ($null -eq $PlanEntry -or $null -eq $PlanEntry.pglogicalVersion) {
    throw 'PlanEntry must be a validated release-plan entry (pglogicalVersion missing).'
}

$StagingDir = [System.IO.Path]::GetFullPath($StagingDir)
if (-not (Test-Path (Join-Path $StagingDir 'lib\pglogical.dll'))) {
    throw "Staging directory is missing lib\pglogical.dll: $StagingDir"
}
if (-not (Test-Path (Join-Path $StagingDir 'share\extension\pglogical.control'))) {
    throw "Staging directory is missing share\extension\pglogical.control: $StagingDir"
}
if (-not $OutputDir) { $OutputDir = Join-Path (Get-RepoRoot) '.build\packages' }
if (-not $ChecksumsFile) { $ChecksumsFile = Join-Path $OutputDir 'SHA256SUMS.txt' }
$null = New-Item -ItemType Directory -Force -Path $OutputDir

# ---------------------------------------------------------------------------
# BUILD-INFO.json: generated strictly from the pinned plan entry + the
# project-calculated EDB archive SHA. Written before compression.
# ---------------------------------------------------------------------------
$buildInfo = New-BuildInfo -Entry $PlanEntry -EdbArtifactCalculatedSha256 $EdbArtifactCalculatedSha256
$buildInfoPath = Join-Path $StagingDir 'BUILD-INFO.json'
$tmpBuildInfo = "$buildInfoPath.tmp"
$buildInfo | Set-Content -Path $tmpBuildInfo -Encoding utf8
Move-Item -Force -Path $tmpBuildInfo -Destination $buildInfoPath
Write-Host "BUILD-INFO.json written to staging root"

# Include the upstream license notice when available.
if (-not $SkipLicense -and $SourceDir -and (Test-Path (Join-Path $SourceDir 'COPYRIGHT'))) {
    $licenseDest = Join-Path $StagingDir 'share\pglogical\COPYRIGHT'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $licenseDest)
    Copy-Item -Path (Join-Path $SourceDir 'COPYRIGHT') -Destination $licenseDest -Force
}

# Compatibility-major package name: pglogical-<v>-pg<major>-w<rev>-x64.zip
$zipName = Get-PackageZipName `
    -PglogicalVersion ([string]$PlanEntry.pglogicalVersion) `
    -PostgresqlMajor ([string]$PlanEntry.postgresqlMajor) `
    -PackagingRevision ([int]$PlanEntry.windowsPackagingRevision)
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

Write-Host "Packaging $zipName"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
$sw.Stop()
$sizeKb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

# ---------------------------------------------------------------------------
# Verify the archive: required layout, BUILD-INFO.json presence/identity,
# and ZIP filename consistency with BUILD-INFO content.
# ---------------------------------------------------------------------------
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($required in @('lib/pglogical.dll', 'lib/pglogical_output.dll', 'share/extension/pglogical.control', 'share/extension/pglogical_origin.control', 'share/extension/pglogical_origin--1.0.0.sql', 'BUILD-INFO.json')) {
        if ($names -notcontains $required) { throw "Packaged ZIP is missing required entry: $required" }
    }
    $sqlCount = @($names | Where-Object { $_ -like 'share/extension/pglogical--*.sql' }).Count
    if ($sqlCount -lt 1) { throw 'Packaged ZIP contains no pglogical--*.sql scripts' }

    $infoEntry = $zip.GetEntry('BUILD-INFO.json')
    $reader = [System.IO.StreamReader]::new($infoEntry.Open())
    try { $embeddedInfo = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $parsedInfo = $embeddedInfo | ConvertFrom-Json
    if ([string]$parsedInfo.pglogicalVersion -ne [string]$PlanEntry.pglogicalVersion) { throw "BUILD-INFO.json pglogicalVersion does not match the plan entry" }
    if ([string]$parsedInfo.postgresqlBuildVersion -ne [string]$PlanEntry.postgresqlBuildVersion) { throw "BUILD-INFO.json postgresqlBuildVersion does not match the plan entry" }
    if ([int]$parsedInfo.edbPackagingRevision -ne [int]$PlanEntry.edbPackagingRevision) { throw "BUILD-INFO.json edbPackagingRevision does not match the plan entry" }
    if ([string]$parsedInfo.edbArtifactFilename -ne [string]$PlanEntry.edbArtifactFilename) { throw "BUILD-INFO.json edbArtifactFilename does not match the plan entry" }
    if ([string]$parsedInfo.upstreamCommitSha -ne [string]$PlanEntry.upstreamCommitSha) { throw "BUILD-INFO.json upstreamCommitSha does not match the plan entry" }
    if ([int]$parsedInfo.windowsPackagingRevision -ne [int]$PlanEntry.windowsPackagingRevision) { throw "BUILD-INFO.json windowsPackagingRevision does not match the plan entry" }
    if ([string]$parsedInfo.edbArtifactCalculatedSha256 -ne $EdbArtifactCalculatedSha256) { throw "BUILD-INFO.json edbArtifactCalculatedSha256 does not match the provided value" }

    # The ZIP filename must match BUILD-INFO identity.
    $expectedName = Get-PackageZipName `
        -PglogicalVersion ([string]$parsedInfo.pglogicalVersion) `
        -PostgresqlMajor ([string]$parsedInfo.postgresqlCompatibilityMajor) `
        -PackagingRevision ([int]$parsedInfo.windowsPackagingRevision)
    if ($zipName -ne $expectedName) {
        throw "ZIP filename '$zipName' does not match BUILD-INFO.json identity '$expectedName'"
    }
    Write-Host "  entries: $($names.Count) (extension scripts: $sqlCount)"
    Write-Host "  BUILD-INFO.json verified inside the archive"
}
finally { $zip.Dispose() }

$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$line = "$hash  $zipName"
Add-Content -Path $ChecksumsFile -Value $line -Encoding ascii
Write-Host "  SHA256: $hash"
Write-Host "  size:   ${sizeKb} KB"
Write-Host "  zip:    $zipPath"
Write-Host "  sums:   $ChecksumsFile"
# The only stdout contract: the produced ZIP path (workflows and tests
# capture this value).
Write-Output $zipPath
