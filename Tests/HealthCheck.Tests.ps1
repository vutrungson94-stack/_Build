#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$global:GBuildTestRoot   = Split-Path -Parent $PSCommandPath
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "HealthCheck" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'HealthCheck.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:td = New-IntegrationTempDir
        $global:state = [PSCustomObject]@{
            ScriptRoot  = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
            BuildConfig = [PSCustomObject]@{ }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3
        }
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "New-HealthResult builds a Pass result" {
        $r = New-HealthResult -Name 'X' -Status 'Pass' -Message 'ok'
        $r.Name | Should -Be 'X'
        $r.Status | Should -Be 'Pass'
        $r.Timestamp | Should -Not -BeNullOrEmpty
    }

    It "New-HealthResult builds a Fail result" {
        $r = New-HealthResult -Name 'Y' -Status 'Fail'
        $r.Status | Should -Be 'Fail'
    }

    It "Get-HealthStatusIcon maps statuses" {
        InModuleScope HealthCheck {
            Get-HealthStatusIcon -Status 'Pass' | Should -Be '[OK]'
            Get-HealthStatusIcon -Status 'Warn' | Should -Be '[!!]'
            Get-HealthStatusIcon -Status 'Fail' | Should -Be '[X]'
        }
    }

    It "Get-HealthStatusColor maps statuses" {
        InModuleScope HealthCheck {
            Get-HealthStatusColor -Status 'Pass' | Should -Be 'Succ'
            Get-HealthStatusColor -Status 'Fail' | Should -Be 'Err'
        }
    }

    It "Test-DiskSpace returns a result with Status and Message" {
        $r = Test-DiskSpace -State $global:state
        $r | Should -Not -BeNullOrEmpty
        $r.Status | Should -BeIn 'Pass', 'Warn', 'Fail'
        $r.Message | Should -Not -BeNullOrEmpty
    }

    It "Test-RequiredTools returns a result named Required Tools" {
        $r = Test-RequiredTools -State $global:state
        $r | Should -Not -BeNullOrEmpty
        $r.Name | Should -Be 'Required Tools'
        $r.Status | Should -BeIn 'Pass', 'Warn', 'Fail'
    }

    It "Test-RequiredTools honors ChaosMissingTool (chaos drill)" {
        $chaosState = [PSCustomObject]@{
            ScriptRoot = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
            BuildConfig = [PSCustomObject]@{ health = [PSCustomObject]@{ requiredTools = @('dotnet'); optionalTools = @() } }
            ChaosMissingTool = 'dotnet'
            Colors = $global:state.Colors
            OS = $global:state.OS
            LogLevel = 3
        }
        $r = Test-RequiredTools -State $chaosState
        $r.Status | Should -Be 'Fail'
        $r.Message | Should -Match 'dotnet'
    }

    It "resolves required tools from the live state config" {
        $state = [PSCustomObject]@{
            ScriptRoot = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
            BuildConfig = [PSCustomObject]@{ health = [PSCustomObject]@{ requiredTools = @('pwsh'); optionalTools = @() } }
            Colors = $global:state.Colors
            OS = $global:state.OS
            LogLevel = 3
        }
        (Test-RequiredTools -State $state).Status | Should -Be 'Pass'
        $state.BuildConfig.health.requiredTools = @('gbuild_missing_health_tool')
        (Test-RequiredTools -State $state).Status | Should -Be 'Fail'
    }

    It "Test-DiskSpace honors ChaosDiskSpaceMB (chaos drill)" {
        $chaosState = [PSCustomObject]@{
            ScriptRoot = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
            BuildConfig = [PSCustomObject]@{ }
            ChaosDiskSpaceMB = 2049
            Colors = $global:state.Colors
            OS = $global:state.OS
            LogLevel = 3
        }
        $r = Test-DiskSpace -State $chaosState -MinMB 2048
        $r.Status | Should -Be 'Fail'
    }

    It "Test-PortAvailability returns a result with Status and Message" {
        $r = Test-PortAvailability -State $global:state -Ports @(1,2,3)
        $r | Should -Not -BeNullOrEmpty
        $r.Status | Should -BeIn 'Pass', 'Warn', 'Fail'
        $r.Message | Should -Not -BeNullOrEmpty
    }

    It "Invoke-HealthCheck returns an array of results" {
        $results = Invoke-HealthCheck -State $global:state
        @($results).Count | Should -BeGreaterThan 0
    }

    It "Show-HealthReport returns a bool and does not throw" {
        $results = Invoke-HealthCheck -State $global:state
        { Show-HealthReport -State $global:state -Results $results } | Should -Not -Throw
        $ok = Show-HealthReport -State $global:state -Results $results
        $ok | Should -BeOfType [bool]
    }
}

Describe 'HealthCheck safety' {
    It 'does not delete temporary directories outside the build roots' {
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_outside_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        try {
            $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; WorkingDir = $TestDrive; BuildConfig = [PSCustomObject]@{ health = [PSCustomObject]@{ autoFixKillPorts = $false } } }
            $result = New-HealthResult -Name 'Disk Space' -Status 'Fail' -Message 'disk full'
            [void](Invoke-AutoFix -State $state -Results @($result))
            Test-Path -LiteralPath $outside | Should -BeTrue
        } finally { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'uses the configured WorkingDir for git status' {
        $repo = Join-Path $TestDrive 'git-working-dir'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git '-C' $repo init '--quiet' 2>$null
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; WorkingDir = $repo; BuildConfig = [PSCustomObject]@{} }
        $result = Test-GitStatus -State $state
        $result.Name | Should -Be 'Git'
        $result.Message | Should -Not -Match 'WorkingDir is not available'
    }
}
