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
    ScriptRoot  = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
    BuildConfig = [PSCustomObject]@{ }
    Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
    OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
    LogLevel = 3
}

Describe "Clean" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Clean.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Assert-SafePath allows target inside allowed root" {
        Assert-SafePath -Target (Join-Path $global:td 'sub') -AllowedRoots @($global:td) | Should -Be $true
    }

    It "Assert-SafePath rejects target outside allowed root" {
        Assert-SafePath -Target 'C:\Windows' -AllowedRoots @($global:td) | Should -Be $false
    }

    It "Assert-SafePath rejects empty target" {
        Assert-SafePath -Target '' -AllowedRoots @($global:td) | Should -Be $false
    }

    It "Remove-SafeItem deletes a file inside allowed root and returns true" {
        $file = Join-Path $global:td ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType File -Path $file -Force | Out-Null
        $result = Remove-SafeItem -Path $file -AllowedRoots @($global:td) -State $null
        $result | Should -Be $true
        Test-Path $file | Should -Be $false
    }

    It "Remove-SafeItem does not delete outside allowed root" {
        $outside = Join-Path $global:td 'outside_root.tmp'
        New-Item -ItemType File -Path $outside -Force | Out-Null
        $bad = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType File -Path $bad -Force | Out-Null
        $result = Remove-SafeItem -Path $bad -AllowedRoots @($global:td) -State $null
        $result | Should -Not -Be $true
        Test-Path $bad | Should -Be $true
        Remove-Item $bad -Force -ErrorAction SilentlyContinue
    }

    It "Remove-SafeFolder removes an empty subfolder and returns true" {
        $sub = Join-Path $global:td 'emptysub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $result = Remove-SafeFolder -FolderPath $sub -AllowedRoots @($global:td) -State $null
        $result | Should -Be $true
        Test-Path $sub | Should -Be $false
    }

    It "Invoke-SmartClean cleans bin under project dir without throwing" {
        $bin = Join-Path $global:td 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        { Invoke-SmartClean -State $global:state -ProjectDir $global:td } | Should -Not -Throw
        Test-Path $bin | Should -Be $false
    }

    It "Add-CleanTarget adds existing folder and skips outside root" {
        $obj = Join-Path $global:td 'obj'
        New-Item -ItemType Directory -Path $obj -Force | Out-Null
        $targets = [System.Collections.Generic.List[string]]::new()
        Add-CleanTarget -Path $obj -AllowedRoots @($global:td) -Targets $targets
        $targets.Count | Should -Be 1

        $outsideTarget = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $outsideTarget -Force | Out-Null
        $targets2 = [System.Collections.Generic.List[string]]::new()
        Add-CleanTarget -Path $outsideTarget -AllowedRoots @($global:td) -Targets $targets2
        $targets2.Count | Should -Be 0
        Remove-Item $outsideTarget -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Invoke-SmartClean throws on a traversing paths.publishOutput instead of widening the delete allowlist" {
        $st = [PSCustomObject]@{
            ScriptRoot = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
            BuildConfig = [PSCustomObject]@{ paths = [PSCustomObject]@{ publishOutput = '../../escape' } }
        }
        { Invoke-SmartClean -State $st -ProjectDir $global:td -CsprojPath '' } | Should -Throw
    }
}
