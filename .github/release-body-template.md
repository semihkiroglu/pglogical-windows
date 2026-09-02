## Provenance

| Field | Value |
| --- | --- |
| pglogical version | {{VERSION}} |
| Upstream repository | [{{UPSTREAM_REPO}}](https://github.com/{{UPSTREAM_REPO}}) |
| Upstream release tag | [{{UPSTREAM_TAG}}](https://github.com/{{UPSTREAM_REPO}}/releases/tag/{{UPSTREAM_TAG}}) |
| Upstream commit SHA | `{{COMMIT_SHA}}` |
| Windows packaging revision | W{{PACKAGING_REVISION}} |
| PostgreSQL compatibility major | {{PG_MAJOR}} |
| PostgreSQL exact build version | {{PG_BUILD_VERSION}} |
| EDB packaging revision | {{EDB_REVISION}} |
| EDB binaries archive | `{{EDB_ARCHIVE}}` |
| EDB binaries URL | <{{EDB_URL}}> |
| EDB binaries SHA-256 (calculated post-download by this project, not a vendor-published checksum) | `{{EDB_BINARIES_SHA256}}` |
| Architecture / configuration | x64 / Release |
| Build workflow run | [{{RUN_URL}}]({{RUN_URL}}) |

> **Note on the exact build input:** PostgreSQL.org versions.json determines the supported current `major.minor`. The EDB packaging revision is resolved by controlled probing of the EDB-controlled download host (heuristic availability discovery — not an authoritative EDB manifest); any network ambiguity fails closed. The artifact is pinned from planning through build, and the EDB archive SHA-256 is calculated by this project after download.

## Packages

`pglogical-{{VERSION}}-pg{{PG_MAJOR}}-w{{PACKAGING_REVISION}}-x64.zip`

The package ZIP name and GitHub release tag identify the upstream version, PostgreSQL compatibility major, and Windows packaging revision. The exact PostgreSQL build version and EDB packaging revision remain in `BUILD-INFO.json` and the provenance table. This package runs on **any** minor of PostgreSQL {{PG_MAJOR}}: PostgreSQL guarantees binary compatibility within a major version, and the server's module magic-block check is major-granular.

Unzip into a matching PostgreSQL installation directory (e.g. `C:\Program Files\PostgreSQL\{{PG_MAJOR}}`) so that `lib\`, `share\extension\`, and `bin\` merge with the existing layout. Install on both provider and subscriber nodes.

Server configuration and node setup follow upstream pglogical — see the [pglogical README](https://github.com/{{UPSTREAM_REPO}}#readme) for the required settings (`shared_preload_libraries = 'pglogical'`, `wal_level = logical`, worker/slot limits) and the `CREATE EXTENSION pglogical` / node registration steps.

## Checksums (SHA-256)

```
{{CHECKSUMS}}
```

---

> **Unofficial build.** These packages are produced by an independent, out-of-tree Windows build of upstream pglogical and are **not** published, endorsed, or supported by EnterpriseDB, 2ndQuadrant, or the PostgreSQL Global Development Group. Use at your own risk.
