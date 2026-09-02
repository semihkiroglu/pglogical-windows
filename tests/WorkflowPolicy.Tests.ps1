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

Test-Case 'Compatibility workflow has no upstream checkout or source build path' {
    Assert-False ($compat -match '(?m)^\s*git clone\b')
    Assert-False ($compat -match 'Build-PgLogical\.ps1')
    Assert-True ($compat -match 'Install-PgLogicalReleasePackage\.ps1')
    Assert-True ($compat -match 'Test-PgLogical\.ps1')
}

Test-Case 'Compatibility workflow exposes force, failure classes, and targeted dispatch' {
    Assert-True ($compat -match 'force:')
    Assert-True ($compat -match "failureClass = 'download'")
    Assert-True ($compat -match "failureClass = 'metadata'")
    Assert-True ($compat -match "failureClass = 'compatibility'")
    Assert-True ($compat -match 'Get-CompatibilityRebuildPlan\.ps1')
    Assert-True ($compat -match 'actions/workflows/release\.yml/dispatches')
    Assert-True ($compat -match 'rebuildMarker')
}

Test-Case 'Upstream watcher reacts to a merged PostgreSQL matrix change' {
    Assert-True ($watch -match "push:\s+paths:\s+- '\.github/pg-versions\.json'")
    Assert-True ($watch -match 'Get-UpstreamReleases\.ps1')
}

Test-Case 'Release workflow accepts the targeted rebuild marker' {
    Assert-True ($release -match 'run-name: release')
    Assert-True ($release -match 'rebuildMarker:')
}

Complete-Tests
