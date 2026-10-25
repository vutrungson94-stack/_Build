
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'

$script:Metrics = [System.Collections.ArrayList]::new()
$script:HttpListener = $null
$script:ListenerRunning = $false
$script:ListenerPort = 0
$script:ListenerRunspace = $null
$script:MetricsSync = [hashtable]::Synchronized(@{ Text = '' })

# Single funnel for this module's user-visible messages. Metrics is loaded before
# Logging in some bootstrap orders, so a direct Write-Log call would be a
# hard dependency; every emit is best-effort and never fails a build.
function Write-MetricLog {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string[]]$MessageArgs = @(),
        [string]$Level = 'DarkGray',
        $State
    )

Set-StrictMode -Version 1.0
    try {
        $text = if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key $Key -MessageArgs $MessageArgs } else { $Key }
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $text $Level $State }
    } catch { }
}

function Update-MetricsText {
    try { $script:MetricsSync.Text = $script:Registry.ToPrometheus() } catch { }
}

class MetricRegistry {
    [System.Collections.ArrayList] $Metrics
    [hashtable] $Aggregates
    [object] $SyncRoot
    [int] $MaxSamples

    MetricRegistry([System.Collections.ArrayList]$Store) {
        $this.Metrics = $Store
        $this.Aggregates = @{}
        $this.SyncRoot = New-Object object
        $this.MaxSamples = 10000
    }

    [string] GetKey([PSCustomObject]$Metric) {
        $name = [string]$Metric.Name
        $labels = @{}
        if ($Metric.PSObject.Properties.Name -contains 'Labels' -and $Metric.Labels) {
            if ($Metric.Labels -is [System.Collections.IDictionary]) {
                foreach ($key in $Metric.Labels.Keys) { $labels[[string]$key] = [string]$Metric.Labels[$key] }
            } else {
                foreach ($property in $Metric.Labels.PSObject.Properties) { $labels[$property.Name] = [string]$property.Value }
            }
        }
        $parts = @()
        foreach ($key in @($labels.Keys | Sort-Object)) { $parts += ('{0}={1}' -f $key, $labels[$key]) }
        return $name + '|' + ($parts -join ',')
    }

    [void] Register([PSCustomObject]$Metric) {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            $key = $this.GetKey($Metric)
            $name = [string]$Metric.Name
            $type = [string]$Metric.Type
            $value = [double]$Metric.Value
            $labels = @{}
            if ($Metric.PSObject.Properties.Name -contains 'Labels' -and $Metric.Labels) {
                if ($Metric.Labels -is [System.Collections.IDictionary]) {
                    foreach ($labelKey in $Metric.Labels.Keys) { $labels[[string]$labelKey] = [string]$Metric.Labels[$labelKey] }
                } else {
                    foreach ($property in $Metric.Labels.PSObject.Properties) { $labels[$property.Name] = [string]$property.Value }
                }
            }
            if ($this.Aggregates.ContainsKey($key)) {
                $entry = $this.Aggregates[$key]
                if ($type -eq 'counter') { $entry.Value = [double]$entry.Value + $value } else { $entry.Value = $value }
                $entry.Type = $type
                $entry.Timestamp = $Metric.Timestamp
            } else {
                $help = if ($Metric.PSObject.Properties.Name -contains 'Help') { [string]$Metric.Help } else { '' }
                $timestamp = if ($Metric.PSObject.Properties.Name -contains 'Timestamp') { $Metric.Timestamp } else { [DateTime]::UtcNow }
                $this.Aggregates[$key] = @{ Key = $key; Name = $name; Type = $type; Help = $help; Labels = $labels; Value = $value; Timestamp = $timestamp }
            }
            [void]$this.Metrics.Add($Metric)
            while ($this.Metrics.Count -gt $this.MaxSamples) { $this.Metrics.RemoveAt(0) }
        } finally {
            [System.Threading.Monitor]::Exit($this.SyncRoot)
        }
    }

    [void] Clear() {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try { $this.Metrics.Clear(); $this.Aggregates = @{} } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
    }

    [System.Collections.Generic.List[object]] GetAggregatedSeries() {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            $result = [System.Collections.Generic.List[object]]::new()
            foreach ($key in @($this.Aggregates.Keys | Sort-Object)) { $result.Add($this.Aggregates[$key]) }
            return $result
        } finally { [System.Threading.Monitor]::Exit($this.SyncRoot) }
    }

    [string] FormatLabels([hashtable]$Labels) {
        if ($null -eq $Labels -or $Labels.Count -eq 0) { return '' }
        $pairs = @()
        foreach ($key in @($Labels.Keys | Sort-Object)) {
            $escapedKey = ([string]$key).Replace('\', '\\').Replace('"', '\"')
            $value = ([string]$Labels[$key]).Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r')
            $pairs += ('{0}="{1}"' -f $escapedKey, $value)
        }
        return '{' + ($pairs -join ',') + '}'
    }

    [string] FormatValue([double]$Value) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    [string] ToPrometheus() {
        $lines = [System.Collections.Generic.List[string]]::new()
        $declared = @{}
        foreach ($entry in $this.GetAggregatedSeries()) {
            $sampleType = if ($entry.Type -eq 'histogram') { 'gauge' } else { [string]$entry.Type }
            if (-not $declared.ContainsKey($entry.Name)) {
                $declared[$entry.Name] = $true
                if ($entry.Help) {
                    $help = ([string]$entry.Help).Replace('\', '\\').Replace("`n", '\n').Replace("`r", '\r')
                    $lines.Add('# HELP {0} {1}' -f @($entry.Name, $help)) | Out-Null
                }
                $lines.Add('# TYPE {0} {1}' -f @($entry.Name, $sampleType)) | Out-Null
            }
            $lines.Add(('{0}{1} {2}' -f @($entry.Name, $this.FormatLabels($entry.Labels), $this.FormatValue([double]$entry.Value)))) | Out-Null
        }
        return ($lines -join "`n")
    }
}

$script:Registry = [MetricRegistry]::new($script:Metrics)

function Get-MetricConfigValue {
    param($State, [string]$Path, $Default = $null)
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { return Get-ConfigValue -Path $Path -State $State -Default $Default }
    return $Default
}

function Get-MetricSectionValue {
    param($Section, [string]$Key, $Default = $null)
    # Delegates entirely to the canonical accessor. The 9-line preamble this
    # replaced was duplicated in eight modules and justified by a comment claiming
    # Get-SectionValue was "case-SENSITIVE for ordinal dictionaries" - no longer
    # true: Get-SectionValue falls back to an -ieq key scan and uses .Contains so
    # OrderedDictionary works.
    return Get-SectionValue -Section $Section -Key $Key -Default $Default
}

function Get-TelemetryConfig {
    param([PSCustomObject]$State)
    $defaultPort = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'MetricsPort' -State $State -Fallback 9100) } else { 9100 }
    # Stated ONCE. This read carried the literal in BOTH arms - inside
    # -Fallback and again in the `else` taken when BuildConstants is absent -
    # so a retune had to land in two places and a partial edit silently
    # produced two different default addresses. The constant remains owned by
    # BuildConstants; this local exists only so the survival default is stated
    # once per function instead of once per branch.
    $metricsBindAddressFallback = 'localhost'
    $defaultAddress = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'MetricsBindAddress' -State $State -Fallback $metricsBindAddressFallback) } else { $metricsBindAddressFallback }
    $defaultPath = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'PrometheusMetricsPath' -State $State -Fallback '/metrics/') } else { '/metrics/' }
    $defaultOtelMetrics = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'OtlpMetricsPath' -State $State -Fallback '/v1/metrics') } else { '/v1/metrics' }
    $defaultOtelTraces = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'OtlpTracesPath' -State $State -Fallback '/v1/traces') } else { '/v1/traces' }
    $defaultOtelDepth = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'OtlpJsonDepth' -State $State -Fallback 10) } else { 10 }
    $cfg = @{ enabled = $true; configured = $false; prometheus = @{ enabled = $false; port = $defaultPort; bindAddress = $defaultAddress; altPorts = @(); metricsPath = $defaultPath }; otel = @{ enabled = $false; endpoint = ''; metricsPath = $defaultOtelMetrics; tracesPath = $defaultOtelTraces; jsonDepth = $defaultOtelDepth } }
    $telemetry = Get-MetricConfigValue -State $State -Path 'telemetry' -Default $null
    if ($null -ne $telemetry) {
        $cfg.configured = $true
        $rootEnabled = Get-MetricSectionValue $telemetry 'enabled' $null
        if ($null -ne $rootEnabled) { $cfg.enabled = [bool]$rootEnabled }
        $prom = Get-MetricSectionValue $telemetry 'prometheus' $null
        if ($null -ne $prom) {
            $value = Get-MetricSectionValue $prom 'enabled' $null; if ($null -ne $value) { $cfg.prometheus.enabled = [bool]$value }
            $value = Get-MetricSectionValue $prom 'port' $null; if ($null -ne $value) { $cfg.prometheus.port = [int]$value }
            $value = Get-MetricSectionValue $prom 'altPorts' $null; if ($null -ne $value) { $cfg.prometheus.altPorts = @($value) }
            $value = Get-MetricSectionValue $prom 'bindAddress' $null; if ($null -ne $value) { $cfg.prometheus.bindAddress = [string]$value }
            $value = Get-MetricSectionValue $prom 'metricsPath' $null; if ($null -ne $value) { $cfg.prometheus.metricsPath = [string]$value }
        }
        $otel = Get-MetricSectionValue $telemetry 'otel' $null
        if ($null -ne $otel) {
            $value = Get-MetricSectionValue $otel 'enabled' $null; if ($null -ne $value) { $cfg.otel.enabled = [bool]$value }
            $value = Get-MetricSectionValue $otel 'endpoint' $null; if ($null -ne $value) { $cfg.otel.endpoint = [string]$value }
            $value = Get-MetricSectionValue $otel 'metricsPath' $null; if ($null -ne $value) { $cfg.otel.metricsPath = [string]$value }
            $value = Get-MetricSectionValue $otel 'tracesPath' $null; if ($null -ne $value) { $cfg.otel.tracesPath = [string]$value }
            $value = Get-MetricSectionValue $otel 'jsonDepth' $null; if ($null -ne $value) { $cfg.otel.jsonDepth = [int]$value }
        }
    }
    if (-not $cfg.enabled) { $cfg.prometheus.enabled = $false; $cfg.otel.enabled = $false }
    if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
        $toggle = Test-EnvToggle -Name 'GBUILD_PROMETHEUS'
        if ($null -ne $toggle -and $cfg.enabled) { $cfg.prometheus.enabled = [bool]$toggle }
    }
    return $cfg
}

