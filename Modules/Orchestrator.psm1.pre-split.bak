# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Orchestrator.psm1 - gbuild entrypoint and dispatch
# Import Logging first so its exported surface (Get-BuildState, Write-Log,
# Set-GBuildExitCode, ...) is loaded before anything calls it.
# -Global: keep Get-BuildState/Write-Log etc. resolvable from every module and
# the top-level gbuild.ps1 scope. Without it this import lands in Orchestrator's
# OWN session state and other -Global modules (SDK, Build) can't see Get-BuildState,
# triggering "... is not recognized" under Set-StrictMode.
$loggingPath = Join-Path $PSScriptRoot 'Logging.psm1'
$null = if (Test-Path $loggingPath) { Import-Module $loggingPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }
# Lifecycle helpers (banner, hooks, exit-code channel, usage tip) are split
# out of this file to keep Orchestrator.psm1 maintainable. Dot-sourced so
# they share this module's scope and $script: state.
$lifecyclePath = Join-Path $PSScriptRoot 'OrchestratorLifecycle.ps1'
if (Test-Path -LiteralPath $lifecyclePath) { . "$lifecyclePath" }
# Core modules needed at startup (Tier 1). Remaining modules are lazy-loaded on
# demand via Import-ModuleOnDemand (inside Invoke-GuildChoice / Start-GBuild) to reduce
# startup cost (was: eager import of 20 modules at import time).
# PathUtils is Tier-1 (zero-dependency): Get-BuildRootDirectory must resolve globally
# BEFORE on-demand Cache loads, including class methods (BuildCache.Initialize),
# including standalone-import flows which bypass the gbuild.ps1 early bootstrap.
# PathUtils MUST load before ErrorHandling/SharedUtils which call Invoke-EnsureDirectory
# at runtime without Get-Command guards.
# NOTE (L5 lazy-load): ClusterOrchestrator, AuditLedger and ModuleDependencies are
# intentionally NOT Tier-1. Every production use-site imports them via
# Import-ModuleOnDemand behind a Get-Command guard (cluster menu 'O' + background
# jobs; audit-ledger compliance block; dependency-graph validator used by tests),
# so eager loading only paid startup cost for dormant features.
# Report IS Tier-1: Start-GBuild's build step and finalizer call
# Write-BuildMetric / Save-BuildReport / Write-TelemetryEntry behind a
# Get-Command guard. Leaving Report lazy meant those guards were ALWAYS false in
# the default flow, so no build_*.json and no telemetry.jsonl was ever produced
# and the SLO block (which samples those files) stayed permanently starved.
# Report is 567 lines with no Tier-1 dependencies of its own - correctness wins.
# SINGLE SOURCE: Modules/Tier1Modules.ps1. The 20-name list used to be inlined
# here AND a second time in gbuild.ps1 (-SelfTest), and the hygiene test only
# matched the first copy, so drift was invisible. Both consumers dot-source the
# same data file now; this loop only decides HOW to import, never WHAT.
. (Join-Path $PSScriptRoot 'Tier1Modules.ps1')
$script:Tier1ModuleList = Get-Tier1ModuleList
foreach ($dep in @($script:Tier1ModuleList.Core)) {
    $depPath = Join-Path $PSScriptRoot "$dep.psm1"
    # -Global: without it the sub-import inside this module lands in Orchestrator's
    # OWN module scope, so exported functions (e.g. Get-PrimaryLanguage from
    # LanguageDetector, Invoke-PluginCommand from Loader) are invisible to OTHER
    # modules (Build, Deploy, plugins) and calls fail with "... is not recognized".
    if (Test-Path $depPath) { Import-Module $depPath -Force -Global -DisableNameChecking }
}
# Provider pattern (Phase 7+) — factory-based strategy, environment + Android SDK abstraction.
# AndroidSdkProvider is Tier-1 (not lazy) so Find-AdbPath/Get-AdbDevices resolve
# in every flow (Build, Deploy, menu choice 1) without depending on Android.psm1 load order.
foreach ($dep in @($script:Tier1ModuleList.Providers)) {
    $depPath = Join-Path (Join-Path $PSScriptRoot 'Providers') "$dep.psm1"
    if (Test-Path $depPath) { Import-Module $depPath -Force -Global -DisableNameChecking }
}

# Lazy module loader - imports a module only if not already loaded (idempotent).
# Used to defer loading of non-core modules until a menu choice actually needs them.
function Import-ModuleOnDemand {
    [CmdletBinding()]
    param([string[]]$ModuleNames)

Set-StrictMode -Version 1.0
    foreach ($name in $ModuleNames) {
        $path = Join-Path $PSScriptRoot "$name.psm1"
        # Providers live in Modules/Providers/ — resolve there as fallback so
        # on-demand loads of provider modules never silently no-op.
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $provPath = Join-Path (Join-Path $PSScriptRoot 'Providers') "$name.psm1"
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
function Resolve-ConfigJsonForSchema {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Config)
    # SINGLE SOURCE for "the config as schema-validation input".
    #
    # ${env:VAR} placeholders must NOT be resolved to their real values before
    # validation: resolving e.g. ${env:APPDATA} to C:\Users\... injects raw
    # backslashes that are invalid JSON escapes and make Test-Json fail on pwsh 7
    # with "Cannot parse the JSON". Schema checks only need the structure, so a
    # placeholder-safe literal is sufficient (and avoids leaking secrets).
    #
    # This was applied ONLY inside the Test-Json branch. The Test-JsonSchema
    # fallback (the branch PowerShell 5.1 actually takes - it has no Test-Json
    # at all) validated the raw placeholder strings, so the same config was
    # accepted on pwsh 7 and rejected on Windows PowerShell 5.1 whenever the
    # schema constrained a placeholder's shape.
    $json = $Config | ConvertTo-Json -Depth 100
    if (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) {
        $json = $json -replace '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '/tmp/placeholder'
    }
    return $json
}

function Test-BuildConfig {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State,
        [switch]$Strict,
        # Explicit escape hatch for the two checks that are now fail-CLOSED
        # (missing schema file, no usable validator). Never inferred: an
        # accident must not be able to turn validation off.
        [switch]$NonStrict
    )
    if (-not $State -or -not $State.BuildConfig) {
        if ($Strict) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m01') "Warn" $State; return $false }
        return $false
    }
    if (-not $State.ConfigPath -or -not (Test-Path $State.ConfigPath)) {
        if ($Strict) { throw (Get-LocaleMessage -Key 'log.orch.configFileNotFound' -MessageArgs @([string]$State.ConfigPath) -Fallback 'Config file not found: {0}') }
        return $false
    }
    $schemaPath = if ($State.PSObject.Properties.Name -contains 'ConfigSchemaPath' -and $State.ConfigSchemaPath) {
        [string]$State.ConfigSchemaPath
    } elseif ($State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) {
        Join-Path ([string]$State.ScriptRoot) 'gbuild.config.schema.json'
    } else {
        [System.IO.Path]::ChangeExtension([string]$State.ConfigPath, '.schema.json')
    }
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        # Fail CLOSED by default. Returning $true here meant that deleting,
        # renaming or botching the copy of gbuild.config.schema.json silently
        # disabled schema validation for the whole platform - and because the
        # schema is 4 000+ lines of property types and additionalProperties
        # rules, everything a consumer mistypes would then be accepted.
        # Opt out explicitly with -NonStrict, never by accident.
        $msg = (Get-LocaleMessage -Key 'log.orch.schemaFileNotFound' -MessageArgs @([string]$schemaPath) -Fallback 'Schema file not found: {0}')
        if ($NonStrict) { Write-Log "[WARN] $msg" "Warn" $State; return $true }
        throw $msg
    }
    $testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
    $hasSchemaParam = $testJsonCmd -and $testJsonCmd.Parameters.ContainsKey('Schema')

    if ($hasSchemaParam) {
        try {
            # ${env:VAR} placeholders are neutralised by the shared helper - see
            # Resolve-ConfigJsonForSchema for why they must not be resolved here.
            $json = Resolve-ConfigJsonForSchema -Config $State.BuildConfig
            $schema = Get-Content $schemaPath -Raw -EA Stop
            $result = $json | Test-Json -Schema $schema -EA Stop
            if (-not $result) {
                $msg = "Config validation failed against schema"
                if ($Strict) { throw $msg }
                Write-Log "[WARN] $msg" "Warn" $State
            }
            return $result
        } catch {
            $msg = "Config validation error: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }

    # REAL schema validation, reachable on every host. This branch used to be
    #
    #     if (Get-Command Test-JsonSchema -ErrorAction SilentlyContinue) { ... }
    #
    # `Test-JsonSchema` is not a PowerShell cmdlet and was never defined in this
    # repository, so all 20 lines were unreachable everywhere. The comment above
    # them reasoned about that branch as if it were live, which is how the gap
    # stayed invisible: on Windows PowerShell 5.1 (no Test-Json) validation
    # quietly fell through to Test-ConfigSchema, and that function only checked
    # FIVE top-level property names. The same config file therefore got a full
    # type/enum/required check on pwsh 7 and a "looks fine" on 5.1.
    #
    # ConfigProvider.Test-BuildConfigSchema is the single owner now, and it
    # implements exactly the keyword subset gbuild.config.schema.json uses. The
    # SAME placeholder-safe config view is used as in the Test-Json branch above,
    # so the two validators cannot disagree about the same file.
    if (Get-Command Test-BuildConfigSchema -ErrorAction SilentlyContinue) {
        try {
            $config = Resolve-ConfigJsonForSchema -Config $State.BuildConfig | ConvertFrom-Json -EA Stop
            $schema = Get-Content $schemaPath -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop
            return [bool](Test-BuildConfigSchema -Instance $config -Schema $schema)
        } catch {
            $msg = "Config validation error: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }

    # Level 5: ConfigProvider.Test-ConfigSchema as structural fallback when neither
    # Test-Json -Schema nor Test-JsonSchema is available (was test-only).
    if (Get-Command Test-ConfigSchema -ErrorAction SilentlyContinue) {
        try {
            $schemaResult = Test-ConfigSchema -State $State -Strict:$Strict
            if ($null -ne $schemaResult) { return [bool]$schemaResult }
        } catch {
            if ($Strict) { throw }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m02' -MessageArgs @($_)) "Warn" $State
            return $false
        }
    }

    # Last resort: the file parses as JSON. This validates NOTHING beyond
    # well-formedness, so it is a fail-CLOSED branch by default too: on a host
    # with neither Test-Json nor a schema-aware validator, reporting "valid"
    # would silently downgrade a full type/property check to a syntax check.
    if ($NonStrict) {
        try {
            $null = Get-Content $State.ConfigPath -Raw -EA Stop | ConvertFrom-Json -EA Stop
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m03') 'Gray' $State
            return $true
        } catch {
            $msg = "Config JSON is invalid: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }
    throw (Get-LocaleMessage -Key 'log.orch.configNoValidator' -Fallback 'No JSON-Schema validator is available on this host, so gbuild.config.json cannot be validated. Install PowerShell 6+ (Test-Json) or supply a validator.')
}

<#
    .SYNOPSIS
        Runs quick health checks before the build starts.
    .PARAMETER State
        Global state object.
    #>
function Test-PreFlight {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not (Get-Command Invoke-HealthCheck -ErrorAction SilentlyContinue)) { return }
    $results = Invoke-HealthCheck -State $State -Quick
    if ($results) {
        $fails = @($results | Where-Object { $_.Status -eq 'Fail' })
        if ($fails.Count -gt 0) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m04' -MessageArgs @($($fails.Count))) "Warn" $State
        }
    }
}

<#
    .SYNOPSIS
        Retrieves the active build profile object from configuration.
    .DESCRIPTION
        Looks up profile by name in State.BuildConfig.profiles.
    .PARAMETER State
        Global state object with BuildConfig.
    .PARAMETER ProfileName
        Profile name (default: Release).
    .OUTPUTS
        Profile PSCustomObject or $null if not found.
    #>
function Assert-BuildCommandAvailable {
    <#
    .SYNOPSIS
        Fails loudly when a module the current menu action needs is absent.
    .DESCRIPTION
        One owner for two defects that shared a single shape.

        DUPLICATION. The publish/deploy switch arms each began with their own
        copy of `if (-not (Get-Command <Command> ...)) { throw '<X> module not
        loaded.' }`. Eight distinct literals were written out 21 times across
        the switch, and the probe was the only thing that varied - so a new arm
        copied whatever arm it sat next to rather than calling a shared helper.

        i18n. Those 21 throws were also the largest single concentration of
        untranslated English left in this module, and they are exactly the
        messages a user sees when the wrong _Build copy is on the module path -
        the most useful diagnostic in the file, and one they could not read in
        their own language.

        Returns $true when the command resolves so a caller can use it as the
        condition itself; throws with the localized message when it does not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$MessageKey,
        [Parameter(Mandatory)][string]$Fallback
    )
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return $true }
    throw (Get-LocaleMessage -Key $MessageKey -Fallback $Fallback)
}

function Merge-Profile {
    [CmdletBinding()]
    param([PSCustomObject]$Base, [PSCustomObject]$Override)
    # Level 5 DRY: deep-merge single-sourced via ConfigProvider.Merge-ConfigObject.
    # Fallback inline merge kept for standalone survival (ConfigProvider absent).
    if (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue) {
        try { return Merge-ConfigObject -Base $Base -Override $Override } catch { }
    }
    if (-not $Base) { return $Override }
    if (-not $Override) { return $Base }
    $merged = [PSCustomObject]@{}
    foreach ($p in $Base.PSObject.Properties) {
        $merged | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
    }
    foreach ($p in $Override.PSObject.Properties) {
        if ($p.Value -is [PSCustomObject] -and $merged.($p.Name) -is [PSCustomObject]) {
            $merged.($p.Name) = Merge-Profile -Base $merged.($p.Name) -Override $p.Value
        } else {
            $merged | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        }
    }
    return $merged
}

function Get-ActiveProfile {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProfileName = 'Release')
    if (-not ($State -and $State.BuildConfig -and $State.BuildConfig.profiles)) { return $null }
    $profiles = $State.BuildConfig.profiles
    if (-not $profiles.$ProfileName) { return $null }

    # Build inheritance chain via explicit `extends` (resolved recursively, cycle-guarded).
    # Level 5: max depth single-sourced via BuildConstants.ProfileInheritanceMaxDepth.
    $maxDepth = 10
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $maxDepth = [int](Get-BuildConstant -Key 'ProfileInheritanceMaxDepth' -Fallback 10) } catch { $maxDepth = 10 }
    }
    $chain = @()
    $cur = $ProfileName
    $guard = 0
    while ($cur -and $guard -lt $maxDepth) {
        if (-not $profiles.$cur) { break }
        $chain = @($cur) + $chain
        $ext = $null
        if ($profiles.$cur.PSObject.Properties.Name -contains 'extends') { $ext = $profiles.$cur.extends }
        if ($ext -eq $cur) { break }
        $cur = $ext
        $guard++
    }

    # Implicit base `default` profile merges first when present
    if ($profiles.default -and $chain -notcontains 'default') { $chain = @('default') + $chain }

    $result = $null
    foreach ($name in $chain) {
        $result = Merge-Profile -Base $result -Override $profiles.$name
    }
    return $result
}

function Get-BuildTestConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)
    $build = Get-ConfigSection -State $State -Path 'build'
    $test = Get-SectionValue -Section $build -Key 'test' -Default $null
    $legacyValue = Get-SectionValue -Section $build -Key 'runTestLint' -Default $null
    $legacyPresent = $null -ne $legacyValue
    $legacy = if ($legacyPresent) { [bool]$legacyValue } else { $null }
    $defaultTest = $true
    # Mirrors BuildConstants.TestLintEnabled ($false): lint is an opt-in step,
    # not part of the default test phase.
    $defaultLint = $false
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $defaultTest = [bool](Get-BuildConstant -Key 'TestEnabled' -State $State -Fallback $true)
        $defaultLint = [bool](Get-BuildConstant -Key 'TestLintEnabled' -State $State -Fallback $false)
    }
    $testValue = Get-SectionValue -Section $test -Key 'enabled' -Default $null
    $lintValue = Get-SectionValue -Section $test -Key 'lintEnabled' -Default $null
    $testEnabled = if ($null -ne $testValue) { [bool]$testValue } elseif ($null -ne $legacy) { $legacy } else { $defaultTest }
    $lintEnabled = if ($null -ne $lintValue) { [bool]$lintValue } elseif ($null -ne $legacy) { $legacy } else { $defaultLint }
    return @{ TestEnabled = $testEnabled; LintEnabled = $lintEnabled }
}

<#
.SYNOPSIS
    Auto-detects Java JDK and Android SDK for MAUI/Android projects.
.DESCRIPTION

        Checks if project type or TFMs require Java/Android SDKs and triggers
        Get-SmartSdk if not already resolved in State.
    .PARAMETER State
        Global state object with JavaSdk and AndroidSdk properties.
    .PARAMETER ProjectType
        The detected project type (e.g., MAUI, Web).
    .PARAMETER Tfms
        Array of target framework monikers.
    #>
function Invoke-SdkDetection {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectType, [string[]]$Tfms)
    $isMaui = ($ProjectType -eq 'MAUI')
    $hasAndroid = @($Tfms | Where-Object { $_ -match 'android' }).Count -gt 0
    # StrictMode-safe: PSCustomObject assignment to non-existent property throws
    # under Set-StrictMode. Use Add-Member helper (Set-BuildStateProperty when available)
    # and guard reads with property existence check so orphan/mock states also work.
    $hasJava = $State.PSObject.Properties.Name -contains 'JavaSdk' -and $State.JavaSdk
    $hasAndroidSdk = $State.PSObject.Properties.Name -contains 'AndroidSdk' -and $State.AndroidSdk
    if (($isMaui -or $hasAndroid) -and -not $hasJava -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.javaSearching') 'Cyan' $State
        $jdk = Get-SmartSdk -State $State -ToolType 'JDK'
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'JavaSdk' -Value $jdk -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name 'JavaSdk' -Value $jdk -Force -ErrorAction SilentlyContinue
        }
        if (-not $jdk) { Write-Log (Get-LocaleMessage -Key 'log.sdk.javaNotFound') 'Warn' $State }
    }
    if ($hasAndroid -and -not $hasAndroidSdk -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.androidSearching') 'Cyan' $State
        $adk = Get-SmartSdk -State $State -ToolType 'Android'
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'AndroidSdk' -Value $adk -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name 'AndroidSdk' -Value $adk -Force -ErrorAction SilentlyContinue
        }
        if (-not $adk) { Write-Log (Get-LocaleMessage -Key 'log.sdk.androidNotFound') 'Warn' $State }
    }
}

<#
    .SYNOPSIS
        Extracts platform-specific TFMs from the target frameworks array.
    .DESCRIPTION
        Returns Windows, Android, iOS, and Mac Catalyst TFMs from a list.
        For Windows-only project types, synthesizes a Windows TFM if missing.
    .PARAMETER Tfms
        Array of target framework monikers from the project.
    .PARAMETER ProjectType
        The detected project type (WinForms, WPF, WinExe).
    .PARAMETER DefaultTfm
        Fallback TFM to derive Windows TFM from.
    #>
function Resolve-TargetFrameworks {
    [CmdletBinding()]
    param([string[]]$Tfms, [string]$ProjectType, [string]$DefaultTfm)
    $winTfm = @($Tfms | Where-Object { $_ -match '-windows$' }) | Select-Object -First 1
    if (-not $winTfm -and ($ProjectType -in @('WinForms', 'WPF', 'WinExe'))) { $winTfm = "$DefaultTfm-windows" }
    return [PSCustomObject]@{
        WinTfm = $winTfm
        AndroidTfm = @($Tfms | Where-Object { $_ -match 'android' }) | Select-Object -First 1
        IosTfm = @($Tfms | Where-Object { $_ -match 'ios' }) | Select-Object -First 1
        MacTfm = @($Tfms | Where-Object { $_ -match 'maccatalyst' }) | Select-Object -First 1
    }
}

<#
    .SYNOPSIS
        Dispatches a menu choice to the corresponding build action.
    .DESCRIPTION
        Routes user menu selections (0-13, D, S, W) to the appropriate
        build, deploy, debug, or utility functions.
    .PARAMETER Choice
        Menu selection key (string).
    .PARAMETER MenuConfig
        Menu configuration hashtable from New-GuildMenuConfig.
    .PARAMETER State
        Global state object.
    .PARAMETER ProjPath
        Path to the .csproj file.
    .PARAMETER ProjectDir
        Project directory path.
    .PARAMETER ProjectType
        Detected project type (MAUI, Web, WinForms, etc.).
    .PARAMETER Tfms
        Array of target framework monikers.
    .PARAMETER DefaultTfm
        Default TFM for the project.
    .PARAMETER WinTfm
        Windows-specific TFM if any.
    .PARAMETER AndroidTfm
        Android-specific TFM if any.
    .PARAMETER IosTfm
        iOS-specific TFM if any.
    .PARAMETER MacTfm
        Mac Catalyst-specific TFM if any.
    .PARAMETER Incremental
        Enable incremental build mode.
    #>


<#
Moved to Modules/RBAC.psm1 (2026-10): Get-BuildActionPermission,
Get-RbacPrivilegedActions and Test-ActionAllowed resolve menu-choice
authorization and belong to the RBAC engine. They are Tier-1 (RBAC) so every
consumer resolves them exactly as before.
#>

<#
.SYNOPSIS
    Escalates anomalies through Alerting (Level 5 closed loop).
.DESCRIPTION
    Thin wrapper over AnomalyDetector.Send-AnomalyAlert (single source).
    Kept for backward compat — new code should call Send-AnomalyAlert directly.
    Lazy-imports AnomalyDetector+Alerting on demand; never breaks a build.
#>
function Send-AnomalyAlertIfNeeded {
    [CmdletBinding()]
    param([PSCustomObject]$Report, [PSCustomObject]$State)
    try {
        Import-ModuleOnDemand -ModuleNames @('AnomalyDetector', 'Alerting')
        if (Get-Command Send-AnomalyAlert -ErrorAction SilentlyContinue) {
            return (Send-AnomalyAlert -Report $Report -State $State)
        }
        # Standalone fallback (AnomalyDetector absent): preserve legacy behavior
        # but with corrected severity mapping (was hardcoded 'Warning' which the
        # default minSeverity=Critical gate silently dropped).
        if (-not $Report -or -not $Report.Anomalies) { return $false }
        $severe = @($Report.Anomalies | Where-Object { $_.Severity -in @('Medium', 'High', 'Critical') })
        if ($severe.Count -eq 0) { return $false }
        Import-ModuleOnDemand -ModuleNames @('Alerting')
        if (Get-Command Send-Alert -ErrorAction SilentlyContinue) {
            $top = 'Medium'
            $order = @('Medium', 'High', 'Critical')
            foreach ($a in $severe) {
                if ($order.IndexOf([string]$a.Severity) -gt $order.IndexOf($top)) { $top = [string]$a.Severity }
            }
            $sev = if ($top -eq 'Critical') { 'Critical' } elseif ($top -eq 'High') { 'Error' } else { 'Warning' }
            return ([bool](Send-Alert -Message ("[ANOMALY] $($Report.Summary)") -Severity $sev -State $State -Data @{ source = 'anomaly-detector'; maxSeverity = [string]$Report.MaxSeverity }))
        }
        return $false
    } catch {
        # benign: alerting must never break the build
    }
}

<#
.SYNOPSIS
    Loads the module dependency map from config (build.menu.moduleMap) with hardcoded fallback.
.DESCRIPTION
    Reads build.menu.moduleMap from gbuild.config.json. Each entry maps a menu choice
    to an array of module names to lazy-load.
.PARAMETER State
    The build state object carrying BuildConfig.
.OUTPUTS
    Hashtable mapping choice keys to string[] module names.
.DESCRIPTION
    There is deliberately NO hardcoded fallback map, and this docstring used to
    claim one existed. It did not: the function returned @{} and every choice
    then failed later with a generic "module not loaded" message. A previous
    revision DID carry a hardcoded $defaultMap, and it had drifted from config
    (IDs 14 and X differed) - two disagreeing sources were the original defect,
    so one source is correct.

    What makes one source safe is that it is VERIFIED rather than trusted. This
    map is the ONLY load path for eight modules: Build, Deploy, Android, Chaos,
    ClusterOrchestrator, HealthCheck, HotReload and Documentation appear in no
    Import-ModuleOnDemand call anywhere in the codebase. If the map is absent,
    misspelled or truncated, the old behaviour was to return @{} - every one of
    those targets then silently did nothing.

    So a missing map is now a named, loud failure rather than a silent one. A
    build platform that loses a whole capability has to say so.
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
function Get-DefaultActionsFromConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)

    $defaultMap = @{
        'MAUI'       = { param($ctx) if ($ctx.tfmInfo.AndroidTfm) { '2' } elseif ($ctx.tfmInfo.WinTfm) { '8' } else { '12' } }
        'Web'        = '7'
        'BlazorWasm' = '7'
        'WinForms'   = '8'
        'WinExe'     = '8'
        'WPF'        = '9'
        'WinUI'      = '8'
        'Console'    = '10'
        'Library'    = '11'
        'Avalonia'   = '16'
        'Python'     = '12'
        'Node.js'    = '12'
        'TypeScript' = '12'
        'Rust'       = '12'
        'Go'         = '12'
        'Java'       = '12'
        'Kotlin'     = '12'
        'Ruby'       = '12'
        'PHP'        = '12'
        'C/C++'      = '12'
        'C'          = '12'
        'Docker'     = '12'
        'Elixir'     = '12'
        'Swift'      = '12'
        'PowerShell' = '12'
        'default'    = '12'
    }

    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.menu -or -not $State.BuildConfig.build.menu.defaultActions) {
        return $defaultMap
    }

    $cfgMap = $State.BuildConfig.build.menu.defaultActions
    $result = @{}
    foreach ($key in $cfgMap.PSObject.Properties.Name) {
        $val = $cfgMap.$key
        if ($val -is [scriptblock]) {
            $result[$key] = $val
        } elseif ($val -is [string]) {
            $result[$key] = $val
        } elseif ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [hashtable]) {
            # MAUI-style conditional: { androidTfm, windowsTfm, default }
            $androidChoice = if ($val.PSObject.Properties.Name -contains 'androidTfm') { $val.androidTfm } elseif ($val.ContainsKey('androidTfm')) { $val['androidTfm'] } else { '2' }
            $windowsChoice = if ($val.PSObject.Properties.Name -contains 'windowsTfm') { $val.windowsTfm } elseif ($val.ContainsKey('windowsTfm')) { $val['windowsTfm'] } else { '8' }
            $defaultChoice = if ($val.PSObject.Properties.Name -contains 'default') { $val.default } elseif ($val.ContainsKey('default')) { $val['default'] } else { '12' }
            $result[$key] = { param($ctx) if ($ctx.tfmInfo.AndroidTfm) { $androidChoice } elseif ($ctx.tfmInfo.WinTfm) { $windowsChoice } else { $defaultChoice } }.GetNewClosure()
        } else {
            $result[$key] = $defaultMap[$key]
        }
    }
    # Merge defaults for any missing keys
    foreach ($key in $defaultMap.Keys) {
        if (-not $result.ContainsKey($key)) { $result[$key] = $defaultMap[$key] }
    }
    return $result
}

<#
.SYNOPSIS
    Dispatches a deploy menu choice through the deploy-target plugin registry.
.DESCRIPTION
    Maps a menu choice letter to its registered deploy-target name and invokes it
    via Invoke-DeployTarget (the registry dispatcher). This replaces the previous
    hardcoded switch so newly registered targets are picked up automatically.
.PARAMETER Choice
    The menu choice letter (A/B/V/G/P/F/E/K/Y).
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
        # PSScriptRoot is Modules/ when this module is loaded normally, and the
        # test suite dot-sources this file, so both shapes are covered.
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

function Invoke-RegisteredDeploy {
    [CmdletBinding()]
    param([string]$Choice, [PSCustomObject]$State, [string]$ProjectDir = '', [string]$ProjectType = '')
    $map = @{
        'A' = 'azure'; 'B' = 'aws'; 'V' = 'vercel'; 'G' = 'gcp'
        'P' = 'kubernetes'; 'F' = 'azureFunctions'; 'E' = 'awsLambda'
        'K' = 'dockerCi'; 'Y' = 'azurePipeline'
    }
    $name = $map[$Choice]
    if (-not $name) { Write-Fail (Resolve-LogMessage -Key 'log.deploy.unknownChoice' -MessageArgs @([string]$Choice) -Fallback 'Unknown deploy choice: {0}') -State $State; return $false }
    if (-not (Get-Command Invoke-DeployTarget -ErrorAction SilentlyContinue)) {
        Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('DeployTargets') -Fallback 'DeployTargets module not loaded.') -State $State
        return $false
    }
    # SURFACE MISCONFIGURATION BEFORE THE DEPLOY. Test-DeployTargets shipped fully
    # implemented but was reachable only from the test suite, so no deploy verb and
    # no CI job ever ran it: a target enabled with a missing required field was
    # discovered only after the CLI had already been invoked against the cloud
    # provider. Report the specific missing keys first; the deploy itself still
    # re-validates authoritatively inside Invoke-DeployTarget.
    try {
        if (Get-Command Test-DeployTargets -ErrorAction SilentlyContinue) {
            $cfgReport = Test-DeployTargets -State $State
            $entry = @($cfgReport.Targets) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($entry -and $entry.Enabled -and -not $entry.Valid) {
                $missingList = (@($entry.Missing) -join ', ')
                $msg = (Get-LocaleMessage -Key 'log.dt.misconfigured' -MessageArgs @($name, $missingList))
                Write-Fail $msg -State $State
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    try { Write-AuditLog -Action "deploy:$name" -Outcome 'Denied' -State $State -Detail $msg } catch { }
                }
                return $false
            }
        }
    } catch { }
    try {
        $result = Invoke-DeployTarget -Name $name -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType
        return (Test-RequiredResult -Result $result -Operation "deploy:$name")
    } catch {
        Write-Fail (Resolve-LogMessage -Key 'log.deploy.failed' -MessageArgs @([string]$name, [string]$_) -Fallback 'Deploy ''{0}'' failed: {1}') -State $State
        return $false
    }
}

