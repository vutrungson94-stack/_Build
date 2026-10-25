# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
# Nested import WITHOUT -Force (references the globally loaded Logging from the
# gbuild.ps1 bootstrap) — a nested -Force re-import orphans the global Logging
# module in PS 5.1, breaking Write-Log resolution.
Import-BuildModule -Dependencies @('BuildProgress', 'PathUtils', 'SharedUtils')
$pluginHelpersPath = Join-Path $PSScriptRoot 'Plugins/helpers/PluginHelpers.psm1'
if (Test-Path -LiteralPath $pluginHelpersPath) { $null = Import-Module $pluginHelpersPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'
Import-GBuildModuleIfMissing -Name 'PluginSDK' -SentinelCommand 'Get-PluginSdkApiVersion'

<#
.SYNOPSIS
    The manifest-file candidates used to resolve a ProjectFile for test/lint dispatch.
.DESCRIPTION
    SINGLE SOURCE. This list was a byte-identical 17-element array written out
    TWICE in this file (Invoke-PluginTestFor and Invoke-PluginLintFor) and was
    missing several files that shipped plugins declare: *.fsproj, *.vbproj,
    *.ps1, *.psm1, *.sln, setup.cfg, compose.yaml / compose.yml /
    docker-compose.*. That meant test/lint auto-dispatch could not resolve a
    project file for F#/VB.NET projects, script projects, setup.cfg-only Python
    projects, or solution-only repositories.
    Assembled from the registered plugins' own ManifestFiles when the plugin
    registry is populated, unioned with the language map, plus the loose
    per-file patterns that no plugin claims (needed for dispatch when no plugin
    is loaded yet).
#>
function Get-DispatchManifestFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

Set-StrictMode -Version 1.0
    $set = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $add = { param($items) foreach ($i in @($items)) { if ($null -ne $i) { $v = ([string]$i).Trim(); if ($v -and $seen.Add($v)) { $set.Add($v) } } } }
    # Baseline: the union of every shipped plugin's declared manifests.
    try {
        $pluginDir = Join-Path $PSScriptRoot 'Plugins'
        if (Test-Path -LiteralPath $pluginDir) {
            foreach ($p in @(Get-ChildItem -LiteralPath $pluginDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue)) {
                $src = $null; try { $src = Get-Content -LiteralPath $p.FullName -Raw -ErrorAction Stop } catch { }
                if (-not $src) { continue }
                $m = [regex]::Match($src, 'ManifestFiles\s*=\s*@\(([^)]*)\)')
                if (-not $m.Success) { continue }
                foreach ($f in @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })) { & $add $f }
            }
        }
    } catch { }
    if ($set.Count -eq 0) { & $add @('package.json','pyproject.toml','setup.py','setup.cfg','Cargo.toml','go.mod','pom.xml','build.gradle','build.gradle.kts','build.sbt','Gemfile','composer.json','CMakeLists.txt','Makefile','Package.swift','mix.exs','Dockerfile','*.csproj','*.fsproj','*.vbproj','*.sln','*.ps1','*.psm1','compose.yaml','compose.yml','docker-compose.yml','docker-compose.yaml') }
    return @($set.ToArray())
}

class PluginRegistry {    hidden [hashtable]$_plugins = @{}
    [void] Register([string]$name, [hashtable]$entry) { $this._plugins[$name] = $entry }
    [hashtable] Get([string]$name) { return $this._plugins[$name] }
    [hashtable[]] GetAll() { return @($this._plugins.Values) }
    [void] Clear() { $this._plugins.Clear() }
}
if (-not (Test-Path Variable:global:GBuildPluginRegistry)) {
    $global:GBuildPluginRegistry = [PluginRegistry]::new()
}
$script:PluginRegistry = $global:GBuildPluginRegistry

<#
.SYNOPSIS
    Runs a plugin scriptblock in the plugin's working directory with centralized output handling.
#>
# Invoke-PluginCommand was deleted: a [bool] projection of
# Invoke-PluginCommandResult. Every one of the 14 shipped plugins calls
# ...Result directly, so the wrapper was exported surface with no caller, and its
# existence implied a second entry point for running a plugin command.
<#
.SYNOPSIS
    Validates that a plugin module exports the required contract functions.