function New-MetricCounter {
    param([Parameter(Mandatory)][string]$Name, [string]$Help = '', [hashtable]$Labels = @{})
    return [PSCustomObject]@{ Type = 'counter'; Name = $Name; Help = $Help; Value = 1.0; Labels = $Labels; Timestamp = [DateTime]::UtcNow }
}

function New-MetricHistogram {
    param([Parameter(Mandatory)][string]$Name, [string]$Help = '', [Parameter(Mandatory)][double]$Value, [hashtable]$Labels = @{})
    return [PSCustomObject]@{ Type = 'histogram'; Name = $Name; Help = $Help; Value = $Value; Labels = $Labels; Timestamp = [DateTime]::UtcNow }
}

function Add-Metric {
    param([Parameter(Mandatory)][PSCustomObject]$Metric, [string]$Name = '', [double]$Value = 1, [hashtable]$Labels = @{})
    $script:Registry.Register($Metric)
    Update-MetricsText
}

function Get-MetricsAsPrometheus { return $script:Registry.ToPrometheus() }

function Get-MetricProperty {
    param($Object, [string[]]$Names, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary]) {
            foreach ($key in $Object.Keys) { if ([string]$key -ieq $name) { return $Object[$key] } }
        } else {
            try { if ($Object.PSObject.Properties.Name -contains $name) { return $Object.$name } } catch { }
        }
    }
    return $Default
}

function ConvertTo-MetricBool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $text = $Value.Trim().ToLowerInvariant()
        if ($text -in @('false', '0', 'no', 'off', 'failed', 'failure')) { return $false }
        if ($text -in @('true', '1', 'yes', 'on', 'passed', 'success', 'ok')) { return $true }
    }
    return [bool]$Value
}

function ConvertTo-MetricTimestamp {
    param($Value, [DateTime]$Fallback = [DateTime]::MinValue)
    if ($null -eq $Value -or $Value -eq '') { return $Fallback }
    try {
        if ($Value -is [DateTime]) { $parsed = [DateTime]$Value }
        elseif ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
        else { $parsed = [DateTime]::Parse([string]$Value) }
        if ($parsed.Kind -eq [DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
        return $parsed
    } catch { return $Fallback }
}

function Get-MetricReportDirectory {
    param([PSCustomObject]$State)
    if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) { try { return [string](Get-ReportDirectory -State $State) } catch { } }
    # Single source for the directory NAME: a deployment that overrides
    # report.outputDir must not silently get a second writer pointing at the
    # default. Keep the literal only as the last-resort fallback.
    $leaf = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'ReportOutputDir' -State $State -Fallback 'build-reports') } else { 'build-reports' }
    $root = if ($State -and ($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and ($State.PSObject.Properties.Name -contains 'WorkingDir') -and $State.WorkingDir) { [string]$State.WorkingDir } elseif ($State -and ($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
    return Join-Path $root $leaf
}

function Get-MetricReportFiles {
    param([string]$Directory, [int]$Limit = 1000)
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    if ($files.Count -gt $Limit) { $files = @($files[0..($Limit - 1)]) }
    return $files
}

function Get-MetricStatusSuccess {
    param($Data)
    $explicit = Get-MetricProperty $Data @('Success', 'Succeeded', 'Passed') $null
    if ($null -ne $explicit) { return ConvertTo-MetricBool -Value $explicit }
    $status = [string](Get-MetricProperty $Data @('Status', 'Outcome', 'Result') '')
    return $status -in @('success', 'succeeded', 'passed', 'ok', 'true', 'completed')
}

function Test-MetricDeploymentEvent {
    param($Data)
    foreach ($name in @('IsDeployment', 'Deployment', 'Deployed', 'IsDeploy')) {
        $value = Get-MetricProperty $Data @($name) $null
        if ($null -ne $value) { return ConvertTo-MetricBool -Value $value }
    }
    $kind = [string](Get-MetricProperty $Data @('Type', 'Kind', 'EventType', 'Operation', 'Stage') '')
    return $kind -match '(?i)(deploy|deployment|release|publish)'
}

function Get-MetricLeadTimeSeconds {
    param($Data, [DateTime]$Fallback)
    $value = Get-MetricProperty $Data @('LeadTimeSec', 'LeadTimeSeconds', 'TimeToDeploySec', 'TimeToDeploySeconds') $null
    if ($null -ne $value) { try { $number = [double]$value; if ($number -ge 0) { return $number } } catch { } }
    $deployment = ConvertTo-MetricTimestamp (Get-MetricProperty $Data @('DeploymentTimestamp', 'DeployedAt', 'DeployAt') $null) ([DateTime]::MinValue)
    $commit = ConvertTo-MetricTimestamp (Get-MetricProperty $Data @('CommitTimestamp', 'CommittedAt', 'ChangeTimestamp') $null) ([DateTime]::MinValue)
    if ($deployment -ne [DateTime]::MinValue -and $commit -ne [DateTime]::MinValue) { return [math]::Max(0, ($deployment - $commit).TotalSeconds) }
    return $null
}

function Get-MetricMedian {
    param([object[]]$Values)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { try { [double]$_ } catch { } } | Sort-Object)
    if ($numbers.Count -eq 0) { return 0.0 }
    $middle = [int][math]::Floor($numbers.Count / 2)
    if ($numbers.Count % 2 -eq 1) { return [double]$numbers[$middle] }
    return ([double]$numbers[$middle - 1] + [double]$numbers[$middle]) / 2.0
}

function Get-MetricSummary {
    param([object[]]$Values)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { try { [double]$_ } catch { } } | Sort-Object)
    if ($numbers.Count -eq 0) { return [PSCustomObject]@{ Min = 0; Max = 0; Mean = 0; Median = 0; Count = 0 } }
    $mean = [math]::Round((($numbers | Measure-Object -Average).Average), 4)
    return [PSCustomObject]@{ Min = [double]$numbers[0]; Max = [double]$numbers[-1]; Mean = $mean; Median = [math]::Round((Get-MetricMedian $numbers), 4); Count = $numbers.Count }
}

