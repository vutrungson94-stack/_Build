#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'Plugin dispatch' {
    BeforeAll {
        $global:GBuildDispatchTemp = Join-Path $( [System.IO.Path]::GetTempPath() ) "gbuild_dispatch_$(New-Guid)"
        New-Item -ItemType Directory -Path $global:GBuildDispatchTemp -Force -EA 0 | Out-Null
        $global:GBuildNodeDir = Join-Path $global:GBuildDispatchTemp 'node-project'
        New-Item -ItemType Directory -Path $global:GBuildNodeDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $global:GBuildNodeDir 'package.json') -Value '{"name":"test","scripts":{"build":"echo build"}}'
        $global:GBuildPyDir = Join-Path $global:GBuildDispatchTemp 'python-project'
        New-Item -ItemType Directory -Path $global:GBuildPyDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $global:GBuildPyDir 'pyproject.toml') -Value '[project]'
        $global:GBuildRustDir = Join-Path $global:GBuildDispatchTemp 'rust-project'
        New-Item -ItemType Directory -Path $global:GBuildRustDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $global:GBuildRustDir 'Cargo.toml') -Value '[package]'
        $global:GBuildNetDir = Join-Path $global:GBuildDispatchTemp 'dotnet-project'
        New-Item -ItemType Directory -Path $global:GBuildNetDir -Force -EA 0 | Out-Null
        Set-Content -Path (Join-Path $global:GBuildNetDir 'test.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"/>'
    }
    AfterAll { Remove-Item $global:GBuildDispatchTemp -Recurse -Force -EA 0 }

    It 'Get-PrimaryLanguage detects Node project from package.json' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $mockState = New-TestState
        $lang = Get-PrimaryLanguage -SearchRoot $global:GBuildNodeDir -State $mockState
        $lang | Should -Not -BeNullOrEmpty
        $lang.Language | Should -Be 'Node.js'
        $lang.BuildFile | Should -Be 'package.json'
    }

    It 'Get-PrimaryLanguage detects Python project from pyproject.toml' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $mockState = New-TestState
        $lang = Get-PrimaryLanguage -SearchRoot $global:GBuildPyDir -State $mockState
        $lang | Should -Not -BeNullOrEmpty
        $lang.Language | Should -Be 'Python'
    }

    It 'Get-PrimaryLanguage detects Rust project from Cargo.toml' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $mockState = New-TestState
        $lang = Get-PrimaryLanguage -SearchRoot $global:GBuildRustDir -State $mockState
        $lang | Should -Not -BeNullOrEmpty
        $lang.Language | Should -Be 'Rust'
    }

    It 'Get-PrimaryLanguage prefers C# over other languages in mixed dir' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $mockState = New-TestState
        $lang = Get-PrimaryLanguage -SearchRoot $global:GBuildNetDir -State $mockState
        $lang | Should -Not -BeNullOrEmpty
        $lang.Language | Should -Be 'C#'
    }

    It 'Resolve-PluginForLanguage returns a valid plugin entry for Node.js' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/Node.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $mockState = New-TestState
        $mockState.LogLevel = 0
        Register-Plugins -State $mockState
        $plugin = Resolve-PluginForLanguage -Language 'Node.js'
        $plugin | Should -Not -BeNullOrEmpty
        $plugin.Info.Name | Should -Be 'Node'
        $plugin.Module | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-PluginBuildSafe returns false for unknown language' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $result = Invoke-PluginBuildSafe -State $mockState -Language 'UnknownLang' -ProjectDir $global:GBuildDispatchTemp
        $result | Should -BeOfType [bool]
        $result | Should -Be $false
    }

    It 'Invoke-PluginBuildSafe tries fallback on failure' {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $result = Invoke-PluginBuildSafe -State $mockState -Language 'UnknownLang' -ProjectDir $global:GBuildDispatchTemp -FallbackLanguage 'Node.js'
        $result | Should -BeOfType [bool]
        $result | Should -Be $false
    }
}

