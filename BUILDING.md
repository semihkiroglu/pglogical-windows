# BUILDING.md

How to build the pglogical Windows x64 packages locally with CMake + MSVC.

## What is built

* `pglogical.dll` — the main extension module.
* `pglogical_output.dll` — the output-plugin compatibility shim.
* `pglogical_create_subscriber.exe` — the subscriber setup utility
  (client-side; links against `libpq` and frontend-support symbols exported
  by the PostgreSQL backend).
* `pglogical.control` and all `pglogical--*.sql` scripts — generated/copied
  from the upstream checkout.

The upstream PGXS `Makefile` is the authoritative description of build
inputs. The source list and export list used by the build are pinned in
`CMakeLists.txt` and `cmake/exports.json` (the latter also drives the
deterministic `.def` files); the extension SQL scripts are copied from the
upstream checkout at install time.

## Prerequisites (Windows x64)

| Tool | Requirement |
| --- | --- |
| Windows | x64, 10 or later |
| PowerShell | 7.x (`pwsh`) |
| Visual Studio | 2022 or newer, "Desktop development with C++" workload, including the **"C++ Clang tools for Windows"** component (LLVM/clang-cl) |
| CMake | >= 3.24 on `PATH` |
| PostgreSQL | official EnterpriseDB Windows installation for the major you build (see below) |
| Git | any recent version |

**Why clang-cl?** The build compiles with **clang-cl** (LLVM's
MSVC-compatible compiler frontend, part of the Visual Studio toolchain) and
links with the MSVC linker (`link.exe`) against the MSVC CRT and
PostgreSQL's import libraries. Upstream pglogical puts preprocessor
directives inside function-call argument lists (e.g. `ExecInsertIndexTuples(`
with `#if PG_VERSION_NUM >= 140000` between the arguments), a GCC-style
pattern that Microsoft's `cl` preprocessor rejects. clang-cl accepts the
same MSVC flags and produces the same ABI; `dumpbin` validation and the
resulting binaries are unchanged. The Windows build job on GitHub Actions
already ships LLVM, so CI needs no extra setup.

Nothing is installed machine-globally by the scripts; all work happens in
temporary directories under `.build/`.

## Getting PostgreSQL (PG_ROOT)

The build needs the PostgreSQL server headers and import libraries:

* `include\pg_config.h`, `include\libpq-fe.h`
* `include\server\postgres.h`
* `include\server\port\win32_msvc\` (dirent.h, unistd.h, ...)
* `include\server\port\win32\` (sys/wait.h, ...)
* `lib\postgres.lib`, `lib\libpq.lib`, `lib\libintl.lib`

### Option A: existing EDB installation

Point `-PgRoot` at your installation, e.g.
`C:\Program Files\PostgreSQL\18`. The include order used by the build is the
order documented by EDB for Visual Studio builds:

```
<PG_ROOT>\include\server\port\win32_msvc
<PG_ROOT>\include\server\port\win32
<PG_ROOT>\include\server
<PG_ROOT>\include
```

### Option B: isolated download (recommended)

`scripts/Install-PostgreSql.ps1` downloads the official EDB "binaries" ZIP
(`postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip`) from
`get.enterprisedb.com` (the EnterpriseDB-controlled host). The minor
version is derived automatically from
`https://www.postgresql.org/versions.json` (the authoritative source for
latest supported minors), and the exact EDB packaging revision is resolved
by the hardened probing described in RELEASING.md (revision `-1` is never
silently assumed), so you never need to look up or pin minor versions or
revisions manually. The download is verified (TLS, content length, ZIP
integrity, major + minor version match), and expanded into an isolated
directory without touching the system:

```powershell
.\scripts\Install-PostgreSql.ps1 -Major 18
# => .pg\installs\pg18\pgsql   (this is PG_ROOT)
```

After a successful install, `EDB-INSTALL-INFO.json` is written next to the
installation recording the exact artifact identity (major, minor, build
version, EDB packaging revision, artifact filename/URL, post-download
SHA-256, install time). An existing installation is **reused only when
every field matches the requested exact artifact** — same major *and*
minor *and* EDB packaging revision *and* filename/URL, with a consistent
cached archive hash. Any mismatch (older minor, older packaging revision,
missing/malformed metadata, stale cache) triggers a clean reinstall; the
EDB packaging revision is never inferred from PostgreSQL headers (they do
not contain it).

If you need a specific minor version (e.g. for reproducible local builds),
pass `-Minor` and `-BinariesUrl` explicitly:

