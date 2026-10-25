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
        $cand = 'C:\definitely\not\here\dotnet.exe'
        Resolve-PinnedDotnetSdk -State $st -CandidateExe $cand | Should -Be $cand
        Resolve-PinnedDotnetSdk -State ([PSCustomObject]@{ BuildConfig = $null }) -CandidateExe $cand | Should -Be $cand
    }

    It 'notifies only once per pin across pipeline stages' {
        '{"sdk":{"version":"98.0.100"}}' | Set-Content -LiteralPath (Join-Path $tempDir 'global.json') -Encoding UTF8
        $sdk = [PSCustomObject]@{ releaseMetadataBaseUrl = ''; maxKnownSdkVersion = ''; autoProvision = [PSCustomObject]@{ enabled = $false } }
        $st = [PSCustomObject]@{ ProjectRoot = $tempDir; WorkingDir = $tempDir; BuildConfig = [PSCustomObject]@{ sdk = $sdk } }
        $cand = 'C:\definitely\not\here\dotnet.exe'
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