function Get-DoraMetrics {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ReportDir = '')
    $windowHours = 24
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $windowHours = [int](Get-BuildConstant -Key 'DoraWindowHours' -State $State -Fallback 24) } catch { } }
    if (-not $ReportDir) { $ReportDir = Get-MetricReportDirectory $State }
    $result = [ordered]@{
        DeploymentFrequency = 0
        DeploymentFrequencyPerHour = 0
        DeploymentCount = 0
        WindowHours = $windowHours
        Unit = 'deployments/day'
        LeadTimeHistogram = [PSCustomObject]@{ Min = 0; Max = 0; Mean = 0; Median = 0; Count = 0 }
        LeadTimeSamples = 0
        ChangeFailureRate = 0
        ChangeCount = 0
        FailureCount = 0
        DeploymentChangeCount = 0
        MTTRHistogram = [PSCustomObject]@{ Min = 0; Max = 0; Mean = 0; Median = 0; Count = 0 }
        MTTRSamples = 0
        Definition = [PSCustomObject]@{ DeploymentFrequency = 'successful deployments per day'; LeadTime = 'commit-to-deployment'; ChangeFailureRate = 'failed deployments divided by all deployments'; MTTR = 'median failure-to-next-success recovery time' }
    }
    $files = @(Get-MetricReportFiles -Directory $ReportDir -Limit 1000)
    if ($files.Count -eq 0) { return [hashtable]$result }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if ($file.Name -notmatch '^(?i:build|deploy)') { continue }
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $timestamp = ConvertTo-MetricTimestamp (Get-MetricProperty $data @('Timestamp', 'CompletedAt', 'EndTime', 'CreatedAt') $null) $file.LastWriteTimeUtc
            $event = [PSCustomObject]@{ Timestamp = $timestamp; Success = (Get-MetricStatusSuccess $data); IsDeployment = (Test-MetricDeploymentEvent $data); LeadTimeSec = (Get-MetricLeadTimeSeconds $data $timestamp); Source = $file.Name; TenantId = [string](Get-MetricProperty $data @('TenantId', 'tenantId') '') }
            $events.Add($event) | Out-Null
        } catch { }
    }
    if ($events.Count -eq 0) { return [hashtable]$result }
    $tenant = [string](Get-MetricProperty $State @('TenantId') '')
    $filtered = @($events | Where-Object { -not $tenant -or ($_.TenantId -eq '' -and $tenant -eq 'default') -or $_.TenantId -eq $tenant })
    $recent = @($filtered | Where-Object { $_.Timestamp -ge [DateTime]::UtcNow.AddHours(-$windowHours) -and $_.IsDeployment -and $_.Success })
    $result.DeploymentCount = $recent.Count
    $result.DeploymentFrequency = $recent.Count
    $result.DeploymentFrequencyPerHour = [math]::Round($recent.Count / [double]$windowHours, 4)
    $lead = @($filtered | Where-Object { $_.IsDeployment -and $_.Success -and $null -ne $_.LeadTimeSec } | ForEach-Object { [double]$_.LeadTimeSec })
    $result.LeadTimeHistogram = Get-MetricSummary $lead
    $result.LeadTimeSamples = $lead.Count
    $deployments = @($filtered | Where-Object { $_.IsDeployment })
    $changes = if ($deployments.Count -gt 0) { $deployments } else { $filtered }
    $failures = @($changes | Where-Object { -not $_.Success }).Count
    $result.ChangeCount = $changes.Count
    $result.DeploymentChangeCount = $deployments.Count
    $result.FailureCount = $failures
    $result.ChangeFailureRate = if ($changes.Count -gt 0) { [math]::Round($failures / [double]$changes.Count, 4) } else { 0 }
    $ordered = @($filtered | Sort-Object Timestamp)
    $recovery = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        if ($ordered[$i].Success) { continue }
        for ($j = $i + 1; $j -lt $ordered.Count; $j++) {
            if ($ordered[$j].Success) { $recovery.Add([math]::Max(0, ($ordered[$j].Timestamp - $ordered[$i].Timestamp).TotalSeconds)) | Out-Null; break }
        }
    }
    $result.MTTRHistogram = Get-MetricSummary @($recovery)
    $result.MTTRSamples = $recovery.Count
    return [hashtable]$result
}

