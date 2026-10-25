# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# BuildImport defines Import-GBuildModule and Import-BuildDependencies

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ==================================================================================================
# Modules/SDK.psm1 - SDK discovery engine
# ==================================================================================================

# ==== Import dependency modules ====
# Nested imports WITHOUT -Force: reference globally loaded modules when present
# (gbuild bootstrap / Import-GBuildModule) - a nested -Force re-import orphans the
# global module in PS 5.1 (same as the Logging rule).
$sdkEnvPath = Join-Path $PSScriptRoot 'Environment.psm1'
if (Test-Path $sdkEnvPath) { Import-Module $sdkEnvPath -DisableNameChecking -ErrorAction SilentlyContinue }
Import-BuildModule -Dependencies @()
$envProviderPath = Join-Path (Join-Path $PSScriptRoot 'Providers') 'EnvironmentProvider.psm1'
if (Test-Path $envProviderPath) { Import-Module $envProviderPath -DisableNameChecking -ErrorAction SilentlyContinue }
Import-GBuildModule -Names @('Environment') -Force
# BuildConstants provides the default table for timeouts/scan depths + SDK paths
# (single source). Guard so a standalone import does not depend on module load order.
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildDefault'

# OS detection via centralized Get-OSPlatform (Environment.psm1, Tier-1 import)
$script:IsWindows = (Get-OSPlatform) -eq 'Windows'
$script:IsMacOS   = (Get-OSPlatform) -eq 'MacOS'
$script:IsLinux   = (Get-OSPlatform) -eq 'Linux'

# ==================================================================================
# SDK CONFIGURATION
# ==================================================================================
enum SdkType
{
    Dotnet
    JDK
    Android
}

class SdkConfig
{
    # NOT dead code: PowerShell class field initializers cannot call functions
    # (Get-BuildDefault/Get-ConfigValue), so these literals are MANDATORY FALLBACKS
    # for standalone imports where BuildConstants is not yet loaded
    # loads fully, the Get-BuildDefault block right after [SdkConfig]::new() overwrites
    # them from the BuildConstants table (single source), then config
    hidden [int]$CacheExpiryDays = 90
    hidden [int]$ExeTimeoutMs = 5000
    hidden [int]$DefaultSearchDepth = 4
    hidden [int]$ProjectScanDepth = 3
    hidden [int]$ParentScanDepth = 2
    hidden [int]$WinSearchDepthDelta = 3
    hidden [string[]]$BlacklistDirs = @('node_modules', 'bin', 'obj', '.git')
    hidden [SdkType[]]$ValidToolTypes = @([SdkType]::Dotnet, [SdkType]::JDK, [SdkType]::Android)
    # NOTE: no getter methods on purpose — all 17 use-sites read these fields
    # directly ($script:SdkConfig.X); a wrapper would add indirection with no value.
}

$script:SdkConfig = [SdkConfig]::new()
# OS-specific blacklist dirs are applied after instantiation (class initializers can't use if/else).
# Single source: BuildConstants.SdkBlacklist{Base,Windows,Mac} - literal is fallback only.
if ($script:IsWindows) {
    $script:SdkConfig.BlacklistDirs = @(Get-BuildDefault -Key 'SdkBlacklistWindows' -Fallback @('node_modules', 'bin', 'obj', '.git', '.vs', 'AppData', 'Program Files (x86)', 'Windows'))
} elseif ($script:IsMacOS) {
    $script:SdkConfig.BlacklistDirs = @(Get-BuildDefault -Key 'SdkBlacklistMac' -Fallback @('node_modules', 'bin', 'obj', '.git', '.DS_Store'))
} else {
    $script:SdkConfig.BlacklistDirs = @(Get-BuildDefault -Key 'SdkBlacklistBase' -Fallback @('node_modules', 'bin', 'obj', '.git'))
}
$script:BinExt = if ($script:IsWindows) { '.exe' } else { '' }

# Apply class defaults from the BuildConstants table (single source of truth - no hardcoding).
# Priority: config sdk.* (GetSdkOverride below) > BuildConstants > class placeholder.
# The class field initializers (lines 54-59) are mandatory PowerShell class fallbacks
# for standalone imports where BuildConstants is not yet loaded. This block is the
# single source of truth for fallback values when BuildConstants IS available.
function Get-SdkConfigDefaults {
    [OutputType([hashtable])]
    param()

Set-StrictMode -Version 1.0
    $get = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { ${function:Get-BuildDefault} } else { $null }
    return @{
        CacheExpiryDays      = if ($get) { [int](& $get -Key 'SdkCacheExpiryDays' -Fallback 90) } else { 90 }
        ExeTimeoutMs         = if ($get) { [int](& $get -Key 'ExeTimeoutMs' -Fallback 5000) } else { 5000 }
        DefaultSearchDepth   = if ($get) { [int](& $get -Key 'SdkDefaultSearchDepth' -Fallback 4) } else { 4 }
        ProjectScanDepth     = if ($get) { [int](& $get -Key 'SdkProjectScanDepth' -Fallback 3) } else { 3 }
        ParentScanDepth      = if ($get) { [int](& $get -Key 'SdkParentScanDepth' -Fallback 2) } else { 2 }
        WinSearchDepthDelta  = if ($get) { [int](& $get -Key 'SdkWinSearchDepthDelta' -Fallback 3) } else { 3 }
    }
}

if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
    $defaults = Get-SdkConfigDefaults
    $script:SdkConfig.CacheExpiryDays      = $defaults.CacheExpiryDays
    $script:SdkConfig.ExeTimeoutMs         = $defaults.ExeTimeoutMs
    $script:SdkConfig.DefaultSearchDepth   = $defaults.DefaultSearchDepth
    $script:SdkConfig.ProjectScanDepth     = $defaults.ProjectScanDepth
    $script:SdkConfig.ParentScanDepth      = $defaults.ParentScanDepth
    $script:SdkConfig.WinSearchDepthDelta  = $defaults.WinSearchDepthDelta
}

<#
    .SYNOPSIS
        Reads an SDK configuration value, falling back to the SdkConfig class default.
    .DESCRIPTION
        SDK discovery settings are declared in gbuild.config.json (sdk.* section) and
        mirrored in the SdkConfig class. This helper resolves the effective value:
        config override wins, otherwise the class default is returned. Keeps the schema
        and code in sync (closes the schema-code disconnect).
    .PARAMETER PropertyName
        The SDK config property name (e.g. 'cacheExpiryDays', 'exeTimeoutMs').
    .PARAMETER State
        Build state carrying BuildConfig (optional; falls back to global state).
    #>
function Get-SdkConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PropertyName,
        [PSCustomObject]$State
    )
    $effectiveState = $State
    if (-not $effectiveState -and (Get-Command Get-BuildState -ErrorAction SilentlyContinue)) { $effectiveState = Get-BuildState }
    $constantKeys = @{
        cacheExpiryDays = 'SdkCacheExpiryDays'
        exeTimeoutMs = 'ExeTimeoutMs'
        defaultSearchDepth = 'SdkDefaultSearchDepth'
        projectScanDepth = 'SdkProjectScanDepth'
        parentScanDepth = 'SdkParentScanDepth'
        winSearchDepthDelta = 'SdkWinSearchDepthDelta'
    }
    if ($constantKeys.ContainsKey($PropertyName) -and (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue)) {
        $value = Get-BuildConstant -Key $constantKeys[$PropertyName] -State $effectiveState -Fallback $null
        if ($null -ne $value) { return $value }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        $fromCfg = Get-ConfigValue -Path "sdk.$PropertyName" -State $effectiveState -Default $null
        if ($null -ne $fromCfg) { return $fromCfg }
    }
    if ($script:SdkConfig.PSObject.Properties.Name -contains $PropertyName) {
        return $script:SdkConfig.$PropertyName
    }
    return $null
}

# Android SDK Path Components (single source: BuildConstants.AndroidCmdLineToolsRelPath,
# overridable via gbuild.config.json sdk.androidCmdLineToolsRelPath).
$script:AndroidCmdLineToolsBinDir = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
    [string](Get-BuildDefault -Key 'AndroidCmdLineToolsRelPath' -Fallback 'cmdline-tools/latest/bin')
} else { 'cmdline-tools/latest/bin' }

function Update-AndroidSdkConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $configured = Get-SdkConfigValue -PropertyName 'androidCmdLineToolsRelPath' -State $State
    if ($configured) {
        $script:AndroidCmdLineToolsBinDir = [string]$configured
        if ($script:SDK_Config -and $script:SDK_Config['Android']) {
            $script:SDK_Config['Android'].Bin = $script:AndroidCmdLineToolsBinDir
        }
        Write-Log (Resolve-LogMessage -Key 'log.sdk.androidToolsFromConfig' -MessageArgs @([string]$script:AndroidCmdLineToolsBinDir) -Fallback '[CONFIG] Android CmdLineTools path updated from config: {0}') "Debug" $State
    }
}

# ==================================================================================
# SDK CONFIGURATION TABLE
# ==================================================================================
# Pre-compute outside the hashtable literal: a self-reference like
# ExeRelativePath = $script:SDK_Config.'Android'.Exe inside the literal evaluates
# BEFORE the key exists -> empty string -> later Mandatory binding crashes.
$androidSdkManagerName = if ($script:IsWindows) { 'sdkmanager.bat' } else { 'sdkmanager' }

$script:SDK_Config = @{
    'Dotnet' = @{
        Exe               = "dotnet$script:BinExt"
        Bin               = '.'
        Label             = '.NET SDK'
        GetHome           = { param($p) Split-Path $p -Parent }
        SetEnv            = {
            param($h)
            $sep = [System.IO.Path]::PathSeparator
            if ($env:PATH -notlike "*$h*")
            { $env:PATH = "$h$sep$env:PATH"
            }
            $env:DOTNET_ROOT = $h
            $env:DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR = $h
        }
        EnvHome           = { if ($env:DOTNET_ROOT)
            { $env:DOTNET_ROOT
            } else
            { $null
            } }
        DirectoryPatterns = @('*dotnet*', '*sdk*')
        ExeRelativePath   = "dotnet$script:BinExt"
    }
    'JDK' = @{
        Exe               = "javac$script:BinExt"
        Bin               = 'bin'
        Label             = 'Java JDK'
        GetHome           = { param($p) Split-Path (Split-Path $p -Parent) -Parent }
        SetEnv            = { param($h) $env:JAVA_HOME = $h }
        EnvHome           = { if ($env:JAVA_HOME) { $env:JAVA_HOME } else { $null } }
        DirectoryPatterns = @('*jdk*', '*jre*', '*java*', '*openjdk*', '*zulu*', '*graalvm*')
        # Level 5 single-source: JdkJavacRelativeWin/Unix (BuildConstants).
        # Class-literal context cannot call functions, so resolve once here via
        # Get-BuildDefault with OS-aware fallback preserving legacy behavior.
        ExeRelativePath   = $(if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
                if ($script:IsWindows) { [string](Get-BuildDefault -Key 'JdkJavacRelativeWin' -Fallback 'bin/javac.exe') }
                else { [string](Get-BuildDefault -Key 'JdkJavacRelativeUnix' -Fallback 'bin/javac') }
            } else { "bin/javac$script:BinExt" })
    }
    'Android' = @{
        Exe               = $androidSdkManagerName
        Bin               = $script:AndroidCmdLineToolsBinDir
        Label             = 'Android SDK'
        GetHome           = {
            param($p)
            try
            {
                $parent = [System.IO.Directory]::GetParent($p)
                if ($parent -and $parent.Parent -and $parent.Parent.Parent)
                {
                    return $parent.Parent.Parent.Parent.FullName
                }
                # Fallback: traverse up to find Android SDK root
                $current = $p
                for ($i = 0; $i -lt 5; $i++)
                {
                    $candidate = Split-Path $current -Parent
                    if (-not $candidate -or $candidate -eq $current)
                    { break
                    }
                    $ptDir = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildDefault -Key 'SdkPlatformToolsDirName' -Fallback 'platform-tools') } else { 'platform-tools' }
                    $btDir = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildDefault -Key 'SdkBuildToolsDirName' -Fallback 'build-tools') } else { 'build-tools' }
                    if ((Test-Path (Join-Path $candidate $ptDir)) -or
                        (Test-Path (Join-Path $candidate $btDir)))
                    {
                        return $candidate
                    }
                    $current = $candidate
                }
                return $null
            }
            catch
            {
                Write-Warning (Resolve-LogMessage -Key 'log.sdk.androidHomeFailed' -MessageArgs @([string]$_) -Fallback 'Failed to determine Android SDK home: {0}')
                return $null
            }
        }
        SetEnv            = {
            param($h)
            try
            {
                if (-not $env:ANDROID_HOME)
                { $env:ANDROID_HOME = $h
                }
                if (-not $env:ANDROID_SDK_ROOT)
                { $env:ANDROID_SDK_ROOT = $h
                }
            }
            catch
            {
                Write-Warning (Resolve-LogMessage -Key 'log.sdk.androidEnvSetFailed' -MessageArgs @([string]$_) -Fallback 'Failed to set Android SDK environment variables: {0}')
            }
        }

        EnvHome           = {
            try
            {
                if ($env:ANDROID_HOME)
                {
                    return $env:ANDROID_HOME
                }
                if ($env:ANDROID_SDK_ROOT)
                {
                    return $env:ANDROID_SDK_ROOT
                }
                return $null
            }
            catch
            {
                Write-Warning (Resolve-LogMessage -Key 'log.sdk.androidEnvReadFailed' -MessageArgs @([string]$_) -Fallback 'Failed to read Android SDK environment variables: {0}')
                return $null
            }
        }
        DirectoryPatterns   = @('*android*', '*sdk*')
        ExeRelativePath   = $androidSdkManagerName
    }
}