#>
function Test-PluginInterface {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$ModuleName,
        [PSCustomObject]$State
    )
    $mod = Get-Module -Name $ModuleName -ErrorAction SilentlyContinue
    if (-not $mod) {
        $mod = Get-Module | Where-Object { $_.Name -eq $ModuleName } | Select-Object -First 1
    }
    if (-not $mod) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractNotFound' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }

    # SINGLE SOURCE: IContract.Get-PluginContractFunctions. This block used to
    # keep a verbatim copy of the literal alongside the call - so the file
    # claimed single-source while still being a second encoding, and the
    # fallback silently reactivated exactly in the standalone-import case the
    # duplication was meant to survive.
    # IContract is not in Loader's bootstrap chain, so load it on demand (the
    # same way PluginSDK is handled above) rather than carrying a second copy.
    $required = @()
    if (-not (Get-Command Get-PluginContractFunctions -ErrorAction SilentlyContinue)) {
        $contractPath = Join-Path $PSScriptRoot 'IContract.psm1'
        if (Test-Path -LiteralPath $contractPath -PathType Leaf) {
            Import-Module $contractPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    try { if (Get-Command Get-PluginContractFunctions -ErrorAction SilentlyContinue) { $required = @(Get-PluginContractFunctions) } } catch { }
    if ($required.Count -eq 0) { Write-Log (Resolve-LogMessage -Key 'log.loader.contractUnavailable' -Fallback 'Plugin contract definition (IContract) is unavailable; cannot validate plugin interface') 'Err' $State; return $false }
    $missing = @()
    foreach ($fn in $required) {
        $cmd = Get-Command -Module $mod -Name $fn -ErrorAction SilentlyContinue
        if (-not $cmd) { $missing += $fn }
    }
    if ($missing.Count -gt 0) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractMissing' -MessageArgs $ModuleName, ($missing -join ', ')) 'Warn' $State
        return $false
    }

    try {
        $infoCmd = Get-Command -Module $mod -Name 'Get-PluginInfo'
        $info = & $infoCmd
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractThrew' -MessageArgs $ModuleName, $_) 'Warn' $State
        return $false
    }

    if (-not $info -or -not $info.PSObject.Properties['Name']) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractMissingName' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }
    if (-not $info.PSObject.Properties['SupportedLanguages'] -or -not ($info.SupportedLanguages -is [System.Collections.ICollection])) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractMissingLangs' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }
    if (-not $info.PSObject.Properties['Priority']) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractMissingPriority' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }

    # ── Behavioral contract checks ──
    if ($info.SupportedLanguages.Count -eq 0) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractEmptyLangs' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }
    foreach ($lang in $info.SupportedLanguages) {
        if ($lang -isnot [string] -or [string]::IsNullOrWhiteSpace($lang)) {
            Write-Log (Get-LocaleMessage -Key 'log.plugin.contractInvalidLangs' -MessageArgs $ModuleName) 'Warn' $State
            return $false
        }
    }
    $prio = $info.Priority
    if ($prio -isnot [int] -or $prio -lt 1 -or $prio -gt 10) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.contractInvalidPriority' -MessageArgs $ModuleName) 'Warn' $State
        return $false
    }

    # Each Invoke-* command must accept -ProjectDir and -State parameters
    foreach ($fn in @('Invoke-PluginBuild', 'Invoke-PluginTest', 'Invoke-PluginLint')) {
        $cmd = Get-Command -Module $mod -Name $fn -ErrorAction SilentlyContinue
        $paramNames = $cmd.Parameters.Keys
        if (-not ($paramNames -contains 'ProjectDir') -or -not ($paramNames -contains 'State')) {
            Write-Log (Get-LocaleMessage -Key 'log.plugin.contractInvalidSig' -MessageArgs $ModuleName, $fn) 'Warn' $State
            return $false
        }
    }

    return $true
}

<#
.SYNOPSIS
    Discovers and registers all plugin modules from the Plugins directory.
#>
<#
.SYNOPSIS
    Resolves environment-provided external plugin roots (marketplace).
.DESCRIPTION
    L5 marketplace (minimal): GBUILD_PLUGIN_PATH lists additional plugin
    directories separated by the OS path separator. Each entry must resolve
    to an existing container with no reparse point; anything else is skipped
    silently. Unset or empty -> @(), so default discovery is unchanged.
    Validation mirrors the containment helpers used by Steps/ (PathUtils when
    available, guarded fallbacks otherwise). PS 5.1-safe.
#>
function Get-ExternalPluginRoots {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $raw = [System.Environment]::GetEnvironmentVariable('GBUILD_PLUGIN_PATH')
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $sep = [System.IO.Path]::PathSeparator
    $roots = @()
    foreach ($part in @(([string]$raw).Split($sep))) {
        $p = ''
        try { $p = [string]$part } catch { $p = '' }
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = ''
        try { $full = [System.IO.Path]::GetFullPath($p.Trim()) } catch { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        $ok = $true
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
            try { $ok = Test-PathUnderRoots -Path $full -AllowedRoots @($full) } catch { $ok = $false }
        }
        if ($ok -and (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue)) {
            try { if (-not (Test-NoReparsePointInPath -Path $full)) { $ok = $false } } catch { $ok = $false }
        } elseif ($ok -and (Get-Command Test-ReparsePointItem -ErrorAction SilentlyContinue)) {
            try { if (Test-ReparsePointItem -Path $full) { $ok = $false } } catch { }
        }
        if (-not $ok) { continue }
        if ($roots -notcontains $full) { $roots += $full }
    }
    return $roots
}

