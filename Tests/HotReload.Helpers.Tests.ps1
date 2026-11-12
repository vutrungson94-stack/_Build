#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'HotReload.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'HotReload helper coverage' {
    It 'delegates to plugin run for non-dotnet projects when available' {
        $state = [PSCustomObject]@{ ProjectRoot = [System.IO.Path]::GetTempPath(); ScriptRoot = [System.IO.Path]::GetTempPath() }
        InModuleScope HotReload -Parameters @{ state = $state } {
            Mock Invoke-PluginRunFor { return $true }
            { Invoke-HotReload -State $state -ProjPath (Join-Path ([System.IO.Path]::GetTempPath()) 'app.py') -ProjectDir ([System.IO.Path]::GetTempPath()) -ProjectType 'Python' } | Should -Not -Throw
            Should -Invoke -CommandName Invoke-PluginRunFor -Times 1 -Exactly
        }
    }
}
