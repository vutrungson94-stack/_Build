# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/ErrorHandling.psm1 (Structured Error Management)
# ==================================================================================================
#
# Provides:
#   - Error taxonomy: Transient / Permanent / Configuration / Environment / User
#   - Auto-retry with exponential backoff
#   - Error aggregation (collect & report all errors)
#   - Structured error objects (Code, Category, Suggestion, Docs)
#   - Rollback support for partial builds
# ==================================================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# Import Logging first so Write-Log is available in this module's scope
$loggingPath = Join-Path $PSScriptRoot 'Logging.psm1'
$null = if (Test-Path $loggingPath) { Import-Module $loggingPath -DisableNameChecking -ErrorAction SilentlyContinue }
# Import BuildConstants for centralized defaults + SharedUtils for Get-BuildConstant wrapper
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildDefault'
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Invoke-EnsureDirectory'
$null = Import-GBuildModule -Names @('SharedUtils') -Force

# -- Module-scope variables ----------------------------------------------------------
$script:ErrorLog       = [System.Collections.Generic.List[hashtable]]::new()
$script:RollbackStack  = [System.Collections.Generic.List[hashtable]]::new()
$script:MaxRetries     = Get-BuildConstant -Key 'MaxRetries' -Fallback 3
$script:BaseDelayMs    = Get-BuildConstant -Key 'RetryBaseDelay' -Fallback 500

# -- Error category constants ---------------------------------------------------
$script:ErrorCategories = @{
    'Transient'     = 'Transient error (network, lock, I/O) - can retry'
    'Permanent'     = 'Permanent error (code, syntax) - DO NOT retry'
    'Configuration' = 'Config error (missing SDK, wrong port) - need to fix config'
    'Environment'   = 'Environment error (missing tool, permission) - needs installation'
    'User'          = 'User-caused error (wrong input, Ctrl+C)'
    'Unknown'       = 'Unclassified error'
}

# -- Operations whose failure is deterministic ----------------------------------
# A verification tool that reports a violation in the source produces the SAME
# verdict every time it runs, so retrying the enclosing step cannot change the
# outcome - it only multiplies the cost. The pipeline stamps the failing
# operation name onto $State.LastNonRetryableOperation before it throws, and
# Get-ErrorCategory consults this list to classify that failure as Permanent
# BEFORE the generic "failed with exit code" bucket can call it Transient.
#
# A lint or test tool that is genuinely unavailable, or a network flake while
# resolving packages, is a DIFFERENT error: those carry their own category from
# the earlier branches and are deliberately not in this list.
$script:NonRetryableOperations = @(
    'lint', 'test', 'format', 'analyze', 'sast', 'policy',
    'audit', 'compliance', 'supplychain', 'signing'
)

function Set-NonRetryableOperation {
    <#
    .SYNOPSIS
        Marks the operation currently executing as deterministic-on-failure.
    .DESCRIPTION
        Called by a pipeline step immediately before it throws a verification
        failure. The stamp lives on State because that is the only object
        guaranteed to reach Get-ErrorCategory, which is called from the catch
        block of Invoke-WithRetry far from the throwing site.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Operation,
        [switch]$Clear
    )

