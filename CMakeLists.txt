# ===========================================================================
# pglogical-windows: out-of-tree CMake/MSVC build for the upstream pglogical
# PostgreSQL extension against an official EnterpriseDB Windows installation.
#
# Toolchain: Visual Studio generator with the ClangCL toolset (clang-cl
# compiler + MSVC link.exe/CRT). clang-cl is required because upstream
# pglogical uses preprocessor directives inside function-call argument lists
# (e.g. ExecInsertIndexTuples(...) with #if between arguments), which
# Microsoft's cl preprocessor rejects; clang-cl is the MSVC-compatible
# frontend that accepts the same flags and produces the same ABI. The
# linker, import libraries, runtime, and export validation remain MSVC.
#
# The upstream PGXS Makefile is the authoritative description of build
# inputs; the source list below is pinned from it for REL2_4_8.
#
# Required cache variables:
#   PG_ROOT                PostgreSQL Windows installation (headers + import libs)
#   PG_MAJOR               PostgreSQL major version (e.g. 18)
#   PGLOGICAL_SOURCE_DIR   upstream pglogical checkout at a release tag
#   PGLOGICAL_VERSION      pglogical version
#   ARCH                   x64 (only architecture supported)
#   CONFIGURATION          Release (default) or Debug
# ===========================================================================
cmake_minimum_required(VERSION 3.24)
project(pglogical-windows LANGUAGES C)

set(PG_ROOT "" CACHE PATH "PostgreSQL Windows installation root (headers and import libraries)")
set(PG_MAJOR "" CACHE STRING "PostgreSQL major version, e.g. 18")
set(PGLOGICAL_SOURCE_DIR "" CACHE PATH "Path to the upstream pglogical checkout at a release tag")
set(PGLOGICAL_VERSION "" CACHE STRING "pglogical version")
set(ARCH "x64" CACHE STRING "Target architecture (x64 only)")
set(CONFIGURATION "Release" CACHE STRING "Build configuration (Release or Debug)")

# ---------------------------------------------------------------------------
# 1. Validate PG_ROOT
# ---------------------------------------------------------------------------
if(NOT PG_ROOT)
  message(FATAL_ERROR "PG_ROOT must point at the PostgreSQL Windows installation (e.g. C:/Program Files/PostgreSQL/18)")
endif()
get_filename_component(PG_ROOT "${PG_ROOT}" ABSOLUTE)
if(NOT EXISTS "${PG_ROOT}/include/pg_config.h")
  message(FATAL_ERROR "PG_ROOT does not contain include/pg_config.h: ${PG_ROOT}")
endif()
foreach(_required
    include/libpq-fe.h
    include/server/postgres.h
    include/server/port/win32_msvc/dirent.h
    include/server/port/win32/sys/wait.h
    lib/postgres.lib
    lib/libpq.lib
    lib/libintl.lib)
  if(NOT EXISTS "${PG_ROOT}/${_required}")
    message(FATAL_ERROR "PG_ROOT is missing ${_required} — an official EDB Windows installation is required (see BUILDING.md)")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# 2. Validate architecture and PostgreSQL major version
# ---------------------------------------------------------------------------
if(NOT ARCH STREQUAL "x64")
  message(FATAL_ERROR "Unsupported architecture '${ARCH}'; only x64 is supported")
endif()
if(NOT CONFIGURATION STREQUAL "Release" AND NOT CONFIGURATION STREQUAL "Debug")
  message(FATAL_ERROR "Unsupported configuration '${CONFIGURATION}'; use Release or Debug")
endif()

file(READ "${PG_ROOT}/include/pg_config.h" _pg_config_h)
if(NOT _pg_config_h MATCHES "#define PG_VERSION_NUM ([0-9]+)")
  message(FATAL_ERROR "Could not read PG_VERSION_NUM from ${PG_ROOT}/include/pg_config.h")
endif()
set(_pg_version_num "${CMAKE_MATCH_1}")
math(EXPR _pg_major_from_root "${_pg_version_num} / 10000")
if(NOT PG_MAJOR)
  set(PG_MAJOR "${_pg_major_from_root}")
endif()
if(NOT "${PG_MAJOR}" STREQUAL "${_pg_major_from_root}")
  message(FATAL_ERROR "PG_MAJOR=${PG_MAJOR} does not match PG_ROOT (PostgreSQL ${_pg_major_from_root}, PG_VERSION_NUM ${_pg_version_num})")
