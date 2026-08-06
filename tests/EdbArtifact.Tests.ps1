<#
.SYNOPSIS
    Unit tests for the hardened EDB artifact resolution helpers: candidate
    URL validation, probe result classification (Available / NotFound /
    TransientFailure / InvalidResponse), retry + HEAD->range-GET fallback,
    full bounded revision scanning with gap handling, upper-bound safety,
    and PostgreSQL.org versions.json validation. The HTTP transport is
    injected as a stub — no live network calls.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

# ---------------------------------------------------------------------------
# Injectable transport stub: routes URL -> raw result; unregistered URLs are
# definitive 404s. Tracks calls for probe-order assertions.
# ---------------------------------------------------------------------------
$script:StubRoutes = @{}
$script:StubCalls = [System.Collections.Generic.List[string]]::new()
function Add-StubRoute {
    param([string]$Url, [hashtable]$Raw)
    $script:StubRoutes[$Url] = $Raw
}
function Invoke-StubTransport {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [switch]$UseRange
    )
    $script:StubCalls.Add("$Method`:$Url")
    if ($script:StubRoutes.ContainsKey($Url)) {
        $raw = $script:StubRoutes[$Url]
        # Identity validation compares the final URL against the candidate;
        # a route that does not explicitly model a redirect must resolve to
        # the candidate URL itself.
        if (-not $raw.FinalUrl) { $raw.FinalUrl = $Url }
        if ($raw.Chain.Count -eq 0) { $raw.Chain = @($Url) }
        return $raw
    }
    return @{ StatusCode = 404; ContentType = ''; Server = ''; FinalUrl = $Url; Chain = @($Url); ErrorCategory = 'None'; ErrorMessage = '' }
}
$script:EdbHttpTransport = 'Invoke-StubTransport'

function New-RawOk {
    param([int]$StatusCode = 200)
    return @{ StatusCode = $StatusCode; ContentType = 'application/zip'; Server = 'AmazonS3'; FinalUrl = ''; Chain = @(); ErrorCategory = 'None'; ErrorMessage = '' }
}
function New-RawRedirect {
    param([string]$FinalUrl)
    return @{ StatusCode = 302; ContentType = ''; Server = ''; FinalUrl = $FinalUrl; Chain = @($FinalUrl); ErrorCategory = 'None'; ErrorMessage = '' }
}
function New-RawS3Forbidden {
    return @{ StatusCode = 403; ContentType = 'application/xml'; Server = 'AmazonS3'; FinalUrl = ''; Chain = @(); ErrorCategory = 'None'; ErrorMessage = '' }
}

function Reset-Stub {
    $script:StubRoutes.Clear()
    $script:StubCalls.Clear()
}

$U = { param($Major, $Minor, $Rev) "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-$Rev-windows-x64-binaries.zip" }

# ---------------------------------------------------------------------------
# Assert-EdbCandidateUrl
# ---------------------------------------------------------------------------
Test-Case 'Assert-EdbCandidateUrl accepts a valid candidate' {
    Assert-True (Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 2)
}

Test-Case 'Assert-EdbCandidateUrl rejects malformed archive filenames' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/postgresql/postgresql-18.4-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 1 } -MessagePattern 'does not match the expected archive pattern'
}

Test-Case 'Assert-EdbCandidateUrl rejects major mismatch' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '17' -Minor '4' -Revision 2 } -MessagePattern 'major 18 does not match requested major 17'
}

Test-Case 'Assert-EdbCandidateUrl rejects minor mismatch' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '5' -Revision 2 } -MessagePattern 'minor 4 does not match requested minor 5'
}

Test-Case 'Assert-EdbCandidateUrl rejects revision mismatch' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 3 } -MessagePattern 'revision 2 does not match candidate revision 3'
}

Test-Case 'Assert-EdbCandidateUrl rejects non-https' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "http://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 2 } -MessagePattern 'must use https'
}

Test-Case 'Assert-EdbCandidateUrl rejects a non-EDB host' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://evil.example.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 2 } -MessagePattern 'host must be get.enterprisedb.com'
}

Test-Case 'Assert-EdbCandidateUrl rejects a wrong path' {
    Assert-Throws { Assert-EdbCandidateUrl -Url "https://get.enterprisedb.com/downloads/postgresql-18.4-2-windows-x64-binaries.zip" -Major '18' -Minor '4' -Revision 2 } -MessagePattern 'must begin with /postgresql/'
}

# ---------------------------------------------------------------------------
# Probe classification (ConvertTo-EdbProbeResult via Probe-EdbArtifactUrl)
# ---------------------------------------------------------------------------
Test-Case 'Probe classifies 2xx as Available' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-1-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 1 -MaxAttempts 1
    Assert-Equal 'Available' $r.Result
}

Test-Case 'Probe classifies 404 as NotFound' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 404)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'NotFound' $r.Result
}

Test-Case 'Probe classifies 410 as NotFound' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 410)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'NotFound' $r.Result
}

Test-Case 'Probe treats EDB S3 403 XML signature as NotFound' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawS3Forbidden)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'NotFound' $r.Result
}

