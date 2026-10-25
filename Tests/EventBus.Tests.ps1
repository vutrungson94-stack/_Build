#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "EventBus Core" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'EventBus.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Clear-BuildEvents
    }

    It "Add-BuildEvent registers a subscriber and Get-BuildEventSubscribers reflects it" {
        $h = { param($s, $d) }
        Add-BuildEvent -EventName 'EVT_BUILD_START' -Handler $h
        $subs = Get-BuildEventSubscribers
        $subs['EVT_BUILD_START'] | Should -Be 1
    }

    It "Remove-BuildEvent removes a previously added subscriber" {
        $h = { param($s, $d) }
        Add-BuildEvent -EventName 'EVT_BUILD_START' -Handler $h
        Remove-BuildEvent -EventName 'EVT_BUILD_START' -Handler $h
        $subs = Get-BuildEventSubscribers
        $subs.ContainsKey('EVT_BUILD_START') | Should -BeFalse
    }

    It "Send-BuildEvent invokes all registered handlers" {
        $global:evtCalls = 0
        $h = { param($s, $d) $global:evtCalls++ }
        Add-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -Handler $h
        Send-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -Data @{}
        $global:evtCalls | Should -Be 1
    }

    It "Send-BuildEvent isolates handler errors (does not throw, records error)" {
        $bad = { param($s, $d) throw 'boom' }
        Add-BuildEvent -EventName 'EVT_BUILD_ERROR' -Handler $bad
        { Send-BuildEvent -EventName 'EVT_BUILD_ERROR' -Data @{} } | Should -Not -Throw
        $errs = Get-BuildEventErrors
        $errs.Count | Should -BeGreaterThan 0
    }

    It "Clear-BuildEvents removes all subscribers and recorded errors" {
        $h = { param($s, $d) }
        Add-BuildEvent -EventName 'EVT_BUILD_START' -Handler $h
        Clear-BuildEvents
        Get-BuildEventSubscribers | Should -BeNullOrEmpty
        Get-BuildEventErrors | Should -BeNullOrEmpty
    }
}

Describe "EventBus Event Constants" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'EventBus.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Clear-BuildEvents
    }
    It "Exposes all 21 EVT_* constants" {
        $constants = @(
            'EVT_BUILD_START', 'EVT_BUILD_COMPLETE', 'EVT_BUILD_ERROR', 'EVT_BUILD_WARNING',
            'EVT_STEP_START', 'EVT_STEP_COMPLETE', 'EVT_STEP_ERROR', 'EVT_STEP_SKIPPED',
            'EVT_STEP_PROGRESS',
            'EVT_ON_ERROR', 'EVT_ON_RETRY', 'EVT_ON_ROLLBACK', 'EVT_PLUGIN_LOADED',
            'EVT_PLUGIN_ERROR', 'EVT_CACHE_HIT', 'EVT_CACHE_MISS', 'EVT_CACHE_SYNC',
            'EVT_TELEMETRY_RECORDED', 'EVT_DEPLOY_START', 'EVT_DEPLOY_COMPLETE', 'EVT_DEPLOY_ERROR'
        )
        foreach ($c in $constants) {
            Get-Variable -Name $c -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'EventBus tenant and payload contract' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'EventBus.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Clear-BuildEvents
    }
    AfterEach {
        Clear-BuildEvents
    }

    It 'isolates subscribers by tenant' {
        $global:defaultCalls = 0
        $global:acmeCalls = 0
        Add-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -TenantId 'default' -Handler { $global:defaultCalls++ }
        Add-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -TenantId 'acme' -Handler { $global:acmeCalls++ }
        Send-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -Source ([PSCustomObject]@{ TenantId = 'acme' })
        $global:defaultCalls | Should -Be 0
        $global:acmeCalls | Should -Be 1
    }

    It 'adds the required payload envelope' {
        $global:payload = $null
        Add-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -Handler { param($source, $data) $global:payload = $data }
        Send-BuildEvent -EventName 'EVT_BUILD_COMPLETE' -Data @{ Value = 1 }
        $global:payload.eventName | Should -Be 'EVT_BUILD_COMPLETE'
        $global:payload.tenantId | Should -Be 'default'
        $global:payload.sequence | Should -BeGreaterThan 0
        $global:payload.timestamp | Should -Not -BeNullOrEmpty
    }
}
