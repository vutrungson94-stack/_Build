
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'

function Get-EventTenant {
    param($Source, [string]$TenantId = '')

Set-StrictMode -Version 1.0
    if ($TenantId) { return $TenantId }
    $value = Get-SectionValue -Section $Source -Key 'TenantId' -Default ''
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return 'default' }
    return [string]$value
}

function Test-EventName {
    param([string]$EventName)
    return (-not [string]::IsNullOrWhiteSpace($EventName) -and $EventName.Length -le 128 -and $EventName -match '^[A-Za-z0-9_.:-]+$')
}

function ConvertTo-EventData {
    param($Data)
    if ($null -eq $Data) { return @{} }
    if ($Data -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Data.Keys) { $result[[string]$key] = $Data[$key] }
        return $result
    }
    try {
        $result = @{}
        foreach ($property in $Data.PSObject.Properties) { $result[$property.Name] = $property.Value }
        return $result
    } catch { return @{} }
}

class BuildEventBus {
    [hashtable] $Subscribers
    [System.Collections.ArrayList] $EventErrors
    [object] $SyncRoot
    [long] $Sequence

    BuildEventBus() {
        $this.Subscribers = @{}
        $this.EventErrors = [System.Collections.ArrayList]::new()
        $this.SyncRoot = New-Object object
        $this.Sequence = 0
    }

