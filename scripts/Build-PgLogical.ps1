<#
.SYNOPSIS
    Builds the pglogical Windows x64 package (DLLs, extension scripts, and
    pglogical_create_subscriber.exe) for one PostgreSQL installation using
    CMake + MSVC.

.DESCRIPTION
    This is the local entry point. It:

      1. validates PG_ROOT (the PostgreSQL Windows installation to build
         against: headers + import libraries must be present);
      2. clones the exact upstream pglogical release tag (unless -SkipClone
         with -SourceDir is given);
      3. configures and builds with CMake + the Visual Studio generator;
      4. verifies the exported entry points of both DLLs with dumpbin;
      5. prints the staging directory for packaging/testing.

    Requirements: PowerShell 7, CMake >= 3.24, Visual Studio 2022 (or newer)
    with the "Desktop development with C++" workload. Nothing is installed
    machine-globally; all work happens under -WorkDir (default
    <repo>/.build/<tag>).

.PARAMETER PgRoot
    The PostgreSQL installation to build against, e.g.
    "C:\Program Files\PostgreSQL\18" or an isolated EDB binaries tree.

.PARAMETER UpstreamTag
    The upstream pglogical release tag, e.g. REL2_4_8. Defaults to the
    releaseBaseline from .github/pg-versions.json.

.PARAMETER Configuration
    Build configuration: Release (default) or Debug.

.PARAMETER Architecture
    Target architecture; only x64 is supported.

.PARAMETER WorkDir
    Temporary working directory for the upstream clone, CMake build, and
    staging. Defaults to <repo>/.build/<tag>.

.PARAMETER SourceDir
    Use an existing upstream checkout instead of cloning (implies -SkipClone).

.PARAMETER ExpectedCommitSha
    When non-empty, verifies that the cloned commit SHA matches this exact
    value. Used in release builds to detect tag movement (the resolve job
    computes the expected SHA from the upstream release). Passing an empty
    string (the default) skips the verification — this is the behavior for
    CI build-smoke, which does not resolve a SHA.

.PARAMETER SkipClone
    Do not clone upstream; requires -SourceDir.

.PARAMETER OutputStaging
    When set, prints the staging directory path to stdout as the last line so
    callers can capture it with $(pwsh ... ).

.EXAMPLE
    pwsh ./scripts/Build-PgLogical.ps1 -PgRoot "C:\Program Files\PostgreSQL\18" -UpstreamTag REL2_4_8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [string]$UpstreamTag,
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [ValidateSet('x64')][string]$Architecture = 'x64',
    [string]$WorkDir,
    [string]$SourceDir,
    [string]$ExpectedCommitSha = '',
    [switch]$SkipClone,
    [switch]$OutputStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$repoRoot = Get-RepoRoot
$config = Import-VersionConfig
$UpstreamRepository = Get-UpstreamRepository

# Default tag derives from the single source of truth (.github/pg-versions.json).
if (-not $UpstreamTag) { $UpstreamTag = ConvertFrom-PgLogicalVersion -Version $config.releaseBaseline }

# ---------------------------------------------------------------------------
# 1. Validate PG_ROOT
# ---------------------------------------------------------------------------
$PgRoot = [System.IO.Path]::GetFullPath($PgRoot)
if (-not (Test-Path $PgRoot)) { throw "PG_ROOT does not exist: $PgRoot" }

$requiredFiles = @(
    'include\pg_config.h', 'include\libpq-fe.h',
    'include\server\postgres.h',
    'include\server\port\win32_msvc\dirent.h',
    'include\server\port\win32\sys\wait.h',
    'lib\postgres.lib', 'lib\libpq.lib', 'lib\libintl.lib'
)
$missing = @($requiredFiles | Where-Object { -not (Test-Path (Join-Path $PgRoot $_)) })
if ($missing.Count -gt 0) {
    throw "PG_ROOT is missing required files for an MSVC extension build: $($missing -join ', '). Use an official EDB Windows installation or Install-PostgreSql.ps1."
}

$verNumLine = Select-String -Path (Join-Path $PgRoot 'include\pg_config.h') -Pattern '#define PG_VERSION_NUM ([0-9]+)' | Select-Object -First 1
if (-not $verNumLine) { throw 'Could not read PG_VERSION_NUM from PG_ROOT\include\pg_config.h' }
$pgVersionNum = [int]$verNumLine.Matches[0].Groups[1].Value
$pgMajor = [math]::Floor($pgVersionNum / 10000)
Write-Host "PG_ROOT=$PgRoot (PostgreSQL major $pgMajor)"

if ($Architecture -ne 'x64') { throw "Architecture '$Architecture' is not supported; only x64 is supported." }
if ($Configuration -ne 'Release') { Write-Host "Building $Configuration (Release is the supported package configuration)." }