# Separate PriorityPaths as scriptblocks that will be set dynamically
$script:GetDotnetPriorityPaths = {
    param([PSCustomObject]$State)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(Get-CommonSdkPaths -State $State)) { $paths.Add($p) }
    if ($script:IsWindows -and $env:ProgramFiles) {
        $dotnetSub = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkDotnetWindowsSub' -State $State -Fallback 'dotnet') } else { 'dotnet' }
        $paths.Add((Join-Path $env:ProgramFiles $dotnetSub))
    }
    elseif ($script:IsMacOS) {
        $paths.Add((Get-BuildConstant -Key 'SdkDotnetMac' -State $State -Fallback '/usr/local/share/dotnet'))
    }
    elseif ($script:IsLinux) {
        $paths.Add((Get-BuildConstant -Key 'SdkDotnetLinux' -State $State -Fallback '/usr/share/dotnet'))
        $homeDir = if ($env:HOME) { $env:HOME } else { (Get-BuildConstant -Key 'SdkRootHomeFallback' -State $State -Fallback '/root') }
        $dotnetDir = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkDotnetDirName' -State $State -Fallback '.dotnet') } else { '.dotnet' }
        $paths.Add((Join-Path $homeDir $dotnetDir))
    }
    $paths.ToArray()
}

$script:GetJdkPriorityPaths = {
    param([PSCustomObject]$State)
    if ($script:IsWindows) {
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @(Get-CommonSdkPaths -State $State)) { $paths.Add($p) }
        $pf = $env:ProgramFiles
        # The 32-bit program-files directory is exposed as
        # 'ProgramFiles(x86)'. PowerShell needs the ${env:...} brace form for a
        # name containing parentheses; the plain `$env:ProgramFilesx86` spelling
        # used here always resolved to $null, so this branch never ran and a JDK
        # installed under C:\Program Files (x86)\Java - the default Oracle/Zulu
        # 32-bit layout - was never discovered. Verified against Windows
        # PowerShell 5.1: $env:ProgramFilesx86 = '', ${env:ProgramFiles(x86)} =
        # 'C:\Program Files (x86)'.
        $pf86 = ${env:ProgramFiles(x86)}
        $local = $env:LOCALAPPDATA
        $javaLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkJavaDirName' -State $State -Fallback 'Java') } else { 'Java' }
        $androidLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidDirName' -State $State -Fallback 'Android') } else { 'Android' }
        $studioLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidStudioDirName' -State $State -Fallback 'Android Studio') } else { 'Android Studio' }
        $jbrLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkJbrDirName' -State $State -Fallback 'jbr') } else { 'jbr' }
        if ($pf) {
            $paths.Add((Join-Path $pf $javaLeaf))
            # Android Studio JBR path - check config first, then env var, then default location
            $androidStudioPath = $null
            if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk -and $State.BuildConfig.sdk.androidStudioPath) {
                $androidStudioPath = $State.BuildConfig.sdk.androidStudioPath
            }
            if ([string]::IsNullOrEmpty($androidStudioPath)) { $androidStudioPath = $env:ANDROID_STUDIO_PATH }
            if (-not [string]::IsNullOrEmpty($androidStudioPath) -and (Test-Path $androidStudioPath)) {
                $jbrPath = Join-Path $androidStudioPath $jbrLeaf
                if (Test-Path $jbrPath) {
                    $paths.Add($jbrPath)
                }
            } else {
                # Fallback to default location but only if it exists
                $defaultJbrPath = Join-Path (Join-Path (Join-Path $pf $androidLeaf) $studioLeaf) $jbrLeaf
                if (Test-Path $defaultJbrPath -ErrorAction SilentlyContinue) {
                    $paths.Add($defaultJbrPath)
                }
            }
        }
        if ($pf86) {
            $paths.Add((Join-Path $pf86 $javaLeaf))
        }
        if ($local) {
            # Check configurable path first
            $androidStudioPath = $null
            if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk -and $State.BuildConfig.sdk.androidStudioPath) {
                $androidStudioPath = $State.BuildConfig.sdk.androidStudioPath
            }
            if ([string]::IsNullOrEmpty($androidStudioPath)) { $androidStudioPath = $env:ANDROID_STUDIO_PATH }
            if (-not [string]::IsNullOrEmpty($androidStudioPath) -and (Test-Path $androidStudioPath)) {
                $jbrPath = Join-Path $androidStudioPath $jbrLeaf
                if (Test-Path $jbrPath -ErrorAction SilentlyContinue) {
                    $paths.Add($jbrPath)
                }
            }
        }
        $paths.ToArray()
    } elseif ($script:IsMacOS) {
        $paths = [System.Collections.Generic.List[string]]::new()
        $paths.Add((Get-BuildConstant -Key 'SdkJvmMac' -State $State -Fallback '/Library/Java/JavaVirtualMachines'))
        if ($env:HOME) {
            $jvmSubDir = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkJvmMacSubDir' -State $State -Fallback 'Library/Java/JavaVirtualMachines') } else { 'Library/Java/JavaVirtualMachines' }
            $paths.Add((Join-Path $env:HOME $jvmSubDir))
        }
        $paths.ToArray()
    } else {
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @(Get-BuildConstant -Key 'SdkJvmUnix' -State $State -Fallback @('/usr/lib/jvm', '/usr/local/lib/jvm'))) { $paths.Add($p) }
        $paths.ToArray()
    }
}

# Real function, not a scriptblock variable: it is exported (line 2032) and
# AndroidSdkProvider probes for it BY NAME with Get-Command before delegating.
# As `$script:GetAndroidPriorityPaths = {...}` it was a variable, so that
# command lookup always failed and the provider silently used its inline
# fallback instead of the shared list. Same body, now a real function.
function GetAndroidPriorityPaths {
    param([PSCustomObject]$State)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(Get-CommonSdkPaths -State $State)) { $paths.Add($p) }
    $androidLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidDirName' -State $State -Fallback 'Android') } else { 'Android' }
    $sdkLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidSdkDirName' -State $State -Fallback 'Sdk') } else { 'Sdk' }
    $sdkLegacyLeaf = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidSdkLegacyDirName' -State $State -Fallback 'android-sdk') } else { 'android-sdk' }
    $macHomeSub = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidHomeMacSub' -State $State -Fallback 'Library/Android/sdk') } else { 'Library/Android/sdk' }
    $linuxHomeSub = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkAndroidHomeLinuxSub' -State $State -Fallback 'Android/Sdk') } else { 'Android/Sdk' }
    # Windows leaf sub-paths. These were re-derived inline below while
    # SdkAndroidWindowsLocalSub / SdkAndroidWindowsProgramSub sat declared,
    # config-mapped and read by nothing. Single source now.
    $winLocalSub = (Join-Path $androidLeaf $sdkLeaf)
    $winProgramSub = (Join-Path $androidLeaf $sdkLegacyLeaf)
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $winLocalSub = [string](Get-BuildConstant -Key 'SdkAndroidWindowsLocalSub' -State $State -Fallback $winLocalSub) } catch { }
        try { $winProgramSub = [string](Get-BuildConstant -Key 'SdkAndroidWindowsProgramSub' -State $State -Fallback $winProgramSub) } catch { }
    }
    if ($script:IsWindows) {
        if ($env:LOCALAPPDATA) {
            $paths.Add((Join-Path $env:LOCALAPPDATA $winLocalSub))
        }
        if ($env:ProgramFiles) {
            $paths.Add((Join-Path $env:ProgramFiles $winProgramSub))
        }
    } elseif ($script:IsMacOS) {
        if ($env:HOME) {
            $paths.Add((Join-Path $env:HOME $macHomeSub))
        }
    } else {
        if ($env:HOME) {
            $paths.Add((Join-Path $env:HOME $linuxHomeSub))
        }
        $paths.Add((Get-BuildConstant -Key 'SdkAndroidLinux' -State $State -Fallback '/opt/android-sdk'))
    }
    $paths.ToArray()
}

# Assign closures to config hashtable
$script:SDK_Config.Dotnet.PriorityPaths = $script:GetDotnetPriorityPaths
$script:SDK_Config.JDK.PriorityPaths = $script:GetJdkPriorityPaths
$script:SDK_Config.Android.PriorityPaths = ${function:GetAndroidPriorityPaths}

# ==================================================================================
# HELPER FUNCTIONS
# ==================================================================================
function Get-CommonSdkPaths {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [PSCustomObject]$State
    )
    $paths = [System.Collections.Generic.List[string]]::new()

    $sdkState = if (Get-Command Get-BuildState -ErrorAction SilentlyContinue) { Get-BuildState -State $State } else { $State }
    $cfgSearch = if ($sdkState -and $sdkState.BuildConfig -and $sdkState.BuildConfig.sdk) { $sdkState.BuildConfig.sdk.searchPaths } else { $null }
    if ($cfgSearch) {
        foreach ($listName in @('primary', 'fallback')) {
            $list = if ($cfgSearch -is [System.Collections.IDictionary]) { $cfgSearch[$listName] } else { $cfgSearch.$listName }
            foreach ($p in @($list)) {
                $resolved = $p
                if (Get-Command Resolve-ConfigEnvironmentValue -ErrorAction SilentlyContinue) { $resolved = Resolve-ConfigEnvironmentValue -Value $p -State $sdkState }
                if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) { $paths.Add([string]$resolved) }
            }
        }
    }
    $customPaths = if ($sdkState -and $sdkState.BuildConfig -and $sdkState.BuildConfig.sdk) { $sdkState.BuildConfig.sdk.customPaths } else { $null }
    foreach ($p in @($customPaths)) {
        $resolved = $p
        if (Get-Command Resolve-ConfigEnvironmentValue -ErrorAction SilentlyContinue) { $resolved = Resolve-ConfigEnvironmentValue -Value $p -State $sdkState }
        if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) { $paths.Add([string]$resolved) }
    }

    # Fallback: project-local .sdk directories (Level 5 single-source via
    # SdkGbuildDotSdk — never hardcode ".sdk" literal).
    $gbuildDotSdk = '.sdk'
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        try { $gbuildDotSdk = [string](Get-BuildConstant -Key 'SdkGbuildDotSdk' -State $sdkState -Fallback '.sdk') } catch { $gbuildDotSdk = '.sdk' }
    }
    if ($sdkState -and $sdkState.ScriptRoot) {
        $paths.Add((Join-Path $sdkState.ScriptRoot $gbuildDotSdk))
        $paths.Add((Join-Path (Split-Path $sdkState.ScriptRoot -Parent) $gbuildDotSdk))
    }
    $paths.Add((Join-Path (Get-Location).Path $gbuildDotSdk))
    return $paths.ToArray()
}

