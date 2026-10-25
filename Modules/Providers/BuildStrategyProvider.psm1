# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Build strategy provider — Factory + Strategy pattern.
# Choose build strategy (Release/Debug/Incremental/Full) based on parameters.
# Properties declared directly — no 'using module' needed (PS 5.1 parse-time safe).


# Canonical default-configuration resolution. BuildConstants' DefaultConfiguration
# (overridable through build.defaultConfiguration) is the single source of truth;
# 'Release' is only the fallback used when BuildConstants is not loaded, which
# keeps the historical behaviour of this provider unchanged.
# Module-private: reachable from the strategy classes below because a class
# defined in a module can call functions in that module's session state.
function Resolve-DefaultConfiguration {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State = $null)

Set-StrictMode -Version 1.0
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [string](Get-BuildConstant -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } catch { return 'Release' }
    }
    return 'Release'
}

class ReleaseBuildStrategy {
    [string] $Name
    [bool]   $Incremental
    # Carries the caller's explicitly requested configuration (set by
    # Get-BuildStrategy). Empty means "use the configured default".
    [string] $Configuration

    # Name is the strategy identity (asserted by consumers/tests), NOT a
    # configuration default; only the resolved Configuration is config-driven.
    ReleaseBuildStrategy() { $this.Name = 'Release'; $this.Incremental = $false; $this.Configuration = '' }

    [hashtable] ResolveOptions([PSCustomObject]$State) {
        $cfg = if ([string]::IsNullOrWhiteSpace($this.Configuration)) { Resolve-DefaultConfiguration -State $State } else { $this.Configuration }
        return @{ Configuration = $cfg; Incremental = $false; Clean = $false }
    }
}

class DebugBuildStrategy {
    [string] $Name
    [bool]   $Incremental

    # -DebugBuild is an explicit request for the Debug configuration, so this
    # strategy is identity-bound to 'Debug' and never consults the default.
    DebugBuildStrategy() { $this.Name = 'Debug'; $this.Incremental = $false }

    [hashtable] ResolveOptions([PSCustomObject]$State) {
        return @{ Configuration = 'Debug'; Incremental = $false; Clean = $false }
    }
}

class IncrementalBuildStrategy {
    [string] $Name
    [bool]   $Incremental
    [string] $Configuration

    IncrementalBuildStrategy() { $this.Name = 'Incremental'; $this.Incremental = $true; $this.Configuration = '' }

    [hashtable] ResolveOptions([PSCustomObject]$State) {
        $cfg = if ([string]::IsNullOrWhiteSpace($this.Configuration)) { Resolve-DefaultConfiguration -State $State } else { $this.Configuration }
        return @{ Configuration = $cfg; Incremental = $true; Clean = $false }
    }
}

class FullBuildStrategy {
    [string] $Name
    [bool]   $Incremental
    [string] $Configuration

    FullBuildStrategy() { $this.Name = 'Full'; $this.Incremental = $false; $this.Configuration = '' }

    [hashtable] ResolveOptions([PSCustomObject]$State) {
        $cfg = if ([string]::IsNullOrWhiteSpace($this.Configuration)) { Resolve-DefaultConfiguration -State $State } else { $this.Configuration }
        return @{ Configuration = $cfg; Incremental = $false; Clean = $true }
    }
}

function Get-BuildStrategy {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch]$DebugBuild,
        [switch]$Incremental,
        [switch]$Clean,
        [string]$Configuration = ''
    )
    # An unset configuration resolves through the canonical constant, so this
    # factory never silently pins a build to 'Release' when the project (or
    # profile) says otherwise. An explicit -Configuration always wins.
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-DefaultConfiguration }
    if ($Clean)       { $strategy = [FullBuildStrategy]::new() }
    elseif ($Incremental) { $strategy = [IncrementalBuildStrategy]::new() }
    elseif ($DebugBuild)  { return [DebugBuildStrategy]::new() }
    elseif ($Configuration -eq 'Debug') { return [DebugBuildStrategy]::new() }
    else { $strategy = [ReleaseBuildStrategy]::new() }
    $strategy.Configuration = $Configuration
    return $strategy
}

Export-ModuleMember -Function @('Get-BuildStrategy')
