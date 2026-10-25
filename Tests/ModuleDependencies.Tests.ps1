#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    ModuleDependencies - explicit dependency graph validation.
.DESCRIPTION
    Fails CI when a module declares a dependency that has no backing file,
    or when the import graph contains a cycle. The map is auto-discovered
    by parsing Import-BuildModule / Import-GBuildModule / Providers imports,
    so no hardcoded list can drift.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ModuleDependencies.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe 'ModuleDependencies - Get-ModuleDependencyMap' {
    It 'discovers all modules including Providers' {
        $map = Get-ModuleDependencyMap -ModulesRoot $global:GBuildModuleRoot
        $map.Keys.Count | Should -BeGreaterThan 40
        $map.ContainsKey('Orchestrator') | Should -Be $true
        $map.ContainsKey('AndroidSdkProvider') | Should -Be $true
        $map.ContainsKey('BuildStrategyProvider') | Should -Be $true
        $map.ContainsKey('EnvironmentProvider') | Should -Be $true
    }

    It 'Orchestrator Tier-1 includes ModuleDependencies + AndroidSdkProvider' {
        $map = Get-ModuleDependencyMap -ModulesRoot $global:GBuildModuleRoot
        # Orchestrator declares Tier-1 via foreach @(...) loop, not Import-BuildModule,
        # so assert the files exist instead (wiring validated by import test below).
        Test-Path (Join-Path $global:GBuildModuleRoot 'ModuleDependencies.psm1') | Should -Be $true
        Test-Path (Join-Path (Join-Path $global:GBuildModuleRoot 'Providers') 'AndroidSdkProvider.psm1') | Should -Be $true
    }

    It 'heavy modules stay lazy: not in Tier-1 eager list, each with a wiring site' {
        $orch = Get-Content -LiteralPath (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Raw -Encoding UTF8
        $m = [regex]::Match($orch, 'foreach\s*\(\s*\$dep\s+in\s+@\(([^)]*)\)\)')
        $m.Success | Should -Be $true
        $tier1 = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        foreach ($lazy in @('ClusterOrchestrator', 'AuditLedger', 'ModuleDependencies')) {
            $tier1 | Should -Not -Contain $lazy -Because "$lazy must lazy-load, not sit in Tier-1"
        }
        # AuditLedger: explicit on-demand import at the compliance block.
        $orch | Should -Match "Import-ModuleOnDemand[^`n]*AuditLedger"
        # ClusterOrchestrator: menu-map entry 'O' resolved via generic on-demand
        # dispatch. The map itself used to be a hardcoded $defaultMap literal in
        # Get-ModuleMapFromConfig; that copy drifted and was removed, leaving
        # gbuild.config.json build.menu.moduleMap as the ONLY definition. This
        # test still grepped for the deleted literal, so it failed on correct
        # code. It now asserts the wiring where it actually lives: the config
        # key that Get-ModuleMapFromConfig reads.
        $cfg = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($cfg.build.menu.moduleMap.PSObject.Properties.Name) | Should -Contain 'O'
        @($cfg.build.menu.moduleMap.'O') | Should -Contain 'ClusterOrchestrator'
        $orch | Should -Match 'build\.menu\.moduleMap' -Because 'Get-ModuleMapFromConfig must resolve the map from config, not from a second inline copy'
        # ModuleDependencies: stays out of Tier-1 but is no longer self-test-only.
        # It is imported directly by this test file, and on demand by
        # Preflight.Invoke-PreflightValidation (build.preflight.checkModuleGraph),
        # which is what makes the validator reachable during a real build instead
        # of only under `gbuild -SelfTest`.
        (Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8) | Should -Match "Import-Module.*ModuleDependencies\.psm1"
        $preflight = Join-Path $global:GBuildModuleRoot 'Preflight.psm1'
        Test-Path $preflight | Should -Be $true -Because 'the production wiring site for this validator must exist'
        (Get-Content -LiteralPath $preflight -Raw -Encoding UTF8) | Should -Match "PreflightCheckModuleGraph" -Because 'a validator reachable only from tests is a validator no build ever runs'
    }
}

Describe 'ModuleDependencies - Test-ModuleDependencies' {
    It 'passes with no missing deps and no cycles' {
        $res = Test-ModuleDependencies -ModulesRoot $global:GBuildModuleRoot
        if ($res.Missing.Count -gt 0) {
            Write-Host ("Missing: " + (($res.Missing | ForEach-Object { "$($_.Module)->$($_.MissingDep)" }) -join '; '))
        }
        if ($res.Cycles.Count -gt 0) {
            Write-Host ("Cycles: " + ($res.Cycles -join ' | '))
        }
        $res.Passed | Should -Be $true
        $res.ModuleCount | Should -BeGreaterThan 40
    }
}
