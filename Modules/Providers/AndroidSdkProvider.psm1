# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# AndroidSdkProvider.psm1 - Android SDK & ADB discovery provider
# Single source of truth for Android SDK home, ADB path, and SDK manager resolution.


# MODULE DEPENDENCIES: Environment, BuildConstants, Locale, Logging, ConfigProvider
# Provider lives in Modules/Providers/, so resolve Modules root explicitly
# (avoids fragile '..\ModuleBootstrap.ps1' dot-source semantics).
$script:ModulesRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapPath = Join-Path $script:ModulesRoot 'ModuleBootstrap.ps1'
if (Test-Path -LiteralPath $script:BootstrapPath) {
    . $script:BootstrapPath -Dependencies @()
}
foreach ($dep in @('Environment', 'BuildConstants', 'Locale', 'Logging', 'ConfigProvider')) {
    $depPath = Join-Path $script:ModulesRoot ($dep + '.psm1')
    if ((Test-Path -LiteralPath $depPath) -and (-not (Get-Module -Name $dep -ErrorAction SilentlyContinue))) {
        Import-Module $depPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

# OS detection via the canonical Environment.Get-OSPlatform, with a
# macOS-CORRECT fallback. The previous fallback was
#   if (Win32NT) { 'Windows' } else { 'Linux' }
# and the catch block defaulted to 'Windows' - so on macOS this provider
# reported 'Linux' (isMacOS = false) and on any detection fault it reported
# 'Windows'. It also ignored EnvironmentProvider.Resolve-CanonicalOS, which
# exists precisely to normalize OS tokens.
$script:DetectedOS = 'Unknown'
try {
    if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) {
        $script:DetectedOS = [string](Get-OSPlatform)
    } elseif (Get-Command Resolve-CanonicalOS -ErrorAction SilentlyContinue) {
        $script:DetectedOS = [string](Resolve-CanonicalOS -RawOS ([System.Environment]::OSVersion.Platform.ToString()))
    } elseif (Get-Command Get-CanonicalOSName -ErrorAction SilentlyContinue) {
        $script:DetectedOS = [string](Get-CanonicalOSName)
    } else {
        $plat = [System.Environment]::OSVersion.Platform
        if ($plat -eq [System.PlatformID]::Win32NT) { $script:DetectedOS = 'Windows' }
        elseif ($plat -eq [System.PlatformID]::MacOSX) { $script:DetectedOS = 'MacOS' }
        else { $script:DetectedOS = 'Linux' }
    }
} catch {
    # Fail to 'Unknown', never to 'Windows': a wrong-OS default makes the
    # provider look for adb.exe on a Unix host and hide a real adb.
    $script:DetectedOS = 'Unknown'
}
if (-not $script:DetectedOS) { $script:DetectedOS = 'Unknown' }
$script:IsWindows = ($script:DetectedOS -eq 'Windows')
$script:IsMacOS   = ($script:DetectedOS -eq 'MacOS')
$script:IsLinux   = ($script:DetectedOS -eq 'Linux')
$script:BinExt    = if ($script:IsWindows) { '.exe' } else { '' }

# Helper: safe BuildDefault lookup with literal fallback (standalone-import safe).
function Get-AndroidDefault {
    param([string]$Key, $Fallback)

Set-StrictMode -Version 1.0
    try {
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            return Get-BuildDefault -Key $Key -Fallback $Fallback
        }
    } catch { }
    return $Fallback
}

