#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

# ── Describe: Logging ──────────────────────────────────────────────────
Describe "Logging" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Write-Log exists and does not throw" {
        $s = [PSCustomObject]@{ LogLevel = 3 }
        { Write-Log 'Test msg' 'Gray' $s } | Should -Not -Throw
    }

    It "Set-LogLevel accepts valid levels" {
        { Set-LogLevel -Level 'Debug' } | Should -Not -Throw
    }

    It "Resolve-ConsoleColor returns valid ConsoleColor" {
        $s = [PSCustomObject]@{ Colors = @{ Info = 'Cyan' } }
        $c = Resolve-ConsoleColor -State $s -Name 'Info'
        $c | Should -Not -BeNullOrEmpty
    }

    It "Show-ProgressBar renders without throw" {
        { Show-ProgressBar -Current 3 -Total 10 -Label 'Testing' } | Should -Not -Throw
    }
}

# ── Describe: HealthCheck ──────────────────────────────────────────────
Describe "HealthCheck" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'HealthCheck.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "New-HealthResult creates Pass result" {
        $r = New-HealthResult -Name 'Test' -Status 'Pass' -Message 'OK'
        $r.Name | Should -Be 'Test'
        $r.Status | Should -Be 'Pass'
    }

    It "New-HealthResult creates Fail result" {
        $r = New-HealthResult -Name 'Bad' -Status 'Fail' -Message 'FAIL'
        $r.Status | Should -Be 'Fail'
    }

    It "Test-DiskSpace returns result for system drive" {
        $r = Test-DiskSpace -MinMB 1
        $r | Should -Not -BeNullOrEmpty
        $r.Status | Should -BeIn 'Pass', 'Warn', 'Fail'
    }
}

# ── Describe: Loader ───────────────────────────────────────────────────
Describe "Loader" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Get-RegisteredPlugins returns null when no plugins registered" {
        $p = Get-RegisteredPlugins
        $p | Should -Be $null
    }

    It "Resolve-PluginForLanguage returns null for unknown language" {
        $r = Resolve-PluginForLanguage -Language 'Klingon'
        $r | Should -Be $null
    }
}