    [string] NormalizeTenant([string]$TenantId) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) { return 'default' }
        return $TenantId
    }

    [void] Subscribe([string]$EventName, [scriptblock]$Handler, [string]$Label, [string]$TenantId = 'default') {
        $tenant = $this.NormalizeTenant($TenantId)
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            if (-not $this.Subscribers.ContainsKey($EventName)) { $this.Subscribers[$EventName] = [System.Collections.ArrayList]::new() }
            foreach ($existing in @($this.Subscribers[$EventName])) { if ($existing.Handler -eq $Handler -and $existing.TenantId -eq $tenant) { return } }
            $handlerText = $Label
            if (-not $handlerText) { try { $handlerText = $Handler.Ast.Extent.ToString(); if ($handlerText.Length -gt 200) { $handlerText = $handlerText.Substring(0, 200) + '...' } } catch { $handlerText = '<unable to extract source>' } }
            [void]$this.Subscribers[$EventName].Add(@{ Handler = $Handler; Label = $handlerText; TenantId = $tenant })
        } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
    }

    [void] Unsubscribe([string]$EventName, [scriptblock]$Handler, [string]$TenantId = '') {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            if (-not $this.Subscribers.ContainsKey($EventName)) { return }
            $tenant = $this.NormalizeTenant($TenantId)
            $list = $this.Subscribers[$EventName]
            for ($i = $list.Count - 1; $i -ge 0; $i--) { if (($list[$i].Handler -eq $Handler) -and ([string]::IsNullOrWhiteSpace($TenantId) -or $list[$i].TenantId -eq $tenant)) { $list.RemoveAt($i) } }
            if ($list.Count -eq 0) { $this.Subscribers.Remove($EventName) }
        } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
    }

      [void] UnsubscribeAll([string]$EventName, [string]$TenantId = '') {
          [System.Threading.Monitor]::Enter($this.SyncRoot)
          try {
              if (-not $this.Subscribers.ContainsKey($EventName)) { return }
              $tenant = $this.NormalizeTenant($TenantId)
              $list = $this.Subscribers[$EventName]
              for ($i = $list.Count - 1; $i -ge 0; $i--) { if ([string]::IsNullOrWhiteSpace($TenantId) -or $list[$i].TenantId -eq $tenant) { $list.RemoveAt($i) } }
              if ($list.Count -eq 0) { $this.Subscribers.Remove($EventName) }
          } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
      }

      [bool] Publish([string]$EventName, [object]$Source, [hashtable]$Data, [string]$TenantId = 'default') {
        $tenant = $this.NormalizeTenant($TenantId)
        $handlers = @()
        [long]$seqValue = 0
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            $this.Sequence = $this.Sequence + 1
            $seqValue = [long]$this.Sequence
            if (-not $this.Subscribers.ContainsKey($EventName)) { return $true }
            $handlers = @($this.Subscribers[$EventName] | Where-Object { $_.TenantId -eq $tenant -or $_.TenantId -eq '*' })
        } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
        $correlation = [string](Get-SectionValue -Section $Source -Key 'CorrelationId' -Default (Get-SectionValue -Section $Data -Key 'correlationId' -Default ''))
        foreach ($entry in $handlers) {
            $payload = @{}
            foreach ($key in @($Data.Keys)) { $payload[[string]$key] = $Data[$key] }
            $payload['eventName'] = $EventName
            $payload['tenantId'] = $tenant
            $payload['timestamp'] = [DateTime]::UtcNow.ToString('o')
            $payload['sequence'] = $seqValue
            $payload['correlationId'] = $correlation
            try { $null = & $entry.Handler $Source $payload }
            catch {
                $message = [string]$_.Exception.Message
                if (Get-Command Protect-AlertText -ErrorAction SilentlyContinue) { try { $message = [string](Protect-AlertText $message) } catch { } }
                $stack = [string]$_.ScriptStackTrace
                if (Get-Command Protect-AlertText -ErrorAction SilentlyContinue) { try { $stack = [string](Protect-AlertText $stack) } catch { } }
                [void]$this.EventErrors.Add(@{ Time = [DateTime]::UtcNow.ToString('o'); EventName = $EventName; TenantId = $tenant; Handler = [string]$entry.Label; Exception = $message; StackTrace = $stack })
                Write-Warning (Resolve-LogMessage -Key 'log.event.handlerFailed' -MessageArgs @([string]$EventName, [string]$message) -Fallback 'EventBus: handler failed for ''{0}'': {1}')
            }
        }
        return $true
    }

    [System.Collections.ArrayList] GetErrors() { return $this.EventErrors }
    [hashtable] GetSubscriberCounts() {
        $result = @{}
        foreach ($eventName in @($this.Subscribers.Keys)) { $result[$eventName] = @($this.Subscribers[$eventName]).Count }
        return $result
    }
    [object[]] GetHandlers([string]$EventName, [string]$TenantId) {
        if (-not $this.Subscribers.ContainsKey($EventName)) { return @() }
        if ([string]::IsNullOrWhiteSpace($TenantId)) { return @($this.Subscribers[$EventName] | ForEach-Object { $_.Handler }) }
        $tenant = $this.NormalizeTenant($TenantId)
        return @($this.Subscribers[$EventName] | Where-Object { $_.TenantId -eq $tenant -or $_.TenantId -eq '*' } | ForEach-Object { $_.Handler })
    }
    [void] Clear([string]$TenantId = '') {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            if ([string]::IsNullOrWhiteSpace($TenantId)) { $this.Subscribers = @{}; $this.EventErrors = [System.Collections.ArrayList]::new(); return }
            foreach ($eventName in @($this.Subscribers.Keys)) {
                $list = $this.Subscribers[$eventName]
                for ($i = $list.Count - 1; $i -ge 0; $i--) { if ($list[$i].TenantId -eq $TenantId) { $list.RemoveAt($i) } }
                if ($list.Count -eq 0) { $this.Subscribers.Remove($eventName) }
            }
        } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
    }
}

