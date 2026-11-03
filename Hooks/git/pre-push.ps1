# pre-push git hook template (managed by gbuild).
#
# Installed by:  Steps/manage-githooks.ps1 -Install
# Removed by:    Steps/manage-githooks.ps1 -Remove
#
# What this hook enforces, in order:
#   1. gbuild -SyntaxCheck (seconds) - parse every shipped file.
#   2. -Scope Standalone + -Scope Orchestrator - the minimum test gate
#      (GBUILD_HOOK_SCOPES, GBUILD_HOOK_SKIP=1 to skip).
#   3. Independent review attestation when the push touches Modules/
#      (see the gate block below for the exact contract).
# Everything heavier (full builds, containers, network) belongs in CI.

[CmdletBinding()]
param(
    # NOT named $args: that would shadow the automatic variable the installer
    # splats when it invokes this template.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitHookArgs,
    # Git passes the ref list on stdin. Declaring a pipeline-enabled parameter
    # makes PowerShell's startup pipeline binding succeed quietly; without it
    # pwsh prints a non-terminating "input object cannot be bound" error on
    # every push. The ref text itself is read via [Console]::In below, never
    # from this parameter.
    [Parameter(ValueFromPipeline = $true)][AllowNull()][object[]]$GitHookStdin
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

# Locale is needed by Resolve-LogMessage below; import it before the first use.
$__localePath = Join-Path $repoRoot 'Modules/Locale.psm1'
if (Test-Path -LiteralPath $__localePath -PathType Leaf) {
    Import-Module $__localePath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}
Remove-Variable -Name __localePath -ErrorAction SilentlyContinue

Write-Host (Resolve-LogMessage -Key 'log.hook.prePushRunning' -Fallback '[gbuild hook] pre-push: running gbuild -SyntaxCheck')
try {
    # Named splat via a VARIABLE. `& $launcher @{...}` does NOT splat - a literal
    # hashtable is an ordinary argument and binds positionally to [string]$Project
    # (as "System.Collections.Hashtable"), silently discarding -SyntaxCheck and
    # NonInteractive; the hook then launched a FULL BUILD and reported its exit
    # code. Only @$variable splats. Keep the variable form (pre-commit.ps1 uses
    # the same pattern).
    # Exit-code contract (verified on pwsh 7.6): a child script calling
    # `exit N` sets the parent's $LASTEXITCODE = N and the parent keeps running,
    # so $LASTEXITCODE below is authoritative for pass/fail.
    $invoke = @{ Project = $repoRoot; SyntaxCheck = $true; NonInteractive = $true }
    & $launcher @invoke
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
} catch {
    Write-Host (Resolve-LogMessage -Key 'log.hook.prePushCheckFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[gbuild hook] pre-push: could not run the check ({0}); allowing the push')
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
    Write-Host (Resolve-LogMessage -Key 'log.hook.prePushBlocked' -MessageArgs @([string]$code) -Fallback '[gbuild hook] pre-push: BLOCKED (exit {0}). Bypass once with: git push --no-verify')
    exit $code
}

# ------------------------------------------------------- test gates (L5) --
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
            Write-Host ("[gbuild hook] -Scope {0} FAILED (exit {1}). Fix, or bypass once with: git push --no-verify" -f $scope, $scopeCode)
            exit $scopeCode
        }
    }
}

