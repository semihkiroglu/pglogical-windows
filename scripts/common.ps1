# common.ps1 - shared helpers for the pglogical-windows build tooling.
# This file is dot-sourced by the other scripts; it is not a standalone entry point.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Get-RepoRoot {
    <#
    .SYNOPSIS
        Resolves the repository root (the directory containing .github/pg-versions.json).
    #>
    $dir = $PSScriptRoot
    while ($null -ne $dir) {
        if (Test-Path (Join-Path $dir '.github/pg-versions.json')) {
            return $dir
        }
        $dir = Split-Path -Parent $dir
    }
    throw "Could not locate repository root (.github/pg-versions.json) above $PSScriptRoot"
}

function Get-ScriptPath {
    param([string]$Name)
    $p = Join-Path (Get-RepoRoot) "scripts/$Name"
    if (-not (Test-Path $p)) { throw "Required script not found: $p" }
    return $p
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WhatFor = 'configuration'
    )
    if (-not (Test-Path $Path)) {
        throw "Missing $WhatFor file: $Path"
    }
    try {
        return Get-Content -Raw -Path $Path | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in $WhatFor file '$Path': $($_.Exception.Message)"
    }
}

# Fixed project constants: this repo tracks exactly one upstream project with
# a stable tag format. These are not configuration — they never change per
# deployment, so they live here as module constants instead of in
# .github/pg-versions.json (which holds only what actually varies: the
# release baseline and the PostgreSQL major list).
$script:UpstreamRepository = '2ndQuadrant/pglogical'
$script:UpstreamTagPattern = '^REL[0-9]+_[0-9]+_[0-9]+$'

function Import-VersionConfig {
    <#
    .SYNOPSIS
        Loads .github/pg-versions.json and validates its shape.
    #>
    $cfg = Read-JsonFile -Path (Join-Path (Get-RepoRoot) '.github/pg-versions.json') -WhatFor 'version'
    if (-not $cfg.releaseBaseline) {
        throw '.github/pg-versions.json: missing "releaseBaseline"'
    }
    if (-not $cfg.postgresqlMajors -or @($cfg.postgresqlMajors).Count -eq 0) {
        throw '.github/pg-versions.json: missing or empty "postgresqlMajors" array'
    }
    foreach ($m in @($cfg.postgresqlMajors)) {
        if ($m -notmatch '^\d+$') {
            throw ".github/pg-versions.json: postgresqlMajors contains non-numeric value '$m'"
        }
    }
    return $cfg
}

function Get-UpstreamRepository {
    <#
    .SYNOPSIS
        Returns the fixed upstream repository (owner/name) this project builds.
    #>
    return $script:UpstreamRepository
}

function Get-UpstreamTagPattern {
    <#
    .SYNOPSIS
        Returns the fixed upstream release tag pattern (regex source).
    #>
    return $script:UpstreamTagPattern
}

# ---------------------------------------------------------------------------
# Process execution
# ---------------------------------------------------------------------------

function Invoke-Native {
    <#
    .SYNOPSIS
        Runs a native command, captures output, and throws on a non-zero exit
        code with a readable message.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 3600
    )
    if (-not (Test-Path $FilePath)) {
        throw "Executable not found: $FilePath"
    }
    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
    }
    try {
        $out = [System.Collections.Generic.List[string]]::new()
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { throw "Failed to start process: $FilePath" }
        # The redirected streams only exist after Start(); read them asynchronously.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { }
            throw "Command timed out after ${TimeoutSeconds}s: $FilePath $($ArgumentList -join ' ')"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) {
            $msg = "Command failed with exit code $($proc.ExitCode):`n  $FilePath $($ArgumentList -join ' ')`n"
            if ($stdout) { $msg += "STDOUT:`n$stdout`n" }
            if ($stderr) { $msg += "STDERR:`n$stderr`n" }
            throw $msg
        }
        # Emit the child's output to the host stream (visible in logs) rather
        # than returning it: scripts that are invoked as `$x = & script.ps1`
        # must not have native-command output leak into their captured value.
        $combined = "$stdout`n$stderr".Trim()
        if ($combined) { Write-Host $combined }
    }
    finally {
        foreach ($key in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key])
        }
    }
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Upstream tag / version handling
# ---------------------------------------------------------------------------

function ConvertTo-PgLogicalVersion {
    <#
    .SYNOPSIS
        Converts an upstream tag such as REL2_4_8 to a dotted version 2.4.8.
    #>
    param([Parameter(Mandatory = $true)][string]$Tag)
    $m = [regex]::Match($Tag, '^REL([0-9]+)_([0-9]+)_([0-9]+)$')
    if (-not $m.Success) {
        throw "Tag '$Tag' does not match the expected upstream release pattern ^REL[0-9]+_[0-9]+_[0-9]+$"
    }
    return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
}

function ConvertFrom-PgLogicalVersion {
    <#
    .SYNOPSIS
        Converts a dotted version 2.4.8 back to the upstream tag REL2_4_8.
    #>
    param([Parameter(Mandatory = $true)][string]$Version)
    $m = [regex]::Match($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)$')
    if (-not $m.Success) {
        throw "Version '$Version' does not match the expected form N.N.N"
    }
    return "REL$($m.Groups[1].Value)_$($m.Groups[2].Value)_$($m.Groups[3].Value)"
}

function Get-LocalReleaseTag {
    <#
    .SYNOPSIS
        Builds the local release tag, e.g. pglogical-2.4.8-pg14-windows.1
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][int]$PackagingRevision,
        [Parameter(Mandatory = $true)][string]$PgMajor
    )
    return "pglogical-$Version-pg$PgMajor-windows.$PackagingRevision"
}