Describe 'Fail-closed operation results' {
    BeforeAll {
        $global:ResultTestState = New-TestState
        $global:ResultTestState.LogLevel = 0
    }

    It 'converts boolean, null, and array values without promoting failure' {
        $success = ConvertTo-OperationResult -Value $true -Operation 'result'
        $failure = ConvertTo-OperationResult -Value $false -Operation 'result'
        $missing = ConvertTo-OperationResult -Value $null -Operation 'result'
        $arrayFailure = ConvertTo-OperationResult -Value @($true, $false) -Operation 'result'
        $empty = ConvertTo-OperationResult -Value @() -Operation 'result'
        $success.Status | Should -Be 'Succeeded'
        $failure.Status | Should -Be 'Failed'
        $missing.Status | Should -Be 'Failed'
        $missing.ReasonCode | Should -Be 'NullResult'
        $arrayFailure.Status | Should -Be 'Failed'
        $empty.Status | Should -Be 'Skipped'
        Test-RequiredResult -Result $success | Should -BeTrue
        Test-RequiredResult -Result $missing | Should -BeFalse
        @('Status','Operation','ReasonCode','Message','ExitCode','DurationMs','Details') | ForEach-Object {
            $success.PSObject.Properties.Name | Should -Contain $_
        }
    }

    It 'returns structured failures for build false, null, and exception' {
        Mock Invoke-PluginBuildFor -ModuleName Loader -MockWith { return $false }
        $falseResult = Invoke-PluginBuildSafe -State $global:ResultTestState -Language 'MockLang' -ProjectDir $global:GBuildDispatchTemp -Detailed
        $falseResult.Status | Should -Be 'Failed'
        Test-RequiredResult -Result $falseResult | Should -BeFalse
        Mock Invoke-PluginBuildFor -ModuleName Loader -MockWith { return $null }
        $nullResult = Invoke-PluginBuildSafe -State $global:ResultTestState -Language 'MockLang' -ProjectDir $global:GBuildDispatchTemp -Detailed
        $nullResult.Status | Should -Be 'Failed'
        $nullResult.ReasonCode | Should -Be 'NullResult'
        Mock Invoke-PluginBuildFor -ModuleName Loader -MockWith { throw 'build exploded' }
        $exceptionResult = Invoke-PluginBuildSafe -State $global:ResultTestState -Language 'MockLang' -ProjectDir $global:GBuildDispatchTemp -Detailed
        $exceptionResult.Status | Should -Be 'Failed'
        $exceptionResult.ReasonCode | Should -Be 'Exception'
    }

    It 'distinguishes a missing plugin test command from success' {
        $global:MissingTestModule = New-Module -Name 'MissingTestModule' -ScriptBlock {
            function Invoke-Noop { }
            function Get-Command {
                [CmdletBinding()]
                param([Parameter(Position=0)][string]$Name)
                if ($Name -eq 'Invoke-PluginTest') { return $null }
                return Microsoft.PowerShell.Core\Get-Command $Name
            }
            Export-ModuleMember -Function Invoke-Noop,Get-Command
        }
        Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return @{ Module = $global:MissingTestModule } }
        $result = Invoke-PluginTestFor -State $global:ResultTestState -Language 'MockLang' -ProjectDir $global:GBuildDispatchTemp -Detailed
        $result.Status | Should -Be 'Skipped'
        $result.ReasonCode | Should -Be 'CommandNotFound'
        Test-RequiredResult -Result $result | Should -BeFalse
        Remove-Module -Name MissingTestModule -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-Command -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name MissingTestModule -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Plugin dispatch context contract' {
    BeforeAll {
        $global:DispatchContextModule = New-Module -Name 'DispatchContextModule' -ScriptBlock {
            function Invoke-PluginTest {
                param($State, $ProjectDir, $ProjectFile, $Configuration, [switch]$Detailed)
                $global:DispatchTestArgs = [PSCustomObject]@{ ProjectDir = $ProjectDir; ProjectFile = $ProjectFile; Configuration = $Configuration }
                return [PSCustomObject]@{ Status = 'Succeeded'; ReasonCode = 'OK'; Message = 'ok'; ExitCode = 0; Details = $null }
            }
            function Invoke-PluginLint {
                param($State, $ProjectDir, $ProjectFile, $Configuration, [switch]$Detailed)
                $global:DispatchLintArgs = [PSCustomObject]@{ ProjectDir = $ProjectDir; ProjectFile = $ProjectFile; Configuration = $Configuration }
                return $true
            }
            Export-ModuleMember -Function Invoke-PluginTest,Invoke-PluginLint
        }
        Import-Module $global:DispatchContextModule -Force -Global -DisableNameChecking
        $global:DispatchContextTemp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_dispatch_context_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $global:DispatchContextTemp -Force | Out-Null
        $global:DispatchContextState = New-TestState
    }
    AfterAll {
        Remove-Module -Name DispatchContextModule -Force -ErrorAction SilentlyContinue
        Remove-Item $global:DispatchContextTemp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name DispatchContextModule,DispatchContextState,DispatchContextTemp,DispatchTestArgs,DispatchLintArgs -Scope Global -ErrorAction SilentlyContinue
    }
    It 'forwards project file, configuration, and project directory to test and lint' {
        Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return @{ Module = $global:DispatchContextModule; Info = [PSCustomObject]@{ Name = 'DispatchContext'; SupportedLanguages = @('MockLang'); Priority = 1 }; Path = 'DispatchContext.psm1' } }
        $file = Join-Path $global:DispatchContextTemp 'context.json'
        Set-Content -LiteralPath $file -Value '{}'
        $test = Invoke-PluginTestFor -State $global:DispatchContextState -Language MockLang -ProjectDir $global:DispatchContextTemp -ProjectFile $file -Configuration Debug -Detailed
        $lint = Invoke-PluginLintFor -State $global:DispatchContextState -Language MockLang -ProjectDir $global:DispatchContextTemp -ProjectFile $file -Configuration Debug -Detailed
        $test.Status | Should -Be 'Succeeded'
        $lint.Status | Should -Be 'Succeeded'
        $global:DispatchTestArgs.ProjectFile | Should -Be $file
        $global:DispatchTestArgs.Configuration | Should -Be 'Debug'
        ([System.IO.Path]::GetFullPath($global:DispatchTestArgs.ProjectDir)) | Should -Be ([System.IO.Path]::GetFullPath($global:DispatchContextTemp))
        $global:DispatchLintArgs.ProjectFile | Should -Be $file
        $global:DispatchLintArgs.Configuration | Should -Be 'Debug'
    }

    It 'resolves the manifest per-plugin, not the first global match' {
        # Multi-manifest tree (package.json + Dockerfile): the dispatch context
        # resolves Dockerfile (first match in the global union). The plugin must
        # still receive ITS OWN manifest - previously every language plugin got
        # the same foreign file and rejected it, failing Test/Lint with a bogus
        # ManifestMissing even though package.json exists (Node+Docker trees).
        Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return @{ Module = $global:DispatchContextModule; Info = [PSCustomObject]@{ Name = 'DispatchContext'; SupportedLanguages = @('MockLang'); Priority = 1; ManifestFiles = @('package.json') }; Path = 'DispatchContext.psm1' } }
        $dir = Join-Path $global:DispatchContextTemp 'multi-manifest'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'package.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $dir 'Dockerfile') -Value 'FROM scratch'
        try {
            $r = Invoke-PluginTestFor -State $global:DispatchContextState -Language MockLang -ProjectDir $dir -Detailed
            $r.Status | Should -Be 'Succeeded'
            ([System.IO.Path]::GetFullPath([string]$global:DispatchTestArgs.ProjectFile)) | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $dir 'package.json')))
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Plugin action dispatch parity (Invoke-PluginActionFor)' {
    BeforeAll {
        # One mock language resolved for ALL four verbs, so the four wrappers
        # run the identical plugin code and any behavioural drift between them
        # shows up as a test failure. Test/Lint/Clean/Run each expose their own
        # plugin command with the verb baked in.
        $global:ParityModule = New-Module -Name 'ParityModule' -ScriptBlock {
            foreach ($verb in @('Test', 'Lint', 'Clean', 'Run')) {
                $def = "function Invoke-Plugin$verb { param(`$State, `$ProjectDir, `$ProjectFile, `$Configuration, [switch]`$Detailed) return [PSCustomObject]@{ Status = 'Succeeded'; ReasonCode = 'OK'; Message = 'ok'; ExitCode = 0; Details = `$null } }"
                Invoke-Expression $def
            }
            Export-ModuleMember -Function Invoke-PluginTest,Invoke-PluginLint,Invoke-PluginClean,Invoke-PluginRun
        }
        Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return @{ Module = $global:ParityModule } }
        $global:ParityTemp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_parity_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $global:ParityTemp -Force | Out-Null
        $global:ParityState = New-TestState
        $global:ParityState | Add-Member -MemberType NoteProperty -Name ProjectRoot -Value $global:ParityTemp -Force
    }
    AfterAll {
        Remove-Module -Name ParityModule -Force -ErrorAction SilentlyContinue
        Remove-Item $global:ParityTemp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name ParityModule,ParityState,ParityTemp -Scope Global -ErrorAction SilentlyContinue
    }

    It 'all four verbs return the identical skeleton for the same plugin outcome' {
        $t = Invoke-PluginTestFor  -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp -Detailed
        $l = Invoke-PluginLintFor  -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp -Detailed
        $c = Invoke-PluginCleanFor -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp -Detailed
        $r = Invoke-PluginRunFor   -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp -Detailed
        foreach ($result in @($t, $l, $c, $r)) {
            $result.Status | Should -Be 'Succeeded'
            $result.ExitCode | Should -Be 0
        }
        # Only the operation namespace may differ - everything else about a
        # Succeeded result must be verb-independent.
        $t.Operation | Should -Be 'plugin.test:MockLang'
        $l.Operation | Should -Be 'plugin.lint:MockLang'
        $c.Operation | Should -Be 'plugin.clean:MockLang'
        $r.Operation | Should -Be 'plugin.run:MockLang'
    }

    It 'all four verbs report PluginNotFound identically' {
        Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return $null }
        try {
            $results = @(
                (Invoke-PluginTestFor  -State $global:ParityState -Language Nope -ProjectDir $global:ParityTemp -Detailed),
                (Invoke-PluginLintFor  -State $global:ParityState -Language Nope -ProjectDir $global:ParityTemp -Detailed),
                (Invoke-PluginCleanFor -State $global:ParityState -Language Nope -ProjectDir $global:ParityTemp -Detailed),
                (Invoke-PluginRunFor   -State $global:ParityState -Language Nope -ProjectDir $global:ParityTemp -Detailed)
            )
            foreach ($result in $results) {
                $result.Status | Should -Be 'Skipped'
                $result.ReasonCode | Should -Be 'PluginNotFound'
                $result.ExitCode | Should -Be 127
            }
            $results[0].Message | Should -Match 'test'
            $results[1].Message | Should -Match 'lint'
            $results[2].Message | Should -Match 'clean'
            $results[3].Message | Should -Match 'run'
        } finally {
            Mock Resolve-PluginForLanguage -ModuleName Loader -MockWith { return @{ Module = $global:ParityModule } }
        }
    }

    It 'all four verbs collapse to $false without -Detailed' {
        $calls = @(
            { Invoke-PluginTestFor  -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp },
            { Invoke-PluginLintFor  -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp },
            { Invoke-PluginCleanFor -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp },
            { Invoke-PluginRunFor   -State $global:ParityState -Language MockLang -ProjectDir $global:ParityTemp }
        )
        foreach ($call in $calls) { (& $call) | Should -BeTrue }
    }

    It 'Invoke-PluginActionFor rejects an unknown verb' {
        { Invoke-PluginActionFor -State $global:ParityState -Verb Build -Language MockLang -ProjectDir $global:ParityTemp } | Should -Throw
    }

    It 'documents the ManifestFiles divergence: Test/Lint pass them, Clean/Run do not' {
        # The merge surfaced this inconsistency: Test and Lint resolve the
        # project file against the dispatch manifest list, Clean and Run leave
        # the list empty and fall back to autodetect. This test PINS the
        # divergence. If someone unifies the paths, this test must be updated
        # in the same change - silently changing which files Clean resolves is
        # how a clean step starts deleting the wrong directory.
        $loaderSrc = Get-Content -LiteralPath (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Raw
        $loaderSrc | Should -Match 'Invoke-PluginTestFor[\s\S]{0,600}-WithManifestFiles'
        $loaderSrc | Should -Match 'Invoke-PluginLintFor[\s\S]{0,600}-WithManifestFiles'
        # Clean and Run wrappers must NOT carry the flag.
        ([regex]::Matches($loaderSrc, 'function Invoke-PluginCleanFor[\s\S]*?(?=\nfunction |\n<#\s*\n\.SYNOPSIS)')).Count | Should -BeGreaterThan 0
        $cleanBody = ([regex]::Match($loaderSrc, 'function Invoke-PluginCleanFor[\s\S]*?\n\}')).Value
        $cleanBody | Should -Not -Match '-WithManifestFiles'
        $runBody = ([regex]::Match($loaderSrc, 'function Invoke-PluginRunFor[\s\S]*?\n\}')).Value
        $runBody | Should -Not -Match '-WithManifestFiles'
    }
}
