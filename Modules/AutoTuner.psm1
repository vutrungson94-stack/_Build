
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildSetting'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'
Import-GBuildModuleIfMissing -Name 'ErrorHandling' -SentinelCommand 'Invoke-HistoryWriteWithRetry'
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Test-PathUnderRoots'

$script:AutoTuneHistoryPath = $null
$script:AutoTuneBackup = @{}

function Get-AutoTuneRoot {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    foreach ($name in @('ProjectRoot', 'WorkingDir')) {
        $value = if ($State) { [string](Get-SectionValue -Section $State -Key $name -Default '') } else { '' }
        if ($value) { return $value }
    }
    $scriptRoot = if ($State) { [string](Get-SectionValue -Section $State -Key 'ScriptRoot' -Default '') } else { '' }
    if ($scriptRoot) {
        try { if ((Split-Path -Leaf $scriptRoot) -ieq 'Modules') { return (Split-Path -Parent $scriptRoot) } } catch { }
        return $scriptRoot
    }
    return (Get-Location).ProviderPath
}

function Resolve-AutoTuneHistoryPath {
    param([PSCustomObject]$State, [string]$Path)
    $root = Get-AutoTuneRoot $State
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $root $Path)) }
    # History files are write targets, so containment is enforced rather than
    # merely canonicalized. This preserves the module's ProjectRoot/WorkingDir
    # root; only the StartsWith comparison is delegated. A relative escape or
    # rooted path outside that root fails closed to ''.
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($root))) { return '' }
    return $candidate
}

function Get-AutoTuneConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $section = if ($State) { Get-SectionValue -Section (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -Key 'autoTune' -Default $null } else { $null }
    $get = {
        param([string]$Key, [string]$Property, $Fallback)
        $value = Get-SectionValue -Section $section -Key $Property -Default $null
        if ($null -ne $value) { return $value }
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { return Get-BuildSetting -Key $Key -State $State -Fallback $Fallback }
        return $Fallback
    }
    $maxEntries = [int](& $get 'AutoTuneMaxHistoryEntries' 'maxHistoryEntries' 200)
    $minSamples = [int](& $get 'AutoTuneMinSamples' 'minSamplesBeforeTune' 5)
    return [PSCustomObject]@{
        enabled = [bool](& $get 'AutoTuneEnabled' 'enabled' $false)
        autoApply = [bool](& $get 'AutoTuneAutoApply' 'autoApply' $false)
        historyPath = [string](& $get 'AutoTuneHistoryPath' 'historyPath' 'build-reports/autotune-history.jsonl')
        maxHistoryEntries = [math]::Max(1, [math]::Min(10000, $maxEntries))
        minSamplesBeforeTune = [math]::Max(1, [math]::Min(10000, $minSamples))
        defaultParallelMax = [int](& $get 'AutoTuneDefaultParallelMax' 'defaultParallelMax' 8)
        parallelCeiling = [int](& $get 'AutoTuneParallelCeiling' 'parallelCeiling' 16)
        cacheMaxEntriesDefault = [int](& $get 'AutoTuneCacheMaxEntriesDefault' 'cacheMaxEntriesDefault' 256)
        cacheMaxSizeMbDefault = [int](& $get 'AutoTuneCacheMaxSizeMbDefault' 'cacheMaxSizeMbDefault' 512)
        defaultTimeoutMinutes = [int](& $get 'AutoTuneDefaultTimeoutMinutes' 'defaultTimeoutMinutes' 30)
        failRateThresholdLow = [double](& $get 'AutoTuneFailRateThresholdLow' 'failRateThresholdLow' 0.1)
        failRateThresholdHigh = [double](& $get 'AutoTuneFailRateThresholdHigh' 'failRateThresholdHigh' 0.3)
        avgDurationThreshold = [double](& $get 'AutoTuneAvgDurationThreshold' 'avgDurationThreshold' 300)
        timeoutMultiplier = [double](& $get 'AutoTuneTimeoutMultiplier' 'timeoutMultiplier' 1.5)
        timeoutRatio = [double](& $get 'AutoTuneTimeoutRatio' 'timeoutRatio' 0.8)
        incrementalRatio = [double](& $get 'AutoTuneIncrementalRatio' 'incrementalRatio' 0.7)
        cacheHitRateLow = [double](& $get 'AutoTuneCacheHitRateLow' 'cacheHitRateLow' 0.5)
        cacheHitRateHigh = [double](& $get 'AutoTuneCacheHitRateHigh' 'cacheHitRateHigh' 0.9)
        verifyEnabled = [bool](& $get 'AutoTuneVerifyEnabled' 'verifyEnabled' $true)
        rollbackEnabled = [bool](& $get 'AutoTuneRollbackEnabled' 'rollbackEnabled' $true)
    }
}