function Get-SloSamples {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $build = [System.Collections.Generic.List[object]]::new()
    $preflight = [System.Collections.Generic.List[object]]::new()
    $secret = [System.Collections.Generic.List[object]]::new()
    $roots = @()
    foreach ($name in @('ProjectRoot', 'WorkingDir', 'ScriptRoot')) {
        $root = if ($State) { [string](Get-MetricProperty $State @($name) '') } else { '' }
        if ($root -and (Test-Path -LiteralPath $root -PathType Container) -and ($roots -notcontains $root)) { $roots += $root }
    }
    $dirs = @()
    # Discover the CONFIGURED report dir first, then the default name, so trend
    # analysis sees history when a deployment overrides report.outputDir.
    $leaves = @()
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $leaves += [string](Get-BuildConstant -Key 'ReportOutputDir' -State $State -Fallback 'build-reports') } catch { }
    }
    if ($leaves -notcontains 'build-reports') { $leaves += 'build-reports' }
    foreach ($root in $roots) {
        foreach ($leaf in $leaves) {
            $dir = Join-Path $root $leaf
            if ((Test-Path -LiteralPath $dir -PathType Container) -and ($dirs -notcontains $dir)) { $dirs += $dir }
        }
    }
    $legacy = Join-Path $PSScriptRoot 'reports'
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and ($dirs -notcontains $legacy)) { $dirs += $legacy }
    $limit = 1000
    foreach ($dir in $dirs) {
        foreach ($file in @(Get-MetricReportFiles $dir $limit)) {
            try {
                $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $name = $file.Name
                if ($name -like 'build_*.json' -or $name -like 'deploy*.json') {
                    $timestamp = ConvertTo-MetricTimestamp (Get-MetricProperty $data @('Timestamp', 'CompletedAt', 'EndTime') $null) $file.LastWriteTimeUtc
                    $entryTenant = [string](Get-MetricProperty $data @('TenantId', 'tenantId') '')
                    $stateTenant = [string](Get-MetricProperty $State @('TenantId') '')
                    if ($stateTenant -and $stateTenant -ne 'default' -and $entryTenant -ne $stateTenant) { continue }
                    $build.Add([PSCustomObject]@{ Timestamp = $timestamp; Ok = (Get-MetricStatusSuccess $data); Source = $name }) | Out-Null
                } elseif ($name -like 'preflight_*.json') {
                    $passed = Get-MetricProperty $data @('Passed', 'Success') $null
                    if ($null -eq $passed) { $passed = ([string](Get-MetricProperty $data @('Overall', 'Status') '') -eq 'ok') }
                    $total = [int](Get-MetricProperty $data @('Total', 'CheckCount') 0)
                    $preflight.Add([PSCustomObject]@{ Timestamp = $file.LastWriteTimeUtc; Passed = ConvertTo-MetricBool -Value $passed; Total = $total; Source = $name }) | Out-Null
                } elseif ($name -like 'secret-*.json') {
                    $fp = [int](Get-MetricProperty $data @('FalsePositives', 'falsePositives') 0)
                    $scanned = [int](Get-MetricProperty $data @('TotalScanned', 'totalScanned') 0)
                    if ($scanned -gt 0) { $secret.Add([PSCustomObject]@{ Timestamp = $file.LastWriteTimeUtc; FalsePositives = $fp; TotalScanned = $scanned; Source = $name }) | Out-Null }
                }
            } catch { }
        }
    }
    foreach ($root in $roots) {
        $distributedLeaf = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [string](Get-BuildConstant -Key 'DistributedReportPath' -State $State -Fallback 'distributed-report')
        } else { 'distributed-report' }
        $distributed = Join-Path (Join-Path $root $distributedLeaf) 'distributed-report.json'
        if (Test-Path -LiteralPath $distributed -PathType Leaf) {
            try {
                $data = Get-Content -LiteralPath $distributed -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $timestamp = ConvertTo-MetricTimestamp (Get-MetricProperty $data @('GeneratedAt', 'Timestamp') $null) (Get-Item -LiteralPath $distributed).LastWriteTimeUtc
                $stateTenant = [string](Get-MetricProperty $State @('TenantId') '')
                foreach ($task in @((Get-MetricProperty $data @('Tasks') @()))) { $taskTenant = [string](Get-MetricProperty $task @('TenantId', 'tenantId') ''); if ($stateTenant -and $stateTenant -ne 'default' -and $taskTenant -ne $stateTenant) { continue }; $build.Add([PSCustomObject]@{ Timestamp = $timestamp; Ok = ConvertTo-MetricBool -Value (Get-MetricProperty $task @('Success') $false); Source = 'distributed-report' }) | Out-Null }
            } catch { }
        }
        $logsLeaf = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { [string](Get-BuildConstant -Key 'LogsDir' -State $State -Fallback 'logs') } catch { 'logs' }
        } else { 'logs' }
        $logDir = Join-Path $root $logsLeaf
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { continue }
        $stateTenant = [string](Get-MetricProperty $State @('TenantId') '')
        if ($stateTenant -and $stateTenant -ne 'default') { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 100)) {
            try {
                foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction Stop)) {
                    $plain = "$line" -replace "`e\[[0-9;?]*[ -/]*[@-~]", ''
                    if ($plain -match 'Tests\s+Passed\s*:\s*(\d+)\s*,\s*Failed\s*:\s*(\d+)') {
                        $passed = [int]$Matches[1]; $failed = [int]$Matches[2]
                        for ($i = 0; $i -lt $passed -and $build.Count -lt $limit; $i++) { $build.Add([PSCustomObject]@{ Timestamp = $file.LastWriteTimeUtc; Ok = $true; Source = $file.Name }) | Out-Null }
                        for ($i = 0; $i -lt $failed -and $build.Count -lt $limit; $i++) { $build.Add([PSCustomObject]@{ Timestamp = $file.LastWriteTimeUtc; Ok = $false; Source = $file.Name }) | Out-Null }
                    } elseif ($plain -match '\[VERIFY\]\s+Overall=(ok|degraded|failed|skipped)\s+\(passed=(\d+)\s+failed=(\d+)\s+skipped=(\d+)\)') {
                        $preflight.Add([PSCustomObject]@{ Timestamp = $file.LastWriteTimeUtc; Passed = ($Matches[1] -eq 'ok'); Total = ([int]$Matches[2] + [int]$Matches[3] + [int]$Matches[4]); Source = $file.Name }) | Out-Null
                    }
                }
            } catch { }
        }
    }
    return @{ Build = @($build | Sort-Object Timestamp -Descending | Select-Object -First $limit); Preflight = @($preflight | Sort-Object Timestamp -Descending | Select-Object -First $limit); SecretFp = @($secret | Sort-Object Timestamp -Descending | Select-Object -First $limit) }
}

function Get-BurnRateAdvisory {
    [CmdletBinding()]
    param([object[]]$Samples = @(), [double]$Target = 0.9, [double]$MaxBurn = 0.2)
    $ordered = @($Samples | Sort-Object { $_.Timestamp })
    if ($ordered.Count -lt 4) { return @{ Advisory = 'unknown'; BaselineErrRate = $null; RecentErrRate = $null; Delta = $null; BudgetBurnRate = $null; SampleCount = $ordered.Count; BaselineSampleCount = 0; RecentSampleCount = 0 } }
    $half = [int][math]::Floor($ordered.Count / 2)
    $base = @($ordered | Select-Object -First $half)
    $recent = @($ordered | Select-Object -Skip $half)
    $baseErr = @($base | Where-Object { -not [bool]$_.Ok }).Count / [double]$base.Count
    $recentErr = @($recent | Where-Object { -not [bool]$_.Ok }).Count / [double]$recent.Count
    $budget = 1.0 - $Target
    if ($budget -le 0) { $budget = 0.01 }
    $burn = [math]::Round($recentErr / $budget, 4)
    $delta = [math]::Round($recentErr - $baseErr, 4)
    $advisory = if ($recentErr -gt $budget) { 'critical' } elseif ($delta -gt $MaxBurn) { 'warning' } else { 'stable' }
    return @{ Advisory = $advisory; BaselineErrRate = [math]::Round($baseErr, 4); RecentErrRate = [math]::Round($recentErr, 4); Delta = $delta; BudgetBurnRate = $burn; SampleCount = $ordered.Count; BaselineSampleCount = $base.Count; RecentSampleCount = $recent.Count }
}