endif()
message(STATUS "PostgreSQL major: ${PG_MAJOR} (PG_VERSION_NUM ${_pg_version_num})")

# ---------------------------------------------------------------------------
# 3. Validate the upstream checkout and compat layer
# ---------------------------------------------------------------------------
if(NOT PGLOGICAL_SOURCE_DIR)
  message(FATAL_ERROR "PGLOGICAL_SOURCE_DIR must point at an upstream pglogical checkout")
endif()
get_filename_component(PGLOGICAL_SOURCE_DIR "${PGLOGICAL_SOURCE_DIR}" ABSOLUTE)
if(NOT EXISTS "${PGLOGICAL_SOURCE_DIR}/Makefile" OR NOT EXISTS "${PGLOGICAL_SOURCE_DIR}/pglogical.h")
  message(FATAL_ERROR "PGLOGICAL_SOURCE_DIR does not look like a pglogical checkout: ${PGLOGICAL_SOURCE_DIR}")
endif()
set(PGLOGICAL_COMPAT_DIR "${PGLOGICAL_SOURCE_DIR}/compat${PG_MAJOR}")
if(NOT EXISTS "${PGLOGICAL_COMPAT_DIR}/pglogical_compat.c")
  message(FATAL_ERROR "Upstream source has no compat${PG_MAJOR}/pglogical_compat.c — pglogical ${PGLOGICAL_VERSION} does not support PostgreSQL ${PG_MAJOR}")
endif()

# ---------------------------------------------------------------------------
# 4. Source list (pinned from the upstream PGXS Makefile for REL2_4_8)
# ---------------------------------------------------------------------------
set(_module_sources
    "${PGLOGICAL_SOURCE_DIR}/pglogical_apply_heap.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_apply_spi.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_apply.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_conflict.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_dependency.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_executor.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_fe.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_functions.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_manager.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_monitoring.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_node.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_output_config.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_output_plugin.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_output_proto.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_proto_json.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_proto_native.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_queue.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_relcache.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_repset.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_rpc.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_sequences.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_sync.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_worker.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical.c")
set(_output_sources "${PGLOGICAL_SOURCE_DIR}/pglogical_output.c")
set(_subscriber_sources
    "${PGLOGICAL_SOURCE_DIR}/pglogical_create_subscriber.c"
    "${PGLOGICAL_SOURCE_DIR}/pglogical_fe.c")

foreach(_src IN LISTS _module_sources _output_sources _subscriber_sources)
  if(NOT EXISTS "${_src}")
    message(FATAL_ERROR "Source file missing from the checkout: ${_src}")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# 5. Include order (EDB-documented MSVC order) and compile definitions
# ---------------------------------------------------------------------------
set(PG_INCLUDE_DIRS
    "${PG_ROOT}/include/server/port/win32_msvc"
    "${PG_ROOT}/include/server/port/win32"
    "${PG_ROOT}/include/server"
    "${PG_ROOT}/include")
# PG17+ keeps frontend headers (pqexpbuffer.h, ...) under include/internal.
if(EXISTS "${PG_ROOT}/include/internal")
  list(APPEND PG_INCLUDE_DIRS "${PG_ROOT}/include/internal")
endif()
list(APPEND PG_INCLUDE_DIRS "${PGLOGICAL_COMPAT_DIR}")

add_compile_definitions(
    WIN32 _WIN32 _WIN64
    _CRT_SECURE_NO_WARNINGS
    _CRT_NONSTDC_NO_DEPRECATE)

set(PG_MSVC_FLAGS /W3 /bigobj)
if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
  add_compile_options(${PG_MSVC_FLAGS})
endif()

# clang-cl diagnostics for upstream/PG-header quirks that are not ours to fix:
#  - PG's generic-msvc.h atomics pass volatile uint32* to winnt.h intrinsics
#    (pointer-sign/incompatible-pointer-types noise from PostgreSQL headers)
#  - pg_bitutils.h / executor.h unused-variable warnings in PG18 headers
#  - pglogical.c:796 has a Windows-only "return false;" inside a void GUC
#    check hook (upstream bug; harmless since GetTempPath failure is fatal)
set(PGLOGICAL_CLANG_SUPPRESSIONS
    -Wno-incompatible-pointer-types
    -Wno-pointer-sign
    -Wno-unused-but-set-variable
    -Wno-return-mismatch)

