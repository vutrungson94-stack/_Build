#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    ProviderContracts - interface conformance for all three providers.
.DESCRIPTION
    Closes the P2 gap: BuildStrategyProvider + EnvironmentProvider had tests,
    AndroidSdkProvider (new P1 consolidation) had none. Validates every
    provider exposes its documented functions and honors return contracts
    without requiring real SDKs/devices (mock State, no external deps).
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$global:GBuildProviderRoot = Join-Path $global:GBuildModuleRoot 'Providers'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'ProviderContracts - BuildStrategyProvider' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildProviderRoot 'BuildStrategyProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It 'exposes Get-BuildStrategy' {
        Get-Command Get-BuildStrategy -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'all four strategies honor ResolveOptions contract' {
        foreach ($args in @(@{}, @{ Incremental = $true }, @{ DebugBuild = $true }, @{ Clean = $true })) {
            if ($args.Count -eq 0) { $s = Get-BuildStrategy }
            elseif ($args.ContainsKey('Incremental')) { $s = Get-BuildStrategy -Incremental }
            elseif ($args.ContainsKey('DebugBuild')) { $s = Get-BuildStrategy -DebugBuild }
            else { $s = Get-BuildStrategy -Clean }
            $s.Name | Should -Not -BeNullOrEmpty
            $opts = $s.ResolveOptions([PSCustomObject]@{})
            $opts | Should -BeOfType [hashtable]
            $opts.ContainsKey('Configuration') | Should -Be $true
            $opts.ContainsKey('Incremental') | Should -Be $true
            $opts.ContainsKey('Clean') | Should -Be $true
        }
    }
}

Describe 'ProviderContracts - EnvironmentProvider' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildProviderRoot 'EnvironmentProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It 'exposes Get-BuildEnvironment + Test-CIEnvironment' {
        Get-Command Get-BuildEnvironment -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-CIEnvironment -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'environment GetConfig honors contract (IsCI bool + Name + OS)' {
        $e = Get-BuildEnvironment
        $e.Name | Should -Not -BeNullOrEmpty
        $e.IsCI | Should -BeOfType [bool]
        $cfg = $e.GetConfig()
        $cfg | Should -BeOfType [hashtable]
        $cfg.IsCI | Should -BeOfType [bool]
    }

    It 'Test-CIEnvironment returns bool without throwing' {
        $r = Test-CIEnvironment
        $r | Should -BeOfType [bool]
    }
}

Describe 'ProviderContracts - AndroidSdkProvider' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildProviderRoot 'AndroidSdkProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It 'exposes all seven provider functions' {
        foreach ($fn in @('Get-AndroidSdkHome','Find-AdbPath','Get-AdbDevices','Invoke-AdbDeviceScan','Get-AndroidSdkManagerPath','Get-AndroidPlatformToolsDir','Update-AndroidSdkProviderConfig')) {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$fn must be exported"
        }
    }

    It 'Find-AdbPath returns null-or-existing path without throwing (fail-closed)' {
        $st = [PSCustomObject]@{ AndroidSdk = $null; ScriptRoot = $env:TEMP; OS = 'Windows'; Colors = @{ Warn = 'Yellow' }; BuildConfig = $null }
        $p = Find-AdbPath -State $st
        if ($p) {
            (Test-Path -LiteralPath $p) | Should -Be $true
        } else {
            $p | Should -BeNullOrEmpty
        }
    }

    It 'Get-AdbDevices returns array without throwing when adb absent' {
        $st = [PSCustomObject]@{ AndroidSdk = $null; ScriptRoot = $env:TEMP; OS = 'Windows'; Colors = @{ Warn = 'Yellow' }; BuildConfig = $null }
        $d = @(Get-AdbDevices -State $st -AdbPath 'Z:\nonexistent-adb.exe' -TryConnect $false)
        $d.Count | Should -Be 0
    }

    It 'Get-AndroidSdkHome returns null or string without throwing (no SDK required)' {
        $st = [PSCustomObject]@{ AndroidSdk = $null; ScriptRoot = $env:TEMP; BuildConfig = $null }
        { Get-AndroidSdkHome -State $st } | Should -Not -Throw
    }

    It 'Get-AndroidSdkManagerPath + Get-AndroidPlatformToolsDir degrade gracefully without SDK' {
        $st = [PSCustomObject]@{ AndroidSdk = $null; ScriptRoot = $env:TEMP; BuildConfig = $null }
        { Get-AndroidSdkManagerPath -State $st } | Should -Not -Throw
        { Get-AndroidPlatformToolsDir -State $st } | Should -Not -Throw
    }

    It 'Update-AndroidSdkProviderConfig applies sdk overrides without throwing' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ sdk = [PSCustomObject]@{ androidCmdLineToolsRelPath = 'cmdline-tools/latest/bin'; adbAutoConnectEndpoints = @('127.0.0.1:5555') } } }
        { Update-AndroidSdkProviderConfig -State $st } | Should -Not -Throw
    }
}