function Resolve-UpstreamSource {
    <#
    .SYNOPSIS
        Resolves the upstream pglogical checkout directory for a release tag,
        cloning it when -SourceDir is not supplied, and verifies
        -ExpectedCommitSha against the final resolved checkout whenever it is
        provided.

    .DESCRIPTION
        The expected-SHA verification runs for BOTH supplied checkouts
        (-SourceDir, implying -SkipClone) and freshly cloned ones: the caller
        must never build from a checkout whose HEAD differs from the resolved
        upstream commit. The expected and actual SHAs are trimmed and compared
        case-insensitively; a mismatch fails immediately with an actionable
        error naming both values.

    .PARAMETER UpstreamRepository
        Upstream repository in owner/name form, e.g. 2ndQuadrant/pglogical.

    .PARAMETER UpstreamTag
        Upstream release tag to clone, e.g. REL2_4_8.

    .PARAMETER WorkDir
        Directory the clone is created under (upstream/ subdirectory).
        Required when cloning.

    .PARAMETER SourceDir
        Use an existing checkout instead of cloning (implies -SkipClone).

    .PARAMETER CloneUrl
        Clone URL override. Defaults to
        https://github.com/<UpstreamRepository>.git; used by the unit tests
        to clone from a local fixture repository.

    .PARAMETER ExpectedCommitSha
        When non-empty, the resolved checkout's HEAD must match this exact
        commit SHA. Empty (the default) skips verification, preserving the
        CI build-smoke behavior.

    .PARAMETER SkipClone
        Do not clone upstream; requires -SourceDir.

    .OUTPUTS
        The resolved absolute SourceDir.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UpstreamRepository,
        [Parameter(Mandatory = $true)][string]$UpstreamTag,
        [string]$WorkDir,
        [string]$SourceDir,
        [string]$CloneUrl,
        [string]$ExpectedCommitSha = '',
        [switch]$SkipClone
    )

    if ($SourceDir) {
        $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
        if (-not (Test-Path (Join-Path $SourceDir 'Makefile'))) { throw "-SourceDir does not look like a pglogical checkout: $SourceDir" }
    }
    elseif (-not $SkipClone) {
        if (-not $WorkDir) { throw 'WorkDir is required when cloning upstream.' }
        $SourceDir = Join-Path $WorkDir 'upstream'
        if (Test-Path (Join-Path $SourceDir '.git')) {
            Write-Host "Reusing existing clone at $SourceDir (delete it to force a fresh clone)"
        }
        else {
            if (-not $CloneUrl) { $CloneUrl = "https://github.com/$UpstreamRepository.git" }
            $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
            if (-not $gitExe) { throw 'git executable not found on PATH; required to clone the upstream source.' }
            Write-Host "Cloning $UpstreamRepository at tag $UpstreamTag"
            Invoke-Native -FilePath $gitExe -ArgumentList @('clone', '--depth', '1', '--branch', $UpstreamTag, $CloneUrl, $SourceDir)
        }
    }
    else {
        throw 'Either -SourceDir or -SkipClone without -SourceDir requires an existing checkout.'
    }

    if ($ExpectedCommitSha) {
        $expected = $ExpectedCommitSha.Trim()
        $headSha = (& git -C $SourceDir rev-parse HEAD 2>$null)
        if ($null -eq $headSha -or [string]::IsNullOrWhiteSpace($headSha)) {
            throw "Could not read HEAD commit from $SourceDir via 'git rev-parse HEAD'; expected commit $expected for upstream tag $UpstreamTag."
        }
        $headSha = $headSha.Trim()
        if (-not [string]::Equals($headSha, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Upstream commit mismatch for tag ${UpstreamTag}: expected commit $expected but checkout HEAD is $headSha. The upstream tag may have moved; re-resolve the upstream release before building."
        }
        Write-Host "Upstream commit verified: $headSha"
    }
    else {
        $headSha = (& git -C $SourceDir rev-parse HEAD 2>$null)
        if ($headSha) { Write-Host "Upstream commit: $($headSha.Trim())" }
    }
    return $SourceDir
}

function Get-ReleasePlan {
    <#
    .SYNOPSIS
        Computes the idempotent release plan for one upstream pglogical
        version across the configured PostgreSQL majors, taking the exact
        EDB artifact identity into account.

    .DESCRIPTION
        For every major:
          * No local release for (version, major)  -> plan windows.1.
          * The latest local release records the same EDB artifact filename
            as the currently resolved artifact -> covered, no action.
          * The resolved artifact differs -> plan the next packaging
            revision (highest existing revision + 1) for that major only.
        Fail-closed conditions (throw, no partial plan):
          * A major has no resolved EDB artifact identity.
          * The latest local release records no EDB artifact filename.
          * The resolved artifact is OLDER (minor/revision tuple) than the
            artifact the latest release was built from.

    .PARAMETER Version
        Upstream pglogical version, e.g. 2.4.8.

    .PARAMETER UpstreamTag
        Upstream release tag, e.g. REL2_4_8.

    .PARAMETER CommitSha
        Resolved upstream commit SHA for the tag.

    .PARAMETER Majors
        Configured PostgreSQL majors to consider.

    .PARAMETER Artifacts
        IDictionary mapping major -> resolved EDB artifact identity
        (as returned by Resolve-EdbArtifact).

    .PARAMETER LocalReleases
        Local repository releases (objects with .tag_name and .body).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$UpstreamTag,
        [Parameter(Mandatory = $true)][string]$CommitSha,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Majors,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Artifacts,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$LocalReleases
    )

    $versionPattern = "^pglogical-$([regex]::Escape($Version))-pg([0-9]+)-windows\.([0-9]+)$"
    $byMajor = @{}
    foreach ($release in $LocalReleases) {
        $m = [regex]::Match([string]$release.tag_name, $versionPattern)
        if (-not $m.Success) { continue }
        $major = $m.Groups[1].Value
        if (-not $byMajor.ContainsKey($major)) {
            $byMajor[$major] = [System.Collections.Generic.List[object]]::new()
        }
        $byMajor[$major].Add([pscustomobject]@{
            tag_name = [string]$release.tag_name
            body     = [string]$release.body
            revision = [int]$m.Groups[2].Value
        })
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($major in @($Majors | Sort-Object { [int]$_ })) {
        $key = [string]$major
        $artifact = $Artifacts[$key]
        if (-not $artifact) {
            throw "Cannot plan a release for PostgreSQL ${key}: no exact EDB artifact identity was resolved (fail closed)."
        }
        if (-not $artifact.filename -or -not $artifact.url) {
            throw "Cannot plan a release for PostgreSQL ${key}: the resolved EDB artifact identity is incomplete (filename/url missing; fail closed)."
        }

        $existing = @($byMajor[$key] | Sort-Object revision)
        if ($existing.Count -eq 0) {
            Write-Host "No local release for pglogical $Version / PostgreSQL $key; planning windows.1 against $($artifact.filename)"
            $plan.Add([pscustomobject]@{
                pglogicalVersion          = $Version
                upstreamTag               = $UpstreamTag
                upstreamCommitSha         = $CommitSha
                postgresqlMajor           = $key
                postgresqlMinor           = $artifact.minor
                postgresqlBuildVersion    = "$($artifact.major).$($artifact.minor)"
                windowsPackagingRevision  = 1
                edbPackagingRevision      = $artifact.revision
                edbArtifactFilename       = $artifact.filename
                edbArtifactUrl            = $artifact.url
                localTag                  = Get-LocalReleaseTag -Version $Version -PackagingRevision 1 -PgMajor $key
            })
            continue
        }

        $newest = $existing[-1]
        $recordedFilename = Get-EdbArtifactFromReleaseBody -Body $newest.body
        if (-not $recordedFilename) {
            throw "Release $($newest.tag_name) for pglogical $Version / PostgreSQL $key records no EDB binaries archive filename; cannot verify EDB artifact coverage. Recreate the release with the current release tooling (fail closed)."
        }
        if ($recordedFilename -eq $artifact.filename) {
            Write-Host "Already packaged against the current EDB artifact: $($newest.tag_name) ($recordedFilename)"
            continue
        }

        $recordedInfo = ConvertFrom-EdbArtifactFilename -Filename $recordedFilename
        $resolvedInfo = ConvertFrom-EdbArtifactFilename -Filename $artifact.filename
        if (-not $recordedInfo -or -not $resolvedInfo) {
            throw "Cannot parse EDB artifact identities (recorded '$recordedFilename' in $($newest.tag_name), resolved '$($artifact.filename)'); refusing to plan a rebuild (fail closed)."
        }
        $recordedMinor = [int]$recordedInfo.minor
        $resolvedMinor = [int]$resolvedInfo.minor
        if ($resolvedMinor -lt $recordedMinor -or ($resolvedMinor -eq $recordedMinor -and $resolvedInfo.revision -lt $recordedInfo.revision)) {
            throw "Resolved EDB artifact $($artifact.filename) is older than the artifact recorded in $($newest.tag_name) ($recordedFilename); refusing to rebuild against an older artifact (fail closed)."
        }

        $nextRevision = [int](($existing | Measure-Object -Property revision -Maximum).Maximum + 1)
        Write-Host "EDB artifact changed for pglogical $Version / PostgreSQL ${key}: $recordedFilename -> $($artifact.filename); planning windows.$nextRevision"
        $plan.Add([pscustomobject]@{
            pglogicalVersion          = $Version
            upstreamTag               = $UpstreamTag
            upstreamCommitSha         = $CommitSha
            postgresqlMajor           = $key
            postgresqlMinor           = $artifact.minor
            postgresqlBuildVersion    = "$($artifact.major).$($artifact.minor)"
            windowsPackagingRevision  = $nextRevision
            edbPackagingRevision      = $artifact.revision
            edbArtifactFilename       = $artifact.filename
            edbArtifactUrl            = $artifact.url
            localTag                  = Get-LocalReleaseTag -Version $Version -PackagingRevision $nextRevision -PgMajor $key
        })
    }
    return @($plan)
}

