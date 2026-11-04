# ============================================================================
# Orchestrator.Pipeline.Events.ps1 - build event wiring extracted from Orchestrator.Pipeline.ps1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

<#
.SYNOPSIS
    Resolves deploy-choice MSBuild args from config (Level 5 single-source).
.DESCRIPTION
    Reads build.deployChoiceArgs.* via Get-BuildConstant so MSBuild args change
    without code edits. Falls back to BuildConstants defaults when config is absent.
#>

function Register-BuildEventSubscribers {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ((Get-Command Add-BuildEvent -ErrorAction SilentlyContinue) -and (Get-Command Send-Alert -ErrorAction SilentlyContinue)) {
        $existing = Get-BuildEventSubscribers

        # EVT_BUILD_START
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_START) -and $existing[$EVT_BUILD_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_START -Label 'Telemetry: BuildStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m32') 'Debug' $src
            }
        }
        # EVT_BUILD_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_COMPLETE) -and $existing[$EVT_BUILD_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_COMPLETE -Label 'Telemetry: BuildComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m33' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_BUILD_COMPLETE -Field 'Success' 'pending'))) 'Debug' $src
            }
        }
        # EVT_BUILD_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_ERROR) -and $existing[$EVT_BUILD_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_ERROR -Label 'Alerting: BuildError' -Handler {
                param($src, $data)
                # ErrorHandling.New-BuildError publishes EVT_ON_ERROR with the
                # payload @{ Error = $err } and Invoke-WithRetry publishes
                # EVT_ON_RETRY with @{ Operation; Attempt; MaxRetries; DelayMs;
                # Error }. This handler read $data.Message, which exists in
                # NEITHER payload, so every critical alert fell through to the
                # generic 'Build error occurred' and the actual diagnostic was
                # dropped at the alerting boundary. Read the real fields, and
                # still accept a flat .Message for third-party publishers.
                $msg = ''
                if ($data) {
                    $raw = Get-EventPayloadField -Data $data -EventName $EVT_BUILD_ERROR -Field 'Message' ''
                    if ($raw -is [string]) { $msg = $raw }
                    elseif ($raw -and $raw.Message) { $msg = [string]$raw.Message }
                }
                if (-not $msg) { $msg = 'Build error occurred' }
                Send-Alert -Message $msg -Severity 'Critical' -State $src -Data $data
            }
        }
        # EVT_BUILD_WARNING
        if (-not ($existing -and $existing.ContainsKey($EVT_BUILD_WARNING) -and $existing[$EVT_BUILD_WARNING] -gt 0)) {
            Add-BuildEvent -EventName $EVT_BUILD_WARNING -Label 'Telemetry: BuildWarning' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m34' -MessageArgs @($($data.Message))) 'Debug' $src
            }
        }
        # EVT_STEP_START
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_START) -and $existing[$EVT_STEP_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_START -Label 'Telemetry: StepStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m35' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_START -Field 'StepName' '(unnamed)'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_STEP_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_COMPLETE) -and $existing[$EVT_STEP_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_COMPLETE -Label 'Telemetry: StepComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m36' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_COMPLETE -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_COMPLETE -Field 'Status' '?'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_STEP_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_ERROR) -and $existing[$EVT_STEP_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_ERROR -Label 'Telemetry: StepError' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m37' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_ERROR -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_ERROR -Field 'Error'))) 'Warn' $src
            }
        }
        # EVT_STEP_SKIPPED
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_SKIPPED) -and $existing[$EVT_STEP_SKIPPED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_SKIPPED -Label 'Telemetry: StepSkipped' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m38' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_SKIPPED -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_SKIPPED -Field 'Reason' 'no reason'))) 'Gray' $src
            }
        }
        # EVT_STEP_PROGRESS
        if (-not ($existing -and $existing.ContainsKey($EVT_STEP_PROGRESS) -and $existing[$EVT_STEP_PROGRESS] -gt 0)) {
            Add-BuildEvent -EventName $EVT_STEP_PROGRESS -Label 'Telemetry: StepProgress' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m39' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_STEP_PROGRESS -Field 'StepName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_STEP_PROGRESS -Field 'ElapsedSec' '?'))) 'Gray' $src
            }
        }
        # EVT_ON_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_ERROR) -and $existing[$EVT_ON_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_ERROR -Label 'Alerting: OnError' -Handler {
                param($src, $data)
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_ERROR -Field 'Message' '') } else { '' }; if (-not $msg) { $msg = 'Error occurred' }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
        # EVT_ON_RETRY
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_RETRY) -and $existing[$EVT_ON_RETRY] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_RETRY -Label 'Telemetry: OnRetry' -Handler {
                param($src, $data)
                # Align with the payload Invoke-WithRetry actually publishes:
                #   @{ Operation; Attempt; MaxRetries; DelayMs; Error }
                # This handler read $data.MaxAttempts and $data.Message, neither
                # of which is in that payload, so every retry line rendered as
                # the useless "[EVT] Retry: 1/ - ".
                $op = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Operation' 'operation') } else { 'operation' }
                $n  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'MaxAttempts' '?') } else { '?' }
                $a  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Attempt' '?') } else { '?' }
                $e  = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_RETRY -Field 'Message' '') } else { '' }
                $suffix = if ($e) { " - $e" } else { '' }
                # ${op} not $op: a bare "$op:" is parsed as a scope-qualified
                # variable reference and fails to parse.
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m40' -MessageArgs @(${op}, $a, $n, $suffix)) 'Warn' $src
            }
        }
        # EVT_ON_ROLLBACK
        if (-not ($existing -and $existing.ContainsKey($EVT_ON_ROLLBACK) -and $existing[$EVT_ON_ROLLBACK] -gt 0)) {
            Add-BuildEvent -EventName $EVT_ON_ROLLBACK -Label 'Alerting: Rollback' -Handler {
                param($src, $data)
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_ON_ROLLBACK -Field 'Message' '') } else { '' }; if (-not $msg) { $msg = 'Rollback executed' }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
        # EVT_PLUGIN_LOADED
        if (-not ($existing -and $existing.ContainsKey($EVT_PLUGIN_LOADED) -and $existing[$EVT_PLUGIN_LOADED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_PLUGIN_LOADED -Label 'Telemetry: PluginLoaded' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m41' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_LOADED -Field 'PluginName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_LOADED -Field 'Version' ''))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_PLUGIN_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_PLUGIN_ERROR) -and $existing[$EVT_PLUGIN_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_PLUGIN_ERROR -Label 'Telemetry: PluginError' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m42' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_ERROR -Field 'PluginName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_PLUGIN_ERROR -Field 'Error'))) 'Warn' $src
            }
        }
        # EVT_CACHE_HIT
        if (-not ($existing -and $existing.ContainsKey($EVT_CACHE_HIT) -and $existing[$EVT_CACHE_HIT] -gt 0)) {
            Add-BuildEvent -EventName $EVT_CACHE_HIT -Label 'Telemetry: CacheHit' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m43' -MessageArgs @($($data.Key))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_CACHE_MISS
        if (-not ($existing -and $existing.ContainsKey($EVT_CACHE_MISS) -and $existing[$EVT_CACHE_MISS] -gt 0)) {
            Add-BuildEvent -EventName $EVT_CACHE_MISS -Label 'Telemetry: CacheMiss' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m44' -MessageArgs @($($data.Key))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_TELEMETRY_RECORDED
        if (-not ($existing -and $existing.ContainsKey($EVT_TELEMETRY_RECORDED) -and $existing[$EVT_TELEMETRY_RECORDED] -gt 0)) {
            Add-BuildEvent -EventName $EVT_TELEMETRY_RECORDED -Label 'Telemetry: Recorded' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m46' -MessageArgs @($(Get-EventPayloadField -Data $data -EventName $EVT_TELEMETRY_RECORDED -Field 'MetricName' '(unnamed)'), $(Get-EventPayloadField -Data $data -EventName $EVT_TELEMETRY_RECORDED -Field 'File' '(no file)'))) (Get-FlowLogLevel -State $src) $src
            }
        }
        # EVT_DEPLOY_START
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_START) -and $existing[$EVT_DEPLOY_START] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_START -Label 'Telemetry: DeployStart' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m47' -MessageArgs @($($data.Target))) 'Info' $src
            }
        }
        # EVT_DEPLOY_COMPLETE
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_COMPLETE) -and $existing[$EVT_DEPLOY_COMPLETE] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_COMPLETE -Label 'Telemetry: DeployComplete' -Handler {
                param($src, $data)
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m48' -MessageArgs @($($data.Target), $($data.Success))) 'Info' $src
            }
        }
        # EVT_DEPLOY_ERROR
        if (-not ($existing -and $existing.ContainsKey($EVT_DEPLOY_ERROR) -and $existing[$EVT_DEPLOY_ERROR] -gt 0)) {
            Add-BuildEvent -EventName $EVT_DEPLOY_ERROR -Label 'Alerting: DeployError' -Handler {
                param($src, $data)
                # DeployTargets publishes @{ Target = ...; Error = ... }.
                # $data.Message exists in neither, so every deploy alert carried
                # only the generic fallback and the real failure was lost.
                $msg = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_DEPLOY_ERROR -Field 'Message' '') } else { '' }
                $target = if ($data) { [string](Get-EventPayloadField -Data $data -EventName $EVT_DEPLOY_ERROR -Field 'Target' '') } else { '' }
                if (-not $msg) { $msg = 'Deploy error occurred' }
                if ($target) { $msg = "[$target] $msg" }
                Send-Alert -Message $msg -Severity 'Error' -State $src -Data $data
            }
        }
    }
}

