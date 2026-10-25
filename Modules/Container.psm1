# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Container.psm1 — Lightweight dependency-injection / service-locator
# Minimal, PS 5.1-safe DI container. Services are registered with a factory
# scriptblock and optionally cached as singletons. The registry is stored in
# process-global state so services registered in one module (e.g. Orchestrator)
# are resolvable from any other module that imports this container — enabling
# incremental, module-by-module migration away from $global:GState.
#
# PRODUCTION WIRING (not test-only — DO NOT DELETE):
#   Orchestrator.Register-BuildServices (:982) registers 4 singletons:
#     BuildContext, MetricRegistry, EventBus, ErrorHandling
#   Production consumers:
#     Logging.Get-BuildState        -> Resolve-Service 'BuildContext' (fallback GState)
#     Orchestrator.Initialize-BuildLogging (:1048) -> Resolve-Service 'MetricRegistry'
#       (DI fallback when telemetry.prometheus is missing from config)
#     Orchestrator.Resolve-BuildSdk (:1200) -> Set-ServiceInstance 'BuildContext'
#       (re-seed singleton after DotnetCmd/CurrentTfm changes)
#     Orchestrator.Start-GBuild finally block -> Clear-Services (teardown releases
#       the 4 singletons so a long-lived host never carries stale instances)
#     ErrorHandling.GetServiceAdapter -> Resolve-Service 'ErrorHandling'
#   PUBLIC EXTENSION POINT (intentionally zero internal callers — DO NOT DELETE):
#     Set-ServiceFactory swaps a registered factory at runtime (e.g. swapping
#     logger backends, mock <-> real in tests). It is the supported
#     reconfiguration API for hosts embedding gbuild; covered by
#     Container.Tests.ps1 ('Set-ServiceFactory ...'). An export with only
#     external/test callers is a contract, not an orphan.
#


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()


if (-not (Test-Path Variable:global:GBuildServices)) {
    $global:GBuildServices = @{}
}

<#
.SYNOPSIS
    Registers a service in the DI container.
.DESCRIPTION
    Stores a factory scriptblock under the given name. When -Singleton is set,
    the produced instance is cached and reused on subsequent resolves.
.PARAMETER Name
    Unique service name (e.g. 'BuildContext', 'MetricRegistry').
.PARAMETER Factory
    Scriptblock that creates the service instance.
.PARAMETER Singleton
    Cache the produced instance for the process lifetime.
#>
function Register-Service {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Factory,

        [switch]$Singleton
    )

Set-StrictMode -Version 1.0

    $global:GBuildServices[$Name] = @{
        Factory   = $Factory
        Singleton = [bool]$Singleton
        Instance  = $null
    }
}

<#
.SYNOPSIS
    Resolves a registered service from the DI container.
.DESCRIPTION
    Returns the cached singleton instance (if applicable) or creates a new one
    by invoking the registered factory. Factory errors are caught and re-thrown
    with diagnostic context so a broken factory does not produce an opaque
    unhandled exception.
.PARAMETER Name
    The service name to resolve.
.PARAMETER Argument
    Optional argument passed to the factory scriptblock.
#>
function Resolve-Service {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$Argument = $null
    )

    if (-not $global:GBuildServices.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.container.line98' -Fallback "Service '$Name' is not registered."))
    }

    $svc = $global:GBuildServices[$Name]
    if ($svc.Singleton -and $null -ne $svc.Instance) {
        return $svc.Instance
    }

    try {
        $instance = if ($null -eq $Argument) { & $svc.Factory } else { & $svc.Factory $Argument }
    }
    catch {
        $msg = "Failed to create service '$Name': $($_.Exception.Message)"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "[DI] $msg" 'Err' $null
        }
        throw [System.InvalidOperationException]::new($msg, $_.Exception)
    }
    if ($svc.Singleton) { $svc.Instance = $instance }
    return $instance
}

<#
.SYNOPSIS
    Tests whether a service is registered.
.PARAMETER Name
    The service name to check.
#>
function Test-ServiceRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Name)
    return $global:GBuildServices.ContainsKey($Name)
}

<#
.SYNOPSIS
    Re-seeds the cached instance of a registered (singleton) service.
.DESCRIPTION
    Replaces the cached singleton instance WITHOUT re-running the factory.
    The primary production use is Orchestrator.Resolve-BuildSdk, which re-seeds
    the DI 'BuildContext' singleton after late State mutations (DotnetCmd /
    CurrentTfm) so consumers never observe a stale snapshot.
.PARAMETER Name
    The registered service name.
.PARAMETER Instance
    The new instance to cache.
#>
function Set-ServiceInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [object]$Instance
    )
    if (-not $global:GBuildServices.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.container.line152' -Fallback "Service '$Name' is not registered."))
    }
    $global:GBuildServices[$Name].Instance = $Instance
}

<#
.SYNOPSIS
    Replaces the factory (and singleton flag) of a registered service.
.DESCRIPTION
    Swaps the factory scriptblock and singleton setting for an already-registered
    service without affecting the current singleton instance (which is reset to
    $null). Useful for runtime reconfiguration (e.g. swapping logger backends,
    swapping mock ↔ real implementations during testing).
.PARAMETER Name
    The registered service name.
.PARAMETER Factory
    New factory scriptblock.
.PARAMETER Singleton
    Cache produced instance (default: not cached).
#>
function Set-ServiceFactory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [scriptblock]$Factory,
        [switch]$Singleton
    )
    if (-not $global:GBuildServices.ContainsKey($Name)) {
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.container.line180' -Fallback "Service '$Name' is not registered."))
    }
    $global:GBuildServices[$Name].Factory   = $Factory
    $global:GBuildServices[$Name].Singleton = [bool]$Singleton
    $global:GBuildServices[$Name].Instance  = $null
}

function Clear-Services {
    $global:GBuildServices.Clear()
}

# NOTE: Get-BuildState is defined in Logging.psm1 (the foundational module imported by all
# others) so it is available to every consumer. It resolves the DI 'BuildContext' singleton
# when registered, otherwise falls back to $global:GState. Keep this module free of a
# duplicate definition to avoid re-import name conflicts.

Export-ModuleMember -Function @('Register-Service', 'Resolve-Service', 'Test-ServiceRegistered', 'Set-ServiceInstance', 'Set-ServiceFactory', 'Clear-Services')




