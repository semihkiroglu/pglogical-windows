<#
.SYNOPSIS
    Packages a staged pglogical build into an installation-oriented ZIP and
    computes its SHA-256 checksum.

.DESCRIPTION
    Produces, for one PostgreSQL major:

      pglogical-<version>-pg<major>-windows-x64.zip

    with the layout:

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

    and appends a "sha256  filename" line to SHA256SUMS.txt in the output
    directory. The upstream pglogical COPYRIGHT/LICENSE file is included in
    the ZIP when present in the source checkout.

    The ZIP content is determined by the staging directory; archive bytes are
    not normalized (timestamps), so reproducibility is content-level, not
    byte-for-byte. No PostgreSQL/EDB binaries are bundled.

.PARAMETER StagingDir
    The staged package directory (lib/, share/, bin/).

.PARAMETER SourceDir
    The upstream pglogical checkout (used to include the COPYRIGHT notice).

.PARAMETER Version
    The pglogical version, e.g. 2.4.8.

.PARAMETER PgMajor
    The PostgreSQL major, e.g. 18.

.PARAMETER OutputDir
    Directory for the ZIP and checksum file. Defaults to
    <repo>/.build/packages.

.PARAMETER ChecksumsFile
    Checksums file to append to. Defaults to <OutputDir>/SHA256SUMS.txt.

.OUTPUTS
    Writes the ZIP path.

.EXAMPLE
    pwsh ./scripts/Package-PgLogical.ps1 -StagingDir .build\stage -Version 2.4.8 -PgMajor 18
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StagingDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][int]$PgMajor,
    [string]$SourceDir,
    [string]$OutputDir,
    [string]$ChecksumsFile,
    [switch]$SkipLicense
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

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

# Include the upstream license notice when available.
if (-not $SkipLicense -and $SourceDir -and (Test-Path (Join-Path $SourceDir 'COPYRIGHT'))) {
    $licenseDest = Join-Path $StagingDir 'share\pglogical\COPYRIGHT'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $licenseDest)
    Copy-Item -Path (Join-Path $SourceDir 'COPYRIGHT') -Destination $licenseDest -Force
}

$zipName = "pglogical-$Version-pg$PgMajor-windows-x64.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

Write-Host "Packaging $zipName"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
$sw.Stop()
$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

# Verify the archive contains the expected layout.
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($required in @('lib/pglogical.dll', 'lib/pglogical_output.dll', 'share/extension/pglogical.control', 'share/extension/pglogical_origin.control', 'share/extension/pglogical_origin--1.0.0.sql')) {
        if ($names -notcontains $required) { throw "Packaged ZIP is missing required entry: $required" }
    }
    $sqlCount = @($names | Where-Object { $_ -like 'share/extension/pglogical--*.sql' }).Count
    if ($sqlCount -lt 1) { throw 'Packaged ZIP contains no pglogical--*.sql scripts' }
    Write-Host "  entries: $($names.Count) (extension scripts: $sqlCount)"
}
finally { $zip.Dispose() }

$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$line = "$hash  $zipName"
Add-Content -Path $ChecksumsFile -Value $line -Encoding ascii
Write-Host "  SHA256: $hash"
Write-Host "  size:   ${sizeMb} KB"
Write-Host "  zip:    $zipPath"
Write-Host "  sums:   $ChecksumsFile"
Write-Output $zipPath
