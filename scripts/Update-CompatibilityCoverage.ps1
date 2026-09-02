<#
.SYNOPSIS
    Persists successful compatibility-smoke results in the repository state file.

.DESCRIPTION
    Only a passed smoke result for an exact published package and exact EDB
    artifact becomes coverage. Existing entries are validated before use and
    duplicate coverage is ignored, so rerunning the same result is idempotent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CoverageFile,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [AllowEmptyCollection()][string[]]$AdditionalCoverageFiles = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-CoverageEntryKey {
    param([Parameter(Mandatory = $true)]$Entry)
    return "$($Entry.postgresqlMajor)|$($Entry.localReleaseTag)|$($Entry.localPackageAssetName)|$($Entry.localPackageBuildArtifactFilename)|$($Entry.serverEdbArtifactFilename)|$($Entry.serverEdbArtifactUrl)"
}

function ConvertTo-CoverageEntry {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$ResultPath
    )
    foreach ($property in @('postgresqlMajor', 'localReleaseTag', 'localPackageAssetName', 'localPackageBuildArtifactFilename', 'serverEdbArtifactFilename', 'serverEdbArtifactUrl')) {
        if ($null -eq $Result.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$Result.$property)) {
            throw "Passed compatibility result '$ResultPath' is missing '$property'; refusing to persist coverage."
        }
    }
    $major = [string]$Result.postgresqlMajor
    if ($major -notmatch '^\d+$') { throw "Passed compatibility result '$ResultPath' has invalid PostgreSQL major '$major'; refusing to persist coverage." }
    $tagIdentity = ConvertFrom-LocalReleaseTag -Tag ([string]$Result.localReleaseTag)
    if (-not $tagIdentity -or $tagIdentity.postgresqlMajor -ne $major) {
        throw "Passed compatibility result '$ResultPath' has an invalid release identity for PostgreSQL $major; refusing to persist coverage."
    }
    $expectedAsset = Get-PackageZipName -PglogicalVersion $tagIdentity.pglogicalVersion -PostgresqlMajor $major -PackagingRevision ([int]$tagIdentity.windowsPackagingRevision)
    if ([string]$Result.localPackageAssetName -ne $expectedAsset) {
        throw "Passed compatibility result '$ResultPath' package asset '$($Result.localPackageAssetName)' does not match release tag '$($tagIdentity.tag_name)'; refusing to persist coverage."
    }
    $packageArtifact = ConvertFrom-EdbArtifactFilename -Filename ([string]$Result.localPackageBuildArtifactFilename)
    if (-not $packageArtifact -or $packageArtifact.major -ne $major) {
        throw "Passed compatibility result '$ResultPath' has an invalid package artifact for PostgreSQL $major; refusing to persist coverage."
    }
    $serverArtifact = ConvertFrom-EdbArtifactFilename -Filename ([string]$Result.serverEdbArtifactFilename)
    if (-not $serverArtifact -or $serverArtifact.major -ne $major) {
        throw "Passed compatibility result '$ResultPath' has an invalid server artifact for PostgreSQL $major; refusing to persist coverage."
    }
    if ($null -ne $Result.PSObject.Properties['serverMinor'] -and [string]$Result.serverMinor -and [string]$Result.serverMinor -ne [string]$serverArtifact.minor) {
        throw "Passed compatibility result '$ResultPath' serverMinor does not match server artifact; refusing to persist coverage."
    }
    if ($null -ne $Result.PSObject.Properties['serverBuildVersion'] -and [string]$Result.serverBuildVersion -and [string]$Result.serverBuildVersion -ne "$major.$($serverArtifact.minor)") {
        throw "Passed compatibility result '$ResultPath' serverBuildVersion does not match server artifact; refusing to persist coverage."
    }
    Assert-EdbCandidateUrl -Url ([string]$Result.serverEdbArtifactUrl) -Major $major -Minor $serverArtifact.minor -Revision ([int]$serverArtifact.revision) | Out-Null

    return [ordered]@{
        postgresqlMajor = $major
        localReleaseTag = [string]$tagIdentity.tag_name
        localPackageAssetName = [string]$Result.localPackageAssetName
        localPackageBuildArtifactFilename = [string]$Result.localPackageBuildArtifactFilename
        serverEdbArtifactFilename = [string]$Result.serverEdbArtifactFilename
        serverEdbArtifactUrl = [string]$Result.serverEdbArtifactUrl
        status = 'passed'
    }
}

try {
    $existingEntries = @(Read-CompatibilityCoverage -Path $CoverageFile)
    $entriesByKey = @{}
    foreach ($entry in $existingEntries) {
        $entriesByKey[(Get-CoverageEntryKey -Entry $entry)] = $entry
    }
    $stateChanged = $false
    foreach ($additionalFile in @($AdditionalCoverageFiles)) {
        if (-not (Test-Path -LiteralPath $additionalFile -PathType Leaf)) { throw "Additional compatibility coverage file not found: $additionalFile" }
        foreach ($entry in @(Read-CompatibilityCoverage -Path $additionalFile)) {
            $key = Get-CoverageEntryKey -Entry $entry
            if (-not $entriesByKey.ContainsKey($key)) {
                $entriesByKey[$key] = $entry
                $stateChanged = $true
            }
        }
    }

    $addedEntries = [System.Collections.Generic.List[object]]::new()
    $resultFiles = @()
    if (Test-Path -LiteralPath $ResultsDirectory -PathType Container) {
        $resultFiles = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.json' -File -Recurse | Sort-Object FullName)
    }
    foreach ($resultFile in $resultFiles) {
        $result = Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
        if ($null -eq $result.PSObject.Properties['resultType'] -or [string]$result.resultType -ne 'smoke-result') { continue }
        if ([string]$result.status -ne 'passed') { continue }
        $entry = ConvertTo-CoverageEntry -Result $result -ResultPath $resultFile.FullName
        $key = Get-CoverageEntryKey -Entry $entry
        if ($entriesByKey.ContainsKey($key)) { continue }
        $entriesByKey[$key] = $entry
        $addedEntries.Add($entry)
        $stateChanged = $true
    }

    $changed = $stateChanged
    if ($changed) {
        $allEntries = @($entriesByKey.Values | Sort-Object { [int]$_.postgresqlMajor }, localReleaseTag, serverEdbArtifactFilename)
        $state = [ordered]@{
            schemaVersion = 1
            entries = $allEntries
        }
        $coverageFullPath = [System.IO.Path]::GetFullPath($CoverageFile)
        $coverageParent = Split-Path -Parent $coverageFullPath
        if ($coverageParent) { $null = New-Item -ItemType Directory -Force -Path $coverageParent }
        $temporaryCoverage = "$coverageFullPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryCoverage -Encoding utf8
            [System.IO.File]::Move($temporaryCoverage, $coverageFullPath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $temporaryCoverage) { Remove-Item -LiteralPath $temporaryCoverage -Force }
        }
    }

    $outputParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputFile))
    if ($outputParent) { $null = New-Item -ItemType Directory -Force -Path $outputParent }
    $summary = [ordered]@{
        schemaVersion = 1
        changed = $changed
        addedEntries = @($addedEntries)
        totalEntries = $entriesByKey.Count
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputFile -Encoding utf8
    Write-Output ($summary | ConvertTo-Json -Depth 12 -Compress)
}
catch {
    Write-Error $_
    exit 1
}