$script:Bus = [BuildEventBus]::new()
Set-Variable -Name 'EVT_BUILD_START' -Value 'EVT_BUILD_START' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_BUILD_COMPLETE' -Value 'EVT_BUILD_COMPLETE' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_BUILD_ERROR' -Value 'EVT_BUILD_ERROR' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_BUILD_WARNING' -Value 'EVT_BUILD_WARNING' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_STEP_START' -Value 'EVT_STEP_START' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_STEP_COMPLETE' -Value 'EVT_STEP_COMPLETE' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_STEP_ERROR' -Value 'EVT_STEP_ERROR' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_STEP_SKIPPED' -Value 'EVT_STEP_SKIPPED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_STEP_PROGRESS' -Value 'EVT_STEP_PROGRESS' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_ON_ERROR' -Value 'EVT_ON_ERROR' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_ON_RETRY' -Value 'EVT_ON_RETRY' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_ON_ROLLBACK' -Value 'EVT_ON_ROLLBACK' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_PLUGIN_LOADED' -Value 'EVT_PLUGIN_LOADED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_PLUGIN_ERROR' -Value 'EVT_PLUGIN_ERROR' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CACHE_HIT' -Value 'EVT_CACHE_HIT' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CACHE_MISS' -Value 'EVT_CACHE_MISS' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CACHE_SYNC' -Value 'EVT_CACHE_SYNC' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_TELEMETRY_RECORDED' -Value 'EVT_TELEMETRY_RECORDED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_DEPLOY_START' -Value 'EVT_DEPLOY_START' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_DEPLOY_COMPLETE' -Value 'EVT_DEPLOY_COMPLETE' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_DEPLOY_ERROR' -Value 'EVT_DEPLOY_ERROR' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_ANOMALY_DETECTED' -Value 'EVT_ANOMALY_DETECTED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_TREND_DRIFT' -Value 'EVT_TREND_DRIFT' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_FAILURE_RATE_DRIFT' -Value 'EVT_FAILURE_RATE_DRIFT' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_AUTO_ROLLBACK' -Value 'EVT_AUTO_ROLLBACK' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CORE_COMMANDS_MISSING' -Value 'EVT_CORE_COMMANDS_MISSING' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CORE_COMMANDS_REPAIRED' -Value 'EVT_CORE_COMMANDS_REPAIRED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_AUDIT_LEDGER_WRITE' -Value 'EVT_AUDIT_LEDGER_WRITE' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CLUSTER_REGISTERED' -Value 'EVT_CLUSTER_REGISTERED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CLUSTER_STATUS_CHANGED' -Value 'EVT_CLUSTER_STATUS_CHANGED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_CLUSTER_BUILD_SUBMITTED' -Value 'EVT_CLUSTER_BUILD_SUBMITTED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_COORDINATOR_LEADER_ACQUIRED' -Value 'EVT_COORDINATOR_LEADER_ACQUIRED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_COORDINATOR_LEADER_RELEASED' -Value 'EVT_COORDINATOR_LEADER_RELEASED' -Option ReadOnly -Scope Script
Set-Variable -Name 'EVT_DISTRIBUTED_DISPATCH' -Value 'EVT_DISTRIBUTED_DISPATCH' -Option ReadOnly -Scope Script

function Add-BuildEvent {
    param([Parameter(Mandatory)][Alias('Name')][string]$EventName, [Parameter(Mandatory)][scriptblock]$Handler, [string]$Label = '', [string]$TenantId = 'default')
    if (-not (Test-EventName $EventName)) { return $false }
    $script:Bus.Subscribe($EventName, $Handler, $Label, $TenantId)
    return $true
}

  function Remove-BuildEvent {
      # The handler is optional: without one, every subscription to the event
      # is removed. The other tool's version of this command behaves the same
      # way, and the two tools export the same command name into one
      # namespace, so a call written for either must bind against either.
      param([Parameter(Mandatory)][Alias('Name')][string]$EventName, [scriptblock]$Handler, [string]$TenantId = '')
      if (-not (Test-EventName $EventName)) { return $false }
      if ($null -eq $Handler) { $script:Bus.UnsubscribeAll($EventName, $TenantId); return $true }
      $script:Bus.Unsubscribe($EventName, $Handler, $TenantId)
      return $true
  }

function Send-BuildEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('Name')][string]$EventName, [object]$Source = $null, [object]$Data = @{}, [string]$TenantId = '')
    if (-not (Test-EventName $EventName)) { return $false }
    if ($null -ne $Data) {
        $isDictionary = $Data -is [System.Collections.IDictionary]
        $isObject = $false
        try { $isObject = ($null -ne $Data.PSObject -and $Data.PSObject.Properties.Count -gt 0) } catch { $isObject = $false }
        if (-not $isDictionary -and -not $isObject) { return $false }
    }
    $sourceTenant = Get-EventTenant -Source $Source -TenantId ''
    if ($TenantId -and $sourceTenant -ne 'default' -and $TenantId -ne $sourceTenant) { return $false }
    $tenant = Get-EventTenant -Source $Source -TenantId $TenantId
    $payload = ConvertTo-EventData $Data
    return [bool]$script:Bus.Publish($EventName, $Source, $payload, $tenant)
}

