#Requires -Version 5.1
#Requires -Module Pester
Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "LanguageDetector" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'LanguageDetector.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:td = New-IntegrationTempDir
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Detects C# from test.csproj" {
        Set-Content -Path (Join-Path $global:td 'test.csproj') -Value '<Project></Project>'
        $langs = Get-DetectedLanguages -SearchRoot $global:td
        ($langs | Where-Object { $_.Language -eq 'C#' }) | Should -Not -BeNullOrEmpty
    }

    It "Detects Node.js from package.json" {
        Set-Content -Path (Join-Path $global:td 'package.json') -Value '{ "name": "x" }'
        $langs = Get-DetectedLanguages -SearchRoot $global:td
        ($langs | Where-Object { $_.Language -eq 'Node.js' }) | Should -Not -BeNullOrEmpty
    }

    It "Detects Rust from Cargo.toml" {
        Set-Content -Path (Join-Path $global:td 'Cargo.toml') -Value '[package]'
        $langs = Get-DetectedLanguages -SearchRoot $global:td
        ($langs | Where-Object { $_.Language -eq 'Rust' }) | Should -Not -BeNullOrEmpty
    }

    It "Get-PrimaryLanguage returns object and prefers C# over Node.js" {
        Set-Content -Path (Join-Path $global:td 'prim.csproj') -Value '<Project></Project>'
        Set-Content -Path (Join-Path $global:td 'prim.package.json') -Value '{ "name": "x" }'
        $prim = Get-PrimaryLanguage -SearchRoot $global:td
        $prim | Should -Not -BeNullOrEmpty
        $prim | Should -BeOfType [PSCustomObject]
        $prim.Language | Should -Be 'C#'
    }

    It "Test-LanguageBuildFile true for csproj and false for txt" {
        Set-Content -Path (Join-Path $global:td 'real.csproj') -Value '<Project></Project>'
        Test-LanguageBuildFile -FilePath (Join-Path $global:td 'real.csproj') | Should -Be $true
        Test-LanguageBuildFile -FilePath (Join-Path $global:td 'nope.txt') | Should -Be $false
    }

    It 'uses package.json, not tsconfig.json, as the TypeScript build file' {
        $dir = Join-Path $global:td 'typescript-regression'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'package.json') -Value '{"name":"fixture","devDependencies":{"typescript":"*"}}'
        Set-Content -LiteralPath (Join-Path $dir 'tsconfig.json') -Value '{}'
        $lang = Get-PrimaryLanguage -SearchRoot $dir
        $lang.Language | Should -Be 'TypeScript'
        $lang.BuildFile | Should -Be 'package.json'
        Test-LanguageBuildFile -FilePath (Join-Path $dir 'tsconfig.json') | Should -BeFalse
    }

    It 'detects a plain Node.js project as Node.js despite node_modules type declarations' {
        # Regression: every @types/* package ships .d.ts files, so the old
        # unfiltered recursive *.ts scan (plus the bare typescript-devDep
        # check) classified ANY npm-installed JS project as TypeScript.
        $dir = Join-Path $global:td 'nodejs-not-ts'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'package.json') -Value '{"name":"app","scripts":{"start":"node index.js"},"devDependencies":{"typescript":"*"}}'
        Set-Content -LiteralPath (Join-Path $dir 'index.js') -Value 'console.log(1)'
        $nmTypes = Join-Path (Join-Path $dir 'node_modules') '@types/node'
        New-Item -ItemType Directory -Path $nmTypes -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nmTypes 'index.d.ts') -Value 'declare var x: number;'
        $langs = @(Get-DetectedLanguages -SearchRoot $dir)
        ($langs | Where-Object { $_.Language -eq 'Node.js' }) | Should -Not -BeNullOrEmpty
        ($langs | Where-Object { $_.Language -eq 'TypeScript' }) | Should -BeNullOrEmpty
        (Get-PrimaryLanguage -SearchRoot $dir).Language | Should -Be 'Node.js'
    }

    It 'still detects TypeScript from real sources without tsconfig' {
        $dir = Join-Path $global:td 'typescript-sources-only'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'package.json') -Value '{"name":"tsapp","scripts":{"build":"tsc"}}'
        $src = Join-Path $dir 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'app.ts') -Value 'const x: number = 1;'
        (Get-PrimaryLanguage -SearchRoot $dir).Language | Should -Be 'TypeScript'
    }

    It 'ignores declaration-only outputs in dist' {
        $dir = Join-Path $global:td 'nodejs-dist-dts'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'package.json') -Value '{"name":"app","scripts":{"start":"node dist/index.js"}}'
        $dist = Join-Path $dir 'dist'
        New-Item -ItemType Directory -Path $dist -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dist 'index.d.ts') -Value 'declare var x: number;'
        Set-Content -LiteralPath (Join-Path $dist 'index.js') -Value 'console.log(1)'
        $langs = @(Get-DetectedLanguages -SearchRoot $dir)
        ($langs | Where-Object { $_.Language -eq 'TypeScript' }) | Should -BeNullOrEmpty
        (Get-PrimaryLanguage -SearchRoot $dir).Language | Should -Be 'Node.js'
    }

    It 'uses csproj, not axaml, as the Avalonia build file' {
        $dir = Join-Path $global:td 'avalonia-regression'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'App.csproj') -Value '<Project><ItemGroup><PackageReference Include="Avalonia" Version="1" /></ItemGroup></Project>'
        Set-Content -LiteralPath (Join-Path $dir 'View.axaml') -Value '<Window />'
        $lang = Get-PrimaryLanguage -SearchRoot $dir
        $lang.Language | Should -Be 'Avalonia'
        $lang.BuildFile | Should -Be '*.csproj'
        Test-LanguageBuildFile -FilePath (Join-Path $dir 'View.axaml') | Should -BeFalse
    }

    It 'uses a language map supplied on the live state after module import' {
        $customFile = Join-Path $global:td 'project.foo'
        Set-Content -LiteralPath $customFile -Value 'custom'
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    languageMap = @([PSCustomObject]@{ Language = 'Custom'; Ext = '.foo'; BuildFile = '*.foo'; BuildTool = 'custom'; TestTool = 'custom-test'; LintTool = 'custom-lint' })
                }
            }
        }
        $langs = @(Get-DetectedLanguages -SearchRoot $global:td -State $state)
        ($langs | Where-Object { $_.Language -eq 'Custom' }) | Should -Not -BeNullOrEmpty
        Test-LanguageBuildFile -FilePath $customFile -State $state | Should -BeTrue
    }

    It "Detects Python from a setup.cfg-only project" {
        # setup.cfg is listed as a Python project marker in three places -
        # build.projectMarkers, Loader's fallback manifest list and the Loader
        # changelog comment - but had NO row in LanguageDetector's table. A
        # repository whose only Python marker is setup.cfg was therefore found as
        # a project and then reported ZERO detected languages, so Get-PrimaryLanguage
        # returned $null and plugin dispatch never fired. Silent, and invisible to
        # every existing gate because nothing compared the marker lists.
        $setupCfgOnly = New-IntegrationTempDir
        try {
            Set-Content -Path (Join-Path $setupCfgOnly 'setup.cfg') -Value "[metadata]`nname = demo"
            $langs = @(Get-DetectedLanguages -SearchRoot $setupCfgOnly)
            ($langs | Where-Object { $_.Language -eq 'Python' }) | Should -Not -BeNullOrEmpty -Because 'a Python project must be detectable from every marker the rest of the system claims to support'
            (Get-PrimaryLanguage -SearchRoot $setupCfgOnly).Language | Should -Be 'Python'
        } finally { Remove-Item $setupCfgOnly -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "keeps the shipped language tables in agreement, or declares the exception" {
        # The language surface is spread over four tables that had already drifted:
        #   detection      LanguageDetector.$script:LanguageMap
        #   priority       BuildConstants.PrimaryLanguagePriority
        #   dispatch       Modules/Plugins/*.plugin.json supportedLanguages
        #   clean targets  build.cleanTargetsPerProjectType
        # Nothing compared them, so each could gain a language without the others
        # noticing - which is exactly how LinuxDesktop ended up dispatchable but
        # undetectable, and setup.cfg ended up a marker that detected nothing.
        $modulesDir = $global:GBuildModuleRoot
        $pluginDir = Join-Path $modulesDir 'Plugins'

        # Detection table (the authoritative list of detectable names).
        $detectorSrc = Get-Content -LiteralPath (Join-Path $modulesDir 'LanguageDetector.psm1') -Raw -Encoding UTF8
        $detectable = @([regex]::Matches($detectorSrc, "Language\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        # Priority table.
        $constSrc = Get-Content -LiteralPath (Join-Path $modulesDir 'BuildConstants.psm1') -Raw -Encoding UTF8
        $prioMatch = [regex]::Match($constSrc, 'PrimaryLanguagePriority\s*=\s*@\(([^)]*)\)')
        $priority = @([regex]::Matches($prioMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })

        # Names a manifest claims to dispatch but no detection row can produce.
        # These are legal ONLY if a project can supply them through
        # build.languageMap, which is the documented third-party extension point.
        $dispatchOnly = @()
        foreach ($p in @(Get-ChildItem -LiteralPath $pluginDir -Filter '*.plugin.json' -File)) {
            $manifest = Get-Content -LiteralPath $p.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($l in @($manifest.supportedLanguages)) {
                if ($detectable -contains $l) { continue }
                $dispatchOnly += [PSCustomObject]@{ Plugin = $p.BaseName; Language = $l }
            }
        }

        # An undeclared dispatch entry is dead: no marker produces it and no config
        # entry exists, so the dispatch branch can never be taken.
        $declaredAliases = @(
            # LinuxDesktop is an intentional CONFIG-PROVIDED alias. It is produced
            # only when a host adds it through build.languageMap (a marker of its
            # own); no built-in marker maps to it, which is why it has no
            # LanguageDetector row. Avalonia.psm1 and Build.psm1 both treat it as a
            # dotnet language. It is declared here so the exception is visible
            # instead of looking like an oversight.
            'LinuxDesktop'
        )
        $undeclared = @($dispatchOnly | Where-Object { $declaredAliases -notcontains $_.Language })
        if ($undeclared.Count -gt 0) {
            throw ("these manifest languages are dispatchable but not detectable and not declared as config-provided aliases: " +
                (($undeclared | ForEach-Object { "$($_.Plugin):$($_.Language)" }) -join ', '))
        }

        # A detectable language with NO priority entry falls through
        # Get-PrimaryLanguage's `return $langs[0]` tail, i.e. it is resolved by
        # directory-scan order rather than by intent.
        $unprioritised = @($detectable | Where-Object { $priority -notcontains $_ })
        $unprioritised | Should -BeNullOrEmpty -Because "a language with no priority entry is picked by scan order, not by design: $($unprioritised -join ', ')"
    }
}
