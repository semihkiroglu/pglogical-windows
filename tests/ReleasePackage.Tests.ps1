<#
.SYNOPSIS
    Unit tests for published release package download and provenance checks.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$script:ApiMode = 'ok'
function Invoke-FakeReleaseGhApi {
    param([string[]]$Args)
    switch ($script:ApiMode) {
        'ok' {
            return @{ ExitCode = 0; Stdout = (@{
                id = 123
                tag_name = '2.4.8-pg18-w1'
                draft = $false
                prerelease = $false
            } | ConvertTo-Json -Compress); Stderr = '' }
        }
        '404' { return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 404: Not Found' } }
        '403' { return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 403: Forbidden' } }
        '429' { return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: HTTP 429: Too Many Requests' } }
        'transport' { return @{ ExitCode = 1; Stdout = ''; Stderr = 'gh: failed to connect to api.github.com: timeout' } }
    }
}
$script:GhApiRunner = 'Invoke-FakeReleaseGhApi'

Test-Case 'GitHub release lookup accepts a published JSON response' {
    $script:ApiMode = 'ok'
    $release = Get-GitHubReleaseByTag -Repository 'o/r' -Tag '2.4.8-pg18-w1'
    Assert-Equal 123 $release.id
    Assert-Equal '2.4.8-pg18-w1' $release.tag_name
}

Test-Case 'GitHub release lookup treats only HTTP 404 as absent' {
    $script:ApiMode = '404'
    Assert-True ($null -eq (Get-GitHubReleaseByTag -Repository 'o/r' -Tag 'missing'))
}

Test-Case 'GitHub release lookup fails closed for 403, 429, and transport errors' {
    foreach ($mode in @('403', '429', 'transport')) {
        $script:ApiMode = $mode
        Assert-Throws { Get-GitHubReleaseByTag -Repository 'o/r' -Tag 'x' | Out-Null } -MessagePattern 'failed'
    }
}

Test-Case 'Release assets require exactly one package ZIP and one checksum file' {
    $assets = @(
        [pscustomobject]@{ name = 'pglogical-2.4.8-pg18-w1-x64.zip'; browser_download_url = 'https://example.invalid/package.zip' },
        [pscustomobject]@{ name = 'SHA256SUMS.txt'; browser_download_url = 'https://example.invalid/SHA256SUMS.txt' }
    )
    $selected = Get-ReleasePackageAssets -Assets $assets
    Assert-Equal 'pglogical-2.4.8-pg18-w1-x64.zip' $selected.Package.name
    Assert-Equal 'SHA256SUMS.txt' $selected.Checksums.name
    Assert-Throws {
        Get-ReleasePackageAssets -Assets @($assets[0]) | Out-Null
    } -MessagePattern 'checksum'
    Assert-Throws {
        Get-ReleasePackageAssets -Assets @($assets + $assets[0]) | Out-Null
    } -MessagePattern 'exactly one package'
}

Test-Case 'Checksum parser accepts a matching line and rejects mismatch or ambiguity' {
    $name = 'pglogical-2.4.8-pg18-w1-x64.zip'
    $hash = ('a' * 64)
    Assert-Equal $hash (Get-ChecksumForAsset -ChecksumsText "$hash  $name`n" -AssetName $name)
    Assert-Throws { Get-ChecksumForAsset -ChecksumsText "$hash  $name" -AssetName $name -ActualSha256 ('b' * 64) } -MessagePattern 'checksum mismatch'
    Assert-Throws { Get-ChecksumForAsset -ChecksumsText "$hash  $name`n$hash  $name`n" -AssetName $name } -MessagePattern 'exactly one'
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pgl-package-" + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixtureRoot 'source'
$expanded = Join-Path $fixtureRoot 'expanded'
New-Item -ItemType Directory -Force -Path $source | Out-Null
try {
    foreach ($relative in @('lib/pglogical.dll', 'lib/pglogical_output.dll', 'share/extension/pglogical.control', 'share/extension/pglogical_origin.control', 'share/extension/pglogical_origin--1.0.0.sql', 'share/extension/pglogical--2.4.8.sql', 'bin/pglogical_create_subscriber.exe')) {
        $path = Join-Path $source ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -Path $path -Value 'fixture' -Encoding ascii
    }
    $info = [ordered]@{
        pglogicalVersion = '2.4.8'
        upstreamRepository = '2ndQuadrant/pglogical'
        upstreamTag = 'REL2_4_8'
        upstreamCommitSha = ('a' * 40)
        postgresqlCompatibilityMajor = '18'
        postgresqlBuildVersion = '18.4'
        edbPackagingRevision = 2
        edbArtifactFilename = 'postgresql-18.4-2-windows-x64-binaries.zip'
        edbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.4-2-windows-x64-binaries.zip'
        edbArtifactCalculatedSha256 = ('b' * 64)
        windowsPackagingRevision = 1
        architecture = 'x64'
        configuration = 'Release'
    }
    $info | ConvertTo-Json | Set-Content -Path (Join-Path $source 'BUILD-INFO.json') -Encoding utf8
    $zipPath = Join-Path $fixtureRoot 'package.zip'
    Compress-Archive -Path (Join-Path $source '*') -DestinationPath $zipPath

    Test-Case 'Synthetic ZIP expands and exposes the parsed staging/provenance' {
        $archive = Expand-ReleasePackageArchive -ZipPath $zipPath -OutputDir $expanded
        Assert-Equal $expanded $archive.StagingDir
        Assert-Equal '2.4.8' $archive.BuildInfo.pglogicalVersion
        Assert-True (Test-ReleasePackageProvenance -Info $archive.BuildInfo -ReleaseTag '2.4.8-pg18-w1' -PostgresqlMajor '18' -PackageAssetName 'pglogical-2.4.8-pg18-w1-x64.zip')
    }

    Test-Case 'Provenance rejects a wrong PostgreSQL major and malformed BUILD-INFO' {
        $archive = Expand-ReleasePackageArchive -ZipPath $zipPath -OutputDir (Join-Path $fixtureRoot 'expanded-2')
        Assert-Throws { Test-ReleasePackageProvenance -Info $archive.BuildInfo -ReleaseTag '2.4.8-pg18-w1' -PostgresqlMajor '17' -PackageAssetName 'pglogical-2.4.8-pg18-w1-x64.zip' } -MessagePattern 'major'
        $broken = [pscustomobject]@{ pglogicalVersion = '2.4.8' }
        Assert-Throws { Test-ReleasePackageProvenance -Info $broken -ReleaseTag '2.4.8-pg18-w1' -PostgresqlMajor '18' -PackageAssetName 'package.zip' } -MessagePattern 'missing'
    }

    Test-Case 'Archive extraction rejects path traversal' {
        Assert-False (Test-SafeReleaseArchiveEntryPath -EntryName '../evil.txt')
        Assert-False (Test-SafeReleaseArchiveEntryPath -EntryName 'C:/evil.txt')
        Assert-True (Test-SafeReleaseArchiveEntryPath -EntryName 'lib/pglogical.dll')
    }
}
finally {
    Remove-Item -Recurse -Force $fixtureRoot -ErrorAction SilentlyContinue
}

$script:GhApiRunner = $null
Complete-Tests
