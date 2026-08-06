## Provenance

| Field | Value |
| --- | --- |
| pglogical version | {{VERSION}} |
| Upstream repository | [{{UPSTREAM_REPO}}](https://github.com/{{UPSTREAM_REPO}}) |
| Upstream release | [{{UPSTREAM_TAG}}](https://github.com/{{UPSTREAM_REPO}}/releases/tag/{{UPSTREAM_TAG}}) |
| Upstream commit SHA | `{{COMMIT_SHA}}` |
| Packaging revision | windows.{{PACKAGING_REVISION}} |
| PostgreSQL version | {{PG_MAJOR}} |
| EDB binaries archive | `{{EDB_ARCHIVE}}` |
| EDB binaries URL | <{{EDB_URL}}> |
| EDB binaries SHA-256 (calculated post-download by this project, not a vendor-published checksum) | `{{EDB_BINARIES_SHA256}}` |
| Architecture / configuration | x64 / Release |
| Build workflow run | [{{RUN_URL}}]({{RUN_URL}}) |

## Packages

`pglogical-{{VERSION}}-pg{{PG_MAJOR}}-windows-x64.zip`

Unzip into a matching PostgreSQL installation directory (e.g. `C:\Program Files\PostgreSQL\{{PG_MAJOR}}`) so that `lib\`, `share\extension\`, and `bin\` merge with the existing layout. Install on both provider and subscriber nodes.

Server configuration and node setup follow upstream pglogical — see the [pglogical README](https://github.com/{{UPSTREAM_REPO}}#readme) for the required settings (`shared_preload_libraries = 'pglogical'`, `wal_level = logical`, worker/slot limits) and the `CREATE EXTENSION pglogical` / node registration steps.

## Checksums (SHA-256)

```
{{CHECKSUMS}}
```

---

> **Unofficial build.** These packages are produced by an independent, out-of-tree Windows build of upstream pglogical and are **not** published, endorsed, or supported by EnterpriseDB, 2ndQuadrant, or the PostgreSQL Global Development Group. Use at your own risk.
