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
if (Test-Path -LiteralPath $lifecyclePath) { . $lifecyclePath }
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

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Deploy.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Deploy.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Standalone.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Standalone.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Sdk.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Sdk.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Environment.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Environment.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Config.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Config.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Targets.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Targets.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Modules.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Modules.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.Pipeline.ps1')) { . (Join-Path $PSScriptRoot 'Orchestrator.Pipeline.ps1') }
Set-StrictMode -Version 1.0
# Lazy module loader - imports a module only if not already loaded (idempotent).
# Used to defer loading of non-core modules until a menu choice actually needs them.

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