# ---------------------------------------------------------------------------
# GitHub API access (token from environment, no secrets on disk)
# ---------------------------------------------------------------------------

function Get-GitHubHeaders {
    $token = $env:GITHUB_TOKEN
    if (-not $token) { $token = $env:GH_TOKEN }
    if (-not $token) {
        throw 'No GitHub token available. Set GITHUB_TOKEN or GH_TOKEN in the environment.'
    }
    return @{
        'Accept'               = 'application/vnd.github+json'
        'Authorization'        = "Bearer $token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        GETs a GitHub REST endpoint with pagination support.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 60
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $page = 0
    do {
        $page++
        $sep = if ($Url.Contains('?')) { '&' } else { '?' }
        $paged = "$Url${sep}per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $paged -Headers (Get-GitHubHeaders) -Method Get -TimeoutSec $TimeoutSeconds
        if ($null -eq $response -or @($response).Count -eq 0) { break }
        foreach ($item in @($response)) { $results.Add($item) }
        if (@($response).Count -lt 100) { break }
    } while ($true)
    return @($results)
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Visual Studio toolchain discovery (local builds only; CI provides the env)
# ---------------------------------------------------------------------------

function Get-VsDevCmdPath {
    <#
    .SYNOPSIS
        Locates vcvars64.bat using vswhere. Returns $null when not found.
    #>
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $installDir = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installDir) { return $null }
    $vcvars = Join-Path $installDir 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $vcvars) { return $vcvars }
    return $null
}

# ---------------------------------------------------------------------------
# PostgreSQL.org versions.json — authoritative source for latest minors
# ---------------------------------------------------------------------------

function ConvertTo-ValidatedPgOrgEntries {
    <#
    .SYNOPSIS
        Validates a parsed PostgreSQL.org versions.json response and returns
        the entries. Malformed responses, missing required properties
        (major/latestMinor/supported), and duplicate major entries fail
        closed. Extracted from Get-PgOrgVersions so the validation is
        unit-testable without network access.
    #>
    param($Response)
    $entries = @($Response)
    if ($entries.Count -eq 0) {
        throw 'PostgreSQL.org versions.json returned no entries; refusing to treat an empty response as valid (fail closed).'
    }
    $seen = @{}
    foreach ($e in $entries) {
        if ($null -eq $e.major) { throw 'PostgreSQL.org versions.json contains an entry without the required "major" property.' }
        $key = [string]$e.major
        if ($seen.ContainsKey($key)) { throw "PostgreSQL.org versions.json contains duplicate major entry '$key'." }
        $seen[$key] = $true
        if ($null -eq $e.latestMinor) { throw "PostgreSQL.org versions.json major '$key' is missing the required ""latestMinor"" property." }
        if ($null -eq $e.supported) { throw "PostgreSQL.org versions.json major '$key' is missing the required ""supported"" property." }
        $eolProp = $e.PSObject.Properties['eolDate']
        if ($null -ne $eolProp -and $eolProp.Value -and $e.supported) {
            Write-Host "PostgreSQL.org versions.json major '$key' is marked supported with a non-null eolDate; accepting (support-state data inconsistency is tolerated only when the supported flag is authoritative)."
        }
    }
    return $entries
}

function Get-PgOrgVersions {
    <#
    .SYNOPSIS
        Fetches https://www.postgresql.org/versions.json, validates the
        response structure (see ConvertTo-ValidatedPgOrgEntries), and returns
        the parsed array. Each entry: major (int), latestMinor (int),
        supported (bool), eolDate (string or null).
    #>
    Write-Host "Fetching PostgreSQL.org versions.json"
    $response = Invoke-RestMethod -Uri 'https://www.postgresql.org/versions.json' -Method Get -TimeoutSec 30
    return ConvertTo-ValidatedPgOrgEntries -Response $response
}