function Get-SloStatus {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $enabled = $true
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $enabled = [bool](Get-BuildConstant -Key 'SloEnabled' -State $State -Fallback $true) } catch { } }
    if (-not $enabled) { return @{ SloEnabled = $false } }
    $dora = Get-DoraMetrics -State $State
    $samples = Get-SloSamples -State $State
    $maxBurn = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [double](Get-BuildConstant -Key 'SloMaxBurnRatePerSprint' -State $State -Fallback 0.2) } else { 0.2 }
    $preflightTarget = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [double](Get-BuildConstant -Key 'SloPreflightPassRateTarget' -State $State -Fallback 0.95) } else { 0.95 }
    $secretTarget = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [double](Get-BuildConstant -Key 'SloSecretScanFalsePositiveRateTarget' -State $State -Fallback 0.01) } else { 0.01 }
    $buildTarget = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [double](Get-BuildConstant -Key 'SloBuildSuccessRateTarget' -State $State -Fallback 0.9) } else { 0.9 }
    $mttrTarget = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'SloMttrSecondsTargetMedian' -State $State -Fallback 300) } else { 300 }
    # The three *WindowDays keys (shipped as 30 under slo.*) had no consumer at
    # all: the sample sets were returned unbounded, so an SLO could be computed
    # over 3 years of samples while the config claimed a 30-day window. Each
    # window is now applied to the sample set it governs, and the effective
    # window is reported so a reader can tell what the number covers.
    $preflightWindowDays = 30
    $secretWindowDays = 30
    $buildWindowDays = 30
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $preflightWindowDays = [int](Get-BuildConstant -Key 'SloPreflightPassRateWindowDays' -State $State -Fallback 30) } catch { }
        try { $secretWindowDays = [int](Get-BuildConstant -Key 'SloSecretScanFalsePositiveRateWindowDays' -State $State -Fallback 30) } catch { }
        try { $buildWindowDays = [int](Get-BuildConstant -Key 'SloBuildSuccessRateWindowDays' -State $State -Fallback 30) } catch { }
    }
    # A window of 0 or less means "unbounded" - an explicit opt-out, not a
    # zero-length window that would silently empty every sample set.
    $withinWindow = {
        param($items, [int]$days)
        $all = @($items)
        if ($days -le 0 -or $all.Count -eq 0) { return $all }
        $cutoff = (Get-Date).AddDays(-$days)
        return @($all | Where-Object {
            $t = [datetime]::MinValue
            try { if ($_.PSObject.Properties.Name -contains 'Timestamp' -and $_.Timestamp) { $t = [datetime]$_.Timestamp } } catch { $t = [datetime]::MinValue }
            ($t -eq [datetime]::MinValue) -or ($t -ge $cutoff)
        })
    }
    $samples.Preflight = @(& $withinWindow $samples.Preflight $preflightWindowDays)
    $samples.SecretFp  = @(& $withinWindow $samples.SecretFp $secretWindowDays)
    $samples.Build    = @(& $withinWindow $samples.Build $buildWindowDays)
    $result = [ordered]@{ SloEnabled = $true; PreflightPassRateOk = $false; SecretScanFPRateOk = $false; BuildSuccessRateOk = $false; MttrMedianOk = $false; BurnRateAdvisory = 'unknown'; PreflightPassRate = $null; PreflightSamples = 0; BuildSuccessRate = $null; BuildSamples = 0; SecretScanFPRate = $null; SecretScanSamples = 0; MttrMedian = $null; BudgetBurnRate = $null; PreflightBudgetBurn = $null; MaxBurnRatePerSprint = $maxBurn; PreflightWindowDays = $preflightWindowDays; SecretScanWindowDays = $secretWindowDays; BuildWindowDays = $buildWindowDays; Dora = $dora }
    if (@($samples.Preflight).Count -gt 0) {
        $passed = @($samples.Preflight | Where-Object { $_.Passed }).Count
        $rate = [math]::Round($passed / [double]@($samples.Preflight).Count, 4)
        $result.PreflightPassRate = $rate; $result.PreflightSamples = @($samples.Preflight).Count; $result.PreflightPassRateOk = ($rate -ge $preflightTarget)
    }
    if (@($samples.SecretFp).Count -gt 0) {
        $fp = [double](($samples.SecretFp | Measure-Object -Property FalsePositives -Sum).Sum)
        $scanned = [double](($samples.SecretFp | Measure-Object -Property TotalScanned -Sum).Sum)
        if ($scanned -gt 0) { $rate = [math]::Round($fp / $scanned, 4); $result.SecretScanFPRate = $rate; $result.SecretScanSamples = @($samples.SecretFp).Count; $result.SecretScanFPRateOk = ($rate -le $secretTarget) }
    }
    if (@($samples.Build).Count -gt 0) {
        $ok = @($samples.Build | Where-Object { $_.Ok }).Count
        $rate = [math]::Round($ok / [double]@($samples.Build).Count, 4)
        $result.BuildSuccessRate = $rate; $result.BuildSamples = @($samples.Build).Count; $result.BuildSuccessRateOk = ($rate -ge $buildTarget)
    }
    if ($dora.MTTRHistogram.Count -gt 0) { $result.MttrMedian = $dora.MTTRHistogram.Median; $result.MttrMedianOk = ($result.MttrMedian -le $mttrTarget) }
    $advisories = @()
    if (@($samples.Build).Count -ge 4) { $b = Get-BurnRateAdvisory -Samples @($samples.Build) -Target $buildTarget -MaxBurn $maxBurn; $result.BudgetBurnRate = $b.BudgetBurnRate; $advisories += $b.Advisory }
    if (@($samples.Preflight).Count -ge 4) { $pf = @($samples.Preflight | ForEach-Object { [PSCustomObject]@{ Timestamp = $_.Timestamp; Ok = [bool]$_.Passed } }); $p = Get-BurnRateAdvisory -Samples $pf -Target $preflightTarget -MaxBurn $maxBurn; $result.PreflightBudgetBurn = $p.BudgetBurnRate; $advisories += $p.Advisory }
    if ($advisories -contains 'critical') { $result.BurnRateAdvisory = 'critical' } elseif ($advisories -contains 'warning') { $result.BurnRateAdvisory = 'warning' } elseif ($advisories -contains 'stable') { $result.BurnRateAdvisory = 'stable' }
    return [hashtable]$result
}

function Get-MetricsBaselinePath {
    param([PSCustomObject]$State, [string]$Path = '')
    if ($Path) { return $Path }
    return (Join-Path (Get-MetricReportDirectory $State) 'metrics-baseline.json')
}

function Get-MetricSnapshot {
    $snapshot = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $script:Registry.GetAggregatedSeries()) {
        $labels = @{}
        foreach ($key in @($entry.Labels.Keys | Sort-Object)) {
            if ($key -match '(?i)(token|secret|password|key|url)') { $labels[$key] = '***REDACTED***' } else { $labels[$key] = [string]$entry.Labels[$key] }
        }
        $snapshot.Add([PSCustomObject]@{ Name = [string]$entry.Name; Type = [string]$entry.Type; Help = [string]$entry.Help; Labels = $labels; Value = [double]$entry.Value; Timestamp = $entry.Timestamp }) | Out-Null
    }
    return @($snapshot)
}

function Get-BaselineSeriesKey {
    param($Name, $Labels)
    $pairs = @()
    if ($null -ne $Labels) {
        if ($Labels -is [System.Collections.IDictionary]) {
            foreach ($key in @($Labels.Keys | Sort-Object)) { $pairs += ('{0}={1}' -f [string]$key, [string]$Labels[$key]) }
        } elseif ($Labels -is [PSCustomObject]) {
            foreach ($property in @($Labels.PSObject.Properties | Sort-Object Name)) { $pairs += ('{0}={1}' -f [string]$property.Name, [string]$property.Value) }
        }
    }
    return ([string]$Name + '|' + ($pairs -join ','))
}

function Get-BaselineMedian {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $mid = [math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
}

function Get-BaselineStepLabel {
    param($Labels)
    if ($null -eq $Labels) { return '' }
    if ($Labels -is [System.Collections.IDictionary]) {
        foreach ($key in @($Labels.Keys)) {
            if ([string]$key -ieq 'step') { return [string]$Labels[$key] }
        }
        return ''
    }
    if ($Labels -is [PSCustomObject]) {
        foreach ($property in @($Labels.PSObject.Properties)) {
            if ([string]$property.Name -ieq 'step') { return [string]$property.Value }
        }
    }
    return ''
}

# Single source for rendering a drifted series as "name{k=v,...}" in the
# build log. Live snapshots carry Labels as a Hashtable, while series
# rehydrated from the baseline JSON carry them as PSCustomObject - the old
# inline formatter only knew the second shape, so every live drift warning
# printed the Hashtable's own .NET properties instead of the step name:
# gbuild_step_duration_seconds{Count=1,Keys=step,SyncRoot=System.Object,...}.
function Format-BaselineDriftIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param($Name, $Labels)
    $ident = [string]$Name
    $pairs = @()
    if ($null -ne $Labels) {
        if ($Labels -is [System.Collections.IDictionary]) {
            foreach ($key in @($Labels.Keys | Sort-Object)) {
                $value = [string]$Labels[$key]
                if ($value -and $value -ne '***REDACTED***') { $pairs += ('{0}={1}' -f [string]$key, $value) }
            }
        } elseif ($Labels -is [PSCustomObject]) {
            foreach ($property in @($Labels.PSObject.Properties | Sort-Object Name)) {
                $value = [string]$property.Value
                if ($value -and $value -ne '***REDACTED***') { $pairs += ('{0}={1}' -f [string]$property.Name, $value) }
            }
        }
    }
    if ($pairs.Count -gt 0) { $ident += '{' + ($pairs -join ',') + '}' }
    return $ident
}

