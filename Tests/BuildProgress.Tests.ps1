#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildConstants.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildProgress.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "BuildProgress (live output streaming)" {
    BeforeAll {
        # Host-agnostic shell resolution: (Get-Process -Id $PID).Path is the
        # dotnet test-host under some runners, which cannot execute pwsh args.
        # Prefer a real pwsh/powershell executable so Process-mode tests run
        # identically under pwsh, Windows PowerShell and dotnet-hosted Pester.
        $script:TestShell = $null
        foreach ($cmd in @('pwsh', 'powershell')) {
            $found = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $src = if ($found.Source) { $found.Source } else { $found.Path }
                if ($src -and (Test-Path -LiteralPath $src -PathType Leaf)) { $script:TestShell = $src; break }
            }
        }
        if (-not $script:TestShell) { $script:TestShell = (Get-Process -Id $PID).Path }
    }

    It "Format-ElapsedTag formats seconds with padding" {
        Format-ElapsedTag -Secs 5 | Should -Match '\[\s*5s\]'
        Format-ElapsedTag -Secs 123.4 | Should -Match '\[\s*123s\]'
    }

    It "ConvertTo-ProcessArgument quotes args containing spaces and preserves plain args" {
        ConvertTo-ProcessArgument -Value 'plain' | Should -Be 'plain'
        ConvertTo-ProcessArgument -Value 'G:\TRUNG SON\x.psm1' | Should -Be '"G:\TRUNG SON\x.psm1"'
        ConvertTo-ProcessArgument -Value '-p:K="v"' | Should -Be '"-p:K=\"v\""'
        ConvertTo-ProcessArgument -Value '' | Should -Be '""'
    }

    It "Get-ProgressConfig returns sane defaults for a null State" {
        $cfg = Get-ProgressConfig -State $null
        $cfg.Enabled | Should -BeTrue
        $cfg.StreamOutput | Should -BeTrue
        $cfg.ThrottleMs | Should -BeGreaterThan 0
        $cfg.HeartbeatSec | Should -BeGreaterThan 0
        $cfg.PollMs | Should -BeGreaterThan 0
    }

    It "ScriptBlock mode collects lines and returns exit code 0" {
        $sb = { Write-Output 'alpha'; Write-Output 'beta' }
        $res = Invoke-WithLiveOutput -ScriptBlock $sb -State $null -Label 'test'
        $res.ExitCode | Should -Be 0
        @($res.Output | Where-Object { $_ -match 'alpha|beta' }).Count | Should -Be 2
        $res.ElapsedSec | Should -BeGreaterOrEqual 0
    }

    It "ScriptBlock mode propagates the native exit code" {
        $sb = { cmd /c "exit 7" }
        $res = Invoke-WithLiveOutput -ScriptBlock $sb -State $null -Label 'test'
        $res.ExitCode | Should -Be 7
    }

    It "Process mode streams a real child process and collects output" {
        $psExe = $script:TestShell
        $res = Invoke-WithLiveOutput -FilePath $psExe -ArgList @('-NoProfile', '-Command', "Write-Output 'live-a'; Start-Sleep -Milliseconds 300; Write-Output 'live-b'") -State $null -Label 'proc-test'
        $res.ExitCode | Should -Be 0
        $joined = ($res.Output -join "`n")
        $joined | Should -Match 'live-a'
        $joined | Should -Match 'live-b'
        $res.ElapsedSec | Should -BeGreaterOrEqual 0.2
    }

    It "Process mode propagates a non-zero child exit code" {
        $psExe = $script:TestShell
        $res = Invoke-WithLiveOutput -FilePath $psExe -ArgList @('-NoProfile', '-Command', 'exit 5') -State $null -Label 'proc-fail'
        $res.ExitCode | Should -Be 5
    }

    It "OnLine callback is invoked once per non-empty line" {
        $seen = [System.Collections.Generic.List[string]]::new()
        $onLine = { param($l) $seen.Add([string]$l) }
        $sb = { Write-Output 'one'; Write-Output 'two' }
        $null = Invoke-WithLiveOutput -ScriptBlock $sb -State $null -Label 'test' -OnLine $onLine
        @($seen | Where-Object { $_ -match 'one|two' }).Count | Should -Be 2
    }

    It "Quiet mode still collects output without invoking OnLine" {
        # Reference-type counter (List) so increments inside the callback — invoked
        # from Invoke-WithLiveOutput's scope — are visible here for the assertion.
        $seen = [System.Collections.Generic.List[string]]::new()
        $onLine = { param($l) $seen.Add([string]$l) }
        $sb = { Write-Output 'quiet-line' }
        $res = Invoke-WithLiveOutput -ScriptBlock $sb -State $null -Label 'test' -OnLine $onLine -Quiet
        ($res.Output | Where-Object { $_ -match 'quiet-line' }).Count | Should -Be 1
        # The point of Quiet mode: OnLine is never invoked.
        $seen.Count | Should -Be 0
    }

    It "Process mode handles a child writing to stderr (merged into Output)" {
        $psExe = $script:TestShell
        $res = Invoke-WithLiveOutput -FilePath $psExe -ArgList @('-NoProfile', '-Command', "[Console]::Error.WriteLine('err-line')") -State $null -Label 'proc-err' -Quiet
        ($res.Output -join "`n") | Should -Match 'err-line'
    }

    It "Process mode kills a hung child on TimeoutSec (ExitCode 124, TimedOut)" {
        $psExe = $script:TestShell
        $res = Invoke-WithLiveOutput -FilePath $psExe -ArgList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -State $null -Label 'proc-timeout' -Quiet -TimeoutSec 2
        $res.TimedOut | Should -Be $true
        $res.ExitCode | Should -Be 124
        $res.ElapsedSec | Should -BeLessThan 25
    }

    It "Process mode without TimeoutSec is unbounded (legacy default)" {
        $psExe = $script:TestShell
        $res = Invoke-WithLiveOutput -FilePath $psExe -ArgList @('-NoProfile', '-Command', "Write-Output 'fast'") -State $null -Label 'proc-notimeout' -Quiet
        $res.TimedOut | Should -Be $false
        $res.ExitCode | Should -Be 0
    }
}

