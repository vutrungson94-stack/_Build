Set-StrictMode -Version 1.0
# ============================================================================
# Orchestrator.Environment.ps1 - environment helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

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