function Compare-MetricsBaseline {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Path = '', [switch]$Persist)
    # baseline.driftEnabled gates the whole comparison. The key had a registered
    # BuildConstant but no consumer, so setting it to false changed nothing.
    # Read through the constant (single resolution path) and then fall back to
    # the raw config for a partial copy where BuildConstants is not loaded.
    $driftEnabled = $true
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $driftEnabled = [bool](Get-BuildConstant -Key 'BaselineDriftEnabled' -State $State -Fallback $true) } catch { $driftEnabled = $true }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { $cfgDrift = Get-ConfigValue -Path 'baseline.driftEnabled' -State $State; if ($null -ne $cfgDrift) { $driftEnabled = [bool]$cfgDrift } } catch { }
    }
    if (-not $driftEnabled) {
        return [PSCustomObject]@{
            Schema = 'gbuild.metrics-baseline.v1'; GeneratedAt = (Get-Date).ToString('o')
            BaselinePath = (Get-MetricsBaselinePath -State $State -Path $Path)
            Compared = $false; Initialized = $false; DriftDetected = $false
            Enabled = $false; Snapshot = @(); History = @(); HistorySize = 0
            ExcludedSteps = @(); ExcludedCount = 0; Comparisons = @()
        }
    }
    # Tunables resolve constant-first (parity rule), then raw config, then the
    # literal default - so standalone imports without BuildConstants still work.
    $threshold = 10.0
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $threshold = [double](Get-BuildConstant -Key 'BaselineDriftThresholdPct' -State $State -Fallback 10.0) } catch { $threshold = 10.0 }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $threshold = [double](Get-ConfigValue -Path 'baseline.driftThresholdPct' -State $State -Default $threshold) } catch { } }
    $minDelta = 0.5
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $minDelta = [double](Get-BuildConstant -Key 'BaselineDriftMinDeltaSeconds' -State $State -Fallback 0.5) } catch { $minDelta = 0.5 }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $minDelta = [double](Get-ConfigValue -Path 'baseline.driftMinDeltaSeconds' -State $State -Default $minDelta) } catch { } }
    $alertOnImprovement = $false
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $alertOnImprovement = [bool](Get-BuildConstant -Key 'BaselineAlertOnImprovement' -State $State -Fallback $false) } catch { $alertOnImprovement = $false }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $cfgImprove = Get-ConfigValue -Path 'baseline.alertOnImprovement' -State $State; if ($null -ne $cfgImprove) { $alertOnImprovement = [bool]$cfgImprove } } catch { } }
    $historySize = 5
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $historySize = [int](Get-BuildConstant -Key 'BaselineHistorySize' -State $State -Fallback 5) } catch { $historySize = 5 }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { try { $historySize = [int](Get-ConfigValue -Path 'baseline.historySize' -State $State -Default $historySize) } catch { } }
    if ($historySize -lt 1) { $historySize = 1 }
    if ($historySize -gt 50) { $historySize = 50 }
    $excludedSteps = @()
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $excludedSteps = @(Get-BuildConstant -Key 'BaselineExcludedSteps' -State $State -Fallback @()) } catch { $excludedSteps = @() }
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { $cfgExcluded = Get-ConfigValue -Path 'baseline.excludedSteps' -State $State; if ($null -ne $cfgExcluded) { $excludedSteps = @($cfgExcluded) } } catch { }
    }
    $excludedSteps = @($excludedSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $baselinePath = Get-MetricsBaselinePath -State $State -Path $Path
    $current = @(Get-MetricSnapshot)
    $previous = @()
    $history = @{}
    if (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
        try {
            $document = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($document.PSObject.Properties.Name -contains 'Snapshot') { $previous = @($document.Snapshot) }
            else { $previous = @($document) }
            if ($document.PSObject.Properties.Name -contains 'History') {
                foreach ($entry in @($document.History)) {
                    $entryKey = ''
                    try { $entryKey = [string]$entry.Key } catch { $entryKey = '' }
                    $entryValues = @()
                    try { foreach ($v in @($entry.Values)) { $entryValues += [double]$v } } catch { }
                    if ($entryKey -and $entryValues.Count -gt 0) { $history[$entryKey] = $entryValues }
                }
            }
        } catch { $previous = @() }
    }
    # Single-point files predate the rolling window: seed each series with its
    # last snapshot value so the median path behaves identically to the old
    # direct comparison until real history accumulates.
    $previousByKey = @{}
    foreach ($oldItem in $previous) {
        $oldName = ''
        try { $oldName = [string]$oldItem.Name } catch { $oldName = '' }
        $oldLabels = $null
        try { $oldLabels = $oldItem.Labels } catch { $oldLabels = $null }
        $previousByKey[(Get-BaselineSeriesKey -Name $oldName -Labels $oldLabels)] = $oldItem
    }
    $comparisons = [System.Collections.Generic.List[object]]::new()
    $excludedCount = 0
    foreach ($item in $current) {
        $itemLabels = $null
        try { $itemLabels = $item.Labels } catch { $itemLabels = $null }
        $stepLabel = Get-BaselineStepLabel -Labels $itemLabels
        $isExcluded = $false
        foreach ($ex in $excludedSteps) {
            if ($stepLabel -ieq $ex) { $isExcluded = $true; break }
        }
        if ($isExcluded) { $excludedCount++; continue }
        $seriesKey = Get-BaselineSeriesKey -Name ([string]$item.Name) -Labels $itemLabels
        $referenceValue = $null
        $medianWindow = 0
        if ($history.ContainsKey($seriesKey)) {
            $window = @($history[$seriesKey] | Where-Object { $null -ne $_ })
            if ($window.Count -gt 0) {
                $referenceValue = Get-BaselineMedian -Values ([double[]]$window)
                $medianWindow = $window.Count
            }
        }
        if ($null -eq $referenceValue -and $previousByKey.ContainsKey($seriesKey)) {
            try { $referenceValue = [double]$previousByKey[$seriesKey].Value } catch { $referenceValue = $null }
            $medianWindow = 1
        }
        if ($null -ne $referenceValue) {
            $oldValue = [double]$referenceValue
            $pct = if ([math]::Abs($oldValue) -gt 0) { [math]::Round((([double]$item.Value - $oldValue) / [math]::Abs($oldValue)) * 100, 4) } else { $null }
            # A percentage is only meaningful once the absolute change is material.
            # Pure percentage alerting on duration metrics produced garbage: a step
            # going from 0.0123s to 0.0153s tripped a 10% threshold and was
            # reported as "baseline drift exceeded", while the 40s Build step -
            # the one worth watching - stayed silent. Histograms carry timings, so
            # they must clear a floor as well as the percentage. Counters are
            # exempt: a baseline of 1 changing to 2 is a real, meaningful signal
            # regardless of magnitude, and the percentage is the whole point.
            $metricType = if ($item.PSObject.Properties.Name -contains 'Type') { [string]$item.Type } else { '' }
            $absoluteDelta = [math]::Abs(([double]$item.Value - $oldValue))
            $material = ($metricType -notmatch '(?i)^histogram$') -or ($absoluteDelta -ge $minDelta)
            # Direction matters for timings: a faster build is an improvement, not
            # an incident. Alerting on improvement is what turned every
            # optimization into a Warn and trained operators to ignore drift
            # warnings entirely. Counters keep symmetric alerting either way.
            # baseline.alertOnImprovement=true restores the old behaviour.
            if ($metricType -match '(?i)^histogram$') {
                if ($alertOnImprovement) { $exceeded = ($null -ne $pct) -and $material -and ([math]::Abs([double]$pct) -gt $threshold) }
                else { $exceeded = ($null -ne $pct) -and $material -and ([double]$pct -gt $threshold) }
            } else {
                $exceeded = ($null -ne $pct) -and $material -and ([math]::Abs([double]$pct) -gt $threshold)
            }
            $comparisons.Add([PSCustomObject]@{ Name = $item.Name; Type = $metricType; Labels = $item.Labels; BaselineValue = $oldValue; CurrentValue = [double]$item.Value; DriftPct = $pct; ThresholdPct = $threshold; MinDelta = $minDelta; AbsoluteDelta = $absoluteDelta; Material = $material; Exceeded = $exceeded; MedianWindow = $medianWindow }) | Out-Null
        }
    }
    $hasPrevious = ($previous.Count -gt 0) -or ($history.Count -gt 0)
    $driftDetected = @($comparisons | Where-Object { $_.Exceeded }).Count -gt 0
    $historyOut = @()
    if ($Persist) {
        foreach ($item in $current) {
            $itemLabels = $null
            try { $itemLabels = $item.Labels } catch { $itemLabels = $null }
            $stepLabel = Get-BaselineStepLabel -Labels $itemLabels
            $isExcluded = $false
            foreach ($ex in $excludedSteps) {
                if ($stepLabel -ieq $ex) { $isExcluded = $true; break }
            }
            if ($isExcluded) { continue }
            $seriesKey = Get-BaselineSeriesKey -Name ([string]$item.Name) -Labels $itemLabels
            $seriesValues = @()
            if ($history.ContainsKey($seriesKey)) { $seriesValues = @($history[$seriesKey]) }
            try { $seriesValues += [double]$item.Value } catch { continue }
            if ($seriesValues.Count -gt $historySize) { $seriesValues = @($seriesValues[($seriesValues.Count - $historySize)..($seriesValues.Count - 1)]) }
            $history[$seriesKey] = $seriesValues
        }
    }
    foreach ($key in @($history.Keys | Sort-Object)) {
        $historyOut += [PSCustomObject]@{ Key = [string]$key; Values = @($history[$key]) }
    }
    $report = [PSCustomObject]@{ Schema = 'gbuild.metrics-baseline.v1'; GeneratedAt = (Get-Date).ToString('o'); BaselinePath = $baselinePath; Compared = $hasPrevious; Initialized = (-not $hasPrevious); DriftDetected = $driftDetected; Enabled = $true; Snapshot = $current; History = @($historyOut); HistorySize = $historySize; ExcludedSteps = @($excludedSteps); ExcludedCount = $excludedCount; Comparisons = @($comparisons) }
    if ($Persist) {
        $dir = Split-Path -Parent $baselinePath
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
        $ok = $false
        if (Get-Command Write-BuildJsonFile -ErrorAction SilentlyContinue) { $ok = [bool](Write-BuildJsonFile -Path $baselinePath -Data $report -Atomic) }
        if (-not $ok) { try { $jd = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } else { 10 }; $report | ConvertTo-Json -Depth $jd | Set-Content -LiteralPath $baselinePath -Encoding UTF8; $ok = $true } catch { $ok = $false } }
        $report | Add-Member -MemberType NoteProperty -Name Persisted -Value $ok -Force
    }
    return $report
}