function New-AutoTuneEWMA {
    param([double]$Alpha, [double]$InitialValue = 0.0)
    return @{ Alpha = $Alpha; Ewma = $InitialValue; Count = 0 }
}

function AutoTuneEWMAUpdate {
    param([hashtable]$Tracker, [double]$Value)
    $Tracker.Ewma = $Tracker.Alpha * $Value + (1.0 - $Tracker.Alpha) * $Tracker.Ewma
    $Tracker.Count++
    return $Tracker
}

function New-AutoTuneRegressor {
    return @{ n = 0; SumX = 0.0; SumY = 0.0; SumXY = 0.0; SumX2 = 0.0; SumY2 = 0.0 }
}

function AutoTuneRegressorUpdate {
    param([hashtable]$Reg, [double]$x, [double]$y)
    $Reg.n++; $Reg.SumX += $x; $Reg.SumY += $y; $Reg.SumXY += $x * $y; $Reg.SumX2 += $x * $x; $Reg.SumY2 += $y * $y
    return $Reg
}

function AutoTuneRegressorResult {
    param([hashtable]$Reg)
    $n = [int]$Reg.n
    if ($n -lt 2) { return [PSCustomObject]@{ Slope = 0.0; Intercept = 0.0; R2 = 0.0; PValue = $null; Significance = 'not-computed' } }
    $denom = $n * $Reg.SumX2 - $Reg.SumX * $Reg.SumX
    $meanX = $Reg.SumX / $n
    $meanY = $Reg.SumY / $n
    if ([math]::Abs($denom) -lt 0.0000000001) { return [PSCustomObject]@{ Slope = 0.0; Intercept = $meanY; R2 = 0.0; PValue = $null; Significance = 'not-computed' } }
    $slope = ($n * $Reg.SumXY - $Reg.SumX * $Reg.SumY) / $denom
    $intercept = $meanY - $slope * $meanX
    $ssXX = $Reg.SumX2 - ($Reg.SumX * $Reg.SumX / $n)
    $ssYY = $Reg.SumY2 - ($Reg.SumY * $Reg.SumY / $n)
    $ssXY = $Reg.SumXY - ($Reg.SumX * $Reg.SumY / $n)
    $r2 = if ($ssXX -gt 0 -and $ssYY -gt 0) { [math]::Max(0.0, [math]::Min(1.0, ($ssXY * $ssXY) / ($ssXX * $ssYY))) } else { 0.0 }
    return [PSCustomObject]@{ Slope = $slope; Intercept = $intercept; R2 = $r2; PValue = $null; Significance = 'not-computed' }
}

function AutoTuneStatsAddSample {
    param([hashtable]$Stats, [double]$DurationSec, [bool]$Success, [int]$ParallelJobs, [bool]$CacheHit, [int]$CpuCount, [double]$MemoryGB)
    $Stats.Count++; $Stats.DurationSecSum += $DurationSec
    if ($Success) { $Stats.SuccessCount++ }
    if ($CacheHit) { $Stats.CacheHitCount++ }
    if ($ParallelJobs -gt 0) { [void]$Stats.ParallelJobs.Add($ParallelJobs) }
    if ($CpuCount -gt 0) { $Stats.CpuCount += $CpuCount }
    if ($MemoryGB -ge 0) { $Stats.MemoryGBSum += $MemoryGB }
    return $Stats
}

function AutoTuneStatsFinalize {
    param([hashtable]$Stats)
    $n = [int]$Stats.Count
    if ($n -eq 0) { return [PSCustomObject]@{ Count = 0; AvgDurationSec = 0; FailRate = 0; CacheHitRate = 0; ParallelJobs = 0; CpuCount = 0; MemoryGB = 0; SuccessCount = 0 } }
    return [PSCustomObject]@{ Count = $n; AvgDurationSec = $Stats.DurationSecSum / $n; FailRate = 1.0 - ($Stats.SuccessCount / $n); CacheHitRate = $Stats.CacheHitCount / $n; ParallelJobs = if ($Stats.ParallelJobs.Count -gt 0) { [int](($Stats.ParallelJobs | Measure-Object -Maximum).Maximum) } else { 0 }; CpuCount = if ($Stats.CpuCount -gt 0) { [int]($Stats.CpuCount / $n) } else { 0 }; MemoryGB = if ($Stats.MemoryGBSum -gt 0) { $Stats.MemoryGBSum / $n } else { 0 }; SuccessCount = $Stats.SuccessCount }
}