```powershell
.\scripts\Install-PostgreSql.ps1 -Major 18 -Minor 4 -BinariesUrl "https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip"
```

> **Checksums:** EDB does not publish an official checksum for the binaries
> ZIPs, so none is enforced; the download is verified via HTTPS, the
> server-provided Content-Length, ZIP structural integrity, and a
> `PG_VERSION_NUM` match. Static sha256 pinning is deliberately out of
> scope. The installers are cached under `.pg-cache` and are never
> committed or redistributed.

## One-shot build

```powershell
# From the repository root:
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -UpstreamTag "REL2_4_8" `
  -Configuration Release
```

What it does:

1. validates `PG_ROOT` (headers + import libraries) and reads the PostgreSQL
   major from `pg_config.h`;
2. clones `https://github.com/2ndQuadrant/pglogical` at `REL2_4_8`
   (shallow) into `.build\REL2_4_8\upstream`;
3. checks that the upstream source has a `compat<major>` implementation for
   your PostgreSQL major;
4. configures CMake with the `Visual Studio 17 2022` generator (`x64`) and
   builds the selected configuration;
5. verifies the DLL exports with `dumpbin` (module magic, `_PG_init`,
   `_PG_output_plugin_init`, and all SQL-callable functions);
6. prints the staging directory.

To use an existing upstream checkout instead of cloning:

```powershell
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -SourceDir "C:\src\pglogical" -SkipClone
```

## Testing the staged build

`scripts/Test-PgLogical.ps1` installs the staged package into the isolated
PostgreSQL tree, runs `initdb`, configures `wal_level = logical` and
`shared_preload_libraries = 'pglogical'`, starts the server with `pg_ctl`,
runs `CREATE EXTENSION pglogical`, verifies `extversion`, creates and drops
a logical replication slot with `pglogical_output`, runs
`pglogical_create_subscriber.exe --help`, and then runs the utility
end-to-end (basebackup + physical catchup + live subscription against a
real provider, verifying both the basebackup data and live replication).
Finally it stops the server and scans the log for errors.

```powershell
.\scripts\Test-PgLogical.ps1 `
  -PgRoot ".pg\installs\pg18\pgsql" `
  -StagingDir ".build\REL2_4_8\stage" `
  -UpstreamVersion "2.4.8"
```

Note: PostgreSQL's postmaster refuses to start under an elevated
(administrator) token. The test script detects that case and launches
`initdb`/`pg_ctl`/`postgres` through `runas /trustlevel:0x20000` (a
restricted token), which is exactly the situation on GitHub-hosted Windows
runners.

## Packaging

`scripts/Package-PgLogical.ps1` creates the ZIP and appends its SHA-256 to
`SHA256SUMS.txt`:

```powershell
.\scripts\Package-PgLogical.ps1 `
  -StagingDir ".build\REL2_4_8\stage" `
  -SourceDir ".build\REL2_4_8\upstream" `
  -Version "2.4.8" -PgMajor 18
# => .build\packages\pglogical-2.4.8-pg18-w1-x64.zip
```

## Manual CMake usage

The scripts wrap CMake; you can also drive it directly:

```powershell
cmake -S . -B .build\cmake `
  -G "Visual Studio 17 2022" -A x64 -T ClangCL `
  -DPG_ROOT="C:\Program Files\PostgreSQL\18" `
  -DPG_MAJOR=18 `
  -DPGLOGICAL_SOURCE_DIR=".build\REL2_4_8\upstream" `
  -DPGLOGICAL_VERSION="2.4.8"
cmake --build .build\cmake --config Release
cmake --install .build\cmake --config Release --prefix .build\stage
```

## CI behavior

* `ci.yml` runs PowerShell static analysis, YAML/JSON validation, and a real
  Windows build + smoke test against PostgreSQL 18 (dry-run, no release).
* The smoke test (`scripts/Test-PgLogical.ps1`) initializes a real cluster
  (de-elevated on CI runners, because postgres refuses an enabled
  Administrators group), loads the extension, verifies the export surface,
  creates a `pglogical_output` logical slot, and then runs an end-to-end
  replication test: provider and subscriber nodes on the same instance
  (separate databases), a subscription, and a live row replicated from the
  provider to the subscriber. `pglogical_create_subscriber.exe` is also
  exercised: `--help` plus a full end-to-end subscriber setup (basebackup
  + physical catchup + live subscription) against the running provider.
* `release.yml` builds the full configured matrix (currently 14–18),
  runs the smoke test per major, packages, and publishes the GitHub
  release. See [RELEASING.md](RELEASING.md).
