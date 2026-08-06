<#
.SYNOPSIS
    Runs every *.Tests.ps1 file in this directory in its own pwsh process.
    Exits non-zero if any test file fails.

.DESCRIPTION
    Dependency-free (no Pester): each test file dot-sources
    test-helpers.ps1 and the repository scripts it exercises. The tests run
    on the CI Linux runner and locally on any machine with git + pwsh.

.EXAMPLE
    pwsh ./tests/run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$testFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) {
    throw "No *.Tests.ps1 files found in $PSScriptRoot"
}

$failedFiles = 0
foreach ($testFile in $testFiles) {
    Write-Host ''
    Write-Host "=== $($testFile.Name) ==="
    & pwsh -NoProfile -File $testFile.FullName
    if ($LASTEXITCODE -ne 0) {
        $failedFiles++
        Write-Host "FAILED: $($testFile.Name)"
    }
}

Write-Host ''
if ($failedFiles -gt 0) {
    throw "$failedFiles of $($testFiles.Count) test file(s) failed."
}
Write-Host "All $($testFiles.Count) test file(s) passed."
