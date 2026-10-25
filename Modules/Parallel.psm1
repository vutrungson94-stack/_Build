# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Parallel.psm1 (Configuration-Driven, Portable, Professional)
# ==================================================================================================
#
# Provides:
#   - Detect independent projects for parallel compilation
#   - PowerShell runspace pool for concurrent builds
#   - Configurable concurrency limit from gbuild.config.json
#   - Progress aggregation across parallel tasks
#   - Throttled execution with configurable max jobs
# ==================================================================================================

# -- Resolve parallel config from State (Single Source of Truth) ----------------

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'PathUtils')

# Ensure Get-ElapsedSeconds (from BuildConstants) is available session-wide.
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-ElapsedSeconds'

<#
.SYNOPSIS
    Resolves parallel build configuration from state with fallback defaults.
.DESCRIPTION
    Reads the build config section from State.BuildConfig.build and fills
    in default values for MaxJobs, timeout, search root, and other settings.
.PARAMETER State
    The build state object.
.OUTPUTS
    PSCustomObject
#>
function Get-ParallelConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0

    # Defaults (used when $State or $State.BuildConfig is not available).
    # Single source: BuildConstants (Parallel* keys + JobTimeoutSec already defined) —
    # literals are fallback only when the module is not loaded.
    $bc = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { ${function:Get-BuildConstant} } else { $null }
    $defaults = @{
        MaxJobs               = Get-ConfigValue -Path 'build.maxParallelJobs' -State $State -Default $(if ($bc) { & $bc 'ParallelMaxJobs' 8 } else { 8 })
        MaxJobsMin            = if ($bc) { & $bc 'ParallelMaxJobsMin' 1 } else { 1 }
        MaxJobsMax            = if ($bc) { & $bc 'ParallelMaxJobsMax' 16 } else { 16 }
        ProgressPollIntervalMs = if ($bc) { & $bc 'ParallelProgressPollMs' 200 } else { 200 }
        ProgressActivityName  = "Parallel Build"
        SearchRoot            = $null  # will resolve from State
        SearchMaxDepth        = if ($bc) { & $bc 'ParallelSearchMaxDepth' 3 } else { 3 }
        # Embedded tool copy (_Build) and build artifacts must
        # never be scheduled as independent projects in a monorepo parallel build.
        # Single source: PathUtils.Get-ExcludeDirPattern over SyntaxCheckExcludeDirs.
        # Level 5 resilience: inline regex fallback when PathUtils was orphaned.
        # NOTE: bare `if` (no parens) — PS 5.1 does NOT support `(if ...)` as a
        # subexpression; the parenthesized form throws "term 'if' not recognized".
        # Fallback mirrors BuildConstants.SyntaxCheckExcludeDirs exactly (incl .tools).
        ExcludePattern        = if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) { (Get-ExcludeDirPattern -FromConstant 'SyntaxCheckExcludeDirs') + '(.*)' } else { $pped = if ($bc) { @(& $bc 'SyntaxCheckExcludeDirs' @('obj','bin','.git','node_modules','TestResults','publish-output','.gbuildcache','build-reports','logs','_Build','.tools')) } else { @('obj','bin','.git','node_modules','TestResults','publish-output','.gbuildcache','build-reports','logs','_Build','.tools') }; ('[\\/](' + (($pped | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')[\\/]') + '(.*)' }
        JobTimeoutSeconds     = if ($bc) { & $bc 'JobTimeoutSec' 600 } else { 600 }
    }

    # Try to read from State.BuildConfig.build
    $cfg = Get-ConfigSection -State $State -Path 'build'

    # Resolve values with fallback chain
    $result = @{}
    $result.MaxJobs               = if ($cfg -and ($null -ne $cfg.maxParallelJobs))                { $cfg.maxParallelJobs }              else { $defaults.MaxJobs }
    $result.MaxJobsMin            = $defaults.MaxJobsMin
    $result.MaxJobsMax            = if ($cfg -and ($null -ne $cfg.maxJobsMax))                     { $cfg.maxJobsMax }                   elseif ($cfg -and ($null -ne $cfg.maxParallelJobs)) { $scale = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'ParallelMaxJobsScaleFactor' -Fallback 4) } else { 4 }; [Math]::Max($cfg.maxParallelJobs * $scale, $defaults.MaxJobsMax) } else { $defaults.MaxJobsMax }
    $result.ProgressPollIntervalMs = if ($cfg -and ($null -ne $cfg.progressPollIntervalMs)) { $cfg.progressPollIntervalMs } else { $defaults.ProgressPollIntervalMs }
    $result.ProgressActivityName  = $defaults.ProgressActivityName
    $result.SearchRoot            = if ($State -and $State.ProjectRoot)                           { $State.ProjectRoot }                else { $defaults.SearchRoot }
    $result.SearchMaxDepth        = if ($cfg -and ($null -ne $cfg.searchMaxDepth))                { $cfg.searchMaxDepth }               else { $defaults.SearchMaxDepth }
    $result.ExcludePattern        = if ($cfg -and ($null -ne $cfg.excludePattern))               { $cfg.excludePattern }               else { $defaults.ExcludePattern }
    $result.JobTimeoutSeconds     = if ($cfg -and ($null -ne $cfg.timeoutMinutes))                { $cfg.timeoutMinutes * 60 }          else { $defaults.JobTimeoutSeconds }

    return [PSCustomObject]$result
}

