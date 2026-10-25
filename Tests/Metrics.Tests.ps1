#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:mTemp = New-IntegrationTempDir
$global:mState = [PSCustomObject]@{ ScriptRoot = $global:mTemp; CorrelationId = 'm-it' }

Describe "Metrics Core" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if ($global:mTemp -and (Test-Path $global:mTemp)) { Remove-Item $global:mTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Clear-Metrics
    }

    It "New-MetricCounter returns a counter object with default value 1" {
        $c = New-MetricCounter -Name 'test_total'
        $c.Type  | Should -Be 'counter'
        $c.Name  | Should -Be 'test_total'
        $c.Value | Should -Be 1
    }

    It "New-MetricHistogram returns a histogram object with the provided value" {
        $h = New-MetricHistogram -Name 'test_dur' -Value 2.5
        $h.Type  | Should -Be 'histogram'
        $h.Value | Should -Be 2.5
    }

    It "Add-Metric appends metrics that surface in Get-MetricsAsPrometheus" {
        Add-Metric -Metric (New-MetricCounter -Name 'prom_a')
        Get-MetricsAsPrometheus | Should -BeLike '*prom_a*'
    }

    It "Get-MetricsAsPrometheus emits HELP and TYPE lines" {
        Add-Metric -Metric (New-MetricCounter -Name 'prom_test' -Help 'a help')
        $out = Get-MetricsAsPrometheus
        $out | Should -BeLike '*# HELP prom_test*'
        $out | Should -BeLike '*# TYPE prom_test counter*'
    }

    It "Submit-BuildMetric records build, duration and error metrics" {
        Submit-BuildMetric -State $global:mState -Step 'compile' -DurationMs 1500 -Success $false
        $out = Get-MetricsAsPrometheus
        $out | Should -BeLike '*gbuild_build_total*'
        $out | Should -BeLike '*gbuild_build_duration_seconds*'
        $out | Should -BeLike '*gbuild_error_total*'
    }

    It "Submit-CacheMetric records cache hit counter" {
        Submit-CacheMetric -Result 'hit' -Project 'MyApp' -CacheKey 'abc123'
        $out = Get-MetricsAsPrometheus
        $out | Should -BeLike '*gbuild_cache_hits_total*'
        $out | Should -Match 'project="MyApp"'
        $out | Should -Match 'cache_key="abc123"'
    }

    It "Submit-CacheMetric records cache miss counter" {
        Submit-CacheMetric -Result 'miss' -Project 'MyApp'
        $out = Get-MetricsAsPrometheus
        $out | Should -BeLike '*gbuild_cache_misses_total*'
        $out | Should -Match 'project="MyApp"'
    }

    It "Clear-Metrics empties the metrics collection" {
        Add-Metric -Metric (New-MetricCounter -Name 'prom_x')
        Clear-Metrics
        Get-MetricsAsPrometheus | Should -BeNullOrEmpty
    }
}

Describe "OTLP protojson payload" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Clear-Metrics
    }

    It "Builds a proper OTLP/HTTP JSON (protojson) body with typed dataPoints" {
        Submit-BuildMetric -State $global:mState -Step 'compile' -DurationMs 100 -Success $true
        $mod = Get-Module Metrics
        $body = (& $mod { param($s) New-OtlpMetricsBody -State $s } $global:mState) | ConvertFrom-Json

        $attrs = $body.resourceMetrics[0].resource.attributes
        $attrs | Where-Object { $_.key -eq 'service.name' } | ForEach-Object { $_.value.stringValue | Should -Be 'gbuild' }
        $attrs | Where-Object { $_.key -eq 'service.version' } | ForEach-Object { $_.value.stringValue | Should -Match '^\d' }
        $attrs | Where-Object { $_.key -eq 'tenant' } | ForEach-Object { $_.value.stringValue | Should -Be 'default' }

        $scope = $body.resourceMetrics[0].scopeMetrics[0]
        $scope.scope.name | Should -Be 'gbuild'

        $cnt = @($scope.metrics | Where-Object { $_.name -eq 'gbuild_build_total' })[0]
        $cnt | Should -Not -BeNullOrEmpty
        $cnt.sum.aggregationTemporality | Should -Be 'AGGREGATION_TEMPORALITY_CUMULATIVE'
        $cnt.sum.isMonotonic | Should -BeTrue
        $cnt.sum.dataPoints[0].timeUnixNano | Should -Match '^\d+$'
        $cnt.sum.dataPoints[0].asDouble | Should -Be 1

        $dur = @($scope.metrics | Where-Object { $_.name -eq 'gbuild_build_duration_seconds' })[0]
        $dur | Should -Not -BeNullOrEmpty
        $dur.gauge.dataPoints[0].asDouble | Should -BeGreaterThan 0
        @($dur.gauge.dataPoints[0].attributes).Count | Should -BeGreaterThan 0
    }
}

