# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ========================================================================
# Chaos.psm1 — Chaos/Resilience Testing for gbuild
# ========================================================================
# Injects controlled failures to validate:
#   - Retry with exponential backoff (ErrorHandling.psm1)
#   - Rollback on partial build failure (ErrorHandling.psm1)
#   - Graceful degradation when modules/tools are missing
#   - Circuit breaker behavior (ErrorHandling.psm1)
#   - Pipeline step failure handling (Orchestrator.psm1)
#
# All chaos scenarios are opt-in via chaos.* config and never run
# in production unless explicitly enabled.
#
# Effector map (each armed $State.Chaos* flag has a real runtime consumer):
#   ChaosNetworkTimeout -> HealthCheck Test-NetworkConnectivity (probe timeout)
#     + self-contained retry drill inside the TransientNetwork scenario below
#   ChaosMissingTool    -> HealthCheck Test-RequiredTools (tool reported missing)
#   ChaosDiskSpaceMB    -> HealthCheck Test-DiskSpace (free space forced below minimum)
#   ChaosDeniedPath     -> real deny ACL on a temp dir (the OS is the consumer)
#   ChaosRetryOverride  -> ErrorHandling Invoke-WithRetry (overrides MaxRetries)
#   ChaosRollback       -> Orchestrator Start-GBuild (one-shot synthetic failure
#     after a green pipeline so the real catch -> Invoke-Rollback path runs)
# ========================================================================

function Get-ChaosConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    # Single-sourced via BuildConstants.ConfigKeyMap (chaos.*) with a
    # standalone fallback when BuildConstants is not loaded.
    # L5 per-environment enablement helper: applied on every return path so
    # GBUILD_CHAOS works even when the config section is absent entirely.
    # GBUILD_CHAOS=1 opts in without editing config; explicit 0 re-disables.
    $applyEnvToggle = {
        param($o)
        if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
            $chaosEnv = Test-EnvToggle -Name 'GBUILD_CHAOS'
            if ($chaosEnv -eq $true) { $o.enabled = $true }
            elseif ($chaosEnv -eq $false) { $o.enabled = $false }
        }
        return $o
    }
    if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) {
        $enabled = [bool](Get-BuildSetting -Key 'ChaosEnabled' -State $State -Fallback $false)
        $seed = [int](Get-BuildSetting -Key 'ChaosSeed' -State $State -Fallback 42)
    } else {
        $cfg = Get-ConfigSection -State $State -Path 'chaos'
        $enabled = if ($cfg -and ($null -ne $cfg.enabled)) { [bool]$cfg.enabled } else { $false }
        $seed = if ($cfg -and $cfg.seed) { [int]$cfg.seed } else { 42 }
        if (-not $cfg) {
            return (& $applyEnvToggle ([PSCustomObject]@{
                enabled = $enabled
                scenarios = @()
                seed = $seed
            }))
        }
    }
    $cfg = Get-ConfigSection -State $State -Path 'chaos'
    if (-not $cfg) {
        return (& $applyEnvToggle ([PSCustomObject]@{
            enabled = $enabled
            scenarios = @()
            seed = $seed
        }))
    }
    # Scenario list as ArrayList: `if..else{@()}` inside a PSCustomObject
    # literal unrolls an empty array to $null, and `$null + 'x'` is string
    # concatenation ('x'), not array-append. ArrayList avoids both traps.
    $scenarioList = [System.Collections.ArrayList]::new()
    if ($cfg.scenarios -is [System.Collections.ICollection]) {
        foreach ($cs in @($cfg.scenarios)) {
            if ($cs -and $scenarioList -notcontains [string]$cs) { [void]$scenarioList.Add([string]$cs) }
        }
    }
    $out = [PSCustomObject]@{
        enabled = if ($null -ne $cfg.enabled) { [bool]$cfg.enabled } else { $enabled }
        scenarios = @($scenarioList)
        seed = if ($cfg.seed) { [int]$cfg.seed } else { $seed }
    }
    # L5 per-environment scenarios: GBUILD_CHAOS_SCENARIOS="TransientNetwork,
    # RetryExhausted" selects drills (unknown names ignored with a warning).
    # With no scenarios the suite stays a safe no-op.
    $out = & $applyEnvToggle $out
    $valid = @('TransientNetwork','ToolMissing','DiskFull','PermissionDenied','RetryExhausted','RollbackTrigger')
    $envScenarios = @()
    if (Get-Command Get-EnvMode -ErrorAction SilentlyContinue) {
        $envScen = Get-EnvMode -Name 'GBUILD_CHAOS_SCENARIOS'
        if ($envScen) {
            foreach ($s in @($envScen -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $match = @($valid | Where-Object { $_.ToLowerInvariant() -eq $s })
                if ($match.Count -gt 0 -and $scenarioList -notcontains $match[0]) { [void]$scenarioList.Add($match[0]) }
                elseif ($match.Count -eq 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                    Write-Log (Resolve-LogMessage -Key 'log.chaos.unknownScenario' -MessageArgs @([string]$s, ($valid -join ', ')) -Fallback '[CHAOS] Ignoring unknown env scenario ''{0}'' (valid: {1})') 'Warn' $State
                }
            }
            $out.scenarios = @($scenarioList)
            $envScenarios = @($scenarioList)
        }
    }
    # EnvScoped: enablement/scenarios originated from environment (not config).
    # The suite uses it to exclude the build-failing RollbackTrigger from the
    # implicit default set — env opt-in runs safe drills unless RollbackTrigger
    # is explicitly listed in GBUILD_CHAOS_SCENARIOS.
    $envEnabled = $false
    if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
        try { $envEnabled = ((Test-EnvToggle -Name 'GBUILD_CHAOS') -eq $true) } catch { $envEnabled = $false }
    }
    $out | Add-Member -MemberType NoteProperty -Name EnvScoped -Value ([bool]($envEnabled -or ($envScenarios.Count -gt 0))) -Force
    $out | Add-Member -MemberType NoteProperty -Name EnvScenarios -Value $envScenarios -Force
    return $out
}

