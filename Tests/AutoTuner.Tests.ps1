#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'AutoTuner.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "AutoTuner (self-optimizing build performance)" {
    BeforeAll {
        $script:tempDir = Join-Path $( [System.IO.Path]::GetTempPath() ) "gbuild-autotune-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-AutoTuneConfig returns defaults when State has no autoTune section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        $cfg = Get-AutoTuneConfig -State $state
        $cfg.enabled | Should -Be $false
        $cfg.autoApply | Should -Be $false
        $cfg.maxHistoryEntries | Should -Be 200
        $cfg.minSamplesBeforeTune | Should -Be 5
    }

    It "Get-AutoTuneConfig reads the autoTune section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; autoApply = $true; maxHistoryEntries = 100 } } }
        $cfg = Get-AutoTuneConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.autoApply | Should -BeTrue
        $cfg.maxHistoryEntries | Should -Be 100
    }

    It "Write-AutoTuneSample appends a JSON line to the history file" {
        $historyFile = Join-Path $tempDir "autotune-history.jsonl"
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $historyFile } }; ScriptRoot = $tempDir }
        Write-AutoTuneSample -Sample @{ DurationSec = 120.5; Success = $true; ProjectType = 'Web'; ParallelJobs = 4; CacheHit = $false; Incremental = $true; CpuCount = 8; MemoryGB = 16.0 } -State $state
        Test-Path $historyFile | Should -BeTrue
        $line = Get-Content $historyFile -Raw
        $line | Should -Match '"DurationSec":120.5'
        $line | Should -Match '"Success":true'
    }

    It "Get-AutoTuneRecommendations returns empty when insufficient samples" {
        $historyFile = Join-Path $tempDir "autotune-history-empty.jsonl"
        "" | Set-Content -Path $historyFile -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $historyFile; minSamplesBeforeTune = 5 } }; ScriptRoot = $tempDir }
        $rec = Get-AutoTuneRecommendations -State $state
        $rec.Recommendations.Count | Should -Be 0
        $rec.SampleCount | Should -Be 0
    }

    It "Get-AutoTuneRecommendations returns recommendations when enough samples exist" {
        $historyFile = Join-Path $tempDir "autotune-history-full.jsonl"
        $lines = @()
        for ($i = 0; $i -lt 10; $i++) {
            $entry = [PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); DurationSec = 30.0; Success = $true; ProjectType = 'Web'; ParallelJobs = 2; CacheHit = $false; Incremental = $true; CpuCount = 8; MemoryGB = 16.0 }
            $lines += ($entry | ConvertTo-Json -Compress)
        }
        $lines | Set-Content -Path $historyFile -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $historyFile; minSamplesBeforeTune = 5 } }; ScriptRoot = $tempDir }
        $rec = Get-AutoTuneRecommendations -State $state
        $rec.SampleCount | Should -Be 10
        $rec.Recommendations | Should -Not -BeNullOrEmpty
    }

    It "Invoke-AutoTuneApply returns empty when autoApply is false" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; autoApply = $false } } }
        $applied = Invoke-AutoTuneApply -State $state
        @($applied).Count | Should -Be 0
    }

    It "Undo-AutoTuneApply is a no-op with empty backup" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultPort = 5000 } } }
        & (Get-Module AutoTuner) { $script:AutoTuneBackup = @{} }
        $restored = Undo-AutoTuneApply -State $state
        @($restored).Count | Should -Be 0
        $state.BuildConfig.build.defaultPort | Should -Be 5000
    }

    It "Undo-AutoTuneApply restores the pre-apply value and clears backup" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultPort = 9999 } } }
        & (Get-Module AutoTuner) { $script:AutoTuneBackup = @{ 'build.defaultPort' = @{ HadPrevious = $true; Previous = 5000 } } }
        $restored = Undo-AutoTuneApply -State $state
        @($restored) | Should -Contain 'build.defaultPort'
        $state.BuildConfig.build.defaultPort | Should -Be 5000
        $again = Undo-AutoTuneApply -State $state
        @($again).Count | Should -Be 0
    }

    It "AutoTuneStats helpers aggregate identically to ML recommendations (DRY contract)" {
        # Get-AutoTuneMLRecommendations feeds these helpers (not manual sums).
        # Helpers are module-internal: exercise via module session state.
        $fin = & (Get-Module AutoTuner) {
            $st = @{ Count = 0; DurationSecSum = 0.0; SuccessCount = 0; CacheHitCount = 0; ParallelJobs = [System.Collections.ArrayList]@(); CpuCount = 0; MemoryGBSum = 0.0 }
            $st = AutoTuneStatsAddSample -Stats $st -DurationSec 30.0 -Success $true -CacheHit $false
            $st = AutoTuneStatsAddSample -Stats $st -DurationSec 60.0 -Success $false -CacheHit $true
            AutoTuneStatsFinalize -Stats $st
        }
        $fin.Count | Should -Be 2
        $fin.AvgDurationSec | Should -Be 45.0
        $fin.FailRate | Should -Be 0.5
        $fin.CacheHitRate | Should -Be 0.5
    }
}