# Android SDK configuration (config-overridable, single-sourced from BuildConstants)
$script:AndroidSdkConfig = @{
    PlatformToolsDirName     = [string](Get-AndroidDefault -Key 'PlatformToolsDirName' -Fallback 'platform-tools')
    BuildToolsDirName        = [string](Get-AndroidDefault -Key 'BuildToolsDirName' -Fallback 'build-tools')
    AndroidDirName           = [string](Get-AndroidDefault -Key 'SdkAndroidDirName' -Fallback 'Android')
    AndroidSdkDirName        = [string](Get-AndroidDefault -Key 'SdkAndroidSdkDirName' -Fallback 'Sdk')
    AndroidSdkLegacyDirName  = [string](Get-AndroidDefault -Key 'SdkAndroidSdkLegacyDirName' -Fallback 'android-sdk')
    AndroidMac               = [string](Get-AndroidDefault -Key 'SdkAndroidMac' -Fallback '/usr/local/share/android-sdk')
    AndroidHomeMacSub        = [string](Get-AndroidDefault -Key 'SdkAndroidHomeMacSub' -Fallback 'Library/Android/sdk')
    AndroidDebian            = [string](Get-AndroidDefault -Key 'SdkAndroidDebian' -Fallback '/usr/lib/android-sdk')
    AndroidHomeLinuxSub      = [string](Get-AndroidDefault -Key 'SdkAndroidHomeLinuxSub' -Fallback 'Android/Sdk')
    RootHomeFallback         = [string](Get-AndroidDefault -Key 'SdkRootHomeFallback' -Fallback '/root')
    GbuildDotSdkAndroidSdk   = [string](Get-AndroidDefault -Key 'SdkGbuildDotSdkAndroidSdk' -Fallback '.sdk/android-sdk')
    GbuildDotSdk             = [string](Get-AndroidDefault -Key 'SdkGbuildDotSdk' -Fallback '.sdk')
    GbuildParentDotSdkAndroidSdk = [string](Get-AndroidDefault -Key 'SdkGbuildParentDotSdkAndroidSdk' -Fallback '../.sdk/android-sdk')
    AdbToolName              = [string](Get-AndroidDefault -Key 'AdbToolName' -Fallback 'adb')
    AndroidCmdLineToolsRelPath = [string](Get-AndroidDefault -Key 'AndroidCmdLineToolsRelPath' -Fallback 'cmdline-tools/latest/bin')
    AutoConnectEndpoints     = @(Get-AndroidDefault -Key 'AdbAutoConnectEndpoints' -Fallback @(
        '127.0.0.1:5555','127.0.0.1:5556','127.0.0.1:5557','127.0.0.1:7555',
        '127.0.0.1:21503','127.0.0.1:62001','localhost:5555'
    ))
    DaemonRestartDelayMs     = [int](Get-AndroidDefault -Key 'AdbDaemonRestartDelayMs' -Fallback 600)
}

# Apply config overrides (sdk.android.* section)
function Update-AndroidSdkProviderConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk) {
        $cfg = $State.BuildConfig.sdk
        if ($cfg.androidCmdLineToolsRelPath) {
            $script:AndroidSdkConfig.AndroidCmdLineToolsRelPath = $cfg.androidCmdLineToolsRelPath
        }
        if ($cfg.adbAutoConnectEndpoints) {
            $script:AndroidSdkConfig.AutoConnectEndpoints = @($cfg.adbAutoConnectEndpoints)
        }
    }
}

<#
.SYNOPSIS
    Returns the Android SDK home directory path.
.DESCRIPTION
    Resolves the Android SDK root by checking State, environment variables,
    OS-specific default locations, and gbuild-specific paths.
.PARAMETER State
    The global build state object.
.OUTPUTS
    string (Android SDK root path) or $null if not found.
