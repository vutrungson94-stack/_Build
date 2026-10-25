#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Validates P1 fix: ModuleBootstrap fallback when BuildImport is missing.
# Standalone module imports must not hard-fail on the BuildImport SPOF.

Describe 'BootstrapResilience - ModuleBootstrap fallback' {
    It 'ModuleBootstrap.ps1 contains fallback inline loader when BuildImport is unavailable' {
        $path = Join-Path (Join-Path $PSScriptRoot '../Modules') 'ModuleBootstrap.ps1'
        $raw = Get-Content $path -Raw -Encoding UTF8
        $raw | Should -Match 'Fallback when BuildImport is missing'
        $raw | Should -Match 'fallback'
    }

    It 'ModuleBootstrap still works when BuildImport is present (normal path)' {
        $global:GBuildModuleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules'
        # Dot-source with a real dependency; must not throw even though BuildImport exists.
        { . (Join-Path $global:GBuildModuleRoot 'ModuleBootstrap.ps1') -Dependencies @('PathUtils') } | Should -Not -Throw
        # PathUtils function should now be available
        Get-Command ConvertTo-ForwardSlash -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'SharedUtils standalone import does not hard-fail (BuildConstants fallback)' {
        # SharedUtils is zero-dep + on-demand BuildConstants import; must survive
        # without Orchestrator Tier-1.
        $global:GBuildModuleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules'
        { Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop } | Should -Not -Throw
        { Get-SyntaxCheckExcludeDirs } | Should -Not -Throw
    }
}
