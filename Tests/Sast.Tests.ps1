#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Sast.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "SAST (multi-language, Level 5)" {
    It "Get-SastConfig returns $null when State has no sast section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        Get-SastConfig -State $state | Should -BeNullOrEmpty
    }

    It "Get-SastConfig reads the security.sast section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ enabled = $true } } } }
        $cfg = Get-SastConfig -State $state
        $cfg.enabled | Should -BeTrue
    }

    It "Get-SastToolMap has mappings for the primary languages" {
        $state = [PSCustomObject]@{ BuildConfig = $null }
        $map = Get-SastToolMap -State $state
        $map['C#'] | Should -Be 'dotnet'
        $map['Python'] | Should -Be 'bandit'
        $map['Go'] | Should -Be 'gosec'
        $map['PowerShell'] | Should -Be 'psscriptanalyzer'
    }

    It "Get-SastToolMap allows override via the config tools" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ tools = [PSCustomObject]@{ Python = 'ruff' } } } } }
        $map = Get-SastToolMap -State $state
        $map['Python'] | Should -Be 'ruff'
        $map['C#'] | Should -Be 'dotnet'
    }

    It "Get-SastCommand returns the correct command per language" {
        $state = [PSCustomObject]@{ BuildConfig = $null }
        $cmd = Get-SastCommand -Language 'Python' -State $state
        $cmd.Tool | Should -Be 'bandit'
        $cmd.Args -join ' ' | Should -Match '-r'
        $cmd.Args -join ' ' | Should -Match '-f json'
        $cmd = Get-SastCommand -Language 'C#' -State $state
        $cmd.Tool | Should -Be 'dotnet'
    }

    It "Get-SastCommand returns $null for a language with no mapping" {
        $state = [PSCustomObject]@{ BuildConfig = $null }
        Get-SastCommand -Language 'Klingon' -State $state | Should -BeNullOrEmpty
    }

    It "ConvertTo-SastFindings parse output npm audit JSON" {
        $npm = @'
{
  "vulnerabilities": {
    "lodash": { "severity": "high", "via": ["GHSA-xxxx"] },
    "minimist": { "severity": "critical", "via": ["GHSA-yyyy"] }
  }
}
'@
        $findings = ConvertTo-SastFindings -Tool 'npm' -Output $npm -Language 'Node.js'
        $findings.Count | Should -Be 2
        ($findings | Where-Object { $_.Message -eq 'lodash' }).Severity | Should -Be 'high'
        ($findings | Where-Object { $_.Message -eq 'minimist' }).Severity | Should -Be 'critical'
    }

    It "ConvertTo-SastFindings parse output bandit JSON" {
        $bandit = @'
{
  "results": [
    { "issue_severity": "HIGH", "test_id": "B608", "filename": "app.py", "line_number": 12, "issue_text": "hardcoded password" }
  ]
}
'@
        $findings = ConvertTo-SastFindings -Tool 'bandit' -Output $bandit -Language 'Python'
        $findings.Count | Should -Be 1
        $findings[0].Rule | Should -Be 'B608'
        $findings[0].File | Should -Be 'app.py'
    }

    It "ConvertTo-SastFindings collapses raw output into one aggregate finding for unknown tools" {
        $findings = ConvertTo-SastFindings -Tool 'cppcheck' -Output "error: something bad" -Language 'C/C++'
        $findings.Count | Should -Be 1
        $findings[0].Message | Should -Match 'something bad'
    }

    It "Invoke-SastTool returns Skipped with a typed reason when the tool is not installed" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ tools = [PSCustomObject]@{ Python = 'bandit-definitely-not-installed-xyz' } } } } }
        $r = Invoke-SastTool -Language 'Python' -ProjectDir $TestDrive -State $state
        $r.Status | Should -Be 'Skipped'
        $r.ReasonCode | Should -Be 'ToolUnavailable'
        $r.Reason | Should -Match 'unavailable'
    }

    It "Invoke-SastScan says which scanner could not run instead of only a finding count" {
        # The gate closed as "Blocked (findings=0)" when a scanner was missing, so
        # the report could not tell "found something" from "scanned nothing".
        $state = [PSCustomObject]@{
            ScriptRoot  = (Split-Path -Parent $PSScriptRoot)
            ProjectRoot = $TestDrive
            BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{
                enabled = $true
                tools   = [PSCustomObject]@{ Python = 'bandit-definitely-not-installed-xyz' }
            } } }
        }
        Set-Content -LiteralPath (Join-Path $TestDrive 'app.py') -Value 'print(1)' -Encoding UTF8
        $r = Invoke-SastScan -State $state -ProjectDir $TestDrive
        $r.Pass | Should -BeFalse
        $r.Reason | Should -Match 'unavailable'
        $r.UnavailableTools | Should -Not -BeNullOrEmpty
    }

    It "Invoke-SastScan does not run a scanner the project has no input for" {
        # npm audit cannot report anything without a lockfile. Treating that as a
        # tool failure blocked a lockfile-free project on a findings=0 verdict.
        $state = [PSCustomObject]@{
            ScriptRoot  = (Split-Path -Parent $PSScriptRoot)
            ProjectRoot = $TestDrive
            BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{
                enabled = $true
                tools   = [PSCustomObject]@{ 'Node.js' = 'npm' }
            } } }
        }
        Set-Content -LiteralPath (Join-Path $TestDrive 'package.json') -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
        $r = Invoke-SastTool -Language 'Node.js' -ProjectDir $TestDrive -State $state
        $r.Status | Should -Be 'Skipped'
        $r.ReasonCode | Should -Be 'ToolInputMissing'
        $r.Reason | Should -Match 'package-lock\.json'
    }

    It "treats a non-zero npm exit code as findings, not as a tool failure" {
        # npm audit exits 1 whenever it found anything. Reading that as a tool
        # failure discarded the vulnerability list (findings=0) and blocked.
        $state = [PSCustomObject]@{ BuildConfig = $null }
        $r = Invoke-SastTool -Language 'Node.js' -ProjectDir $TestDrive -State $state
        $r.Status | Should -Not -Be 'Failed'
        $r.Reason | Should -Not -Match 'Tool exited with code'
    }

    It "surfaces npm's own failure text instead of a bare 'returned an error'" {
        $payload = '{"error":{"code":"ENOLOCK","summary":"This command requires an existing lockfile."}}'
        { ConvertTo-SastFindings -Tool 'npm' -Output $payload -Language 'Node.js' } |
            Should -Throw -ExpectedMessage '*requires an existing lockfile*'
    }

    It "Invoke-SastTool returns Skipped when the language is not mapped" {
        $state = [PSCustomObject]@{ BuildConfig = $null }
        $r = Invoke-SastTool -Language 'Klingon' -ProjectDir $TestDrive -State $state
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'No SAST tool'
    }

    It "Get-SastTimeoutSec returns config value when set" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ timeoutSec = 45 } } } }
        Get-SastTimeoutSec -State $state | Should -Be 45
    }

    It "Get-SastTimeoutSec defaults to 120 when absent" {
        $state = [PSCustomObject]@{ BuildConfig = $null }
        Get-SastTimeoutSec -State $state | Should -Be 120
    }

    It "Get-SastTimeoutSec honors 0 (timeout disabled)" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ timeoutSec = 0 } } } }
        Get-SastTimeoutSec -State $state | Should -Be 0
    }

    It "Invoke-SastScan returns Skipped when security.sast.enabled=false" {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ enabled = $false } } } }
        $r = Invoke-SastScan -State $state -ProjectDir $TestDrive
        $r.Status | Should -Be 'Skipped'
        $r.Pass | Should -BeTrue
    }

    It "Invoke-SastScan has no errors when config is missing" {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ } }
        $r = Invoke-SastScan -State $state -ProjectDir $TestDrive
        $r.Pass | Should -BeTrue
        $r.Status | Should -Be 'Skipped'
    }
}

