# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


function Import-GBuildModule {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true, Position=0)] [string[]]$Names,
        [string]$ModuleRoot = $PSScriptRoot,
        [switch]$Force,
        [switch]$Required,
        [switch]$SkipIfLoaded
    )

Set-StrictMode -Version 1.0
    $allFound = $true
    foreach ($name in $Names) {
        if ($SkipIfLoaded) {
            $existing = Get-Module -Name $name -ErrorAction SilentlyContinue
            if ($existing) { continue }
        }
        $path = Join-Path $ModuleRoot "$name.psm1"
        if (-not (Test-Path $path -PathType Leaf)) {
            if ($Required) { throw (Resolve-LogMessage -Key 'log.buildimport.line27' -MessageArgs @([string]$path) -Fallback "Required module not found: $path") }
            $allFound = $false
            continue
        }
        $ea = if ($Required) { 'Stop' } else { 'SilentlyContinue' }
        if ($Force) {
            $null = Import-Module $path -Force -Global -DisableNameChecking -ErrorAction $ea
        } else {
            $null = Import-Module $path -Global -DisableNameChecking -ErrorAction $ea
        }
    }
    return $allFound
}

# ========================================================================
# Import-BuildModule — centralized, self-loading module bootstrap.
# Single reusable entry point every module uses to load its dependencies.
# It guarantees BuildImport (and thus Logging) are available before loading
# the requested dependency modules, so a module can drop the duplicated
# 2-line `$buildImportPath` preamble and just call Import-BuildModule.
# Safe for both the gbuild bootstrap flow and standalone Import-Module.
# ========================================================================
function Import-BuildModule {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Dependencies = @(),
        [switch]$Force
    )
    # Self-load BuildImport if not yet available (standalone / direct import).
    if (-not (Get-Command Import-BuildDependencies -ErrorAction SilentlyContinue)) {
        $buildImportPath = Join-Path $PSScriptRoot 'BuildImport.psm1'
        if (Test-Path $buildImportPath) {
            $null = Import-Module $buildImportPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    # Propagate the dependency result: returning $true unconditionally masked a
    # missing/failed dependency import from callers that check the return value.
    $depsOk = $true
    if (Get-Command Import-BuildDependencies -ErrorAction SilentlyContinue) {
        Import-BuildDependencies -Modules $Dependencies -Force:$Force
    } else {
        $depsOk = $false
    }
    return $depsOk
}

function Import-BuildDependencies {
    [CmdletBinding()]
    param(
        [string[]]$Modules = @(),
        [switch]$Force
    )
    $loggingPath = Join-Path $PSScriptRoot 'Logging.psm1'
    if (Test-Path $loggingPath) {
        # -Global so Write-Log etc. resolve from any module's scope. Without it the
        # import lands only in BuildImport's session state and caller modules (e.g.
        # Siem, Versioning) hit CommandNotFound on Write-Log when Logging was not
        # pre-loaded globally by the test harness / gbuild bootstrap.
        # Only import when Logging is absent: it is pre-loaded globally by the
        # gbuild bootstrap / Orchestrator Tier-1, and a re-import here while it is
        # already (or is being) loaded would exceed the PS 5.1 module nesting limit
        # and orphan the global Logging module.
        if (-not (Get-Module -Name 'Logging')) {
            $null = Import-Module $loggingPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    # ConfigProvider is a core cross-cutting config helper (Get-ConfigValue) used by
    # ~12 modules and many tests. Load it globally alongside Logging so any harness /
    # standalone import that goes through this bootstrap can resolve it (avoids
    # "Get-ConfigValue is not recognized" in isolated module imports / tests).
    $configPath = Join-Path $PSScriptRoot 'ConfigProvider.psm1'
    if (Test-Path $configPath) {
        if (-not (Get-Module -Name 'ConfigProvider')) {
            $null = Import-Module $configPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if ($Modules -and $Modules.Count -gt 0) {
        $null = Import-GBuildModule -Names $Modules -Force:$Force
    }
}

Export-ModuleMember -Function @('Import-GBuildModule', 'Import-BuildDependencies', 'Import-BuildModule')
