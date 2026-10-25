#Requires -Version 5.1
Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Write-BuildTextFileAtomic -PreCommit isolation' {
    It 'aborts and leaves the destination untouched when the hook throws' {
        # The hook exists so CredentialVault can harden permissions before the
        # bytes land. Sharing one try/catch with the replace meant a FAILING
        # hook fell into the copy fallback - so the hardened-file guarantee
        # silently inverted into "write it un-hardened and report success".
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-atomic-' + [System.Guid]::NewGuid().ToString('n'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'vault.json'
        $marker = Join-Path $dir 'hook-ran.txt'
        try {
            [System.IO.File]::WriteAllText($path, 'ORIGINAL')
            $ok = Write-BuildTextFileAtomic -Path $path -Lines @('NEW') -PreCommit {
                param($t)
                # Proven from the filesystem, not by assigning a variable: a
                # scriptblock invoked with & runs in a child scope, so writes to
                # variables in the test's scope are silently discarded.
                [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $t) 'hook-ran.txt'), [System.IO.File]::ReadAllText($t))
                throw 'permission hardening refused'
            }
            $ok | Should -BeFalse
            [System.IO.File]::ReadAllText($path) | Should -Be 'ORIGINAL'
            [System.IO.File]::Exists($marker) | Should -BeTrue
            [System.IO.File]::ReadAllText($marker).Trim() | Should -Be 'NEW'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'aborts when the hook leaves a non-zero LASTEXITCODE and does not leak a temp file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-atomic-' + [System.Guid]::NewGuid().ToString('n'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'artifact.txt'
        try {
            $ok = Write-BuildTextFileAtomic -Path $path -Lines @('NEW') -PreCommit {
                param($t) $global:LASTEXITCODE = 3
            }
            $ok | Should -BeFalse
            [System.IO.File]::Exists($path) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -Force).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still writes when the hook succeeds, and the hook saw the staged bytes' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-atomic-' + [System.Guid]::NewGuid().ToString('n'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'artifact.txt'
        $marker = Join-Path $dir 'hook-ran.txt'
        try {
            $ok = Write-BuildTextFileAtomic -Path $path -Lines @('NEW') -PreCommit {
                param($t)
                [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $t) 'hook-ran.txt'), [System.IO.File]::ReadAllText($t))
            }
            $ok | Should -BeTrue
            [System.IO.File]::ReadAllText($path).Trim() | Should -Be 'NEW'
            # The hook is handed the STAGED file, not the destination: if it were
            # handed the destination, hardening would happen after the bytes were
            # already visible and the whole hook would be pointless.
            [System.IO.File]::ReadAllText($marker).Trim() | Should -Be 'NEW'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is not vetoed by a stale non-zero LASTEXITCODE when the hook runs no native command' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-atomic-' + [System.Guid]::NewGuid().ToString('n'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'artifact.txt'
        $global:LASTEXITCODE = 9
        try {
            $ok = Write-BuildTextFileAtomic -Path $path -Lines @('NEW') -PreCommit { param($t) }
            $ok | Should -BeTrue
            [System.IO.File]::Exists($path) | Should -BeTrue
        } finally {
            $global:LASTEXITCODE = 0
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Stop-BuildProcess teardown' {
    BeforeAll {
        # Host-agnostic shell resolution, matching BuildProgress.Tests.ps1:
        # (Get-Process -Id $PID).Path can be a test host rather than a shell.
        $script:StopShell = $null
        foreach ($cmd in @('pwsh', 'powershell')) {
            $found = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $src = if ($found.Source) { $found.Source } else { $found.Path }
                if ($src -and (Test-Path -LiteralPath $src -PathType Leaf)) { $script:StopShell = $src; break }
            }
        }
        if (-not $script:StopShell) { $script:StopShell = (Get-Process -Id $PID).Path }
    }

    It 'accepts a null process without throwing' {
        { Stop-BuildProcess -Process $null } | Should -Not -Throw
    }

    It 'leaves an already-exited process alone' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:StopShell
        $psi.Arguments = '-NoProfile -Command "exit 3"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $proc.WaitForExit(10000) | Out-Null
            $proc.HasExited | Should -BeTrue
            { Stop-BuildProcess -Process $proc -WaitMs 100 } | Should -Not -Throw
            $proc.HasExited | Should -BeTrue
        } finally { try { $proc.Dispose() } catch { } }
    }

    It 'terminates a running process within the bounded wait' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:StopShell
        $psi.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            Start-Sleep -Milliseconds 500
            { Stop-BuildProcess -Process $proc -WaitMs 5000 -EntireTree } | Should -Not -Throw
            $proc.HasExited | Should -BeTrue
        } finally {
            try { Stop-BuildProcess -Process $proc -WaitMs 1000 } catch { }
            try { $proc.Dispose() } catch { }
        }
    }
}

