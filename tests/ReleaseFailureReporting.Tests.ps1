<#
.SYNOPSIS
    Regression tests for idempotent release-failure issue reporting.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

Test-Case 'release failure marker is stable for a version and upstream tag' {
    $marker = Get-ReleaseFailureMarker -Version '2.4.8' -UpstreamTag 'REL2_4_8'
    Assert-Equal '<!-- pglogical-build-failure: 2.4.8/REL2_4_8 -->' $marker
}

Test-Case 'existing failure issue lookup matches marker and ignores unrelated issues' {
    $marker = Get-ReleaseFailureMarker -Version '2.4.8' -UpstreamTag 'REL2_4_8'
    $issues = @(
        [pscustomobject]@{ number = 17; state = 'open'; body = '<!-- pglogical-build-failure: 2.4.7/REL2_4_7 -->' },
        [pscustomobject]@{ number = 42; state = 'open'; body = "Some text`n$marker`nMore text" },
        [pscustomobject]@{ number = 99; state = 'open'; body = '' }
    )

    $found = @(Find-ExistingReleaseFailureIssue -Issues $issues -Marker $marker)

    Assert-Equal 1 $found.Count
    Assert-Equal 42 $found[0].number
}

Complete-Tests