Describe 'Metrics safety and SLO' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Clear-Metrics
    }

    It 'compares a new metric snapshot against the stored baseline' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        $path = Join-Path $TestDrive 'metrics-baseline.json'
        Add-Metric -Metric (New-MetricCounter -Name 'baseline_total' -Labels @{ kind = 'test' })
        $first = Compare-MetricsBaseline -State $state -Path $path -Persist
        Clear-Metrics
        Add-Metric -Metric (New-MetricCounter -Name 'baseline_total' -Labels @{ kind = 'test' })
        Add-Metric -Metric (New-MetricCounter -Name 'baseline_total' -Labels @{ kind = 'test' })
        $second = Compare-MetricsBaseline -State $state -Path $path
        $first.Initialized | Should -BeTrue
        $second.Compared | Should -BeTrue
        $second.Comparisons[0].DriftPct | Should -Be 100
    }

    # Percentage-only alerting on duration metrics produced pure noise: a pipeline
    # step going 0.0123s -> 0.0153s tripped the 10% threshold and the build warned
    # "baseline drift exceeded", while the 40s Build step stayed silent. Histogram
    # (timing) series must clear an absolute floor as well; counters must not,
    # because a baseline of 1 becoming 2 is a real signal at any magnitude.
    Describe 'drift materiality floor' {
        BeforeEach { Clear-Metrics }

        It 'does not flag a histogram whose absolute change is negligible' {
            $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
            $path = Join-Path $TestDrive 'bl-hist-noise.json'
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.0123 -Labels @{ step = 'AffectedScan' })
            Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
            Clear-Metrics
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.0153 -Labels @{ step = 'AffectedScan' })
            $r = Compare-MetricsBaseline -State $state -Path $path
            $r.Comparisons[0].DriftPct | Should -BeGreaterThan 10
            $r.Comparisons[0].Exceeded | Should -BeFalse
            $r.DriftDetected | Should -BeFalse
        }

        It 'still flags a histogram whose absolute change is material' {
            $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
            $path = Join-Path $TestDrive 'bl-hist-real.json'
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.80 -Labels @{ step = 'SupplyChain' })
            Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
            Clear-Metrics
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 1.67 -Labels @{ step = 'SupplyChain' })
            $r = Compare-MetricsBaseline -State $state -Path $path
            $r.Comparisons[0].Exceeded | Should -BeTrue
            $r.Comparisons[0].AbsoluteDelta | Should -BeGreaterThan 0.5
        }

        It 'does not floor counters - percentage stays authoritative' {
            $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
            $path = Join-Path $TestDrive 'bl-counter.json'
            Add-Metric -Metric ([PSCustomObject]@{ Type = 'counter'; Name = 'hits_total'; Help = ''; Value = 1; Labels = @{}; Timestamp = [DateTime]::UtcNow })
            Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
            Clear-Metrics
            Add-Metric -Metric ([PSCustomObject]@{ Type = 'counter'; Name = 'hits_total'; Help = ''; Value = 2; Labels = @{}; Timestamp = [DateTime]::UtcNow })
            $r = Compare-MetricsBaseline -State $state -Path $path
            $r.Comparisons[0].DriftPct | Should -Be 100
            $r.Comparisons[0].Exceeded | Should -BeTrue
        }

        It 'records why a comparison did or did not exceed' {
            $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
            $path = Join-Path $TestDrive 'bl-fields.json'
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.01 -Labels @{ step = 'X' })
            Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
            Clear-Metrics
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.02 -Labels @{ step = 'X' })
            $c = (Compare-MetricsBaseline -State $state -Path $path).Comparisons[0]
            $c.PSObject.Properties.Name | Should -Contain 'Type'
            $c.PSObject.Properties.Name | Should -Contain 'AbsoluteDelta'
            $c.PSObject.Properties.Name | Should -Contain 'Material'
            $c.PSObject.Properties.Name | Should -Contain 'MinDelta'
            $c.Type | Should -Be 'histogram'
            $c.Material | Should -BeFalse
        }
    }

    It 'keeps raw samples bounded while retaining aggregate counters' {
        for ($i = 0; $i -lt 10005; $i++) { Add-Metric -Metric (New-MetricCounter -Name 'bounded_total') }
        @(Get-MetricRawSamples).Count | Should -BeLessOrEqual 10000
        (Get-MetricsAsPrometheus) | Should -Match 'bounded_total.*10005'
    }

    It 'uses deployment events and commit-to-deployment lead time for DORA' {
        $dir = Join-Path $TestDrive 'dora-reports'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $now = [DateTime]::UtcNow
        ([ordered]@{ Timestamp = $now.AddMinutes(-10).ToString('o'); Status = 'Success'; Type = 'deployment'; CommitTimestamp = $now.AddMinutes(-20).ToString('o'); DeploymentTimestamp = $now.AddMinutes(-10).ToString('o') } | ConvertTo-Json) | Set-Content -Path (Join-Path $dir 'build_deploy.json')
        ([ordered]@{ Timestamp = $now.AddMinutes(-5).ToString('o'); Status = 'Failed'; Type = 'build' } | ConvertTo-Json) | Set-Content -Path (Join-Path $dir 'build_fail.json')
        ([ordered]@{ Timestamp = $now.ToString('o'); Status = 'Success'; Type = 'build' } | ConvertTo-Json) | Set-Content -Path (Join-Path $dir 'build_recover.json')
        $result = Get-DoraMetrics -State ([PSCustomObject]@{ ProjectRoot = $TestDrive }) -ReportDir $dir
        $result.DeploymentCount | Should -Be 1
        $result.LeadTimeHistogram.Median | Should -Be 600
        $result.MTTRHistogram.Median | Should -Be 300
    }

    It 'does not persist a baseline while serializing OTLP' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        Add-Metric -Metric (New-MetricCounter -Name 'serialization_total')
        $baselinePath = Join-Path $TestDrive 'metrics-baseline.json'
        Remove-Item -LiteralPath $baselinePath -Force -ErrorAction SilentlyContinue
        $module = Get-Module Metrics
        [void](& $module { param($s) New-OtlpMetricsBody -State $s } $state)
        Test-Path -LiteralPath (Join-Path $TestDrive 'metrics-baseline.json') | Should -BeFalse
    }
}

