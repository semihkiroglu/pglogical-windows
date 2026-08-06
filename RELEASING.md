# RELEASING.md

How releases are discovered, built, and published, and how to handle
failures.

## PostgreSQL matrix synchronization

`pg-versions-sync.yml` runs daily at **03:00 UTC** and is also manually
dispatchable. It fetches `https://www.postgresql.org/versions.json`, and for
each supported major resolves the exact EDB Windows x64 binaries artifact
(including its packaging revision) on the official EDB host before
considering a new major available. Explicitly EOL majors
(`supported=false`) are removed from `.github/pg-versions.json`; a transient
resolution failure retains an already configured major. The workflow
commits only a real config diff. It refuses to persist an empty derived
matrix, preserving the last valid configuration for manual review.

EDB-ready new majors are emitted as candidates, but are not persisted until a
caller supplies them as compatibility-eligible. This keeps matrix discovery
separate from the upstream compat/build policy.

## Exact EDB artifact resolution

PostgreSQL minors are pinned to `https://www.postgresql.org/versions.json`
(the authoritative latest-supported source). The exact Windows x64 binaries
artifact is then resolved directly on the official EDB host
(`get.enterprisedb.com`) by HEAD-probing `postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip`
in ascending revision order and taking the **highest revision that exists**.

Packaging revision `-1` is **never silently assumed**: EDB can republish the
same minor under a new packaging revision (e.g. `postgresql-18.4-1-...` →
`postgresql-18.4-2-...`), and the extension must be compiled and linked
against the headers/import libraries of the exact distribution it ships
with. No third-party package manifest (Scoop, Chocolatey, WinGet, …) is ever
used as a trust source. If no revision resolves, the caller fails closed
with a clear error instead of guessing. The resolved artifact is verified to
belong to the requested major/minor before anything is built, both by
filename construction and by the installed `PG_VERSION_NUM` after extraction.

The downloaded ZIP is cached by filename (and in CI by a cache key that
includes the exact artifact filename), so a different packaging revision can
never reuse the wrong cached ZIP. The post-download SHA-256 is calculated
and recorded in release provenance as a **calculated** checksum — EDB does
not publish official checksums for these archives, and none is claimed.

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
4. resolves the exact official EDB artifact for every configured PG major
   (see above); an unresolvable artifact fails the run (fail closed);
5. lists the local releases and, per PG major, compares the resolved EDB
   artifact filename with the one recorded in the latest release for that
   version × major:
   * no local release → plan `windows.1`;
   * same artifact filename → covered, no action;
   * newer artifact (minor and/or packaging revision) → plan the **next
     packaging revision** for that major only;
   * older artifact or an unrecorded/unparseable identity → fail closed;
6. emits an idempotent JSON build plan (single version × N majors);
7. does nothing when the latest release is already fully packaged;
8. dispatches `release.yml` for each missing entry.

**The EDB artifact identity is the rebuild trigger** — a post-download SHA
recalculation alone never triggers a release. Once a release exists with the
current artifact identity recorded, later watcher runs detect it as covered,
so there are no release loops.

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
* A new pglogical upstream version always starts at `windows.1`.
* A rebuild of the same pglogical version and PostgreSQL major caused by an
  EDB artifact change (new packaging revision or new filename of the exact
  official artifact) is released as the next revision (`windows.2`,
  `windows.3`, …) for the affected major(s) only. The watcher computes the
  next revision as the highest existing revision plus one; an existing tag
  is never overwritten or silently reused.
* A rebuild caused only by packaging changes (e.g. a fix in the ZIP layout
  or the release tooling, not in the pglogical source) can also be released
  as the next revision by dispatching `release.yml` with an explicit
  `packagingRevision`.
* Published releases are never overwritten or mutated; existing assets are
  never silently replaced. `release.yml` checks for an existing
  release before creating one and skips publication if it already exists.

## Release build pipeline

`release.yml` (reusable + manually dispatchable) for one upstream tag:

1. **resolve** (Ubuntu): validates the release (exists, published, tag
   pattern, >= baseline), resolves the exact upstream commit SHA, computes
   the PostgreSQL major matrix = configured majors in
   `.github/pg-versions.json` ∩ the upstream `compat<major>` directories,
   and resolves the exact official EDB artifact for every feasible major
   (fail closed when any is unresolvable). An
   optional `postgresMajors` input restricts the matrix (used by CI).
2. **build** (Windows, per major): installs the exact resolved EDB Windows
   binaries into an isolated directory (cached under the exact artifact
   filename), clones the exact upstream tag, verifies the expected upstream
   commit SHA against the checkout (always, even for caller-supplied
   checkouts), builds with CMake + MSVC, verifies DLL exports with
   `dumpbin`, runs the smoke test, packages the ZIP + per-major checksum,
   and records the EDB artifact filename and its calculated SHA-256.
3. **publish** (Ubuntu, `contents: write` only here): downloads all
   artifacts, verifies the expected ZIP count and every SHA-256 locally,
   creates a **draft** release pinned to the validated commit
   (`--target $GITHUB_SHA`), uploads all ZIPs and the aggregate
   `SHA256SUMS.txt`, and only then publishes the release. The release body
   records the exact EDB artifact filename, URL, and calculated SHA-256. On
   any failure the incomplete draft is deleted; a failed build never leaves
   a partial release.

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
* **The exact EDB artifact cannot be resolved:** the watcher and the
  release pipeline both fail closed with a clear error; nothing is planned
  or published. Check pg.org versions.json and get.enterprisedb.com
  availability, then re-run.

## Adding or retiring a PostgreSQL major

`.github/pg-versions.json` is the source of truth for the configured majors:

* **Add a major** (e.g. 19 after it becomes stable): matrix synchronization
  reports a candidate only after pg.org support and the EDB artifact
  resolution pass. A caller must also establish upstream compatibility
  before supplying the major as eligible for persistence. Minor versions
  are never pinned — they are always derived from pg.org at build time.
* **Retire a major:** remove its entry. Builds for it stop immediately.
  `pg-versions-sync.yml` also auto-removes explicitly EOL majors (`supported=false`
  in pg.org data).
* **Minor versions are automatic:** `scripts/Install-PostgreSql.ps1`
  derives the latest minor from pg.org on every run and resolves the exact
  packaging revision from the official EDB host. No manual minor bumps are
  needed. The CI cache key includes the exact EDB artifact filename, so
  installers re-download automatically when the artifact changes.

## Release body contents

Each release body records: pglogical version, upstream repository/release,
upstream commit SHA, packaging revision, the PostgreSQL major the package
was built for, the exact EDB binaries archive filename and URL, the
calculated post-download EDB SHA-256, toolchain details, the build workflow
run URL, the package checksums, and the unofficial-build disclaimer. The
template lives at `.github/release-body-template.md`.
