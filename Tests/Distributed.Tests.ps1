#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "Distributed Build (Multi-Host)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Distributed.psm1') -Force -DisableNameChecking -ErrorAction Stop
        # Provide a fake `ssh` on PATH so connectivity + command execution can be exercised.
        $sshDir = Join-Path $TestDrive 'fakebin_ok'
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Set-Content -Path (Join-Path $sshDir 'ssh.cmd') -Value "@echo off`r`nexit /b 0"
        $global:GBuildFakeSshDir = $sshDir
        $global:GBuildOrigPath = $env:PATH
        $env:PATH = "$sshDir$([IO.Path]::PathSeparator)$env:PATH"
    }
    AfterAll {
        $env:PATH = $global:GBuildOrigPath
    }

    It "Get-DistributedConfig returns safe defaults when State is null" {
        $cfg = Get-DistributedConfig -State $null
        $cfg.enabled | Should -BeFalse
        $cfg.strategy | Should -Be 'round-robin'
        $cfg.hosts.Count | Should -Be 0
        $cfg.timeout.connect | Should -Be 30
        $cfg.timeout.execution | Should -Be 600
    }

    It "Get-DistributedConfig reads the distributed section from State" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'tag-based'
                    repoRoot = '/srv/repo'
                    hosts    = @([PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u'; tags = @('web'); maxConcurrent = 2 })
                    timeout  = [PSCustomObject]@{ connect = 15; execution = 300 }
                }
            }
        }
        $cfg = Get-DistributedConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.strategy | Should -Be 'tag-based'
        $cfg.repoRoot | Should -Be '/srv/repo'
        $cfg.hosts.Count | Should -Be 1
        $cfg.timeout.connect | Should -Be 15
        $cfg.timeout.execution | Should -Be 300
    }

    It "Resolve-EnvPlaceholder replaces ${env:VAR} placeholders" {
        $env:GBUILD_TEST_REPO = '/resolved/path'
        Resolve-EnvPlaceholder -Text '${env:GBUILD_TEST_REPO}' | Should -Be '/resolved/path'
        Resolve-EnvPlaceholder -Text 'plain' | Should -Be 'plain'
        Resolve-EnvPlaceholder -Text '${env:GBUILD_MISSING_VAR}' | Should -Be '${env:GBUILD_MISSING_VAR}'
    }

    It "Get-DistributedConfig resolves env placeholder inside repoRoot" {
        $env:GBUILD_TEST_REPO = '/env/repo'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ distributed = [PSCustomObject]@{ repoRoot = '${env:GBUILD_TEST_REPO}' } } }
        (Get-DistributedConfig -State $state).repoRoot | Should -Be '/env/repo'
    }

    It "Resolve-HostAssignment round-robins across hosts" {
        $hosts = @(
            [PSCustomObject]@{ name = 'a' }
            [PSCustomObject]@{ name = 'b' }
            [PSCustomObject]@{ name = 'c' }
        )
        $idx = [ref]0
        $h1 = Resolve-HostAssignment -Task ([PSCustomObject]@{ Name = 't1' }) -Hosts $hosts -Strategy 'round-robin' -RoundRobinIndex $idx
        $h2 = Resolve-HostAssignment -Task ([PSCustomObject]@{ Name = 't2' }) -Hosts $hosts -Strategy 'round-robin' -RoundRobinIndex $idx
        $h3 = Resolve-HostAssignment -Task ([PSCustomObject]@{ Name = 't3' }) -Hosts $hosts -Strategy 'round-robin' -RoundRobinIndex $idx
        $h1.name | Should -Be 'a'
        $h2.name | Should -Be 'b'
        $h3.name | Should -Be 'c'
    }

    It "Resolve-HostAssignment tag-based matches a task tag to a host tag" {
        $hosts = @(
            [PSCustomObject]@{ name = 'web-host'; tags = @('web', 'linux') }
            [PSCustomObject]@{ name = 'maui-host'; tags = @('maui', 'windows') }
        )
        $idx = [ref]0
        $h = Resolve-HostAssignment -Task ([PSCustomObject]@{ Name = 'w'; Tags = @('web') }) -Hosts $hosts -Strategy 'tag-based' -RoundRobinIndex $idx
        $h.name | Should -Be 'web-host'
    }

    It "Resolve-HostAssignment tag-based falls back to round-robin on no tag match" {
        $hosts = @(
            [PSCustomObject]@{ name = 'web-host'; tags = @('web') }
            [PSCustomObject]@{ name = 'maui-host'; tags = @('maui') }
        )
        $idx = [ref]0
        $h = Resolve-HostAssignment -Task ([PSCustomObject]@{ Name = 'x'; Tags = @('nope') }) -Hosts $hosts -Strategy 'tag-based' -RoundRobinIndex $idx
        $h.name | Should -Be 'web-host'
    }

    It "Test-RemoteHost returns true when ssh echo ok succeeds" {
        $okDir = Join-Path $TestDrive 'fakebin_ok'
        New-Item -ItemType Directory -Path $okDir -Force | Out-Null
        Set-Content -Path (Join-Path $okDir 'ssh.cmd') -Value "@echo off`r`necho ok"
        $orig = $env:PATH
        $env:PATH = "$okDir$([IO.Path]::PathSeparator)$env:PATH"
        try {
            $hostObj = [PSCustomObject]@{ name = 'h'; hostname = '1.2.3.4'; user = 'u'; identityFile = '~/.ssh/id_rsa' }
            Test-RemoteHost -TargetHost $hostObj -ConnectTimeout 5 | Should -BeTrue
        }
        finally {
            $env:PATH = $orig
        }
    }

    It "Invoke-RemoteCommand reports failure when ssh exits non-zero" {
        $failDir = Join-Path $TestDrive 'fakebin_fail'
        New-Item -ItemType Directory -Path $failDir -Force | Out-Null
        Set-Content -Path (Join-Path $failDir 'ssh.cmd') -Value "@echo off`r`nexit /b 1"
        $orig = $env:PATH
        $env:PATH = "$failDir$([IO.Path]::PathSeparator)$env:PATH"
        try {
            $hostObj = [PSCustomObject]@{ name = 'h'; hostname = '1.1.1.1'; user = 'u'; identityFile = '~/.ssh/id_rsa' }
            $r = Invoke-RemoteCommand -TargetHost $hostObj -Command 'dotnet build' -RepoRoot '/srv/repo' -ConnectTimeout 5
            $r.Success | Should -BeFalse
            $r.ExitCode | Should -Be 1
        }
        finally {
            $env:PATH = $orig
        }
    }

    It "Invoke-DistributedBuild returns null when disabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ distributed = [PSCustomObject]@{ enabled = $false } } }
        $r = Invoke-DistributedBuild -Tasks @([PSCustomObject]@{ Name = 't'; Command = 'echo hi' }) -State $state
        $r | Should -BeNullOrEmpty
    }

    It "Invoke-DistributedBuild distributes tasks across hosts and collects success" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'round-robin'
                    repoRoot = '/srv/repo'
                    hosts    = @(
                        [PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2 }
                        [PSCustomObject]@{ name = 'h2'; hostname = '2.2.2.2'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2 }
                    )
                    timeout  = [PSCustomObject]@{ connect = 5; execution = 30 }
                }
            }
        }
        $tasks = @(
            [PSCustomObject]@{ Name = 'a'; Command = 'dotnet build a.csproj' }
            [PSCustomObject]@{ Name = 'b'; Command = 'dotnet build b.csproj' }
        )
        $results = Invoke-DistributedBuild -Tasks $tasks -State $state -Simulation
        $results | Should -Not -BeNullOrEmpty
        $results.Count | Should -Be 2
        ($results | Where-Object { $_.Success }).Count | Should -Be 2
    }

    It "Invoke-DistributedBuild returns empty array when no tasks supplied" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ distributed = [PSCustomObject]@{ enabled = $true; repoRoot = '/srv/repo'; hosts = @([PSCustomObject]@{ name = 'h'; hostname = '1.1.1.1'; user = 'u' }) } } }
        $r = Invoke-DistributedBuild -Tasks @() -State $state -SkipConnectivityCheck
        $r | Should -BeNullOrEmpty
    }

    It "kills a remote command when execution timeout expires" {
        $slowDir = Join-Path $TestDrive 'fakebin_slow'
        New-Item -ItemType Directory -Path $slowDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $slowDir 'ssh.cmd'), "@echo off`r`nping -n 8 127.0.0.1 >nul`r`nexit /b 0")
        $oldPath = $env:PATH
        $env:PATH = "$slowDir$([IO.Path]::PathSeparator)$oldPath"
        try {
            $hostObject = [PSCustomObject]@{ name = 'slow'; hostname = '127.0.0.1'; user = 'u'; identityFile = '~/.ssh/id_rsa' }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RemoteCommand -TargetHost $hostObject -Command 'sleep' -RepoRoot '/srv/repo' -ConnectTimeout 1 -ExecutionTimeout 1
            $watch.Stop()
            $result.Success | Should -BeFalse
            $result.TimedOut | Should -BeTrue
            $result.ExitCode | Should -Be 124
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
        } finally { $env:PATH = $oldPath }
    }

    It "rejects an ssh hostname injection value" {
        $hostObject = [PSCustomObject]@{ name = 'bad'; hostname = 'host;Write-Output injected'; user = 'u' }
        Invoke-RemoteCommand -TargetHost $hostObject -Command 'echo ok' -RepoRoot '/srv/repo' -ExecutionTimeout 1 | Should -Not -BeNullOrEmpty
        (Invoke-RemoteCommand -TargetHost $hostObject -Command 'echo ok' -RepoRoot '/srv/repo' -ExecutionTimeout 1).Success | Should -BeFalse
    }

    It "rejects an option-like ssh user identity value" {
        $hostObject = [PSCustomObject]@{ name = 'bad-user'; hostname = '1.1.1.1'; user = '-oProxyCommand=evil' }
        (Invoke-RemoteCommand -TargetHost $hostObject -Command 'echo ok' -RepoRoot '/srv/repo' -ExecutionTimeout 1).Success | Should -BeFalse
    }

    It "expands a tilde only at the start of an ssh identity path" {
        InModuleScope Distributed {
            $embedded = Join-Path $TestDrive 'identity~key'
            Resolve-DistributedIdentityPath -Path $embedded | Should -Be ([System.IO.Path]::GetFullPath($embedded))
            Resolve-DistributedIdentityPath -Path '~other/.ssh/id_rsa' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Distributed - result aggregation dashboard (New-DistributedReport)' {

    BeforeEach {
        $dir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_rpt_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script:state = [PSCustomObject]@{ ScriptRoot = $dir }
        $script:cfg = [PSCustomObject]@{ reportPath = 'distributed-report' }
        $script:results = @(
            [PSCustomObject]@{ Task = 'a'; Host = 'h1'; Success = $true;  Duration = 1.5; Error = $null }
            [PSCustomObject]@{ Task = 'b'; Host = 'h1'; Success = $false; Duration = 2.0; Error = 'boom' }
            [PSCustomObject]@{ Task = 'c'; Host = 'h2'; Success = $true;  Duration = 0.5; Error = $null }
        )
    }

    AfterEach {
        if ($dir -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes JSON and Markdown report files under reportPath' {
        $report = New-DistributedReport -Results $script:results -State $script:state -Config $script:cfg
        $report | Should -Not -BeNullOrEmpty
        (Test-Path $report.JsonPath) | Should -BeTrue
        (Test-Path $report.MarkdownPath) | Should -BeTrue
        $json = Get-Content $report.JsonPath -Raw | ConvertFrom-Json
        $json.Total | Should -Be 3
        $json.Success | Should -Be 2
        $json.Failed | Should -Be 1
        $json.Hosts.Count | Should -Be 2
    }

    It 'aggregates per-host rollup correctly' {
        $report = New-DistributedReport -Results $script:results -State $script:state -Config $script:cfg
        $h1 = @($report.Summary.Hosts | Where-Object { $_.Host -eq 'h1' })[0]
        $h1.Total | Should -Be 2
        $h1.Success | Should -Be 1
        $h1.Failed | Should -Be 1
    }

    It 'contains a traversal report path under the state root' {
        $script:cfg.reportPath = '../outside'
        $report = New-DistributedReport -Results $script:results -State $script:state -Config $script:cfg
        $report.JsonPath | Should -BeLike '*distributed-report\distributed-report.json'
        $report.JsonPath | Should -Not -Match '(?i)outside'
        Test-Path -LiteralPath (Join-Path $script:state.ScriptRoot '../outside') | Should -BeFalse
    }
}

Describe 'Distributed - real-path integration (fake ssh transport, no -Simulation)' {
    # Exercises the FULL production path — config -> host assignment -> runspace
    # pool -> Invoke-RemoteCommand equivalent (ssh args) -> aggregation -> report —
    # with only the ssh TRANSPORT faked (ssh.cmd exit 0/1 on PATH). This goes
    # beyond -Simulation (which returns placeholders without touching the pool).
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Distributed.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $sshDir = Join-Path $TestDrive 'fakebin_ok'
        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            Set-Content -Path (Join-Path $sshDir 'ssh.cmd') -Value "@echo off`r`nexit /b 0"
        }
        $global:GBuildRealPathOrigPath = $env:PATH
        $env:PATH = "$sshDir$([IO.Path]::PathSeparator)$env:PATH"
        if (Get-Command Reset-CircuitBreaker -ErrorAction SilentlyContinue) { Reset-CircuitBreaker }
    }
    AfterAll {
        $env:PATH = $global:GBuildRealPathOrigPath
    }

    It 'round-robins tasks across hosts and collects success (real runspace path)' {
        # Inline state (repo convention: Pester It bodies cannot see helper
        # functions — states are built inline like the tests above).
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'round-robin'
                    repoRoot = '/srv/repo'
                    hosts    = @(
                        [PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2 }
                        [PSCustomObject]@{ name = 'h2'; hostname = '2.2.2.2'; user = 'u'; identityFile = '~/.ssh/id_rsa'; maxConcurrent = 2 }
                    )
                    timeout  = [PSCustomObject]@{ connect = 5; execution = 30 }
                }
            }
        }
        $tasks = @(
            [PSCustomObject]@{ Name = 'a'; Command = 'dotnet build a.csproj' }
            [PSCustomObject]@{ Name = 'b'; Command = 'dotnet build b.csproj' }
        )
        $results = Invoke-DistributedBuild -Tasks $tasks -State $state -SkipConnectivityCheck
        $results | Should -Not -BeNullOrEmpty
        $results.Count | Should -Be 2
        ($results | Where-Object { $_.Success }).Count | Should -Be 2
        (($results | ForEach-Object { $_.Host } | Sort-Object) -join ',') | Should -Be 'h1,h2'
        ($results | Where-Object { $_.ExitCode -ne 0 }).Count | Should -Be 0
    }

    It 'tag-based routing sends each task to its matching host (real runspace path)' {
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'tag-based'
                    repoRoot = '/srv/repo'
                    hosts    = @(
                        [PSCustomObject]@{ name = 'web-host'; hostname = '1.1.1.1'; user = 'u'; tags = @('web') }
                        [PSCustomObject]@{ name = 'maui-host'; hostname = '2.2.2.2'; user = 'u'; tags = @('maui') }
                    )
                    timeout  = [PSCustomObject]@{ connect = 5; execution = 30 }
                }
            }
        }
        $tasks = @(
            [PSCustomObject]@{ Name = 'w'; Command = 'npm run build'; Tags = @('web') }
            [PSCustomObject]@{ Name = 'm'; Command = 'dotnet publish'; Tags = @('maui') }
        )
        $results = Invoke-DistributedBuild -Tasks $tasks -State $state -SkipConnectivityCheck
        $results.Count | Should -Be 2
        (@($results | Where-Object { $_.Task -eq 'w' })[0].Host) | Should -Be 'web-host'
        (@($results | Where-Object { $_.Task -eq 'm' })[0].Host) | Should -Be 'maui-host'
    }

    It 'all-failed aggregation returns null (throw recorded by circuit breaker)' {
        $failDir = Join-Path $TestDrive 'fakebin_fail'
        if (-not (Test-Path $failDir)) {
            New-Item -ItemType Directory -Path $failDir -Force | Out-Null
            Set-Content -Path (Join-Path $failDir 'ssh.cmd') -Value "@echo off`r`nexit /b 1"
        }
        $orig = $env:PATH
        $env:PATH = "$failDir$([IO.Path]::PathSeparator)$env:PATH"
        try {
            $state = [PSCustomObject]@{
                ScriptRoot  = $TestDrive
                BuildConfig = [PSCustomObject]@{
                    distributed = [PSCustomObject]@{
                        enabled  = $true
                        strategy = 'round-robin'
                        repoRoot = '/srv/repo'
                        hosts    = @(
                            [PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u' }
                        )
                        timeout  = [PSCustomObject]@{ connect = 5; execution = 30 }
                    }
                }
            }
            $tasks = @([PSCustomObject]@{ Name = 'a'; Command = 'dotnet build a.csproj' })
            $r = Invoke-DistributedBuild -Tasks $tasks -State $state -SkipConnectivityCheck
            $r | Should -BeNullOrEmpty
        }
        finally {
            $env:PATH = $orig
        }
    }

    It 'real-path run emits a JSON+Markdown report under ScriptRoot' {
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            BuildConfig = [PSCustomObject]@{
                distributed = [PSCustomObject]@{
                    enabled  = $true
                    strategy = 'round-robin'
                    repoRoot = '/srv/repo'
                    hosts    = @(
                        [PSCustomObject]@{ name = 'h1'; hostname = '1.1.1.1'; user = 'u' }
                    )
                    timeout  = [PSCustomObject]@{ connect = 5; execution = 30 }
                }
            }
        }
        $tasks = @([PSCustomObject]@{ Name = 'a'; Command = 'dotnet build a.csproj' })
        $results = Invoke-DistributedBuild -Tasks $tasks -State $state -SkipConnectivityCheck
        $results.Count | Should -Be 1
        $reportDir = Join-Path $TestDrive 'distributed-report'
        (Test-Path $reportDir) | Should -BeTrue
        $jsonFile = Join-Path $reportDir 'distributed-report.json'
        (Test-Path $jsonFile) | Should -BeTrue
        (Test-Path (Join-Path $reportDir 'distributed-report.md')) | Should -BeTrue
        $json = Get-Content $jsonFile -Raw | ConvertFrom-Json
        $json.Total | Should -BeGreaterOrEqual 1
        $json.Success | Should -BeGreaterOrEqual 1
    }
}
