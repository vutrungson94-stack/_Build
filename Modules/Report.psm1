# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# BuildImport defines Import-GBuildModule and Import-BuildDependencies
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ==================================================================================================
# Modules/Report.psm1 (Build Reports & Analytics)
# ==================================================================================================
#
# Provides:
#   - Structured JSON build output (machine-readable)
#   - Build time tracking per project
#   - Trend analysis (build time over time)
#   - SARIF format for code analysis
#   - gbuild --report
# ==================================================================================================

# -- Import dependency ----------------------------------------------------------
$reportLogPath = Join-Path $PSScriptRoot 'Logging.psm1'
# Nested import WITHOUT -Force (references the globally loaded Logging from the
# gbuild.ps1 bootstrap) — a nested -Force re-import orphans the global Logging
# module in PS 5.1, breaking Write-Log resolution for every module.
if (Test-Path $reportLogPath) { $null = Import-Module $reportLogPath -DisableNameChecking -ErrorAction SilentlyContinue }
# Environment owns Read-JsonSafe/Save-JsonSafe. Import it once here so report
# helpers call the owner directly instead of carrying guarded local fallbacks.
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Read-JsonSafe'
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildTimestamp'

# -- Module-scope vars ----------------------------------------------------------
$script:BuildMetrics = [System.Collections.Generic.List[hashtable]]::new()
$script:ReportDir    = $null

# Cache available commands to avoid repetitive reflection
$script:HasBuildMeta = $null
$script:HasWriteLog  = $null
$script:HasColorFn   = $null

# -- Helper: resolve config value with fallback ---------------------------------
<#
.SYNOPSIS
    Resolves a report configuration value from State with a fallback default.
.DESCRIPTION
    Reads the named key from State.BuildConfig.report and returns it, or
    returns the provided Default value if the key is not set.
.PARAMETER State
    The build state object.
.PARAMETER Key
    The configuration key to read.
.PARAMETER Default
    The default value to return if the key is not configured.
#>
function Get-ReportConfigValue {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Key,
        $Default
    )

Set-StrictMode -Version 1.0
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        return Get-ConfigValue -Path "report.$Key" -State $State -Default $Default -ResolveEnv
    }
    return Resolve-ConfigValue -State $State -Path "report.$Key" -Default $Default
}

# -- Helper: resolve telemetry config value ------------------------------------
<#
.SYNOPSIS
    Resolves a telemetry configuration value from State with a fallback default.
.DESCRIPTION
    Reads the named key from State.BuildConfig.telemetry and returns it, or
    returns the provided Default value if the key is not set.
.PARAMETER State
    The build state object.
.PARAMETER Key
    The configuration key to read.
.PARAMETER Default
    The default value to return if the key is not configured.
#>
function Get-TelemetryConfigValue {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Key,
        $Default
    )
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        return Get-ConfigValue -Path "telemetry.$Key" -State $State -Default $Default -ResolveEnv
    }
    return Resolve-ConfigValue -State $State -Path "telemetry.$Key" -Default $Default
}

# -- Helper: safe Write-Log wrapper ----------------------------------------------
<#
.SYNOPSIS
    Safe wrapper around Write-Log with cached command availability.
.DESCRIPTION
    Checks once whether Write-Log exists, caches the result, and calls it
    if available. Prevents repetitive Get-Command calls.
.PARAMETER Message
    The log message text.
.PARAMETER Level
    The log level/color (Gray, Info, Warn, Err, Succ).
.PARAMETER State
    The build state object.
#>
function Write-ReportLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [string]$Level = "Gray",
        [PSCustomObject]$State
    )
    # P1 DRY: reuse Logging.Write-LogSafe (same guard + fallback) instead of a fork.
    if (Get-Command Write-LogSafe -ErrorAction SilentlyContinue) { Write-LogSafe $Message $Level $State; return }
    if ($null -eq $script:HasWriteLog) {
        $script:HasWriteLog = [bool](Get-Command Write-Log -ErrorAction SilentlyContinue)
    }
    if ($script:HasWriteLog) {
        Write-Log $Message $Level $State
    }
}

# -- Initialize report directory ------------------------------------------------
<#
.SYNOPSIS
    Creates the build report directory if it does not exist.
.DESCRIPTION
    Resolves the report output directory from config (default: build-reports)
    relative to the State.ScriptRoot parent, creates it if missing, sets the
    module-scoped $script:ReportDir, and returns the path.
.PARAMETER State
    The build state object.
.OUTPUTS
    string
#>
function Initialize-ReportDir {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    # Directory resolution single-sourced via SharedUtils.Get-ReportDirectory
    # (config report.outputDir + BuildConstants.ReportOutputDir + rooted path).
    $reportDir = if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) {
        Get-ReportDirectory -State $State
    } else {
        $defaultReportDir = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'ReportOutputDir' -Fallback 'build-reports' } else { 'build-reports' }
        $reportDirName = Get-ReportConfigValue -State $State -Key "outputDir" -Default $defaultReportDir
        # Fail closed: the old final arm returned the BARE directory name, so
        # Invoke-EnsureDirectory created build-reports\ in the process current
        # directory and every subsequent report, telemetry and SBOM write landed
        # there. Compliance evidence must never silently relocate.
        if ([System.IO.Path]::IsPathRooted([string]$reportDirName)) { $reportDirName }
        elseif ($State -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) { Join-Path ([string]$State.ProjectRoot) $reportDirName }
        elseif ($State -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) { Join-Path (Split-Path ([string]$State.ScriptRoot) -Parent) $reportDirName }
        else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.report.line161' -Fallback 'Report root is undetermined: State carries neither a rooted ProjectRoot nor a rooted ScriptRoot. Refusing to create the report directory in the current directory.')) }
    }

    if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $reportDir) } elseif (-not (Test-Path $reportDir -PathType Container)) { New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null }

    $script:ReportDir = $reportDir
    return $reportDir
}

