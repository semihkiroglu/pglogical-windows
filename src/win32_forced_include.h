/* -------------------------------------------------------------------------
 * win32_forced_include.h
 *
 * Forced include (/FI) for pglogical_create_subscriber.c only.
 *
 * 1. Include order. The upstream source includes <sys/stat.h> before
 *    postgres_fe.h, which breaks PostgreSQL's win32_port.h struct stat
 *    handling (win32_port.h must see sys/stat.h through its own renamed
 *    include first). Forcing postgres_fe.h before the source's own
 *    includes establishes the correct order; the source's later
 *    postgres_fe.h include is skipped by its include guard.
 *
 * 2. No postgres.exe dependency. The subscriber utility used to import
 *    pgport symbols (optarg, optind, getopt_long, get_progname, strlcpy,
 *    pg_usleep) from postgres.exe. Loading postgres.exe as a DLL into the
 *    utility process is fragile (it drags in postgres.exe's own imports
 *    and crashes with access violations), so every such symbol is now
 *    redirected to a local implementation in win32_frontend_shim.c via
 *    the macros below. PGDLLIMPORT is emptied so that the backend globals
 *    visible through the include closure (CurrentMemoryContext & friends)
 *    stay plain externs; the subscriber never references them, so the
 *    linker drops them (/OPT:REF).
 *
 * 3. Frontend memory helpers. fe_memutils.h declares palloc/pstrdup/pfree
 *    as real functions. postgres.exe's copies are BACKEND implementations
 *    that dereference CurrentMemoryContext — a NULL global in a standalone
 *    utility, i.e. a crash. Mapping them to the pg_malloc/pg_strdup/pg_free
 *    wrappers from win32_frontend_shim.c gives them the frontend semantics
 *    the tool expects.
 *
 * -------------------------------------------------------------------------
 */
#ifndef PGL_WIN32_FORCED_INCLUDE_H
#define PGL_WIN32_FORCED_INCLUDE_H

#if defined(_MSC_VER) || defined(__clang__)
#define PGDLLIMPORT
#endif

/* Frontend memory helpers (see comment 3 above). */
#define pstrdup pg_strdup
#define pfree pg_free
#define palloc pg_malloc
#define palloc0 pg_malloc0
#define repalloc pg_realloc

/* pgport functions, reimplemented in win32_frontend_shim.c (see 2 above). */
#define getopt_long pgl_getopt_long
#define optarg pgl_optarg
#define optind pgl_optind
#define opterr pgl_opterr
#define optopt pgl_optopt
#define get_progname pgl_get_progname
#define strlcpy pgl_strlcpy
#define strlcat pgl_strlcat
#define pg_usleep pgl_pg_usleep

#include "postgres_fe.h"

#endif							/* PGL_WIN32_FORCED_INCLUDE_H */
