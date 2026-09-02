<#
.SYNOPSIS
    Converts compatibility-smoke results into targeted rebuild decisions.

.DESCRIPTION
    This is a decision-only wrapper. It downloads no package and dispatches no
    workflow. It reads the smoke result JSON files, fetches current release and
    issue/run state, and emits pinned next-revision plans plus deduplicated
    same-artifact issue candidates.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$PlanFile,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    [Parameter(Mandatory = $true)][string]$OutputFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Read-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Could not read JSON '$Path': $($_.Exception.Message)" }
}

try {
    $plan = Read-JsonObject -Path $PlanFile
    foreach ($property in @('pglogicalVersion', 'upstreamTag', 'upstreamCommitSha')) {
        if ($null -eq $plan.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$plan.$property)) {
            throw "Smoke plan is missing '$property'; failing closed."
        }
    }
    if ([string]$plan.upstreamCommitSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'Smoke plan upstreamCommitSha is malformed; failing closed.' }

    $resultFiles = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.json' -File -Recurse -ErrorAction Stop)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $resultFiles) {
        $item = Read-JsonObject -Path $file.FullName
        if ($item.PSObject.Properties['resultType'] -and [string]$item.resultType -eq 'summary') { continue }
        $results.Add($item)
    }

    $localReleases = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$Repository/releases")
    $existingTags = @($localReleases | ForEach-Object { [string]$_.tag_name } | Where-Object { $_ })
    $artifacts = @{}
    foreach ($result in @($results)) {
        if (-not $result.PSObject.Properties['postgresqlMajor']) { continue }
        $major = [string]$result.postgresqlMajor
        if (-not $result.serverEdbArtifactFilename -or -not $result.serverEdbArtifactUrl) { continue }
        $parsed = ConvertFrom-EdbArtifactFilename -Filename ([string]$result.serverEdbArtifactFilename)
        if (-not $parsed -or $parsed.major -ne $major) { throw "Smoke result for PostgreSQL $major contains an invalid current artifact identity." }
        $candidate = [pscustomobject]@{
            major = $major
            minor = [string]$result.serverMinor
            revision = [int]$parsed.revision
            filename = [string]$result.serverEdbArtifactFilename
            url = [string]$result.serverEdbArtifactUrl
        }
        if ($artifacts.ContainsKey($major) -and [string]$artifacts[$major].filename -ne $candidate.filename) { throw "Smoke results disagree about the current artifact for PostgreSQL $major." }
        $artifacts[$major] = $candidate
    }

    $failedCompatibility = @($results | Where-Object { [string]$_.status -eq 'failed' -and [string]$_.failureClass -eq 'compatibility' })
    $failedMajors = @($failedCompatibility | ForEach-Object { [string]$_.postgresqlMajor } | Sort-Object { [int]$_ } -Unique)
    $activeRuns = [System.Collections.Generic.List[object]]::new()
    foreach ($runStatus in @('queued', 'in_progress', 'waiting')) {
        foreach ($run in @(Invoke-GitHubApi -Url "https://api.github.com/repos/$Repository/actions/workflows/release.yml/runs?status=$runStatus")) { $activeRuns.Add($run) }
    }
    $inFlightTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($run in @($activeRuns)) {
        foreach ($propertyName in @('display_title', 'name', 'run_name')) {
            $property = $run.PSObject.Properties[$propertyName]
            if ($null -eq $property) { continue }
            foreach ($match in [regex]::Matches([string]$property.Value, 'pglogical-[0-9]+\.[0-9]+\.[0-9]+-pg[0-9]+-windows\.[0-9]+')) {
                $null = $inFlightTags.Add($match.Value)
            }
        }
    }

    $targeted = @(Get-TargetedRebuildPlan -Version ([string]$plan.pglogicalVersion) -UpstreamTag ([string]$plan.upstreamTag) -CommitSha ([string]$plan.upstreamCommitSha) -FailedMajors $failedMajors -Artifacts $artifacts -LocalReleases $localReleases -CompatibilityResults @($results) -ExistingReleaseTags $existingTags -InFlightTags @($inFlightTags))

    $issues = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$Repository/issues?state=all")
    $issueCandidates = [System.Collections.Generic.List[object]]::new()
    $seenMarkers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($result in @($failedCompatibility)) {
        $major = [string]$result.postgresqlMajor
        $packageArtifact = [string]$result.localPackageBuildArtifactFilename
        $serverArtifact = [string]$result.serverEdbArtifactFilename
        if (-not $packageArtifact -or -not $serverArtifact -or $packageArtifact -ne $serverArtifact) { continue }
        $packageTag = [string]$result.localReleaseTag
        if (-not $packageTag) { throw "Same-artifact compatibility failure for PostgreSQL $major has no package release tag; failing closed." }
        $marker = Get-CompatibilityFailureMarker -Major $major -PackageTag $packageTag -ServerArtifactFilename $serverArtifact
        if ($seenMarkers.Contains($marker) -or (Find-ExistingReleaseFailureIssue -Issues $issues -Marker $marker)) { continue }
        $null = $seenMarkers.Add($marker)
        $body = @"
$marker

Compatibility smoke failed for PostgreSQL $major even though the package and current EDB artifact are identical.

- Package release: $packageTag
- EDB artifact: $serverArtifact
- Decision: do not dispatch an automatic rebuild; investigate the compatibility failure.
"@
        $issueCandidates.Add([pscustomobject]@{
            marker = $marker
            title = "Compatibility smoke failure: PostgreSQL $major ($serverArtifact)"
            body = $body.Trim()
            postgresqlMajor = $major
        })
    }

    $output = [ordered]@{
        schemaVersion = 1
        resultType = 'rebuild-decision'
        pglogicalVersion = [string]$plan.pglogicalVersion
        upstreamTag = [string]$plan.upstreamTag
        upstreamCommitSha = [string]$plan.upstreamCommitSha
        failedMajors = $failedMajors
        targetedRebuildPlan = $targeted
        issueCandidates = @($issueCandidates)
        existingReleaseTags = $existingTags
        inFlightTags = @($inFlightTags)
    }
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputFile))
    if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent }
    $output | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputFile -Encoding utf8
    Write-Output ($output | ConvertTo-Json -Depth 30 -Compress)
}
catch {
    Write-Error $_
    exit 1
}