function Test-ExeWithTimeout
{
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$ExePath,
        [string]$Arguments,
        [int]$TimeoutMilliseconds = 0,
        [PSCustomObject]$State = $null
    )
    if ($TimeoutMilliseconds -le 0) { $TimeoutMilliseconds = [int](Get-SdkConfigValue -PropertyName 'exeTimeoutMs' -State $State) }
    if ($TimeoutMilliseconds -le 0) { $TimeoutMilliseconds = 5000 }
    try
    {
        # Batch files (.bat/.cmd) MUST NOT go through Start-Process here:
        # on PowerShell 7 + hidden-window ShellExecute it can hang forever.
        # Route them through cmd.exe via raw .NET Process instead.
        # Windows-only: .bat/.cmd + ComSpec exist solely on Windows. On Unix
        # there is no cmd.exe, so fail closed instead of throwing.
        if ($ExePath -match '\.(bat|cmd)$')
        {
            if (-not $script:IsWindows) { return $false }
            if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { return $false }
            $psi = New-BuildProcessStartInfo -FilePath $ExePath -Arguments $Arguments -AllowBatch
            if ($null -eq $psi) { return $false }
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
        }
        else
        {
            $startArgs = @{
                FilePath = $ExePath
                ArgumentList = $Arguments
                PassThru = $true
                ErrorAction = 'Stop'
            }
            if ($script:IsWindows)
            { $startArgs['WindowStyle'] = 'Hidden'
            } else
            { $startArgs['NoNewWindow'] = $true
            }
            $proc = Start-Process @startArgs
        }
        if ($proc.WaitForExit($TimeoutMilliseconds))
        {
            return ($null -ne $proc.ExitCode -and $proc.ExitCode -eq 0)
        }
        if (-not $proc.HasExited)
        { $proc.Kill()
        }
        return $false
    } catch
    { return $false
    }
}

function Get-SdkExePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$SdkRoot,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    if (-not $cfg)
    { return $null
    }
    return Join-Path (Join-Path $SdkRoot $cfg.Bin) $cfg.Exe
}

function Test-IsGhostSdk {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ExePath, [PSCustomObject]$State = $null)
    # Ghost stub: file exists but --list-sdks returns exit 0 with empty output
    # or --version fails. Used as explicit pre-check for SystemPath/PriorityPaths.
    if (-not (Test-Path $ExePath)) { return $true }
    try {
        $out = & $ExePath '--list-sdks' 2>&1
        if ($LASTEXITCODE -eq 0 -and $null -ne $out -and @($out).Count -gt 0) { return $false }
        # Non-dotnet ghost falls back to version probe (timeout single-sourced from
        # SdkConfig.ExeTimeoutMs — no separate literal for the ghost probe).
        $timeout = [int](Get-SdkConfigValue -PropertyName 'exeTimeoutMs' -State $State)
        if ($timeout -le 0) { $timeout = 5000 }
        return -not (Test-ExeWithTimeout -ExePath $ExePath -Arguments '--version' -TimeoutMilliseconds $timeout -State $State)
    } catch { return $true }
}

function Test-SdkExe
{
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$ExePath,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType,
        [PSCustomObject]$State = $null
    )
    if (-not (Test-Path $ExePath))
    { return $false
    }
    if (Test-IsGhostSdk -ExePath $ExePath -State $State) {
        # A diagnostic must never be able to change the return value. This call
        # previously invoked Get-LocaleMessage unguarded, so in any context where
        # Locale.psm1 is not loaded the ghost-rejection path THREW instead of
        # returning $false - turning "this muxer is unusable" into a hard error.
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            $msg = if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.sdk.ghost' -MessageArgs @($ExePath) } else { "SDK-capable check failed, ignoring: $ExePath" }
            Write-Log $msg "Warn"
        }
        return $false
    }
    if ($ToolType -eq 'Dotnet')
    {
        try
        {
            $output = & $ExePath '--list-sdks' 2>&1
            return ($LASTEXITCODE -eq 0) -and ($null -ne $output) -and ($output.Count -gt 0)
        } catch
        { return $false
        }
    }
    $versionArg = if ($ToolType -eq 'JDK')
    { '-version'
    } else
    { '--version'
    }
    return Test-ExeWithTimeout -ExePath $ExePath -Arguments $versionArg -State $State
}

function Invoke-SmartScan
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$RootPath,
        [string]$Filter,
        [scriptblock]$ValidateScript,
        [int]$MaxDepth = 0,
        [string]$Label = "",
        [PSCustomObject]$State
    )
    if ($MaxDepth -le 0) { $MaxDepth = [int](Get-SdkConfigValue -PropertyName 'defaultSearchDepth' -State $State) }
    if ($MaxDepth -lt 0) { $MaxDepth = 4 }
    $shouldLog = -not [string]::IsNullOrWhiteSpace($Label)
    $colorName = 'Gray'
    $grayColor = if (Get-Command Resolve-SafeColor -ErrorAction SilentlyContinue)
    {
        Resolve-SafeColor -ColorName $colorName -State $State -Fallback 'DarkGray'
    } else
    { 'DarkGray'
    }
    if ($shouldLog)
    { Write-Log "   $Label ..." -Color $grayColor -Level Debug -State $State
    }
    if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
        $found = Invoke-CompatibleChildItem -Path $RootPath -File -Filter $Filter -Recurse -Depth $MaxDepth -State $State -EA SilentlyContinue |
            Where-Object { & $ValidateScript $_.FullName } | Select-Object -First 1
    } else {
        $found = Get-ChildItem -Path $RootPath -File -Filter $Filter -Recurse -EA SilentlyContinue |
            Where-Object { & $ValidateScript $_.FullName } | Select-Object -First 1
    }
    if ($shouldLog)
    { Write-Log ' ' -Level Info -State $State
    }
    if ($null -ne $found)
    { return $found.FullName
    }
    return $null
}

function Find-SdkByDirectory
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$RootPath,
        [int]$MaxDepth = 0,
        [Parameter(Mandatory)] [string[]]$DirectoryPatterns,
        # Allow empty (not Missing) so a config gap degrades gracefully instead of
        # crashing the pipeline with "Cannot bind argument to parameter 'Exe'".
        [AllowEmptyString()] [string]$Exe,
        [string]$Label = '',
        [scriptblock]$ValidateScript,
        [PSCustomObject]$State
    )
    if ($MaxDepth -le 0) { $MaxDepth = [int](Get-SdkConfigValue -PropertyName 'defaultSearchDepth' -State $State) }
    if ($MaxDepth -lt 0) { $MaxDepth = 4 }
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.noExe') "Warn" -State $(if ($State) { $State } else { $null })
        return $null
    }
    try
    {
        $logState = if ($State) { $State } else { $null }
        Write-Log (Resolve-LogMessage -Key 'log.sdk.scanningFor' -MessageArgs @([string]$Exe, $Label) -Fallback 'Scanning for {0} in directories matching patterns...{1}') "Debug" -State $logState
        $rootExe = Join-Path $RootPath $Exe
        if (Test-Path -Path $rootExe) {
            if (-not $ValidateScript -or (& $ValidateScript $rootExe)) {
                Write-Log (Resolve-LogMessage -Key 'log.sdk.foundAt' -MessageArgs @([string]$rootExe) -Fallback 'Found SDK at: {0}') "Debug" -State $logState
                return $RootPath
            }
        }
        $foundDir = $null
        $dirsSeen = @{}
        foreach ($p in $DirectoryPatterns) {
            # Invoke-CompatibleChildItem (Environment.psm1): PS 5.1 has NO -Depth
            # parameter on Get-ChildItem - the raw call threw ParameterBinding
            # and the silent catch degraded every directory scan to $null.
            $dirs = if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
                Invoke-CompatibleChildItem -Path $RootPath -Directory -Recurse -Depth $MaxDepth -Filter $p -State $State -ErrorAction SilentlyContinue
            } else {
                Get-ChildItem -Path $RootPath -Directory -Recurse -Depth $MaxDepth -Filter $p -ErrorAction SilentlyContinue
            }
            foreach ($dir in $dirs) {
                if ($dirsSeen.ContainsKey($dir.FullName)) { continue }
                $dirsSeen[$dir.FullName] = $true
                $exePath = Join-Path $dir.FullName $Exe
                if (Test-Path -Path $exePath) {
                    if (-not $ValidateScript -or (& $ValidateScript $exePath)) {
                        $foundDir = $dir
                        break
                    }
                }
            }
            if ($foundDir) { break }
        }

        if (-not $foundDir) {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.noMatchingDirs' -Fallback 'No matching directories found') "Debug" -State $logState
            return $null
        }

        $targetDir = $foundDir.FullName
        $exePath = Join-Path $targetDir $Exe
        Write-Log (Resolve-LogMessage -Key 'log.sdk.foundAt' -MessageArgs @([string]$exePath) -Fallback 'Found SDK at: {0}') "Debug" -State $logState
        return $targetDir
    } catch
    {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.scanError' -MessageArgs @($_)) "Err" -State $logState
        return $null
    }
}

# ==================================================================================
# CACHE FUNCTIONS
# ==================================================================================
function Get-SdkCacheFile
{
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $configuredRel = if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { Get-ConfigValue -Path 'sdk.cacheUserRelativePath' -State $State -Default $null } else { $null }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ($configuredRel) {
        if ([System.IO.Path]::IsPathRooted([string]$configuredRel)) { return [string]$configuredRel }
        if ($userProfile) { return Join-Path $userProfile ([string]$configuredRel) }
    }
    if ($State -and $State.SDKCache) { return $State.SDKCache }
    if ($userProfile)
    {
        $rel = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkCacheUserRelativePath' -State $State -Fallback '.gbuild/sdkcache.json') } else { '.gbuild/sdkcache.json' }
        return Join-Path $userProfile $rel
    }
    $localName = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SdkCacheLocalFileName' -State $State -Fallback '.sdkcache.json') } else { '.sdkcache.json' }
    if ($State -and $State.ScriptRoot)
    { return Join-Path $State.ScriptRoot $localName
    }
    # Normalize the '..' away: the old Join-Path chain returned a path carrying a
    # literal '..\' segment into Test-Path/Read-JsonSafe and out to callers.
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) $localName))
}

function Get-CachedSdk
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [string]$SdkName
    )
    $cacheFile = Get-SdkCacheFile -State $State
    if (-not (Test-Path $cacheFile))
    { return $null
    }
    try
    {
        $cache = Read-JsonSafe -FilePath $cacheFile
        if (-not $cache) { return $null }
        $validUntil = [datetime]$cache.ValidUntil
        if ((Get-Date) -lt $validUntil -and $cache.OS -eq $State.OS)
        {
            $path = $cache.$SdkName
            if ($path -eq "NOT_FOUND")
            {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue)
                {
                    Write-Log (Resolve-LogMessage -Key 'log.sdk.cacheNotFound' -MessageArgs @([string]$SdkName) -Fallback 'CACHE {0} not found (skipping scan)') "Gray" $State
                }
                return "NOT_FOUND"
            }
            if (-not [string]::IsNullOrEmpty($path) -and (Test-Path -Path $path))
            {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue)
                {
                    Write-Log (Resolve-LogMessage -Key 'log.sdk.usingCache' -MessageArgs @([string]$SdkName, $path) -Fallback 'Using cache for {0}: {1}') "Gray" $State
                }
                return $path
            }
        }
    } catch
    {
    }
    return $null
}

function Set-CachedSdk
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [string]$SdkName,
        [string]$Path
    )
    $cacheFile = Get-SdkCacheFile -State $State
    $cacheDir = Split-Path $cacheFile -Parent
    if ($cacheDir) {
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $cacheDir) }
        elseif (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force -EA SilentlyContinue | Out-Null }
    }
    $cache = if (Test-Path $cacheFile)
    {
        try
        {
            if (Get-Command Read-JsonSafe -ErrorAction SilentlyContinue) { Read-JsonSafe -FilePath $cacheFile }
            else { Get-Content $cacheFile -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop }
        } catch
        { $null
        }
    } else
    { $null
    }
    if ($null -eq $cache)
    {
        $cache = [PSCustomObject]@{
            ValidUntil = (Get-Date).AddDays([int](Get-SdkConfigValue -PropertyName 'cacheExpiryDays' -State $State)).ToString("o")
            OS = $State.OS
        }
    }
    # Corrupt-cache guard: a missing/invalid ValidUntil must not kill the discovery
    # waterfall (the [datetime] cast throws outside any try). Treat as expired so
    # the entry gets refreshed below.
    $validUntil = [datetime]::MinValue
    if ($cache.PSObject.Properties.Name -contains 'ValidUntil' -and $cache.ValidUntil) {
        try { $validUntil = [datetime]$cache.ValidUntil }
        catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.sdk.cacheInvalidValidUntil' -MessageArgs @([string]$cache.ValidUntil) -Fallback '[SDK] cache ValidUntil invalid (''{0}'') - treating entry as expired') 'Debug' $State -Level DEBUG
            }
        }
    }
    $isExpired = ($validUntil -le (Get-Date)) -or ($cache.OS -ne $State.OS)
    if ($isExpired)
    {
        $cache.ValidUntil = (Get-Date).AddDays([int](Get-SdkConfigValue -PropertyName 'cacheExpiryDays' -State $State)).ToString("o")
        $cache.OS = $State.OS
    }
    $cache | Add-Member -MemberType NoteProperty -Name $SdkName -Value $Path -Force
    # Purge legacy corrupted keys from old bug where SdkName was written as
    # "-S-d-k-N-a-m-e.ToLower()" (interpolated ToLower call). Self-heals without manual delete.
    foreach ($prop in @($cache.PSObject.Properties.Name)) {
        if ($prop -match '^-S-d-k' -or $prop -match 'ToLower') {
            $cache.PSObject.Properties.Remove($prop)
        }
    }