Describe 'SAST - P0 execution regressions' {
    It 'discovers and evaluates multiple project languages' {
        $root = Join-Path $TestDrive 'multi-language'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'app.py') -Value 'print(1)' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'app.go') -Value 'package main' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $root; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ enabled = $true; toolUnavailablePolicy = 'skip'; tools = [PSCustomObject]@{ Python = 'missing-python'; Go = 'missing-go' } } } } }
        $result = Invoke-SastScan -State $state -ProjectDir $root
        $result.Checks.Count | Should -BeGreaterThan 1
        $result.Pass | Should -BeTrue
    }
    It 'rejects malformed structured tool output' {
        { ConvertTo-SastFindings -Tool npm -Output '{bad' -Language Node.js } | Should -Throw
    }
}

# These guards used to live only in Steps/vulnerability-scan.ps1 - a standalone
# manual utility that no pipeline step ever invoked - so they protected a path
# that never ran. Sast is the wired owner and now carries them, so they are
# regression-tested here on the path that actually executes.
Describe 'SAST - scan root confinement (P0)' {
    It 'rejects a scan root outside the build roots' {
        $inside = Join-Path $TestDrive 'inside'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $inside, $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'app.py') -Value 'print(1)' -Encoding UTF8
        $state = [PSCustomObject]@{
            ProjectRoot = $inside
            WorkingDir  = $inside
            BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ enabled = $true } } }
        }
        $result = Invoke-SastScan -State $state -ProjectDir $outside
        $result.Pass | Should -BeFalse
        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Match 'containment'
    }
    It 'rejects a scan root that traverses a reparse point' -Skip:(-not (Test-IsWindowsHost)) {
        $root = Join-Path $TestDrive 'junction-root'
        $target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $root, $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'app.py') -Value 'print(1)' -Encoding UTF8
        $link = Join-Path $root 'linked'
        # mklink /J needs no elevation; skip quietly if the host forbids it.
        & cmd.exe /c "mklink /J `"$link`" `"$target`"" 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'could not create a directory junction on this host'; return }
        try {
            $state = [PSCustomObject]@{
                ProjectRoot = $root
                WorkingDir  = $root
                BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sast = [PSCustomObject]@{ enabled = $true } } }
            }
            $result = Invoke-SastScan -State $state -ProjectDir $link
            $result.Pass | Should -BeFalse
            $result.Reason | Should -Match 'reparse'
        } finally {
            & cmd.exe /c "rmdir `"$link`"" 2>$null | Out-Null
        }
    }
    It 'PathUtils.Test-NoReparsePointInPath accepts a plain path and rejects a junction' -Skip:(-not (Test-IsWindowsHost)) {
        $plain = Join-Path $TestDrive 'plain-path'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $plain 'x.txt') -Value 'x' -Encoding UTF8
        Test-NoReparsePointInPath -Path $plain | Should -BeTrue
        Test-NoReparsePointInPath -Path (Join-Path $plain 'x.txt') | Should -BeTrue
        Test-NoReparsePointInPath -Path '' | Should -BeFalse
        $t2 = Join-Path $TestDrive 'pt-target'
        New-Item -ItemType Directory -Path $t2 -Force | Out-Null
        $l2 = Join-Path $TestDrive 'pt-link'
        & cmd.exe /c "mklink /J `"$l2`" `"$t2`"" 2>$null | Out-Null
        if (Test-Path -LiteralPath $l2) {
            try { Test-NoReparsePointInPath -Path $l2 | Should -BeFalse }
            finally { & cmd.exe /c "rmdir `"$l2`"" 2>$null | Out-Null }
        }
    }
}

# A dotnet muxer can be installed as host + runtimes with NO SDK. `Get-Command
# dotnet` succeeds for it, so the vulnerability audit - an SDK verb - resolved to
# it, failed with "No .NET SDKs were found", and the step then blocked the build
# reporting findings=0. These pin the resolution and the zero-finding contract.
Describe 'SAST - dotnet scanner resolution (SDK-capable muxer only)' {
    It 'never reports an SDK-less muxer as available for the dotnet audit' {
        # Whichever muxer Resolve-SastToolPath picks, it must be able to list SDKs.
        $path = Resolve-SastToolPath -Tool 'dotnet' -State ([PSCustomObject]@{ BuildConfig = $null })
        if ($path) {
            $out = & $path '--list-sdks' 2>&1
            $LASTEXITCODE | Should -Be 0
            @($out).Count | Should -BeGreaterThan 0
        } else {
            # No SDK on this machine: reporting unavailable is the correct answer.
            $path | Should -BeNullOrEmpty
        }
    }

    It 'reports a nonexistent scanner as unavailable' {
        Test-SastToolAvailable -Tool 'bandit-definitely-not-installed-xyz' -State ([PSCustomObject]@{ BuildConfig = $null }) | Should -BeFalse
    }

    It 'does not fall back to a PATH muxer when State points at a broken one' {
        $brokenPath = if ($IsWindows) { 'C:\definitely\not\here\dotnet.exe' } else { '/definitely/not/here/dotnet' }
        $state = [PSCustomObject]@{
            BuildConfig = $null
            DotnetCmd   = $brokenPath
        }
        $path = Resolve-SastToolPath -Tool 'dotnet' -State $state
        $path | Should -Not -Be $brokenPath
        if ($path) {
            $out = & $path '--list-sdks' 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe 'SAST - zero findings must stay zero (no phantom finding)' {
    # `return ,@($list.ToArray())` wraps the array so the pipeline does not unroll
    # it, but for an EMPTY list that emits one empty array as a single item. A
    # clean project then counted 1 finding, reported a blank severity-less entry
    # and flipped the scan from Passed to Warned.
    It 'returns zero findings for a clean dotnet audit report' {
        $out = 'Determining projects to restore...' + "`n" +
               'The following sources were used:' + "`n" +
               'https://api.nuget.org/v3/index.json' + "`n" +
               'The given project `LamToanLop1` has no vulnerable packages given the current sources.'
        $findings = @(ConvertTo-SastFindings -Tool 'dotnet' -Output $out -Language 'C#')
        $findings.Count | Should -Be 0
    }

    It 'still reports real advisories' {
        $out = 'Package  Version  Severity  Advisory' + "`n" +
               'Newtonsoft.Json  12.0.1  high  GHSA-abcd-1234-efgh'
        $findings = @(ConvertTo-SastFindings -Tool 'dotnet' -Output $out -Language 'C#')
        $findings.Count | Should -Be 1
        $findings[0].Rule | Should -Be 'GHSA-abcd-1234-efgh'
    }

    It 'surfaces what the tool actually said when the output is unrecognised' {
        # Previously a bare "unrecognized dotnet output" was swallowed by the
        # caller's catch and re-reported as "SAST parser or tool failed", so a
        # missing SDK looked like a parser bug.
        $msg = $null
        try { ConvertTo-SastFindings -Tool 'dotnet' -Output 'No .NET SDKs were found.' -Language 'C#' | Out-Null }
        catch { $msg = [string]$_.Exception.Message }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Match 'No \.NET SDKs were found'
    }

    It 'returns zero findings for an unknown tool that reports only whitespace' {
        # The unknown-tool fallback branch is the one place a scanner can produce
        # an empty list while still being recognised, so it needs the same guard.
        @(ConvertTo-SastFindings -Tool 'cppcheck' -Output "   `r`n  " -Language 'C/C++').Count | Should -Be 0
    }
}

Describe 'SAST - fixture files must not declare project languages' {
    # A lone Go-default.go template under a tool fixture is not a Go project, but the
    # extension walk counted it as one - so a pure C#/Blazor repo demanded
    # bandit, gosec, cargo-audit, maven and bundler, and the fail-closed tool
    # policy blocked the build for scanners the project never needed.
    BeforeAll {
        $global:sastFixture = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_sast_fixture_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $global:sastFixture -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $global:sastFixture 'package.json') -Value '{"name":"app"}'
        $fx = Join-Path $global:sastFixture 'FixtureTool/Tools/.mktest/templates'
        New-Item -ItemType Directory -Path $fx -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fx 'Go-default.go') -Value 'package main'
        Set-Content -LiteralPath (Join-Path $fx 'Java-default.java') -Value 'class A {}'
        Set-Content -LiteralPath (Join-Path $fx 'Rust-default.rs') -Value 'fn main() {}'
        Set-Content -LiteralPath (Join-Path $fx 'Ruby-default.rb') -Value 'puts 1'
    }
    AfterAll {
        Remove-Item $global:sastFixture -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ignores extension-only evidence under test and fixture directories' {
        $langs = @(Get-SastProjectLanguages -ProjectDir $global:sastFixture -State ([PSCustomObject]@{ BuildConfig = $null }))
        $langs | Should -Not -Contain 'Go'
        $langs | Should -Not -Contain 'Java'
        $langs | Should -Not -Contain 'Rust'
        $langs | Should -Not -Contain 'Ruby'
        $langs | Should -Not -Contain 'Python'
        $langs | Should -Contain 'Node.js'
    }

    It 'still counts manifest evidence anywhere (a test csproj is still C#)' {
        $dir = Join-Path $global:sastFixture 'FixtureTool/Helpers/Analyzer.CSharp'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Analyzer.CSharp.csproj') -Value '<Project></Project>'
        try {
            $langs = @(Get-SastProjectLanguages -ProjectDir $global:sastFixture -State ([PSCustomObject]@{ BuildConfig = $null }))
            $langs | Should -Contain 'C#'
        } finally {
            Remove-Item (Join-Path $global:sastFixture 'FixtureTool') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'SAST - PSScriptAnalyzer findings map 1:1 (no table-text blob)' {
    It 'maps native severities to the finding scale' {
        $records = @(
            [PSCustomObject]@{ RuleName = 'PSAvoidUsingCmdletAliases'; Severity = 'Warning'; ScriptName = 'a.ps1'; Line = 3; Message = 'use full name' }
            [PSCustomObject]@{ RuleName = 'PSAvoidUsingWriteHost'; Severity = 'Information'; ScriptName = 'b.ps1'; Line = 1; Message = 'no host' }
        )
        $fs = @(ConvertTo-ScriptAnalyzerFindings -Records $records)
        $fs.Count | Should -Be 2
        ($fs | Where-Object { $_.Rule -eq 'PSAvoidUsingCmdletAliases' }).Severity | Should -Be 'Medium'
        ($fs | Where-Object { $_.Rule -eq 'PSAvoidUsingWriteHost' }).Severity | Should -Be 'Low'
        ($fs | Where-Object { $_.Rule -eq 'PSAvoidUsingCmdletAliases' }).File | Should -Be 'a.ps1'
    }

    It 'returns zero findings for empty input, not one blank entry' {
        @(ConvertTo-ScriptAnalyzerFindings -Records @()).Count | Should -Be 0
        @(ConvertTo-ScriptAnalyzerFindings -Records @($null, '', '   ')).Count | Should -Be 0
    }

    It 'passes a project with no PowerShell scripts instead of failing it' {
        # A C#-only repo has no .ps1/.psm1/.psd1: the PowerShell check must
        # pass silently (nothing to scan), never fail or invent findings.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_sast_nops_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $dir 'app.cs') -Value 'class A {}'
            if (-not (Test-SastToolAvailable -Tool 'Invoke-ScriptAnalyzer' -State ([PSCustomObject]@{ BuildConfig = $null }))) {
                $r = Invoke-SastTool -Language 'PowerShell' -ProjectDir $dir -State ([PSCustomObject]@{ BuildConfig = $null })
                $r.Status | Should -Be 'Skipped'
            } else {
                $r = Invoke-SastTool -Language 'PowerShell' -ProjectDir $dir -State ([PSCustomObject]@{ BuildConfig = $null })
                $r.Status | Should -Be 'Passed'
                @($r.Findings).Count | Should -Be 0
            }
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
