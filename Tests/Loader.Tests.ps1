Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/Loader.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'Loader' {
    BeforeAll {
        if (Get-Command Register-Plugins -ErrorAction SilentlyContinue) {
            Register-Plugins -State $null
        }
    }

    It 'Resolve-PluginForLanguage returns correct plugin for C#' {
        $plugin = Resolve-PluginForLanguage -Language 'C#'
        $plugin | Should -Not -BeNullOrEmpty
        $plugin.Info.Name | Should -Be 'Dotnet'
    }

    It 'Resolve-PluginForLanguage returns correct plugin for Python' {
        $plugin = Resolve-PluginForLanguage -Language 'Python'
        $plugin | Should -Not -BeNullOrEmpty
        $plugin.Info.Name | Should -Be 'Python'
    }

    It 'Resolve-PluginForLanguage returns correct plugin for Go' {
        $plugin = Resolve-PluginForLanguage -Language 'Go'
        $plugin | Should -Not -BeNullOrEmpty
        $plugin.Info.Name | Should -Be 'Go'
    }

    It 'Resolve-PluginForLanguage returns correct plugin for PowerShell' {
        $plugin = Resolve-PluginForLanguage -Language 'PowerShell'
        $plugin | Should -Not -BeNullOrEmpty
        $plugin.Info.Name | Should -Be 'PowerShell'
    }

    It 'Resolve-PluginForLanguage returns nothing for unknown language' {
        $plugin = Resolve-PluginForLanguage -Language 'UnknownLanguage'
        $plugin | Should -BeNullOrEmpty
    }

    It 'All supported languages resolve to a plugin' {
        $languages = @('C#', 'Python', 'Go', 'Java', 'Rust', 'Node.js', 'Ruby', 'PHP', 'Docker', 'PowerShell')
        foreach ($lang in $languages) {
            $plugin = Resolve-PluginForLanguage -Language $lang
            $plugin | Should -Not -BeNullOrEmpty
        }
    }
}
