<#
.SYNOPSIS
    Synchronizes the configured PostgreSQL major matrix from pg.org data.

.DESCRIPTION
    Reads PostgreSQL.org versions.json, derives each EDB Windows binary URL,
    and verifies availability with an HTTP HEAD request. Explicitly EOL majors
    are removed. Existing supported majors survive a transient EDB probe
    failure so an unavailable new minor cannot shrink the last known matrix.

    A caller may pass -EligibleNewMajors only after it has applied the
    repository-specific compatibility policy. This script will then add only
    those new majors that are both supported by pg.org and EDB-probe verified.

.PARAMETER ConfigPath
    Version configuration JSON to update. Defaults to .github/pg-versions.json
    in the repository root.

.PARAMETER EligibleNewMajors
    New PostgreSQL majors that have passed the caller's compatibility policy.
    Detection alone never adds a new major to the persisted matrix.

.OUTPUTS
    A PSCustomObject describing the resulting matrix and whether ConfigPath was
    actually modified.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$EligibleNewMajors = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-NormalizedMajorList {
    param(
        [object[]]$Majors,
        [string]$Description
    )

    $normalized = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Majors)) {
        $major = [string]$value
        if ([string]::IsNullOrWhiteSpace($major) -or $major -notmatch '^\d+$') {
            throw "$Description contains a non-numeric PostgreSQL major: '$major'"
        }
        if (-not $normalized.Contains($major)) {
            $null = $normalized.Add($major)
        }
    }

    return @($normalized | Sort-Object { [int]$_ })
}

function Test-VersionSyncEdbBinaryUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    return Test-EdbBinaryUrl -Url $Url
}

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Get-RepoRoot) '.github/pg-versions.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Version config not found: $ConfigPath"
}

$config = Read-JsonFile -Path $ConfigPath -WhatFor 'version'
if (-not $config.releaseBaseline) {
    throw ('{0}: missing "releaseBaseline"' -f $ConfigPath)
}
if ($null -eq $config.postgresqlMajors -or @($config.postgresqlMajors).Count -eq 0) {
    throw ('{0}: missing or empty "postgresqlMajors" array' -f $ConfigPath)
}

$rawConfiguredMajors = @($config.postgresqlMajors | ForEach-Object { [string]$_ })
$oldMajors = @(Get-NormalizedMajorList -Majors $config.postgresqlMajors -Description "$ConfigPath postgresqlMajors")
$eligibleMajors = @(Get-NormalizedMajorList -Majors $EligibleNewMajors -Description 'EligibleNewMajors')

$configuredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($major in $oldMajors) {
    $null = $configuredSet.Add($major)
}
$eligibleSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($major in $eligibleMajors) {
    $null = $eligibleSet.Add($major)
}

$versions = @(Get-PgOrgVersions)
if ($versions.Count -eq 0) {
    throw 'PostgreSQL.org versions data is empty'
}

$versionsByMajor = @{}
foreach ($entry in $versions) {
    if ($null -eq $entry) {
        throw 'PostgreSQL.org versions data contains a null entry'
    }
    foreach ($requiredProperty in @('major', 'latestMinor', 'supported', 'eolDate')) {
        if ($null -eq $entry.PSObject.Properties[$requiredProperty]) {
            throw "PostgreSQL.org versions data entry is missing '$requiredProperty'"
        }
    }

    $major = [string]$entry.major
    # versions.json retains historical pre-10 rows (for example 6.3). The
    # supported package matrix uses the integer major convention introduced by
    # PostgreSQL 10, so historical dotted rows must not block current sync.
    if ($major -match '^\d+\.\d+$') {
        Write-Host "Ignoring legacy PostgreSQL version row: $major"
        continue
    }
    if ($major -notmatch '^\d+$') {
        throw "PostgreSQL.org versions data has an invalid major: '$major'"
    }

    $minor = [string]$entry.latestMinor
    if ([string]::IsNullOrWhiteSpace($minor) -or $minor -notmatch '^\d+$') {
        throw "PostgreSQL.org versions data has an invalid latestMinor for PG ${major}: '$minor'"
    }
    if ($versionsByMajor.ContainsKey($major)) {
        throw "PostgreSQL.org versions data contains duplicate PG major $major"
    }
    if (-not [bool]$entry.supported -and [string]::IsNullOrWhiteSpace([string]$entry.eolDate)) {
        throw "PostgreSQL.org versions data marks PG $major unsupported without an eolDate"
    }

    $versionsByMajor[$major] = $entry
}

