#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'Environment model' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Add-DeployEnvironment and Get-DeployEnvironments round-trip' {
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{ deploy = $null }
        Add-DeployEnvironment -State $mockState -Name 'dev' -Branch 'develop'
        Add-DeployEnvironment -State $mockState -Name 'prod' -Branch 'main'
        $envs = Get-DeployEnvironments -State $mockState
        $envs.Count | Should -Be 2
        @($envs | Where-Object { $_.Name -eq 'dev' }).Count | Should -Be 1
        @($envs | Where-Object { $_.Name -eq 'prod' }).Count | Should -Be 1
    }

    It 'Test-ApprovalRequired returns true only for environments with requiresApproval' {
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{ deploy = $null }
        Add-DeployEnvironment -State $mockState -Name 'safe' -RequiresApproval:$false
        Add-DeployEnvironment -State $mockState -Name 'gated' -RequiresApproval
        Test-ApprovalRequired -State $mockState -EnvironmentName 'safe' | Should -Be $false
        Test-ApprovalRequired -State $mockState -EnvironmentName 'gated' | Should -Be $true
    }

    It 'Resolve-EnvironmentForBranch matches branch patterns' {
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{ deploy = $null }
        Add-DeployEnvironment -State $mockState -Name 'staging' -Branch 'staging/*'
        Add-DeployEnvironment -State $mockState -Name 'production' -Branch 'main'
        $env = Resolve-EnvironmentForBranch -State $mockState -Branch 'main'
        $env | Should -Not -BeNullOrEmpty
        $env.Name | Should -Be 'production'
    }

    It 'Get-DeployEnvironments handles empty config' {
        $mockState = New-TestState
        $envs = Get-DeployEnvironments -State $mockState
        if ($envs) {
            $envs.Count | Should -Be 0
        } else {
            $null | Should -Be $null
        }
    }

    It 'Publish-Environment handles unknown environments gracefully' {
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{ deploy = $null }
        $result = Publish-Environment -State $mockState -From 'nonexistent' -To 'also-nonexistent'
        $result | Should -Be $false
    }
}
