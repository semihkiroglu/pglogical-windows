<#
.SYNOPSIS
    Discovers the latest published upstream pglogical release and computes an
    idempotent build plan only for that version (never backfills skipped
    versions).

.DESCRIPTION
    Calls GET /repos/{owner}/{repo}/releases/latest (which excludes drafts
    and prereleases by definition), validates the tag against the configured
    pattern (^REL[0-9]+_[0-9]+_[0-9]+$), checks the configured baseline
    (2.4.8), checks the expected local release tags, and emits a JSON build
    plan listing the upstream version × PG major entries that are missing
    locally.

    If the latest release is already fully packaged locally, the plan is
    empty (successful no-op). A 404 from the API (meaning every release is a
    draft or prerelease) is also a silent no-op (exit 0).

    Semantics: only the single NEWEST missing version is ever considered.
    Skipped intermediate versions are never backfilled.

.PARAMETER OutputFile
    Path where the JSON build plan is written. Defaults to
    <repo>/.build/release-plan.json.

.PARAMETER Repository
    Upstream repository in owner/name form. Defaults to the value from
    .github/pg-versions.json.

.PARAMETER Baseline
    Minimum upstream version to consider. Defaults to the value from
    .github/pg-versions.json (2.4.8).

.PARAMETER Quiet
    Suppresses the human-readable summary.

.EXAMPLE
    pwsh ./scripts/Get-UpstreamReleases.ps1 -OutputFile plan.json
#>
[CmdletBinding()]
param(
    [string]$OutputFile,
    [string]$Baseline,
    [switch]$Quiet
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

function Write-EmptyPlan {
    $outputDirectory = Split-Path -Parent $OutputFile
    if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
        $null = New-Item -ItemType Directory -Force -Path $outputDirectory
    }
    $emptyPlan = [pscustomobject]@{
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        upstreamRepo = $Repository
        localRepo    = $localOwner
        baseline     = $Baseline
        plan         = @()
    }
    $emptyPlan | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputFile -Encoding utf8
    Write-Host "Empty plan written to: $OutputFile"
}

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

Write-Host "Upstream repository : $Repository"
Write-Host "Local repository    : $localOwner"
Write-Host "Release baseline    : $Baseline"

# ---------------------------------------------------------------------------
# 1. Get the single latest upstream release
# ---------------------------------------------------------------------------
$latestRelease = $null
try {
    $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers (Get-GitHubHeaders) -Method Get
    Write-Host "Fetched latest upstream release: $($latestRelease.tag_name)"
}
catch {
    $statusCode = $null
    if ($null -ne $_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 404) {
        Write-Host 'No published upstream releases found (all are draft or prerelease). Nothing to do.'
        Write-EmptyPlan
        exit 0
    }
    throw
}

# ---------------------------------------------------------------------------
# 2. Validate the latest release against guards
# ---------------------------------------------------------------------------
if (-not $latestRelease) {
    Write-Host 'No matching upstream release found. Nothing to do.'
    Write-EmptyPlan
    exit 0
}

$tag = [string]$latestRelease.tag_name
if (-not $tagPattern.IsMatch($tag)) {
    throw "Latest upstream tag '$tag' does not match the expected pattern $(Get-UpstreamTagPattern)"
}

$version = ConvertTo-PgLogicalVersion -Tag $tag
if ([version]$version -lt [version]$Baseline) {
    throw "Latest upstream version $version is below the configured baseline $Baseline; not packaging."
}
Write-Host "Latest upstream release: $tag ($version)"

# ---------------------------------------------------------------------------
# 3. Resolve exact commit SHA
# ---------------------------------------------------------------------------
$commitSha = $null
$ref = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/git/ref/tags/$tag" -Headers (Get-GitHubHeaders) -Method Get
if ($ref.object.type -eq 'tag') {
    $tagObj = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/git/tags/$($ref.object.sha)" -Headers (Get-GitHubHeaders) -Method Get
    $commitSha = [string]$tagObj.object.sha
}
else {
    $commitSha = [string]$ref.object.sha
}
Write-Host "Resolved $tag -> $commitSha"

# ---------------------------------------------------------------------------
# 4. Check local release tags and compute missing set (per PG major)
# ---------------------------------------------------------------------------
$majors = @($config.postgresqlMajors | Sort-Object { [int]$_ })

$plan = @()
foreach ($major in $majors) {
    $localTag = Get-LocalReleaseTag -Version $version -PackagingRevision 1 -PgMajor $major
    $alreadyPackaged = $false
    try {
        $encodedLocalTag = [uri]::EscapeDataString($localTag)
        $null = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$localOwner/releases/tags/$encodedLocalTag" `
            -Headers (Get-GitHubHeaders) `
            -Method Get
        $alreadyPackaged = $true
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -ne 404) { throw }
    }
    if ($alreadyPackaged) {
        Write-Host "Already packaged: $localTag (skipping)"
        continue
    }
    $plan += [pscustomobject]@{
        version           = $version
        upstreamTag       = $tag
        commitSha         = $commitSha
        pgMajor           = $major
        packagingRevision = 1
        localTag          = $localTag
    }
}
$plan = @($plan | Sort-Object { [int]$_.pgMajor })

$result = [pscustomobject]@{
    generatedAt    = (Get-Date).ToUniversalTime().ToString('o')
    upstreamRepo   = $Repository
    localRepo      = $localOwner
    baseline       = $Baseline
    plan           = $plan
}

if (Split-Path -Parent $OutputFile) {
    $outputDirectory = Split-Path -Parent $OutputFile
    if (-not (Test-Path $outputDirectory)) {
        $null = New-Item -ItemType Directory -Force -Path $outputDirectory
    }
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputFile -Encoding utf8

if (-not $Quiet) {
    if ($plan.Count -eq 0) {
        Write-Host 'Build plan is empty: latest upstream release is already packaged for all configured majors. Nothing to do.'
    }
    else {
        Write-Host "Build plan ($($plan.Count) missing release(s)):"
        foreach ($p in $plan) {
            Write-Host "  $($p.version) [$($p.upstreamTag) @ $($p.commitSha)] -> $($p.localTag)"
        }
    }
}
Write-Host "Plan written to: $OutputFile"