function Register-Plugins {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $pluginDir = Join-Path $PSScriptRoot 'Plugins'
    if (-not (Test-Path $pluginDir)) { return }

    # Config-driven additional plugin directories (build.pluginDirs).
    # Each entry is resolved relative to ProjectRoot when not rooted.
    $extraDirs = @()
    $cfgPluginDirs = $null
    $cfgPluginDirsRaw = Get-ConfigValue -Path 'build.pluginDirs' -State $State
    if ($null -ne $cfgPluginDirsRaw) {
        $cfgPluginDirs = @($cfgPluginDirsRaw)
    } elseif ((Get-Command Get-BuildState -ErrorAction SilentlyContinue)) {
        $gs = Get-BuildState -State $State
        $cfgPluginDirsRaw = Get-ConfigValue -Path 'build.pluginDirs' -State $gs
        if ($null -ne $cfgPluginDirsRaw) {
            $cfgPluginDirs = @($cfgPluginDirsRaw)
        }
    }
    if ($cfgPluginDirs) {
        # Root-selection single-sourced in PathUtils.Get-BuildRootDirectory.
        # Level 5 resilience: inline fallback (ProjectRoot > ScriptRoot > cwd).
        $root = $null
        if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
            try { $root = Get-BuildRootDirectory -State $State } catch { $root = $null }
        }
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = if ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
        }
        foreach ($d in $cfgPluginDirs) {
            $resolved = if ([System.IO.Path]::IsPathRooted($d)) { $d } else { Join-Path $root $d }
            if (Test-Path $resolved) { $extraDirs += $resolved }
        }
    }

    $searchDirs = @($pluginDir) + $extraDirs
    # Marketplace: environment-provided roots join config-provided ones.
    # Additive only (env unset -> @() -> identical discovery as before).
    try {
        foreach ($er in @(Get-ExternalPluginRoots)) {
            if (-not [string]::IsNullOrWhiteSpace($er) -and $extraDirs -notcontains $er -and $searchDirs -notcontains $er) { $searchDirs += $er }
        }
    } catch { }
    $plugins = @()
    foreach ($dir in $searchDirs) {
        if (Test-Path $dir) {
            $plugins += Get-ChildItem -Path $dir -Filter '*.psm1' -File -ErrorAction SilentlyContinue
        }
    }
    # Formal SDK gate (PluginSDK.psm1): when available, pre-scan manifests so
    # version/compat/disabled policy applies BEFORE any module import, and so
    # dependency order is deterministic. Absent SDK (standalone) => legacy path.
    $useSdk = [bool](Get-Command Get-PluginManifest -ErrorAction SilentlyContinue)
    $sdkManifests = @{}
    $sdkCompat = @{}
    if ($useSdk) {
        foreach ($p in $plugins) {
            try {
                $mf = Get-PluginManifest -PluginPath $p.FullName -State $State
            } catch { $mf = $null }
            if ($null -eq $mf) { continue }
            $sdkManifests[$p.FullName] = $mf
            try {
                $sdkCompat[$p.FullName] = Test-PluginCompatibility -Manifest $mf -State $State
            } catch {
                $sdkCompat[$p.FullName] = @{ Compatible = $false; Reasons = @($_.Exception.Message); Manifest = $mf }
            }
        }
        # Dependency order: order the IMPORT sequence (not just registration) so
        # a plugin's Import-Module-time helper imports see their deps first.
        if (Get-Command Resolve-PluginDependencies -ErrorAction SilentlyContinue) {
            $depResult = Resolve-PluginDependencies -Manifests @($sdkManifests.Values)
            if ($depResult.Missing.Count -gt 0) {
                Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedContract' -MessageArgs ('dependencies: missing: ' + ($depResult.Missing -join ', '))) 'Warn' $State
            }
            if (-not $depResult.Valid) {
                foreach ($e in @($depResult.Errors)) {
                    Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedContract' -MessageArgs ('dependencies: ' + $e)) 'Warn' $State
                }
            }
            $orderByName = @{}
            $seq = 0
            foreach ($m in $depResult.Ordered) { $orderByName[[string]$m.name] = $seq; $seq++ }
            $plugins = @($plugins | Sort-Object -Property @{
                Expression = {
                    $mn = $null
                    if ($sdkManifests.ContainsKey($_.FullName)) { $mn = [string]$sdkManifests[$_.FullName].name }
                    if ($null -ne $mn -and $orderByName.ContainsKey($mn)) { return $orderByName[$mn] }
                    return 9999
                }
            }, @{ Expression = { $_.Name } })
        }
    }
    foreach ($p in $plugins) {
        try {
            # Anti-shadow: a plugin candidate claiming the name of an already
            # loaded CORE module (loaded from outside any Plugins dir, e.g. a
            # stale PathUtils.psm1 copy dropped into a plugin dir) would orphan
            # the global core module on PS 5.1 at the import below. Skip loudly
            # instead. Same-name reloads between two Plugins dirs (portable
            # copies) still proceed to the Remove-Module below as before.
            $shadowed = Get-Module -Name $p.BaseName -ErrorAction SilentlyContinue
            if ($shadowed -and $shadowed.Path -and ($shadowed.Path -ne $p.FullName) -and ($shadowed.Path -notmatch '[\\/]Plugins[\\/]')) {
                Write-Log (Resolve-LogMessage -Key 'log.plugin.nameCollision' -MessageArgs @([string]$p.Name, $shadowed.Path) -Fallback '[PLUGIN] Skipped ''{0}'': name collides with loaded core module from {1}') 'Warn' $State
                continue
            }
            # Drop any previously-loaded copy of this plugin first so two portable
            # _Build copies in one session cannot shadow each other's functions.
            Remove-Module -Name $p.BaseName -ErrorAction SilentlyContinue
            # Import WITHOUT -Global so functions stay in module scope (avoids name collisions across plugins)
            Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop
            $mod = Get-Module -Name $p.BaseName -ErrorAction SilentlyContinue
            if (-not $mod) {
                $mod = Get-Module | Where-Object { $_.Path -eq $p.FullName } | Select-Object -First 1
            }
            # Non-plugin helper modules (e.g. *Helpers.psm1) are shared internals, not
            # plugins. Skip them quietly instead of flagging an "invalid contract",
            # which would be misleading noise on every build.
            if (-not $mod -or -not (Get-Command -Module $mod -Name 'Get-PluginInfo' -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedHelper' -MessageArgs $p.Name) 'Verbose' $State
                continue
            }
            $info = Get-PluginInfo
            if (-not (Test-PluginInterface -ModuleName $p.BaseName -State $State)) {
                Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedContract' -MessageArgs $p.Name) 'Warn' $State
                continue
            }
            # Formal SDK compatibility gate: manifest (sidecar or synthesized)
            # + semver policy (disabled/allowList/apiVersion/gbuild window).
            # Runs AFTER the legacy contract check so old error messages stay
            # stable; a rejection here unloads the module to keep state clean.
            if ($useSdk -and $sdkCompat.ContainsKey($p.FullName)) {
                $cc = $sdkCompat[$p.FullName]
                # Refresh the manifest merge now that live Get-PluginInfo ran
                # inside the imported module scope (picks up real languages).
                try {
                    if (Get-Command Get-PluginManifest -ErrorAction SilentlyContinue) {
                        $live = Get-PluginManifest -PluginPath $p.FullName -PluginInfo $info -State $State
                        if ($null -ne $live) {
                            $sdkManifests[$p.FullName] = $live
                            if (Get-Command Test-PluginCompatibility -ErrorAction SilentlyContinue) {
                                $cc = Test-PluginCompatibility -Manifest $live -State $State
                                $sdkCompat[$p.FullName] = $cc
                            }
                        }
                    }
                } catch { }
                if (-not $cc.Compatible) {
                    foreach ($r in @($cc.Reasons)) {
                        Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedContract' -MessageArgs ($p.Name + ': ' + $r)) 'Warn' $State
                    }
                    Remove-Module -Name $p.BaseName -ErrorAction SilentlyContinue
                    continue
                }
                # Stamp the resolved version onto the registry entry so
                # Get-RegisteredPlugins consumers can report/audit it.
                 $mfFinal = $sdkManifests[$p.FullName]
                if ($null -ne $mfFinal) {
                    # Capability truth: a verb is implemented when the plugin
                    # defines the $script:Custom* override OR BasePlugin's
                    # metadata-driven default is usable (a real command for the
                    # verb, or the always-on preflight fallback). Dot-sourcing
                    # BasePlugin gives every module all six Invoke-Plugin*
                    # functions regardless of metadata completeness, so the old
                    # Get-Command comparison could never fail.
                    $overrideVars = try { @(& $mod { Get-Variable -Scope Script -Name 'Custom*' | ForEach-Object { $_.Name } }) } catch { @() }
                    $metadata = $null
                    try { $metadata = & $mod { Get-PluginMetadata } } catch { $metadata = $null }
                    $verbToField = @{ build='BuildCommand'; test='TestCommand'; lint='LintCommand'; clean='CleanCommand'; run='RunCommand' }
                    $overrideToCap = @{ CustomBuild = 'build'; CustomTest = 'test'; CustomLint = 'lint'; CustomPreflight = 'preflight'; CustomClean = 'clean'; CustomRun = 'run' }
                    $actualList = @('preflight')  # Get-BasePluginPreflight is always available
                    foreach ($ov in $overrideVars) { if ($overrideToCap.ContainsKey($ov)) { $actualList += $overrideToCap[$ov] } }
                    if ($metadata) {
                        foreach ($cap in $verbToField.Keys) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$metadata[$verbToField[$cap]])) { $actualList += $cap }
                        }
                    }
                    $actualCapabilities = @($actualList | Sort-Object -Unique)
                    $declaredCapabilities = @($mfFinal.capabilities | Where-Object { $_ })
                    if ($declaredCapabilities.Count -gt 0) {
                        # One-way contract: every verb the manifest ADVERTISES must
                        # be implemented. The reverse is not a violation — a plugin
                        # may keep clean/run available for GetConfig consumers
                        # without advertising them in $manifest.capabilities.
                        $missing = @($declaredCapabilities | Where-Object { $actualCapabilities -notcontains $_ })
                        if ($missing.Count -gt 0) {
                            Write-Log (Get-LocaleMessage -Key 'log.plugin.skippedContract' -MessageArgs ($p.Name + ': manifest advertises unimplemented verbs: ' + ($missing -join ','))) 'Warn' $State
                            Remove-Module -Name $p.BaseName -ErrorAction SilentlyContinue
                            continue
                        }
                    }
                    if ($info.PSObject.Properties.Name -contains 'Version') { $info.Version = [string]$mfFinal.version }
                    else { $info | Add-Member -MemberType NoteProperty -Name 'Version' -Value ([string]$mfFinal.version) -Force }
                    if ($info.PSObject.Properties.Name -contains 'ApiVersion') { $info.ApiVersion = [string]$mfFinal.apiVersion }
                    else { $info | Add-Member -MemberType NoteProperty -Name 'ApiVersion' -Value ([string]$mfFinal.apiVersion) -Force }
                }
            }
            # Store module object; functions will be invoked via module scope: & $mod { FunctionName ... }
            $script:PluginRegistry.Register($info.Name, @{
                Info     = $info
                Module   = $mod
                Path     = $p.FullName
            })
            $verSuffix = ''
            if ($info.PSObject.Properties.Name -contains 'Version' -and $info.Version) { $verSuffix = (' v{0}' -f $info.Version) }
            Write-Log (Get-LocaleMessage -Key 'log.plugin.loaded' -MessageArgs ($info.Name + $verSuffix), ($info.SupportedLanguages -join ', ')) 'Succ' $State
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_PLUGIN_LOADED -Source $State -Data @{ Name = $info.Name; Languages = ($info.SupportedLanguages -join ',') } | Out-Null
            }
        } catch {
            Write-Log (Get-LocaleMessage -Key 'log.plugin.failedToLoad' -MessageArgs $p.Name, $_) 'Warn' $State
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_PLUGIN_ERROR -Source $State -Data @{ Name = $p.Name; Error = "$_" } | Out-Null
            }
        }
    }
    $loaded = Get-RegisteredPlugins
    if ($loaded) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.totalRegistered' -MessageArgs $loaded.Count) 'Info' $State
    }
}

