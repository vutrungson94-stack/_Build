# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'PathUtils')

$script:LanguageMap = @(
     @{ Language='C#';        Ext='.csproj';           BuildTool='dotnet';   TestTool='dotnet test';    LintTool='dotnet format';  BuildFile='*.csproj' }
     @{ Language='F#';        Ext='.fsproj';           BuildTool='dotnet';   TestTool='dotnet test';    LintTool='dotnet format';  BuildFile='*.fsproj' }
     @{ Language='VB.NET';    Ext='.vbproj';           BuildTool='dotnet';   TestTool='dotnet test';    LintTool='dotnet format';  BuildFile='*.vbproj' }
     @{ Language='C#';        Ext='.sln';               BuildTool='dotnet';   TestTool='dotnet test';    LintTool='dotnet format';  BuildFile='*.sln' }
     @{ Language='Node.js';   Ext='package.json';       BuildTool='npm';      TestTool='npm test';       LintTool='npx eslint';     BuildFile='package.json' }
     @{ Language='TypeScript'; Ext='.json';            BuildTool='npm';      TestTool='npm test';       LintTool='npx tsc --noEmit'; BuildFile='package.json' }

    @{ Language='Python';    Ext='pyproject.toml';     BuildTool='python';   TestTool='pytest';         LintTool='ruff';           BuildFile='pyproject.toml' }
    @{ Language='Python';    Ext='setup.py';           BuildTool='python';   TestTool='pytest';         LintTool='ruff';           BuildFile='setup.py' }
    @{ Language='Python';    Ext='setup.cfg';          BuildTool='python';   TestTool='pytest';         LintTool='ruff';           BuildFile='setup.cfg' }
    @{ Language='Rust';      Ext='Cargo.toml';         BuildTool='cargo';    TestTool='cargo test';     LintTool='cargo clippy';   BuildFile='Cargo.toml' }
    @{ Language='Java';      Ext='pom.xml';            BuildTool='mvn';      TestTool='mvn test';       LintTool='mvn checkstyle:check'; BuildFile='pom.xml' }
    @{ Language='Java';      Ext='build.gradle';       BuildTool='gradle';   TestTool='gradle test';    LintTool='gradle lint';    BuildFile='build.gradle' }
    @{ Language='Go';        Ext='go.mod';             BuildTool='go';       TestTool='go test';        LintTool='go vet';        BuildFile='go.mod' }
    @{ Language='Ruby';      Ext='Gemfile';            BuildTool='bundle';   TestTool='bundle exec rspec'; LintTool='rubocop';   BuildFile='Gemfile' }
    @{ Language='PHP';       Ext='composer.json';      BuildTool='composer'; TestTool='phpunit';        LintTool='phpcs';          BuildFile='composer.json' }
    @{ Language='C/C++';     Ext='CMakeLists.txt';     BuildTool='cmake';    TestTool='ctest';          LintTool='cppcheck';       BuildFile='CMakeLists.txt' }
    @{ Language='C';         Ext='Makefile';           BuildTool='make';     TestTool='make test';      LintTool='cppcheck';       BuildFile='Makefile' }
    @{ Language='Kotlin';    Ext='build.gradle.kts';   BuildTool='gradle';   TestTool='gradle test';    LintTool='ktlint';         BuildFile='build.gradle.kts' }
    @{ Language='Swift';     Ext='Package.swift';      BuildTool='swift';    TestTool='swift test';     LintTool='swiftlint';      BuildFile='Package.swift' }
    @{ Language='Scala';     Ext='build.sbt';          BuildTool='sbt';      TestTool='sbt test';       LintTool='sbt scalafmtCheck'; BuildFile='build.sbt' }
    @{ Language='Elixir';    Ext='mix.exs';            BuildTool='mix';      TestTool='mix test';       LintTool='mix format --check-formatted'; BuildFile='mix.exs' }
    @{ Language='Docker';    Ext='Dockerfile';         BuildTool='docker';   TestTool=$null;            LintTool='docker compose config'; BuildFile='Dockerfile' }
     @{ Language='Avalonia';  Ext='.csproj';            BuildTool='dotnet';   TestTool='dotnet test';    LintTool='dotnet format';  BuildFile='*.csproj' }

    @{ Language='PowerShell'; Ext='.psm1';             BuildTool='';          TestTool='';               LintTool='Invoke-ScriptAnalyzer'; BuildFile='*.psm1' }
)