function Invoke-PluginTestAndLintGate {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectDir = '',
        [Parameter(Mandatory)][string]$Language,
        $TestFlags,
        [switch]$Detailed
    )
    if ($null -eq $TestFlags) { $TestFlags = Get-BuildTestConfig -State $State }
    if ($TestFlags.TestEnabled) {
        if (-not (Get-Command Invoke-PluginTestFor -ErrorAction SilentlyContinue)) {
            throw (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Invoke-PluginTestFor') -Fallback 'Invoke-PluginTestFor not loaded.')
        }
        $testResult = Invoke-PluginTestFor -State $State -Language $Language -ProjectDir $ProjectDir -Detailed:$Detailed
        $testGate = Test-BuildGateResult -Result $testResult -Operation "test:$Language" -StageLabel 'Tests' -State $State
        if ($testGate.Skipped) { Write-SubLog ("Skipped tests for {0}: {1}" -f $Language, $testGate.Message) }
        # PUBLISH THE VERDICT. The gate produced a verdict and dropped it: the
        # build kept no record of which language was tested, and no JUnit
        # artifact was ever written, so a CI consumer had nothing to consume
        # even though the exporter existed and the shipped schema advertised
        # report.format = "junit". Record it on the state and publish the
        # artifact; both are best-effort and must never fail the build.
        if (Get-Command Add-BuildTestResult -ErrorAction SilentlyContinue) {
            try { $null = Add-BuildTestResult -State $State -Result $testGate -Suite $Language } catch { }
        }
        if (Get-Command Publish-BuildJUnitArtifact -ErrorAction SilentlyContinue) {
            try { $null = Publish-BuildJUnitArtifact -State $State -SuiteName 'gbuild' } catch { }
        }
        if (-not $testGate.Passed) {
            if (Get-Command Write-BuildGateDiagnostics -ErrorAction SilentlyContinue) { Write-BuildGateDiagnostics -Gate $testGate -State $State }
            $testDetail = if ($testGate.Message) { [string]$testGate.Message } else { '' }
            $message = Get-LocaleMessage -Key 'log.plugin.testFailed' -MessageArgs @($Language, $testDetail)
            Write-Fail $message -State $State
            throw $message
        }
    }
    if ($TestFlags.LintEnabled) {
        if (-not (Get-Command Invoke-PluginLintFor -ErrorAction SilentlyContinue)) {
            throw (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Invoke-PluginLintFor') -Fallback 'Invoke-PluginLintFor not loaded.')
        }
        $lintResult = Invoke-PluginLintFor -State $State -Language $Language -ProjectDir $ProjectDir -Detailed:$Detailed
        $lintGate = Test-BuildGateResult -Result $lintResult -Operation "lint:$Language" -StageLabel 'Lint' -State $State
        if ($lintGate.Skipped) { Write-SubLog ("Skipped lint for {0}: {1}" -f $Language, $lintGate.Message) }
        if (-not $lintGate.Passed) {
            if (Get-Command Write-BuildGateDiagnostics -ErrorAction SilentlyContinue) { Write-BuildGateDiagnostics -Gate $lintGate -State $State }
            $lintDetail = if ($lintGate.Message) { [string]$lintGate.Message } else { '' }
            $message = Get-LocaleMessage -Key 'log.plugin.lintFailed' -MessageArgs @($Language, $lintDetail)
            Write-Fail $message -State $State
            throw $message
        }
    }
    return $true
}

<#
.SYNOPSIS
    Resolves deploy-choice MSBuild args from config (Level 5 single-source).
.DESCRIPTION
    Reads build.deployChoiceArgs.* via Get-BuildConstant so MSBuild args change
    without code edits. Falls back to BuildConstants defaults when config is absent.
#>
function Get-DeployChoiceArgs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('Apk','Ios','WinMsix','Aot')][string]$Kind,
        [PSCustomObject]$State
    )
    # Explicit key mapping, not `"DeployChoiceArgs$Kind"`. The string-built key
    # meant the four constants (DeployChoiceArgsApk / Ios / WinMsix / Aot) never
    # appeared at any call site, so each was declared, mapped to config and read
    # by nothing while still looking wired - and no static check could tell.
    $key = ''
    switch ($Kind) {
        'Apk'     { $key = 'DeployChoiceArgsApk' }
        'Ios'     { $key = 'DeployChoiceArgsIos' }
        'WinMsix' { $key = 'DeployChoiceArgsWinMsix' }
        'Aot'     { $key = 'DeployChoiceArgsAot' }
    }
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $v = Get-BuildConstant -Key $key -State $State -Fallback $null
            if ($v) { return @($v) }
        }
    } catch { }
    return @()
}

function Get-DeployDefaultRid {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $v = Get-BuildConstant -Key 'DeployDefaultRid' -State $State -Fallback 'win-x64'
            if ($v) { return [string]$v }
        }
    } catch { }
    return 'win-x64'
}

<#
.SYNOPSIS
    Builds the -Target catalog: every menu ID with purpose + engines (L5).
.DESCRIPTION
    Single source for `-Target list` and the invalid-target hint. Labels come
    from the neutral menu config (locale-aware), engine modules from
    Get-ModuleMapFromConfig (config-driven), project defaults from
    Get-DefaultActionsFromConfig. Availability (Supported) is intentionally
    NOT filtered here — it depends on the detected project type and OS at
    build time; the interactive menu shows the supported subset per project.
    Returns an ordered array of @{ Key; Label; Title; Modules; DefaultFor }.
#>
function Get-TargetCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([PSCustomObject]$State)
    $menu = $null
    try {
        if (Get-Command New-GuildMenuConfig -ErrorAction SilentlyContinue) {
            $menu = New-GuildMenuConfig -ProjectType '' -AndroidTfm '' -WinTfm '' -OS '' -ParallelProjects @() -State $State
        }
    } catch { $menu = $null }
    $modMap = @{}
    try {
        if (Get-Command Get-ModuleMapFromConfig -ErrorAction SilentlyContinue) { $modMap = Get-ModuleMapFromConfig -State $State }
    } catch { }
    $order = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','T','I','A','B','V','G','P','F','E','K','Y','N','W','D','S','H','R','C','L','0','X','Z','M','O')
    $seen = @{}
    foreach ($k in $order) { $seen[$k] = $true }
    $extra = @()
    foreach ($src in @($menu, $modMap)) {
        if ($src -is [hashtable]) {
            foreach ($k in @($src.Keys)) {
                if (-not $seen.ContainsKey([string]$k)) { $seen[[string]$k] = $true; $extra += [string]$k }
            }
        }
    }
    # Reverse default-action map: which project types default to each ID.
    # String values group directly; scriptblocks (MAUI-style conditionals) are
    # probed against the three canonical TFM contexts (android-only,
    # windows-only, neither) so the project type is attributed to every ID the
    # block can return. Deterministic with no TFM context required; a block
    # that yields nothing falls back to the 'conditional' bucket.
    $defaultFor = @{}
    # Single source for the TFM used to probe conditional default actions.
    $__probeTfm = 'net8.0'
    try {
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $__probeTfm = [string](Get-BuildSetting -Key 'DefaultTfm' -State $State -Fallback 'net8.0') }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($__probeTfm)) { $__probeTfm = 'net8.0' }
    try {
        if (Get-Command Get-DefaultActionsFromConfig -ErrorAction SilentlyContinue) {
            $defs = Get-DefaultActionsFromConfig -State $State
            if ($defs -is [hashtable]) {
                foreach ($pt in @($defs.Keys)) {
                    $v = $defs[$pt]
                    if ($v -is [string] -and $v) {
                        if (-not $defaultFor.ContainsKey($v)) { $defaultFor[$v] = [System.Collections.ArrayList]::new() }
                        [void]$defaultFor[$v].Add([string]$pt)
                    } elseif ($v -is [scriptblock]) {
                        $probeCtxs = @(
                            # Derive the probe TFM from the configured default instead
                            # of pinning .NET 10. These three contexts only answer
                            # "is this block android-only / windows-only / neither?",
                            # and that depends on the SHAPE of the TFM string. Pinning
                            # 'net10.0-android' meant a project really targeting
                            # net9.0-android or net11.0-android matched none of them
                            # and fell into the 'conditional' bucket, so its default
                            # action was silently mis-attributed.
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ($__probeTfm + '-android'); WinTfm = '' } },
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = ($__probeTfm + '-windows') } },
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = '' } }
                        )
                        $candidateIds = @()
                        foreach ($pc in $probeCtxs) {
                            try {
                                $probeResult = & $v $pc
                                if ($probeResult -is [string] -and $probeResult) { $candidateIds += $probeResult }
                            } catch { }
                        }
                        $candidateIds = @($candidateIds | Select-Object -Unique)
                        if ($candidateIds.Count -eq 0) {
                            if (-not $defaultFor.ContainsKey('conditional')) { $defaultFor['conditional'] = [System.Collections.ArrayList]::new() }
                            [void]$defaultFor['conditional'].Add([string]$pt)
                        } else {
                            foreach ($cid in $candidateIds) {
                                if (-not $defaultFor.ContainsKey($cid)) { $defaultFor[$cid] = [System.Collections.ArrayList]::new() }
                                if ($defaultFor[$cid] -notcontains [string]$pt) { [void]$defaultFor[$cid].Add([string]$pt) }
                            }
                        }
                    }
                }
            }
        }
    } catch { }
    $rows = [System.Collections.ArrayList]::new()
    foreach ($k in @($order + $extra)) {
        $label = [string]$k; $title = ''
        if (($menu -is [hashtable]) -and $menu.ContainsKey($k) -and $menu[$k]) {
            try {
                if ($menu[$k].Label) { $label = [string]$menu[$k].Label }
                if ($menu[$k].Title) { $title = [string]$menu[$k].Title }
            } catch { }
        }
        $mods = @()
        if (($modMap -is [hashtable]) -and $modMap.ContainsKey($k) -and $modMap[$k]) { $mods = @($modMap[$k] | ForEach-Object { [string]$_ }) }
        $df = @()
        if ($defaultFor.ContainsKey($k)) { $df = @($defaultFor[$k]) }
        [void]$rows.Add([PSCustomObject]@{ Key = [string]$k; Label = $label; Title = $title; Modules = $mods; DefaultFor = $df })
    }
    return @($rows)
}

<#
.SYNOPSIS
    Prints the -Target catalog (like -Help, but for build target IDs).
.DESCRIPTION
    Invoked by `-Target list|help|?` (no project needed). Shows every menu ID
    with its purpose and engine modules, plus per-project-type defaults, so an
    ID from the help text (e.g. 2 = Publish Android APK) is always resolvable
    to a meaning without running interactively.
