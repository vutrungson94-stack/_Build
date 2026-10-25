#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Remediation coverage: Get-ConfigValue + Resolve-NativePath.
.DESCRIPTION
    P1 remediation added a unified config accessor and moved Resolve-NativePath
    single-sourced into PathUtils. The unified accessor initially shipped as a
    second function (Get-ConfigValueSafe) with zero production callers, so it
    was folded back into Get-ConfigValue - which already carried -Type and
    -ResolveEnv - and this file covers the surviving single path plus
    Resolve-NativePath.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe 'Get-ConfigValue - unified accessor' {
    It 'is exported from ConfigProvider' {
        Get-Command Get-ConfigValue -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'resolves nested value from State.BuildConfig' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ maxParallelJobs = 6 } } }
        Get-ConfigValue -State $st -Path 'build.maxParallelJobs' | Should -Be 6
    }

    It 'returns Default when path missing everywhere' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        Get-ConfigValue -State $st -Path 'build.doesNotExist' -Default 'fallback' | Should -Be 'fallback'
    }

    It 'coerces Type int/bool/string' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ a = [PSCustomObject]@{ n = '7'; b = 1; s = 42 } } }
        Get-ConfigValue -State $st -Path 'a.n' -Type int | Should -BeOfType [int]
        Get-ConfigValue -State $st -Path 'a.b' -Type bool | Should -BeOfType [bool]
        Get-ConfigValue -State $st -Path 'a.s' -Type string | Should -BeOfType [string]
    }
}

Describe 'Resolve-NativePath - single-sourced in PathUtils' {
    It 'is exported from PathUtils' {
        Get-Command Resolve-NativePath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'returns null for empty input' {
        Resolve-NativePath -Path '' | Should -BeNullOrEmpty
        Resolve-NativePath -Path '   ' | Should -BeNullOrEmpty
    }

    It 'resolves current directory to absolute native path' {
        $cwd = (Get-Location).ProviderPath
        $r = Resolve-NativePath -Path $cwd
        $r | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($r) | Should -Be $true
    }

    It 'normalizes forward slashes on Windows without throwing' {
        { Resolve-NativePath -Path 'C:/Users/Test' } | Should -Not -Throw
    }
}
