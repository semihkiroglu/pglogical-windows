<#
.SYNOPSIS
    Dependency-free assertion helpers for the pglogical-windows unit tests.
    Dot-sourced by each *.Tests.ps1 file.
#>

$script:TestPassed = 0
$script:TestFailed = 0
$script:TestFailures = [System.Collections.Generic.List[string]]::new()

function Test-Case {
    <#
    .SYNOPSIS
        Runs one named test case; failures are collected and reported
        without aborting the remaining cases.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        $script:TestPassed++
        Write-Host "  PASS  $Name"
    }
    catch {
        $script:TestFailed++
        $message = "$Name :: $($_.Exception.Message)"
        $script:TestFailures.Add($message)
        Write-Host "  FAIL  $message"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [string]$Message = 'expected condition to be true'
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message = 'values differ'
    )
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message (expected '$Expected', actual '$Actual')"
    }
}

function Assert-Throws {
    <#
    .SYNOPSIS
        Asserts that the script block throws; optionally that the exception
        message matches -MessagePattern.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [string]$MessagePattern,
        [string]$Message = 'expected the script block to throw'
    )
    $threw = $false
    try {
        & $Body
    }
    catch {
        $threw = $true
        if ($MessagePattern -and ($_.Exception.Message -notmatch $MessagePattern)) {
            throw "Exception message did not match '$MessagePattern': $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw $Message }
}

function Complete-Tests {
    <#
    .SYNOPSIS
        Prints the summary and exits non-zero when any case failed.
    #>
    if ($script:TestFailed -gt 0) {
        Write-Host ''
        Write-Host "$($script:TestFailed) test case(s) FAILED, $($script:TestPassed) passed:"
        foreach ($failure in $script:TestFailures) { Write-Host "  - $failure" }
        exit 1
    }
    Write-Host ''
    Write-Host "All $($script:TestPassed) test case(s) passed."
    exit 0
}
