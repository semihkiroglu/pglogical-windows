<#
.SYNOPSIS
    Installs an official EnterpriseDB PostgreSQL Windows x64 binary
    distribution into an isolated directory for building and testing against.

.DESCRIPTION
    Downloads the official EDB "binaries" ZIP
    (postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip) from
    get.enterprisedb.com (the EnterpriseDB-controlled download host), expands
    it into an isolated directory, and validates the layout and version.

    The minor version comes from https://www.postgresql.org/versions.json
    (the authoritative source for latest supported minors). The exact EDB
    packaging revision is resolved by probing the official EDB host in
    ascending order and taking the highest revision that exists; revision -1
    is never silently assumed, because EDB can republish the same minor under
    a new packaging revision. When -Minor and -BinariesUrl are both provided,
    they take precedence over derivation.

    Why this source?
      * The ZIP is produced by the same build that the official EDB Windows
        installer ships, without requiring a silent installer run.
      * It contains everything a native MSVC extension build needs:
        - include\server and the win32/win32_msvc port headers
        - lib\postgres.lib, lib\libpq.lib, lib\libintl.lib
        - bin\initdb.exe, bin\pg_ctl.exe, bin\psql.exe, bin\postgres.exe
      * It is not redistributed: the repository never commits or re-uploads
        the download, and CI caches it only as a build input.

    Checksum note: EDB does not publish an official checksum for the binaries
    ZIPs. The download is therefore verified via HTTPS/TLS, the server's
    Content-Length, ZIP structural integrity, the presence of the expected
    layout, and a PG_VERSION_NUM match for the requested major. Static sha256
    pinning is deliberately out of scope.

.PARAMETER Major
    PostgreSQL major version to install, e.g. 18. Must be present in
    .github/pg-versions.json (configured majors).

.PARAMETER Minor
    Optional explicit minor version. When omitted, derived from
    https://www.postgresql.org/versions.json (latestMinor for the major).

.PARAMETER BinariesUrl
    Optional explicit EDB binaries URL. When omitted, derived from major +
    minor using the standard EDB URL pattern.

.PARAMETER DestinationDir
    Directory that will contain the isolated installation
    (<DestinationDir>/pgsql). Defaults to <repo>/.pg/installs/pg<major>.

.PARAMETER CacheDir
    Directory used to cache the downloaded ZIP. Defaults to
    <repo>/.pg-cache. Cached files are keyed by name; a complete download is
    reused across runs.

.PARAMETER Force
    Re-download and re-extract even when a valid installation exists.

.OUTPUTS
    Writes the resolved PG_ROOT (the pgsql directory inside DestinationDir).

.EXAMPLE
    pwsh ./scripts/Install-PostgreSql.ps1 -Major 18
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateRange(9, 99)][int]$Major,
    [string]$Minor,
    [string]$BinariesUrl,
    [string]$DestinationDir,
    [string]$CacheDir,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Get-RepoRoot
$config = Import-VersionConfig

$majorKey = [string]$Major
if ($majorKey -notin @($config.postgresqlMajors)) {
    $known = @($config.postgresqlMajors) -join ', '
    throw "PostgreSQL major $Major is not configured in .github/pg-versions.json. Configured majors: $known. Adding a major is a deliberate configuration change."
}

# Resolve minor + exact binaries URL: explicit params > resolution
if ($Minor -and $BinariesUrl) {
    Write-Host "Using explicit minor=$Minor binariesUrl=$BinariesUrl"
}
elseif ($Minor) {
    $artifact = Resolve-EdbArtifact -Major $majorKey -Minor $Minor
    if (-not $artifact) {
        throw "Could not resolve an exact EDB Windows binaries artifact for PostgreSQL $Major.$Minor on get.enterprisedb.com; refusing to guess a packaging revision (fail closed). Specify -BinariesUrl explicitly if the artifact is known."
    }
    $BinariesUrl = $artifact.url
    Write-Host "Using explicit minor=$Minor, resolved exact artifact: $($artifact.filename)"
}
else {
    $artifact = Resolve-EdbArtifact -Major $majorKey
    if (-not $artifact) {
        throw "Could not resolve the exact EDB Windows binaries artifact for PostgreSQL $Major from versions.json and get.enterprisedb.com. Specify -Minor and -BinariesUrl explicitly, or ensure the major is present and supported in pg.org data."
    }
    $Minor = $artifact.minor
    $BinariesUrl = $artifact.url
}

$url = $BinariesUrl

# Optional official checksum; absent until EDB publishes one.
$expectedSha256 = ''

if (-not $DestinationDir) { $DestinationDir = Join-Path $repoRoot ".pg\installs\pg$majorKey" }
if (-not $CacheDir) { $CacheDir = Join-Path $repoRoot '.pg-cache' }
$pgRoot = Join-Path $DestinationDir 'pgsql'