# -- Normalize individual build task ---------------------------------------------
<#
.SYNOPSIS
    Normalizes a build task into a standard PSCustomObject format.
.DESCRIPTION
    Accepts a task as a string or hashtable and converts it to a normalized
    object with ScriptBlock, Arguments, and Name properties for use with
    the runspace pool.
.PARAMETER Task
    The task to normalize. Can be a string (task name) or a hashtable with
    Name, ScriptBlock, and Arguments keys.
.PARAMETER State
    The build state object for logging.
.OUTPUTS
    PSCustomObject
#>
function Get-NormalizedBuildTask {
    [CmdletBinding()]
    param(
        [object]$Task,
        [PSCustomObject]$State
    )

    $scriptBlock = $null
    $arguments   = @{}
    $taskName    = $null

    if ($Task -is [string]) {
        # String task: wrap in a scriptblock that outputs it
        $taskText   = $Task
        $scriptBlock = { param($Name, $StateObj) Write-Output "Task: $Name" }
        $arguments   = @{ Name = $taskText; StateObj = $State }
        $taskName    = $taskText
    }
    elseif ($Task -is [hashtable]) {
        $scriptBlock = if ($Task.ContainsKey('ScriptBlock')) { $Task['ScriptBlock'] }
                       else { { param($Name, $StateObj) Write-Output "Task: $Name" } }
        $arguments   = if ($Task.ContainsKey('Arguments'))   { $Task['Arguments'] } else { @{} }
        $taskName    = if ($Task.ContainsKey('Name'))        { $Task['Name'] }      else { "unnamed" }
    }
    else {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.parallel.unknownTask' -MessageArgs @([string]$Task.GetType().Name) -Fallback '[PARALLEL] Skipping unknown task type: {0}') "Warn" $State
        }
        return $null
    }

    return [PSCustomObject]@{
        ScriptBlock = $scriptBlock
        Arguments   = $arguments
        Name        = $taskName
    }
}

# -- Build projects in parallel (runspace pool) ---------------------------------
<#
.SYNOPSIS
    Executes build tasks in parallel using a PowerShell runspace pool.
.DESCRIPTION
    Creates a runspace pool with the configured number of workers, dispatches
    normalized build tasks, waits for completion with progress reporting,
    collects results, and returns an array of result objects. Supports
    configurable timeout per task.
.PARAMETER BuildTasks
    Array of task objects (strings or hashtables) to execute in parallel.
.PARAMETER MaxJobs
    Maximum number of concurrent runspaces (overrides config if > 0).
.PARAMETER State
    The build state object.
.OUTPUTS
    PSCustomObject[]
