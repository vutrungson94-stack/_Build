#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$ErrorActionPreference = 'Stop'

# Import shared helpers before anything else
$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $testRoot) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $testRoot 'Helpers/MockHelpers.psm1') -Force -DisableNameChecking -ErrorAction Stop

$global:state = New-FullTestState

Describe "Config Integration" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
        # L5 test isolation: other test files reuse the $global:state name for
        # mocks (e.g. Project.Tests). Rebuild the real config state here so this
        # block never depends on file-top execution order in batched runs.
        $global:state = New-FullTestState
    }

    It "New-FullTestState loads the real gbuild.config.json into BuildConfig" {
        $global:state | Should -Not -BeNullOrEmpty
        $global:state.BuildConfig | Should -Not -BeNullOrEmpty
        $global:state.BuildConfig.PSObject.Properties.Name -contains 'build' | Should -BeTrue
    }

    It "Test-BuildConfig validates the real config against its schema" {
        Test-BuildConfig -State $global:state | Should -BeTrue
    }

    It "Get-ActiveProfile returns the CI profile with enableJsonLog set" {
        $ci = Get-ActiveProfile -State $global:state -ProfileName 'CI'
        $ci | Should -Not -BeNullOrEmpty
        $ci.enableJsonLog | Should -BeTrue
    }

    It "Get-ActiveProfile returns the Release profile by default" {
        $rel = Get-ActiveProfile -State $global:state
        $rel | Should -Not -BeNullOrEmpty
        $rel.configuration | Should -Be 'Release'
    }

    It "Resolve-ConfigValue resolves nested config keys" {
        Resolve-ConfigValue -State $global:state -Path 'ci.docker.enabled' -Default $false | Should -BeTrue
    }

    It "Resolve-ConfigValue returns the default for a missing key" {
        Resolve-ConfigValue -State $global:state -Path 'does.not.exist' -Default 'fallback' | Should -Be 'fallback'
    }

    It "validates the effective merged config with the shipped schema" {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $projectConfig = Join-Path $TestDrive 'gbuild.config.json'
        [PSCustomObject]@{
            description = 'project override'
            build = [PSCustomObject]@{ enableIncremental = $false }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $projectConfig -Encoding UTF8
        $state = [PSCustomObject]@{
            ScriptRoot = $buildRoot
            ProjectRoot = $TestDrive
            BuildConfig = $null
        }
        $null = Initialize-BuildConfigState -State $state
        Test-BuildConfig -State $state -Strict | Should -BeTrue
        $state.ConfigPath | Should -Be $projectConfig
        $state.ConfigSchemaPath | Should -Be (Join-Path $buildRoot 'gbuild.config.schema.json')
    }
}

Describe "Merge-ConfigTenantOverride" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:toBase = [pscustomobject]@{
            version = '1.0.0'
            build   = [pscustomobject]@{ maxParallelJobs = 4; languageMap = @(@{ Language = 'Kotlin'; BuildTool = 'gradle' }) }
            tenancy = [pscustomobject]@{ overrides = [pscustomobject]@{ acme = [pscustomobject]@{ build = [pscustomobject]@{ maxParallelJobs = 1 } } } }
        }
    }

    It "returns the config unchanged when no TenantId is set" {
        $st = [PSCustomObject]@{}
        $r = Merge-ConfigTenantOverride -Config $global:toBase -State $st
        $r.build.maxParallelJobs | Should -Be 4
    }

    It "returns the config unchanged for the default tenant" {
        $st = [PSCustomObject]@{ TenantId = 'default' }
        $r = Merge-ConfigTenantOverride -Config $global:toBase -State $st
        $r.build.maxParallelJobs | Should -Be 4
    }

    It "returns the config unchanged when the tenant has no override" {
        $st = [PSCustomObject]@{ TenantId = 'other' }
        $r = Merge-ConfigTenantOverride -Config $global:toBase -State $st
        $r.build.maxParallelJobs | Should -Be 4
    }

    It "deep-merges tenancy.overrides.<tenantId> over the base config" {
        $st = [PSCustomObject]@{ TenantId = 'acme' }
        $r = Merge-ConfigTenantOverride -Config $global:toBase -State $st
        $r.build.maxParallelJobs | Should -Be 1
        # PS 5.1 + StrictMode: a 1-element array unrolls to a scalar -> direct .Count returns $null
        @($r.build.languageMap).Count | Should -Be 1
        $r.version | Should -Be '1.0.0'
    }

    It "accepts hashtable config trees" {
        $base = @{
            version = '1.0.0'
            build   = @{ maxParallelJobs = 4; languageMap = @() }
            tenancy = @{ overrides = @{ acme = @{ build = @{ maxParallelJobs = 9 } } } }
        }
        $st = [PSCustomObject]@{ TenantId = 'acme' }
        $r = Merge-ConfigTenantOverride -Config $base -State $st
        $r.build.maxParallelJobs | Should -Be 9
    }
}