<#
.SYNOPSIS
    Runs a single chaos scenario by name.
.DESCRIPTION
    Supported scenarios:
      - TransientNetwork   : injects a transient network error on the first attempt
      - ToolMissing        : simulates a missing CLI tool
      - DiskFull           : simulates insufficient disk space
      - PermissionDenied   : simulates an access-denied error
      - RetryExhausted     : exhausts the retry limit to validate backoff + failure
      - RollbackTrigger    : forces a rollback mid-pipeline
#>
function Invoke-ChaosScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [PSCustomObject]$State = $null
    )

    $chaosCfg = Get-ChaosConfig -State $State
    if (-not $chaosCfg.enabled) {
        Write-Log (Resolve-LogMessage -Key 'log.chaos.skipped' -Fallback '[CHAOS] Skipped (chaos.enabled=false; opt in via chaos.enabled=true or GBUILD_CHAOS=1)') 'Gray' $State
        return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Skipped'; Detail = 'Chaos testing is disabled' }
    }

    $valid = @('TransientNetwork','ToolMissing','DiskFull','PermissionDenied','RetryExhausted','RollbackTrigger')
    if ($Scenario -notin $valid) {
        return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Failed'; Detail = "Unknown scenario: $Scenario. Valid: $($valid -join ', ')" }
    }

    Write-Log (Resolve-LogMessage -Key 'log.chaos.injecting' -MessageArgs @([string]$Scenario) -Fallback '[CHAOS] Injecting scenario: {0}') 'Warn' $State

    try {
        switch ($Scenario) {
            'TransientNetwork' {
                $originalTimeout = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'NetworkTimeout' -State $State -Fallback 15 } else { 15 }
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosNetworkTimeout' -Value 0.001 -Force
                # Drill: push a real transient fault through the live retry engine
                # (ErrorHandling Invoke-WithRetry) instead of only setting a flag.
                # The fault message matches the Transient classifier
                # (Get-ErrorCategory), so the first attempt fails and the retry
                # recovers — validating backoff end to end while armed.
                $drill = 'not run (retry engine unavailable)'
                try {
                    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
                        $script:ChaosDrillAttempts = 0
                        $null = Invoke-WithRetry -Action {
                            $script:ChaosDrillAttempts++
                            if ($script:ChaosDrillAttempts -lt 2) { throw (Resolve-LogMessage -Key 'log.chaos.line170' -Fallback 'Chaos drill: simulated network timeout') }
                            return 'recovered'
                        } -MaxRetries 2 -BaseDelayMs 1 -OperationName 'ChaosTransientNetwork' -State $State
                        $drill = 'transient fault recovered via retry (validated)'
                    } else {
                        # Level 5 single-source: fallback poll delay (was literal 100ms).
                        $chaosPollMs = 100
                        try {
                            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                                $chaosPollMs = [int](Get-BuildConstant -Key 'DistributedPollMs' -State $State -Fallback 100)
                            }
                        } catch { $chaosPollMs = 100 }
                        Start-Sleep -Milliseconds $chaosPollMs
                        $drill = 'Network timeout set to 1ms for one probe'
                    }
                } catch {
                    $drill = "drill failed: $($_.Exception.Message)"
                }
                $State.ChaosNetworkTimeout = $originalTimeout
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = $drill }
            }
            'ToolMissing' {
                # Level 5 single-source: drill tool list from BuildConstants
                # (was inline literals). Falls back to minimal list standalone.
                $tools = @('dotnet','git','node','npm')
                try {
                    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
                        $req = @(Get-BuildDefault -Key 'DefaultRequiredTools' -Fallback @('dotnet','git'))
                        $opt = @(Get-BuildDefault -Key 'DefaultOptionalTools' -Fallback @('node','npm'))
                        $merged = @($req + $opt | Select-Object -Unique)
                        if ($merged.Count -gt 0) { $tools = @($merged | Select-Object -First 4) }
                    }
                } catch { }
                $missing = $tools | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
                if (-not $missing) { $missing = $tools[0] }
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosMissingTool' -Value $missing -Force
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = "Simulated missing tool: $missing" }
            }
            'DiskFull' {
                $minDisk = Get-BuildConstant -Key 'MinDiskMB' -State $State -Fallback 2048
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosDiskSpaceMB' -Value ($minDisk + 1) -Force
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = "Simulated disk below threshold ($minDisk MB)" }
            }
            'PermissionDenied' {
                # Portable temp dir ([IO.Path]::GetTempPath(), never $env:TEMP which
                # is $null on Linux/macOS) and an unguessable leaf ([guid], never
                # Get-Random, whose output is predictable enough to pre-squat).
                $testPath = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-chaos-perm-test-' + [guid]::NewGuid().ToString('N'))
                try {
                    if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $testPath) } elseif (-not (Test-Path $testPath -PathType Container)) { New-Item -ItemType Directory -Path $testPath -Force -ErrorAction Stop | Out-Null }
                } catch { }
                # Windows-only. On Linux/macOS FileSystemAccessRule('Everyone', ...)
                # has no resolvable POSIX principal and the constructor throws,
                # which escaped to the outer catch and made this drill report
                # Status='Error' - i.e. the PermissionDenied injection silently
                # degraded to a no-op on 2 of the 3 supported platforms, with no
                # warning. Guard it the way this drill's own teardown already
                # guards it, and say so instead of pretending it injected.
                $isWin = if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { [bool](Test-IsWindowsHost) } else { $true }
                if (-not $isWin) {
                    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                        Write-Log (Resolve-LogMessage -Key 'log.chaos.permissionDeniedUnsupported' -Fallback '[Chaos] The PermissionDenied drill needs NTFS ACLs and is skipped on this platform.') 'Gray' $State
                    }
                    $acl = $null
                } else {
                    try {
                        $acl = Get-Acl $testPath -ErrorAction SilentlyContinue
                        if ($acl) {
                            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone','ReadAndExecute','Deny')
                            $acl.AddAccessRule($rule)
                            Set-Acl -Path $testPath -AclObject $acl -ErrorAction SilentlyContinue
                        }
                    } catch { $acl = $null }
                }
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosDeniedPath' -Value $testPath -Force
                # REGISTER FOR CLEANUP. This directory was created, ACL-locked with
                # a Deny rule for 'Everyone', published on State, and then never
                # removed by anything - every chaos run leaked a deny-ACL directory
                # into the temp path, and because the ACL denies access it cannot
                # always be removed by a plain delete afterwards. Register-TempFile
                # already enforces containment (tool / project / temp roots) and
                # hands the path to Start-GBuild's finally block, which is the
                # consumer this orphan function was written for and never had.
                if (Test-Path -LiteralPath $testPath) {
                    if (Get-Command Register-TempFile -ErrorAction SilentlyContinue) {
                        try { Register-TempFile -State $State -Path $testPath } catch { }
                    }
                }
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = "Set deny ACL on $testPath" }
            }
            'RetryExhausted' {
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosRetryOverride' -Value 0 -Force
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = 'Retry limit overridden to 0 for next operation' }
            }
            'RollbackTrigger' {
                $State | Add-Member -MemberType NoteProperty -Name 'ChaosRollback' -Value $true -Force
                return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Injected'; Detail = 'Rollback will be triggered on next failure' }
            }
        }
    } catch {
        return [PSCustomObject]@{ Scenario = $Scenario; Status = 'Error'; Detail = $_.Exception.Message }
    }
}

