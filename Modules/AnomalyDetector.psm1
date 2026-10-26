
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildSetting'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'
Import-GBuildModuleIfMissing -Name 'ErrorHandling' -SentinelCommand 'Invoke-HistoryWriteWithRetry'
# Owner of Invoke-BuildSecretProtect, which Protect-AnomalyText delegates to.
Import-GBuildModuleIfMissing -Name 'SharedUtils' -SentinelCommand 'Invoke-BuildSecretProtect'
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Test-PathUnderRoots'
# Cache provides Enter-BuildHistoryLock for history file access
Import-GBuildModuleIfMissing -Name 'Cache' -SentinelCommand 'Enter-BuildHistoryLock'
# Shared preamble: root resolver, path resolver, config reader.
# Intentionally duplicated in RootCause.psm1 (not imported from a shared
# module): both files load through -Global imports where a shared preamble
# module hits module-scope issues, so each module carries its own copy.
# Keep the two copies byte-identical; the duplication is asserted by the
# near-duplicate hygiene check, not by an import.
$script:AnomalyHistoryPath = $null
$script:CircuitBreakerStates = @{}

function Get-DiagnosticRoot {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    foreach ($name in @('ProjectRoot', 'WorkingDir', 'ScriptRoot')) {
        $value = if ($State) { [string](Get-SectionValue -Section $State -Key $name -Default '') } else { '' }
        if ($value) {
            try { if ($name -eq 'ScriptRoot' -and (Split-Path -Leaf $value) -ieq 'Modules') { return (Split-Path -Parent $value) } } catch { }
            return $value
        }
    }
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        return [string](Get-BuildRootDirectory -State $State)
    }
    throw (Get-LocaleMessage -Key 'log.diagnostic.noRoot')
}

function Resolve-DiagnosticPath {
    param([PSCustomObject]$State, [string]$Path)
    $root = Get-DiagnosticRoot $State
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $root $Path)) }
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($root))) { return '' }
    return $candidate
}

function Resolve-AnomalyPath {
    param([PSCustomObject]$State, [string]$Path)
    return (Resolve-DiagnosticPath -State $State -Path $Path)
}

function Get-AnomalyConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)
    $section = if ($State) { Get-SectionValue -Section (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -Key 'anomaly' -Default $null } else { $null }
    $reportDir = if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { [string](Get-BuildSetting -Key 'ReportOutputDir' -State $State -Fallback 'build-reports') } else { 'build-reports' }
    $get = {
        param([string]$Key, [string]$Property, $Fallback)
        $value = Get-SectionValue -Section $section -Key $Property -Default $null
        if ($null -ne $value) { return $value }
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { return Get-BuildSetting -Key $Key -State $State -Fallback $Fallback }
        return $Fallback
    }
    $history = [string](& $get 'AnomalyHistoryPath' 'historyPath' (Join-Path $reportDir 'anomaly-history.jsonl'))
    $sampleProperty = Get-SectionValue -Section $section -Key 'sampleHistoryPath' -Default $null
    $sample = if ($null -ne $sampleProperty) { [string]$sampleProperty } else { [string](Join-Path $reportDir 'anomaly-samples.jsonl') }
    try { if ([System.IO.Path]::GetFullPath($sample) -eq [System.IO.Path]::GetFullPath($history)) { $sample = $history + '.samples' } } catch { }
    return [PSCustomObject]@{
        enabled = [bool](& $get 'AnomalyEnabled' 'enabled' $true)
        zScoreThreshold = [double](& $get 'AnomalyZScoreThreshold' 'zScoreThreshold' 3.0)
        ewmaAlpha = [double](& $get 'AnomalyEwmaAlpha' 'ewmaAlpha' 0.3)
        minSamples = [math]::Max(2, [int](& $get 'AnomalyMinSamples' 'minSamples' 10))
        historyPath = $history
        sampleHistoryPath = $sample
        sampleHistoryConfigured = ($null -ne $sampleProperty)
        maxHistoryEntries = [math]::Max(1, [int](& $get 'AnomalyMaxHistoryEntries' 'maxHistoryEntries' 500))
        alertOnAnomaly = [bool](& $get 'AnomalyAlertOnAnomaly' 'alertOnAnomaly' $true)
        defaultWindowSize = [math]::Max(2, [int](& $get 'AnomalyDefaultWindowSize' 'defaultWindowSize' 20))
        failureRateThreshold = [double](& $get 'AnomalyFailureRateThreshold' 'failureRateThreshold' 0.3)
        failureRateZScoreHigh = [double](& $get 'AnomalyFailureRateZScoreHigh' 'failureRateZScoreHigh' 2.5)
        failureRateZScoreCrit = [double](& $get 'AnomalyFailureRateZScoreCrit' 'failureRateZScoreCrit' 4.0)
        trendSlopeThreshold = [double](& $get 'AnomalyTrendSlopeThreshold' 'trendSlopeThreshold' 0.5)
        trendR2Threshold = [double](& $get 'AnomalyTrendR2Threshold' 'trendR2Threshold' 0.4)
        trendHighSlope = [double](& $get 'AnomalyTrendHighSlope' 'trendHighSlope' 2.0)
        criticalZScore = [double](& $get 'AnomalyCriticalZScore' 'criticalZScore' 5.0)
        highZScore = [double](& $get 'AnomalyHighZScore' 'highZScore' 4.0)
        ewmaMultiplier = [double](& $get 'AnomalyEwmaMultiplier' 'ewmaMultiplier' 2.0)
        failureRateHighZScore2 = [double](& $get 'AnomalyFailureRateHighZScore2' 'failureRateHighZScore2' 3.0)
        rollbackEnabled = [bool](Get-SectionValue -Section $section -Key 'rollbackEnabled' -Default $true)
    }
}

