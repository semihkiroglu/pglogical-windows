<#
.SYNOPSIS
    Regression tests for PostgreSQL's output_plugin_libraries security GUC.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

Test-Case 'output plugin GUC support follows the patched PostgreSQL minor thresholds' {
    Assert-False (Test-PgLogicalOutputPluginGucSupported -PgMajor 14 -PgMinor 23)
    Assert-True (Test-PgLogicalOutputPluginGucSupported -PgMajor 14 -PgMinor 24)
    Assert-False (Test-PgLogicalOutputPluginGucSupported -PgMajor 15 -PgMinor 18)
    Assert-True (Test-PgLogicalOutputPluginGucSupported -PgMajor 15 -PgMinor 19)
    Assert-False (Test-PgLogicalOutputPluginGucSupported -PgMajor 16 -PgMinor 14)
    Assert-True (Test-PgLogicalOutputPluginGucSupported -PgMajor 16 -PgMinor 15)
    Assert-False (Test-PgLogicalOutputPluginGucSupported -PgMajor 17 -PgMinor 10)
    Assert-True (Test-PgLogicalOutputPluginGucSupported -PgMajor 17 -PgMinor 11)
    Assert-False (Test-PgLogicalOutputPluginGucSupported -PgMajor 18 -PgMinor 5)
    Assert-True (Test-PgLogicalOutputPluginGucSupported -PgMajor 18 -PgMinor 6)
}

$script:NativeCalls = @()
$script:OutputPluginSetting = "`"pgoutput, test_decoding, wal2json,`r`n pglogical_output`""

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
    throw "Unexpected SQL in fake psql: $sql"
}

$script:NativeProcessRunner = 'Invoke-FakeOutputPluginNativeProcess'

Test-Case 'supported PostgreSQL verification accepts wrapped output and preserves existing plugins' {
    $script:NativeCalls = @()
    $script:OutputPluginSetting = "`"pgoutput, test_decoding, wal2json,`r`n pglogical_output`""

    $verified = Test-PgLogicalOutputPluginConfigured -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'

    Assert-True $verified
    Assert-Equal 1 @($script:NativeCalls).Count
}

Test-Case 'pre-whitelist PostgreSQL skips verification without failing' {
    $script:NativeCalls = @()
    $script:OutputPluginSetting = ''

    $verified = Test-PgLogicalOutputPluginConfigured -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'

    Assert-False $verified
    Assert-Equal 1 @($script:NativeCalls).Count
}

Test-Case 'supported PostgreSQL fails closed when the start-time config omits pglogical_output' {
    $script:NativeCalls = @()
    $script:OutputPluginSetting = 'pgoutput, test_decoding'

    Assert-Throws {
        Test-PgLogicalOutputPluginConfigured -PsqlPath 'psql.exe' -PgHost '127.0.0.1' -Port '5432'
    } -MessagePattern 'pglogical_output'
}

$script:NativeProcessRunner = $null
Complete-Tests
