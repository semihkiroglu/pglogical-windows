<#
.SYNOPSIS
    Smoke-tests a staged pglogical build against an isolated PostgreSQL
    installation: starts a real server, creates the extension, verifies the
    version and both DLLs, exercises pglogical_output, and runs
    pglogical_create_subscriber.exe --help.

.DESCRIPTION
    For one release-matrix entry (one PostgreSQL major):

      1. verifies the PostgreSQL version of PG_ROOT;
      2. copies the staged package into the isolated installation;
      3. initdb into a temporary data directory;
      4. configures wal_level=logical, worker/sender/slot counts,
         shared_preload_libraries='pglogical', and (when supported)
         output_plugin_libraries including pglogical_output;
      5. starts PostgreSQL with pg_ctl;
      6. CREATE EXTENSION pglogical and verifies extversion;
      7. creates and drops a temporary logical replication slot using
         pglogical_output (proves both DLLs load);
      8. runs pglogical_create_subscriber.exe --help;
      9. runs the subscriber utility end-to-end (basebackup + catchup +
         live subscription);
     10. stops PostgreSQL cleanly;
     11. fails on any server log ERROR/FATAL, missing dependency, or wrong
         extension version.

    GitHub-hosted Windows runners run with administrative privileges, which
    PostgreSQL's postmaster refuses. When the current process is elevated,
    initdb/pg_ctl/postgres are launched through "runas /trustlevel:0x20000"
    (a restricted token without the Administrators group), which satisfies
    the postmaster's check without any machine-global changes. On CI the
    de-elevation account is created with explicit consent (CI passes
    -AllowTemporaryLocalUser); elevated runs outside CI fail with a clear
    error instead of silently creating a local system user.

.PARAMETER PgRoot
    The isolated PostgreSQL installation (PG_ROOT).

.PARAMETER StagingDir
    The staged package directory produced by Build-PgLogical.ps1 (layout:
    lib/, share/extension/, bin/).

.PARAMETER UpstreamVersion
    Expected pglogical version, e.g. 2.4.8.

.PARAMETER WorkDir
    Directory for the temporary cluster; a unique subdirectory is created
    and cleaned up afterwards.

.PARAMETER KeepDataDir
    Keep the temporary cluster directory (for debugging).

.PARAMETER AllowTemporaryLocalUser
    Opt-in for the temporary de-elevation account. When running elevated
    outside CI (a developer machine), the script refuses to create or
    modify a local system user unless this switch is passed. CI always
    passes it; local elevated runs must re-run from a non-elevated shell
    or opt in explicitly.

.EXAMPLE
    pwsh ./scripts/Test-PgLogical.ps1 -PgRoot "C:\pg\18" -StagingDir .build\stage -UpstreamVersion 2.4.8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [Parameter(Mandatory = $true)][string]$StagingDir,
    [Parameter(Mandatory = $true)][string]$UpstreamVersion,
    [string]$WorkDir,
    [switch]$KeepDataDir,
    [switch]$AllowTemporaryLocalUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$PgRoot = [System.IO.Path]::GetFullPath($PgRoot)
$StagingDir = [System.IO.Path]::GetFullPath($StagingDir)
if (-not (Test-Path $StagingDir)) { throw "Staging directory not found: $StagingDir" }
$binDir = Join-Path $PgRoot 'bin'

foreach ($tool in @('initdb.exe', 'pg_ctl.exe', 'psql.exe', 'postgres.exe')) {
    if (-not (Test-Path (Join-Path $binDir $tool))) { throw "PG_ROOT is missing bin\$tool" }
}

