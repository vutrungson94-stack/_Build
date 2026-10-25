#Requires -Version 5.1
Set-StrictMode -Version 1.0

Describe 'CircuitBreaker' {

    BeforeAll {
        $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'ErrorHandling.psm1')
        Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Reset-CircuitBreaker
    }

    It 'Initialize-CircuitBreaker reads config (enabled/threshold/reset)' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=2; resetTimeoutMs=1 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        Initialize-CircuitBreaker -State $state
        $got = Get-CircuitBreakerState
        $got.Configured       | Should -Be $true
        $got.Threshold        | Should -Be 2
        $got.ResetTimeoutMs   | Should -Be 1
    }

    It 'Disabled breaker runs action and stays Closed' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$false; failureThreshold=2; resetTimeoutMs=1 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        $result = Invoke-WithCircuitBreaker -Action { 42 } -State $state
        $result | Should -Be 42
        (Get-CircuitBreakerState).State | Should -Be 'Closed'
    }

    It 'Closed goes Open after reaching failure threshold' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=2; resetTimeoutMs=10000 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        { Invoke-WithCircuitBreaker -Action { throw 'boom' } -State $state } | Should -Throw
        { Invoke-WithCircuitBreaker -Action { throw 'boom' } -State $state } | Should -Throw
        (Get-CircuitBreakerState).State | Should -Be 'Open'
    }

    It 'Open breaker blocks execution and throws InvalidOperationException' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=2; resetTimeoutMs=10000 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        { Invoke-WithCircuitBreaker -Action { throw 'boom' } -State $state } | Should -Throw
        { Invoke-WithCircuitBreaker -Action { throw 'boom' } -State $state } | Should -Throw

        $ran = @{ Value = $false }
        { Invoke-WithCircuitBreaker -Action { $ran.Value = $true; 1 } -State $state } | Should -Throw -ExceptionType ([System.InvalidOperationException])
        $ran.Value | Should -Be $false
    }

    It 'HalfOpen on timeout then success closes breaker' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=1; resetTimeoutMs=100 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        { Invoke-WithCircuitBreaker -Action { throw 'x' } -State $state } | Should -Throw
        (Get-CircuitBreakerState).State | Should -Be 'Open'

        Start-Sleep -Milliseconds 150
        (Get-CircuitBreakerState).State | Should -Be 'HalfOpen'

        $result = Invoke-WithCircuitBreaker -Action { 'ok' } -State $state
        $result | Should -Be 'ok'
        $after = Get-CircuitBreakerState
        $after.State        | Should -Be 'Closed'
        $after.FailureCount | Should -Be 0
    }

    It 'HalfOpen on timeout then failure re-opens breaker' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=1; resetTimeoutMs=100 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        { Invoke-WithCircuitBreaker -Action { throw 'x' } -State $state } | Should -Throw
        Start-Sleep -Milliseconds 150
        (Get-CircuitBreakerState).State | Should -Be 'HalfOpen'

        { Invoke-WithCircuitBreaker -Action { throw 'x' } -State $state } | Should -Throw
        (Get-CircuitBreakerState).State | Should -Be 'Open'
    }

    It 'Reset-CircuitBreaker returns breaker to Closed with zero counts' {
        $state = [PSCustomObject]@{
            ScriptRoot   = (Split-Path $PSScriptRoot)
            BuildConfig  = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ circuitBreaker = [PSCustomObject]@{ enabled=$true; failureThreshold=1; resetTimeoutMs=10000 } } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }
        { Invoke-WithCircuitBreaker -Action { throw 'x' } -State $state } | Should -Throw
        (Get-CircuitBreakerState).State | Should -Be 'Open'

        Reset-CircuitBreaker
        $after = Get-CircuitBreakerState
        $after.State        | Should -Be 'Closed'
        $after.FailureCount | Should -Be 0
    }
}