try
{ $null = Write-BuildJsonFile -Path $cacheFile -Data $cache -Depth 5
} catch {
}
}

# ==================================================================================
# SHARED VALIDATE+REGISTER HELPER (replaces per-function duplication)
# ==================================================================================
<#
.SYNOPSIS
    Validates an SDK executable, registers it (cache + env), and returns the result path.
.DESCRIPTION
    Common tail logic shared by all 6 Find-Sdk* functions. Eliminates the
    duplicated: Test-SdkExe ? GetHome ? GetSafePath ? Write-Log ? SetCachedSdk ? SetEnv ? return.
.PARAMETER ExePath
    Full path to the candidate SDK executable (e.g. C:\...\dotnet.exe).
.PARAMETER ToolType
    Dotnet | JDK | Android.
.PARAMETER State
    Build state object.
.PARAMETER LogLabel
    Human-readable label for the log line (e.g. "from env", "in PATH").
.OUTPUTS
    string: Full exe path for Dotnet, safe home path for JDK/Android, or $null on failure.
#>
function Register-SdkCandidate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ExePath,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [string]$LogLabel = ''
    )
    $cfg = $script:SDK_Config[$ToolType]
    if (-not $cfg) { return $null }
    $item = Get-Item -Path $ExePath -EA SilentlyContinue
    if (-not $item) { return $null }
    $resolvedExe = $item.FullName
    Write-Log (Resolve-LogMessage -Key 'log.sdk.validatingCandidate' -MessageArgs @([string]$resolvedExe) -Fallback '[SDK] validating candidate: {0}') 'Debug' $State
    if (-not (Test-SdkExe -ExePath $resolvedExe -ToolType $ToolType -State $State)) {
        Write-Log (Resolve-LogMessage -Key 'log.sdk.candidateFailed' -MessageArgs @([string]$resolvedExe) -Fallback '[SDK] candidate FAILED validation: {0}') 'Debug' $State
        return $null
    }
    Write-Log (Resolve-LogMessage -Key 'log.sdk.candidateOk' -Fallback '[SDK] candidate validated OK') 'Debug' $State
    $hPath = & $cfg.GetHome $resolvedExe
    Write-Log (Resolve-LogMessage -Key 'log.sdk.homeResolved' -MessageArgs @([string]$hPath) -Fallback '[SDK] home resolved: [{0}]') 'Debug' $State
    if (-not $hPath) { return $null }
    $safeHome = if (Get-Command Get-SafePath -ErrorAction SilentlyContinue) { Get-SafePath -Path $hPath } else { $hPath }
    if ($LogLabel -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        $sourceKey = switch ($LogLabel) {
            'from env' { 'log.sdk.source.env' }
            'in PATH' { 'log.sdk.source.path' }
            'at priority path' { 'log.sdk.source.priority' }
            'in project tree' { 'log.sdk.source.projectTree' }
            'in parent directory' { 'log.sdk.source.parentDirectory' }
            'from custom path' { 'log.sdk.source.customPath' }
            default { '' }
        }
        $sourceLabel = if ($sourceKey) { Get-LocaleMessage -Key $sourceKey } else { $LogLabel }
        Write-Log (Get-LocaleMessage -Key 'log.sdk.found' -MessageArgs @($cfg.Label, $sourceLabel, $safeHome)) 'Succ' $State
    }
    $null = Set-CachedSdk -State $State -SdkName $ToolType -Path $hPath
    $null = & $cfg.SetEnv $safeHome
    if ($ToolType -eq 'Dotnet') { return $resolvedExe }
    return $safeHome
}

# ==================================================================================
# SDK DISCOVERY FUNCTIONS
# ==================================================================================
function Find-SdkFromEnvHome
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    $envHome = & $cfg.EnvHome
    Write-Log (Resolve-LogMessage -Key 'log.sdk.envHome' -MessageArgs @([string]$ToolType, $envHome) -Fallback '[SDK] env home for {0}: [{1}]') 'Debug' $State
    if (-not $envHome -or -not (Test-Path -Path $envHome)) { return $null }
    $testExe = Get-SdkExePath -SdkRoot $envHome -ToolType $ToolType
    Write-Log (Resolve-LogMessage -Key 'log.sdk.envCandidate' -MessageArgs @([string]$testExe, $(if (Test-Path -Path $testExe) { 1 } else { 0 })) -Fallback '[SDK] env candidate exe: [{0}] exists={1}') 'Debug' $State
    if (-not $testExe -or -not (Test-Path -Path $testExe)) { return $null }
    return Register-SdkCandidate -ExePath $testExe -ToolType $ToolType -State $State -LogLabel 'from env'
}

function Find-SdkFromSystemPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    # Get-Command can return MULTIPLE Application matches when a stub and a real SDK
    # both sit on PATH; .Source would then be an object[] (binding it to [string]
    # parameters throws). Always take the FIRST Application hit explicitly - the
    # Test-SdkExe ghost-stub validation below is what rejects broken candidates.
    $sysCmd = @(Get-Command $cfg.Exe -CommandType Application -ErrorAction SilentlyContinue)[0]
    if (-not $sysCmd) { return $null }
    $testExe = if ($sysCmd.Source) { $sysCmd.Source } elseif ($sysCmd.Path) { $sysCmd.Path } else { $null }
    if (-not $testExe -or -not (Test-Path -Path $testExe)) { return $null }
    # Ghost-stub check: exe exists but doesn't actually work
    if (-not (Test-SdkExe -ExePath $testExe -ToolType $ToolType -State $State)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Get-LocaleMessage -Key 'log.sdk.fake' -MessageArgs @($cfg.Exe, $testExe)) 'Warn' $State }
        return $null
    }
    return Register-SdkCandidate -ExePath $testExe -ToolType $ToolType -State $State -LogLabel 'in PATH'
}

function Find-SdkFromCache
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    $cachedPath = Get-CachedSdk -State $State -SdkName $ToolType
    if ($cachedPath -eq "NOT_FOUND") {
        $isInteractive = if (Get-Command Test-InteractiveSession -ErrorAction SilentlyContinue) {
            Test-InteractiveSession -State $State
        } else { -not $State.NonInteractive }
        if ($isInteractive) {
            Set-CachedSdk -State $State -SdkName $ToolType -Path ""
            $cachedPath = ""
        } else { return $null }
    }
    if ([string]::IsNullOrWhiteSpace($cachedPath)) { return $null }
    $cachedExePath = Join-Path $cachedPath $cfg.ExeRelativePath
    if (-not (Test-Path -Path $cachedPath) -or -not (Test-Path -Path $cachedExePath -PathType Leaf)) {
        Set-CachedSdk -State $State -SdkName $ToolType -Path ""; return $null
    }
    if (-not (Test-SdkExe -ExePath $cachedExePath -ToolType $ToolType -State $State)) {
        Set-CachedSdk -State $State -SdkName $ToolType -Path ""; return $null
    }
    $null = & $cfg.SetEnv $cachedPath
    if ($ToolType -eq 'Dotnet') { return Join-Path $cachedPath $cfg.Exe }
    return $cachedPath
}

function Find-SdkInPriorityPaths
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    $priorityPaths = & $cfg.PriorityPaths -State $State
    foreach ($path in $priorityPaths) {
        if (-not $path -or -not (Test-Path -Path $path)) { continue }
        # Invoke-CompatibleChildItem: PS 5.1 lacks Get-ChildItem -Depth (raw call
        # threw + silent-catch degraded the scan to $null).
        $candidates = if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
            $exeDepth = [int](Get-BuildConstant -Key 'SdkExeSearchDepth' -Fallback 2)
    @(Invoke-CompatibleChildItem -Path $path -File -Filter $cfg.Exe -Recurse -Depth $exeDepth -State $State -EA SilentlyContinue)
        } else {
            @(Get-ChildItem -Path $path -File -Filter $cfg.Exe -Recurse -Depth ([int](Get-BuildConstant -Key 'SdkExeSearchDepth' -Fallback 2)) -EA SilentlyContinue)
        }
        $foundExe = $candidates |
            Where-Object { Test-SdkExe -ExePath $_.FullName -ToolType $ToolType -State $State } | Select-Object -First 1
        if (-not $foundExe) { continue }
        $result = Register-SdkCandidate -ExePath $foundExe.FullName -ToolType $ToolType -State $State -LogLabel 'at priority path'
        if ($result) { return $result }
    }
    return $null
}

function Find-SdkInProjectTree
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    $currentDir = if ($State.WorkingDir) { [string]$State.WorkingDir } else { (Get-Location).ProviderPath }
    $validateBlock = { Test-SdkExe -ExePath $args[0] -ToolType $ToolType -State $State }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $projectDepth = [int](Get-SdkConfigValue -PropertyName 'projectScanDepth' -State $State)
        Write-Log (Resolve-LogMessage -Key 'log.sdk.scanningProjectTree' -MessageArgs @([string]$projectDepth) -Fallback 'Scanning project tree (depth {0})...') "Debug" $State
    }
    $projectDepth = [int](Get-SdkConfigValue -PropertyName 'projectScanDepth' -State $State)
    $res = Invoke-SmartScan -RootPath $currentDir -Filter $cfg.Exe `
        -MaxDepth $projectDepth -Label "Scanning project" `
        -ValidateScript $validateBlock -State $State
    if ($res) {
        $result = Register-SdkCandidate -ExePath $res -ToolType $ToolType -State $State -LogLabel 'in project tree'
        if ($result) { return $result }
    }
    $walker = $currentDir
    while (-not [string]::IsNullOrWhiteSpace($walker)) {
        $walker = Split-Path $walker -Parent
        if ([string]::IsNullOrWhiteSpace($walker) -or $walker -eq (Split-Path $walker -Qualifier)) { break }
        $parentDepth = [int](Get-SdkConfigValue -PropertyName 'parentScanDepth' -State $State)
        $sdkRoot = Find-SdkByDirectory -RootPath $walker -MaxDepth $parentDepth `
            -DirectoryPatterns $cfg.DirectoryPatterns -Exe $cfg.ExeRelativePath `
            -Label "Scanning parent: $walker" -ValidateScript $validateBlock -State $State
        if ($null -ne $sdkRoot -and (Test-Path -Path $sdkRoot)) {
            $exePath = Join-Path $sdkRoot $cfg.Exe
            $result = Register-SdkCandidate -ExePath $exePath -ToolType $ToolType -State $State -LogLabel 'in parent directory'
            if ($result) { return $result }
        }
    }
    return $null
}

function Find-SdkOnWindowsDrives
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    if (-not $script:IsWindows) { return $null }
    $cfg = $script:SDK_Config[$ToolType]
    $validateBlock = { Test-SdkExe -ExePath $args[0] -ToolType $ToolType -State $State }
    $currentDir = if ($State.WorkingDir) { [string]$State.WorkingDir } else { (Get-Location).ProviderPath }
    $projectDrive = [System.IO.Path]::GetPathRoot($currentDir)
    if ([string]::IsNullOrWhiteSpace($projectDrive)) { return $null }
    $relativePart = if ($currentDir.StartsWith($projectDrive)) { $currentDir.Substring($projectDrive.Length) } else { "" }
    $depthX = ($relativePart.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) | Where-Object { $_ -ne "" }).Count
    $searchDepth = $depthX + [int](Get-SdkConfigValue -PropertyName 'winSearchDepthDelta' -State $State)
    $allDrives = if (Get-Command Get-AvailableDrives -ErrorAction SilentlyContinue) { Get-AvailableDrives } else { @() }
    $orderedDrives = [System.Collections.Generic.List[string]]::new()
    $orderedDrives.Add($projectDrive.TrimEnd('\', '/') + '\')
    foreach ($d in $allDrives) {
        $cleanD = $d.TrimEnd('\', '/') + '\'
        if ($cleanD -ne $orderedDrives[0]) { $orderedDrives.Add($cleanD) }
    }
    $validDrives = $orderedDrives.ToArray() | Select-Object -Unique | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -Path $_)
    }
    foreach ($drive in $validDrives) {
        $labelPrefix = if ($drive -eq $validDrives[0]) { "Scanning project drive $drive" } else { "Scanning drive $drive" }
        $sdkRoot = Find-SdkByDirectory -RootPath $drive -MaxDepth $searchDepth `
            -DirectoryPatterns $cfg.DirectoryPatterns -Exe $cfg.ExeRelativePath `
            -Label "$labelPrefix (Depth $searchDepth)" -ValidateScript $validateBlock -State $State
        if ($null -ne $sdkRoot -and (Test-Path -Path $sdkRoot)) {
            $exePath = Join-Path $sdkRoot $cfg.Exe
            $result = Register-SdkCandidate -ExePath $exePath -ToolType $ToolType -State $State -LogLabel "on drive $drive"
            if ($result) { return $result }
        }
    }
    return $null
}