Test-Case 'Probe rejects a 403 without the S3 absence signature (fail closed)' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url @{ StatusCode = 403; ContentType = 'text/html'; Server = 'nginx'; FinalUrl = $url; Chain = @($url); ErrorCategory = 'None'; ErrorMessage = '' }
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'InvalidResponse' $r.Result
}

Test-Case 'Probe classifies 503 as TransientFailure and exhausts retries' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 503)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 2
    Assert-Equal 'TransientFailure' $r.Result
    Assert-Equal 2 (@($script:StubCalls | Where-Object { $_ -like 'HEAD:*' }).Count)
}

Test-Case 'Probe classifies 429 as TransientFailure and exhausts retries' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 429)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 2
    Assert-Equal 'TransientFailure' $r.Result
}

Test-Case 'Probe classifies transport timeout as TransientFailure' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url @{ StatusCode = 0; ContentType = ''; Server = ''; FinalUrl = $url; Chain = @($url); ErrorCategory = 'Timeout'; ErrorMessage = 'timed out' }
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 2
    Assert-Equal 'TransientFailure' $r.Result
}

Test-Case 'Probe rejects a redirect to HTTP (fail closed)' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawRedirect "http://evil.example.com/zip")
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'InvalidResponse' $r.Result
}

Test-Case 'Probe rejects a redirect to an unrelated host (fail closed)' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawRedirect "https://cdn.evil.example.com/postgresql-18.4-9-windows-x64-binaries.zip")
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'InvalidResponse' $r.Result
}

Test-Case 'HEAD unsupported (405) falls back to ranged GET and succeeds' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 405)
    $getUrl = $url
    $script:StubRoutes[$url] = (New-RawOk 405)
    # Override GET behavior: when the stub sees a GET with UseRange on this
    # URL, it returns 206. The stub cannot see UseRange in the URL, so route
    # GET responses via a dedicated map keyed by method.
    $script:StubGetRoutes = @{ $url = (New-RawOk 206) }
    function Invoke-StubTransport2 {
        param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][string]$Url, [switch]$UseRange)
        $script:StubCalls.Add("$Method`:$Url")
        $raw = $null
        if ($Method -eq 'GET' -and $script:StubGetRoutes.ContainsKey($Url)) {
            $raw = $script:StubGetRoutes[$Url]
        }
        elseif ($script:StubRoutes.ContainsKey($Url)) {
            $raw = $script:StubRoutes[$Url]
        }
        if ($null -eq $raw) {
            return @{ StatusCode = 404; ContentType = ''; Server = ''; FinalUrl = $Url; Chain = @($Url); ErrorCategory = 'None'; ErrorMessage = '' }
        }
        if (-not $raw.FinalUrl) { $raw.FinalUrl = $Url }
        if ($raw.Chain.Count -eq 0) { $raw.Chain = @($Url) }
        return $raw
    }
    $script:EdbHttpTransport = 'Invoke-StubTransport2'
    try {
        $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
        Assert-Equal 'Available' $r.Result
        Assert-True (@($script:StubCalls | Where-Object { $_ -like 'GET:*' }).Count -ge 1) 'expected a GET fallback call'
    }
    finally {
        $script:EdbHttpTransport = 'Invoke-StubTransport'
    }
}

Test-Case 'Probe rejects an unexpected status (401) as InvalidResponse' {
    Reset-Stub
    $url = "https://get.enterprisedb.com/postgresql/postgresql-18.4-9-windows-x64-binaries.zip"
    Add-StubRoute $url (New-RawOk 401)
    $r = Probe-EdbArtifactUrl -Url $url -Major '18' -Minor '4' -Revision 9 -MaxAttempts 1
    Assert-Equal 'InvalidResponse' $r.Result
}

# ---------------------------------------------------------------------------
# Resolve-EdbArtifact: full bounded range scan
# ---------------------------------------------------------------------------
function Set-RevisionMap {
    <#
    .SYNOPSIS
        Routes revisions 1..Max of a major.minor to a per-revision status.
        $Map: hashtable revision -> status code; missing keys are 404.
    #>
    param([string]$Major, [string]$Minor, [hashtable]$Map, [int]$Max = 10)
    Reset-Stub
    for ($r = 1; $r -le $Max; $r++) {
        $url = "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-$r-windows-x64-binaries.zip"
        $status = if ($Map.ContainsKey($r)) { [int]$Map[$r] } else { 404 }
        if ($status -eq 403) {
            Add-StubRoute $url (New-RawS3Forbidden)
        } else {
            Add-StubRoute $url (New-RawOk $status)
        }
    }
}

Test-Case 'Resolve: revisions 1..2 available, 3 missing -> revision 2 (full range probed)' {
    Set-RevisionMap '18' '4' @{ 1 = 200; 2 = 200 }
    $a = Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 5 -MaxAttempts 1
    Assert-Equal 2 $a.revision
    Assert-Equal 'postgresql-18.4-2-windows-x64-binaries.zip' $a.filename
    # The full bounded range must be probed, not stopped at the first miss.
    Assert-Equal 5 (@($script:StubCalls | Where-Object { $_ -like 'HEAD:*' }).Count)
}

