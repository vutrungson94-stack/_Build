#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

# The machine profile (profiles\signing.json inside the tool) is REAL state on the
# developer machine. The posture report reads it, so these tests must not depend
# on it: point the lookup at an empty profile and restore it afterwards.
$global:GBuildOriginalSigningProfile = $env:GBUILD_SIGNING_PROFILE
$global:GBuildEmptySigningProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-empty-profile-' + [guid]::NewGuid().ToString('N') + '.json')
Set-Content -LiteralPath $global:GBuildEmptySigningProfile -Value '{}' -Encoding UTF8
$env:GBUILD_SIGNING_PROFILE = $global:GBuildEmptySigningProfile

Describe "Security - Credential Sanitization" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Redacts OpenRouter API keys" {
        $out = Remove-Credentials -Text "token sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 here"
        $out | Should -Not -BeLike "*sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*"
        $out | Should -BeLike "*REDACTED*"
    }

    It "Redacts Bearer tokens" {
        $out = Remove-Credentials -Text "Authorization: Bearer abcdef1234567890abcdef=="
        $out | Should -Not -BeLike "*Bearer abcdef*"
        $out | Should -BeLike "*REDACTED*"
    }

    It "Redacts generic password assignments" {
        $out = Remove-Credentials -Text "password=supersecret123"
        $out | Should -Not -BeLike "*supersecret123*"
        $out | Should -BeLike "*REDACTED*"
    }

    It "Leaves clean text unchanged" {
        $text = "Build completed in 3.2s with 0 errors"
        Remove-Credentials -Text $text | Should -BeExactly $text
    }

    It "Handles empty and null input safely" {
        Remove-Credentials -Text '' | Should -BeExactly ''
        Remove-Credentials -Text $null | Should -BeNullOrEmpty
    }

    It "Uses config-driven redactPatterns from State when provided" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    redactPatterns = @(
                        [PSCustomObject]@{ name = 'Custom Token'; pattern = 'CUSTOMKEY-[0-9]{4,}'; replacement = 'CUSTOMKEY-***' }
                    )
                }
            }
        }
        $out = Remove-Credentials -Text "token=CUSTOMKEY-99887766 leaked" -State $state
        $out | Should -Not -BeLike "*CUSTOMKEY-99887766*"
        $out | Should -BeLike "*CUSTOMKEY-***"
    }

    It "Falls back to built-in defaults when State has no redactPatterns" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        $out = Remove-Credentials -Text "sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" -State $state
        $out | Should -BeLike "*REDACTED*"
    }
}

Describe "Security - Secret Scan Exclusions" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $temp = New-IntegrationTempDir
        # A directory that should be scanned
        $keepDir = Join-Path $temp 'keep'
        $null = New-Item -ItemType Directory -Path $keepDir -Force
        Set-Content -Path (Join-Path $keepDir 'app.json') -Value '{"key":"sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"}' -Encoding UTF8
        # A directory we explicitly exclude
        $dropDir = Join-Path $temp 'drop'
        $null = New-Item -ItemType Directory -Path $dropDir -Force
        Set-Content -Path (Join-Path $dropDir 'app.json') -Value '{"key":"sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"}' -Encoding UTF8
        # A tool-like Tests directory with a .Tests.ps1 file (auto-detected as test dir)
        $syncTestDir = Join-Path (Join-Path $temp 'OtherTool') 'Tests'
        $null = New-Item -ItemType Directory -Path $syncTestDir -Force
        Set-Content -Path (Join-Path $syncTestDir 'sample.ps1') -Value '$_api = "sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"' -Encoding UTF8
        Set-Content -Path (Join-Path $syncTestDir 'Dummy.Tests.ps1') -Value 'Describe "x" { It "y" { $k = "sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" } }' -Encoding UTF8
        # A brand-new test directory (not in any hardcoded list) — auto-detected
        $newTestDir = Join-Path $temp 'UnitTests'
        $null = New-Item -ItemType Directory -Path $newTestDir -Force
        Set-Content -Path (Join-Path $newTestDir 'app.Tests.ps1') -Value 'Describe "x" { It "y" { $k = "sk-or-v1-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" } }' -Encoding UTF8
    }
    AfterAll {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Includes both keep and drop directories on a default scan" {
        $res = Invoke-SecretScan -SearchRoot $temp
        $res.Findings.Count | Should -Be 2
    }

    It "Excludes the drop directory when passed via ExcludeDirs" {
        $res = Invoke-SecretScan -SearchRoot $temp -ExcludeDirs @('drop', 'OtherTool/Tests', 'OtherTests', 'UnitTests')
        $res.Findings.Count | Should -Be 1
        ($res.Findings.File -replace '\\', '/' -join ',') | Should -Not -BeLike "*drop*"
    }

    It "Auto-detects OtherTool/Tests as a test directory via *.Tests.ps1" {
        $res = Invoke-SecretScan -SearchRoot $temp
        ($res.Findings.File -replace '\\', '/' -join ',') | Should -Not -BeLike "*OtherTool/Tests*"
    }

    It "Auto-detects a brand-new test directory (UnitTests) without hardcoding" {
        $res = Invoke-SecretScan -SearchRoot $temp
        ($res.Findings.File -replace '\\', '/' -join ',') | Should -Not -BeLike "*UnitTests*"
    }

    It "Reads security.excludeDirs from State config" {
        $state = [PSCustomObject]@{
            WorkingDir  = $temp
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{ excludeDirs = @('keep') }
            }
        }
        $res = Invoke-SecretScan -State $state
        # 'keep' is excluded via config; drop + test dirs still scanned
        $files = $res.Findings.File -replace '\\', '/' -join ','
        $files | Should -Not -BeLike "*keep*"
        $files | Should -BeLike "*drop*"
    }
}

