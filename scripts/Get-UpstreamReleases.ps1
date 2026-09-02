<#
.SYNOPSIS
    Discovers the latest upstream pglogical release and plans one complete
    unified release containing all upstream-compatible configured PostgreSQL
    major assets.

.DESCRIPTION
    The normal path is upstream-release driven. A complete published local
    release is coverage only when its unified tag exposes the exact package
    asset for every configured major; legacy per-major releases remain readable
    during migration. Once any major is missing, exact EDB identity is resolved
    for every configured major so the immutable unified release is never
    partial. Compatibility smoke is a separate workflow and is the path that
    requests later Windows packaging revisions.

.PARAMETER ForceUnified
    Explicitly ignores complete legacy per-major coverage and emits one full
    unified plan. Intended only for one-time migration of historical releases;
    normal upstream-watch execution must leave this switch unset.
#>
[CmdletBinding()]
param(
    [string]$OutputFile,
    [string]$Baseline,
    [switch]$Quiet,
    [switch]$ForceUnified
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Get-RepoRoot
$config = Import-VersionConfig
$Repository = Get-UpstreamRepository
if (-not $Baseline) { $Baseline = [string]$config.releaseBaseline }
$tagPattern = [regex](Get-UpstreamTagPattern)
if (-not $OutputFile) { $OutputFile = Join-Path $repoRoot '.build/release-plan.json' }

$localOwner = $env:GITHUB_REPOSITORY
if (-not $localOwner) {
    $remote = git -C $repoRoot remote get-url origin 2>$null
    if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') {
        $localOwner = "$($matches[1])/$($matches[2])"
    }
}
if (-not $localOwner) {
    throw 'Cannot determine the local repository (owner/name). Set GITHUB_REPOSITORY or configure an origin remote.'
}

function Write-PlanFile {
    param(
        [Parameter(Mandatory = $true)]$Value
    )
    $outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputFile))
    if ($outputDirectory) { $null = New-Item -ItemType Directory -Force -Path $outputDirectory }
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -Encoding utf8
}

function New-EmptyPlan {
    param(
        [string]$UpstreamTag = '',
        [string]$CommitSha = '',
        [string[]]$Majors = @(),
        [string]$Reason = 'already covered'
    )
    return [pscustomobject]@{
        schemaVersion = 1
        generatedAt = [DateTime]::UtcNow.ToString('o')
        upstreamRepo = $Repository
        localRepo = $localOwner
        baseline = $Baseline
        pglogicalVersion = if ($UpstreamTag) { ConvertTo-PgLogicalVersion -Tag $UpstreamTag } else { '' }
        upstreamTag = $UpstreamTag
        upstreamCommitSha = $CommitSha
        postgresqlMajors = @($Majors)
        plan = @()
        reason = $Reason
    }
}

