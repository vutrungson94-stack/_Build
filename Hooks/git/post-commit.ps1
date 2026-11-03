# post-commit git hook template (managed by gbuild).
#
# Installed by:  Steps/manage-githooks.ps1 -Install
# Removed by:    Steps/manage-githooks.ps1 -Remove
#
# Advisory ONLY. This hook can never fail the commit - it runs after the commit
# exists, so a non-zero exit here would be reported by git as a hook problem while
# changing nothing. It emits one line so the developer knows local verification is
# available, then exits 0 unconditionally.

[CmdletBinding()]
param(
    # NOT named $args: that would shadow the automatic variable the installer
    # splats when it invokes this template.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitHookArgs
)

Set-StrictMode -Version 1.0

# Self-healing bootstrap (standalone-safe). Single owner: Modules/StepBootstrap.ps1.
# Required by 'Hygiene: Steps and Hooks share one bootstrap', which fails a
# Hooks\ file that carries its own copy of this block instead.
$__gbuildHookBootstrap = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildHookBootstrap -PathType Leaf) {
    . $__gbuildHookBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildHookBootstrap -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Continue'

# Worktree-root walk. Same constraints as pre-commit.ps1 (staged standalone:
# no shared function reachable; git rev-parse fails from inside .git) - keep
# byte-identical with pre-commit.ps1 and pre-push.ps1 (asserted by test).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = ''
$probe = $here
for ($i = 0; $i -lt 6; $i++) {
    $candidate = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -eq $probe) { break }
    if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { $repoRoot = $candidate; break }
    $probe = $candidate
}
if ([string]::IsNullOrWhiteSpace($repoRoot)) { exit 0 }

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'gbuild.ps1') -PathType Leaf)) { exit 0 }

# Locale is needed by Resolve-LogMessage below. gbuild purges modules in child
# processes it spawns, but this hook's own session may not have loaded Locale
# yet (the bootstrap above only imports it when StepBootstrap is reachable from
# the staged hook, which it is not). Import it now; no-op if already present.
$__localePath = Join-Path $repoRoot 'Modules/Locale.psm1'
if (Test-Path -LiteralPath $__localePath -PathType Leaf) {
    Import-Module $__localePath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}
Remove-Variable -Name __localePath -ErrorAction SilentlyContinue

Write-Host (Resolve-LogMessage -Key 'log.hook.committed' -Fallback '[gbuild hook] committed. Verify locally with: gbuild . -SyntaxCheck   (full run: gbuild .)')
exit 0