# ---------------------------------------------------------------------------
# 2. Upstream source (clone the exact tag or use -SourceDir)
# ---------------------------------------------------------------------------
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot ".build\$UpstreamTag" }
$null = New-Item -ItemType Directory -Force -Path $WorkDir

if ($SourceDir) {
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
    if (-not (Test-Path (Join-Path $SourceDir 'Makefile'))) { throw "-SourceDir does not look like a pglogical checkout: $SourceDir" }
}
elseif (-not $SkipClone) {
    $SourceDir = Join-Path $WorkDir 'upstream'
    if (Test-Path (Join-Path $SourceDir '.git')) {
        Write-Host "Reusing existing clone at $SourceDir (delete it to force a fresh clone)"
    }
    else {
        Write-Host "Cloning $UpstreamRepository at tag $UpstreamTag"
        Invoke-Native -FilePath 'git' -ArgumentList @('clone', '--depth', '1', '--branch', $UpstreamTag, "https://github.com/$UpstreamRepository.git", $SourceDir)
    }
    $headSha = (& git -C $SourceDir rev-parse HEAD 2>$null)
    Write-Host "Upstream commit: $headSha"
    if ($ExpectedCommitSha -and ($ExpectedCommitSha -ne $headSha)) {
        throw "Upstream tag $UpstreamTag moved: expected commit $ExpectedCommitSha, clone HEAD is $headSha"
    }
}
else {
    throw 'Either -SourceDir or -SkipClone without -SourceDir requires an existing checkout.'
}

$upstreamVersion = ConvertTo-PgLogicalVersion -Tag $UpstreamTag

# ---------------------------------------------------------------------------
# 3. Apply local patches (all patches named pglogical-<version>-*.patch apply
#     in name order).
# ---------------------------------------------------------------------------
$patchDir = Join-Path $PSScriptRoot '..\patches'
$patches = Get-ChildItem -Path $patchDir -Filter "pglogical-$upstreamVersion-*.patch" -File | Sort-Object Name
foreach ($patchFile in $patches) {
    Write-Host "Applying patch $($patchFile.Name)"
    & git -C $SourceDir apply --check --whitespace=nowarn $patchFile.FullName 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Patch $($patchFile.Name) does not apply to upstream $upstreamVersion; update it." }
    # --whitespace=fix: upstream pglogical sources carry trailing whitespace
    # (e.g. pglogical.c #if lines); fixing it while applying keeps the build
    # logs warning-free without changing code semantics. stderr is discarded
    # so the 'trailing whitespace' hints never surface; a real apply failure
    # still fails loudly via the exit code below.
    & git -C $SourceDir apply --whitespace=fix $patchFile.FullName 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Patch application failed." }
    Write-Host "Patch applied: $($patchFile.Name)"
}

# ---------------------------------------------------------------------------
# 4. Build matrix validation for this PG major
# ---------------------------------------------------------------------------
$compatDir = Join-Path $SourceDir "compat$pgMajor"
if (-not (Test-Path (Join-Path $compatDir 'pglogical_compat.c'))) {
    throw "Upstream pglogical $upstreamVersion has no compat$pgMajor implementation; it cannot be built against PostgreSQL $pgMajor."
}

# ---------------------------------------------------------------------------
# 5. CMake configure + build
# ---------------------------------------------------------------------------
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    $candidates = @(
        "${env:ProgramFiles}\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    )
    foreach ($c in $candidates) {
        $resolved = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) { $cmake = [pscustomobject]@{ Source = $resolved.FullName }; break }
    }
}
if (-not $cmake) { throw 'CMake not found. Install CMake >= 3.24 and ensure it is on PATH.' }
$cmakePath = $cmake.Source

$buildDir = Join-Path $WorkDir 'build'
$null = New-Item -ItemType Directory -Force -Path $buildDir

# Upstream pglogical uses preprocessor directives inside function-call
# argument lists (e.g. ExecInsertIndexTuples(...) with #if PG_VERSION_NUM
# between the arguments). Microsoft's cl preprocessor rejects that pattern,
# so the C compiler must be clang-cl — LLVM's MSVC-compatible frontend —
# while the linker, runtime, and tooling remain MSVC (link.exe, MSVC CRT,
# dumpbin). clang-cl ships with Visual Studio as the "ClangCL" toolset.
$generator = 'Visual Studio 17 2022'
$toolset = $null
$vsInstance = $null
if ($env:PGL_TOOLSET) {
    $toolset = $env:PGL_TOOLSET
    Write-Host "Using toolset from PGL_TOOLSET: $toolset"
}
else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $llvm = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset -property installationPath
        if ($llvm) {
            $toolset = 'ClangCL'
            $vsInstance = $llvm.Trim()
            Write-Host "Visual Studio C++ Clang tools (ClangCL toolset) found at $vsInstance"
        }
        else {
            throw 'clang-cl is required to build pglogical: upstream uses preprocessor directives inside function-call argument lists, which Microsoft cl rejects. Install the "C++ Clang tools for Windows" Visual Studio component (or set PGL_TOOLSET=ClangCL if your LLVM is registered differently).'
        }
    }
    else {
        throw 'Visual Studio not found (vswhere missing). Install Visual Studio 2022+ with "Desktop development with C++".'
    }
}