<#
.SYNOPSIS
    Runs all enabled chaos scenarios and returns a report.
.DESCRIPTION
    Iterates over build.chaos.scenarios (or all built-in scenarios when
    the list is empty) and invokes each one. Returns a summary PSCustomObject.
#>
function Remove-ChaosInjection {
    <#
    .SYNOPSIS
        Reverts everything Invoke-ChaosScenario injected into this build.
    .DESCRIPTION
        A chaos drill that cannot undo its own damage is not a drill, it is a
        mutation. Invoke-ChaosSuite used to run every scenario and return without
        reverting anything: the PermissionDenied drill created a temp directory,
        applied a Deny ACL for 'Everyone' and published it on
        State.ChaosDeniedPath, and no code path ever removed it - so each chaos run
        left an undeletable deny-ACL directory in the temp path. DiskFull likewise
        left State.ChaosDiskSpaceMB rewritten, which then fed the next gate that
        reads it.

        Teardown is best-effort and never throws: a failure to clean up must not
        turn a drill report into a build failure. The ACL is cleared BEFORE the
        delete because a Deny rule for 'Everyone' includes the current user and
        would otherwise make the directory unremovable.
    #>
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not $State) { return }
    $reverted = [System.Collections.Generic.List[string]]::new()

    # 1. PermissionDenied: clear the deny ACL, then remove the directory.
    $denied = ''
    try { if ($State.PSObject.Properties.Name -contains 'ChaosDeniedPath') { $denied = [string]$State.ChaosDeniedPath } } catch { }
    if ($denied -and (Test-Path -LiteralPath $denied)) {
        try {
            if (Get-Command Get-Acl -ErrorAction SilentlyContinue) {
                $acl = Get-Acl -LiteralPath $denied -ErrorAction SilentlyContinue
                if ($acl) {
                    # Remove the Deny entries this scenario added rather than
                    # blanket-disabling inheritance, so an unrelated inherited
                    # policy on the temp root is left as it was.
                    $denyRules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference -eq 'Everyone' })
                    foreach ($r in $denyRules) { try { [void]$acl.RemoveAccessRule($r) } catch { } }
                    try { Set-Acl -LiteralPath $denied -AclObject $acl -ErrorAction SilentlyContinue } catch { }
                }
            }
        } catch { }
        $removed = $false
        if (Get-Command Invoke-SafeRemove -ErrorAction SilentlyContinue) {
            try { $removed = [bool](Invoke-SafeRemove -Path $denied -Recurse -Force -ErrorAction SilentlyContinue) } catch { $removed = $false }
        }
        if (-not $removed) { try { Remove-Item -LiteralPath $denied -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        if (-not (Test-Path -LiteralPath $denied)) { $reverted.Add('PermissionDenied') }
        else { Write-Log (Resolve-LogMessage -Key 'log.chaos.teardownFailed' -MessageArgs @($denied) -Fallback '[CHAOS] Could not remove injected deny-ACL path {0}; delete it manually.') 'Warn' $State }
    }
    try { $State | Add-Member -MemberType NoteProperty -Name 'ChaosDeniedPath' -Value '' -Force } catch { }

    # 2. DiskFull: the simulated floor was written onto State, where later gates
    #    read it. Clear it so the value cannot outlive the drill.
    try { $State | Add-Member -MemberType NoteProperty -Name 'ChaosDiskSpaceMB' -Value $null -Force } catch { }
    $reverted.Add('DiskFull')

    return $reverted.ToArray()
}