#>
function Invoke-ParallelBuild {
    [CmdletBinding()]
    param(
        [object[]]$BuildTasks,
        # Sentinel 0 = use build.maxParallelJobs (Get-ParallelConfig); >0 = caller override.
        [int]$MaxJobs = 0,
        [PSCustomObject]$State
    )

    # -- Resolve config ----------------------------------------------------------
    $cfg = Get-ParallelConfig -State $State
    $MaxJobs = if ($MaxJobs -le 0) { $cfg.MaxJobs } else { $MaxJobs }
    $MaxJobs = [Math]::Max($cfg.MaxJobsMin, [Math]::Min($MaxJobs, $cfg.MaxJobsMax))
    $timeoutSec = $cfg.JobTimeoutSeconds

    if ($null -eq $BuildTasks -or $BuildTasks.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.parallel.noTasks' -Fallback '[PARALLEL] No tasks to build') "Warn" $State
        }
        return @()
    }

    # -- Normalize tasks ---------------------------------------------------------
    $normalizedTasks = [System.Collections.ArrayList]@()
    foreach ($task in $BuildTasks) {
        $normalized = Get-NormalizedBuildTask -Task $task -State $State
        if ($normalized) { $normalizedTasks.Add($normalized) | Out-Null }
    }

    if ($normalizedTasks.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.parallel.noValidTasks' -Fallback '[PARALLEL] No valid tasks after normalization') "Warn" $State
        }
        return @()
    }

    $actualJobCount = [Math]::Min($MaxJobs, $normalizedTasks.Count)

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.parallel.running' -MessageArgs @([string]$normalizedTasks.Count, [string]$actualJobCount) -Fallback '[PARALLEL] Running {0} tasks with {1} workers...') "Info" $State
    }

    # -- Create runspace pool -----------------------------------------------------
    $runspacePool = $null
    try {
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        # Inject Logging module so Write-Log / Write-Info / etc. work inside runspaces
        $loggingPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Logging.psm1'
        if (Test-Path -LiteralPath $loggingPath) {
            $sessionState.ImportPSModule($loggingPath)
        }
        # Pass the current host so runspaces can safely call Write-Host / Write-Progress /
        # Read-Host. When no host object is available (some CI agents / non-interactive
        # runspaces), fall back to the 3-argument overload which uses a default minimal
        # host. Passing $null to the 4-argument overload throws "host is null".
        if ($Host) {
            $runspacePool = [runspacefactory]::CreateRunspacePool(1, $actualJobCount, $sessionState, $Host)
        }
        elseif ($PSVersionTable.PSVersion.Major -ge 7) {
            $runspacePool = [runspacefactory]::CreateRunspacePool(1, $actualJobCount, $sessionState)
        }
        else {
            # PS 5.1 has no 3-arg overload without host; use IS-only overload
            $runspacePool = [runspacefactory]::CreateRunspacePool($sessionState)
            $runspacePool.SetMinRunspaces(1)
            $runspacePool.SetMaxRunspaces($actualJobCount)
        }
        $runspacePool.Open()
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.parallel.poolFailed' -MessageArgs @([string]$_) -Fallback '[PARALLEL] Failed to create runspace pool: {0}') "Err" $State
        }
        return @()
    }

    # -- Create jobs --------------------------------------------------------------
    $jobs = [System.Collections.ArrayList]@()
    try {
        foreach ($task in $normalizedTasks) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            $null = $ps.AddScript($task.ScriptBlock)

            # Add named arguments
            if ($task.Arguments) {
                foreach ($entry in $task.Arguments.GetEnumerator()) {
                    $null = $ps.AddParameter($entry.Key, $entry.Value)
                }
            }

            $asyncResult = $ps.BeginInvoke()
            $jobs.Add([PSCustomObject]@{
                PowerShell   = $ps
                AsyncResult  = $asyncResult
                TaskName     = $task.Name
                StartTime    = Get-Date
            }) | Out-Null
        }
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.parallel.jobsFailed' -MessageArgs @([string]$_) -Fallback '[PARALLEL] Failed to create jobs: {0}') "Err" $State
        }
        # Cleanup any partially created jobs
        foreach ($job in $jobs) {
            try { $job.PowerShell.Dispose() } catch { # cleanup best-effort
                }
        }
        if ($runspacePool) { try { $runspacePool.Close(); $runspacePool.Dispose() } catch { # cleanup best-effort
                } }
        return @()
    }

    # -- Wait for completion with progress ----------------------------------------
    # try/finally: collection + pool cleanup MUST run even when the wait loop
    # throws unexpectedly (a terminating error here previously skipped
    # EndInvoke/Dispose and leaked PowerShell instances + the runspace pool).
    $results = [System.Collections.ArrayList]@()
    $total = $jobs.Count
    $startWait = Get-Date
    $timeoutReached = $false

    try {
        while (-not $timeoutReached) {
            $completedCount = 0
            foreach ($job in $jobs) {
                if ($job.AsyncResult.IsCompleted) { $completedCount++ }
            }

            # Check timeout
            if ($timeoutSec -gt 0 -and (Get-ElapsedSeconds $startWait) -gt $timeoutSec) {
                $timeoutReached = $true
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    # Format BEFORE calling Write-Log — Write-Log has no -f parameter.
                    Write-Log (Resolve-LogMessage -Key 'log.parallel.timeout' -MessageArgs @([string]$timeoutSec) -Fallback '[PARALLEL] Timeout reached after {0}s. Collecting partial results...') "Warn" $State
                }
            }

            if ($completedCount -ge $total -or $timeoutReached) { break }

            $pct = [int]($completedCount / $total * 100)
            Write-Progress -Activity $cfg.ProgressActivityName -Status "$completedCount/$total completed ($pct%)" -PercentComplete $pct
            Start-Sleep -Milliseconds $cfg.ProgressPollIntervalMs
        }
    }
    finally {
        # Guarded: a throwing host must not skip the cleanup below.
        try { Write-Progress -Activity $cfg.ProgressActivityName -Completed } catch { }

        # -- Collect results (ALWAYS) ---------------------------------------------
        foreach ($job in $jobs) {
            try {
                if (-not $job.AsyncResult.IsCompleted) {
                    # Incomplete job (timeout or exceptional unwind): STOP it —
                    # EndInvoke would block indefinitely on a still-running task.
                    try { $job.PowerShell.Stop() } catch { # cleanup best-effort
                        }
                    $results.Add([PSCustomObject]@{
                        Task     = $job.TaskName
                        Output   = $null
                        Success  = $false
                        Error    = "Timeout after ${timeoutSec}s"
                        Duration = Get-ElapsedSeconds $job.StartTime
                    }) | Out-Null
                    continue
                }
                $output = $job.PowerShell.EndInvoke($job.AsyncResult)
                # The verdict must come from the TASK, not from the runspace.
                # This hardcoded Success = $true meant "the scriptblock
                # returned without throwing the PowerShell engine", which is a
                # statement about the HOST, not about the build: a task that ran
                # `dotnet build`, got a non-zero exit code and returned
                # @{ Success = $false; ExitCode = 1 } completed normally here
                # and was counted as a SUCCESS. So a parallel build in which
                # every single project failed reported
                # "Completed: 3 success, 0 failed" and the caller built its
                # verdict on "3 succeeded, 0 failed". This was invisible
                # because target 14 was unreachable; it became observable the
                # moment the flow was fixed.
                #
                # A task's own verdict is honoured when it reports one. Any
                # object carrying a Success property in the output stream sets
                # the result, last one wins (a task that reports progress as it
                # goes and a summary at the end should end on the summary).
                # Anything else keeps the honest default: a completed job with
                # no reported verdict and no error-stream output is a success.
                $taskOk = $true
                $taskExit = $null
                foreach ($o in @($output)) {
                    if ($null -eq $o) { continue }
                    $hasSuccess = $false; $val = $false; $exit = $null
                    if ($o -is [System.Collections.IDictionary]) {
                        if ($o.Contains('Success')) { $hasSuccess = $true; $val = [bool]$o['Success'] }
                        if ($o.Contains('ExitCode')) { $exit = $o['ExitCode'] }
                    } else {
                        $names = @($o.PSObject.Properties.Name)
                        if ($names -contains 'Success') { $hasSuccess = $true; $val = [bool]$o.Success }
                        if ($names -contains 'ExitCode') { $exit = $o.ExitCode }
                    }
                    if ($hasSuccess) { $taskOk = $val; $taskExit = $exit }
                }
                # A terminating/non-terminating error written by the task is a
                # failure even when the scriptblock still returned an object.
                $errCount = 0
                try { $errCount = @($job.PowerShell.Streams.Error).Count } catch { }
                if ($errCount -gt 0) { $taskOk = $false }
                $results.Add([PSCustomObject]@{
                    Task      = $job.TaskName
                    Output    = $output
                    Success   = $taskOk
                    ExitCode  = $taskExit
                    Error     = $(if ($errCount -gt 0) { "$errCount error stream record(s)" } else { $null })
                    Duration  = Get-ElapsedSeconds $job.StartTime
                }) | Out-Null
            }
            catch {
                $results.Add([PSCustomObject]@{
                    Task     = $job.TaskName
                    Output   = $null
                    Success  = $false
                    Error    = $_.Exception.Message
                    Duration = Get-ElapsedSeconds $job.StartTime
                }) | Out-Null
            }
            finally {
                try { $job.PowerShell.Dispose() } catch { # cleanup best-effort
                    }
            }
        }

        # -- Cleanup runspace pool (ALWAYS) ---------------------------------------
        try { $runspacePool.Close() } catch { # cleanup best-effort
            }
        try { $runspacePool.Dispose() } catch { # cleanup best-effort
            }
    }

    # -- Report results -----------------------------------------------------------
    $successCount = @($results | Where-Object { $_.Success }).Count
    $failCount    = @($results | Where-Object { -not $_.Success }).Count
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $logLevel = if ($failCount -gt 0) { 'Warn' } else { 'Succ' }
        Write-Log (Resolve-LogMessage -Key 'log.parallel.completed' -MessageArgs @([string]$successCount, [string]$failCount) -Fallback '[PARALLEL] Completed: {0} success, {1} failed') $logLevel $State
    }

    return $results
}

