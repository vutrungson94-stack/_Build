#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:td = New-IntegrationTempDir
$global:state = [PSCustomObject]@{
    ScriptRoot  = $global:td
    ProjectRoot = $global:td
    WorkingDir  = $global:td
    BuildConfig = [PSCustomObject]@{ }
    Colors      = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
    OS          = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
    LogLevel    = 3
}

Describe "Build module functions" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1')   -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll { if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -EA 0 } }

    It "Stop-ProcessByPort does not throw for an unsupported ProjectType (early-return before State use)" {
        # Source signature is -State -ProjectDir -ProjectType -ExeName -OutputDir (no -Port).
        # A ProjectType outside the supported set returns before touching $State.
        { Stop-ProcessByPort -State $global:state -ProjectType 'Library' } | Should -Not -Throw
    }

    It "Stop-ProcessByPort does not throw with a valid State and no supported ProjectType" {
        { Stop-ProcessByPort -State $global:state } | Should -Not -Throw
    }

    It "Stop-ProcessByPort does not throw with ProjectType Web on an empty dir" {
        { Stop-ProcessByPort -State $global:state -ProjectType 'Web' -ProjectDir $global:td } | Should -Not -Throw
    }

    It "Start-BuildAndShow returns false for a missing .csproj without throwing" {
        # Source uses -Project (string), not -ProjectPath/-CsprojPath.
        $r = Start-BuildAndShow -State $global:state -Project (Join-Path $global:td 'nope.csproj')
        $r | Should -Be $false
    }

    It "Invoke-GitHubBuild does not throw when gh is unavailable (no trigger)" {
        { Invoke-GitHubBuild -State $global:state -PackageFormat 'apk' } | Should -Not -Throw
    }

    It "Invoke-GitHubBuild does not throw with an empty PackageFormat" {
        { Invoke-GitHubBuild -State $global:state -PackageFormat '' } | Should -Not -Throw
    }

    It "Invoke-AutoDeploy does not throw without an APK (adb not found)" {
        { Invoke-AutoDeploy -State $global:state } | Should -Not -Throw
    }

    It "Get-ProjectTypeActions returns WinForms actions from shipped config" {
        $buildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $state = [PSCustomObject]@{
            ScriptRoot  = $buildRoot
            BuildConfig = (Get-Content (Join-Path $buildRoot 'gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        $actions = & (Get-Module Build) { Get-ProjectTypeActions -State $args[0] -ProjectType 'WinForms' } $state
        $actions | Should -Not -BeNullOrEmpty
        $actions.default | Should -Contain '--self-contained'
    }

    It "Get-ProjectTypeActions exposes one config-driven Console runtime action" {
        $buildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $state = [PSCustomObject]@{
            ScriptRoot  = $buildRoot
            BuildConfig = (Get-Content (Join-Path $buildRoot 'gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        $actions = & (Get-Module Build) { Get-ProjectTypeActions -State $args[0] -ProjectType 'Console' } $state
        @($actions.default | Where-Object { $_ -eq '-r' }).Count | Should -Be 1
        $actions.default | Should -Contain '${consoleSelfContained}'
        $actions.default | Should -Contain '${rid}'
    }
}

Describe 'Build dispatch and target contracts' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:targetState = [PSCustomObject]@{
            ProjectRoot = $( [System.IO.Path]::GetTempPath() )
            ScriptRoot = $( [System.IO.Path]::GetTempPath() )
            OS = 'Windows'
            LogLevel = 0
            BuildConfig = [PSCustomObject]@{}
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
        }
    }
    It 'detects a non-.NET project before applying the dotnet gate' {
        $dir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_node_gate_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'package.json'
        Set-Content -LiteralPath $file -Value '{"name":"gate"}'
        Mock Invoke-PluginBuildFor -ModuleName Build -MockWith { return [PSCustomObject]@{ Status = 'Succeeded'; ReasonCode = 'OK'; Message = 'mocked'; ExitCode = 0; Details = $null } }
        try {
            $state = $global:targetState.PSObject.Copy()
            $state.ProjectRoot = $dir
            $state | Add-Member -MemberType NoteProperty -Name DotnetCmd -Value '' -Force
            $r = Start-BuildAndShow -State $state -Project $file -Tfm '' -OutputSubDir default -Configuration Debug -Detailed
            $r.Status | Should -Be 'Succeeded'
            $r.ReasonCode | Should -Be 'OK'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns structured results for target 14 and X' {
        $p = Invoke-GuildParallelBuild -State $global:targetState -Projects @() -Tfm net8.0
        $x = Invoke-GuildDistributedBuild -State $global:targetState -Projects @()
        $p.Status | Should -Be 'Skipped'
        $p.ReasonCode | Should -Be 'NoProjects'
        $x.Status | Should -Be 'Skipped'
        $x.ReasonCode | Should -Be 'NoProjects'
    }
    It 'maps target 14 and X through the Build wrapper' {
        $config = Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'gbuild.config.json') -Raw | ConvertFrom-Json
        $config.build.menu.moduleMap.'14' | Should -Contain 'Build'
        $config.build.menu.moduleMap.X | Should -Contain 'Build'
    }
}

