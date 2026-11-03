# pre-commit / pre-push / post-commit git hook template (managed by gbuild).
#
# Installed by:  Steps/manage-githooks.ps1 -Install
# Removed by:    Steps/manage-githooks.ps1 -Remove
#
# The installer (New-HookContent) writes a POSIX shim into .git/hooks that sets
# $GbuildManagedHook, resolves the template path relative to the installed hook,
# and invokes this file with the git-supplied @args. Editing the installed copy is
# therefore pointless - change THIS file, or pass -Force to reinstall.
#
# What this hook enforces, in order:
#   1. gbuild -SyntaxCheck (seconds) - parse every shipped file.
#   2. -Scope Standalone + -Scope Orchestrator (minutes; GBUILD_HOOK_SCOPES,
#      GBUILD_HOOK_SKIP=1 to skip) - the two gates whose absence let both
#      2026-11-03 escaped defects through. A failure blocks the commit.
# Design rules this template obeys, and why:
#  * It NEVER blocks a commit for an unrelated reason. A hook that can wedge a
#    developer's workflow gets uninstalled within a day, which is worse than not
#    having had it. The test gates ARE the related reason - they are the checks
#    that actually execute the artifact.
#  * It degrades to a no-op when the toolchain is absent (no pwsh, no gbuild.ps1,
#    no repository layout it recognises). Absence is not a failure.
#  * It never leaves a non-zero exit unless a check it actually ran failed.
#  * It prints WHY it skipped, so a silent no-op is distinguishable from a pass.

[CmdletBinding()]
param(
    # NOT named $args: that would shadow the automatic variable the installer
    # splats when it invokes this template.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitHookArgs
)

Set-StrictMode -Version 1.0

# Self-healing bootstrap (standalone-safe). Single owner: Modules/StepBootstrap.ps1.
# The shipped templates resolve it the same way, and
# 'Hygiene: Steps and Hooks share one bootstrap' FAILS a Hooks\ file that does
# not - correctly, since a copy of the block per file is what made the original
# six diverge.
$__gbuildHookBootstrap = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildHookBootstrap -PathType Leaf) {
    . $__gbuildHookBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildHookBootstrap -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- discovery --
# Walk up from the installed hook (.git/hooks/<name>) to the worktree root.
# PROBED 2026-10: `git -C <hook-dir> rev-parse --show-toplevel` was tried as a
# replacement and REVERTED - from inside .git/hooks/.gbuild git reports "this
# operation must be run in a work tree" (exit 128), so the hook went silent
# exactly in its real staged location. The hand walk is location-anchored and
# works from inside .git, so it stays. This stays an inline fragment - not a
# shared function - because the installer stages each template into
# .git/hooks/.gbuild where Modules/StepBootstrap.ps1 is out of reach, so the
# template must stay dependency-free. The same walk ships in pre-commit.ps1,
# pre-push.ps1 and post-commit.ps1: keep the three byte-identical
# (Tests/Steps.Tests.ps1 asserts it).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = ''
$probe = $here
for ($i = 0; $i -lt 6; $i++) {
    $candidate = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -eq $probe) { break }
    if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { $repoRoot = $candidate; break }
    $probe = $candidate
}
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Verbose '[gbuild hook] no repository root found above the hooks directory; nothing to do'
    exit 0
}

$launcher = Join-Path $repoRoot 'gbuild.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    # A consumer project does not necessarily vend gbuild. Never block them.
    Write-Verbose "[gbuild hook] no gbuild.ps1 in $repoRoot; hook is a no-op for this repository"
    exit 0
}

# ------------------------------------------------------------------- policy --
# Everything here is a fast, local, side-effect-free check. Anything that needs a
# network, a container runtime or minutes of wall clock belongs in CI, not in a
# developer's commit path.
$check = 'gbuild'
# Named splat, not an array splat. `& $launcher @('a','b','-SyntaxCheck')` passes
# each element POSITIONALLY, so -SyntaxCheck arrives as the value of $Project
# instead of as a switch, and the launcher dies with "a positional parameter
# cannot be found". Passing the switches by name is the only correct form.
$invoke = @{ Project = $repoRoot; SyntaxCheck = $true; NonInteractive = $true }