function Get-BuildEventErrors { param([string]$TenantId = ''); $errors = @($script:Bus.GetErrors()); if ([string]::IsNullOrWhiteSpace($TenantId)) { return $errors }; return @($errors | Where-Object { $_.TenantId -eq $TenantId }) }
  function Get-BuildEventSubscribers { param([Alias('Name')][string]$EventName = '', [scriptblock]$Handler, [string]$TenantId = ''); return $script:Bus.GetSubscriberCounts() }
function Get-BuildEventHandlers { param([Parameter(Mandatory)][string]$EventName, [string]$TenantId = ''); return @($script:Bus.GetHandlers($EventName, $TenantId)) }
function Clear-BuildEvents { param([string]$TenantId = ''); $script:Bus.Clear($TenantId) }
function Get-BuildEventBus { return $script:Bus }

# =============================================================================
# PAYLOAD CONTRACT
# =============================================================================
# WHY THIS EXISTS
# The event name constants were made authoritative (publishers must use
# $EVT_* rather than a string literal, enforced by a hygiene gate), but the
# event PAYLOAD had no declared shape at all. A publisher and its handler were
# connected only by agreeing on a field name in two different files.
#
# That agreement had silently rotted across most of the bus. 9 of the 17
# handlers registered in Orchestrator.Register-BuildEventSubscribers read
# fields no publisher ever sends, so those log lines rendered with blanks:
#   handler read $data.StepName  | publishers send @{ Step = ... }
#   handler read $data.Success   | publisher sends @{ Status = 'Success' }
#   handler read $data.PluginName| publisher sends @{ Name = ... }
#   handler read $data.MetricName| publisher sends @{ Metric = ... }
#   handler read $data.Message   | publisher sends @{ Error = ... }  <- this one
#                                dropped the real error at the alerting edge
#
# Declaring the shape makes the drift detectable instead of invisible. The
# schema below is the single source; Test-BuildEventPayloadContract checks the
# live code against it and the hygiene gate runs that check, so a new mismatch
# fails the build instead of printing an empty telemetry line forever.
#
# 'Keys'    - the fields a publisher may send.
# 'Aliases' - alternative spellings accepted on READ, so a payload can evolve
#             without breaking an already-deployed handler. First match wins.
$script:EventPayloadSchema = @{
    'EVT_BUILD_START'           = @{ Keys = @('Steps'); Aliases = @{} }
    'EVT_BUILD_COMPLETE'        = @{ Keys = @('Status', 'Success', 'DurationSec', 'CacheHit'); Aliases = @{ 'Success' = @('Status', 'Succeeded') } }
    'EVT_BUILD_ERROR'           = @{ Keys = @('Message', 'Error', 'Choice', 'ProjectType'); Aliases = @{ 'Message' = @('Message', 'Error') } }
    'EVT_BUILD_WARNING'         = @{ Keys = @('Message'); Aliases = @{} }
    'EVT_STEP_START'            = @{ Keys = @('Step', 'StepName'); Aliases = @{ 'StepName' = @('Step', 'StepName', 'Name') } }
    'EVT_STEP_COMPLETE'         = @{ Keys = @('Step', 'Status', 'DurationMs'); Aliases = @{ 'StepName' = @('Step', 'StepName', 'Name'); 'Status' = @('Status', 'State') } }
    'EVT_STEP_ERROR'            = @{ Keys = @('Step', 'Error'); Aliases = @{ 'StepName' = @('Step', 'StepName', 'Name') } }
    'EVT_STEP_SKIPPED'          = @{ Keys = @('Step', 'Reason'); Aliases = @{ 'StepName' = @('Step', 'StepName', 'Name') } }
    'EVT_STEP_PROGRESS'         = @{ Keys = @('Label', 'ElapsedSec', 'Step'); Aliases = @{ 'StepName' = @('Label', 'Step', 'StepName'); 'Message' = @('Label', 'Message') } }
    'EVT_ON_ERROR'              = @{ Keys = @('Error', 'Message'); Aliases = @{ 'Message' = @('Error', 'Message') } }
    'EVT_ON_RETRY'              = @{ Keys = @('Operation', 'Attempt', 'MaxRetries', 'DelayMs', 'Error'); Aliases = @{ 'MaxAttempts' = @('MaxRetries', 'MaxAttempts'); 'Message' = @('Error', 'Message') } }
    'EVT_ON_ROLLBACK'           = @{ Keys = @('Message'); Aliases = @{} }
    'EVT_PLUGIN_LOADED'         = @{ Keys = @('Name', 'Version', 'Languages'); Aliases = @{ 'PluginName' = @('Name', 'PluginName') } }
    'EVT_PLUGIN_ERROR'          = @{ Keys = @('Name', 'Error'); Aliases = @{ 'PluginName' = @('Name', 'PluginName') } }
    'EVT_CACHE_HIT'             = @{ Keys = @('Key', 'Project'); Aliases = @{} }
    'EVT_CACHE_MISS'            = @{ Keys = @('Key', 'Project'); Aliases = @{} }
    'EVT_CACHE_SYNC'            = @{ Keys = @('Action', 'Key'); Aliases = @{} }
    'EVT_TELEMETRY_RECORDED'    = @{ Keys = @('File', 'Metric'); Aliases = @{ 'MetricName' = @('Metric', 'MetricName', 'Name') } }
    'EVT_DEPLOY_START'          = @{ Keys = @('Target', 'DryRun'); Aliases = @{} }
    'EVT_DEPLOY_COMPLETE'       = @{ Keys = @('Target', 'Success'); Aliases = @{} }
    'EVT_DEPLOY_ERROR'          = @{ Keys = @('Target', 'Error'); Aliases = @{ 'Message' = @('Error', 'Message') } }
    'EVT_ANOMALY_DETECTED'      = @{ Keys = @('dimension', 'detail', 'timestamp', 'severity'); Aliases = @{} }
    'EVT_TREND_DRIFT'           = @{ Keys = @('dimension', 'detail', 'timestamp'); Aliases = @{} }
    'EVT_FAILURE_RATE_DRIFT'    = @{ Keys = @('dimension', 'detail', 'timestamp'); Aliases = @{} }
    'EVT_AUTO_ROLLBACK'         = @{ Keys = @('dimension', 'severity', 'timestamp'); Aliases = @{} }
    'EVT_CORE_COMMANDS_MISSING' = @{ Keys = @('Missing'); Aliases = @{} }
    'EVT_CORE_COMMANDS_REPAIRED'= @{ Keys = @('Missing'); Aliases = @{} }
    'EVT_AUDIT_LEDGER_WRITE'    = @{ Keys = @('Sequence', 'Hash'); Aliases = @{} }
    'EVT_CLUSTER_REGISTERED'    = @{ Keys = @('Cluster', 'Endpoint'); Aliases = @{ 'Name' = @('Cluster', 'Name') } }
    'EVT_CLUSTER_STATUS_CHANGED'= @{ Keys = @('Cluster', 'OldStatus', 'NewStatus'); Aliases = @{ 'Name' = @('Cluster', 'Name') } }
    'EVT_CLUSTER_BUILD_SUBMITTED' = @{ Keys = @('BuildId', 'Cluster', 'Project'); Aliases = @{} }
    'EVT_COORDINATOR_LEADER_ACQUIRED' = @{ Keys = @(); Aliases = @{} }
    'EVT_COORDINATOR_LEADER_RELEASED' = @{ Keys = @(); Aliases = @{} }
    'EVT_DISTRIBUTED_DISPATCH'  = @{ Keys = @('Tasks', 'Hosts', 'Concurrency'); Aliases = @{} }
}