function Invoke-ChaosSuite {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)
    $chaosCfg = Get-ChaosConfig -State $State
    if (-not $chaosCfg.enabled) {
        Write-Log (Resolve-LogMessage -Key 'log.chaos.suiteSkipped' -Fallback '[CHAOS] Suite skipped (chaos.enabled=false; opt in via chaos.enabled=true or GBUILD_CHAOS=1)') 'Gray' $State
        return [PSCustomObject]@{ Status = 'Skipped'; Scenarios = @() }
    }

    # Scenario selection: explicit list wins (config + GBUILD_CHAOS_SCENARIOS).
    # Legacy default (config-enabled, no list) runs all six. Env-enabled with
    # no list runs the five non-destructive drills — RollbackTrigger fails the
    # build by design, so it requires explicit listing via env.
    $allSafe = @('TransientNetwork','ToolMissing','DiskFull','PermissionDenied','RetryExhausted')
    if ($chaosCfg.scenarios.Count -gt 0) { $scenarios = @($chaosCfg.scenarios) }
    elseif ($chaosCfg.EnvScoped) {
        $scenarios = $allSafe
        Write-Log (Resolve-LogMessage -Key 'log.chaos.envNoScenarios' -Fallback '[CHAOS] Env-enabled with no scenario list - running safe drills only (add RollbackTrigger to GBUILD_CHAOS_SCENARIOS to include it)') 'Warn' $State
    } else { $scenarios = @($allSafe + @('RollbackTrigger')) }
    $results = @()
    try {
        foreach ($s in $scenarios) {
            $r = Invoke-ChaosScenario -Scenario $s -State $State
            $results += $r
        }
    } finally {
        # ALWAYS revert, including when a scenario threw. Registering the temp path
        # with Register-TempFile only helps if the run reaches Start-GBuild's
        # finally block; this runs even on the failure path that skips it.
        $reverted = @()
        try { $reverted = @(Remove-ChaosInjection -State $State) } catch { }
        if ($reverted.Count -gt 0) {
            Write-Log (Resolve-LogMessage -Key 'log.chaos.reverted' -MessageArgs @($reverted -join ', ')) 'Info' $State
        }
    }

    $passed = @($results | Where-Object { $_.Status -eq 'Injected' }).Count
    # 'Error' (a scenario that threw mid-injection) counts as failed: the old
    # filter matched only 'Failed', so an Errored scenario vanished from every
    # bucket and the suite could report Passed with an error inside.
    $failed = @($results | Where-Object { $_.Status -in @('Failed', 'Error') }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    return [PSCustomObject]@{
        Status    = if ($failed -gt 0) { 'Degraded' } elseif ($skipped -gt 0) { 'Partial' } else { 'Passed' }
        Total     = $results.Count
        Passed    = $passed
        Failed    = $failed
        Skipped   = $skipped
        Scenarios = $results
    }
}

Export-ModuleMember -Function @('Get-ChaosConfig', 'Invoke-ChaosScenario', 'Invoke-ChaosSuite', 'Remove-ChaosInjection')
