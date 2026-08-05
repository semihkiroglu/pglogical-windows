# pglogical for Windows

Unofficial Windows x64 packages of the [pglogical](https://github.com/2ndQuadrant/pglogical)
PostgreSQL logical replication extension, built with CMake + MSVC against
official EnterpriseDB PostgreSQL Windows installations.

**This is an unofficial packaging project.** The packages are produced by an
independent, out-of-tree build of the upstream pglogical source. They are not
published, endorsed, or supported by EnterpriseDB, 2ndQuadrant, or the
PostgreSQL Global Development Group.

## What this repository provides

* An out-of-tree **CMake + MSVC** build of upstream pglogical for Windows
  x64 — no MSYS2/MinGW, no Meson, no source-built PostgreSQL, no Docker.
* Build and release automation on GitHub Actions:
  * `ci.yml` — validation and a real Windows build + smoke test.
  * `upstream-watch.yml` — daily discovery of new upstream releases.
  * `release.yml` — the full PostgreSQL 14–18 build matrix and release
    publication.
  * `pg-versions-sync.yml` — daily PostgreSQL version matrix sync.
* One GitHub release per PostgreSQL major, tagged
  `pglogical-<version>-pg<major>-windows.<rev>` (e.g.
  `pglogical-2.4.8-pg18-windows.1`), each with a ZIP and a `SHA256SUMS.txt`.
* Local PowerShell tooling (`scripts/`) for building and testing on Windows.

The upstream pglogical repository is never modified, forked, or vendored;
every build clones the exact upstream release tag.

## Supported versions

| PostgreSQL major | Status |
| --- | --- |
| 14 | supported |
| 15 | supported |
| 16 | supported |
| 17 | supported |
| 18 | supported |
| 19 | not included (prerelease); enable deliberately via `.github/pg-versions.json` |

The build matrix for an upstream release is the intersection of the
configured majors in [.github/pg-versions.json](.github/pg-versions.json) and the PostgreSQL
versions that the upstream source supports (its `compat<major>` directories).

Architecture: **x64 only**. Configuration: **Release only**.

## Packages

Every published release contains one ZIP per PostgreSQL major:

```
pglogical-<pglogical-version>-pg<postgres-major>-windows-x64.zip
```

Example: `pglogical-2.4.8-pg18-windows-x64.zip`

Each ZIP has an installation-oriented layout:

```
lib/
  pglogical.dll
  pglogical_output.dll
share/
  extension/
    pglogical.control
    pglogical--*.sql
    pglogical_origin.control
    pglogical_origin--1.0.0.sql
bin/
  pglogical_create_subscriber.exe
```

No PostgreSQL/EDB binaries, headers, or libraries are bundled. The upstream
pglogical copyright notice is included in each package.

## Installation

1. Download the ZIP matching your PostgreSQL major from the
   [releases](./releases) page.
2. Verify the SHA-256 checksum against `SHA256SUMS.txt`.
3. Unzip into your PostgreSQL installation directory so that `lib\`,
   `share\extension\`, and `bin\` merge with the existing layout. For a
   standard EDB installation that is `C:\Program Files\PostgreSQL\<major>`.
4. **Both the provider and the subscriber node must install the package**
   for their PostgreSQL major.
5. Follow the official pglogical documentation for server configuration
   (`postgresql.conf` settings), `CREATE EXTENSION pglogical`, and node /
   subscription setup: <https://github.com/2ndQuadrant/pglogical>.

## Local build

Prerequisites: Windows x64, PowerShell 7, Visual Studio 2022+ with the
"Desktop development with C++" workload **and the "C++ Clang tools for
Windows" component** (the build compiles with clang-cl — see BUILDING.md
for why), CMake >= 3.24, and an official PostgreSQL Windows installation
(or run `scripts/Install-PostgreSql.ps1` to fetch one into an isolated
directory).

```powershell
# One-shot: download PG 18 into .pg\installs, clone REL2_4_8,
# build with CMake+MSVC, verify exports, stage the package.
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -UpstreamTag "REL2_4_8" `
  -Configuration Release
```

Full instructions in [BUILDING.md](BUILDING.md).

## Release synchronization

Release discovery, tagging, packaging-revision policy, and the daily
automation (`pg-versions-sync.yml` at 03:00 UTC, `upstream-watch.yml` at
03:30 UTC) are documented in [RELEASING.md](RELEASING.md).

## Compatibility limitations

* x64 only; 32-bit PostgreSQL is not supported.
* Built with the Visual Studio ClangCL toolset (clang-cl compiler, MSVC
  linker/CRT) against the official EnterpriseDB Windows binaries; other
  Windows builds of PostgreSQL (e.g. conda, MinGW) are not targets.
* `pglogical_create_subscriber.exe` is built, packaged, and exercised
  end-to-end by the CI: every release build runs the full
  basebackup/restore/catchup/subscription workflow against a live
  provider and verifies both the basebackup data and live replication
  (see `scripts/Test-PgLogical.ps1`, Step 9c). This applies to every
  supported PostgreSQL major, not just one.
* A single local patch is applied to the upstream source at build time
  (version-pinned: the build fails loudly if it no longer applies):
  - `patches/pglogical-2.4.8-windows.patch` — the Windows build fixes
    (rand/sys-stat for the subscriber tool, PGDLLEXPORT on
    `_PG_init`/`_PG_output_plugin_init`, shmem startup-hook wiring, DWORD
    exit code, `QuoteWindowsArgv`, empty `shared_preload_libraries` for
    the subscriber catchup start on cmd.exe).
* The extension is only as compatible with your PostgreSQL version as the
  upstream source is; see the upstream compatibility notes.

## Security

See [SECURITY.md](SECURITY.md) for how to report issues.

## License and attribution

The build tooling in this repository is licensed under the PostgreSQL
License (see [LICENSE](LICENSE)). The packaged pglogical extension is
copyright its upstream authors and shipped under the PostgreSQL License;
the packaged PostgreSQL binaries remain under their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
