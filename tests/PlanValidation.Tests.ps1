<#
.SYNOPSIS
    Unit tests for Test-ReleasePlan: pinned release-plan validation
    (malformed JSON, required properties, duplicates, URL/host/filename
    identity, SHA/tag formats, cross-entry consistency) and the pinning
    helper behaviors.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

function New-ValidEntry {
    param(
        [string]$Major = '18',
        [string]$Minor = '4',
        [int]$EdbRevision = 2,
        [int]$WindowsRevision = 1
    )
    return [ordered]@{
        pglogicalVersion         = '2.4.8'
        upstreamTag              = 'REL2_4_8'
        upstreamCommitSha        = '9a0e182745885ad0152ea387988c95a483396a81'
        postgresqlMajor          = $Major
        postgresqlMinor          = $Minor
        postgresqlBuildVersion   = "$Major.$Minor"
        windowsPackagingRevision = $WindowsRevision
        edbPackagingRevision     = $EdbRevision
        edbArtifactFilename      = "postgresql-$Major.$Minor-$EdbRevision-windows-x64-binaries.zip"
        edbArtifactUrl           = "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-$EdbRevision-windows-x64-binaries.zip"
        localTag                 = "pglogical-2.4.8-pg$Major-windows.$WindowsRevision"
    }
}

Test-Case 'Test-ReleasePlan accepts a valid multi-entry plan' {
    $plan = @((New-ValidEntry -Major '18' -Minor '4' -EdbRevision 2), (New-ValidEntry -Major '17' -Minor '10' -EdbRevision 1))
    $entries = Test-ReleasePlan -PlanJson ($plan | ConvertTo-Json -Depth 6)
    Assert-Equal 2 @($entries).Count
}

Test-Case 'Test-ReleasePlan rejects malformed JSON' {
    Assert-Throws { Test-ReleasePlan -PlanJson '{not json' } -MessagePattern 'malformed'
}

Test-Case 'Test-ReleasePlan rejects an empty plan' {
    Assert-Throws { Test-ReleasePlan -PlanJson '[]' } -MessagePattern 'no entries'
    Assert-Throws { Test-ReleasePlan -PlanJson '' } -MessagePattern 'empty'
}

Test-Case 'Test-ReleasePlan rejects a missing required property' {
    $e = New-ValidEntry
    $e.Remove('edbArtifactUrl')
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern "missing required property 'edbArtifactUrl'"
}

Test-Case 'Test-ReleasePlan rejects duplicate PostgreSQL majors' {
    $plan = @((New-ValidEntry -Major '18'), (New-ValidEntry -Major '18' -Minor '5' -EdbRevision 1))
    Assert-Throws { Test-ReleasePlan -PlanJson ($plan | ConvertTo-Json -Depth 6) } -MessagePattern "duplicate PostgreSQL major '18'"
}

Test-Case 'Test-ReleasePlan rejects entries mixing different upstream releases' {
    $e1 = New-ValidEntry
    $e2 = New-ValidEntry -Major '17' -Minor '10' -EdbRevision 1
    $e2['pglogicalVersion'] = '2.4.7'
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e1, $e2) | ConvertTo-Json -Depth 6) } -MessagePattern 'mixes different upstream releases'
}

Test-Case 'Test-ReleasePlan rejects an invalid upstream commit SHA' {
    $e = New-ValidEntry
    $e['upstreamCommitSha'] = 'short'
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern '40 hex'
}

Test-Case 'Test-ReleasePlan rejects an invalid upstream tag' {
    $e = New-ValidEntry
    $e['upstreamTag'] = 'v2.4.8'
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'invalid upstream tag'
}

Test-Case 'Test-ReleasePlan rejects an invalid windowsPackagingRevision' {
    $e = New-ValidEntry
    $e['windowsPackagingRevision'] = 0
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'windowsPackagingRevision'
}

Test-Case 'Test-ReleasePlan rejects a non-HTTPS URL' {
    $e = New-ValidEntry
    $e['edbArtifactUrl'] = "http://get.enterprisedb.com/postgresql/$($e['edbArtifactFilename'])"
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'must use https'
}

Test-Case 'Test-ReleasePlan rejects a non-EDB host' {
    $e = New-ValidEntry
    $e['edbArtifactUrl'] = "https://evil.example.com/postgresql/$($e['edbArtifactFilename'])"
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'host must be get.enterprisedb.com'
}

Test-Case 'Test-ReleasePlan rejects a filename that does not match the URL' {
    $e = New-ValidEntry
    $e['edbArtifactFilename'] = 'postgresql-18.4-9-windows-x64-binaries.zip'
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'does not match the URL filename'
}

Test-Case 'Test-ReleasePlan rejects an EDB major mismatch' {
    $e = New-ValidEntry -Major '18'
    $e['edbArtifactFilename'] = 'postgresql-17.4-2-windows-x64-binaries.zip'
    $e['edbArtifactUrl'] = "https://get.enterprisedb.com/postgresql/$($e['edbArtifactFilename'])"
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern "filename major '17' does not match postgresqlMajor '18'"
}

Test-Case 'Test-ReleasePlan rejects an EDB minor mismatch' {
    $e = New-ValidEntry -Major '18' -Minor '4'
    $e['edbArtifactFilename'] = 'postgresql-18.5-2-windows-x64-binaries.zip'
    $e['edbArtifactUrl'] = "https://get.enterprisedb.com/postgresql/$($e['edbArtifactFilename'])"
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern "minor '5' does not match postgresqlMinor '4'"
}

Test-Case 'Test-ReleasePlan rejects an EDB revision mismatch' {
    $e = New-ValidEntry -Major '18' -Minor '4' -EdbRevision 2
    $e['edbArtifactFilename'] = 'postgresql-18.4-3-windows-x64-binaries.zip'
    $e['edbArtifactUrl'] = "https://get.enterprisedb.com/postgresql/$($e['edbArtifactFilename'])"
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern "revision '3' does not match edbPackagingRevision '2'"
}

Test-Case 'Test-ReleasePlan rejects a buildVersion that does not match major.minor' {
    $e = New-ValidEntry -Major '18' -Minor '4'
    $e['postgresqlBuildVersion'] = '18.5'
    Assert-Throws { Test-ReleasePlan -PlanJson (@($e) | ConvertTo-Json -Depth 6) } -MessagePattern 'does not match major.minor'
}

Complete-Tests