function Get-EventPayloadField {
    <#
    .SYNOPSIS
        Reads one field from an event payload, honouring the alias table.
    .DESCRIPTION
        A handler that wants the step name should call
        Get-EventPayloadField -Data $data -Field 'StepName' rather than
        touching $data.StepName directly. This is what keeps a publisher/handler
        rename from silently producing an empty log line: the alias table is the
        contract, and a mismatch shows up in Test-BuildEventPayloadContract
        instead of in production telemetry.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]$Data,
        [Parameter(Mandatory)][string]$Field,
        [string]$EventName = '',
        $Default = $null
    )
    if ($null -eq $Data) { return $Default }

    $candidates = @($Field)
    if ($EventName -and $script:EventPayloadSchema.ContainsKey($EventName)) {
        $aliasMap = $script:EventPayloadSchema[$EventName].Aliases
        if ($aliasMap -and $aliasMap.ContainsKey($Field)) { $candidates = @($aliasMap[$Field]) }
    }
    foreach ($name in $candidates) {
        $value = Get-SectionValue -Section $Data -Key $name -Default $null
        if ($null -ne $value) { return $value }
    }
    return $Default
}

function Test-BuildEventPayloadContract {
    <#
    .SYNOPSIS
        Checks live publisher/handler field usage against the declared schema.
    .DESCRIPTION
        Static analysis over the shipped modules, run by the hygiene gate and by
        gbuild -SelfTest:
          * every $data.<Field> read inside a handler registered for event E
            must be a declared Key or Alias of E
          * every field a publisher passes in -Data @{...} for event E must be a
            declared Key of E
        Returns .Passed / .Offenders so a caller can fail a build on drift.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ModulesRoot = '',
        [string[]]$ExtraFiles = @()
    )
    if (-not $ModulesRoot) { $ModulesRoot = $PSScriptRoot }
    $offenders = [System.Collections.Generic.List[string]]::new()
    $schema = $script:EventPayloadSchema

    $files = @(
        Get-ChildItem -LiteralPath $ModulesRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.psm1' }
    )
    foreach ($extra in @($ExtraFiles)) {
        if (Test-Path -LiteralPath $extra -PathType Leaf) { $files += (Get-Item -LiteralPath $extra) }
    }
    $scanned = @()

    foreach ($f in $files) {
        $raw = try { Get-Content -LiteralPath $f.FullName -Raw } catch { continue }
        if (-not $raw) { continue }

        # Strip comments before analysing. Same methodology ProcessMetrics uses
        # for its adoption ratios: a comment is prose, and a gate that flags the
        # explanatory note attached to a fix is a gate that cries wolf. The
        # block-comment pass replaces content with blanks rather than deleting
        # it, so brace matching and line structure stay intact.
        $text = [regex]::Replace($raw, '(?s)<#.*?#>', { param($m) ($m.Value -replace '[^\r\n]', ' ') })
        $text = [regex]::Replace($text, '(?m)^\s*#.*$', '')
        $text = [regex]::Replace($text, '\s+#(?![{]).*$', '')

        # --- publisher side: -EventName $EVT_X ... -Data @{ k = ...; ... } ----
        foreach ($m in [regex]::Matches($text, '-EventName\s+\$?(EVT_[A-Z_]+)[^\r\n]*')) {
            $evt = $m.Groups[1].Value
            if (-not $schema.ContainsKey($evt)) { continue }
            $declared = @($schema[$evt].Keys)
            # Capture the -Data hashtable that belongs to this publish call.
            $tail = $text.Substring($m.Index, [Math]::Min(600, $text.Length - $m.Index))
            $dm = [regex]::Match($tail, '-Data\s*@\{(.*?)\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if (-not $dm.Success) { continue }
            foreach ($km in [regex]::Matches($dm.Groups[1].Value, '(?m)(?:^|[;\r\n])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
                $key = $km.Groups[1].Value
                if ($declared -notcontains $key) {
                    $offenders.Add("$($f.Name): publishes '$key' on $evt but the schema declares only $($declared -join ',')")
                }
            }
        }

        # --- handler side: $data.<Field> reads --------------------------------
        # Single-quoted on purpose: '$?' is a PowerShell automatic variable, so a
        # double-quoted pattern would interpolate it and produce a bogus regex.
        $handlerPattern = '-EventName\s+\$?(EVT_[A-Z_]+)\s+-Label[^\r\n]*?-Handler\s*\{(?<body>(?:[^{}]|\{[^{}]*\})*)\}'
        $handlerCount = 0
        foreach ($hm in [regex]::Matches($text, $handlerPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $evt = $hm.Groups[1].Value
            if (-not $schema.ContainsKey($evt)) { continue }
            $handlerCount++
            $keys = @($schema[$evt].Keys)
            $aliasKeys = @($schema[$evt].Aliases.Keys)
            $allowed = $keys + $aliasKeys
            foreach ($rm in [regex]::Matches($hm.Groups['body'].Value, '\$data\.([A-Za-z_][A-Za-z0-9_]*)')) {
                $field = $rm.Groups[1].Value
                if ($allowed -notcontains $field) {
                    $offenders.Add("$($f.Name): handler for $evt reads `$data.$field which is not declared (allowed: $(($allowed | Sort-Object) -join ', '))")
                } elseif ($keys -notcontains $field) {
                    # The field is a declared ALIAS, so no publisher sends it under
                    # that name. Reading `$data.<alias> directly bypasses the alias
                    # table and renders blank - which is exactly the bug the table
                    # exists to prevent. Require the resolver instead.
                    $offenders.Add("$($f.Name): handler for $evt reads `$data.$field directly, but that name is an alias (publishers send: $($keys -join ', ')). Use Get-EventPayloadField -EventName $evt -Field '$field'")
                }
            }
        }
        $scanned += @{ File = $f.Name; Handlers = $handlerCount }
        # A module that actually SUBSCRIBES but yielded no parsed handler is a
        # silent false pass. Keyed on a real call, not the word
        # 'Register-BuildEventSubscribers', which also appears in prose.
        if ($handlerCount -eq 0 -and $text -match '(?m)Add-BuildEvent\s+-EventName') {
            $offenders.Add("$($f.Name): calls Add-BuildEvent but the contract scanner could not parse a single handler body")
        }
    }

    $list = @($offenders | Sort-Object -Unique)
    $handlers = 0
    foreach ($s in @($scanned)) { $handlers += [int]$s.Handlers }
    return [PSCustomObject]@{
        Passed    = ($list.Count -eq 0)
        Offenders = $list
        Handlers  = $handlers
        Events    = $schema.Count
        Summary   = if ($list.Count -eq 0) { "$handlers handler(s) against $($schema.Count) event payload contracts OK" }
                    else { "$($list.Count) payload contract violation(s)" }
    }
}

Export-ModuleMember -Function @('Add-BuildEvent', 'Remove-BuildEvent', 'Send-BuildEvent', 'Get-BuildEventErrors', 'Get-BuildEventSubscribers', 'Get-BuildEventHandlers', 'Clear-BuildEvents', 'Get-BuildEventBus', 'Get-EventPayloadField', 'Test-BuildEventPayloadContract') -Variable @('EVT_BUILD_START', 'EVT_BUILD_COMPLETE', 'EVT_BUILD_ERROR', 'EVT_BUILD_WARNING', 'EVT_STEP_START', 'EVT_STEP_COMPLETE', 'EVT_STEP_ERROR', 'EVT_STEP_SKIPPED', 'EVT_STEP_PROGRESS', 'EVT_ON_ERROR', 'EVT_ON_RETRY', 'EVT_ON_ROLLBACK', 'EVT_PLUGIN_LOADED', 'EVT_PLUGIN_ERROR', 'EVT_CACHE_HIT', 'EVT_CACHE_MISS', 'EVT_CACHE_SYNC', 'EVT_TELEMETRY_RECORDED', 'EVT_DEPLOY_START', 'EVT_DEPLOY_COMPLETE', 'EVT_DEPLOY_ERROR', 'EVT_ANOMALY_DETECTED', 'EVT_TREND_DRIFT', 'EVT_FAILURE_RATE_DRIFT', 'EVT_AUTO_ROLLBACK', 'EVT_CORE_COMMANDS_MISSING', 'EVT_CORE_COMMANDS_REPAIRED', 'EVT_AUDIT_LEDGER_WRITE', 'EVT_CLUSTER_REGISTERED', 'EVT_CLUSTER_STATUS_CHANGED', 'EVT_CLUSTER_BUILD_SUBMITTED', 'EVT_COORDINATOR_LEADER_ACQUIRED', 'EVT_COORDINATOR_LEADER_RELEASED', 'EVT_DISTRIBUTED_DISPATCH')
