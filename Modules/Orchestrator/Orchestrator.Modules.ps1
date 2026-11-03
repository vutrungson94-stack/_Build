# ============================================================================
# Orchestrator.Modules.ps1 - module helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Import-ModuleOnDemand {
    [CmdletBinding()]
    param([string[]]$ModuleNames)

Set-StrictMode -Version 1.0
    foreach ($name in $ModuleNames) {
        # PSScriptRoot is Modules/Orchestrator since the split; sibling modules
        # live one level up. If this file is ever dot-sourced straight from
        # Modules/ root again, Orchestrator.psm1 sits next to it.
        $modulesDir = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.psm1') -PathType Leaf) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
        $path = Join-Path $modulesDir "$name.psm1"
        # Providers live in Modules/Providers/ - resolve there as fallback so
        # on-demand loads of provider modules never silently no-op.
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $provPath = Join-Path (Join-Path $modulesDir 'Providers') "$name.psm1"
            if (Test-Path -LiteralPath $provPath -PathType Leaf) { $path = $provPath }
        }
        if (-not (Test-Path $path)) { continue }
        $loaded = Get-Module -Name $name -ErrorAction SilentlyContinue
            # A same-named module already imported from a DIFFERENT _Build copy
            # (e.g. <other-root>\_Build_old loaded earlier in this host) would otherwise
        # shadow the active copy. Re-import the active one so every run uses THIS
        # _Build's modules and state (mirrors the session-isolation purge in gbuild.ps1).
        if ($loaded -and (($loaded.Path -and $loaded.Path -ne $path) -or -not $loaded.Path)) {
            Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
            $loaded = $null
        }
        if ($loaded) { continue }
        if (Test-Path $path) {
            # -Global so the on-demand module's exports are visible to whichever
            # module invokes it (same cross-module visibility fix as Tier-1).
            Import-Module $path -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
}

<#
    .SYNOPSIS
        Validates gbuild.config.json against its JSON schema.
    .DESCRIPTION
        Loads the config file and schema, then runs Test-Json for validation.
        Falls back gracefully if Test-Json cmdlet is unavailable.
    .PARAMETER State
        Global state object with ConfigPath and BuildConfig.
    .OUTPUTS
        [bool] $true if validation passes or cannot be performed, $false on failure.
    #>

function Get-ModuleMapFromConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)

    if (-not $State) { return @{} }
    if (-not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.menu -or -not $State.BuildConfig.build.menu.moduleMap) {
        # No map on this State. Deliberately NOT an error here.
        #
        # Invoke-GuildChoice is also called programmatically, and with a
        # synthetic or partially-built State that carries no config at all - the
        # test suite does exactly this. A caller that passed -MenuConfig
        # explicitly has already declared what the menu is, so demanding the
        # module map of it would be imposing a requirement the caller never
        # made.
        #
        # The case that MUST be loud - a real build whose config failed to load,
        # leaving eight load-path-only modules unreachable - is owned by
        # Test-BuildMenuModuleMap, which Start-GBuild calls once at startup and
        # which fails with the specific missing section. Fixing it here instead
        # would have broken every programmatic caller to defend against a
        # failure mode that is already caught earlier and better.
        return @{}
    }

    $cfgMap = $State.BuildConfig.build.menu.moduleMap
    $result = @{}
    if (-not $cfgMap) { return @{} }
    foreach ($key in $cfgMap.PSObject.Properties.Name) {
        $val = $cfgMap.$key
        if ($val -is [array]) { $result[$key] = @($val) }
        elseif ($val -is [string]) { $result[$key] = @($val) }
        else { $result[$key] = @() }
    }
    return $result
}

<#
.SYNOPSIS
    Loads default build actions per project type from config (build.menu.defaultActions) with hardcoded fallback.
.DESCRIPTION
    Reads build.menu.defaultActions from gbuild.config.json. Each entry maps a project type
    to a menu choice key. For MAUI, supports conditional selection based on TFM:
      { "androidTfm": "2", "windowsTfm": "8", "default": "12" }
    Falls back to built-in defaults if config is absent or incomplete.
.PARAMETER State
    The build state object carrying BuildConfig.
.OUTPUTS
    Hashtable mapping project type names to menu choice keys or scriptblocks for conditional logic.
#>