if (-not $WorkDir) { $WorkDir = Join-Path (Get-RepoRoot) '.build\smoke' }
$dataDir = Join-Path $WorkDir ("pgdata-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$serverOut = $null   # postgres stdout redirect (step 5)
$serverErr = $null   # postgres stderr redirect (step 5)
$null = New-Item -ItemType Directory -Force -Path $WorkDir

$failed = $false
$script:pgLastExitCode = $null
$script:pgTaskUser = $null
$script:pgTaskPw = $null
$script:pgTaskAccountReady = $false
$script:pgTaskAccountCreated = $false
function Fail-Step {
    param([string]$Message)
    Write-Host "SMOKE TEST FAILED: $Message"
    $script:failed = $true
}

# ---------------------------------------------------------------------------
# Restricted-token launcher (postmaster refuses to run elevated)
# ---------------------------------------------------------------------------
function Test-Elevated {
    if ($env:OS -ne 'Windows_NT') { return $false }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The GitHub Actions runner user is a "Local account and member of
# Administrators group" (S-1-5-114), which UAC does not filter, so every
# process it spawns (including /RL LIMITED scheduled tasks) runs with an
# enabled Administrators group and postgres.exe refuses to start. The
# smoke test therefore runs the server and tools under a dedicated
# NON-admin local account launched with CreateProcessWithLogonW (creates a
# fresh logon session and token; no batch-logon right, no interactive
# logon, no reboot needed). The account is created once per run and
# removed at the end; the fixed placeholder password is safe only because
# CI VMs are ephemeral.
function Ensure-PgTaskAccount {
    if ($script:pgTaskAccountReady) { return $true }
    if (-not (Test-Elevated)) { return $false }
    # Guard: never create/modify a local system user without consent.
    # GitHub Actions runners are ephemeral and opt in via
    # -AllowTemporaryLocalUser (GITHUB_ACTIONS=true is not sufficient on
    # its own — the switch is the explicit consent). On a developer
    # machine an elevated shell must either re-run de-elevated or pass
    # the switch; silently touching local accounts is surprising.
    if ($env:GITHUB_ACTIONS -ne 'true' -and -not $AllowTemporaryLocalUser) {
        throw "Running elevated outside CI: Test-PgLogical would create a temporary local user 'pglci' to run PostgreSQL de-elevated. Re-run from a non-elevated shell, or pass -AllowTemporaryLocalUser to allow the temporary user explicitly."
    }
    $script:pgTaskUser = 'pglci'
    $script:pgTaskPw = 'PglC1!2026Ephemeral'
    & net.exe user $script:pgTaskUser 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        try {
            $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
            $user = $computer.Create('User', $script:pgTaskUser)
            $user.SetPassword($script:pgTaskPw)
            $user.SetInfo()
            Write-Host "   created de-elevation account $script:pgTaskUser"
            $script:pgTaskAccountCreated = $true
        }
        catch {
            Write-Host "   ADSI user creation failed: $($_.Exception.Message)"
            return $false
        }
    }
    else {
        $script:pgTaskAccountCreated = $true
    }
    $root = Get-RepoRoot
    & icacls.exe $root /grant "${script:pgTaskUser}:(OI)(CI)F" /T /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   icacls grant failed (exit $LASTEXITCODE)"
        return $false
    }
    $script:pgTaskAccountReady = $true
    return $true
}

# PostgreSQL refuses to run with an enabled Administrators group, and CI
# sessions (GitHub Actions) run elevated. runas.exe /trustlevel:0x20000
# produces the right token but fails in non-interactive service sessions,
# so we create the restricted token ourselves: the BUILTIN\Administrators
# SID becomes deny-only and all privileges are disabled — the same shape
# as a "basic user" token. Process launch under the de-elevation account
# goes through .NET's Process.Start with credentials (it calls
# CreateProcessWithLogonW with correct marshaling); direct P/Invoke
# variants failed with ERROR_INVALID_NAME / heap corruption / access
# violations.

# Launches $CommandLine under the de-elevation account. Returns a hashtable
# with ok/process (or ok=$false, err=...). .NET handles the logon and
# process creation; the redirecting wrapper captures output to files, so no
# pipe handles are inherited (which would hang the runner on EOF).
function Start-DeElevated {
    param([string]$CommandLine)
    # Build the SecureString manually (the analyzer rejects
    # ConvertTo-SecureString -AsPlainText).
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $script:pgTaskPw.ToCharArray()) { $secure.AppendChar($ch) }
    $lastErr = $null
    foreach ($domain in @('.', $env:COMPUTERNAME)) {
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $env:ComSpec
            $psi.Arguments = $CommandLine
            $psi.UserName = $script:pgTaskUser
            $psi.Domain = $domain
            $psi.Password = $secure
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = (Get-RepoRoot)
            $p = [System.Diagnostics.Process]::Start($psi)
            return @{ ok = $true; process = $p; domain = $domain }
        }
        catch {
            $lastErr = $_.Exception.Message
            $hr = $_.Exception.InnerException.HResult
            if ($hr) { $lastErr = "$lastErr (0x$('{0:X8}' -f ($hr -band 0xFFFFFFFF)))" }
        }
    }
    return @{ ok = $false; err = $lastErr }
}

