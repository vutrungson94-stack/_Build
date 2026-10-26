#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

# ── Describe: Build ────────────────────────────────────────────────────
Describe "Build" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Start-BuildAndShow returns false for nonexistent project" {
        $mockState = [PSCustomObject]@{ LogLevel = 0 }
        $r = Start-BuildAndShow -State $mockState -Project 'Z:\nonexistent.csproj'
        $r | Should -Be $false
    }

    It "Stop-ProcessByPort does not throw with minimal params" {
        $s = [PSCustomObject]@{ LogLevel = 0; OS = 'Windows'; Colors = @{ Gray = 'Gray' } }
        { Stop-ProcessByPort -State $s -ProjectDir $( [System.IO.Path]::GetTempPath() ) } | Should -Not -Throw
    }
}

# ── Describe: Menu ─────────────────────────────────────────────────────
Describe "Menu" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Menu.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "New-GuildMenuConfig returns non-empty hashtable" {
        $cfg = New-GuildMenuConfig -ProjectType 'MAUI' -AndroidTfm 'net10.0-android' -WinTfm 'net10.0-windows10.0.19041.0' -OS 'Windows' -ParallelProjects @()
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.Count | Should -BeGreaterThan 0
    }

    It "Menu includes exit and build choices" {
        $cfg = New-GuildMenuConfig -ProjectType 'MAUI' -AndroidTfm 'net10.0-android' -WinTfm 'net10.0-windows10.0.19041.0' -OS 'Windows' -ParallelProjects @()
        $cfg.ContainsKey('0') | Should -Be $true
        $cfg.ContainsKey('1') | Should -Be $true
    }

    It "Non-.NET project shows only 12 as supported build choice" {
        $cfg = New-GuildMenuConfig -ProjectType 'Node.js' -OS 'Windows' -ParallelProjects @()
        $cfg['12'].Supported | Should -Be $true
        $cfg['1'].Supported | Should -Be $false
        $cfg['2'].Supported | Should -Be $false
        $cfg['10'].Supported | Should -Be $false
        $cfg['11'].Supported | Should -Be $false
    }

    It "Non-.NET project shows 0 (Exit) and D (Doctor) as supported" {
        $cfg = New-GuildMenuConfig -ProjectType 'Python' -OS 'Linux' -ParallelProjects @()
        $cfg['0'].Supported | Should -Be $true
        $cfg['D'].Supported | Should -Be $true
        $cfg['S'].Supported | Should -Be $true
    }

}

# ── Describe: Orchestrator ─────────────────────────────────────────────
Describe "Orchestrator" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Get-ActiveProfile returns null when no BuildConfig" {
        $mockState = [PSCustomObject]@{ ActiveProfile = 'Release'; BuildConfig = $null }
        $p = Get-ActiveProfile -State $mockState -ProfileName 'Release'
        $p | Should -Be $null
    }

    It "Test-BuildConfig returns false for null BuildConfig" {
        $mockState = [PSCustomObject]@{ BuildConfig = $null }
        $v = Test-BuildConfig -State $mockState
        $v | Should -Be $false
    }
}

# ── Describe: Build Providers (Phase 7) ──────────────────────────────
Describe "Build Providers" {
    BeforeAll {
        $global:GBuildProviderRoot = Join-Path $global:GBuildModuleRoot 'Providers'
        $null = Import-Module (Join-Path $global:GBuildProviderRoot 'BuildStrategyProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildProviderRoot 'EnvironmentProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It "Get-BuildStrategy returns Release by default" {
        $s = Get-BuildStrategy
        $s.Name | Should -Be 'Release'
        $s.Incremental | Should -Be $false
    }

    It "Get-BuildStrategy -Incremental returns Incremental strategy" {
        $s = Get-BuildStrategy -Incremental
        $s.Name | Should -Be 'Incremental'
        $s.Incremental | Should -Be $true
    }

    It "Get-BuildStrategy -DebugBuild returns Debug strategy" {
        $s = Get-BuildStrategy -DebugBuild
        $s.Name | Should -Be 'Debug'
    }

    It "Get-BuildStrategy -Clean returns Full strategy" {
        $s = Get-BuildStrategy -Clean
        $s.Name | Should -Be 'Full'
    }

    It "Build strategy ResolveOptions returns a hashtable" {
        $s = Get-BuildStrategy -Incremental
        $opts = $s.ResolveOptions([PSCustomObject]@{ CurrentTfm = 'net10.0' })
        $opts | Should -BeOfType [hashtable]
        $opts.Configuration | Should -Be 'Release'
        $opts.Incremental | Should -Be $true
    }

    It "Get-BuildEnvironment returns an environment provider" {
        $e = Get-BuildEnvironment
        $e.Name | Should -Not -BeNullOrEmpty
        $e.IsCI | Should -BeOfType [bool]
        $e.OS | Should -Not -BeNullOrEmpty
    }

    It "Get-BuildEnvironment returns canonical OS (Windows/Linux/MacOS), never raw .NET tokens" {
        $e = Get-BuildEnvironment
        $e.OS | Should -BeIn @('Windows', 'Linux', 'MacOS')
    }

    It "Resolve-CanonicalOS maps raw tokens to canonical form" {
        Resolve-CanonicalOS -RawOS 'Win32NT' | Should -Be 'Windows'
        Resolve-CanonicalOS -RawOS 'Windows' | Should -Be 'Windows'
        Resolve-CanonicalOS -RawOS 'Linux' | Should -Be 'Linux'
        Resolve-CanonicalOS -RawOS 'macOS' | Should -Be 'MacOS'
        Resolve-CanonicalOS -RawOS 'MacOS' | Should -Be 'MacOS'
    }

    It "Resolve-CanonicalOS falls back to the detector for Unix/empty input" {
        $u = Resolve-CanonicalOS -RawOS 'Unix'
        $u | Should -BeIn @('Windows', 'Linux', 'MacOS')
        $n = Resolve-CanonicalOS -RawOS ''
        $n | Should -BeIn @('Windows', 'Linux', 'MacOS', 'Unknown')
    }

    It "Get-BuildEnvironment.GetConfig returns a hashtable" {
        $e = Get-BuildEnvironment
        $cfg = $e.GetConfig()
        $cfg | Should -BeOfType [hashtable]
        $cfg.IsCI | Should -BeOfType [bool]
    }
}