function Get-PgOrgEntry {
    <#
    .SYNOPSIS
        Returns the validated PostgreSQL.org versions.json entry for one
        major. Throws when the major is missing or duplicated.
    #>
    param([Parameter(Mandatory = $true)][string]$Major)
    $entries = Get-PgOrgVersions
    $match = @($entries | Where-Object { [string]$_.major -eq $Major })
    if ($match.Count -eq 0) { throw "PostgreSQL major $Major not found in PostgreSQL.org versions.json (fail closed)." }
    if ($match.Count -gt 1) { throw "PostgreSQL.org versions.json contains duplicate entries for major $Major; refusing to pick one (fail closed)." }
    return $match[0]
}

function Get-EdbBinaryUrl {
    <#
    .SYNOPSIS
        Derives the EDB Windows binaries URL for a given major + minor +
        packaging revision. The returned URL is validated against the
        candidate contract by Assert-EdbCandidateUrl before any request.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [ValidateRange(1, 50)][int]$Revision = 1
    )
    return "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-$Revision-windows-x64-binaries.zip"
}

# The single EDB-controlled host for Windows binaries artifacts.
$script:EdbHost = 'get.enterprisedb.com'

# Injectable raw HTTP transport used by the EDB probe. Production default is
# Invoke-EdbHttpRaw; unit tests replace this with a stub that never touches
# the network. A transport stub is a function returning a raw result hashtable
# with the same shape as Invoke-EdbHttpRaw.
$script:EdbHttpTransport = $null

function Assert-EdbCandidateUrl {
    <#
    .SYNOPSIS
        Validates that a URL is a well-formed EDB Windows x64 binaries
        candidate for exactly the requested major/minor/revision: scheme is
        https, host is get.enterprisedb.com, path begins with /postgresql/,
        and the filename matches the archive pattern with matching
        major/minor/revision. Returns $true; throws (fail closed) otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [Parameter(Mandatory = $true)][int]$Revision
    )
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "Malformed EDB candidate URL: $Url"
    }
    if ($uri.Scheme -ne 'https') { throw "EDB candidate URL must use https: $Url" }
    if ($uri.Host -ne $script:EdbHost) { throw "EDB candidate URL host must be $($script:EdbHost): $Url" }
    if (-not $uri.AbsolutePath.StartsWith('/postgresql/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "EDB candidate URL path must begin with /postgresql/: $Url"
    }
    $filename = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    $parsed = ConvertFrom-EdbArtifactFilename -Filename $filename
    if (-not $parsed) { throw "EDB candidate filename does not match the expected archive pattern: $filename" }
    if ($parsed.major -ne [string]$Major) { throw "EDB candidate filename major $($parsed.major) does not match requested major $Major" }
    if ($parsed.minor -ne [string]$Minor) { throw "EDB candidate filename minor $($parsed.minor) does not match requested minor $Minor" }
    if ($parsed.revision -ne $Revision) { throw "EDB candidate filename revision $($parsed.revision) does not match candidate revision $Revision" }
    return $true
}

