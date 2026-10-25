# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ============================================================================
# IContract.psm1  (Phase B4 - Interface contracts / runtime contract validation)
# ============================================================================
# Provides PS 5.1-safe duck-typing contract validation for the OOP core
# classes (BuildContext, MetricRegistry, BuildEventBus, BuildCache) and for
# plugin modules. PS 7+ could additionally declare `interface` types; here we
# validate structural conformance (required methods + properties) so the same
# checks run identically on PS 5.1.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# --- Helper: detect member presence on any object --------------------------
function Test-MemberPresent {
    [CmdletBinding()]
    param(
        $Object,
        [string]$Name,
        [string]$Kind # 'Method' | 'Property'
    )

Set-StrictMode -Version 1.0
    if ($Kind -eq 'Method') {
        if ($null -ne $Object.PSObject.Methods[$Name]) { return $true }
        try { return ($null -ne $Object.GetType().GetMethod($Name)) } catch { return $false }
    }
    if ($null -ne $Object.PSObject.Properties[$Name]) { return $true }
    try { return ($null -ne $Object.GetType().GetProperty($Name)) } catch { return $false }
}

<#
.SYNOPSIS
    Validates that an object exposes a set of required methods and properties.
.DESCRIPTION
    Structural (duck-typing) contract check. Returns an ArrayList of result
    objects with Contract/Member/Kind/Present/Conforms fields so callers can
    report exactly which members are missing.
#>
function Test-ContractConformance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Object,
        [string[]]$RequiredMethods = @(),
        [string[]]$RequiredProperties = @(),
        [string]$ContractName = 'Anonymous'
    )

    $results = [System.Collections.ArrayList]@()

    foreach ($m in $RequiredMethods) {
        $present = Test-MemberPresent -Object $Object -Name $m -Kind 'Method'
        $results.Add([PSCustomObject]@{
                Contract = $ContractName
                Member   = $m
                Kind     = 'Method'
                Present  = $present
                Conforms = $present
            }) | Out-Null
    }

    foreach ($p in $RequiredProperties) {
        $present = Test-MemberPresent -Object $Object -Name $p -Kind 'Property'
        $results.Add([PSCustomObject]@{
                Contract = $ContractName
                Member   = $p
                Kind     = 'Property'
                Present  = $present
                Conforms = $present
            }) | Out-Null
    }

    return $results
}

<#
.SYNOPSIS
    Validates the four OOP core contracts at runtime.
.DESCRIPTION
    Imports the OOP modules on demand (if not already loaded) and verifies that
    BuildContext, MetricRegistry, BuildEventBus and BuildCache instances expose
    the members declared by their contract. Returns a result object with
    All/Failed/Passed. Throws when -ThrowOnFailure and any member is missing.