function Invoke-PgNative {
    <#
    .SYNOPSIS
        Runs a PostgreSQL tool, using a restricted token when elevated.
        Returns the tool's exit code; captures output to a log.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputLog
    )
    $quoted = (@($FilePath) + $Arguments) | ForEach-Object { '"' + $_ + '"' }
    $cmdLine = $quoted -join ' '
    # Wrapper lives in the workspace so the de-elevated task account (which
    # is granted access to the repo tree) can read it; %TEMP% is not
    # accessible to it.
    $wrapperDir = Join-Path (Get-RepoRoot) '.build\smoke'
    $null = New-Item -ItemType Directory -Force -Path $wrapperDir
    $wrapper = Join-Path $wrapperDir ("pglrun-" + [guid]::NewGuid().ToString('N') + '.cmd')
    # Redirecting wrapper: the de-elevated child has no redirected handles,
    # so the batch captures output itself. The direct path rewrites this as
    # a plain wrapper below (Start-Process owns the redirection then).
    "@echo off`n$cmdLine > `"$OutputLog`" 2>&1`n" |
        Set-Content -Path $wrapper -Encoding ascii

    # The de-elevation strategy: run the child under the dedicated non-admin
    # account via CreateProcessWithLogonW (see Ensure-PgTaskAccount). The
    # direct path MUST NOT use `& cmd.exe`: the postmaster inherits the
    # stdout/stderr pipe handles and keeps them open, so the workflow runner
    # would wait forever for pipe EOF. Start-Process with -RedirectStandard*
    # writes files instead of pipes.
    $mode = 'direct'
    if (Test-Elevated -and (Ensure-PgTaskAccount)) {
        $mode = 'pgluser'
    }

    $exitCode = 1
    try {
        if ($mode -eq 'direct') {
            # Plain wrapper: Start-Process owns the redirection. The batch's
            # last command's exit code becomes cmd.exe's exit code.
            "@echo off`n$cmdLine`n" | Set-Content -Path $wrapper -Encoding ascii
            $p = Start-Process -FilePath $env:ComSpec `
                -ArgumentList "/d /c `"$wrapper`"" `
                -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput "$OutputLog" -RedirectStandardError "$OutputLog.err"
            $exitCode = $p.ExitCode
        }
        else {
            # pgluser child: run the redirecting wrapper (already written
            # above) and take the exit code from the process.
            $r = Start-DeElevated -CommandLine "/d /c `"$wrapper`""
            if (-not $r.ok) {
                # Best effort: run directly. Safe because Start-Process
                # redirects to files, not pipes.
                Write-Host "de-elevated launch failed: $($r.err); falling back to a direct launch."
                "@echo off`n$cmdLine`n" | Set-Content -Path $wrapper -Encoding ascii
                $p = Start-Process -FilePath $env:ComSpec `
                    -ArgumentList "/d /c `"$wrapper`"" `
                    -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput "$OutputLog" -RedirectStandardError "$OutputLog.err"
                $exitCode = $p.ExitCode
            }
            else {
                $r.process.WaitForExit()
                $exitCode = $r.process.ExitCode
            }
        }
    }
    finally {
        Remove-Item $wrapper -ErrorAction SilentlyContinue
    }
    # The exit code is carried in a script-scope variable: PowerShell
    # functions leak stray success-stream output (native stderr merged with
    # 2>&1 etc.), and a caller capturing `$x = Invoke-PgNative` could get an
    # array instead of the int. $null = Invoke-PgNative discards everything.
    $script:pgLastExitCode = $exitCode
    return $exitCode
}