function ConvertTo-AnomalySampleRecord {
    param([hashtable]$Sample)
    return [PSCustomObject]@{ Schema = 'anomaly.sample.v1'; Timestamp = [string](Get-SectionValue -Section $Sample -Key 'Timestamp' -Default (Get-Date).ToString('o')); DurationSec = [math]::Max(0.0, [double](Get-SectionValue -Section $Sample -Key 'DurationSec' -Default 0)); Success = [bool](Get-SectionValue -Section $Sample -Key 'Success' -Default $true); ParallelJobs = [int](Get-SectionValue -Section $Sample -Key 'ParallelJobs' -Default 0); CacheHit = [bool](Get-SectionValue -Section $Sample -Key 'CacheHit' -Default $false); Incremental = [bool](Get-SectionValue -Section $Sample -Key 'Incremental' -Default $false) }
}

function Write-AnomalySample {
    param([hashtable]$Sample, [PSCustomObject]$State = $null)
    return Invoke-HistoryWriteWithRetry -OperationName 'anomaly sample write' -Action {
        $cfg = Get-AnomalyConfig -State $State
        $path = Resolve-AnomalyPath -State $State -Path $cfg.sampleHistoryPath
        $line = (ConvertTo-AnomalySampleRecord $Sample | ConvertTo-Json -Compress)
        $lock = Enter-BuildHistoryLock $path -HistoryName 'anomaly'
        try { $lines = [System.Collections.Generic.List[string]]::new(); foreach ($item in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$item) | Out-Null }; $lines.Add($line) | Out-Null; [void](Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries)) } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
}

function Get-AnomalySamples {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $cfg = Get-AnomalyConfig -State $State
    $paths = [System.Collections.Generic.List[string]]::new()
    $paths.Add((Resolve-AnomalyPath -State $State -Path $cfg.sampleHistoryPath)) | Out-Null
    if ($cfg.historyPath -ne $cfg.sampleHistoryPath) { $paths.Add((Resolve-AnomalyPath -State $State -Path $cfg.historyPath)) | Out-Null }
    if (-not $cfg.sampleHistoryConfigured -and (Get-Command Get-AutoTuneConfig -ErrorAction SilentlyContinue)) {
        try { $auto = Get-AutoTuneConfig -State $State; $legacy = Resolve-AnomalyPath -State $State -Path $auto.historyPath; if ($paths -notcontains $legacy) { $paths.Add($legacy) | Out-Null } } catch { }
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $lock = $null
        try { $lock = Enter-BuildHistoryLock $path -HistoryName 'anomaly'; $lines = @(Read-BuildHistoryLines -Path $path) } finally { if ($lock) { Exit-BuildFileLock -Lock $lock } }
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($line in @($lines | Select-Object -Last $cfg.maxHistoryEntries)) {
            try {
                $item = $line | ConvertFrom-Json -ErrorAction Stop
                $schema = [string](Get-SectionValue -Section $item -Key 'Schema' -Default '')
                if ($schema -and $schema -notin @('anomaly.sample.v1', 'autotune.sample.v1')) { continue }
                if ($null -eq (Get-SectionValue -Section $item -Key 'DurationSec' -Default $null)) { continue }
                $result.Add($item) | Out-Null
            } catch { }
        }
        if ($result.Count -gt 0) { return @($result) }
    }
    return @()
}

