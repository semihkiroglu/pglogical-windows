# SECURITY.md

## Reporting a vulnerability

This project packages the upstream
[pglogical](https://github.com/2ndQuadrant/pglogical) extension for Windows.
Security issues can arise in two places:

1. **Upstream pglogical / PostgreSQL** — report to the upstream projects:
   * pglogical: https://github.com/2ndQuadrant/pglogical/issues
   * PostgreSQL: https://www.postgresql.org/support/security/
   Do not report upstream vulnerabilities here expecting a fix in this
   repository; this project only packages upstream code.
2. **This repository's build/release tooling** (scripts, workflows, package
   layout) — please report privately.

For private reports about this repository's own tooling, open a GitHub
issue with the `security` label, or contact the repository owner directly
through GitHub. Do not create public issues for tooling vulnerabilities
that could be exploited before they are fixed.

## Security properties of the packages

* Packages are built in CI from the exact upstream release tag; the commit
  SHA is resolved from the upstream repository and recorded in the release
  body.
* Every release publishes a `SHA256SUMS.txt`; verify downloads against it.
* The build downloads PostgreSQL binaries only from the official
  EnterpriseDB host (`get.enterprisedb.com`) over HTTPS.
* No credentials or tokens are stored in the repository; workflows use
  short-lived `GITHUB_TOKEN` permissions with the least privilege required.
* Published releases are immutable: existing releases and assets are never
  overwritten or mutated.

## Supported versions

Only the PostgreSQL majors listed in `.github/pg-versions.json` are built and
tested. Anything else — including prerelease PostgreSQL majors — is not
supported by this project.
