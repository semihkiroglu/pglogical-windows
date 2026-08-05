/* -------------------------------------------------------------------------
 * win32_frontend_shim.c
 *
 * Frontend-support shim for pglogical_create_subscriber.exe.
 *
 * The subscriber utility is built against an official EDB PostgreSQL
 * Windows installation, which ships no libpgport/libpgcommon import
 * libraries. Two groups of symbols therefore need local implementations:
 *
 * 1. Memory helpers declared by include/server/common/fe_memutils.h that
 *    the tool links against — pg_malloc, pg_malloc0, pg_malloc_extended,
 *    pg_realloc, pg_free and pg_strdup — as thin wrappers over the C
 *    runtime.
 *
 * 2. pgport functions that postgres.exe exports but that must NOT be
 *    imported from it: loading postgres.exe as a DLL into the utility
 *    process drags in postgres.exe's own import chain and crashes with
 *    access violations. win32_forced_include.h redirects getopt_long,
 *    optarg/optind/opterr/optopt, get_progname, strlcpy and pg_usleep to
 *    the pgl_* implementations below.
 *
 * palloc/pstrdup/pfree and friends must NOT be defined here: they are
 * mapped to the pg_* wrappers above by win32_forced_include.h, giving
 * frontend (malloc-based) semantics.
 *
 * The getopt_long implementation is PostgreSQL source (src/port/
 * getopt_long.c, PostgreSQL License); everything else is original code
 * written for this project (PostgreSQL License).
 *
 * -------------------------------------------------------------------------
 */
#include "postgres_fe.h"
#include "getopt_long.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <ctype.h>
#include <signal.h>
#include <io.h>
#include <process.h>

/* -------------------------------------------------------------------------
 * 1. Frontend memory helpers
 * -------------------------------------------------------------------------
 */
void *
pg_malloc(size_t size)
{
	void	   *p = malloc(size);

	if (p == NULL && size > 0)
	{
		fprintf(stderr, "out of memory\n");
		exit(1);
	}
	return p;
}

void *
pg_malloc0(size_t size)
{
	void	   *p = calloc(1, size);

	if (p == NULL && size > 0)
	{
		fprintf(stderr, "out of memory\n");
		exit(1);
	}
	return p;
}

void *
pg_malloc_extended(size_t size, int flags)
{
	void	   *p = malloc(size);

	if (p == NULL && size > 0)
	{
		/* MCXT_ALLOC_NO_OOM (0x02) is the only flag this shim understands */
		if (flags & 0x02)
			return NULL;
		fprintf(stderr, "out of memory\n");
		exit(1);
	}
	return p;
}

void *
pg_realloc(void *ptr, size_t size)
{
	void	   *p = realloc(ptr, size);

	if (p == NULL && size > 0)
	{
		fprintf(stderr, "out of memory\n");
		exit(1);
	}
	return p;
}

void
pg_free(void *ptr)
{
	free(ptr);
}

char *
pg_strdup(const char *in)
{
	char	   *p = strdup(in);

	if (p == NULL)
	{
		fprintf(stderr, "out of memory\n");
		exit(1);
	}
	return p;
}

/* -------------------------------------------------------------------------
 * 2. pgport replacements (see header comment)
 * -------------------------------------------------------------------------
 */

/* Option-parsing globals (renamed via win32_forced_include.h). */
char	   *pgl_optarg;
int			pgl_optind = 1;
int			pgl_opterr = 1;
int			pgl_optopt;

/*
 * getopt_long() -- long options parser.
 *
 * PostgreSQL source, src/port/getopt_long.c (see license header in the
 * upstream file; BSD-style, reproduced in the project docs). The function
 * and the globals above are renamed to the pgl_* namespace by
 * win32_forced_include.h so that the utility has no postgres.exe import.
 */
#define BADCH	'?'
#define BADARG	':'
#define EMSG	""

