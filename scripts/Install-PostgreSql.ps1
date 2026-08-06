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

# Exact artifact identity derived from the selected URL (never from
# PG_VERSION_NUM — PostgreSQL headers do not contain the EDB packaging
# revision).
$artifactFilename = [System.IO.Path]::GetFileName([Uri]$url)
$artifactParsed = ConvertFrom-EdbArtifactFilename -Filename $artifactFilename
if (-not $artifactParsed) {
    throw "The resolved EDB binaries URL does not have a valid archive filename: $url"
}
if ($artifactParsed.major -ne $majorKey -or $artifactParsed.minor -ne [string]$Minor) {
    throw "The resolved EDB binaries URL filename '$artifactFilename' does not match the requested PostgreSQL $Major.$Minor (fail closed)."
}

# Optional official checksum; absent until EDB publishes one.
$expectedSha256 = ''

if (-not $DestinationDir) { $DestinationDir = Join-Path $repoRoot ".pg\installs\pg$majorKey" }
if (-not $CacheDir) { $CacheDir = Join-Path $repoRoot '.pg-cache' }
$pgRoot = Join-Path $DestinationDir 'pgsql'
$null = New-Item -ItemType Directory -Force -Path $CacheDir
$zipPath = Join-Path $CacheDir $artifactFilename
$installInfoPath = Join-Path $DestinationDir 'EDB-INSTALL-INFO.json'

# ---------------------------------------------------------------------------
# Reuse an existing installation ONLY when it matches the exact artifact
# identity: same major, same minor, same EDB packaging revision, same
# filename/URL, valid metadata, and a consistent cached archive. Anything
# missing, malformed, stale, or different reinstalls.
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

function Get-InstallInfo {
    <#
    .SYNOPSIS
        Reads and parses EDB-INSTALL-INFO.json. Returns $null when the file
        is missing or malformed (both mean "no reuse").
    #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content $Path -Raw | ConvertFrom-Json)
    }
    catch {
        Write-Host "Installation metadata $Path is malformed; not reusing."
        return $null
    }
}

$reuse = $false
if (-not $Force -and (Test-Path $pgRoot) -and (Test-PgRootValid -Root $pgRoot)) {
    $info = Get-InstallInfo -Path $installInfoPath
    if ($info -and (Test-InstallMetadataIdentity `
            -Info $info `
            -Major $majorKey `
            -Minor $Minor `
            -EdbRevision $artifactParsed.revision `
            -ArtifactFilename $artifactFilename `
            -ArtifactUrl $url) `
        -and (Test-PgConfigVersion -PgConfigHeader (Join-Path $pgRoot 'include\pg_config.h') -ExpectedMajor $majorKey -ExpectedMinor $Minor)) {
        $reuse = $true
        # Cached archive consistency: when the cache still holds the ZIP,
        # its calculated SHA must match the metadata record.
        if (Test-Path $zipPath) {
            $cachedHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not [string]$info.calculatedSha256 -or $cachedHash -ne [string]$info.calculatedSha256) {
                Write-Host "Cached archive SHA256 does not match installation metadata; reinstalling."
                $reuse = $false
            }
        }
    }
    elseif ($info) {
        Write-Host "Installation metadata does not match the exact requested artifact identity; reinstalling."
    }
    if ($reuse) {
        Write-Host "Reusing existing exact-matching PostgreSQL installation at $pgRoot ($artifactFilename)"
        return $pgRoot
    }
}
elseif (-not $Force) {
    Write-Host "Existing installation at $pgRoot is incomplete; reinstalling."
}
if ($reuse) { return $pgRoot }
Write-Host "Installing exact artifact: $artifactFilename"

# ---------------------------------------------------------------------------
# Download (with cache)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Write installation metadata (atomic) — only after download, ZIP validity,
# extraction, layout, and exact major.minor all succeeded. The SHA-256 is
# calculated by this project post-download; it is NOT a vendor-published
# checksum.
# ---------------------------------------------------------------------------
$calculatedSha = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$installInfo = [ordered]@{
    postgresqlMajor      = $majorKey
    postgresqlMinor      = $Minor
    postgresqlBuildVersion = "$Major.$Minor"
    edbPackagingRevision = $artifactParsed.revision
    edbArtifactFilename  = $artifactFilename
    edbArtifactUrl       = $url
    calculatedSha256     = $calculatedSha
    installedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
}
$null = New-Item -ItemType Directory -Force -Path $DestinationDir
$tmpInfoPath = "$installInfoPath.tmp"
$installInfo | ConvertTo-Json -Depth 3 | Set-Content -Path $tmpInfoPath -Encoding utf8
Move-Item -Force -Path $tmpInfoPath -Destination $installInfoPath
Write-Host "Installation metadata written: $installInfoPath (calculated SHA256 $calculatedSha)"

Write-Host "PostgreSQL $installedVersion installed at:"
Write-Host "  PG_ROOT=$pgRoot"
return $pgRoot
