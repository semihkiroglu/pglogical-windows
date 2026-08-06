<#
.SYNOPSIS
    Discovers the latest published upstream pglogical release and computes an
    idempotent build plan only for that version (never backfills skipped
    versions).

.DESCRIPTION
    Calls GET /repos/{owner}/{repo}/releases/latest (which excludes drafts
    and prereleases by definition), validates the tag against the configured
    pattern (^REL[0-9]+_[0-9]+_[0-9]+$), checks the configured baseline
    (2.4.8), resolves the exact official EDB Windows x64 artifact for every
    configured PostgreSQL major, compares it with the artifact recorded in
    the latest local release for that version × major, and emits a JSON
    build plan.

    Plan semantics per version × major:
      * no local release                          -> packaging revision 1
      * local release records the same EDB
        artifact filename as the resolved one     -> covered (no action)
      * resolved artifact is newer (minor and/or
        packaging revision)                       -> next packaging revision
    The EDB identity is the trigger: a post-download SHA recalculation alone
    never triggers a rebuild. Fail-closed: an unresolvable EDB artifact, an
    unparseable recorded identity, or a resolved artifact OLDER than the one
    recorded in the latest release aborts the plan with a clear error.

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
# 4. Resolve the exact EDB artifact for every configured major (fail closed)
# ---------------------------------------------------------------------------
$majors = @($config.postgresqlMajors | Sort-Object { [int]$_ })
$artifacts = [ordered]@{}
foreach ($major in $majors) {
    $artifact = Resolve-EdbArtifact -Major $major
    if (-not $artifact) {
        throw "Cannot resolve the exact EDB Windows x64 binaries artifact for PostgreSQL $major (fail closed). Refusing to plan a release against an unknown artifact; check pg.org versions.json and get.enterprisedb.com availability."
    }
    $artifacts[$major] = $artifact
    Write-Host "PG $major exact EDB artifact: $($artifact.filename)"
}

# ---------------------------------------------------------------------------
# 5. Fetch local releases for this version and compute the plan (per PG major)
# ---------------------------------------------------------------------------
$allReleases = @(Invoke-GitHubApi -Url "https://api.github.com/repos/$localOwner/releases")
$localReleases = @($allReleases | Where-Object { -not $_.draft } | ForEach-Object {
    [pscustomobject]@{ tag_name = [string]$_.tag_name; body = [string]$_.body }
})
Write-Host "Fetched $($localReleases.Count) local releases"

$plan = @(Get-ReleasePlan `
    -Version $version `
    -UpstreamTag $tag `
    -CommitSha $commitSha `
    -Majors $majors `
    -Artifacts $artifacts `
    -LocalReleases $localReleases)
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