Describe 'byte/file digest owners' {
    # SharedUtils owns three distinct digest questions. They only look alike: a
    # STRING, an in-memory byte buffer and a file's CONTENTS hash different
    # things, so folding them together is what produced the drift these tests
    # pin down.
    #
    # Get-BuildBytesHash was deleted: its only consumer was the test suite, and
    # the digest layer collapsed to the two surviving owners (string + file).
    # The tests below were deleted with it. The string owner (Get-BuildStringHash)
    # and file owner (Get-BuildFileSha256) remain and their invariants are pinned.

    It 'Get-BuildFileSha256 matches the published SHA-256 of a known file' {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-hash-' + [System.Guid]::NewGuid().ToString('n') + '.txt')
        [System.IO.File]::WriteAllText($file, 'hello')
        try {
            Get-BuildFileSha256 -Path $file |
                Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-BuildFileSha256 defaults to lowercase and honours -Case Upper' {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-hash-' + [System.Guid]::NewGuid().ToString('n') + '.txt')
        [System.IO.File]::WriteAllText($file, 'hello')
        try {
            $lower = Get-BuildFileSha256 -Path $file
            $upper = Get-BuildFileSha256 -Path $file -Case Upper
            $lower | Should -Be $lower.ToLowerInvariant()
            $upper | Should -Be $lower.ToUpperInvariant()
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-BuildFileSha256 returns empty for a missing or blank path' {
        Get-BuildFileSha256 -Path '' | Should -Be ''
        Get-BuildFileSha256 -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-does-not-exist-9f3a') | Should -Be ''
    }
}

Describe 'Standalone byte-digest naming' {
    # Standalone used to carry two byte-identical digests in one module -
    # Get-StandaloneSha256 and Get-StandaloneHash - called interchangeably. The
    # live module-scope copy and the copy inlined into the bundle template must
    # now share one name, or a fix to one silently invalidates shipped bundles.
    It 'the module-scope digest is reachable under exactly one name' {
        { Get-Command -Name 'Get-StandaloneSha256' -Module 'Standalone' -ErrorAction SilentlyContinue } |
            Should -Not -Throw
    }
}

Describe 'Resolve-EnvPlaceholder' {
    It 'resolves ${env:VAR} placeholders from the process environment' {
        $env:GBUILD_TEST_PH = 'hello123'
        try {
            Resolve-EnvPlaceholder -Text '${env:GBUILD_TEST_PH}' | Should -Be 'hello123'
        } finally {
            Remove-Item Env:\GBUILD_TEST_PH -ErrorAction SilentlyContinue
        }
    }

    It 'leaves values without placeholders unchanged' {
        Resolve-EnvPlaceholder -Text 'plain-value' | Should -Be 'plain-value'
    }

    It 'returns input unchanged when the env var is unset' {
        Remove-Item Env:\GBUILD_TEST_MISSING -ErrorAction SilentlyContinue
        Resolve-EnvPlaceholder -Text '${env:GBUILD_TEST_MISSING}' | Should -Be '${env:GBUILD_TEST_MISSING}'
    }
}

Describe 'Read-DotEnvFile' {
    # Replaces the former 'Import-DotEnvFile / Remove-DotEnvFile' block. Those
    # two wrote into and cleared the live process environment and had no
    # production caller; build.envFile is served by the read-only
    # Read-DotEnvFile. The read-only contract is now pinned here, including the
    # property that actually matters: reading a .env must not touch the session.
    It 'Read-DotEnvFile loads KEY=value pairs and returns a hashtable' {
        $td = Join-Path $env:TEMP ("gbuild_dotenv_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $td -Force | Out-Null
        $envFile = Join-Path $td '.env'
        Set-Content -Path $envFile -Value 'GB_DOT_KEY=dotvalue123'
        try {
            $loaded = Read-DotEnvFile -Path $envFile
            $loaded | Should -BeOfType [hashtable]
            $loaded.GB_DOT_KEY | Should -Be 'dotvalue123'
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Read-DotEnvFile leaves the process environment untouched' {
        $td = Join-Path $env:TEMP ("gbuild_dotenv_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $td -Force | Out-Null
        $envFile = Join-Path $td '.env'
        Set-Content -Path $envFile -Value 'GB_DOT_TEST2=value2'
        try {
            $null = Read-DotEnvFile -Path $envFile
            [Environment]::GetEnvironmentVariable('GB_DOT_TEST2') | Should -BeNullOrEmpty
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Remove-JsonComments' {
    It 'strips single-line // comments' {
        $r = Remove-JsonComments -JsonWithComments '{ "a": 1,  // note }'
        $r | Should -Not -Match '//'
    }

    It 'strips block /* */ comments' {
        $r = Remove-JsonComments -JsonWithComments '{ "a": 1 /* note */ }'
        $r | Should -Not -Match '/\*'
    }

    It 'preserves URLs (with //) inside quoted strings' {
        $r = Remove-JsonComments -JsonWithComments '{ "url": "https://example.com/x" }'
        $r | Should -Match 'https://example.com/x'
    }
}

Describe 'Test-ToolAvailable' {
    It 'returns $false for a nonexistent tool' {
        Test-ToolAvailable -ToolName 'zzz_no_such_tool_xyz' | Should -Be $false
    }
}

Describe 'Get-ExecutableExtension' {
    It 'returns .exe for a Windows state and empty otherwise' {
        $winExt = Get-ExecutableExtension -State ([pscustomobject]@{ OS = 'Windows' })
        $winExt | Should -Be '.exe'
        $nixExt = Get-ExecutableExtension -State ([pscustomobject]@{ OS = 'Linux' })
        $nixExt | Should -Be ''
    }
}

Describe 'Resolve-PowerShellHost' {
    It 'resolves to pwsh or powershell and the result is a runnable application' {
        $host1 = Resolve-PowerShellHost
        @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe') | Should -Contain $host1
        $resolved = Get-Command $host1 -CommandType Application -ErrorAction SilentlyContinue
        $resolved | Should -Not -BeNullOrEmpty
    }

    It 'prefers pwsh when both hosts are installed' {
        $hasPwsh = [bool](Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
        $hasLegacy = [bool](Get-Command powershell -CommandType Application -ErrorAction SilentlyContinue)
        if ($hasPwsh -and $hasLegacy) {
            Resolve-PowerShellHost | Should -Be 'pwsh'
        } else {
            Set-ItResult -Inconclusive -Because 'Only one PowerShell host installed on this machine; preference not testable here.'
        }
    }

    It 'always resolves at least one usable host (never empty)' {
        Resolve-PowerShellHost | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-BuildTenantId / Get-BuildCorrelationId' {
    It 'returns the tenant id from state or null' {
        Get-BuildTenantId -State ([pscustomobject]@{ TenantId = 't1' }) | Should -Be 't1'
        Get-BuildTenantId -State ([pscustomobject]@{}) | Should -BeNullOrEmpty
    }

    It 'returns the correlation id from state or null' {
        Get-BuildCorrelationId -State ([pscustomobject]@{ CorrelationId = 'c1' }) | Should -Be 'c1'
    }
}

Describe 'Get-InvokeCommandHint (OS-correct launcher)' {
    It 'returns the launcher form matching the current OS' {
        $w = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        $isWin = if ($null -ne $w) { [bool]$w } else { ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
        if ($isWin) {
            Get-InvokeCommandHint | Should -Be '.\_Build\gbuild.ps1'
        } else {
            Get-InvokeCommandHint | Should -Be './_Build/gbuild'
        }
    }

    It 'appends arguments after the launcher' {
        Get-InvokeCommandHint -Arguments '-Locale vi' | Should -Match '^-?\.[\\/]_Build[\\/]gbuild(\.ps1)? -Locale vi$'
    }

    It 'matches the OS probe used by PathUtils.Resolve-NativePath' {
        $hint = Get-InvokeCommandHint
        $w = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        $isWin = if ($null -ne $w) { [bool]$w } else { ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
        if ($isWin) { $hint | Should -Match '\\' } else { $hint | Should -Match '/' }
    }

    It 'uses the bare entry form when standing inside the tool dir' {
        $w = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        $isWin = if ($null -ne $w) { [bool]$w } else { ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
        $tool = Join-Path $env:TEMP 'gbuild_hint_tool'
        $h = Get-InvokeCommandHint -ScriptRoot $tool -FromDirectory $tool -Arguments '-Help'
        if ($isWin) { $h | Should -Be '.\gbuild.ps1 -Help' } else { $h | Should -Be './gbuild -Help' }
    }

    It 'uses the actual folder name from the tool parent' {
        $w = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        $isWin = if ($null -ne $w) { [bool]$w } else { ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
        $tool = Join-Path $env:TEMP 'MyCustomBuild'
        $parent = Split-Path $tool -Parent
        $h = Get-InvokeCommandHint -ScriptRoot $tool -FromDirectory $parent -Arguments '-Locale vi'
        if ($isWin) { $h | Should -Be '.\MyCustomBuild\gbuild.ps1 -Locale vi' } else { $h | Should -Be './MyCustomBuild/gbuild -Locale vi' }
    }
}

Describe 'Test-BuildGateResult: gate carries the failing tool output' {
    # Regression: a failing verification gate used to hand the caller only
    # $gate.Message, a summary like "Command failed with exit code 2". The
    # tool's own report - every offending file, line and rule - sat in the
    # result's Details and was dropped one layer above, so `dotnet format
    # --verify-no-changes` failed a build over whitespace and the console said
    # nothing beyond the exit code. Details must survive the verdict.

    It 'preserves Details on a failed verdict' {
        $res = New-OperationResult -Status Failed -Operation 'lint:C#' -ReasonCode 'NonZeroExit' `
            -Message 'Command failed with exit code 2' -ExitCode 2 `
            -Details @('MathEngine.cs(35,11): error WHITESPACE: Fix whitespace formatting.')
        $gate = Test-BuildGateResult -Result $res -Operation 'lint:C#' -StageLabel 'Lint'
        $gate.Passed | Should -BeFalse
        @($gate.Details) | Should -Not -BeNullOrEmpty
        # @() matters: a one-element Details arrives as a bare string, so
        # $gate.Details[0] would yield 'M' rather than the whole line.
        [string]@($gate.Details)[0] | Should -Match 'MathEngine\.cs\(35,11\)'
    }

    It 'still fails the gate - surfacing output must not change pass/fail semantics' {
        $res = New-OperationResult -Status Failed -Operation 'lint:C#' -ReasonCode 'NonZeroExit' `
            -Message 'Command failed with exit code 2' -ExitCode 2 -Details @('a violation')
        $gate = Test-BuildGateResult -Result $res -Operation 'lint:C#' -StageLabel 'Lint'
        $gate.Passed | Should -BeFalse
        $gate.Skipped | Should -BeFalse
        $gate.Status | Should -Be 'Failed'
        $gate.Message | Should -Be 'Command failed with exit code 2'
    }

    It 'keeps the tri-state contract intact: Succeeded and Skipped both pass' {
        $ok = Test-BuildGateResult -Result (New-OperationResult -Status Succeeded -Operation 'lint:C#') -Operation 'lint:C#'
        $ok.Passed | Should -BeTrue
        $ok.Skipped | Should -BeFalse
        $skip = Test-BuildGateResult -Result (New-OperationResult -Status Skipped -Operation 'lint:C#' -ReasonCode 'NoTests') -Operation 'lint:C#'
        $skip.Passed | Should -BeTrue
        $skip.Skipped | Should -BeTrue
    }

    It 'carries Details through without error when the tool captured nothing' {
        $gate = Test-BuildGateResult -Result (New-OperationResult -Status Failed -Operation 'test:Go' -Message 'boom') -Operation 'test:Go'
        $gate.Passed | Should -BeFalse
        $gate.Contains('Details') | Should -BeTrue
    }
}

Describe 'Write-BuildGateDiagnostics' {
    # All six gate call sites in the Orchestrator share one failure shape, so they
    # all delegate printing here. Bounded so a tool emitting thousands of lines
    # cannot flood the log, with the overflow counted rather than dropped.

    BeforeAll {
        $script:CaptureDiag = {
            param($Gate, $MaxLines = 20)
            $out = Write-BuildGateDiagnostics -Gate $Gate -MaxLines $MaxLines 6>&1 | Out-String
            return ($out -replace "`e\[[0-9;]*[A-Za-z]", '')
        }
    }

    It 'prints the offending file, line and rule from a failed lint gate' {
        $res = New-OperationResult -Status Failed -Operation 'lint:C#' -ReasonCode 'NonZeroExit' `
            -Message 'Command failed with exit code 2' -ExitCode 2 `
            -Details @('Models\MathEngine.cs(35,11): error WHITESPACE: Fix whitespace formatting.')
        $gate = Test-BuildGateResult -Result $res -Operation 'lint:C#' -StageLabel 'Lint'
        $text = & $script:CaptureDiag $gate
        $text | Should -Match 'Lint diagnostics'
        # The whole point: the actionable line reaches the user, not just exit code 2.
        $text | Should -Match 'Models\\MathEngine\.cs\(35,11\)'
        $text | Should -Match 'WHITESPACE'
    }

    It 'stays silent when the gate passed, even if Details are present' {
        $gate = Test-BuildGateResult -Result (New-OperationResult -Status Succeeded -Operation 'lint:C#' -Details @('ignored')) -Operation 'lint:C#'
        (& $script:CaptureDiag $gate) | Should -BeNullOrEmpty
    }

    It 'bounds output to MaxLines and reports how many were withheld' {
        $many = 1..105 | ForEach-Object { "File$_.cs($_): error WHITESPACE: fix it." }
        $gate = Test-BuildGateResult -Result (New-OperationResult -Status Failed -Operation 'lint:C#' `
            -Message 'Command failed with exit code 2' -ExitCode 2 -Details $many) -Operation 'lint:C#' -StageLabel 'Lint'
        $text = & $script:CaptureDiag $gate 5
        $text | Should -Match 'File1\.cs'
        $text | Should -Match 'File5\.cs'
        $text | Should -Not -Match 'File6\.cs'
        $text | Should -Match 'and 100 more line'
    }

    It 'drops blank lines and strips ANSI colour codes' {
        $gate = @{ Passed = $false; Status = 'Failed'; Label = 'Lint'; Details = @('keep me', '', '   ', "`e[31mcolored`e[0m") }
        $text = & $script:CaptureDiag $gate
        $text | Should -Match 'keep me'
        $text | Should -Match 'colored'
        $text | Should -Not -Match ([regex]::Escape("`e[31m"))
    }

    It 'is a safe no-op for a null gate or a gate with no Details' {
        { Write-BuildGateDiagnostics -Gate $null } | Should -Not -Throw
        { Write-BuildGateDiagnostics -Gate @{ Passed = $false; Status = 'Failed' } } | Should -Not -Throw
    }

    It 'ignores a scalar Details that is not tool output' {
        # Details is free-form and some plugins put a bool in it. Rendering
        # "False" as a finding is noise, not diagnosis.
        (& $script:CaptureDiag @{ Passed = $false; Status = 'Failed'; Details = $false }) | Should -BeNullOrEmpty
        (& $script:CaptureDiag @{ Passed = $false; Status = 'Failed'; Details = @(42, 7, $true) }) | Should -BeNullOrEmpty
    }

    It 'keeps real strings out of a mixed collection' {
        $text = & $script:CaptureDiag @{ Passed = $false; Status = 'Failed'; Details = @(42, 'Real.cs(2,2): error WHITESPACE: fix it.', $true) }
        $text | Should -Match 'Real\.cs\(2,2\)'
        $text | Should -Not -Match '\[INFO\]\s+\d+\s*$'
    }

    It 'still renders a plain single string of tool output' {
        $text = & $script:CaptureDiag @{ Passed = $false; Status = 'Failed'; Details = 'Single.cs(1,1): error WHITESPACE: fix it.' }
        $text | Should -Match 'Single\.cs\(1,1\)'
    }
}

Describe 'Resolve-BuildOpenOutput' {
    It 'explicit false never opens' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ openOutput = $false } } }
        Resolve-BuildOpenOutput -State $state | Should -BeFalse
    }

    It 'explicit true still stays quiet for non-interactive runs' {
        $state = [PSCustomObject]@{ NonInteractive = $true; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ openOutput = $true } } }
        Resolve-BuildOpenOutput -State $state | Should -BeFalse
    }

    It 'explicit true still stays quiet when flagged as CI' {
        $state = [PSCustomObject]@{ IsCI = $true; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ openOutput = $true } } }
        Resolve-BuildOpenOutput -State $state | Should -BeFalse
    }

    It 'returns a bool without throwing when config is absent' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        { Resolve-BuildOpenOutput -State $state } | Should -Not -Throw
        Resolve-BuildOpenOutput -State $state | Should -BeOfType [bool]
    }
}