Test-Case 'Resolve: revision 1 available, 2 missing, 3 available -> revision 3 (gap handled)' {
    Set-RevisionMap '18' '4' @{ 1 = 200; 3 = 200 }
    $a = Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 5 -MaxAttempts 1
    Assert-Equal 3 $a.revision
}

Test-Case 'Resolve: revision 1 available, revision 2 transient 503 -> fail (never downgrade)' {
    Set-RevisionMap '18' '4' @{ 1 = 200; 2 = 503 }
    Assert-Throws { Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 5 -MaxAttempts 1 } -MessagePattern 'indeterminate after retries'
}

Test-Case 'Resolve: every candidate 404 -> no artifact' {
    Set-RevisionMap '18' '99' @{}
    $a = Resolve-EdbArtifact -Major '18' -Minor '99' -MaxRevision 5 -MaxAttempts 1
    Assert-True ($null -eq $a)
}

Test-Case 'Resolve: transient timeout at revision 2 -> fail closed' {
    Reset-Stub
    $url1 = "https://get.enterprisedb.com/postgresql/postgresql-18.4-1-windows-x64-binaries.zip"
    $url2 = "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip"
    Add-StubRoute $url1 (New-RawOk 200)
    Add-StubRoute $url2 @{ StatusCode = 0; ContentType = ''; Server = ''; FinalUrl = $url2; Chain = @($url2); ErrorCategory = 'Timeout'; ErrorMessage = 'timeout' }
    Assert-Throws { Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 5 -MaxAttempts 2 } -MessagePattern 'indeterminate'
}

Test-Case 'Resolve: highest available revision equals MaxRevision -> fail (boundary inconclusive)' {
    Set-RevisionMap '18' '4' @{ 1 = 200; 2 = 200; 3 = 200 }
    Assert-Throws { Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 3 -MaxAttempts 1 } -MessagePattern 'equal to the configured probe bound'
}

Test-Case 'Resolve: EDB S3 403 absence signature is treated as absence (gap probing continues)' {
    Reset-Stub
    $url1 = "https://get.enterprisedb.com/postgresql/postgresql-18.4-1-windows-x64-binaries.zip"
    $url3 = "https://get.enterprisedb.com/postgresql/postgresql-18.4-3-windows-x64-binaries.zip"
    Add-StubRoute $url1 (New-RawOk 200)
    Add-StubRoute $url3 (New-RawOk 200)
    # revision 2 -> S3 403 (observed EDB behavior for absent artifacts)
    $url2 = "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip"
    Add-StubRoute $url2 (New-RawS3Forbidden)
    $a = Resolve-EdbArtifact -Major '18' -Minor '4' -MaxRevision 5 -MaxAttempts 1
    Assert-Equal 3 $a.revision
}

# ---------------------------------------------------------------------------
# PostgreSQL.org versions.json validation
# ---------------------------------------------------------------------------
Test-Case 'PgOrg validation accepts a valid response' {
    $entries = ConvertTo-ValidatedPgOrgEntries -Response @(
        [pscustomobject]@{ major = 18; latestMinor = 4; supported = $true; eolDate = $null },
        [pscustomobject]@{ major = 17; latestMinor = 10; supported = $true; eolDate = $null }
    )
    Assert-Equal 2 @($entries).Count
}

Test-Case 'PgOrg validation rejects an empty response' {
    Assert-Throws { ConvertTo-ValidatedPgOrgEntries -Response @() } -MessagePattern 'no entries'
}

Test-Case 'PgOrg validation rejects duplicate majors' {
    Assert-Throws {
        ConvertTo-ValidatedPgOrgEntries -Response @(
            [pscustomobject]@{ major = 18; latestMinor = 4; supported = $true },
            [pscustomobject]@{ major = 18; latestMinor = 3; supported = $true }
        )
    } -MessagePattern 'duplicate major entry'
}

Test-Case 'PgOrg validation rejects a missing latestMinor' {
    Assert-Throws {
        ConvertTo-ValidatedPgOrgEntries -Response @([pscustomobject]@{ major = 18; supported = $true })
    } -MessagePattern 'latestMinor'
}

Test-Case 'PgOrg validation rejects a missing supported flag' {
    Assert-Throws {
        ConvertTo-ValidatedPgOrgEntries -Response @([pscustomobject]@{ major = 18; latestMinor = 4 })
    } -MessagePattern 'supported'
}

Test-Case 'Get-PgOrgEntry fails closed for a missing major' {
    # Stub Get-PgOrgVersions to avoid network access.
    function Get-PgOrgVersions {
        return @([pscustomobject]@{ major = 18; latestMinor = 4; supported = $true })
    }
    Assert-Throws { Get-PgOrgEntry -Major '17' } -MessagePattern 'not found'
    Assert-Equal '4' (Get-PgOrgEntry -Major '18').latestMinor
}

Complete-Tests
