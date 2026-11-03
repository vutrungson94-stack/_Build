Set-StrictMode -Version 1.0
# ============================================================================
# Orchestrator.Standalone.ps1 - standalone helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Invoke-StandaloneOperation {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [switch]$CacheClear,
        [switch]$CacheOptimize,
        [switch]$CacheStats,
        [switch]$VersionBump
    )
    if ($CacheClear) {
        Import-ModuleOnDemand -ModuleNames @('Cache')
        if (Get-Command Clear-BuildCache -ErrorAction SilentlyContinue) {
            Clear-BuildCache -State $State -Force
            if (Get-Command Reset-ReportCache -ErrorAction SilentlyContinue) { Reset-ReportCache }
        } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m50' -MessageArgs @(${lb}, ${rb})) 'Warn' $State }
        return $true
    }
    if ($CacheOptimize) {
        Import-ModuleOnDemand -ModuleNames @('Cache')
        if (Get-Command Optimize-Cache -ErrorAction SilentlyContinue) { Optimize-Cache -State $State } else { Write-Log "${lb}WARN${rb} $(Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Cache') -Fallback 'Cache module not loaded')" 'Warn' $State }
        return $true
    }
    if ($CacheStats) {
        Import-ModuleOnDemand -ModuleNames @('Cache')
        if (Get-Command Show-CacheStats -ErrorAction SilentlyContinue) { Show-CacheStats -State $State } else { Write-Log "${lb}WARN${rb} $(Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Cache') -Fallback 'Cache module not loaded')" 'Warn' $State }
        return $true
    }
    if ($VersionBump) {
        Import-ModuleOnDemand -ModuleNames @('Versioning')
        if (Get-Command Invoke-VersionBump -ErrorAction SilentlyContinue) { Invoke-VersionBump -State $State } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m53' -MessageArgs @(${lb}, ${rb})) 'Warn' $State }
        return $true
    }
    return $false
}

<#
.SYNOPSIS
    Validates config + resolves active profile, applying profile overrides onto State.
#>