int
pgl_getopt_long(int argc, char *const argv[],
				const char *optstring,
				const struct option *longopts, int *longindex)
{
	static char *place = EMSG;	/* option letter processing */
	const char *oli;			/* option letter list index */
	static int	nonopt_start = -1;
	static bool force_nonopt = false;

	if (!*place)
	{							/* update scanning pointer */
		char	  **args = (char **) argv;

retry:

		/*
		 * If we are out of arguments or only non-options remain, return -1.
		 */
		if (pgl_optind >= argc || pgl_optind == nonopt_start)
		{
			place = EMSG;
			nonopt_start = -1;
			force_nonopt = false;
			return -1;
		}

		place = argv[pgl_optind];

		/*
		 * An argument is a non-option if it meets any of the following
		 * criteria: it follows an argument that is equivalent to the string
		 * "--", it does not start with '-', or it is equivalent to the
		 * string "-".  When we encounter a non-option, we move it to the
		 * end of argv (after shifting all remaining arguments over to make
		 * room), and then we try again with the next argument.
		 */
		if (force_nonopt || place[0] != '-' || place[1] == '\0')
		{
			for (int i = pgl_optind; i < argc - 1; i++)
				args[i] = args[i + 1];
			args[argc - 1] = place;

			if (nonopt_start == -1)
				nonopt_start = argc - 1;
			else
				nonopt_start--;

			goto retry;
		}

		place++;

		if (place[0] == '-' && place[1] == '\0')
		{
			/* found "--", treat it as end of options */
			++pgl_optind;
			force_nonopt = true;
			goto retry;
		}

		if (place[0] == '-' && place[1])
		{
			/* long option */
			size_t		namelen;
			int			i;

			place++;

			namelen = strcspn(place, "=");
			for (i = 0; longopts[i].name != NULL; i++)
			{
				if (strlen(longopts[i].name) == namelen
					&& strncmp(place, longopts[i].name, namelen) == 0)
				{
					int			has_arg = longopts[i].has_arg;

					if (has_arg != no_argument)
					{
						if (place[namelen] == '=')
							pgl_optarg = place + namelen + 1;
						else if (pgl_optind < argc - 1 &&
								 has_arg == required_argument)
						{
							pgl_optind++;
							pgl_optarg = argv[pgl_optind];
						}
						else
						{
							if (optstring[0] == ':')
								return BADARG;

							if (pgl_opterr && has_arg == required_argument)
								fprintf(stderr,
										"%s: option requires an argument -- %s\n",
										argv[0], place);

							place = EMSG;
							pgl_optind++;

							if (has_arg == required_argument)
								return BADCH;
							pgl_optarg = NULL;
						}
					}
					else
					{
						pgl_optarg = NULL;
						if (place[namelen] != 0)
						{
							/* XXX error? */
						}
					}

					pgl_optind++;

					if (longindex)
						*longindex = i;

					place = EMSG;

					if (longopts[i].flag == NULL)
						return longopts[i].val;
					else
					{
						*longopts[i].flag = longopts[i].val;
						return 0;
					}
				}
			}

			if (pgl_opterr && optstring[0] != ':')
				fprintf(stderr,
						"%s: illegal option -- %s\n", argv[0], place);
			place = EMSG;
			pgl_optind++;
			return BADCH;
		}
	}

	/* short option */
	pgl_optopt = (int) *place++;

	oli = strchr(optstring, pgl_optopt);
	if (!oli)
	{
		if (!*place)
			++pgl_optind;
		if (pgl_opterr && *optstring != ':')
			fprintf(stderr,
					"%s: illegal option -- %c\n", argv[0], pgl_optopt);
		return BADCH;
	}

	if (oli[1] != ':')
	{							/* don't need argument */
		pgl_optarg = NULL;
		if (!*place)
			++pgl_optind;
	}
	else
	{							/* need an argument */
		if (*place)				/* no white space */
			pgl_optarg = place;
		else if (argc <= ++pgl_optind)
		{						/* no arg */
			place = EMSG;
			if (*optstring == ':')
				return BADARG;
			if (pgl_opterr)
				fprintf(stderr,
						"%s: option requires an argument -- %c\n",
						argv[0], pgl_optopt);
			return BADCH;
		}
		else
			/* white space */
			pgl_optarg = argv[pgl_optind];
		place = EMSG;
		++pgl_optind;
	}
	return pgl_optopt;
}

size_t
pgl_strlcpy(char *dst, const char *src, size_t siz)
{
	size_t		n = strlen(src);

	if (siz > 0)
	{
		size_t		c = (n >= siz) ? siz - 1 : n;

		memcpy(dst, src, c);
		dst[c] = '\0';
	}
	return n;
}

const char *
pgl_get_progname(const char *argv0)
{
	static char progname[MAXPGPATH];
	const char *slash = strrchr(argv0, '\\');
	const char *base = slash ? slash + 1 : argv0;

	pgl_strlcpy(progname, base, sizeof(progname));
	return progname;
}