Write-Host "Configuring CMake ($generator, $Architecture, toolset $toolset)"
$configureArgs = @(
    '-S', $repoRoot,
    '-B', $buildDir,
    "-G", $generator,
    "-A", $Architecture,
    "-T", $toolset,
    "-DPG_ROOT=$PgRoot",
    "-DPG_MAJOR=$pgMajor",
    "-DPGLOGICAL_SOURCE_DIR=$SourceDir",
    "-DPGLOGICAL_VERSION=$upstreamVersion"
)
# Pin the Visual Studio instance explicitly: CMake's own instance lookup can
# fail on runners even though vswhere found the install (generator then
# reports "could not find any instance of Visual Studio").
if ($vsInstance) {
    $configureArgs += @("-DCMAKE_GENERATOR_INSTANCE=$vsInstance")
}
Invoke-Native -FilePath $cmakePath -ArgumentList $configureArgs

Write-Host "Building (configuration: $Configuration)"
Invoke-Native -FilePath $cmakePath -ArgumentList @('--build', $buildDir, '--config', $Configuration)

# ---------------------------------------------------------------------------
# 5b. Stage the install layout (lib/, share/extension/, bin/)
# ---------------------------------------------------------------------------
$stageDir = Join-Path $WorkDir 'stage'
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
Write-Host "Staging into $stageDir"
Invoke-Native -FilePath $cmakePath -ArgumentList @('--install', $buildDir, '--config', $Configuration, '--prefix', $stageDir)
foreach ($expected in @("lib\pglogical.dll", "lib\pglogical_output.dll", "share\extension\pglogical.control")) {
    if (-not (Test-Path (Join-Path $stageDir $expected))) {
        throw "Staging failed: missing $expected in $stageDir"
    }
}
Write-Host "Staged files:"
Get-ChildItem -Recurse -File $stageDir | ForEach-Object { Write-Host "  $($_.FullName.Substring($stageDir.Length + 1))" }

# ---------------------------------------------------------------------------
# 6. Verify DLL exports with dumpbin
# ---------------------------------------------------------------------------
$exports = Read-JsonFile -Path (Join-Path $repoRoot 'cmake\exports.json') -WhatFor 'exports manifest'
$stageDir = Join-Path $WorkDir "stage"
$configDir = if ($Configuration -eq 'Debug') { 'Debug' } else { 'Release' }

$vcvars = Get-VsDevCmdPath
if (-not $vcvars) {
    Write-Host 'WARNING: vcvars64.bat not found; skipping dumpbin export verification (CI performs it).'
}
else {
    $dllChecks = @(
        @{ Dll = 'pglogical.dll'; Expected = @($exports.pglogical) },
        @{ Dll = 'pglogical_output.dll'; Expected = @($exports.pglogical_output) }
    )
    Invoke-InVsEnv -VcVarsPath $vcvars -ScriptBlock {
        foreach ($check in $dllChecks) {
            $dllPath = Join-Path $buildDir "$configDir\$($check.Dll)"
            if (-not (Test-Path $dllPath)) { throw "Build did not produce $($check.Dll) at $dllPath" }
            $dumpbinOut = & dumpbin /nologo /exports $dllPath
            if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $($check.Dll)" }
            $exported = @($dumpbinOut | ForEach-Object {
                if ($_ -match '^\s+[0-9A-F]+\s+[0-9A-F]+\s+([0-9A-F]+)\s+([A-Za-z_][A-Za-z0-9_]*)$') { $matches[2] }
            } | Sort-Object -Unique)
            $missingExports = @($check.Expected | Where-Object { $exported -notcontains $_ })
            if ($missingExports.Count -gt 0) {
                throw "$($check.Dll) is missing required exports: $($missingExports -join ', ')"
            }
            Write-Host "Export verification OK: $($check.Dll) exports $($check.Expected.Count)/$($check.Expected.Count) required symbols"
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Report the staging directory
# ---------------------------------------------------------------------------
Write-Host "Build complete. Staging directory: $stageDir"
if ($OutputStaging) { Write-Output $stageDir }