function Update-MetricsBaseline { param([PSCustomObject]$State, [string]$Path = ''); return Compare-MetricsBaseline -State $State -Path $Path -Persist }

function Start-MetricsEndpoint {
    param([int]$Port = 0, [PSCustomObject]$State)
    if ($script:ListenerRunning) {
        Write-MetricLog -Key 'log.metrics.endpointRunning' -MessageArgs @($script:ListenerPort) -Level 'DarkGray' -State $State
        return
    }
    $cfg = Get-TelemetryConfig -State $State
    if (-not $cfg.enabled -or -not $cfg.prometheus.enabled) { return }
    if ($Port -le 0) { $Port = $cfg.prometheus.port }
    # metricsPath / bindAddress are already resolved by Get-TelemetryConfig from
    # telemetry.prometheus.*, so they are used directly. The previous
    # `if (-not $cfg...) { '/metrics/' }` and `if (-not $address) { 'localhost' }`
    # fallbacks were unreachable AND shadowed BuildConstants PrometheusMetricsPath
    # (PrometheusMetricsPath) and MetricsBindAddress (MetricsBindAddress).
    $path = [string]$cfg.prometheus.metricsPath
    $address = [string]$cfg.prometheus.bindAddress
    # A blank configured address still falls back to the canonical default.
    # The literal here is only the survival fallback when BuildConstants cannot
    # be resolved; config and BuildConstants remain the real sources.
    if ([string]::IsNullOrWhiteSpace($address)) {
        $address = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [string](Get-BuildConstant -Key 'MetricsBindAddress' -State $State -Fallback 'localhost')
        } else { 'localhost' }
    }

    # telemetry.prometheus.altPorts was declared and read into $cfg but never
    # consumed: a single bind failure silently disabled the whole endpoint. Try
    # each candidate in order before giving up.
    $candidates = @($Port) + @($cfg.prometheus.altPorts | Where-Object { $_ -and [int]$_ -ne $Port })
    $listener = $null
    $endpoint = ''
    foreach ($candidatePort in $candidates) {
        $candidate = 'http://{0}:{1}{2}' -f $address, $candidatePort, $path
        $probe = $null
        try {
            $probe = [System.Net.HttpListener]::new()
            $probe.Prefixes.Add($candidate)
            $probe.Start()
            $listener = $probe
            $endpoint = $candidate
            $script:ListenerPort = $candidatePort
            break
        } catch {
            if ($probe) { try { $probe.Dispose() } catch { } }
        }
    }
    if (-not $listener) {
        Write-MetricLog -Key 'log.metrics.endpointTip' -Level 'DarkYellow' -State $State
        Write-MetricLog -Key 'log.metrics.endpointDisabled' -MessageArgs @(($candidates -join ', '), $address) -Level 'DarkYellow' -State $State
        return
    }
    $script:HttpListener = $listener; $script:ListenerRunning = $true; Update-MetricsText
    Write-MetricLog -Key 'log.metrics.endpointStarted' -MessageArgs @($script:ListenerPort) -Level 'DarkGray' -State $State
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $runspace.Open(); $runspace.SessionStateProxy.SetVariable('listener', $listener); $runspace.SessionStateProxy.SetVariable('MetricsSync', $script:MetricsSync)
    $powerShell = [System.Management.Automation.PowerShell]::Create(); $powerShell.Runspace = $runspace
    [void]$powerShell.AddScript({ while ($listener.IsListening) { try { $context = $listener.GetContext(); $body = [System.Text.Encoding]::UTF8.GetBytes([string]$MetricsSync.Text); $context.Response.ContentType = 'text/plain; version=0.0.4'; $context.Response.ContentLength64 = $body.Length; $context.Response.OutputStream.Write($body, 0, $body.Length); $context.Response.OutputStream.Close() } catch { if (-not $listener.IsListening) { break } } } })
    $script:ListenerRunspace = @{ PowerShell = $powerShell; Runspace = $runspace }; [void]$powerShell.BeginInvoke()
}

function Stop-MetricsEndpoint {
    if (-not $script:ListenerRunning) { return }
    $wasPort = $script:ListenerPort
    $script:ListenerRunning = $false
    if ($script:HttpListener) { try { $script:HttpListener.Stop(); $script:HttpListener.Close(); $script:HttpListener.Dispose() } catch { }; $script:HttpListener = $null }
    if ($script:ListenerRunspace) { try { $script:ListenerRunspace.PowerShell.Stop(); $script:ListenerRunspace.PowerShell.Dispose(); $script:ListenerRunspace.Runspace.Close(); $script:ListenerRunspace.Runspace.Dispose() } catch { }; $script:ListenerRunspace = $null }
    $script:ListenerPort = 0
    Write-MetricLog -Key 'log.metrics.endpointStopped' -MessageArgs @($wasPort) -Level 'DarkGray' -State $null
}

function ConvertTo-OtlpAttributeArray {
    param([hashtable]$Labels)
    if ($null -eq $Labels -or $Labels.Count -eq 0) { return @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($Labels.Keys | Sort-Object)) { $result.Add(@{ key = [string]$key; value = @{ stringValue = [string]$Labels[$key] } }) | Out-Null }
    return @($result)
}

function ConvertTo-OtlpTimeNano {
    param([DateTime]$Utc)
    $offset = [DateTimeOffset]::new($Utc)
    return [string](($offset.ToUnixTimeMilliseconds()) * 1000000)
}

function New-OtlpMetricsBody {
    param([PSCustomObject]$State)
    $tenant = if ($State -and (Get-MetricProperty $State @('TenantId') $null)) { [string](Get-MetricProperty $State @('TenantId') 'default') } else { 'default' }
    $version = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'Version' -Fallback '2.0.0') } else { '2.0.0' }
    $resource = @(@{ key = 'service.name'; value = @{ stringValue = 'gbuild' } }, @{ key = 'service.version'; value = @{ stringValue = $version } }, @{ key = 'tenant'; value = @{ stringValue = $tenant } })
    $byName = [ordered]@{}
    foreach ($entry in $script:Registry.GetAggregatedSeries()) { $name = [string]$entry.Name; if (-not $byName.Contains($name)) { $byName[$name] = [System.Collections.Generic.List[object]]::new() }; $byName[$name].Add($entry) | Out-Null }
    $metrics = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $byName.Keys) {
        $samples = @($byName[$name]); $counter = @($samples | Where-Object { $_.Type -eq 'counter' }).Count -eq $samples.Count
        $points = [System.Collections.Generic.List[object]]::new()
        foreach ($sample in $samples) { $points.Add(@{ attributes = @(ConvertTo-OtlpAttributeArray $sample.Labels); timeUnixNano = (ConvertTo-OtlpTimeNano $sample.Timestamp); asDouble = [double]$sample.Value }) | Out-Null }
        $metric = [ordered]@{ name = $name; description = [string]$samples[0].Help }
        if ($counter) { $metric['sum'] = @{ dataPoints = @($points); aggregationTemporality = 'AGGREGATION_TEMPORALITY_CUMULATIVE'; isMonotonic = $true } } else { $metric['gauge'] = @{ dataPoints = @($points) } }
        $metrics.Add($metric) | Out-Null
    }
    $body = [ordered]@{ resourceMetrics = @(@{ resource = @{ attributes = $resource }; scopeMetrics = @(@{ scope = @{ name = 'gbuild' }; metrics = @($metrics) }) }) }
    $depth = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } else { 20 }
    $jsonDepth = $depth
    if ($depth -le 0) { $jsonDepth = [int](Get-BuildConstant -Key 'OtlpJsonDepth' -State $State -Fallback 12) }
    return ($body | ConvertTo-Json -Depth $jsonDepth -Compress)
}

