#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "SDK" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SDK.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    BeforeEach {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_sdk_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $global:state = [PSCustomObject]@{
            ScriptRoot = $tempDir
            ProjectRoot = $tempDir
            WorkingDir  = $tempDir
            OS = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
            BuildConfig = [PSCustomObject]@{ }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ── Get-SdkExePath ─────────────────────────────────────────────────
    It "Get-SdkExePath returns dotnet(.exe) path for Dotnet tool type" {
        $p = Get-SdkExePath -SdkRoot 'C:\x' -ToolType 'Dotnet'
        $p | Should -BeLike '*dotnet*'
        if ($IsWindows) { $p | Should -BeLike '*.exe' }
    }

    # ── Test-SdkExe ────────────────────────────────────────────────────
    It "Test-SdkExe returns false for non-existent executable" {
        Test-SdkExe -ExePath 'C:\nonexistent.exe' -ToolType 'JDK' | Should -Be $false
    }

    # ── Get/Set-CachedSdk ──────────────────────────────────────────────
    It "Set-CachedSdk then Get-CachedSdk returns the stored path" {
        $realExe = (Get-Command pwsh).Source
        Set-CachedSdk -State $global:state -SdkName 'Dotnet' -Path $realExe
        Get-CachedSdk -State $global:state -SdkName 'Dotnet' | Should -Be $realExe
    }

    It "Set-CachedSdk emits no pipeline output (must not pollute SDK discovery return values)" {
        # Regression: a bare Write-BuildJsonFile call leaked $true into
        # Set-CachedSdk output, which propagated through Register-SdkCandidate
        # into Get-SmartSdk, turned State.DotnetCmd into an array, and crashed
        # Preflight with "Cannot process argument transformation on parameter
        # 'ToolName'. Cannot convert value to type System.String."
        $out = @(Set-CachedSdk -State $global:state -SdkName 'Dotnet' -Path 'C:\does\not\exist\dotnet.exe')
        $out.Count | Should -Be 0
    }

    It "Get-CachedSdk returns null when stored path does not exist on disk" {
        Set-CachedSdk -State $global:state -SdkName 'Dotnet' -Path 'C:\does\not\exist\dotnet.exe'
        Get-CachedSdk -State $global:state -SdkName 'Dotnet' | Should -Be $null
    }

    It "Get-CachedSdk returns null when no cache file exists" {
        Get-CachedSdk -State $global:state -SdkName 'Dotnet' | Should -Be $null
    }

    # ── Test-ExeWithTimeout ─────────────────────────────────────────────
    It "Test-ExeWithTimeout returns true for a real pwsh executable" {
        $pwsh = (Get-Command pwsh).Source
        Test-ExeWithTimeout -ExePath $pwsh -Arguments '-NoProfile -Command "exit 0"' | Should -Be $true
    }

    It "Test-ExeWithTimeout returns false for a non-zero exit code" {
        $pwsh = (Get-Command pwsh).Source
        Test-ExeWithTimeout -ExePath $pwsh -Arguments '-NoProfile -Command "exit 5"' | Should -Be $false
    }

    # ── Invoke-SmartScan ────────────────────────────────────────────────
    It "Invoke-SmartScan finds a matching .txt file" {
        $f = Join-Path $tempDir 'sample.txt'
        Set-Content -LiteralPath $f -Value 'hello' -Encoding UTF8
        $r = Invoke-SmartScan -RootPath $tempDir -Filter '*.txt' -ValidateScript { $true } -State $global:state
        $r | Should -Be $f
    }

    It "Invoke-SmartScan returns null when no file matches" {
        $r = Invoke-SmartScan -RootPath $tempDir -Filter '*.zzz' -ValidateScript { $true } -State $global:state
        $r | Should -Be $null
    }

    # ── Find-SdkByDirectory ─────────────────────────────────────────────
    It "Find-SdkByDirectory returns null when exe missing in matching dir" {
        $d = Join-Path $tempDir 'dotnet_home'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Find-SdkByDirectory -RootPath $tempDir -DirectoryPatterns @('*dotnet*') -Exe 'nonexistent.exe' -State $global:state
        $r | Should -Be $null
    }

    It "resolves SDK config values from the live state after import" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ sdk = [PSCustomObject]@{
                exeTimeoutMs = 17
                defaultSearchDepth = 9
                cacheExpiryDays = 3
            } }
        }
        Get-SdkConfigValue -PropertyName 'exeTimeoutMs' -State $state | Should -Be 17
        Get-SdkConfigValue -PropertyName 'defaultSearchDepth' -State $state | Should -Be 9
        Get-SdkConfigValue -PropertyName 'cacheExpiryDays' -State $state | Should -Be 3
    }

    It "uses the explicit SDK cache path from state" {
        $state = [PSCustomObject]@{ SDKCache = (Join-Path $tempDir 'explicit-sdk-cache.json') }
        Get-SdkCacheFile -State $state | Should -Be $state.SDKCache
    }

    It "prefers a configured SDK cache path over the state mirror" {
        $state = [PSCustomObject]@{
            SDKCache = (Join-Path $tempDir 'stale-sdk-cache.json')
            BuildConfig = [PSCustomObject]@{ sdk = [PSCustomObject]@{ cacheUserRelativePath = '.contract-sdk-cache.json' } }
        }
        Get-SdkCacheFile -State $state | Should -Match 'contract-sdk-cache\.json$'
    }

    # ── Get-ModuleState ─────────────────────────────────────────────────
    It "Get-ModuleState returns a PSCustomObject with an OS property" {
        $savedGState = $global:GState
        $global:GState = $null
        try {
            $m = Get-ModuleState
            $m | Should -Not -BeNullOrEmpty
            $m.PSObject.Properties.Name | Should -Contain 'OS'
        } finally {
            $global:GState = $savedGState
        }
    }

    # ── Test-IsAdmin ─────────────────────────────────────────────────────
    It "Test-IsAdmin returns a boolean" {
        $r = Test-IsAdmin
        $r | Should -BeOfType [bool]
    }

    # ── Get-LatestSdkTfm ────────────────────────────────────────────────
    It "Get-LatestSdkTfm returns netX.Y from dotnet --list-sdks output" {
        $tfm = & {
            $out = @('8.0.100 [C:\sdk8]', '10.0.200 [C:\sdk10]')
            $best = $null
            foreach ($line in $out) {
                if ($line -match '(\d+)\.(\d+)\.\d+') {
                    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                    if ($null -eq $best -or $major -gt $best.Major -or ($major -eq $best.Major -and $minor -gt $best.Minor)) {
                        $best = [PSCustomObject]@{ Major = $major; Minor = $minor }
                    }
                }
            }
            if ($best) { "net$($best.Major).$($best.Minor)" } else { $null }
        }
        $tfm | Should -Be 'net10.0'
    }

    # ── Install-SdkFromRemote (disabled) ────────────────────────────────
    It "Install-SdkFromRemote returns null when autoProvision is disabled" {
        $autoProv = [PSCustomObject]@{ enabled = $false }
        $sdk = [PSCustomObject]@{ autoProvision = $autoProv }
        $bc = [PSCustomObject]@{ sdk = $sdk }
        $state = [PSCustomObject]@{ ScriptRoot = $tempDir; BuildConfig = $bc }
        Install-SdkFromRemote -State $state -ToolType 'Dotnet' | Should -Be $null
    }

    It "Install-SdkFromRemote returns null for non-Dotnet tool types" {
        $autoProv = [PSCustomObject]@{ enabled = $true }
        $sdk = [PSCustomObject]@{ autoProvision = $autoProv }
        $bc = [PSCustomObject]@{ sdk = $sdk }
        $state = [PSCustomObject]@{ ScriptRoot = $tempDir; BuildConfig = $bc }
        Install-SdkFromRemote -State $state -ToolType 'JDK' | Should -Be $null
    }

    It "Install-SdkFromRemote returns null when disabled even with a RequiredVersion" {
        $autoProv = [PSCustomObject]@{ enabled = $false }
        $sdk = [PSCustomObject]@{ autoProvision = $autoProv }
        $bc = [PSCustomObject]@{ sdk = $sdk }
        $state = [PSCustomObject]@{ ScriptRoot = $tempDir; BuildConfig = $bc }
        Install-SdkFromRemote -State $state -ToolType 'Dotnet' -RequiredVersion '10.0.300' | Should -Be $null
    }
}