function ConvertTo-AutoTuneRecord {
    param([hashtable]$Sample)
    $timestamp = Get-SectionValue -Section $Sample -Key 'Timestamp' -Default (Get-Date).ToString('o')
    $duration = [double](Get-SectionValue -Section $Sample -Key 'DurationSec' -Default 0)
    if ($duration -lt 0) { $duration = 0 }
    $success = [bool](Get-SectionValue -Section $Sample -Key 'Success' -Default $true)
    $parallel = [int](Get-SectionValue -Section $Sample -Key 'ParallelJobs' -Default 0)
    $cpu = [int](Get-SectionValue -Section $Sample -Key 'CpuCount' -Default 0)
    $memory = [double](Get-SectionValue -Section $Sample -Key 'MemoryGB' -Default 0)
    $projectType = [string](Get-SectionValue -Section $Sample -Key 'ProjectType' -Default '')
    if ($projectType -match '(?i)(https?://|token|secret|password|api[_-]?key|sk-|ghp_)') { $projectType = 'redacted' }
    # Failure attribution, closes the RootCause -> AutoTuner loop. The tuner
    # previously saw only Success=$false, never WHY, so it could not learn
    # (e.g. distinguish "slow but green" from "failed on missing tool").
    # Orchestrator stamps the category the failure-path analysis computed.
    $failureCategory = [string](Get-SectionValue -Section $Sample -Key 'FailureCategory' -Default '')
    $failureConfidence = [math]::Max(0.0, [math]::Min(1.0, [double](Get-SectionValue -Section $Sample -Key 'FailureConfidence' -Default 0)))
    return [PSCustomObject]@{ Schema = 'autotune.sample.v1'; Timestamp = ([string]$timestamp); DurationSec = $duration; Success = $success; ProjectType = $projectType; ParallelJobs = $parallel; CacheHit = [bool](Get-SectionValue -Section $Sample -Key 'CacheHit' -Default $false); Incremental = [bool](Get-SectionValue -Section $Sample -Key 'Incremental' -Default $false); CpuCount = $cpu; MemoryGB = $memory; FailureCategory = $failureCategory; FailureConfidence = $failureConfidence }
}

function Write-AutoTuneSample {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Sample, [PSCustomObject]$State = $null)
    # L5 robustness: retry read-modify-write on lock contention. Previously a
    # single 5s lock attempt under parallel-suite load returned $false and
    # dropped the sample. Retry is safe: success returns immediately, only
    # lock-acquire failure retries; duplicate append is bounded by
    # maxHistoryEntries and harmless for EWMA/regression aggregates. Attempts
    # and delays are owned by ErrorHandling.Invoke-HistoryWriteWithRetry.
    return Invoke-HistoryWriteWithRetry -OperationName 'autotune sample write' -Action {
        $cfg = Get-AutoTuneConfig -State $State
        $path = Resolve-AutoTuneHistoryPath -State $State -Path $cfg.historyPath
        $record = ConvertTo-AutoTuneRecord -Sample $Sample
        $line = $record | ConvertTo-Json -Compress
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'autotune'
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($existing in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$existing) | Out-Null }
            $lines.Add($line) | Out-Null
            $kept = @($lines | Select-Object -Last $cfg.maxHistoryEntries)
            [void](Write-BuildHistoryLines -Path $path -Lines $kept)
        } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
}