Describe 'AutoTuner safety' {
    It 'rejects a history path outside the configured root' {
        $root = Join-Path $TestDrive 'contained'
        $outside = Join-Path $TestDrive 'outside-history.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $outside } }; WorkingDir = $root }
        Write-AutoTuneSample -Sample @{ DurationSec = 10; Success = $true } -State $state | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It 'applies and undoes guarded configuration values' {
        $history = Join-Path $TestDrive 'apply-history.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; autoApply = $true; historyPath = $history; minSamplesBeforeTune = 5 }; build = [PSCustomObject]@{ cacheLocal = [PSCustomObject]@{ maxEntries = 256; maxSizeMb = 512 } } }; WorkingDir = (Split-Path -Parent $history) }
        1..10 | ForEach-Object { Write-AutoTuneSample -Sample @{ DurationSec = 30; Success = $true; CacheHit = $false } -State $state }
        $applied = @(Invoke-AutoTuneApply -State $state)
        $applied.Count | Should -BeGreaterThan 0
        $state.BuildConfig.build.cacheLocal.maxEntries | Should -Not -Be 256
        [void](Undo-AutoTuneApply -State $state)
        $state.BuildConfig.build.cacheLocal.maxEntries | Should -Be 256
    }

    It 'serializes concurrent history writers without malformed lines' {
        $history = Join-Path $TestDrive 'concurrent-history.jsonl'
        $historyRoot = Split-Path -Parent $history
        $module = Join-Path $global:GBuildModuleRoot 'AutoTuner.psm1'
        $jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock { param($m, $h, $root) Import-Module $m -Force -DisableNameChecking; $s = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $h } }; WorkingDir = $root }; 1..4 | ForEach-Object { Write-AutoTuneSample -Sample @{ DurationSec = 10; Success = $true } -State $s } } -ArgumentList $module, $history, $historyRoot }
        $jobs | Wait-Job | Out-Null
        $jobs | Receive-Job | Out-Null
        $jobs | Remove-Job
        $lines = @(Get-Content -LiteralPath $history -ErrorAction SilentlyContinue)
        $lines.Count | Should -Be 8
        foreach ($line in $lines) { { $line | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw }
    }

    It 'does not fabricate a p-value' {
        $result = & (Get-Module AutoTuner) { $r = New-AutoTuneRegressor; $r = AutoTuneRegressorUpdate -Reg $r -x 0 -y 1; $r = AutoTuneRegressorUpdate -Reg $r -x 1 -y 2; AutoTuneRegressorResult -Reg $r }
        $result.PValue | Should -BeNullOrEmpty
        $result.Significance | Should -Be 'not-computed'
    }
}
