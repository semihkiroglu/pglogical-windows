# Contributing to pglogical for Windows

Thanks for considering a contribution! This is a small, focused project that
packages the upstream [pglogical](https://github.com/2ndQuadrant/pglogical)
extension for PostgreSQL on Windows x64. Contributions are welcome — please
keep them focused. This repository builds and distributes; it does not develop
pglogical itself.

## What belongs here

* Windows build failures and fixes (CMake, scripts, toolchain issues).
* PostgreSQL-version compatibility problems in the Windows packages.
* Packaging issues (ZIP layout, missing files, `BUILD-INFO.json`, checksums).
* Workflow / release engineering issues (GitHub Actions, release automation).
* Windows-specific pglogical patches.
* Documentation improvements.

## What generally belongs upstream

* Generic pglogical behavior unrelated to Windows packaging.
* Upstream logical replication bugs.
* Generic SQL/API behavior already present in the upstream source.

When opening an issue, first determine whether the problem is in upstream
pglogical or in this Windows build/distribution. Issues about this repository
go in [our issue tracker](https://github.com/semihkiroglu/pglogical-windows/issues);
upstream issues belong at
[https://github.com/2ndQuadrant/pglogical/issues](https://github.com/2ndQuadrant/pglogical/issues).
If you are not sure, open an issue here — we will help route it.

## Development expectations

* Create a branch and open a pull request against `main`. Main is protected:
  a pull request is required and CI must pass before merge.
* Keep changes focused on a single concern.
* Run the existing tests: `./tests/run-tests.ps1` (PowerShell unit tests,
  no external dependencies) — CI runs them on every PR.
* Preserve upstream provenance: do **not** vendor upstream source into this
  repository. Builds always clone the exact upstream release tag, and the
  expected commit SHA is verified before building.
* Windows-specific patches should be version-specific where appropriate
  (`patches/pglogical-<version>-windows.patch`) and must apply cleanly to the
  pinned upstream tag.
* CI must pass, including the Windows build + smoke test when build-relevant
  files change.
* Keep all user-facing text (PRs, issues, documentation) in English.

See [BUILDING.md](BUILDING.md) for the local build/test/packaging workflow and
[RELEASING.md](RELEASING.md) for how releases are produced.

There is no formal governance process and no CLA — just open an issue or a
pull request.
