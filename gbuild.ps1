# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# gbuild.ps1 - thin entrypoint. SYNCHRONIZED with gbuild (bash) + gbuild.bat.
# Project-root resolution lives in ONE place (Find-ProjectManifest /
# Resolve-BuildProjectRoot in Modules); this launcher must not duplicate it.
# Responsibilities: parse CLI -> early guides (-Locale/-Target list) ->
# -SyntaxCheck (parse every shipped file) -> bootstrap Orchestrator ->
# Start-GBuild. Heavy logic stays in Modules/*.psm1 (single source).
# PS 5.1-parseable: no (if), no ?./??, no ternary, no ForEach-Object -Parallel.
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Project = '',
    [Alias('gh')][switch]$GitHub,
    [Alias('i')][switch]$Incremental,
    [Alias('c')][switch]$Clean,
    [Alias('cc')][switch]$CacheClear,
    [Alias('co')][switch]$CacheOptimize,
    [switch]$CacheStats,
    [switch]$VersionBump,
    [Alias('sec')][switch]$Security,
    [Alias('dist')][switch]$Distributed,
    [switch]$NonInteractive,
    [switch]$Force,
    [string]$Target = '',
    [string]$Locale = '',
    [string]$LogLevel = 'Info',
    [switch]$License,
    [switch]$Help,
    [Alias('vrf')][switch]$VerifyInfra,
    [switch]$SyntaxCheck,
    [switch]$SelfTest
)

Set-StrictMode -Version 1.0

# Locale is needed for the workspace-root guard below; load it before any
# user-facing message is emitted.
$null = Import-Module (Join-Path $PSScriptRoot 'Modules/Locale.psm1') -Global -DisableNameChecking -ErrorAction SilentlyContinue

