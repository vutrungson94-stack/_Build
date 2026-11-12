#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Orchestrator SDK and service helpers' {
    It 'Invoke-SdkDetection does not throw for non-MAUI with no Android TFMs' {
        $state = [PSCustomObject]@{ JavaSdk=$null; AndroidSdk=$null }
        InModuleScope Orchestrator -Parameters @{ state = $state } {
            Mock Write-Log { }
            { Invoke-SdkDetection -State $state -ProjectType 'Web' -Tfms @('net8.0') } | Should -Not -Throw
        }
    }
    It 'Invoke-SdkDetection queries smart SDKs when MAUI/Android and missing' {
        $state = [PSCustomObject]@{}
        InModuleScope Orchestrator -Parameters @{ state = $state } {
            Mock Write-Log { }
            $jdk = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-jdk'
            $adk = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-android'
            Mock Get-SmartSdk { param($State,$ToolType) if ($ToolType -eq 'JDK') { return $jdk } return $adk }
            Mock Get-LocaleMessage { param($Key) return $Key }
            Mock Set-BuildStateProperty { param($State,$Name,$Value,$Force) $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
            Invoke-SdkDetection -State $state -ProjectType 'MAUI' -Tfms @('net8.0-android')
            $state.JavaSdk | Should -Be $jdk
            $state.AndroidSdk | Should -Be $adk
        }
    }
    It 'Register-BuildServices registers singletons when container APIs exist' {
        InModuleScope Orchestrator -Parameters @{ state = [PSCustomObject]@{} } {
            function Register-Service { param($Name,$Factory,[switch]$Singleton) }
            function Test-ServiceRegistered { param($Name) return $false }
            Mock Register-Service { }
            Mock Test-ServiceRegistered { return $false }
            Mock Get-Command { return [pscustomobject]@{Name='Register-Service'} } -ParameterFilter { $Name -eq 'Register-Service' }
            { Register-BuildServices -State $state } | Should -Not -Throw
        }
    }
    It 'Unregister-BuildEventSubscribers is a no-op when event bus helpers are missing' {
        InModuleScope Orchestrator {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-BuildEventHandlers' }
            { Unregister-BuildEventSubscribers } | Should -Not -Throw
        }
    }
}