function Get-LanguageMap {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([PSCustomObject]$State = $null)

Set-StrictMode -Version 1.0
    if (-not $State -and (Get-Command Get-BuildState -ErrorAction SilentlyContinue)) { $State = Get-BuildState }
    $merged = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in $script:LanguageMap) { $merged.Add($entry) }
    $configured = @()
    if ($State -and $State.BuildConfig) {
        $cfg = $State.BuildConfig
        if ($cfg -is [System.Collections.IDictionary]) {
            if ($cfg.ContainsKey('build')) { $cfg = $cfg['build'] }
        } elseif ($cfg.PSObject.Properties.Name -contains 'build') { $cfg = $cfg.build }
        if ($cfg) {
            if ($cfg -is [System.Collections.IDictionary]) {
                if ($cfg.ContainsKey('languageMap')) { $configured = @($cfg['languageMap']) }
            } elseif ($cfg.PSObject.Properties.Name -contains 'languageMap') { $configured = @($cfg.languageMap) }
        }
    }
    foreach ($entry in $configured) {
        if ($null -eq $entry) { continue }
        $language = if ($entry -is [System.Collections.IDictionary]) { $entry['Language'] } else { $entry.Language }
        $buildFile = if ($entry -is [System.Collections.IDictionary]) { $entry['BuildFile'] } else { $entry.BuildFile }
        if (-not $language -or -not $buildFile) { continue }
        $ext = if ($entry -is [System.Collections.IDictionary]) { $entry['Ext'] } else { $entry.Ext }
        $buildTool = if ($entry -is [System.Collections.IDictionary]) { $entry['BuildTool'] } else { $entry.BuildTool }
        $testTool = if ($entry -is [System.Collections.IDictionary]) { $entry['TestTool'] } else { $entry.TestTool }
        $lintTool = if ($entry -is [System.Collections.IDictionary]) { $entry['LintTool'] } else { $entry.LintTool }
        $newEntry = @{
            Language  = [string]$language
            Ext       = if ($ext) { [string]$ext } else { [System.IO.Path]::GetExtension([string]$buildFile) }
            BuildTool = if ($null -ne $buildTool) { [string]$buildTool } else { $null }
            TestTool  = if ($null -ne $testTool) { [string]$testTool } else { $null }
            LintTool  = if ($null -ne $lintTool) { [string]$lintTool } else { $null }
            BuildFile = [string]$buildFile
        }
        $idx = -1
        for ($i = 0; $i -lt $merged.Count; $i++) {
            if ($merged[$i].Language -eq $newEntry.Language -and $merged[$i].BuildFile -eq $newEntry.BuildFile) { $idx = $i; break }
        }
        if ($idx -ge 0) { $merged[$idx] = $newEntry } else { $merged.Add($newEntry) }
    }
    return $merged.ToArray()
}