# -- Refresh command caches ------------------------------------------------------
<#
.SYNOPSIS
    Clears cached command availability flags used by report helpers.
.DESCRIPTION
    Resets the module-scoped command detection booleans so they are
    re-evaluated on the next call. Useful after module reloads.
#>
function Reset-ReportCache {
    [CmdletBinding()]
    param()
    $script:HasBuildMeta = $null
    $script:HasWriteLog  = $null
    $script:HasColorFn   = $null
    # Per-run state: $script:ReportDir is memoised on first use and $script:BuildMetrics
    # accumulates across calls. Without this, a second Start-GBuild in one session
    # (long-lived host) writes project B's reports, telemetry and SBOM into
    # project A's build-reports/ and aggregates both runs' metrics into one report.
    # Clearing forces re-resolution from the current State on next use.
    $script:ReportDir = $null
    try { $script:BuildMetrics.Clear() } catch { }
}

# -- Write build metric --------------------------------------------------------
<#
.SYNOPSIS
    Records a build metric entry in the module-scoped metrics list.
.DESCRIPTION
    Creates a structured metric hashtable with timestamp, status, duration,
    project info, configuration, OS, user, hostname, and profile. Optionally
    attaches build metadata (commit, branch) and extra custom fields.
.PARAMETER State
    The build state object.
.PARAMETER Status
    Build status: Success or Failure (default: Success).
.PARAMETER Duration
    Build duration in seconds (default: 0).
.PARAMETER ProjectName
    The project name (default: derived from State.ProjectRoot).
.PARAMETER Configuration
    Build configuration (default: Release).
.PARAMETER TargetFramework
    The target framework moniker.
.PARAMETER OutputType
    The project output type.
.PARAMETER Extra
    Additional custom fields to merge into the metric.
.OUTPUTS
    hashtable
#>
function Write-BuildMetric {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Status = 'Success',
        [double]$Duration = 0,
        [string]$ProjectName = '',
        [string]$Configuration = 'Release',
        [string]$TargetFramework = '',
        [string]$OutputType = '',
        # Pipeline stage label (DORA); producers/hooks may set it explicitly.
        # Left empty when unknown instead of guessing — Metrics tolerates ''.
        [string]$Stage = '',
        [hashtable]$Extra = @{}
    )

    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }

    $fallbackProj = if (Get-Command Get-ProjectShortName -ErrorAction SilentlyContinue) { Get-ProjectShortName -State $State -Default 'Unknown' } elseif ($State -and $State.ProjectRoot) { Split-Path $State.ProjectRoot -Leaf } else { 'Unknown' }
    $metric = @{
        Timestamp       = (Get-Date).ToString('o')
        Status          = $Status
        Duration        = $Duration
        Project         = if ($ProjectName) { $ProjectName } else { $fallbackProj }
        Configuration   = $Configuration
        TargetFramework = $TargetFramework
        OutputType      = $OutputType
        OS              = if ($State -and $State.OS) { $State.OS } else { 'Unknown' }
        User            = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { [string](Get-BuildIdentity).User } else { [System.Environment]::UserName }
        Hostname        = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { [string](Get-BuildIdentity).Host } else { [System.Environment]::MachineName }
        Profile         = if ($State -and $State.ActiveProfile) { $State.ActiveProfile } else { 'Unknown' }
            # PS 5.1-safe git metadata: no ?. operator. Fields stay '' when git is
        # unavailable or returns nothing (Versioning.Get-BuildMetadata may omit
        # Commit/Branch entirely — access guarded below).
        Commit          = ''
        Stage           = ''
    }

    # Cache command availability
    if ($null -eq $script:HasBuildMeta) {
        $script:HasBuildMeta = [bool](Get-Command Get-BuildMetadata -ErrorAction SilentlyContinue)
    }

    if ($script:HasBuildMeta) {
        $gitMeta = Get-BuildMetadata -State $State
        if ($gitMeta) {
            # Null/missing-safe: Versioning returns a hashtable and may omit keys
            # when git is absent; never assume the member exists.
            $metaCommit = $null
            if ($gitMeta.PSObject.Properties.Name -contains 'Commit') { $metaCommit = $gitMeta.Commit }
            elseif ($gitMeta -is [System.Collections.IDictionary] -and $gitMeta.ContainsKey('Commit')) { $metaCommit = $gitMeta['Commit'] }
            if ($metaCommit) { $metric.Commit = [string]$metaCommit }
            $metaBranch = $null
            if ($gitMeta.PSObject.Properties.Name -contains 'Branch') { $metaBranch = $gitMeta.Branch }
            elseif ($gitMeta -is [System.Collections.IDictionary] -and $gitMeta.ContainsKey('Branch')) { $metaBranch = $gitMeta['Branch'] }
            if ($metaBranch) { $metric.Branch = [string]$metaBranch }
            $metaDirty = $null
            if ($gitMeta.PSObject.Properties.Name -contains 'IsDirty') { $metaDirty = $gitMeta.IsDirty }
            elseif ($gitMeta -is [System.Collections.IDictionary] -and $gitMeta.ContainsKey('IsDirty')) { $metaDirty = $gitMeta['IsDirty'] }
            if ($null -ne $metaDirty) { $metric.IsDirty = [bool]$metaDirty }
        }
    }

    foreach ($k in $Extra.Keys) {
        $metric[$k] = $Extra[$k]
    }

    $script:BuildMetrics.Add($metric) | Out-Null
    return $metric
}