# ============================================================================
# Introspection guides run BEFORE the workspace-root guard: -Help, -SelfTest
# and -SyntaxCheck are already exempt there, and the -Locale/-Target guides are
# the same class of command - they print a catalog and exit without resolving a
# project, so they must also work from a directory that merely holds the
# platform tools. (Previously the guard fired first and `gbuild -Target list`
# died with "This folder only holds the platform tools".)
# ============================================================================
$__localeArg = if ($PSBoundParameters.ContainsKey('Locale')) { [string]$Locale } else { $null }
$__localeGuide = ($null -ne $__localeArg) -and (([string]::IsNullOrWhiteSpace($__localeArg)) -or (@('list', 'help', '?') -contains $__localeArg.Trim().ToLowerInvariant()))
Remove-Variable -Name __localeArg -ErrorAction SilentlyContinue
if ($__localeGuide) {
    if (-not (Get-Command Show-LocaleHelp -ErrorAction SilentlyContinue)) {
        $null = Import-Module (Join-Path $PSScriptRoot 'Modules/Locale.psm1') -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (Get-Command Show-LocaleHelp -ErrorAction SilentlyContinue) {
        Show-LocaleHelp
    } else {
        Write-LogSafe (Resolve-LogMessage -Key 'log.gbuild.line70' -Fallback '[LOCALE] Locale help not available') 'Warn' $global:GState
    }
    Remove-Variable -Name __localeGuide -ErrorAction SilentlyContinue
    exit 0
}
Remove-Variable -Name __localeGuide -ErrorAction SilentlyContinue

# ============================================================================
# -Target guide: `-Target list|help|?` prints the target catalog and exits,
# WITHOUT resolving a project. Mirrors the -Help/-Locale intercepts.
# ============================================================================
$__targetArg = if ($PSBoundParameters.ContainsKey('Target')) { [string]$Target } else { $null }
$__targetGuide = ($null -ne $__targetArg) -and (([string]::IsNullOrWhiteSpace($__targetArg)) -or (@('list', 'help', '?') -contains $__targetArg.Trim().ToLowerInvariant()))
Remove-Variable -Name __targetArg -ErrorAction SilentlyContinue
if ($__targetGuide) {
    if (-not (Get-Command Show-TargetList -ErrorAction SilentlyContinue)) {
        $null = Import-Module (Join-Path $PSScriptRoot 'Modules/Orchestrator.psm1') -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (Get-Command Show-TargetList -ErrorAction SilentlyContinue) {
        # Need a minimal State for Show-TargetList
        $tmpState = [PSCustomObject]@{ ScriptRoot = $PSScriptRoot; BuildConfig = $null }
        Show-TargetList -State $tmpState
    } else {
        Write-LogSafe (Resolve-LogMessage -Key 'log.gbuild.line93' -Fallback '[TARGET] Target list not available') 'Warn' $global:GState
    }
    Remove-Variable -Name __targetGuide -ErrorAction SilentlyContinue
    exit 0
}
Remove-Variable -Name __targetGuide -ErrorAction SilentlyContinue

# Refuse to run against a folder that merely holds the platform tools: that is
# not a project, and running here is what created stray logs/build-reports
# (and worse, git state) outside any project.
$targetDir = if ($Project) { $Project } else { (Get-Location).Path }
$toolFolderNames = @('_Build', '_Sync', '_Tests')
$holdsPlatformFolders = @($toolFolderNames | Where-Object { Test-Path -LiteralPath (Join-Path $targetDir $_) -PathType Container }).Count -gt 0
$isPlatformFolder = @((($targetDir -replace '\\', '/') -split '/') | Where-Object { $_ -in $toolFolderNames }).Count -gt 0
if (-not ($Help -or $SelfTest -or $SyntaxCheck) -and $holdsPlatformFolders -and -not $isPlatformFolder) {
    $msg = if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.launcher.workspaceRoot' } else { "This folder only holds the platform tools (_Build, _Sync, _Tests). Point gbuild at a project directory instead." }
    Write-Host $msg -ForegroundColor Red
    exit 1
}

$gbuildModulesRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Modules'))
$gbuildModulePrefix = $gbuildModulesRoot + [System.IO.Path]::DirectorySeparatorChar
# Anti-shadow purge: drop any gbuild module loaded from THIS tree before we go
# on to load our own, so a previous run's copy cannot satisfy a sentinel check.
# The case comparison follows the host filesystem. It used to be an inline
# OSVersion.Platform ternary, which is the exact thing PathUtils.Get-PathComparison
# exists to own - and this file imports PathUtils a few lines later, so the copy
# had no defence other than being small.
$gbuildPathComparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
foreach ($gbuildLoadedModule in @(Get-Module -ErrorAction SilentlyContinue)) {
    if (-not $gbuildLoadedModule.Path) { continue }
    try { $gbuildLoadedPath = [System.IO.Path]::GetFullPath($gbuildLoadedModule.Path) } catch { continue }
    if ($gbuildLoadedPath.StartsWith($gbuildModulePrefix, $gbuildPathComparison)) {
        Remove-Module -Name $gbuildLoadedModule.Name -Force -ErrorAction SilentlyContinue
    }
}
Remove-Variable -Name gbuildModulesRoot,gbuildModulePrefix,gbuildPathComparison,gbuildLoadedModule,gbuildLoadedPath -ErrorAction SilentlyContinue

# ============================================================================
# -SyntaxCheck: parse every shipped script file without executing a build.
# Used by Dockerfile smoke, Standalone self-test, and CI. Exits 0 when all
# files parse, 1 otherwise. No module imports required (pure parser).
# ============================================================================
if ($SyntaxCheck.IsPresent) {
    $checkRoots = @(
        (Join-Path $PSScriptRoot 'Modules')
        (Join-Path $PSScriptRoot 'Steps')
        (Join-Path $PSScriptRoot 'Hooks')
    )
    $checkFiles = New-Object System.Collections.Generic.List[string]
    $discoveryErrors = New-Object System.Collections.Generic.List[string]
    $existingRootCount = 0
    $entryPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace([string]$entryPath)) { $entryPath = $MyInvocation.MyCommand.Path }
    if (-not [string]::IsNullOrWhiteSpace([string]$entryPath) -and (Test-Path -LiteralPath $entryPath -PathType Leaf)) { $checkFiles.Add([string]$entryPath) }
    # Tool-root scripts also ship with the tree (Install-GBuild.ps1,
    # gbuild.module.ps1, ...), so a syntax break in one must fail this check
    # exactly like a break in Modules/ does. Ad-hoc debug-*.ps1 once lived
    # here with a real parse error and stayed invisible because only the three
    # roots below were scanned.
    try {
        $rootScripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Force -ErrorAction Stop | Where-Object {
            return ($_.Extension.ToLowerInvariant() -eq '.ps1')
        } | Sort-Object -Property FullName)
        foreach ($f in $rootScripts) { $checkFiles.Add([string]$f.FullName) }
        # NOTE: $existingRootCount is intentionally NOT incremented here. The
        # tool root always exists, so counting it would make the 'no parser
        # roots found' discovery failure below unreachable.
    } catch {
        $discoveryErrors.Add("$PSScriptRoot : $($_.Exception.Message)")
    }
    foreach ($root in $checkRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-Host ("[SYNTAX] root not present: {0}" -f $root)
            continue
        }
        $existingRootCount++
        try {
            $found = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop | Where-Object {
                $extension = $_.Extension.ToLowerInvariant()
                return ($extension -eq '.ps1' -or $extension -eq '.psm1' -or $extension -eq '.psd1')
            } | Sort-Object -Property FullName)
            foreach ($f in $found) { $checkFiles.Add([string]$f.FullName) }
        } catch {
            $discoveryErrors.Add("${root}: $($_.Exception.Message)")
        }
    }
    $checkFiles = @($checkFiles.ToArray() | Sort-Object -Unique)
    if ($existingRootCount -eq 0) { $discoveryErrors.Add('no parser roots found') }
    if ($discoveryErrors.Count -gt 0) {
        Write-Host ("[SYNTAX] DISCOVERY FAILED: {0}" -f ($discoveryErrors -join ' | '))
        exit 1
    }
    if ($checkFiles.Count -eq 0) {
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line156' -Fallback '[SYNTAX] DISCOVERY FAILED: no PowerShell files found')
        exit 1
    }
    $failCount = 0
    $failNames = New-Object System.Collections.Generic.List[string]
    foreach ($file in $checkFiles) {
        $tokens = $null
        $errors = $null
        try {
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        } catch {
            $failCount++
            $failNames.Add((Split-Path -Leaf $file))
            Write-Host (Resolve-LogMessage -Key 'log.gbuild.syntaxError' -Fallback ("[SYNTAX] {0}: {1}" -f (Split-Path -Leaf $file), $_.Exception.Message))
            continue
        }
        if ($errors -and $errors.Count -gt 0) {
            $failCount++
            $failNames.Add((Split-Path -Leaf $file))
            foreach ($e in $errors) {
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.syntaxError2' -Fallback ("[SYNTAX] {0}: {1}" -f (Split-Path -Leaf $file), $e.Message))
            }
        }
    }
    if ($failCount -gt 0) {
        Write-Host ("[SYNTAX] FAILED: {0} file(s) with errors: {1}" -f $failCount, ($failNames -join ', '))
        exit 1
    }
    Write-Host ("[SYNTAX] OK: {0} file(s) parsed clean." -f $checkFiles.Count)
    exit 0
}