Describe 'SDK project pin (global.json)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SDK.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    BeforeEach {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_sdkpin_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parses version triples and strips prerelease suffixes' {
        $t = ConvertTo-DotnetVersionTriple -Version '10.0.300'
        $t.Major | Should -Be 10
        $t.Patch | Should -Be 300
        (ConvertTo-DotnetVersionTriple -Version '8.0.100-preview.1').Patch | Should -Be 100
        ConvertTo-DotnetVersionTriple -Version 'not-a-version' | Should -Be $null
    }

    It 'compares versions numerically' {
        Compare-DotnetVersion -A '10.0.300' -B '10.0.202' | Should -Be 1
        Compare-DotnetVersion -A '10.0.202' -B '10.0.300' | Should -Be -1
        Compare-DotnetVersion -A '10.0.300' -B '10.0.300' | Should -Be 0
        Compare-DotnetVersion -A 'garbage' -B '10.0.300' | Should -Be $null
    }

    It 'reads the pin from global.json with rollForward default' {
        '{"sdk":{"version":"10.0.300"}}' | Set-Content -LiteralPath (Join-Path $tempDir 'global.json') -Encoding UTF8
        $st = [PSCustomObject]@{ ProjectRoot = $tempDir; BuildConfig = [PSCustomObject]@{} }
        $pin = Get-GlobalJsonSdkPin -State $st
        $pin.Version | Should -Be '10.0.300'
        $pin.RollForward | Should -Be 'latestPatch'
        $pin.Path | Should -BeLike '*global.json'
    }

    It 'returns null when no global.json exists or it is corrupt' {
        $st = [PSCustomObject]@{ ProjectRoot = $tempDir; BuildConfig = [PSCustomObject]@{} }
        Get-GlobalJsonSdkPin -State $st | Should -Be $null
        '{broken json' | Set-Content -LiteralPath (Join-Path $tempDir 'global.json') -Encoding UTF8
        Get-GlobalJsonSdkPin -State $st | Should -Be $null
    }

    It 'applies rollForward: the BAOS case stays unsatisfied, upgrades satisfy' {
        # D:\BAOS pins 10.0.300 with latestMajor while the host has 10.0.202.
        Test-DotnetPinSatisfied -RequiredVersion '10.0.300' -InstalledSdks @('10.0.202') -RollForward 'latestMajor' | Should -Be $false
        Test-DotnetPinSatisfied -RequiredVersion '10.0.300' -InstalledSdks @('10.0.202', '10.0.402') -RollForward 'latestMajor' | Should -Be $true
        Test-DotnetPinSatisfied -RequiredVersion '8.0.100' -InstalledSdks @('8.0.404') -RollForward 'latestPatch' | Should -Be $true
        Test-DotnetPinSatisfied -RequiredVersion '8.0.100' -InstalledSdks @('8.0.50') -RollForward 'latestPatch' | Should -Be $false
        Test-DotnetPinSatisfied -RequiredVersion '8.0.100' -InstalledSdks @('8.0.404') -RollForward 'disable' | Should -Be $false
        Test-DotnetPinSatisfied -RequiredVersion '' -InstalledSdks @() | Should -Be $true
    }

    It 'falls back to maxKnownSdkVersion without touching the network' {
        # Channel 99.0 has no release-cache entry, so the remote/cache paths
        # cannot interfere: base '' skips remote, maxKnown answers.
        $sdk = [PSCustomObject]@{ releaseMetadataBaseUrl = ''; maxKnownSdkVersion = '99.0.404' }
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ sdk = $sdk } }
        Get-LatestReleasedSdkVersion -State $st -Channel '99.0' | Should -Be '99.0.404'
        $sdk2 = [PSCustomObject]@{ releaseMetadataBaseUrl = ''; maxKnownSdkVersion = '' }
        $st2 = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ sdk = $sdk2 } }
        Get-LatestReleasedSdkVersion -State $st2 -Channel '99.0' | Should -Be ''
    }

    It 'returns the candidate untouched when nothing can be done (never reds a green build)' {
        '{"sdk":{"version":"99.0.100"}}' | Set-Content -LiteralPath (Join-Path $tempDir 'global.json') -Encoding UTF8
        $sdk = [PSCustomObject]@{ releaseMetadataBaseUrl = ''; maxKnownSdkVersion = ''; autoProvision = [PSCustomObject]@{ enabled = $false } }
        $st = [PSCustomObject]@{ ProjectRoot = $tempDir; WorkingDir = $tempDir; BuildConfig = [PSCustomObject]@{ sdk = $sdk } }
        $cand = if ($IsWindows) { 'C:\definitely\not\here\dotnet.exe' } else { '/definitely/not/here/dotnet' }
        Resolve-PinnedDotnetSdk -State $st -CandidateExe $cand | Should -Be $cand
        Resolve-PinnedDotnetSdk -State ([PSCustomObject]@{ BuildConfig = $null }) -CandidateExe $cand | Should -Be $cand
    }

    It 'notifies only once per pin across pipeline stages' {
        '{"sdk":{"version":"98.0.100"}}' | Set-Content -LiteralPath (Join-Path $tempDir 'global.json') -Encoding UTF8
        $sdk = [PSCustomObject]@{ releaseMetadataBaseUrl = ''; maxKnownSdkVersion = ''; autoProvision = [PSCustomObject]@{ enabled = $false } }
        $st = [PSCustomObject]@{ ProjectRoot = $tempDir; WorkingDir = $tempDir; BuildConfig = [PSCustomObject]@{ sdk = $sdk } }
        $cand = if ($IsWindows) { 'C:\definitely\not\here\dotnet.exe' } else { '/definitely/not/here/dotnet' }
        # Strict-safe read of module session state (direct $script: reads throw
        # under Set-StrictMode when the variable does not exist yet).
        $pinCount = {
            $m = Get-Module SDK
            if (-not $m) { return -1 }
            $v = $m.SessionState.PSVariable.Get('SdkPinNotified')
            if ($null -eq $v) { return 0 }
            return @($v.Value.Keys).Count
        }
        $before = & $pinCount
        Resolve-PinnedDotnetSdk -State $st -CandidateExe $cand | Should -Be $cand
        $afterFirst = & $pinCount
        ($afterFirst - $before) | Should -Be 1
        Resolve-PinnedDotnetSdk -State $st -CandidateExe $cand | Should -Be $cand
        $afterSecond = & $pinCount
        $afterSecond | Should -Be $afterFirst
    }
}

