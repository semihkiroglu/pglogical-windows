<#
.SYNOPSIS
    Unit tests for upstream compatibility-major detection helpers.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("pgl-compat-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'compat14') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'compat18') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'not-compat19') | Out-Null

    Test-Case 'Compatibility helper returns numeric compat directories sorted' {
        $majors = @(Get-UpstreamCompatibilityMajors -SourceDir $root)
        Assert-Equal '14,18' ($majors -join ',')
    }

    Test-Case 'Compatibility helper distinguishes present and absent majors' {
        Assert-True (Test-UpstreamCompatibilityMajor -SourceDir $root -Major '18')
        Assert-False (Test-UpstreamCompatibilityMajor -SourceDir $root -Major '19')
    }

    Test-Case 'Compatibility helper fails closed for a missing checkout' {
        Assert-Throws { Get-UpstreamCompatibilityMajors -SourceDir (Join-Path $root 'missing') | Out-Null } -MessagePattern 'not found'
    }
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Complete-Tests