<#
.SYNOPSIS
    Unregisters build event subscribers (L5 session hygiene).
.DESCRIPTION
    Removes every handler via Remove-BuildEvent (scriptblock identity, fetched
    through Get-BuildEventHandlers) so repeated Start-GBuild calls in one
    session (global gbuild fn, HotReload watch, Pester) never accumulate stale
    handlers. Register-BuildEventSubscribers re-adds them on the next build.
    Never throws; teardown must not break the build finally block.
#>

function Unregister-BuildEventSubscribers {
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-BuildEventHandlers -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command Remove-BuildEvent -ErrorAction SilentlyContinue)) { return }
    $events = @()
    try { $events = @((Get-BuildEventSubscribers).Keys) } catch { $events = @() }
    foreach ($ev in $events) {
        try {
            $handlers = @(Get-BuildEventHandlers -EventName $ev)
            foreach ($h in $handlers) {
                try { Remove-BuildEvent -EventName $ev -Handler $h } catch { }
            }
        } catch { }
    }
}

<#
.SYNOPSIS
    Registers core OOP services into the lightweight DI container (singletons).
#>

function Register-BuildServices {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (Get-Command Register-Service -ErrorAction SilentlyContinue) {
        if (-not (Test-ServiceRegistered -Name 'BuildContext')) {
            Register-Service -Name 'BuildContext' -Factory { New-BuildContext -Seed $State } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'MetricRegistry')) {
            Register-Service -Name 'MetricRegistry' -Factory { Get-MetricRegistry } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'EventBus')) {
            Register-Service -Name 'EventBus' -Factory { Get-BuildEventBus } -Singleton
        }
        if (-not (Test-ServiceRegistered -Name 'ErrorHandling')) {
            Register-Service -Name 'ErrorHandling' -Factory { Get-ErrorHandlingService } -Singleton
        }
    }
}