#>
function Get-AndroidSdkHome {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

    # Level 5: apply sdk.* config overrides (was test-only). No-op when absent.
    if (Get-Command Update-AndroidSdkProviderConfig -ErrorAction SilentlyContinue) {
        try { Update-AndroidSdkProviderConfig -State $State } catch { }
    }

    # 1. State already has it
    if ($State.AndroidSdk -and (Test-Path $State.AndroidSdk)) {
        return $State.AndroidSdk
    }

    # 2. Environment variables
    $envSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $null }
    if ($envSdk -and (Test-Path $envSdk)) { return $envSdk }

    # 3. OS-specific priority paths — single-sourced in SDK.GetAndroidPriorityPaths.
    # The provider delegates when SDK is available (Tier-1, always loaded in a
    # normal build) and keeps a minimal fallback for standalone import.
    $c = $script:AndroidSdkConfig
    $paths = [System.Collections.Generic.List[string]]::new()

    $sharedPaths = $null
    if (Get-Command GetAndroidPriorityPaths -ErrorAction SilentlyContinue) {
        try { $sharedPaths = @(GetAndroidPriorityPaths -State $State) } catch { $sharedPaths = $null }
    }
    if ($sharedPaths -and $sharedPaths.Count -gt 0) {
        foreach ($p in $sharedPaths) { if ($p) { $paths.Add([string]$p) } }
    } else {
        if ($script:IsWindows) {
            if ($env:LOCALAPPDATA) { $paths.Add((Join-Path (Join-Path $env:LOCALAPPDATA $c.AndroidDirName) $c.AndroidSdkDirName)) }
            if ($env:ProgramFiles) { $paths.Add((Join-Path (Join-Path $env:ProgramFiles $c.AndroidDirName) $c.AndroidSdkLegacyDirName)) }
        } elseif ($script:IsMacOS) {
            if ($env:HOME) { $paths.Add((Join-Path $env:HOME $c.AndroidHomeMacSub)) }
            $paths.Add($c.AndroidMac)
        } elseif ($script:IsLinux) {
            if ($env:HOME) { $paths.Add((Join-Path $env:HOME $c.AndroidHomeLinuxSub)) }
            $paths.Add($c.AndroidDebian)
            $sdkAndroidLinux = [string](Get-AndroidDefault -Key 'SdkAndroidLinux' -Fallback '/opt/android-sdk')
            if ($c.AndroidDebian -ne $sdkAndroidLinux) { $paths.Add($sdkAndroidLinux) }
        }
    }

    # 4. gbuild-specific paths (SDK roots, not platform-tools leaves)
    if ($State -and $State.ScriptRoot) {
        $sr = $State.ScriptRoot
        $paths.Add((Join-Path $sr $c.GbuildParentDotSdkAndroidSdk))
        $paths.Add((Join-Path (Join-Path $sr $c.GbuildDotSdk) $c.GbuildDotSdkAndroidSdk))
    }

    # 5. Config-driven custom paths
    if ($State -and $State.BuildConfig -and $State.BuildConfig.sdk -and $State.BuildConfig.sdk.customPaths) {
        foreach ($p in @($State.BuildConfig.sdk.customPaths)) {
            if ($p -like '*android*' -or $p -like '*sdk*') { $paths.Add($p) }
        }
    }

    foreach ($p in $paths) {
        if ($p -and (Test-Path $p)) { return $p }
    }

    return $null
}

<#
.SYNOPSIS
    Finds the ADB executable path.
.DESCRIPTION
    Searches for adb in PATH, State.AndroidSdk, environment variables,
    OS-specific default locations, and gbuild-specific paths.
.PARAMETER State
    The global build state object.
.OUTPUTS
    string (full path to adb executable) or tool name for PATH resolution.