function Find-SdkFromCustomPaths
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    $cfg = $script:SDK_Config[$ToolType]
    $customPaths = if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk -and $State.BuildConfig.sdk.customPaths) {
        @($State.BuildConfig.sdk.customPaths)
    } elseif ((Get-Command Get-BuildState -ErrorAction SilentlyContinue)) {
        $gs = Get-BuildState -State $State
        if ($gs -and $gs.BuildConfig -and $gs.BuildConfig.sdk -and $gs.BuildConfig.sdk.customPaths) {
            @($gs.BuildConfig.sdk.customPaths)
        } else { @() }
    } else { @() }
    if ($customPaths.Count -eq 0) { return $null }
    $validateBlock = { Test-SdkExe -ExePath $args[0] -ToolType $ToolType -State $State }
    foreach ($base in $customPaths) {
        $resolved = if ([System.IO.Path]::IsPathRooted($base)) { $base } else {
            $root = if ($State -and $State.ProjectRoot) { $State.ProjectRoot } else { (Get-Location).ProviderPath }
            Join-Path $root $base
        }
        # Direct hits FIRST (no recursion): <base>\sdkmanager.bat or
        # <base>\cmdline-tools\latest\bin\sdkmanager.bat. The recursive scan
        # below uses shallow depths and misses nested tool layouts.
        $directCandidates = @(
            (Join-Path $resolved $cfg.ExeRelativePath),
            (Join-Path (Join-Path $resolved $cfg.Bin) $cfg.Exe)
        )
        foreach ($cand in $directCandidates) {
            if ((Test-Path -Path $cand) -and (& $validateBlock $cand)) {
                Write-Log (Resolve-LogMessage -Key 'log.sdk.foundAt' -MessageArgs @([string]$cand) -Fallback 'Found SDK at: {0}') "Debug" -State $State
                $result = Register-SdkCandidate -ExePath $cand -ToolType $ToolType -State $State -LogLabel 'from custom path'
                if ($result) { return $result }
            }
        }
        $sdkRoot = Find-SdkByDirectory -RootPath $resolved -MaxDepth 1 `
            -DirectoryPatterns $cfg.DirectoryPatterns -Exe $cfg.ExeRelativePath `
            -Label "Scanning custom path: $resolved" -ValidateScript $validateBlock -State $State
        if ($null -ne $sdkRoot -and (Test-Path -Path $sdkRoot)) {
            $exePath = Join-Path $sdkRoot $cfg.Exe
            $result = Register-SdkCandidate -ExePath $exePath -ToolType $ToolType -State $State -LogLabel 'from custom path'
            if ($result) { return $result }
        }
    }
    return $null
}

function Get-ModuleState
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)
    if ($null -ne $State) { return $State }
    if (Get-Command Get-BuildState -ErrorAction SilentlyContinue) {
        $gs = Get-BuildState -State $State
        if ($null -ne $gs) { return $gs }
    }
    try
    {
        $gstateVar = Get-Variable -Name GState -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $gstateVar -and $null -ne $gstateVar.Value)
        { return $gstateVar.Value
        }
    } catch
    {
    }
    # CI detection: EnvironmentProvider.Test-CIEnvironment is the single
    # implementation. This used to be `[bool]$env:CI` - a fifth, independent
    # CI probe (the others are Preflight.psm1:287 and the provider itself).
    # $env:CI is also wrong on Azure DevOps and GitLab, where it may be unset
    # while TF_BUILD / GITLAB_CI are set, so this reported IsCI=$false inside
    # those CI systems.
    $isCi = $false
    if (Get-Command Test-CIEnvironment -ErrorAction SilentlyContinue) {
        try { $isCi = [bool](Test-CIEnvironment) } catch { $isCi = $false }
    } elseif (Get-Command Test-BuildCIHost -ErrorAction SilentlyContinue) {
        # Standalone import (no provider): the raw $env: probe is owned by
        # SharedUtils.Test-BuildCIHost, which also knows TF_BUILD and GITLAB_CI.
        try { $isCi = [bool](Test-BuildCIHost) } catch { $isCi = $false }
    } else {
        $isCi = [bool]($env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'True' -or $env:GITLAB_CI -eq 'true' -or $env:CI -eq 'true')
    }
    return [PSCustomObject]@{
        ScriptRoot = $PSScriptRoot
        WorkingDir = (Get-Location).ProviderPath
        IsInitialized = $false
        NonInteractive = $false
        IsCI = $isCi
        OS = if ($script:IsWindows)
        { 'Windows'
        } elseif ($script:IsMacOS)
        { 'MacOS'
        } else
        { 'Linux'
        }
    }
}

<#
    .SYNOPSIS
        Detects whether the current process can write to a system location (admin/root).
    .DESCRIPTION
        Windows: checks WindowsPrincipal for Administrator role.
        Linux/macOS: checks effective uid == 0.
        Used by auto-provisioning to decide install strategy.
    #>
function Test-IsAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:IsWindows) {
        try {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $princ = [System.Security.Principal.WindowsPrincipal]::new($id)
            return $princ.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { return $false }
    } else {
        try {
            $uid = id -u 2>$null
            return ($uid -eq '0')
        } catch { return $false }
    }
}

<#
    .SYNOPSIS
        Parses the highest installed SDK version from `dotnet --list-sdks` output.
    .DESCRIPTION
        Returns the TFM prefix (e.g. 'net10.0') for the latest SDK found.
        Used to auto-detect the default TFM from the resolved .NET SDK.
    .PARAMETER DotnetExe
        Path to the dotnet executable.
    #>
function Get-LatestSdkTfm {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$DotnetExe)
    try {
        $out = & $DotnetExe '--list-sdks' 2>&1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return $null }
        $best = $null
        foreach ($line in @($out)) {
            if ($line -match '(\d+)\.(\d+)\.\d+') {
                $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                if ($null -eq $best -or ($major -gt $best.Major) -or ($major -eq $best.Major -and $minor -gt $best.Minor)) {
                    $best = [PSCustomObject]@{ Major = $major; Minor = $minor }
                }
            }
        }
        if ($best) { return "net$($best.Major).$($best.Minor)" }
    } catch {
        # benign - parsing failure returns null fallback
        }
    return $null
}

function ConvertTo-DotnetVersionTriple {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Version)
    # Parses '10.0.300', '8.0.404', '10.0.100-preview.1' (suffix stripped).
    # Returns $null when the leading numeric triple is absent.
    try {
        $clean = ([string]$Version).Trim() -replace '\+.*$', ''
        $clean = $clean -replace '-.*$', ''
        $parts = @($clean -split '\.')
        if ($parts.Count -lt 3) { return $null }
        return [PSCustomObject]@{
            Major = [int]$parts[0]
            Minor = [int]$parts[1]
            Patch = [int]$parts[2]
        }
    } catch { return $null }
}

function Get-GlobalJsonSdkPin {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State = $null)
    # Reads the project's global.json sdk.version / sdk.rollForward by walking
    # up from ProjectRoot (then WorkingDir), max 4 levels. Returns
    # @{ Version; RollForward; Path } or $null when no pin exists. Never throws:
    # a missing/unparseable pin means "no constraint", never "fail the build".
    # The project's own pin is authoritative; the system never rewrites it.
    $roots = @()
    try {
        if ($State) {
            foreach ($prop in @('ProjectRoot', 'WorkingDir')) {
                if ($State.PSObject.Properties.Name -contains $prop) {
                    $v = [string]$State.$prop
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $roots += $v }
                }
            }
        }
    } catch { }
    foreach ($root in $roots) {
        $dir = ''
        try { $dir = [System.IO.Path]::GetFullPath($root) } catch { continue }
        for ($depth = 0; $depth -lt 4; $depth++) {
            $candidate = Join-Path $dir 'global.json'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                try {
                    $json = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $sdk = $null
                    if ($json.PSObject.Properties.Name -contains 'sdk') { $sdk = $json.sdk }
                    if ($null -ne $sdk -and $sdk.PSObject.Properties.Name -contains 'version') {
                        $ver = [string]$sdk.version
                        if (-not [string]::IsNullOrWhiteSpace($ver)) {
                            $rf = 'latestPatch'
                            if ($sdk.PSObject.Properties.Name -contains 'rollForward' -and -not [string]::IsNullOrWhiteSpace([string]$sdk.rollForward)) {
                                $rf = [string]$sdk.rollForward
                            }
                            return [PSCustomObject]@{ Version = $ver.Trim(); RollForward = $rf.Trim(); Path = $candidate }
                        }
                    }
                } catch { }
                return $null
            }
            $parent = $null
            try { $parent = [System.IO.Path]::GetDirectoryName($dir) } catch { $parent = $null }
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    return $null
}

function Get-InstalledDotnetSdks {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$DotnetExe)
    # Lists installed SDK versions via '<exe> --list-sdks' (fast, local only).
    # Returns @() on any failure; never throws.
    try {
        if (-not (Test-Path -LiteralPath $DotnetExe -PathType Leaf)) { return @() }
        $out = & $DotnetExe '--list-sdks' 2>&1
        if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return @() }
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @($out)) {
            $text = [string]$line
            if ($text -match '^\s*(\d+\.\d+\.\d+[^\s]*)') { $found.Add($Matches[1].Trim()) | Out-Null }
        }
        return @($found.ToArray())
    } catch { return @() }
}

function Test-DotnetPinSatisfied {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$RequiredVersion = '',
        [string[]]$InstalledSdks = @(),
        [string]$RollForward = 'latestPatch'
    )
    # Mirrors global.json sdk.rollForward semantics (numeric triple compare,
    # prerelease suffix stripped): disable = exact; latestPatch (default) =
    # same major.minor with patch >= requested; latestFeature = same
    # major.minor with patch (feature band) >= requested; latestMinor = same
    # major with minor.patch >= requested; latestMajor = any installed >=
    # requested. No pin ($RequiredVersion empty/unparseable) is satisfied.
    if ([string]::IsNullOrWhiteSpace($RequiredVersion)) { return $true }
    $req = ConvertTo-DotnetVersionTriple -Version $RequiredVersion
    if ($null -eq $req) { return $true }
    $mode = ([string]$RollForward).Trim().ToLowerInvariant()
    if ($mode -notin @('disable', 'latestpatch', 'latestfeature', 'latestminor', 'latestmajor')) { $mode = 'latestpatch' }
    foreach ($cand in @($InstalledSdks)) {
        $inst = ConvertTo-DotnetVersionTriple -Version ([string]$cand)
        if ($null -eq $inst) { continue }
        $ok = $false
        switch ($mode) {
            'disable' { $ok = ($inst.Major -eq $req.Major -and $inst.Minor -eq $req.Minor -and $inst.Patch -eq $req.Patch) }
            'latestpatch' { $ok = ($inst.Major -eq $req.Major -and $inst.Minor -eq $req.Minor -and $inst.Patch -ge $req.Patch) }
            'latestfeature' { $ok = ($inst.Major -eq $req.Major -and $inst.Minor -eq $req.Minor -and $inst.Patch -ge $req.Patch) }
            'latestminor' { $ok = ($inst.Major -eq $req.Major -and ($inst.Minor -gt $req.Minor -or ($inst.Minor -eq $req.Minor -and $inst.Patch -ge $req.Patch))) }
            'latestmajor' {
                $ok = ($inst.Major -gt $req.Major -or ($inst.Major -eq $req.Major -and ($inst.Minor -gt $req.Minor -or ($inst.Minor -eq $req.Minor -and $inst.Patch -ge $req.Patch))))
            }
        }
        if ($ok) { return $true }
    }
    return $false
}

function Compare-DotnetVersion {
    [CmdletBinding()]
    [OutputType([object])]
    param([string]$A = '', [string]$B = '')
    # Numeric triple compare (suffix stripped): -1 when A<B, 0 when equal,
    # 1 when A>B, $null when either side is unparseable (caller treats $null
    # as "unknown", never as a verdict — fail-soft by construction).
    $ta = ConvertTo-DotnetVersionTriple -Version $A
    $tb = ConvertTo-DotnetVersionTriple -Version $B
    if ($null -eq $ta -or $null -eq $tb) { return $null }
    foreach ($part in @('Major', 'Minor', 'Patch')) {
        if ($ta.$part -lt $tb.$part) { return -1 }
        if ($ta.$part -gt $tb.$part) { return 1 }
    }
    return 0
}