# ============================================================================
# -SelfTest: verify this _Build copy is internally consistent, then exit.
# (aicommit verification marker)
# This switch was previously declared but never forwarded to Start-GBuild and
# Start-GBuild has no such parameter, so `gbuild -SelfTest` silently ran a FULL
# BUILD and ignored the request. It now runs a real, fast integrity check:
#   1. every shipped .ps1/.psm1/.psd1 parses
#   2. gbuild.config.json is valid JSON and matches gbuild.config.schema.json
#   3. every Tier-1 core module + Provider imports cleanly
#   4. the core command surface Start-GBuild depends on resolves
# Exit 0 when healthy, 1 otherwise. No project resolution, no build.
# ============================================================================
if ($SelfTest.IsPresent) {
    $failures = New-Object System.Collections.Generic.List[string]
    $ok = 0

    # 1. Parse every shipped script
    $selfCheckRoots = @(
        (Join-Path $PSScriptRoot 'Modules')
        (Join-Path $PSScriptRoot 'Steps')
        (Join-Path $PSScriptRoot 'Hooks')
    )
    $selfFiles = New-Object System.Collections.Generic.List[string]
    foreach ($r in $selfCheckRoots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue |
                         Where-Object { $e = $_.Extension.ToLowerInvariant(); $e -eq '.ps1' -or $e -eq '.psm1' -or $e -eq '.psd1' })) {
            $selfFiles.Add([string]$f.FullName)
        }
    }
    # Tool-root scripts ship with the tree, so they parse here too (same
    # rationale as the -SyntaxCheck tool-root scope above).
    foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension.ToLowerInvariant() -eq '.ps1' })) {
        $selfFiles.Add([string]$f.FullName)
    }
    $selfParseFail = 0
    foreach ($file in @($selfFiles.ToArray() | Sort-Object -Unique)) {
        $tk = $null; $er = $null
        try { $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tk, [ref]$er) }
        catch { $selfParseFail++; $failures.Add("parse threw: $file"); continue }
        if ($er -and $er.Count -gt 0) { $selfParseFail++; $failures.Add("parse errors: $file") }
    }
    if ($selfParseFail -eq 0) { Write-Host ("[SELFTEST] parse: OK ({0} files)" -f $selfFiles.Count); $ok++ }
    else { Write-Host ("[SELFTEST] parse: FAILED ({0} file(s))" -f $selfParseFail) -ForegroundColor Red }

    # 2. Config JSON + schema
    $cfgPath = Join-Path $PSScriptRoot 'gbuild.config.json'
    $schPath = Join-Path $PSScriptRoot 'gbuild.config.schema.json'
    $cfgOk = $false
    try {
        $cfgText = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
        $null = $cfgText | ConvertFrom-Json -ErrorAction Stop
        if (Test-Path -LiteralPath $schPath -PathType Leaf) {
            $orchPath = Join-Path $PSScriptRoot 'Modules/Orchestrator.psm1'
            Import-Module $orchPath -Force -Global -DisableNameChecking -ErrorAction Stop
            if (Get-Command Test-BuildConfig -ErrorAction SilentlyContinue) {
                $state = [PSCustomObject]@{
                    ScriptRoot = $PSScriptRoot
                    ConfigPath = $cfgPath
                    BuildConfig = ($cfgText | ConvertFrom-Json)
                }
                $verdict = Test-BuildConfig -State $state
                if ($verdict) { $cfgOk = $true; Write-Host (Resolve-LogMessage -Key 'log.gbuild.line250' -Fallback '[SELFTEST] config: OK (valid against gbuild.config.schema.json)') }
                else { $failures.Add('config failed schema validation') }
            } else { $cfgOk = $true; Write-Host (Resolve-LogMessage -Key 'log.gbuild.line252' -Fallback '[SELFTEST] config: OK (JSON parsed; schema validator unavailable)') }
        } else { $cfgOk = $true; Write-Host (Resolve-LogMessage -Key 'log.gbuild.line253' -Fallback '[SELFTEST] config: OK (JSON parsed; no schema file present)') }
    } catch { $failures.Add("config: $($_.Exception.Message)") }
    if ($cfgOk) { $ok++ } else { Write-Host (Resolve-LogMessage -Key 'log.gbuild.line255' -Fallback '[SELFTEST] config: FAILED') -ForegroundColor Red }

    # 3. Tier-1 modules + Providers import
    # SINGLE SOURCE: Modules/Tier1Modules.ps1 (shared with Orchestrator.psm1's
    # eager prologue). The Core list used to be inlined here a second time, and
    # the hygiene test only matched the Orchestrator copy, so this copy could
    # drift invisibly. This probe adds only its own extras (Logging, because the
    # probe runs before Orchestrator exists; Orchestrator itself, the probe target).
    $tier1List = @{}
    try {
        . (Join-Path (Join-Path $PSScriptRoot 'Modules') 'Tier1Modules.ps1')
        $tier1List = Get-Tier1ModuleList
    } catch { $tier1List = @{} }
    if (-not $tier1List -or -not $tier1List.Core) { $failures.Add('Tier-1 module list unavailable (Modules/Tier1Modules.psm1 missing or unloadable)'); Write-Host (Resolve-LogMessage -Key 'log.gbuild.line268' -Fallback '[SELFTEST] imports: FAILED (list unavailable)') -ForegroundColor Red }
    else {
    $tier1 = @('Logging') + @($tier1List.Core) + @('Orchestrator')
    $importFail = 0
    foreach ($m in $tier1) {
        $p = Join-Path (Join-Path $PSScriptRoot 'Modules') "$m.psm1"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $importFail++; $failures.Add("missing module: $m"); continue }
        try { Import-Module $p -Force -Global -DisableNameChecking -ErrorAction Stop | Out-Null }
        catch { $importFail++; $failures.Add("import failed: $m - $($_.Exception.Message)") }
    }
    foreach ($m in @($tier1List.Providers)) {
        $p = Join-Path (Join-Path (Join-Path $PSScriptRoot 'Modules') 'Providers') "$m.psm1"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $importFail++; $failures.Add("missing provider: $m"); continue }
        try { Import-Module $p -Force -Global -DisableNameChecking -ErrorAction Stop | Out-Null }
        catch { $importFail++; $failures.Add("provider import failed: $m - $($_.Exception.Message)") }
    }
    if ($importFail -eq 0) { Write-Host (Resolve-LogMessage -Key 'log.gbuild.selftestImportsOk' -MessageArgs @($tier1.Count + @($tier1List.Providers).Count) -Fallback ("[SELFTEST] imports: OK ({0} modules)" -f ($tier1.Count + @($tier1List.Providers).Count))); $ok++ }
    else { Write-Host ("[SELFTEST] imports: FAILED ({0})" -f $importFail) -ForegroundColor Red }
    } # else: Tier-1 list resolved

    # 4b. Event payload contract (L5). The event-NAME registry was already
    # gated, but a publisher and its handler were bound only by agreeing on a
    # field name in two files. That agreement had rotted across most of the bus
    # - 11 handler reads named fields no publisher sends, so telemetry rendered
    # blanks and the build-error handler dropped the real diagnostic before the
    # alerting boundary. This makes the declared payload shape a checked
    # contract, so drift fails the self-test instead of printing empty lines.
    $pcFail = 0
    $pcPath = Join-Path (Join-Path $PSScriptRoot 'Modules') 'EventBus.psm1'
    if (-not (Test-Path -LiteralPath $pcPath -PathType Leaf)) {
        $pcFail++; $failures.Add('missing module: EventBus')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line299' -Fallback '[SELFTEST] event-contract: FAILED (validator absent)') -ForegroundColor Red
    } else {
        try {
            Import-Module $pcPath -Force -Global -DisableNameChecking -ErrorAction Stop
            $pc = Test-BuildEventPayloadContract -ModulesRoot (Join-Path $PSScriptRoot 'Modules')
            if ($pc.Passed) {
                $ok++
                Write-Host ("[SELFTEST] event-contract: OK ({0} handler(s) vs {1} declared payload(s))" -f $pc.Handlers, $pc.Events)
            } else {
                $pcFail++
                foreach ($o in @($pc.Offenders)) { $failures.Add("event payload: $o") }
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.selftestEventContractFailed' -MessageArgs @(@($pc.Offenders).Count) -Fallback ("[SELFTEST] event-contract: FAILED ({0} violation(s))" -f @($pc.Offenders).Count)) -ForegroundColor Red
            }
        } catch { $pcFail++; $failures.Add("event payload: $($_.Exception.Message)"); Write-Host (Resolve-LogMessage -Key 'log.gbuild.line312' -Fallback '[SELFTEST] event-contract: FAILED') -ForegroundColor Red }
    }

    # 4. Core command surface
    $core = @('Start-GBuild','Invoke-GuildChoice','Get-BuildState','Write-Log','Get-ConfigValue',
              'Get-BuildConstant','Get-BuildRootDirectory','Find-ProjectManifest','Import-GBuildModule')
    $cmdFail = 0
    foreach ($c in $core) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $cmdFail++; $failures.Add("missing command: $c") }
    }
    if ($cmdFail -eq 0) { Write-Host ("[SELFTEST] commands: OK ({0} resolved)" -f $core.Count); $ok++ }
    else { Write-Host ("[SELFTEST] commands: FAILED ({0} missing)" -f $cmdFail) -ForegroundColor Red }

    # 5. Module dependency graph (missing deps + import cycles).
    # ModuleDependencies.ps1 shipped fully implemented - a 60+ module graph
    # builder and an iterative-DFS cycle detector - but was reachable only from
    # the test suite, so no build verb and no CI gate ever checked it. A broken
    # dependency declaration therefore surfaced as an import failure at runtime
    # instead of as a self-test result. This is the check that makes the graph
    # self-policing.
    $depFail = 0
    $depPath = Join-Path (Join-Path $PSScriptRoot 'Modules') 'ModuleDependencies.psm1'
    if (-not (Test-Path -LiteralPath $depPath -PathType Leaf)) {
        $depFail++; $failures.Add('missing module: ModuleDependencies')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line336' -Fallback '[SELFTEST] dependencies: FAILED (validator absent)') -ForegroundColor Red
    } else {
        try {
            Import-Module $depPath -Force -Global -DisableNameChecking -ErrorAction Stop
            $depRoot = Join-Path $PSScriptRoot 'Modules'
            $verdict = Test-ModuleDependencies -ModulesRoot $depRoot
            if ($verdict -and $verdict.Passed) {
                $ok++
                Write-Host ("[SELFTEST] dependencies: OK ({0} modules, no missing deps, no cycles)" -f $verdict.ModuleCount)
            } else {
                $depFail++
                foreach ($m in @($verdict.Missing)) { $failures.Add("missing dependency: $($m.Module) -> $($m.MissingDep)") }
                foreach ($c in @($verdict.Cycles)) { $failures.Add("dependency cycle: $($c -join ' -> ')") }
                Write-Host ("[SELFTEST] dependencies: FAILED ({0})" -f $verdict.Summary) -ForegroundColor Red
            }
        } catch { $depFail++; $failures.Add("dependency graph: $($_.Exception.Message)"); Write-Host (Resolve-LogMessage -Key 'log.gbuild.line351' -Fallback '[SELFTEST] dependencies: FAILED') -ForegroundColor Red }
    }
    Write-Host ''
    # 6. Process self-measurement (CMMI L5). Everything above checks that the
    # platform RUNS. This checks that the platform can measure the PROCESS that
    # maintains it, and that no structural class has regressed below the
    # committed adoption floor.
    #
    # It is the only check that can fail on a codebase which is otherwise
    # perfectly healthy: six of the seven adoption classes were at 1.0 while
    # i18nProseCoverage sat at 37%, which no behavioural test can see.
    $pmFail = 0
    $pmPath = Join-Path (Join-Path $PSScriptRoot 'Modules') 'ProcessMetrics.psm1'
    if (-not (Test-Path -LiteralPath $pmPath -PathType Leaf)) {
        $pmFail++; $failures.Add('missing module: ProcessMetrics')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line366' -Fallback '[SELFTEST] process-metrics: FAILED (engine absent)') -ForegroundColor Red
    } else {
        try {
            Import-Module $pmPath -Force -Global -DisableNameChecking -ErrorAction Stop
            $pm = Get-BuildProcessMetrics -ToolRoot $PSScriptRoot
            if (-not $pm -or @($pm.Classes).Count -lt 7) { throw (Resolve-LogMessage -Key 'log.gbuild.selftestAdoptionClasses' -MessageArgs @([string]@($pm.Classes).Count) -Fallback "expected at least 7 adoption classes, measured $(@($pm.Classes).Count)") }
            $cmp = Compare-BuildProcessTrend -Metrics $pm -ToolRoot $PSScriptRoot
            if (-not $cmp.HasFloor) { throw (Resolve-LogMessage -Key 'log.gbuild.selftestNoFloor' -Fallback 'no committed adoptionFloor in Tests/process-baseline.json - the regression gate cannot decide anything') }
            if (@($cmp.Regressions).Count -gt 0) {
                $pmFail++
                foreach ($r in @($cmp.Regressions)) { $failures.Add("adoption regression: $($r.Class) is $([math]::Round($r.Current*100,1))%, floor is $([math]::Round($r.Floor*100,1))% ($($r.Metric))") }
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.selftestProcessMetricsFailed' -MessageArgs @(@($cmp.Regressions).Count) -Fallback ("[SELFTEST] process-metrics: FAILED ({0} class(es) below floor)" -f @($cmp.Regressions).Count)) -ForegroundColor Red
            } else {
                $ok++
                Write-Host ("[SELFTEST] process-metrics: OK ({0}/{1} classes at parity, mean {2:P1}, {3} site(s) outstanding)" -f $pm.ClassesAtParity, $pm.ClassCount, $pm.MeanAdoption, $pm.TotalRemaining)
            }
        } catch { $pmFail++; $failures.Add("process-metrics: $($_.Exception.Message)"); Write-Host (Resolve-LogMessage -Key 'log.gbuild.line382' -Fallback '[SELFTEST] process-metrics: FAILED') -ForegroundColor Red }
    }

    # 6b. SPC control limits (UCL/LCL). The floor gate above decides "not worse
    # than the committed minimum"; this gate decides "the process is stable".
    # Limits come from the recorded trend history (last -Window samples); below
    # MinSamples there is no verdict (fail-open) and the floor gate still
    # applies. Fails only on a DOWNWARD shift below the effective LCL; UCL
    # breaches are reported, never failed.
    if (Get-Command Compare-BuildProcessControl -ErrorAction SilentlyContinue) {
        try {
            $ctl = Compare-BuildProcessControl -ToolRoot $PSScriptRoot
            if (-not $ctl.HasLimits) {
                $ok++
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.controlInsufficient' -MessageArgs @([string]$ctl.Samples) -Fallback ("[SELFTEST] process-control: insufficient history ({0} sample(s)) - no verdict; adoptionFloor applies" -f $ctl.Samples))
            } elseif ($ctl.OutOfControl.Count -gt 0) {
                $names = (@($ctl.OutOfControl | ForEach-Object { $_.Class }) -join ', ')
                $failures.Add("process-control: below LCL: $names")
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.controlFailed' -MessageArgs @($names) -Fallback ("[SELFTEST] process-control: FAILED (below LCL: {0})" -f $names)) -ForegroundColor Red
            } else {
                $ok++
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.controlOk' -MessageArgs @([string]$ctl.Classes.Count, [string]$ctl.Window) -Fallback ("[SELFTEST] process-control: OK ({0} class(es) in control, window {1})" -f $ctl.Classes.Count, $ctl.Window))
            }
        } catch { $pmFail++; $failures.Add("process-control: $($_.Exception.Message)"); Write-Host (Resolve-LogMessage -Key 'log.gbuild.controlFailed' -MessageArgs @($_.Exception.Message) -Fallback ("[SELFTEST] process-control: FAILED ({0})" -f $_.Exception.Message)) -ForegroundColor Red }
    } else { $pmFail++; $failures.Add('Compare-BuildProcessControl unavailable') }

    # 6c. QPM measures (change failure rate + MTTR + escaped defects).
    # The gate reads ONLY: (a) the window change-failure rate against the
    # committed ceiling in Tests/process-baseline.json .qpm.maxChangeFailureRate,
    # (b) the validity of the escaped-defect ledger (Tests/qpm-ledger.json).
    # It deliberately does NOT gate on the escaped count: escapes happen, and a
    # build cannot pass with an UNLOGGED escape - visibility plus review
    # enforces logging, not the gate. Ceiling never rises to go green.
    $qpmWindow = 50; $qpmMax = 0.10
    try {
        $b2 = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Tests/process-baseline.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if (($b2.PSObject.Properties.Name -contains 'qpm') -and $b2.qpm) {
            if ($null -ne $b2.qpm.maxChangeFailureRate) { $qpmMax = [double]$b2.qpm.maxChangeFailureRate }
            if ($null -ne $b2.qpm.windowSamples) { $qpmWindow = [int]$b2.qpm.windowSamples }
        }
    } catch { }
    if (Get-Command Get-BuildQpmMeasures -ErrorAction SilentlyContinue) {
        try {
            $qpm = Get-BuildQpmMeasures -ToolRoot $PSScriptRoot -WindowSamples $qpmWindow
            $qpmGateOk = $true
            if (-not $qpm.LedgerValid) {
                $qpmGateOk = $false; $pmFail++
                $failures.Add("qpm ledger invalid: $(@($qpm.LedgerErrors) -join '; ')")
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.qpmLedgerFailed' -MessageArgs @([string]@($qpm.LedgerErrors).Count) -Fallback ("[SELFTEST] qpm: FAILED (escaped-defect ledger invalid: {0} error(s))" -f @($qpm.LedgerErrors).Count)) -ForegroundColor Red
            }
            if (($null -ne $qpm.ChangeFailureRate) -and ($qpm.ChangeFailureRate -gt $qpmMax)) {
                $qpmGateOk = $false; $pmFail++
                $failures.Add("qpm change failure rate $($qpm.ChangeFailureRate) exceeds ceiling $qpmMax over $($qpm.Samples) samples")
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.qpmRateFailed' -MessageArgs @([string]$qpm.ChangeFailureRate, [string]$qpmMax, [string]$qpm.Samples) -Fallback ("[SELFTEST] qpm: FAILED (change failure rate {0} exceeds ceiling {1} over {2} samples)" -f $qpm.ChangeFailureRate, $qpmMax, $qpm.Samples)) -ForegroundColor Red
            }
            if ($qpmGateOk) {
                $ok++
                $mttrText = if ($null -eq $qpm.MeanRecoveryTimeSeconds) { 'n/a' } else { "$($qpm.MeanRecoveryTimeSeconds)s" }
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.qpmOk' -MessageArgs @([string]$qpm.ChangeFailureRate, [string]$qpm.Samples, $mttrText, [string]$qpm.EscapedDefects) -Fallback ("[SELFTEST] qpm: OK (failure rate {0} over {1} sample(s); MTTR {2}; escaped defects {3}; ledger valid)" -f $qpm.ChangeFailureRate, $qpm.Samples, $mttrText, $qpm.EscapedDefects))
            }
        } catch { $pmFail++; $failures.Add("qpm: $($_.Exception.Message)") }
    } else { $pmFail++; $failures.Add('Get-BuildQpmMeasures unavailable') }

    # PSScriptAnalyzer gate (error/warning). Runs only when the analyzer module
    # is available (CI installs PSScriptAnalyzer 1.25.0; local dev may use the
    # bundled .tools copy). A missing analyzer degrades to a skip, never a fail.
    $psaFail = 0
    $psaModule = $null
    $psaBundled = Join-Path $PSScriptRoot '.tools/Modules/PSScriptAnalyzer/1.22.0/PSScriptAnalyzer.psd1'
    if (Test-Path -LiteralPath $psaBundled -PathType Leaf) {
        try { $psaModule = Import-Module $psaBundled -Force -PassThru -ErrorAction Stop } catch { $psaModule = $null }
    }
    if (-not $psaModule) {
        try { $psaModule = Import-Module PSScriptAnalyzer -PassThru -ErrorAction Stop } catch { $psaModule = $null }
    }
    if ($psaModule) {
        try {
            $psaSettingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
            $psaSettings = $null
            if (Test-Path -LiteralPath $psaSettingsPath -PathType Leaf) {
                try { $psaSettings = Invoke-Expression (Get-Content -LiteralPath $psaSettingsPath -Raw) } catch { $psaSettings = $null }
            }
            $psaRoots = @(
                (Join-Path $PSScriptRoot 'Modules')
                (Join-Path $PSScriptRoot 'Steps')
                (Join-Path $PSScriptRoot 'Hooks')
            )
            $psaFiles = @()
            foreach ($r in $psaRoots) {
                if (Test-Path -LiteralPath $r -PathType Container) {
                    $psaFiles += @(Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') })
                }
            }
            $psaFiles += @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.ps1' })
            $psaFindings = @()
            foreach ($f in $psaFiles) {
                try {
                    if ($psaSettings) {
                        $psaFindings += @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $psaSettings -ErrorAction SilentlyContinue)
                    } else {
                        $psaFindings += @(Invoke-ScriptAnalyzer -Path $f.FullName -Severity @('Error','Warning') -ErrorAction SilentlyContinue)
                    }
                } catch { }
            }
            if ($psaFindings.Count -gt 0) {
                $psaFail = $psaFindings.Count
                $failures.Add("PSScriptAnalyzer: $($psaFindings.Count) finding(s)")
                Write-Host ("[SELFTEST] psscriptanalyzer: FAILED ({0} finding(s))" -f $psaFindings.Count) -ForegroundColor Red
            } else {
                $ok++
                Write-Host (Resolve-LogMessage -Key 'log.gbuild.selftestPsaOk' -Fallback "[SELFTEST] psscriptanalyzer: OK") -ForegroundColor Green
            }
        } catch {
            Write-Host ("[SELFTEST] psscriptanalyzer: skipped ({0})" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.selftestPsaSkipped' -Fallback "[SELFTEST] psscriptanalyzer: skipped (module unavailable)") -ForegroundColor Yellow
    }

    if ($failures.Count -gt 0) {
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line386' -Fallback '[SELFTEST] FAILURES:') -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    }
    if ($failures.Count -eq 0) {
        Write-Host ("[SELFTEST] PASSED ({0}/{0} checks)" -f $ok) -ForegroundColor Green
        exit 0
    }
    Write-Host ("[SELFTEST] FAILED ({0} problem(s))" -f $failures.Count) -ForegroundColor Red
    exit 1
}

# ============================================================================
# -Help / -License intercepts (no project resolution, no build).
# ============================================================================
if ($Help.IsPresent) {
    # Single source: Documentation.Show-GBuildHelp (same text as menu 'H').
    # -Help is the ONE place for ALL commands (usage, switches, target
    # catalog, locales, examples). Falls back to the short summary below only
    # when the module is unavailable (partial copy) so -Help never fails.
    $helpShown = $false
    try {
        $docPath = Join-Path $PSScriptRoot 'Modules/Documentation.psm1'
        if ((-not (Get-Command Show-GBuildHelp -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $docPath -PathType Leaf)) {
            Import-Module $docPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
        if (Get-Command Show-GBuildHelp -ErrorAction SilentlyContinue) {
            Show-GBuildHelp
            $helpShown = $true
        }
    } catch { $helpShown = $false }
    if (-not $helpShown) {
        Write-Host ''
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line418' -Fallback '  gbuild - portable multi-language build system')
        Write-Host ''
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line420' -Fallback '  Usage:')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line421' -Fallback '    .\_Build\gbuild.ps1 [-Project <path>] [-Target <id>] [switches]')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line422' -Fallback '    ./_Build/gbuild     [-Project <path>] [-Target <id>] [switches]')
        Write-Host ''
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line424' -Fallback '  Switches: -GitHub -Incremental -Clean -CacheClear -CacheOptimize')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line425' -Fallback '    -CacheStats -VersionBump -Security -Distributed -NonInteractive')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line426' -Fallback '    -Force -VerifyInfra -SyntaxCheck -License -Help -Locale <code>')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line427' -Fallback '  Guides: -Locale list | -Target list')
        Write-Host ''
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line429' -Fallback '  Display language: -Locale <code> (e.g. -Locale vi) | env GBUILD_LOCALE')
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line430' -Fallback '    | config build.locale.default - run with -Locale list to see all languages.')
        Write-Host ''
    }
    exit 0
}

if ($License.IsPresent) {
    $licPath = Join-Path $PSScriptRoot 'LICENSE'
    if (Test-Path -LiteralPath $licPath -PathType Leaf) {
        Get-Content -LiteralPath $licPath -TotalCount 5 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host (Resolve-LogMessage -Key 'log.gbuild.line441' -Fallback 'gbuild - MIT License (see LICENSE file).')
    }
    exit 0
}

# ============================================================================
# Per-run overrides -> environment (consumed downstream by Locale/Orchestrator).
# ============================================================================
$nativeProject = ''
if (-not [string]::IsNullOrWhiteSpace($Project)) {
    # Normalize via PathUtils.Resolve-NativePath (single source): converts
    # Git-Bash/WSL '/c/...' forms to native paths on Windows, resolves to an
    # absolute path everywhere. Falls back to the raw value if unavailable.
    $nativeProject = $Project
    try {
        if (-not (Get-Command Resolve-NativePath -ErrorAction SilentlyContinue)) {
            $puPath = Join-Path $PSScriptRoot 'Modules/PathUtils.psm1'
            if (Test-Path -LiteralPath $puPath -PathType Leaf) {
                Import-Module $puPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
            }
        }
        if (Get-Command Resolve-NativePath -ErrorAction SilentlyContinue) {
            $resolved = Resolve-NativePath -Path $Project
            if (-not [string]::IsNullOrWhiteSpace($resolved)) { $nativeProject = $resolved }
        }
    } catch { $nativeProject = $Project }
    [Environment]::SetEnvironmentVariable('GBUILD_PROJECT', $nativeProject)
}
if (-not [string]::IsNullOrWhiteSpace($Locale)) {
    [Environment]::SetEnvironmentVariable('GBUILD_LOCALE', $Locale)
}

$__runLocation = try { (Get-Location).ProviderPath } catch { (Get-Location).Path }
$__tempFiles = [System.Collections.Generic.List[string]]::new()
$__priorState = $null
if (Test-Path Variable:global:GState) { $__priorState = $global:GState }
if ($__priorState) {
    try { if ($__priorState.TempFiles) { $__tempFiles = $__priorState.TempFiles } } catch { }
}
if (Test-Path Variable:global:GBuildServices) {
    try { $global:GBuildServices.Clear() } catch { }
}

# --- Project-root resolution (BEFORE any state/cache/report is written) -------
# Single source: Resolve-BuildProjectRoot in Modules/PathUtils.psm1. The
# launcher must not duplicate it. Previously ProjectRoot was simply the launch
# directory, so a run started from a directory with no build file of its own
# still dropped .gbuild-state.gbuildstate, .gbuildcache\ and build-reports\ into
# THAT directory -- including a filesystem volume root such as F:\. Discovery
# now walks up for a project marker, and a volume root is refused outright
# because it can never be a project.
$__projectRoot = $__runLocation
$__volumeRoot  = $false
$__refusal     = ''
$__candidates  = @()
if ([string]::IsNullOrWhiteSpace($nativeProject)) {
    try {
        $__pu = Join-Path $PSScriptRoot 'Modules/PathUtils.psm1'
        if (-not (Get-Command Resolve-BuildProjectRoot -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath $__pu -PathType Leaf) {
                Import-Module $__pu -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
            }
        }
        if (Get-Command Resolve-BuildProjectRoot -ErrorAction SilentlyContinue) {
            # ScriptRoot is passed so the tool tree itself stays exempt: running
            # gbuild from inside _Build (self-test / -SyntaxCheck) is legitimate
            # even on an install root with no project manifest.
            $__resolved = Resolve-BuildProjectRoot -StartDir $__runLocation -State ([PSCustomObject]@{ ScriptRoot = $PSScriptRoot })
            if ($__resolved -and -not [string]::IsNullOrWhiteSpace([string]$__resolved.Root)) {
                $__projectRoot = [string]$__resolved.Root
                $__volumeRoot = [bool]$__resolved.IsVolumeRoot
                $__candidates  = @($__resolved.Candidates)
                # A volume root can never be a project.
                if ($__volumeRoot) { $__refusal = 'volume-root' }
                # A directory with NO project manifest is not a project either.
                # Refusing here is what stops .gbuild-state.gbuildstate,
                # .gbuildcache\, build-reports\ and logs\ from being written NEXT
                # TO the _Build folder when the launch directory merely CONTAINS
                # projects - and stops one shared state/cache from serving every
                # project underneath it.
                elseif (-not [bool]$__resolved.HasMarker -and -not [bool]$__resolved.IsToolRoot) { $__refusal = 'no-project-marker' }
            }
        }
    } catch { $__projectRoot = $__runLocation; $__volumeRoot = $false; $__refusal = '' }
    if ($__refusal) {
        $__refusedFrom = $__runLocation
        $__refusalKind = [string]$__refusal
        $__found = @($__candidates)
        Remove-Variable -Name __runLocation,__tempFiles,__priorState,__projectRoot,__volumeRoot,__resolved,__pu,__refusal,__candidates -ErrorAction SilentlyContinue
        if ($__refusalKind -eq 'volume-root') {
            if (-not (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
                $null = Import-Module (Join-Path $PSScriptRoot 'Modules/Locale.psm1') -Global -DisableNameChecking -ErrorAction SilentlyContinue
            }
            Write-Host (Get-LocaleMessage -Key 'log.launcher.volumeRootRefusal' -MessageArgs @($__refusedFrom) -Fallback 'Refusing to build from a volume root: {0}') -ForegroundColor Red
            Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.volumeRootHint1' -Fallback 'A volume root cannot be a project.')) -ForegroundColor Red
            Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.volumeRootHint2' -Fallback 'Run gbuild from inside a project directory.')) -ForegroundColor Red
        } else {
            # Routed through the locale layer: a refusal is the first thing a
            # user in a non-English locale sees, and ProcessMetrics.psm1's
            # i18nProseCoverage ratchet measures exactly this kind of site.
            # Locale.psm1 is not loaded on the normal path (only for -Locale
            # help), so import it here on demand, same shape as the intercepts
            # above. -Fallback keeps the English text if loading fails.
            if (-not (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
                $null = Import-Module (Join-Path $PSScriptRoot 'Modules/Locale.psm1') -Global -DisableNameChecking -ErrorAction SilentlyContinue
            }
            # Tier 1 of Set-LocaleFromState, applied inline: honour an explicit
            # choice (-Locale sets GBUILD_LOCALE) without the device-cache write,
            # because this path exits before State exists.
            if ($PSBoundParameters.ContainsKey('Locale') -and -not [string]::IsNullOrWhiteSpace($Locale)) { $env:GBUILD_LOCALE = $Locale }
            $__pick = [Environment]::GetEnvironmentVariable('GBUILD_LOCALE')
            if (-not [string]::IsNullOrWhiteSpace($__pick) -and (Get-Command Set-CurrentLocale -ErrorAction SilentlyContinue)) {
                try { Set-CurrentLocale -Locale $__pick.Trim().ToLowerInvariant() } catch { }
            }
            Remove-Variable -Name __pick -ErrorAction SilentlyContinue
            Write-Host ("[FATAL] " + (Get-LocaleMessage -Key 'log.launcher.noProjectMarker' -MessageArgs @($__refusedFrom) -Fallback 'No project found at or above: {0}')) -ForegroundColor Red
            Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.noProjectMarkerHint' -Fallback 'That directory has no project manifest (*.sln, *.csproj, package.json, go.mod, Cargo.toml, pyproject.toml, pom.xml, CMakeLists.txt, ...).')) -ForegroundColor Red
            Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.noProjectMarkerWhy' -Fallback 'Building here would scatter gbuild state, cache, reports and logs beside _Build and make them shared across every project in here.')) -ForegroundColor Red
            if ($__found.Count -gt 0) {
                Write-Host '' -ForegroundColor Red
                Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.noProjectMarkerFound' -Fallback 'Projects found below it - build one with:')) -ForegroundColor Red
                foreach ($__c in @($__found)) { Write-Host ("          -Project ""{0}""" -f $__c) -ForegroundColor Yellow }
            } else {
                Write-Host ('        ' + (Get-LocaleMessage -Key 'log.launcher.noProjectMarkerFix' -Fallback 'Fix: pass -Project <path>, or run gbuild from inside the project.')) -ForegroundColor Red
            }
        }
        exit 1
    }
}

$global:GState = [PSCustomObject]@{
    TempFiles   = $__tempFiles
    ScriptRoot  = $PSScriptRoot
    ProjectRoot = $__projectRoot
    WorkingDir  = $__runLocation
}
Remove-Variable -Name __runLocation,__tempFiles,__priorState,__projectRoot,__volumeRoot,__resolved,__pu,__refusal,__candidates,__refusalKind,__refusedFrom -ErrorAction SilentlyContinue

# ============================================================================
# Normal bootstrap: load Orchestrator (Tier-1 chain) and dispatch Start-GBuild.
# Purge a same-named module loaded from a DIFFERENT _Build copy so every run
# uses THIS tree (mirrors Import-ModuleOnDemand anti-shadow guard).
# ============================================================================
try {
    $orchPath = Join-Path $PSScriptRoot 'Modules/Orchestrator.psm1'
    if (-not (Test-Path -LiteralPath $orchPath -PathType Leaf)) {
        Write-Host ("[FATAL] Required module not found: {0}" -f $orchPath) -ForegroundColor Red
        exit 1
    }
    $loaded = Get-Module -Name 'Orchestrator' -ErrorAction SilentlyContinue
    if ($loaded -and (($loaded.Path -and $loaded.Path -ne $orchPath) -or (-not $loaded.Path))) {
        Remove-Module -Name 'Orchestrator' -Force -ErrorAction SilentlyContinue
        $loaded = $null
    }
    if (-not $loaded) {
        Import-Module $orchPath -Force -Global -DisableNameChecking -ErrorAction Stop
    }
} catch {
    Write-Host ("[FATAL] Failed to load Orchestrator: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if (-not (Get-Command Start-GBuild -ErrorAction SilentlyContinue)) {
    Write-Host (Resolve-LogMessage -Key 'log.gbuild.line601' -Fallback '[FATAL] Start-GBuild not available after loading Orchestrator.') -ForegroundColor Red
    exit 1
}

# Explicit -Project authority: Find-Project honors $State.ExplicitProject +
# $State.ProjectRoot as the SINGLE source of truth (never silently falls back
# to the launch directory). Stamp both here so the contract holds for every
# run. Add-Member (not direct assignment): safe for missing props on
# restricted-adapter hosts (see Orchestrator Start-GBuild StartTime fix).
if (-not [string]::IsNullOrWhiteSpace($nativeProject)) {
    try {
        $gs = $null
        if (Get-Command Get-BuildState -ErrorAction SilentlyContinue) { $gs = Get-BuildState }
        if (-not $gs -and (Test-Path Variable:global:GState)) { $gs = $global:GState }
        if ($gs) {
            $gs | Add-Member -MemberType NoteProperty -Name 'ExplicitProject' -Value ([string]$nativeProject) -Force
            $gs | Add-Member -MemberType NoteProperty -Name 'ProjectRoot' -Value ([string]$nativeProject) -Force
        }
    } catch {
        Write-Host ("[FATAL] Failed to stamp explicit project root: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

$splat = @{}
if ($GitHub.IsPresent) { $splat['GitHub'] = $true }
if ($NonInteractive.IsPresent) { $splat['NonInteractive'] = $true }
if ($Incremental.IsPresent) { $splat['Incremental'] = $true }
if ($Clean.IsPresent) { $splat['Clean'] = $true }
if ($CacheClear.IsPresent) { $splat['CacheClear'] = $true }
if ($CacheOptimize.IsPresent) { $splat['CacheOptimize'] = $true }
if ($CacheStats.IsPresent) { $splat['CacheStats'] = $true }
if ($VersionBump.IsPresent) { $splat['VersionBump'] = $true }
if ($Force.IsPresent) { $splat['Force'] = $true }
if ($Security.IsPresent) { $splat['Security'] = $true }
if ($Distributed.IsPresent) { $splat['Distributed'] = $true }
if ($VerifyInfra.IsPresent) { $splat['VerifyInfra'] = $true }
if (-not [string]::IsNullOrWhiteSpace($Target)) { $splat['Target'] = $Target }
if (-not [string]::IsNullOrWhiteSpace($LogLevel)) { $splat['LogLevel'] = $LogLevel }

# Clear any verdict left by an earlier Start-GBuild in this session so a second
# run can never inherit the first run's non-zero code.
if (Get-Command Reset-GBuildExitCode -ErrorAction SilentlyContinue) { try { Reset-GBuildExitCode } catch { } }

# ============================================================================
# Exit-code contract (L4). Start-GBuild is a library function and never calls
# `exit`; enforcement gates (security / policy / supply-chain / SAST) record
# their verdict in the exit-code channel instead. Previously the rich ExitCode
# carried by New-OperationResult was computed and discarded, and this catch
# mapped EVERY throw to `exit 1` - so "dotnet not installed" (127), "plugin
# missing" (127) and "tests failed" (1) were indistinguishable to CI.
# ============================================================================
$__buildExit = 0
try {
    Start-GBuild @splat
    if (Get-Command Get-GBuildExitCode -ErrorAction SilentlyContinue) { $__buildExit = [int](Get-GBuildExitCode) }
} catch {
    $__buildError = $_
    $__buildExit = 1
    # Prefer the specific code a gate already recorded over the generic 1.
    if (Get-Command Get-GBuildExitCode -ErrorAction SilentlyContinue) {
        try { $__recorded = [int](Get-GBuildExitCode); if ($__recorded -gt 1) { $__buildExit = $__recorded } } catch { }
    }
    Write-Host ("[FATAL] Start-GBuild failed: {0}" -f $__buildError.Exception.Message) -ForegroundColor Red
}

if ($__buildExit -ne 0) {
    $__reasons = @()
    if (Get-Command Get-GBuildExitReason -ErrorAction SilentlyContinue) { try { $__reasons = @(Get-GBuildExitReason) } catch { } }
    if ($__reasons.Count -gt 0) {
        Write-Host ("[FATAL] Build gate(s) failed: {0}" -f ($__reasons -join ', ')) -ForegroundColor Red
    }
}
exit $__buildExit
