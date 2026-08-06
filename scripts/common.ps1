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
                version             = $Version
                upstreamTag         = $UpstreamTag
                commitSha           = $CommitSha
                pgMajor             = $key
                packagingRevision   = 1
                localTag            = Get-LocalReleaseTag -Version $Version -PackagingRevision 1 -PgMajor $key
                edbArtifactFilename = $artifact.filename
                edbArtifactUrl      = $artifact.url
                edbMinor            = $artifact.minor
                edbRevision         = $artifact.revision
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
            version             = $Version
            upstreamTag         = $UpstreamTag
            commitSha           = $CommitSha
            pgMajor             = $key
            packagingRevision   = $nextRevision
            localTag            = Get-LocalReleaseTag -Version $Version -PackagingRevision $nextRevision -PgMajor $key
            edbArtifactFilename = $artifact.filename
            edbArtifactUrl      = $artifact.url
            edbMinor            = $artifact.minor
            edbRevision         = $artifact.revision
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

function Get-PgOrgVersions {
    <#
    .SYNOPSIS
        Fetches https://www.postgresql.org/versions.json and returns the
        parsed array. Each entry: major (int), latestMinor (int), supported
        (bool), eolDate (string or null).
    #>
    Write-Host "Fetching PostgreSQL.org versions.json"
    $response = Invoke-RestMethod -Uri 'https://www.postgresql.org/versions.json' -Method Get -TimeoutSec 30
    return @($response)
}

function Get-EdbBinaryUrl {
    <#
    .SYNOPSIS
        Derives the EDB Windows binaries URL for a given major + minor +
        packaging revision.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor,
        [ValidateRange(1, 50)][int]$Revision = 1
    )
    return "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-$Revision-windows-x64-binaries.zip"
}

function Test-EdbBinaryUrl {
    <#
    .SYNOPSIS
        HEAD-probes an EDB binaries URL. Returns true if the URL responds
        with a 2xx status, false otherwise (including 404).
    #>
    param([Parameter(Mandatory = $true)][string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        Write-Host "HEAD probe failed for $Url : $($_.Exception.Message)"
        return $false
    }
}

function Resolve-EdbArtifact {
    <#
    .SYNOPSIS
        Resolves the current exact EDB Windows x64 binaries artifact for a
        PostgreSQL major from the official EDB host (get.enterprisedb.com).

    .DESCRIPTION
        The minor version comes from https://www.postgresql.org/versions.json
        (the authoritative source for latest supported minors). The exact
        packaging revision is then resolved by HEAD-probing
        get.enterprisedb.com in ascending order and taking the highest
        revision that exists. Revision -1 is never silently assumed: EDB can
        republish the same minor under a new packaging revision (e.g.
        postgresql-18.4-1 -> postgresql-18.4-2), and the extension must be
        built against the exact artifact whose headers/import libraries are
        used. No third-party package manifest is consulted.

    .PARAMETER Major
        PostgreSQL major, e.g. 18.

    .PARAMETER Minor
        Optional explicit minor. When omitted, derived from pg.org
        versions.json (latestMinor for the major).

    .PARAMETER MaxRevision
        Upper bound for the revision enumeration. Revisions above this are
        never considered.

    .OUTPUTS
        A PSCustomObject with .major, .minor, .revision, .filename and .url,
        or $null when no artifact exists (callers fail closed).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [string]$Minor,
        [ValidateRange(1, 50)][int]$MaxRevision = 10
    )
    if (-not $Minor) {
        $versions = Get-PgOrgVersions
        $entry = @($versions | Where-Object { [string]$_.major -eq $Major } | Select-Object -First 1)
        if (-not $entry) {
            Write-Host "PostgreSQL major $Major not found in versions.json"
            return $null
        }
        $Minor = [string]$entry[0].latestMinor
    }

    $resolved = $null
    for ($revision = 1; $revision -le $MaxRevision; $revision++) {
        $url = Get-EdbBinaryUrl -Major $Major -Minor $Minor -Revision $revision
        if (Test-EdbBinaryUrl -Url $url) {
            $resolved = [pscustomobject]@{
                major    = $Major
                minor    = $Minor
                revision = $revision
                filename = [System.IO.Path]::GetFileName([Uri]$url)
                url      = $url
            }
            Write-Host "EDB artifact revision $revision available: $($resolved.filename)"
        }
        else {
            Write-Host "EDB artifact revision $revision not available: $url"
            break
        }
    }
    if (-not $resolved) {
        Write-Host "No EDB Windows x64 binaries artifact found for PostgreSQL $Major.$Minor on get.enterprisedb.com (no revision responded; probed ascending from revision 1)."
        return $null
    }

    # Defense in depth: the resolved artifact must belong to the requested
    # PostgreSQL major before anything is built against it.
    $parsed = ConvertFrom-EdbArtifactFilename -Filename $resolved.filename
    if (-not $parsed -or $parsed.major -ne $Major) {
        throw "Resolved EDB artifact $($resolved.filename) does not belong to PostgreSQL major $Major; refusing to use it (fail closed)."
    }
    return $resolved
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