void
pgl_pg_usleep(long usec)
{
	Sleep((DWORD) (usec / 1000));
}

/* -------------------------------------------------------------------------
 * 3. Remaining pgport/pgcommon symbols (all previously imported from
 *    postgres.exe). Importing postgres.exe as a DLL into the utility
 *    process is unsafe: the loader leaves some import-address-table
 *    entries as RVAs instead of absolute addresses, and the first call
 *    branches into nowhere (access violation). Everything postgres.exe
 *    used to provide is therefore reimplemented here.
 *
 * Most of this is PostgreSQL source (from src/port, PostgreSQL License);
 * the printf/open/stat family is original code written for this project.
 * -------------------------------------------------------------------------
 */

/* --- printf family (c.h maps fprintf/printf/snprintf/sprintf/vfprintf/
 * strerror to these when building against the EDB headers) --- */

int
pg_snprintf(char *str, size_t count, const char *fmt, ...)
{
	va_list		args;
	int			len;

	va_start(args, fmt);
	len = (vsnprintf)(str, count, fmt, args);
	va_end(args);
	return len;
}

#undef vsnprintf
int
pg_vsnprintf(char *str, size_t count, const char *fmt, va_list args)
{
	/* The EDB headers map vsnprintf to pg_vsnprintf with an OBJECT-LIKE
	 * macro, so even a parenthesized call expands back to this function
	 * (infinite recursion, -Winfinite-recursion). Call the real CRT
	 * function with the macro undefined, then restore the mapping. */
	return vsnprintf(str, count, fmt, args);
}
#define vsnprintf pg_vsnprintf

int
pg_sprintf(char *str, const char *fmt, ...)
{
	va_list		args;
	int			len;

	va_start(args, fmt);
	len = (vsprintf)(str, fmt, args);
	va_end(args);
	return len;
}

#undef vsprintf
int
pg_vsprintf(char *str, const char *fmt, va_list args)
{
	/* object-like macro: (vsprintf) would expand to (pg_vsprintf) - self
	 * call. Call the real CRT function, then restore the mapping. */
	return vsprintf(str, fmt, args);
}
#define vsprintf pg_vsprintf

#undef vfprintf
int
pg_vfprintf(FILE *stream, const char *fmt, va_list args)
{
	/* object-like macro: (vfprintf) would expand to (pg_vfprintf) - self
	 * call. Call the real CRT function, then restore the mapping. */
	return vfprintf(stream, fmt, args);
}
#define vfprintf pg_vfprintf

int
pg_fprintf(FILE *stream, const char *fmt, ...)
{
	va_list		args;
	int			len;

	va_start(args, fmt);
	len = (vfprintf)(stream, fmt, args);
	va_end(args);
	return len;
}

int
pg_printf(const char *fmt, ...)
{
	va_list		args;
	int			len;

	va_start(args, fmt);
	len = (vprintf)(fmt, args);
	va_end(args);
	return len;
}

#undef vprintf
int
pg_vprintf(const char *fmt, va_list args)
{
	/* object-like macro: (vprintf) would expand to (pg_vprintf) - self
	 * call. Call the real CRT function, then restore the mapping. */
	return vprintf(fmt, args);
}
#define vprintf pg_vprintf

#undef strerror
char *
pg_strerror(int errnum)
{
	/* object-like macro: (strerror) would expand to (pg_strerror) - self
	 * call. Call the real CRT function, then restore the mapping. */
	return strerror(errnum);
}
#define strerror pg_strerror

/* --- pg_strcasecmp / pg_strncasecmp (src/port/pgstrcasecmp.c) --- */

int
pg_strcasecmp(const char *s1, const char *s2)
{
	for (;;)
	{
		unsigned char ch1 = (unsigned char) *s1++;
		unsigned char ch2 = (unsigned char) *s2++;

		if (ch1 != ch2)
		{
			if (ch1 >= 'A' && ch1 <= 'Z')
				ch1 += 'a' - 'A';
			if (ch2 >= 'A' && ch2 <= 'Z')
				ch2 += 'a' - 'A';

			if (ch1 != ch2)
				return (int) ch1 - (int) ch2;
		}
		if (ch1 == 0)
			return 0;
	}
}