<#
.SYNOPSIS
    Returns all registered plugin info objects, ordered by priority.
#>
function Get-RegisteredPlugins {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()
    return $script:PluginRegistry.GetAll() | ForEach-Object { $_.Info } | Sort-Object Priority
}

<#
.SYNOPSIS
    Resolves the highest-priority plugin supporting a given language.
.DESCRIPTION
    Honors build.pluginDispatch.enabled=false by returning $null (dispatch
    disabled) so callers fall back to the .NET path. Level 5: the key is now
    read (was orphan) via Get-BuildConstant with config-first resolution.
#>
function Resolve-PluginForLanguage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Language)
    # Config-driven language overrides (build.pluginDispatch.languageOverrides) let
    # users route e.g. 'C#' -> 'Avalonia' so the Avalonia plugin is reachable for
    # .NET csproj projects the LanguageDetector reports as 'C#'.
    $gs = Get-BuildState -ErrorAction SilentlyContinue
    $dispatchEnabled = $true
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $dispatchEnabled = [bool](Get-BuildConstant -Key 'PluginDispatchEnabled' -State $gs -Fallback $true)
        } else {
            $dispatchEnabled = [bool](Get-ConfigValue -Path 'build.pluginDispatch.enabled' -State $gs -Default $true)
        }
    } catch { $dispatchEnabled = $true }
    if (-not $dispatchEnabled) { return $null }
    $lang = $Language
    $overrides = Get-ConfigValue -Path 'build.pluginDispatch.languageOverrides' -State $gs
    if ($overrides -and ($overrides.PSObject.Properties.Name -contains $Language)) {
        $mapped = $overrides.$Language
        if (-not [string]::IsNullOrWhiteSpace([string]$mapped)) { $lang = [string]$mapped }
    }
    $sorted = $script:PluginRegistry.GetAll() | Sort-Object { $_.Info.Priority }
    foreach ($entry in $sorted) {
        if ($lang -in $entry.Info.SupportedLanguages) {
            return $entry
        }
    }
    return $null
}