# --------------------------------------- independent review gate (Modules/) --
# Changes under Modules/ are the build engine itself; a defect there is a
# fleet-wide defect (QPM-2026-001: every emitted standalone bundle died;
# QPM-2026-002: entry guides blocked behind the workspace-root guard). An
# independent review attestation is REQUIRED. Local attestation cannot prove
# the review happened - it exists to force the review to be a conscious,
# recorded act. Attestation paths (first match wins):
#   1. env GBUILD_REVIEW_APPROVED=<name>   - recorded and printed
#   2. EVERY commit in the pushed range carries a 'Reviewed-by: <name>' trailer
#   3. env GBUILD_REVIEW_OVERRIDE=<reason> - recorded WAIVER (never an approval)
# Otherwise the push is blocked with instructions. CI runs regardless.
$ranges = New-Object System.Collections.Generic.List[string]
# Git passes the ref list on stdin ("<local ref> SP <local sha> SP <remote ref> SP <remote sha>" per line;
# deletes carry the zero sha). Read the raw stream - PowerShell's pipeline binder
# does not deliver stdin to $input, and git hook stdin is never a TTY here.
$stdinLines = @()
try {
    if ([Console]::IsInputRedirected) {
        $stdinLines = @([Console]::In.ReadToEnd() -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    }
} catch { }
foreach ($line in $stdinLines) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 4) { continue }
    $localSha = [string]$parts[1]; $remoteSha = [string]$parts[3]
    $zero = '0000000000000000000000000000000000000000'
    if ($localSha -eq $zero) { continue } # branch deletion: nothing to review
    if ($remoteSha -eq $zero) {
        $base = (git -C $repoRoot merge-base HEAD origin/main 2>$null)
        if (-not $base) { $base = (git -C $repoRoot rev-parse HEAD~20 2>$null) }
        if ($base) { $ranges.Add("$base..$localSha") } else { $ranges.Add($localSha) }
    } else {
        $ranges.Add("$remoteSha..$localSha")
    }
}
if ($ranges.Count -eq 0) {
    $base = (git -C $repoRoot merge-base HEAD origin/main 2>$null)
    if (-not $base) { $base = (git -C $repoRoot rev-parse HEAD~20 2>$null) }
    if ($base) { $ranges.Add("$base..HEAD") } else { $ranges.Add('HEAD') }
}
$changedModules = New-Object System.Collections.Generic.List[string]
$commits = New-Object System.Collections.Generic.List[string]
foreach ($r in $ranges) {
    foreach ($f in @(git -C $repoRoot diff --name-only $r 2>$null)) { if ($f -and ($f -match '^Modules[\\/]')) { $changedModules.Add($f) } }
    foreach ($c in @(git -C $repoRoot rev-list $r 2>$null)) { if ($c) { $commits.Add($c) } }
}
$changedModules = @($changedModules | Sort-Object -Unique)
$commits = @($commits | Sort-Object -Unique)
if ($changedModules.Count -gt 0) {
    $attested = $false; $how = ''
    if ($env:GBUILD_REVIEW_APPROVED) { $attested = $true; $how = "GBUILD_REVIEW_APPROVED=$($env:GBUILD_REVIEW_APPROVED)" }
    else {
        $trailer = 0
        foreach ($c in $commits) {
            $msg = (git -C $repoRoot log -1 --format=%B $c) -join "`n"
            if ($msg -match '(?im)^Reviewed-by:\s*\S') { $trailer++ }
        }
        if ($commits.Count -gt 0 -and $trailer -ge $commits.Count) { $attested = $true; $how = "Reviewed-by trailer on all $trailer commit(s)" }
    }
    if (-not $attested -and $env:GBUILD_REVIEW_OVERRIDE) {
        $attested = $true; $how = "WAIVER ($($env:GBUILD_REVIEW_OVERRIDE))"
        Write-Host (Resolve-LogMessage -Key 'log.hook.reviewWaiver' -MessageArgs @([string]$env:GBUILD_REVIEW_OVERRIDE) -Fallback ("[gbuild hook] pre-push: WARNING - Modules/ review WAIVED, reason recorded: {0}" -f $env:GBUILD_REVIEW_OVERRIDE))
    }
    if (-not $attested) {
        Write-Host (Resolve-LogMessage -Key 'log.hook.reviewBlocked' -Fallback '[gbuild hook] pre-push: BLOCKED - this push changes Modules/ without an independent review attestation.')
        Write-Host (Resolve-LogMessage -Key 'log.hook.reviewChanged' -Fallback '[gbuild hook] changed under Modules/:')
        $changedModules | Select-Object -First 20 | ForEach-Object { Write-Host ("    " + $_) }
        Write-Host (Resolve-LogMessage -Key 'log.hook.reviewHowTo' -Fallback "[gbuild hook] how to proceed: (1) a maintainer who is NOT the author reviews the diff, (2) re-push with GBUILD_REVIEW_APPROVED=<reviewer-name>, or (3) amend the commits with a 'Reviewed-by: <name>' trailer, or (4) GBUILD_REVIEW_OVERRIDE=<reason> to record an explicit waiver (never an approval)")
        Write-Host (Resolve-LogMessage -Key 'log.hook.reviewCi' -Fallback '[gbuild hook] CI runs regardless; this gate exists so review is a conscious act, not a bypassed formality.')
        exit 2
    }
    Write-Host ("[gbuild hook] pre-push: Modules/ changes attested ({0})" -f $how)
}

Write-Host (Resolve-LogMessage -Key 'log.hook.prePushOk' -Fallback '[gbuild hook] pre-push: OK')
exit 0