#>
function Test-InterfaceContracts {
    [CmdletBinding()]
    param(
        [switch]$ThrowOnFailure
    )

    $modDir = $PSScriptRoot
    foreach ($m in @('BuildContext', 'Metrics', 'EventBus', 'Cache')) {
        $p = Join-Path $modDir "$m.psm1"
        if (Test-Path $p -PathType Leaf) {
            # -Global: reference/refresh the global module copy instead of creating a
            # nested duplicate - a nested -Force import orphans the global module in PS 5.1.
            Import-Module $p -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }

    $all = [System.Collections.ArrayList]@()

    # BuildContext
    $bc = New-BuildContext -Seed ([PSCustomObject]@{})
    $all.AddRange((Test-ContractConformance $bc `
            -RequiredMethods @('LogError', 'AddTempFile', 'ResolvePath') `
            -RequiredProperties @('CorrelationId', 'TenantId', 'ProjectRoot', 'ScriptRoot') `
            -ContractName 'BuildContext'))

    # MetricRegistry
    $mr = Get-MetricRegistry
    $all.AddRange((Test-ContractConformance $mr `
            -RequiredMethods @('Register', 'ToPrometheus', 'FormatLabels') `
            -RequiredProperties @('Metrics') `
            -ContractName 'MetricRegistry'))

    # BuildEventBus
    $bus = Get-BuildEventBus
    $all.AddRange((Test-ContractConformance $bus `
            -RequiredMethods @('Subscribe', 'Unsubscribe', 'Publish', 'GetErrors', 'GetSubscriberCounts', 'Clear') `
            -RequiredProperties @('Subscribers') `
            -ContractName 'BuildEventBus'))

    # BuildCache
    $cache = Get-BuildCache
    $all.AddRange((Test-ContractConformance $cache `
            -RequiredMethods @('Initialize', 'GetEntry', 'SaveEntry', 'IsValid', 'GetStatistics', 'ClearCache') `
            -RequiredProperties @('CacheRoot', 'Stats') `
            -ContractName 'BuildCache'))

    # @() wrap: Where-Object unrolls a SINGLE failure to a scalar PSCustomObject,
    # whose .Count is $null under StrictMode (fragile truthiness below).
    $failed = @($all | Where-Object { -not $_.Conforms })
    if ($ThrowOnFailure -and $failed.Count -gt 0) {
        $names = ($failed | ForEach-Object { "$($_.Contract).$($_.Member)" }) -join ', '
        throw (Resolve-LogMessage -Key 'log.icontract.line141' -MessageArgs @([string]$names) -Fallback "Contract validation failed for: $names")
    }

    return [PSCustomObject]@{
        All     = $all
        Failed  = $failed
        Passed  = ($failed.Count -eq 0)
        Summary = "$(($all | Where-Object { $_.Conforms }).Count)/$($all.Count) members conform"
    }
}


<#
.SYNOPSIS
    Single-source plugin contract (P2 DRY).
.DESCRIPTION
    The 5-function plugin contract was hardcoded in 3 places
    (Loader.Test-PluginInterface, IContract.Test-PluginContracts, PluginSDK).
    This function is now the single source; other modules must call it.
#>
function Get-PluginContractFunctions {
    [CmdletBinding()] param()
    return @('Get-PluginInfo', 'Invoke-PluginBuild', 'Invoke-PluginTest', 'Invoke-PluginLint', 'Invoke-PluginPreflight')
}

function Test-PluginContracts {
    [CmdletBinding()]
    param([string[]]$PluginPaths = @(), [switch]$ThrowOnFailure)
    if ($PluginPaths.Count -eq 0) { $directory = Join-Path $PSScriptRoot 'Plugins'; if (Test-Path -LiteralPath $directory) { $PluginPaths = @(Get-ChildItem -LiteralPath $directory -Filter '*.psm1' -File | Select-Object -ExpandProperty FullName) } }
    if (-not (Get-Command Get-PluginManifest -ErrorAction SilentlyContinue)) { $sdkPath = Join-Path $PSScriptRoot 'PluginSDK.psm1'; if (Test-Path -LiteralPath $sdkPath) { Import-Module $sdkPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue } }
    $required = @(Get-PluginContractFunctions)
    $all = [System.Collections.Generic.List[object]]::new()
    $manifests = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $PluginPaths) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
        $manifest = $null
        if (Get-Command Get-PluginManifest -ErrorAction SilentlyContinue) { try { $manifest = Get-PluginManifest -PluginPath $path } catch { } }
        if ($manifest) {
            [void]$manifests.Add($manifest)
            if (Get-Command Test-PluginManifest -ErrorAction SilentlyContinue) { $check = Test-PluginManifest -Manifest $manifest; if (-not $check.Valid) { [void]$all.Add([PSCustomObject]@{ Contract = $base; Member = 'Manifest'; Kind = 'Manifest'; Present = $true; Conforms = $false }) } }
            if (Get-Command Test-PluginCompatibility -ErrorAction SilentlyContinue) { $compatibility = Test-PluginCompatibility -Manifest $manifest; if (-not $compatibility.Compatible) { [void]$all.Add([PSCustomObject]@{ Contract = $base; Member = 'Compatibility'; Kind = 'Compatibility'; Present = $true; Conforms = $false }) } }
        }
        $module = Import-Module $path -PassThru -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not $module) { foreach ($function in $required) { [void]$all.Add([PSCustomObject]@{ Contract = $base; Member = $function; Kind = 'Function'; Present = $false; Conforms = $false }) }; continue }
        $found = @(Get-Command -Module $module.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if ($found -notcontains 'Get-PluginInfo') { continue }
        foreach ($function in $required) { $present = $found -contains $function; [void]$all.Add([PSCustomObject]@{ Contract = $base; Member = $function; Kind = 'Function'; Present = $present; Conforms = $present }) }
    }
    if ($manifests.Count -gt 0 -and (Get-Command Resolve-PluginDependencies -ErrorAction SilentlyContinue)) {
        $dependencies = Resolve-PluginDependencies -Manifests @($manifests)
        if (-not $dependencies.Valid) { [void]$all.Add([PSCustomObject]@{ Contract = 'PluginSet'; Member = 'Dependencies'; Kind = 'Dependency'; Present = $true; Conforms = $false }) }
    }
    $failed = @($all | Where-Object { -not $_.Conforms })
    if ($ThrowOnFailure -and $failed.Count -gt 0) { throw (Resolve-LogMessage -Key 'log.icontract.line194' -Fallback 'Plugin contract validation failed for: ' + (($failed | ForEach-Object { $_.Contract + '/' + $_.Member }) -join ', ')) }
    return [PSCustomObject]@{ All = @($all); Failed = $failed; Passed = ($failed.Count -eq 0); Summary = "$( @($all | Where-Object { $_.Conforms }).Count)/$($all.Count) plugin contracts conform" }
}

Export-ModuleMember -Function @('Test-ContractConformance', 'Test-InterfaceContracts', 'Test-PluginContracts', 'Get-PluginContractFunctions')