function Get-AutoTuneSamples {
    param([PSCustomObject]$State, [string]$Path, [int]$Limit = 200)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lock = $null
    try {
        $lock = Enter-BuildHistoryLock -Path $Path -HistoryName 'autotune'
        $lines = @(Read-BuildHistoryLines -Path $Path)
    } finally { if ($lock) { Exit-BuildFileLock -Lock $lock } }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($lines | Select-Object -Last ([math]::Max(1, $Limit)))) {
        try {
            $item = $line | ConvertFrom-Json -ErrorAction Stop
            $schema = [string](Get-SectionValue -Section $item -Key 'Schema' -Default '')
            if ($schema -and $schema -ne 'autotune.sample.v1') { continue }
            if ($null -eq (Get-SectionValue -Section $item -Key 'DurationSec' -Default $null)) { continue }
            $result.Add($item) | Out-Null
        } catch { }
    }
    return @($result)
}

function Get-AutoTuneHostCapacity {
    param([PSCustomObject]$State = $null)
    $cpu = [Environment]::ProcessorCount
    $memory = 0.0
    try {
        if (Test-IsWindowsHost) {
            $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($computer) { $memory = [math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1) }
        } elseif (Test-Path -LiteralPath '/proc/meminfo') {
            $line = @(Get-Content -LiteralPath '/proc/meminfo' -ErrorAction Stop | Where-Object { $_ -match '^MemTotal:\s+(\d+)' } | Select-Object -First 1)
            if ($line.Count -gt 0 -and $line[0] -match '^MemTotal:\s+(\d+)') { $memory = [math]::Round(([double]$Matches[1] / 1024 / 1024), 1) }
        }
    } catch { }
    return [PSCustomObject]@{ CpuCount = $cpu; MemoryGB = $memory }
}

