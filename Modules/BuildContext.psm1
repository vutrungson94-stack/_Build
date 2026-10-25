# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# BuildContext.psm1 — Core build-context value object (OOP adoption, Phase B1a)
# A well-typed, PS 5.1-safe class capturing the cross-cutting build state that
# was previously an ad-hoc PSCustomObject ($global:GState). Existing modules
# continue to use $global:GState (backward compatible); this class is the
# recommended entry point for new code and is registered in the DI container.


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# Module-local: coerce any colors shape into the [hashtable] the BuildContext
# class requires. Accepts hashtable/IDictionary (copied), PSCustomObject or a
# JSON-deserialized colors node (projected); anything else falls back to the
# built-in palette. Colors must never abort construction — historically a
# PSCustomObject seed threw 'Exception setting "Colors"... Cannot convert to
# Hashtable' and killed the build. 5.1-safe: statements only. Not exported.
function ConvertTo-ColorsHashtable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($Colors)

Set-StrictMode -Version 1.0
    $defaults = @{ Header = 'Magenta'; Info = 'Cyan'; Warn = 'Yellow'; Err = 'Red'; Succ = 'Green'; Gray = 'DarkGray'; White = 'White' }
    if ($null -eq $Colors) { return $defaults }
    if ($Colors -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Colors.Keys) { $h[[string]$k] = $Colors[$k] }
        if ($h.Count -gt 0) { return $h }
        return $defaults
    }
    if ($Colors -is [PSCustomObject]) {
        $h = @{}
        foreach ($p in $Colors.PSObject.Properties) { $h[$p.Name] = $p.Value }
        if ($h.Count -gt 0) { return $h }
        return $defaults
    }
    return $defaults
}

class BuildContext {
    [datetime] $StartTime
    [string]    $ScriptRoot
    [string]    $ProjectRoot
    [string]    $ExplicitProject
    [string]    $WorkingDir
    [string]    $ConfigPath
    [string]    $ModulePath
    [string]    $SDKCache
    [PSCustomObject] $BuildConfig
    [System.Collections.ArrayList] $ErrorLog
    [int]       $WarningCount
    [string]    $FailureReason
    [hashtable] $Colors
    [string]    $OS
    [string]    $DotnetCmd
    [string]    $JavaSdk
    [string]    $AndroidSdk
    [string]    $ActiveProfile
    [string]    $CurrentTfm
    [string]    $TenantId
    [string]    $CorrelationId
    [bool]      $IsCI
    [bool]      $NonInteractive
    [string]    $BuildStrategy
    [string]    $CacheFile
    [string]    $AlertingToken
    [datetime]  $AlertingTokenCreatedAt

    BuildContext() {
        $this.ErrorLog = [System.Collections.ArrayList]::new()
        $bcColors = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'Colors' } else { $null }
        # Same coercion as the seed path below: the config-first constant is
        # a hashtable today, but must stay safe if it ever arrives as
        # PSCustomObject (config node, deserialized state).
        $this.Colors = ConvertTo-ColorsHashtable -Colors $bcColors
        $this.StartTime = [datetime]::UtcNow
    }

    [void] LogError([string]$Message, [string]$Category) {
        $entry = [PSCustomObject]@{
            Time     = [datetime]::UtcNow.ToString('o')
            Message  = $Message
            Category = $Category
        }
        [void]$this.ErrorLog.Add($entry)
    }

    [void] AddTempFile([string]$Path) {
        if ($null -eq $this.PSObject.Properties['TempFiles']) {
            $this | Add-Member -MemberType NoteProperty -Name 'TempFiles' -Value ([System.Collections.ArrayList]::new())
        }
        [void]$this.TempFiles.Add($Path)
    }

    [string] ResolvePath([string]$Relative) {
        if ([string]::IsNullOrWhiteSpace($Relative)) { return $this.ProjectRoot }
        if ([System.IO.Path]::IsPathRooted($Relative)) { return $Relative }
        return Join-Path $this.ProjectRoot $Relative
    }
}

<#
.SYNOPSIS
    Creates a BuildContext, optionally seeded from an existing state object.
.DESCRIPTION
    Factory that seeds a BuildContext from the existing PSCustomObject state
    ($global:GState). Only known properties are copied; unknown ad-hoc members
    remain on the source state. This is the recommended entry point for new code
    and is registered in the DI container as the 'BuildContext' service.
.PARAMETER Seed
    Optional PSCustomObject (e.g. $global:GState) whose known properties are copied.
#>
function New-BuildContext {
    [CmdletBinding()]
    param([PSCustomObject]$Seed)

    $ctx = [BuildContext]::new()
    if ($null -eq $Seed) { return $ctx }

    $map = @{
        StartTime     = 'StartTime'
        ScriptRoot    = 'ScriptRoot'
        ProjectRoot   = 'ProjectRoot'
        ExplicitProject = 'ExplicitProject'
        WorkingDir    = 'WorkingDir'
        ConfigPath    = 'ConfigPath'
        ModulePath    = 'ModulePath'
        SDKCache      = 'SDKCache'
        BuildConfig   = 'BuildConfig'
        WarningCount  = 'WarningCount'
        FailureReason = 'FailureReason'
        OS            = 'OS'
        DotnetCmd     = 'DotnetCmd'
        JavaSdk       = 'JavaSdk'
        AndroidSdk    = 'AndroidSdk'
        ActiveProfile = 'ActiveProfile'
        CurrentTfm    = 'CurrentTfm'
        TenantId      = 'TenantId'
        CorrelationId = 'CorrelationId'
        IsCI          = 'IsCI'
        NonInteractive = 'NonInteractive'
        BuildStrategy  = 'BuildStrategy'
        CacheFile      = 'CacheFile'
        AlertingToken  = 'AlertingToken'
        AlertingTokenCreatedAt = 'AlertingTokenCreatedAt'
    }
    foreach ($key in $map.Keys) {
        if ($Seed.PSObject.Properties.Name -contains $key) {
            $ctx.$($map[$key]) = $Seed.$key
        }
    }
    if ($Seed.PSObject.Properties.Name -contains 'Colors' -and $Seed.Colors) {
        # Single-sourced coercion (see ConvertTo-ColorsHashtable): the
        # PSCustomObject stamped by Logging.Set-StateColors used to throw
        # 'Exception setting "Colors"...' on the second Start-GBuild in one
        # session via the Orchestrator.Resolve-BuildSdk re-seed.
        $ctx.Colors = ConvertTo-ColorsHashtable -Colors $Seed.Colors
    }
    return $ctx
}

Export-ModuleMember -Function @('New-BuildContext')