Describe 'Metrics baseline direction and rolling median' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Clear-Metrics
    }

    It 'does not flag a timing improvement as drift' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        $path = Join-Path $TestDrive 'bl-improve.json'
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 4.4838 -Labels @{ step = 'Preflight' })
        Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 2.9807 -Labels @{ step = 'Preflight' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.Comparisons[0].DriftPct | Should -BeLessThan 0
        $r.Comparisons[0].Exceeded | Should -BeFalse
        $r.DriftDetected | Should -BeFalse
    }

    It 'still flags a timing regression as drift' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        $path = Join-Path $TestDrive 'bl-regress.json'
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 2.9807 -Labels @{ step = 'Preflight' })
        Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 4.4838 -Labels @{ step = 'Preflight' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.Comparisons[0].DriftPct | Should -BeGreaterThan 10
        $r.Comparisons[0].Exceeded | Should -BeTrue
        $r.DriftDetected | Should -BeTrue
    }

    It 'flags improvements again when baseline.alertOnImprovement is true' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ baseline = [PSCustomObject]@{ alertOnImprovement = $true } } }
        $path = Join-Path $TestDrive 'bl-improve-optin.json'
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 4.4838 -Labels @{ step = 'Preflight' })
        Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 2.9807 -Labels @{ step = 'Preflight' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.Comparisons[0].Exceeded | Should -BeTrue
        $r.DriftDetected | Should -BeTrue
    }

    It 'skips excluded steps entirely' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ baseline = [PSCustomObject]@{ excludedSteps = @('AffectedScan') } } }
        $path = Join-Path $TestDrive 'bl-excluded.json'
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.80 -Labels @{ step = 'AffectedScan' })
        Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 8.80 -Labels @{ step = 'AffectedScan' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.ExcludedCount | Should -Be 1
        @($r.Comparisons).Count | Should -Be 0
        $r.DriftDetected | Should -BeFalse
    }

    It 'compares against the median of the rolling window, not a single spike' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ baseline = [PSCustomObject]@{ historySize = 5 } } }
        $path = Join-Path $TestDrive 'bl-median.json'
        foreach ($v in @(10.0, 10.2, 9.8)) {
            Clear-Metrics
            Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value $v -Labels @{ step = 'Build' })
            Compare-MetricsBaseline -State $state -Path $path -Persist | Out-Null
        }
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 10.1 -Labels @{ step = 'Build' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.Comparisons[0].MedianWindow | Should -Be 3
        $r.Comparisons[0].Exceeded | Should -BeFalse
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 20.0 -Labels @{ step = 'Build' })
        $r2 = Compare-MetricsBaseline -State $state -Path $path
        $r2.Comparisons[0].Exceeded | Should -BeTrue
    }

    It 'reads a legacy single-snapshot file as a window of one' {        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        $path = Join-Path $TestDrive 'bl-legacy.json'
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 0.80 -Labels @{ step = 'SupplyChain' })
        $first = Compare-MetricsBaseline -State $state -Path $path -Persist
        $first.History.Count | Should -BeGreaterThan 0
        Clear-Metrics
        Add-Metric -Metric (New-MetricHistogram -Name 'step_seconds' -Value 1.67 -Labels @{ step = 'SupplyChain' })
        $r = Compare-MetricsBaseline -State $state -Path $path
        $r.Comparisons[0].MedianWindow | Should -Be 1
        $r.Comparisons[0].Exceeded | Should -BeTrue
    }
}

Describe 'Format-BaselineDriftIdentity' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'renders live Hashtable labels as step pairs, not .NET properties' {
        $out = Format-BaselineDriftIdentity -Name 'gbuild_step_duration_seconds' -Labels @{ step = 'Build' }
        $out | Should -Be 'gbuild_step_duration_seconds{step=Build}'
    }

    It 'renders rehydrated PSCustomObject labels identically' {
        $labels = [PSCustomObject]@{ step = 'SastScan' }
        $out = Format-BaselineDriftIdentity -Name 'gbuild_step_duration_seconds' -Labels $labels
        $out | Should -Be 'gbuild_step_duration_seconds{step=SastScan}'
    }

    It 'sorts multiple pairs and skips redacted or empty values' {
        $out = Format-BaselineDriftIdentity -Name 'm' -Labels @{ step = 'Build'; status = 'failed'; token = '***REDACTED***'; empty = '' }
        $out | Should -Be 'm{status=failed,step=Build}'
    }

    It 'returns the bare name when labels are missing' {
        Format-BaselineDriftIdentity -Name 'm' -Labels $null | Should -Be 'm'
        Format-BaselineDriftIdentity -Name 'm' -Labels @{} | Should -Be 'm'
    }
}