function Get-AutoTuneMLRecommendations {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $cfg = Get-AutoTuneConfig -State $State
    if (-not $cfg.enabled) { return [PSCustomObject]@{ Recommendations = @{}; SampleCount = 0 } }
    $path = Resolve-AutoTuneHistoryPath -State $State -Path $cfg.historyPath
    $samples = @(Get-AutoTuneSamples -State $State -Path $path -Limit $cfg.maxHistoryEntries)
    if ($samples.Count -lt $cfg.minSamplesBeforeTune) { return [PSCustomObject]@{ Recommendations = @{}; SampleCount = $samples.Count } }
    $capacity = Get-AutoTuneHostCapacity -State $State
    $alpha = 0.3
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { try { $alpha = [double](Get-BuildDefault -Key 'AutoTuneEwmaAlpha' -Fallback 0.3) } catch { } }
    $ewma = New-AutoTuneEWMA -Alpha $alpha -InitialValue ([double]$samples[0].DurationSec)
    $reg = New-AutoTuneRegressor
    $stats = @{ Count = 0; DurationSecSum = 0.0; SuccessCount = 0; CacheHitCount = 0; ParallelJobs = [System.Collections.ArrayList]::new(); CpuCount = 0; MemoryGBSum = 0.0 }
    $incremental = 0
    $index = 0
    foreach ($sample in $samples) {
        $duration = [math]::Max(0.0, [double]$sample.DurationSec)
        $success = if ($sample.PSObject.Properties.Name -contains 'Success') { [bool]$sample.Success } else { $true }
        $hit = if ($sample.PSObject.Properties.Name -contains 'CacheHit') { [bool]$sample.CacheHit } else { $false }
        $parallel = if ($sample.PSObject.Properties.Name -contains 'ParallelJobs') { [int]$sample.ParallelJobs } else { 0 }
        $cpu = if ($sample.PSObject.Properties.Name -contains 'CpuCount') { [int]$sample.CpuCount } else { 0 }
        $memory = if ($sample.PSObject.Properties.Name -contains 'MemoryGB') { [double]$sample.MemoryGB } else { 0 }
        $ewma = AutoTuneEWMAUpdate -Tracker $ewma -Value $duration
        $reg = AutoTuneRegressorUpdate -Reg $reg -x $index -y $duration
        $stats = AutoTuneStatsAddSample -Stats $stats -DurationSec $duration -Success $success -ParallelJobs $parallel -CacheHit $hit -CpuCount $cpu -MemoryGB $memory
        if ($sample.PSObject.Properties.Name -contains 'Incremental' -and [bool]$sample.Incremental) { $incremental++ }
        $index++
    }
    $final = AutoTuneStatsFinalize -Stats $stats
    $rec = [ordered]@{}
    $parallelValue = [math]::Min([int]$capacity.CpuCount, $cfg.parallelCeiling)
    if ($final.AvgDurationSec -gt $cfg.avgDurationThreshold -and $final.FailRate -lt $cfg.failRateThresholdLow) { $parallelValue = [math]::Min([int]$capacity.CpuCount, $cfg.parallelCeiling) }
    elseif ($final.FailRate -gt $cfg.failRateThresholdHigh -and $parallelValue -gt 1) { $parallelValue = [math]::Max(1, [int][math]::Floor($parallelValue / 2)) }
    # L5: trend-gated early warning (additive, never removes threshold recs).
    # Failure regressor tracks 1-success over time; a positive slope with
    # meaningful R2 means failures are RISING even if the absolute failRate
    # has not crossed the threshold yet. In that case ensure a conservative
    # parallel reduction exists. Identical-success histories (slope 0, R2 0)
    # are unaffected, preserving existing behaviour/tests.
    $failReg = New-AutoTuneRegressor
    $fi = 0
    foreach ($sample in $samples) {
        $ok = if ($sample.PSObject.Properties.Name -contains 'Success') { [bool]$sample.Success } else { $true }
        $failReg = AutoTuneRegressorUpdate -Reg $failReg -x $fi -y $(if ($ok) { 0.0 } else { 1.0 })
        $fi++
    }
    $failTrend = AutoTuneRegressorResult -Reg $failReg
    if ($failTrend.R2 -ge 0.5 -and $failTrend.Slope -gt 0.02 -and $parallelValue -gt 1 -and -not $rec.Contains('build.maxParallelJobs')) {
        $rec['build.maxParallelJobs'] = [math]::Max(1, [int][math]::Floor($parallelValue / 2))
    }
    if ($parallelValue -gt 0 -and $parallelValue -ne $cfg.defaultParallelMax) { $rec['build.maxParallelJobs'] = $parallelValue }
    $entries = if ($final.CacheHitRate -lt $cfg.cacheHitRateLow) { [math]::Min($cfg.cacheMaxEntriesDefault * 2, 1024) } else { $cfg.cacheMaxEntriesDefault }
    $size = if ($final.CacheHitRate -lt $cfg.cacheHitRateLow) { [math]::Min($cfg.cacheMaxSizeMbDefault * 2, 2048) } else { $cfg.cacheMaxSizeMbDefault }
    $rec['build.cacheLocal.maxEntries'] = [int]$entries; $rec['build.cacheLocal.maxSizeMb'] = [int]$size
    if ($final.AvgDurationSec -gt 0 -and ($final.AvgDurationSec / 60) -gt ($cfg.defaultTimeoutMinutes * $cfg.timeoutRatio)) { $rec['build.timeoutMinutes'] = [int][math]::Ceiling(($final.AvgDurationSec / 60) * $cfg.timeoutMultiplier) }
    if ($incremental / [double]$samples.Count -gt $cfg.incrementalRatio) { $rec['build.enableIncremental'] = $true }
    $regression = AutoTuneRegressorResult -Reg $reg
    # Confidence drives whether Invoke-AutoTuneApply treats a recommendation as
    # auto-appliable or advisory-only. High R2 + sufficient samples = high;
    # low R2 = low (threshold recs still returned for compat, but callers can
    # gate auto-apply on this). Previously R2 was computed and discarded.
    $conf = if ($samples.Count -ge [math]::Max($cfg.minSamplesBeforeTune, 10) -and $regression.R2 -ge 0.5) { 'high' } elseif ($regression.R2 -ge 0.3) { 'medium' } else { 'low' }
    return [PSCustomObject]@{ Recommendations = $rec; SampleCount = $samples.Count; FailRate = [math]::Round($final.FailRate, 2); AvgDurationSec = [math]::Round($final.AvgDurationSec, 1); CacheHitRate = [math]::Round($final.CacheHitRate, 2); CpuCount = $capacity.CpuCount; MemoryGB = [math]::Round($final.MemoryGB, 1); EwmaDurationSec = [math]::Round($ewma.Ewma, 1); RegSlopeDuration = [math]::Round($regression.Slope, 4); RegR2Duration = [math]::Round($regression.R2, 4); RegSignificanceDuration = $regression.Significance; TrendConfidence = $conf; FailTrendSlope = [math]::Round($failTrend.Slope, 4); FailTrendR2 = [math]::Round($failTrend.R2, 4) }
}