# -- Save report to JSON file --------------------------------------------------
<#
.SYNOPSIS
    Saves a build metric to a JSON report file.
.DESCRIPTION
    Writes the metric hashtable to a timestamped JSON file in the report
    directory. Environment.Save-JsonSafe is the owner.
.PARAMETER State
    The build state object.
.PARAMETER Metric
    The metric hashtable to save (typically from Write-BuildMetric).
.OUTPUTS
    string
#>
function Save-BuildReport {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [hashtable]$Metric
    )

    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }
    if (-not $Metric) { return $null }

    $fileName = "build_$(Get-BuildTimestamp -Kind FileStamp).json"
    $filePath = Join-Path $script:ReportDir $fileName
    # Collision-free claim, same rule as Logging.Start-Log: the stamp carries
    # only second resolution, so two builds in the same second compute the same
    # name and the atomic replace below would silently discard the first
    # report. Claim with CreateNew (atomic: throws if the name is taken) and
    # suffix _2, _3, ... until the claim wins. The claimed (empty) file stays:
    # Save-JsonSafe replaces it atomically below, so there is no
    # check-then-act window. If this build dies before writing, an empty
    # build_*.json remains; readers (Read-ReportJson) skip unparseable files.
    $repAttempt = 1
    while ($true) {
        try {
            $repFs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try { $repFs.Dispose() } catch { }
            break
        } catch [System.IO.IOException] {
            $repAttempt++
            if ($repAttempt -gt 100) { break }
            $repLeaf = "build_$(Get-BuildTimestamp -Kind FileStamp)_$repAttempt.json"
            $filePath = Join-Path $script:ReportDir $repLeaf
        }
    }

    try {
        Save-JsonSafe -Data $Metric -FilePath $filePath

        Write-ReportLog -Message "[REPORT] Saved: $filePath" -Level "Gray" -State $State

        # Feed the anomaly history. AnomalyDetector's whole premise is a rolling
        # baseline: Get-DurationAnomaly / Get-FailureRateAnomaly are handed a
        # history and only become meaningful once minSamples (default 10) have
        # accumulated. Write-AnomalySample existed and was fully implemented but
        # had NO production caller, so the sample file never grew past empty and
        # anomaly detection could never fire - the feature was a permanent
        # no-op behind a config flag that said it was on.
        #
        # Save-BuildReport is the right chokepoint: it already holds the resolved
        # metric (duration, status, cache outcome) and the state, and it runs
        # once per build on both the success and the failure path. Failures here
        # are swallowed - telemetry must never fail a build that already
        # produced its report.
        #
        # Every branch below is PS 5.1-parseable: no `if` used as an expression,
        # no ternary. Run-CoreTests runs the PS51Compat parse gate over every
        # shipped file.
        try {
            # Load AnomalyDetector on demand. Without this the guard below is
            # always false in a real build, because nothing else in the report
            # path pulls the module in - the only importers were the alert path
            # and the 'M' menu entry, and a straight `gbuild -Target 12` never
            # reaches either.
            if (-not (Get-Command Write-AnomalySample -ErrorAction SilentlyContinue)) {
                Import-GBuildModuleIfMissing -Name 'AnomalyDetector' -SentinelCommand 'Write-AnomalySample'
            }
            if (Get-Command Write-AnomalySample -ErrorAction SilentlyContinue) {
                $parallelJobs = 0
                $incremental = $false
                if ($State) {
                    if ($State.PSObject.Properties.Name -contains 'Incremental') { $incremental = [bool]$State.Incremental }
                    if ($State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -and $State.BuildConfig.build) {
                        $cfgJobs = $State.BuildConfig.build.maxParallelJobs
                        if ($null -ne $cfgJobs) { try { $parallelJobs = [int]$cfgJobs } catch { $parallelJobs = 0 } }
                    }
                }
                $durationSec = 0.0
                if ($Metric.ContainsKey('Duration') -and $null -ne $Metric['Duration']) { try { $durationSec = [double]$Metric['Duration'] } catch { $durationSec = 0.0 } }
                $statusText = 'Success'
                if ($Metric.ContainsKey('Status') -and $Metric['Status']) { $statusText = [string]$Metric['Status'] }
                $cacheHit = $false
                if ($Metric.ContainsKey('CacheHit')) { $cacheHit = [bool]$Metric['CacheHit'] }
                elseif ($Metric.ContainsKey('CacheStatus')) { $cacheHit = ([string]$Metric['CacheStatus'] -eq 'Hit') }
                $null = Write-AnomalySample -State $State -Sample @{
                    Timestamp    = (Get-Date).ToString('o')
                    DurationSec  = $durationSec
                    Success      = ($statusText -notmatch '(?i)fail|error')
                    ParallelJobs = $parallelJobs
                    CacheHit     = $cacheHit
                    Incremental  = $incremental
                }
            }
        } catch { }

        return $filePath
    } catch {
        Write-ReportLog -Message "[REPORT] Cannot save report: $_" -Level "Warn" -State $State
        return $null
    }
}

