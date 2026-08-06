<#
.SYNOPSIS
    Unit tests for Resolve-UpstreamSource: ExpectedCommitSha verification on
    both supplied checkouts and the clone path.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pgl-upstream-tests-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempRoot

try {
    # ------------------------------------------------------------------
    # Fixture: an upstream-like git repository with a REL2_4_8 tag.
    # ------------------------------------------------------------------
    $fixtureRepo = Join-Path $tempRoot 'upstream-fixture'
    $null = New-Item -ItemType Directory -Force -Path $fixtureRepo
    git -C $fixtureRepo init -q
    git -C $fixtureRepo config user.email 'tests@example.com'
    git -C $fixtureRepo config user.name 'Test Runner'
    Set-Content -Path (Join-Path $fixtureRepo 'Makefile') -Value '# fixture' -Encoding ascii
    Set-Content -Path (Join-Path $fixtureRepo 'README') -Value 'fixture' -Encoding ascii
    git -C $fixtureRepo add -A
    git -C $fixtureRepo commit -q -m 'fixture commit'
    git -C $fixtureRepo tag REL2_4_8
    $fixtureSha = (& git -C $fixtureRepo rev-parse HEAD).Trim()

    $baseArgs = @{ UpstreamRepository = '2ndQuadrant/pglogical'; UpstreamTag = 'REL2_4_8' }

    Test-Case 'Matching ExpectedCommitSha with a supplied SourceDir succeeds' {
        $resolved = Resolve-UpstreamSource @baseArgs -SourceDir $fixtureRepo -ExpectedCommitSha $fixtureSha
        Assert-Equal $fixtureRepo $resolved 'expected the supplied SourceDir to be returned'
    }

    Test-Case 'Mismatching ExpectedCommitSha with a supplied SourceDir fails with both SHAs' {
        $wrongSha = 'a' * 40
        $message = ''
        try {
            Resolve-UpstreamSource @baseArgs -SourceDir $fixtureRepo -ExpectedCommitSha $wrongSha | Out-Null
        }
        catch { $message = $_.Exception.Message }
        Assert-True ($message -ne '') 'expected a throw'
        Assert-True ($message -match [regex]::Escape($wrongSha)) "expected message to contain the expected SHA ($wrongSha)"
        Assert-True ($message -match [regex]::Escape($fixtureSha)) "expected message to contain the actual checkout SHA ($fixtureSha)"
        Assert-True ($message -match 'mismatch') 'expected an actionable mismatch error'
    }

    Test-Case 'SHA comparison is case-insensitive' {
        $resolved = Resolve-UpstreamSource @baseArgs -SourceDir $fixtureRepo -ExpectedCommitSha $fixtureSha.ToUpperInvariant()
        Assert-Equal $fixtureRepo $resolved
    }

    Test-Case 'ExpectedCommitSha is trimmed before comparison' {
        $resolved = Resolve-UpstreamSource @baseArgs -SourceDir $fixtureRepo -ExpectedCommitSha " $fixtureSha "
        Assert-Equal $fixtureRepo $resolved
    }

    Test-Case 'The normal clone path still succeeds and verifies the SHA' {
        $workDir = Join-Path $tempRoot 'clone-work'
        $null = New-Item -ItemType Directory -Force -Path $workDir
        $cloneUrl = 'file://' + ($fixtureRepo -replace '\\', '/')
        $resolved = Resolve-UpstreamSource @baseArgs -WorkDir $workDir -CloneUrl $cloneUrl -ExpectedCommitSha $fixtureSha
        Assert-Equal (Join-Path $workDir 'upstream') $resolved
        $head = (& git -C $resolved rev-parse HEAD).Trim()
        Assert-Equal $fixtureSha $head 'clone HEAD must match the fixture commit'
    }

    Test-Case 'The clone path fails on a mismatching expected SHA' {
        $workDir = Join-Path $tempRoot 'clone-work-2'
        $null = New-Item -ItemType Directory -Force -Path $workDir
        $cloneUrl = 'file://' + ($fixtureRepo -replace '\\', '/')
        Assert-Throws {
            Resolve-UpstreamSource @baseArgs -WorkDir $workDir -CloneUrl $cloneUrl -ExpectedCommitSha ('b' * 40) | Out-Null
        } -MessagePattern 'mismatch'
    }

    Test-Case 'Empty ExpectedCommitSha skips verification (existing behavior)' {
        $resolved = Resolve-UpstreamSource @baseArgs -SourceDir $fixtureRepo
        Assert-Equal $fixtureRepo $resolved
    }

    Test-Case 'SkipClone without SourceDir still fails' {
        Assert-Throws {
            Resolve-UpstreamSource @baseArgs -SkipClone | Out-Null
        } -MessagePattern 'requires an existing checkout'
    }

    Test-Case 'A non-checkout SourceDir is rejected' {
        $notCheckout = Join-Path $tempRoot 'not-a-checkout'
        $null = New-Item -ItemType Directory -Force -Path $notCheckout
        Assert-Throws {
            Resolve-UpstreamSource @baseArgs -SourceDir $notCheckout | Out-Null
        } -MessagePattern 'does not look like a pglogical checkout'
    }
}
finally {
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
    Complete-Tests
}