Set-StrictMode -Version 1.0
    if (-not $State) { return }
    try {
        if ($Clear) {
            $State | Add-Member -MemberType NoteProperty -Name 'LastNonRetryableOperation' -Value '' -Force -ErrorAction SilentlyContinue
            return
        }
        $State | Add-Member -MemberType NoteProperty -Name 'LastNonRetryableOperation' -Value ([string]$Operation) -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-ErrorCategoryInfo {
    param([string]$Category)
    if ($script:ErrorCategories.ContainsKey($Category)) { return $script:ErrorCategories[$Category] }
    return $script:ErrorCategories['Unknown']
}

# -- Classify error into category ---------------------------------------------
function Get-ErrorCategory {
    param(
        [object]$ErrorRecord,
        [PSCustomObject]$State = $null
    )

    if ($null -eq $ErrorRecord -or $ErrorRecord -isnot [System.Management.Automation.ErrorRecord]) { return 'Unknown' }

    $msg = $ErrorRecord.Exception.Message

    # Network/IO errors (transient) - but exclude dotnet build/publish failures which are permanent
    if ($msg -match '(?i)(network|timeout|connection|temporary|transient|retry|locked|access denied.*being used|sharing violation)') {
        return 'Transient'
    }
    # dotnet build/publish failed with exit code - treat as permanent (build errors don't self-heal)
    if ($msg -match '(?i)^(dotnet (publish|build|restore) failed with exit code)') {
        return 'Permanent'
    }
    # Lint / test / format tool failures are DETERMINISTIC: the tool found a
    # violation in the source, so re-running it produces the same verdict.
    # These were falling through to the generic bucket below, which classified
    # every one of them as Transient and made Invoke-WithRetry re-run the WHOLE
    # pipeline step three more times (re-selecting the target, re-detecting the
    # language and re-scanning ADB each time - roughly three wasted minutes on
    # an error that can never self-heal).
    #
    # Both the plugin dispatch path and PluginHelpers.psm1 emit the canonical
    # "Command failed with exit code N" wording for these, so the message alone
    # cannot tell a lint verdict from a network flake. The operations named in
    # $State.LastNonRetryableOperation are stamped by the pipeline step that
    # knows which tool it just ran; that is the only signal that can decide.
    if ($State -and ($State.PSObject.Properties.Name -contains 'LastNonRetryableOperation')) {
        if ($script:NonRetryableOperations -contains ([string]$State.LastNonRetryableOperation)) {
            return 'Permanent'
        }
    }
    # Generic "failed with exit code" for an UNKNOWN external process. Kept as
    # Transient because a genuinely flaky child process does exist, but it is
    # now the last-resort branch rather than the one that swallowed every lint
    # and test failure.
    if ($msg -match '(?i)failed with exit code') {
        return 'Transient'
    }

    # Configuration errors
    if ($msg -match '(?i)(not found|cannot find|missing|sdk.*not.*found|invalid.*config|launchSettings|NETSDK\d+)') {
        return 'Configuration'
    }

    # Environment errors
    if ($msg -match '(?i)(permission|unauthorized|admin|requires|elevation|environment)') {
        return 'Environment'
    }

    # User errors (cancelled, etc.)
    if ($msg -match '(?i)(user.*cancel|operation.*cancel|host.*disconnect)') {
        return 'User'
    }

    # Compile/code errors (permanent)
    if ($msg -match '(?i)(CS\d{4}:|MSB\d+:|NETSDK\d+:|syntax|compile error|csc\.exe|compiler)') {
        return 'Permanent'
    }

    return 'Unknown'
}

# -- Create structured error object -----------------------------------------------
function New-BuildError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [string]$Category = 'Unknown',

        [string]$Code = '',

        [string]$Suggestion = '',

        [string]$DocsLink = '',

        [hashtable]$Context = @{},
        [string[]]$RelatedFiles = @(),

        [object]$OriginalError = $null,

        [PSCustomObject]$State = $null
    )

    $err = @{
        Timestamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Message       = $Message
        Category      = $Category
        Code          = $Code
        Suggestion    = $Suggestion
        DocsLink      = $DocsLink
        RelatedFiles  = $RelatedFiles
        Context       = $Context
        StackTrace    = if ($OriginalError) { $OriginalError.ScriptStackTrace } else { '' }
        IsRetryable   = ($Category -eq 'Transient')
    }

    # Enrich context with correlation id and originating module when available
    if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId') {
        $err.Context['CorrelationId'] = $State.CorrelationId
    }
    try {
        $caller = (Get-PSCallStack)[1]
        if ($caller) {
            $mod = if ($caller.FunctionName -and $caller.FunctionName -notmatch '^<') { $caller.FunctionName }
                   elseif ($caller.ScriptName) { [System.IO.Path]::GetFileNameWithoutExtension($caller.ScriptName) }
                   else { $null }
            if ($mod) { $err.Context['Module'] = $mod }
        }
    } catch { # benign: Get-PSCallStack may fail in constrained runspaces
    }

    # Auto-classify if category is unclear
    if ($Category -eq 'Unknown' -and $OriginalError) {
        $err.Category = Get-ErrorCategory -ErrorRecord $OriginalError
        $err.IsRetryable = ($err.Category -eq 'Transient')
    }

    $script:ErrorLog.Add($err) | Out-Null
    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        Send-BuildEvent -EventName $EVT_ON_ERROR -Source $State -Data @{ Error = $err } | Out-Null
    }
    return $err
}

# -- Retry with exponential backoff ---------------------------------------------
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Action,

        [string]$OperationName = 'Operation',

        [int]$MaxRetries = (Get-BuildDefault -Key 'MaxRetries' -Fallback 3),

        [int]$BaseDelayMs = (Get-BuildDefault -Key 'RetryBaseDelay' -Fallback 500),

        [int]$MaxDelayMs = (Get-BuildConstant -Key 'RetryMaxDelayMs' -Fallback 10000),

        [int]$TotalTimeoutSec = 0,

        [PSCustomObject]$State = $null
    )

    # Allow config-driven retry tuning via BuildConfig.errorHandling
    $eh = Get-ConfigSection -State $State -Path 'errorHandling'
    if ($eh) {
        if ($eh.PSObject.Properties.Name -contains 'maxRetries') { $MaxRetries = $eh.maxRetries }
        if ($eh.PSObject.Properties.Name -contains 'baseDelayMs') { $BaseDelayMs = $eh.baseDelayMs }
        if ($eh.PSObject.Properties.Name -contains 'maxDelayMs') { $MaxDelayMs = $eh.maxDelayMs }
        if ($eh.PSObject.Properties.Name -contains 'retryTimeoutSec') { $TotalTimeoutSec = $eh.retryTimeoutSec }
    }
    # Chaos drill hook: RetryExhausted scenario arms $State.ChaosRetryOverride
    # (Chaos.psm1). Honored here so the fault exercises this real retry path.
    if ($State -and ($State.PSObject.Properties.Name -contains 'ChaosRetryOverride') -and $null -ne $State.ChaosRetryOverride) {
        $MaxRetries = [int]$State.ChaosRetryOverride
    }
    $logState = Get-BuildState -State $State

    $attempt = 0
    $lastError = $null
    $start = Get-Date

    while ($attempt -le $MaxRetries) {
        try {
            # Clear the deterministic-operation stamp at the START of each
            # attempt. The step that wants it re-stamps it before it throws, so
            # a stamp left behind by a previous attempt can never mis-classify
            # this one.
            Set-NonRetryableOperation -State $State -Operation '' -Clear
            $result = & $Action
            if ($attempt -gt 0) {
    Write-Log (Resolve-LogMessage -Key 'log.error.retrySucceeded' -MessageArgs @([string]$OperationName, [string]$attempt) -Fallback '[{0}] Succeeded after {1} retry(ies)') "Succ" $logState
            }
            return $result
        }
        catch {
            $lastError = $_
            $attempt++

            $category = Get-ErrorCategory -ErrorRecord $_ -State $State
            $isRetryable = ($category -eq 'Transient')

            if ($TotalTimeoutSec -gt 0 -and (Get-ElapsedSeconds $start) -ge $TotalTimeoutSec) {
    Write-Log (Resolve-LogMessage -Key 'log.error.timedOut' -MessageArgs @([string]$OperationName, [string]$TotalTimeoutSec) -Fallback '[{0}] Timed out after {1} s') "Err" $logState
                # $null = : New-BuildError returns the error hashtable, and this
                # call site discarded it. Bare, the hashtable escaped onto the
                # success stream and PowerShell's default formatter rendered it
                # as a Name/Value table in the middle of the build output.
                $null = New-BuildError -Message "$OperationName timed out" -Category 'Transient' `
                    -OriginalError $_ -State $State -Context @{ Operation = $OperationName; Attempt = $attempt }
                throw
            }

            if (-not $isRetryable -or $attempt -gt $MaxRetries) {
                # The two reasons to stop are DIFFERENT and the old single
                # message conflated them, so an exhausted-transient failure
                # printed the self-contradictory
                #   "Failed (non-retryable - Transient)"
                # Report which one actually applies.
                $reason = if (-not $isRetryable) { "not retryable - $category" }
                          else { "retry budget exhausted after $MaxRetries attempt(s) - last category $category" }
    Write-Log (Resolve-LogMessage -Key 'log.error.failed' -MessageArgs @([string]$OperationName, [string]$reason, [string]$_.Exception.Message) -Fallback '[{0}] Failed ({1}): {2}') "Err" $logState
                $null = New-BuildError -Message "$OperationName failed" -Category $category `
                    -OriginalError $_ -State $State -Context @{ Operation = $OperationName; Attempt = $attempt }
                throw
            }

            # Exponential backoff: 500ms, 1s, 2s, 4s, ...
            $delay = [Math]::Min($BaseDelayMs * [Math]::Pow(2, $attempt - 1), $MaxDelayMs)
    Write-Log (Resolve-LogMessage -Key 'log.error.transientRetry' -MessageArgs @([string]$OperationName, [string]$attempt, [string]$MaxRetries, [string]$delay) -Fallback '[{0}] Transient error (attempt {1}/{2}). Retry after {3}ms...') "Warn" $logState
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_ON_RETRY -Source $logState -Data @{ Operation = $OperationName; Attempt = $attempt; MaxRetries = $MaxRetries; DelayMs = $delay; Error = $lastError.Exception.Message } | Out-Null
            }
            Start-Sleep -Milliseconds $delay
        }
    }

    # Should not reach here
    throw $lastError
}