#>
function Show-TargetList {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $rows = @()
    try { $rows = @(Get-TargetCatalog -State $State) } catch { $rows = @() }
    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add('')
    [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.title' -Fallback 'gbuild target catalog — IDs usable with -Target <id>'))
    [void]$lines.Add('')
    $groups = @(
        @{ Name = 'BUILD'; Keys = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','T','I') },
        @{ Name = 'DEPLOY'; Keys = @('A','B','V','G','P','F','E','K','Y','N') },
        @{ Name = 'OPS'; Keys = @('W','D','S','H','R','C','L','0','X','Z','M','O') }
    )
    $byKey = @{}
    foreach ($r in $rows) { $byKey[$r.Key] = $r }
    $shown = @{}
    foreach ($g in $groups) {
        [void]$lines.Add("  $($g.Name):")
        foreach ($k in $g.Keys) {
            if (-not $byKey.ContainsKey($k)) { continue }
            $shown[$k] = $true
            $r = $byKey[$k]
            $mods = if ($r.Modules.Count -gt 0) { " (modules: $($r.Modules -join ', '))" } else { '' }
            $df = if ($r.DefaultFor.Count -gt 0) { " [default for: $($r.DefaultFor -join ', ')]" } else { '' }
            $ttl = if ($r.Title) { " — $($r.Title)" } else { '' }
            [void]$lines.Add(("    [{0}]" -f $k).PadRight(9) + "$($r.Label)$ttl$mods$df")
        }
    }
    $rest = @($rows | Where-Object { -not $shown.ContainsKey($_.Key) })
    if ($rest.Count -gt 0) {
        [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.custom' -Fallback 'CUSTOM:'))
        foreach ($r in $rest) {
            $mods = if ($r.Modules.Count -gt 0) { " (modules: $($r.Modules -join ', '))" } else { '' }
            [void]$lines.Add(("    [{0}]" -f $r.Key).PadRight(9) + "$($r.Label)$mods")
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.notes' -Fallback 'Notes:'))
    [void]$lines.Add('    - ' + (Get-LocaleMessage -Key 'ui.target.noteAvailability' -Fallback 'Availability depends on the detected project type and OS;'))
    [void]$lines.Add('      ' + (Get-LocaleMessage -Key 'ui.target.noteSubset' -Fallback 'run interactively in a project to see its supported subset.'))
    [void]$lines.Add('    - ' + (Get-LocaleMessage -Key 'ui.target.noteRecord' -Fallback 'A build log always records the used ID: [TARGET] Using -Target <id> (<purpose>).'))
    [void]$lines.Add('')
    foreach ($ln in $lines) {
        try { Write-Host $ln } catch { }
    }
}

<#
.SYNOPSIS
    Resolves the auto-build choice for -Project runs without -Target.
.DESCRIPTION
    Looks up the product type in build.menu.defaultActions (falls back to the
    'default' entry, then to '12'). The fallback chain validates ITSELF: '12'
    (Build default) is only a fallback when the menu actually supports it
    (Unknown / non-dotnet products). Otherwise returns '' and logs an Err
    naming the supported IDs, so the caller fails loudly instead of dying
    later at "Invalid choice". Never throws for config gaps.
.PARAMETER MenuConfig
    Hashtable from New-GuildMenuConfig (keys carry Supported flags).
.PARAMETER State
    Build state (reads build.menu.defaultActions).
.PARAMETER ProjectType
    Detected product type (e.g. 'WinForms', 'MAUI').
.PARAMETER BuildContext
    Context object passed to conditional (scriptblock) default actions.
.OUTPUTS
    [string] a supported menu choice key, or '' when none applies.
#>
function Resolve-AutoBuildChoice {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$MenuConfig, [PSCustomObject]$State, [string]$ProjectType, [PSCustomObject]$BuildContext)
    $choice = '12'
    try {
        if (Get-Command Get-DefaultActionsFromConfig -ErrorAction SilentlyContinue) {
            $defaultActions = Get-DefaultActionsFromConfig -State $State
            $action = $defaultActions[$ProjectType]
            if ($null -eq $action) { $action = $defaultActions['default'] }
            if ($null -ne $action) {
                if ($action -is [scriptblock]) { $choice = [string](& $action $BuildContext) }
                else { $choice = [string]$action }
            }
        }
    } catch { $choice = '12' }
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '12' }
    if ($MenuConfig.ContainsKey($choice) -and $MenuConfig[$choice].Supported -ne $false) {
        return $choice
    }
    if ($MenuConfig.ContainsKey('12') -and $MenuConfig['12'].Supported -ne $false) {
        return '12'
    }
    $supported = @($MenuConfig.Keys | Where-Object { $MenuConfig[$_] -and $MenuConfig[$_].Supported } | Sort-Object)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.target.noSupportedDefault' -MessageArgs @([string]$ProjectType, $choice, ($supported -join ', ')) -Fallback '[TARGET] No supported default for product type {0} (resolved ''{1}'' unavailable; fallback ''12'' unsupported). Supported: {2}. Pass -Target <id> explicitly.') 'Err' $State
    }
    return ''
}

function Invoke-GuildChoice {    [CmdletBinding()]
    param([string]$Choice = "", [hashtable]$MenuConfig, [PSCustomObject]$State, [string]$ProjPath = "", [string]$ProjectDir = "", [string]$ProjectType = "", [string[]]$Tfms = @(), [string]$DefaultTfm = "", [string]$WinTfm = "", [string]$AndroidTfm = "", [string]$IosTfm = "", [string]$MacTfm = "", [string[]]$ParallelProjects = @(), [switch]$Incremental, [hashtable]$PipelineContext = @{})
    # StrictMode-safe: typed-with-default above guarantees every variable exists
    # even when a `Set-StrictMode -Version Latest` caller omits arguments.
    try { if ($null -eq $ProjectType) { $ProjectType = "" } } catch { $ProjectType = "" }
    $choiceResult = $null
    if (-not $MenuConfig.ContainsKey($Choice) -or -not $MenuConfig[$Choice].Supported) {
        # Actionable: name what THIS project actually supports so a habit-typed
        # ID (e.g. '12', valid only for Unknown / non-.NET products) tells the
        # operator what to pick instead, and where ALL commands live (-Help).
        # 5.1-safe: statements only, no ternary. Numbers sort numerically.
        $supportedIds = @($MenuConfig.Keys | Where-Object { $MenuConfig[$_] -and $MenuConfig[$_].Supported })
        $numIds = @($supportedIds | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ })
        $alphaIds = @($supportedIds | Where-Object { $_ -notmatch '^\d+$' } | Sort-Object)
        $supportedIds = @($numIds + $alphaIds)
        $helpHint = 'gbuild -Help'
        if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
            try {
                $hintCwd = try { ((Get-Location).ProviderPath) } catch { '' }
                $hintRoot = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { '' }
                $helpHint = Get-InvokeCommandHint -Arguments '-Help' -ScriptRoot $hintRoot -FromDirectory $hintCwd
            } catch { }
        }
        $message = "Invalid choice: '$Choice' is not supported for this project. Supported: $($supportedIds -join ', '). Run '$helpHint' for ALL commands."
        Write-Fail $message -State $State
        throw $message
    }
    # RBAC: privileged actions require an allow-list when security.allowedActions is
    # configured. An action not in the allow-list (and not explicitly denied) is blocked.
    # Single source: BuildConstants.RbacPrivilegedActions (security.rbac.privilegedActions).
    $privileged = @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13')
    # Single source: RBAC.Get-RbacPrivilegedActions (config-overridable via
    # security.rbac.privilegedActions), then BuildConstants, then the hardcoded
    # mirror below (only when neither module chain loads). The literal is a
    # verbatim copy of the RBAC fallback - never edited independently.
    try {
        if (Get-Command Get-RbacPrivilegedActions -ErrorAction SilentlyContinue) {
            $viaRbac = @(Get-RbacPrivilegedActions -Kind 'privileged')
            if ($viaRbac.Count -gt 0) { $privileged = $viaRbac }
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $resolved = @(Get-BuildConstant -Key 'RbacPrivilegedActions' -State $State -Fallback $privileged)
            if ($resolved.Count -gt 0) { $privileged = $resolved }
        }
    } catch { }
    if ($Choice -in $privileged) {
        # Test-ActionAllowed lives in RBAC.psm1: ensure it is loaded for
        # standalone-Orchestrator sessions. No-op inside a normal run.
        Import-ModuleOnDemand -ModuleNames @('RBAC')
        $allowed = Test-ActionAllowed -State $State -Action $Choice
        if (-not $allowed.Allowed) {
            Write-Fail $allowed.Reason -State $State
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                Write-AuditLog -Action "choice:$Choice" -Outcome 'Denied' -State $State -Detail $allowed.Reason
            }
            return $false
        }
    }
    $sc = if ($Choice -eq '13') { 'Succ' } elseif ($Choice -eq '0') { 'Gray' } else { 'Info' }
    Write-StepTitle $MenuConfig[$Choice].Title -Color $sc -State $State
    # Audit privileged actions on success-path entry.
    if ($Choice -in $privileged -and (Get-Command Write-AuditLog -ErrorAction SilentlyContinue)) {
        Write-AuditLog -Action "choice:$Choice" -Outcome 'Started' -State $State
    }
    # Lazy-load the modules this choice depends on (keeps startup lean).
    $moduleMap = Get-ModuleMapFromConfig -State $State
    if ($moduleMap.ContainsKey($Choice)) {
        Import-ModuleOnDemand -ModuleNames $moduleMap[$Choice]
    }
    switch ($Choice) {
        '0' { Write-Info (Get-LocaleMessage -Key 'log.orchestrator.m06') $State; return }
        'D' {
            if (Get-Command Invoke-Doctor -ErrorAction SilentlyContinue) {
                $doctorOk = [bool](Invoke-Doctor -State $State)
                # The bool verdict used to be discarded: a broken environment
                # reported Succeeded/NoArtifact and -Target D exited 0. D is in
                # Get-FatalActionChoices, so an unhealthy environment now fails
                # the run (interactive sessions get the continue prompt; CI gets
                # a nonzero exit, which is the point of a health gate).
                $choiceResult = New-OperationResult -Status $(if ($doctorOk) { 'Succeeded' } else { 'Failed' }) -Operation 'target:D' -ReasonCode $(if ($doctorOk) { 'OK' } else { 'DoctorFailed' }) -Message $(if ($doctorOk) { 'Environment health check passed' } else { 'Environment health check failed' })
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('HealthCheck') -Fallback 'HealthCheck module not loaded.') -State $State
            }
        }
        'S' {
            if (Get-Command Invoke-SecurityScan -ErrorAction SilentlyContinue) {
                # The menu result is user-facing, but a FAILING scan must still
                # leave a non-zero exit code behind: `-Security`/CI callers read
                # it, and an operator who drives a scan from the menu must not
                # get a green pipeline out of a red gate.
                $menuScan = Invoke-SecurityScan -State $State
                if ($menuScan -and -not $menuScan.Pass) {
                    Set-GBuildExitCode -Code 2 -Reason 'security-scan'
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Security') -Fallback 'Security module not loaded.') -State $State
            }
        }
        '1' { if (Get-Command Invoke-DeviceDebug -ErrorAction SilentlyContinue) { return (Invoke-DeviceDebug -State $State -Project $ProjPath -Tfm $AndroidTfm) } else { throw (Get-LocaleMessage -Key 'log.orch.moduleAndroidMissing' -Fallback 'Android module not loaded.') } }
        '2' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $AndroidTfm -OutputSubDir 'apk' -BuildArgs (Get-DeployChoiceArgs -Kind Apk -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '3' { if (-not (Get-Command Invoke-AndroidAabBuild -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-AndroidAabBuild -State $State -ProjPath $ProjPath -AndroidTfm $AndroidTfm -ProjectDir $ProjectDir -ProjectType $ProjectType -Incremental:$Incremental) }
        '4' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $IosTfm -OutputSubDir 'ios' -BuildArgs (Get-DeployChoiceArgs -Kind Ios -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '5' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $MacTfm -OutputSubDir 'mac' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '6' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.msixNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'Windows MSIX requires Windows (current: {0})') }; $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $WinTfm -OutputSubDir 'win' -BuildArgs (Get-DeployChoiceArgs -Kind WinMsix -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '7' { if (-not (Get-Command Invoke-WebPublish -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-WebPublish -State $State -ProjPath $ProjPath -DefaultTfm $DefaultTfm -ProjectType $ProjectType -ProjectDir $ProjectDir -Incremental:$Incremental) }
        '8' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.desktopPublishNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'Desktop publish requires Windows (current: {0})') }; if (-not (Get-Command Invoke-DesktopPublish -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-DesktopPublish -State $State -ProjPath $ProjPath -WinTfm $WinTfm -Tfms $Tfms -DefaultTfm $DefaultTfm -ProjectType $ProjectType -Incremental:$Incremental) }
        '9' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.wpfPublishNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'WPF publish requires Windows (current: {0})') }; $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $WinTfm -OutputSubDir 'wpf' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '10' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'console' -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        '11' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'lib' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '12' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'default' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '13' {
            $fmtNonInteractive = 'aab'
            $fmtInteractive = 'apk'
            try {
                if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                    $fmtNonInteractive = [string](Get-BuildConstant -Key 'CiPackageFormatNonInteractive' -State $State -Fallback 'aab')
                    $fmtInteractive = [string](Get-BuildConstant -Key 'CiPackageFormatInteractive' -State $State -Fallback 'apk')
                }
            } catch { }
            $fmt = if ($State.NonInteractive -or $State.IsCI) { $fmtNonInteractive } else { $fmtInteractive }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.ghTriggeringFormat' -MessageArgs @([string]$fmt) -Fallback 'Triggering GitHub Actions workflow - format: {0}')
            # The verdict must come from the callee. Invoke-GitHubBuild returns
            # early when the `gh` CLI is absent, and this arm used to print
            # "GitHub Actions triggered (fmt)" unconditionally - so a machine with
            # no gh CLI produced a GREEN "triggered" for a build that was never
            # triggered. That is the worst class of lie in a build tool: it
            # converts a missing prerequisite into a silent pass. Combined with
            # the uniform-return contract at the end of this function, which
            # turns an unset $choiceResult into Succeeded/NoArtifact, a
            # non-interactive run with no gh reported total success.
            $ghResult = $null
            if (Get-Command Invoke-GitHubBuild -ErrorAction SilentlyContinue) {
                $ghResult = Invoke-GitHubBuild -State $State -PackageFormat $fmt
            }
            if ($ghResult -and ($ghResult.ContainsKey('Success')) -and -not [bool]$ghResult.Success) {
                $choiceResult = New-BuildResult -Status Failed -Operation 'target:13' -ReasonCode 'GitHubTriggerFailed' -Message ([string]$ghResult.Message)
            } elseif ($ghResult -and $ghResult.ContainsKey('Success') -and [bool]$ghResult.Success) {
                Write-Done (Resolve-LogMessage -Key 'log.orchestrator.githubTriggered' -MessageArgs @([string]$fmt) -Fallback 'GitHub Actions triggered ({0})') -State $State
                $choiceResult = New-BuildResult -Status Succeeded -Operation 'target:13' -ReasonCode 'OK' -Message ([string]$ghResult.Message)
            } else {
                # No verdict available (Build module absent, or a callee that
                # predates the Success key). Say so rather than claim success.
                Write-Warn (Resolve-LogMessage -Key 'log.orchestrator.githubTriggerUnverified' -Fallback 'GitHub build dispatch returned no verdict; treat the remote workflow as NOT triggered') -State $State
                $choiceResult = New-BuildResult -Status Skipped -Operation 'target:13' -ReasonCode 'NoVerdict' -Message 'GitHub build dispatch returned no verdict'
            }
        }
        '14' {
            # The result must be CAPTURED. '14' is in Get-BuildTargetChoices, so
            # the single validation point at the end of this function runs
            # Test-RequiredResult against $choiceResult; with the assignment
            # missing that variable was still $null, Test-RequiredResult read it
            # as a failed result, and the dispatcher threw "Build target '14'
            # failed" AFTER the parallel build had already reported
            # "3 succeeded, 0 failed". The bug was invisible only because target
            # 14 was unreachable (see the ScanProject import fix); the moment the
            # flow became reachable the false failure surfaced.
            if ($ParallelProjects -and $ParallelProjects.Count -gt 0) {
                $choiceResult = Invoke-GuildParallelBuild -State $State -Projects $ParallelProjects -Tfm $DefaultTfm -MaxJobs (Get-BuildConstant -Key 'ParallelMaxJobs' -State $State -Fallback 8)
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.orchestrator.parallelUnavailable' -Fallback 'Parallel build not available: no independent projects detected') -State $State
                $choiceResult = New-BuildResult -Status Skipped -Operation 'target:14' -ReasonCode 'NoProjects' -Message 'Parallel build needs independent projects'
            }
        }
        'X' {
            $choiceResult = Invoke-GuildDistributedBuild -State $State -Projects $ParallelProjects
        }
        '15' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'aot' -BuildArgs (Get-DeployChoiceArgs -Kind Aot -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        'A' { return (Invoke-RegisteredDeploy -Choice 'A' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'B' { return (Invoke-RegisteredDeploy -Choice 'B' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'V' { return (Invoke-RegisteredDeploy -Choice 'V' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'H' {
            if (Get-Command Show-GBuildHelp -ErrorAction SilentlyContinue) {
                Show-GBuildHelp
            } elseif (Get-Command Get-Help -ErrorAction SilentlyContinue) {
                Get-Help Start-GBuild
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m07') 'Warn' $State
            }
        }
        'R' {
            if (Get-Command Show-BuildReport -ErrorAction SilentlyContinue) {
                Show-BuildReport -State $State
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Report') -Fallback 'Report module not loaded.') -State $State
            }
        }
        'C' {
            if (Get-Command Get-CacheStatistics -ErrorAction SilentlyContinue) {
                Get-CacheStatistics -State $State
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m08') 'Warn' $State
            }
        }
        'L' {
            # versioning.generateChangelog gates changelog emission. The key was
            # declared in config but never read, so operators could not suppress
            # changelog generation. Defaults to true (previous behaviour).
            $genChangelog = $true
            if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
                $cfgGen = Get-ConfigValue -Path 'versioning.generateChangelog' -State $State
                if ($null -ne $cfgGen) { $genChangelog = [bool]$cfgGen }
            }
            if (-not $genChangelog) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m09') 'Gray' $State
            } elseif (Get-Command New-Changelog -ErrorAction SilentlyContinue) {
                New-Changelog -State $State
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m10') 'Warn' $State
            }
        }
        'W' { Invoke-HotReload -State $State -ProjPath $ProjPath -ProjectDir $projectDir -ProjectType $projectType }
        'G' { return (Invoke-RegisteredDeploy -Choice 'G' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'P' { return (Invoke-RegisteredDeploy -Choice 'P' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'F' { return (Invoke-RegisteredDeploy -Choice 'F' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'E' { return (Invoke-RegisteredDeploy -Choice 'E' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'K' { return (Invoke-RegisteredDeploy -Choice 'K' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'Y' { return (Invoke-RegisteredDeploy -Choice 'Y' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        '16' {
            if ($ProjectType -ne 'Avalonia') { throw (Get-LocaleMessage -Key 'log.orch.linuxDesktopNeedsAvalonia' -MessageArgs @([string]$ProjectType) -Fallback 'Linux Desktop publish requires an Avalonia project (current: {0})') }
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            # Fallback is the CONFIGURED deploy RID (Get-DeployDefaultRid),
            # not a hardcoded 'linux-x64' - that literal made a Linux Desktop
            # publish target linux-x64 even on Windows/macOS.
            $rid = if (Get-Command Get-RuntimeIdentifier -ErrorAction SilentlyContinue) { [string](Get-RuntimeIdentifier) } else { [string](Get-DeployDefaultRid -State ) }
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'linux' -BuildArgs @('-r', $rid, '--self-contained', 'true') -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        '17' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $rid = if ($State.OS -eq 'MacOS') { if (Get-Command Get-RuntimeIdentifier -ErrorAction SilentlyContinue) { [string](Get-RuntimeIdentifier) } else { 'osx-arm64' } } else { 'osx-x64' }
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'macos' -BuildArgs @('-r', $rid, '--self-contained', 'true') -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        'N' {
            $null = Assert-BuildCommandAvailable -Command 'Publish-Environment' -MessageKey 'log.orch.moduleDeployTargetsMissing' -Fallback 'DeployTargets module not loaded.'
            if ($PipelineContext -and ($PipelineContext.ContainsKey('NewEnvironment')) -and $PipelineContext.NewEnvironment) {
                $null = Assert-BuildCommandAvailable -Command 'Add-DeployEnvironment' -MessageKey 'log.orch.deployEnvRegUnavailable' -Fallback 'DeployTargets environment registration is unavailable.'
                $ne = $PipelineContext.NewEnvironment
                Add-DeployEnvironment -State $State -Name ([string]$ne.Name) -Branch ([string]$ne.Branch) -Targets @($ne.Targets) | Out-Null
            }
            if (Get-Command Invoke-DeployGroup -ErrorAction SilentlyContinue) {
                $hasGroups = $false
                $og = Get-ConfigSection -State $State -Path 'deploy.order'
                if ($og -and ($og.PSObject.Properties.Name -contains 'groups') -and @($og.groups).Count -gt 0) { $hasGroups = $true }
                if ($hasGroups) {
                    $groupResult = Invoke-DeployGroup -State $State
                    if (-not (Test-RequiredResult -Result $groupResult -Operation 'deploy:group')) { throw (Get-LocaleMessage -Key 'log.orch.deployGroupFailed' -Fallback 'Deploy group failed.') }
                }
            }
            $fromEnv = Get-ConfigValue -Path 'deploy.promotion.from' -State $State -Default 'staging'
            $toEnv = Get-ConfigValue -Path 'deploy.promotion.to' -State $State -Default 'production'
            Write-Info (Get-LocaleMessage -Key 'log.orchestrator.m11' -MessageArgs @($fromEnv, $toEnv)) $State
            $choiceResult = Publish-Environment -State $State -From $fromEnv -To $toEnv
            if (-not (Test-RequiredResult -Result $choiceResult -Operation 'deploy:promotion')) { throw (Get-LocaleMessage -Key 'log.orch.envPromotionFailed' -MessageArgs @([string]$fromEnv, [string]$toEnv) -Fallback "Environment promotion '{0}' -> '{1}' failed.") }
        }
        'Z' {
            if (Get-Command Invoke-ChaosSuite -ErrorAction SilentlyContinue) {
                $suite = Invoke-ChaosSuite -State $State
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m12' -MessageArgs @($($suite.Status), $($suite.Passed), $($suite.Failed), $($suite.Skipped))) $(if ($suite.Status -eq 'Passed') { 'Succ' } elseif ($suite.Status -eq 'Partial') { 'Warn' } else { 'Err' }) $State
                # The suite result used to be log-only: $choiceResult stayed $null
                # and the tail of this function reported Succeeded/NoArtifact, so
                # a Degraded drill (drill harness broke) exited 0. A drill the
                # operator explicitly requested is an operation like any other:
                # Skipped (chaos disabled) and Passed/Partial (drills injected)
                # succeed; Degraded (a scenario Failed/Errored, i.e. the drill
                # itself broke) fails. Z is in Get-FatalActionChoices, so a
                # Failed verdict aborts the run instead of reporting success.
                $zStatus = if ($suite -and $suite.Status -eq 'Degraded') { 'Failed' } elseif ($null -eq $suite) { 'Failed' } else { 'Succeeded' }
                $zReason = if ($null -eq $suite) { 'NullResult' } elseif ($suite.Status -eq 'Degraded') { 'DrillFailed' } elseif ($suite.Status -eq 'Skipped') { 'Skipped' } else { 'OK' }
                $zDetail = if ($suite) { "Chaos suite: $($suite.Status) (passed $($suite.Passed), failed $($suite.Failed), skipped $($suite.Skipped))" } else { 'Chaos suite returned no result' }
                $choiceResult = New-OperationResult -Status $zStatus -Operation 'target:Z' -ReasonCode $zReason -Message $zDetail
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Chaos') -Fallback 'Chaos module not loaded.') -State $State
            }
        }
        'M' {
            if (Get-Command Get-AnomalyReport -ErrorAction SilentlyContinue) {
                $report = Get-AnomalyReport -State $State
                if ($report.Status -eq 'Disabled') {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m13') 'Gray' $State
                } elseif ($report.Status -eq 'InsufficientData') {
                    $anCfg = Get-AnomalyConfig -State $State
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m14' -MessageArgs @($($report.SampleCount), $($anCfg.minSamples))) 'Warn' $State
                } else {
                    $icon = if ($report.MaxSeverity -in @('High','Critical')) { 'Err' } elseif ($report.MaxSeverity -eq 'Medium') { 'Warn' } else { 'Succ' }
                    Write-Log "[ANOMALY] $($report.Summary)" $icon $State
                    foreach ($a in $report.Anomalies) {
                        $aIcon = switch ($a.Severity) { 'Critical' { 'Err' } 'High' { 'Err' } 'Medium' { 'Warn' } default { 'Warn' } }
                        Write-Log "  [$($a.Dimension)] $($a.Suggestion)" $aIcon $State
                    }
                    if (Get-Command Write-AnomalyHistory -ErrorAction SilentlyContinue) { [void](Write-AnomalyHistory -Report $report -State $State) }
                    [void](Send-AnomalyAlertIfNeeded -Report $report -State $State)
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('AnomalyDetector') -Fallback 'AnomalyDetector module not loaded.') -State $State
            }
        }
        'T' {
            $testFlags = Get-BuildTestConfig -State $State
            if (-not $testFlags.TestEnabled) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m15') 'Gray' $State
                $choiceResult = [pscustomobject]@{ Status = 'Succeeded'; Skipped = $true; Message = 'Tests disabled by configuration' }
                break
            }
            $testLang = if ($PipelineContext -and $PipelineContext.langInfo) {
                if ($PipelineContext.langInfo.Language) { [string]$PipelineContext.langInfo.Language } else { [string]$PipelineContext.langInfo }
            } else { $ProjectType }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningTests' -MessageArgs @([string]$testLang) -Fallback 'Running tests for {0}...')
            # Menu 'T' must not also run lint when lintEnabled is true; scope the
            # shared gate to this stage, while keeping the real implementation here.
            $testOnlyFlags = [PSCustomObject]@{ TestEnabled = $true; LintEnabled = $false }
            [void](Invoke-PluginTestAndLintGate -State $State -ProjectDir $ProjectDir -Language $testLang -TestFlags $testOnlyFlags -Detailed)
            $choiceResult = [pscustomobject]@{ Status = 'Succeeded' }
            Write-Done (Resolve-LogMessage -Key 'log.orchestrator.testsPassed' -MessageArgs @([string]$testLang) -Fallback 'Tests passed ({0})') -State $State
        }
        'I' {
            $testFlags = Get-BuildTestConfig -State $State
            if (-not $testFlags.LintEnabled) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m16') 'Gray' $State
                $choiceResult = [pscustomobject]@{ Status = 'Succeeded'; Skipped = $true; Message = 'Lint disabled by configuration' }
                break
            }
            $lintLang = if ($PipelineContext -and $PipelineContext.langInfo) {
                if ($PipelineContext.langInfo.Language) { [string]$PipelineContext.langInfo.Language } else { [string]$PipelineContext.langInfo }
            } else { $ProjectType }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningLint' -MessageArgs @([string]$lintLang) -Fallback 'Running lint for {0}...')
            # Menu 'I' must not also run tests when testEnabled is true; scope the
            # shared gate to this stage, while keeping the real implementation here.
            $lintOnlyFlags = [PSCustomObject]@{ TestEnabled = $false; LintEnabled = $true }
            [void](Invoke-PluginTestAndLintGate -State $State -ProjectDir $ProjectDir -Language $lintLang -TestFlags $lintOnlyFlags -Detailed)
            $choiceResult = [pscustomobject]@{ Status = 'Succeeded' }
            Write-Done (Resolve-LogMessage -Key 'log.orchestrator.lintPassed' -MessageArgs @([string]$lintLang) -Fallback 'Lint passed ({0})') -State $State
        }
        'O' {
            Write-StepTitle 'MULTI-CLUSTER ORCHESTRATION' 'Info' $State
            if (Get-Command Get-AllClusters -ErrorAction SilentlyContinue) {
                $clusters = Get-AllClusters -State $State
                if ($clusters.Count -eq 0) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m17') 'Warn' $State
                } else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m18' -MessageArgs @($($clusters.Count))) 'Info' $State
                    foreach ($c in $clusters) {
                        $status = if ($c.Status -eq 'Ready') { 'Succ' } elseif ($c.Status -eq 'Registering') { 'Warn' } else { 'Err' }
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m19' -MessageArgs @($($c.Name), $($c.Region), $($c.Zone), $($c.Status), $($c.ActiveBuilds), $($c.MaxConcurrent))) $status $State
                    }
                }
                $healthy = Get-HealthyClusters -State $State
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m20' -MessageArgs @($($healthy.Count))) 'Info' $State
                # Level 5: wire cluster build submission when PipelineContext carries
                # a ClusterBuildSpec (opt-in, one-shot). Daemon entry points
                # (Start-ClusterHealthMonitor, Start/Stop-CoordinatorLeaderElection)
                # are intentionally NOT run synchronously here (infinite loops);
                # they are launched as background jobs only when cluster.enabled,
                # and Install-GBuildOperator is invoked for operator setup.
                try {
                    $spec = $null
                    if ($PipelineContext -and ($PipelineContext.ContainsKey('ClusterBuildSpec'))) { $spec = $PipelineContext.ClusterBuildSpec }
                    # Producer for ClusterBuildSpec. Submit-ClusterBuild /
                    # Get-ClusterBuildStatus / Wait-ClusterBuild / Stop-ClusterBuild
                    # / Install-GBuildOperator / Get-GBuildCRDs (~350 lines) were
                    # all gated on PipelineContext.ClusterBuildSpec, and NOTHING
                    # ever set that key - so the entire Kubernetes build
                    # submission path was unreachable in every run. Build the
                    # spec from the resolved project when
                    # build.cluster.submit.enabled is true.
                    if (-not $spec) {
                        try {
                            $submitEnabled = [bool](Get-ConfigValue -Path 'build.cluster.submit.enabled' -State $State -Default $false)
                            if ($submitEnabled -and (Get-Command Submit-ClusterBuild -ErrorAction SilentlyContinue)) {
                                # Submit-ClusterBuild declares -BuildSpec as
                                # [hashtable]; a PSCustomObject is not bindable.
                                # Resolve the name WITHOUT a nested (if ...) -
                                # that is not a subexpression on PS 5.1.
                                $specBase = ''
                                if ($State.ProjectRoot) { $specBase = [string]$State.ProjectRoot } else { $specBase = [string]$State.ScriptRoot }
                                $specProject = [string]$ProjectType
                                if ([string]::IsNullOrWhiteSpace($specProject)) { $specProject = (Split-Path $specBase -Leaf) }
                                $spec = @{
                                    ProjectName    = $specProject
                                    Namespace      = [string](Get-ConfigValue -Path 'build.cluster.job.namespace' -State $State -Fallback 'gbuild-jobs')
                                    BuilderImage   = [string](Get-ConfigValue -Path 'build.cluster.submit.builderImage' -State $State -Fallback (Get-ConfigValue -Path 'build.cluster.builderImage' -State $State -Fallback ''))
                                    ServiceAccount = [string](Get-ConfigValue -Path 'build.cluster.workloadIdentity.serviceAccount' -State $State -Fallback '')
                                    RepoRoot       = $specBase
                                    Command        = [string](Get-ConfigValue -Path 'build.cluster.submit.command' -State $State -Fallback '')
                                }
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m21' -MessageArgs @($($spec.ProjectName))) 'Info' $State
                            }
                        } catch { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m22' -MessageArgs @($($_.Exception.Message))) 'Warn' $State }
                    }
                    if ($spec -and (Get-Command Submit-ClusterBuild -ErrorAction SilentlyContinue) -and (Get-Command Wait-ClusterBuild -ErrorAction SilentlyContinue)) {
                        $sub = Submit-ClusterBuild -State $State -BuildSpec $spec
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m23' -MessageArgs @($($sub.BuildId), $($sub.Cluster))) 'Succ' $State
                        if (Get-Command Get-ClusterBuildStatus -ErrorAction SilentlyContinue) {
                            $st = Get-ClusterBuildStatus -BuildId $sub.BuildId -ClusterName $sub.Cluster -State $State
                            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m24' -MessageArgs @($($st.Status))) 'Info' $State
                        }
                        $waited = Wait-ClusterBuild -BuildId $sub.BuildId -ClusterName $sub.Cluster -State $State
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m25' -MessageArgs @($($waited.Status))) $(if ($waited.Status -eq 'Succeeded') { 'Succ' } else { 'Err' }) $State
                        # A submitted-and-waited remote build that did not succeed
                        # used to end here as an Err-colored log line with no
                        # verdict: the arm assigns nothing, the tail reports
                        # Succeeded/NoArtifact, and a failed cluster build exited
                        # 0. O is in Get-FatalActionChoices, so record the real
                        # verdict and let the pipeline abort on failure. (Viewing
                        # clusters without submitting still succeeds: this only
                        # runs after a real submit+wait.)
                        $oStatus = if ($waited -and $waited.Status -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
                        $oReason = if ($waited -and $waited.Status -eq 'Succeeded') { 'OK' } else { 'ClusterBuildFailed' }
                        $oMsg = if ($waited) { "Cluster build $($sub.BuildId) on $($sub.Cluster): $($waited.Status)" } else { "Cluster build $($sub.BuildId) on $($sub.Cluster) returned no result" }
                        $choiceResult = New-OperationResult -Status $oStatus -Operation 'target:O' -ReasonCode $oReason -Message $oMsg -Details $waited
                    }
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m26' -MessageArgs @($($_.Exception.Message))) 'Warn' $State
                }
                try {
                    $clusterEnabled = $false
                    try {
                        # Canonical path is build.cluster (same as Menu 'O'
                        # Supported flag + ClusterOrchestrator init). The old
                        # top-level 'cluster' path never exists in config, so
                        # this gate must read build.cluster or the daemon
                        # wiring below (health job, leader election, operator)
                        # silently never runs.
                        $cc = Get-ConfigSection -State $State -Path 'build.cluster'
                        if ($cc -and ($cc.PSObject.Properties.Name -contains 'enabled')) { $clusterEnabled = [bool]$cc.enabled }
                    } catch { }
                    if ($clusterEnabled) {
                        # Health monitor + leader election run as background jobs (never block the menu).
                        # Both jobs re-derive their own State from gbuild.config.json. The previous
                        # version passed `-State $null` into the job, so
                        # Initialize-ClusterOrchestrator saw no BuildConfig, $script:ClusterCache
                        # stayed empty, and the health monitor spun on an empty collection with
                        # Start-Sleep 30 forever - a permanently running background job that could
                        # never observe anything, in every session where build.cluster.enabled is
                        # true (the shipped default).
                        $jobModules = @('Modules/ConfigProvider.psm1','Modules/Logging.psm1','Modules/PathUtils.psm1','Modules/Environment.psm1','Modules/ErrorHandling.psm1','Modules/SDK.psm1','Modules/EventBus.psm1','Modules/BuildConstants.psm1','Modules/ClusterOrchestrator.psm1')
                        $monitorBody = {
                            param($sr, $mods, $pr)
                            foreach ($m in $mods) { Import-Module (Join-Path $sr $m) -Force -DisableNameChecking -ErrorAction SilentlyContinue }
                            $st = [PSCustomObject]@{ ScriptRoot = $sr; ProjectRoot = $pr; BuildConfig = $null; WorkingDir = $pr }
                            try { $st = Initialize-BuildConfigState -State $st } catch { }
                            Start-ClusterHealthMonitor -State $st
                        }
                        if (Get-Command Start-ClusterHealthMonitor -ErrorAction SilentlyContinue) {
                            $existingHM = Get-Job -Name 'gbuild-cluster-health' -ErrorAction SilentlyContinue
                            if (-not $existingHM) {
                                Start-Job -Name 'gbuild-cluster-health' -ScriptBlock $monitorBody -ArgumentList @([string]$State.ScriptRoot, $jobModules, [string]$State.ProjectRoot) -ErrorAction SilentlyContinue | Out-Null
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m27') 'Gray' $State
                            }
                        }
                        # Leader election was exported, implemented (83 lines of K8s Lease
                        # acquire/renew/release) and never started: the block only logged
                        # "available as background job" and did nothing, so the whole
                        # coordination.k8s.io/v1 path was unreachable. Start it for real.
                        if (Get-Command Start-CoordinatorLeaderElection -ErrorAction SilentlyContinue) {
                            $existingLE = Get-Job -Name 'gbuild-coordinator-leader' -ErrorAction SilentlyContinue
                            if (-not $existingLE) {
                                $leaderBody = {
                                    param($sr, $mods, $pr)
                                    foreach ($m in $mods) { Import-Module (Join-Path $sr $m) -Force -DisableNameChecking -ErrorAction SilentlyContinue }
                                    $st = [PSCustomObject]@{ ScriptRoot = $sr; ProjectRoot = $pr; BuildConfig = $null; WorkingDir = $pr }
                                    try { $st = Initialize-BuildConfigState -State $st } catch { }
                                    Start-CoordinatorLeaderElection -State $st
                                }
                                Start-Job -Name 'gbuild-coordinator-leader' -ScriptBlock $leaderBody -ArgumentList @([string]$State.ScriptRoot, $jobModules, [string]$State.ProjectRoot) -ErrorAction SilentlyContinue | Out-Null
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m28') 'Gray' $State
                            }
                            # StopLeaderElection previously had no producer either.
                            $stopRequested = $false
                            try {
                                if ($PipelineContext -and ($PipelineContext.ContainsKey('StopLeaderElection'))) { $stopRequested = [bool]$PipelineContext.StopLeaderElection }
                            } catch { }
                            # Reads build.cluster.stopLeaderElection, the key that is
                            # actually SHIPPED in gbuild.config.json and declared in the
                            # schema. The old path 'build.cluster.coordinator.stopLeaderElection'
                            # is unshippable (build.cluster is additionalProperties:false),
                            # so this always evaluated the $false default and the shipped
                            # knob was dead.
                            if (-not $stopRequested) { try { $stopRequested = [bool](Get-ConfigValue -Path 'build.cluster.stopLeaderElection' -State $State -Default $false) } catch { } }
                            if ($stopRequested) {
                                $job = Get-Job -Name 'gbuild-coordinator-leader' -ErrorAction SilentlyContinue
                                if ($job) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m29') 'Gray' $State
                            }
                        }
                        if (Get-Command Install-GBuildOperator -ErrorAction SilentlyContinue) {
                            $opRequested = $false
                            try { if ($PipelineContext -and ($PipelineContext.ContainsKey('InstallOperator'))) { $opRequested = [bool]$PipelineContext.InstallOperator } } catch { }
                            # Producer from config: build.cluster.operator.install
                            if (-not $opRequested) { try { $opRequested = [bool](Get-ConfigValue -Path 'build.cluster.operator.install' -State $State -Default $false) } catch { } }
                            if ($opRequested) { Install-GBuildOperator -State $State | Out-Null }
                        }
                        # Reference Stop entry point so it stays wired (no-op unless election running).
                        if (Get-Command Stop-CoordinatorLeaderElection -ErrorAction SilentlyContinue) {
                            $stopRequested = $false
                            try { if ($PipelineContext -and ($PipelineContext.ContainsKey('StopLeaderElection'))) { $stopRequested = [bool]$PipelineContext.StopLeaderElection } } catch { }
                            if ($stopRequested) { Stop-CoordinatorLeaderElection -State $State }
                        }
                    }
                } catch {
                    # benign: cluster daemons must never break the menu
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('ClusterOrchestrator') -Fallback 'ClusterOrchestrator module not loaded.') -State $State
            }
        }
        default {
            # Extensibility: config-driven custom menu entries (build.menu.customEntries).
            # The MenuConfig entry carries a Handler (command name or scriptblock).
            $entry = if ($MenuConfig -and $MenuConfig.ContainsKey($Choice)) { $MenuConfig[$Choice] } else { $null }
            if ($entry -and $entry.Handler) {
                if ($entry.Handler -is [scriptblock]) {
                    & $entry.Handler -State $State -ProjPath $ProjPath -ProjectDir $ProjectDir -ProjectType $ProjectType
                } elseif (Get-Command $entry.Handler -ErrorAction SilentlyContinue) {
                    & $entry.Handler -State $State -ProjPath $ProjPath -ProjectDir $ProjectDir -ProjectType $ProjectType
                } else {
                    Write-Fail (Resolve-LogMessage -Key 'log.menu.handlerNotFound' -MessageArgs @([string]$entry.Handler) -Fallback 'Custom menu handler ''{0}'' not found') -State $State
                }
            } else {
                throw (Get-LocaleMessage -Key 'log.orch.unknownChoice' -MessageArgs @([string]$Choice) -Fallback 'Unknown choice: {0}')
            }
        }
    }
    # SINGLE validation point for build-target results.
    # This list is the canonical "these menu choices produce a build artifact"
    # set. It used to be duplicated verbatim in the pipeline body (with a
    # narrower list) which meant the dispatcher always threw FIRST and the
    # pipeline copy was dead code - its Write-Fail could never run, and its
    # $ctx.buildOk assignment only ever saw success because a failure had
    # already propagated. The pipeline now reads the verdict instead of
    # recomputing it.
    if ($Choice -in (Get-BuildTargetChoices)) {
        if (-not (Test-RequiredResult -Result $choiceResult -Operation "target:$Choice")) {
            $message = if ($choiceResult -and $choiceResult.Message) { [string]$choiceResult.Message } else { "Build target '$Choice' failed" }
            throw $message
        }
    }
    # UNIFORM RETURN CONTRACT. Operations that produce no build artifact - the
    # doctor/security-scan/cache-stats/changelog/gitHub/chaos/anomaly/cluster
    # arms, and '0' (quit) - assign nothing to $choiceResult, so this function
    # used to return $null for them. The pipeline's non-build branch then ran
    # ConvertTo-OperationResult -Value $null, which is Failed/NullResult, and
    # because those same keys (13, S, C, L, ...) are in the privileged set it
    # threw "Target 'X' failed" AFTER the operation had already succeeded. Since
    # Show-GuildMenu answers '13' when non-interactive, EVERY non-interactive
    # build reported failure. Reaching here means the arm completed without
    # throwing, so an explicit Succeeded verdict is the truthful answer.
    if ($null -eq $choiceResult) {
        return New-OperationResult -Status Succeeded -Operation "target:$Choice" -ReasonCode 'NoArtifact' -Message "Target '$Choice' completed (produces no build artifact)"
    }
    return $choiceResult
}

<#
.SYNOPSIS
    Returns the canonical list of menu choices that produce a build artifact.
.DESCRIPTION
    Single source for the build-target verdict. Used by Invoke-GuildChoice to
    validate and by the pipeline to decide whether the result is a build
    result (and therefore whether to run the post-build test/lint stages).
    Previously declared three times in Orchestrator + Menu with drifting
    membership.
#>
function Get-BuildTargetChoices {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $configured = $null
    try { $configured = Get-ConfigValue -Path 'build.targetCatalog.buildChoices' -State $null -Default $null } catch { $configured = $null }
    if ($null -ne $configured -and @($configured).Count -gt 0) { return @($configured | ForEach-Object { [string]$_ }) }
    return @('2','3','4','5','6','7','8','9','10','11','12','14','15','16','17')
}

<#
.SYNOPSIS
    Returns the canonical list of menu choices whose failure must abort the run.
.DESCRIPTION
    Privileged, non-build actions (cluster, distributed, deploy, security,
    chaos, test, lint). A failure here is always fatal.

    THREE layers, in precedence order:
      1. build.targetCatalog.fatalChoices (explicit operator override).
      2. The RBAC privileged set (resolved through Get-RbacPrivilegedActions,
         which is itself config-overridable via
         security.rbac.privilegedActions) UNION the execution-fatal extras
         below. Privilege and fatality are DIFFERENT concepts sharing one
         computation, not one list: X/Z/O/D need no authorization, but a
         failure in any of them must not report success.
      3. Hardcoded union fallback (only when neither RBAC nor BuildConstants
         can be loaded).

    Execution-fatal extras (present here, deliberately ABSENT from
    RbacPrivilegedActions):
      X - Multi-Host Distributed Build. Remote execution across hosts; a
          100%-failed remote run used to exit 0 because X was in neither the
          build set nor the fatal set.
      Z - Chaos drill. An explicitly requested resilience drill whose harness
          reports Degraded (drill failed to inject) is a failed operation.
      O - Cluster submit. An explicitly requested, opted-in
          (build.cluster.submit.enabled) remote build whose waited status is
          not Succeeded is a failed operation.
      D - Doctor. An explicitly requested health check on a broken environment
          reporting success is a lie; -Target D is the CI health gate.
    W (HotReload, long-running watcher), M (Anomaly, analysis completed =
    success even with Critical findings; execution errors already throw) and
    T/I (test/lint, already throw via Invoke-PluginTestAndLintGate) are
    deliberately NOT here.
#>
function Get-FatalActionChoices {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    # Layer 1: explicit operator override.
    try {
        $override = Get-ConfigValue -Path 'build.targetCatalog.fatalChoices' -State $State -Default $null
        if ($null -ne $override -and @($override).Count -gt 0) { return @(@($override) | ForEach-Object { [string]$_ }) }
    } catch { }
    # Layer 2: privileged set (single-sourced in the RBAC accessor) plus the
    # execution-fatal extras. The privileged list is READ here, never copied:
    # the previous implementation carried its own 14-key verbatim copy that had
    # already drifted twice from the owner.
    $privileged = @()
    try {
        if (Get-Command Get-RbacPrivilegedActions -ErrorAction SilentlyContinue) {
            $privileged = @(Get-RbacPrivilegedActions)
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $privileged = @(Get-BuildConstant -Key 'RbacPrivilegedActions' -State $State -Fallback @())
        }
    } catch { $privileged = @() }
    $fatal = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($privileged)) { $v = [string]$k; if ($v -and -not $fatal.Contains($v)) { [void]$fatal.Add($v) } }
    foreach ($k in @('X', 'Z', 'O', 'D')) { if (-not $fatal.Contains($k)) { [void]$fatal.Add($k) } }
    if ($fatal.Count -gt 0) { return @($fatal.ToArray()) }
    # Layer 3: nothing loaded. Verbatim union of the RbacPrivilegedActions
    # fallback (RBAC.psm1 Get-RbacPrivilegedActions) and the extras above.
    return @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13','X','Z','O','D')
}

<#
    .SYNOPSIS
        Main entry point for the gbuild build system.
    .DESCRIPTION
        Orchestrates the full build pipeline: config validation, SDK detection,
        profile loading, project scanning, menu display, and build dispatch.
        Handles standalone operations (clean, cache, version bump) as well.
    .PARAMETER GitHub
        Trigger GitHub Actions workflow (non-interactive mode).
    .PARAMETER NonInteractive
        Run without user prompts.
    .PARAMETER Incremental
        Skip clean step, build incrementally.
    .PARAMETER Clean
        Perform smart clean only (bin/obj/cache).
    .PARAMETER CacheClear
        Clear the build cache.
    .PARAMETER CacheOptimize
        Optimize the build cache.
    .PARAMETER CacheStats
        Display cache statistics.
    .PARAMETER VersionBump
        Auto-increment project version.
    .PARAMETER LogLevel
        Log verbosity level (Error, Warn, Info, Debug).
    #>

<#
.SYNOPSIS
    Resolves the effective pipeline step list from config + caller-supplied steps.
.DESCRIPTION
    When build.pipeline.steps is defined in config, those entries are used.
    Otherwise the caller-supplied $Steps array is returned as-is.
    Config steps: array of @{ Name; ScriptBlock; When; Retry; TimeoutSeconds }
    Level 5: build.pipeline.validate=true enforces required name+script and
    warns on unknown keys; script/when bodies are validated with the PowerShell
    parser before ScriptBlock::Create so config typos fail fast (no sandbox —
    config is trusted local input, same trust as gbuild.ps1).
#>
<#
.SYNOPSIS
    Resolves the effective pipeline step list from a gbuild.pipeline.yml file.
.DESCRIPTION
    Returns $null when no pipeline file is present, so the caller falls through
    to build.pipeline.steps. Returns an array when one is.

    The module is imported on demand rather than at Tier-1: it is only needed
    by projects that actually adopt pipeline-as-code, and it is a pure parser
    with no state. Validation failures PROPAGATE (do not get swallowed) - a
    malformed pipeline must fail the build loudly rather than silently
    reverting to the built-in pipeline.
.OUTPUTS
    Array of step hashtables, or $null.
#>
function Resolve-PipelineYamlSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param([PSCustomObject]$State)

    $hasCommand = [bool](Get-Command Get-BuildYamlPipelineDocument -ErrorAction SilentlyContinue)
    if (-not $hasCommand) {
        $yamlPath = Join-Path $PSScriptRoot 'YamlPipeline.psm1'
        if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) { return $null }
        Import-ModuleOnDemand -ModuleNames @('YamlPipeline')
        if (-not (Get-Command Get-BuildYamlPipelineDocument -ErrorAction SilentlyContinue)) { return $null }
    }

    $doc = Get-BuildYamlPipelineDocument -State $State
    if ($null -eq $doc) { return $null }

    # Throws on an invalid pipeline: the operator asked for this file, so
    # silently building something else would be worse than failing.
    Test-PipelineYamlDocument -Document $doc -State $State | Out-Null

    $envApplied = Set-PipelineYamlEnvironment -Document $doc -State $State
    try {
        $steps = ConvertFrom-PipelineYamlStep -Document $doc -State $State
    } finally {
        Clear-PipelineYamlEnvironment -Applied $envApplied
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $src = ''
        try { if ($doc.PSObject.Properties.Name -contains 'SourcePath') { $src = [string]$doc.SourcePath } } catch { }
        Write-Log (Get-LocaleMessage -Key 'log.pipeline.yamlLoaded' -MessageArgs @(@($steps).Count, $src)) 'Info' $State
    }
    return ,@($steps)
}

function Resolve-PipelineSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [PSCustomObject]$State,
        [array]$CallerSteps
    )
    # Normalize caller steps to an array: PowerShell unrolls a 1-element array into a scalar
    # both at parameter binding and at return, so EVERY return path must wrap with ,@() once
    # to preserve the "returns an array of steps" contract (even when CallerSteps is scalar/$null).
    if ($null -eq $CallerSteps) { return ,@() }
    $callerArr = @($CallerSteps)

    $cfg = Get-ConfigSection -State $State -Path 'build.pipeline'

    # -- Pipeline-as-code (gbuild.pipeline.yml) --------------------------------
    # A YAML pipeline, when present, takes precedence over build.pipeline.steps
    # in gbuild.config.json. Previously README documented this whole feature
    # while nothing implemented it: no YAML parser existed, no example file was
    # shipped, and Resolve-PipelineSteps only ever read the JSON key - so a
    # `gbuild.pipeline.yml` was silently ignored.
    $yamlSteps = Resolve-PipelineYamlSteps -State $State
    if ($yamlSteps) { return ,@($yamlSteps) }

    if (-not $cfg -or -not ($cfg.PSObject.Properties.Name -contains 'steps')) {
        return ,@($callerArr)
    }

    $rawSteps = $cfg.steps
    if ($null -eq $rawSteps) { return ,@($callerArr) }
    $validate = $true
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $validate = [bool](Get-BuildConstant -Key 'PipelineValidate' -State $State -Fallback $true)
        } elseif ($cfg.PSObject.Properties.Name -contains 'validate') {
            $validate = [bool]$cfg.validate
        }
    } catch { $validate = $true }
    $resolved = [System.Collections.ArrayList]::new()
    $cfgSteps = @($rawSteps)
    if ($cfgSteps.Count -eq 0) { return ,@($callerArr) }
    # L5: pipeline mode (default 'replace' = legacy behaviour). 'append' runs
    # caller steps then config steps; 'merge' overrides same-name caller steps
    # in place and appends new names. Previously any non-empty config steps
    # REPLACED the 12 built-in steps, so a one-step typo silently dropped
    # RegisterPlugins..Build. Mode is additive and defaults to replace, so
    # existing configs/tests are unaffected.
    $mode = 'replace'
    try {
        if ($cfg.PSObject.Properties.Name -contains 'mode' -and $cfg.mode) { $mode = ([string]$cfg.mode).ToLowerInvariant() }
    } catch { $mode = 'replace' }
    if ($mode -notin @('replace','merge','append')) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m31' -MessageArgs @("mode='$mode'", 'replace, merge, append')) 'Warn' $State
        }
        $mode = 'replace'
    }
    $allowedKeys = @('name', 'script', 'when', 'retry', 'timeoutSeconds', 'jobIsolated')
    foreach ($cfgStep in @($cfg.steps)) {
        $propNames = @($cfgStep.PSObject.Properties.Name)
        if ($validate) {
            # Missing 'script' is fatal (nothing to run); missing 'name' stays
            # backward-compatible (defaults to StepN, covered by PipelineRunner.Tests).
            if (-not ($propNames -contains 'script')) {
                throw (Get-LocaleMessage -Key 'log.orch.pipelineStepMissingScript' -MessageArgs @([string]($propNames -join ', ')) -Fallback "Invalid build.pipeline.steps entry: each step requires 'script' (got: {0}).")
            }
            if (-not ($propNames -contains 'name') -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m30' -MessageArgs @($($resolved.Count))) 'Warn' $State
            }
            $unknown = @($propNames | Where-Object { $_ -notin $allowedKeys })
            if ($unknown.Count -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m31' -MessageArgs @($($unknown -join ', '), $($allowedKeys -join ', '))) 'Warn' $State
            }
        }
        $scriptBody = if ($propNames -contains 'script') { [string]$cfgStep.script } else { '' }
        $whenBody = if ($propNames -contains 'when') { [string]$cfgStep.when } else { $null }
        # Fail fast on PowerShell parse errors (trusted local config, no sandbox).
        foreach ($body in @(@{ Label = 'script'; Text = $scriptBody }, @{ Label = 'when'; Text = $whenBody })) {
            if ([string]::IsNullOrWhiteSpace($body.Text)) { continue }
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($body.Text, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                throw (Get-LocaleMessage -Key 'log.orch.pipelineStepParseError' -MessageArgs @([string]$cfgStep.name, [string]$body.Label, [string]$parseErrors.Count, [string]$parseErrors[0].Message) -Fallback "Invalid build.pipeline.steps entry '{0}': {1} has {2} parse error(s): {3")
            }
        }
        $entry = @{
            Name = if ($propNames -contains 'name') { $cfgStep.name } else { "Step$($resolved.Count)" }
            Script = if ($propNames -contains 'script') { [scriptblock]::Create($scriptBody) } else { { } }
        }
        if ($propNames -contains 'when') {
            $entry.When = [scriptblock]::Create($whenBody)
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'retry') {
            $entry.Retry = [int]$cfgStep.retry
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'timeoutSeconds') {
            $entry.TimeoutSeconds = [int]$cfgStep.timeoutSeconds
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'jobIsolated') {
            $entry.JobIsolated = [bool]$cfgStep.jobIsolated
        }
        $resolved.Add($entry) | Out-Null
    }
    if ($mode -eq 'append') {
        $combined = [System.Collections.ArrayList]::new()
        foreach ($c in @($callerArr)) { [void]$combined.Add($c) }
        foreach ($e in @($resolved.ToArray())) { [void]$combined.Add($e) }
        return ,@($combined.ToArray())
    }
    if ($mode -eq 'merge') {
        $merged = [System.Collections.ArrayList]::new()
        foreach ($c in @($callerArr)) { [void]$merged.Add($c) }
        $nameIndex = @{}
        for ($i = 0; $i -lt $merged.Count; $i++) {
            $n = ''
            try {
                $item = $merged[$i]
                if ($item -is [System.Collections.IDictionary]) { if ($item.Contains('Name')) { $n = [string]$item['Name'] } }
                elseif ($item -and $item.PSObject -and $item.PSObject.Properties.Name -contains 'Name') { $n = [string]$item.Name }
            } catch { $n = '' }
            if ($n -ne '') { $nameIndex[$n] = $i }
        }
        foreach ($e in @($resolved.ToArray())) {
            $en = [string]$e['Name']
            if ($en -ne '' -and $nameIndex.ContainsKey($en)) { $merged[$nameIndex[$en]] = $e }
            else { [void]$merged.Add($e) }
        }
        return ,@($merged.ToArray())
    }
    # Preserve the documented "Returns: array" contract even for a single config
    # step — $resolved.ToArray() unrolls to a bare hashtable on a single item.
    return ,@($resolved.ToArray())
}

function Get-PipelineStepDisplayName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StepName)
    $key = "log.stepName.$StepName"
    $text = Get-LocaleMessage -Key $key -Fallback $StepName
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq $key) { return $StepName }
    return $text
}

<#
.SYNOPSIS
    Executes a single pipeline step with optional retry.
.DESCRIPTION
    Per-step timeoutSeconds is cooperatively enforced as an SLA: the step runs
    in-process, wall-clock is measured, and exceeding the SLA fails the step
    (retry if enabled). True preemptive kill is deliberately NOT attempted —
    killing a step mid-execution in-process would corrupt shared build state.
    Whole-pipeline stepTimeoutSeconds watchdog shares the same post-hoc semantics.
#>
<#
.SYNOPSIS
    Runs one pipeline-step attempt inside a background job with a hard timeout.
.DESCRIPTION
    This is the REAL pre-emptive enforcement behind timeoutSeconds. The
    in-process path can only measure a breach after the step body returns -
    a hung step hangs the pipeline. A Start-Job child is a separate process:
    when Wait-Job exceeds the timeout, Stop-Job kills it and the step fails
    with a StepTimeout error that the normal retry loop then handles exactly
    like the in-process SLA breach (same FullyQualifiedErrorId).

    CONTRACT (must hold for the merge-back to be faithful):
      * The step body runs against a DESERIALIZED COPY of $Context. Whatever
        it assigns is merged back key-by-key on success, so $ctx.csproj,
        $ctx.buildOk, $ctx.skippedSteps and friends survive. New keys the
        step creates are added too.
      * $State travels as a read-only snapshot. A step that MUTATES $State
        (rather than $ctx) loses those writes in job mode - every built-in
        step communicates via $ctx, so this only binds custom steps, and it
        is stated here rather than discovered in production.
      * Module functions the step calls (Register-Plugins, Write-Log,
        Import-ModuleOnDemand, ...) resolve because the job bootstraps the
        real module tree from $ModulesRoot. A step that depends on the
        CALLER's live session (closures, $script: state, runspace-bound COM
        objects) cannot cross the process boundary and must stay in-process.
      * Step output objects do not survive serialization with their types;
        they come back as strings/property bags. The engine discards step
        output (Out-Null), so this binds direct callers only.
.OUTPUTS
    The step's output array (stringified for safe transport).
#>
function Invoke-PipelineStepJobAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Step,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [int]$TimeoutSec,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$ModulesRoot
    )
    $scriptText = [string]$Step.Script
    # PID-qualified: two concurrent builds running the same step name would
    # otherwise share one job name, so Get-Job/Wait-Job/Stop-Job could attach
    # to the sibling build's job. (The cluster daemon jobs above dedupe by
    # fixed name intentionally - they are singletons. Step attempts are not.)
    $jobName = 'gbuild-step-{0}-{1}' -f ([string]$Step.Name -replace '[^A-Za-z0-9_-]', '_'), $PID
    $job = $null
    try {
        $job = Start-Job -Name $jobName -ScriptBlock {
            param($ScriptText, $CtxData, $StateData, $Root)
            $ErrorActionPreference = 'Stop'
            # Locale first: the bootstrap failure below must itself be
            # localizable, and Locale is a leaf module with no dependencies.
            $localeMod = Join-Path $Root 'Locale.psm1'
            if (Test-Path -LiteralPath $localeMod -PathType Leaf) {
                Import-Module $localeMod -Global -DisableNameChecking -ErrorAction SilentlyContinue | Out-Null
            }
            $modPath = Join-Path $Root 'Orchestrator.psm1'
            if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) {
                $bootMsg = 'log.pipeline.jobBootstrap'
                if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
                    $bootMsg = Get-LocaleMessage -Key 'log.pipeline.jobBootstrap' -MessageArgs @($Root)
                }
                throw $bootMsg
            }
            Import-Module $modPath -Global -DisableNameChecking -ErrorAction Stop | Out-Null
            $Context = $CtxData
            $State = $StateData
            $stepBody = [scriptblock]::Create($ScriptText)
            $output = & $stepBody $Context 2>&1
            # Same failure contract as the in-process path: an ErrorRecord or
            # Exception anywhere in the output stream fails the attempt, with
            # the root message preserved.
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw (Resolve-LogMessage -Key 'log.orchestrator.stepFailed' -MessageArgs @([string]$detail) -Fallback ('STEPFAILED: {0}' -f $detail))
                }
            }
            return @{ Output = @($output); Context = $Context }
        } -ArgumentList @($scriptText, $Context, $State, $ModulesRoot)
        $done = Wait-Job -Job $job -Timeout $TimeoutSec
        if (-not $done) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new((Get-LocaleMessage -Key 'log.pipeline.jobKilled' -MessageArgs @($DisplayName, $TimeoutSec))),
                'StepTimeout',
                'InvalidOperation',
                $null
            )
        }
        $envelope = Receive-Job -Job $job
        if ($job.State -eq 'Failed') {
            $reason = ''
            try { $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason.Message } catch { $reason = '' }
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "job '$jobName' failed without a recorded reason" }
            if ($reason.StartsWith('STEPFAILED: ')) { throw $reason.Substring('STEPFAILED: '.Length) }
            throw $reason
        }
        if ($null -ne $envelope -and $envelope -is [System.Collections.IDictionary] -and $envelope.Contains('Context')) {
            $back = $envelope['Context']
            if ($back -is [System.Collections.IDictionary]) {
                foreach ($k in @($back.Keys)) {
                    try { $Context[$k] = $back[$k] } catch { }
                }
            }
            if ($envelope.Contains('Output')) { return @($envelope['Output']) }
        }
        return @()
    } finally {
        if ($null -ne $job) {
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-PipelineStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Step,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [string]$LeftBracket = '[',
        [string]$RightBracket = ']'
    )
    $stepName = $Step.Name
    $displayStepName = Get-PipelineStepDisplayName -StepName $stepName
    $stepScript = $Step.Script
    $stepKeys = @($Step.Keys)
    # L5 watchdog: if stepTimeoutSeconds is configured (ROOT-level stepTimeoutSeconds,
    # we monitor elapsed wall-clock time. When exceeded, we log and treat the
    # step as failed (retry if enabled, otherwise pipeline continues). This avoids
    # the Start-Job sandbox isolation problem entirely — the step runs in-process
    # and we simply cut it off after the threshold.
    $stepTimeoutSec = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        [int](Get-BuildConstant -Key 'StepTimeoutSeconds' -State $State -Fallback 0)
    } else { 0 }
    # Always initialize: under Set-StrictMode, referencing an unset $stepWatch
    # inside $action below throws for every step when no timeout is configured.
    $stepWatch = $null
    if ($stepTimeoutSec -gt 0) {
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $retryEnabled = [bool](Get-BuildConstant -Key 'PipelineRetryEnabled' -State $State -Fallback $true)
    $maxRetries = if ($stepKeys -contains 'Retry') { [int]$Step.Retry } else {
        # Fallback to config maxRetries
        [int](Get-BuildConstant -Key 'PipelineMaxRetries' -State $State -Fallback 0)
    }
    if (-not $retryEnabled) { $maxRetries = 0 }
    $timeoutSec = if ($stepKeys -contains 'TimeoutSeconds') { [int]$Step.TimeoutSeconds } else { 0 }
    if ($timeoutSec -lt 0) { $timeoutSec = 0 }

    # Job isolation (opt-in per step via 'job' / 'jobIsolated'). A step that
    # opts in runs its body in a background job with a HARD timeout:
    # Wait-Job stops waiting, Stop-Job kills the hung child process, and the
    # attempt fails with StepTimeout. The in-process path below can only
    # measure a breach after the body returns, so without this a hung step
    # hangs the pipeline. Isolation REQUIRES a timeout: a job without one is
    # rejected loudly rather than silently run in-process.
    $jobIsolated = ($stepKeys -contains 'JobIsolated' -and [bool]$Step.JobIsolated) -or ($stepKeys -contains 'Job' -and [bool]$Step.Job)
    if ($jobIsolated -and $timeoutSec -le 0) {
        throw (Get-LocaleMessage -Key 'log.pipeline.jobNoTimeout' -MessageArgs @($displayStepName))
    }

    # L5: per-step timeoutSeconds is now cooperatively enforced (SLA check).
    # Previously any step setting it threw immediately without running.
    # True preemptive kill is unsafe in-process (state corruption), so we run
    # the step, measure wall-clock, and fail it when the SLA is exceeded —
    # same semantics as the root stepTimeoutSeconds watchdog below. Honest
    # enforcement without pretending to kill mid-execution.
    $stepTimer = $null
    if ($timeoutSec -gt 0) { $stepTimer = [System.Diagnostics.Stopwatch]::StartNew() }

    # Delegate retry logic to ErrorHandling.Invoke-WithRetry (single source for retry semantics)
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        if ($jobIsolated) {
            $action = {
                if ($stepWatch) { $stepWatch.Start() }
                # Each attempt gets the FULL timeout (a killed job is dead and
                # cannot be resumed), matching the standalone fallback below.
                $output = Invoke-PipelineStepJobAttempt -Step $Step -Context $Context -State $State -TimeoutSec $timeoutSec -DisplayName $displayStepName -ModulesRoot $PSScriptRoot
                if ($stepWatch) { $stepWatch.Stop() }
                # Root watchdog still applies post-hoc: a step that finished
                # inside its own timeout may still have blown the pipeline-wide
                # budget, and that breach must fail the step the same way.
                if ($stepTimeoutSec -gt 0 -and $stepWatch -and $stepWatch.Elapsed.TotalSeconds -ge $stepTimeoutSec) {
                    Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $stepTimeoutSec)) 'Warn' $State
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.Exception]::new("Step '$displayStepName' timed out after $stepTimeoutSec s"),
                        "StepTimeout",
                        'InvalidOperation',
                        $null
                    )
                }
                return $output
            }
            return Invoke-WithRetry -Action $action -OperationName "Pipeline step [$displayStepName] (job)" -MaxRetries $maxRetries -State $State
        }
        $action = {
            if ($stepWatch) { $stepWatch.Start() }
            $output = & $stepScript $Context 2>&1
            if ($stepTimer) { $stepTimer.Stop() }
            # Per-step SLA: fail when the step's own timeoutSeconds is exceeded.
            if ($timeoutSec -gt 0 -and $stepTimer -and $stepTimer.Elapsed.TotalSeconds -ge $timeoutSec) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $timeoutSec)) 'Warn' $State
                }
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' exceeded its timeoutSeconds SLA of $timeoutSec s (took $([math]::Round($stepTimer.Elapsed.TotalSeconds,1)) s)"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            # Watchdog: if stepTimeoutSec is configured and step exceeds it, cut off.
            if ($stepTimeoutSec -gt 0 -and $stepWatch -and $stepWatch.IsRunning -and $stepWatch.Elapsed.TotalSeconds -ge $stepTimeoutSec) {
                $stepWatch.Stop()
                Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $stepTimeoutSec)) 'Warn' $State
                # Throw an ErrorRecord so Invoke-WithRetry treats this as a step
                # failure (retry if enabled, otherwise the pipeline sees the
                # timeout). A discarded $null = ErrorRecord would silently
                # swallow the breach — log-only is not enforcement.
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' timed out after $stepTimeoutSec s"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            if ($stepWatch) { $stepWatch.Stop() }
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    # Preserve the root cause: the legacy generic message hid which
                    # command inside the step actually failed (undebuggable builds).
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw ((Get-LocaleMessage -Key 'log.step.failed' -MessageArgs $displayStepName) + ": $detail")
                }
            }
            return $output
        }
        return Invoke-WithRetry -Action $action -OperationName "Pipeline step [$displayStepName]" -MaxRetries $maxRetries -State $State
    }

    # Fallback when ErrorHandling is not loaded (standalone bundle without the
    # Tier-1 chain). This MUST mirror Invoke-WithRetry's contract, otherwise the
    # two paths disagree: the previous version retried EVERY error - including
    # permanent compile/config failures - with NO delay, so maxRetries iterations
    # completed in microseconds and a step with a side effect (publish, deploy,
    # artifact upload) that failed AFTER the side effect was re-executed
    # immediately N times, turning one network timeout into N duplicate uploads.
    $baseDelayMs = 500
    $maxDelayMs = 10000
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $baseDelayMs = [int](Get-BuildConstant -Key 'RetryBaseDelay' -State $State -Fallback 500) } catch { }
        try { $maxDelayMs = [int](Get-BuildConstant -Key 'RetryMaxDelayMs' -State $State -Fallback 10000) } catch { }
    }
    $attempt = 0
    while ($true) {
        try {
            if ($jobIsolated) {
                $output = Invoke-PipelineStepJobAttempt -Step $Step -Context $Context -State $State -TimeoutSec $timeoutSec -DisplayName $displayStepName -ModulesRoot $PSScriptRoot
                return $output
            }
            if ($stepTimer) { try { $stepTimer.Restart() } catch { } }
            $output = & $stepScript $Context 2>&1
            if ($stepTimer) { try { $stepTimer.Stop() } catch { } }
            if ($timeoutSec -gt 0 -and $stepTimer -and $stepTimer.Elapsed.TotalSeconds -ge $timeoutSec) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' exceeded its timeoutSeconds SLA of $timeoutSec s"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw ((Get-LocaleMessage -Key 'log.step.failed' -MessageArgs $displayStepName) + ": $detail")
                }
            }
            return $output
        } catch {
            $attempt++
            # Same transient-only classification as Get-ErrorCategory: retry
            # network/lock/IO style failures, fail fast on anything permanent.
            $category = 'Permanent'
            if (Get-Command Get-ErrorCategory -ErrorAction SilentlyContinue) {
                try { $category = [string](Get-ErrorCategory -ErrorRecord $_) } catch { $category = 'Permanent' }
            } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                $msg = [string]$_.Exception.Message
                if ($msg -match '(?i)timeout|timed out|connection|network|unavailable|temporar|being used by another process|could not obtain a lock') { $category = 'Transient' }
            }
            if ($category -ne 'Transient' -or $attempt -gt $maxRetries) { throw }
            $delay = [Math]::Min($baseDelayMs * [Math]::Pow(2, $attempt - 1), $maxDelayMs)
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                $lb = if ($LeftBracket) { $LeftBracket } else { '[' }
                $rb = if ($RightBracket) { $RightBracket } else { ']' }
                Write-Log "$lb$(Get-LocaleMessage -Key 'log.step.retry' -MessageArgs $displayStepName, $attempt, $maxRetries, $_.Exception.Message) (retry in ${delay}ms)$rb" 'Warn' $State
            }
            Start-Sleep -Milliseconds $delay
        }
    }
}

