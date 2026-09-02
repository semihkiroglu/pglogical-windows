<#
.SYNOPSIS
    Contract checks for compatibility and new-major workflow wiring.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$compat = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/compatibility-smoke.yml') -Raw
$watch = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/upstream-watch.yml') -Raw
$release = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml') -Raw
$prepare = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Prepare-UnifiedReleaseAssets.ps1') -Raw
$releaseBody = Get-Content -LiteralPath (Join-Path $repoRoot '.github/release-body-template.md') -Raw

Test-Case 'Compatibility workflow has no upstream checkout or source build path' {
    Assert-False ($compat -match '(?m)^\s*git clone\b')
    Assert-False ($compat -match 'Build-PgLogical\.ps1')
    Assert-True ($compat -match 'Install-PgLogicalReleasePackage\.ps1')
    Assert-True ($compat -match 'Test-PgLogical\.ps1')
}

Test-Case 'Release workflow publishes one complete unified release' {
    Assert-True ($release -match 'name: Publish unified release')
    Assert-True ($release -match 'Prepare-UnifiedReleaseAssets\.ps1')
    Assert-True ($release -match 'pattern: packages-pg\*')
    Assert-True ($release -match 'merge-multiple: false')
    Assert-True ($release -match 'release-assets/release-body\.md')
    Assert-True ($prepare -match 'Test-ReleasePlan')
    Assert-True ($release -match 'release-assets/\*\.zip release-assets/SHA256SUMS\.txt')
    Assert-True ($prepare -match 'Get-ReleaseTitle')
    Assert-True ($release -match '--draft')
    Assert-True ($release -match 'gh release edit.*--draft=false')
    Assert-True ($releaseBody -match '\{\{PACKAGE_PROVENANCE\}\}')
    Assert-True ($releaseBody -match '\{\{PACKAGES\}\}')
    Assert-True ($releaseBody -match '\{\{CHECKSUMS\}\}')
    Assert-True ($release -match 'releases/latest')
    Assert-False ($release -match 'name: Publish release \(PostgreSQL')
    $publishBlock = [regex]::Match($release, '(?ms)^  publish:.*?(?=^  set-latest:)').Value
    Assert-False ($publishBlock -match '(?m)^\s+strategy:')
    Assert-False ($publishBlock.Contains('-PgMajor'))
}

Test-Case 'Compatibility workflow exposes force, failure classes, and unified dispatch' {
    Assert-True ($compat -match 'force:')
    Assert-True ($compat -match "failureClass = 'download'")
    Assert-True ($compat -match "failureClass = 'metadata'")
    Assert-True ($compat -match "failureClass = 'compatibility'")
    Assert-True ($compat -match 'Get-CompatibilityRebuildPlan\.ps1')
    Assert-True ($compat -match 'actions/workflows/release\.yml/dispatches')
    Assert-True ($compat -match 'rebuildMarker')
    Assert-True ($compat -match 'Sort-Object -Unique')
}

Test-Case 'Upstream watcher reacts to a merged PostgreSQL matrix change' {
    Assert-True ($watch -match "push:\s+paths:\s+- '\.github/pg-versions\.json'")
    Assert-True ($watch -match 'Get-UpstreamReleases\.ps1')
}

Test-Case 'Release workflow accepts the targeted rebuild marker' {
    Assert-True ($release -match 'run-name: release')
    Assert-True ($release -match 'rebuildMarker:')
}

Test-Case 'Release failure reporter uses PowerShell environment variable syntax' {
    Assert-True ($release.Contains('gh issue create --repo "$env:GITHUB_REPOSITORY"'))
    Assert-False ($release.Contains('gh issue create --repo "$GITHUB_REPOSITORY"'))
}

Test-Case 'Compatibility workflow persists successful coverage through an automated PR' {
    Assert-True ($compat -match 'Update-CompatibilityCoverage\.ps1')
    Assert-True ($compat -match 'compatibility-coverage\.json')
    Assert-True ($compat -match 'contents: write')
    Assert-True ($compat -match 'pull-requests: write')
    Assert-True ($compat -match 'gh pr create')
    Assert-True ($compat -match 'gh pr merge .*--auto')
    Assert-True ($compat -match 'group: compatibility-smoke')
    Assert-True ($compat -match 'git push --force-with-lease')
}

Complete-Tests