function Invoke-HistoryWriteWithRetry {
    <#
    .SYNOPSIS
        Retries one history read-modify-write action with linear backoff.
    .DESCRIPTION
        Narrow companion to Invoke-WithRetry, not a second general retry
        owner. History persistence must retry EVERY failure (including lock
        contention whose error category is not necessarily Transient), make
        exactly three attempts by default, wait 100 ms then 200 ms, and return
        $false when the final attempt fails. Using the general retry helper
        here would change all three behaviors: it makes four attempts with
        MaxRetries=3, only retries Transient errors, uses exponential delays,
        and throws instead of returning $false.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$OperationName = 'history write',
        [int]$MaxAttempts = 0,
        [int]$BaseDelayMs = 0
    )
    if ($MaxAttempts -le 0) {
        $MaxAttempts = 3
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            try { $MaxAttempts = [int](Get-BuildDefault -Key 'HistoryWriteMaxAttempts' -Fallback 3) } catch { }
        }
        if ($MaxAttempts -le 0) { $MaxAttempts = 3 }
    }
    if ($BaseDelayMs -le 0) {
        $BaseDelayMs = 100
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            try { $BaseDelayMs = [int](Get-BuildDefault -Key 'HistoryWriteRetryDelayMs' -Fallback 100) } catch { }
        }
        if ($BaseDelayMs -le 0) { $BaseDelayMs = 100 }
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Action)
        } catch {
            if ($attempt -ge $MaxAttempts) { return $false }
            Start-Sleep -Milliseconds ($BaseDelayMs * $attempt)
        }
    }
    return $false
}

# -- Circuit breaker -----------------------------------------------------------
$script:CircuitBreaker = @{
    State           = 'Closed'
    FailureCount    = 0
    SuccessCount    = 0
    LastFailureTime = $null
    LastStateChange = Get-Date
    Configured      = $false
    Threshold       = (Get-BuildConstant -Key 'CircuitBreakerThreshold' -Fallback 5)
    ResetTimeoutMs  = (Get-BuildConstant -Key 'CircuitBreakerResetMs' -Fallback 60000)
}

function Initialize-CircuitBreaker {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $eh = Get-ConfigSection -State $State -Path 'errorHandling'
    if ($eh) {
        $cb = $eh.circuitBreaker
        if ($cb) {
            if ($cb.PSObject.Properties.Name -contains 'failureThreshold') { $script:CircuitBreaker.Threshold = $cb.failureThreshold }
            if ($cb.PSObject.Properties.Name -contains 'resetTimeoutMs')   { $script:CircuitBreaker.ResetTimeoutMs = $cb.resetTimeoutMs }
            $script:CircuitBreaker.Configured = [bool]($cb.PSObject.Properties.Name -contains 'enabled' -and $cb.enabled)
        }
    }
    if ($script:CircuitBreaker.Configured) {
        Restore-CircuitBreakerState -State $State
    }
    Save-CircuitBreakerStateIfEnabled -State $State
    return $script:CircuitBreaker
}

function Get-CircuitBreakerState {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State = $null
    )

    $now = Get-Date
    if ($script:CircuitBreaker.State -eq 'Open') {
        $elapsed = ($now - $script:CircuitBreaker.LastStateChange).TotalMilliseconds
        if ($elapsed -ge $script:CircuitBreaker.ResetTimeoutMs) {
            $script:CircuitBreaker.State = 'HalfOpen'
            $script:CircuitBreaker.LastStateChange = $now
        Write-Log (Resolve-LogMessage -Key 'log.circuit.openingTest' -Fallback '[CIRCUIT] Opening test (HalfOpen)') "Warn" (Get-BuildState -State $State)
            Save-CircuitBreakerStateIfEnabled -State (Get-BuildState -State $State)
        }
    }
    return $script:CircuitBreaker
}