Write-Host "Upstream repository : $Repository"
Write-Host "Local repository    : $localOwner"
Write-Host "Release baseline    : $Baseline"

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pglogical-upstream-watch-" + [guid]::NewGuid().ToString('N'))
try {
    # -----------------------------------------------------------------------
    # 1. Get and validate the single latest published upstream release.
    # -----------------------------------------------------------------------
    $latestRelease = $null
    try {
        $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers (Get-GitHubHeaders) -Method Get
    }
    catch {
        $statusCode = $null
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value -and $null -ne $responseProperty.Value.StatusCode) {
            $statusCode = [int]$responseProperty.Value.StatusCode
        }
        if ($statusCode -eq 404) {
            $empty = New-EmptyPlan -Reason 'no published upstream release'
            Write-PlanFile -Value $empty
            Write-Host 'No published upstream releases found; nothing to do.'
            exit 0
        }
        throw
    }
    if (-not $latestRelease) {
        $empty = New-EmptyPlan -Reason 'no upstream release response'
        Write-PlanFile -Value $empty
        exit 0
    }
    $tag = [string]$latestRelease.tag_name
    if (-not $tagPattern.IsMatch($tag)) { throw "Latest upstream tag '$tag' does not match the expected pattern $(Get-UpstreamTagPattern)" }
    $version = ConvertTo-PgLogicalVersion -Tag $tag
    if ([version]$version -lt [version]$Baseline) { throw "Latest upstream version $version is below the configured baseline $Baseline; not packaging." }
    Write-Host "Latest upstream release: $tag ($version)"

    # Resolve the commit using the API's commit view, which handles lightweight
    # and annotated tags without trusting a mutable branch name.
    $commit = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/commits/$tag" -Headers (Get-GitHubHeaders) -Method Get) | Select-Object -First 1
    $commitSha = [string]$commit.sha
    if ($commitSha -notmatch '^[0-9a-fA-F]{40}$') { throw "Could not resolve a 40-hex commit SHA for upstream tag '$tag'; failing closed." }
    Write-Host "Resolved $tag -> $commitSha"

    # -----------------------------------------------------------------------
    # 2. Build the upstream-compatible major set from the exact source tag.
    # -----------------------------------------------------------------------
    $sourceDir = Resolve-UpstreamSource -UpstreamRepository $Repository -UpstreamTag $tag -WorkDir $workDir -ExpectedCommitSha $commitSha
    $compatibleMajors = @(Get-UpstreamCompatibilityMajors -SourceDir $sourceDir)
    $configuredMajors = @($config.postgresqlMajors | ForEach-Object { [string]$_ } | Sort-Object { [int]$_ })
    $majors = @($configuredMajors | Where-Object { $compatibleMajors -contains $_ } | Sort-Object { [int]$_ })
    Write-Host "Configured compatible PostgreSQL majors: $($majors -join ', ')"

    # -----------------------------------------------------------------------
    # 3. Coverage first. A published package asset covers a version × major;
    #    if any major is missing, the unified release must contain every
    #    configured major and therefore needs every exact EDB identity.
    # -----------------------------------------------------------------------
    $allReleases = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$localOwner/releases")
    $publishedReleases = @($allReleases | Where-Object { Test-PublishedRelease -Release $_ })
    Write-Host "Fetched $($publishedReleases.Count) published local releases ($($allReleases.Count) total)"
    $missingMajors = @(Get-MissingReleaseMajors -Version $version -Majors $majors -LocalReleases $allReleases)
    if ($missingMajors.Count -eq 0 -and -not $ForceUnified) {
        $empty = New-EmptyPlan -UpstreamTag $tag -CommitSha $commitSha -Majors $majors -Reason 'all compatible majors are already covered'
        Write-PlanFile -Value $empty
        Write-Host 'Build plan is empty: all compatible configured majors are covered.'
        exit 0
    }

    # -----------------------------------------------------------------------
    # 4. Resolve exact EDB identity for every configured compatible major and
    #    create one shared-tag entry per package asset.
    # -----------------------------------------------------------------------
    $artifacts = [ordered]@{}
    foreach ($major in $majors) {
        $pgEntry = Get-PgOrgEntry -Major $major
        $artifact = Resolve-EdbArtifact -Major $major -Minor ([string]$pgEntry.latestMinor)
        if (-not $artifact) { throw "Cannot resolve the exact EDB Windows x64 binaries artifact for PostgreSQL $major; failing closed." }
        $artifacts[$major] = $artifact
        Write-Host "PG $major exact EDB artifact: $($artifact.filename)"
    }

    $plan = @(Get-ReleasePlan -Version $version -UpstreamTag $tag -CommitSha $commitSha -Majors $majors -Artifacts $artifacts -LocalReleases $allReleases -ForceUnified:$ForceUnified)
    $plan = @($plan | Sort-Object { [int]$_.postgresqlMajor })
    $result = [pscustomobject]@{
        schemaVersion = 1
        generatedAt = [DateTime]::UtcNow.ToString('o')
        upstreamRepo = $Repository
        localRepo = $localOwner
        baseline = $Baseline
        pglogicalVersion = $version
        upstreamTag = $tag
        upstreamCommitSha = $commitSha
        postgresqlMajors = $majors
        compatibleUpstreamMajors = $compatibleMajors
        plan = $plan
        reason = if ($ForceUnified) { 'forced unified migration' } else { 'missing local package coverage' }
    }
    Write-PlanFile -Value $result
    if (-not $Quiet) {
        Write-Host "Build plan: one unified release ($($plan.Count) package assets):"
        foreach ($entry in $plan) { Write-Host "  $($entry.localTag) [EDB $($entry.edbArtifactFilename)]" }
    }
    Write-Host "Plan written to: $OutputFile"
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}
