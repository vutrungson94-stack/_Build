# ============================================================================ #
# OrchestratorLifecycle.ps1 - extracted lifecycle helpers from Orchestrator.psm1 #
# Dot-sourced by Orchestrator.psm1; runs in the module scope.                    #
# ============================================================================ #

function Show-TargetUsageTip {
    [CmdletBinding()]
    param(
        # Kept for backward compat (callers pass the active menu config).
        # The tip no longer enumerates targets — -Help owns the full catalog.
        [Parameter(Mandatory)][hashtable]$MenuConfig,
        [PSCustomObject]$State
    )
    try {
        Write-Sep
        $helpCmd = 'gbuild -Help'
        if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
            try {
                $tipCwd = try { ((Get-Location).ProviderPath) } catch { '' }
                $tipRoot = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { '' }
                $helpCmd = Get-InvokeCommandHint -Arguments '-Help' -ScriptRoot $tipRoot -FromDirectory $tipCwd
            } catch { }
        }
        Write-Log (Get-LocaleMessage -Key 'log.system.tipHelp' -MessageArgs @($helpCmd)) 'Info' $State
        Write-Sep
    } catch {
        # benign - tip is cosmetic only
    }
}

# Pure frame computation for the startup banner (unit-testable). The old banner
# hardcoded a 62-wide border around a fixed 4-space pad, so every locale text
# either rattled inside an oversized frame or overflowed a too-narrow middle
# line. Width now derives from the actual text, with a floor so short strings
# still render a stable frame.
function Format-GBuildBannerLines {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = 'gbuild - PowerShell Build System' }
    $textArea = [Math]::Max($Text.Length + 8, 40)
    $border = '+' + ('=' * ($textArea + 2)) + '+'
    $pad = $textArea - $Text.Length
    if ($pad -lt 0) { $pad = 0 }
    $left = [int][Math]::Floor($pad / 2)
    $right = $pad - $left
    $middle = '| ' + (' ' * $left) + $Text + (' ' * $right) + ' |'
    return @($border, $middle, $border)
}

function Show-GBuildBanner {
    param([PSCustomObject]$State = $null)
    $fg = if ($State -and (Get-Command Resolve-SafeColor -ErrorAction SilentlyContinue)) { Resolve-SafeColor -ColorName 'Header' -State $State -Fallback 'Magenta' } else { 'Magenta' }
    $bannerText = ''
    try { $bannerText = [string](Get-LocaleMessage -Key 'log.system.banner' -Fallback 'gbuild - PowerShell Build System') } catch { $bannerText = '' }
    $lines = @(Format-GBuildBannerLines -Text $bannerText)
    Write-Log ("`n" + $lines[0]) $fg $State
    Write-Log $lines[1] $fg $State
    Write-Log ($lines[2] + "`n") $fg $State
}