set(PG_IMPORT_LIBS
    "${PG_ROOT}/lib/postgres.lib"
    "${PG_ROOT}/lib/libpq.lib"
    "${PG_ROOT}/lib/libintl.lib")

# ---------------------------------------------------------------------------
# 6. Deterministic DLL exports (.def generated from cmake/exports.json)
# ---------------------------------------------------------------------------
function(pgl_generate_def _exports_json _exports_key _def_out)
  set(_def_path "${CMAKE_BINARY_DIR}/${_exports_key}.def")
  set(_lines "EXPORTS")
  string(JSON _len LENGTH "${_exports_json}" "${_exports_key}")
  if(_len GREATER 0)
    math(EXPR _last "${_len} - 1")
    foreach(_i RANGE 0 "${_last}")
      string(JSON _sym GET "${_exports_json}" "${_exports_key}" "${_i}")
      string(APPEND _lines "\n    ${_sym}")
    endforeach()
  endif()
  file(WRITE "${_def_path}" "${_lines}\n")
  set(${_def_out} "${_def_path}" PARENT_SCOPE)
endfunction()

set(_exports_json_path "${CMAKE_CURRENT_SOURCE_DIR}/cmake/exports.json")
if(NOT EXISTS "${_exports_json_path}")
  message(FATAL_ERROR "Missing exports manifest: ${_exports_json_path}")
endif()
file(READ "${_exports_json_path}" _exports_json)

# ---------------------------------------------------------------------------
# 7. Targets
# ---------------------------------------------------------------------------
# pglogical.dll — the main extension module (module magic, _PG_init, all
# SQL-callable functions, the output plugin implementation, and the
# frontend helper used by pglogical_create_subscriber).
add_library(pglogical SHARED
    ${_module_sources}
    "${PGLOGICAL_COMPAT_DIR}/pglogical_compat.c")
target_include_directories(pglogical PRIVATE ${PG_INCLUDE_DIRS})
target_link_libraries(pglogical PRIVATE ${PG_IMPORT_LIBS})
pgl_generate_def("${_exports_json}" pglogical _pglogical_def)
target_sources(pglogical PRIVATE "${_pglogical_def}")
if(MSVC)
  target_compile_options(pglogical PRIVATE ${PGLOGICAL_CLANG_SUPPRESSIONS})
endif()

# pglogical_output.dll — compatibility shim output plugin that loads
# pglogical.dll at runtime (upstream load_external_function design).
add_library(pglogical_output SHARED ${_output_sources})
target_include_directories(pglogical_output PRIVATE ${PG_INCLUDE_DIRS})
target_link_libraries(pglogical_output PRIVATE ${PG_IMPORT_LIBS})
pgl_generate_def("${_exports_json}" pglogical_output _pglogical_output_def)
target_sources(pglogical_output PRIVATE "${_pglogical_output_def}")
if(MSVC)
  target_compile_options(pglogical_output PRIVATE ${PGLOGICAL_CLANG_SUPPRESSIONS})
endif()

# pglogical_create_subscriber.exe — client utility. It links ONLY libpq:
# every pgport/pgcommon symbol it needs is implemented locally in
# win32_frontend_shim.c. postgres.lib must NOT be linked — its
# import-library thunks (pg_printf, pgwin32_open, canonicalize_path, ...)
# would duplicate the shim's definitions, and importing postgres.exe at
# runtime is unsafe anyway (the loader leaves some IAT entries unresolved,
# causing access violations).
add_executable(pglogical_create_subscriber ${_subscriber_sources}
    "${CMAKE_CURRENT_SOURCE_DIR}/src/win32_frontend_shim.c")
target_include_directories(pglogical_create_subscriber PRIVATE ${PG_INCLUDE_DIRS})
target_link_libraries(pglogical_create_subscriber PRIVATE
    "${PG_ROOT}/lib/libpq.lib"
    "${PG_ROOT}/lib/libintl.lib")
