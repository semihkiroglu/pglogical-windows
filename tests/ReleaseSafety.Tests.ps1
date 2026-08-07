<#
.SYNOPSIS
    Unit tests for release publish safety: fail-closed existing-release
    detection (Test-ExistingRelease) and cleanup ownership
    (Test-ReleaseOwnership). The gh api boundary is stubbed - no real
    GitHub API calls.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

# --- HTTP-status-driven gh api stub -----------------------------------------
$script:FakeResponses = @{}   # url -> hashtable {Status, Tag}

function Invoke-FakeGhApi {
    param([Parameter(Mandatory = $true)][string[]]$Args)
    $url = $Args[0]
    if ($script:FakeResponses.ContainsKey($url)) {
        $resp = $script:FakeResponses[$url]
        if ($resp.Status -eq 200) {
            if ($url -match 'releases/tags/') { return @{ ExitCode = 0; Stdout = "987654`n"; Stderr = '' } }
            return @{ ExitCode = 0; Stdout = $resp.Tag; Stderr = '' }
        }
        if ($resp.Status -eq 404) {
            return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 404: Not Found (https://api.github.com/repos/o/r/releases/tags/x) []' }
        }
        return @{ ExitCode = 1; Stdout = ''; Stderr = "gh: HTTP $($resp.Status): API error (https://api.github.com/repos/o/r/$url) []" }
    }
    # Unknown URL: simulate a transport-level failure (network/timeout).
    return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: failed to connect to api.github.com port 443 after 30s: Operation timed out' }
}

$script:GhApiRunner = 'Invoke-FakeGhApi'

# --- Test-ExistingRelease: status classification -----------------------------
Test-Case 'Existing-release detection: HTTP 200 -> exists' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 200; Tag = 'pglogical-2.4.8-pg18-windows.1' } }
    Assert-Equal 'exists' (Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Existing-release detection: HTTP 404 -> absent' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 404; Tag = '' } }
    Assert-Equal 'absent' (Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Existing-release detection: HTTP 401 -> fail closed' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 401; Tag = '' } }
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'indeterminate'
}

Test-Case 'Existing-release detection: HTTP 403 -> fail closed' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 403; Tag = '' } }
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'indeterminate'
}

Test-Case 'Existing-release detection: HTTP 429 -> fail closed' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 429; Tag = '' } }
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'indeterminate'
}

Test-Case 'Existing-release detection: HTTP 500 -> fail closed' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 500; Tag = '' } }
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'indeterminate'
}

Test-Case 'Existing-release detection: transport error -> fail closed' {
    $script:FakeResponses = @{}   # no route -> simulated network failure
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'indeterminate'
}

Test-Case 'Existing-release detection: malformed 200 response -> fail closed' {
    $script:FakeResponses = @{ 'repos/o/r/releases/tags/pglogical-2.4.8-pg18-windows.1' = @{ Status = 200; Tag = '' } }
    # Override stdout with garbage via a custom runner for this case
    $script:GhApiRunner = {
        param([string[]]$Args)
        return @{ ExitCode = 0; Stdout = 'not-a-number'; Stderr = '' }
    }
    Assert-Throws { Test-ExistingRelease -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r' } -MessagePattern 'unexpected response'
    $script:GhApiRunner = 'Invoke-FakeGhApi'
}

# --- Test-ReleaseOwnership: cleanup authorization -----------------------------
Test-Case 'Cleanup ownership: job created the draft -> cleanup allowed' {
    $script:FakeResponses = @{
        'repos/o/r/releases/42' = @{ Status = 200; Tag = 'pglogical-2.4.8-pg18-windows.1' }
    }
    Assert-True (Test-ReleaseOwnership -Created 'true' -ReleaseId '42' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Cleanup ownership: release existed before the job -> forbidden' {
    $script:FakeResponses = @{ 'repos/o/r/releases/42' = @{ Status = 200; Tag = 'pglogical-2.4.8-pg18-windows.1' } }
    Assert-False (Test-ReleaseOwnership -Created 'false' -ReleaseId '42' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Cleanup ownership: created=true but tag identity does not match -> forbidden' {
    $script:FakeResponses = @{
        'repos/o/r/releases/42' = @{ Status = 200; Tag = 'pglogical-2.4.8-pg17-windows.1' }
    }
    Assert-False (Test-ReleaseOwnership -Created 'true' -ReleaseId '42' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Cleanup ownership: release ID lookup fails -> forbidden' {
    $script:FakeResponses = @{ 'repos/o/r/releases/42' = @{ Status = 404; Tag = '' } }
    Assert-False (Test-ReleaseOwnership -Created 'true' -ReleaseId '42' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Cleanup ownership: created=true but invalid release ID -> forbidden' {
    Assert-False (Test-ReleaseOwnership -Created 'true' -ReleaseId 'abc' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Test-Case 'Cleanup ownership: creation failed before ID capture -> forbidden' {
    Assert-False (Test-ReleaseOwnership -Created '' -ReleaseId '' -Tag 'pglogical-2.4.8-pg18-windows.1' -Repository 'o/r')
}

Complete-Tests