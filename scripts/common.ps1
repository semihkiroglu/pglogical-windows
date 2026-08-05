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
        Derives the EDB Windows binaries URL for a given major + minor.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major,
        [Parameter(Mandatory = $true)][string]$Minor
    )
    return "https://get.enterprisedb.com/postgresql/postgresql-$Major.$Minor-1-windows-x64-binaries.zip"
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

function Get-PgLatestMinor {
    <#
    .SYNOPSIS
        Returns the latest supported minor version and derived EDB URL for a
        PostgreSQL major. Sources versions.json live, finds the
        matching major, and HEAD-probes the derived URL to confirm
        availability (EDB binaries may lag pg.org by days).

    .OUTPUTS
        A PSCustomObject with .minor (string) and .binariesUrl (string), or
        $null if the major is not found or the URL is not yet reachable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Major
    )
    $versions = Get-PgOrgVersions
    $entry = @($versions | Where-Object { [string]$_.major -eq $Major } | Select-Object -First 1)
    if (-not $entry) {
        Write-Host "PostgreSQL major $Major not found in versions.json"
        return $null
    }
    $minor = [string]$entry[0].latestMinor
    $url = Get-EdbBinaryUrl -Major $Major -Minor $minor
    Write-Host "PG $Major latest minor: $minor, derived URL: $url"

    # HEAD-probe to confirm EDB has the binaries (they lag pg.org).
    if (-not (Test-EdbBinaryUrl -Url $url)) {
        Write-Host "EDB binaries not yet available at $url (HEAD returned non-2xx); cannot use PG $Major.$minor"
        return $null
    }
    return [pscustomobject]@{ minor = $minor; binariesUrl = $url }
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