int
pg_strncasecmp(const char *s1, const char *s2, size_t n)
{
	while (n-- > 0)
	{
		unsigned char ch1 = (unsigned char) *s1++;
		unsigned char ch2 = (unsigned char) *s2++;

		if (ch1 != ch2)
		{
			if (ch1 >= 'A' && ch1 <= 'Z')
				ch1 += 'a' - 'A';
			if (ch2 >= 'A' && ch2 <= 'Z')
				ch2 += 'a' - 'A';

			if (ch1 != ch2)
				return (int) ch1 - (int) ch2;
		}
		if (ch1 == 0)
			return 0;
	}
	return 0;
}

/* --- Windows file/process helpers ---
 * The EDB headers map open/fopen/system/popen/stat/kill to these.
 * The path encodings here are plain byte strings (fine for ASCII paths;
 * PG's originals convert UTF-8 to UTF-16). */

int
pgwin32_open(const char *path, int flags, ...)
{
	int			mode = 0;
	va_list		ap;

	va_start(ap, flags);
	mode = va_arg(ap, int);
	va_end(ap);
	return _open(path, flags, mode);
}

FILE *
pgwin32_fopen(const char *path, const char *mode)
{
	/* parenthesized: fopen is macro-mapped to pgwin32_fopen */
	return (fopen)(path, mode);
}

FILE *
pgwin32_popen(const char *command, const char *type)
{
	return _popen(command, type);
}

int
pgwin32_system(const char *command)
{
	/* parenthesized: system is macro-mapped to pgwin32_system */
	return (system)(command);
}

/* stat() -> _pgstat64 (win32_port.h). The struct stat here is the
 * win32_port.h 64-bit-time copy of __stat64. */
int
_pgstat64(const char *name, struct stat *buf)
{
	struct _stat64 st;

	if (_stat64(name, &st) != 0)
		return -1;
	memset(buf, 0, sizeof(*buf));
	buf->st_dev = st.st_dev;
	buf->st_ino = st.st_ino;
	buf->st_mode = st.st_mode;
	buf->st_nlink = st.st_nlink;
	buf->st_uid = st.st_uid;
	buf->st_gid = st.st_gid;
	buf->st_rdev = st.st_rdev;
	buf->st_size = st.st_size;
	buf->st_atime = st.st_atime;
	buf->st_mtime = st.st_mtime;
	buf->st_ctime = st.st_ctime;
	return 0;
}

/* pgkill() -- src/port/kill.c (PostgreSQL License); only the SIGKILL path
 * is needed by the tool (no pipe-signal support for other signals), plus
 * the kill(pid, 0) existence probe used by postmaster_is_alive(). */
int
pgkill(int pid, int sig)
{
	HANDLE		prochandle;

	if (pid <= 0)
	{
		errno = EINVAL;
		return -1;
	}
	if (sig == 0)
	{
		/* Existence probe: kill(pid, 0) must not signal, just check. */
		if ((prochandle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD) pid)) == NULL)
		{
			errno = ESRCH;
			return -1;
		}
		CloseHandle(prochandle);
		return 0;
	}
	if (sig != SIGKILL)
	{
		errno = EINVAL;
		return -1;
	}
	if ((prochandle = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD) pid)) == NULL)
	{
		errno = ESRCH;
		return -1;
	}
	if (!TerminateProcess(prochandle, 255))
	{
		/* _dosmaperr is not available to link here; map the common case */
		errno = (GetLastError() == ERROR_ACCESS_DENIED) ? EACCES : EINVAL;
		CloseHandle(prochandle);
		return -1;
	}
	CloseHandle(prochandle);
	return 0;
}

/* --- path handling (src/port/path.c, PostgreSQL License; trimmed to the
 * functions the subscriber needs, with the encoding-aware bits removed:
 * data-directory paths are ASCII) --- */

static char *
skip_drive(const char *path)
{
	if (IS_DIR_SEP(path[0]) && IS_DIR_SEP(path[1]))
	{
		path += 2;
		while (*path && !IS_DIR_SEP(*path))
			path++;
	}
	else if (isalpha((unsigned char) path[0]) && path[1] == ':')
	{
		path += 2;
	}
	return (char *) path;
}

/* Not provided by the EDB port headers; PATH entries are ';'-separated
 * on Windows. */
#ifndef IS_PATH_VAR_SEP
#define IS_PATH_VAR_SEP(ch) ((ch) == ';')
#endif

char *
first_dir_separator(const char *filename)
{
	const char *p;

	for (p = skip_drive(filename); *p; p++)
		if (IS_DIR_SEP(*p))
			return unconstify(char *, p);
	return NULL;
}