Write-Host (Resolve-LogMessage -Key 'log.hook.preCommitRunning' -MessageArgs @([string]$check) -Fallback '[gbuild hook] pre-commit: running {0} -SyntaxCheck')
try {
    & $launcher @invoke
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
} catch {
    Write-Host (Resolve-LogMessage -Key 'log.hook.preCommitCheckFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[gbuild hook] pre-commit: could not run the check ({0}); allowing the commit')
    exit 0
}

# Modules loaded from this tree are purged by gbuild.ps1 at startup (anti-shadow
# purge), so Locale - and Resolve-LogMessage with it - is gone from the session by
# now. Re-import it for the remaining messages (same pattern gbuild.ps1's entry
# points use). No-op when the import is already available.
$__localePath = Join-Path $repoRoot 'Modules/Locale.psm1'
if (-not (Get-Command Resolve-LogMessage -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $__localePath -PathType Leaf)) {
    Import-Module $__localePath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}
Remove-Variable -Name __localePath -ErrorAction SilentlyContinue

if ($code -ne 0) {
    # SyntaxCheck failed: blocked path. Post-conditions of the tool, when it
    # writes them, are far more actionable than a bare exit code.
    $reasonFile = Join-Path $repoRoot 'build-reports/gate-result.json'
    if (Test-Path -LiteralPath $reasonFile -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $reasonFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($j.PSObject.Properties.Name -contains 'reason') { Write-Host (Resolve-LogMessage -Key 'log.hook.reason' -MessageArgs @([string]$j.reason) -Fallback '[gbuild hook] reason: {0}') }
        } catch { }
    }
    Write-Host (Resolve-LogMessage -Key 'log.hook.preCommitBlocked' -MessageArgs @([string]$code) -Fallback '[gbuild hook] pre-commit: BLOCKED (exit {0}). Fix, or bypass once with: git commit --no-verify')
    exit $code
}

# ------------------------------------------------------- test gates (L5) --
# -Scope Standalone and -Scope Orchestrator are the MINIMUM gate. They exist
# because both escaped defects found on 2026-11-03 passed every green signal
# that did not (a) execute a freshly emitted standalone bundle and (b) run the
# entrypoint guides from a tool-folder CWD. The gates run after the fast
# SyntaxCheck and honour two env knobs:
#   GBUILD_HOOK_SKIP=1     - skip the test scopes (SyntaxCheck still ran); loud
#   GBUILD_HOOK_SCOPES     - comma-separated scopes (default Standalone,Orchestrator)
$runner = Join-Path $repoRoot 'Tests/Run-CoreTests.ps1'
$runGates = $true
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    Write-Host (Resolve-LogMessage -Key 'log.hook.testRunnerMissing' -Fallback '[gbuild hook] Tests/Run-CoreTests.ps1 not found; skipping test gates (never block for absence)')
    $runGates = $false
} elseif ($env:GBUILD_HOOK_SKIP -eq '1') {
    Write-Host (Resolve-LogMessage -Key 'log.hook.testGatesSkipped' -Fallback '[gbuild hook] GBUILD_HOOK_SKIP=1 - test gates skipped (SyntaxCheck still ran)')
    $runGates = $false
}
if ($runGates) {
    $scopes = @()
    if ($env:GBUILD_HOOK_SCOPES) { $scopes = @($env:GBUILD_HOOK_SCOPES -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    else { $scopes = @('Standalone', 'Orchestrator') }
    foreach ($scope in $scopes) {
        Write-Host ("[gbuild hook] running -Scope {0} (minimum gate)" -f $scope)
        try {
            & $runner -Scope $scope -StrictSkips
            $scopeCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        } catch {
            Write-Host ("[gbuild hook] -Scope {0} could not run ({1}); skipping, never block for absence" -f $scope, $_.Exception.Message)
            continue
        }
        if ($scopeCode -ne 0) {
            Write-Host ("[gbuild hook] -Scope {0} FAILED (exit {1}). Fix, or bypass once with: git commit --no-verify" -f $scope, $scopeCode)
            exit $scopeCode
        }
    }
}

Write-Host (Resolve-LogMessage -Key 'log.hook.preCommitOk' -Fallback '[gbuild hook] pre-commit: OK')
exit 0
