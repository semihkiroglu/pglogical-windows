<#
.SYNOPSIS
    Regression tests for the single-invocation contract of Invoke-GhApi:
    one logical Invoke-GhApi call must execute the underlying command
    exactly once, with ExitCode / Stdout / Stderr all captured from that
    single invocation. The native-process boundary (Invoke-NativeProcess)
    is stubbed - no real process and no real GitHub API call.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

# --- Counting native-process stub --------------------------------------------
$script:NativeCalls = 0
$script:NativeCallArgs = @()
$script:NativeRoutes = @{}   # call-index -> result hashtable

function Invoke-FakeNativeProcess {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $script:NativeCalls++
    $script:NativeCallArgs += , @($Arguments)
    $idx = $script:NativeCalls
    if ($script:NativeRoutes.ContainsKey($idx)) {
        return $script:NativeRoutes[$idx]
    }
    return @{ ExitCode = 0; Stdout = ''; Stderr = '' }
}

$script:NativeProcessRunner = 'Invoke-FakeNativeProcess'
$script:GhApiRunner = $null   # production path: real Invoke-GhApi logic

Test-Case 'Single invocation: successful command runs once, stdout+stderr captured' {
    $script:NativeCalls = 0
    $script:NativeRoutes = @{ 1 = @{ ExitCode = 0; Stdout = "987654`n"; Stderr = '' } }
    $r = Invoke-GhApi -Args @('repos/o/r/releases/tags/x', '--jq', '.id')
    Assert-Equal 1 $script:NativeCalls
    Assert-Equal 0 $r.ExitCode
    Assert-Equal '987654' $r.Stdout
    Assert-Equal '' $r.Stderr
    Assert-Equal 'api' $script:NativeCallArgs[0][0]
    Assert-Equal 'repos/o/r/releases/tags/x' $script:NativeCallArgs[0][1]
}

Test-Case 'Single invocation: failing command runs once, stderr captured from that call' {
    $script:NativeCalls = 0
    $script:NativeRoutes = @{ 1 = @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 500: Internal Server Error (https://api.github.com/repos/o/r/releases/tags/x) []' } }
    $r = Invoke-GhApi -Args @('repos/o/r/releases/tags/x', '--jq', '.id')
    Assert-Equal 1 $script:NativeCalls
    Assert-Equal 1 $r.ExitCode
    Assert-Equal '' $r.Stdout
    Assert-True ($r.Stderr -match 'HTTP 500')
}

Test-Case 'Failure output cannot come from a second invocation' {
    # The first (and only) call fails with HTTP 500. If the old buggy
    # implementation issued a second call to fetch stderr, that second call
    # would have returned HTTP 404 (a different, misleading result) and the
    # assertion below would fail. The fix guarantees one invocation.
    $script:NativeCalls = 0
    $script:NativeRoutes = @{
        1 = @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 500: Internal Server Error (https://api.github.com/repos/o/r/releases/tags/x) []' }
        2 = @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 404: Not Found (https://api.github.com/repos/o/r/releases/tags/x) []' }
    }
    $r = Invoke-GhApi -Args @('repos/o/r/releases/tags/x', '--jq', '.id')
    Assert-Equal 1 $script:NativeCalls
    Assert-True ($r.Stderr -match 'HTTP 500')
    Assert-False ($r.Stderr -match 'HTTP 404')
}

Test-Case 'High-level GhApiRunner injection takes precedence and never touches the process boundary' {
    $script:NativeCalls = 0
    $script:GhApiRunner = {
        param([string[]]$Args)
        return @{ ExitCode = 0; Stdout = '42'; Stderr = '' }
    }
    $r = Invoke-GhApi -Args @('repos/o/r/releases/tags/x', '--jq', '.id')
    Assert-Equal 0 $script:NativeCalls
    Assert-Equal '42' $r.Stdout
    $script:GhApiRunner = $null
}

Complete-Tests