# -- Telemetry export --------------------------------------------------------
<#
.SYNOPSIS
    Exports a telemetry entry to a JSONL file based on the telemetry config.
.DESCRIPTION
    Reads State.BuildConfig.telemetry. When disabled, returns immediately
    (no file written). When collectBuildTimes is false, the Duration field is
    stripped. When collectErrorStats is true, an ErrorCount field is appended
    from State.Errors or Get-ErrorSummary. When anonymousOnly is true, the
    User and Hostname fields are stripped before writing. Output is appended
    line-by-line to telemetry.jsonl in the report directory.
.PARAMETER State
    The build state object.
.PARAMETER Metric
    The metric hashtable to export (typically from Write-BuildMetric).
.OUTPUTS
    string (path to telemetry file) or $null when disabled / failed.
#>
function Write-TelemetryEntry {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [hashtable]$Metric
    )

    $enabled = [bool](Get-TelemetryConfigValue -State $State -Key 'enabled' -Default $false)
    if (-not $enabled) { return $null }
    if (-not $Metric) { return $null }
    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }

    $entry = @{}
    foreach ($k in $Metric.Keys) { $entry[$k] = $Metric[$k] }

    # L5: W3C trace propagation (additive). Stamp traceparent so distributed
    # steps and SIEM can correlate. Never overwrites an explicit caller value.
    try {
        if (-not $entry.ContainsKey('Traceparent') -and -not $entry.ContainsKey('TraceId')) {
            $tc = Get-BuildTraceContext -State $State
            if ($tc) {
                $entry['TraceId'] = [string]$tc.TraceId
                $entry['Traceparent'] = [string]$tc.Traceparent
            }
        }
    } catch { }

    $collectTimes  = [bool](Get-TelemetryConfigValue -State $State -Key 'collectBuildTimes' -Default $false)
    $collectErrors = [bool](Get-TelemetryConfigValue -State $State -Key 'collectErrorStats' -Default $false)
    $anonOnly      = [bool](Get-TelemetryConfigValue -State $State -Key 'anonymousOnly' -Default $true)

    if (-not $collectTimes -and $entry.ContainsKey('Duration')) {
        $entry.Remove('Duration') | Out-Null
    }

    if ($collectErrors) {
        $errCount = 0
        if ($State -and ($State.PSObject.Properties.Name -contains 'Errors') -and $State.Errors) {
            $errCount = @($State.Errors).Count
        } elseif (Get-Command Get-ErrorSummary -ErrorAction SilentlyContinue) {
            try { $errCount = (Get-ErrorSummary).Total } catch { $errCount = 0 }
        }
        $entry['ErrorCount'] = $errCount
    }

    if ($anonOnly) {
        $entry.Remove('User') | Out-Null
        $entry.Remove('Hostname') | Out-Null
    }

    $filePath = Join-Path $script:ReportDir 'telemetry.jsonl'
    # Bound the file. telemetry.jsonl was the only history store in build-reports
    # with NO cap: anomaly/autotune/root-cause each trim to maxHistoryEntries,
    # this one grew forever, so Get-SloSamples re-parsed an ever-growing file on
    # every build. maxReportHistory is the existing owner for report retention.
    $maxEntries = 0
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { $maxEntries = [int](Get-ConfigValue -Path 'report.maxReportHistory' -State $State -Default 0) } catch { $maxEntries = 0 }
    }
    if ($maxEntries -lt 1) { $maxEntries = 500 }

    $telemetryLock = $null
    try {
        # Lock like every sibling store, through the ONE shared primitive.
        # Bare AppendAllText let two concurrent gbuild invocations interleave
        # partial lines; a torn line then made ConvertFrom-Json throw inside the
        # SLO sample loop. This used to hand-roll a 100 x 25 ms retry loop, a
        # fourth copy of Enter-BuildFileLock, and it silently proceeded with a
        # null lock when every attempt failed.
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Enter-BuildFileLock')
        if (Get-Command Enter-BuildFileLock -ErrorAction SilentlyContinue) {
            $telemetryLock = Enter-BuildFileLock -Path $filePath
        }
        if ($null -eq $telemetryLock) {
            Write-ReportLog -Message "[TELEMETRY] Could not acquire the append lock for $filePath; entry dropped" -Level "Warn" -State $State
            return
        }
        $line = ($entry | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonShallowDepth' -Fallback 5) } else { 5 }) -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($filePath, $line, [System.Text.Encoding]::UTF8)
        # Ring-trim to maxEntries, keeping the newest lines.
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            $all = @(Get-Content -LiteralPath $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($all.Count -gt $maxEntries) {
                $keep = @($all[($all.Count - $maxEntries)..($all.Count - 1)])
                # SharedUtils.Write-BuildTextFileAtomic is the owner. This inline
                # version carried two defects the owner already avoids: the
                # temp name "$filePath.tmp" is PREDICTABLE (a collision between
                # concurrent writers and a symlink target for anything that can
                # write the directory) and File.Replace was called with a $null
                # backup path, which PowerShell binds to an empty string so the
                # call threw ArgumentException on every build - telemetry.jsonl
                # therefore grew past its cap forever.
                [void](Write-BuildTextFileAtomic -Path $filePath -Lines ([string[]]$keep))
            }
        }
        Write-ReportLog -Message "[TELEMETRY] Appended entry to $filePath" -Level "Gray" -State $State
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_TELEMETRY_RECORDED -Source $State -Data @{ File = $filePath; Metric = $Metric } | Out-Null
        }
        return $filePath
    } catch {
        Write-ReportLog -Message "[TELEMETRY] Cannot write telemetry: $_" -Level "Warn" -State $State
        return $null
    } finally {
        if ($telemetryLock) { try { $telemetryLock.Dispose() } catch { } }
    }
}