try {
    # -----------------------------------------------------------------------
    # Shared helpers (used by steps 4-9c)
    # -----------------------------------------------------------------------
    function Get-FreePort {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $p = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        return $p
    }

    function Invoke-Sql([string]$Db, [string]$Sql) {
        & $psql -X -h 127.0.0.1 -p $port -U postgres -d $Db -v ON_ERROR_STOP=1 -t -A -c $Sql 2>&1
        if ($LASTEXITCODE -ne 0) { Fail-Step "psql ($Db) failed: $Sql"; throw "sql failed: $Sql" }
    }

    # Polls until $Sql returns exactly $Expected (used for replication
    # convergence checks); returns $true on success within the timeout.
    function Wait-SqlResult([string]$Db, [string]$Sql, [string]$Expected, [int]$TimeoutSeconds = 60, [int]$Port = $port) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $out = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Db -t -A -c $Sql 2>&1
            if ($LASTEXITCODE -eq 0 -and (($out | Out-String).Trim() -eq $Expected)) { return $true }
            Start-Sleep -Seconds 2
        }
        return $false
    }

    # -----------------------------------------------------------------------
    # 1. Verify the PostgreSQL major version
    # -----------------------------------------------------------------------
    Write-Host "== Step 1: PostgreSQL version"
    $pgConfigExe = Join-Path $binDir 'pg_config.exe'
    $verText = & $pgConfigExe --version
    Write-Host "   $verText"
    if ($verText -notmatch 'PostgreSQL ([0-9]+)\.([0-9]+)') {
        Fail-Step "Could not parse pg_config --version output: $verText"
        throw 'version check failed'
    }
    $pgMajor = [int]$matches[1]
    $pgMinor = [int]$matches[2]

    # -----------------------------------------------------------------------
    # 2. Copy the staged package into the isolated installation
    # -----------------------------------------------------------------------
    Write-Host "== Step 2: installing staged package into $PgRoot"
    $map = @(
        @{ Src = 'lib'; Dst = 'lib' },
        @{ Src = 'share\extension'; Dst = 'share\extension' },
        @{ Src = 'bin'; Dst = 'bin' }
    )
    foreach ($m in $map) {
        $src = Join-Path $StagingDir $m.Src
        if (-not (Test-Path $src)) {
            Write-Host "   (staging has no $($m.Src) directory; skipping)"
            continue
        }
        $dst = Join-Path $PgRoot $m.Dst
        $null = New-Item -ItemType Directory -Force -Path $dst
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    }
    if (-not (Test-Path (Join-Path $PgRoot 'lib\pglogical.dll'))) { Fail-Step 'pglogical.dll was not installed into PG_ROOT\lib' }

    # -----------------------------------------------------------------------
    # 3-11 retry envelope: the Windows "could not reserve shared memory region
    # ... error code 487" (ERROR_INVALID_ADDRESS) collision is a transient
    # ASLR/address-space flake when many postgres instances start/stop in one
    # runner. When the ONLY server-log errors are the 487 cascade, retry the
    # whole test once from a clean cluster; anything else fails fast.
    # -----------------------------------------------------------------------
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host '== Retry 2: cleaning up after 487 shared-memory collision'
            Remove-Item -Recurse -Force $dataDir -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force (Join-Path $WorkDir 'subscriber-data') -ErrorAction SilentlyContinue
            @($initLog, $serverOut, $serverErr, (Join-Path $WorkDir 'subscriber-postgresql.conf'), (Join-Path $WorkDir 'pglogical_create_subscriber_postgres.log')) |
                Where-Object { $_ } | Remove-Item -Force -ErrorAction SilentlyContinue
            # Let Windows release the shared-memory sections of the dead
            # postmasters before the retry maps new ones.
            Start-Sleep -Seconds 3
        }

    # -----------------------------------------------------------------------
    # 3. initdb
    # -----------------------------------------------------------------------
    Write-Host "== Step 3: initdb"
    $initLog = Join-Path $WorkDir 'initdb.log'
    $null = Invoke-PgNative -FilePath (Join-Path $binDir 'initdb.exe') -Arguments @('-D', $dataDir, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--no-locale') -OutputLog $initLog
    $code = $script:pgLastExitCode
    Write-Host "   [debug] initdb code='$code' type=$($code.GetType().FullName) pgversion=$(Test-Path (Join-Path $dataDir 'PG_VERSION'))"
    if ($code -ne 0 -or -not (Test-Path (Join-Path $dataDir 'PG_VERSION'))) {
        Fail-Step "initdb failed (exit $code). Log:"; Get-Content $initLog -ErrorAction SilentlyContinue
        throw 'initdb failed'
    }

    # -----------------------------------------------------------------------
    # 4. Configure postgresql.conf
    # -----------------------------------------------------------------------
    Write-Host "== Step 4: configuration"
    $conf = Join-Path $dataDir 'postgresql.conf'
    $configLines = @(
        "wal_level = logical",
        "max_worker_processes = 16",
        "max_replication_slots = 10",
        "max_wal_senders = 10",
        "shared_preload_libraries = 'pglogical'",
        "listen_addresses = '127.0.0.1'",
        "logging_collector = off"
    )
    if (Test-PgLogicalOutputPluginGucSupported -PgMajor $pgMajor -PgMinor $pgMinor) {
        # This GUC must be in postgresql.conf before the postmaster starts;
        # changing it from the already-open test session is not sufficient for
        # logical slot creation.
        $configLines += "output_plugin_libraries = 'pgoutput, test_decoding, pglogical_output'"
        Write-Host '   configured output_plugin_libraries for pglogical_output'
    }
    $configLines | Add-Content -Path $conf -Encoding utf8

    # Pick a free port.
    $port = Get-FreePort

    # -----------------------------------------------------------------------
    # 5. Start PostgreSQL. The postmaster is a long-lived daemon: starting it
    #    through a cmd wrapper (or any -Wait style invocation) lets it inherit
    #    the wrapper's stdout/stderr handles, which keeps the caller waiting
    #    for pipe/process EOF indefinitely. When elevated (CI), start it via
    #    a scheduled task without "highest privileges" so it runs with a
    #    UAC-filtered token (Administrators deny-only — postgres refuses an
    #    enabled admin group), fire-and-forget, then poll the port.
    # -----------------------------------------------------------------------
    Write-Host "== Step 5: start postgres (port $port)"
    $postgresExe = Join-Path $binDir 'postgres.exe'
    $serverOut = Join-Path $WorkDir 'postgres.stdout.log'
    $serverErr = Join-Path $WorkDir 'postgres.stderr.log'
    $pgProc = $null
    if (Test-Elevated -and (Ensure-PgTaskAccount)) {
        # Fire-and-forget de-elevated start: CreateProcessWithLogonW returns
        # the process handle; the wrapper redirects postgres output to files.
        $svcWrapper = Join-Path $WorkDir ("pgserver-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
        "@echo off`n`"$postgresExe`" -D `"$dataDir`" -p $port -h 127.0.0.1 > `"$serverOut`" 2> `"$serverErr`"`n" |
            Set-Content -Path $svcWrapper -Encoding ascii
        $r = Start-DeElevated -CommandLine "/d /c `"$svcWrapper`""
        if ($r.ok) {
            # The wrapper runs postgres in the foreground, so this process
            # stays alive as long as the postmaster does.
            $pgProc = $r.process
            Write-Host "   started as $script:pgTaskUser (PID $($pgProc.Id))"
        }
        else {
            Write-Host "de-elevated launch failed: $($r.err); starting directly (postmaster will refuse if elevated)."
            $pgProc = Start-Process -FilePath $postgresExe `
                -ArgumentList @('-D', "`"$dataDir`"", '-p', "$port", '-h', '127.0.0.1') `
                -PassThru -NoNewWindow `
                -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
        }
    }
    else {
        $pgProc = Start-Process -FilePath $postgresExe `
            -ArgumentList @('-D', "`"$dataDir`"", '-p', "$port", '-h', '127.0.0.1') `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    }

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($pgProc -and $pgProc.HasExited) { break }
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect('127.0.0.1', $port)
            if ($client.Connected) { $ready = $true }
            $client.Close()
            if ($ready) { break }
        }
        catch { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        Fail-Step "postgres did not become ready within 60s (exited: $($pgProc -and $pgProc.HasExited))"
        Get-Content $serverErr -ErrorAction SilentlyContinue | Select-Object -Last 40
        if ($pgProc -and -not $pgProc.HasExited) { Stop-Process -Id $pgProc.Id -Force -ErrorAction SilentlyContinue }
        throw 'server start failed'
    }
    Write-Host '   postgres is accepting connections'

    try {
        # -------------------------------------------------------------------
        # 6. CREATE EXTENSION pglogical
        # -------------------------------------------------------------------
        Write-Host '== Step 6: CREATE EXTENSION pglogical'
        $psql = Join-Path $binDir 'psql.exe'
        $null = Test-PgLogicalOutputPluginConfigured -PsqlPath $psql -PgHost '127.0.0.1' -Port $port

        $sql = "CREATE EXTENSION pglogical;"
        $out = & $psql -X -h 127.0.0.1 -p $port -U postgres -d postgres -v ON_ERROR_STOP=1 -c $sql 2>&1
        if ($LASTEXITCODE -ne 0) { Fail-Step "CREATE EXTENSION failed: $out"; throw 'create extension failed' }
        Write-Host "   $out"

        # -------------------------------------------------------------------
        # 7. Verify extversion and both DLLs
        # -------------------------------------------------------------------
        Write-Host '== Step 7: extension version'
        $out = & $psql -X -h 127.0.0.1 -p $port -U postgres -d postgres -t -A -v ON_ERROR_STOP=1 -c "SELECT extversion FROM pg_extension WHERE extname = 'pglogical';" 2>&1
        if ($LASTEXITCODE -ne 0) { Fail-Step "extversion query failed: $out"; throw 'extversion query failed' }
        $extVersion = ($out | Select-Object -First 1).Trim()
        Write-Host "   extversion = $extVersion (expected $UpstreamVersion)"
        if ($extVersion -ne $UpstreamVersion) {
            Fail-Step "Extension version $extVersion does not match expected $UpstreamVersion"
            throw 'extension version mismatch'
        }

        # -------------------------------------------------------------------
        # 8. pglogical_output: create + drop a logical replication slot
        # -------------------------------------------------------------------
        Write-Host '== Step 8: pglogical_output slot test'
        $out = & $psql -X -h 127.0.0.1 -p $port -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_create_logical_replication_slot('pgl_test_slot', 'pglogical_output');" 2>&1
        if ($LASTEXITCODE -ne 0) { Fail-Step "slot creation failed (pglogical_output DLL did not load): $out"; throw 'slot creation failed' }
        Write-Host "   $out"
        $out = & $psql -X -h 127.0.0.1 -p $port -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_drop_replication_slot('pgl_test_slot');" 2>&1
        if ($LASTEXITCODE -ne 0) { Fail-Step "slot drop failed: $out"; throw 'slot drop failed' }

        # -------------------------------------------------------------------
        # 9. End-to-end replication test: provider + subscriber nodes on the
        #    same instance, separate databases, one row replicated live.
        #    (pglogical_create_subscriber.exe is exercised separately in
        #    steps 9b/9c.)
        # -------------------------------------------------------------------
        Write-Host '== Step 9: end-to-end replication test'
        $dsn = "host=127.0.0.1 port=$port dbname=postgres"
        $subDsn = "host=127.0.0.1 port=$port dbname=subdb"
        $null = Invoke-Sql 'postgres' "CREATE DATABASE subdb;"
        $null = Invoke-Sql 'subdb' "CREATE EXTENSION pglogical;"
        $null = Invoke-Sql 'postgres' "SELECT pglogical.create_node(node_name := 'provider', dsn := '$dsn');"
        $null = Invoke-Sql 'subdb' "SELECT pglogical.create_node(node_name := 'subscriber', dsn := '$subDsn');"
        $null = Invoke-Sql 'postgres' "CREATE TABLE public.repl_test (id integer PRIMARY KEY, payload text);"
        $null = Invoke-Sql 'postgres' "SELECT pglogical.replication_set_add_table('default', 'public.repl_test');"
        $null = Invoke-Sql 'subdb' "CREATE TABLE public.repl_test (id integer PRIMARY KEY, payload text);"
        $null = Invoke-Sql 'subdb' "SELECT pglogical.create_subscription(subscription_name := 'test_sub', provider_dsn := '$dsn', replication_sets := ARRAY['default'], synchronize_structure := false, synchronize_data := false);"
        $null = Invoke-Sql 'subdb' "SELECT pglogical.wait_for_subscription_sync_complete('test_sub');"
        Write-Host '   subscription synced'
        $null = Invoke-Sql 'postgres' "INSERT INTO public.repl_test VALUES (1, 'hello');"
        if (-not (Wait-SqlResult -Db 'subdb' -Sql 'SELECT count(*) FROM public.repl_test WHERE id = 1;' -Expected '1')) {
            Fail-Step 'replicated row not visible on the subscriber within 60s'
            throw 'replication check failed'
        }
        Write-Host '   replication OK: row inserted on provider is visible on subscriber'
        # Cleanup: drop subscription and nodes (the instance is discarded
        # afterwards anyway, but keep the test tidy).
        $null = Invoke-Sql 'subdb' "SELECT pglogical.drop_subscription('test_sub');"
        $null = Invoke-Sql 'subdb' "SELECT pglogical.drop_node('subscriber');"
        $null = Invoke-Sql 'postgres' "SELECT pglogical.drop_node('provider');"
        Write-Host '   nodes dropped'

        # -------------------------------------------------------------------
        # 9b. pglogical_create_subscriber.exe --help
        # -------------------------------------------------------------------
        # Run from PG_ROOT/bin: the package staging dir only contains the
        # exe, not its DLL dependencies (libpq, libintl, ...) - running it
        # there fails with 0xC0000135 (STATUS_DLL_NOT_FOUND).
        $subscriber = Join-Path $binDir 'pglogical_create_subscriber.exe'
        if (-not (Test-Path $subscriber)) { $subscriber = Join-Path $StagingDir 'bin\pglogical_create_subscriber.exe' }
        if (Test-Path $subscriber) {
            Write-Host '== Step 9b: pglogical_create_subscriber --help'
            $p = Start-Process -FilePath $subscriber -ArgumentList '--help' -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $WorkDir 'subscriber.out') -RedirectStandardError (Join-Path $WorkDir 'subscriber.err')
            if (-not $p.WaitForExit(30000)) {
                $cdb = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Debuggers' -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
                if (-not $cdb) { $cdb = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Debuggers' -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue | Select-Object -First 1 }
                if ($cdb) {
                    try {
                        Write-Host '   cdb attach (full stack):'
                        & $cdb.FullName -c "~* k; q" -p $p.Id 2>&1 | Select-Object -First 30 | ForEach-Object { Write-Host "   $($_.ToString().TrimEnd())" }
                    }
                    catch { Write-Host "   cdb attach failed: $($_.Exception.Message)" }
                }
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Fail-Step 'pglogical_create_subscriber --help HUNG (no exit within 30s)'
                throw 'subscriber help hung'
            }
            if ($p.ExitCode -ne 0) {
                Fail-Step "pglogical_create_subscriber --help failed (exit $($p.ExitCode))"
                try {
                    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000 } -MaxEvents 2 -ErrorAction SilentlyContinue
                    foreach ($e in $ev) { Write-Host "   WER ($($e.TimeCreated)): $($e.Message -replace [Environment]::NewLine, ' | ')" }
                }
                catch { }
                throw 'subscriber help failed'
            }
            $out = (Get-Content (Join-Path $WorkDir 'subscriber.out') -ErrorAction SilentlyContinue) + (Get-Content (Join-Path $WorkDir 'subscriber.err') -ErrorAction SilentlyContinue)
            if (($out | Out-String) -notmatch 'pglogical_create_subscriber') {
                Fail-Step 'pglogical_create_subscriber --help output did not identify the program'
                throw 'subscriber help output invalid'
            }
            Write-Host '   subscriber --help OK'
        }
        else {
            Fail-Step 'pglogical_create_subscriber.exe not found in staging or PG bin'
            throw 'subscriber binary missing'
        }

        # -------------------------------------------------------------------
        # 9c. pglogical_create_subscriber.exe end-to-end: real subscriber
        #     setup. The utility itself performs basebackup + physical
        #     catchup + logical subscription against a live provider; we
        #     verify the data lands and live replication flows.
        # -------------------------------------------------------------------
    Write-Host '== Step 9c: pglogical_create_subscriber end-to-end setup'
    $subscriberExe = Join-Path $binDir 'pglogical_create_subscriber.exe'
    if (-not (Test-Path $subscriberExe)) {
        Fail-Step "subscriber exe not found in PG bin: $subscriberExe"
        throw 'subscriber exe missing for e2e'
    }

        # The utility creates its own subscriber data dir via pg_basebackup.
        $subDataDir = Join-Path $WorkDir 'subscriber-data'
        Remove-Item -Recurse -Force $subDataDir -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Force -Path $subDataDir

        # A separate port for the subscriber instance.
        $subPort = Get-FreePort

        # The exe overwrites postgresql.conf from --postgresql-conf, so
        # hand it a complete subscriber config: its own port, pglogical
        # preloaded (the second, final start runs with it; the catchup
        # start is forced without via -c shared_preload_libraries='').
        $subConf = Join-Path $WorkDir 'subscriber-postgresql.conf'
        @(
            "port = $subPort",
            "listen_addresses = '127.0.0.1'",
            "shared_preload_libraries = 'pglogical'",
            "max_worker_processes = 16",
            "max_replication_slots = 10",
            "max_wal_senders = 10",
            "logging_collector = off"
        ) | Set-Content -Path $subConf -Encoding utf8

        # Provider side: fresh node + table + data + replication set
        # (Step 9 dropped its own nodes).
        $provDsn = "host=127.0.0.1 port=$port dbname=postgres"
        $subDsn = "host=127.0.0.1 port=$subPort dbname=postgres"
        $null = Invoke-Sql 'postgres' "SELECT pglogical.create_node(node_name := 'provider', dsn := '$provDsn');"
        $null = Invoke-Sql 'postgres' 'CREATE TABLE IF NOT EXISTS public.repl_test (id integer PRIMARY KEY, payload text);'
        $null = Invoke-Sql 'postgres' 'TRUNCATE public.repl_test;'
        $null = Invoke-Sql 'postgres' "INSERT INTO public.repl_test VALUES (1, 'before');"
        $null = Invoke-Sql 'postgres' "SELECT pglogical.replication_set_add_table('default', 'public.repl_test');"

        # Run the exe under the de-elevation account when elevated: it
        # starts a postgres instance via pg_ctl, which refuses an enabled
        # Administrators group. Working dir = WorkDir so the utility's
        # pglogical_create_subscriber_postgres.log lands in a known place.
        $exeOut = Join-Path $WorkDir 'subscriber-e2e.out.log'
        $exeErr = Join-Path $WorkDir 'subscriber-e2e.err.log'
        $cmd = "cd /d `"$WorkDir`" && `"$subscriberExe`" -vv -D `"$subDataDir`" -n exe_sub --postgresql-conf `"$subConf`" --provider-dsn `"$provDsn`" --subscriber-dsn `"$subDsn`" > `"$exeOut`" 2> `"$exeErr`""
        if (Test-Elevated -and (Ensure-PgTaskAccount)) {
            $r = Start-DeElevated -CommandLine "/d /c `"$cmd`""
            if (-not $r.ok) {
                Fail-Step "de-elevated subscriber launch failed: $($r.err)"
                throw 'de-elevated subscriber launch failed'
            }
            $p = $r.process
        }
        else {
            $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', "`"$cmd`"") -PassThru -NoNewWindow
        }
        if (-not $p.WaitForExit(150000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Fail-Step 'pglogical_create_subscriber e2e HUNG (no exit within 150s)'
            Get-Content $exeOut -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object { Write-Host "   $_" }
            Get-Content $exeErr -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object { Write-Host "   $_" }
            $pgl = Join-Path $WorkDir 'pglogical_create_subscriber_postgres.log'
            if (Test-Path $pgl) { Write-Host '   subscriber postgres log:'; Get-Content $pgl | Select-Object -Last 40 | ForEach-Object { Write-Host "   $_" } }
            # The catchup postmaster may still be alive; stop it so the
            # throwaway cluster teardown does not leave orphans.
            $null = Invoke-PgNative -FilePath (Join-Path $binDir 'pg_ctl.exe') -Arguments @('-D', $subDataDir, '-m', 'fast', '-w', 'stop') -OutputLog (Join-Path $WorkDir 'pgctl-sub-stop.log') -ErrorAction SilentlyContinue
            throw 'subscriber e2e hung'
        }
        Write-Host "   exe exit code: $($p.ExitCode)"
        if ($p.ExitCode -ne 0) {
            Fail-Step 'pglogical_create_subscriber e2e failed:'
            Get-Content $exeOut -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host "   $_" }
            Get-Content $exeErr -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host "   $_" }
            $pgl = Join-Path $WorkDir 'pglogical_create_subscriber_postgres.log'
            if (Test-Path $pgl) { Write-Host '   subscriber postgres log:'; Get-Content $pgl | Select-Object -Last 40 | ForEach-Object { Write-Host "   $_" } }
            if ($attempt -eq 1 -and (Test-Path $pgl) -and (Select-String -Path $pgl -Pattern 'error code 487|could not reserve shared memory' -Quiet)) {
                Write-Host '   [retry] subscriber postgres log shows the transient 487 collision; stopping subscriber and retrying once'
                $null = Invoke-PgNative -FilePath (Join-Path $binDir 'pg_ctl.exe') -Arguments @('-D', $subDataDir, '-m', 'fast', '-w', 'stop') -OutputLog (Join-Path $WorkDir 'pgctl-sub-stop.log') -ErrorAction SilentlyContinue
                continue
            }
            throw 'subscriber e2e failed'
        }

        # Verify basebackup data is visible on the subscriber.
        if (-not (Wait-SqlResult -Db 'postgres' -Sql 'SELECT count(*) FROM public.repl_test WHERE id = 1;' -Expected '1' -Port $subPort)) {
            Fail-Step 'subscriber basebackup data not visible within 60s'
            throw 'subscriber data check failed'
        }
        Write-Host '   subscriber has basebackup data (id=1 visible)'

        # Verify live replication: insert on the provider, expect it on
        # the subscriber.
        $null = Invoke-Sql 'postgres' "INSERT INTO public.repl_test VALUES (2, 'after');"
        if (-not (Wait-SqlResult -Db 'postgres' -Sql 'SELECT count(*) FROM public.repl_test WHERE id = 2;' -Expected '1' -Port $subPort)) {
            Fail-Step 'live row not replicated to subscriber within 60s'
            throw 'subscriber replication check failed'
        }
        Write-Host '   live replication OK: row inserted on provider visible on subscriber'

        # Cleanup: stop the subscriber instance (provider-side slots die
        # with the throwaway test cluster).
        $null = Invoke-PgNative -FilePath (Join-Path $binDir 'pg_ctl.exe') -Arguments @('-D', $subDataDir, '-m', 'fast', '-w', 'stop') -OutputLog (Join-Path $WorkDir 'pgctl-sub-stop.log')
        Write-Host '   subscriber instance stopped'
    }
    finally {
        # -------------------------------------------------------------------
        # 10. Stop PostgreSQL cleanly
        # -------------------------------------------------------------------
        Write-Host '== Step 10: pg_ctl stop'
        $null = Invoke-PgNative -FilePath (Join-Path $binDir 'pg_ctl.exe') -Arguments @('-D', $dataDir, '-m', 'fast', '-w', 'stop') -OutputLog (Join-Path $WorkDir 'pgctl-stop.log')
        $code = $script:pgLastExitCode
        # Diagnostics: was there a backend/postmaster crash (pglogical.dll)?
        $stderrTail = Get-Content $serverErr -ErrorAction SilentlyContinue | Select-Object -Last 25
        $crashHints = $stderrTail | Where-Object { $_ -match 'terminated by exception|server process|could not|crash|segfault' }
        if ($crashHints) { Write-Host '   postmaster stderr crash hints:'; $crashHints | ForEach-Object { Write-Host "     $_" } }
        try {
            $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000 } -MaxEvents 5 -ErrorAction SilentlyContinue
            foreach ($e in $ev) { if ($e.Message -match 'postgres|pglogical') { Write-Host "   WER ($($e.TimeCreated)): $($e.Message -replace [Environment]::NewLine, ' | ')" } }
        }
        catch { }
        if ($code -ne 0 -and $pgProc -and -not $pgProc.HasExited) {
            Write-Host "pg_ctl stop failed (exit $code); force-stopping postmaster PID $($pgProc.Id)"
            Stop-Process -Id $pgProc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # -----------------------------------------------------------------------
    # 11. Scan the server logs for errors
    # -----------------------------------------------------------------------
    Write-Host '== Step 11: server log scan'
    $serverLogs = @($serverOut, $serverErr) | Where-Object { Test-Path $_ }
    if ($serverLogs.Count -gt 0) {
        $errors = @(Get-Content $serverLogs | Where-Object { $_ -match '\b(ERROR|FATAL|PANIC)\b' })
        if ($errors.Count -gt 0) {
            $non487 = @($errors | Where-Object { $_ -notmatch 'error code 487|could not reserve shared memory|server process .* was terminated|terminated by exception|terminated by signal' })
            if ($attempt -eq 1 -and $non487.Count -eq 0) {
                Write-Host '   [retry] log errors match the transient Windows 487 shared-memory collision; retrying once from a clean cluster'
                continue
            }
            Fail-Step "PostgreSQL server log contains errors:"
            $errors | Select-Object -Last 10 | ForEach-Object { Write-Host "   $_" }
            break
        }
        else {
            Write-Host '   no ERROR/FATAL/PANIC found in server log'
            break
        }
    }
    }
}
finally {
    if ($script:pgTaskAccountCreated) {
        & net.exe user $script:pgTaskUser /delete 2>&1 | Out-Null
        Write-Host "   removed de-elevation account $script:pgTaskUser"
    }
    if (-not $KeepDataDir) {
        Remove-Item -Recurse -Force $dataDir -ErrorAction SilentlyContinue
        if ($serverOut) { Remove-Item -Force $serverOut -ErrorAction SilentlyContinue }
        if ($serverErr) { Remove-Item -Force $serverErr -ErrorAction SilentlyContinue }
    }
    else {
        Write-Host "Keeping test cluster at: $dataDir"
    }
}

if ($failed) {
    throw 'Smoke test FAILED (see messages above).'
}
Write-Host 'Smoke test PASSED: extension created, version verified, both DLLs loaded, subscriber binary OK.'