function Send-OtlpPost {
    param([string]$Url, [byte[]]$Bytes, [PSCustomObject]$State, [int]$TimeoutSec = 0)
    try { $uri = [System.Uri]::new($Url) } catch { return $false }
    if ($uri.Scheme -notin @('http', 'https')) { return $false }
    if ($TimeoutSec -le 0 -and (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue)) { try { $TimeoutSec = [int](Get-BuildConstant -Key 'WebhookTimeoutSec' -State $State -Fallback 10) } catch { } }
    if ($TimeoutSec -le 0) { $TimeoutSec = 10 }
    $request = [System.Net.WebRequest]::Create($uri); $request.Method = 'POST'; $request.ContentType = 'application/json'; $request.ContentLength = $Bytes.Length; $request.Timeout = $TimeoutSec * 1000
    try { $request.ReadWriteTimeout = $TimeoutSec * 1000 } catch { }
    $stream = $null; $response = $null
    try { $stream = $request.GetRequestStream(); $stream.Write($Bytes, 0, $Bytes.Length); $stream.Close(); $response = $request.GetResponse(); $status = [int]$response.StatusCode; return ($status -ge 200 -and $status -lt 300) }
    catch { return $false }
    finally { if ($stream) { try { $stream.Dispose() } catch { } }; if ($response) { try { $response.Close() } catch { } } }
}

function Send-OtelTraces {
    param([PSCustomObject]$State, [string]$OtelEndpoint, [hashtable]$TraceData, [int]$TimeoutSec = 0)
    if ([string]::IsNullOrWhiteSpace($OtelEndpoint)) { return $false }
    $telemetry = Get-TelemetryConfig -State $State
    if (-not $telemetry.enabled -or ($telemetry.configured -and -not $telemetry.otel.enabled)) { return $false }
    $path = if ($telemetry.configured -and $telemetry.otel.tracesPath) { [string]$telemetry.otel.tracesPath } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'OtlpTracesPath' -State $State -Fallback '/v1/traces') } else { '/v1/traces' }
    $body = $TraceData | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'OtlpJsonDepth' -Fallback 10) } else { 10 }) -Compress
    return [bool](Send-OtlpPost -Url ('{0}{1}' -f $OtelEndpoint.TrimEnd('/'), $path) -Bytes ([System.Text.Encoding]::UTF8.GetBytes($body)) -State $State -TimeoutSec $TimeoutSec)
}

function Send-OtelMetrics {
    [OutputType([bool])]
    param([PSCustomObject]$State, [string]$OtelEndpoint, [int]$TimeoutSec = 0)
    if ([string]::IsNullOrWhiteSpace($OtelEndpoint)) { return $false }
    $telemetry = Get-TelemetryConfig -State $State
    if (-not $telemetry.enabled -or ($telemetry.configured -and -not $telemetry.otel.enabled)) { return $false }
    $path = if ($telemetry.configured -and $telemetry.otel.metricsPath) { [string]$telemetry.otel.metricsPath } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'OtlpMetricsPath' -State $State -Fallback '/v1/metrics') } else { '/v1/metrics' }
    $body = New-OtlpMetricsBody -State $State
    return [bool](Send-OtlpPost -Url ('{0}{1}' -f $OtelEndpoint.TrimEnd('/'), $path) -Bytes ([System.Text.Encoding]::UTF8.GetBytes($body)) -State $State -TimeoutSec $TimeoutSec)
}

function Submit-BuildMetric {
    param([PSCustomObject]$State, [string]$Step, [double]$DurationMs, [bool]$Success, [string]$ProjectName = '', [string]$Configuration = 'Release', [string]$TargetFramework = '', [string]$OutputType = '', [string]$Commit = '', [string]$Stage = '', [string]$Name = '', [double]$Value = 0, [hashtable]$Labels = @{})
    if ($Name) { Add-Metric -Metric ([PSCustomObject]@{ Type = 'gauge'; Name = $Name; Help = ''; Value = $Value; Labels = $Labels; Timestamp = [DateTime]::UtcNow }); return }
    $tenant = if ($State -and [string](Get-MetricProperty $State @('TenantId') '') -ne 'default') { [string](Get-MetricProperty $State @('TenantId') '') } else { 'default' }
    $status = if ($Success) { 'success' } else { 'failure' }
    $labels = @{ status = $status; step = $Step; tenant = $tenant }
    if ($ProjectName) { $labels.project = $ProjectName }; if ($Configuration) { $labels.configuration = $Configuration }; if ($TargetFramework) { $labels.tfm = $TargetFramework }; if ($OutputType) { $labels.output_type = $OutputType }; if ($Commit) { $labels.commit = $Commit }; if ($Stage) { $labels.stage = $Stage }
    Add-Metric -Metric (New-MetricCounter -Name 'gbuild_build_total' -Help 'Total number of builds' -Labels @{ status = $status; step = $Step; tenant = $tenant })
    Add-Metric -Metric (New-MetricHistogram -Name 'gbuild_build_duration_seconds' -Help 'Build duration in seconds' -Value ([math]::Round($DurationMs / 1000.0, 4)) -Labels $labels)
    if (-not $Success) { Add-Metric -Metric (New-MetricCounter -Name 'gbuild_error_total' -Help 'Total number of errors' -Labels @{ category = $Step; tenant = $tenant }) }
}

function Submit-CacheMetric {
    param([ValidateSet('hit', 'miss', 'stale')][string]$Result, [string]$Project = '', [string]$CacheKey = '', [string]$TenantId = '')
    $name = if ($Result -eq 'hit') { 'gbuild_cache_hits_total' } else { 'gbuild_cache_misses_total' }
    $labels = @{}; if ($Project) { $labels.project = $Project }; if ($CacheKey) { $labels.cache_key = if ($CacheKey.Length -gt 12) { $CacheKey.Substring(0, 12) + '...' } else { $CacheKey } }; if ($TenantId -and $TenantId -ne 'default') { $labels.tenant = $TenantId }
    Add-Metric -Metric (New-MetricCounter -Name $name -Help 'Cache result counter' -Labels $labels)
}

function Clear-Metrics { $script:Registry.Clear(); Update-MetricsText }
function Get-MetricRegistry { return $script:Registry }
function Get-MetricRawSamples { return @($script:Registry.Metrics) }

$ExecutionContext.SessionState.Module.OnRemove = { Stop-MetricsEndpoint }

Export-ModuleMember -Function @('New-MetricCounter', 'New-MetricHistogram', 'Add-Metric', 'Get-MetricsAsPrometheus', 'Start-MetricsEndpoint', 'Stop-MetricsEndpoint', 'Send-OtelTraces', 'Send-OtelMetrics', 'Submit-BuildMetric', 'Submit-CacheMetric', 'Clear-Metrics', 'Get-MetricRegistry', 'Get-TelemetryConfig', 'Get-DoraMetrics', 'Get-SloSamples', 'Get-BurnRateAdvisory', 'Get-SloStatus', 'Compare-MetricsBaseline', 'Update-MetricsBaseline', 'Get-MetricsBaselinePath', 'Get-MetricRawSamples', 'Format-BaselineDriftIdentity')