# -- Shared helper: read all report files ---------------------------------------
<#
.SYNOPSIS
    Reads build report JSON files from the report directory.
.DESCRIPTION
    Lists build_*.json files sorted by last write time (newest first),
    limited to the LastN count, and parses each with Read-ReportJson.
.PARAMETER State
    The build state object.
.PARAMETER LastN
    Maximum number of reports to return. Defaults to config maxReportHistory.
.OUTPUTS
    object[]
#>
function Get-ReportData {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [int]$LastN = -1
    )

    if ($LastN -le 0) {
        $LastN = [int](Get-ReportConfigValue -State $State -Key "maxReportHistory" -Default 20)
    }

    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }
    if (-not (Test-Path $script:ReportDir)) { return @() }

    $reports = Get-ChildItem -Path $script:ReportDir -Filter "build_*.json" -File -EA SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First $LastN

    $data = @()
    foreach ($r in $reports) {
        try {
            $parsed = Read-JsonSafe -FilePath $r.FullName
            if ($parsed) { $data += $parsed }
        } catch {
            # Skip malformed report files silently
        }
    }

    return $data
}

# -- Show build report ---------------------------------------------------------
<#
.SYNOPSIS
    Displays build report statistics and trend analysis.
.DESCRIPTION
    Reads the latest build reports, displays each with status, timestamp,
    project, configuration, and duration, then computes and shows trend
    metrics including average/min/max duration and success rate.
.PARAMETER State
    The build state object.
.PARAMETER LastN
    Number of recent reports to show (default: config maxReportHistory).
#>
function Show-BuildReport {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [int]$LastN = -1
    )

    if ($LastN -le 0) {
        $LastN = [int](Get-ReportConfigValue -State $State -Key "maxReportHistory" -Default 20)
    }

    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }

    # Show header
    Write-ReportLog -Message "[REPORT] Build Reports" -Level "Info" -State $State
    Write-ReportLog -Message "[REPORT] Directory: $script:ReportDir" -Level "Gray" -State $State

    if (-not (Test-Path $script:ReportDir)) {
        Write-ReportLog -Message "[REPORT] No reports found" -Level "Warn" -State $State
        return
    }

    # Resolve colors dynamically for NoColor compatibility
    if ($null -eq $script:HasColorFn) {
        $script:HasColorFn = [bool](Get-Command Resolve-SafeColor -ErrorAction SilentlyContinue)
    }
    $hasColorFn = $script:HasColorFn
    $cyan     = if ($hasColorFn) { Resolve-SafeColor -ColorName "Info" -State $State -Fallback "Cyan" } else { "Cyan" }
    $darkGray = if ($hasColorFn) { Resolve-SafeColor -ColorName "Gray" -State $State -Fallback "DarkGray" } else { "DarkGray" }
    $white    = if ($hasColorFn) { Resolve-SafeColor -ColorName "White" -State $State -Fallback "White" } else { "White" }
    $magenta  = if ($hasColorFn) { Resolve-SafeColor -ColorName "Header" -State $State -Fallback "Magenta" } else { "Magenta" }
    $green    = if ($hasColorFn) { Resolve-SafeColor -ColorName "Succ" -State $State -Fallback "Green" } else { "Green" }
    $red      = if ($hasColorFn) { Resolve-SafeColor -ColorName "Err" -State $State -Fallback "Red" } else { "Red" }

    $reports = Get-ChildItem -Path $script:ReportDir -Filter "build_*.json" -File -EA SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First $LastN

    if (-not $reports -or $reports.Count -eq 0) {
        Write-Log (Resolve-LogMessage -Key 'log.report.noneFound' -Fallback '[INFO] No reports found') 'Yellow' $State
        return
    }

    Write-Log ' ' -State $State
    Write-Log (Resolve-LogMessage -Key 'log.report.latest' -MessageArgs @([string]$LastN) -Fallback 'Latest {0} reports:') -Color $cyan -State $State
    Write-Log "  " ("-" * 70) -Color $darkGray -State $State

    foreach ($r in $reports) {
        try {
            $data = Read-JsonSafe -FilePath $r.FullName

            if ($data) {
                $statusIcon = if ($data.Status -eq 'Success') { '[OK]' } else { '[FAIL]' }
                $statusColor = if ($data.Status -eq 'Success') { $green } else { $red }

                Write-Log (Resolve-LogMessage -Key 'log.report.entry' -MessageArgs @([string]$statusIcon, $data.Timestamp, $data.Project, $data.Configuration, $data.Duration) -Fallback '{0} {1}  {2}  [{3}]  Duration: {4}s') -Color $statusColor -State $State
            }
        } catch {
            Write-ReportLog -Message "[REPORT] Failed to read report: $($r.Name)" -Level "Warn" -State $State
        }
    }

    # Trend analysis
    Write-Log ' ' -State $State
    Write-Log (Resolve-LogMessage -Key 'log.report.trendAnalysis' -Fallback '[STATS] Trend Analysis:') -Color $magenta -State $State
    $allReports = Get-ReportData -State $State -LastN $LastN

    if ($allReports -and $allReports.Count -gt 0) {
        $durations = @($allReports | ForEach-Object { [double]$_.Duration })
        $avgDuration = ($durations | Measure-Object -Average).Average
        $minDuration = ($durations | Measure-Object -Minimum).Minimum
        $maxDuration = ($durations | Measure-Object -Maximum).Maximum

        Write-Log (Resolve-LogMessage -Key 'log.report.average' -MessageArgs @([string][math]::Round($avgDuration, 1)) -Fallback 'Average: {0}s') -Color $white -State $State
        Write-Log (Resolve-LogMessage -Key 'log.report.min' -MessageArgs @([string][math]::Round($minDuration, 1)) -Fallback 'Min:     {0}s') -Color $green -State $State
        Write-Log (Resolve-LogMessage -Key 'log.report.max' -MessageArgs @([string][math]::Round($maxDuration, 1)) -Fallback 'Max:     {0}s') -Color $red -State $State

        $successCount = @($allReports | Where-Object { $_.Status -eq 'Success' }).Count
        $successRate = if ($allReports.Count -gt 0) { ($successCount / $allReports.Count) * 100 } else { 0 }
        Write-Log (Resolve-LogMessage -Key 'log.report.successRate' -MessageArgs @([string]$successCount, $allReports.Count, [math]::Round($successRate, 1)) -Fallback 'Success: {0}/{1} ({2}%)') -Color $cyan -State $State

        Write-ReportLog -Message "[REPORT] Trends: Avg=${avgDuration}s Min=${minDuration}s Max=${maxDuration}s Success=${successRate}% ($successCount/$($allReports.Count))" -Level "Info" -State $State

        # Level 5 wiring: per-report trend deltas come from the single-source
        # Get-BuildTrend (avg/delta/classification) instead of a second inline
        # computation, so the orphan export stays wired to production output.
        # report.trackTrends gates it: the key shipped in gbuild.config.json but
        # was read by nobody, so the per-build table was always printed.
        $trackTrends = [bool](Get-ReportConfigValue -State $State -Key 'trackTrends' -Default $true)
        if (-not $trackTrends) { Write-ReportLog -Message '[REPORT] Per-build trend table disabled (report.trackTrends=false)' -Level 'Gray' -State $State }
        try {
            $trendRows = if ($trackTrends) { @(Get-BuildTrend -State $State -LastN $LastN) } else { @() }
            if ($trendRows -and $trendRows.Count -gt 0) {
                Write-Log (Resolve-LogMessage -Key 'log.report.perBuildTrend' -MessageArgs @([string]$avgDuration) -Fallback 'Per-build trend (vs avg {0}s):') -Color $white -State $State
                foreach ($t in ($trendRows | Select-Object -First 5)) {
                    $tColor = if ($t.Trend -eq 'Improving') { $green } elseif ($t.Trend -eq 'Regressing') { $red } else { $darkGray }
                    Write-Log (Resolve-LogMessage -Key 'log.report.trendLine' -MessageArgs @([string]$t.Timestamp, $t.Project, $t.Status, $t.Duration, $t.Delta, $t.Trend, $t.AvgDuration) -Fallback '{0} {1} [{2}] {3}s (delta {4}s, {5}, avg {6}s)') -Color $tColor -State $State
                }
            }
        } catch { }
    }
}

