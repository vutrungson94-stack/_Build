#Requires -Version 5.1
Set-StrictMode -Version 1.0

<#
.SYNOPSIS
    Builds a full integration-test State object from the real gbuild.config.json.
.DESCRIPTION
    Loads the actual _Build/gbuild.config.json and its schema path into a State
    object mirroring what Start-GBuild produces at runtime. Used by integration
    tests that exercise config-driven behaviour across modules.
.PARAMETER BuildRoot
    Root of the _Build module tree (defaults to the parent of the Tests dir).
.PARAMETER ConfigPath
    Path to gbuild.config.json (defaults to _Build/gbuild.config.json).
#>
function New-FullTestState {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '../../gbuild.config.json')
    )
    $cfg = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue
        if ($raw) { $cfg = $raw | ConvertFrom-Json }
    }
    $state = [PSCustomObject]@{
        ScriptRoot    = (Split-Path -Parent $ConfigPath)
        ProjectRoot   = (Split-Path -Parent (Split-Path -Parent $ConfigPath))
        ConfigPath    = $ConfigPath
        BuildConfig   = $cfg
        CorrelationId = [guid]::NewGuid().ToString('N')
    }
    return $state
}

<#
.SYNOPSIS
    Creates a uniquely-named temporary directory for integration tests.
#>
function New-IntegrationTempDir {
    [CmdletBinding()]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_it_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

<#
.SYNOPSIS
    Returns $true only when real external infrastructure (network/S3/SSH/OTLP) is
    opted in via the test runner's -RealInfra flag ($env:GBUILD_REAL_INFRA = '1').
.DESCRIPTION
    Tests that contact real services MUST gate themselves with:
        It "..." -Skip:(-not (Test-RealInfraEnabled)) { ... }
    Default (no -RealInfra) is mock-only, so CI never depends on live infrastructure.
#>
function Test-RealInfraEnabled {
    return ($env:GBUILD_REAL_INFRA -eq '1')
}

Export-ModuleMember -Function @('New-FullTestState', 'New-IntegrationTempDir', 'Test-RealInfraEnabled')