function Get-AutoTunePathState {
    param($Root, [string]$Path)
    $parts = @($Path -split '\.')
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $next = Get-SectionValue -Section $node -Key $parts[$i] -Default $null
        if ($null -eq $next) { return [PSCustomObject]@{ Found = $false; Node = $null; Leaf = $parts[-1]; Parent = $node } }
        $node = $next
    }
    $leaf = $parts[-1]
    $found = $null -ne (Get-SectionValue -Section $node -Key $leaf -Default $null)
    return [PSCustomObject]@{ Found = $found; Node = $node; Leaf = $leaf; Parent = $node }
}

function Set-AutoTunePathValue {
    param($Root, [string]$Path, $Value)
    $parts = @($Path -split '\.'); $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $next = Get-SectionValue -Section $node -Key $parts[$i] -Default $null
        if ($null -eq $next) {
            $next = [PSCustomObject]@{}
            if ($node -is [System.Collections.IDictionary]) { $node[$parts[$i]] = $next } else { $node | Add-Member -MemberType NoteProperty -Name $parts[$i] -Value $next -Force }
        }
        $node = $next
    }
    $leaf = $parts[-1]
    if ($node -is [System.Collections.IDictionary]) { $node[$leaf] = $Value } else { if ($node.PSObject.Properties.Name -contains $leaf) { $node.$leaf = $Value } else { $node | Add-Member -MemberType NoteProperty -Name $leaf -Value $Value -Force } }
}

function Remove-AutoTunePathValue {
    param($Root, [string]$Path)
    $state = Get-AutoTunePathState -Root $Root -Path $Path
    if (-not $state.Found) { return }
    if ($state.Node -is [System.Collections.IDictionary]) { $state.Node.Remove($state.Leaf) } else { $state.Node.PSObject.Properties.Remove($state.Leaf) }
}

function Test-AutoTuneValue {
    param([string]$Key, $Value, [PSCustomObject]$State = $null)
    $cfg = Get-AutoTuneConfig -State $State
    switch ($Key) {
        'build.maxParallelJobs' { return ([int]$Value -ge 1 -and [int]$Value -le $cfg.parallelCeiling) }
        'build.timeoutMinutes' { return ([double]$Value -gt 0 -and [double]$Value -le 480) }
        'build.cacheLocal.maxEntries' { return ([int]$Value -ge 16 -and [int]$Value -le 4096) }
        'build.cacheLocal.maxSizeMb' { return ([int]$Value -ge 64 -and [int]$Value -le 8192) }
        'build.enableIncremental' { return $Value -is [bool] }
        default { return $false }
    }
}

function Invoke-AutoTuneApply {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $cfg = Get-AutoTuneConfig -State $State
    if (-not $cfg.enabled -or -not $cfg.autoApply -or -not $State -or -not (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null)) { return @() }
    # L5 OPM pilot gate: auto-apply halts while a pilot proposal is pending
    # approval. Fail-open (no proposal file -> $true) so every flow that never
    # created a proposal behaves exactly as before. Silent by design: the
    # proposal ledger records why, not the build log.
    $pilotOk = $true
    try { $pilotOk = Test-AutoTunePilotApproved -State $State } catch { $pilotOk = $true }
    if (-not $pilotOk) { return @() }
    $root = Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null
    $recommendations = Get-AutoTuneMLRecommendations -State $State
    $applied = @()
    foreach ($key in @($recommendations.Recommendations.Keys)) {
        $value = $recommendations.Recommendations[$key]
        if (-not (Test-AutoTuneValue -Key $key -Value $value -State $State)) { continue }
        $pathState = Get-AutoTunePathState -Root $root -Path $key
        if (-not $script:AutoTuneBackup.ContainsKey($key)) { $script:AutoTuneBackup[$key] = @{ HadPrevious = $pathState.Found; Previous = $(if ($pathState.Found) { Get-SectionValue -Section $pathState.Node -Key $pathState.Leaf -Default $null } else { $null }); Applied = $value } }
        Set-AutoTunePathValue -Root $root -Path $key -Value $value
        if ($cfg.verifyEnabled) {
            $check = Get-AutoTunePathState -Root $root -Path $key
            $actual = if ($check.Found) { Get-SectionValue -Section $check.Node -Key $check.Leaf -Default $null } else { $null }
            if (-not (Test-AutoTuneValue -Key $key -Value $actual -State $State)) { if ($script:AutoTuneBackup[$key].HadPrevious) { Set-AutoTunePathValue -Root $root -Path $key -Value $script:AutoTuneBackup[$key].Previous } else { Remove-AutoTunePathValue -Root $root -Path $key }; continue }
        }
        $applied += $key
    }
    # COMPENSATING ACTION. Undo-AutoTuneApply is the other half of this
    # function, and nothing ever called it: the tuned values stayed applied
    # after a build that FAILED, so a run that crashed on an unrelated step
    # still changed the project's configuration. The rollback stack is the
    # platform's compensation channel (Build.psm1 registers the cache purge
    # and the output-dir restore the same way), so the undo belongs there.
    # GetNewClosure is REQUIRED: the action runs later, inside
    # ErrorHandling.Invoke-Rollback, and must still see THIS $State.
    if ($applied.Count -gt 0 -and (Get-Command Register-RollbackAction -ErrorAction SilentlyContinue)) {
        try {
            $undoState = $State
            Register-RollbackAction -Name 'UndoAutoTuneApply' -Context @{ Applied = @($applied) } -Action {
                if (-not (Get-Command Undo-AutoTuneApply -ErrorAction SilentlyContinue)) { return }
                $undoed = @(Undo-AutoTuneApply -State $undoState)
                if ($undoed.Count -gt 0) {
                    Write-Log (Resolve-LogMessage -Key 'log.autotune.undone' -MessageArgs @([string]($undoed -join ', ')) -Fallback '[AUTOTUNE] Reverted tuned values after a failed build: {0}') 'Warn' $undoState
                }
            }.GetNewClosure()
        } catch { }
    }
    return $applied
}

