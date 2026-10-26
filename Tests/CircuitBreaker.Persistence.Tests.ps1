#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "Circuit Breaker State Persistence" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ErrorHandling.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:tempStateFile = Join-Path $( [System.IO.Path]::GetTempPath() ) ("gbuild_cb_test_{0}.gbuildstate" -f [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        Reset-CircuitBreaker
        if (Test-Path $global:tempStateFile) { Remove-Item $global:tempStateFile -Force -ErrorAction SilentlyContinue }
    }

    It "Saves breaker state to disk when persistState is enabled and threshold is reached" {
        $state = [PSCustomObject]@{
            ScriptRoot = (Split-Path -Parent $global:tempStateFile)
            BuildConfig = [PSCustomObject]@{
                errorHandling = [PSCustomObject]@{
                    circuitBreaker = [PSCustomObject]@{ enabled = $true; failureThreshold = 2; resetTimeoutMs = 100000; persistState = $true; statePath = $global:tempStateFile }
                }
            }
        }
        Initialize-CircuitBreaker -State $state | Out-Null
        # Force two failures to trip the breaker open
        { Invoke-WithCircuitBreaker -Action { throw 'fail1' } -OperationName 'T' -State $state } | Should -Throw
        { Invoke-WithCircuitBreaker -Action { throw 'fail2' } -OperationName 'T' -State $state } | Should -Throw
        $cb = Get-CircuitBreakerState
        $cb.State | Should -Be 'Open'
        Test-Path $global:tempStateFile | Should -BeTrue
    }

    It "Restores a previously persisted Open state on Initialize" {
        # Manually write an Open breaker state file
        $saved = [PSCustomObject]@{
            CircuitBreaker = [PSCustomObject]@{
                State = 'Open'; FailureCount = 9; SuccessCount = 0; LastFailureTime = (Get-Date); LastStateChange = (Get-Date); Configured = $true; Threshold = 5; ResetTimeoutMs = 60000
            }
            SavedAt = (Get-Date).ToString('o')
        }
        $saved | Export-Clixml -Path $global:tempStateFile -Force
        $state = [PSCustomObject]@{
            ScriptRoot = (Split-Path -Parent $global:tempStateFile)
            BuildConfig = [PSCustomObject]@{
                errorHandling = [PSCustomObject]@{
                    circuitBreaker = [PSCustomObject]@{ enabled = $true; failureThreshold = 5; resetTimeoutMs = 100000; persistState = $true; statePath = $global:tempStateFile }
                }
            }
        }
        Initialize-CircuitBreaker -State $state | Out-Null
        $cb = Get-CircuitBreakerState
        $cb.State | Should -Be 'Open'
        $cb.FailureCount | Should -Be 9
    }

    It "Save/Restore round-trips through Save-CircuitBreakerState / Restore-CircuitBreakerState" {
        Reset-CircuitBreaker
        $state = [PSCustomObject]@{ ScriptRoot = (Split-Path -Parent $global:tempStateFile) }
        Save-CircuitBreakerState -State $state -Path $global:tempStateFile | Should -BeTrue
        Test-Path $global:tempStateFile | Should -BeTrue
        $restored = Restore-CircuitBreakerState -State $state -Path $global:tempStateFile
        $restored | Should -BeTrue
    }
}