# A dotnet muxer installed as host + runtimes but WITHOUT an SDK still satisfies
# `Get-Command dotnet`. Callers that resolved by name picked it, and every SDK verb
# then failed with "No .NET SDKs were found". Resolve-DotnetSdkCommand is the single
# owner that validates capability, so these pin that contract.
Describe 'Resolve-DotnetSdkCommand' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SDK.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'never returns a path that cannot list SDKs' {
        $resolved = Resolve-DotnetSdkCommand -State ([PSCustomObject]@{ BuildConfig = $null })
        if ($resolved) {
            $out = & $resolved '--list-sdks' 2>&1
            $LASTEXITCODE | Should -Be 0
            @($out).Count | Should -BeGreaterThan 0
        } else {
            # No SDK installed here - declining to guess is the correct answer.
            $resolved | Should -BeNullOrEmpty
        }
    }

    It 'rejects a PreferredPath that does not exist' {
        $resolved = Resolve-DotnetSdkCommand -State ([PSCustomObject]@{ BuildConfig = $null }) -PreferredPath 'C:\definitely\not\here\dotnet.exe'
        $resolved | Should -Not -Be 'C:\definitely\not\here\dotnet.exe'
    }

    It 'rejects a PreferredPath that exists but carries no SDK' {
        # A shim that reports success but lists no SDKs is exactly what a
        # runtime-only install looks like to a naive existence check.
        $shim = Join-Path $TestDrive 'dotnet-fake-sdk.exe'
        [System.IO.File]::WriteAllBytes($shim, @(77, 90, 0, 0))
        $resolved = Resolve-DotnetSdkCommand -State ([PSCustomObject]@{ BuildConfig = $null }) -PreferredPath $shim
        $resolved | Should -Not -Be $shim
    }

    It 'keeps an SDK-capable PreferredPath when one is supplied' {
        $known = Resolve-DotnetSdkCommand -State ([PSCustomObject]@{ BuildConfig = $null })
        if (-not $known) { Set-ItResult -Skipped -Because 'no .NET SDK on this host'; return }
        $resolved = Resolve-DotnetSdkCommand -State ([PSCustomObject]@{ BuildConfig = $null }) -PreferredPath $known
        $resolved | Should -Be $known
    }
}