function Invoke-WithCircuitBreaker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Action,

        [string]$OperationName = 'Operation',

        [PSCustomObject]$State = $null
    )

    $logState = Get-BuildState -State $State

    if ($State) { Initialize-CircuitBreaker -State $State | Out-Null }

    if (-not $script:CircuitBreaker.Configured) {
        return & $Action
    }

    $cb = Get-CircuitBreakerState -State $State
    if ($cb.State -eq 'Open') {
        Write-Log (Resolve-LogMessage -Key 'log.circuit.openSkipping' -MessageArgs @([string]$OperationName) -Fallback '[CIRCUIT] Circuit is OPEN - skipping ''{0}''') "Err" $logState
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.errorhandling.line446' -Fallback "Circuit breaker OPEN for '$OperationName'"))
    }

    try {
        $result = & $Action
        $script:CircuitBreaker.SuccessCount++
        if ($script:CircuitBreaker.State -eq 'HalfOpen') {
            $script:CircuitBreaker.State = 'Closed'
            $script:CircuitBreaker.FailureCount = 0
            $script:CircuitBreaker.LastStateChange = Get-Date
        Write-Log (Resolve-LogMessage -Key 'log.circuit.halfOpenClosed' -Fallback '[CIRCUIT] HalfOpen succeeded - closing circuit') "Succ" $logState
            Save-CircuitBreakerStateIfEnabled -State $logState
        }
        return $result
    }
    catch {
        $script:CircuitBreaker.FailureCount++
        $script:CircuitBreaker.LastFailureTime = Get-Date
        if ($script:CircuitBreaker.State -eq 'HalfOpen') {
            $script:CircuitBreaker.State = 'Open'
            $script:CircuitBreaker.LastStateChange = Get-Date
        Write-Log (Resolve-LogMessage -Key 'log.circuit.halfOpenOpened' -Fallback '[CIRCUIT] HalfOpen failed - opening circuit') "Err" $logState
            Save-CircuitBreakerStateIfEnabled -State $logState
        }
        elseif ($script:CircuitBreaker.FailureCount -ge $script:CircuitBreaker.Threshold) {
            $script:CircuitBreaker.State = 'Open'
            $script:CircuitBreaker.LastStateChange = Get-Date
        Write-Log (Resolve-LogMessage -Key 'log.circuit.thresholdReached' -MessageArgs @([string]$script:CircuitBreaker.FailureCount) -Fallback '[CIRCUIT] Reached error threshold ({0}) - opening circuit') "Err" $logState
            Save-CircuitBreakerStateIfEnabled -State $logState
        }
        throw
    }
}

function Reset-CircuitBreaker {
    [CmdletBinding()]
    param()

    $script:CircuitBreaker.State = 'Closed'
    $script:CircuitBreaker.FailureCount = 0
    $script:CircuitBreaker.SuccessCount = 0
    $script:CircuitBreaker.LastFailureTime = $null
    $script:CircuitBreaker.LastStateChange = Get-Date
    Save-CircuitBreakerStateIfEnabled -State $null
}

# -- Circuit breaker state persistence ----------------------------------------
function Get-CircuitBreakerStateFilePath {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    # Never fall back to '.' : that anchors the persisted breaker state to the
    # PROCESS current directory, so two builds sharing a CWD cross-contaminate
    # and an operator gets a stray .gbuild-circuitbreaker.gbuildstate dropped in
    # whatever directory the launcher happened to run from. Fail closed instead.
    if ($State -and $State.ScriptRoot) { $root = [string]$State.ScriptRoot }
    elseif ($State -and $State.ProjectRoot) { $root = [string]$State.ProjectRoot }
    else { return $null }
    if ([string]::IsNullOrWhiteSpace($root) -or -not [System.IO.Path]::IsPathRooted($root)) { return $null }
    return Join-Path $root '.gbuild-circuitbreaker.gbuildstate'
}

function Save-CircuitBreakerState {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = Get-CircuitBreakerStateFilePath -State $State }
    # No rooted root available (State was $null, e.g. Reset-CircuitBreaker):
    # skip persistence rather than dropping a state file in the CWD.
    if ([string]::IsNullOrEmpty($Path)) { return $false }

    $dir = Split-Path -Parent $Path
    if ($dir) {
        # Level 5 resilience: Invoke-EnsureDirectory (PathUtils) may be missing
        # when a nested -Force re-import orphaned the global module on PS 5.1.
        # Guard + New-Item fallback so state persistence never FATals the build.
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $dir) }
        elseif (-not (Test-Path $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    }

    try {
        $data = [PSCustomObject]@{
            CircuitBreaker = $script:CircuitBreaker
            SavedAt        = (Get-Date).ToString('o')
        }
        # Same atomic+locked rule as Save-BuildState: in-place Export-Clixml
        # interleaves under concurrent writers.
        $lock = $null
        try {
            if (Get-Command Enter-BuildFileLock -ErrorAction SilentlyContinue) {
                try { $lock = Enter-BuildFileLock -Path $Path -TimeoutMs 5000 } catch { $lock = $null }
            }
        } catch { $lock = $null }
        $tmpPath = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
        try {
            # CLIXML is binary, so Write-BuildTextFileAtomic does not apply; the
            # temp-write-then-replace is what does. The MOVE is delegated to
            # SharedUtils.Move-BuildFileAtomic, which owns the staged-replacement
            # contract (existence check, parent creation, atomic File.Replace,
            # GUID-named backup deleted afterwards, concurrent-create retry).
            #
            # The private copy this replaces was a bare Move-Item -Force: no
            # backup, so a failure mid-move left the destination ABSENT rather
            # than restored. These two functions write the circuit-breaker and
            # build-state files, which is exactly the content a later run trusts
            # to be intact.
            #
            # This block was byte-identical in both functions, which is why the
            # change applies to each.
            $data | Export-Clixml -Path $tmpPath -Force
            if (Get-Command Move-BuildFileAtomic -ErrorAction SilentlyContinue) {
                if (-not (Move-BuildFileAtomic -Source $tmpPath -Destination $Path)) {
                    throw (Resolve-LogMessage -Key 'log.error.atomicMoveFailed' -MessageArgs @($Path) -Fallback 'Atomic move failed for {0}')
                }
            } else {
                Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
            }
        } finally {
            try { if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue } } catch { }
            try { if ($lock) { $lock.Dispose() } } catch { }
        }
        return $true
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.circuit.persistFailed' -MessageArgs @([string][string]$_) -Fallback '[CIRCUIT] Failed to persist breaker state: {0}') "Warn" $State
        }
        return $false
    }
}