$nextMatrix = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$availableMajors = [System.Collections.Generic.List[string]]::new()
$removedEolMajors = [System.Collections.Generic.List[string]]::new()
$retainedOnProbeFailureMajors = [System.Collections.Generic.List[string]]::new()
$retainedUnknownMajors = [System.Collections.Generic.List[string]]::new()
$candidateNewMajors = [System.Collections.Generic.List[string]]::new()
$addedMajors = [System.Collections.Generic.List[string]]::new()
$eolMajors = [System.Collections.Generic.List[object]]::new()

foreach ($major in @($versionsByMajor.Keys | Sort-Object { [int]$_ })) {
    $entry = $versionsByMajor[$major]
    if (-not [bool]$entry.supported) {
        if ($configuredSet.Contains($major)) {
            $null = $removedEolMajors.Add($major)
            $null = $eolMajors.Add([pscustomobject]@{
                major = $major
                eolDate = [string]$entry.eolDate
            })
        }
        continue
    }

    $minor = [string]$entry.latestMinor
    $url = Get-EdbBinaryUrl -Major $major -Minor $minor
    $isAvailable = Test-VersionSyncEdbBinaryUrl -Url $url
    if ($isAvailable) {
        $null = $availableMajors.Add($major)
    }

    if ($configuredSet.Contains($major)) {
        $null = $nextMatrix.Add($major)
        if (-not $isAvailable) {
            $null = $retainedOnProbeFailureMajors.Add($major)
            Write-Host "Keeping configured PG $major after unavailable EDB URL: $url"
        }
        continue
    }

    if (-not $isAvailable) {
        Write-Host "Skipping new PG $major because EDB URL is unavailable: $url"
        continue
    }

    $null = $candidateNewMajors.Add($major)
    if ($eligibleSet.Contains($major)) {
        $null = $nextMatrix.Add($major)
        $null = $addedMajors.Add($major)
        Write-Host "Adding eligible PG $major with verified EDB URL: $url"
    }
    else {
        Write-Host "Detected EDB-ready PG $major; waiting for compatibility eligibility before adding it"
    }
}

# A missing pg.org entry is not proof of EOL. Retain it until the authoritative
# data explicitly marks the configured major supported=false.
foreach ($major in $oldMajors) {
    if (-not $versionsByMajor.ContainsKey($major)) {
        $null = $nextMatrix.Add($major)
        $null = $retainedUnknownMajors.Add($major)
        Write-Host "Keeping configured PG $major because it is absent from versions.json"
    }
}

$newMajors = @($nextMatrix | Sort-Object { [int]$_ })
if ($newMajors.Count -eq 0) {
    throw 'Refusing to write an empty PostgreSQL major matrix; retain the last valid config for manual review'
}

$changed = (($rawConfiguredMajors -join ',') -ne ($newMajors -join ','))

if ($changed) {
    $config.postgresqlMajors = @($newMajors)
    $json = $config | ConvertTo-Json -Depth 8
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ConfigPath, "$($json.TrimEnd())$([Environment]::NewLine)", $utf8WithoutBom)
    Write-Host "Updated PostgreSQL matrix: $($oldMajors -join ', ') -> $($newMajors -join ', ')"
}
else {
    Write-Host "PostgreSQL matrix unchanged: $($newMajors -join ', ')"
}

return [pscustomobject]@{
    changed = [bool]$changed
    oldMajors = @($oldMajors)
    newMajors = @($newMajors)
    availableMajors = @($availableMajors | Sort-Object { [int]$_ })
    removedEolMajors = @($removedEolMajors | Sort-Object { [int]$_ })
    eolMajors = @($eolMajors | Sort-Object { [int]$_.major })
    retainedOnProbeFailureMajors = @($retainedOnProbeFailureMajors | Sort-Object { [int]$_ })
    retainedUnknownMajors = @($retainedUnknownMajors | Sort-Object { [int]$_ })
    candidateNewMajors = @($candidateNewMajors | Sort-Object { [int]$_ })
    addedMajors = @($addedMajors | Sort-Object { [int]$_ })
}