function Test-LanguageEntryBuildFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([hashtable]$Entry, [string]$FilePath, [PSCustomObject]$State = $null)
    if (-not $Entry -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    $leaf = [System.IO.Path]::GetFileName($FilePath)
    $pattern = [string]$Entry.BuildFile
    if ($leaf -notlike $pattern) { return $false }
    if ($Entry.Language -eq 'Avalonia') {
        try {
            $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
            return ($content -match '(?i)Avalonia\.Framework|PackageReference[^>]*Include\s*=\s*["'']Avalonia')
        } catch { return $false }
    }
    if ($Entry.Language -eq 'TypeScript') {
        $dir = Split-Path -Parent $FilePath
        $tsConfig = @(Get-ChildItem -LiteralPath $dir -Filter 'tsconfig*.json' -File -ErrorAction SilentlyContinue)
        if ($tsConfig.Count -gt 0) { return $true }
        try {
            $pkg = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($pkg -and $pkg.scripts) {
                foreach ($p in $pkg.scripts.PSObject.Properties) {
                    if ([string]$p.Value -match '(?i)tsc|typescript') { return $true }
                }
            }
        } catch { }
        try {
            $sources = @(Get-ChildItem -Path (Join-Path $dir '*') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { ($_.Extension -eq '.ts' -or $_.Extension -eq '.tsx') -and $_.Name -notlike '*.d.ts' -and $_.FullName -notmatch '[\\/](node_modules|\.git|dist|build|coverage|publish-output|\.gbuildcache|test|tests|__tests__|examples?|demo|docs?|vendor|tmp|temp|out|\.next|\.nuxt)[\\/]' } |
                Select-Object -First 1)
        } catch { $sources = @() }
        return ($sources.Count -gt 0)
    }
    return $true
}

function Get-DetectedLanguages {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [string]$SearchRoot,
        # -1 = sentinel "use default" (BuildConstants.LangDetectDepth)
        [int]$Depth = -1,
        [PSCustomObject]$State
    )
    if ($Depth -lt 0) { $Depth = Get-BuildConstant -Key 'LangDetectDepth' -State $State -Fallback 5 }
    if (-not (Test-Path $SearchRoot)) { return @() }

    $languageMap = @(Get-LanguageMap -State $State)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen = @{}
    # SharedUtils already loaded via bootstrap → call directly (no guard)
    $pubOut = if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) {
        Resolve-PublishOutputDir -State $State
    } else {
        Get-BuildConstant -Key 'PublishOutputDir' -State $State -Fallback 'publish-output'
    }
    $repDir = Get-BuildConstant -Key 'ReportOutputDir' -State $State -Fallback 'build-reports'
    # Single source: PathUtils.Get-ExcludeDirPattern over SyntaxCheckExcludeDirs
    # (+ language-domain extras). Fixes the old inline copy whose doubled
    # backslashes made '\\.git' match "backslash + any char + git" instead of the
    # literal '.git' directory on forward-slash-normalized paths.
    # Resolved publish/report dirs (config-overridable via paths.publishOutput /
    # report.outputDir) are merged in so a custom-named output dir is never scanned.
    $extraDirs = @('packages','.vs','.idea','.sdk') + @($pubOut, $repDir) | Where-Object { $_ } | Select-Object -Unique
    # Ensure PathUtils is available (defensive: module might not be loaded in
    # constrained scopes / PS 5.1 nesting edge cases). On-demand import so the
    # language detector never crashes the preflight pipeline if the bootstrap
    # chain was truncated.
    if (-not (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.lang.pathUtilsSelfHeal' -Fallback '[LANGDET] PathUtils was not loaded by bootstrap; imported on demand (self-healing)') 'Warn' $State
        }
    }
    $excludePattern = ''
    if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
        $excludePattern = Get-ExcludeDirPattern -FromConstant 'SyntaxCheckExcludeDirs' -Extra $extraDirs
    }

    $excludeDirs = @((Get-SyntaxCheckExcludeDirs)) + @($extraDirs) | Where-Object { $_ } | Select-Object -Unique
    $excludePattern = ''
    if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
        $excludePattern = Get-ExcludeDirPattern -FromConstant 'SyntaxCheckExcludeDirs' -Extra $extraDirs
    }

    $directRootHit = $false
    foreach ($entry in $languageMap) {
        if ($seen.ContainsKey($entry.Language)) { continue }
        $rootFound = @(Get-ChildItem -LiteralPath $SearchRoot -Filter $entry.BuildFile -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($rootFound.Count -gt 0 -and (Test-LanguageEntryBuildFile -Entry $entry -FilePath $rootFound[0].FullName -State $State)) {
            $seen[$entry.Language] = $true
            $directRootHit = $true
            $results.Add([PSCustomObject]@{
                Language     = $entry.Language
                BuildTool    = $entry.BuildTool
                TestTool     = $entry.TestTool
                LintTool     = $entry.LintTool
                BuildFile    = $entry.BuildFile
                BuildFilePath = $rootFound[0].FullName
                ProjectDir   = $rootFound[0].DirectoryName
            })
        }
    }
    if ($directRootHit) { return $results.ToArray() }

    foreach ($entry in $languageMap) {
        if ($seen.ContainsKey($entry.Language)) { continue }
        if (Get-Command Get-BoundedProjectFiles -ErrorAction SilentlyContinue) {
            $found = Get-BoundedProjectFiles -Root $SearchRoot -Filters @($entry.BuildFile) -Depth $Depth -ExcludeDirs $excludeDirs -File |
                Where-Object { $_.FullName -notmatch $excludePattern } |
                Where-Object { Test-LanguageEntryBuildFile -Entry $entry -FilePath $_.FullName -State $State } |
                Select-Object -First 1
        } else {
            $found = Get-ChildItem -Path $SearchRoot -Recurse -Filter $entry.BuildFile -File -EA SilentlyContinue |
                Where-Object { $_.FullName -notmatch $excludePattern } |
                Where-Object { Test-LanguageEntryBuildFile -Entry $entry -FilePath $_.FullName -State $State } |
                Select-Object -First 1
        }
        if ($found) {
            $seen[$entry.Language] = $true
            $results.Add([PSCustomObject]@{
                Language     = $entry.Language
                BuildTool    = $entry.BuildTool
                TestTool     = $entry.TestTool
                LintTool     = $entry.LintTool
                BuildFile    = $entry.BuildFile
                BuildFilePath = $found.FullName
                ProjectDir   = $found.DirectoryName
            })
        }
    }

    return $results.ToArray()
}

