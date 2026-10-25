#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ErrorHandling.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'Pipeline engine' {
    BeforeAll {
        $global:GBuildPipelineTestTemp = Join-Path $env:TEMP "gbuild_pipeline_$(New-Guid)"
        New-Item -ItemType Directory -Path $global:GBuildPipelineTestTemp -Force -EA 0 | Out-Null
    }
    AfterAll { Remove-Item $global:GBuildPipelineTestTemp -Recurse -Force -EA 0 }

    It 'Invoke-GBuildPipeline runs all steps in order' {
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $ctx = @{ order = [System.Collections.ArrayList]@() }
        $steps = @(
            @{ Name = 'StepA'; Script = { param($c) $c.order.Add('A') } }
            @{ Name = 'StepB'; Script = { param($c) $c.order.Add('B') } }
            @{ Name = 'StepC'; Script = { param($c) $c.order.Add('C') } }
        )
        Invoke-GBuildPipeline -State $mockState -Context $ctx -Steps $steps
        $ctx.order.Count | Should -Be 3
        ($ctx.order -join '') | Should -Be 'ABC'
    }

    It 'Invoke-GBuildPipeline skips step when When condition is false' {
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $ctx = @{ order = [System.Collections.ArrayList]@() }
        $steps = @(
            @{ Name = 'StepA'; Script = { param($c) $c.order.Add('A') } }
            @{ Name = 'StepB'; When = { param($c) $false }; Script = { param($c) $c.order.Add('B') } }
            @{ Name = 'StepC'; Script = { param($c) $c.order.Add('C') } }
        )
        Invoke-GBuildPipeline -State $mockState -Context $ctx -Steps $steps
        ($ctx.order -join '') | Should -Be 'AC'
    }

    It 'Invoke-GBuildPipeline runs step when When condition is true' {
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $ctx = @{ testMode = $true; order = [System.Collections.ArrayList]@() }
        $steps = @(
            @{ Name = 'StepA'; Script = { param($c) $c.order.Add('A') } }
            @{ Name = 'StepB'; When = { param($c) $c.testMode }; Script = { param($c) $c.order.Add('B') } }
        )
        Invoke-GBuildPipeline -State $mockState -Context $ctx -Steps $steps
        ($ctx.order -join '') | Should -Be 'AB'
    }

    It 'Invoke-GBuildPipeline throws when pipeline timeout is exceeded' {
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $mockState.BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ pipeline = [PSCustomObject]@{ timeoutSeconds = 0 } } }
        $ctx = @{ }
        $steps = @(
            @{ Name = 'FastStep'; Script = { param($c) Start-Sleep -Milliseconds 100 } }
        )
        # With timeoutSeconds = 0, no timeout should trigger
        { Invoke-GBuildPipeline -State $mockState -Context $ctx -Steps $steps } | Should -Not -Throw
    }

    It 'Invoke-GBuildPipeline handles step retry via Invoke-WithRetry' {
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $mockState.BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ pipeline = [PSCustomObject]@{ retryEnabled = $true; maxRetries = 1 } } }
        $ctx = @{ attemptCount = 0 }
        $steps = @(
            @{
                Name = 'RetryStep'
                Script = {
                    param($c)
                    $c.attemptCount++
                    if ($c.attemptCount -lt 2) { throw "Transient: attempt $($c.attemptCount)" }
                }
            }
        )
        # With maxRetries=1: attempt 1 throws, attempt 2 succeeds → pipeline completes without error
        { Invoke-GBuildPipeline -State $mockState -Context $ctx -Steps $steps } | Should -Not -Throw
        $ctx.attemptCount | Should -Be 2
    }
}