char *
first_path_var_separator(const char *pathlist)
{
	const char *p;

	for (p = pathlist; *p; p++)
		if (IS_PATH_VAR_SEP(*p))
			return unconstify(char *, p);
	return NULL;
}

char *
last_dir_separator(const char *filename)
{
	const char *p,
			   *ret = NULL;

	for (p = skip_drive(filename); *p; p++)
		if (IS_DIR_SEP(*p))
			ret = p;
	return unconstify(char *, ret);
}

static void
debackslash_path(char *path)
{
	char	   *p;

	for (p = path; *p; p++)
		if (*p == '\\')
			*p = '/';
}

static char *
trim_directory(char *path)
{
	char	   *p;

	path = skip_drive(path);

	if (path[0] == '\0')
		return path;

	/* back up over trailing slash(es) */
	for (p = path + strlen(path) - 1; IS_DIR_SEP(*p) && p > path; p--)
		;
	/* back up over directory name */
	for (; !IS_DIR_SEP(*p) && p > path; p--)
		;
	/* if multiple slashes before directory name, remove 'em all */
	for (; p > path && IS_DIR_SEP(*(p - 1)); p--)
		;
	/* don't erase a leading slash */
	if (p == path && IS_DIR_SEP(*p))
		p++;
	*p = '\0';
	return p;
}

static void
trim_trailing_separator(char *path)
{
	char	   *p;

	path = skip_drive(path);
	p = path + strlen(path);
	if (p > path)
		for (p--; p > path && IS_DIR_SEP(*p); p--)
			*p = '\0';
}

static char *
append_subdir_to_path(char *path, char *subdir)
{
	size_t		len = strlen(subdir);

	if (path != subdir)
		memmove(path, subdir, len);

	return path + len;
}

void
canonicalize_path(char *path)
{
	char	   *p,
			   *to_p;
	char	   *spath;
	char	   *parsed;
	char	   *unparse;
	bool		was_sep = false;
	int			pathdepth = 0;	/* counts collected regular directory names */

	/* Convert all back slashes to forward slashes */
	debackslash_path(path);

	/*
	 * Removing the trailing slash on a path means we never get ugly double
	 * trailing slashes. Also, Win32 can't stat() a directory with a trailing
	 * slash. Don't remove a leading slash, though.
	 */
	trim_trailing_separator(path);

	/*
	 * Remove duplicate adjacent separators
	 */
	p = path;
	/* Don't remove leading double-slash on Win32 */
	if (*p)
		p++;
	to_p = p;
	for (; *p; p++, to_p++)
	{
		/* Handle many adjacent slashes, like "/a///b" */
		while (*p == '/' && was_sep)
			p++;
		if (to_p != p)
			*to_p = *p;
		was_sep = (*p == '/');
	}
	*to_p = '\0';

	/*
	 * Remove any uses of "." and process ".." ourselves
	 */
	spath = skip_drive(path);
	if (*spath == '\0')
		return;					/* empty path is returned as-is */

	if (*spath == '/')
	{
		/* Skip the leading slash for absolute path */
		parsed = unparse = (spath + 1);
	}
	else
		parsed = unparse = spath;

	while (*unparse != '\0')
	{
		char	   *unparse_next;
		bool		is_double_dot;

		/* Split off this dir name, and set unparse_next to the next one */
		unparse_next = unparse;
		while (*unparse_next && *unparse_next != '/')
			unparse_next++;
		if (*unparse_next != '\0')
			*unparse_next++ = '\0';

		/* Identify type of this dir name */
		if (strcmp(unparse, ".") == 0)
		{
			/* We can ignore "." components in all cases */
			unparse = unparse_next;
			continue;
		}

		if (strcmp(unparse, "..") == 0)
			is_double_dot = true;
		else
		{
			Assert(*unparse != '\0');
			is_double_dot = false;
		}

		if (*spath == '/')
		{
			/* absolute path */
			if (parsed == spath + 1 && is_double_dot)
			{
				/* We can ignore ".." immediately after / */
			}
			else if (is_double_dot)
			{
				/* Remove last parsed dir (trim_directory keeps the /) */
				*parsed = '\0';
				parsed = trim_directory(path);
				if (--pathdepth == 0)
					parsed = spath + 1;
			}
			else
			{
				if (parsed != spath + 1)
					*parsed++ = '/';
				parsed = append_subdir_to_path(parsed, unparse);
				pathdepth++;
			}
		}
		else if (is_double_dot)
		{
			/* relative path with ".." */
			if (pathdepth > 0)
			{
				/* Remove last parsed dir */
				*parsed = '\0';
				parsed = trim_directory(path);
				pathdepth--;
			}
			else
			{
				/* Append irreducible double-dot (..) */
				if (parsed != spath)
					*parsed++ = '/';
				parsed = append_subdir_to_path(parsed, unparse);
			}
		}
		else
		{
			/* Append normal dir */
			if (parsed != spath)
				*parsed++ = '/';
			parsed = append_subdir_to_path(parsed, unparse);
			pathdepth++;
		}

		unparse = unparse_next;
	}

	/*
	 * If our output path is empty at this point, insert ".".
	 */
	if (parsed == spath)
		*parsed++ = '.';

	*parsed = '\0';
}