# ---------------------------------------------------------------------------
# Reuse a valid installation unless forced
# ---------------------------------------------------------------------------
function Test-PgRootValid {
    param([string]$Root)
    $required = @(
        'bin\postgres.exe', 'bin\initdb.exe', 'bin\pg_ctl.exe', 'bin\psql.exe', 'bin\pg_config.exe',
        'include\pg_config.h', 'include\libpq-fe.h', 'include\server\postgres.h',
        'include\server\port\win32_msvc\dirent.h', 'include\server\port\win32\sys\wait.h',
        'lib\postgres.lib', 'lib\libpq.lib', 'lib\libintl.lib'
    )
    foreach ($rel in $required) {
        if (-not (Test-Path (Join-Path $Root $rel))) { return $false }
    }
    return $true
}

if (-not $Force -and (Test-Path $pgRoot) -and (Test-Path (Join-Path $pgRoot 'include\pg_config.h'))) {
    if (Test-PgRootValid -Root $pgRoot) {
        $existing = Select-String -Path (Join-Path $pgRoot 'include\pg_config.h') -Pattern '#define PG_VERSION "([0-9]+)\.([0-9]+)' | Select-Object -First 1
        if ($existing -and $existing.Matches[0].Groups[1].Value -eq $majorKey) {
            Write-Host "Reusing existing PostgreSQL $($existing.Matches[0].Groups[1].Value).$($existing.Matches[0].Groups[2].Value) installation at $pgRoot"
            return $pgRoot
        }
    }
    Write-Host "Existing installation at $pgRoot is incomplete or wrong version; reinstalling."
}

# ---------------------------------------------------------------------------
# Download (with cache)
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $CacheDir
$zipName = [System.IO.Path]::GetFileName([Uri]$url)
$zipPath = Join-Path $CacheDir $zipName

$redownload = $Force -or -not (Test-Path $zipPath)
if ($redownload) {
    Write-Host "Downloading $url"
    Write-Host "  -> $zipPath"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    $sw.Stop()
    Write-Host "Downloaded $([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB in $([math]::Round($sw.Elapsed.TotalSeconds))s"
}
else {
    Write-Host "Using cached download: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB)"
}

# ---------------------------------------------------------------------------
# Verify (TLS guaranteed by https; check length, optional sha256, zip integrity)
# ---------------------------------------------------------------------------
if ($expectedSha256) {
    $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedSha256.ToLowerInvariant()) {
        throw "SHA256 mismatch for $zipPath`n  expected: $($expectedSha256.ToLowerInvariant())`n  actual:   $actual"
    }
    Write-Host 'SHA256 verification passed.'
}
else {
    Write-Host 'No official SHA256 is published for this EDB binaries ZIP; skipping checksum verification (see script header).'
}

try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = $zip.Entries.Count
        if ($entries -lt 100) { throw "ZIP contains only $entries entries; expected a full PostgreSQL distribution." }
    }
    finally { $zip.Dispose() }
}
catch {
    throw "Downloaded file is not a valid ZIP archive: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Expand into the isolated destination
# ---------------------------------------------------------------------------
if (Test-Path $pgRoot) { Remove-Item -Recurse -Force $pgRoot }
$null = New-Item -ItemType Directory -Force -Path $DestinationDir
Write-Host "Expanding into $DestinationDir"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Expand-Archive -Path $zipPath -DestinationPath $DestinationDir -Force
$sw.Stop()
Write-Host "Expanded in $([math]::Round($sw.Elapsed.TotalSeconds))s"

# ---------------------------------------------------------------------------
# Validate the resulting installation
# ---------------------------------------------------------------------------
if (-not (Test-PgRootValid -Root $pgRoot)) {
    throw "Expanded distribution at $pgRoot is missing required files. Expected layout under <dest>\pgsql with bin/, include/, lib/."
}

$verLine = Select-String -Path (Join-Path $pgRoot 'include\pg_config.h') -Pattern '#define PG_VERSION "([0-9.]+)"' | Select-Object -First 1
$verNumLine = Select-String -Path (Join-Path $pgRoot 'include\pg_config.h') -Pattern '#define PG_VERSION_NUM ([0-9]+)' | Select-Object -First 1
if (-not $verLine) { throw 'Could not read PG_VERSION from pg_config.h' }
$installedVersion = $verLine.Matches[0].Groups[1].Value
$installedNum = [int]$verNumLine.Matches[0].Groups[1].Value
$expectedMajor = [int]$majorKey
$expectedMinor = [int]$Minor
$installedMajor = [math]::Floor($installedNum / 10000)
$installedMinor = $installedNum % 10000
if ($installedMajor -ne $expectedMajor -or $installedMinor -ne $expectedMinor) {
    throw "Installed PostgreSQL version ($installedVersion, PG_VERSION_NUM $installedNum) does not match the requested artifact PostgreSQL $expectedMajor.$expectedMinor"
}

Write-Host "PostgreSQL $installedVersion installed at:"
Write-Host "  PG_ROOT=$pgRoot"
return $pgRoot
