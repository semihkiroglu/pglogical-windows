<#
.SYNOPSIS
    Regression tests for PostgreSQL's output_plugin_libraries security GUC.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$script:NativeCalls = @()
$script:OutputPluginGucSupported = $true
$script:OutputPluginSetting = 'pgoutput, test_decoding, wal2json'
$script:OutputPluginSettingAfterAlter = 'pgoutput, test_decoding, wal2json, pglogical_output'

function Invoke-FakeOutputPluginNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $script:NativeCalls += , @($Arguments)
    $sqlIndex = [array]::IndexOf($Arguments, '-c') + 1
    $sql = if ($sqlIndex -gt 0) { $Arguments[$sqlIndex] } else { '' }

    if ($sql -like '*SELECT setting FROM pg_settings*') {
        return @{ ExitCode = 0; Stdout = $script:OutputPluginSetting; Stderr = '' }
    }
    if ($sql -like '*FROM pg_settings*') {
        if ($script:OutputPluginGucSupported) {
            return @{ ExitCode = 0; Stdout = '1'; Stderr = '' }
        }
        return @{ ExitCode = 0; Stdout = '0'; Stderr = '' }
    }
    if ($sql -like '*ALTER SYSTEM SET output_plugin_libraries*') {
        if ($null -ne $script:OutputPluginSettingAfterAlter) {
            $script:OutputPluginSetting = $script:OutputPluginSettingAfterAlter
        }
        return @{ ExitCode = 0; Stdout = 't'; Stderr = '' }
    }
    throw "Unexpected SQL in fake psql: $sql"
}

$script:NativeProcessRunner = 'Invoke-FakeOutputPluginNativeProcess'

Test-Case 'supported PostgreSQL config appends pglogical_output without dropping existing plugins' {
    $script:NativeCalls = @()
    $script:OutputPluginGucSupported = $true
    $script:OutputPluginSetting = 'pgoutput, test_decoding, wal2json'
    $script:OutputPluginSettingAfterAlter = 'pgoutput, test_decoding, wal2json, pglogical_output'

    $configured = Configure-PglogicalOutputPlugin -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'

    Assert-True $configured
    Assert-Equal 4 @($script:NativeCalls).Count
    $alterSql = $script:NativeCalls[2][([array]::IndexOf($script:NativeCalls[2], '-c') + 1)]
    Assert-True ($alterSql -match "ALTER SYSTEM SET output_plugin_libraries = 'pgoutput, test_decoding, wal2json, pglogical_output'")
}

Test-Case 'pre-whitelist PostgreSQL skips the unknown GUC without failing' {
    $script:NativeCalls = @()
    $script:OutputPluginGucSupported = $false
    $script:OutputPluginSettingAfterAlter = $null

    $configured = Configure-PglogicalOutputPlugin -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'

    Assert-False $configured
    Assert-Equal 1 @($script:NativeCalls).Count
}

Test-Case 'supported PostgreSQL fails closed when reload does not expose pglogical_output' {
    $script:NativeCalls = @()
    $script:OutputPluginGucSupported = $true
    $script:OutputPluginSetting = 'pgoutput, test_decoding'
    $script:OutputPluginSettingAfterAlter = $null

    Assert-Throws {
        Configure-PglogicalOutputPlugin -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'
    } -MessagePattern 'pglogical_output'
}

$script:NativeProcessRunner = $null
Complete-Tests