<#
.SYNOPSIS
    Executes a build pipeline: a sequence of named steps with events, metrics,
    optional retry, timeout, and When conditions.
.DESCRIPTION
    Provides the pipeline step abstraction for Start-GBuild. Each step is a
    hashtable with Name + Script ({ param($ctx) ... }). The runner emits
    EventBus lifecycle events (EVT_BUILD_START / EVT_STEP_START / EVT_STEP_COMPLETE /
    EVT_STEP_ERROR / EVT_BUILD_COMPLETE), records per-step duration metrics,
    honours step-level When/Retry, enforces the whole-pipeline timeout, and
    re-throws on the first step failure so the caller's error handling
    (rollback, telemetry) is preserved.
#>
function Invoke-GBuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [Parameter(Mandatory=$true)] [hashtable]$Context,
        [Parameter(Mandatory=$true)] [array]$Steps
    )

    $lb = if ($State.PSObject.Properties.Name -contains 'LeftBracket') { $State.LeftBracket } else { '[' }
    $rb = if ($State.PSObject.Properties.Name -contains 'RightBracket') { $State.RightBracket } else { ']' }

    $effectiveSteps = Resolve-PipelineSteps -State $State -CallerSteps $Steps
    $cancelled = $false

    # Pipeline-level timeout enforcement
    $pipelineTimeout = 0
    $pipelineTimeout = [int](Get-BuildConstant -Key 'PipelineTimeoutSeconds' -State $State -Fallback 0)
    $pipelineSw = [System.Diagnostics.Stopwatch]::StartNew()

    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        Send-BuildEvent -EventName $EVT_BUILD_START -Source $State -Data @{ Steps = $effectiveSteps.Count } | Out-Null
    }

    # Level 5 wiring: quick pre-flight health gate runs at pipeline start.
    # Test-PreFlight is a no-op when HealthCheck is absent, so this never
    # breaks minimal/standalone flows.
    if (Get-Command Test-PreFlight -ErrorAction SilentlyContinue) {
        try { [void](Test-PreFlight -State $State) } catch { }
    }
    # Ensure project .gitignore covers gbuild runtime artifacts (no hardcode:
    # patterns come from BuildConstants.ProjectGitignorePatterns / config).
    if (Get-Command Update-ProjectGitignore -ErrorAction SilentlyContinue) {
        try { Update-ProjectGitignore -State $State -ProjectDir $State.ProjectRoot } catch { }
    }

    foreach ($step in $effectiveSteps) {
        $stepName = $step.Name
        $displayStepName = Get-PipelineStepDisplayName -StepName $stepName
        $Context.CurrentStep = $stepName

        # Cancellation check (supports external abort via $Context.PipelineCancelled)
        if ($Context.PipelineCancelled) {
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.cancelled' -MessageArgs $displayStepName)$rb" 'Warn' $State
            $cancelled = $true
            break
        }

        # When condition: skip step if scriptblock returns false/null/0
        if ($step.When) {
            try {
                $whenResult = [bool](& $step.When $Context)
            } catch {
                 Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.whenError' -MessageArgs $displayStepName, $_.Exception.Message)$rb" 'Warn' $State
                $whenResult = $true
            }
            if (-not $whenResult) {
                 Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.skipped' -MessageArgs $displayStepName)$rb" 'Info' $State
                if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                    Send-BuildEvent -EventName $EVT_STEP_SKIPPED -Source $State -Data @{ Step = $stepName; Reason = 'WhenConditionFalse' } | Out-Null
                }
                continue
            }
        }

        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_STEP_START -Source $State -Data @{ Step = $stepName } | Out-Null
        }
         Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.running' -MessageArgs $displayStepName)$rb" 'Info' $State

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-PipelineStep -Step $step -Context $Context -State $State -LeftBracket $lb -RightBracket $rb | Out-Null
            $sw.Stop()
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_STEP_COMPLETE -Source $State -Data @{ Step = $stepName; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) } | Out-Null
            }
            if (Get-Command Add-Metric -ErrorAction SilentlyContinue) {
                Add-Metric -Metric (New-MetricHistogram -Name 'gbuild_step_duration_seconds' -Help 'Per-step build duration in seconds' -Value ([math]::Round($sw.Elapsed.TotalSeconds, 4)) -Labels @{ step = $stepName })
            }
        } catch {
            $sw.Stop()
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_STEP_ERROR -Source $State -Data @{ Step = $stepName; Error = $_.Exception.Message } | Out-Null
            }
            if (Get-Command Add-Metric -ErrorAction SilentlyContinue) {
                Add-Metric -Metric (New-MetricHistogram -Name 'gbuild_step_duration_seconds' -Help 'Per-step build duration in seconds' -Value ([math]::Round($sw.Elapsed.TotalSeconds, 4)) -Labels @{ step = $stepName; status = 'failed' })
            }
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.failed' -MessageArgs $displayStepName, $_.Exception.Message)$rb" 'Err' $State
            throw
        }

        # Pipeline-level timeout check
        if ($pipelineTimeout -gt 0 -and $pipelineSw.Elapsed.TotalSeconds -ge $pipelineTimeout) {
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.timeout' -MessageArgs $pipelineTimeout)$rb" 'Warn' $State
            $cancelled = $true
            break
        }
    }

    if (-not $cancelled) {
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_BUILD_COMPLETE -Source $State -Data @{ Status = 'Success' } | Out-Null
        }
    }

    if ($cancelled) {
         Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.cancelledAt' -MessageArgs $stepName)$rb" 'Warn' $State
    }
    $pipelineSw.Stop()
}

<#
.SYNOPSIS
    Resolves builder correlation id + tenant id and stamps them onto State.
#>
function Initialize-BuildIdentity {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not $State.PSObject.Properties.Name -contains 'CorrelationId') {
        # Level 5 single-source: CorrelationIdLength (was literal 12).
        $corrLen = 12
        try {
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                $corrLen = [int](Get-BuildConstant -Key 'CorrelationIdLength' -State $State -Fallback 12)
            }
        } catch { $corrLen = 12 }
        if ($corrLen -le 0) { $corrLen = 12 }
        $State | Add-Member -MemberType NoteProperty -Name CorrelationId -Value ([guid]::NewGuid().ToString('N').Substring(0,$corrLen)) -Force
    }
    $tenantRaw = if ($State.BuildConfig -and $State.BuildConfig.tenancy -and $State.BuildConfig.tenancy.tenantId) { $State.BuildConfig.tenancy.tenantId }
                 elseif ($State.BuildConfig -and $State.BuildConfig.tenancy -and $State.BuildConfig.tenancy.defaultTenant) { $State.BuildConfig.tenancy.defaultTenant }
                 else { 'default' }
    $tenantId = 'default'
    if ($tenantRaw -match '^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$') {
        $envVal = [Environment]::GetEnvironmentVariable($Matches[1])
        if (-not [string]::IsNullOrEmpty($envVal)) { $tenantId = $envVal }
    } elseif (-not [string]::IsNullOrWhiteSpace($tenantRaw)) {
        $tenantId = $tenantRaw
    }
    if (-not ($State.PSObject.Properties.Name -contains 'TenantId')) {
        $State | Add-Member -MemberType NoteProperty -Name TenantId -Value $tenantId -Force
    } else {
        $State.TenantId = $tenantId
    }
    # Apply tenant overrides (tenancy.overrides) now that TenantId is resolved so
    # downstream config consumers see the merged values for the active tenant.
    # ConfigProvider.Merge-ConfigTenantOverride is guarded: absent overrides (and any
    # standalone import without it) return the config unchanged.
    if ($State -and $State.BuildConfig -and (Get-Command Merge-ConfigTenantOverride -ErrorAction SilentlyContinue)) {
        $State.BuildConfig = Merge-ConfigTenantOverride -Config $State.BuildConfig -State $State
    }
}

<#
.SYNOPSIS
    Wires EventBus alerting subscribers for build error / rollback events.
#>
<#
.SYNOPSIS
    Flow-scoped log level (P1 scoped logging).
.DESCRIPTION
    Routine high-volume flow logs (per-step/plugin/cache/telemetry) report at
    $ScopedLevel (default Debug) under build.scopedLogging, and at $VerboseLevel
    when verbose. Warnings/errors/alerts never go through here — they always show.
#>
function Get-FlowLogLevel {
    [CmdletBinding()] param([PSCustomObject]$State, [string]$ScopedLevel = 'Debug', [string]$VerboseLevel = 'Info')
    $scoped = $true
    try {
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $scoped = [bool](Get-BuildSetting -Key 'LogScopedLogging' -State $State -Fallback $true) }
        elseif (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { $scoped = [bool](Get-ConfigValue -Path 'build.scopedLogging' -State $State -Default $true) }
    } catch { $scoped = $true }
    if ($scoped) { return $ScopedLevel } else { return $VerboseLevel }
}

