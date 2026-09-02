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
(the authoritative latest-supported source; the response is validated before
use). The exact Windows x64 binaries artifact is resolved on the
EDB-controlled download host (`get.enterprisedb.com`) by **controlled
availability probing** of
`postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip`.

This is **heuristic availability discovery, not an authoritative EDB
manifest** (PostgreSQL's JSON does not carry the EDB packaging revision,
and no official EDB machine-readable current-artifact feed exists). The
resolver therefore:

* validates every candidate URL (https, `get.enterprisedb.com`, correct
  path and archive filename, matching major/minor/revision) before any
  request;
* probes with HEAD, falling back to a minimal `Range: bytes=0-0` GET only
  when HEAD is explicitly unsupported for a non-transient protocol reason
  (the full ZIP is never downloaded just to check existence);
* classifies every probe result as **Available / NotFound /
  TransientFailure / InvalidResponse**. Only a definitive 404/410 — or the
  observed EDB/CDN 403 `AccessDenied` S3 signature for absent artifacts —
  means "not present". Timeouts, DNS/TLS/socket failures, 408/425/429/5xx
  are indeterminate and are retried a bounded number of times with short
  backoff; after retry exhaustion the run **fails closed** — an older
  revision is never silently substituted;
* rejects redirects (none are observed on the EDB host; any redirect —
  HTTPS downgrade or foreign host — fails closed);
* probes the **entire bounded revision range** `1..MaxRevision` (default
  10, configurable for tests), so a gap (`-1` and `-3` present, `-2`
  absent) still resolves `-3`;
* returns no artifact only when **every** candidate is conclusively absent,
  and fails when the highest available revision equals the configured bound
  (a higher revision may exist beyond it).

Packaging revision `-1` is **never silently assumed**. No third-party
package manifest (Scoop, Chocolatey, WinGet, …) is ever used as a trust
source. The resolved artifact is verified to belong to the requested
major/minor before anything is built, both by filename construction and by
the installed `PG_VERSION_NUM` after extraction.

The downloaded ZIP is cached by filename (and in CI by a cache key that
includes the exact artifact filename), so a different packaging revision can
never reuse the wrong cached ZIP. The post-download SHA-256 is calculated
and recorded in release provenance as a **calculated** checksum — EDB does
not publish official checksums for these archives, and none is claimed.

## Release-plan pinning

`upstream-watch.yml` resolves every EDB artifact **once**, at planning
time, and dispatches a **single** `release.yml` run carrying the complete
pinned plan (one entry per PostgreSQL major in one unified release, with the
exact EDB artifact identity per entry — different majors may use different EDB
revisions). `release.yml` validates the whole plan before any build
(malformed JSON, duplicate majors, invalid revisions, non-HTTPS/non-EDB
URLs, filename identity mismatches, upstream tag/commit SHA) and verifies
every pinned URL is still conclusively available — without re-discovering
or substituting a newer revision. A newer EDB revision appearing after
planning is picked up by the next watcher run, not by the current build.

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
5. lists the local releases and compares unified package coverage:
   * no local release or no complete unified release → plan `w1` (or the
     next unused unified revision);
   * a published unified release with the expected package asset for every
     configured major → covered, no action;
   * legacy per-major releases are read as migration coverage only;
   * an incomplete unified release → plan the next revision with **all**
     configured major assets, because a published release is immutable;
6. emits an idempotent JSON build plan (one unified version × Windows revision,
   with one entry per PostgreSQL major and each entry pinning its exact EDB
   artifact);
7. does nothing when the latest release is already fully packaged;
8. dispatches **one** `release.yml` run with the complete pinned plan. The
   build jobs remain a PostgreSQL matrix, but publication is a single job that
   attaches every ZIP and one aggregate checksum file to one GitHub release.

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
runs from overlapping, and `release.yml` has a unified per-version
concurrency group (`release-<workflow>-<ref>`), so only one aggregate
release can be published at a time.

## Local release tags and packaging revisions

One GitHub release per upstream pglogical release and Windows packaging
revision, with one asset per configured PostgreSQL major:

```
Release title: 2.4.8 for Windows (W1)
Git tag:       2.4.8-w1
Packages:      pglogical-2.4.8-pg14-w1-x64.zip ... pglogical-2.4.8-pg18-w1-x64.zip
Checksum:      SHA256SUMS.txt
```

* `2.4.8` identifies the upstream release.
* `w1` identifies the unified Windows packaging revision in the Git tag and in
  every major-specific package filename; the release title renders it as `W1`.
* The PostgreSQL major belongs to the package asset identity, not the GitHub
  release identity.
* A new pglogical upstream version starts at unified `w1`.
* If any configured major needs a compatibility rebuild, the next unified
  revision (`w2`, `w3`, …) rebuilds and publishes **all** configured majors so
  every release remains self-contained. The watcher computes the next revision
  as the highest existing unified revision plus one; an existing tag is never
  overwritten or silently reused.