if(MSVC)
  # The upstream source includes <sys/stat.h> before postgres_fe.h; on
  # Windows that order clashes with PostgreSQL's win32_port.h struct stat
  # redefinition. The forced include (src/win32_forced_include.h) fixes
  # the include order, maps the backend-named memory helpers to our shim,
  # and redirects pgport symbols (getopt_long, optarg, strlcpy, ...) to the
  # shim so the utility has no postgres.exe import. It applies to the
  # upstream source AND to the shim itself (so the getopt_long.h
  # declarations it sees are renamed consistently).
  set(_pgl_forced_include "${CMAKE_CURRENT_SOURCE_DIR}/src/win32_forced_include.h")
  set_source_files_properties("${PGLOGICAL_SOURCE_DIR}/pglogical_create_subscriber.c"
      PROPERTIES COMPILE_OPTIONS "/FI\"${_pgl_forced_include}\"")
  set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/src/win32_frontend_shim.c"
      PROPERTIES COMPILE_OPTIONS "/FI\"${_pgl_forced_include}\"")
  # The Windows patch rewrites upstream's random() call to rand() (the MSVC
  # equivalent), so no random->rand macro is needed here. Defining one is
  # actively harmful on PostgreSQL 14: port.h declares `extern long
  # random(void)` there, which the macro would turn into a conflicting
  # redeclaration of rand() from stdlib.h.
  target_compile_options(pglogical_create_subscriber PRIVATE
      ${PGLOGICAL_CLANG_SUPPRESSIONS})
endif()

# ---------------------------------------------------------------------------
# 8. pglogical.control generation (from pglogical.control.in)
# ---------------------------------------------------------------------------
set(_control_in "${PGLOGICAL_SOURCE_DIR}/pglogical.control.in")
if(NOT EXISTS "${_control_in}")
  message(FATAL_ERROR "Missing upstream file: ${_control_in}")
endif()
file(READ "${_control_in}" _control_template)
string(REPLACE "__PGLOGICAL_VERSION__" "${PGLOGICAL_VERSION}" _control_text "${_control_template}")
string(REPLACE "__REQUIRES__" "" _control_text "${_control_text}")
set(_generated_control "${CMAKE_BINARY_DIR}/generated/pglogical.control")
file(WRITE "${_generated_control}" "${_control_text}")

# ---------------------------------------------------------------------------
# 9. Install / staging rules (installation-oriented layout)
# ---------------------------------------------------------------------------
install(TARGETS pglogical pglogical_output
        RUNTIME DESTINATION lib
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib)
install(TARGETS pglogical_create_subscriber RUNTIME DESTINATION bin)
install(FILES "${_generated_control}" DESTINATION share/extension)
# Only the extension SQL scripts and the legacy origin control file belong in
# share/extension. install(DIRECTORY ...) would drag the whole upstream source
# tree in (compat*/docs/expected/internals-doc/sql/t/.git/pglogical_dump as
# empty dirs + test SQL files), so select the files explicitly — mirroring the
# upstream Makefile DATA list.
file(GLOB _pglogical_sql "${PGLOGICAL_SOURCE_DIR}/pglogical--*.sql")
list(APPEND _pglogical_sql
     "${PGLOGICAL_SOURCE_DIR}/pglogical_origin.control"
     "${PGLOGICAL_SOURCE_DIR}/pglogical_origin--1.0.0.sql")
install(FILES ${_pglogical_sql} DESTINATION share/extension)

# ---------------------------------------------------------------------------
# 10. Post-build export verification hook (runs when dumpbin is on PATH)
# ---------------------------------------------------------------------------
find_program(DUMPBIN_EXECUTABLE dumpbin)
if(DUMPBIN_EXECUTABLE)
  foreach(_target pglogical pglogical_output)
    add_custom_command(TARGET ${_target} POST_BUILD
      COMMAND "${DUMPBIN_EXECUTABLE}" /nologo /exports "$<TARGET_FILE:${_target}>"
              > "${CMAKE_BINARY_DIR}/${_target}.exports.txt"
      COMMENT "Dumping exports of ${_target}"
      VERBATIM)
  endforeach()
endif()

message(STATUS "Configured pglogical ${PGLOGICAL_VERSION} for PostgreSQL ${PG_MAJOR} (${ARCH}, ${CONFIGURATION})")
message(STATUS "  module sources: ${_module_sources}")
message(STATUS "  stage via: cmake --install ${CMAKE_BINARY_DIR} --config ${CONFIGURATION} --prefix <stage>")