# -- Get trend data ------------------------------------------------------------
<#
.SYNOPSIS
    Returns build trend data computed from saved build reports.
.DESCRIPTION
    Reads the saved build_*.json reports (via Get-ReportData) and returns one
    annotated object per report with the rolling average duration, the delta
    from that average, and a trend classification (Improving/Regressing/Stable).
.PARAMETER State
    The build state object.
.PARAMETER LastN
    Number of recent reports to include (default: config maxReportHistory).
.OUTPUTS
    pscustomobject[]
#>
function Get-BuildTrend {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [int]$LastN = -1
    )

    if ($LastN -le 0) {
        $LastN = [int](Get-ReportConfigValue -State $State -Key "maxReportHistory" -Default 20)
    }
    if (-not $script:ReportDir) { Initialize-ReportDir -State $State | Out-Null }
    if (-not (Test-Path $script:ReportDir)) { return @() }

    $data = @(Get-ReportData -State $State -LastN $LastN)
    if (-not $data -or $data.Count -eq 0) { return @() }

    $durations = @($data | ForEach-Object { [double]$_.Duration })
    $avg = ($durations | Measure-Object -Average).Average

    $trend = @()
    foreach ($d in $data) {
        $delta = [double]$d.Duration - $avg
        $label = if ($delta -lt 0) { 'Improving' } elseif ($delta -gt 0) { 'Regressing' } else { 'Stable' }
        $trend += [PSCustomObject]@{
            Timestamp   = $d.Timestamp
            Project     = $d.Project
            Status      = $d.Status
            Duration    = $d.Duration
            AvgDuration = [math]::Round($avg, 2)
            Delta       = [math]::Round($delta, 2)
            Trend       = $label
        }
    }
    return $trend
}

<#
.SYNOPSIS
    Exports test results to JUnit XML (CI-compatible).
.DESCRIPTION
    L5 gap closure: Report previously produced only build_*.json + telemetry,
    so CI systems expecting JUnit (Jenkins/GitHub/GitLab) could not consume
    test gates. This is purely additive — no existing report path changes.