function Invoke-EdbHttpRaw {
    <#
    .SYNOPSIS
        Performs ONE raw HTTP request (HEAD or ranged GET) against an EDB
        candidate URL with manual redirect handling. Never throws for
        HTTP-level outcomes; transport failures are classified into an
        ErrorCategory. This is the production default transport and is
        replaced by a stub in unit tests.

    .OUTPUTS
        Hashtable: @{ StatusCode; ContentType; Server; FinalUrl; Chain;
                     ErrorCategory; ErrorMessage }
        ErrorCategory: None | Timeout | Dns | Tls | Connection | Protocol | Other
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('HEAD', 'GET')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [switch]$UseRange,
        [int]$TimeoutSeconds = 20
    )
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $current = $Url
        $chain = [System.Collections.Generic.List[string]]::new()
        for ($hop = 0; $hop -le 5; $hop++) {
            $chain.Add($current)
            $httpMethod = if ($Method -eq 'HEAD') { [System.Net.Http.HttpMethod]::Head } else { [System.Net.Http.HttpMethod]::Get }
            $req = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $current)
            if ($UseRange) { $req.Headers.TryAddWithoutValidation('Range', 'bytes=0-0') | Out-Null }
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $status = [int]$resp.StatusCode
            $location = $null
            if ($resp.Headers.Location) { $location = [string]$resp.Headers.Location }
            $contentType = ''
            if ($resp.Content.Headers.ContentType) { $contentType = [string]$resp.Content.Headers.ContentType }
            $server = ''
            if ($resp.Headers.Server) { $server = (($resp.Headers.Server | ForEach-Object { $_.Product.ToString() }) -join ',') }
            if ($status -ge 300 -and $status -lt 400 -and $location) {
                $target = $null
                if ([Uri]::TryCreate($location, [UriKind]::Absolute, [ref]$target)) {
                    $current = [string]$target
                }
                elseif ([Uri]::TryCreate([Uri]$current, $location, [ref]$target)) {
                    $current = [string]$target
                }
                else {
                    $resp.Dispose(); $req.Dispose()
                    return @{ StatusCode = $status; ContentType = ''; Server = ''; FinalUrl = $current; Chain = @($chain); ErrorCategory = 'Protocol'; ErrorMessage = "Malformed redirect Location header: $location" }
                }
                $resp.Dispose(); $req.Dispose()
                continue
            }
            $resp.Dispose(); $req.Dispose()
            return @{ StatusCode = $status; ContentType = $contentType; Server = $server; FinalUrl = $current; Chain = @($chain); ErrorCategory = 'None'; ErrorMessage = '' }
        }
        return @{ StatusCode = 0; ContentType = ''; Server = ''; FinalUrl = $current; Chain = @($chain); ErrorCategory = 'Protocol'; ErrorMessage = 'Redirect limit exceeded (more than 5 hops)' }
    }
    catch {
        $category = 'Other'
        $message = $_.Exception.Message
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($_.Exception -is [System.Threading.Tasks.TaskCanceledException]) {
            $category = 'Timeout'
        }
        elseif ($inner -is [System.Net.Sockets.SocketException]) {
            if ($inner.SocketErrorCode -eq [System.Net.Sockets.SocketError]::HostNotFound -or $inner.SocketErrorCode -eq [System.Net.Sockets.SocketError]::NoData) {
                $category = 'Dns'
            } else {
                $category = 'Connection'
            }
        }
        elseif ($inner -is [System.Security.Authentication.AuthenticationException]) {
            $category = 'Tls'
        }
        elseif ($_.Exception -is [System.Net.Http.HttpRequestException]) {
            $category = 'Connection'
        }
        return @{ StatusCode = 0; ContentType = ''; Server = ''; FinalUrl = $Url; Chain = @($Url); ErrorCategory = $category; ErrorMessage = $message }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertTo-EdbProbeResult {
    <#
    .SYNOPSIS
        Classifies one raw transport result into the probe result model:
        Available | NotFound | TransientFailure | InvalidResponse |
        HeadUnsupported. Redirect/identity validation happens here: any
        redirect (observed EDB behavior has none) or final-URL deviation
        from the candidate fails closed as InvalidResponse.
    #>
    param(
        [Parameter(Mandatory = $true)]$Raw,
        [Parameter(Mandatory = $true)][string]$Url
    )
    if ($Raw.ErrorCategory -ne 'None') {
        return @{ Result = 'TransientFailure'; StatusCode = 0; Reason = "transport $($Raw.ErrorCategory): $($Raw.ErrorMessage)" }
    }
    if ([string]$Raw.FinalUrl -ne $Url) {
        return @{ Result = 'InvalidResponse'; StatusCode = $Raw.StatusCode; Reason = "final URL '$($Raw.FinalUrl)' differs from candidate '$Url'; redirects are not observed on the EDB host and are rejected (fail closed)" }
    }
    $code = [int]$Raw.StatusCode
    if ($code -ge 200 -and $code -lt 300) {
        return @{ Result = 'Available'; StatusCode = $code; Reason = '' }
    }
    if ($code -eq 404 -or $code -eq 410) {
        return @{ Result = 'NotFound'; StatusCode = $code; Reason = "HTTP $code" }
    }
    if ($code -eq 405 -or $code -eq 501) {
        return @{ Result = 'HeadUnsupported'; StatusCode = $code; Reason = "HTTP $code (HEAD unsupported)" }
    }
    if ($code -eq 408 -or $code -eq 425 -or $code -eq 429 -or ($code -ge 500 -and $code -le 599)) {
        return @{ Result = 'TransientFailure'; StatusCode = $code; Reason = "HTTP $code" }
    }
    if ($code -eq 403) {
        # Observed EDB/CDN behavior (verified Aug 2026): missing artifacts
        # return 403 with an S3 AccessDenied XML error (server: AmazonS3),
        # never 404. Treat that exact signature as the host's definitive
        # absence response; any other 403 fails closed.
        if ($Raw.ContentType -match 'application/xml' -and $Raw.Server -match 'AmazonS3') {
            return @{ Result = 'NotFound'; StatusCode = 403; Reason = 'HTTP 403 with the observed EDB S3 AccessDenied signature (definitive absence on the EDB host)' }
        }
        return @{ Result = 'InvalidResponse'; StatusCode = 403; Reason = 'HTTP 403 without the EDB S3 absence signature; refusing to classify (fail closed)' }
    }
    return @{ Result = 'InvalidResponse'; StatusCode = $code; Reason = "unexpected HTTP status $code" }
}

function Probe-EdbArtifactUrl {
    <#
    .SYNOPSIS
        Probes one EDB candidate URL and returns the classified result
        (Available | NotFound | TransientFailure | InvalidResponse).
        Transient failures are retried a bounded number of times with short
        backoff; when HEAD is explicitly unsupported (405/501), a minimal
        ranged GET (Range: bytes=0-0) fallback is used with the same
        validation and retry behavior. The candidate URL is validated before
        the first request.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [Parameter(Mandatory = $true)][int]$Revision,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3
    )
    Assert-EdbCandidateUrl -Url $Url -Major $Major -Minor $Minor -Revision $Revision | Out-Null
    $transport = if ($script:EdbHttpTransport) { $script:EdbHttpTransport } else { 'Invoke-EdbHttpRaw' }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $raw = & $transport -Method 'HEAD' -Url $Url
        $result = ConvertTo-EdbProbeResult -Raw $raw -Url $Url
        if ($result.Result -eq 'TransientFailure') {
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (1 * $attempt) }
            continue
        }
        if ($result.Result -ne 'HeadUnsupported') { return $result }
        # HEAD explicitly unsupported (non-transient): ranged GET fallback.
        for ($getAttempt = 1; $getAttempt -le $MaxAttempts; $getAttempt++) {
            $raw = & $transport -Method 'GET' -UseRange -Url $Url
            $result = ConvertTo-EdbProbeResult -Raw $raw -Url $Url
            if ($result.Result -eq 'TransientFailure') {
                if ($getAttempt -lt $MaxAttempts) { Start-Sleep -Seconds (1 * $getAttempt) }
                continue
            }
            return $result
        }
        return $result
    }
    return @{ Result = 'TransientFailure'; StatusCode = 0; Reason = "transient failures exhausted after $MaxAttempts attempts" }
}

function Resolve-EdbArtifact {
    <#
    .SYNOPSIS
        Resolves the exact EDB Windows x64 binaries artifact for a
        PostgreSQL major/minor by probing the ENTIRE bounded revision range
        on the EDB-controlled host and returning the highest conclusively
        available revision.

    .DESCRIPTION
        The minor comes from https://www.postgresql.org/versions.json (the
        authoritative source for latest supported minors); the EDB packaging
        revision is heuristic availability discovery against the
        EDB-controlled download host — NOT an authoritative EDB manifest.
        The full range 1..MaxRevision is probed (gaps are allowed), any
        indeterminate result fails the resolution (no fallback to an older
        revision), and a highest-available revision equal to MaxRevision
        fails because the upper boundary is inconclusive. No artifact is
        returned only when every candidate was conclusively absent.

    .OUTPUTS
        A PSCustomObject with .major, .minor, .revision, .filename and .url,
        or $null when no artifact conclusively exists.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [string]$Minor,
        [ValidateRange(1, 50)][int]$MaxRevision = 10,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3
    )
    if (-not $Minor) {
        $entry = Get-PgOrgEntry -Major $Major
        $Minor = [string]$entry.latestMinor
    }

    $highest = $null
    for ($revision = 1; $revision -le $MaxRevision; $revision++) {
        $url = Get-EdbBinaryUrl -Major $Major -Minor $Minor -Revision $revision
        $result = Probe-EdbArtifactUrl -Url $url -Major $Major -Minor $Minor -Revision $revision -MaxAttempts $MaxAttempts
        if ($result.Result -eq 'Available') {
            $highest = [pscustomobject]@{
                major    = $Major
                minor    = $Minor
                revision = $revision
                filename = [System.IO.Path]::GetFileName([Uri]$url)
                url      = $url
            }
            Write-Host "EDB artifact revision $revision available: $($highest.filename)"
        }
        elseif ($result.Result -eq 'NotFound') {
            Write-Host "EDB artifact revision $revision absent: $url ($($result.Reason))"
        }
        elseif ($result.Result -eq 'TransientFailure') {
            throw "EDB artifact probe for $url remained indeterminate after retries ($($result.Reason)); refusing to fall back to an older revision (fail closed)."
        }
        else {
            throw "EDB artifact probe for $url returned an invalid response ($($result.Reason)); failing closed."
        }
    }

    if (-not $highest) {
        Write-Host "No EDB Windows x64 binaries artifact found for PostgreSQL $Major.$Minor on get.enterprisedb.com (every candidate revision 1..$MaxRevision conclusively absent)."
        return $null
    }
    if ($highest.revision -eq $MaxRevision) {
        throw "The highest available EDB revision for PostgreSQL $Major.$Minor is $MaxRevision, equal to the configured probe bound; a higher revision may exist beyond the bound, so this resolution is inconclusive (fail closed). Raise MaxRevision if this is a false alarm."
    }
    return $highest
}