<#
.SYNOPSIS
    Runs plugin preflight validation for a language if available.
.DESCRIPTION
    Calls Invoke-PluginPreflight on the matching plugin. Returns a result
    hashtable with Passed, Errors, Warnings. Falls back gracefully if the
    plugin does not implement preflight.
#>
function Invoke-PreflightForLanguage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectFile = ''
    )
    $entry = Resolve-PluginForLanguage -Language $Language
    if (-not $entry) {
        # Was the bare string 'No plugin for language', which also DROPPED $Language
        # - the one piece of information needed to fix it. These messages shipped
        # translated in all 7 locales and were never used.
        return @{ Passed = $true; Errors = @(); Warnings = @((Get-LocaleMessage -Key 'log.plugin.noPluginForLang' -MessageArgs @($Language))); Skipped = $true }
    }
    $mod = $entry.Module
    if (-not $mod) {
        return @{ Passed = $true; Errors = @(); Warnings = @((Get-LocaleMessage -Key 'log.plugin.moduleNotLoaded' -MessageArgs @($Language))); Skipped = $true }
    }
    try {
        # Invoke function in module scope to avoid global name collisions
        $result = & $mod { param($s,$d,$f) Invoke-PluginPreflight -State $s -ProjectDir $d -ProjectFile $f } $State $ProjectDir $ProjectFile
        if ($null -eq $result) { return @{ Passed = $true; Errors = @(); Warnings = @(); Skipped = $false } }
        if ($result -is [bool]) { return @{ Passed = $result; Errors = @(); Warnings = @(); Skipped = $false } }
        if ($result -is [hashtable]) { return $result }
        return @{ Passed = $true; Errors = @(); Warnings = @('Unexpected preflight result type'); Skipped = $false }
    } catch {
        return @{ Passed = $false; Errors = @($_.Exception.Message); Warnings = @(); Skipped = $false }
    }
}

function Resolve-PluginDispatchContext {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string[]]$ManifestFiles = @()
    )
    if ($ProjectFile -and (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
        $ProjectDir = Split-Path -Parent $ProjectFile
    }
    if ([string]::IsNullOrWhiteSpace($ProjectDir) -and $State) {
        if ($State.PSObject.Properties.Name -contains 'ExplicitProject' -and $State.ExplicitProject) {
            $candidate = [string]$State.ExplicitProject
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $ProjectFile = $candidate; $ProjectDir = Split-Path -Parent $candidate }
            elseif (Test-Path -LiteralPath $candidate -PathType Container) { $ProjectDir = $candidate }
        }
        if ([string]::IsNullOrWhiteSpace($ProjectDir) -and ($State.PSObject.Properties.Name -contains 'ProjectRoot')) { $ProjectDir = [string]$State.ProjectRoot }
    }
    if ([string]::IsNullOrWhiteSpace($ProjectFile) -and $ProjectDir -and (Get-Command Resolve-PluginManifest -ErrorAction SilentlyContinue)) {
        $ProjectFile = [string](Resolve-PluginManifest -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles)
    }
    if ($ProjectDir) { try { $ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir) } catch { } }
    return [PSCustomObject]@{ ProjectDir = $ProjectDir; ProjectFile = $ProjectFile }
}

