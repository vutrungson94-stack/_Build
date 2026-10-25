#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "Parallel Runspace Pool" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Parallel.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Creates and runs a runspace pool without 'host is null' error" {
        $tasks = @('alpha', 'beta', 'gamma')
        { Invoke-ParallelBuild -BuildTasks $tasks -MaxJobs 2 } | Should -Not -Throw
        $results = Invoke-ParallelBuild -BuildTasks $tasks -MaxJobs 2
        $results | Should -Not -BeNullOrEmpty
        $results.Count | Should -Be 3
        ($results | Where-Object { $_.Success }).Count | Should -Be 3
    }

    It "Creates runspace pool via InitialSessionState overload (no host fallback)" {
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool = [runspacefactory]::CreateRunspacePool($sessionState)
        { $pool.Open(); $pool.Close(); $pool.Dispose() } | Should -Not -Throw
    }

    It "Returns results for scriptblock-based tasks" {
        $tasks = @(
            @{ Name = 'one'; ScriptBlock = { param($n, $s) "R:$n" } }
            @{ Name = 'two'; ScriptBlock = { param($n, $s) "R:$n" } }
        )
        $results = Invoke-ParallelBuild -BuildTasks $tasks -MaxJobs 2
        $results.Count | Should -Be 2
        $outputs = $results | ForEach-Object { $_.Output } | ForEach-Object { $_ }
        ($outputs | Where-Object { $_ -like 'R:*' }).Count | Should -Be 2
    }
}
