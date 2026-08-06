<#
.SYNOPSIS
    Unit tests for the exact EDB artifact resolution helpers: filename
    parsing, release-body provenance parsing, and the revision enumeration
    (which never assumes packaging revision -1).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

# ---------------------------------------------------------------------------
# ConvertFrom-EdbArtifactFilename
# ---------------------------------------------------------------------------
Test-Case 'ConvertFrom-EdbArtifactFilename parses a valid artifact filename' {
    $parsed = ConvertFrom-EdbArtifactFilename -Filename 'postgresql-18.4-2-windows-x64-binaries.zip'
    Assert-True ($null -ne $parsed)
    Assert-Equal '18' $parsed.major
    Assert-Equal '4' $parsed.minor
    Assert-Equal 2 $parsed.revision
}

Test-Case 'ConvertFrom-EdbArtifactFilename rejects unknown filename shapes' {
    Assert-True ($null -eq (ConvertFrom-EdbArtifactFilename -Filename 'postgresql-18.4-windows-x64-binaries.zip'))
    Assert-True ($null -eq (ConvertFrom-EdbArtifactFilename -Filename 'postgresql-18.4-2-windows-x64.zip'))
    Assert-True ($null -eq (ConvertFrom-EdbArtifactFilename -Filename 'postgresql-18.4-2-windows-x64-binaries.zip.sig'))
    Assert-True ($null -eq (ConvertFrom-EdbArtifactFilename -Filename 'installer-18.4-2-windows-x64-binaries.zip'))
    Assert-True ($null -eq (ConvertFrom-EdbArtifactFilename -Filename ''))
}

# ---------------------------------------------------------------------------
# Get-EdbArtifactFromReleaseBody
# ---------------------------------------------------------------------------
Test-Case 'Get-EdbArtifactFromReleaseBody reads the current provenance row' {
    $body = "| Field | Value |`n| --- | --- |`n| EDB binaries archive | ``postgresql-18.4-2-windows-x64-binaries.zip`` |`n| EDB binaries SHA-256 (calculated post-download) | ``abc123`` |"
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' (Get-EdbArtifactFromReleaseBody -Body $body)
}

Test-Case 'Get-EdbArtifactFromReleaseBody reads the legacy SHA row filename' {
    $body = "| EDB binaries SHA-256 | ``7effe34c0bf89027b3f171447d351cbc460f4566c8d0f643daec67f140787858  postgresql-18.4-1-windows-x64-binaries.zip`` |"
    Assert-Equal 'postgresql-18.4-1-windows-x64-binaries.zip' (Get-EdbArtifactFromReleaseBody -Body $body)
}

Test-Case 'Get-EdbArtifactFromReleaseBody returns null when no artifact is recorded' {
    Assert-True ($null -eq (Get-EdbArtifactFromReleaseBody -Body '| Field | Value |'))
    Assert-True ($null -eq (Get-EdbArtifactFromReleaseBody -Body ''))
}

# ---------------------------------------------------------------------------
# Resolve-EdbArtifact (network functions stubbed; -Minor supplied so pg.org
# is not consulted)
# ---------------------------------------------------------------------------
$script:ProbedUrls = [System.Collections.Generic.List[string]]::new()
function Test-EdbBinaryUrl {
    <# Stub: revisions 1..2 exist, everything else does not. #>
    param([Parameter(Mandatory = $true)][string]$Url)
    $script:ProbedUrls.Add($Url)
    if ($Url -match '-([0-9]+)-windows-x64-binaries\.zip$') {
        return ([int]$matches[1] -le 2)
    }
    return $false
}

Test-Case 'Resolve-EdbArtifact enumerates revisions and picks the highest available (never assumes -1)' {
    $artifact = Resolve-EdbArtifact -Major '18' -Minor '4'
    Assert-True ($null -ne $artifact)
    Assert-Equal 2 $artifact.revision
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $artifact.filename
    Assert-Equal 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip' $artifact.url
    Assert-Equal '18' $artifact.major
    Assert-Equal '4' $artifact.minor
    # Ascending probes: 1, 2, then the first miss (3).
    Assert-True ($script:ProbedUrls.Count -ge 3) 'expected at least three ascending probes'
    Assert-True ($script:ProbedUrls[0] -match 'postgresql-18\.4-1-windows-x64-binaries\.zip$')
    Assert-True ($script:ProbedUrls[1] -match 'postgresql-18\.4-2-windows-x64-binaries\.zip$')
}

Test-Case 'Resolve-EdbArtifact returns null (fail closed) when no revision exists' {
    $script:ProbedUrls.Clear()
    function Test-EdbBinaryUrl {
        param([Parameter(Mandatory = $true)][string]$Url)
        $script:ProbedUrls.Add($Url)
        return $false
    }
    $artifact = Resolve-EdbArtifact -Major '18' -Minor '99'
    Assert-True ($null -eq $artifact)
    # Probing breaks at the first missing revision: one probe, then fail closed.
    Assert-Equal 1 $script:ProbedUrls.Count 'expected a single probe before the first-miss break'
}

Test-Case 'Resolve-EdbArtifact stops probing at the first missing revision' {
    $script:ProbedUrls.Clear()
    function Test-EdbBinaryUrl {
        param([Parameter(Mandatory = $true)][string]$Url)
        $script:ProbedUrls.Add($Url)
        if ($Url -match '-([0-9]+)-windows-x64-binaries\.zip$') {
            return ([int]$matches[1] -le 1)
        }
        return $false
    }
    $artifact = Resolve-EdbArtifact -Major '14' -Minor '23'
    Assert-True ($null -ne $artifact)
    Assert-Equal 1 $artifact.revision
    Assert-Equal 2 $script:ProbedUrls.Count 'expected probes 1 and 2 only'
}

Complete-Tests
