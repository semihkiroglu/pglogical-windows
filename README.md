# pglogical for Windows

[![CI](https://github.com/semihkiroglu/pglogical-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/semihkiroglu/pglogical-windows/actions/workflows/ci.yml)
[![Releases](https://img.shields.io/badge/releases-download-2f6f4f)](https://github.com/semihkiroglu/pglogical-windows/releases)
[![License](https://img.shields.io/badge/license-PostgreSQL%20License-2f6f4f)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-0078d6)](BUILDING.md)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14--18-336791)](#compatibility)
[![pglogical](https://img.shields.io/badge/pglogical-2.4.8-2f6f4f)](https://github.com/2ndQuadrant/pglogical)

Unofficial Windows x64 packages of the [pglogical](https://github.com/2ndQuadrant/pglogical)
PostgreSQL logical replication extension, built with CMake + MSVC against
official EnterpriseDB PostgreSQL Windows installations.

**This is an unofficial packaging project.** The packages are produced by an
independent, out-of-tree build of the upstream pglogical source, which is
**not forked or vendored** here: every build clones the exact upstream release
tag, and Windows-specific patches, when needed, are applied only to the
ephemeral build checkout. The packages are not published, endorsed, or
supported by EnterpriseDB, 2ndQuadrant, the PostgreSQL Global Development
Group, or the upstream pglogical maintainers.

## Why this repository exists

Upstream pglogical does not provide Windows binary packages. This repository
provides an independent out-of-tree Windows x64 build and release pipeline for
pglogical using **CMake, the Visual Studio toolchain (clang-cl/MSVC), and
PowerShell** — no MSYS2/MinGW, no Meson, no source-built PostgreSQL, no Docker —
without maintaining a permanent fork of upstream pglogical.

The pipeline runs on GitHub Actions:

* `ci.yml` — validation and a real Windows build + smoke test.
* `upstream-watch.yml` — daily discovery of new upstream releases.
* `release.yml` — the full build matrix and release publication.
* `pg-versions-sync.yml` — daily PostgreSQL version matrix sync.

## Quick Install

1. Go to [GitHub Releases](https://github.com/semihkiroglu/pglogical-windows/releases)
   and download the ZIP matching your PostgreSQL build line, e.g.
   `pglogical-2.4.8-pg18-w1-x64.zip`. The exact PostgreSQL minor and EDB
   packaging revision used by that package are recorded in `BUILD-INFO.json`.
2. Verify the SHA-256 checksum against `SHA256SUMS.txt`.
3. Extract the ZIP into the root of your PostgreSQL installation (for a
   standard EDB installation: `C:\Program Files\PostgreSQL\<major>`) so that
   its `lib\`, `share\extension\`, and `bin\` directories merge into the
   existing layout.
4. Configure PostgreSQL as required by upstream pglogical — at minimum:

   ```conf
   shared_preload_libraries = 'pglogical'
   wal_level = logical
   ```

   PostgreSQL 14.24, 15.19, 16.15, 17.11, and 18.6 introduced the
   `output_plugin_libraries` security whitelist. On those versions and later,
   add `pglogical_output` on every node that can create pglogical logical
   replication slots (normally the provider):

   ```conf
   output_plugin_libraries = 'pgoutput, test_decoding, pglogical_output'
   ```

   Preserve any existing trusted entries when extending a custom whitelist;
   do not replace it blindly. Older PostgreSQL minors that do not expose this
   setting should omit the line. The setting is required because PostgreSQL
   now rejects unlisted logical decoding output plugins (CVE-2026-6471).

5. Restart PostgreSQL.
6. Run `CREATE EXTENSION pglogical;` on each database that needs it.

Install the package on **both** the provider and the subscriber node, for the
matching PostgreSQL major. For the full node / subscription setup and any
additional required settings (worker / slot limits), follow the upstream
[pglogical documentation](https://github.com/2ndQuadrant/pglogical).

## Compatibility

| PostgreSQL | pglogical | Platform |
| --- | --- | --- |
| 14 | 2.4.8 | Windows x64 |
| 15 | 2.4.8 | Windows x64 |
| 16 | 2.4.8 | Windows x64 |
| 17 | 2.4.8 | Windows x64 |
| 18 | 2.4.8 | Windows x64 |

The matrix is driven by [.github/pg-versions.json](.github/pg-versions.json):
the build matrix for an upstream release is the intersection of the configured
majors and the PostgreSQL versions the upstream source supports (its
`compat<major>` directories). PostgreSQL 19 (prerelease) is not included and
can only be enabled deliberately via `.github/pg-versions.json`.

The exact build version of every package — PostgreSQL minor and EDB packaging
revision — is recorded in the asset filename, the release provenance table, and
the embedded `BUILD-INFO.json`. That minor is a build-input identifier, not a
compatibility claim: each package runs on **any** minor of its PostgreSQL
major, because PostgreSQL guarantees binary compatibility within a major
version (the server's module magic-block check is major-granular).

Architecture: **x64 only**. Configuration: **Release only**. The extension is
only as compatible with your PostgreSQL version as the upstream source is.

## Release and asset naming

Each release contains one ZIP per PostgreSQL major. The GitHub release **tag**
identifies the PostgreSQL compatibility-major release stream
(`<version>-pg<major>-w<revision>`), and the release title follows
`<version> for PostgreSQL <major> (W<revision>)`. The asset **filename** uses
the same release identity:

```
pglogical-<pglogical-version>-pg<postgres-major>-w<packaging-revision>-x64.zip
```

Example: `pglogical-2.4.8-pg18-w1-x64.zip`

| Part | Meaning |
| --- | --- |
| `pglogical 2.4.8` | upstream pglogical version |
| `PostgreSQL 18` | compatibility major the package targets |
| `W1` | Windows packaging revision |
| `PostgreSQL 18.4` / `EDB packaging revision 2` | exact build provenance recorded in `BUILD-INFO.json` |
| `Windows x64` | platform / architecture |

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
BUILD-INFO.json
```

`BUILD-INFO.json` records the exact provenance: pglogical version, upstream
repository/tag/commit SHA, PostgreSQL compatibility major, exact build version,
EDB packaging revision, EDB artifact filename/URL, the EDB archive SHA-256
**calculated by this project after download** (never a vendor-published
checksum), the Windows packaging revision, and architecture/configuration.

No PostgreSQL/EDB binaries, headers, or libraries are bundled. The upstream
pglogical copyright notice is included in each package.

## Security and provenance

Release builds are engineered to be verifiable:

* **Upstream source is pinned.** Each release build resolves the upstream
  pglogical release tag, resolves and records its exact upstream commit SHA,
  and verifies the checkout against that expected commit before building.
* **No vendoring, no permanent fork.** Upstream source is never committed to
  this repository; version-specific Windows patches are applied only to the
  ephemeral build checkout when such a patch exists.
* **Exact PostgreSQL build input.** PostgreSQL major/minor comes from
  PostgreSQL.org's `versions.json`; the exact EnterpriseDB Windows binaries
  artifact (including its packaging revision) is resolved by **controlled
  availability probing** of the EDB-controlled download host. This is
  heuristic availability discovery, **not** an authoritative EDB manifest.
* **Pinned through the build.** The resolved artifact is pinned from planning
  through build; the post-download SHA-256 of the EDB archive is calculated by
  this project and recorded — EDB does not publish the checksums used here.
* **Published checksums.** Every release ships a `SHA256SUMS.txt` and packages
  embed `BUILD-INFO.json`.
* **Real testing before publication.** Every release build runs a real
  PostgreSQL install, `CREATE EXTENSION`, a logical slot check, and an
  end-to-end provider→subscriber replication smoke test per major.
* **Build provenance.** Release artifacts are attested with GitHub artifact
  attestations (build provenance) in the publish workflow.

Published releases are immutable: existing releases and assets are never
overwritten or mutated.

For more detail see [SECURITY.md](SECURITY.md) and [RELEASING.md](RELEASING.md).

## Building from source

Prerequisites:

- **Windows:** x64
- **PowerShell:** 7.x
- **Visual Studio:** 2022+ with the "Desktop development with C++" workload
  and the "C++ Clang tools for Windows" component
- **CMake:** >= 3.24
- **PostgreSQL:** a matching official Windows installation, or run
  `scripts/Install-PostgreSql.ps1` to fetch one into an isolated directory

The build compiles with clang-cl using the Visual Studio/MSVC toolchain; see
BUILDING.md for the rationale.

```powershell
# One-shot: download PG 18 into .pg\installs, clone REL2_4_8,
# build with CMake+MSVC, verify exports, stage the package.
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -UpstreamTag "REL2_4_8" `
  -Configuration Release
```

Full instructions in [BUILDING.md](BUILDING.md).

## Documentation

* [BUILDING.md](BUILDING.md) — local build, test, and packaging.
* [RELEASING.md](RELEASING.md) — release discovery, tagging, and automation.
* [SECURITY.md](SECURITY.md) — reporting and package security properties.
* [CONTRIBUTING.md](CONTRIBUTING.md) — what belongs here vs. upstream.
* [SUPPORT.md](SUPPORT.md) — where to ask for help.
* Upstream pglogical documentation: <https://github.com/2ndQuadrant/pglogical>

## License and attribution

The build tooling in this repository is licensed under the PostgreSQL
License (see [LICENSE](LICENSE)). The packaged pglogical extension is
copyright its upstream authors and shipped under the PostgreSQL License;
the packaged PostgreSQL binaries remain under their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