function Resolve-PluginDispatchConfiguration {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Configuration = '')
    if (-not [string]::IsNullOrWhiteSpace($Configuration)) { return $Configuration }
    $resolved = $null
    try { $resolved = [string](Get-BuildConstant -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } catch { $resolved = 'Release' }
    try {
        if ($State -and $State.PSObject.Properties.Name -contains 'ActiveProfile' -and $State.ActiveProfile -and $State.BuildConfig -and $State.BuildConfig.profiles) {
            $profile = $State.BuildConfig.profiles.($State.ActiveProfile)
            if ($profile -and $profile.PSObject.Properties.Name -contains 'configuration' -and $profile.configuration) { $resolved = [string]$profile.configuration }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'Release' }
    return $resolved
}

function Invoke-PluginActionInModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][string]$CommandName,
        [PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [string]$Arguments = '',
        [switch]$Detailed
    )
    $body = {
        param($s, $d, $f, $c, $i, $a, $det, $name)
        $cmd = Get-Command -Name $name -ErrorAction Stop
        $params = @{}
        if ($cmd.Parameters.ContainsKey('State')) { $params.State = $s }
        if ($cmd.Parameters.ContainsKey('ProjectDir')) { $params.ProjectDir = $d }
        if ($cmd.Parameters.ContainsKey('ProjectFile')) { $params.ProjectFile = $f }
        if ($cmd.Parameters.ContainsKey('Configuration')) { $params.Configuration = $c }
        if ($cmd.Parameters.ContainsKey('Incremental')) { $params.Incremental = $i }
        if ($cmd.Parameters.ContainsKey('Arguments')) { $params.Arguments = $a }
        if ($cmd.Parameters.ContainsKey('Detailed') -and $det) { $params.Detailed = $true }
        & $cmd @params
    }
    return (& $Module $body $State $ProjectDir $ProjectFile $Configuration $Incremental $Arguments $Detailed $CommandName)
}

function ConvertTo-PluginDispatchResult {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [string]$Operation)
    if (Get-Command ConvertTo-PluginActionResult -ErrorAction SilentlyContinue) {
        return ConvertTo-PluginActionResult -Value $Value -Operation $Operation
    }
    return ConvertTo-OperationResult -Value $Value -Operation $Operation
}

function Get-PluginDispatchOutputPath {
    [CmdletBinding()]
    param([object]$Result, [PSCustomObject]$State, [string]$ProjectDir)
    $path = [string](Get-PluginObjectValue -Object $Result -Name 'OutputPath' -Default '')
    if ($path) { return $path }
    $details = Get-PluginObjectValue -Object $Result -Name 'Details' -Default $null
    $path = [string](Get-PluginObjectValue -Object $details -Name 'OutputPath' -Default '')
    if ($path) { return $path }
    if (Get-Command Resolve-PluginOutputDir -ErrorAction SilentlyContinue) {
        $candidate = Resolve-PluginOutputDir -State $State -ProjectDir $ProjectDir
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { return $candidate }
    }
    return ''
}

<#
.SYNOPSIS
    Invokes the build action of the plugin matching the given language.