function Get-PrimaryLanguage {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$SearchRoot,
        # -1 = sentinel "use default" (BuildConstants.LangDetectDepth)
        [int]$Depth = -1,
        [PSCustomObject]$State
    )
    if ($Depth -lt 0) { $Depth = Get-BuildConstant -Key 'LangDetectDepth' -State $State -Fallback 5 }
    $langs = Get-DetectedLanguages -SearchRoot $SearchRoot -Depth $Depth -State $State
    if ($langs.Count -eq 0) { return $null }
    $priority = Get-BuildConstant -Key 'PrimaryLanguagePriority' -Fallback @('Avalonia', 'C#', 'F#', 'VB.NET', 'Node.js', 'TypeScript', 'Python', 'Rust', 'Java', 'Kotlin', 'Scala', 'Go', 'Ruby', 'PHP', 'C/C++', 'C', 'Swift', 'Elixir', 'PowerShell', 'Docker')
    foreach ($p in $priority) {
        $match = $langs | Where-Object { $_.Language -eq $p }
        if ($match) { return $match[0] }
    }
    return $langs[0]
}

function Test-LanguageBuildFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$FilePath, [PSCustomObject]$State = $null)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    $name = [System.IO.Path]::GetFileName($FilePath).ToLowerInvariant()
    if ($name -eq 'tsconfig.json' -or $name -like 'tsconfig*.json' -or $name -like '*.axaml') { return $false }
    foreach ($entry in @(Get-LanguageMap -State $State)) {
        $pattern = ([string]$entry.BuildFile).ToLowerInvariant()
        if ($name -like $pattern) { return $true }
    }
    return $false
}

function Get-DotnetLanguages {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('C#', 'F#', 'VB.NET')
}

Export-ModuleMember -Function @('Get-LanguageMap', 'Get-DetectedLanguages', 'Get-PrimaryLanguage', 'Test-LanguageBuildFile', 'Get-DotnetLanguages')
