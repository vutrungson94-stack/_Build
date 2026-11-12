#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'EventBus.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Orchestrator pipeline event and service helpers' {
    It 'Register-BuildEventSubscribers registers handlers when dependencies are available' {
        $state = [PSCustomObject]@{}
        InModuleScope Orchestrator -Parameters @{ state = $state } {
            $script:registered = [System.Collections.Generic.List[string]]::new()
            Mock Get-Command { return [pscustomobject]@{Name=$Name} } -ParameterFilter { $Name -in 'Add-BuildEvent','Send-Alert' }
            Mock Get-BuildEventSubscribers { return @{} }
            Mock Add-BuildEvent { param($EventName,$Label,$Handler) $script:registered.Add([string]$EventName) }
            Mock Send-Alert { }
            Mock Get-LocaleMessage { param($Key,$MessageArgs) return $Key }
            Mock Get-EventPayloadField { param($Data,$EventName,$Field,$Default) if ($Data -and $Data.PSObject.Properties.Name -contains $Field) { return $Data.$Field } return $Default }
            Mock Get-FlowLogLevel { return 'Info' }
            Mock Write-Log { }
            Register-BuildEventSubscribers -State $state
            $script:registered.Count | Should -BeGreaterThan 5
        }
    }

    It 'Unregister-BuildEventSubscribers removes registered handlers' {
        InModuleScope Orchestrator {
            $script:removed = 0
            Mock Get-Command { return [pscustomobject]@{Name=$Name} } -ParameterFilter { $Name -in 'Get-BuildEventHandlers','Remove-BuildEvent' }
            Mock Get-BuildEventSubscribers { return @{ 'EVT_BUILD_START' = 1 } }
            Mock Get-BuildEventHandlers { param($EventName) return @({}) }
            Mock Remove-BuildEvent { param($EventName,$Handler) $script:removed++ }
            { Unregister-BuildEventSubscribers } | Should -Not -Throw
            $script:removed | Should -BeGreaterThan 0
        }
    }

    It 'Register-BuildServices registers missing services and is idempotent for existing ones' {
        InModuleScope Orchestrator -Parameters @{ state = [PSCustomObject]@{} } {
            $script:registered = [System.Collections.Generic.List[string]]::new()
            Mock Get-Command { return [pscustomobject]@{Name=$Name} } -ParameterFilter { $Name -in 'Register-Service','Test-ServiceRegistered' }
            Mock Test-ServiceRegistered { param($Name) return ($Name -eq 'EventBus') }
            Mock Register-Service { param($Name,$Factory,[switch]$Singleton) $script:registered.Add([string]$Name) }
            Mock New-BuildContext { param($Seed) return [pscustomobject]@{} }
            Mock Get-MetricRegistry { return [pscustomobject]@{} }
            Mock Get-BuildEventBus { return [pscustomobject]@{} }
            Mock Get-ErrorHandlingService { return [pscustomobject]@{} }
            Register-BuildServices -State $state
            $script:registered | Should -Contain 'BuildContext'
            $script:registered | Should -Not -Contain 'EventBus'
        }
    }

    It 'Resolve-BuildSdk returns false when core commands cannot be repaired' {
        InModuleScope Orchestrator -Parameters @{ state = [PSCustomObject]@{} } {
            Mock Assert-CoreCommands { return $false }
            Mock Get-LocaleMessage { param($Key) return $Key }
            Mock Write-Log { }
            Resolve-BuildSdk -State $state | Should -BeFalse
        }
    }

    It 'Resolve-BuildSdk resolves dotnet command and persists state' {
        $state = [PSCustomObject]@{}
        InModuleScope Orchestrator -Parameters @{ state = $state } {
            Mock Assert-CoreCommands { return $true }
            Mock Get-SmartSdk { param($State,$ToolType) return 'C:\dotnet\dotnet.exe' }
            Mock Set-BuildStateProperty { param($State,$Name,$Value,$Force) $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
            Mock Get-LocaleMessage { param($Key,$MessageArgs) return $Key }
            Mock Write-Log { }
            function Test-ServiceRegistered { param($Name) return $false }
            function Save-BuildState { param($State,[switch]$Completed) }
            Mock Test-ServiceRegistered { return $false }
            Mock Save-BuildState { }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Set-ServiceInstance' }
            $ok = Resolve-BuildSdk -State $state
            $ok | Should -BeTrue
            $state.DotnetCmd | Should -Be 'C:\dotnet\dotnet.exe'
        }
    }
}
