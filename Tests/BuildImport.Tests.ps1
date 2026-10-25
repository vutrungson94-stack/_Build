#Requires -Version 5.1
Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Import-GBuildModule' {
    It 'returns $false for a missing optional module (no -Required)' {
        Import-GBuildModule -Names 'Zz_NoSuchModule_12345' | Should -Be $false
    }

    It 'throws for a missing -Required module' {
        { Import-GBuildModule -Names 'Zz_NoSuchModule_12345' -Required } | Should -Throw
    }

    It 'supports loading multiple names at once' {
        $r = Import-GBuildModule -Names @('PathUtils', 'SharedUtils')
        $r | Should -Be $true
    }

    It 'honors -SkipIfLoaded without re-importing an existing module' {
        $null = Import-GBuildModule -Names 'PathUtils' -Force
        Import-GBuildModule -Names 'PathUtils' -SkipIfLoaded | Should -Be $true
    }
}

Describe 'Import-BuildModule / Import-BuildDependencies' {
    It 'Import-BuildModule returns $true and does not throw' {
        Import-BuildModule -Dependencies @('PathUtils') | Should -Be $true
    }

    It 'Import-BuildDependencies ignores unknown optional modules gracefully' {
        { Import-BuildDependencies -Modules @('Zz_NoSuchModule_12345') } | Should -Not -Throw
    }
}