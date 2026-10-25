#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Chaos.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "Chaos (resilience testing)" {
    It "Get-ChaosConfig returns defaults when State has no chaos section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        $cfg = Get-ChaosConfig -State $state
        $cfg.enabled | Should -Be $false
        $cfg.scenarios.Count | Should -Be 0
        $cfg.seed | Should -Be 42
    }

    It "Get-ChaosConfig reads the chaos section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true; scenarios = @('ToolMissing','DiskFull'); seed = 123 } } }
        $cfg = Get-ChaosConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.scenarios.Count | Should -Be 2
        $cfg.seed | Should -Be 123
    }

    It "Invoke-ChaosScenario returns Skipped when chaos is disabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $false } } }
        $result = Invoke-ChaosScenario -Scenario 'ToolMissing' -State $state
        $result.Status | Should -Be 'Skipped'
    }

    It "Invoke-ChaosScenario returns Failed for unknown scenario" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'NonExistentScenario' -State $state
        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -Match 'Unknown scenario'
    }

    It "Invoke-ChaosScenario injects ToolMissing scenario when enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'ToolMissing' -State $state
        $result.Status | Should -Be 'Injected'
        $result.Scenario | Should -Be 'ToolMissing'
    }

    It "Invoke-ChaosScenario injects DiskFull scenario when enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'DiskFull' -State $state
        $result.Status | Should -Be 'Injected'
    }

    It "Invoke-ChaosScenario injects TransientNetwork scenario when enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'TransientNetwork' -State $state
        $result.Status | Should -Be 'Injected'
        $result.Scenario | Should -Be 'TransientNetwork'
    }

    It "Invoke-ChaosScenario injects RetryExhausted scenario when enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'RetryExhausted' -State $state
        $result.Status | Should -Be 'Injected'
        $state.ChaosRetryOverride | Should -Be 0
    }

    It "Invoke-ChaosScenario injects RollbackTrigger scenario when enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true } } }
        $result = Invoke-ChaosScenario -Scenario 'RollbackTrigger' -State $state
        $result.Status | Should -Be 'Injected'
        $state.ChaosRollback | Should -BeTrue
    }

    It "Invoke-ChaosSuite runs all scenarios when enabled with empty list" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $true; scenarios = @() } } }
        $suite = Invoke-ChaosSuite -State $state
        $suite.Total | Should -Be 6
        $suite.Passed | Should -Be 6
        $suite.Status | Should -Be 'Passed'
    }

    It "Invoke-ChaosSuite returns Skipped when disabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ chaos = [PSCustomObject]@{ enabled = $false } } }
        $suite = Invoke-ChaosSuite -State $state
        $suite.Status | Should -Be 'Skipped'
    }
}
