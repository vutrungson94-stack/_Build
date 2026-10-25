#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'AutoTuner.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'AnomalyDetector.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "AnomalyDetector (statistical anomaly detection)" {
    BeforeAll {
        $script:tempDir = Join-Path $env:TEMP "gbuild-anomaly-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-AnomalyConfig returns defaults when State has no anomaly section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        $cfg = Get-AnomalyConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.zScoreThreshold | Should -Be 3.0
        $cfg.ewmaAlpha | Should -Be 0.3
        $cfg.minSamples | Should -Be 10
    }

    It "Get-AnomalyConfig reads the anomaly section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ anomaly = [PSCustomObject]@{ enabled = $false; zScoreThreshold = 2.5; minSamples = 5 } } }
        $cfg = Get-AnomalyConfig -State $state
        $cfg.enabled | Should -Be $false
        $cfg.zScoreThreshold | Should -Be 2.5
        $cfg.minSamples | Should -Be 5
    }

    It "Get-DurationAnomaly detects anomaly with extreme z-score" {
        $history = @(30.0, 32.0, 31.0, 29.0, 30.5, 31.5, 30.0, 28.5, 31.0, 30.0)
        $result = Get-DurationAnomaly -CurrentDurationSec 500.0 -HistoryDurations $history -ZScoreThreshold 3.0
        $result.IsAnomaly | Should -BeTrue
        $result.ZScore | Should -BeGreaterThan 3.0
        $result.Severity | Should -BeIn @('Medium', 'High', 'Critical')
    }

    It "Get-DurationAnomaly returns normal for typical duration" {
        $history = @(30.0, 32.0, 31.0, 29.0, 30.5, 31.5, 30.0, 28.5, 31.0, 30.0)
        $result = Get-DurationAnomaly -CurrentDurationSec 30.5 -HistoryDurations $history -ZScoreThreshold 3.0
        $result.IsAnomaly | Should -Be $false
        $result.Severity | Should -Be 'Normal'
    }

    It "Get-FailureRateAnomaly detects anomaly when failure rate spikes" {
        $history = @(0.0, 0.05, 0.0, 0.1, 0.0, 0.0, 0.05, 0.0, 0.0, 0.05)
        $result = Get-FailureRateAnomaly -CurrentFailureRate 0.8 -HistoryFailureRates $history -Threshold 0.3
        $result.IsAnomaly | Should -BeTrue
        $result.ZScore | Should -BeGreaterThan 2.5
    }

    It "Get-FailureRateAnomaly returns normal for stable failure rate" {
        $history = @(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        $result = Get-FailureRateAnomaly -CurrentFailureRate 0.0 -HistoryFailureRates $history -Threshold 0.3
        $result.IsAnomaly | Should -Be $false
    }

    It "Get-AnomalyReport returns InsufficientData when not enough samples" {
        $historyFile = Join-Path $tempDir "autotune-history.jsonl"
        $lines = @(
            ([PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); DurationSec = 30.0; Success = $true; ProjectType = 'Web'; ParallelJobs = 4; CacheHit = $false; Incremental = $true; CpuCount = 8; MemoryGB = 16.0 } | ConvertTo-Json -Compress)
        )
        $lines | Set-Content -Path $historyFile -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ anomaly = [PSCustomObject]@{ enabled = $true; minSamples = 10 }; autoTune = [PSCustomObject]@{ historyPath = $historyFile } }; ScriptRoot = $tempDir }
        $report = Get-AnomalyReport -State $state
        $report.Status | Should -Be 'InsufficientData'
        $report.SampleCount | Should -Be 1
    }

    It "Get-AnomalyReport returns Healthy when data is within normal range" {
        $historyFile = Join-Path $tempDir "autotune-history-healthy.jsonl"
        $lines = @()
        for ($i = 0; $i -lt 15; $i++) {
            $entry = [PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); DurationSec = 30.0 + $i * 0.5; Success = $true; ProjectType = 'Web'; ParallelJobs = 4; CacheHit = $false; Incremental = $true; CpuCount = 8; MemoryGB = 16.0 }
            $lines += ($entry | ConvertTo-Json -Compress)
        }
        $lines | Set-Content -Path $historyFile -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ anomaly = [PSCustomObject]@{ enabled = $true; minSamples = 10 }; autoTune = [PSCustomObject]@{ historyPath = $historyFile } }; ScriptRoot = $tempDir }
        $report = Get-AnomalyReport -State $state
        $report.Status | Should -Be 'Healthy'
        $report.Anomalies.Count | Should -Be 0
    }
}

Describe 'AnomalyDetector safety' {
    It 'rejects a history path outside the configured root' {
        $root = Join-Path $TestDrive 'contained'
        $outside = Join-Path $TestDrive 'outside-history.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ anomaly = [PSCustomObject]@{ enabled = $true; historyPath = $outside } }; ProjectRoot = $root }
        Write-AnomalyHistory -Report ([PSCustomObject]@{ Status = 'Healthy'; SampleCount = 1; Anomalies = @(); MaxSeverity = 'Normal' }) -State $state | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It 'keeps sample and report histories separate and excludes raw secrets' {
        $samplePath = Join-Path $TestDrive 'anomaly-samples.jsonl'
        $reportPath = Join-Path $TestDrive 'anomaly-reports.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ anomaly = [PSCustomObject]@{ enabled = $true; sampleHistoryPath = $samplePath; historyPath = $reportPath } }; ProjectRoot = $TestDrive }
        Write-AnomalySample -Sample @{ DurationSec = 10; Success = $true; Token = 'must-not-leak' } -State $state
        Write-AnomalyHistory -Report ([PSCustomObject]@{ Status = 'Healthy'; SampleCount = 1; Anomalies = @(); MaxSeverity = 'Normal' }) -State $state
        (Get-Content -LiteralPath $samplePath -Raw) | Should -Not -Match 'must-not-leak'
        (Get-Content -LiteralPath $reportPath -Raw) | Should -Not -Match 'must-not-leak'
        (Get-Content -LiteralPath $samplePath -Raw) | Should -Match 'anomaly.sample.v1'
        (Get-Content -LiteralPath $reportPath -Raw) | Should -Match 'anomaly.report.v1'
    }
}