function Restore-CircuitBreakerState {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        $eh = Get-ConfigSection -State $State -Path 'errorHandling'
        if ($eh) {
            $cb = $eh.circuitBreaker
            if ($cb -and $cb.PSObject.Properties.Name -contains 'statePath' -and $cb.statePath) {
                $Path = $cb.statePath
            }
        }
        if ([string]::IsNullOrEmpty($Path)) { $Path = Get-CircuitBreakerStateFilePath -State $State }
    }
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        $data = Import-Clixml -LiteralPath $Path
        if ($data -and $data.CircuitBreaker) {
            $src = $data.CircuitBreaker
            foreach ($prop in $src.PSObject.Properties) {
                if ($script:CircuitBreaker.ContainsKey($prop.Name)) {
                    $script:CircuitBreaker[$prop.Name] = $prop.Value
                }
            }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.circuit.stateRestored' -MessageArgs @([string]$script:CircuitBreaker.State, [string]$data.SavedAt) -Fallback '[CIRCUIT] Restored breaker state ({0}) saved {1}') "Info" $State
            }
            return $true
        }
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.circuit.restoreFailed' -MessageArgs @([string][string]$_) -Fallback '[CIRCUIT] Failed to restore breaker state: {0}') "Warn" $State
        }
    }
    return $false
}

function Save-CircuitBreakerStateIfEnabled {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $cb = Get-ConfigSection -State $State -Path 'errorHandling'
    if ($cb) {
        $cb = $cb.circuitBreaker
    }
    if (-not $cb) { return }
    if (-not ($cb.PSObject.Properties.Name -contains 'persistState') -or -not $cb.persistState) { return }

    $path = if ($cb.PSObject.Properties.Name -contains 'statePath' -and $cb.statePath) {
        $cb.statePath
    } else {
        Get-CircuitBreakerStateFilePath -State $State
    }
    Save-CircuitBreakerState -State $State -Path $path | Out-Null
}

# -- Rollback registry ---------------------------------------------------------
function Register-RollbackAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [scriptblock]$Action,

        [hashtable]$Context = @{}
    )

    $script:RollbackStack.Add(@{
        Name     = $Name
        Action   = $Action
        Context  = $Context
    }) | Out-Null
}

function Invoke-Rollback {
    [CmdletBinding()]
    param(
        [string]$Reason = 'Build failed',

        [PSCustomObject]$State
    )

    if ($script:RollbackStack.Count -eq 0) {
        Write-Log (Resolve-LogMessage -Key 'log.rollback.none' -Fallback 'No rollback actions to execute') "Info" $State
        return
    }

        Write-Log (Resolve-LogMessage -Key 'log.rollback.starting' -MessageArgs @([string]$script:RollbackStack.Count, [string]$Reason) -Fallback 'Starting rollback ({0} actions) - Reason: {1}') "Warn" $State

    # Execute in REVERSE order (LIFO)
    $i = $script:RollbackStack.Count - 1
    $successCount = 0
    $failCount = 0

    while ($i -ge 0) {
        $rollback = $script:RollbackStack[$i]
        try {
            Write-Log (Resolve-LogMessage -Key 'log.rollback.action' -MessageArgs @([string][string]$rollback.Name) -Fallback 'Rollback: {0}') "Info" $State
            $rbAction = $rollback.Action
            $rbCtx = $rollback.Context
            if ($null -eq $rbCtx) { $rbCtx = @{} }
            & $rbAction $rbCtx
            $successCount++
        }
        catch {
            Write-Log (Resolve-LogMessage -Key 'log.rollback.actionFailed' -MessageArgs @([string][string]$rollback.Name, [string]$_.Exception.Message) -Fallback 'Rollback ''{0}'' failed: {1}') "Err" $State
            $failCount++
        }
        $i--
    }

        Write-Log (Resolve-LogMessage -Key 'log.rollback.complete' -MessageArgs @([string][string]$successCount, [string]$failCount) -Fallback 'Rollback complete: {0} succeeded, {1} failed') "Info" $State
    $script:RollbackStack.Clear()
}

function Clear-RollbackStack {
    $script:RollbackStack.Clear()
}

# -- State persistence ---------------------------------------------------------
function Get-StateFilePath {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    # Never fall back to '.' : it anchors the persisted build state to the
    # PROCESS current directory, which litters the launch directory (a stray
    # .gbuild-state.gbuildstate was observed at the filesystem root) and makes
    # the state file location depend on how the launcher was invoked. Fail
    # closed instead so the caller keeps the explicit -Path it was given.
    if ($State -and $State.ProjectRoot) { $root = [string]$State.ProjectRoot }
    elseif ($State -and $State.ScriptRoot) { $root = [string]$State.ScriptRoot }
    else { return $null }
    if ([string]::IsNullOrWhiteSpace($root) -or -not [System.IO.Path]::IsPathRooted($root)) { return $null }
    return Join-Path $root '.gbuild-state.gbuildstate'
}