#>
function Find-AdbPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

    # AdbToolName existed and was mapped to config but never read, so a site with
    # a differently-named adb could not be configured. Resolve it from the
    # already-built config object (which carries AdbToolName) with a literal
    # fallback for a partial copy.
    $adbLeaf = 'adb'
    try { if ($script:AndroidSdkConfig -and ($script:AndroidSdkConfig.PSObject.Properties.Name -contains 'AdbToolName') -and $script:AndroidSdkConfig.AdbToolName) { $adbLeaf = [string]$script:AndroidSdkConfig.AdbToolName } } catch { }
    # sdk.androidAdbRelativeWin / sdk.androidAdbRelativeUnix (shipped as
    # 'platform-tools/adb[.exe]') were declared and mapped but never read; a site
    # whose adb is not at the default relative path could not be configured.
    $adbRelKey = if ($script:IsWindows) { 'AndroidAdbRelativeWin' } else { 'AndroidAdbRelativeUnix' }
    $adbRelative = ''
    try { $adbRelative = [string](Get-AndroidDefault -Key $adbRelKey -Fallback '') } catch { $adbRelative = '' }
    $adbName = "$adbLeaf$script:BinExt"
    $c = $script:AndroidSdkConfig

    # Step 1: Check if adb is in system PATH
    $adbInPath = @(Get-Command -Name $adbName -CommandType Application -ErrorAction SilentlyContinue)
    if ($adbInPath.Count -gt 0) {
        $first = $adbInPath[0]
        if ($first.Source) { return $first.Source }
        return $first.Path
    }

    # Step 2: Check Android SDK from State
    # Use the provider's own accessor instead of re-deriving platform-tools/<adb>
    # here. Get-AndroidPlatformToolsDir existed and had zero production callers,
    # so the "where is platform-tools" knowledge existed in two places.
    $sdkHome = Get-AndroidSdkHome -State $State
    if ($sdkHome) {
        # A configured sdk.androidAdbRelativeWin/Unix is authoritative: it names
        # the adb path RELATIVE TO THE SDK ROOT, so it subsumes both the
        # platform-tools directory and the binary name.
        if (-not [string]::IsNullOrWhiteSpace($adbRelative)) {
            $relPath = $adbRelative
            try { $relPath = [string](Resolve-EnvPlaceholder -Text $relPath) } catch { }
            if ($relPath -notmatch '\$\{env:') {
                $candidate = $relPath
                try { if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $sdkHome $candidate } } catch { }
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
        $ptDir = Get-AndroidPlatformToolsDir -State $State
        if (-not $ptDir) { $ptDir = Join-Path $sdkHome $c.PlatformToolsDirName }
        $sdkAdbPath = Join-Path $ptDir $adbName
        if (Test-Path -LiteralPath $sdkAdbPath) { return $sdkAdbPath }
    }

    # Step 3: Check environment variables
    $envSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $null }
    if ($envSdk) {
        $envAdbPath = Join-Path (Join-Path $envSdk $c.PlatformToolsDirName) $adbName
        if (Test-Path -LiteralPath $envAdbPath) { return $envAdbPath }
    }

    # Step 4: OS-specific priority paths (same logic as Get-AndroidSdkHome but with platform-tools/adb)
    #
    # Every Join-Path below is nested 2-argument form. The 3-positional-child
    # form these lines used to use is PowerShell 6+ syntax and throws under
    # Windows PowerShell 5.1 ("A positional parameter cannot be found"), which
    # is exactly the host that reaches this block first: every one of these
    # paths is an OS-gated ADB lookup, so the Windows branch was the one that
    # always broke. Join-Path -AdditionalChildPath is also 6+ and is not a fix.
    $priorityPaths = [System.Collections.Generic.List[string]]::new()
    if ($script:IsWindows) {
        if ($env:LOCALAPPDATA) { $priorityPaths.Add((Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA $c.AndroidDirName) $c.AndroidSdkDirName) $c.PlatformToolsDirName) $adbName)) }
        if ($env:ProgramFiles) { $priorityPaths.Add((Join-Path (Join-Path (Join-Path (Join-Path $env:ProgramFiles $c.AndroidDirName) $c.AndroidSdkLegacyDirName) $c.PlatformToolsDirName) $adbName)) }
    } elseif ($script:IsMacOS) {
        if ($env:HOME) { $priorityPaths.Add((Join-Path (Join-Path (Join-Path $env:HOME $c.AndroidHomeMacSub) $c.PlatformToolsDirName) $adbName)) }
        $priorityPaths.Add((Join-Path (Join-Path $c.AndroidMac $c.PlatformToolsDirName) $adbName))
    } elseif ($script:IsLinux) {
        $homeDir = if ($env:HOME) { $env:HOME } else { $c.RootHomeFallback }
        $priorityPaths.Add((Join-Path (Join-Path (Join-Path $homeDir $c.AndroidHomeLinuxSub) $c.PlatformToolsDirName) $adbName))
        $priorityPaths.Add((Join-Path (Join-Path $c.AndroidDebian $c.PlatformToolsDirName) $adbName))
        # Level 5 single-source: SdkAndroidLinux + PlatformToolsDirName via Join-Path.
        $sdkAndroidLinux = [string](Get-AndroidDefault -Key 'SdkAndroidLinux' -Fallback '/opt/android-sdk')
        $linuxFallbackAdb = Join-Path (Join-Path $sdkAndroidLinux $c.PlatformToolsDirName) $adbName
        if ($priorityPaths -notcontains $linuxFallbackAdb) { $priorityPaths.Add($linuxFallbackAdb) }
    }

    # gbuild-specific paths
    if ($State -and $State.ScriptRoot) {
        $sr = $State.ScriptRoot
        $priorityPaths.Add((Join-Path (Join-Path (Join-Path $sr $c.GbuildParentDotSdkAndroidSdk) $c.PlatformToolsDirName) $adbName))
        # Nested 2-argument Join-Path on purpose. This line used THREE positional
        # children, which is PowerShell 6+ syntax and throws "A positional
        # parameter cannot be found" under Windows PowerShell 5.1.
        # (Join-Path -AdditionalChildPath is ALSO 6+, so it is not a fix either.)
        # Four nested calls are the only shape that behaves identically on
        # 5.1, 7.x and PowerShell Core on Linux/macOS. PS51Compat.Tests.ps1
        # scans SYNTAX shapes only, so this hazard was invisible to it; the
        # ps51-smoke CI job is what catches this class of defect.
        $priorityPaths.Add((Join-Path (Join-Path (Join-Path (Join-Path $sr $c.GbuildDotSdk) $c.GbuildDotSdkAndroidSdk) $c.PlatformToolsDirName) $adbName))
    }

    foreach ($adbPath in $priorityPaths) {
        if (Test-Path -Path $adbPath) { return $adbPath }
    }

    # Fail-closed: return $null when no adb executable exists on disk.
    # Callers guard with Test-Path and degrade gracefully; returning a bare
    # tool name ('adb') would pass a non-empty check but fail Test-Path,
    # breaking the Android.Tests null-or-existing contract.
    return $null
}

