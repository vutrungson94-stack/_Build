#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/PowerShell.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'PowerShell plugin' {
    BeforeAll {
        $global:GBuildPsTemp = Join-Path $env:TEMP "gbuild_pstest_$(New-Guid)"
        New-Item -ItemType Directory -Path $global:GBuildPsTemp -Force -EA 0 | Out-Null
    }
    AfterAll {
        if (Test-Path $global:GBuildPsTemp) { Remove-Item $global:GBuildPsTemp -Recurse -Force -EA 0 }
    }

    It 'Get-PluginInfo advertises PowerShell language with metadata' {
        $info = & (Get-Command -Module PowerShell -Name 'Get-PluginInfo' -ErrorAction Stop)
        $info | Should -Not -BeNullOrEmpty
        $info.Name | Should -Be 'PowerShell'
        $info.SupportedLanguages | Should -Contain 'PowerShell'
        $info.BuildCommand | Should -Not -BeNullOrEmpty
    }

    It 'exposes the full plugin contract (5 functions)' {
        foreach ($fn in @('Get-PluginInfo', 'Invoke-PluginBuild', 'Invoke-PluginTest', 'Invoke-PluginLint', 'Invoke-PluginPreflight')) {
            Get-Command $fn -Module PowerShell -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $fn
        }
    }

    It 'Invoke-PluginBuild fails (returns $false) on a project with a syntax error' {
        $badDir = Join-Path $global:GBuildPsTemp 'bad'
        New-Item -ItemType Directory -Path $badDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $badDir 'bad.ps1') -Value 'function Broken { Write-Output "unterminated'
        $ms = New-TestState; $ms.LogLevel = 0; $ms.ScriptRoot = $global:GBuildPsTemp
        $r = & (Get-Command -Module PowerShell -Name 'Invoke-PluginBuild') -State $ms -ProjectDir $badDir
        $r | Should -BeOfType [bool]
        $r | Should -Be $false
    }

    It 'Invoke-PluginBuild passes (returns $true) on a valid script' {
        $goodDir = Join-Path $global:GBuildPsTemp 'good'
        New-Item -ItemType Directory -Path $goodDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $goodDir 'good.ps1') -Value 'function Hello { "world" }'
        $ms = New-TestState; $ms.LogLevel = 0; $ms.ScriptRoot = $global:GBuildPsTemp
        $r = & (Get-Command -Module PowerShell -Name 'Invoke-PluginBuild') -State $ms -ProjectDir $goodDir
        $r | Should -BeOfType [bool]
        $r | Should -Be $true
    }

    It 'Invoke-PluginPreflight warns (graceful) when no manifest is present' {
        $ms = New-TestState; $ms.LogLevel = 0; $ms.ScriptRoot = $global:GBuildPsTemp
        $empty = Join-Path $global:GBuildPsTemp 'empty'
        New-Item -ItemType Directory -Path $empty -Force -EA 0 | Out-Null
        $r = & (Get-Command -Module PowerShell -Name 'Invoke-PluginPreflight') -State $ms -ProjectDir $empty
        $r | Should -Not -BeNullOrEmpty
        $r.Passed | Should -Be $true
        $r.Warnings | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-PluginTest and Invoke-PluginLint return a bool (graceful skip if no Pester/PSSA)' {
        $ms = New-TestState; $ms.LogLevel = 0; $ms.ScriptRoot = $global:GBuildPsTemp
        $goodDir = Join-Path $global:GBuildPsTemp 'good'
        $t = & (Get-Command -Module PowerShell -Name 'Invoke-PluginTest') -State $ms -ProjectDir $goodDir
        $t | Should -BeOfType [bool]
        $l = & (Get-Command -Module PowerShell -Name 'Invoke-PluginLint') -State $ms -ProjectDir $goodDir
        $l | Should -BeOfType [bool]
    }
}