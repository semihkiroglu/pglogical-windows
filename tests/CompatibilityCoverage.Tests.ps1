<#
.SYNOPSIS
    Unit tests for persisted compatibility-smoke coverage state.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

Test-Case 'Passed smoke results are persisted once and remain deduplicated' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("compatibility-coverage-" + [guid]::NewGuid().ToString('N'))
    $coverageFile = Join-Path $root 'compatibility-coverage.json'
    $resultsDirectory = Join-Path $root 'results'
    $outputFile = Join-Path $root 'update-result.json'
    $additionalFile = Join-Path $root 'branch-coverage.json'
    $resultFile = Join-Path $resultsDirectory 'compat-result-pg18.json'
    try {
        $null = New-Item -ItemType Directory -Force -Path $resultsDirectory
        [ordered]@{ schemaVersion = 1; entries = @() } |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $coverageFile -Encoding utf8
        [ordered]@{
            resultType = 'smoke-result'
            status = 'passed'
            postgresqlMajor = '18'
            serverMinor = '6'
            serverBuildVersion = '18.6'
            serverEdbArtifactFilename = 'postgresql-18.6-2-windows-x64-binaries.zip'
            serverEdbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.6-2-windows-x64-binaries.zip'
            localReleaseTag = '2.4.8-pg18-w1'
            localPackageAssetName = 'pglogical-2.4.8-pg18-w1-x64.zip'
            localPackageBuildArtifactFilename = 'postgresql-18.5-1-windows-x64-binaries.zip'
            packageProvenance = [ordered]@{
                pglogicalVersion = '2.4.8'
                upstreamTag = 'REL2_4_8'
                upstreamCommitSha = '9a0e182745885ad0152ea387988c95a483396a81'
            }
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultFile -Encoding utf8

        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\Update-CompatibilityCoverage.ps1') `
            -CoverageFile $coverageFile -ResultsDirectory $resultsDirectory -OutputFile $outputFile
        if ($LASTEXITCODE -ne 0) { throw "Coverage update failed with exit code $LASTEXITCODE." }

        $state = Get-Content -LiteralPath $coverageFile -Raw | ConvertFrom-Json
        Assert-Equal 1 @($state.entries).Count
        Assert-Equal 'postgresql-18.6-2-windows-x64-binaries.zip' $state.entries[0].serverEdbArtifactFilename

        [ordered]@{
            schemaVersion = 1
            entries = @([ordered]@{
                postgresqlMajor = '17'
                localReleaseTag = '2.4.8-pg17-w1'
                localPackageAssetName = 'pglogical-2.4.8-pg17-w1-x64.zip'
                localPackageBuildArtifactFilename = 'postgresql-17.10-1-windows-x64-binaries.zip'
                serverEdbArtifactFilename = 'postgresql-17.11-3-windows-x64-binaries.zip'
                serverEdbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-17.11-3-windows-x64-binaries.zip'
                status = 'passed'
            })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $additionalFile -Encoding utf8
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\Update-CompatibilityCoverage.ps1') `
            -CoverageFile $coverageFile -ResultsDirectory $resultsDirectory -OutputFile $outputFile -AdditionalCoverageFiles $additionalFile
        if ($LASTEXITCODE -ne 0) { throw "Additional coverage merge failed with exit code $LASTEXITCODE." }
        $state = Get-Content -LiteralPath $coverageFile -Raw | ConvertFrom-Json
        Assert-Equal 2 @($state.entries).Count

        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\Update-CompatibilityCoverage.ps1') `
            -CoverageFile $coverageFile -ResultsDirectory $resultsDirectory -OutputFile $outputFile
        if ($LASTEXITCODE -ne 0) { throw "Repeated coverage update failed with exit code $LASTEXITCODE." }

        $state = Get-Content -LiteralPath $coverageFile -Raw | ConvertFrom-Json
        Assert-Equal 2 @($state.entries).Count
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Complete-Tests