function Save-BuildState {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Path,
        # L5 resume support. The payload used to carry no completion marker and no
        # schema version, so a state file left behind by a CRASHED run was
        # indistinguishable from one written by a run that finished - and nothing
        # ever read the file anyway. Callers now checkpoint with -Completed:$false
        # and stamp -Completed:$true from the pipeline's finally block, which is
        # what makes Restore-BuildState able to report an interrupted build.
        [bool]$Completed = $true
    )

    if (-not $State) { return $false }
    if ([string]::IsNullOrEmpty($Path)) { $Path = Get-StateFilePath -State $State }
    # No resolvable root and no explicit -Path: refuse to guess. Writing to the
    # CWD is exactly the leak this guard exists to stop.
    if ([string]::IsNullOrEmpty($Path)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.state.skippedNoRoot' -Fallback '[STATE] Skipped: no rooted ProjectRoot/ScriptRoot to persist into') "Warn" $State }
        return $false
    }

    $dir = Split-Path -Parent $Path
    if ($dir) {
        # Level 5 resilience: same guard as Save-CircuitBreakerState above —
        # a PS 5.1 orphaned PathUtils must degrade to New-Item, never FATAL.
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $dir) }
        elseif (-not (Test-Path $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    }

    try {
        # Persist paths relative to the state file directory so the project can
        # be moved/copied to another machine without breaking absolute paths.
        #
        # The anchor MUST be the state file's own directory, because that is what
        # Restore-BuildState re-joins against. Resolve-Path -Relative anchors on
        # the PROCESS current directory instead, so a save from CWD=X and a
        # restore from CWD=Y round-tripped a different path (e.g. '..\'), and the
        # restored ScriptRoot then resolved the Locale per-device cache into an
        # unrelated tree (observed as F:\.gbuild\locale.json when the launcher
        # happened to run from F:\). GetRelativePath anchors explicitly.
        $anchor = try { [System.IO.Path]::GetFullPath((Split-Path -Parent ([System.IO.Path]::GetFullPath($Path)))) }
                  catch { $null }
        if (-not $anchor) { $anchor = (Get-Location).ProviderPath }
        $stateCopy = $State.PSObject.Copy()
        foreach ($prop in @('ScriptRoot', 'ProjectRoot', 'WorkingDir')) {
            if ($stateCopy.PSObject.Properties.Name -contains $prop) {
                $abs = $stateCopy.$prop
                if ($abs -and (Test-Path -LiteralPath $abs -ErrorAction SilentlyContinue)) {
                    $rel = $null
                    try {
                        $absFull = [System.IO.Path]::GetFullPath([string]$abs)
                        $rel = [System.IO.Path]::GetRelativePath($anchor, $absFull)
                    } catch { $rel = $null }
                    # Never persist a path that is absolute or escapes the anchor:
                    # those are the only shapes Restore-BuildState cannot rejoin
                    # correctly. Fall back to keeping the absolute value.
                    if ($rel -and -not [System.IO.Path]::IsPathRooted($rel) -and
                        $rel -notmatch '^[\\/]?\.([\\/]|$)' -and
                        $rel -notmatch '^[\\/]?\.\.([\\/]|$)') {
                        $stateCopy.$prop = $rel
                    }
                }
            }
        }
        $data = [PSCustomObject]@{
            # SCHEMA VERSION. The payload was unversioned, so a future field
            # rename could not be told apart from an old file. 0 is reserved for
            # payloads written before this key existed; Restore-BuildState
            # normalises a missing value to 0 rather than failing.
            SchemaVersion = 1
            State   = $stateCopy
            Errors  = @($script:ErrorLog)
            SavedAt = (Get-Date).ToString('o')
            Completed = [bool]$Completed
        }
        # Atomic + locked. Export-Clixml -Force writes in place: two concurrent
        # builds truncated/interleaved each other's state file, and Restore then
        # swallowed the parse failure and returned $null - permanently degrading
        # crash/resume detection with no repair. Write to a unique temp file and
        # Move (atomic on one volume) under the shared file lock when available.
        $lock = $null
        try {
            if (Get-Command Enter-BuildFileLock -ErrorAction SilentlyContinue) {
                try { $lock = Enter-BuildFileLock -Path $Path -TimeoutMs 5000 } catch { $lock = $null }
            }
        } catch { $lock = $null }
        $tmpPath = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
        try {
            # CLIXML is binary, so Write-BuildTextFileAtomic does not apply; the
            # temp-write-then-replace is what does. The MOVE is delegated to
            # SharedUtils.Move-BuildFileAtomic, which owns the staged-replacement
            # contract (existence check, parent creation, atomic File.Replace,
            # GUID-named backup deleted afterwards, concurrent-create retry).
            #
            # The private copy this replaces was a bare Move-Item -Force: no
            # backup, so a failure mid-move left the destination ABSENT rather
            # than restored. These two functions write the circuit-breaker and
            # build-state files, which is exactly the content a later run trusts
            # to be intact.
            #
            # This block was byte-identical in both functions, which is why the
            # change applies to each.
            $data | Export-Clixml -Path $tmpPath -Force
            if (Get-Command Move-BuildFileAtomic -ErrorAction SilentlyContinue) {
                if (-not (Move-BuildFileAtomic -Source $tmpPath -Destination $Path)) {
                    throw (Resolve-LogMessage -Key 'log.error.atomicMoveFailed' -MessageArgs @($Path) -Fallback 'Atomic move failed for {0}')
                }
            } else {
                Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
            }
        } finally {
            try { if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue } } catch { }
            try { if ($lock) { $lock.Dispose() } } catch { }
        }
        return $true
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.state.saveFailed' -MessageArgs @([string][string]$_) -Fallback '[STATE] Failed to save build state: {0}') "Err" $State
        }
        return $false
    }
}