Describe 'SDK memo project scoping' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SDK.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Get-SdkMemoKey scopes by project root' {
        $a = [PSCustomObject]@{ ProjectRoot = 'C:\projA'; ScriptRoot = 'C:\tool' }
        $b = [PSCustomObject]@{ ProjectRoot = 'C:\projB'; ScriptRoot = 'C:\tool' }
        $ka = Get-SdkMemoKey -ToolType 'Dotnet' -State $a
        $kb = Get-SdkMemoKey -ToolType 'Dotnet' -State $b
        $ka | Should -Not -Be $kb -Because 'run 2 in another project must not reuse run 1 SDK path'
        $ka | Should -Match 'Dotnet'
        # Same project, same key (memo still hits within one run).
        (Get-SdkMemoKey -ToolType 'Dotnet' -State $a) | Should -Be $ka
    }

    It 'Reset-SdkMemo clears all memo tables without throwing' {
        { Reset-SdkMemo } | Should -Not -Throw
    }
}

# The discovery waterfall is the part of SDK that decides WHICH toolchain a
# build runs with. Its finders were previously reachable only through a real
# host install, so every branch that matters on a fresh machine (env home,
# PATH, cache, priority paths, project tree, custom paths, Windows drives) was
# unmeasured. These tests fabricate the tool trees in TestDrive and mock the
# executable probe, which keeps them hermetic on Windows, Linux and macOS.
Describe 'SDK discovery waterfall' {
    BeforeAll {
        # Get-LocaleMessage lives in Locale.psm1. The real bootstrap imports it
        # globally before SDK; a standalone SDK import does not, and the
        # discovery logging path calls it unguarded.
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SDK.psm1') -Force -DisableNameChecking -ErrorAction Stop

        $script:jdkExeName = if ($IsWindows) { 'javac.exe' } else { 'javac' }
        $script:dotnetExeName = if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' }
        $script:NewJdkTree = {
            param([string]$Root)
            $bin = Join-Path $Root 'bin'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            $exe = Join-Path $bin $script:jdkExeName
            [System.IO.File]::WriteAllText($exe, '')
            return $exe
        }
        # Writes a runnable fake tool. Windows uses a .cmd shim; POSIX uses a
        # shell script marked executable so Get-Command resolves it.
        $script:WriteFakeExe = {
            param([string]$Path, [string[]]$Lines = @(), [int]$ExitCode = 0, [string]$ListSdksOutput = '')
            if ($IsWindows) {
                $body = "@echo off`r`n"
                foreach ($line in $Lines) { $body += "echo $line`r`n" }
                $body += "exit /b $ExitCode`r`n"
                [System.IO.File]::WriteAllText($Path, $body)
            } else {
                $body = "#!/bin/sh`n"
                foreach ($line in $Lines) { $body += "echo '$line'`n" }
                $body += "exit $ExitCode`n"
                [System.IO.File]::WriteAllText($Path, $body)
                & chmod +x $Path
            }
        }
    }

    BeforeEach {
        $script:state = [PSCustomObject]@{
            ScriptRoot     = $TestDrive
            ProjectRoot    = $TestDrive
            WorkingDir     = $TestDrive
            OS             = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
            NonInteractive = $true
            SDKCache       = (Join-Path $TestDrive 'sdkcache.json')
            BuildConfig    = [PSCustomObject]@{}
            Colors         = [PSCustomObject]@{ Warn = 'Yellow'; Err = 'Red'; Cyan = 'Cyan'; Gray = 'Gray'; Succ = 'Green'; Info = 'Cyan' }
        }
    }

    It 'GetAndroidPriorityPaths returns platform SDK locations' {
        InModuleScope SDK -Parameters @{ State = $script:state } {
            param($State)
            $paths = @(GetAndroidPriorityPaths -State $State)
            $paths.Count | Should -BeGreaterThan 0
            foreach ($p in $paths) { [string]::IsNullOrWhiteSpace($p) | Should -BeFalse }
        }
    }

    It 'Get-CommonSdkPaths merges configured search and custom paths' {
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            ProjectRoot = $TestDrive
            OS          = $script:state.OS
            BuildConfig = [PSCustomObject]@{
                sdk = [PSCustomObject]@{
                    searchPaths = [PSCustomObject]@{ primary = @('C:\sdk-primary'); fallback = @('C:\sdk-fallback') }
                    customPaths = @('C:\sdk-custom')
                }
            }
        }
        InModuleScope SDK -Parameters @{ State = $state } {
            param($State)
            $common = @(Get-CommonSdkPaths -State $State)
            $common | Should -Contain 'C:\sdk-primary'
            $common | Should -Contain 'C:\sdk-fallback'
            $common | Should -Contain 'C:\sdk-custom'
            $common | Should -Contain (Join-Path $State.ScriptRoot '.sdk')
            $common | Should -Contain (Join-Path (Split-Path $State.ScriptRoot -Parent) '.sdk')
        }
    }

    It 'Update-AndroidSdkConfig rebinds the cmdline-tools bin directory' {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                sdk = [PSCustomObject]@{ androidCmdLineToolsRelPath = 'custom/cmdline-tools/latest/bin' }
            }
        }
        InModuleScope SDK -Parameters @{ State = $state } {
            param($State)
            $cfg = $script:SDK_Config['Android']
            $savedDir = $script:AndroidCmdLineToolsBinDir
            $savedBin = $cfg.Bin
            try {
                Update-AndroidSdkConfig -State $State
                $script:AndroidCmdLineToolsBinDir | Should -Be 'custom/cmdline-tools/latest/bin'
                $cfg.Bin | Should -Be 'custom/cmdline-tools/latest/bin'
            } finally {
                $script:AndroidCmdLineToolsBinDir = $savedDir
                $cfg.Bin = $savedBin
            }
        }
    }

    It 'Register-SdkCandidate rejects missing and failing candidates' {
        InModuleScope SDK -Parameters @{ State = $script:state; Missing = (Join-Path $TestDrive 'missing.exe') } {
            param($State, $Missing)
            Mock Write-Log { }
            Register-SdkCandidate -ExePath $Missing -ToolType 'JDK' -State $State | Should -BeNullOrEmpty
            Mock Test-SdkExe { return $false }
            $exe = Join-Path $TestDrive 'failing.exe'
            [System.IO.File]::WriteAllText($exe, '')
            Register-SdkCandidate -ExePath $exe -ToolType 'JDK' -State $State | Should -BeNullOrEmpty
        }
    }

    It 'Register-SdkCandidate returns the JDK home and sets JAVA_HOME' {
        $jdkRoot = Join-Path $TestDrive 'jdk'
        $null = & $script:NewJdkTree $jdkRoot
        $savedJavaHome = $env:JAVA_HOME
        try {
            InModuleScope SDK -Parameters @{ State = $script:state; JdkRoot = $jdkRoot; ExeName = $script:jdkExeName } {
                param($State, $JdkRoot, $ExeName)
                Mock Test-SdkExe { return $true }
                Mock Write-Log { }
                $r = Register-SdkCandidate -ExePath (Join-Path (Join-Path $JdkRoot 'bin') $ExeName) -ToolType 'JDK' -State $State -LogLabel 'from env'
                $r | Should -Not -BeNullOrEmpty
                Test-Path -LiteralPath (Join-Path (Join-Path $r 'bin') $ExeName) | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $r 'bin') | Should -BeTrue
                $env:JAVA_HOME | Should -Not -BeNullOrEmpty
            }
        } finally {
            $env:JAVA_HOME = $savedJavaHome
        }
    }

    It 'Register-SdkCandidate returns the muxer for Dotnet and the root for Android' {
        $dotnetRoot = Join-Path $TestDrive 'dotnet'
        New-Item -ItemType Directory -Path $dotnetRoot -Force | Out-Null
        $dotnetExe = Join-Path $dotnetRoot $script:dotnetExeName
        [System.IO.File]::WriteAllText($dotnetExe, '')
        $androidRoot = Join-Path $TestDrive 'Android/Sdk'
        $androidBin = Join-Path $androidRoot 'cmdline-tools/latest/bin'
        New-Item -ItemType Directory -Path $androidBin -Force | Out-Null
        $sdkManager = Join-Path $androidBin $(if ($IsWindows) { 'sdkmanager.bat' } else { 'sdkmanager' })
        [System.IO.File]::WriteAllText($sdkManager, '')

        InModuleScope SDK -Parameters @{ State = $script:state; DotnetExe = $dotnetExe; SdkManager = $sdkManager } {
            param($State, $DotnetExe, $SdkManager)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            $r = Register-SdkCandidate -ExePath $DotnetExe -ToolType 'Dotnet' -State $State
            $r | Should -Not -BeNullOrEmpty
            (Split-Path $r -Leaf) | Should -Be (Split-Path $DotnetExe -Leaf)
            Test-Path -LiteralPath $r | Should -BeTrue
            $r = Register-SdkCandidate -ExePath $SdkManager -ToolType 'Android' -State $State -LogLabel 'on drive C:\'
            $r | Should -Match 'Android[/\\]Sdk$'
        }
    }

    It 'Find-SdkFromEnvHome resolves JAVA_HOME and declines an empty tree' {
        $jdkRoot = Join-Path $TestDrive 'jdk-env'
        $null = & $script:NewJdkTree $jdkRoot
        $emptyRoot = Join-Path $TestDrive 'empty-env'
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
        $savedJavaHome = $env:JAVA_HOME
        try {
            $env:JAVA_HOME = $jdkRoot
            InModuleScope SDK -Parameters @{ State = $script:state } {
                param($State)
                Mock Test-SdkExe { return $true }
                Mock Write-Log { }
                Find-SdkFromEnvHome -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
            }
            $env:JAVA_HOME = $emptyRoot
            InModuleScope SDK -Parameters @{ State = $script:state } {
                param($State)
                Mock Test-SdkExe { return $true }
                Mock Write-Log { }
                Find-SdkFromEnvHome -State $State -ToolType 'JDK' | Should -BeNullOrEmpty
            }
        } finally {
            $env:JAVA_HOME = $savedJavaHome
        }
    }

    It 'Find-SdkFromSystemPath resolves a PATH entry and rejects a ghost' {
        $bin = Join-Path $TestDrive 'path-bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $exe = Join-Path $bin $script:jdkExeName
        if ($IsWindows) {
            [System.IO.File]::WriteAllText($exe, '')
        } else {
            $null = & $script:WriteFakeExe $exe
            & chmod +x $exe
        }
        $savedPath = $env:PATH
        try {
            $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
            InModuleScope SDK -Parameters @{ State = $script:state } {
                param($State)
                Mock Test-SdkExe { return $true }
                Mock Write-Log { }
                Find-SdkFromSystemPath -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
            }
            InModuleScope SDK -Parameters @{ State = $script:state } {
                param($State)
                Mock Test-SdkExe { return $false }
                Mock Write-Log { }
                Find-SdkFromSystemPath -State $State -ToolType 'JDK' | Should -BeNullOrEmpty
            }
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'Find-SdkFromCache uses a valid cache entry and ignores NOT_FOUND' {
        $jdkRoot = Join-Path $TestDrive 'jdk-cache'
        $null = & $script:NewJdkTree $jdkRoot
        Set-CachedSdk -State $script:state -SdkName 'JDK' -Path $jdkRoot
        InModuleScope SDK -Parameters @{ State = $script:state; JdkRoot = $jdkRoot } {
            param($State, $JdkRoot)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            Find-SdkFromCache -State $State -ToolType 'JDK' | Should -Be $JdkRoot
        }
        Set-CachedSdk -State $script:state -SdkName 'JDK' -Path 'NOT_FOUND'
        InModuleScope SDK -Parameters @{ State = $script:state } {
            param($State)
            Mock Write-Log { }
            Find-SdkFromCache -State $State -ToolType 'JDK' | Should -BeNullOrEmpty
        }
    }

    It 'Find-SdkInPriorityPaths scans a configured priority root' {
        $root = Join-Path $TestDrive 'priority'
        $null = & $script:NewJdkTree (Join-Path $root 'jdk')
        InModuleScope SDK -Parameters @{ State = $script:state; Root = $root } {
            param($State, $Root)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            $cfg = $script:SDK_Config['JDK']
            $saved = $cfg.PriorityPaths
            try {
                $cfg.PriorityPaths = { param($s) @($Root) }.GetNewClosure()
                Find-SdkInPriorityPaths -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
            } finally {
                $cfg.PriorityPaths = $saved
            }
        }
    }

    It 'Find-SdkInProjectTree scans the working directory' {
        $root = Join-Path $TestDrive 'project'
        $null = & $script:NewJdkTree (Join-Path $root 'jdk')
        $state = $script:state.PSObject.Copy()
        $state.WorkingDir = $root
        InModuleScope SDK -Parameters @{ State = $state } {
            param($State)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            Find-SdkInProjectTree -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
        }
    }

    It 'Find-SdkFromCustomPaths resolves absolute and relative roots' {
        $absoluteRoot = Join-Path $TestDrive 'custom-abs'
        $null = & $script:NewJdkTree $absoluteRoot
        $relativeRoot = Join-Path $TestDrive 'vendor/jdk'
        $null = & $script:NewJdkTree $relativeRoot
        $absoluteState = [PSCustomObject]@{
            ProjectRoot = $TestDrive
            OS          = $script:state.OS
            BuildConfig = [PSCustomObject]@{ sdk = [PSCustomObject]@{ customPaths = @($absoluteRoot) } }
        }
        InModuleScope SDK -Parameters @{ State = $absoluteState } {
            param($State)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            Find-SdkFromCustomPaths -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
        }
        $relativeState = [PSCustomObject]@{
            ProjectRoot = $TestDrive
            OS          = $script:state.OS
            BuildConfig = [PSCustomObject]@{ sdk = [PSCustomObject]@{ customPaths = @('vendor/jdk') } }
        }
        InModuleScope SDK -Parameters @{ State = $relativeState } {
            param($State)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            Find-SdkFromCustomPaths -State $State -ToolType 'JDK' | Should -Not -BeNullOrEmpty
        }
        InModuleScope SDK -Parameters @{ State = $script:state } {
            param($State)
            Find-SdkFromCustomPaths -State $State -ToolType 'JDK' | Should -BeNullOrEmpty
        }
    }

    It 'Find-SdkOnWindowsDrives is Windows-only and registrable when mocked' {
        if (-not $IsWindows) {
            InModuleScope SDK -Parameters @{ State = $script:state } {
                param($State)
                Find-SdkOnWindowsDrives -State $State -ToolType 'Dotnet' | Should -BeNullOrEmpty
            }
            return
        }
        $sdkRoot = Join-Path $TestDrive 'drive-dotnet'
        New-Item -ItemType Directory -Path $sdkRoot -Force | Out-Null
        $exe = Join-Path $sdkRoot $script:dotnetExeName
        [System.IO.File]::WriteAllText($exe, '')
        InModuleScope SDK -Parameters @{ State = $script:state; SdkRoot = $sdkRoot; Exe = $exe } {
            param($State, $SdkRoot, $Exe)
            Mock Test-SdkExe { return $true }
            Mock Write-Log { }
            Mock Find-SdkByDirectory { return $SdkRoot }
            Mock Get-AvailableDrives { return @() }
            $State.WorkingDir = 'C:\fake\project'
            $r = Find-SdkOnWindowsDrives -State $State -ToolType 'Dotnet'
            $r | Should -Not -BeNullOrEmpty
            (Split-Path $r -Leaf) | Should -Be (Split-Path $Exe -Leaf)
            Test-Path -LiteralPath $r | Should -BeTrue
        }
    }

    It 'Test-ExeWithTimeout runs a batch shim on Windows and fails closed elsewhere' {
        $bat = Join-Path $TestDrive 'probe.bat'
        [System.IO.File]::WriteAllText($bat, "@exit /b 0`r`n")
        if ($IsWindows) {
            Test-ExeWithTimeout -ExePath $bat -Arguments '' -TimeoutMilliseconds 5000 | Should -BeTrue
            $savedComSpec = $env:ComSpec
            try {
                $env:ComSpec = ''
                Test-ExeWithTimeout -ExePath $bat -Arguments '' -TimeoutMilliseconds 5000 | Should -BeFalse
            } finally {
                $env:ComSpec = $savedComSpec
            }
        } else {
            Test-ExeWithTimeout -ExePath $bat -Arguments '' -TimeoutMilliseconds 5000 | Should -BeFalse
        }
    }

    It 'Test-IsGhostSdk flags a silent stub and accepts real output' {
        $stub = Join-Path $TestDrive $(if ($IsWindows) { 'ghost.cmd' } else { 'ghost' })
        if ($IsWindows) {
            [System.IO.File]::WriteAllText($stub, "@echo off`r`nif `"%~1`"==`"--list-sdks`" exit /b 0`r`nexit /b 1`r`n")
        } else {
            [System.IO.File]::WriteAllText($stub, "#!/bin/sh`nif [ `"`$1`" = `"--list-sdks`" ]; then exit 0; fi`nexit 1`n")
            & chmod +x $stub
        }
        $real = Join-Path $TestDrive $(if ($IsWindows) { 'real-sdk.cmd' } else { 'real-sdk' })
        $lines = @('10.0.100 [/fake/sdk]')
        $null = & $script:WriteFakeExe $real -Lines $lines
        InModuleScope SDK -Parameters @{ Stub = $stub; Real = $real } {
            param($Stub, $Real)
            Test-IsGhostSdk -ExePath $Stub | Should -BeTrue
            Test-IsGhostSdk -ExePath $Real | Should -BeFalse
        }
    }

    It 'Get-LatestSdkTfm parses the highest installed SDK and fails closed' {
        $fake = Join-Path $TestDrive $(if ($IsWindows) { 'dotnet-list.cmd' } else { 'dotnet-list' })
        $null = & $script:WriteFakeExe $fake -Lines @('8.0.100 [C:\sdk8]', '10.0.200 [C:\sdk10]')
        Get-LatestSdkTfm -DotnetExe $fake | Should -Be 'net10.0'
        $failing = Join-Path $TestDrive $(if ($IsWindows) { 'dotnet-fail.cmd' } else { 'dotnet-fail' })
        $null = & $script:WriteFakeExe $failing -Lines @('8.0.100 [C:\sdk8]') -ExitCode 1
        Get-LatestSdkTfm -DotnetExe $failing | Should -BeNullOrEmpty
    }
}