* A rebuild caused only by packaging changes (e.g. a fix in the ZIP layout or
  release tooling, not in the pglogical source) can also be released as the
  next unified revision by dispatching `release.yml` with an explicit
  `packagingRevision`.
* Published releases are never overwritten or mutated; existing assets are
  never silently replaced. `release.yml` checks for an existing release before
  creating one and verifies a pre-existing tag has the complete expected asset
  set before skipping publication.

## Release build pipeline

`release.yml` (reusable + manually dispatchable) for one upstream tag:

1. **resolve** (Ubuntu): validates the release (exists, published, tag
   pattern, >= baseline), resolves the exact upstream commit SHA, computes
   the PostgreSQL major matrix = configured majors in
   `.github/pg-versions.json` ∩ the upstream `compat<major>` directories,
   and resolves the exact official EDB artifact for every feasible major
   (fail closed when any is unresolvable). An optional `postgresMajors`
   input restricts the matrix (used by CI). When a pinned `planJson` input
   is supplied (the watcher path), the whole plan is validated first and
   every pinned EDB URL is verified still available — no discovery or
   substitution happens in the build.
2. **build** (Windows, per plan entry): installs the exact pinned EDB
   Windows binaries into an isolated directory (reused only on exact
   artifact-identity match via `EDB-INSTALL-INFO.json`, cached under the
   exact artifact filename), clones the exact upstream tag, verifies the
   expected upstream commit SHA against the checkout (always, even for
   caller-supplied checkouts), builds with CMake + MSVC, verifies DLL
   exports with `dumpbin`, runs the smoke test, and packages the
   compatibility-major ZIP (`pglogical-<v>-pg<major>-w<rev>-x64.zip`) with an
   embedded `BUILD-INFO.json`. Each build also records the EDB artifact
   filename and its calculated SHA-256 for the aggregate publisher.
3. **publish** (Ubuntu, `contents: write` only here): downloads every
   `packages-pg<major>` artifact from the matrix, verifies exactly one expected
   ZIP and its checksum/provenance per configured major, creates one **draft**
   release pinned to the validated commit (`--target $GITHUB_SHA`) with the
   title `<version> for Windows (W<revision>)`, uploads all ZIPs and one
   aggregate `SHA256SUMS.txt`, and only then publishes the release. The release
   body records one provenance section per PostgreSQL major: exact build
   version, EDB packaging revision, EDB artifact filename/URL, and the
   project-calculated EDB archive SHA-256. On any failure the incomplete draft
   is deleted; a failed build never leaves a partial release.
4. **set-latest** (Ubuntu): after the single publish job succeeds, GitHub
   Latest is reconciled deterministically to the complete unified release for
   this pglogical version. The selector requires every configured major's ZIP
   asset, so a partial release can never become Latest.
## One-time legacy release migration

The repository may contain historical per-major tags such as
`2.4.8-pg18-w1`. They are read-only migration inputs and are not produced by
new code. To migrate an existing version, generate an explicit full unified
plan:

```bash
pwsh -NoProfile -File ./scripts/Get-UpstreamReleases.ps1 \
  -ForceUnified -OutputFile /tmp/pglogical-unified-migration-plan.json

# Extract only the validated plan-entry array for planJson:
pwsh -NoProfile -Command '$p = Get-Content /tmp/pglogical-unified-migration-plan.json -Raw | ConvertFrom-Json; $p.plan | ConvertTo-Json -Compress -Depth 10 | Set-Content /tmp/pglogical-unified-plan-entries.json'

# Inspect the entry array, then dispatch it as a pinned plan:
gh workflow run release.yml \
  -f planJson="$(< /tmp/pglogical-unified-plan-entries.json)"
```

Do not delete historical releases until the new unified release has completed
and its tag, complete ZIP asset set, aggregate checksum, and `releases/latest`
read-back have all been verified. If the unified publication fails, leave the
historical releases intact and investigate the failed run. After successful
verification, delete only the explicitly identified legacy release/tag pairs;
never reuse an immutable tag.

## Manual dispatch

```bash
# Build + publish pglogical 2.4.8 for all supported majors (discovery mode):
gh workflow run release.yml -f upstreamTag=REL2_4_8 -f packagingRevision=1

# Build + publish from a pinned unified plan (the watcher path; one entry
# per major, all entries share one <version>-w<revision> tag):
gh workflow run release.yml -f planJson='[{"pglogicalVersion":"2.4.8", ...}]'

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

Each unified release body records: pglogical version, upstream
repository/release, upstream commit SHA, Windows packaging revision, one
provenance section per PostgreSQL major (exact build version, EDB packaging
revision, EDB binaries archive filename and URL, and the calculated
post-download EDB SHA-256), toolchain details, the build workflow run URL, the
aggregate package checksums, and the unofficial-build disclaimer. The template
lives at `.github/release-body-template.md`.