<#
.SYNOPSIS
    Scans for connected Android devices via ADB.
.DESCRIPTION
    Runs adb devices and parses output. Optionally auto-connects to
    configured endpoints (emulators, TCP/IP devices) if none found initially.
.PARAMETER State
    The global build state object.
.PARAMETER AdbPath
    Optional explicit ADB path. If omitted, uses Find-AdbPath.
.PARAMETER TryConnect
    Whether to attempt auto-connect to configured endpoints.
.OUTPUTS
    string[] of device serials.
#>
function Get-AdbDevices {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$AdbPath = '',
        [bool]$TryConnect = $true
    )

    if (-not $AdbPath) { $AdbPath = Find-AdbPath -State $State }
    if ([string]::IsNullOrWhiteSpace($AdbPath) -or -not (Test-Path -LiteralPath $AdbPath -EA SilentlyContinue)) {
        # Report WHICH part of the Android SDK is missing. Get-AndroidSdkManagerPath
        # existed and had zero production callers, so the toolchain never told an
        # operator that cmdline-tools/sdkmanager was absent - it just said "ADB not
        # available", which is unactionable when the real gap is a missing SDK
        # component that `adb` alone cannot fix.
        $sdkHome = Get-AndroidSdkHome -State $State
        if (-not $sdkHome) {
            Write-Log (Get-LocaleMessage -Key 'log.android.adbUnavailable' -Fallback 'ADB not available.') $State.Colors.Warn $State
            Write-Log (Resolve-LogMessage -Key 'log.android.noSdkRoot' -Fallback '[ANDROID] No Android SDK root found. Set ANDROID_HOME or ANDROID_SDK_ROOT, or install the SDK. adb alone is not enough to build or deploy.') 'Warn' $State
        } else {
            $sdkManager = Get-AndroidSdkManagerPath -State $State
            if (-not $sdkManager) {
                Write-Log (Get-LocaleMessage -Key 'log.android.adbUnavailable' -Fallback 'ADB not available.') $State.Colors.Warn $State
                Write-Log (Resolve-LogMessage -Key 'log.android.sdkRootNoTools' -MessageArgs @([string]$sdkHome) -Fallback '[ANDROID] SDK root ''{0}'' found but platform-tools/adb is missing, and cmdline-tools/sdkmanager is not installed. Install the SDK platform-tools (and cmdline-tools for dependency management).') 'Warn' $State
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.android.adbUnavailable' -Fallback 'ADB not available.') $State.Colors.Warn $State
                Write-Log (Resolve-LogMessage -Key 'log.android.sdkmanagerNoAdb' -MessageArgs @([string]$sdkHome, $sdkManager) -Fallback '[ANDROID] SDK root ''{0}'' found, sdkmanager present at ''{1}'', but platform-tools/adb is missing. Run: {1} platform-tools') 'Warn' $State
            }
        }
        return @()
    }

    $Result = Invoke-AdbDeviceScan -State $State -AdbPath $AdbPath

    if ($Result.Count -eq 0 -and $TryConnect) {
        $endpoints = $script:AndroidSdkConfig.AutoConnectEndpoints
        if ($endpoints.Count -eq 0) {
            Write-Log (Get-LocaleMessage -Key 'log.android.adbUnavailable' -Fallback 'ADB not available. Skipping device scan.') 'Info' $State
        }
        # Level 5 single-source: AdbConnectTimeoutMs bounds each auto-connect probe
        # so scanning 7 endpoints takes ~14s max instead of minutes on blocked network.
        $adbConnectTimeoutMs = 2000
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $adbConnectTimeoutMs = [int](Get-BuildConstant -Key 'AdbConnectTimeoutMs' -State $State -Fallback 2000) } catch { $adbConnectTimeoutMs = 2000 }
        }
        $probed = @()
        foreach ($endpoint in $endpoints) {
            if ([string]::IsNullOrWhiteSpace($endpoint)) { continue }
            $probe = $null
            try {
                $job = Start-Job -ScriptBlock { param($adb, $ep) & $adb connect $ep 2>&1 | Out-String } -ArgumentList $AdbPath, $endpoint
                $done = Wait-Job -Job $job -Timeout ([Math]::Max(1, [int]($adbConnectTimeoutMs / 1000))) | Out-Null
                $probe = Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                if (-not $done -and -not $probe) { $probe = '' }
            } catch {
                try { $probe = & $AdbPath connect $endpoint 2>&1 | Out-String } catch { $probe = '' }
            }
            if ($probe -match 'connected|already connected') {
                $probed += $endpoint
            }
        }
        if ($probed.Count -gt 0) {
            Write-Log (Get-LocaleMessage -Key 'log.android.autoConnect' -MessageArgs ($probed -join ', ')) $State.Colors.Info $State
            $Result = Invoke-AdbDeviceScan -State $State -AdbPath $AdbPath
        }
    }
    return $Result
}