function Restore-BuildState {
    [CmdletBinding()]
    param(
        [string]$Path,
        [PSCustomObject]$State = $null
    )

    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }

    # Reset the restored-run facts so a failed read cannot leak the PREVIOUS
    # successful restore's verdict into this one.
    $script:RestoredStateSchemaVersion = $null
    $script:RestoredStateCompleted = $null
    $script:RestoredStateSavedAt = $null
    $script:RestoredErrorCount = 0

    try {
        $data = Import-Clixml -LiteralPath $Path
        if ($data -and $data.State) {
            # Normalise the version. Payloads written before SchemaVersion existed
            # simply lack the property; treating that as 0 keeps them readable
            # instead of failing an unknown-version check on a file we ourselves
            # produced. A payload from a NEWER major version is refused rather than
            # half-interpreted, because its field meanings are not guaranteed.
            $version = 0
            if ($data.PSObject.Properties.Name -contains 'SchemaVersion' -and $null -ne $data.SchemaVersion) {
                try { $version = [int]$data.SchemaVersion } catch { $version = 0 }
            }
            $script:RestoredStateSchemaVersion = $version
            $script:RestoredStateCompleted = $true
            if ($data.PSObject.Properties.Name -contains 'Completed' -and $null -ne $data.Completed) {
                $script:RestoredStateCompleted = [bool]$data.Completed
            } else {
                # A pre-Completed payload cannot prove the run finished, so it is
                # reported as incomplete rather than optimistically assumed good.
                $script:RestoredStateCompleted = $false
            }
            $script:RestoredStateSavedAt = [string]$data.SavedAt
            $anchor = Split-Path -Parent $Path
            foreach ($prop in @('ScriptRoot', 'ProjectRoot', 'WorkingDir')) {
                if ($data.State.PSObject.Properties.Name -contains $prop) {
                    $p = $data.State.$prop
                    if ($p -and -not [System.IO.Path]::IsPathRooted($p)) {
                        $abs = Join-Path $anchor $p
                        if (Test-Path -LiteralPath $abs -ErrorAction SilentlyContinue) {
                            # Normalize: a persisted '..\' re-joined onto the
                            # anchor yields 'F:\..\', which still string-matches
                            # Test-Path but resolves to an unrelated tree. Fold
                            # every '.'/'..' segment away so the value is a
                            # canonical absolute path.
                            try { $abs = [System.IO.Path]::GetFullPath($abs) } catch { }
                            $data.State.$prop = $abs
                        }
                    }
                }
            }
            # Previous-run errors are NOT injected into the live error log.
            # They used to be restored here, which leaked them into every
            # subsequent run: Write-TelemetryEntry counts the live log, so a
            # successful build published {"Status":"Success","ErrorCount":2}
            # inherited from a run that happened before it. Per-run accounting
            # must start from zero; the restored facts stay in the state file
            # for checkpoint/resume purposes without becoming this run's errors.
            if ($data.Errors) {
                try { $script:RestoredErrorCount = [int]@($data.Errors).Count } catch { $script:RestoredErrorCount = 0 }
            } else { $script:RestoredErrorCount = 0 }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                $logState = if ($State) { $State } else { $data.State }
        Write-Log (Resolve-LogMessage -Key 'log.state.restored' -MessageArgs @([string][string]$data.SavedAt) -Fallback '[STATE] Restored build state (saved {0})') "Info" $logState
            }
            return $data.State
        }
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.state.restoreFailed' -MessageArgs @([string][string]$_) -Fallback '[STATE] Failed to restore build state: {0}') "Err" $State
        }
    }
    return $null
}

function Get-RestoredStateInfo {
    <#
    .SYNOPSIS
        Facts about the state file Restore-BuildState last read.
    .DESCRIPTION
        Restore-BuildState returns the State object, which carries no verdict of
        its own. A caller therefore cannot tell a completed previous run from one
        that was interrupted - the difference between "last build was fine" and
        "last build died mid-pipeline and left the tree half-written". This exposes
        the marker Save-BuildState writes so the resume path can report it.
        Returns $null when nothing has been restored in this process.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    if ($null -eq $script:RestoredStateSavedAt) { return $null }
    # PreviousErrorCount completes the accessor. Restore-BuildState deliberately
    # refuses to inject a previous run's errors into the LIVE log (per-run
    # accounting must start from zero), which meant the count it parsed out of
    # the payload landed in $script:RestoredErrorCount and was then read by
    # nothing at all: persisted, parsed, and dropped. A resume banner can say
    # "the last run died with 3 errors" only if the number survives the read, so
    # the accessor - the single documented way to learn what was restored -
    # carries it. Nothing here re-enters the live log; this is a fact ABOUT the
    # restored file, never a contribution to the current run.
    return [PSCustomObject]@{
        SchemaVersion      = $script:RestoredStateSchemaVersion
        SavedAt            = $script:RestoredStateSavedAt
        Completed          = [bool]$script:RestoredStateCompleted
        PreviousErrorCount = [int]$script:RestoredErrorCount
    }
}

# -- Error aggregation & reporting ---------------------------------------------
function Get-ErrorSummary {
    $groups = $script:ErrorLog | Group-Object -Property { $_.Category }
    $summary = @{
        Total    = $script:ErrorLog.Count
        ByCategory = @{}
        Errors   = @($script:ErrorLog)
    }

    foreach ($g in $groups) {
        $summary.ByCategory[$g.Name] = @{
            Count       = $g.Count
            Description = Get-ErrorCategoryInfo -Category $g.Name
            Errors      = @($g.Group)
        }
    }

    return $summary
}

