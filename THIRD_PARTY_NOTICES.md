# THIRD_PARTY_NOTICES.md

This repository builds and redistributes third-party software. It does not
vendor upstream source code; the build clones the exact upstream release tag
at build time and packages the compiled artifacts.

## pglogical

* Upstream: https://github.com/2ndQuadrant/pglogical
* License: PostgreSQL License
* Copyright: Copyright (c) 2012-2016, PostgreSQL Global Development Group and
  contributors (see the `COPYRIGHT` file in the upstream repository, which
  is included in every package).

The PostgreSQL License (SPDX: `PostgreSQL`):

> PostgreSQL Database Management System
> (formerly known as Postgres, then as Postgres95)
>
> Portions Copyright (c) 1996-2026, The PostgreSQL Global Development Group
> Portions Copyright (c) 1994, The Regents of the University of California
>
> Permission to use, copy, modify, and distribute this software and its
> documentation for any purpose, without fee, and without a written
> agreement is hereby granted, provided that the above copyright notice and
> this paragraph and the following two paragraphs appear in all copies.
>
> IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
> DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES,
> INCLUDING LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS
> DOCUMENTATION, EVEN IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF
> THE POSSIBILITY OF SUCH DAMAGE.
>
> THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
> INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
> AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS
> ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATIONS
> TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

## Windows build patch (derived work)

The build applies `patches/pglogical-2.4.8-windows.patch` to the ephemeral
upstream checkout. The patch is derived from the Windows build patch
contributed by **ljackwilson** in upstream issue
[#442](https://github.com/2ndQuadrant/pglogical/issues/442)
("Getting this error 'The specified module could not be found.' on creating
extension pglogical on windows"), in particular:

* shared-memory startup-hook wiring for PostgreSQL 15+;
* additional `PGDLLEXPORT` declarations;
* subscriber-tool fixes (`random()` -> `rand()`, `sys/stat.h` exclusion on
  Windows, `DWORD` exit code, `QuoteWindowsArgv` cast).

The empty `shared_preload_libraries` change for the subscriber catchup start
is an addition by this project. The original patch is distributed under the
same PostgreSQL License as upstream pglogical.

## PostgreSQL (runtime target)

The packages are built against, and are designed to be installed into,
official EnterpriseDB PostgreSQL Windows installations.

* License: PostgreSQL License (see above)
* Copyright: The PostgreSQL Global Development Group
* The PostgreSQL binaries themselves are **not** bundled in or
  redistributed by this repository.

## EnterpriseDB PostgreSQL Windows binaries

* Source: https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
  (downloads served from `get.enterprisedb.com`)
* These are build-time inputs only, downloaded into CI caches; they are
  neither committed nor redistributed by this repository.
* License: PostgreSQL License plus additional terms as published by EDB for
  its Windows distributions. See the EDB download page and the installer's
  license text.

## Build tooling

* The scripts and workflows in this repository are original work, licensed
  under the PostgreSQL License (see [LICENSE](LICENSE)).
* Build tools used (Visual Studio/MSVC, CMake, PowerShell, Git, GitHub
  Actions runners) are third-party software subject to their own licenses.

## No affiliation

This project is an independent packaging effort. It is not affiliated with,
endorsed by, or sponsored by EnterpriseDB, 2ndQuadrant, or the PostgreSQL
Global Development Group.