function Invoke-GBuildHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$HookName,
        [PSCustomObject]$State,
        [bool]$Success = $true
    )
    # Legacy file-based hook (portable: nested Join-Path, no backslash literal).
    # Compatibility shim for pre-folder layouts: emits a deprecation notice when
    # triggered so old checkouts keep working while users migrate to
    # Hooks/{HookName}/*.ps1 or build.hooks.<name>.
    $hookPath = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'Hooks' "${HookName}.ps1")
    if (Test-Path $hookPath) {
        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m94' -MessageArgs @($HookName, $HookName, $HookName)) 'Warn' $State
        & $hookPath -State $State -Success:$Success
    }

    # Auto-load all scripts in Hooks/{HookName}/ directory (Level 5: folder-based hooks)
    $hookDir = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'Hooks' $HookName)
    if (Test-Path $hookDir -PathType Container) {
        $hookScripts = Get-ChildItem -Path $hookDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($script in $hookScripts) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m95' -MessageArgs @($HookName, $($script.Name))) 'Debug' $State
            & $script.FullName -State $State -Success:$Success
        }
    }

    # Config-driven hook registry: build.hooks.<HookName> = [ scriptPath | commandName, ... ]
    # L5: relative paths resolve against the _Build root (not cwd) so portable
    # mode and CI (cwd = project) still find Steps/*.ps1. Hook-contract first
    # (-State -Success), step-contract fallback (-State only) for Steps/*.
    if ($State -and $State.BuildConfig -and $State.BuildConfig.hooks -and $State.BuildConfig.hooks.PSObject.Properties.Name -contains $HookName) {
        $cfgHooks = $State.BuildConfig.hooks.$HookName
        if ($cfgHooks -is [System.Collections.ICollection] -and $cfgHooks.Count -gt 0) {
            $buildRoot = if ($State -and $State.ScriptRoot) { $State.ScriptRoot } else { $PSScriptRoot }
            if ($buildRoot -and $buildRoot -like '*Modules') { $buildRoot = Split-Path $buildRoot -Parent }
            foreach ($h in $cfgHooks) {
                if ([string]::IsNullOrWhiteSpace($h)) { continue }
                $resolved = $h
                if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                    $candidate = Join-Path $buildRoot ($resolved -replace '^\./', '' -replace '^/', '')
                    if (Test-Path -LiteralPath $candidate) { $resolved = $candidate }
                }
                if (Test-Path -LiteralPath $resolved) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m96' -MessageArgs @($HookName, $resolved)) 'Debug' $State
                    try { & $resolved -State $State -Success:$Success }
                    catch {
                        # Step-contract fallback (Steps/*.ps1 without -Success).
                        try { & $resolved -State $State }
                        catch { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m97' -MessageArgs @($HookName, $resolved, $_)) 'Warn' $State }
                    }
                } elseif (Get-Command $h -ErrorAction SilentlyContinue) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m98' -MessageArgs @($HookName, $h)) 'Debug' $State
                    & (Get-Command $h) -State $State -Success:$Success
                } else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m99' -MessageArgs @($HookName, $h, $buildRoot)) 'Warn' $State
                }
            }
        }
    }
}

# ============================================================================
# L4: Process exit-code channel.
# Start-GBuild is a library function - it must not call `exit`. But every
# enforcement gate (security, policy, supply-chain, SAST) has to be able to
# tell the LAUNCHER that the build must fail the CI job. Previously the rich
# ExitCode carried by New-OperationResult / New-BuildResult was computed and
# then thrown away: gbuild.ps1 mapped every throw to `exit 1`, so a missing
# dotnet SDK (127) was indistinguishable from a failed test (1).
# Single source: this channel. The launcher reads it via Get-GBuildExitCode.
# ============================================================================
$script:BuildExitCode = 0
$script:BuildExitReasons = [System.Collections.Generic.List[string]]::new()

<#
.SYNOPSIS
    Records a non-zero process exit code and the reason that produced it.
.DESCRIPTION
    First-writer-wins on severity: a later code never downgrades an earlier,
    more specific one. Reasons accumulate so the summary can print every gate
    that failed rather than only the first.
#>
function Set-GBuildExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Code,
        [string]$Reason = ''
    )
    if ($Code -le 0) { return }
    if ($Code -gt $script:BuildExitCode) { $script:BuildExitCode = $Code }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        if ($script:BuildExitReasons -notcontains $Reason) { $script:BuildExitReasons.Add([string]$Reason) }
    }
}

<#
.SYNOPSIS
    Returns the process exit code accumulated during the current run (0 = ok).
#>
function Get-GBuildExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:BuildExitCode
}

<#
.SYNOPSIS
    Returns the list of reasons that forced a non-zero exit code.
#>
function Get-GBuildExitReason {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @($script:BuildExitReasons.ToArray())
}

<#
.SYNOPSIS
    Clears the exit-code channel. Called by the launcher before Start-GBuild so
    a second run in the same session never inherits the first run's verdict.
#>
function Reset-GBuildExitCode {
    [CmdletBinding()]
    param()
    $script:BuildExitCode = 0
    $script:BuildExitReasons.Clear()
}