# -- Detect independent projects (heuristic) -----------------------------------
<#
.SYNOPSIS
    Detects independent projects that have no inter-project references.
.DESCRIPTION
    Scans for .csproj files up to the specified depth, parses each to check
    for ProjectReference elements, and returns a hashtable with All and
    Independent project lists for parallel scheduling.
.PARAMETER State
    The build state object.
.PARAMETER SearchRoot
    The root directory to search from. Defaults to State.ProjectRoot.
.PARAMETER MaxDepth
    Maximum directory recursion depth (default 3).
.OUTPUTS
    hashtable
#>
function Find-IndependentProjects {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$SearchRoot,
        # -1 = sentinel "use default" (build.searchMaxDepth > BuildConstants > 3).
        # Positive values passed by the caller are respected as-is.
        [int]$MaxDepth = -1
    )

    $cfg = Get-ParallelConfig -State $State

    if ($MaxDepth -lt 0) { $MaxDepth = $cfg.SearchMaxDepth }

    # Resolve search root: explicit > State.ProjectRoot > config default
    if ([string]::IsNullOrWhiteSpace($SearchRoot)) {
        $SearchRoot = $cfg.SearchRoot
    }
    if ([string]::IsNullOrWhiteSpace($SearchRoot)) {
        $SearchRoot = "."
    }

    $excludePattern = $cfg.ExcludePattern

    # Use cross-platform child item (supports PS 5.1 without -Depth)
    $getChildItem = if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
        { Invoke-CompatibleChildItem -Path $args[0] -Recurse -File -Depth $args[1] -Filter "*.csproj" }
    } else {
        # Fallback: raw Get-ChildItem (PS 6+)
        { Get-ChildItem -Path $args[0] -Recurse -Depth $args[1] -Filter "*.csproj" -File -EA SilentlyContinue }
    }

    $csprojs = & $getChildItem $SearchRoot $MaxDepth |
        Where-Object { $_.FullName -notmatch $excludePattern }

    $projects = [System.Collections.ArrayList]@()
    foreach ($p in $csprojs) {
        try {
            [xml]$xml = Get-Content $p.FullName -Raw -Encoding UTF8 -EA Stop
            $projectRefs = $xml.SelectSingleNode("//*[local-name()='ProjectReference']")
            $hasRefs = $null -ne $projectRefs
            $refs = [System.Collections.ArrayList]@()
            foreach ($ref in $projectRefs) {
                $include = $ref.GetAttribute('Include')
                if ($include) { $refs.Add($include) | Out-Null }
            }
            $projects.Add([PSCustomObject]@{
                Path           = $p.FullName
                Name           = $p.BaseName
                HasProjectRefs = $hasRefs
                ProjectRefs    = $refs
            }) | Out-Null
        }
        catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.parallel.parseFailed' -MessageArgs @([string]$p.FullName, $_) -Fallback '[PARALLEL] Failed to parse project: {0} - {1}') "Warn" $State
            }
            else {
                Write-Warning (Resolve-LogMessage -Key 'log.parallel.parseFailed' -MessageArgs @([string]$p.FullName, [string]$_) -Fallback 'Failed to parse project: {0} - {1}')
            }
        }
    }

    $independent = $projects | Where-Object { -not $_.HasProjectRefs }

    return @{
        All         = $projects
        Independent = $independent
    }
}

Export-ModuleMember -Function @('Invoke-ParallelBuild', 'Find-IndependentProjects')




