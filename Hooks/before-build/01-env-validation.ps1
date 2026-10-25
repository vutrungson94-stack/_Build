param(
    [Parameter(Mandatory)][PSCustomObject]$State,
    [bool]$Success = $true
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
# Self-healing bootstrap (standalone-safe). Single owner:
# Modules/StepBootstrap.ps1. When this script runs outside an Orchestrator
# session the shared libs are absent; that file walks up to the _Build root and
# imports them. No-op inside a normal gbuild run.
$__gbuildModulesDir = Split-Path -Parent $PSScriptRoot
$__gbuildStepBootstrap = Join-Path $__gbuildModulesDir 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildStepBootstrap -PathType Leaf) {
    . $__gbuildStepBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @('Environment','Project','HealthCheck')
}
Remove-Variable -Name __gbuildModulesDir, __gbuildStepBootstrap -ErrorAction SilentlyContinue
if (-not $Success) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.beforeBuildSkipped' -Fallback '[HOOK] before-build: skipped after prior failure') 'Warn' $State }; return }
if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.beforeBuildValidating' -Fallback '[HOOK] before-build: environment validation') 'Debug' $State }
$checkDisk = $true
$checkNetwork = $true
if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $checkDisk = [bool](Get-ConfigValue -Path 'health.checkDiskSpace' -State $State -Default $true); $checkNetwork = [bool](Get-ConfigValue -Path 'health.checkNetwork' -State $State -Default $true) } catch { } }
$disk = if ($checkDisk -and (Get-Command Test-DiskSpace -ErrorAction SilentlyContinue)) { Test-DiskSpace -State $State } else { $null }
# These three keys shipped translated in all 7 locales and were never emitted:
# the hook printed hardcoded "[HOOK] <check>: <Status>", so a disk / toolchain /
# network problem reported in English regardless of -Locale.
if ($disk -and $disk.Status -ne 'Pass') { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Get-LocaleMessage -Key 'log.hook.lowDisk' -MessageArgs @([string]$disk.Message)) 'Warn' $State } }
$tools = if (Get-Command Test-RequiredTools -ErrorAction SilentlyContinue) { Test-RequiredTools -State $State } else { $null }
if ($tools -and $tools.Status -ne 'Pass') { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Get-LocaleMessage -Key 'log.hook.missingTools' -MessageArgs @([string]$tools.Message)) 'Warn' $State } }
$network = if ($checkNetwork -and (Get-Command Test-NetworkConnectivity -ErrorAction SilentlyContinue)) { Test-NetworkConnectivity -State $State } else { $null }
if ($network -and $network.Status -ne 'Pass') { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Get-LocaleMessage -Key 'log.hook.networkUnreachable' -MessageArgs @("$($network.Status) - $($network.Message)")) 'Warn' $State } }
if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.beforeBuildComplete' -Fallback '[HOOK] before-build: validation complete') 'Debug' $State }
