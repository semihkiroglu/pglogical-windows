<#
.SYNOPSIS
    Builds the compatibility-smoke decision plan for configured majors.

.DESCRIPTION
    This script only discovers the current PostgreSQL.org minor and EDB
    artifact identity, then compares it with the newest published package per
    major. It never checks out pglogical source and never compiles anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $config = Import-VersionConfig
    $version = [string]$config.releaseBaseline
    $pgOrgEntries = @(Get-PgOrgVersions)
    $configuredMajors = @($config.postgresqlMajors | ForEach-Object { [string]$_ } | Sort-Object { [int]$_ })
    $artifacts = @{}
    foreach ($major in $configuredMajors) {
        $pgEntry = @($pgOrgEntries | Where-Object { [string]$_.major -eq $major }) | Select-Object -First 1
        if ($null -eq $pgEntry) { throw "PostgreSQL.org versions.json has no configured major '$major'; failing closed." }
        if (-not [bool]$pgEntry.supported) { throw "Configured PostgreSQL major '$major' is not supported by PostgreSQL.org; update .github/pg-versions.json first." }
        $artifact = Resolve-EdbArtifact -Major $major -Minor ([string]$pgEntry.latestMinor)
        if ($null -eq $artifact) { throw "No conclusive EDB artifact is available for configured PostgreSQL major '$major'; refusing to produce an incomplete smoke plan." }
        $artifacts[$major] = $artifact
    }

    $localReleases = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$Repository/releases")
    $entries = @(Get-CompatibilitySmokePlan -Majors $configuredMajors -LocalReleases $localReleases -ServerArtifacts $artifacts -Force:$Force)
    $testEntries = @($entries | Where-Object { $_.status -eq 'test' })
    $upstreamTag = ConvertFrom-PgLogicalVersion -Version $version
    $upstreamCommit = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$(Get-UpstreamRepository)/commits/$upstreamTag") | Select-Object -First 1
    if ($null -eq $upstreamCommit -or [string]$upstreamCommit.sha -notmatch '^[0-9a-fA-F]{40}$') { throw "Could not resolve commit SHA for upstream tag '$upstreamTag'; failing closed." }
    $upstreamCommitSha = [string]$upstreamCommit.sha
    $plan = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        pglogicalVersion = $version
        upstreamTag = $upstreamTag
        upstreamCommitSha = $upstreamCommitSha
        postgresqlMajors = $configuredMajors
        force = [bool]$Force
        entries = $entries
        testEntries = $testEntries
    }
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputFile))
    if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent }
    $json = $plan | ConvertTo-Json -Depth 30
    $json | Set-Content -LiteralPath $OutputFile -Encoding utf8
    Write-Output ($plan | ConvertTo-Json -Depth 30 -Compress)
}
catch {
    Write-Error $_
    exit 1
}
