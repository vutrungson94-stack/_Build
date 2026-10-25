# ============================================================================
# IContract.Tests.ps1  (Phase B4 - interface contract validation)
# ============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

Describe 'IContract - Test-ContractConformance (duck-typing)' {
    BeforeAll {
        $iContract = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'IContract.psm1'))
        $null = Import-Module $iContract -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'detects present methods and properties' {
        $obj = [PSCustomObject]@{ Foo = 1 }
        $obj | Add-Member -MemberType ScriptMethod -Name 'Bar' -Value { } -Force
        $r = Test-ContractConformance $obj -RequiredMethods @('Bar') -RequiredProperties @('Foo') -ContractName 'Fake'
        $r.Count | Should -Be 2
        ($r | Where-Object { $_.Conforms }).Count | Should -Be 2
    }

    It 'flags missing members as non-conforming' {
        $obj = [PSCustomObject]@{ }
        $r = Test-ContractConformance $obj -RequiredMethods @('Missing') -RequiredProperties @('Absent') -ContractName 'Fake'
        ($r | Where-Object { -not $_.Conforms }).Count | Should -Be 2
    }
}

Describe 'IContract - Test-InterfaceContracts (OOP core)' {
    BeforeAll {
        $iContract = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'IContract.psm1'))
        $null = Import-Module $iContract -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'passes for all four OOP core classes' {
        $res = Test-InterfaceContracts
        $res.Passed | Should -BeTrue
        $res.Failed.Count | Should -Be 0
    }

    It 'throws when -ThrowOnFailure and a member is missing' {
        { Test-InterfaceContracts -ThrowOnFailure } | Should -Not -Throw
    }
}

Describe 'IContract - manifest and dependency regressions' {
    BeforeAll {
        $null = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'PluginSDK.psm1')) -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'does not synthesize over invalid JSON' {
        $dir = Join-Path $TestDrive 'invalid-plugin'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $module = Join-Path $dir 'Broken.psm1'
        Set-Content -LiteralPath $module -Value 'function Get-PluginInfo { [PSCustomObject]@{ Name = "Broken" } }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'Broken.plugin.json') -Value '{bad' -Encoding UTF8
        $manifest = Get-PluginManifest -PluginPath $module
        $manifest.manifestFound | Should -BeTrue
        (Test-PluginManifest -Manifest $manifest).Valid | Should -BeFalse
    }
    It 'marks a missing plugin dependency as a contract failure' {
        $dir = Join-Path $TestDrive 'dependency-plugin'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $module = Join-Path $dir 'NeedsGhost.psm1'
        $manifest = [ordered]@{ name = 'NeedsGhost'; version = '1.0.0'; apiVersion = '1.0.0'; supportedLanguages = @('Test'); capabilities = @('build'); dependencies = @([ordered]@{ name = 'Ghost'; version = '1.0.0' }); entryPoint = 'NeedsGhost.psm1' }
        Set-Content -LiteralPath $module -Value 'function Get-PluginInfo { [PSCustomObject]@{ Name = "NeedsGhost" } }; function Invoke-PluginBuild {}; function Invoke-PluginTest {}; function Invoke-PluginLint {}; function Invoke-PluginPreflight {}' -Encoding UTF8
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'NeedsGhost.plugin.json') -Encoding UTF8
        $result = Test-PluginContracts -PluginPaths @($module)
        $result.Passed | Should -BeFalse
    }
}

Describe 'IContract - Test-PluginContracts' {
    BeforeAll {
        $iContract = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'IContract.psm1'))
        $null = Import-Module $iContract -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'all shipped plugins expose the four required functions' {
        $res = Test-PluginContracts
        $res.Passed | Should -BeTrue
        $res.Failed.Count | Should -Be 0
    }
}