function Get-rollingStats {
    param([double[]]$Values, [int]$Window = 20)
    if ($null -eq $Values -or $Values.Count -eq 0) { return [PSCustomObject]@{ Mean = 0.0; StdDev = 0.0; Count = 0 } }
    $Window = [math]::Max(1, $Window)
    $windowValues = if ($Values.Count -gt $Window) { @($Values[-$Window..-1]) } else { @($Values) }
    $mean = ($windowValues | Measure-Object -Average).Average
    $variance = ($windowValues | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum / [double]$windowValues.Count
    return [PSCustomObject]@{ Mean = $mean; StdDev = [math]::Sqrt($variance); Count = $windowValues.Count }
}

function Get-DurationAnomaly {
    param([double]$CurrentDurationSec, [double[]]$HistoryDurations, [double]$ZScoreThreshold = 3.0, [double]$EwmaAlpha = 0.3, [int]$WindowSize = 20, [double]$CriticalZScore = 5.0, [double]$HighZScore = 4.0, [double]$EwmaMultiplier = 2.0)
    if (-not $PSBoundParameters.ContainsKey('CriticalZScore') -and (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) { try { $CriticalZScore = [double](Get-BuildDefault -Key 'AnomalyCriticalZScore' -Fallback 5.0) } catch { } }
    if (-not $PSBoundParameters.ContainsKey('HighZScore') -and (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) { try { $HighZScore = [double](Get-BuildDefault -Key 'AnomalyHighZScore' -Fallback 4.0) } catch { } }
    if (-not $PSBoundParameters.ContainsKey('EwmaMultiplier') -and (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) { try { $EwmaMultiplier = [double](Get-BuildDefault -Key 'AnomalyEwmaMultiplier' -Fallback 2.0) } catch { } }
    $stats = Get-rollingStats -Values $HistoryDurations -Window ([math]::Max(2, $WindowSize))
    $z = if ($stats.StdDev -gt 0) { ($CurrentDurationSec - $stats.Mean) / $stats.StdDev } else { 0.0 }
    $ewma = if ($HistoryDurations.Count -gt 0) { [double]$HistoryDurations[-1] } else { 0.0 }
    foreach ($value in @($HistoryDurations)) { $ewma = $EwmaAlpha * $value + (1.0 - $EwmaAlpha) * $ewma }
    $isAnomaly = $false; $severity = 'Normal'; $suggestion = 'Build duration is within expected range.'
    if ($z -gt $ZScoreThreshold) { $isAnomaly = $true; $severity = if ($z -gt $CriticalZScore) { 'Critical' } elseif ($z -gt $HighZScore) { 'High' } else { 'Medium' }; $suggestion = "Build duration is $([math]::Round($z,1)) sigma above the rolling mean." }
    elseif ($HistoryDurations.Count -gt 0 -and $CurrentDurationSec -gt $ewma * $EwmaMultiplier) { $isAnomaly = $true; $severity = 'Low'; $suggestion = "Build duration exceeds $([math]::Round($EwmaMultiplier))x the EWMA trend." }
    return [PSCustomObject]@{ IsAnomaly = $isAnomaly; ZScore = [math]::Round($z, 2); Ewma = [math]::Round($ewma, 2); RollingMean = [math]::Round($stats.Mean, 2); RollingStd = [math]::Round($stats.StdDev, 2); Severity = $severity; Suggestion = $suggestion }
}

function Get-FailureRateAnomaly {
    param([double]$CurrentFailureRate, [double[]]$HistoryFailureRates, [double]$Threshold = 0.3, [int]$WindowSize = 20, [double]$HighZScore = 2.5, [double]$CriticalZScore = 4.0, [double]$HighZScore2 = 3.0)
    if (-not $PSBoundParameters.ContainsKey('HighZScore2') -and (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) { try { $HighZScore2 = [double](Get-BuildDefault -Key 'AnomalyFailureRateHighZScore2' -Fallback 3.0) } catch { } }
    $stats = Get-rollingStats -Values $HistoryFailureRates -Window ([math]::Max(2, $WindowSize))
    $z = if ($stats.StdDev -gt 0) { ($CurrentFailureRate - $stats.Mean) / $stats.StdDev } else { 0.0 }
    $isAnomaly = $z -gt $HighZScore
    $severity = if (-not $isAnomaly) { 'Normal' } elseif ($z -gt $CriticalZScore) { 'Critical' } elseif ($z -gt $HighZScore2) { 'High' } else { 'Medium' }
    $suggestion = if ($isAnomaly) { "Failure rate is $([math]::Round($z,1)) sigma above the rolling baseline." } else { 'Failure rate is within expected range.' }
    return [PSCustomObject]@{ IsAnomaly = $isAnomaly; ZScore = [math]::Round($z, 2); RollingMean = [math]::Round($stats.Mean, 4); Severity = $severity; Suggestion = $suggestion }
}

function Get-AnomalyReport {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $cfg = Get-AnomalyConfig -State $State
    if (-not $cfg.enabled) { return [PSCustomObject]@{ Status = 'Disabled'; Anomalies = @(); Summary = ''; MaxSeverity = 'Normal'; SampleCount = 0 } }
    $samples = @(Get-AnomalySamples -State $State)
    if ($samples.Count -lt $cfg.minSamples) { return [PSCustomObject]@{ Status = 'InsufficientData'; Anomalies = @(); Summary = ''; MaxSeverity = 'Normal'; SampleCount = $samples.Count } }
    $latest = $samples[-1]
    $baselineSamples = if ($samples.Count -gt 1) { @($samples[0..($samples.Count - 2)]) } else { @() }
    $durations = @($baselineSamples | ForEach-Object { [double]$_.DurationSec })
    $successes = @($baselineSamples | ForEach-Object { [bool]$_.Success })
    $window = [math]::Min($cfg.defaultWindowSize, [math]::Max(1, $successes.Count))
    $failureRates = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $successes.Count; $i++) { $start = [math]::Max(0, $i - $window + 1); $slice = @($successes[$start..$i]); $failureRates.Add((@($slice | Where-Object { -not $_ }).Count / [double]$slice.Count)) | Out-Null }
    if ($successes.Count -gt 0) {
        $currentSlice = @($successes[([math]::Max(0, $successes.Count - $window))..($successes.Count - 1)])
        if (-not [bool]$latest.Success) { $currentSlice += $false } else { $currentSlice += $true }
        $currentFailureRate = @($currentSlice | Where-Object { -not $_ }).Count / [double]$currentSlice.Count
    } else { $currentFailureRate = if ([bool]$latest.Success) { 0.0 } else { 1.0 } }
    $duration = Get-DurationAnomaly -CurrentDurationSec ([double]$latest.DurationSec) -HistoryDurations $durations -ZScoreThreshold $cfg.zScoreThreshold -EwmaAlpha $cfg.ewmaAlpha -WindowSize $cfg.defaultWindowSize -CriticalZScore $cfg.criticalZScore -HighZScore $cfg.highZScore -EwmaMultiplier $cfg.ewmaMultiplier
    $failure = Get-FailureRateAnomaly -CurrentFailureRate $currentFailureRate -HistoryFailureRates @($failureRates) -Threshold $cfg.failureRateThreshold -WindowSize $cfg.defaultWindowSize -HighZScore $cfg.failureRateZScoreHigh -CriticalZScore $cfg.failureRateZScoreCrit -HighZScore2 $cfg.failureRateHighZScore2
    $anomalies = [System.Collections.Generic.List[object]]::new()
    if ($duration.IsAnomaly) { $anomalies.Add([PSCustomObject]@{ Dimension = 'Duration'; Severity = $duration.Severity; ZScore = $duration.ZScore; Detail = $duration.Suggestion; Tags = @('duration', 'performance') }) | Out-Null }
    if ($failure.IsAnomaly) { $anomalies.Add([PSCustomObject]@{ Dimension = 'FailureRate'; Severity = $failure.Severity; ZScore = $failure.ZScore; Detail = $failure.Suggestion; Tags = @('failures', 'stability') }) | Out-Null }
    $trendSlope = 0.0; $trendR2 = 0.0
    if ($durations.Count -ge 5) {
        $n = [math]::Min($cfg.defaultWindowSize, $durations.Count); $ys = @($durations[-$n..-1]); $xm = ($n - 1) / 2.0; $ym = ($ys | Measure-Object -Average).Average; $sxy = 0.0; $sxx = 0.0; $syy = 0.0
        for ($i = 0; $i -lt $n; $i++) { $dx = $i - $xm; $dy = $ys[$i] - $ym; $sxy += $dx * $dy; $sxx += $dx * $dx; $syy += $dy * $dy }
        if ($sxx -gt 0) { $trendSlope = $sxy / $sxx; if ($syy -gt 0) { $trendR2 = ($sxy * $sxy) / ($sxx * $syy) } }
        if ([math]::Abs($trendSlope) -gt $cfg.trendSlopeThreshold -and $trendR2 -gt $cfg.trendR2Threshold) { $direction = if ($trendSlope -gt 0) { 'increasing' } else { 'decreasing' }; $anomalies.Add([PSCustomObject]@{ Dimension = 'Trend'; Severity = if ($trendSlope -gt $cfg.trendHighSlope) { 'High' } else { 'Low' }; ZScore = [math]::Round([math]::Abs($trendSlope), 2); Detail = "Build duration shows a $direction trend (slope=$([math]::Round($trendSlope,2))s/sample, R²=$([math]::Round($trendR2,2)))."; Tags = @('trend', 'drift') }) | Out-Null }
    }
    $order = @('Normal', 'Low', 'Medium', 'High', 'Critical'); $maxSeverity = 'Normal'; foreach ($anomaly in $anomalies) { if ($order.IndexOf($anomaly.Severity) -gt $order.IndexOf($maxSeverity)) { $maxSeverity = $anomaly.Severity } }
    return [PSCustomObject]@{ Status = if ($anomalies.Count -gt 0) { 'AnomaliesDetected' } else { 'Healthy' }; SampleCount = $samples.Count; Anomalies = @($anomalies); MaxSeverity = $maxSeverity; Summary = "$($anomalies.Count) anomaly(ies) across $($samples.Count) samples (max severity: $maxSeverity)" }
}

function Write-AnomalyHistory {
    param([Parameter(Mandatory)][PSCustomObject]$Report, [PSCustomObject]$State = $null)
    $cfg = Get-AnomalyConfig -State $State
    if (-not $cfg.enabled) { return $false }
    try {
        $path = Resolve-AnomalyPath -State $State -Path $cfg.historyPath
        $entry = [PSCustomObject]@{ Schema = 'anomaly.report.v1'; Timestamp = (Get-Date).ToString('o'); Status = [string]$Report.Status; SampleCount = [int]$Report.SampleCount; AnomalyCount = @((Get-SectionValue -Section $Report -Key 'Anomalies' -Default @())).Count; MaxSeverity = [string](Get-SectionValue -Section $Report -Key 'MaxSeverity' -Default 'Normal'); CorrelationId = if ($State) { [string](Get-SectionValue -Section $State -Key 'CorrelationId' -Default '') } else { '' }; TenantId = if ($State) { [string](Get-SectionValue -Section $State -Key 'TenantId' -Default 'default') } else { 'default' } }
        $line = $entry | ConvertTo-Json -Compress
        $lock = Enter-BuildHistoryLock $path -HistoryName 'anomaly'
        try { $lines = [System.Collections.Generic.List[string]]::new(); foreach ($item in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$item) | Out-Null }; $lines.Add($line) | Out-Null; Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries) } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    } catch { return $false }
}

function Get-AnomalyTenantKey {
    param([PSCustomObject]$State)
    $tenant = if ($State) { [string](Get-SectionValue -Section $State -Key 'TenantId' -Default '') } else { '' }
    if ([string]::IsNullOrWhiteSpace($tenant)) { $tenant = 'default' }
    return $tenant
}

function Get-AnomalyCircuitBreakerState {
    param([PSCustomObject]$State = $null)
    $key = 'AnomalyCircuitBreaker:' + (Get-AnomalyTenantKey $State)
    $state = if ($State -and $State.SessionState) { $State.SessionState } else { $PSCmdlet.SessionState }
    try { if ($state.SessionStateDictionary.Keys -contains $key) { return $state.SessionStateDictionary[$key] } } catch { }
    if ($script:CircuitBreakerStates.ContainsKey($key)) { return $script:CircuitBreakerStates[$key] }
    return [PSCustomObject]@{ Enabled = $false; FailureCount = 0; MaxFailures = 5; CoolDownSec = 60; LastFailure = [datetime]::MinValue }
}

function Set-AnomalyCircuitBreakerState {
    param([PSCustomObject]$State, [int]$FailureCount, [int]$MaxFailures = 5, [int]$CoolDownSec = 60)
    $key = 'AnomalyCircuitBreaker:' + (Get-AnomalyTenantKey $State); $state = if ($State -and $State.SessionState) { $State.SessionState } else { $PSCmdlet.SessionState }
    $value = [PSCustomObject]@{ Enabled = $true; FailureCount = $FailureCount; MaxFailures = $MaxFailures; CoolDownSec = $CoolDownSec; LastFailure = Get-Date }
    try { $state.SessionStateDictionary[$key] = $value } catch { $script:CircuitBreakerStates[$key] = $value }
}

function Clear-AnomalyCircuitBreakerState {
    param([PSCustomObject]$State = $null)
    $key = 'AnomalyCircuitBreaker:' + (Get-AnomalyTenantKey $State); $state = if ($State -and $State.SessionState) { $State.SessionState } else { $PSCmdlet.SessionState }
    try { if ($state.SessionStateDictionary.Keys -contains $key) { $state.SessionStateDictionary.Remove($key) | Out-Null } } catch { }
    if ($script:CircuitBreakerStates.ContainsKey($key)) { $script:CircuitBreakerStates.Remove($key) }
}

function Test-AnomalyCircuitBreaker {
    param([PSCustomObject]$State = $null)
    $cb = Get-AnomalyCircuitBreakerState -State $State
    if ($cb.Enabled -and $cb.FailureCount -ge $cb.MaxFailures) { if (((Get-Date) - $cb.LastFailure).TotalSeconds -lt $cb.CoolDownSec) { return $true }; Clear-AnomalyCircuitBreakerState -State $State }
    return $false
}

function Invoke-AnomalyRollback {
    param([Parameter(Mandatory)][PSCustomObject]$Report, [PSCustomObject]$State)
    $cfg = Get-AnomalyConfig -State $State
    if (-not $cfg.enabled) { return $true }
    $critical = @($Report.Anomalies | Where-Object { $_.Severity -eq 'Critical' } | Select-Object -First 1)
    if ($critical.Count -eq 0) { return $true }
    if ($State) { try { $previous = Get-AnomalyCircuitBreakerState -State $State; Set-AnomalyCircuitBreakerState -State $State -FailureCount ([int]$previous.FailureCount + 1) } catch { } }
    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) { try { Send-BuildEvent -EventName $EVT_AUTO_ROLLBACK -Source $State -Data @{ dimension = $critical[0].Dimension; severity = $critical[0].Severity; timestamp = (Get-Date).ToString('o') } | Out-Null } catch { } }
    if (-not $cfg.rollbackEnabled) { return $false }
    if (Get-Command Set-BuildResult -ErrorAction SilentlyContinue) { try { Set-BuildResult -State $State -Success $false -Error "Critical anomaly detected in $($critical[0].Dimension)"; return $true } catch { return $false } }
    return $false
}

function Invoke-AnomalyPrevention {
    param([Parameter(Mandatory)][PSCustomObject]$Report, [PSCustomObject]$State)
    $cfg = Get-AnomalyConfig -State $State
    if (-not $cfg.enabled) { return $true }
    try { if (Test-AnomalyCircuitBreaker -State $State) { return $false } } catch { }
    $items = @($Report.Anomalies | Where-Object { $_.Dimension -in @('Trend', 'FailureRate') })
    if ($items.Count -eq 0) { return $true }
    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        foreach ($item in $items) {
            $eventName = if ($item.Dimension -eq 'Trend') { $EVT_TREND_DRIFT } else { $EVT_FAILURE_RATE_DRIFT }
            try { Send-BuildEvent -EventName $eventName -Source $State -Data @{ dimension = $item.Dimension; detail = [string]$item.Detail; timestamp = (Get-Date).ToString('o') } | Out-Null } catch { }
        }
    }
    return $true
}