#>
function Invoke-PluginBuildFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [Parameter(Mandatory)] [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $operation = "plugin.build:$Language"
    try {
        $context = Resolve-PluginDispatchContext -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
        $ProjectDir = [string]$context.ProjectDir
        $ProjectFile = [string]$context.ProjectFile
        $Configuration = Resolve-PluginDispatchConfiguration -State $State -Configuration $Configuration
        $plugin = Resolve-PluginForLanguage -Language $Language
        if (-not $plugin) {
            $fallbackToDotnet = [bool](Get-ConfigValue -Path 'build.pluginDispatch.fallbackToDotnet' -State $State -Type bool)
            if ($fallbackToDotnet) { $plugin = Resolve-PluginForLanguage -Language 'C#' }
            if (-not $plugin) {
                $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'PluginNotFound' -Message "No plugin is available for '$Language'" -ExitCode 127
                if ($Detailed) { return $result }
                return $false
            }
        }
        $mod = $plugin.Module
        if (-not $mod) {
            $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'ModuleNotLoaded' -Message "Plugin module is not loaded for '$Language'" -ExitCode 127
            if ($Detailed) { return $result }
            return $false
        }
        $hasBuild = & $mod { Get-Command -Name 'Invoke-PluginBuild' -ErrorAction SilentlyContinue }
        if (-not $hasBuild) {
            $result = New-OperationResult -Status Skipped -Operation $operation -ReasonCode 'CommandNotFound' -Message "Invoke-PluginBuild is not available for '$Language'" -ExitCode 127
            if ($Detailed) { return $result }
            return $false
        }
        $inputHash = Get-PluginInputHash -ProjectDir $ProjectDir -ProjectFile $ProjectFile
        $cacheKey = Get-PluginCacheKey -Plugin $plugin -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -InputHash $inputHash
        if ($Incremental -and $inputHash -and (Get-Command Test-CacheValid -ErrorAction SilentlyContinue)) {
            try {
                if (Get-Command Initialize-BuildCache -ErrorAction SilentlyContinue) { $null = Initialize-BuildCache -State $State }
                if (Test-CacheValid -Key $cacheKey -ProjectHash $inputHash) {
                    $entry = Get-CacheEntry -Key $cacheKey
                    $output = ''
                    if ($entry) { $output = [string]$entry.OutputPath }
                    $hasOutput = $false
                    if ($output -and (Test-Path -LiteralPath $output -PathType Leaf)) { $hasOutput = $true }
                    elseif ($output -and (Test-Path -LiteralPath $output -PathType Container)) { $hasOutput = @(Get-ChildItem -LiteralPath $output -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0 }
                    if ($hasOutput) {
                        $result = New-OperationResult -Status Succeeded -Operation $operation -ReasonCode 'CacheHit' -Message 'Build cache hit' -Details $entry
                        $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $output -Force
                        if ($Detailed) { return $result }
                        return $true
                    }
                    if (Get-Command Remove-CacheEntry -ErrorAction SilentlyContinue) { Remove-CacheEntry -Key $cacheKey -ErrorAction SilentlyContinue }
                }
            } catch { }
        }
        try {
            $rawResult = Invoke-PluginActionInModule -Module $mod -CommandName 'Invoke-PluginBuild' -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed
        } catch {
            $result = New-OperationResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $_.Exception.Message -ExitCode 1 -Details $_
            if ($Detailed) { return $result }
            return $false
        }
        $result = ConvertTo-PluginDispatchResult -Value $rawResult -Operation $operation
        if ($result.Status -eq 'Succeeded' -and $inputHash -and (Get-Command Save-CacheEntry -ErrorAction SilentlyContinue)) {
            $output = Get-PluginDispatchOutputPath -Result $result -State $State -ProjectDir $ProjectDir
            $metadata = @{ CacheKey = $cacheKey; Configuration = $Configuration; ProjectPath = $(if ($ProjectFile) { $ProjectFile } else { $ProjectDir }) }
            Save-CacheEntry -Key $cacheKey -ProjectHash $inputHash -OutputPath $output -Metadata $metadata | Out-Null
        }
        if ($Detailed) { return $result }
        return ($result.Status -eq 'Succeeded')
    } catch {
        $result = New-OperationResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $_.Exception.Message -ExitCode 1 -Details $_
        if ($Detailed) { return $result }
        return $false
    }
}

<#
.SYNOPSIS
    Single dispatch skeleton for the Test/Lint/Clean/Run plugin actions.
.DESCRIPTION
    The four Invoke-Plugin{Test,Lint,Clean,Run}For bodies were the same 12-step
    skeleton written four times (resolve context -> resolve config -> resolve
    plugin -> Get-Command probe -> Skipped/PluginNotFound -> Skipped/CommandNotFound
    -> Invoke-PluginActionInModule -> ConvertTo-PluginDispatchResult -> Detailed
    branch -> bool branch -> catch -> Failed/Exception). Only the verb, the
    command name, and two flags differed. This function owns the skeleton; the
    four public names stay as thin wrappers so every existing call site and
    plugin contract keeps resolving.

    KNOWN DIVERGENCE (surfaced by the merge, preserved, not papered over):
    Test and Lint pass -ManifestFiles to Resolve-PluginDispatchContext while
    Clean and Run do not, and Test/Lint forward -Incremental while Clean/Run
    never pass it and only Run forwards -Arguments. Those differences are kept
    byte-for-byte identical here via -WithManifestFiles / -PassIncremental /
    -PassArguments; unifying them is a behaviour change that belongs in its
    own review, not in a DRY refactor.

    RETURNS: operation result when -Detailed, else $true/$false.
#>
function Invoke-PluginActionFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [ValidateSet('Test', 'Lint', 'Clean', 'Run')] [string]$Verb,
        [Parameter(Mandatory)] [string]$Language,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Arguments = '',
        [switch]$Incremental,
        [switch]$WithManifestFiles,
        [switch]$PassIncremental,
        [switch]$PassArguments,
        [switch]$Detailed
    )
    $verbLower = $Verb.ToLowerInvariant()
    $commandName = 'Invoke-Plugin{0}' -f $Verb
    $operation = 'plugin.{0}:{1}' -f $verbLower, $Language
    # Whether the caller supplied -ProjectFile explicitly. The dispatch
    # context below may AUTO-resolve one from the global manifest union;
    # that auto result is re-resolved per-plugin further down and must not
    # be treated as user intent.
    $explicitProjectFile = -not [string]::IsNullOrWhiteSpace($ProjectFile)
    try {
        if ($WithManifestFiles) {
            $context = Resolve-PluginDispatchContext -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -ManifestFiles $(Get-DispatchManifestFiles)
        } else {
            $context = Resolve-PluginDispatchContext -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
        }
        $ProjectDir = [string]$context.ProjectDir
        $ProjectFile = [string]$context.ProjectFile
        $Configuration = Resolve-PluginDispatchConfiguration -State $State -Configuration $Configuration
        $plugin = Resolve-PluginForLanguage -Language $Language
        if (-not $plugin -or -not $plugin.Module) {
            $result = New-OperationResult -Status Skipped -Operation $operation -ReasonCode 'PluginNotFound' -Message ("No {0} implementation is available for '{1}'" -f $verbLower, $Language) -ExitCode 127
            if ($Detailed) { return $result }
            return $false
        }
        if (-not $explicitProjectFile -and $WithManifestFiles -and $plugin.Info) {
            # Per-plugin manifest resolution. The dispatch context above
            # resolves ONE ProjectFile from the GLOBAL manifest union (first
            # match wins), so in a multi-manifest tree (package.json +
            # Dockerfile) every language plugin received the same foreign
            # file and rejected it: Resolve-PluginManifest returns $null for
            # an explicit-but-foreign file without scanning ProjectDir,
            # failing Test/Lint with a bogus ManifestMissing even though the
            # plugin's own manifest exists. Re-resolve with THIS plugin's
            # manifest list; fall back to '' so the plugin scans ProjectDir
            # itself instead of choking on a foreign file.
            try {
                $pluginManifests = @($plugin.Info.ManifestFiles | Where-Object { $_ })
                if ($pluginManifests.Count -gt 0 -and $ProjectDir -and (Get-Command Resolve-PluginManifest -ErrorAction SilentlyContinue)) {
                    $perPluginFile = [string](Resolve-PluginManifest -ProjectDir $ProjectDir -ManifestFiles $pluginManifests)
                    $ProjectFile = if ($perPluginFile) { $perPluginFile } else { '' }
                }
            } catch { }
        }
        $mod = $plugin.Module
        # $using: does NOT work here (it is only for remoting/jobs/parallel);
        # build the probe scriptblock with the verb baked in. $commandName
        # comes from a ValidateSet, so this cannot inject.
        $probe = [scriptblock]::Create("Get-Command -Name '$commandName' -ErrorAction SilentlyContinue")
        $hasFn = & $mod $probe
        if (-not $hasFn) {
            $result = New-OperationResult -Status Skipped -Operation $operation -ReasonCode 'CommandNotFound' -Message ('{0} is not available for ''{1}''' -f $commandName, $Language) -ExitCode 127
            if ($Detailed) { return $result }
            return $false
        }
        # Flags are forwarded only for the verbs that forwarded them before the
        # merge: -Incremental for Test/Lint, -Arguments for Run. Clean never
        # received either, so forwarding -Incremental:$false/-Arguments '' to a
        # Clean command that happens to declare such a parameter would silently
        # change a call that previously omitted it.
        if ($PassIncremental -and $PassArguments) {
            $rawResult = Invoke-PluginActionInModule -Module $mod -CommandName $commandName -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Arguments $Arguments -Detailed
        } elseif ($PassIncremental) {
            $rawResult = Invoke-PluginActionInModule -Module $mod -CommandName $commandName -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed
        } elseif ($PassArguments) {
            $rawResult = Invoke-PluginActionInModule -Module $mod -CommandName $commandName -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Arguments $Arguments -Detailed
        } else {
            $rawResult = Invoke-PluginActionInModule -Module $mod -CommandName $commandName -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Detailed
        }
        $result = ConvertTo-PluginDispatchResult -Value $rawResult -Operation $operation
        if ($Detailed) { return $result }
        return ($result.Status -eq 'Succeeded')
    } catch {
        $result = New-OperationResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $_.Exception.Message -ExitCode 1 -Details $_
        if ($Detailed) { return $result }
        return $false
    }
}