function Undo-AutoTuneApply {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    if (-not $State -or -not (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -or $script:AutoTuneBackup.Count -eq 0) { return @() }
    $root = Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null
    $restored = @()
    foreach ($key in @($script:AutoTuneBackup.Keys)) {
        $entry = $script:AutoTuneBackup[$key]
        $pathState = Get-AutoTunePathState -Root $root -Path $key
        if ($pathState.Found -and $entry.ContainsKey('Applied')) {
            $actual = Get-SectionValue -Section $pathState.Node -Key $pathState.Leaf -Default $null
            if ($actual -ne $entry.Applied) { continue }
        }
        try {
            if ($entry.HadPrevious) { Set-AutoTunePathValue -Root $root -Path $key -Value $entry.Previous } elseif ($pathState.Found) { Remove-AutoTunePathValue -Root $root -Path $key }
            $restored += $key
        } catch { }
    }
    $script:AutoTuneBackup = @{}
    return $restored
}

function Get-AutoTuneRecommendations { param([PSCustomObject]$State = $null); return Get-AutoTuneMLRecommendations -State $State }

<#
.SYNOPSIS
    Resolves the pilot-proposal ledger path (next to the tune history).
.DESCRIPTION
    L5 OPM: every tuning change first lands as a proposal that a pilot must
    approve. No new config key and no schema change: the ledger lives next to
    the existing autotune history file. Fail-closed to '' outside the root.
#>
function Resolve-AutoTuneProposalPath {
    param([PSCustomObject]$State)
    $cfg = Get-AutoTuneConfig -State $State
    $hist = Resolve-AutoTuneHistoryPath -State $State -Path $cfg.historyPath
    if ([string]::IsNullOrWhiteSpace($hist)) { return '' }
    $dir = $null
    try { $dir = Split-Path $hist -Parent } catch { $dir = $null }
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    $candidate = Join-Path $dir 'autotune-proposals.jsonl'
    $root = Get-AutoTuneRoot $State
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($root))) { return '' }
    return $candidate
}

<#
.SYNOPSIS
    Records a tuning change as a pilot proposal (Status=Proposed).
.DESCRIPTION
    Returns the proposal object (with its Id) on success, $null when the
    ledger is unreachable. Per-key validation stays at apply time
    (Test-AutoTuneValue in Invoke-AutoTuneApply): the proposal is the review
    artefact, the pilot is what validates it.