function Register-BuildEventSubscribers {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ((Get-Command Add-BuildEvent -ErrorAction SilentlyContinue) -and (Get-Command Send-Alert -ErrorAction SilentlyContinue)) {
        $existing = Get-BuildEventSubscribers

        # EVT_BUILD_START
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_START) -and $existing[$EVT_BUILD_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_START -Label 'Telemetry: BuildStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m32') 'Debug' $src
            }
        }
        # EVT_BUILD_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_COMPLETE) -and $existing[$EVT_BUILD_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_COMPLETE -Label 'Telemetry: BuildComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m33' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_BUILD_COMPLETE -Field 'Success' 'pending'))) 'Debug' $src
            }
        }
        # EVT_BUILD_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_ERROR) -and $existing[$EVT_BUILD_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_ERROR -Label 'Alerting: BuildError' -Handler {
                param($src, $data)
                # ErrorHandling.New-BuildError publishes EVT_ON_ERROR with the
                # payload @{ Error = $err } and Invoke-WithRetry publishes
                # EVT_ON_RETRY with @{ Operation; Attempt; MaxRetries; DelayMs;
                # Error }. This handler read $data.Message, which exists in
                # NEITHER payload, so every critical alert fell through to the
                # generic 'Build error occurred' and the actual diagnostic was
                # dropped at the alerting boundary. Read the real fields, and
                # still accept a flat .Message for third-party publishers.
                $msg = ''
                if ($data) {
                    $raw = Get-EventPayloadField -Data $data -EventName $EVT_BUILD_ERROR -Field 'Message' ''
                    if ($raw -is [string]) { $msg = $raw }
                    elseif ($raw -and $raw.Message) { $msg = [string]$raw.Message }
                }
                if (-not $msg) { $msg = 'Build error occurred' }
                Send-Alert -Message $msg -Severity 'Critical' -State $src -Data $data
            }
        }
        # EVT_BUILD_WARNING
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_WARNING) -and $existing[$EVT_BUILD_WARNING] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_WARNING -Label 'Telemetry: BuildWarning' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m34' -MessageArgs @($($data.Message))) 'Debug' $src
            }
        }
        # EVT_STEP_START
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_START) -and $existing[$EVT_STEP_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_START -Label 'Telemetry: StepStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m35' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_START -Field 'StepName' '(unnamed)'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_STEP_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_COMPLETE) -and $existing[$EVT_STEP_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_COMPLETE -Label 'Telemetry: StepComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m36' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_COMPLETE -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_COMPLETE -Field 'Status' '?'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_STEP_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_ERROR) -and $existing[$EVT_STEP_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_ERROR -Label 'Telemetry: StepError' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m37' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_ERROR -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_ERROR -Field 'Error'))) 'Warn' $src
            }
        }
        # EVT_STEP_SKIPPED
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_SKIPPED) -and $existing[$EVT_STEP_SKIPPED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_SKIPPED -Label 'Telemetry: StepSkipped' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m38' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_SKIPPED -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_SKIPPED -Field 'Reason' 'no reason'))) 'Gray' $src
            }
        }
        # EVT_STEP_PROGRESS
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_PROGRESS) -and $existing[$EVT_STEP_PROGRESS] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_PROGRESS -Label 'Telemetry: StepProgress' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m39' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_PROGRESS -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_PROGRESS -Field 'ElapsedSec' '?'))) 'Gray' $src
            }
        }
        # EVT_ON_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_ERROR) -and $existing[$EVT_ON_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_ERROR -Label 'Alerting: OnError' -Handler {
                param($src, $data)
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_ERROR -Field 'Message' '') } else { '' }; if (-not $msg) { $msg = 'Error occurred' }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
        # EVT_ON_RETRY
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_RETRY) -and $existing[$EVT_ON_RETRY] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_RETRY -Label 'Telemetry: OnRetry' -Handler {
                param($src, $data)
                # Align with the payload Invoke-WithRetry actually publishes:
                #   @{ Operation; Attempt; MaxRetries; DelayMs; Error }
                # This handler read $data.MaxAttempts and $data.Message, neither
                # of which is in that payload, so every retry line rendered as
                # the useless "[EVT] Retry: 1/ - ".
                $op = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Operation' 'operation') } else { 'operation' }
                $n  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'MaxAttempts' '?') } else { '?' }
                $a  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Attempt' '?') } else { '?' }
                $e  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Message' '') } else { '' }
                $suffix = if ($e) { " - $e" } else { '' }
                # ${op} not $op: a bare "$op:" is parsed as a scope-qualified
                # variable reference and fails to parse.
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m40' -MessageArgs @(${op}, $a, $n, $suffix)) 'Warn' $src
            }
        }
        # EVT_ON_ROLLBACK
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_ROLLBACK) -and $existing[$EVT_ON_ROLLBACK] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_ROLLBACK -Label 'Alerting: Rollback' -Handler {
                param($src, $data)
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_ROLLBACK -Field 'Message' '') } else { '' }; if (-not $msg) { $msg = 'Rollback executed' }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
        # EVT_PLUGIN_LOADED
        if (-not ($existing -and $existing.ContainsKey($EVT_PLUGIN_LOADED) -and $existing[$EVT_PLUGIN_LOADED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_PLUGIN_LOADED -Label 'Telemetry: PluginLoaded' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m41' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_LOADED -Field 'PluginName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_LOADED -Field 'Version' ''))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_PLUGIN_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_PLUGIN_ERROR) -and $existing[$EVT_PLUGIN_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_PLUGIN_ERROR -Label 'Telemetry: PluginError' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m42' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_ERROR -Field 'PluginName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_ERROR -Field 'Error'))) 'Warn' $src
            }
        }
        # EVT_CACHE_HIT
        if (-not ($existing -and $existing.ContainsKey($EVT_CACHE_HIT) -and $existing[$EVT_CACHE_HIT] -gt 0)) {
            Add-BuildEvent -EventName $EVT_CACHE_HIT -Label 'Telemetry: CacheHit' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m43' -MessageArgs @($($data.Key))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_CACHE_MISS
        if (-not ($existing -and $existing.ContainsKey($EVT_CACHE_MISS) -and $existing[$EVT_CACHE_MISS] -gt 0)) {
            Add-BuildEvent -EventName $EVT_CACHE_MISS -Label 'Telemetry: CacheMiss' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m44' -MessageArgs @($($data.Key))) (Get-FlowLogLevel -State $src) $src
            }
}
            # EVT_TELEMETRY_RECORDED
        if (-not ($existing -and $existing.ContainsKey($EVT_TELEMETRY_RECORDED) -and $existing[$EVT_TELEMETRY_RECORDED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_TELEMETRY_RECORDED -Label 'Telemetry: Recorded' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m46' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_TELEMETRY_RECORDED -Field 'MetricName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_TELEMETRY_RECORDED -Field 'File' '(no file)'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_DEPLOY_START
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_START) -and $existing[$EVT_DEPLOY_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_START -Label 'Telemetry: DeployStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m47' -MessageArgs @($($data.Target))) 'Info' $src
            }
        }
        # EVT_DEPLOY_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_COMPLETE) -and $existing[$EVT_DEPLOY_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_COMPLETE -Label 'Telemetry: DeployComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m48' -MessageArgs @($($data.Target), $($data.Success))) 'Info' $src
            }
        }
        # EVT_DEPLOY_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_ERROR) -and $existing[$EVT_DEPLOY_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_ERROR -Label 'Alerting: DeployError' -Handler {
                param($src, $data)
                # DeployTargets publishes @{ Target = ...; Error = ... }.
                # $data.Message exists in neither, so every deploy alert carried
                # only the generic fallback and the real failure was lost.
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_DEPLOY_ERROR -Field 'Message' '') } else { '' }
                $target = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_DEPLOY_ERROR -Field 'Target' '') } else { '' }
                if (-not $msg) { $msg = 'Deploy error occurred' }
                if ($target) { $msg = "[$target] $msg" }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
    }
}

<#
.SYNOPSIS
    Unregisters build event subscribers (L5 session hygiene).
.DESCRIPTION
    Removes every handler via Remove-BuildEvent (scriptblock identity, fetched
    through Get-BuildEventHandlers) so repeated Start-GBuild calls in one
    session (global gbuild fn, HotReload watch, Pester) never accumulate stale
    handlers. Register-BuildEventSubscribers re-adds them on the next build.
    Never throws; teardown must not break the build finally block.
#>
function Unregister-BuildEventSubscribers {
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-BuildEventHandlers -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command Remove-BuildEvent -ErrorAction SilentlyContinue)) { return }
    $events = @()
    try { $events = @((Get-BuildEventSubscribers).Keys) } catch { $events = @() }
    foreach ($ev in $events) {
        try {
            $handlers = @(Get-BuildEventHandlers -EventName $ev)
            foreach ($h in $handlers) {
                try { Remove-BuildEvent -EventName $ev -Handler $h } catch { }
            }
        } catch { }
    }
}

<#
.SYNOPSIS
    Registers core OOP services into the lightweight DI container (singletons).
#>
function Register-BuildServices {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (Get-Command Register-Service -ErrorAction SilentlyContinue) {
        if (-not (Test-ServiceRegistered -Name 'BuildContext')) {
            Register-Service -Name 'BuildContext' -Factory { New-BuildContext -Seed $State } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'MetricRegistry')) {
            Register-Service -Name 'MetricRegistry' -Factory { Get-MetricRegistry } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'EventBus')) {
            Register-Service -Name 'EventBus' -Factory { Get-BuildEventBus } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'ErrorHandling')) {
            Register-Service -Name 'ErrorHandling' -Factory { Get-ErrorHandlingService } -Singleton
        }
    }
}

<#
.SYNOPSIS
    Resolves environment + build strategy via the provider model and stamps onto State.
#>
function Resolve-BuildEnvironmentAndStrategy {
    [CmdletBinding()]
    param([PSCustomObject]$State, [switch]$Incremental, [switch]$Clean, [string]$LogLevel)
    if (Get-Command Get-BuildEnvironment -ErrorAction SilentlyContinue) {
        $envProvider = Get-BuildEnvironment
        $State | Add-Member -MemberType NoteProperty -Name IsCI -Value $envProvider.IsCI -Force -EA SilentlyContinue
        if (-not $State.PSObject.Properties.Name -contains 'OS' -or [string]::IsNullOrEmpty($State.OS)) {
            $State | Add-Member -MemberType NoteProperty -Name OS -Value $envProvider.OS -Force -EA SilentlyContinue
        }
        $envName = if ($envProvider.Name -eq 'Local') { Get-LocaleMessage -Key 'log.environment.local' } else { [string]$envProvider.Name }
        Write-Log (Get-LocaleMessage -Key 'log.system.environment' -MessageArgs @($envName, $envProvider.IsCI, $envProvider.OS)) 'Info' $State
    }
    if (Get-Command Get-BuildStrategy -ErrorAction SilentlyContinue) {
        # CORRECTED: was `-Debug:($LogLevel -eq 'Debug')`. Get-BuildStrategy
        # declares -DebugBuild, not -Debug, so this bound to the COMMON
        # -Debug parameter (i.e. it set $DebugPreference) and DebugBuild was
        # permanently $false - a -Debug log level never produced a Debug
        # build strategy.
        $strategy = Get-BuildStrategy -Incremental:$Incremental -Clean:$Clean -DebugBuild:($LogLevel -eq 'Debug')
        $State | Add-Member -MemberType NoteProperty -Name BuildStrategy -Value $strategy.Name -Force -EA SilentlyContinue
        # Consume the strategy's resolved options. ResolveOptions existed on
        # all four strategy classes and was called by NOTHING outside the
        # provider's own tests, so Configuration / Incremental / Clean were
        # computed and discarded. Stamping them on State makes the strategy
        # the single decision point instead of one that only sets a label.
        $strategyOpts = $null
        try { $strategyOpts = $strategy.ResolveOptions($State) } catch { $strategyOpts = $null }
        if ($strategyOpts) {
            $State | Add-Member -MemberType NoteProperty -Name BuildConfiguration -Value ([string]$strategyOpts.Configuration) -Force -EA SilentlyContinue
            $State | Add-Member -MemberType NoteProperty -Name StrategyIncremental -Value ([bool]$strategyOpts.Incremental) -Force -EA SilentlyContinue
            $State | Add-Member -MemberType NoteProperty -Name StrategyClean -Value ([bool]$strategyOpts.Clean) -Force -EA SilentlyContinue
        }
        $strategyKey = "log.strategy.$(([string]$strategy.Name).ToLowerInvariant())"
        $strategyName = Get-LocaleMessage -Key $strategyKey -Fallback ([string]$strategy.Name)
        Write-Log (Get-LocaleMessage -Key 'log.system.strategy' -MessageArgs @($strategyName)) 'Info' $State
    }
}

<#
.SYNOPSIS
    Prints a discoverability tip after gbuild auto-selects a default target, so the
    operator knows the full feature set is one step away. Shown only on an interactive terminal.
.DESCRIPTION
    The tip points ONLY to -Help: -Help is the single place for ALL commands
    (usage, switches, target catalog, locales, examples). No separate
    '-Target list' pointer here — that guide lives inside -Help.
#>

<#
.SYNOPSIS
    Initialises logging directory + starts the Prometheus metrics endpoint if enabled.
#>
function Initialize-BuildLogging {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$LogLevel = 'Info')
    # Log directory base comes from config logging.path (new/optional) with the
    # single-sourced BuildConstants LogsDir as default ('logs'), so operators can
    # relocate build logs without editing core. Empty/absent falls back to 'logs'.
    $rawLogDir = Resolve-ConfigValue -State $State -Path 'logging.path' -Default (Get-BuildConstant -Key 'LogsDir' -Fallback 'logs')
    $logNameDir = if ([string]::IsNullOrWhiteSpace([string]$rawLogDir)) { Get-BuildConstant -Key 'LogsDir' -Fallback 'logs' } else { [string]$rawLogDir }
    $logDir = Join-Path $State.ScriptRoot (Join-Path $logNameDir $State.TenantId)
    if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $logDir) } elseif (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Start-Log -Path (Join-Path $logDir "build_$(Get-BuildTimestamp -Kind FileStamp).log")
    $safeLogLevel = if ($LogLevel -in @('Error','Warn','Info','Debug')) { $LogLevel } else { 'Info' }
    Set-LogLevel -Level $safeLogLevel
    Write-Log (Get-LocaleMessage -Key 'log.system.building') 'Succ' $State -Level $safeLogLevel
    if (Get-Command Start-MetricsEndpoint -ErrorAction SilentlyContinue) {
        $promCfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.telemetry -and $State.BuildConfig.telemetry.prometheus) { $State.BuildConfig.telemetry.prometheus } else { $null }
        if (-not $promCfg) {
            # DI fallback: read prometheus config from the registered MetricRegistry service
            try { $reg = Resolve-Service -Name 'MetricRegistry'; if ($reg -and $reg.PrometheusConfig) { $promCfg = $reg.PrometheusConfig } } catch {
                # benign - service not registered, metrics start skipped
                }
        }
        if ($promCfg -and $promCfg.enabled) {
            if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
                try {
                    if ((Test-EnvToggle -Name 'GBUILD_PROMETHEUS') -eq $true -and -not [bool]$State.BuildConfig.telemetry.prometheus.enabled) {
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m49' -MessageArgs @($($promCfg.port))) 'Info' $State
                    }
                } catch { }
            }
            Start-MetricsEndpoint -Port ([int]$promCfg.port) -State $State | Out-Null
        }
    }
}

<#
.SYNOPSIS
    Handles standalone operations (CacheClear/Optimize/Stats/VersionBump). Returns $true if handled.
#>
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
function Initialize-BuildConfigAndProfile {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $strictValidation = Resolve-ConfigValue -State $State -Path 'health.failOnInvalidConfig' -Default $false
    $warnEv = $false
    if ($State.BuildConfig) {
        try {
            $configValid = Test-BuildConfig -State $State -Strict:$strictValidation
        } catch {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m54' -MessageArgs @(${lb}, ${rb}, $($_.Exception.Message))) 'Err' $State
            return $false
        }
        if (-not $configValid) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m55' -MessageArgs @(${lb}, ${rb})) 'Warn' $State; $warnEv = $true }
        $expectedCfgVer = [version](Get-BuildConstant -Key 'Version' -Fallback '2.0.0')
        $cfgVer = if ($State.BuildConfig.PSObject.Properties.Name -contains 'version') { try { [version]::Parse($State.BuildConfig.version) } catch { $null } } else { $null }
        if ($null -eq $cfgVer) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m56' -MessageArgs @(${lb}, ${rb})) 'Warn' $State
            $warnEv = $true
        } elseif ($cfgVer -lt $expectedCfgVer) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m57' -MessageArgs @(${lb}, ${rb}, $($cfgVer), $($expectedCfgVer))) 'Warn' $State
            $warnEv = $true
        }
        if ($warnEv -and (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue)) {
            Send-BuildEvent -EventName $EVT_BUILD_WARNING -Source $State -Data @{ Message = 'Config validation warnings detected' } | Out-Null
        }
    }
    $activeProfile = if ($State.PSObject.Properties.Name -contains 'ActiveProfile') { $State.ActiveProfile } else { if ($State.BuildConfig -and $State.BuildConfig.build) { $State.BuildConfig.build.defaultConfiguration } elseif (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { [string](Get-BuildSetting -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } else { 'Release' } }
    $sprofile = Get-ActiveProfile -State $State -ProfileName $activeProfile
    if ($sprofile) {
        Write-Log (Get-LocaleMessage -Key 'log.system.profile' -MessageArgs @($activeProfile)) "Info" $State
        if ($sprofile.logLevel) { Set-LogLevel -Level $sprofile.logLevel }
        # Apply profile overrides onto live config so they actually take effect
        if ($sprofile.PSObject.Properties.Name -contains 'enableParallelBuild' -and $null -ne $sprofile.enableParallelBuild) {
            $State.BuildConfig.build.enableParallelBuild = [bool]$sprofile.enableParallelBuild
        }
        if ($sprofile.PSObject.Properties.Name -contains 'enableBuildCache' -and $null -ne $sprofile.enableBuildCache) {
            $State.BuildConfig.build.enableBuildCache = [bool]$sprofile.enableBuildCache
        }
        if ($sprofile.PSObject.Properties.Name -contains 'enableJsonLog' -and $null -ne $sprofile.enableJsonLog) {
            $State.BuildConfig.logging.enableJsonLog = [bool]$sprofile.enableJsonLog
        }
        if ($sprofile.PSObject.Properties.Name -contains 'nonInteractive' -and $sprofile.nonInteractive) {
            $State | Add-Member -MemberType NoteProperty -Name NonInteractive -Value $true -Force -EA SilentlyContinue
        }
        if ($sprofile.PSObject.Properties.Name -contains 'targetFramework' -and -not [string]::IsNullOrWhiteSpace($sprofile.targetFramework)) {
            Set-BuildStateProperty -State $State -Name 'CurrentTfm' -Value ([string]$sprofile.targetFramework) -Force
        }
    }
    return $true
}

<#
.SYNOPSIS
    Centralized health gate for Tier-1 commands that must resolve globally.
.DESCRIPTION
    Level 5 structural fix for the PS 5.1 module-scope orphan incident (FATAL
    Invoke-EnsureDirectory in Save-BuildState): instead of guarding every call
    site, assert the invariant ONCE at pipeline checkpoints. When commands are
    missing it warns LOUDLY (never degraded-silent), emits an event, attempts
    a -Global repair re-import of PathUtils, and returns $false when still
    unhealthy so the caller fails fast with a clear cause. Never throws.
    5.1-safe: statements only, no (if) subexpressions, no ?. / ??.
#>
function Assert-CoreCommands {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State = $null,
        [switch]$Repair
    )
    $required = @('Invoke-EnsureDirectory', 'Get-ExcludeDirPattern', 'Get-BuildRootDirectory', 'Resolve-BuildRootedPath', 'Test-PathUnderRoots', 'Find-ProjectManifest', 'Format-Path', 'Test-SafePath')
    $missing = @()
    foreach ($cmd in $required) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
    }
    if ($missing.Count -eq 0) { return $true }
    $detail = 'Missing core commands (PathUtils orphan?): ' + ($missing -join ', ')
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.core.detail' -MessageArgs @([string]$detail) -Fallback '[CORE] {0}') 'Warn' $State
    }
    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        try { Send-BuildEvent -EventName $EVT_CORE_COMMANDS_MISSING -Source $State -Data @{ Missing = @($missing) } | Out-Null } catch { }
    }
    if ($Repair) {
        $puPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
        if (Test-Path -LiteralPath $puPath -PathType Leaf) {
            try { Import-Module $puPath -Force -Global -DisableNameChecking -ErrorAction Stop } catch { }
        }
        $stillMissing = @()
        foreach ($cmd in $required) {
            if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $stillMissing += $cmd }
        }
        if ($stillMissing.Count -eq 0) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m58') 'Succ' $State
            }
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                try { Send-BuildEvent -EventName $EVT_CORE_COMMANDS_REPAIRED -Source $State -Data @{ Missing = @($missing) } | Out-Null } catch { }
            }
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Resolves the .NET SDK and caches build state after resolution (resume-on-crash checkpoint).
#>
function Resolve-BuildSdk {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    # Level 5 health gate (PS 5.1 orphan): plugin-contract validation runs
    # before this point and may have orphaned PathUtils — heal loudly here so
    # Save-BuildState below can never hit a mystery CommandNotFound.
    if (Get-Command Assert-CoreCommands -ErrorAction SilentlyContinue) {
        if (-not (Assert-CoreCommands -State $State -Repair)) {
            Write-Log (Get-LocaleMessage -Key 'log.system.coreCommandsUnavailable') 'Err' $State
            return $false
        }
    }
    if (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue) {
        $dotnetExe = Get-SmartSdk -State $State -ToolType 'Dotnet'
        if ($dotnetExe) {
            Set-BuildStateProperty -State $State -Name 'DotnetCmd' -Value ([string]$dotnetExe) -Force
            Write-Log "[SDK] $(Get-LocaleMessage -Key 'log.sdk.dotnetResolved' -MessageArgs @($dotnetExe))" 'Succ' $State
        } else {
            $dotnetBin = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'DotnetToolName' -Fallback 'dotnet') } else { 'dotnet' }
            $anyDotnet = Get-Command $dotnetBin -ErrorAction SilentlyContinue
            if ($anyDotnet) {
                Write-Log "[FATAL] $(Get-LocaleMessage -Key 'log.sdk.dotnetNoSdk')" 'Err' $State
            } else {
                Write-Log "[FATAL] $(Get-LocaleMessage -Key 'log.sdk.dotnetNotFound')" 'Err' $State
            }
            Write-Log "[ABORT] $(Get-LocaleMessage -Key 'log.sdk.dotnetRequired')" 'Err' $State
            return $false
        }
        # Auto-provisioning printed a manual-install diagram and asked us to stop.
        if ($State.PSObject.Properties.Name -contains 'BuildAborted' -and $State.BuildAborted) {
            Write-Log "[ABORT] $(Get-LocaleMessage -Key 'log.sdk.manualRequired')" 'Err' $State
            return $false
        }
    }
    foreach ($prop in @('DotnetCmd','JavaSdk','AndroidSdk','CurrentTfm')) { if ($State.$prop) { Write-Log (Get-LocaleMessage -Key 'log.system.sdkState' -MessageArgs @($prop, $State.$prop)) 'Gray' $State } }
    # Keep the DI BuildContext singleton in sync with the live state (re-seed after
    # late mutations such as DotnetCmd / CurrentTfm so it is never a stale snapshot).
    if (Get-Command Set-ServiceInstance -ErrorAction SilentlyContinue -and (Test-ServiceRegistered -Name 'BuildContext')) {
        Set-ServiceInstance -Name 'BuildContext' -Instance (New-BuildContext -Seed $State)
    }
    # RESUME CHECKPOINT, not a completion record. Marked incomplete so a run that
    # dies after this point is detectable on the next invocation.
    if (Get-Command Save-BuildState -ErrorAction SilentlyContinue) { Save-BuildState -State $State -Completed:$false | Out-Null }
    return $true
}

<#
.SYNOPSIS
    Returns the built-in build pipeline as an ordered step list.
.DESCRIPTION
    Extracted from Start-GBuild so the pipeline is DEFINED in one place and
    can be exercised directly. It used to be an inline literal inside
    Start-GBuild, which meant no test could reach it: Pipeline.E2E hand-built a
    4-element stub array reusing production step NAMES, so every gate step,
    its config gate and its When condition were untested, and a regression in
    the real pipeline could not fail a single test.
    Step scripts close over $State and $resolvedCfg from this function's scope,
    exactly as they did when the literal was inline.
.OUTPUTS
    Array of step hashtables: @{ Name = <string>; Script = <scriptblock> }.
