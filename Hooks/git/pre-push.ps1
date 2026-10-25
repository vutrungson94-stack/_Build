# pre-push git hook template (managed by gbuild).
#
# Installed by:  Steps/manage-githooks.ps1 -Install
# Removed by:    Steps/manage-githooks.ps1 -Remove
#
# Kept deliberately cheap. A pre-push hook is on the developer's critical path and
# runs AFTER they have already written the code, so anything slow here reads as
# "the build system is in the way". This runs the same fast local parse/analyze
# pass as pre-commit and nothing more: full builds, container builds and anything
# networked belong in CI.

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
# byte-identical with pre-commit.ps1 and post-commit.ps1 (asserted by test).
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

$launcher = Join-Path $repoRoot 'gbuild.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    Write-Verbose "[gbuild hook] no gbuild.ps1 in $repoRoot; hook is a no-op for this repository"
    exit 0
}

Write-Host (Resolve-LogMessage -Key 'log.hook.prePushRunning' -Fallback '[gbuild hook] pre-push: running gbuild -SyntaxCheck')
try {
    # Named splat: an array splat would pass -SyntaxCheck POSITIONALLY, making it
    # the value of $Project rather than a switch.
    & $launcher @{ Project = $repoRoot; SyntaxCheck = $true; NonInteractive = $true }
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
} catch {
    Write-Host (Resolve-LogMessage -Key 'log.hook.prePushCheckFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[gbuild hook] pre-push: could not run the check ({0}); allowing the push')
    exit 0
}

if ($code -eq 0) { Write-Host (Resolve-LogMessage -Key 'log.hook.prePushOk' -Fallback '[gbuild hook] pre-push: OK'); exit 0 }
Write-Host (Resolve-LogMessage -Key 'log.hook.prePushBlocked' -MessageArgs @([string]$code) -Fallback '[gbuild hook] pre-push: BLOCKED (exit {0}). Bypass once with: git push --no-verify')
exit $code