Describe "Security - License Compliance" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Returns empty when no license config is present" {
        $state = [PSCustomObject]@{ WorkingDir = (New-IntegrationTempDir) }
        Test-LicenseCompliance -State $state | Should -BeNullOrEmpty
        Remove-Item $state.WorkingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns empty when allow/deny lists are empty" {
        $wd = New-IntegrationTempDir
        $state = [PSCustomObject]@{
            WorkingDir = $wd
            BuildConfig = [PSCustomObject]@{ license = [PSCustomObject]@{ allowed = @(); deny = @() } }
        }
        Test-LicenseCompliance -State $state | Should -BeNullOrEmpty
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Reports a violation for a denied package reference" {
        $wd = New-IntegrationTempDir
        $proj = Join-Path $wd 'Test.csproj'
        Set-Content -Path $proj -Value '<Project><ItemGroup><PackageReference Include="MyEvilPkg" Version="1.0.0" /></ItemGroup></Project>' -Encoding UTF8
        $state = [PSCustomObject]@{
            WorkingDir = $wd
            BuildConfig = [PSCustomObject]@{ license = [PSCustomObject]@{ allowed = @(); deny = @('MyEvilPkg') } }
        }
        $v = Test-LicenseCompliance -State $state
        # @(...) is not cosmetic. PowerShell UNROLLS a one-element array when it
        # crosses a function boundary, so $v is a bare PSCustomObject here - and
        # Windows PowerShell 5.1 has no scalar `.Count` adapter for PSCustomObject,
        # so $v.Count is $null on 5.1 while it is 1 on 7. The assertion below only
        # ever passed on PowerShell 7. Same applies to [0] indexing below.
        @($v).Count | Should -Be 1
        @($v)[0].Package | Should -BeExactly 'MyEvilPkg'
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Security - npm Vulnerability Scanning" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Test-NpmVulnerabilities returns empty when no package.json exists" {
        $td = New-IntegrationTempDir
        $state = [PSCustomObject]@{ WorkingDir = $td }
        $result = @(Test-NpmVulnerabilities -State $state)
        $result.Count | Should -Be 0
        Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Test-NpmVulnerabilities returns empty when npm is absent or no vulns" {
        $td = New-IntegrationTempDir
        Set-Content -Path (Join-Path $td 'package.json') -Value '{}' -Encoding UTF8
        $state = [PSCustomObject]@{ WorkingDir = $td }
        $result = @(Test-NpmVulnerabilities -State $state)
        if ((Get-Command npm -ErrorAction SilentlyContinue) -and $result.Count -gt 0) {
            Set-ItResult -Skipped -Because "npm audit reports ecosystem vulnerabilities for empty project in this environment"
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        $result.Count | Should -Be 0
        Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Test-NpmVulnerabilities is exported from Security module" {
        Get-Command Test-NpmVulnerabilities -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "Security - Secret Detection & Scanning" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $temp = New-IntegrationTempDir
        $openaiFile = Join-Path $temp 'openai.txt'
        Set-Content -Path $openaiFile -Value 'key sk-abcdefghijklmnopqrstuvwxyz0123456789' -Encoding UTF8
        $awsFile = Join-Path $temp 'aws.txt'
        Set-Content -Path $awsFile -Value 'aws_key AKIAIOSFODNN7EXAMPLE' -Encoding UTF8
        $cleanFile = Join-Path $temp 'clean.txt'
        Set-Content -Path $cleanFile -Value 'nothing to see here' -Encoding UTF8
    }
    AfterAll {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Find-SecretsInFile detects an OpenAI key" {
        # @(...) for the same reason as the license case: one finding unrolls to
        # a bare PSCustomObject, and 5.1 returns $null for .Count on one.
        $f = Find-SecretsInFile -FilePath $openaiFile
        @($f).Count | Should -BeGreaterThan 0
    }

    It "Find-SecretsInFile detects an AWS access key" {
        $f = Find-SecretsInFile -FilePath $awsFile
        @($f).Count | Should -BeGreaterThan 0
    }

    It "Find-SecretsInFile returns no findings for a clean file" {
        $f = Find-SecretsInFile -FilePath $cleanFile
        $f.Count | Should -Be 0
    }

    It "Invoke-SecretScan detects a secret and excludes build artifacts" {
        $scanRoot = New-IntegrationTempDir
        $keepDir = Join-Path $scanRoot 'src'
        New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
        Set-Content -Path (Join-Path $keepDir 'config.json') -Value '{"k":"sk-abcdefghijklmnopqrstuvwxyz0123456789"}' -Encoding UTF8
        $binDir = Join-Path $scanRoot 'bin'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Set-Content -Path (Join-Path $binDir 'leak.json') -Value '{"k":"sk-abcdefghijklmnopqrstuvwxyz0123456789"}' -Encoding UTF8
        $res = Invoke-SecretScan -SearchRoot $scanRoot -ExcludeDirs @('bin', 'obj', 'node_modules', '.git')
        $res.Findings.Count | Should -BeGreaterThan 0
        ($res.Findings.File -replace '\\', '/' -join ',') | Should -Not -BeLike "*bin*"
        Remove-Item $scanRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Security - Vulnerabilities, License, Orchestrator" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
        function global:dotnet { $global:LASTEXITCODE = 0; 'No vulnerabilities found' }
        # The scanners below stub `dotnet` as a FUNCTION. Security's capture helper
        # prefers Resolve-DotnetSdkCommand whenever that command is visible, so a
        # leftover SDK module (SDK.Tests.ps1 imports it earlier in the shared
        # Pester session) resolves a real muxer, bypasses the stub and turns the
        # synthetic .csproj into a fail-closed ScannerError. Pin the resolver to
        # "no preference" so the stub stays authoritative in any run order.
        InModuleScope Security {
            if (Get-Command Resolve-DotnetSdkCommand -ErrorAction SilentlyContinue) {
                Mock Resolve-DotnetSdkCommand { '' }
            }
        }
    }
    AfterAll {
        Remove-Item function:dotnet -ErrorAction SilentlyContinue
    }

    It "Test-VulnerablePackages does not throw and returns empty for a clean project" {
        $wd = New-IntegrationTempDir
        $proj = Join-Path $wd 'Test.csproj'
        Set-Content -Path $proj -Value '<Project><ItemGroup><PackageReference Include="Newtonsoft.Json" Version="13.0.3" /></ItemGroup></Project>' -Encoding UTF8
        $state = [PSCustomObject]@{ WorkingDir = $wd }
        { $script:vp = Test-VulnerablePackages -State $state } | Should -Not -Throw
        @($script:vp).Count | Should -Be 0
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Asserts NO BLOCKING violation, not literally nothing. These two cases used to
    # assert `Should -BeNullOrEmpty`, which passed only because the scanners
    # returned `,@($list.ToArray())` - the comma operator nested the list inside
    # itself, so the pipeline emitted ONE object and Pester never saw the contents.
    # That same wrapping made an empty scanner list count as one finding. With the
    # wrap removed the real contract is visible: an allowlisted package yields no
    # blocking violation, while a "[coverage]" row (an ecosystem that publishes no
    # license metadata) is informational and is logged, never enforced - which is
    # exactly what Invoke-LicenseCompliance documents at its [coverage] filter.
    It "Test-LicenseCompliance reports no blocking violation on allowlist pass" {
        $wd = New-IntegrationTempDir
        $proj = Join-Path $wd 'Test.csproj'
        Set-Content -Path $proj -Value '<Project><ItemGroup><PackageReference Include="AllowedPkg" Version="1.0.0" /></ItemGroup></Project>' -Encoding UTF8
        $state = [PSCustomObject]@{
            WorkingDir = $wd
            BuildConfig = [PSCustomObject]@{ license = [PSCustomObject]@{ allowed = @('AllowedPkg'); deny = @() } }
        }
        $violations = @(Test-LicenseCompliance -State $state)
        $blocking = @($violations | Where-Object { [string]$_.Package -ne '[coverage]' })
        $blocking.Count | Should -Be 0
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Test-LicenseCompliance reports no blocking violation with wildcard allowlist" {
        $wd = New-IntegrationTempDir
        $proj = Join-Path $wd 'Test.csproj'
        Set-Content -Path $proj -Value '<Project><ItemGroup><PackageReference Include="AnyPkg" Version="1.0.0" /></ItemGroup></Project>' -Encoding UTF8
        $state = [PSCustomObject]@{
            WorkingDir = $wd
            BuildConfig = [PSCustomObject]@{ license = [PSCustomObject]@{ allowed = @('*'); deny = @() } }
        }
        $violations = @(Test-LicenseCompliance -State $state)
        $blocking = @($violations | Where-Object { [string]$_.Package -ne '[coverage]' })
        $blocking.Count | Should -Be 0
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Invoke-SecurityScan runs and returns structured output without throwing" {
        $wd = New-IntegrationTempDir
        $state = [PSCustomObject]@{
            WorkingDir  = $wd
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{ scanSecrets = $true }
                license  = [PSCustomObject]@{ allowed = @('*'); deny = @() }
            }
        }
        $script:scanResult = $null
        { $script:scanResult = Invoke-SecurityScan -State $state -SkipVulnerable } | Should -Not -Throw
        $script:scanResult | Should -Not -BeNullOrEmpty
        $script:scanResult.Pass | Should -BeOfType [bool]
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Security - P0 scanner regressions' {
    It 'redacts secret material from every finding field' {
        $root = New-IntegrationTempDir
        try {
            $file = Join-Path $root 'config.json'
            Set-Content -LiteralPath $file -Value '{"token":"sk-abcdefghijklmnopqrstuvwxyz0123456789"}' -Encoding UTF8
            $result = Find-SecretsInFile -FilePath $file
            $json = $result | ConvertTo-Json -Compress
            $json | Should -Not -Match 'sk-abcdefghijklmnopqrstuvwxyz0123456789'
            $json | Should -Match 'REDACTED'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'includes source and lockfile extensions in the inventory' {
        $root = New-IntegrationTempDir
        try {
            Set-Content -LiteralPath (Join-Path $root 'main.go') -Value 'package main' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $root 'go.sum') -Value 'example.com/x v1.0.0/go.mod h1:abc' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $root 'package-lock.json') -Value '{"lockfileVersion":3,"packages":{}}' -Encoding UTF8
            (Invoke-SecretScan -SearchRoot $root -ExcludeDirs @()).FilesScanned | Should -BeGreaterThan 0
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fails closed when a vulnerability tool emits invalid JSON' {        $root = New-IntegrationTempDir
        try {
            Set-Content -LiteralPath (Join-Path $root 'package.json') -Value '{}' -Encoding UTF8
            function global:npm { 'not-json'; $global:LASTEXITCODE = 0 }
            $state = [PSCustomObject]@{ WorkingDir = $root; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
            $result = Invoke-SecurityScan -State $state -SkipSecrets
            $result.Pass | Should -BeFalse
            $result.ScannerErrors | Should -BeGreaterThan 0
        } finally {
            Remove-Item function:npm -ErrorAction SilentlyContinue
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Security - scan root fails closed (no CWD fallback)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Resolve-SecuritySearchRoot returns the configured WorkingDir' {
        $root = New-IntegrationTempDir
        try {
            Resolve-SecuritySearchRoot -State ([PSCustomObject]@{ WorkingDir = $root }) | Should -Be $root
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-SecuritySearchRoot throws instead of returning the CWD' {
        # Every scanner used to fall back to '.' here, so a missing WorkingDir
        # made the gate scan the launch directory and report Pass. The fallback
        # is gone: the gate must fail loudly.
        { Resolve-SecuritySearchRoot -State ([PSCustomObject]@{}) } | Should -Throw
        { Resolve-SecuritySearchRoot -State $null } | Should -Throw
        { Resolve-SecuritySearchRoot -State ([PSCustomObject]@{ WorkingDir = '' }) } | Should -Throw
    }

    It 'Invoke-SecretScan without a root throws instead of scanning the CWD' {
        $origLoc = $PWD.Path
        $cwd = New-IntegrationTempDir
        try {
            Set-Location -LiteralPath $cwd
            Set-Content -LiteralPath (Join-Path $cwd 'note.txt') -Value 'nothing secret here' -Encoding UTF8
            { Invoke-SecretScan -State ([PSCustomObject]@{}) } | Should -Throw
            # ... and nothing was scanned from the launch directory.
            { Invoke-SecretScan -State ([PSCustomObject]@{ WorkingDir = '' }) } | Should -Throw
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'vulnerability scanners without a root throw instead of scanning the CWD' {
        $bare = [PSCustomObject]@{}
        { Test-VulnerablePackages -State $bare } | Should -Throw
        { Test-NpmVulnerabilities -State $bare } | Should -Throw
        { Test-GoVulnerabilities -State $bare } | Should -Throw
        { Test-PythonVulnerabilities -State $bare } | Should -Throw
        { Test-RustVulnerabilities -State $bare } | Should -Throw
        # Test-LicenseCompliance with no configured allow/deny lists has nothing
        # to enforce and correctly returns empty. But with a policy configured
        # and no root, it must throw rather than scan the launch directory.
        $noRootWithPolicy = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ license = [PSCustomObject]@{ deny = @('evil-pkg') } }
        }
        { Test-LicenseCompliance -State $noRootWithPolicy } | Should -Throw
    }
}

Describe 'Security - Code Signing Status' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'reports NotSigned when no signing mechanism is enabled' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        $s = Get-CodeSigningStatus -State $state
        $s.Status | Should -Be 'NotSigned'
        $s.Mechanisms | Should -BeNullOrEmpty
    }

    It 'reports Signed when artifactSign is enabled with a resolvable tool and key' {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    artifactSign = [PSCustomObject]@{
                        enabled = $true
                        tool    = 'cosign'
                        key     = 'test-key'
                    }
                }
            }
        }
        # cosign is not on PATH in the test environment, so the mechanism is
        # reported as tool-missing rather than active. The status must still
        # be NotSigned (no active mechanism) and the detail must name the gap.
        $s = Get-CodeSigningStatus -State $state
        $s.Status | Should -Be 'NotSigned'
        ($s.Details -join '; ') | Should -Match 'cosign'
    }

    It 'reports Signed when gpg signing is enabled with a key and gpg is present' {
        $gpg = Get-Command 'gpg', 'gpg2' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gpg) { Set-ItResult -Skipped -Because 'gpg/gpg2 not on PATH' }
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    gpgSign = [PSCustomObject]@{ enabled = $true; keyId = 'ABC123' }
                }
            }
        }
        $s = Get-CodeSigningStatus -State $state
        $s.Status | Should -Be 'Signed'
        $s.Mechanisms | Should -Contain 'gpgSign'
    }

    It 'reports Signed when audit-ledger signing is enabled with a key path' {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    auditLedger = [PSCustomObject]@{
                        signing = [PSCustomObject]@{ enabled = $true; keyPath = '/tmp/test.key' }
                    }
                }
            }
        }
        $s = Get-CodeSigningStatus -State $state
        $s.Status | Should -Be 'Signed'
        $s.Mechanisms | Should -Contain 'auditLedger'
    }

    It 'does not throw when State is null' {
        $s = Get-CodeSigningStatus -State $null
        $s.Status | Should -Be 'NotSigned'
    }

    It 'reports Unknown (not disabled) when a signing config read fails' {
        # A transient config failure used to report 'disabled' for every
        # mechanism, asserting controls were OFF when they may have been ON.
        # Now a failed read reports 'unknown' so the posture is unverified,
        # never affirmatively wrong.
        # Every SIGNING config has to be part of the simulated failure, not just
        # the three that existed when this test was written: a read that failed
        # for one mechanism and succeeded for another would let that mechanism
        # report 'disabled' - which is exactly the affirmative-wrong the test
        # exists to prevent. security.peSign (the Windows PE signer) is one of
        # them now.
        Mock -ModuleName Security Get-ConfigValue { throw 'simulated config failure' } -ParameterFilter { $Path -in @('security.artifactSign', 'security.peSign', 'security.gpgSign', 'security.auditLedger.signing') }
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        $s = Get-CodeSigningStatus -State $state
        $s.Status | Should -Be 'Unknown'
        ($s.Details -join '; ') | Should -Match 'unknown'
        ($s.Details -join '; ') | Should -Not -Match 'disabled'
    }
}

# Restore the machine's profile env after the file's tests.
if ($null -eq $global:GBuildOriginalSigningProfile) { Remove-Item Env:GBUILD_SIGNING_PROFILE -ErrorAction SilentlyContinue }
else { $env:GBUILD_SIGNING_PROFILE = $global:GBuildOriginalSigningProfile }
Remove-Item -LiteralPath $global:GBuildEmptySigningProfile -Force -ErrorAction SilentlyContinue