function Test-BuildMenuModuleMap {
    <#
    .SYNOPSIS
        Fails a build whose menu module map cannot load its load-path-only modules.
    .DESCRIPTION
        build.menu.moduleMap is the ONLY place eight modules are named for
        loading: Build, Deploy, Android, Chaos, ClusterOrchestrator,
        HealthCheck, HotReload and Documentation appear in no
        Import-ModuleOnDemand call anywhere in the codebase. They are reachable
        through this one config table and nothing else.

        That makes a config typo a silent capability loss. If the section is
        missing, renamed, or an entry names a module that does not ship, the
        old behaviour was that the menu entry still rendered, the choice was
        still accepted, and the target then did nothing - the user saw a build
        that reported success having built nothing.

        Called once from Start-GBuild, before any target runs, so the failure is
        attributed to the cause rather than to whichever target happened to trip
        over it later.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)

    $sections = @('build','menu','moduleMap')
    # The walk starts at BuildConfig, NOT at $State. $State is a runtime object
    # that CARRIES the config. Walking $State for build/menu/moduleMap falsely
    # reported a missing map on EVERY valid build, which is a stricter failure
    # than the gate exists to enforce and a green build of zero work is less
    # wrong than a red build of a working tree. Recorded as lesson 1 in the log.
    $node = if ($State -and $State.PSObject.Properties['BuildConfig'] -and $State.BuildConfig) { $State.BuildConfig } else { $null }
    $reached = @()
    foreach ($s in $sections) {
        if ($null -eq $node) { break }
        $p = $node.PSObject.Properties[$s]
        if ($null -eq $p -or $null -eq $p.Value) { break }
        $reached += $s
        $node = $p.Value
    }
    if ($reached.Count -lt $sections.Count) {
        $reachedLabel = if ($reached.Count) { $reached -join ' -> ' } else { 'State' }
        # Routed through the locale layer. This is a build-STARTUP failure, i.e.
        # the first thing a user sees on a broken install, so it must not be one
        # of the English-only emit sites ProcessMetrics counts against
        # i18nProseCoverage.
        $msg = Get-LocaleMessage -Key 'log.orch.moduleMapMissing' -MessageArgs @($reachedLabel)
        throw $msg
    }

    # Every named module must exist, and the load-path-only set must be covered.
    $loadPathOnly = @('Build','Deploy','Android','Chaos','ClusterOrchestrator','HealthCheck','HotReload','Documentation')
    $named = New-Object System.Collections.Generic.List[string]
    $missingFiles = @()
    $modulesRoot = $null
    if ($State.PSObject.Properties['ScriptRoot'] -and $State.ScriptRoot) {
        $modulesRoot = Join-Path $State.ScriptRoot 'Modules'
    } elseif ($PSScriptRoot) {
        # PSScriptRoot is Modules/Orchestrator since the split (this file was
        # extracted from Orchestrator.psm1); the Modules root is its parent.
        # If the file is dot-sourced straight from Modules/ root (tests), the
        # sibling Orchestrator.psm1 sits next to it, so use $PSScriptRoot then.
        $modulesRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.psm1') -PathType Leaf) {
            $PSScriptRoot
        } else {
            Split-Path -Parent $PSScriptRoot
        }
    }
    foreach ($p in $State.BuildConfig.build.menu.moduleMap.PSObject.Properties) {
        foreach ($m in @($p.Value)) {
            $name = ([string]$m).Trim()
            if (-not $name) { continue }
            [void]$named.Add($name)
            if ($modulesRoot -and -not (Test-Path -LiteralPath (Join-Path $modulesRoot "$name.psm1") -PathType Leaf)) {
                $missingFiles += ("choice '{0}' names module '{1}', but Modules/{1}.psm1 does not ship" -f $p.Name, $name)
            }
        }
    }
    if ($missingFiles.Count -gt 0) { throw ($missingFiles -join '; ') }

    $unreachable = @($loadPathOnly | Where-Object { -not $named.Contains($_) })
    if ($unreachable.Count -gt 0) {
        # Routed through the locale layer: this is a startup failure an operator
        # reads, and adding raw English here is charged against the
        # i18nProseCoverage ratchet - which is the point of the ratchet.
        throw (Get-LocaleMessage -Key 'log.orch.moduleMapIncomplete' -MessageArgs @(($unreachable -join ', ')))
    }
    return $true
}

