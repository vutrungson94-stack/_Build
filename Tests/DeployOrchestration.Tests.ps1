$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $here (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

BeforeAll {
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
    if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        function Write-Log { param($Message, $Level, $State) }
    }
}

Describe 'Deploy Orchestration' {
    # Test-DeployHealth is opt-in: it probes only when deploy.health.enabled
    # is true AND an endpoint is configured. The schema declared both keys
    # before anything read them, so the probe was unreachable code; wiring it
    # into Invoke-DeployWithRollback is only safe with that gate.
    It 'Test-DeployHealth does not probe when health is not configured' {
        (Test-DeployHealth -State $null -Url 'http://127.0.0.1:1' -Retries 1 -DelayMs 50) | Should -Be $true
    }

    It 'Test-DeployHealth returns true for reachable URL' {
        # Loopback listener on an OS-assigned port, NOT https://example.com.
        # A unit test must not depend on the public internet: it is slow, it is
        # non-deterministic, and on a managed workstation an outbound SYN to a
        # public host reads as C2 beaconing to the endpoint agent - which then
        # kills the test host. This file's own comment about TEST-NET blackholes
        # records the same failure mode from the other direction.
        #
        # The listener runs in Start-Job (NOT Start-ThreadJob, which does not
        # exist on Windows PowerShell 5.1) and publishes its port through a file
        # so the port is chosen by the kernel and never raced for.
        $portFile = Join-Path $TestDrive ('health-port-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $job = Start-Job -ScriptBlock {
            param($Path)
            # TcpListener on port 0, not HttpListener: HttpListener refuses to
            # serve without AddPrefix and cannot report an OS-assigned port, so
            # it would either need a hardcoded port (racy across parallel runs)
            # or a guessed prefix. TcpListener gives us both for free.
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $l.Start()
            Set-Content -LiteralPath $Path -Value ([string]$l.LocalEndpoint.Port) -Encoding ASCII
            try {
                $client = $l.AcceptTcpClient()
                $stream = $client.GetStream()
                $buf = New-Object byte[] 4096
                # Drain whatever request headers arrived; the method is irrelevant.
                try { [void]$stream.Read($buf, 0, $buf.Length) } catch { }
                $resp = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($resp)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $client.Close()
            } catch {
                Set-Content -LiteralPath "$Path.err" -Value ([string]$_.Exception.Message) -Encoding ASCII
            } finally { try { $l.Stop() } catch { } }
        } -ArgumentList $portFile
        try {
            $deadline = (Get-Date).AddSeconds(20)
            $port = 0
            while ((Get-Date) -lt $deadline -and $port -eq 0) {
                Start-Sleep -Milliseconds 50
                if (Test-Path $portFile) {
                    $raw = (Get-Content $portFile -Raw -ErrorAction SilentlyContinue)
                    if ($raw) { $port = [int]$raw.Trim() }
                }
            }
            $port | Should -BeGreaterThan 0
            $healthState = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ health = [PSCustomObject]@{ enabled = $true } } } }
            $result = Test-DeployHealth -State $healthState -Url "http://127.0.0.1:$port/healthz" -Retries 3 -DelayMs 300
            $result | Should -Be $true
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Remove-Item $portFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-DeployHealth returns false for unreachable URL' {
        # Loopback port 1 = instant connection-refused. Do NOT use TEST-NET
        # blackhole addresses (192.0.2.x): long-hanging SYNs look like C2
        # beaconing to endpoint-protection agents, which kill the test host.
        $healthState = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ health = [PSCustomObject]@{ enabled = $true } } } }
        $result = Test-DeployHealth -State $healthState -Url 'http://127.0.0.1:1' -Retries 1 -DelayMs 50
        $result | Should -Be $false
    }

    It 'Invoke-DeployWithRollback runs the health probe and fails on a broken endpoint' {
        # The defect this guards: exit code 0 used to be reported as a
        # successful deploy with no probe at all, so a release that was live
        # and serving 5xx was recorded as Succeeded.
        function global:Invoke-HealthyFake { param($s) $true }
        $state = New-TestState
        Register-DeployTarget -Name 'healthyFake' -Function 'Invoke-HealthyFake'
        # New-TestState ships BuildConfig = $null; build the health block here.
        $state.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ health = [PSCustomObject]@{ enabled = $true; url = 'http://127.0.0.1:1'; retries = 1; delayMs = 10 } } }
        $result = Invoke-DeployWithRollback -State $state -TargetName 'healthyFake'
        $result | Should -Be $false
        Remove-Item -LiteralPath 'function:global:Invoke-HealthyFake' -ErrorAction SilentlyContinue
    }

    It 'Invoke-DeployWithRollback succeeds on registered target' {
        function global:Invoke-FakeAzure { param($s) $true }
        $mockState = New-TestState
        Register-DeployTarget -Name 'fakeAzure' -Function 'Invoke-FakeAzure'
        $result = Invoke-DeployWithRollback -State $mockState -TargetName 'fakeAzure'
        $result | Should -Be $true
        Remove-Item -LiteralPath 'function:global:Invoke-FakeAzure' -ErrorAction SilentlyContinue
    }

    It 'Invoke-DeployWithRollback fails on unregistered target' {
        $mockState = New-TestState
        $result = Invoke-DeployWithRollback -State $mockState -TargetName 'missingTarget'
        $result | Should -Be $false
    }

    It 'Invoke-DeployGroup returns false when no order.groups configured' {
        $mockState = New-TestState
        $result = Invoke-DeployGroup -State $mockState
        $result | Should -Be $false
    }

    It 'Invoke-DeployGroup runs targets sequentially within a group' {
        $global:execOrder = @()
        function global:Invoke-SeqA { param($s) $global:execOrder += 'A'; $true }
        function global:Invoke-SeqB { param($s) $global:execOrder += 'B'; $true }
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{
            deploy = @{
                order = @{
                    groups = @(
                        @{ name = 'g1'; targets = @('seqA', 'seqB'); failFast = $false }
                    )
                }
            }
        }
        Register-DeployTarget -Name 'seqA' -Function 'Invoke-SeqA'
        Register-DeployTarget -Name 'seqB' -Function 'Invoke-SeqB'
        $result = Invoke-DeployGroup -State $mockState
        $result | Should -Be $true
        $global:execOrder[0] | Should -Be 'A'
        $global:execOrder[1] | Should -Be 'B'
        Remove-Item -LiteralPath 'function:global:Invoke-SeqA' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'function:global:Invoke-SeqB' -ErrorAction SilentlyContinue
    }

    It 'Invoke-DeployGroup returns false when a target fails' {
        function global:Invoke-SeqFail { param($s) return $false }
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{
            deploy = @{
                order = @{
                    groups = @(
                        @{ name = 'g1'; targets = @('seqFail'); failFast = $false }
                    )
                }
            }
        }
        Register-DeployTarget -Name 'seqFail' -Function 'Invoke-SeqFail'
        Invoke-DeployGroup -State $mockState | Should -BeFalse
        Remove-Item -LiteralPath 'function:global:Invoke-SeqFail' -ErrorAction SilentlyContinue
    }

    It 'does not report a partial deployment as successful' {
        function global:Invoke-PartialFail { param($s) $false }
        $mockState = New-TestState
        $mockState.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ order = [PSCustomObject]@{ groups = @([PSCustomObject]@{ name = 'g1'; targets = @('partialFail'); failFast = $false }) } } }
        Register-DeployTarget -Name 'partialFail' -Function 'Invoke-PartialFail'
        Invoke-DeployGroup -State $mockState | Should -BeFalse
        Remove-Item -LiteralPath 'function:global:Invoke-PartialFail' -ErrorAction SilentlyContinue
    }

    It 'Enter-DeployLock acquires and Exit-DeployLock releases' {
        $lockName = "lock-$(Get-Random)"
        Enter-DeployLock -LockName $lockName -TimeoutMs 1000 | Should -Be $true
        { Exit-DeployLock -LockName $lockName } | Should -Not -Throw
    }

    It 'Enter-DeployLock blocks concurrent acquisition' {
        $lockName = "blocked-$(Get-Random)"
        $null = Enter-DeployLock -LockName $lockName -TimeoutMs 5000
        $second = Enter-DeployLock -LockName $lockName -TimeoutMs 200
        $second | Should -Be $false
        Exit-DeployLock -LockName $lockName
    }
}