#>
function New-AutoTuneProposal {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][hashtable]$Changes, [PSCustomObject]$State = $null, [string]$PilotScope = 'pilot')
    $scope = 'pilot'
    if (-not [string]::IsNullOrWhiteSpace($PilotScope)) { $scope = [string]$PilotScope }
    $entry = [PSCustomObject]@{
        Schema     = 'autotune.proposal.v1'
        Id         = ([guid]::NewGuid().ToString('N'))
        CreatedAt  = (Get-Date).ToString('o')
        Changes    = $Changes
        PilotScope = $scope
        Status     = 'Proposed'
    }
    $ok = Invoke-HistoryWriteWithRetry -OperationName 'autotune proposal write' -Action {
        $cfg = Get-AutoTuneConfig -State $State
        $path = Resolve-AutoTuneProposalPath -State $State
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $line = $entry | ConvertTo-Json -Compress
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'autotune-proposal'
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($existing in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$existing) | Out-Null }
            $lines.Add($line) | Out-Null
            $kept = @($lines | Select-Object -Last $cfg.maxHistoryEntries)
            [void](Write-BuildHistoryLines -Path $path -Lines $kept)
        } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
    if ($ok) { return $entry }
    return $null
}

<#
.SYNOPSIS
    True when auto-apply may proceed under the pilot policy.
.DESCRIPTION
    Fail-open $true on ANY read problem (missing file, corrupt line, missing
    helpers): a flow that never created a proposal must behave exactly as
    before. With -ProposalId, only that proposal is judged (unknown id ->
    $true). Without it, any proposal still in Status=Proposed blocks the apply
    until Approve-AutoTuneProposal moves it to Approved.
#>
function Test-AutoTunePilotApproved {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State = $null, [string]$ProposalId = '')
    try {
        $path = Resolve-AutoTuneProposalPath -State $State
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
        $lock = $null
        $lines = @()
        try {
            $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'autotune-proposal'
            $lines = @(Read-BuildHistoryLines -Path $path)
        } finally { if ($lock) { Exit-BuildFileLock -Lock $lock } }
        $proposals = @()
        foreach ($line in $lines) {
            try {
                $item = $line | ConvertFrom-Json -ErrorAction Stop
                if ([string](Get-SectionValue -Section $item -Key 'Schema' -Default '') -ne 'autotune.proposal.v1') { continue }
                $proposals += $item
            } catch { }
        }
        if ($proposals.Count -eq 0) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($ProposalId)) {
            foreach ($p in $proposals) {
                if ([string](Get-SectionValue -Section $p -Key 'Id' -Default '') -eq $ProposalId) {
                    return ([string](Get-SectionValue -Section $p -Key 'Status' -Default '') -eq 'Approved')
                }
            }
            return $true
        }
        foreach ($p in $proposals) {
            if ([string](Get-SectionValue -Section $p -Key 'Status' -Default '') -eq 'Proposed') { return $false }
        }
        return $true
    } catch { return $true }
}

function Approve-AutoTuneProposal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Id, [string]$Decision = 'Approved', [string]$Evidence = '', [PSCustomObject]$State = $null)
    $d = 'Approved'
    if ($Decision -eq 'Rejected') { $d = 'Rejected' }
    return Invoke-HistoryWriteWithRetry -OperationName 'autotune proposal decision' -Action {
        $path = Resolve-AutoTuneProposalPath -State $State
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'autotune-proposal'
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            $found = $false
            foreach ($item in @(Read-BuildHistoryLines -Path $path)) {
                $out = [string]$item
                try {
                    $e = $item | ConvertFrom-Json -ErrorAction Stop
                    if ([string](Get-SectionValue -Section $e -Key 'Id' -Default '') -eq $Id) {
                        $e.Status = $d
                        $e | Add-Member -NotePropertyName 'DecidedAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force
                        $e | Add-Member -NotePropertyName 'Evidence' -NotePropertyValue ([string]$Evidence) -Force
                        $out = ($e | ConvertTo-Json -Compress)
                        $found = $true
                    }
                } catch { }
                $lines.Add($out) | Out-Null
            }
            if (-not $found) { return $false }
            $cfg = Get-AutoTuneConfig -State $State
            [void](Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries))
        } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
}

Export-ModuleMember -Function @('Get-AutoTuneConfig', 'Get-AutoTuneHostCapacity', 'Write-AutoTuneSample', 'Get-AutoTuneSamples', 'Get-AutoTuneMLRecommendations', 'Get-AutoTuneRecommendations', 'Invoke-AutoTuneApply', 'Undo-AutoTuneApply', 'Test-AutoTuneValue', 'Resolve-AutoTuneProposalPath', 'New-AutoTuneProposal', 'Test-AutoTunePilotApproved', 'Approve-AutoTuneProposal')