function Get-ReleaseMetadataCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State = $null)
    # User-local sidecar next to the SDK cache (never inside a project or a
    # shared SDK dir). Best-effort: falls back to TEMP, never throws.
    try {
        $leaf = 'dotnet-release.json'
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $leaf = [string](Get-BuildConstant -Key 'SdkReleaseCacheFileName' -State $State -Fallback 'dotnet-release.json') } catch { }
        }
        if (Get-Command Get-SdkCacheFile -ErrorAction SilentlyContinue) {
            try {
                $sdkCache = [string](Get-SdkCacheFile -State $State)
                if (-not [string]::IsNullOrWhiteSpace($sdkCache)) {
                    $dir = [System.IO.Path]::GetDirectoryName($sdkCache)
                    if (-not [string]::IsNullOrWhiteSpace($dir)) { return (Join-Path $dir $leaf) }
                }
            } catch { }
        }
        return (Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-' + $leaf))
    } catch { return '' }
}

function Get-LatestReleasedSdkVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State = $null,
        [Parameter(Mandatory)][string]$Channel
    )
    # Latest SDK the provider has actually released for a channel (e.g. '10.0').
    # Source order: fresh remote release-metadata -> same-channel cache within
    # TTL -> stale same-channel cache -> sdk.maxKnownSdkVersion config ->
    # unknown (''). Remote failure (offline/slow/blocked) NEVER fails the
    # build: it just degrades to cache/config, and the release-cap check that
    # consumes this is skipped when the result is unknown.
    $chan = ([string]$Channel).Trim()
    if ([string]::IsNullOrWhiteSpace($chan)) { return '' }
    $ttlHours = 24
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $ttlHours = [int](Get-BuildConstant -Key 'SdkReleaseCacheHours' -State $State -Fallback 24)
        }
    } catch { $ttlHours = 24 }
    if ($ttlHours -lt 1) { $ttlHours = 1 }
    $cachePath = Get-ReleaseMetadataCachePath -State $State
    $readCache = {
        param([bool]$RespectTtl)
        try {
            if ([string]::IsNullOrWhiteSpace($cachePath) -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return '' }
            $data = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $data -or [string]$data.Channel -ne $chan) { return '' }
            if ($RespectTtl -and $null -ne $data.PSObject.Properties['CheckedUtc']) {
                try {
                    $age = (Get-Date).ToUniversalTime() - [datetime]$data.CheckedUtc
                    if ($age.TotalHours -gt $ttlHours) { return '' }
                } catch { }
            }
            return [string]$data.Latest
        } catch { return '' }
    }
    $fresh = & $readCache $true
    if (-not [string]::IsNullOrWhiteSpace($fresh)) { return $fresh }
    $remote = ''
    try {
        $base = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata'
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $base = [string](Get-BuildConstant -Key 'SdkReleaseMetadataBaseUrl' -State $State -Fallback $base) } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $url = $base.TrimEnd('/') + '/' + $chan + '/releases.json'
            # Same Windows PowerShell 5.1 gap as the installer download below: without the
            # assembly load, New-Object System.Net.Http.HttpClient throws and the
            # whole release-metadata probe is swallowed by 'catch { $remote = '' }'
            # - so the "is the newest channel version newer than my cache?"
            # check silently never ran on 5.1. The load must precede any
            # HttpClient TYPE LITERAL; see the ordering note at the installer.
            try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
            $http = New-Object System.Net.Http.HttpClient
            try {
                $http.Timeout = [System.TimeSpan]::FromSeconds(8)
                $text = $http.GetStringAsync($url).GetAwaiter().GetResult()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $meta = $text | ConvertFrom-Json -ErrorAction Stop
                    if ($meta.PSObject.Properties.Name -contains 'latest-sdk' -and -not [string]::IsNullOrWhiteSpace([string]$meta.'latest-sdk')) {
                        $remote = ([string]$meta.'latest-sdk').Trim()
                    } elseif ($meta.PSObject.Properties.Name -contains 'releases') {
                        $first = @($meta.releases) | Select-Object -First 1
                        if ($first -and $first.PSObject.Properties.Name -contains 'sdk' -and $first.sdk.PSObject.Properties.Name -contains 'version') {
                            $remote = ([string]$first.sdk.version).Trim()
                        }
                    }
                }
            } finally {
                try { $http.Dispose() } catch { }
            }
        }
    } catch { $remote = '' }
    if (-not [string]::IsNullOrWhiteSpace($remote)) {
        try {
            $dir = [System.IO.Path]::GetDirectoryName($cachePath)
            if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
            $payload = [PSCustomObject]@{ Channel = $chan; Latest = $remote; CheckedUtc = (Get-Date).ToUniversalTime().ToString('o') }
            [System.IO.File]::WriteAllText($cachePath, (($payload | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        return $remote
    }
    $stale = & $readCache $false
    if (-not [string]::IsNullOrWhiteSpace($stale)) { return $stale }
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $cfg = [string](Get-BuildConstant -Key 'SdkMaxKnownVersion' -State $State -Fallback '')
            if (-not [string]::IsNullOrWhiteSpace($cfg)) { return $cfg.Trim() }
        }
    } catch { }
    return ''
}

<#
    .SYNOPSIS
        Downloads and installs the .NET SDK when no local copy is found.
    .DESCRIPTION
        Last-resort strategy in Get-SmartSdk. Reads sdk.autoProvision config
        (enabled, installDir, channel). Honors admin detection:
        - If install requires elevation and we are not admin, prints a manual
          download diagram and sets $State.BuildAborted = $true (no install).
        - If we can install, downloads dotnet-install script and runs it.
        After install, auto-detects the latest SDK TFM and updates $State.CurrentTfm.
    .PARAMETER State
        Build state (carries BuildConfig + CurrentTfm).
    .PARAMETER ToolType
        Must be 'Dotnet' for auto-provisioning (only .NET supported).
    #>
function Install-SdkFromRemote {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType,
        [string]$RequiredVersion = ''
    )
    if ($ToolType -ne 'Dotnet') { return $null }
    # Log prefix brackets used by all ${lb}TAG${rb} messages below (never assigned
    # before -> prefixes rendered without brackets).
    $lb = '['
    $rb = ']'
    $cfg = $null
    if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk -and $State.BuildConfig.sdk.autoProvision) {
        $cfg = $State.BuildConfig.sdk.autoProvision
    } elseif ((Get-Command Get-BuildState -ErrorAction SilentlyContinue)) {
        $gs = Get-BuildState -State $State
        if ($gs -and $gs.BuildConfig -and $gs.BuildConfig.sdk -and $gs.BuildConfig.sdk.autoProvision) { $cfg = $gs.BuildConfig.sdk.autoProvision }
    }
    if ($null -eq $cfg -or -not [bool]$cfg.enabled) { return $null }

    $installDir = if ($cfg.installDir) { $cfg.installDir } else { (Get-BuildConstant -Key 'SdkAutoProvisionInstallDir' -State $State -Fallback '~/.dotnet') }
    $installDir = $ExecutionContext.InvokeCommand.ExpandString($installDir)
    $channel = if ($cfg.channel) { $cfg.channel } else { (Get-BuildConstant -Key 'SdkAutoProvisionChannel' -State $State -Fallback 'LTS') }
    # Exact version pin wins over channel: an explicit pin (caller-supplied
    # project requirement first, sdk.autoProvision.version second) installs
    # THAT version instead of "latest of channel", so builds are reproducible
    # and a project pin can actually be satisfied. Invalid pins are ignored
    # (fail-soft to channel behaviour) with a warning, never a throw.
    $pinVersion = ([string]$RequiredVersion).Trim()
    if ([string]::IsNullOrWhiteSpace($pinVersion) -and $cfg.version) { $pinVersion = ([string]$cfg.version).Trim() }
    if ([string]::IsNullOrWhiteSpace($pinVersion)) {
        try { $pinVersion = ([string](Get-BuildConstant -Key 'SdkAutoProvisionVersion' -State $State -Fallback '')).Trim() } catch { $pinVersion = '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($pinVersion) -and $pinVersion -notmatch '^\d+\.\d+\.\d+') {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.pinInvalid' -MessageArgs @([string]$pinVersion) -Fallback 'Ignoring invalid SDK version pin: {0}') 'Warn' $State
        }
        $pinVersion = ''
    }
    # Installer integrity: sdk.autoProvision.installerSha256 pins the expected
    # SHA-256 of the dotnet-install script. Mismatch fails closed (no execute);
    # unpinned (default, compat) proceeds with a one-line recommendation.
    $expectedSha = ''
    if ($cfg.installerSha256) { $expectedSha = ([string]$cfg.installerSha256).Trim() }
    if ([string]::IsNullOrWhiteSpace($expectedSha)) {
        try { $expectedSha = ([string](Get-BuildConstant -Key 'SdkAutoProvisionInstallerSha256' -State $State -Fallback '')).Trim() } catch { $expectedSha = '' }
    }
    $expectedSha = ($expectedSha -replace '\s', '').ToLowerInvariant()

    # Decide if elevation is required for the chosen install dir.
    # Protected patterns single-sourced from BuildConstants.SdkProtectedPathPatterns.
    $needsAdmin = $false
    # Fallback patterns single-sourced from BuildConstants.SdkProtectedPathPatterns.
    # The literal below is the standalone fallback (BuildConstants not loaded).
    # No nested re-check: the outer branch already established its absence.
    $fallbackProtectedPatterns = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        @(Get-BuildConstant -Key 'SdkProtectedPathPatterns' -State $State -Fallback @('Program Files', 'Windows', '/usr/*', '/opt/*'))
    } else {
        @('Program Files', 'Windows', '/usr/*', '/opt/*')
    }
    $protectedPatterns = $fallbackProtectedPatterns
    if ($script:IsWindows) {
        foreach ($pat in @($protectedPatterns | Where-Object { $_ -notlike '/*' })) {
            if ($installDir -like "*$pat*") { $needsAdmin = $true; break }
        }
        if (-not $needsAdmin -and $env:SystemDrive) {
            # Drive-anchored check derived from the SAME configured pattern list as
            # the branch above. This used to hardcode "Program Files|Windows" in a
            # regex, so dropping either name from sdk.protectedPathPatterns had no
            # effect here and a relocated install dir was still flagged as needing
            # elevation. One list, one owner.
            $driveRoot = $env:SystemDrive.TrimEnd('\', '/') + '\'
            foreach ($pat in @($protectedPatterns | Where-Object { $_ -notlike '/*' })) {
                if ($installDir.StartsWith($driveRoot + $pat, [System.StringComparison]::OrdinalIgnoreCase)) { $needsAdmin = $true; break }
            }
        }
    } else {
        foreach ($pat in @($protectedPatterns | Where-Object { $_ -like '/*' })) {
            if ($installDir -like $pat) { $needsAdmin = $true; break }
        }
    }
    $isAdmin = Test-IsAdmin

    if ($needsAdmin -and -not $isAdmin) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.needAdmin' -MessageArgs @([string]$installDir) -Fallback 'Cannot auto-install .NET SDK to {0} without administrator privileges.') 'Err' $State
        }
        Write-Log ' ' -State $State
        Write-Log '  ----' -Color Yellow -State $State
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundTitle' -Fallback '.NET SDK NOT FOUND - manual install required') -Color Yellow -State $State
        Write-Log '  -                                                               -' -Color Yellow -State $State
        $dlPage = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'SdkDownloadPageUrl' -Fallback 'https://dotnet.microsoft.com/download' } else { 'https://dotnet.microsoft.com/download' }
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundStep1' -MessageArgs @([string]$dlPage) -Fallback '1. Visit: {0}') -Color Yellow -State $State
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundStep2' -MessageArgs @([string]$channel) -Fallback '2. Download the .NET SDK (channel: {0})') -Color Yellow -State $State
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundStep3' -Fallback '3. Install to a writable location (e.g. ~/.dotnet)') -Color Yellow -State $State
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundStep4' -Fallback '4. Re-run gbuild, OR set sdk.autoProvision.installDir') -Color Yellow -State $State
        Write-Log (Resolve-LogMessage -Key 'log.sdk.notFoundStep4b' -Fallback 'to a user-writable path and run as administrator.') -Color Yellow -State $State
        Write-Log '  ---' -Color Yellow -State $State
        Write-Log ' ' -State $State
        if ($State.PSObject.Properties.Name -contains 'BuildAborted') { $State.BuildAborted = $true }
        return $null
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        if (-not [string]::IsNullOrWhiteSpace($pinVersion)) {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.autoProvisioningVersion' -MessageArgs @([string]$pinVersion, [string]$channel, $installDir) -Fallback 'Auto-provisioning .NET SDK version {0} (channel {1}) to {2} ...') 'Info' $State
        } else {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.autoProvisioning' -MessageArgs @([string]$channel, $installDir) -Fallback 'Auto-provisioning .NET SDK (channel {0}) to {1} ...') 'Info' $State
        }
    }
    try {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet_install_' + [guid]::NewGuid().ToString('N'))
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $tmpDir) } else { New-Item -ItemType Directory -Path $tmpDir -Force -ErrorAction Stop | Out-Null }
        $scriptUrl = Get-BuildConstant -Key 'SdkInstallScriptUrlUnix' -Fallback 'https://dot.net/v1/dotnet-install.sh'
        $scriptPath = Join-Path $tmpDir ([string](Get-BuildConstant -Key 'SdkInstallScriptNameUnix' -Fallback 'dotnet-install.sh'))
        if ($script:IsWindows) {
            $scriptUrl = Get-BuildConstant -Key 'SdkInstallScriptUrlWin' -Fallback 'https://dot.net/v1/dotnet-install.ps1'
            $scriptPath = Join-Path $tmpDir ([string](Get-BuildConstant -Key 'SdkInstallScriptNameWin' -Fallback 'dotnet-install.ps1'))
        }
        # System.Net.Http is NOT pre-loaded in a bare Windows PowerShell 5.1
        # session: constructing [System.Net.Http.HttpClient] there throws
        # "Unable to find type", which landed in the catch below, logged
        # "Auto-provision failed", and returned $null - i.e. .NET SDK
        # auto-provisioning was silently dead on the one host this tool claims
        # to support. Modules/Deploy.psm1 and Modules/Environment.psm1 both
        # already carry this exact load, with the reason documented; this module
        # did not.
        #
        # ORDER MATTERS and is the non-obvious part. The load must come FIRST,
        # unconditionally: PowerShell resolves a [System.Net.Http.HttpClient]
        # TYPE LITERAL at parse/bind time, so a guard of the form
        #     if (([System.Net.Http.HttpClient] -as [type])) { Add-Type ... }
        # throws "Unable to find type" on 5.1 before the guard can protect
        # anything. Add-Type is idempotent and near-free once loaded, so the
        # unconditional form is both correct and cheaper to reason about.
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
        $http = [System.Net.Http.HttpClient]::new()
        $bytes = $http.GetByteArrayAsync($scriptUrl).GetAwaiter().GetResult()
        $http.Dispose()
        [System.IO.File]::WriteAllBytes($scriptPath, $bytes)
        if (-not (Test-Path $scriptPath)) { throw (Resolve-LogMessage -Key 'log.sdk.line1697' -Fallback 'download failed') }
        if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            try {
                $actual = (-join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).ToLowerInvariant()
            } finally {
                try { $hasher.Dispose() } catch { }
            }
            if ($actual -ne $expectedSha) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}ERR${rb} $(Resolve-LogMessage -Key 'log.sdk.installHashMismatch' -MessageArgs @([string]$expectedSha, [string]$actual) -Fallback 'dotnet-install script hash mismatch (expected {0}, got {1}); refusing to execute')" 'Err' $State }
                return $null
            }
        } elseif (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.sdk.installerUnpinned' -Fallback 'dotnet-install script hash is not pinned; set sdk.autoProvision.installerSha256 to enforce supply-chain integrity') 'Warn' $State
        }

        if ($script:IsWindows) {
            # SharedUtils.Resolve-PowerShellHost owns the preference order. The
            # fallback was hardcoded 'powershell', which is inconsistent with
            # the pwsh-first rule every other call site follows and would run
            # the dotnet-install script under the legacy host even when pwsh was
            # the host that launched this build.
            $psHostExe = 'pwsh'
            if (Get-Command Resolve-PowerShellHost -ErrorAction SilentlyContinue) {
                try { $resolved = [string](Resolve-PowerShellHost); if ($resolved) { $psHostExe = $resolved } } catch { }
            }
            # Pinned version installs exactly what the project requires (no
            # channel guesswork); unpinned keeps the legacy channel behaviour.
            if (-not [string]::IsNullOrWhiteSpace($pinVersion)) {
                $null = & $psHostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Version $pinVersion -InstallDir $installDir 2>&1
            } else {
                $null = & $psHostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Channel $channel -InstallDir $installDir 2>&1
            }
        } else {
            if (-not [string]::IsNullOrWhiteSpace($pinVersion)) {
                $null = & bash $scriptPath --version $pinVersion --install-dir $installDir 2>&1
            } else {
                $null = & bash $scriptPath -Channel $channel -InstallDir $installDir 2>&1
            }
        }
        if ($LASTEXITCODE -ne 0) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}ERR${rb} $(Resolve-LogMessage -Key 'log.sdk.installExitCode' -MessageArgs @([string]$LASTEXITCODE) -Fallback 'dotnet-install exited with code {0}')" 'Err' $State }
            return $null
        }
        $exeExt = if ($script:IsWindows) { '.exe' } else { '' }
        $dotnetExe = Join-Path $installDir "dotnet$exeExt"
        if (-not (Test-Path $dotnetExe) -or -not (Test-SdkExe -ExePath $dotnetExe -ToolType 'Dotnet')) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}ERR${rb} $(Resolve-LogMessage -Key 'log.sdk.installedInvalid' -MessageArgs @([string]$dotnetExe) -Fallback 'Installed dotnet not valid at {0}')" 'Err' $State }
            return $null
        }
        # Auto-detect TFM from the freshly installed SDK.
        $tfm = Get-LatestSdkTfm -DotnetExe $dotnetExe
        if ($tfm -and $State.PSObject.Properties.Name -contains 'CurrentTfm') {
            $State.CurrentTfm = $tfm
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}SDK${rb} $(Resolve-LogMessage -Key 'log.sdk.autoDetectedTfm' -MessageArgs @([string]$tfm) -Fallback 'Auto-detected CurrentTfm = {0}')" 'Succ' $State }
        }
        Set-CachedSdk -State $State -SdkName 'Dotnet' -Path $installDir
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}SDK${rb} $(Resolve-LogMessage -Key 'log.sdk.installedAt' -MessageArgs @([string]$dotnetExe) -Fallback 'Installed .NET SDK at: {0}')" 'Succ' $State }
        return $dotnetExe
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "${lb}ERR${rb} $(Resolve-LogMessage -Key 'log.sdk.provisionFailed' -MessageArgs @([string]$_) -Fallback 'Auto-provision failed: {0}')" 'Err' $State }
        return $null
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ==================================================================================
# MAIN SDK DISCOVERY ORCHESTRATOR
# ==================================================================================
function Get-SdkMemoKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ToolType, [PSCustomObject]$State = $null)
    # The memo key MUST scope to the project: keying by ToolType alone meant a
    # second run (or a second project in one run) reused run 1's SDK path, and
    # suppressed run 2's pin diagnostics via SdkPinNotified. ProjectRoot is the
    # stable per-project identity available at every call site.
    $scope = ''
    try {
        if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) {
            $scope = [string]$State.ProjectRoot
        } elseif ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) {
            $scope = [string]$State.ScriptRoot
        }
    } catch { $scope = '' }
    if ([string]::IsNullOrWhiteSpace($scope)) { return [string]$ToolType }
    return ([string]$ToolType + '|' + $scope)
}

