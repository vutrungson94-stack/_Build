#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$global:GBuildTestRoot   = Split-Path -Parent $PSCommandPath
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Versioning" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Versioning.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:td = New-IntegrationTempDir
        $global:state = [PSCustomObject]@{
            ScriptRoot  = Join-Path $global:td 'app'
            ProjectRoot = $global:td
            WorkingDir  = $global:td
            BuildConfig = [PSCustomObject]@{ }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3
        }
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-CurrentVersion reads 1.2.3 from version.json" {
        Set-Content -Path (Join-Path $global:td 'version.json') -Value '{ "version": "1.2.3" }'
        $v = Get-CurrentVersion -State $global:state
        $v.Version | Should -Be '1.2.3'
        $v.Source  | Should -Be 'version.json'
    }

    It "Invoke-VersionBump patch bumps 1.2.3 to 1.2.4" {
        Set-Content -Path (Join-Path $global:td 'version.json') -Value '{ "version": "1.2.3" }'
        $out = Invoke-VersionBump -State $global:state -BumpType 'patch'
        $out | Should -Match '1\.2\.4'
        $data = Get-Content -Path (Join-Path $global:td 'version.json') -Raw | ConvertFrom-Json
        $data.version | Should -Be '1.2.4'
    }

    It "Invoke-VersionBump minor bumps 0.1.0 to 0.2.0" {
        Set-Content -Path (Join-Path $global:td 'version.json') -Value '{ "version": "0.1.0" }'
        $out = Invoke-VersionBump -State $global:state -BumpType 'minor'
        $out | Should -Match '0\.2\.0'
        $data = Get-Content -Path (Join-Path $global:td 'version.json') -Raw | ConvertFrom-Json
        $data.version | Should -Be '0.2.0'
    }

    It "Invoke-VersionBump major bumps 0.1.0 to 1.0.0" {
        Set-Content -Path (Join-Path $global:td 'version.json') -Value '{ "version": "0.1.0" }'
        $out = Invoke-VersionBump -State $global:state -BumpType 'major'
        $out | Should -Match '1\.0\.0'
        $data = Get-Content -Path (Join-Path $global:td 'version.json') -Raw | ConvertFrom-Json
        $data.version | Should -Be '1.0.0'
    }

    It "Get-BuildMetadata returns expected keys" {
        $meta = Get-BuildMetadata -State $global:state
        $meta | Should -BeOfType [hashtable]
        $meta.ContainsKey('BuildTime') | Should -Be $true
        $meta.ContainsKey('OS') | Should -Be $true
        $meta.ContainsKey('Hostname') | Should -Be $true
        $meta.ContainsKey('User') | Should -Be $true
        $meta.ContainsKey('Profile') | Should -Be $true
    }

    It "Resolve-VersionFilePath prefers the rooted ProjectRoot and never returns a bare filename" {
        $p = Resolve-VersionFilePath -State $global:state
        [System.IO.Path]::IsPathRooted([string]$p) | Should -BeTrue
        $p | Should -Be (Join-Path $global:td 'version.json')
    }

    It "Resolve-VersionFilePath throws instead of resolving against the CWD" {
        { Resolve-VersionFilePath -State ([PSCustomObject]@{}) } | Should -Throw
        { Resolve-VersionFilePath -State ([PSCustomObject]@{ ScriptRoot = '.' }) } | Should -Throw
        { Resolve-VersionFilePath -State $null } | Should -Throw
    }

    It "Resolve-VersionSearchRoot throws instead of returning the CWD" {
        Resolve-VersionSearchRoot -State $global:state | Should -Be $global:td
        { Resolve-VersionSearchRoot -State ([PSCustomObject]@{}) } | Should -Throw
        { Resolve-VersionSearchRoot -State ([PSCustomObject]@{ WorkingDir = '.' }) } | Should -Throw
    }

    It "New-Changelog throws instead of writing into the CWD" {
        $origLoc = $PWD.Path
        $cwd = New-IntegrationTempDir
        try {
            Set-Location -LiteralPath $cwd
            { New-Changelog -State ([PSCustomObject]@{}) } | Should -Throw
            @(Get-ChildItem -LiteralPath $cwd -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