#>
function Get-BuiltInPipelineSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [PSCustomObject]$State,
        [string]$ResolvedCfg = '',
        [switch]$Distributed,
        [string]$Target = '',
        [switch]$Security,
        [switch]$Incremental,
        [switch]$GitHub
    )
    $resolvedCfg = $ResolvedCfg
    # Bound as locals: the step scripts close over these names, exactly as they
    # did when the literal sat inside Start-GBuild.
    $Distributed = $Distributed
    $Target = $Target
    $Security = $Security
    # -Incremental closes over the same way. The Build step references
    # -Incremental:$Incremental at :2965 and :3066, but this function never
    # declared it: the closure resolved an UNSET variable to $null silently
    # (an uninitialized variable in a GetNewClosure() dynamic-module scope is
    # $null even under Set-StrictMode 1.0), so `-Incremental` was always $false
    # and the plugin cache short-circuit at Loader.psm1:639 never fired.
    $Incremental = $Incremental
    # Same class for -GitHub: the Build step passes it to Show-GuildMenu (:3074)
    # but it was never bound into this scope, so `-GitHub` was always $false.
    $GitHub = $GitHub
    # Each step script is bound to THIS function's scope with GetNewClosure().
    # A bare scriptblock resolves variables through the CALLER's live scope
    # chain, so $State / $resolvedCfg / $Distributed / $Target / $Security only
    # resolved because Start-GBuild happened to still be on the stack. Call the
    # pipeline from anywhere else - a test, a plugin, a future refactor - and
    # under Set-StrictMode every one of those steps throws
    # "The variable '$Security' cannot be retrieved because it has not been set."
    # GetNewClosure captures the values now, at definition time.
    $built = @(
    @{
        Name = 'RegisterPlugins'
        Script = {
            param($ctx)
            Register-Plugins -State $State
            Invoke-GBuildHook -HookName 'before-build' -State $State
        }
    },
    @{
        Name = 'ScanProject'
        Script = {
            param($ctx)
            Show-ProgressBar -Current 1 -Total 4 -Label (Get-LocaleMessage -Key 'log.project.searchingCsproj')
            Write-SubLog (Get-LocaleMessage -Key 'log.project.searchingCsproj')
            # Prefer the csproj resolved directly from -Project in gbuild.ps1.
            # This bypasses Find-Project entirely so a stale/cached Find-Project
            # (which could ignore -Project and re-detect WebUI) can never override
            # the explicit project. Fall back to Find-Project only when -Project
            # was not supplied.
            if ($State.ProjectCsproj -and (Test-Path $State.ProjectCsproj)) {
                $csproj = Get-Item -Path $State.ProjectCsproj
                Write-SubLog (Get-LocaleMessage -Key 'log.project.explicitCsproj' -MessageArgs @($State.ProjectCsproj))
            } elseif (Get-Command Find-Project -ErrorAction SilentlyContinue) {
                $csproj = Find-Project -State $State
            } else { $null }
            $ctx.csproj = $csproj
            if (-not $csproj) {
                Write-Log (Get-LocaleMessage -Key 'log.project.noCsproj') 'Info' $State
                Import-ModuleOnDemand -ModuleNames @('LanguageDetector')
                $searchRoot = if ($State.ProjectRoot -and (Test-Path $State.ProjectRoot)) { $State.ProjectRoot } else { $State.ScriptRoot }
                $langInfo = Get-PrimaryLanguage -SearchRoot $searchRoot -State $State
                if (-not $langInfo) { Write-Fail (Get-LocaleMessage -Key 'log.project.noSupported') -State $State; return }
                Write-Done (Get-LocaleMessage -Key 'log.project.detected' -MessageArgs @($langInfo.Language, $langInfo.BuildFile)) -State $State
                $ctx.projPath = $langInfo.BuildFilePath
                $ctx.projectDir = $langInfo.ProjectDir
                $ctx.projectType = $langInfo.Language
                $ctx.tfms = @()
                $ctx.defaultTfm = ''
                $ctx.tfmInfo = $null
                $ctx.langInfo = $langInfo
                $ctx.lang = $langInfo.Language
            } else {
                $ctx.projPath = $csproj.FullName
                $ctx.projectDir = $csproj.DirectoryName
                Import-ModuleOnDemand -ModuleNames @('Project')
                $meta = if (Get-Command Get-ProjectMetadata -ErrorAction SilentlyContinue) { Get-ProjectMetadata -CsprojPath $ctx.projPath -State $State } else { $null }
                $ctx.projectType = if ($meta -and $meta.ProjectType) { [string]$meta.ProjectType } else { 'Unknown' }
                $ctx.tfms = if ($meta -and $meta.Tfms) { ,$meta.Tfms } else { @() }
                $ctx.defaultTfm = if ($ctx.tfms.Count -gt 0) { $ctx.tfms[0] } else { $State.CurrentTfm }
                Invoke-SdkDetection -State $State -ProjectType $ctx.projectType -Tfms $ctx.tfms
                $ctx.tfmInfo = Resolve-TargetFrameworks -Tfms $ctx.tfms -ProjectType $ctx.projectType -DefaultTfm $ctx.defaultTfm
                Write-Done (Get-LocaleMessage -Key 'log.project.projectFound' -MessageArgs @($csproj.Name, $ctx.projectType)) -State $State
                $buildCfg = if ($State.BuildConfig -and $State.BuildConfig.build) { $State.BuildConfig.build } else { $null }
                $parallelEnabled = [bool](Get-BuildConstant -Key 'EnableParallelBuild' -State $State -Fallback $true)
                if ($parallelEnabled) {
                    # The module map in Get-ModuleMapFromConfig loads Parallel for
                    # target '14' only, and that map is consulted INSIDE
                    # Invoke-GuildChoice - i.e. AFTER this step. So this guard
                    # could never be true: Find-IndependentProjects was
                    # unresolvable at ScanProject time, $ctx.parallelProjects
                    # was therefore always empty, Menu.New-GuildMenuConfig
                    # computed $hasParallel = $false from it, and BOTH the
                    # Parallel Build (target 14) and Multi-Host Distributed
                    # Build (target X) were reported as "not supported for
                    # project type ..." for every project. Load it here
                    # instead. On-demand rather than Tier-1: the scan is the
                    # only consumer before a parallel build is chosen, and
                    # paying the import on every ordinary build would be a
                    # regression for a feature most runs never use.
                    Import-ModuleOnDemand -ModuleNames @('Parallel')
                    if (Get-Command Find-IndependentProjects -ErrorAction SilentlyContinue) {
                        $projInfo = Find-IndependentProjects -State $State
                        if ($projInfo.Independent -and $projInfo.Independent.Count -gt 1) {
                            $pp = [System.Collections.ArrayList]@()
                            $projInfo.Independent | ForEach-Object { $pp.Add($_.Path) | Out-Null }
                            $ctx.parallelProjects = $pp
                            Write-Log (Get-LocaleMessage -Key 'log.project.parallelDetected' -MessageArgs @($projInfo.Independent.Count)) "Info" $State
                        }
                    }
                }
            }
            # Scoped-logging anchor: every later step reports against this scope.
            $scopeLabel = if ($ctx.lang) { "$($ctx.projectType)/$($ctx.lang)" } elseif ($ctx.projectType) { [string]$ctx.projectType } else { 'Unknown' }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m67' -MessageArgs @($scopeLabel)) 'Debug' $State
        }
    },
    @{
        Name = 'Preflight'
        Script = {
            param($ctx)
            $cfg = Get-ConfigSection -State $State -Path 'build.preflight'
            $enabled = if ($cfg -and $null -ne $cfg.enabled) { [bool]$cfg.enabled } else { $true }
            if (-not $enabled) { Write-Log "[PREFLIGHT] $(Get-LocaleMessage -Key 'log.status.skipped') (build.preflight.enabled=false)" 'Gray' $State; return }
            Import-ModuleOnDemand -ModuleNames @('Preflight')
            if (Get-Command Invoke-PreflightValidation -ErrorAction SilentlyContinue) {
                $projDir = if ($ctx.projectDir) { $ctx.projectDir } elseif ($State.ProjectRoot) { $State.ProjectRoot } else { $State.ScriptRoot }
                $projFile = if ($ctx.projPath) { $ctx.projPath } else { '' }
                $pf = Invoke-PreflightValidation -State $State -ProjectDir $projDir -ProjectFile $projFile
                if (-not $pf.Passed) {
                    $msg = Get-LocaleMessage -Key 'log.system.preflightFailed' -MessageArgs @(($pf.Errors -join '; '))
                    Write-Log $msg 'Err' $State
                    throw $msg
                }
                Write-Log (Get-LocaleMessage -Key 'log.system.preflightPassed' -MessageArgs @($pf.Checks.Count)) 'Succ' $State
            } else { Write-Log "[PREFLIGHT] $(Get-LocaleMessage -Key 'log.status.skipped') (module unavailable)" 'Gray' $State }
        }
    },
    @{
        Name = 'AffectedScan'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'AFFECTED' -Reason 'build.affected.enabled=false' -EnablePaths @('build.affected.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Cache')
            if (Get-Command Get-AffectedProjects -ErrorAction SilentlyContinue) {
                $projFiles = @()
                if ($ctx.parallelProjects -and $ctx.parallelProjects.Count -gt 0) { $projFiles = [string[]]$ctx.parallelProjects }
                elseif ($ctx.projPath) { $projFiles = @([string]$ctx.projPath) }
                elseif ($State.ProjectRoot) {
                    $all = if (Get-Command Get-AllProjects -ErrorAction SilentlyContinue) { Get-AllProjects -SearchRoot $State.ProjectRoot -State $State } else { @() }
                    $projFiles = @($all | ForEach-Object { $_.FullName })
                }
                if ($projFiles.Count -eq 0) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m68') 'Gray' $State; return }
                $res = Get-AffectedProjects -ProjectFiles $projFiles -State $State
                if ($res -and $res.Affected) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m69' -MessageArgs @($($res.Affected.Count), $($res.Unchanged.Count))) 'Info' $State
                    # Read build.affected.skipUnchanged from THIS step's own config
                    # section. This used to test `$cfg.skipUnchanged`, a variable
                    # that exists only in the Preflight step's scope (:2904), so it
                    # always resolved to $null and build.affected.skipUnchanged was
                    # never honoured.
                    $skipUnchanged = [bool](Get-ConfigValue -Path 'build.affected.skipUnchanged' -State $State -Type bool)
                    if ($skipUnchanged -and $res.Unchanged.Count -gt 0 -and $ctx.parallelProjects.Count -gt 0) {
                        $filtered = @($ctx.parallelProjects | Where-Object { $_ -in $res.Affected })
                        $ctx.parallelProjects = [System.Collections.ArrayList]@($filtered)
                        # Name the projects being dropped. Previously only a
                        # count was logged, so a project silently vanishing
                        # from the build set had to be diagnosed by
                        # reconstructing the affected-graph by hand.
                        $droppedNames = @()
                        try { $droppedNames = @($ctx.parallelProjects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_) }) } catch { $droppedNames = @() }
                        if ($droppedNames.Count -gt 0) {
                            Write-Log (Get-LocaleMessage -Key 'log.cache.noSourceChanges' -MessageArgs @(($droppedNames -join ', '))) 'Gray' $State
                        }
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m70' -MessageArgs @($($filtered.Count))) 'Info' $State
                    }
                } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m71') 'Gray' $State }
            } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m72') 'Gray' $State }
        }
    },
    @{
        Name = 'Build'
        Script = {
            param($ctx)
            $csproj = $ctx.csproj
            if ($null -eq $csproj -and $ctx.langInfo) {
                $ctx.buildAttempted = $true
                Show-ProgressBar -Current 2 -Total 4 -Label "Building $($ctx.langInfo.Language)"
                $lang = $ctx.langInfo.Language
                $ctx.lang = $lang
                $fallbackLang = ''
                try {
                    $langOverrides = Get-ConfigValue -Path 'build.pluginDispatch.languageOverrides' -State $State
                    $fallbackLang = [string](Get-SectionValue -Section $langOverrides -Key $lang -Default '')
                } catch { }
                $null = Assert-BuildCommandAvailable -Command 'Invoke-PluginBuildSafe' -MessageKey 'log.orch.moduleLoaderMissing' -Fallback 'Loader (plugin system) not loaded.'
                $buildResult = Invoke-PluginBuildSafe -State $State -Language $lang -ProjectDir $ctx.projectDir -ProjectFile $ctx.projPath -FallbackLanguage $fallbackLang -Incremental:$Incremental -Detailed
                $buildOk = Test-RequiredResult -Result $buildResult -Operation "build:$lang"
                if (-not $buildOk) {
                    $buildDetail = if ($buildResult -and $buildResult.Message) { [string]$buildResult.Message } else { '' }
                    $message = Get-LocaleMessage -Key 'log.plugin.buildFailed' -MessageArgs @($lang, $buildDetail)
                    Write-Fail $message -State $State
                    throw $message
                }
                $ctx.buildOk = $buildOk
                $testFlags = Get-BuildTestConfig -State $State
                if ($testFlags.TestEnabled -or $testFlags.LintEnabled) {
                    # Shared gate, same definition as menu 'T'/'I' below.
                    Invoke-PluginTestAndLintGate -State $State -ProjectDir $ctx.projectDir -Language $lang -TestFlags $testFlags | Out-Null
                }
                # Stamp the publish location while the plugin result (with its
                # OutputPath) is still in hand. Without this the downstream
                # provenance/deploy chain resolves blind and a green build
                # with no artifacts passes silently.
                Update-BuildPublishOutput -Context $ctx -State $State -PluginResult $buildResult -ProjectDir $ctx.projectDir | Out-Null
                # Same reveal rule as the .NET path (Build.Invoke-BuildOutputReveal):
                # open only when the shared resolver allows it, so CI stays quiet.
                $openPublish = $false
                try {
                    if (Get-Command Resolve-BuildOpenOutput -ErrorAction SilentlyContinue) { $openPublish = [bool](Resolve-BuildOpenOutput -State $State) }
                } catch { $openPublish = $false }
                if ($openPublish -and $ctx.projectDir -and (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) -and (Get-Command Open-Target -ErrorAction SilentlyContinue)) {
                    $poRoot = Join-Path $ctx.projectDir (Resolve-PublishOutputDir -State $State)
                    if (Test-Path -LiteralPath $poRoot) { Open-Target $poRoot -State $State }
                }                    $totalSec = [math]::Round(((Get-Date) - $State.StartTime).TotalSeconds, 1)
                $ctx.totalSec = $totalSec
                Write-Host "`n"; Write-Sep; _2Col "  [BUILD DONE] $(Get-LocaleMessage -Key 'log.system.completed')" (Get-LocaleMessage -Key 'log.system.total' -MessageArgs @($totalSec)) 'Succ' 'Gray' $State; Write-Sep
                if (Get-Command Write-BuildMetric -ErrorAction SilentlyContinue) {
                    $metric = Write-BuildMetric -State $State -Status 'Success' -Duration $totalSec -ProjectName (Split-Path $ctx.projectDir -Leaf) -Configuration $resolvedCfg -OutputType $lang
                    $ctx.metric = $metric
                    if (Get-Command Save-BuildReport -ErrorAction SilentlyContinue) {
                        try { $null = Save-BuildReport -State $State -Metric $metric } catch { }
                    }
                    if (Get-Command Write-TelemetryEntry -ErrorAction SilentlyContinue) { Write-TelemetryEntry -State $State -Metric $metric | Out-Null }
                    if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) { Submit-BuildMetric -State $State -Step $lang -DurationMs ($totalSec * 1000) -Success:$buildOk -ProjectName (Split-Path $ctx.projectDir -Leaf) -Configuration $resolvedCfg -OutputType $lang | Out-Null }
                }
            } else {
                Show-ProgressBar -Current 2 -Total 4 -Label (Get-LocaleMessage -Key 'log.system.selectMode')
                $menuConfig = New-GuildMenuConfig -ProjectType $ctx.projectType -AndroidTfm $ctx.tfmInfo.AndroidTfm -WinTfm $ctx.tfmInfo.WinTfm -OS $State.OS -ParallelProjects $ctx.parallelProjects -State $State
                $ctx.menuConfig = $menuConfig
                if ($Distributed.IsPresent) {
                    if ($menuConfig.ContainsKey('X') -and $menuConfig['X'].Supported) {
                        $choice = 'X'
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m73') 'Info' $State
                    } else {
                        # Name the gate that actually closed. This used to emit
                        # a single message blaming distributed.enabled, which
                        # ships TRUE - so when target X was unavailable for the
                        # other reason (fewer than two independent projects)
                        # the diagnostic pointed at a config key that was
                        # already set, and the real cause was undiscoverable
                        # from the output.
                        $distEnabled = [bool](Get-ConfigValue -Path 'distributed.enabled' -State $State -Type bool)
                        $msgKey = if ($distEnabled) { 'log.orchestrator.parallelUnavailable' } else { 'log.orchestrator.m74' }
                        Write-Log (Get-LocaleMessage -Key $msgKey) 'Warn' $State
                        return
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($Target)) {
                    $choice = $Target.Trim()
                    if (-not $menuConfig.ContainsKey($choice)) {
                        $listCmd = 'gbuild -Target list'
                        if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
                            try { $listCmd = Get-InvokeCommandHint -Arguments '-Target list' -ScriptRoot $State.ScriptRoot -FromDirectory ((Get-Location).ProviderPath) } catch { }
                        }
                         $message = Get-LocaleMessage -Key 'log.target.invalid' -MessageArgs @($choice, $listCmd)
                         Write-Log $message 'Err' $State
                         throw $message

                    }
                    if ($menuConfig[$choice].Supported -eq $false) {
                         $message = Get-LocaleMessage -Key 'log.target.unsupported' -MessageArgs @($choice, $menuConfig[$choice].Label, $ctx.projectType)
                         Write-Log $message 'Err' $State
                         throw $message

                    }
                    Write-Log (Get-LocaleMessage -Key 'log.target.using' -MessageArgs @($choice, $menuConfig[$choice].Label)) 'Info' $State
                } elseif ($State.ExplicitProject) {
                    # -Project given without -Target: auto-pick the PRODUCT's default
                    # build action so the shortest command (.\_Build\gbuild -Project "<product>")
                    # builds that product directly instead of prompting a menu. The factory
                    # (_Build) location is never used as the product.
                     $choice = Resolve-AutoBuildChoice -MenuConfig $menuConfig -State $State -ProjectType $ctx.projectType -BuildContext $ctx
                     if ([string]::IsNullOrWhiteSpace($choice)) { throw (Get-LocaleMessage -Key 'log.orch.noSupportedBuildTarget' -Fallback 'No supported build target is available for this project.') }

                    Write-Log (Get-LocaleMessage -Key 'log.target.auto' -MessageArgs @($choice, $menuConfig[$choice].Label, $ctx.projectType)) 'Info' $State
                    # Discoverability tip: tell the operator how to reach the FULL feature set
                    # (menu / -Target / deploy / CI / security ...) instead of only auto-build.
                    if (-not $State.NonInteractive -and -not $State.IsCI -and (Get-Command Test-InteractiveSession -ErrorAction SilentlyContinue)) {
                        Show-TargetUsageTip -MenuConfig $menuConfig -State $State
                    }
                } else {
                    $choice = Show-GuildMenu -MenuConfig $menuConfig -State $State -GitHub:$GitHub
                }
                $ctx.choice = $choice
                if ($choice -eq '0') { return }
                 $ctx.buildAttempted = $true
                 Show-ProgressBar -Current 3 -Total 4 -Label $menuConfig[$choice].Label
                 $choiceResult = Invoke-GuildChoice -Choice $choice -MenuConfig $menuConfig -State $State -ProjPath $ctx.projPath -ProjectDir $ctx.projectDir -ProjectType $ctx.projectType -Tfms $ctx.tfms -DefaultTfm $ctx.defaultTfm -WinTfm $ctx.tfmInfo.WinTfm -AndroidTfm $ctx.tfmInfo.AndroidTfm -IosTfm $ctx.tfmInfo.IosTfm -MacTfm $ctx.tfmInfo.MacTfm -ParallelProjects ([string[]]$ctx.parallelProjects) -Incremental:$Incremental -PipelineContext $ctx
                 $buildChoices = Get-BuildTargetChoices
                 # Config-driven project-type list. This used to be a
                 # hardcoded 10-item array that omitted 'Unknown' and
                 # therefore could not honour a build.menu.dotnetTypes
                 # override the way Menu.psm1:132 does.
                 $dotnetTypes = @(Get-ProjectTypes -State $State)
                 $testFlags = Get-BuildTestConfig -State $State
                 $buildOk = $false
                 if ($choice -in $buildChoices) {
                     # Invoke-GuildChoice already validated build targets and
                     # threw on failure, so this is a READ of the verdict,
                     # not a second validation.
                     $buildOk = Test-RequiredResult -Result $choiceResult -Operation "target:$choice"
                 } else {
                     $actionResult = ConvertTo-OperationResult -Value $choiceResult -Operation "target:$choice"
                     $buildOk = ($actionResult.Status -eq 'Succeeded')
                     if ($choice -in (Get-FatalActionChoices) -and -not $buildOk) {
                         $message = if ($choiceResult -and $choiceResult.Message) { [string]$choiceResult.Message } else { "Target '$choice' failed" }
                         Write-Fail $message -State $State
                         throw $message
                     }
                 }
                  $ctx.buildOk = $buildOk
                  if ($choice -in $buildChoices) {
                      Update-BuildPublishOutput -Context $ctx -State $State -PluginResult $choiceResult -ProjectDir $ctx.projectDir | Out-Null
                  }
                  if ($choice -in $buildChoices -and ($testFlags.TestEnabled -or $testFlags.LintEnabled)) {
                      # Prefer the DETECTED language, exactly as the interactive 'T'/'I' arms do at
                  # the top of this function. This line used to collapse every
                  # .NET project type to the literal 'C#' BEFORE consulting
                  # langInfo, so an Avalonia project auto-built through
                  # Invoke-PluginTestFor with Language='C#'. Loader resolves
                  # a plugin by matching SupportedLanguages and then taking
                  # the LOWEST priority, so 'C#' routed to Dotnet (priority
                  # 1) and the Avalonia plugin (priority 10) was never
                  # consulted - the same project therefore tested DIFFERENTLY
                  # depending on whether you ran `gbuild` or `gbuild -Target T`.
                  # $dotnetTypes is retained only as the fallback for when
                  # detection produced nothing at all.
                   $testLang = if ($ctx.langInfo -and $ctx.langInfo.Language) { [string]$ctx.langInfo.Language } elseif ($ctx.langInfo) { [string]$ctx.langInfo } elseif ($ctx.projectType -in $dotnetTypes) { 'C#' } else { $ctx.projectType }
                       if ($testFlags.TestEnabled) { Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningTests' -MessageArgs @([string]$testLang) -Fallback 'Running tests for {0}...') }
                       if ($testFlags.LintEnabled) { Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningLint' -MessageArgs @([string]$testLang) -Fallback 'Running lint for {0}...') }
                       Invoke-PluginTestAndLintGate -State $State -ProjectDir $ctx.projectDir -Language $testLang -TestFlags $testFlags -Detailed | Out-Null
                   }
                 if (Get-Command Get-ErrorSummary -ErrorAction SilentlyContinue) { $errSummary = Get-ErrorSummary; if ($errSummary -and $errSummary.Total -gt 0 -and $State.LogLevel -ge 1 -and (Get-Command Show-ErrorReport -ErrorAction SilentlyContinue)) { Show-ErrorReport -State $State } }
                 $totalSec = [math]::Round(((Get-Date) - $State.StartTime).TotalSeconds, 1)
                 $ctx.totalSec = $totalSec
                 Write-Host "`n"; Write-Sep; _2Col "  [PIPELINE DONE] $(Get-LocaleMessage -Key 'log.system.completed')" (Get-LocaleMessage -Key 'log.system.total' -MessageArgs @($totalSec)) 'Succ' 'Gray' $State; Write-Sep
                 if (Get-Command Write-BuildMetric -ErrorAction SilentlyContinue) {
                     $metric = Write-BuildMetric -State $State -Status $(if ($buildOk) { 'Success' } else { 'Failure' }) -Duration $totalSec -ProjectName $csproj.BaseName -Configuration $resolvedCfg -TargetFramework $ctx.defaultTfm -OutputType $ctx.projectType
                     $ctx.metric = $metric
                     if (Get-Command Save-BuildReport -ErrorAction SilentlyContinue) {
                         try { $null = Save-BuildReport -State $State -Metric $metric } catch { }
                     }
                     if (Get-Command Write-TelemetryEntry -ErrorAction SilentlyContinue) { Write-TelemetryEntry -State $State -Metric $metric | Out-Null }
                     if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) { Submit-BuildMetric -State $State -Step $ctx.projectType -DurationMs ($totalSec * 1000) -Success:$buildOk -ProjectName $csproj.BaseName -Configuration $resolvedCfg -TargetFramework $ctx.defaultTfm -OutputType $ctx.projectType | Out-Null }
                 }

            }
        }
    },
    @{
        Name = 'SecurityScan'
        Script = {
            param($ctx)
            # L5 GATE WIRING. This gate used to live ONLY in the finally block
            # behind `if ($Security.IsPresent)`, so the secret scan, the
            # vulnerable-package audit and license compliance never ran on a
            # default build and never ran in CI (build.yml drives
            # `-Target 10 -NonInteractive`, with no -Security). A gate that
            # only runs when someone remembers a switch is not a gate.
            # It is now a first-class pipeline step, enabled by
            # security.scanOnBuild (ships TRUE). -Security still forces it on.
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SECURITY' -Reason 'security.scanOnBuild=false' -EnablePaths @('security.scanOnBuild') -DefaultEnabled $true -ForceOn:$Security.IsPresent)) { return }
            Import-ModuleOnDemand -ModuleNames @('Security')
            if (-not (Get-Command Invoke-SecurityScan -ErrorAction SilentlyContinue)) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m86' -MessageArgs @(${lb}, ${rb})) 'Gray' $State; return }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m83' -MessageArgs @(${lb}, ${rb})) 'Info' $State
            $secResult = Invoke-SecurityScan -State $State
            if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) { Set-BuildStateProperty -State $State -Name 'SecurityScanCompleted' -Value $true -Force }
            # PERSIST THE EVIDENCE, not just the in-memory flag. State is a
            # PowerShell object that dies with the process, so setting
            # SecurityScanCompleted left CI with nothing to assert against: the
            # "the security gate must run on a default build" check in
            # .github/workflows/build.yml could only read security.scanOnBuild
            # back out of the config, which is the very claim it was supposed
            # to test. This file is what makes the step observable.
            if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) {
                try {
                    $secDir = Get-ReportDirectory -State $State
                    if ($secDir) {
                        $null = Write-BuildJsonFile -Path (Join-Path $secDir 'security-scan.json') -Atomic -Data ([PSCustomObject]@{
                                CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                                Pass           = [bool]$secResult.Pass
                                Critical       = $secResult.Critical
                                High           = $secResult.High
                                Medium         = $secResult.Medium
                                Vulnerabilities = $secResult.Vulnerabilities
                                License        = $secResult.License
                            })
                    }
                } catch { }
            }
            if ($secResult -and -not $secResult.Pass) {
                # ENFORCEMENT. security.blockOnCriticalVulns=true and
                # security.licenseEnforcement='block' were decorative while this
                # only logged: a committed AWS key produced a green build.
                $detail = "Critical=$($secResult.Critical), High=$($secResult.High), Medium=$($secResult.Medium), Vulnerabilities=$($secResult.Vulnerabilities), LicenseViolations=$($secResult.License)"
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m84' -MessageArgs @(${lb}, ${rb}, $detail)) 'Err' $State
                Set-GBuildExitCode -Code 2 -Reason 'security-scan'
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    # Write-AuditLog declares -Action/-Outcome/-State/-Detail. This
                    # used to pass -Type/-Result, which do not exist: parameter
                    # binding threw inside the try/catch and the denial entry was
                    # silently dropped - on exactly the event an auditor queries.
                    try { Write-AuditLog -Action 'security:scan' -Outcome 'Denied' -Detail $detail -State $State } catch { }
                }
                throw (Get-LocaleMessage -Key 'log.security.failed')
            }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m85' -MessageArgs @(${lb}, ${rb})) 'Succ' $State
        }
    },
    @{
        Name = 'AutoTune'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'AUTOTUNE' -Reason 'autoTune.enabled=false or autoApply=false' -EnablePaths @('autoTune.enabled','autoTune.autoApply') -RequireAll)) { return }
            Import-ModuleOnDemand -ModuleNames @('AutoTuner')
            if (Get-Command Invoke-AutoTuneApply -ErrorAction SilentlyContinue) {
                $applied = Invoke-AutoTuneApply -State $State
                if ($applied.Count -gt 0) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m75' -MessageArgs @($($applied -join ', '))) 'Succ' $State
                } else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m76') 'Info' $State
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m77') 'Gray' $State }
        }
    },
    @{
        Name = 'SupplyChain'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SUPPLYCHAIN' -Reason 'security.sbom/provenance disabled' -EnablePaths @('security.sbom.enabled','security.provenance.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('SupplyChain')
            if (Get-Command Invoke-SupplyChainChecks -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.supplychain.running') 'Info' $State
                # PublishOutput was never passed here, so provenance (enabled by
                # default via security.provenance.enabled) always threw
                # 'publish output unavailable' and the default-enabled
                # supply-chain step failed EVERY build even though the build
                # had just produced its artifacts. Resolve the same publish
                # root Build.psm1 writes to (Resolve-PublishOutputDir).
                $publishOut = [string]$ctx.publishOutput
                if ([string]::IsNullOrWhiteSpace($publishOut) -and $ctx.projectDir) {
                    $pubRoot = if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) { [string](Resolve-PublishOutputDir -State $State) } else { 'publish-output' }
                    if (-not [string]::IsNullOrWhiteSpace($pubRoot)) {
                        $candidate = if ([System.IO.Path]::IsPathRooted($pubRoot)) { $pubRoot } else { Join-Path ([string]$ctx.projectDir) $pubRoot }
                        if (Test-Path -LiteralPath $candidate -PathType Container) { $publishOut = $candidate }
                    }
                }
                $sc = Invoke-SupplyChainChecks -State $State -ProjectDir $ctx.projectDir -PublishOutput $publishOut
                # Invoke-SupplyChainChecks returns a hashtable with Pass; it has
                # no Status property, so the previous `$sc.Status -eq 'Skipped'`
                # branch was always false.
                $status = if ($sc -and $sc.Pass) { 'Passed' } else { 'Failed' }
                $statusText = Get-LocaleMessage -Key "log.status.$($status.ToLowerInvariant())"
                Write-Log (Get-LocaleMessage -Key 'log.supplychain.status' -MessageArgs @($statusText)) $(if ($status -eq 'Passed' -or $status -eq 'Skipped') { 'Succ' } else { 'Warn' }) $State
                if (-not $sc.Pass) { throw (Get-LocaleMessage -Key 'log.supplychain.failed') }
            } else { Write-Log (Get-LocaleMessage -Key 'log.supplychain.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'SastScan'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SAST' -Reason 'security.sast.enabled=false' -EnablePaths @('security.sast.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Sast')
            if (Get-Command Invoke-SastScan -ErrorAction SilentlyContinue) {
                $dir = if ($ctx.projectDir) { $ctx.projectDir } elseif ($State.ProjectRoot) { $State.ProjectRoot } else { $State.ScriptRoot }
                $sr = Invoke-SastScan -State $State -ProjectDir $dir
                $icon = switch ($sr.Status) { 'Passed' { 'Succ' } 'Skipped' { 'Gray' } 'Warned' { 'Warn' } default { 'Warn' } }
                $statusText = Get-LocaleMessage -Key "log.status.$(([string]$sr.Status).ToLowerInvariant())" -Fallback ([string]$sr.Status)
                Write-Log (Get-LocaleMessage -Key 'log.sast.status' -MessageArgs @($statusText, $sr.TotalFindings)) $icon $State
                # "Blocked (findings=0)" named the finding count as the reason for
                # a block even when nothing had been scanned - the scanner was not
                # installed. The scan now reports why it closed; print it, so the
                # operator is told what the platform could not run rather than being
                # pointed at a count of zero.
                if ((-not $sr.Pass) -and $sr.Reason) {
                    Write-Log (Resolve-LogMessage -Key 'log.sast.gateReason' -MessageArgs @([string]$sr.Reason) -Fallback '[SAST] Gate closed because: {0}') 'Warn' $State
                }
                # PUBLISH THE FINDINGS. Invoke-SastScan already produces
                # findings in the SARIF shape, and Report.psm1 already ships a
                # SARIF 2.1.0 writer - but nothing connected the two, so the
                # findings died with the process and no code-scanning consumer
                # ever received a file. This runs BEFORE the verdict is thrown
                # so a FAILED scan still leaves the evidence on disk.
                Import-ModuleOnDemand -ModuleNames @('Report')
                if (Get-Command Publish-BuildSarifArtifact -ErrorAction SilentlyContinue) {
                    try {
                        $sarifFindings = @()
                        foreach ($check in @($sr.Checks)) {
                            if ($null -eq $check) { continue }
                            foreach ($f in @($check.Findings)) { if ($null -ne $f) { $sarifFindings += $f } }
                        }
                        if ($sarifFindings.Count -gt 0) {
                            $sarifPath = Publish-BuildSarifArtifact -State $State -Findings $sarifFindings -ToolName 'gbuild-sast'
                            if ($sarifPath) { Write-Log (Resolve-LogMessage -Key 'log.sast.sarifWritten' -MessageArgs @([string]$sarifPath) -Fallback '[SAST] SARIF findings written: {0}') 'Gray' $State }
                        }
                    } catch { }
                }
                if (-not $sr.Pass) { Write-Log (Get-LocaleMessage -Key 'log.sast.failed') 'Err' $State; throw (Get-LocaleMessage -Key 'log.sast.failed') }
            } else { Write-Log (Get-LocaleMessage -Key 'log.sast.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'PolicyCheck'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'POLICY' -Reason 'security.policy.enabled=false' -EnablePaths @('security.policy.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Policy')
            if (Get-Command Invoke-PolicyChecks -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.policy.running') 'Info' $State
                $pr = Invoke-PolicyChecks -State $State -ProjectDir $ctx.projectDir
                $status = if ($pr -and $pr.Pass) { 'Passed' } elseif ($pr -and $pr.Status -eq 'Skipped') { 'Skipped' } else { 'Failed' }
                $statusText = Get-LocaleMessage -Key "log.status.$($status.ToLowerInvariant())"
                Write-Log (Get-LocaleMessage -Key 'log.policy.status' -MessageArgs @($statusText)) $(if ($status -eq 'Passed' -or $status -eq 'Skipped') { 'Succ' } else { 'Warn' }) $State
                # Read the enforcement mode FROM THE MODULE RESULT. This used to
                # test `$cfg.enforcement`, a variable that does not exist in this
                # step's closure ($cfg is a local of the Preflight step, :2904) -
                # an unset variable in a GetNewClosure() scope resolves to $null
                # silently, so the test was always false and
                # security.policy.enforcement="block" NEVER threw. Policy
                # violations shipped green. Invoke-PolicyChecks already returns
                # the resolved Enforcement (:364, :377, :383), so this consumes
                # the module's own decision instead of re-deriving it.
                $enforcement = ''
                if ($pr -and $pr.PSObject.Properties.Name -contains 'Enforcement') { $enforcement = [string]$pr.Enforcement }
                if (-not $enforcement) {
                    # Single-value reader, not Get-ConfigSection: the gate
                    # contract (pinned by PipelineBuiltIn.Tests) forbids inlining
                    # the section read - the step-enabled helper owns the enable
                    # decision, and enforcement is a separate concern resolved
                    # here through the same accessor every other value uses.
                    try { $enforcement = [string](Get-ConfigValue -Path 'security.policy.enforcement' -State $State -Default 'block') } catch { $enforcement = 'block' }
                    if ([string]::IsNullOrWhiteSpace($enforcement)) { $enforcement = 'block' }
                }
                if ($status -eq 'Failed' -and $enforcement -in @('block', 'fail') -and -not $pr.Pass) { throw (Get-LocaleMessage -Key 'log.policy.failed') }
                # A backend-evaluation failure under 'warn' is the one case that
                # must still surface as an error: the gate did not actually run.
                if ($status -eq 'Failed' -and $enforcement -eq 'warn' -and $pr.Status -eq 'Failed') {
                    Write-Log (Get-LocaleMessage -Key 'log.policy.status' -MessageArgs @($statusText)) 'Warn' $State
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.policy.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'SiemExport'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SIEM' -Reason 'security.siem.enabled=false' -EnablePaths @('security.siem.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Siem')
            if (Get-Command Export-SiemEvents -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.siem.running') 'Info' $State
                $se = Export-SiemEvents -State $State
                # Two defects in this step's verdict handling:
                #  1. It read $se.OutputFile, which does not exist - Export-SiemEvents
                #     returns OutputPath, so the destination always printed empty.
                #  2. It logged 'Succ' UNCONDITIONALLY. Export-SiemEvents sets
                #     Status='Failed' when the HTTP transport rejects the batch or
                #     the file write fails, so a failed SIEM export reported
                #     success and the pipeline continued.
                # The step is an export/telemetry sink, not an enforcement gate,
                # so a failed export is reported as an error but does NOT fail
                # the build (security.siem has no enforcement mode); making it
                # fatal would let an unreachable SIEM break every build.
                $seStatus = [string]$se.Status
                $seColor = if ($seStatus -eq 'Exported') { 'Succ' } elseif ($seStatus -eq 'Skipped') { 'Gray' } else { 'Err' }
                $statusText = Get-LocaleMessage -Key "log.status.$($seStatus.ToLowerInvariant())" -Fallback $seStatus
                Write-Log (Get-LocaleMessage -Key 'log.siem.status' -MessageArgs @($statusText, $se.Count, $se.OutputPath)) $seColor $State
            } else { Write-Log (Get-LocaleMessage -Key 'log.siem.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'StandaloneBundle'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'STANDALONE' -Reason 'build.standalone.enabled=false' -EnablePaths @('build.standalone.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Standalone')
            if (Get-Command New-StandaloneBundle -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.standalone.running') 'Info' $State
                $sb = New-StandaloneBundle -State $State
                # The step logged 'Succ' unconditionally and never read $sb.Status,
                # but New-StandaloneBundle returns Status='Failed' when the module
                # set could not be embedded or when signing / SBOM / provenance
                # failed - so a bundle that could not be produced reported
                # success and the pipeline continued. Producing a signed
                # standalone artifact is the point of this step, so a Failed
                # verdict fails the run.
                $sbStatus = [string]$sb.Status
                $sbColor = if ($sbStatus -eq 'Succeeded') { 'Succ' } elseif ($sbStatus -eq 'Skipped') { 'Gray' } else { 'Err' }
                $statusText = Get-LocaleMessage -Key "log.status.$($sbStatus.ToLowerInvariant())" -Fallback $sbStatus
                Write-Log (Get-LocaleMessage -Key 'log.standalone.status' -MessageArgs @($statusText, $sb.OutputFile)) $sbColor $State
                if ($sbStatus -eq 'Failed') {
                    if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 2 -Reason 'standalone-bundle' }
                    throw (Get-LocaleMessage -Key 'log.standalone.failed' -MessageArgs @($statusText) -Fallback 'Standalone bundle generation failed.')
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.standalone.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'PublishArtifact'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'ARTIFACT' -Reason 'build.publishArtifact.enabled=false' -EnablePaths @('build.publishArtifact.enabled'))) { return }
            $artifactStep = Join-Path $State.ScriptRoot 'Steps/publish-artifact.ps1'
            if (Test-Path $artifactStep) {
                try {
                    & $artifactStep -State $State -ErrorAction Stop
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m78' -MessageArgs @($_)) 'Warn' $State
                }
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m79') 'Gray' $State
            }
        }
    }
    )
    foreach ($s in $built) { if ($s.Script) { $s.Script = $s.Script.GetNewClosure() } }
    return $built
}

<#
.SYNOPSIS
    Records a step that was skipped because its feature is disabled.
.DESCRIPTION
    Scoped pipeline logging: disabled optional steps are collected into
    $Context.skippedSteps and reported as ONE summary line so each build only
    shows logs relevant to its own project type. Set build.scopedLogging=false
    for the legacy per-step lines.
#>
function Test-StepEnabled {
    # Single owner of the step enable/disable prologue that was hand-copied
    # into each of the nine optional gate steps (AffectedScan, SecurityScan,
    # AutoTune, SupplyChain, SastScan, PolicyCheck, SiemExport,
    # StandaloneBundle, PublishArtifact). Each copy read Get-ConfigSection,
    # pulled its 'enabled' value, and Write-SkippedStep'd when off - but the
    # copies had already started to drift (SupplyChain used one value key,
    # SecurityScan ORed a CLI switch into the same decision, AutoTune
    # conjoined a second key). This helper owns the decision; the step keeps
    # only its own body.
    #
    # Keys: config dot-paths resolved by Get-ConfigSection's own
    # enabled/value lookup. Sections: for gates keyed off a non-'enabled'
    # value, set -ValueKey. OnePath/OneKey pairs are the simple case; the
    # SupplyChain gate passes two (sbom | provenance).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$StepLabel,
        [Parameter(Mandatory)] [string]$Reason,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        # Dot-paths (read by Get-ConfigValue) to the boolean enablement values.
        # One path = a single gate switch; several = OR (SupplyChain:
        # 'security.sbom.enabled' OR 'security.provenance.enabled').
        [Parameter(Mandatory)] [string[]]$EnablePaths,
        # When no path yields a value, this default decides (single-source
        # fallback for a config-less project). RequireAll mode ignores it (a
        # AND-gate without every key cannot prove it is armed, so it is off).
        [bool]$DefaultEnabled = $false,
        # Every path must be present AND true (AutoTune: enabled AND autoApply).
        [switch]$RequireAll,
        # A CLI switch that forces the gate on (SecurityScan's -Security).
        [bool]$ForceOn
    )
    # Resolve over Get-ConfigValue so leaves and sections read uniformly.
    # OR mode (default): true if any path's value is truthy. If NO path
    # yields a value (key absent everywhere), the gate's DefaultEnabled wins.
    # RequireAll: every path's value must be truthy; a null/absent path counts
    # as false (a gate without its config cannot prove it is armed).
    # ForceOn (a CLI switch) always wins.
    $enabled = $DefaultEnabled
    $saw = $false; $anyTrue = $false
    foreach ($pp in $EnablePaths) {
        $v = Get-ConfigValue -Path $pp -State $State -Default $null
        if ($null -ne $v) {
            $saw = $true
            $b = $false
            try { $b = [bool]$v } catch { $b = ($v -is [string] -and $v.ToLowerInvariant() -eq 'true') }
            if ($b) { $anyTrue = $true }
            elseif ($RequireAll) { $anyTrue = $false; break }
        } elseif ($RequireAll) { $anyTrue = $false; break }
    }
    if ($RequireAll) {
        # All must be present-and-true; a single absent path already failed
        # above. Count true-only paths.
        $trueCount = 0
        foreach ($pp in $EnablePaths) {
            $v = Get-ConfigValue -Path $pp -State $State -Default $null
            if ($null -eq $v) { $trueCount = -1; break }
            try { if ([bool]$v) { $trueCount++ } } catch { $trueCount = -1; break }
        }
        $enabled = ($trueCount -ne -1 -and $trueCount -eq $EnablePaths.Count)
    } elseif ($saw) {
        $enabled = $anyTrue
    }
    if ($ForceOn) { $enabled = $true }
    if (-not $enabled) {
        Write-SkippedStep -Step $StepLabel -Reason $Reason -Context $Context -State $State
        return $false
    }
    return $true
}

function Write-SkippedStep {
    param([string]$Step, [string]$Reason, $Context, $State)

        $scoped = $true
        try {
            if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $scoped = [bool](Get-BuildSetting -Key 'LogScopedLogging' -State $State -Fallback $true) }
            elseif (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { $scoped = [bool](Get-ConfigValue -Path 'build.scopedLogging' -State $State -Default $true) }
        } catch { $scoped = $true }
        if ($scoped) { [void]$Context.skippedSteps.Add("$Step ($Reason)") }
        else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m66' -MessageArgs @($Step, $Reason)) 'Gray' $State }
    }

<#
.SYNOPSIS
    Single writer for the pipeline publish-output location.
.DESCRIPTION
    Both build branches (plugin dispatch and menu-driven .NET) funnel through
    here so downstream consumers (SupplyChain provenance, deploy targets, GPG
    signing) share one source. Previously every consumer read
    $ctx.publishOutput, which nothing in either branch ever assigned, so the
    provenance/deploy chain always fell back to re-resolving a directory
    that might not exist - and a green build with no artifacts passed
    silently, leaving the operator to discover the missing folder.
    Never throws: returns '' when nothing was produced, and says so loudly.
#>
function Update-BuildPublishOutput {
    param($Context, $PluginResult, [string]$ProjectDir, $State)
        $resolved = ''
        try {
            if ($null -ne $PluginResult -and (Get-Command Get-PluginDispatchOutputPath -ErrorAction SilentlyContinue)) {
                try { $resolved = [string](Get-PluginDispatchOutputPath -Result $PluginResult -State $State -ProjectDir $ProjectDir) } catch { $resolved = '' }
            }
            if ([string]::IsNullOrWhiteSpace($resolved)) {
                $pubName = 'publish-output'
                try {
                    if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) { $pubName = [string](Resolve-PublishOutputDir -State $State) }
                } catch { $pubName = 'publish-output' }
                if (-not [string]::IsNullOrWhiteSpace($pubName)) {
                    $anchor = ''
                    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) { $anchor = $ProjectDir }
                    elseif ($State -and $State.ProjectRoot) { $anchor = [string]$State.ProjectRoot }
                    if ($anchor) {
                        $candidate = if ([System.IO.Path]::IsPathRooted($pubName)) { $pubName } else { Join-Path $anchor $pubName }
                        if ((Test-Path -LiteralPath $candidate -PathType Container) -and @(Get-ChildItem -LiteralPath $candidate -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                            $resolved = $candidate
                        }
                    }
                }
            }
        } catch { $resolved = '' }
        try { $Context.publishOutput = $resolved } catch { }
        if ($resolved) {
            Write-Log (Get-LocaleMessage -Key 'log.build.publishOutputDir' -MessageArgs @($resolved)) 'Succ' $State
        } else {
            Write-Log (Get-LocaleMessage -Key 'log.build.noPublishOutput') 'Warn' $State
        }
        return $resolved
    }

function Start-GBuild {
    [CmdletBinding()]
    param([switch]$GitHub, [switch]$NonInteractive, [switch]$Incremental, [switch]$Clean, [switch]$CacheClear, [switch]$CacheOptimize, [switch]$CacheStats, [switch]$VersionBump, [switch]$Force,
                 [switch]$Security, [switch]$Distributed, [switch]$VerifyInfra, [string]$Target = '', [string]$LogLevel = "Info")
    $State = $null
    $buildAttempted = $false
    $buildFailed = $false
    $configEnvironmentScope = $null
    $lb = '['
    $rb = ']'
    try {

        $State = Get-BuildState
        $buildAttempted = $false; $buildFailed = $false
        if (-not $State) {
            Write-Host ('[FATAL] ' + (Resolve-LogMessage -Key 'log.orchestrator.gstateNotInitialized' -Fallback 'GState not initialized.')) -ForegroundColor Red
            # A bare `return` here exited 0: "no state" reported success. Record
            # the verdict and throw so the launcher exits nonzero. Safe: the
            # outer catch tolerates $State=$null (Write-LogSafe defaults it) and
            # Invoke-Rollback no-ops on the just-cleared stack.
            if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 1 -Reason 'no-state' }
            throw (Get-LocaleMessage -Key 'log.orch.gstateNotInitialized' -Fallback 'GState not initialized.')
        }

        # Reset per-run accumulators at the start of every build so a stack left
        # behind by a previously crashed run cannot leak actions into this one.
        if (Get-Command Clear-RollbackStack -ErrorAction SilentlyContinue) { Clear-RollbackStack }
        # The event bus and the metric registry are the other two per-run
        # accumulators, and they were NOT reset here. Reset-ErrorLog documents
        # the long-lived-host case explicitly ("hosts that call Start-GBuild more
        # than once in a session"), and in exactly that scenario the second run
        # inherited the first run's event subscribers and metric counters: the
        # subscriber registry is keyed by tenant+event, so
        # Register-BuildEventSubscribers saw non-zero counts and skipped
        # re-registering, and the second build's metrics were cumulative rather
        # than per-run. Both are correctness bugs in a reuse scenario, not
        # cosmetics.
        if (Get-Command Clear-BuildEvents -ErrorAction SilentlyContinue) {
            try { Clear-BuildEvents -TenantId '' } catch { }
        }
        if (Get-Command Clear-Metrics -ErrorAction SilentlyContinue) {
            try { Clear-Metrics } catch { }
        }
        # FULL per-run reset (long-lived hosts calling Start-GBuild twice).
        # Each of these leaked run-1 state into run 2 before:
        #  - Reset-ErrorLog: $script:ErrorLog survived AND Restore-BuildState
        #    repopulated it from the previous run's file, so run 2 printed run
        #    1's error summary and inflated telemetry ErrorCount. (Clear-
        #    RollbackStack above is only half of Reset-ErrorLog.)
        #  - Reset-CircuitBreaker: an Open breaker from run 1 threw
        #    'Circuit breaker OPEN' before run 2 did any work.
        #  - Reset-ReportCache: $script:ReportDir memo sent run 2's reports
        #    into run 1's project tree; $script:BuildMetrics aggregated both runs.
        #  - Reset-AuditLogPath: $script:AuditLogPath memo sent run 2's audit
        #    entries to run 1's logs/<tenant>/audit.log.
        #  - Plugin registry: never cleared, so run 2 dispatched to a
        #    PSModuleInfo for a module Remove-Module'd during re-registration
        #    (run-1 code executing after the source changed).
        #  - Exit channel: Reset-GBuildExitCode ran only from the launcher, so a
        #    host calling Start-GBuild twice inherited run 1's verdict.
        # Every call is guarded: a missing module must degrade to the previous
        # behaviour, never break the bootstrap.
        if (Get-Command Reset-ErrorLog -ErrorAction SilentlyContinue) {
            try { Reset-ErrorLog } catch { }
        }
        if (Get-Command Reset-CircuitBreaker -ErrorAction SilentlyContinue) {
            try { Reset-CircuitBreaker } catch { }
        }
        if (Get-Command Reset-ReportCache -ErrorAction SilentlyContinue) {
            try { Reset-ReportCache } catch { }
        }
        if (Get-Command Reset-AuditLogPath -ErrorAction SilentlyContinue) {
            try { Reset-AuditLogPath } catch { }
        }
        if (Get-Command Reset-SdkMemo -ErrorAction SilentlyContinue) {
            try { Reset-SdkMemo } catch { }
        }
        try {
            if (Test-Path Variable:global:GBuildPluginRegistry) {
                $reg = $global:GBuildPluginRegistry
                if ($reg -and ($reg.PSObject.Methods.Name -contains 'Clear')) { $reg.Clear() }
            }
        } catch { }
        if (Get-Command Reset-GBuildExitCode -ErrorAction SilentlyContinue) {
            try { Reset-GBuildExitCode } catch { }
        }
        # Per-run State properties stamped by the previous run. A fresh
        # CorrelationId per run (Initialize-BuildIdentity only mints when
        # absent); SecurityScanCompleted must not suppress run 2's scan; the
        # failure-attribution trio must not poison run 2's success.
        try {
            if ($State.PSObject.Properties.Name -contains 'CorrelationId') {
                $State.PSObject.Properties.Remove('CorrelationId')
            }
        } catch { }
        foreach ($propName in @('SecurityScanCompleted', 'LastFailureCategory', 'LastFailureConfidence', 'FailureReason', 'BuildGateFailed', 'AuditLedgerLastSeq', 'LastNonRetryableOperation')) {
            try {
                if ($State.PSObject.Properties.Name -contains $propName) {
                    $State.PSObject.Properties.Remove($propName)
                }
            } catch { }
        }

        # RESUME / CRASH DETECTION. The state file was write-only: Save-BuildState
        # ran once (inside Resolve-BuildSdk) and Restore-BuildState had no caller
        # anywhere in the product, so the "resume-on-crash checkpoint" the comment
        # claimed never actually resumed and an interrupted run was
        # indistinguishable from a clean one. Read the previous run's marker now.
        # This is deliberately READ-ONLY with respect to live configuration: the
        # restored object is surfaced as PreviousBuild* facts for the banner, the
        # report and telemetry, never merged over this run's State, because a
        # stale config or path from a crashed run must not steer a fresh build.
        if (Get-Command Restore-BuildState -ErrorAction SilentlyContinue) {
            try {
                $priorPath = Get-StateFilePath -State $State
                if ($priorPath -and (Test-Path -LiteralPath $priorPath -PathType Leaf)) {
                    $prior = Restore-BuildState -Path $priorPath
                    $priorInfo = Get-RestoredStateInfo
                    if ($prior) {
                        $priorSaved = ''
                        if ($priorInfo) { $priorSaved = [string]$priorInfo.SavedAt }
                        $priorComplete = $true
                        if ($priorInfo -and $priorInfo.PSObject.Properties.Name -contains 'Completed') { $priorComplete = [bool]$priorInfo.Completed }
                        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
                            Set-BuildStateProperty -State $State -Name 'PreviousBuildSavedAt' -Value $priorSaved -Force
                            Set-BuildStateProperty -State $State -Name 'PreviousBuildCompleted' -Value $priorComplete -Force
                        }
                        if (-not $priorComplete) {
                            # An interrupted predecessor is actionable: the tree may
                            # hold half-written output, so say so rather than
                            # letting the next build quietly build on top of it.
                            Write-Log (Get-LocaleMessage -Key 'log.state.previousIncomplete' -MessageArgs @($priorSaved)) 'Warn' $State
                        }
                        # The previous run's ERRORS are deliberately not replayed
                        # into this run's log, but "how badly did the last run
                        # fail" is exactly what an operator resuming a broken tree
                        # needs, and Get-RestoredStateInfo is the accessor that
                        # carries it. Report it here rather than leaving the count
                        # parsed-then-discarded, and say plainly that it is NOT
                        # part of this run's tally.
                        $priorErrors = 0
                        if ($priorInfo -and $priorInfo.PSObject.Properties.Name -contains 'PreviousErrorCount') { $priorErrors = [int]$priorInfo.PreviousErrorCount }
                        if ($priorErrors -gt 0) {
                            Write-Log (Get-LocaleMessage -Key 'log.state.previousHadErrors' -MessageArgs @($priorErrors, $priorSaved)) 'Warn' $State
                        }
                    }
                }
            } catch { }
        }

        # Reset StartTime for accurate total duration (fixes 6565s bug when GState reused across builds).
        # Set via Add-Member primitive (Set-BuildStateProperty): direct
        # assignment of a missing StartTime throws "cannot be found on this
        # object" on hosts whose PSObject adapter refuses new-member
        # assignment, and on deserialized (CliXml) states.
        Set-BuildStateProperty -State $State -Name 'StartTime' -Value (Get-Date) -Force
        if ((Test-Path Variable:global:GBuildServices) -and $global:GBuildServices.ContainsKey('BuildContext') -and $global:GBuildServices['BuildContext'].Instance) {
            try { $global:GBuildServices['BuildContext'].Instance.StartTime = $State.StartTime } catch {}
        }

        # --- Bootstrap: config, correlation, tenant, event subscribers, DI services -----
        # Config must be stamped before locale, profiles, menu, SDK auto-provision,
        # security, deploy and build type actions read it. Previously production
        # left BuildConfig unset, so known types such as WinForms still hit the
        # "Unknown project type" fallback in Build.psm1.
         if (Get-Command Initialize-BuildConfigState -ErrorAction SilentlyContinue) {
             $null = Initialize-BuildConfigState -State $State
         }
         if (Get-Command Enter-BuildConfigEnvironment -ErrorAction SilentlyContinue) {
             $configEnvironmentScope = Enter-BuildConfigEnvironment -State $State
         }
         Initialize-BuildIdentity -State $State
        if (Get-Command Set-LocaleFromState -ErrorAction SilentlyContinue) { Set-LocaleFromState -State $State | Out-Null }
        # $null = on every bootstrap call whose return value is discarded.
        # Register-BuildEventSubscribers issues one Add-BuildEvent per subscriber
        # and each returns $true, so the bare call pushed 21 bare 'True' lines
        # onto stdout on every run. Start-GBuild is a library function invoked
        # bare from gbuild.ps1, so those booleans reached the host console - they
        # never entered the log file, so no log-based gate could ever see them,
        # and they corrupted stdout for every consumer that parses it (CI
        # capture, Docker, gbuild.bat redirection). Suppress at the call site;
        # the values were never used.
        $null = Register-BuildEventSubscribers -State $State
        $null = Register-BuildServices -State $State

        # --- B4: runtime interface-contract validation (non-fatal) ----------------
        if (Get-Command Test-InterfaceContracts -ErrorAction SilentlyContinue) {
            try {
                $contract = Test-InterfaceContracts
                if ($contract.Passed) {
                    Write-Log (Get-LocaleMessage -Key 'log.system.interfaceContracts' -MessageArgs @($contract.Summary)) 'Debug' $State
                }
                else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m59' -MessageArgs @(${lb}, ${rb}, $($contract.Summary))) 'Warn' $State
                }
            }
            catch {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m60' -MessageArgs @(${lb}, ${rb}, $($_.Exception.Message))) 'Warn' $State
            }
        }
        # Level 5: plugin contract validation (non-fatal, log-only) so
        # Test-PluginContracts is wired into every build, never test-only.
        if (Get-Command Test-PluginContracts -ErrorAction SilentlyContinue) {
            try {
                $plugContract = Test-PluginContracts
                if ($plugContract.Passed) {
                    Write-Log (Get-LocaleMessage -Key 'log.system.pluginContracts' -MessageArgs @($plugContract.Summary)) 'Debug' $State
                }
                else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m61' -MessageArgs @(${lb}, ${rb}, $($plugContract.Summary))) 'Warn' $State
                }
            }
            catch {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m62' -MessageArgs @(${lb}, ${rb}, $($_.Exception.Message))) 'Warn' $State
            }
        }
        if ($NonInteractive.IsPresent -or $Distributed.IsPresent) { $State | Add-Member -MemberType NoteProperty -Name NonInteractive -Value $true -Force -EA SilentlyContinue }
        Set-BuildStateProperty -State $State -Name 'ForceBuild' -Value ([bool]$Force.IsPresent) -Force
        # Auto-enable incremental in CI/GitHub mode unless explicitly set
        if (-not $PSBoundParameters.ContainsKey('Incremental') -and ($GitHub -or $NonInteractive)) {
            $Incremental = $true
            Write-Log (Get-LocaleMessage -Key 'log.system.incrementalCi') 'Cyan' $State
        }

        # --- Core-command health gate (PS 5.1 orphan, post plugin-contracts) ----
        # Test-PluginContracts above imports every plugin; a misbehaving plugin
        # import could orphan PathUtils — fail fast with a clear cause here.
        if (Get-Command Assert-CoreCommands -ErrorAction SilentlyContinue) {
            if (-not (Assert-CoreCommands -State $State -Repair)) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m63') 'Err' $State
                Set-BuildStateProperty -State $State -Name 'FailureReason' -Value 'CoreCommandsMissing' -Force
                # Was a bare `return` (exit 0) after logging Err: missing core
                # commands reported success. Record + throw like every gate.
                if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 1 -Reason 'core-commands' }
                throw (Get-LocaleMessage -Key 'log.orchestrator.m63')
            }
        }

        # --- Environment + strategy resolution -----------------------------------
        Resolve-BuildEnvironmentAndStrategy -State $State -Incremental:$Incremental -Clean:$Clean -LogLevel $LogLevel

        # --- Logging init + metrics endpoint -------------------------------------
        Initialize-BuildLogging -State $State -LogLevel $LogLevel
        $lb = '['
        $rb = ']'

        # --- Standalone operations (early return) --------------------------------
        if (Invoke-StandaloneOperation -State $State -CacheClear:$CacheClear -CacheOptimize:$CacheOptimize -CacheStats:$CacheStats -VersionBump:$VersionBump) {
            return
        }

        # --- Config validation + profile application -----------------------------
        # A bare `return` here exited 0 on invalid config. An unbuildable
        # configuration is a failure, not a no-op. (The m55 text logged inside
        # Initialize-BuildConfigAndProfile says "continues with defaults" - it
        # describes the Warn-and-continue sub-case there, not this abort, so
        # the throw carries its own message instead of reusing it.)
        if (-not (Initialize-BuildConfigAndProfile -State $State)) {
            if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 1 -Reason 'invalid-config' }
            throw (Resolve-LogMessage -Key 'log.orchestrator.invalidConfig' -Fallback 'Build configuration is invalid. Aborting.')
        }

        # --- Menu module map integrity -------------------------------------------
        # AFTER Initialize-BuildConfigAndProfile, because $State.BuildConfig does
        # not exist until that runs - placing it earlier made every real build
        # fail on a config that had not been loaded yet, which is the opposite
        # of the failure this gate exists to catch.
        #
        # Build, Deploy, Android, Chaos, ClusterOrchestrator, HealthCheck,
        # HotReload and Documentation are named for loading ONLY by
        # build.menu.moduleMap - in no Import-ModuleOnDemand call anywhere.
        # Without this check a missing or truncated section produced a menu that
        # rendered fine, accepted a choice, and then built nothing: a green
        # build of zero work.
        Test-BuildMenuModuleMap -State $State | Out-Null

        # --- SDK resolution + checkpoint -----------------------------------------
        # "dotnet not found" exited 0. The exit-code contract reserves 127 for a
        # missing toolchain (command-not-found convention) so CI can tell it
        # apart from a failed test (1).
        if (-not (Resolve-BuildSdk -State $State)) {
            if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 127 -Reason 'sdk-missing' }
            throw (Get-LocaleMessage -Key 'log.sdk.dotnetNotFound')
        }

        # --- Infra verification standalone op (after SDK resolved) ---------------
        # Runs when -VerifyInfra/vrf is passed (even if verification.enabled=false)
        # and early-returns after writing build-reports/infra-verification.json.
        # A verification the operator EXPLICITLY requested must be honest: an
        # Overall of 'failed' exited 0 (Gray log, silent success), and a missing
        # module exited 0 after a Warn. Both now record + throw; 'ok' and
        # 'degraded' still exit 0 (degraded = warnings, reported as Warn above).
        if ($VerifyInfra.IsPresent) {
            Import-ModuleOnDemand -ModuleNames @('InfraVerification','Distributed','CacheProvider')
            if (Get-Command Invoke-InfraVerification -ErrorAction SilentlyContinue) {
                $vRes = Invoke-InfraVerification -State $State -Force
                if ($vRes) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m64' -MessageArgs @($($vRes.Overall), $($vRes.Passed), $($vRes.Failed), $($vRes.Skipped))) $(if ($vRes.Overall -eq 'ok') { 'Succ' } elseif ($vRes.Overall -eq 'degraded') { 'Warn' } else { 'Gray' }) $State }
                if ($vRes -and $vRes.Overall -eq 'failed') {
                    if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 1 -Reason 'infra-verification' }
                    throw (Resolve-LogMessage -Key 'log.orchestrator.infraFailed' -Fallback 'Infrastructure verification failed.')
                }
                return
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m65') 'Warn' $State
                if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 1 -Reason 'infra-verification-unavailable' }
                throw (Resolve-LogMessage -Key 'log.orchestrator.infraUnavailable' -Fallback 'Infrastructure verification module unavailable.')
            }
        }

                     # Precedence: strategy-resolved configuration (set by
                     # Resolve-BuildEnvironmentAndStrategy from
                     # BuildStrategyProvider.ResolveOptions) > active profile >
                     # build.defaultConfiguration > 'Release'. The strategy
                     # tier was previously absent, so a Debug build strategy
                     # produced the string 'Debug' in a log line and then built
                     # with the default configuration.
                     $resolvedCfg = ''
                     if ($State.PSObject.Properties.Name -contains 'BuildConfiguration' -and -not [string]::IsNullOrWhiteSpace([string]$State.BuildConfiguration)) { $resolvedCfg = [string]$State.BuildConfiguration }
                     if ([string]::IsNullOrWhiteSpace($resolvedCfg)) {
                         if ($State.PSObject.Properties.Name -contains 'ActiveProfile' -and $State.ActiveProfile -and $State.BuildConfig -and $State.BuildConfig.profiles) {
                             $prof = $null
                             try { $prof = $State.BuildConfig.profiles.($State.ActiveProfile) } catch { $prof = $null }
                             if ($prof -and ($prof.PSObject.Properties.Name -contains 'configuration') -and $prof.configuration) { $resolvedCfg = [string]$prof.configuration }
                         }
                     }
                     if ([string]::IsNullOrWhiteSpace($resolvedCfg)) {
                         if ($State.BuildConfig -and $State.BuildConfig.build) { $resolvedCfg = $State.BuildConfig.build.defaultConfiguration }
                         elseif (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $resolvedCfg = [string](Get-BuildSetting -Key 'DefaultConfiguration' -State $State -Fallback 'Release') }
                         else { $resolvedCfg = 'Release' }
                     }
                     if ([string]::IsNullOrWhiteSpace([string]$resolvedCfg)) { $resolvedCfg = 'Release' }

        if ($State.BuildConfig -and $State.BuildConfig.build -and $State.BuildConfig.build.enableBuildCache) {
            Import-ModuleOnDemand -ModuleNames @('Cache')
            if (Get-Command Initialize-BuildCache -ErrorAction SilentlyContinue) { Initialize-BuildCache -State $State | Out-Null }
        }