function ConvertFrom-EdbArtifactFilename {
    <#
    .SYNOPSIS
        Parses an EDB Windows x64 binaries filename of the form
        postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip into
        its components. Returns $null when the filename does not match.
    #>
    param([string]$Filename)
    if ([string]::IsNullOrWhiteSpace($Filename)) { return $null }
    $m = [regex]::Match($Filename.Trim(), '^postgresql-([0-9]+)\.([0-9]+)-([0-9]+)-windows-x64-binaries\.zip$')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{
        major    = $m.Groups[1].Value
        minor    = $m.Groups[2].Value
        revision = [int]$m.Groups[3].Value
    }
}

function Get-EdbArtifactFromReleaseBody {
    <#
    .SYNOPSIS
        Extracts the EDB binaries archive filename recorded in a release
        body. Accepts both the current provenance row ("EDB binaries
        archive") and the legacy row ("EDB binaries SHA-256" whose value
        embeds "<sha256>  <filename>"). Returns $null when neither row
        records a filename.
    #>
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    foreach ($line in ($Body -split '\r?\n')) {
        if ($line -match '^\|\s*EDB binaries archive\s*\|\s*`([^`]+)`\s*\|') {
            return $matches[1].Trim()
        }
    }
    foreach ($line in ($Body -split '\r?\n')) {
        if ($line -match '^\|\s*EDB binaries SHA-256\s*\|\s*`([^`]+)`\s*\|') {
            $tokens = @($matches[1].Trim() -split '\s+')
            if ($tokens.Count -ge 2) { return $tokens[-1].Trim() }
        }
    }
    return $null
}

function Get-PackageZipName {
    <#
    .SYNOPSIS
        Computes the exact-version package ZIP name for a plan entry:
        pglogical-<version>-pg<major>.<minor>-edb<revision>-windows-x64.zip.
        The name identifies the exact PostgreSQL build version and EDB
        packaging revision, unlike the major-oriented release tag.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PglogicalVersion,
        [Parameter(Mandatory = $true)][string]$PostgresqlMajor,
        [Parameter(Mandatory = $true)][string]$PostgresqlMinor,
        [Parameter(Mandatory = $true)][int]$EdbPackagingRevision
    )
    return "pglogical-$PglogicalVersion-pg$PostgresqlMajor.$PostgresqlMinor-edb$EdbPackagingRevision-windows-x64.zip"
}

function New-BuildInfo {
    <#
    .SYNOPSIS
        Generates the BUILD-INFO.json content for a package, using ONLY the
        validated/pinned plan entry plus the project-calculated EDB archive
        SHA-256. Never rediscovers any version while packaging. Deterministic
        property order and stable encoding (UTF-8, no BOM).
    #>
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$EdbArtifactCalculatedSha256,
        [string]$Architecture = 'x64',
        [string]$Configuration = 'Release'
    )
    $info = [ordered]@{
        pglogicalVersion             = [string]$Entry.pglogicalVersion
        upstreamRepository           = (Get-UpstreamRepository)
        upstreamTag                  = [string]$Entry.upstreamTag
        upstreamCommitSha            = [string]$Entry.upstreamCommitSha
        postgresqlCompatibilityMajor = [string]$Entry.postgresqlMajor
        postgresqlBuildVersion       = [string]$Entry.postgresqlBuildVersion
        edbPackagingRevision         = [int]$Entry.edbPackagingRevision
        edbArtifactFilename          = [string]$Entry.edbArtifactFilename
        edbArtifactUrl               = [string]$Entry.edbArtifactUrl
        edbArtifactCalculatedSha256  = $EdbArtifactCalculatedSha256
        windowsPackagingRevision     = [int]$Entry.windowsPackagingRevision
        architecture                 = $Architecture
        configuration                = $Configuration
    }
    return ($info | ConvertTo-Json -Depth 4)
}

# Injectable gh api runner for tests. When set, Invoke-GhApi calls it with
# -Args <string[]> instead of the real CLI; it must return a hashtable with
# ExitCode / Stdout / Stderr.
$script:GhApiRunner = $null

function Invoke-GhApi {
    <#
    .SYNOPSIS
        Runs `gh api <args>` (or the injected test runner) and returns
        @{ ExitCode; Stdout; Stderr }.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Args)
    if ($script:GhApiRunner) {
        return & $script:GhApiRunner -Args $Args
    }
    $stdout = & gh api @Args 2> $null
    $code = $LASTEXITCODE
    $stderr = ''
    if ($code -ne 0) {
        $stderr = (& gh api @Args 2>&1 1> $null | Out-String) 2> $null
    }
    return @{ ExitCode = $code; Stdout = ($stdout | Out-String).TrimEnd(); Stderr = $stderr.Trim() }
}

function Test-ExistingRelease {
    <#
    .SYNOPSIS
        Classifies whether a release exists for the exact tag, using the
        GitHub REST API (repos/{repo}/releases/tags/{tag}).

        Returns 'exists' (HTTP 200) or 'absent' (HTTP 404). Any other
        outcome - authentication/authorization failures, rate limiting, API
        outage, timeouts, network failures, malformed responses - throws,
        so the caller fails closed instead of treating an error as absence.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Repository
    )
    $result = Invoke-GhApi -Args @("repos/$Repository/releases/tags/$Tag", "--jq", ".id")
    if ($result.ExitCode -eq 0) {
        if ($result.Stdout -match '^\d+\s*$') { return 'exists' }
        throw "Release existence check for '$Tag' returned an unexpected response (exit 0, output '$($result.Stdout)'). Failing closed."
    }
    if ($result.Stderr -match 'HTTP 404') { return 'absent' }
    throw "Release existence check for '$Tag' is indeterminate (exit $($result.ExitCode): $($result.Stderr.Trim())). Failing closed - not treating this as 'release absent'."
}

