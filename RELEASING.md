# RELEASING.md

How releases are discovered, built, and published, and how to handle
failures.

## PostgreSQL matrix synchronization

`pg-versions-sync.yml` runs daily at **03:00 UTC** and is also manually
dispatchable. It fetches `https://www.postgresql.org/versions.json`, derives
the EDB Windows binaries URL for each supported major, and HEAD-probes that
URL before considering a new major available. Explicitly EOL majors
(`supported=false`) are removed from `.github/pg-versions.json`; a transient
HEAD failure retains an already configured major. The workflow commits only a
real config diff. It refuses to persist an empty derived matrix, preserving
the last valid configuration for manual review.

EDB-ready new majors are emitted as candidates, but are not persisted until a
caller supplies them as compatibility-eligible. This keeps matrix discovery
separate from the upstream compat/build policy.

## Upstream release discovery

`upstream-watch.yml` runs daily at **03:30 UTC** (after the 03:00 UTC
matrix sync, so it sees the latest config) and is also manually
dispatchable. It runs on an
Ubuntu runner (cheap) and:

1. queries the **single latest published release**
   of `2ndQuadrant/pglogical` via `GET /repos/{owner}/{repo}/releases/latest`
   (which excludes drafts and prereleases by definition). A 404 (meaning
   all releases are draft or prerelease) is a silent no-op.
2. validates the tag against `^REL[0-9]+_[0-9]+_[0-9]+$`;
3. ignores it if below the **2.4.8 baseline** configured in
   `.github/pg-versions.json`;
4. lists the local releases and computes which PG majors are missing;
5. emits an idempotent JSON build plan (single version × N majors);
6. does nothing when the latest release is already fully packaged;
7. dispatches `release.yml` for each missing entry.

**Semantics change from previous design:** only the single NEWEST missing
upstream version is ever considered. Intermediate skipped versions are never
backfilled. The full release-list poll has been replaced with a single
`/releases/latest` call.

Upstream release events are never listened to directly (external
repositories cannot deliver them), and the poll is safe to run repeatedly.
A concurrency group (`upstream-watch`) prevents two schedule/manual
runs from overlapping, and `release.yml` has a per-version concurrency
group (`release-<tag>-<revision>`), so the same version can never be
published twice concurrently.

## Local release tags and packaging revisions

One GitHub release per upstream pglogical release **and** PostgreSQL major:

```
pglogical-2.4.8-pg14-windows.1
pglogical-2.4.8-pg15-windows.1
```

* `2.4.8` identifies the upstream release.
* `pg14` identifies the PostgreSQL major the package was built for.
* `windows.1` is the packaging revision.
* A rebuild caused only by packaging changes (e.g. a fix in the ZIP layout
  or the release tooling, not in the pglogical source) can be released as
  `windows.2`.
* Automated synchronization of a new upstream release always starts at
  revision 1.
* Published releases are never overwritten or mutated; existing assets are
  never silently replaced. `release.yml` checks for an existing
  release before creating one and skips publication if it already exists.

## Release build pipeline

`release.yml` (reusable + manually dispatchable) for one upstream tag:

1. **resolve** (Ubuntu): validates the release (exists, published, tag
   pattern, >= baseline), resolves the exact upstream commit SHA, and
   computes the PostgreSQL major matrix = configured majors in
   `.github/pg-versions.json` ∩ the upstream `compat<major>` directories. An
   optional `postgresMajors` input restricts the matrix (used by CI).
2. **build** (Windows, per major): installs the official EDB Windows
   binaries into an isolated directory (cached), clones the exact upstream
   tag, builds with CMake + MSVC, verifies DLL exports with `dumpbin`, runs
   the smoke test, and packages the ZIP + per-major checksum.
3. **publish** (Ubuntu, `contents: write` only here): downloads all
   artifacts, verifies the expected ZIP count and every SHA-256 locally,
   creates a **draft** release, uploads all ZIPs and the aggregate
   `SHA256SUMS.txt`, and only then publishes the release. On any failure
   the incomplete draft is deleted; a failed build never leaves a partial
   release.

## Manual dispatch

```bash
# Build + publish pglogical 2.4.8 for all supported majors:
gh workflow run release.yml -f upstreamTag=REL2_4_8 -f packagingRevision=1

# Rebuild without touching the release (e.g. for CI experiments):
gh workflow run release.yml -f upstreamTag=REL2_4_8 -f dryRun=true

# Build only some majors:
gh workflow run release.yml -f upstreamTag=REL2_4_8 -f postgresMajors=17,18
```

## Failure recovery

* **A build job fails:** fix the issue in a PR (CI re-runs the whole
  pipeline in dry-run mode), then re-run `release.yml`. The failed run
  never created a release, so nothing needs cleanup.
* **Publication fails mid-way:** the draft release is deleted by the
  cleanup step. Verify with `gh release list --exclude-drafts`; if a draft
  remains, delete it (`gh release delete <tag> --yes --cleanup-tag`) and
  re-run.
* **A release already exists:** publication is skipped, never overwritten.
  If the release is broken beyond repair, publish a new packaging revision
  (`-f packagingRevision=2`) instead of mutating the old one.
* **Upstream tag disappears or is force-changed:** the resolve step fails
  with a clear error; nothing is published. Re-verify the upstream release
  before retrying.

## Adding or retiring a PostgreSQL major

`.github/pg-versions.json` is the source of truth for the configured majors:

* **Add a major** (e.g. 19 after it becomes stable): matrix synchronization
  reports a candidate only after pg.org support and the EDB HEAD probe pass.
  A caller must also establish upstream compatibility before supplying the
  major as eligible for persistence. Minor versions are never pinned — they
  are always derived from pg.org at build time.
* **Retire a major:** remove its entry. Builds for it stop immediately.
  `pg-versions-sync.yml` also auto-removes explicitly EOL majors (`supported=false`
  in pg.org data).
* **Minor versions are automatic:** `scripts/Install-PostgreSql.ps1`
  derives the latest minor from pg.org on every run. No manual minor bumps
  are needed. The CI cache key includes `.github/pg-versions.json`, so
  installers re-download automatically on config changes.

## Release body contents

Each release body records: pglogical version, upstream repository/release,
upstream commit SHA, packaging revision, the PostgreSQL major the package
was built for, toolchain details, the build workflow run URL, the package
checksums, and the unofficial-build disclaimer. The template lives at
`.github/release-body-template.md`.
