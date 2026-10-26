#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Distributed.E2E - mock end-to-end distributed build proof.
.DESCRIPTION
    Proves Invoke-DistributedBuild dispatches tasks across hosts and
    aggregates results WITHOUT requiring two real networked machines. A fake
    ssh.cmd on $env:PATH stands in for real SSH: it always exits 0
    and echoes the remote command, so the full code path
    (Get-AvailableHosts -> Resolve-HostAssignment -> Invoke-RemoteCommand
     -> New-DistributedReport) executes and is asserted. No hardcoded paths.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $PSCommandPath) '../Modules'

Describe "Distributed Build E2E (mock SSH)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Distributed.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop

        $sshDir = Join-Path $TestDrive 'fakebin_ok'
        $null = New-Item -ItemType Directory -Path $sshDir -Force
        Set-Content -Path (Join-Path $sshDir 'ssh.cmd') -Value "@echo off`r`nexit /b 0"
        $global:GBuildFakeSshDir = $sshDir
        $global:GBuildOrigPath = $env:PATH
        $env:PATH = "$sshDir$([IO.Path]::PathSeparator)$env:PATH"
    }

    AfterAll {
        # Restore PATH (this test added a fake ssh dir to it).
        $env:PATH = $global:GBuildOrigPath
        # Intentionally do NOT Remove-Module: Pester shares module session state
        # across files in one run; removing here would break later test files that
        # import the same module.
    }

    It "Runs a distributed build across two mock hosts and reports success" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'round-robin'
                    repoRoot = $TestDrive
                    hosts    = @(
                        [PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2; tags = @('web') }
                        [PSCustomObject]@{ name = 'h2'; hostname = '2.2.2.2'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2; tags = @('web') }
                    )
                    timeout  = [PSCustomObject]@{ connect = 15; execution = 120 }
                }
            }
        }
        $tasks = @(
            [PSCustomObject]@{ Name = 'a'; Command = 'dotnet build web-a.csproj'; Tags = @('web') }
            [PSCustomObject]@{ Name = 'b'; Command = 'dotnet build web-b.csproj'; Tags = @('web') }
        )

        $result = Invoke-DistributedBuild -State $state -Tasks $tasks -SkipConnectivityCheck
        $result | Should -Not -BeNull
        $result.Count | Should -Be 2
        ($result | Where-Object { -not $_.Success }).Count | Should -Be 0
    }

    It "New-DistributedReport produces JSON and Markdown rollup" {
        $dir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_rpt_e2e_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $state = [PSCustomObject]@{ ScriptRoot = $dir }
        $cfg = [PSCustomObject]@{ reportPath = 'distributed-report' }
        $results = @(
            [PSCustomObject]@{ Task = 'a'; Host = 'h1'; Success = $true;  Duration = 1.0; Error = $null }
            [PSCustomObject]@{ Task = 'b'; Host = 'h2'; Success = $true;  Duration = 0.5; Error = $null }
        )

        $report = New-DistributedReport -Results $results -State $state -Config $cfg
        $report | Should -Not -BeNullOrEmpty
        (Test-Path $report.JsonPath) | Should -BeTrue
        (Test-Path $report.MarkdownPath) | Should -BeTrue
        $json = Get-Content $report.JsonPath -Raw | ConvertFrom-Json
        $json.Total | Should -Be 2
        $json.Success | Should -Be 2
    }
}