/* find_my_exec() -- minimal standalone equivalent (src/common/exec.c).
 * Resolves argv0 against the current directory or PATH. */
size_t
pgl_strlcat(char *dst, const char *src, size_t siz)
{
	size_t		dlen = strlen(dst);
	size_t		n = strlen(src);

	if (siz > 0 && dlen < siz)
	{
		size_t		c = (n >= siz - dlen) ? siz - dlen - 1 : n;

		memcpy(dst + dlen, src, c);
		dst[dlen + c] = '\0';
	}
	return dlen + n;
}

static void
join_path_components(char *ret_path, const char *head, const char *tail)
{
	if (ret_path != head)
		strlcpy(ret_path, head, MAXPGPATH);

	/* Remove any trailing separator in head */
	trim_trailing_separator(ret_path);

	/* If head is not empty, add a separator */
	if (*ret_path)
		strlcat(ret_path, "/", MAXPGPATH);

	strlcat(ret_path, tail, MAXPGPATH);
}

int
find_my_exec(const char *argv0, char *retpath)
{
	char	   *path;
	DWORD		attr;

	strlcpy(retpath, argv0, MAXPGPATH);
	if (first_dir_separator(retpath) != NULL)
	{
		GetFullPathNameA(retpath, MAXPGPATH, retpath, NULL);
		attr = GetFileAttributesA(retpath);
		if (attr != INVALID_FILE_ATTRIBUTES)
		{
			canonicalize_path(retpath);
			return 0;
		}
		return -1;
	}

	/* Win32 checks the current directory first for names without slashes */
	attr = GetFileAttributesA(retpath);
	if (attr != INVALID_FILE_ATTRIBUTES)
	{
		GetFullPathNameA(retpath, MAXPGPATH, retpath, NULL);
		canonicalize_path(retpath);
		return 0;
	}

	if ((path = getenv("PATH")) && *path)
	{
		char	   *startp = NULL,
				   *endp = NULL;

		do
		{
			if (!startp)
				startp = path;
			else
				startp = endp + 1;

			endp = first_path_var_separator(startp);
			if (!endp)
				endp = startp + strlen(startp); /* point to end */

			strlcpy(retpath, startp, Min(endp - startp + 1, MAXPGPATH));
			join_path_components(retpath, retpath, argv0);
			canonicalize_path(retpath);

			attr = GetFileAttributesA(retpath);
			if (attr != INVALID_FILE_ATTRIBUTES)
				return 0;
		} while (*endp);
	}

	return -1;
}

/* pg_check_dir() -- simplified (src/port/pgcheckdir.c): existence and
 * directory-ness via the file attributes; no readdir permission probe. */
int
pg_check_dir(const char *dir)
{
	DWORD		attr = GetFileAttributesA(dir);

	if (attr == INVALID_FILE_ATTRIBUTES)
	{
		errno = ENOENT;
		return -1;
	}
	if (!(attr & FILE_ATTRIBUTE_DIRECTORY))
	{
		errno = ENOTDIR;
		return -1;
	}
	return 0;
}

/* escape_single_quotes_ascii() -- src/port/quotes.c (PostgreSQL License) */
char *
escape_single_quotes_ascii(const char *src)
{
	int			len = strlen(src),
				i,
				j;
	char	   *result = malloc(len * 2 + 1);

	if (!result)
		return NULL;

	for (i = 0, j = 0; i < len; i++)
	{
		if (SQL_STR_DOUBLE(src[i], true))
			result[j++] = src[i];
		result[j++] = src[i];
	}
	result[j] = '\0';
	return result;
}