function Test-ReleaseOwnership {
    <#
    .SYNOPSIS
        Cleanup ownership check. A draft release may be deleted only when
        THIS job created it: 'created' must be exactly 'true', a valid
        numeric release ID must have been captured after creation, and the
        release currently at that ID must still target the expected tag.

        Returns $true when deletion is authorized; $false otherwise (the
        caller must leave the release and tag untouched - fail safe).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Created,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReleaseId,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Repository
    )
    if ($Created -ne 'true') { return $false }
    if ($ReleaseId -notmatch '^\d+$') { return $false }
    $result = Invoke-GhApi -Args @("repos/$Repository/releases/$ReleaseId", "--jq", ".tag_name")
    if ($result.ExitCode -ne 0) { return $false }
    $actualTag = ($result.Stdout -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    return ($actualTag -eq $Tag)
}

function Select-LatestRelease {
    <#
    .SYNOPSIS
        Deterministically selects which release must be GitHub Latest for a
        pglogical version: the highest configured PostgreSQL major that has
        a published (non-draft, non-prerelease) release for that version.
        Drafts, prereleases, unrelated versions, and unconfigured majors are
        ignored. Returns the matching release tag, or $null when none exists.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Majors,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Releases
    )
    $pattern = "^pglogical-$([regex]::Escape($Version))-pg([0-9]+)-windows\.([0-9]+)$"
    $configured = @($Majors | ForEach-Object { [string]$_ } | Sort-Object { [int]$_ })
    $best = $null   # @{ major; revision; tag }
    foreach ($major in $configured) {
        $bestForMajor = $null
        foreach ($r in $Releases) {
            if ($r.draft -or $r.prerelease) { continue }
            $m = [regex]::Match([string]$r.tag_name, $pattern)
            if (-not $m.Success) { continue }
            if ($m.Groups[1].Value -ne $major) { continue }
            $revision = [int]$m.Groups[2].Value
            if (-not $bestForMajor -or $revision -gt $bestForMajor.revision) {
                $bestForMajor = @{ major = $major; revision = $revision; tag = [string]$r.tag_name }
            }
        }
        if ($bestForMajor) { $best = $bestForMajor }
    }
    if (-not $best) { return $null }
    return $best.tag
}

function Test-ReleasePlan {
    <#
    .SYNOPSIS
        Validates a serialized release plan (JSON array of plan entries)
        against the pinned plan-entry contract. Returns the validated
        entries; throws (fail closed) on the first violation. Validation
        covers: JSON well-formedness, required properties, duplicate
        PostgreSQL majors, revision sanity, upstream tag pattern, upstream
        commit SHA format, HTTPS/EDB-host URLs, and filename identity
        (major/minor/revision match against the entry fields).
    #>
    param([Parameter(Mandatory = $true)][string]$PlanJson)
    if ([string]::IsNullOrWhiteSpace($PlanJson)) {
        throw 'Release plan JSON is empty; a pinned plan is required.'
    }
    $entries = $null
    try {
        $entries = @($PlanJson | ConvertFrom-Json)
    }
    catch {
        throw "Release plan JSON is malformed: $($_.Exception.Message)"
    }
    if ($entries.Count -eq 0) {
        throw 'Release plan contains no entries.'
    }
    $tagPattern = [regex](Get-UpstreamTagPattern)
    $required = @(
        'pglogicalVersion', 'upstreamTag', 'upstreamCommitSha',
        'postgresqlMajor', 'postgresqlMinor', 'postgresqlBuildVersion',
        'windowsPackagingRevision', 'edbPackagingRevision',
        'edbArtifactFilename', 'edbArtifactUrl'
    )
    $seenMajors = @{}
    $planVersion = $null
    $planTag = $null
    $planSha = $null
    foreach ($e in $entries) {
        # Whole-plan consistency: every entry must target the same upstream
        # release and commit (one pglogical version per plan).
        if ($null -eq $planVersion) {
            $planVersion = [string]$e.pglogicalVersion
            $planTag = [string]$e.upstreamTag
            $planSha = [string]$e.upstreamCommitSha
        }
        elseif ([string]$e.pglogicalVersion -ne $planVersion -or [string]$e.upstreamTag -ne $planTag -or [string]$e.upstreamCommitSha -ne $planSha) {
            throw "Release plan mixes different upstream releases/commits; every entry must pin the same pglogical version, upstream tag, and upstream commit SHA."
        }
        foreach ($prop in $required) {
            $propInfo = $e.PSObject.Properties[$prop]
            if ($null -eq $propInfo -or $null -eq $propInfo.Value) {
                throw "Release plan entry is missing required property '$prop'."
            }
        }
        if ([string]$e.upstreamCommitSha -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Release plan entry has invalid upstreamCommitSha '$($e.upstreamCommitSha)' (expected 40 hex characters)."
        }
        if (-not $tagPattern.IsMatch([string]$e.upstreamTag)) {
            throw "Release plan entry has invalid upstream tag '$($e.upstreamTag)' (expected $(Get-UpstreamTagPattern))."
        }
        if ([int]$e.windowsPackagingRevision -lt 1) {
            throw "Release plan entry has invalid windowsPackagingRevision '$($e.windowsPackagingRevision)'."
        }
        if ([int]$e.edbPackagingRevision -lt 1) {
            throw "Release plan entry has invalid edbPackagingRevision '$($e.edbPackagingRevision)'."
        }
        $major = [string]$e.postgresqlMajor
        if ($seenMajors.ContainsKey($major)) {
            throw "Release plan contains duplicate PostgreSQL major '$major'."
        }
        $seenMajors[$major] = $true
        if ([string]"$($e.postgresqlMajor).$($e.postgresqlMinor)" -ne [string]$e.postgresqlBuildVersion) {
            throw "Release plan entry postgresqlBuildVersion '$($e.postgresqlBuildVersion)' does not match major.minor '$($e.postgresqlMajor).$($e.postgresqlMinor)'."
        }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$e.edbArtifactUrl, [UriKind]::Absolute, [ref]$uri)) {
            throw "Release plan entry has malformed edbArtifactUrl '$($e.edbArtifactUrl)'."
        }
        if ($uri.Scheme -ne 'https') {
            throw "Release plan entry edbArtifactUrl must use https: '$($e.edbArtifactUrl)'."
        }
        if ($uri.Host -ne $script:EdbHost) {
            throw "Release plan entry edbArtifactUrl host must be $($script:EdbHost): '$($e.edbArtifactUrl)'."
        }
        $filename = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        if ($filename -ne [string]$e.edbArtifactFilename) {
            throw "Release plan entry edbArtifactFilename '$($e.edbArtifactFilename)' does not match the URL filename '$filename'."
        }
        $parsed = ConvertFrom-EdbArtifactFilename -Filename $filename
        if (-not $parsed) {
            throw "Release plan entry has invalid edbArtifactFilename '$filename' (expected the EDB archive pattern)."
        }
        if ($parsed.major -ne $major) {
            throw "Release plan entry EDB filename major '$($parsed.major)' does not match postgresqlMajor '$major'."
        }
        if ($parsed.minor -ne [string]$e.postgresqlMinor) {
            throw "Release plan entry EDB filename minor '$($parsed.minor)' does not match postgresqlMinor '$($e.postgresqlMinor)'."
        }
        if ($parsed.revision -ne [int]$e.edbPackagingRevision) {
            throw "Release plan entry EDB filename revision '$($parsed.revision)' does not match edbPackagingRevision '$($e.edbPackagingRevision)'."
        }
    }
    return $entries
}