<#
.SYNOPSIS
    Invokes the test action of the plugin matching the given language.
#>
function Invoke-PluginTestFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    Invoke-PluginActionFor -State $State -Verb Test -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -WithManifestFiles -PassIncremental -Detailed:$Detailed
}

<#
.SYNOPSIS
    Invokes the lint action of the plugin matching the given language.
#>
function Invoke-PluginLintFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    Invoke-PluginActionFor -State $State -Verb Lint -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -WithManifestFiles -PassIncremental -Detailed:$Detailed
}

<#
.SYNOPSIS
    Dispatches optional Invoke-PluginClean (P3). Missing plugin/fn returns
    $false and, with -Detailed, a Skipped result (the old "returns $true"
    comment was stale: the code always returned $false here).
#>
function Invoke-PluginCleanFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Detailed
    )
    Invoke-PluginActionFor -State $State -Verb Clean -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Detailed:$Detailed
}

<#
.SYNOPSIS
    Dispatches optional Invoke-PluginRun (P3). Missing plugin/fn/command = $false graceful.
#>
function Invoke-PluginRunFor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Arguments = '',
        [switch]$Detailed
    )
    Invoke-PluginActionFor -State $State -Verb Run -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Arguments $Arguments -PassArguments -Detailed:$Detailed
}

<#
.SYNOPSIS
    Safe wrapper around Invoke-PluginBuildFor with try/catch + fallback.
#>
function Invoke-PluginBuildSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Language,
        [Parameter(Mandatory)] [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$FallbackLanguage = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $primary = $null
    try {
        $primaryRaw = Invoke-PluginBuildFor -State $State -Language $Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed
        $primary = ConvertTo-PluginDispatchResult -Value $primaryRaw -Operation "plugin.build:$Language"
    } catch {
        $primary = New-OperationResult -Status Failed -Operation "plugin.build:$Language" -ReasonCode 'Exception' -Message $_.Exception.Message -ExitCode 1 -Details $_
    }
    if ($primary.Status -eq 'Succeeded') {
        if ($Detailed) { return $primary }
        return $true
    }
    if (-not $FallbackLanguage) {
        if ($Detailed) { return $primary }
        return $false
    }
    # The fallback was previously entirely silent. A language falling back to a
    # different toolchain is a real behavioural change - different compiler,
    # different output - so it is now announced before and after the attempt.
    if ($State -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.retryingFallback' -MessageArgs @($FallbackLanguage)) 'Gray' $State
    }
    $fallback = $null
    try {
        $fallbackRaw = Invoke-PluginBuildFor -State $State -Language $FallbackLanguage -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed
        $fallback = ConvertTo-PluginDispatchResult -Value $fallbackRaw -Operation "plugin.build:$FallbackLanguage"
    } catch {
        $fallback = New-OperationResult -Status Failed -Operation "plugin.build:$FallbackLanguage" -ReasonCode 'Exception' -Message $_.Exception.Message -ExitCode 1 -Details $_
    }
    if (($fallback.Status -ne 'Succeeded') -and $State -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.plugin.fallbackFailed' -MessageArgs @($FallbackLanguage, [string]$fallback.Message)) 'DarkYellow' $State
    }
    if ($Detailed) { return $fallback }
    return ($fallback.Status -eq 'Succeeded')
}

Export-ModuleMember -Function @(
    'Register-Plugins', 'Get-RegisteredPlugins', 'Resolve-PluginForLanguage',
    'Invoke-PluginBuildFor', 'Invoke-PluginActionFor', 'Invoke-PluginTestFor', 'Invoke-PluginLintFor', 'Resolve-PluginDispatchConfiguration',
    'Invoke-PluginCleanFor', 'Invoke-PluginRunFor',
    'Invoke-PluginCommandResult', 'Invoke-PluginBuildSafe', 'Invoke-PreflightForLanguage',
    'Get-PluginDispatchOutputPath', 'Get-ExternalPluginRoots'
)