<#
.SYNOPSIS
    Internal: runs adb devices and parses output.
    Handles adb daemon restart on transient failures.
#>
function Invoke-AdbDeviceScan {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$AdbPath
    )
    $devices = [System.Collections.Generic.List[string]]::new()
    $deviceSet = [System.Collections.Generic.HashSet[string]]::new()
    $inDeviceList = $false

    $output = & $AdbPath devices 2>&1
    $rawText = ($output -join "`n")

    # Handle adb daemon crash/restart (BlueStacks, large APK pushes, etc.)
    if ($rawText -match "daemon not running|could not read ok from ADB Server|cannot connect to daemon|failed to start daemon") {
        Write-Log (Get-LocaleMessage -Key 'log.android.adbDaemonRestart') $State.Colors.Warn $State
        & $AdbPath start-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds $script:AndroidSdkConfig.DaemonRestartDelayMs
        $output = & $AdbPath devices 2>&1
    }

    foreach ($line in $output) {
        if ($line -match "List of devices attached") {
            $inDeviceList = $true
            continue
        }

        if ($inDeviceList) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match "^(\S+)\s+device$") {
                $serial = $matches[1]
                if ($deviceSet.Add($serial)) {
                    $devices.Add($serial)
                }
            }
            elseif ($line -match "unauthorized") {
                Write-Log (Get-LocaleMessage -Key 'log.android.unauthDevice') $State.Colors.Warn $State
            }
        }
    }

    return $devices.ToArray()
}

<#
.SYNOPSIS
    Returns the Android SDK manager (sdkmanager) executable path.
#>
function Get-AndroidSdkManagerPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

    $sdkHome = Get-AndroidSdkHome -State $State
    if (-not $sdkHome) { return $null }

    $managerName = if ($script:IsWindows) { 'sdkmanager.bat' } else { 'sdkmanager' }
    $binDir = $script:AndroidSdkConfig.AndroidCmdLineToolsRelPath
    $managerPath = Join-Path (Join-Path $sdkHome $binDir) $managerName

    if (Test-Path $managerPath) { return $managerPath }
    return $null
}

<#
.SYNOPSIS
    Returns the platform-tools directory path.
#>
function Get-AndroidPlatformToolsDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

    $sdkHome = Get-AndroidSdkHome -State $State
    if (-not $sdkHome) { return $null }

    $ptDir = $script:AndroidSdkConfig.PlatformToolsDirName
    $ptPath = Join-Path $sdkHome $ptDir
    if (Test-Path $ptPath) { return $ptPath }
    return $null
}

# Export all provider functions
Export-ModuleMember -Function @(
    'Get-AndroidSdkHome',
    'Find-AdbPath',
    'Get-AdbDevices',
    'Invoke-AdbDeviceScan',
    'Get-AndroidSdkManagerPath',
    'Get-AndroidPlatformToolsDir',
    'Update-AndroidSdkProviderConfig'
)