Show-GBuildBanner -State $State
        if ($Clean) {
            Import-ModuleOnDemand -ModuleNames @('Clean')
            Show-ProgressBar -Current 50 -Total 100 -Label "Standalone smart clean"
            Write-StepTitle "SMART CLEAN PROJECT" -Color "Yellow" -State $State
            if (Get-Command Invoke-SmartClean -ErrorAction SilentlyContinue) { Invoke-SmartClean -State $State -ProjectDir $State.ScriptRoot -CsprojPath "" }
            Write-Done (Resolve-LogMessage -Key 'log.orchestrator.projectCleaned' -Fallback 'Project cleaned.') -State $State; return
        }
    # -- Build Pipeline (step abstraction) --------------------------------------
    $pipelineCtx = @{
        csproj = $null; projPath = $null; projectDir = $null; projectType = $null
        tfms = @(); defaultTfm = ''; tfmInfo = $null
        parallelProjects = [System.Collections.ArrayList]@(); langInfo = $null
        choice = $null; menuConfig = $null; buildOk = $false; metric = $null
        errSummary = $null; totalSec = 0; lang = $null
        buildAttempted = $false; buildFailed = $false
        skippedSteps = [System.Collections.ArrayList]@()
    }

    # L5 wiring: every CLI switch the Build step closes over MUST be forwarded
    # here. This call passed only -State/-ResolvedCfg, so inside the closure
    # $Target was always '', $Distributed/$Security always $false, and the
    # `elseif (-not [string]::IsNullOrWhiteSpace($Target))` arm at :3026 was
    # unreachable dead code - `gbuild -Target <id>` silently fell through to
    # Resolve-AutoBuildChoice / Show-GuildMenu instead of the requested target.
    $buildSteps = Get-BuiltInPipelineSteps -State $State -ResolvedCfg $resolvedCfg -Distributed:$Distributed -Target $Target -Security:$Security -Incremental:$Incremental -GitHub:$GitHub


    try {
        Invoke-GBuildPipeline -State $State -Context $pipelineCtx -Steps $buildSteps
        if ($pipelineCtx.skippedSteps -and $pipelineCtx.skippedSteps.Count -gt 0) {
            $scopeLabel = if ($pipelineCtx.lang) { "$($pipelineCtx.projectType)/$($pipelineCtx.lang)" } elseif ($pipelineCtx.projectType) { [string]$pipelineCtx.projectType } else { 'Unknown' }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m80' -MessageArgs @($scopeLabel, $($pipelineCtx.skippedSteps.Count), $($pipelineCtx.skippedSteps -join ', '))) 'Debug' $State
        }
        $buildAttempted = $pipelineCtx.buildAttempted
        # Chaos drill: RollbackTrigger arms $State.ChaosRollback (Chaos.psm1).
        # One-shot synthetic failure AFTER a green pipeline so the real
        # catch -> RootCause -> Invoke-Rollback path executes end to end.
        # Opt-in only (chaos.enabled + scenario run); disarms immediately so a
        # retry is a genuine clean build, never a drill loop.
        if ($State -and ($State.PSObject.Properties.Name -contains 'ChaosRollback') -and $State.ChaosRollback) {
            $State.ChaosRollback = $false
            throw (Get-LocaleMessage -Key 'log.orch.chaosRollbackTriggered' -Fallback 'Chaos drill: RollbackTrigger forced failure (rollback validation)')
        }
    } catch {
        $buildFailed = $true
        $buildAttempted = $pipelineCtx.buildAttempted
        Write-LogSafe ("$lb$(Get-LogLocalized -Key 'log.marker.fail' -Fallback '[x]')$rb $($_.Exception.Message)") 'Err' $State
        Write-LogSafe (Get-LocaleMessage -Key 'log.system.stack' -MessageArgs @($_.ScriptStackTrace)) 'Warn' $State
        if (Get-Command New-BuildError -ErrorAction SilentlyContinue) { New-BuildError -Message "Build failed: $($_.Exception.Message)" -Category 'Permanent' -RelatedFiles @($pipelineCtx.projPath, $pipelineCtx.projectDir) -Context @{ Choice = $pipelineCtx.choice; ProjectType = $pipelineCtx.projectType } }
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) { Send-BuildEvent -EventName $EVT_BUILD_ERROR -Source $State -Data @{ Message = "Build failed: $($_.Exception.Message)"; Choice = $pipelineCtx.choice; ProjectType = $pipelineCtx.projectType } | Out-Null }
        # Level 5: Auto root-cause analysis
        Import-ModuleOnDemand -ModuleNames @('RootCause')
        if (Get-Command Get-RootCauseAnalysis -ErrorAction SilentlyContinue) {
            $rc = Get-RootCauseAnalysis -ErrorRecord $_ -State $State
            if ($rc -and $rc.Confidence -gt 0) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m81' -MessageArgs @(${lb}, ${rb}, $($rc.Category), $($rc.Confidence), $($rc.Suggestion))) 'Warn' $State
                if (Get-Command Write-RootCauseHistory -ErrorAction SilentlyContinue) { [void](Write-RootCauseHistory -Analysis @{ Category = $rc.Category; Confidence = $rc.Confidence; Suggestion = $rc.Suggestion; RelatedFiles = $rc.RelatedFiles; Tags = $rc.Tags } -State $State) }
                # CLOSE THE LOOP. The finally-block AutoTune sample recorded
                # only Success=$false here, never WHY, so the tuner/anomaly
                # layer could not learn from failures. Stamp the attribution on
                # State where the sampler reads it.
                try {
                    $State | Add-Member -MemberType NoteProperty -Name 'LastFailureCategory' -Value ([string]$rc.Category) -Force
                    $State | Add-Member -MemberType NoteProperty -Name 'LastFailureConfidence' -Value ([double]$rc.Confidence) -Force
                } catch { }
                # Level 5 wiring: aggregate history summary keeps
                # Get-RootCauseSummary wired to production failure output.
                if (Get-Command Get-RootCauseSummary -ErrorAction SilentlyContinue) {
                    try {
                        $rcSum = Get-RootCauseSummary -State $State
                        if ($rcSum -and $rcSum.Total -gt 0) {
                            $topCat = @(($rcSum.Categories.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1 | ForEach-Object { "$($_.Name) x$($_.Value)" }))
                            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m82' -MessageArgs @(${lb}, ${rb}, $($rcSum.Total), $($rcSum.AvgConfidence), $($topCat -join ', '))) 'Gray' $State
                        }
                    } catch { }
                }
            }
        }
        if (Get-Command Invoke-Rollback -ErrorAction SilentlyContinue) {
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) { Send-BuildEvent -EventName $EVT_ON_ROLLBACK -Source $State -Data @{ Message = "Rollback triggered: $($_.Exception.Message)" } | Out-Null }
            Invoke-Rollback -Reason $_.Exception.Message -State $State
        }
        # Note: publish-output cleanup is handled by the existing rollback
        # mechanism (RestoreOutputDir action restores the previous good output
        # from its backup). No extra rename is performed here to avoid
        # clobbering the restored good artifact.
        if (Test-InteractiveSession -State $State) {
            $cont = Read-Host "`nPress Enter to exit, or 'C' to continue"
            if ($cont -ne 'C' -and $cont -ne 'c') { throw }
        } else {
            throw
        }
    }

} catch {
    $buildFailed = $true
    Write-LogSafe (Get-LocaleMessage -Key 'log.system.fatal' -MessageArgs @($_)) 'Err' $State
    Write-LogSafe (Get-LocaleMessage -Key 'log.system.stack' -MessageArgs @($_.ScriptStackTrace)) 'Warn' $State
    if (Get-Command New-BuildError -ErrorAction SilentlyContinue) { New-BuildError -Message "Build failed: $($_.Exception.Message)" -Category 'Permanent' -RelatedFiles (@((Get-Variable projPath -ErrorAction SilentlyContinue -ValueOnly), (Get-Variable projectDir -ErrorAction SilentlyContinue -ValueOnly)) | Where-Object { $_ }) -Context @{ Choice = (Get-Variable choice -ErrorAction SilentlyContinue -ValueOnly); ProjectType = (Get-Variable projectType -ErrorAction SilentlyContinue -ValueOnly) } }
    if (Get-Command Invoke-Rollback -ErrorAction SilentlyContinue) { Invoke-Rollback -Reason $_.Exception.Message -State $State }
    throw
} finally {
    if ($buildAttempted -and $State) {
        Invoke-GBuildHook -HookName 'after-build' -State $State -Success:(-not $buildFailed)
        # Optional GPG signing of published artifacts after a successful build
        # (security.gpgSign). DeployTargets is imported on demand so this wiring
        # stays lazy and never breaks when the module is absent.
        if (-not $buildFailed) {
            Import-ModuleOnDemand -ModuleNames @('DeployTargets')
            if (Get-Command Invoke-GpgSign -ErrorAction SilentlyContinue) { Invoke-GpgSign -State $State | Out-Null }
        }
    }
    if (Get-Command Send-OtelMetrics -ErrorAction SilentlyContinue) {
        $telemetryCfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.telemetry) { $State.BuildConfig.telemetry } else { $null }
        # Routed through Get-BuildConstant (config-first, profile/tenant aware)
        # rather than reading the raw sub-tree, so telemetry.enabled and
        # telemetry.otel.enabled resolve through the SAME path as every other
        # setting instead of having a second, divergent reader.
        $telemetryEnabled = [bool](Get-BuildConstant -Key 'TelemetryEnabled' -State $State -Fallback $true)
        $otelEnabled = [bool](Get-BuildConstant -Key 'TelemetryOtelEnabled' -State $State -Fallback $false)
        $otelEndpointConfig = Get-SectionValue -Section (Get-SectionValue -Section $telemetryCfg -Key 'otel' -Default $null) -Key 'endpoint' -Default $null
        if ($telemetryEnabled -and $otelEnabled -and $otelEndpointConfig) {
            # Unconfigured environment: never POST to a literal '${env:...}' URL.
            $otelEndpoint = [string]$otelEndpointConfig
            if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
                $otelEndpoint = [string](Get-ConfigValue -Path 'telemetry.otel.endpoint' -State $State -Default $otelEndpoint -ResolveEnv)
            } elseif (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) {
                $otelEndpoint = Resolve-EnvPlaceholder -Text $otelEndpoint
            }
            $otelUnresolved = if (Get-Command Test-UnresolvedEnvPlaceholder -ErrorAction SilentlyContinue) {
                Test-UnresolvedEnvPlaceholder -Text $otelEndpoint
            } else { $otelEndpoint -match '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}' }
            if (-not $otelUnresolved) {
                # Both senders were piped to Out-Null, so a failed export looked
                # exactly like a successful one: telemetry silently lost every run
                # and nothing said so. Check the result and surface it.
                $otelMetricsOk = Send-OtelMetrics -State $State -OtelEndpoint $otelEndpoint
                if ($otelMetricsOk -eq $false) { Write-Log (Get-LocaleMessage -Key 'log.metrics.otlpMetricsFailed' -MessageArgs @([string]$otelEndpoint)) 'DarkYellow' $State }
                if (Get-Command Send-OtelTraces -ErrorAction SilentlyContinue) {
                    $traceData = @{ traceId = $State.CorrelationId; success = -not $buildFailed; timestamp = (Get-Date).ToString('o') }
                    $otelTraceOk = Send-OtelTraces -State $State -OtelEndpoint $otelEndpoint -TraceData $traceData
                    if ($otelTraceOk -eq $false) { Write-Log (Get-LocaleMessage -Key 'log.metrics.otlpTraceFailed' -MessageArgs @([string]$otelEndpoint)) 'DarkYellow' $State }
                }
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.system.otelSkipped') 'Gray' $State
            }
        }
    }
    if (Get-Command Stop-MetricsEndpoint -ErrorAction SilentlyContinue) {
        Stop-MetricsEndpoint | Out-Null
    }
    # FALLBACK for the paths that never reach the pipeline: -Clean, -CacheClear /
    # -CacheOptimize / -CacheStats, -VersionBump, -VerifyInfra and a bootstrap
    # failure all `return` before $buildSteps, so the SecurityScan step cannot
    # have run. Without this the gate would be skipped on exactly those runs.
    # The pipeline step stamps State.SecurityScanCompleted, so a normal build
    # does not get scanned twice.
    $scanAlreadyRan = $false
    try { if ($State.PSObject.Properties.Name -contains 'SecurityScanCompleted') { $scanAlreadyRan = [bool]$State.SecurityScanCompleted } } catch { }
    $finalScanEnabled = $Security.IsPresent
    if (-not $finalScanEnabled) {
        try {
            $secSection = Get-ConfigSection -State $State -Path 'security'
            if ($secSection -and $null -ne $secSection.scanOnBuild) { $finalScanEnabled = [bool]$secSection.scanOnBuild }
        } catch { }
    }
    if ($finalScanEnabled -and -not $scanAlreadyRan) {
        Import-ModuleOnDemand -ModuleNames @('Security')
        if (Get-Command Invoke-SecurityScan -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m83' -MessageArgs @(${lb}, ${rb})) 'Info' $State
            $secResult = Invoke-SecurityScan -State $State
            # ENFORCEMENT. This branch used to only log at 'Warn' and drop
            # $secResult.Pass on the floor, which made
            # security.blockOnCriticalVulns=true and
            # security.licenseEnforcement='block' purely decorative: a committed
            # AWS key produced a green build. A failing scan now fails the
            # process (exit 2) so CI goes red.
            if ($secResult -and -not $secResult.Pass) {
                $detail = "Critical=$($secResult.Critical), High=$($secResult.High), Medium=$($secResult.Medium), Vulnerabilities=$($secResult.Vulnerabilities), LicenseViolations=$($secResult.License)"
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m84' -MessageArgs @(${lb}, ${rb}, $detail)) 'Err' $State
                Set-GBuildExitCode -Code 2 -Reason 'security-scan'
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    # Same -Type/-Result binding fix as the SecurityScan step
                    # above: the denial entry was silently dropped.
                    try { Write-AuditLog -Action 'security:scan' -Outcome 'Denied' -Detail $detail -State $State } catch { }
                }
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m85' -MessageArgs @(${lb}, ${rb})) 'Succ' $State
            }
        } else {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m86' -MessageArgs @(${lb}, ${rb})) 'Warn' $State
        }
    }
    # Level 5: AutoTuner — record build sample for self-optimization
    Import-ModuleOnDemand -ModuleNames @('AutoTuner')
    if (Get-Command Write-AutoTuneSample -ErrorAction SilentlyContinue) {
        # Single source: AutoTuner.Get-AutoTuneHostCapacity (cross-platform).
        # Previously duplicated Windows-only Get-CimInstance here (broke on
        # Linux/macOS and drifted from the tuner's own capacity logic).
        $hostCap = @{ CpuCount = [Environment]::ProcessorCount; MemoryGB = 4.0 }
        try {
            if (Get-Command Get-AutoTuneHostCapacity -ErrorAction SilentlyContinue) { $hostCap = Get-AutoTuneHostCapacity }
        } catch { }
        $cpuCount = [int]$hostCap.CpuCount
        $memGB = [double]$hostCap.MemoryGB
        # $pipelineCtx only exists when bootstrap reached the pipeline stage;
        # a bootstrap failure (e.g. event-subscriber error) must not cause a
        # second FATAL here that masks the original error.
        $safeCtx = Get-Variable -Name pipelineCtx -ValueOnly -ErrorAction SilentlyContinue
        $pJ = if ($safeCtx -and $safeCtx.parallelProjects) { $safeCtx.parallelProjects.Count } else { 0 }
        # Flow-scoped hygiene: Write-AutoTuneSample returns bool — void it so a
        # bare True/False never leaks onto the build console.
        # FailureCategory/Confidence close the RootCause -> AutoTuner loop: the
        # catch above stamps what the failure analysis concluded, so a failed
        # sample carries its attribution instead of a bare Success=$false.
        $failCat = ''
        $failConf = 0.0
        try {
            if ($State -and ($State.PSObject.Properties.Name -contains 'LastFailureCategory') -and $State.LastFailureCategory) { $failCat = [string]$State.LastFailureCategory }
            if ($State -and ($State.PSObject.Properties.Name -contains 'LastFailureConfidence') -and $State.LastFailureConfidence) { $failConf = [double]$State.LastFailureConfidence }
        } catch { }
        [void](Write-AutoTuneSample -Sample @{
            DurationSec  = if ($safeCtx -and $safeCtx.totalSec) { [double]$safeCtx.totalSec } else { 0 }
            Success      = -not $buildFailed
            ProjectType  = if ($safeCtx -and $safeCtx.projectType) { [string]$safeCtx.projectType } else { 'unknown' }
            ParallelJobs = $pJ
            CacheHit     = $false
            Incremental  = $Incremental.IsPresent
            CpuCount     = $cpuCount
            MemoryGB     = [math]::Round($memGB, 1)
            FailureCategory  = $failCat
            FailureConfidence = $failConf
        } -State $State)
        if (Get-Command Get-AutoTuneRecommendations -ErrorAction SilentlyContinue) {
            $atRec = Get-AutoTuneRecommendations -State $State
            if ($atRec -and $atRec.Recommendations -and $atRec.Recommendations.Count -gt 0) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m87' -MessageArgs @(${lb}, ${rb}, $($atRec.SampleCount), $($atRec.Recommendations.Keys -join ', '))) 'Debug' $State
            }
        }
    }
    # Level 5: automatic anomaly detection on every build. This closes the
    # build -> detect loop (AutoTuner samples above feed Get-AnomalySamples;
    # the AutoTune pipeline step closes detect -> adjust for the NEXT build,
    # which this check then verifies — a genuine cross-build feedback loop).
    # Log-only and fully guarded: never fails a build.
    if ($State -and -not $buildFailed) {
        try {
            Import-ModuleOnDemand -ModuleNames @('AnomalyDetector')
            if (Get-Command Get-AnomalyReport -ErrorAction SilentlyContinue) {
                $autoAn = Get-AnomalyReport -State $State
                if ($autoAn -and $autoAn.Status -notin @('Disabled', 'InsufficientData')) {
                    $anIcon = if ($autoAn.MaxSeverity -in @('High', 'Critical')) { 'Err' } elseif ($autoAn.MaxSeverity -eq 'Medium') { 'Warn' } else { 'Succ' }
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m88' -MessageArgs @(${lb}, ${rb}, $($autoAn.Summary))) $anIcon $State -Level Debug
                    if (Get-Command Write-AnomalyHistory -ErrorAction SilentlyContinue) { [void](Write-AnomalyHistory -Report $autoAn -State $State) }
                    [void](Send-AnomalyAlertIfNeeded -Report $autoAn -State $State)
                }
            }
        } catch {
            # benign: detection must never break the build
        }
    }
    # Level 5: SLO compliance on every build from REAL artifact history
    # (build-reports/, distributed-report/, logs/ via Get-SloSamples).
    # Log-only and fully guarded: never fails a build.
    if ($State) {
        try {
            Import-ModuleOnDemand -ModuleNames @('Metrics')
            if (Get-Command Get-SloStatus -ErrorAction SilentlyContinue) {
                $slo = Get-SloStatus -State $State
                if ($slo -and $slo.SloEnabled -and $slo.BurnRateAdvisory -ne 'unknown') {
                    $sloIcon = if ($slo.BurnRateAdvisory -eq 'critical') { 'Err' } elseif ($slo.BurnRateAdvisory -eq 'warning') { 'Warn' } else { 'Succ' }
                    $sloMsg = "${lb}SLO${rb} burn=$($slo.BurnRateAdvisory)"
                    if ($null -ne $slo.BuildSuccessRate) { $sloMsg += " build_ok=$($slo.BuildSuccessRate) ($($slo.BuildSamples) samples)" }
                    if ($null -ne $slo.PreflightPassRate) { $sloMsg += " preflight_ok=$($slo.PreflightPassRate) ($($slo.PreflightSamples) samples)" }
                    if ($null -ne $slo.BudgetBurnRate) { $sloMsg += " budget_burn=$($slo.BudgetBurnRate)x" }
                    Write-Log $sloMsg $sloIcon $State -Level Debug
                }
            }
        } catch {
            # benign: SLO reporting must never break the build
        }
    }
    # Level 5 (the missing half): persist a metrics baseline so the NEXT run can
    # be compared against this one. Compare-MetricsBaseline (drift %, threshold
    # alerting) shipped and was fully tested, but its write side was never called
    # from production, so the trend could never actually accumulate. Persisting
    # the snapshot closes the measurement loop that makes drift detection real.
    if ($State) {
        try {
            Import-ModuleOnDemand -ModuleNames @('Metrics')
            if (Get-Command Update-MetricsBaseline -ErrorAction SilentlyContinue) {
                $baseline = Update-MetricsBaseline -State $State
                if ($baseline -and $baseline.DriftDetected) {
                    # Name the series AND its distinguishing label. The message used
                    # to print only the metric name, so a run with six drifted
                    # pipeline steps rendered as six identical
                    # "gbuild_step_duration_seconds(...)" entries with no way to
                    # tell which step regressed. Rendering is single-sourced in
                    # Metrics.Format-BaselineDriftIdentity (it knows both live
                    # Hashtable labels and rehydrated PSCustomObject labels); the
                    # inline branch is only the stale-copy fallback.
                    $hasDriftFormat = [bool](Get-Command Format-BaselineDriftIdentity -ErrorAction SilentlyContinue)
                    $exceeded = @($baseline.Comparisons | Where-Object { $_.Exceeded } | ForEach-Object {
                            if ($hasDriftFormat) {
                                $ident = Format-BaselineDriftIdentity -Name ([string]$_.Name) -Labels $_.Labels
                            } else {
                                $ident = [string]$_.Name
                                if ($_.Labels) {
                                    $pairs = @()
                                    if ($_.Labels -is [System.Collections.IDictionary]) {
                                        foreach ($key in @($_.Labels.Keys | Sort-Object)) {
                                            $value = [string]$_.Labels[$key]
                                            if ($value -and $value -ne '***REDACTED***') { $pairs += ('{0}={1}' -f [string]$key, $value) }
                                        }
                                    } else {
                                        $pairs = @($_.Labels.PSObject.Properties | Where-Object { $_.Value -and $_.Value -ne '***REDACTED***' } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
                                    }
                                    if ($pairs.Count -gt 0) { $ident += '{' + ($pairs -join ',') + '}' }
                                }
                            }
                            "{0} {1}%" -f $ident, $_.DriftPct
                        })
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m89' -MessageArgs @(${lb}, ${rb}, $($exceeded -join '; '))) 'DarkYellow' $State -Level Warn
                }
            }
        } catch {
            # benign: baseline capture must never break the build
        }
    }
    # Level 5: audit-ledger compliance (WORM + retention + verification).
    # Wires AuditLedger orphans into prod: Write/Verify-Range/Export/Enforce/
    # WormProtection/Scheduler. Fully guarded — compliance never breaks a build.
    if ($State) {
        try {
            Import-ModuleOnDemand -ModuleNames @('AuditLedger')
            if (Get-Command Write-AuditLedgerEntry -ErrorAction SilentlyContinue) {
                try {
                    $auditEnabled = $false
                    try {
                        $alCfg = Get-ConfigSection -State $State -Path 'security.auditLedger'
                        if ($alCfg -and ($alCfg.PSObject.Properties.Name -contains 'enabled')) { $auditEnabled = [bool]$alCfg.enabled }
                    } catch { $auditEnabled = $false }
                    # L5 per-environment enablement (GBUILD_AUDIT_LEDGER=1):
                    # Initialize-AuditLedger owns the effective decision
                    # (config OR env, unsigned fail-open when env-originated).
                    if (-not $auditEnabled -and (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue)) {
                        try { if ((Test-EnvToggle -Name 'GBUILD_AUDIT_LEDGER') -eq $true) { $auditEnabled = $true } } catch { }
                    }
                    if ($auditEnabled) {
                        Write-AuditLedgerEntry -State $State -Entry @{ Type = 'BUILD'; Action = 'build:complete'; Allowed = (-not $buildFailed); Detail = "success=$(-not $buildFailed)" }
                    }
                } catch { }
            }
            if (Get-Command Start-AuditLedgerVerificationScheduler -ErrorAction SilentlyContinue) {
                try { Start-AuditLedgerVerificationScheduler -State $State } catch { }
            }
            if (Get-Command Test-AuditLedger -ErrorAction SilentlyContinue) {
                # Full verification + ANCHOR comparison. This used to be a
                # range check gated on $State.AuditLedgerLastSeq, a property
                # nothing ever set, so the whole verification block was dead:
                # a tampered or truncated ledger was never detected.
                # Test-AuditLedger now also compares against the last signed
                # Merkle anchor, which is what makes tail truncation visible.
                try {
                    $verifyResult = Test-AuditLedger -State $State -FullChain
                    if ($verifyResult) {
                        $anchored = [bool]($verifyResult.ContainsKey('AnchorPresent') -and $verifyResult.AnchorPresent)
                        if (-not $verifyResult.Valid) {
                            $verdict = "audit ledger INVALID (entries=$($verifyResult.TotalEntries), verified=$($verifyResult.VerifiedEntries), anchor=$anchored)"
                            Set-GBuildExitCode -Code 3 -Reason 'audit-ledger-invalid'
                            Write-Log "[AUDIT] $verdict" 'Err' $State
                            foreach ($e in @($verifyResult.Errors)) { Write-Log "[AUDIT]   - $e" 'Err' $State }
                        } else {
                            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m90' -MessageArgs @($($verifyResult.TotalEntries), $anchored)) 'Info' $State
                        }
                        # Re-verify ONLY the entries this run appended, and
                        # report them individually. The full-chain check above
                        # answers "is the ledger intact?"; this answers "are the
                        # entries this build is accountable for intact?", which
                        # is the question a per-build audit consumer actually
                        # has. Test-AuditLedgerRange existed with no caller.
                        $lastSeq = 0
                        try { if ($State -and ($State.PSObject.Properties.Name -contains 'AuditLedgerLastSeq') -and $State.AuditLedgerLastSeq) { $lastSeq = [int]$State.AuditLedgerLastSeq } } catch { }
                        $newSeq = 0
                        try { $newSeq = [int]$State.AuditLedgerEntryCount } catch { $newSeq = 0 }
                        if ($newSeq -gt 0 -and $newSeq -ne $lastSeq) {
                            $rng = Test-AuditLedgerRange -State $State -FromSequence ($lastSeq + 1) -ToSequence $newSeq
                            if ($rng -and @($rng.Entries).Count -gt 0) {
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m91' -MessageArgs @($(@($rng.Entries).Count), $newSeq, $($rng.Valid))) $(if ($rng.Valid) { 'Info' } else { 'Err' }) $State
                            }
                            if ($State) { try { $State | Add-Member -MemberType NoteProperty -Name 'AuditLedgerLastSeq' -Value $newSeq -Force } catch { } }
                        }
                    }
                } catch { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m92' -MessageArgs @($($_.Exception.Message))) 'Warn' $State }
            }
            if (Get-Command Get-AuditLedgerWormStatus -ErrorAction SilentlyContinue) {
                # Report the WORM posture honestly. This reader existed and had
                # zero callers, so the state of the immutable-storage control was
                # never surfaced to an operator.
                try {
                    $worm = Get-AuditLedgerWormStatus -State $State
                    if ($worm) {
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m93' -MessageArgs @($($worm.Enforced), $($worm.Status), $($worm.Reason))) $(if ($worm.Enforced) { 'Succ' } else { 'Gray' }) $State
                    }
                } catch { }
            }
            if (Get-Command Update-AuditRetention -ErrorAction SilentlyContinue) {
                try { $null = Update-AuditRetention -State $State } catch { }
            }
            if (Get-Command Export-AuditLedger -ErrorAction SilentlyContinue) {
                try {
                    $exportOnBuild = $false
                    try {
                        $alCfg2 = Get-ConfigSection -State $State -Path 'security.auditLedger'
                        if ($alCfg2 -and ($alCfg2.PSObject.Properties.Name -contains 'exportOnBuild')) { $exportOnBuild = [bool]$alCfg2.exportOnBuild }
                    } catch { }
                    if ($exportOnBuild) { $null = Export-AuditLedger -State $State -Format 'jsonl' }
                } catch { }
            }
            if (Get-Command Set-WormProtection -ErrorAction SilentlyContinue) {
                try {
                    $ledgerPath = ''
                    try {
                        if (Get-Command Get-LedgerPath -ErrorAction SilentlyContinue) { $ledgerPath = Get-LedgerPath -State $State } catch { }
                    } catch { }
                    if ($ledgerPath -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
                        Set-WormProtection -Path $ledgerPath -Enable
                    }
                } catch { }
            }
        } catch {
            # benign: compliance must never break the build
        }
    }
    # Seal the resume record. The checkpoint written during Resolve-BuildSdk was
    # stamped -Completed:$false; recording completion here is what lets the NEXT
    # run tell a finished build from an interrupted one. Guarded and best-effort
    # because it runs in the finally block, where a throw would mask the real
    # build outcome.
    if (Get-Command Save-BuildState -ErrorAction SilentlyContinue) {
        try {
            $sealed = $true
            try { if ($State.PSObject.Properties.Name -contains 'BuildGateFailed' -and $State.BuildGateFailed) { $sealed = $false } } catch { }
            Save-BuildState -State $State -Completed:$sealed | Out-Null
        } catch { }
    }
    if ($State -and $State.TempFiles -and $State.TempFiles.Count -gt 0) {
        # CORRECTED. This ran a bare `Remove-Item -Recurse -Force` over
        # $State.TempFiles with no containment check - exactly the bug that
        # Environment.psm1's PowerShell.Exiting handler documents as fixed.
        # Register-TempFile now refuses out-of-scope paths at registration
        # time, and this consumer applies the same allow-list defensively so a
        # hand-populated TempFiles list cannot become a recursive-delete
        # primitive.
        $tempAllowedRoots = @()
        try { if ($State.ScriptRoot) { $tempAllowedRoots += [System.IO.Path]::GetFullPath([string]$State.ScriptRoot) } } catch { }
        try { if ($State.ProjectRoot) { $tempAllowedRoots += [System.IO.Path]::GetFullPath([string]$State.ProjectRoot) } } catch { }
        try { $tempAllowedRoots += [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()) } catch { }
        $State.TempFiles | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | ForEach-Object {
            $candidate = ''
            try { $candidate = [System.IO.Path]::GetFullPath([string]$_) } catch { return }
            $ok = $false
            # Pre-filter before the recursive delete. Follows the host
            # filesystem's case sensitivity; Invoke-SafeRemove re-checks with
            # the canonical comparison, so this is defence in depth, but a
            # case-insensitive pre-filter on a case-sensitive volume silently
            # skipped legitimate temp files and left the tree littered.
            $tmpCmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
                      else { if ((Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost)) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
            foreach ($root in $tempAllowedRoots) {
                $prefix = $root.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
                if ($candidate.StartsWith($prefix, $tmpCmp)) { $ok = $true; break }
            }
            if (-not $ok) { return }
            if (Get-Command Invoke-SafeRemove -ErrorAction SilentlyContinue) {
                try { Invoke-SafeRemove -Path $candidate -AllowedRoots $tempAllowedRoots -Recurse -Force -ErrorAction Stop } catch { }
            } else {
                try { Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
    # L5 session hygiene: detach event subscribers (wires Remove-BuildEvent into
    # prod). Next Start-GBuild re-registers them; same-session repeats stay clean.
    if (Get-Command Unregister-BuildEventSubscribers -ErrorAction SilentlyContinue) {
        try { Unregister-BuildEventSubscribers } catch { }
    }
    if (Get-Command Stop-Log -ErrorAction SilentlyContinue) { try { Stop-Log } catch {
            # benign - logging already stopped or unavailable
            } }
    # Shutdown the DI container: release all registered singletons so a
    # long-lived host (REPL / repeated gbuild calls in one session) never
    # carries stale service instances across runs. Same call is used by tests.
    if (Get-Command Clear-Services -ErrorAction SilentlyContinue) { try { Clear-Services } catch {
            # benign — container not imported or already cleared
            } }
    if ($configEnvironmentScope -and (Get-Command Exit-BuildConfigEnvironment -ErrorAction SilentlyContinue)) {
        try { Exit-BuildConfigEnvironment -Scope $configEnvironmentScope } catch { }
    }
}
}

<#
.SYNOPSIS
        Displays the gbuild system banner/logo to console.
    #>

Export-ModuleMember -Function @("Test-BuildConfig","Test-BuildMenuModuleMap","Test-PreFlight","Get-ActiveProfile","Get-BuildTestConfig","Resolve-TargetFrameworks","Invoke-GuildChoice","Start-GBuild","Get-BuiltInPipelineSteps","Write-SkippedStep","Test-StepEnabled","Update-BuildPublishOutput","Invoke-GBuildPipeline","Invoke-PipelineStepJobAttempt","Resolve-PipelineSteps","Resolve-PipelineYamlSteps","Invoke-PipelineStep","Show-GBuildBanner","Invoke-GBuildHook","Register-BuildEventSubscribers","Unregister-BuildEventSubscribers","Import-ModuleOnDemand","Get-ModuleMapFromConfig","Get-DefaultActionsFromConfig","Get-DeployChoiceArgs","Get-DeployDefaultRid","Assert-CoreCommands","Get-FlowLogLevel","Get-TargetCatalog","Show-TargetList","Resolve-AutoBuildChoice","Set-GBuildExitCode","Get-GBuildExitCode","Get-GBuildExitReason","Reset-GBuildExitCode","Get-BuildTargetChoices","Get-FatalActionChoices","Invoke-SdkDetection","Invoke-PluginTestAndLintGate","Show-TargetUsageTip","Assert-BuildCommandAvailable")




