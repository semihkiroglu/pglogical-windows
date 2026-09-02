<#
.SYNOPSIS
    Prepares and validates the assets for one unified GitHub release.

.DESCRIPTION
    The build matrix uploads one artifact directory per PostgreSQL major. This
    script validates every planned directory, copies each major-specific ZIP to
    one release-assets directory, writes one aggregate SHA256SUMS.txt, and
    renders the multi-major release body. It emits one compact JSON summary on
    stdout and fails closed on any missing, ambiguous, or mismatched identity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanJson,
    [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$UpstreamRepository,
    [Parameter(Mandatory = $true)][string]$UpstreamTag,
    [Parameter(Mandatory = $true)][string]$CommitSha,
    [string]$RunUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$entries = @(Test-ReleasePlan -PlanJson $PlanJson | Sort-Object { [int]$_.postgresqlMajor })
if ($entries.Count -eq 0) { throw 'Cannot prepare unified release assets from an empty release plan.' }
if ([string]$entries[0].pglogicalVersion -ne $Version) {
    throw "Release plan version '$($entries[0].pglogicalVersion)' does not match requested version '$Version'."
}
if ([string]$entries[0].upstreamTag -ne $UpstreamTag -or [string]$entries[0].upstreamCommitSha -ne $CommitSha) {
    throw 'Release plan upstream identity does not match the requested release inputs.'
}
if (-not (Test-Path -LiteralPath $ArtifactsRoot -PathType Container)) {
    throw "Build artifact root does not exist: $ArtifactsRoot"
}
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    throw "Release body template does not exist: $TemplatePath"
}

$revision = [int]$entries[0].windowsPackagingRevision
$releaseTag = Get-LocalReleaseTag -Version $Version -PackagingRevision $revision
$releaseTitle = Get-ReleaseTitle -Version $Version -PackagingRevision $revision
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $resolvedOutput) { Remove-Item -LiteralPath $resolvedOutput -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $resolvedOutput

$checksumLines = [System.Collections.Generic.List[string]]::new()
$provenanceSections = [System.Collections.Generic.List[string]]::new()
$packageLines = [System.Collections.Generic.List[string]]::new()

foreach ($entry in $entries) {
    $major = [string]$entry.postgresqlMajor
    $artifactDirectory = Join-Path ([System.IO.Path]::GetFullPath($ArtifactsRoot)) "packages-pg$major"
    if (-not (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
        throw "Unified release is missing package artifact directory for PostgreSQL ${major}: $artifactDirectory"
    }

    $packageFiles = @(Get-ChildItem -LiteralPath $artifactDirectory -Filter '*.zip' -File)
    if ($packageFiles.Count -ne 1) {
        throw "Unified release requires exactly one package ZIP for PostgreSQL $major; found $($packageFiles.Count)."
    }
    $packageFile = $packageFiles[0]
    $expectedPackageName = Get-PackageZipName -PglogicalVersion $Version -PostgresqlMajor $major -PackagingRevision $revision
    if ($packageFile.Name -ne $expectedPackageName) {
        throw "Package ZIP '$($packageFile.Name)' does not match the expected PostgreSQL $major asset '$expectedPackageName'."
    }

    $checksumFiles = @(Get-ChildItem -LiteralPath $artifactDirectory -Filter 'SHA256SUMS.txt' -File)
    if ($checksumFiles.Count -ne 1) {
        throw "Unified release requires exactly one SHA256SUMS.txt for PostgreSQL $major; found $($checksumFiles.Count)."
    }
    $actualPackageHash = (Get-FileHash -LiteralPath $packageFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $listedPackageHash = Get-ChecksumForAsset -ChecksumsText (Get-Content -LiteralPath $checksumFiles[0].FullName -Raw) -AssetName $packageFile.Name -ActualSha256 $actualPackageHash

    $edbFiles = @(Get-ChildItem -LiteralPath $artifactDirectory -Filter 'edb-artifact.txt' -File)
    if ($edbFiles.Count -ne 1) {
        throw "Unified release requires exactly one edb-artifact.txt for PostgreSQL $major; found $($edbFiles.Count)."
    }
    $edbRecord = (Get-Content -LiteralPath $edbFiles[0].FullName -Raw).Trim()
    $edbMatch = [regex]::Match($edbRecord, '^([0-9a-fA-F]{64})\s+(.+?)\s*$')
    if (-not $edbMatch.Success) { throw "edb-artifact.txt for PostgreSQL $major is malformed." }
    $edbHash = $edbMatch.Groups[1].Value.ToLowerInvariant()
    $edbFilename = $edbMatch.Groups[2].Value.Trim()
    if ($edbFilename -ne [string]$entry.edbArtifactFilename) {
        throw "EDB artifact record '$edbFilename' does not match the pinned plan artifact '$($entry.edbArtifactFilename)' for PostgreSQL $major."
    }

    $destination = Join-Path $resolvedOutput $packageFile.Name
    Copy-Item -LiteralPath $packageFile.FullName -Destination $destination -Force
    $checksumLines.Add("$listedPackageHash  $($packageFile.Name)")

    $sectionLines = @(
        "### PostgreSQL $major",
        '',
        '| Field | Value |',
        '| --- | --- |',
        "| Exact PostgreSQL build | $($entry.postgresqlBuildVersion) |",
        "| EDB packaging revision | $($entry.edbPackagingRevision) |",
        "| EDB binaries archive | ``$edbFilename`` |",
        "| EDB binaries URL | <$($entry.edbArtifactUrl)> |",
        "| EDB binaries SHA-256 | ``$edbHash`` |",
        "| Package asset | ``$($packageFile.Name)`` |"
    )
    $provenanceSections.Add(($sectionLines -join "`n"))
    $packageLines.Add("- PostgreSQL $major ($($entry.postgresqlBuildVersion)): ``$($packageFile.Name)``")
}

$checksumPath = Join-Path $resolvedOutput 'SHA256SUMS.txt'
$checksumsText = (@($checksumLines | Sort-Object) -join "`n")
$checksumsText | Set-Content -LiteralPath $checksumPath -Encoding ascii

$template = Get-Content -LiteralPath $TemplatePath -Raw
$replacements = [ordered]@{
    '{{VERSION}}' = $Version
    '{{UPSTREAM_REPO}}' = $UpstreamRepository
    '{{UPSTREAM_TAG}}' = $UpstreamTag
    '{{COMMIT_SHA}}' = $CommitSha
    '{{PACKAGING_REVISION}}' = [string]$revision
    '{{RUN_URL}}' = $RunUrl
    '{{PACKAGE_PROVENANCE}}' = ($provenanceSections -join "`n`n")
    '{{PACKAGES}}' = ($packageLines -join "`n")
    '{{CHECKSUMS}}' = $checksumsText
}
foreach ($placeholder in $replacements.Keys) {
    if (-not $template.Contains($placeholder)) { throw "Release body template is missing required placeholder '$placeholder'." }
    $template = $template.Replace($placeholder, [string]$replacements[$placeholder])
}
if ($template -match '\{\{[A-Z_]+\}\}') { throw 'Release body template contains unreplaced placeholders.' }
$bodyPath = Join-Path $resolvedOutput 'release-body.md'
$template | Set-Content -LiteralPath $bodyPath -Encoding utf8

[pscustomobject]@{
    releaseTag = $releaseTag
    releaseTitle = $releaseTitle
    packageCount = $entries.Count
    checksumPath = $checksumPath
    bodyPath = $bodyPath
} | ConvertTo-Json -Compress