function Reset-SdkMemo {
    [CmdletBinding()]
    param()
    # Per-run reset for long-lived hosts calling Start-GBuild twice. With
    # project-scoped keys (Get-SdkMemoKey) a reset is hygiene, not correctness -
    # but SdkPinNotified/SdkPinProvisioned suppress diagnostics per key, so a
    # reset guarantees run 2's pin warnings are emitted even for the same project.
    try { $script:SdkResolvedMemo = @{} } catch { }
    try { $script:SdkPinNotified = @{} } catch { }
    try { $script:SdkPinProvisioned = @{} } catch { }
}

function Get-SmartSdk
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$State,
        [ValidateSet('Dotnet', 'JDK', 'Android')] [string]$ToolType
    )
    # Session memo: discovery strategies validate on disk (and log) on
    # every call, so the 2nd/3rd lookup in one run (Build, SAST, lint...)
    # re-printed 'Checking...'/'Found...' and re-spawned validation.
    # A resolved SDK cannot change mid-session (SetEnv only stamps the
    # found home), so a recorded SUCCESS returns silently. Misses are
    # never memoized: a later retry (e.g. after auto-provision) must
    # re-run the waterfall. Same Get-Variable probe idiom as
    # $script:SdkPinNotified below (StrictMode-safe).
    $memoKey = Get-SdkMemoKey -ToolType $ToolType -State $State
    try {
        if ($null -eq (Get-Variable -Name 'SdkResolvedMemo' -Scope Script -ErrorAction SilentlyContinue)) { $script:SdkResolvedMemo = @{} }
        if ($script:SdkResolvedMemo.ContainsKey($memoKey)) {
            $memoHit = [string]$script:SdkResolvedMemo[$memoKey]
            if (-not [string]::IsNullOrWhiteSpace($memoHit)) { return $memoHit }
        }
    } catch { }
    # Flow-scoped: the Android CmdLineTools override only matters to Android
    # flows. Applying (and logging) it on every Dotnet/JDK lookup is what leaked
    # "[CONFIG] Android ..." into WinForms/Web builds.
    if ($ToolType -eq 'Android') { Update-AndroidSdkConfig -State $State }
    if ($ToolType -eq 'JDK' -and $script:SDK_Config['JDK']) {
        $jdkRelative = if ($script:IsWindows) { Get-BuildConstant -Key 'JdkJavacRelativeWin' -State $State -Fallback 'bin/javac.exe' } else { Get-BuildConstant -Key 'JdkJavacRelativeUnix' -State $State -Fallback 'bin/javac' }
        if ($jdkRelative) { $script:SDK_Config['JDK'].ExeRelativePath = [string]$jdkRelative }
    }

    $labelName = $script:SDK_Config[$ToolType].Label
    if (Get-Command Write-Log -ErrorAction SilentlyContinue)
    {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.checking' -MessageArgs @($labelName)) "Info" $State
    }
    $quickMode = [bool](Get-SdkConfigValue -PropertyName 'quickMode' -State $State)
    $skipWinDrives = [bool](Get-SdkConfigValue -PropertyName 'skipWindowsDriveScan' -State $State)
    # Per-strategy trace markers - make waterfall stalls diagnosable in build logs.
    $strategies = @(
        @{ Name = 'CustomPaths';   Call = { param($s) Find-SdkFromCustomPaths -State $State -ToolType $ToolType } },
        @{ Name = 'EnvHome';       Call = { param($s) Find-SdkFromEnvHome -State $State -ToolType $ToolType } },
        @{ Name = 'SystemPath';    Call = { param($s) Find-SdkFromSystemPath -State $State -ToolType $ToolType } },
        @{ Name = 'Cache';         Call = { param($s) Find-SdkFromCache -State $State -ToolType $ToolType } },
        @{ Name = 'PriorityPaths'; Call = { param($s) Find-SdkInPriorityPaths -State $State -ToolType $ToolType } }
    )
    if (-not $quickMode) {
        $strategies += @(
            @{ Name = 'ProjectTree'; Call = { param($s) Find-SdkInProjectTree -State $State -ToolType $ToolType } }
        )
        if (-not $skipWinDrives) {
            $strategies += @(
                @{ Name = 'WindowsDrives'; Call = { param($s) Find-SdkOnWindowsDrives -State $State -ToolType $ToolType } }
            )
        }
    }
    foreach ($strategy in $strategies) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.strategy' -MessageArgs @($strategy.Name)) 'Debug' $State
        $result = & $strategy.Call $State
        if ($result)
        {
            try { if ($null -eq (Get-Variable -Name 'SdkResolvedMemo' -Scope Script -ErrorAction SilentlyContinue)) { $script:SdkResolvedMemo = @{} }; $script:SdkResolvedMemo[$memoKey] = [string]$result } catch { }
            return $result
        }
    }
    # Last resort: auto-provision (download) if enabled in config.
    $result = Install-SdkFromRemote -State $State -ToolType $ToolType
    if ($result)
    { try { if ($null -eq (Get-Variable -Name 'SdkResolvedMemo' -Scope Script -ErrorAction SilentlyContinue)) { $script:SdkResolvedMemo = @{} }; $script:SdkResolvedMemo[$memoKey] = [string]$result } catch { }
    return $result
    }
    Set-CachedSdk -State $State -SdkName $ToolType -Path "NOT_FOUND"
    return $null
}

