Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/Menu.psm1'
$global:GBuildModuleRoot = Join-Path $PSScriptRoot '../Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
Import-Module $modulePath -Force -DisableNameChecking

Describe 'Menu' {
    BeforeAll {
        if (Get-Command Set-CurrentLocale -ErrorAction SilentlyContinue) {
            Set-CurrentLocale -Locale 'en'
        }
    }

    It 'Get-MenuLabel returns English fallback for known key' {
        $label = Get-MenuLabel -Key 'menu.exit'
        $label | Should -Be 'Exit'
    }

    It 'Get-MenuLabel returns key itself for unknown key' {
        $label = Get-MenuLabel -Key 'menu.nonexistent'
        $label | Should -Be 'menu.nonexistent'
    }

    It 'New-GuildMenuConfig returns hashtable with expected keys' {
        $state = [PSCustomObject]@{ OS = 'Windows' }
        $config = New-GuildMenuConfig -ProjectType 'Web' -OS 'Windows' -State $state
        $config | Should -Not -BeNullOrEmpty
        $config.ContainsKey('0') | Should -Be $true
    }

    It 'New-GuildMenuConfig marks MacOS-only choices as unsupported on Windows' {
        $state = [PSCustomObject]@{ OS = 'Windows' }
        $config = New-GuildMenuConfig -ProjectType 'iOS' -OS 'Windows' -State $state
        if ($config.ContainsKey('4')) {
            $config['4'].Supported | Should -Be $false
        }
    }
    It 'Show-BuildEnvironmentSummary is exported (config customEntries handler)' {
        Get-Command Show-BuildEnvironmentSummary -Module Menu -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Show-BuildEnvironmentSummary returns $true (handler contract)' {
        $state = [PSCustomObject]@{ OS = 'Windows'; BuildConfig = [PSCustomObject]@{ version = '1.0' } }
        Show-BuildEnvironmentSummary -State $state -ProjPath '' -ProjectDir '' -ProjectType 'Console' | Should -Be $true
    }
}