function Test-PinnedEdbUrl {
    <#
    .SYNOPSIS
        Verifies that a pinned plan entry's EDB artifact URL is still
        conclusively available on the EDB host. The pinned identity is used
        as-is — discovery is never repeated, and no other revision is ever
        substituted. A definitive absence fails, an indeterminate result
        fails after retries.
    #>
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [int]$MaxAttempts = 3
    )
    $result = Probe-EdbArtifactUrl `
        -Url ([string]$Entry.edbArtifactUrl) `
        -Major ([string]$Entry.postgresqlMajor) `
        -Minor ([string]$Entry.postgresqlMinor) `
        -Revision ([int]$Entry.edbPackagingRevision) `
        -MaxAttempts $MaxAttempts
    if ($result.Result -eq 'Available') {
        Write-Host "Pinned EDB artifact verified available: $($Entry.edbArtifactFilename)"
        return $true
    }
    if ($result.Result -eq 'NotFound') {
        throw "Pinned EDB artifact $($Entry.edbArtifactFilename) is definitively absent on the EDB host ($($result.Reason)); failing closed."
    }
    throw "Pinned EDB artifact $($Entry.edbArtifactFilename) could not be verified ($($result.Reason)); failing closed without substituting another revision."
}

function Test-InstallMetadataIdentity {
    <#
    .SYNOPSIS
        Verifies parsed installation metadata (EDB-INSTALL-INFO.json content)
        against the exact requested artifact identity. Returns $true only
        when EVERY field matches: PostgreSQL major, minor, build version, EDB
        packaging revision, artifact filename, and artifact URL. A $null
        (missing/malformed) metadata object is never a match.
    #>
    param(
        $Info,
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [Parameter(Mandatory = $true)][int]$EdbRevision,
        [Parameter(Mandatory = $true)][string]$ArtifactFilename,
        [Parameter(Mandatory = $true)][string]$ArtifactUrl
    )
    if (-not $Info) { return $false }
    $checks = @(
        ([string]$Info.postgresqlMajor -eq $Major),
        ([string]$Info.postgresqlMinor -eq $Minor),
        ([string]$Info.postgresqlBuildVersion -eq "$Major.$Minor"),
        ([int]$Info.edbPackagingRevision -eq $EdbRevision),
        ([string]$Info.edbArtifactFilename -eq $ArtifactFilename),
        ([string]$Info.edbArtifactUrl -eq $ArtifactUrl)
    )
    return ($checks -notcontains $false)
}

function Test-PgConfigVersion {
    <#
    .SYNOPSIS
        Reads PG_VERSION / PG_VERSION_NUM from a pg_config.h file and checks
        the exact major.minor. Returns $true on match, $false otherwise.
        PostgreSQL headers never contain the EDB packaging revision, so only
        major/minor are checked here.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PgConfigHeader,
        [Parameter(Mandatory = $true)][string]$ExpectedMajor,
        [Parameter(Mandatory = $true)][string]$ExpectedMinor
    )
    if (-not (Test-Path $PgConfigHeader)) { return $false }
    $verLine = Select-String -Path $PgConfigHeader -Pattern '#define PG_VERSION "([0-9.]+)"' | Select-Object -First 1
    $verNumLine = Select-String -Path $PgConfigHeader -Pattern '#define PG_VERSION_NUM ([0-9]+)' | Select-Object -First 1
    if (-not $verLine -or -not $verNumLine) { return $false }
    $installedNum = [int]$verNumLine.Matches[0].Groups[1].Value
    $installedMajor = [math]::Floor($installedNum / 10000)
    $installedMinor = $installedNum % 10000
    return ($installedMajor -eq [int]$ExpectedMajor -and $installedMinor -eq [int]$ExpectedMinor)
}

function Invoke-InVsEnv {
    <#
    .SYNOPSIS
        Runs a script block with the MSVC x64 environment loaded (via
        vcvars64.bat), then restores the previous environment.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$VcVarsPath
    )
    if (-not $VcVarsPath) {
        $VcVarsPath = Get-VsDevCmdPath
        if (-not $VcVarsPath) {
            throw 'Visual Studio C++ tools (vcvars64.bat) not found. Install "Desktop development with C++" or run from a developer prompt.'
        }
    }
    $snapshot = @{}
    Get-ChildItem Env: | ForEach-Object { $snapshot[$_.Name] = $_.Value }

    $cmd = "`"$VcVarsPath`" && set"
    $envDump = & cmd.exe /d /s /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize the MSVC environment via $VcVarsPath"
    }
    $newEnv = @{}
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') { $newEnv[$matches[1]] = $matches[2] }
    }
    foreach ($key in $newEnv.Keys) { Set-Item -Path "Env:$key" -Value $newEnv[$key] }

    try {
        return & $ScriptBlock
    }
    finally {
        foreach ($key in (Get-ChildItem Env:).Name) {
            if (-not $snapshot.ContainsKey($key)) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
        }
        foreach ($key in $snapshot.Keys) { Set-Item -Path "Env:$key" -Value $snapshot[$key] }
    }
}