function Resolve-PinnedDotnetSdk {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State = $null,
        [string]$CandidateExe = ''
    )
    # Project-pin gate (additive): when the project pins sdk.version in
    # global.json and the resolved SDK cannot satisfy it, either provision
    # exactly that version side-by-side (opt-in autoProvision, user-writable
    # dir only — the shared/system SDK is never touched) or log an actionable
    # message naming the required version, the installed set and the fixes.
    # No pin -> candidate returned untouched (legacy behaviour preserved).
    # Provision/release-cap failures also fall through to the candidate, so a
    # green build can never turn red from this gate; a red build just fails
    # with guidance instead of dotnet's bare version error.
    if ([string]::IsNullOrWhiteSpace($CandidateExe)) { return $CandidateExe }
    $pin = $null
    try { $pin = Get-GlobalJsonSdkPin -State $State } catch { $pin = $null }
    if ($null -eq $pin -or [string]::IsNullOrWhiteSpace([string]$pin.Version)) { return $CandidateExe }
    $req = ([string]$pin.Version).Trim()
    $installed = @()
    try { $installed = @(Get-InstalledDotnetSdks -DotnetExe $CandidateExe) } catch { $installed = @() }
    $ok = $false
    try { $ok = [bool](Test-DotnetPinSatisfied -RequiredVersion $req -InstalledSdks $installed -RollForward ([string]$pin.RollForward)) } catch { $ok = $false }
    if ($ok) { return $CandidateExe }
    $installedText = '(none detected)'
    try { if (@($installed).Count -gt 0) { $installedText = ((@($installed) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', ') } } catch { }
    if ([string]::IsNullOrWhiteSpace($installedText)) { $installedText = '(none detected)' }
    # De-duplicate: Resolve-DotnetSdkCommand runs at several pipeline stages
    # (Preflight, Build, ...), so without this the same actionable notice
    # would print once per stage. First occurrence wins per (pin, global.json).
    $noticeKey = ($req + '|' + [string]$pin.Path).ToLowerInvariant()
    # Strict-safe init: reading an unset $script: variable throws under
    # Set-StrictMode, so probe via Get-Variable (never throws with
    # SilentlyContinue) instead of a direct read.
    $alreadyNotified = $false
    try {
        if ($null -eq (Get-Variable -Name 'SdkPinNotified' -Scope Script -ErrorAction SilentlyContinue)) { $script:SdkPinNotified = @{} }
        if ($script:SdkPinNotified.ContainsKey($noticeKey)) { $alreadyNotified = $true }
        else { $script:SdkPinNotified[$noticeKey] = $true }
    } catch { $alreadyNotified = $false }
    # Repeat stages reuse the previously provisioned SDK instead of
    # reinstalling: same noticeKey, still on disk -> return it silently.
    if ($alreadyNotified) {
        try {
            $memoVar = Get-Variable -Name 'SdkPinProvisioned' -Scope Script -ErrorAction SilentlyContinue
            if ($memoVar -and $memoVar.Value.ContainsKey($noticeKey)) {
                $memo = [string]$memoVar.Value[$noticeKey]
                if (-not [string]::IsNullOrWhiteSpace($memo) -and (Test-Path -LiteralPath $memo -PathType Leaf)) { return $memo }
            }
        } catch { }
    }
    if (-not $alreadyNotified -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        try { Write-Log (Resolve-LogMessage -Key 'log.sdk.pinMismatch' -MessageArgs @($req, [string]$pin.Path, $installedText) -Fallback '[SDK] Project global.json requires .NET SDK {0} ({1}); installed SDKs: {2}') 'Warn' $State } catch { }
    }
    # Release cap: a pin newer than anything the provider released (typo or
    # future version) can never be provisioned — tell the project to cap its
    # pin instead. Previews/RCs are the deliberate exception (advisory only).
    $latest = ''
    try {
        $triple = ConvertTo-DotnetVersionTriple -Version $req
        if ($triple) { $latest = [string](Get-LatestReleasedSdkVersion -State $State -Channel ("$($triple.Major).$($triple.Minor)")) }
    } catch { $latest = '' }
    $exceeds = $false
    if (-not [string]::IsNullOrWhiteSpace($latest)) {
        try { if ((Compare-DotnetVersion -A $req -B $latest) -gt 0) { $exceeds = $true } } catch { $exceeds = $false }
    }
    if ($exceeds) {
        if (-not $alreadyNotified -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            try { Write-Log (Resolve-LogMessage -Key 'log.sdk.pinExceedsRelease' -MessageArgs @($req, $latest, [string]$pin.Path) -Fallback '[SDK] Required SDK {0} is newer than the latest released SDK {1}; lower global.json ({2}) to {1} or older (preview/RC versions excepted)') 'Err' $State } catch { }
        }
        return $CandidateExe
    }
    $provisioned = $null
    try { $provisioned = Install-SdkFromRemote -State $State -ToolType 'Dotnet' -RequiredVersion $req } catch { $provisioned = $null }
    if (-not [string]::IsNullOrWhiteSpace($provisioned) -and (Test-Path -LiteralPath $provisioned -PathType Leaf)) {
        $usable = $false
        try {
            if (Get-Command Test-SdkExe -ErrorAction SilentlyContinue) { $usable = [bool](Test-SdkExe -ExePath $provisioned -ToolType 'Dotnet' -State $State) }
            else {
                $probe = & $provisioned '--list-sdks' 2>&1
                $usable = ($LASTEXITCODE -eq 0) -and ($null -ne $probe) -and (@($probe).Count -gt 0)
            }
        } catch { $usable = $false }
        if ($usable) {
            $provInstalled = @()
            try { $provInstalled = @(Get-InstalledDotnetSdks -DotnetExe $provisioned) } catch { $provInstalled = @() }
            $provOk = $false
            try { $provOk = [bool](Test-DotnetPinSatisfied -RequiredVersion $req -InstalledSdks $provInstalled -RollForward ([string]$pin.RollForward)) } catch { $provOk = $false }
            if ($provOk) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    try { Write-Log (Resolve-LogMessage -Key 'log.sdk.pinProvisioned' -MessageArgs @($req, [string]$provisioned) -Fallback '[SDK] Provisioned required SDK {0} at: {1}') 'Succ' $State } catch { }
                }
                try {
                    $storeVar = Get-Variable -Name 'SdkPinProvisioned' -Scope Script -ErrorAction SilentlyContinue
                    if ($null -eq $storeVar) { $script:SdkPinProvisioned = @{} }
                    $script:SdkPinProvisioned[$noticeKey] = [string]$provisioned
                } catch { }
                return [string]$provisioned
            }
        }
    }
    $latestText = if ([string]::IsNullOrWhiteSpace($latest)) { 'unknown' } else { $latest }
    $newest = $req
    try {
        $best = $null
        foreach ($cand in @($installed)) {
            if ([string]::IsNullOrWhiteSpace([string]$cand)) { continue }
            if ($null -eq $best -or ((Compare-DotnetVersion -A ([string]$cand) -B ([string]$best)) -gt 0)) { $best = [string]$cand }
        }
        if (-not [string]::IsNullOrWhiteSpace($best)) { $newest = $best }
    } catch { $newest = $req }
    if (-not $alreadyNotified -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        try { Write-Log (Resolve-LogMessage -Key 'log.sdk.pinInstallHint' -MessageArgs @($req, $latestText, $newest) -Fallback '[SDK] Fix: install SDK {0} (latest released: {1}), or set global.json sdk.version to an installed version (e.g. {2}); unattended: sdk.autoProvision.enabled=true with a writable installDir') 'Err' $State } catch { }
    }
    return $CandidateExe
}

function Resolve-DotnetSdkCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State = $null,
        [string]$PreferredPath = ''
    )
    # Single owner for "which dotnet do we run".
    #
    # A dotnet muxer can exist, be first on PATH, and still be unable to run any
    # SDK command: that is a runtime-only install (e.g. C:\Program Files\dotnet
    # shipping host + runtimes but no SDK). Callers that resolved by name or by
    # PATH picked that one and every SDK verb then failed with
    # "No .NET SDKs were found", which surfaced as unrelated-looking build
    # failures - `dotnet format` exiting 2, the SAST vulnerability audit blocking
    # on findings=0. So EVERY candidate here is validated with Test-SdkExe
    # (`dotnet --list-sdks` must exit 0 and print at least one SDK) before it is
    # accepted. A candidate that fails validation is skipped, never returned.
    #
    # Order:
    #   1. PreferredPath - usually State.DotnetCmd. Validated, because a previous
    #      stage may have cached a SDK-less muxer there; trusting it blindly is
    #      what pinned later steps to the broken one.
    #   2. Get-SmartSdk  - the canonical resolver (honours DOTNET_ROOT).
    #   3. DOTNET_ROOT / DOTNET_ROOT(x86) - the documented explicit opt-in, cheap
    #      and correct even when SDK.psm1 has not been imported yet.
    #   4. PATH          - last resort, still validated.
    # Returns $null when no muxer on this machine can run SDK commands, so callers
    # can report "no .NET SDK" instead of failing later with a tool's own error.
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $isUsable = {
        param($path)
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $p = [string]$path
        if (-not $seen.Add($p)) { return $false }   # already tried and rejected
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        if (Get-Command Test-SdkExe -ErrorAction SilentlyContinue) { return [bool](Test-SdkExe -ExePath $p -ToolType 'Dotnet' -State $State) }
        # Test-SdkExe unavailable: fall back to the capability probe it performs.
        try {
            $out = & $p '--list-sdks' 2>&1
            return ($LASTEXITCODE -eq 0) -and ($null -ne $out) -and ($out.Count -gt 0)
        } catch { return $false }
    }

    # Single exit below runs every candidate through the project-pin gate.
    # Always initialized: Set-StrictMode forbids reading an unset variable.
    $finalExe = $null
    if ($isUsable.Invoke($PreferredPath)) { $finalExe = [string]$PreferredPath }

    if ([string]::IsNullOrWhiteSpace($finalExe) -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        try {
            $smart = Get-SmartSdk -State $State -ToolType 'Dotnet'
            if ($isUsable.Invoke($smart)) { $finalExe = [string]$smart }
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($finalExe)) {
        foreach ($var in @('DOTNET_ROOT', 'DOTNET_ROOT(x86)')) {
            $root = [Environment]::GetEnvironmentVariable($var)
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            foreach ($leaf in @('dotnet.exe', 'dotnet')) {
                if ($isUsable.Invoke((Join-Path $root $leaf))) { $finalExe = [string](Join-Path $root $leaf); break }
            }
            if (-not [string]::IsNullOrWhiteSpace($finalExe)) { break }
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalExe) -and (Get-Command Get-Command -ErrorAction SilentlyContinue)) {
        $onPath = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) {
            $src = if ($onPath.Source) { [string]$onPath.Source } else { [string]$onPath.Path }
            if ($isUsable.Invoke($src)) { $finalExe = $src }
        }
    }
    if ([string]::IsNullOrWhiteSpace($finalExe)) { return $null }
    # Project-pin gate: satisfies global.json exactly, provisions side-by-side
    # when enabled, or logs what to install/cap. Absent pin (or any helper
    # failure) the candidate passes through untouched.
    if (Get-Command Resolve-PinnedDotnetSdk -ErrorAction SilentlyContinue) {
        try {
            $checked = Resolve-PinnedDotnetSdk -State $State -CandidateExe $finalExe
            if (-not [string]::IsNullOrWhiteSpace($checked)) { return [string]$checked }
        } catch { }
    }
    return [string]$finalExe
}

Export-ModuleMember -Function @('Get-SmartSdk', 'Get-SdkMemoKey', 'Reset-SdkMemo', 'Get-ModuleState', 'Get-CachedSdk', 'Set-CachedSdk', 'Get-SdkCacheFile', 'Get-SdkConfigValue', 'Test-ExeWithTimeout', `
    'Get-SdkExePath', 'Invoke-SmartScan', 'Find-SdkByDirectory', 'Test-SdkExe', `
    'Install-SdkFromRemote', 'Test-IsAdmin', 'Get-LatestSdkTfm', 'Resolve-DotnetSdkCommand', `
    'ConvertTo-DotnetVersionTriple', 'Get-GlobalJsonSdkPin', 'Get-InstalledDotnetSdks', 'Test-DotnetPinSatisfied', `
    'Compare-DotnetVersion', 'Get-ReleaseMetadataCachePath', 'Get-LatestReleasedSdkVersion', 'Resolve-PinnedDotnetSdk', `
    'GetAndroidPriorityPaths'
)