function Show-ErrorReport {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [switch]$AsJson
    )

    $summary = Get-ErrorSummary

    if ($summary.Total -eq 0) {
    Write-Log (Resolve-LogMessage -Key 'log.error.noneRecorded' -Fallback 'No errors recorded') "Succ" $State
        return
    }

    if ($AsJson) {
        $summary | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonShallowDepth' -Fallback 5) } else { 5 })
        return
    }

    Write-SectionBox "?? ERROR SUMMARY REPORT" -Color "Warn" -State $State
    Write-Log (Resolve-LogMessage -Key 'log.error.totalCount' -MessageArgs @([string][string]$summary.Total) -Fallback 'Total errors: {0}') "Warn" $State

    foreach ($category in $summary.ByCategory.Keys | Sort-Object) {
        $info = $summary.ByCategory[$category]
        Write-Log ' ' "White" $State
    Write-Log (Resolve-LogMessage -Key 'log.error.categoryCount' -MessageArgs @([string][string]$category, [string]$info.Count) -Fallback '[{0}] {1} errors') "Err" $State
        Write-Log "    $($info.Description)" "Gray" $State
        foreach ($err in $info.Errors | Select-Object -First 3) {
            Write-Log "      -> $($err.Message)" "Gray" $State
        if ($err.RelatedFiles -and $err.RelatedFiles.Count -gt 0) {
            Write-Log (Resolve-LogMessage -Key 'log.error.relatedFiles' -MessageArgs @([string]($err.RelatedFiles -join ', ')) -Fallback 'Related: {0}') "Gray" $State
        }
            if ($err.Suggestion) {
                Write-Log "        ?? $($err.Suggestion)" "Cyan" $State
            }
        }
        if ($info.Errors.Count -gt 3) {
    Write-Log (Resolve-LogMessage -Key 'log.error.andMore' -MessageArgs @([string][string]($info.Errors.Count - 3)) -Fallback '... and {0} other errors') "Gray" $State
        }
    }
}

# -- Quick helpers (shortcuts) -------------------------------------------------
function Write-ErrorStructured {
    [CmdletBinding()]
    param(
        [string]$Message,
        [string]$Category = 'Unknown',
        [string]$Suggestion = '',
        [string]$Code = '',
        [PSCustomObject]$State
    )

    $err = New-BuildError -Message $Message -Category $Category -Code $Code -Suggestion $Suggestion

    $color = switch ($Category) {
        'Transient'     { 'Warn' }
        'Permanent'     { 'Err' }
        'Configuration' { 'Err' }
        'Environment'   { 'Err' }
        default         { 'Err' }
    }

    Write-Log (Resolve-LogMessage -Key 'log.error.message' -MessageArgs @([string]$Message) -Fallback '[ERROR] {0}') $color $State
    if ($Suggestion) {
    Write-Log (Resolve-LogMessage -Key 'log.error.suggestion' -MessageArgs @([string][string]$Suggestion) -Fallback 'Suggestion: {0}') "Info" $State
    }
    if ($Code) {
    Write-Log (Resolve-LogMessage -Key 'log.error.code' -MessageArgs @([string][string]$Code) -Fallback 'Error code: {0}') "Gray" $State
    }

    return $err
}

function Reset-ErrorLog {
    $script:ErrorLog.Clear()
    Clear-RollbackStack
}

# -- DI service facade (B3) --------------------------------------------------
<#
.SYNOPSIS
    Returns a stable service-handle for error-handling functions (DI resolution).
.DESCRIPTION
    Used by modules that resolve core services via Container.psm1's
    Resolve-Service. Wraps the public error-handling functions so callers can
    depend on a contract rather than the mutable $global:GState / script scope.
.OUTPUTS
    PSCustomObject with delegates to the error-handling functions.
#>
function Get-ErrorHandlingService {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        NewBuildError            = { param($m, $cat, $s) New-BuildError -Message $m -Category $cat -Suggestion $s }
        WriteErrorStructured     = { param($m, $cat, $st) Write-ErrorStructured -Message $m -Category $cat -State $st }
        InvokeWithRetry          = { param($sb, $op, $st) Invoke-WithRetry -Action $sb -OperationName $op -State $st }
        RegisterRollbackAction   = { param($n, $sb, $ctx) Register-RollbackAction -Name $n -Action $sb -Context $ctx }
        InvokeRollback           = { param($st, $r) Invoke-Rollback -State $st -Reason $r }
        InitializeCircuitBreaker = { param($st) Initialize-CircuitBreaker -State $st }
        GetCircuitBreakerState   = { param($st) Get-CircuitBreakerState -State $st }
    }
}

Export-ModuleMember -Function @('Get-ErrorCategory', 'Get-ErrorCategoryInfo', 'New-BuildError', 'Invoke-WithRetry', 'Invoke-HistoryWriteWithRetry', `
    'Register-RollbackAction', 'Invoke-Rollback', 'Clear-RollbackStack', `
    'Get-ErrorSummary', 'Show-ErrorReport', 'Write-ErrorStructured', 'Reset-ErrorLog', `
    'Initialize-CircuitBreaker', 'Get-CircuitBreakerState', 'Invoke-WithCircuitBreaker', 'Reset-CircuitBreaker', `
    'Save-CircuitBreakerState', 'Restore-CircuitBreakerState', `
    'Get-StateFilePath', 'Save-BuildState', 'Restore-BuildState', 'Get-RestoredStateInfo', 'Get-ErrorHandlingService', `
    'Set-NonRetryableOperation')