#>
function Get-ReportFieldValue {
    param($Object, [string]$Name, $Default = '')
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $v = $Object[$Name]; if ($null -ne $v -and -not ([string]$v -eq '')) { return $v } }
            foreach ($k in @($Object.Keys)) {
                if ([string]$k -ieq $Name) { return $Object[$k] }
            }
            return $Default
        }
        if ($Object.PSObject -and $Object.PSObject.Properties.Name -contains $Name) {
            $v = $Object.$Name
            if ($null -ne $v -and -not ([string]$v -eq '')) { return $v }
        }
    } catch { }
    return $Default
}

function Export-JUnitReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$SuiteName = 'gbuild'
    )
    $total = @($Results).Count
    $fail = 0; $skip = 0
    foreach ($it in @($Results)) {
        $st = [string](Get-ReportFieldValue -Object $it -Name 'Status' -Default '')
        if ($st -in @('Failed','Blocked')) { $fail++ }
        elseif ($st -in @('Skipped')) { $skip++ }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8"?>')
    $escSuite = [string]$SuiteName -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
    [void]$sb.Append(('<testsuite name="{0}" tests="{1}" failures="{2}" skipped="{3}">' -f $escSuite, $total, $fail, $skip))
    foreach ($r in @($Results)) {
        $rawName = Get-ReportFieldValue -Object $r -Name 'Name' -Default ''
        if ([string]::IsNullOrWhiteSpace([string]$rawName)) { $rawName = Get-ReportFieldValue -Object $r -Name 'Test' -Default 'test' }
        $rawCls = Get-ReportFieldValue -Object $r -Name 'Class' -Default ''
        if ([string]::IsNullOrWhiteSpace([string]$rawCls)) { $rawCls = $SuiteName }
        $rawStatus = [string](Get-ReportFieldValue -Object $r -Name 'Status' -Default '')
        $name = ([string]$rawName -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
        $cls = ([string]$rawCls -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
        [void]$sb.Append(('<testcase classname="{0}" name="{1}">' -f $cls, $name))
        if ($rawStatus -in @('Failed','Blocked')) {
            $rawMsg = Get-ReportFieldValue -Object $r -Name 'Message' -Default ''
            if ([string]::IsNullOrWhiteSpace([string]$rawMsg)) { $rawMsg = Get-ReportFieldValue -Object $r -Name 'Reason' -Default 'failed' }
            $msg = ([string]$rawMsg -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
            [void]$sb.Append(('<failure message="{0}"/>' -f $msg))
        } elseif ($rawStatus -in @('Skipped')) {
            [void]$sb.Append('<skipped/>')
        }
        [void]$sb.Append('</testcase>')
    }
    [void]$sb.Append('</testsuite>')
    $dir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    # Single-source atomic write: delegate to SharedUtils when available so
    # this exporter never hand-rolls File.Replace + guid temp (Hygiene gate).
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Write-BuildTextFileAtomic')
    if (Get-Command Write-BuildTextFileAtomic -ErrorAction SilentlyContinue) {
        [void](Write-BuildTextFileAtomic -Path $OutputPath -Lines @($sb.ToString()))
    } else {
        [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $OutputPath
}

<#
.SYNOPSIS
    Exports security/policy findings to SARIF 2.1.0 (GitHub code-scanning compatible).
.DESCRIPTION
    Additive only. Consumes @{ Rule=; Message=; File=; Line=} findings.
#>
function Export-SarifReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ToolName = 'gbuild'
    )
    $rules = @(); $results = @(); $seen = @{}
    foreach ($f in @($Findings)) {
        $ruleId = [string](Get-ReportFieldValue -Object $f -Name 'Rule' -Default 'finding')
        if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = 'finding' }
        if (-not $seen.ContainsKey($ruleId)) {
            $seen[$ruleId] = $true
            $rules += @{ id = $ruleId; name = $ruleId; shortDescription = @{ text = $ruleId } }
        }
        $sev = [string](Get-ReportFieldValue -Object $f -Name 'Severity' -Default '')
        $level = 'note'
        if ($sev -eq 'Critical') { $level = 'error' }
        elseif ($sev -eq 'Warning') { $level = 'warning' }
        $msgText = [string](Get-ReportFieldValue -Object $f -Name 'Message' -Default $ruleId)
        $fileUri = [string](Get-ReportFieldValue -Object $f -Name 'File' -Default '')
        $lineNo = Get-ReportFieldValue -Object $f -Name 'Line' -Default 1
        $lineInt = 1
        try { $lineInt = [int]$lineNo } catch { $lineInt = 1 }
        if ($lineInt -le 0) { $lineInt = 1 }
        $results += @{
            ruleId = $ruleId
            level = $level
            message = @{ text = $msgText }
            locations = @(@{ physicalLocation = @{ artifactLocation = @{ uri = $fileUri }; region = @{ startLine = $lineInt } } })
        }
    }
    $sarif = @{ version = '2.1.0'; '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'; runs = @(@{ tool = @{ driver = @{ name = $ToolName; rules = @($rules) } }; results = @($results) }) }
    $dir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    # Single-source JSON write (atomic when SharedUtils is available).
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Write-BuildJsonFile')
    if (Get-Command Write-BuildJsonFile -ErrorAction SilentlyContinue) {
        [void](Write-BuildJsonFile -Path $OutputPath -Data $sarif -Depth 10 -Atomic)
    } else {
        [System.IO.File]::WriteAllText($OutputPath, (($sarif | ConvertTo-Json -Depth 10) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $OutputPath
}

<#
.SYNOPSIS
    Returns W3C trace-context headers derived from the build CorrelationId.
.DESCRIPTION
    L5 gap closure: tracing previously stopped at CorrelationId logging.
    Derives deterministic traceId (32 hex) + spanId (16 hex) from the
    CorrelationId hash so distributed steps can propagate W3C `traceparent`
    without a new dependency. Additive, no network I/O.
#>
function Get-BuildTraceContext {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $corr = ''
    try { if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId') { $corr = [string]$State.CorrelationId } } catch { }
    if ([string]::IsNullOrWhiteSpace($corr)) { $corr = [guid]::NewGuid().ToString('N') }
    # SharedUtils.Get-BuildStringHash is the owner. This inlined exactly the
    # shape that owner exists to prevent, and the stringHashDelegation adoption
    # class is the gate for it. The rendered value is unchanged (lowercase hex),
    # so traceparent output is byte-identical.
    $hex = Get-BuildStringHash -Text $corr
    $traceId = $hex.Substring(0, 32)
    $spanId = $hex.Substring(0, 16)
    return [PSCustomObject]@{ TraceId = $traceId; SpanId = $spanId; Traceparent = ("00-{0}-{1}-01" -f $traceId, $spanId); CorrelationId = $corr }
}

<#
.SYNOPSIS
    Records one test/lint gate outcome on the build state so it can be
    published as a JUnit artifact at the end of the run.
.DESCRIPTION
    Export-JUnitReport is a writer with no producer: nothing in the tree fed
    it a result, so a CI consumer asking for JUnit XML got nothing - and the
    `report.format = "junit"` value the shipped schema advertises was read by
    nobody. This is the producer side: the plugin test/lint gate records its
    verdict here, and Publish-BuildJUnitArtifact turns the collected verdicts
    into the XML file.
#>
function Add-BuildTestResult {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][object]$Result,
        [string]$Suite = 'gbuild'
    )
    $existing = @()
    if ($State.PSObject.Properties.Name -contains 'TestResults') {
        try { $existing = @($State.TestResults) } catch { $existing = @() }
    }
    $status = 'Succeeded'
    $message = ''
    try {
        $status = [string](Get-ReportFieldValue -Object $Result -Name 'Status' -Default 'Succeeded')
        $message = [string](Get-ReportFieldValue -Object $Result -Name 'Message' -Default '')
    } catch { }
    $record = [PSCustomObject]@{
        Name    = if ([string]::IsNullOrWhiteSpace($Suite)) { 'gbuild' } else { $Suite }
        Class   = if ([string]::IsNullOrWhiteSpace($Suite)) { 'gbuild' } else { $Suite }
        Status  = $status
        Message = $message
    }
    $all = @($existing) + @($record)
    if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
        Set-BuildStateProperty -State $State -Name 'TestResults' -Value $all -Force
    } else {
        $State | Add-Member -MemberType NoteProperty -Name 'TestResults' -Value $all -Force -ErrorAction SilentlyContinue
    }
    return $all.Count
}

<#
.SYNOPSIS
    Writes the build's collected test results as a JUnit XML artifact.
.DESCRIPTION
    Path: <report output dir>/junit/results.xml - the layout every CI
    consumer (GitHub, GitLab, Jenkins, Azure DevOps) expects. Returns the
    written path, or an empty string when there is nothing to publish.
#>
function Publish-BuildJUnitArtifact {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$SuiteName = 'gbuild',
        [string]$OutputPath = ''
    )
    $records = @()
    if ($State.PSObject.Properties.Name -contains 'TestResults') {
        try { $records = @($State.TestResults) } catch { $records = @() }
    }
    if ($records.Count -eq 0) { return '' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-ReportDirectory')
        if (-not (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue)) { return '' }
        $dir = Get-ReportDirectory -State $State
        if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
        $OutputPath = Join-Path (Join-Path $dir 'junit') 'results.xml'
    }
    return Export-JUnitReport -Results $records -OutputPath $OutputPath -SuiteName $SuiteName
}

<#
.SYNOPSIS
    Writes security/SAST findings as a SARIF 2.1.0 artifact.
.DESCRIPTION
    Path: <report output dir>/sarif/results.sarif. The SAST module already
    produces findings in the SARIF shape (Tool/Severity/Rule/File/Line/
    Message), so the findings are handed to the writer unchanged instead of
    being re-shaped per caller.
#>
function Publish-BuildSarifArtifact {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [object[]]$Findings = @(),
        [string]$ToolName = 'gbuild',
        [string]$OutputPath = ''
    )
    if ($null -eq $Findings -or $Findings.Count -eq 0) { return '' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-ReportDirectory')
        if (-not (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue)) { return '' }
        $dir = Get-ReportDirectory -State $State
        if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
        $OutputPath = Join-Path (Join-Path $dir 'sarif') 'results.sarif'
    }
    return Export-SarifReport -Findings $Findings -OutputPath $OutputPath -ToolName $ToolName
}

Export-ModuleMember -Function @('Initialize-ReportDir', 'Write-BuildMetric', 'Save-BuildReport', 'Write-TelemetryEntry', 'Show-BuildReport', 'Reset-ReportCache', 'Get-TelemetryConfigValue', 'Get-BuildTrend', 'Get-ReportFieldValue', 'Export-JUnitReport', 'Export-SarifReport', 'Get-BuildTraceContext', 'Add-BuildTestResult', 'Publish-BuildJUnitArtifact', 'Publish-BuildSarifArtifact')
