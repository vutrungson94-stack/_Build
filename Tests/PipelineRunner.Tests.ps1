#Requires -Version 5.1
Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
# BuildConstants is required for the watchdog tests: Get-BuildConstant resolves
# StepTimeoutSeconds through BuildConstants (ConfigKeyMap + BuildDefaults), and
# without it every lookup degrades to the caller fallback (0 = off).
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildConstants.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
# Pipeline step engine now lives in Orchestrator (PipelineRunner module was merged).
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Describe 'Resolve-PipelineSteps' {
    It 'returns caller steps when no config pipeline steps are defined' {
        $state = [pscustomobject]@{ BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ pipeline = [pscustomobject]@{ } } } }
        $caller = @(
            [pscustomobject]@{ Name = 'A'; Script = { 'a' } }
        )
        $resolved = Resolve-PipelineSteps -State $state -CallerSteps $caller
        $resolved.Count | Should -Be 1
        $resolved[0].Name | Should -Be 'A'
    }

    It 'maps config steps to scriptblocks with Name/Script/When/Retry' {
        $state = [pscustomobject]@{
            BuildConfig = [pscustomobject]@{
                build = [pscustomobject]@{
                    pipeline = [pscustomobject]@{
                        steps = @(
                            [pscustomobject]@{ name = 'StepOne'; script = "'x'"; when = '$true'; retry = 2; timeoutSeconds = 5 }
                        )
                    }
                }
            }
        }
        $resolved = Resolve-PipelineSteps -State $state -CallerSteps @()
        $resolved.Count | Should -Be 1
        $resolved[0].Name | Should -Be 'StepOne'
        $resolved[0].Script | Should -BeOfType [scriptblock]
        $resolved[0].When | Should -BeOfType [scriptblock]
        $resolved[0].Retry | Should -Be 2
        $resolved[0].TimeoutSeconds | Should -Be 5
    }

    It 'defaults name when config step has no name' {
        $state = [pscustomobject]@{
            BuildConfig = [pscustomobject]@{
                build = [pscustomobject]@{
                    pipeline = [pscustomobject]@{
                        steps = @( [pscustomobject]@{ script = "'y'" } )
                    }
                }
            }
        }
        $resolved = Resolve-PipelineSteps -State $state -CallerSteps @()
        $resolved.Count | Should -Be 1
        $resolved[0].Name | Should -Match '^Step'
    }
}

Describe 'Invoke-PipelineStep' {
    It 'executes a step Script and returns its output text' {
        $ctx = @{}
        $result = Invoke-PipelineStep -Step @{ Name = 'T'; Script = { 'hello' } } -Context $ctx -State ([pscustomobject]@{ LogLevel = 0 })
        $result | Select-Object -Last 1 | Should -Be 'hello'
    }

    It 'does not throw when a step has no timeout and succeeds' {
        $ctx = @{}
        { Invoke-PipelineStep -Step @{ Name = 'T'; Script = { 'ok' } } -Context $ctx -State ([pscustomobject]@{ LogLevel = 0 }) } | Should -Not -Throw
    }
}

Describe 'Invoke-PipelineStep watchdog (stepTimeoutSeconds)' {
    # Root-level config dot-path 'stepTimeoutSeconds' (BuildConstants.ConfigKeyMap
    # maps StepTimeoutSeconds -> 'stepTimeoutSeconds'; 0 = disabled, registered default).
    # The watchdog evaluates elapsed time when the step returns, appends an
    # ErrorRecord, and the output scan then throws -> retry/rethrow semantics.
    It 'flags a step that exceeds the configured stepTimeoutSeconds' {
        $state = [pscustomobject]@{ LogLevel = 0; BuildConfig = [pscustomobject]@{ stepTimeoutSeconds = 1 } }
        $step = @{
            Name   = 'SlowStep'
            Script = { param($ctx) Start-Sleep -Seconds 2; 'late output' }
        }
        { Invoke-PipelineStep -Step $step -Context @{} -State $state } | Should -Throw
    }

    It 'does not flag a step when stepTimeoutSeconds is 0 (disabled)' {
        $state = [pscustomobject]@{ LogLevel = 0; BuildConfig = [pscustomobject]@{ stepTimeoutSeconds = 0 } }
        $step = @{ Name = 'QuickStep'; Script = { param($ctx) Start-Sleep -Milliseconds 100; 'ok' } }
        { Invoke-PipelineStep -Step $step -Context @{} -State $state } | Should -Not -Throw
    }

    It 'falls back to the registered default (0 = off) when config carries no stepTimeoutSeconds' {
        $state = [pscustomobject]@{ LogLevel = 0 }
        $step = @{ Name = 'DefaultOffStep'; Script = { param($ctx) 'ok' } }
        $result = Invoke-PipelineStep -Step $step -Context @{} -State $state
        $result | Select-Object -Last 1 | Should -Be 'ok'
    }
}