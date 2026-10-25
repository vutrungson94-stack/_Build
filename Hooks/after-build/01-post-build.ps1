param(
    [Parameter(Mandatory)][PSCustomObject]$State,
    [bool]$Success = $true,
    [switch]$Apply
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
    . $__gbuildStepBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildModulesDir, __gbuildStepBootstrap -ErrorAction SilentlyContinue
if (-not $Success) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Get-LocaleMessage -Key 'log.hook.afterFailed') 'Err' $State }; return }
$configuredApply = $false
if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $configuredApply = [bool](Get-ConfigValue -Path 'hooks.afterBuild.apply' -State $State -Default $false) } catch { $configuredApply = $false } }
if (-not ($Apply -or $configuredApply)) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.afterBuildComplete' -Fallback '[HOOK] after-build: verification complete; remediation not requested') 'Debug' $State }; return }
if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.afterBuildApplying' -Fallback '[HOOK] after-build: applying requested post-build action') 'Info' $State }
$root = if (($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) { [string]$State.ProjectRoot } elseif (($State.PSObject.Properties.Name -contains 'WorkingDir') -and $State.WorkingDir -and [System.IO.Path]::IsPathRooted([string]$State.WorkingDir)) { [string]$State.WorkingDir } elseif (($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) { [string]$State.ScriptRoot } else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.01-post-build.line23' -Fallback 'after-build root is undetermined: State carries no rooted ProjectRoot/WorkingDir/ScriptRoot. Refusing to write CHANGELOG.md into the current directory.')) }
# Tool root derived from this hook's own location (Hooks/after-build/ -> tool root
# is exactly two levels up), not from a second directory walk and not from a
# Windows-only backslash literal. Deterministic on every OS.
$__toolRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$versioningPath = Join-Path (Join-Path $__toolRoot 'Modules') 'Versioning.psm1'
if (-not (Test-Path -LiteralPath $versioningPath -PathType Leaf)) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.versioningUnavailable' -Fallback '[HOOK] after-build: versioning module unavailable') 'Warn' $State }; return }
Import-Module $versioningPath -Force -DisableNameChecking -ErrorAction Stop
$outputPath = Join-Path $root 'CHANGELOG.md'
try { [void](New-Changelog -State $State -OutputPath $outputPath -ErrorAction Stop); if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.postBuildApplied' -Fallback '[HOOK] post-build action applied') 'Info' $State } } catch { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.hook.postBuildFailed' -Fallback '[HOOK] post-build action failed') 'Warn' $State } }
