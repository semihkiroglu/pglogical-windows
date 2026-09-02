## Provenance

| Field | Value |
| --- | --- |
| pglogical version | {{VERSION}} |
| Upstream repository | [{{UPSTREAM_REPO}}](https://github.com/{{UPSTREAM_REPO}}) |
| Upstream release tag | [{{UPSTREAM_TAG}}](https://github.com/{{UPSTREAM_REPO}}/releases/tag/{{UPSTREAM_TAG}}) |
| Upstream commit SHA | `{{COMMIT_SHA}}` |
| Windows packaging revision | W{{PACKAGING_REVISION}} |
| Architecture / configuration | x64 / Release |
| Build workflow run | [{{RUN_URL}}]({{RUN_URL}}) |

{{PACKAGE_PROVENANCE}}

> **Note on the exact build input:** PostgreSQL.org versions.json determines each supported current `major.minor`. The EDB packaging revision is resolved by controlled probing of the EDB-controlled download host (heuristic availability discovery — not an authoritative EDB manifest); any network ambiguity fails closed. Each artifact is pinned from planning through its build, and the EDB archive SHA-256 is calculated by this project after download.

## Packages

{{PACKAGES}}

Unzip each package into its matching PostgreSQL installation directory (for example, `C:\\Program Files\\PostgreSQL\\18`) so that `lib\\`, `share\\extension\\`, and `bin\\` merge with the existing layout. Install the matching major package on both provider and subscriber nodes.

Server configuration and node setup follow upstream pglogical — see the [pglogical README](https://github.com/{{UPSTREAM_REPO}}#readme) for the required settings (`shared_preload_libraries = 'pglogical'`, `wal_level = logical`, worker/slot limits) and the `CREATE EXTENSION pglogical` / node registration steps.

## Checksums (SHA-256)

```
{{CHECKSUMS}}
```

---

> **Unofficial build.** These packages are produced by an independent, out-of-tree Windows build of upstream pglogical and are **not** published, endorsed, or supported by EnterpriseDB, 2ndQuadrant, or the PostgreSQL Global Development Group. Use at your own risk.