function Protect-AnomalyText {
    param([AllowNull()][object]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    # Canonical routine, same shape as Security/Sast. The inline assignment regex
    # this replaces was missing passwd, access_key and credential, so an anomaly
    # report could carry those values in clear whenever Alerting was absent.
    # -State is forwarded so security.redactPatterns (tier 1 of the shared
    # ruleset) applies here too; dropping it silently exempted this sink from
    # project-configured redaction rules.
    return (Invoke-BuildSecretProtect -Text ([string]$Text) -State $State)
}

function Send-AnomalyAlert {
    param([Parameter(Mandatory)][PSCustomObject]$Report, [PSCustomObject]$State = $null)
    try {
        if (-not $Report -or @((Get-SectionValue -Section $Report -Key 'Anomalies' -Default @())).Count -eq 0) { return $false }
        try { if (Test-AnomalyCircuitBreaker -State $State) { return $false } } catch { }
        $cfg = Get-AnomalyConfig -State $State
        if (-not $cfg.alertOnAnomaly) { return $false }
        $severe = @($Report.Anomalies | Where-Object { $_.Severity -in @('Medium', 'High', 'Critical') })
        if ($severe.Count -eq 0) { return $false }
        $order = @('Low', 'Medium', 'High', 'Critical'); $top = 'Medium'; foreach ($item in $severe) { if ($order.IndexOf([string]$item.Severity) -gt $order.IndexOf($top)) { $top = [string]$item.Severity } }
        $map = @{ 'Low' = 'Info'; 'Medium' = 'Warning'; 'High' = 'Error'; 'Critical' = 'Critical' }; if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $configured = Get-BuildConstant -Key 'AnomalyAlertSeverityMap' -State $State -Fallback $null; if ($configured) { $map = $configured } } catch { } }
        $alertSeverity = [string](Get-SectionValue -Section $map -Key $top -Default 'Error'); if ($alertSeverity -notin @('Info', 'Warning', 'Error', 'Critical')) { $alertSeverity = 'Error' }
        $details = @($severe | ForEach-Object { "[$($_.Dimension)/$($_.Severity)] $(Protect-AnomalyText $_.Detail -State $State)" })
        $message = "[ANOMALY] $([string]$Report.Summary)"
        $data = @{ source = 'anomaly-detector'; maxSeverity = [string]$Report.MaxSeverity; anomalySeverity = $top; sampleCount = [int]$Report.SampleCount; details = $details }
        if ($State -and (Get-SectionValue -Section $State -Key 'CorrelationId' -Default $null)) { $data.correlationId = [string]$State.CorrelationId }
        try { [void](Invoke-AnomalyPrevention -Report $Report -State $State) } catch { }
        $sent = $false
        if (Get-Command Send-Alert -ErrorAction SilentlyContinue) { try { $sent = [bool](Send-Alert -Message $message -Severity $alertSeverity -State $State -Data $data) } catch { $sent = $false } }
        if (-not $sent) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $message 'Warn' $State; foreach ($detail in $details) { Write-Log "  $detail" 'Gray' $State } }
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) { try { Send-BuildEvent -EventName $EVT_ANOMALY_DETECTED -Source $State -Data $data | Out-Null } catch { } }
            if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) { try { Submit-BuildMetric -State $State -Step 'AnomalyDetected' -Success $true -ProjectName 'anomaly' -Configuration ([string]$Report.MaxSeverity) | Out-Null } catch { } }
        }
        try { [void](Invoke-AnomalyRollback -Report $Report -State $State) } catch { }
        return $sent
    } catch { return $false }
}

Export-ModuleMember -Function @('Get-AnomalyConfig', 'Get-DurationAnomaly', 'Get-FailureRateAnomaly', 'Get-AnomalyReport', 'Get-AnomalySamples', 'Write-AnomalySample', 'Write-AnomalyHistory', 'Send-AnomalyAlert', 'Get-AnomalyCircuitBreakerState', 'Set-AnomalyCircuitBreakerState', 'Clear-AnomalyCircuitBreakerState', 'Test-AnomalyCircuitBreaker', 'Invoke-AnomalyRollback', 'Invoke-AnomalyPrevention')
