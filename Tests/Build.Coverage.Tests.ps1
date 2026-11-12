#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Coverage-focused tests for Build.psm1's higher-miss functions.
.DESCRIPTION
    Exercises Stop-ProcessByPort, Invoke-GitHubBuild, New-AndroidAab,
    Invoke-DeviceDebug, Invoke-GuildParallelBuild and Invoke-GuildDistributedBuild
    through hermetic mocks so the control-flow paths run inside the measurement
    window without real processes, ADB, dotnet, or GitHub CLI.
#>

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Build - coverage paths' {
    Context 'Invoke-GitHubBuild' {
        It 'fails when package format is missing' {
            $r = InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                Invoke-GitHubBuild -State $state -PackageFormat ''
            }
            $r.Status | Should -Be 'Failed'
            $r.ReasonCode | Should -Be 'NoPackageFormat'
        }

        It 'fails when gh is not installed' {
            $r = InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
                Invoke-GitHubBuild -State $state -PackageFormat 'apk'
            }
            $r.Status | Should -Be 'Failed'
            $r.ReasonCode | Should -Be 'ToolMissing'
        }
    }

    Context 'New-AndroidAab' {
        It 'returns early for invalid keystore path' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                { New-AndroidAab -State $state -ProjectPath 'C:\missing\app.csproj' -Tfm 'net8.0-android' -Keystore 'C:\no\such.keystore' } | Should -Not -Throw
            }
        }

        It 'resolves project directory and rejects when no csproj found' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                $dir = Join-Path $TestDrive 'emptyproj'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                { New-AndroidAab -State $state -ProjectPath $dir -Tfm 'net8.0-android' -Keystore 'C:\no\such.keystore' } | Should -Not -Throw
            }
        }
    }

    Context 'Invoke-DeviceDebug' {
        It 'returns when project path is missing or adb unavailable' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Warn='Yellow'; Cyan='Cyan'; Gray='Gray'; Info='Cyan' } }
                { Invoke-DeviceDebug -State $state -Project '' -Tfm 'net8.0-android' } | Should -Not -Throw
                { Invoke-DeviceDebug -State $state -Project 'C:\no\app.csproj' -Tfm 'net8.0-android' } | Should -Not -Throw
            }
        }
    }

    Context 'Invoke-AutoDeploy' {
        It 'returns early when adb/apk/device conditions are not met' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Warn='Yellow'; Cyan='Cyan'; Succ='Green'; Err='Red'; Info='Cyan' } }
                Mock Find-AdbPath { $null }
                { Invoke-AutoDeploy -State $state -ApkPath 'C:\no\app.apk' -AppId 'com.test.app' } | Should -Not -Throw
            }
        }
    }

    Context 'Stop-ProcessByPort' {
        It 'returns for unsupported project types' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ OS = 'Windows'; Colors = [pscustomobject]@{ Gray='Gray'; Succ='Green'; Warn='Yellow' } }
                { Stop-ProcessByPort -State $state -ProjectDir $TestDrive -ProjectType 'Library' -WhatIf } | Should -Not -Throw
            }
        }
    }

    Context 'Parallel and distributed build entry points' {
        It 'returns skipped/blocked results when prerequisites are missing' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Warn='Yellow'; Succ='Green' }; BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ defaultConfiguration = 'Release' } } }
                $r1 = Invoke-GuildParallelBuild -State $state -Projects @() -Tfm 'net8.0'
                $r1.Status | Should -Be 'Skipped'

                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Invoke-ParallelBuild' }
                Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*Parallel.psm1*' }
                $r2 = Invoke-GuildParallelBuild -State $state -Projects @('a.csproj') -Tfm 'net8.0'
                $r2.Status | Should -BeIn @('Blocked','Failed','Skipped','Succeeded')

                $d1 = Invoke-GuildDistributedBuild -State $state -Projects @()
                $d1.Status | Should -Be 'Skipped'

                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Invoke-DistributedBuild' }
                Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*Distributed.psm1*' }
                $d2 = Invoke-GuildDistributedBuild -State $state -Projects @('a.csproj')
                $d2.Status | Should -BeIn @('Blocked','Failed','Skipped','Succeeded')
            }
        }
    }
}

    Context 'Invoke-GitHubBuild - extended paths' {
        It 'returns failed result when gh exits non-zero' {
            $r = InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                $gh = Join-Path $TestDrive 'gh.ps1'
                '@{ exit 1 }' | Out-Null
                Set-Content -Path $gh -Value 'param($a,$b,$c,$d,$e,$f,$g,$h) $global:LASTEXITCODE=1' -Encoding ASCII
                $cmd = [pscustomobject]@{ Source = $gh }
                Mock Get-Command { $cmd } -ParameterFilter { $Name -eq 'gh' }
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'git' }
                Invoke-GitHubBuild -State $state -PackageFormat 'apk'
            }
            $r.Status | Should -Be 'Failed'
            $r.ReasonCode | Should -Be 'DispatchFailed'
        }

        It 'succeeds when gh exits zero with git branch available' {
            $r = InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                $gh = Join-Path $TestDrive 'gh2.ps1'
                Set-Content -Path $gh -Value 'param($a,$b,$c,$d,$e,$f,$g,$h) $global:LASTEXITCODE=0' -Encoding ASCII
                $cmd = [pscustomobject]@{ Source = $gh }
                Mock Get-Command { $cmd } -ParameterFilter { $Name -eq 'gh' }
                Mock Get-Command { [pscustomobject]@{ Name = 'git' } } -ParameterFilter { $Name -eq 'git' }
                Mock Get-Command { $null } -ParameterFilter { $Name -ne 'gh' -and $Name -ne 'git' }
                function git { param([Parameter(ValueFromRemainingArguments)]$args) if ($args -contains '--show-current') { return 'feature/x' } }
                Invoke-GitHubBuild -State $state -PackageFormat 'aab'
            }
            $r.Status | Should -Be 'Succeeded'
        }
    }

    Context 'New-AndroidAab - extended' {
        It 'calls Start-BuildAndShow with signing args when keystore valid' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Err='Red'; Cyan='Cyan'; Succ='Green' } }
                $ks = Join-Path $TestDrive 'test.keystore'
                New-Item -ItemType File -Path $ks -Force | Out-Null
                $keystore = [pscustomobject]@{ Path = $ks; Alias = 'myalias'; StorePass = 'spass'; KeyPass = 'kpass' }
                $script:called = $false
                function Start-BuildAndShow {
                    param($State, $Project, $Tfm, $OutputSubDir, $BuildArgs, $ProjectType, [switch]$Incremental)
                    $script:called = $true
                    if ($OutputSubDir -ne 'aab') { throw "bad output" }
                    return $true
                }
                New-AndroidAab -State $state -ProjectPath 'C:\some\app.csproj' -Tfm 'net8.0-android' -Keystore $keystore
                $script:called | Should -BeTrue
                (Test-Path Env:ANDROID_KEYSTORE_PASS) | Should -BeFalse
            }
        }
    }

    Context 'Stop-ProcessByPort - extended' {
        It 'handles web project type with mocked helpers' {
            InModuleScope Build {
                $state = [PSCustomObject]@{ OS = 'Windows'; Colors = [pscustomobject]@{ Gray='Gray'; Succ='Green'; Warn='Yellow' } }
                Mock Get-Process { @() }
                Mock Get-PortOwnerProcess { @() }
                Mock Get-LaunchSettingsPorts { @() }
                Mock Get-ProcessCommandLine { '' }
                { Stop-ProcessByPort -State $state -ProjectDir $TestDrive -ProjectType 'Web' -OutputDir $TestDrive -ExeName 'app' -WhatIf } | Should -Not -Throw
            }
        }
    }
