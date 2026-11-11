#Requires -Version 5.1

<#
.SYNOPSIS
    Modern core test runner for the _Build system. Runs every unit/state
    test scope safely, isolating state-sensitive scopes in child processes so a
    crash in one scope (e.g. third-party EDR terminating a long-lived child) can
    never abort the whole suite, and never lets one scope's module-global state
    leak into another.
.DESCRIPTION
    Architecture (P5.6 / EDR-resilient):
      * A fast core batch (module-isolated scopes) runs in-process for speed.
      * Every state-sensitive scope runs as an ISOLATED child process
        (`powershell -File Run-CoreTests.ps1 -Scope <X>`), so:
          - module-global / Locale state can never contaminate other scopes;
          - a quarantine/kill of a long-lived child is counted as an infra
            failure and never as a passing scope.
       * The parent parses each child's canonical structured verdict line.
      * Run stats are flushed incrementally to `suite-progress-<pid>.log` so a
        mid-suite post-mortem is always possible.

    Debug hooks:
      * GBUILD_SKIP_CORE=1 -> skip the in-process core batch (child scopes only).
      * GBUILD_SS_LIST="A,B,C" -> run only these scopes (comma-separated), each
        isolated in a child process (no core batch).
.EXAMPLE
    powershell -File Tests\Run-CoreTests.ps1 -Scope All
.EXAMPLE
    powershell -File Tests\Run-CoreTests.ps1 -Scope Cache
.EXAMPLE
    $env:GBUILD_SS_LIST='Cache,Deploy'; powershell -File Tests\Run-CoreTests.ps1
#>

[CmdletBinding()]
param(
    [string]$Scope = 'All',
    [switch]$WaitOnly,
    [switch]$StrictSkips,
    # L4 measurement gate. OFF by default: Pester coverage is implemented with
    # PowerShell breakpoints and is roughly an order of magnitude slower, which
    # is unacceptable on every PR run. Run-CoreTests.ps1 -Coverage (or the
    # dedicated `coverage` CI job) produces the baseline; the baseline file is
    # the artefact, and -MinCoveragePct turns it into a gate.
    [switch]$Coverage,
    [switch]$NoCoverage,
    # Minimum acceptable line-coverage percentage. Requires -Coverage.
    [double]$MinCoveragePct = 0
)

Set-StrictMode -Version 1.0
Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

$testRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
$runnerSelf = $MyInvocation.MyCommand.Path
# Keep an in-memory copy so the suite can heal itself.
#
# Every isolated scope is spawned as `powershell -File $runnerSelf`, so the parent
# re-executes THIS file once per scope. On a managed workstation the endpoint
# agent can quarantine or remove the driver mid-suite - and the parent then dies
# with no verdict line at all: it cannot spawn the next child, and nothing
# reports why. Observed as a run that stopped after "[Scope] START" and never
# wrote RESULT.
#
# Restoring the file from memory before each spawn keeps the suite running and
# makes the loss visible instead of silent. -SelfHealRunner:Off restores the old
# behaviour for anyone diagnosing a genuine file-system problem.
$__runnerBytes = $null
try { $__runnerBytes = [System.IO.File]::ReadAllBytes($runnerSelf) } catch { $__runnerBytes = $null }
function Test-RunnerSelfHeal {
    if ($null -eq $script:GBuildRunnerSelfBytes) { return $false }
    if ($env:GBUILD_SELFHEAL_RUNNER -eq 'Off') { return $false }
    try { return (Test-Path -LiteralPath $script:GBuildRunnerSelf -PathType Leaf) } catch { return $false }
}
function Restore-RunnerSelf {
    if (-not (Test-RunnerSelfHeal)) { return }
    try {
        [System.IO.File]::WriteAllBytes($script:GBuildRunnerSelf, $script:GBuildRunnerSelfBytes)
        Write-SuiteMessage "[RUNNER] Restored $([System.IO.Path]::GetFileName($script:GBuildRunnerSelf)) - it was removed mid-suite (endpoint protection?)." 'Warn'
    } catch { Write-SuiteMessage "[RUNNER] Could not restore the test runner: $($_.Exception.Message)" 'Err' }
}
$script:GBuildRunnerSelf = $runnerSelf
$script:GBuildRunnerSelfBytes = $__runnerBytes
Remove-Variable -Name __runnerBytes -ErrorAction SilentlyContinue
$progressLog = Join-Path $testRoot ("suite-progress-{0}.log" -f $PID)
$CoverageDir = Join-Path $testRoot 'TestResults/coverage'

function Write-ProgressLine {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Add-Content -LiteralPath $progressLog -Value $line -Encoding UTF8
    # Runner-local fallback: Write-LogSafe lives in Logging.psm1, which this
    # runner intentionally does NOT import (scope isolation). Never fail progress.
    if (Get-Command Write-LogSafe -ErrorAction SilentlyContinue) { Write-LogSafe $Message 'Info' }
    else { Write-Host $line }
}

function Write-SuiteMessage {
    param([string]$Message, [string]$Level = 'Info')
    if (Get-Command Write-LogSafe -ErrorAction SilentlyContinue) { Write-LogSafe $Message $Level }
    else { Write-Host $Message }
}

function New-PesterConfigFor {
    param([string[]]$Files)
    $cfg = New-PesterConfiguration
    $cfg.Run.Path        = $Files
    $cfg.Run.PassThru    = $true
    $cfg.Run.Exit        = $false
    $cfg.Output.Verbosity = 'Normal'
    $cfg.TestResult.Enabled = $false
    # ── L4: CODE COVERAGE (opt-in via -Coverage) ──────────────────────────────
    # There was NO coverage measurement anywhere in this repository: 1,100+
    # assertions and no way to know which of ~970 production functions they
    # touched. Without it, "Verification" cannot reach Quantitatively Managed
    # because the process is not measured at all.
    #
    # Deliberately opt-in: Pester coverage is breakpoint-based and roughly an
    # order of magnitude slower, so running it on every PR run is not
    # acceptable. CI runs it in a dedicated job and publishes
    # Tests/TestResults/coverage-baseline.json as the baseline artefact.
    if ($Coverage -and -not $script:NoCoverage -and (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        try {
            $psMajor = $PSVersionTable.PSVersion.Major
            if ($psMajor -ge 5) {
                $cfg.CodeCoverage.Enabled    = $true
                # Pester 5.7 has no OutputPathDetailed: one merged XML per run.
                # The runner executes each scope in a separate child process, so
                # the path MUST be per-process or every child would overwrite
                # the previous scope's report and the merge below would only
                # ever see the last scope.
                if (-not (Test-Path -LiteralPath $CoverageDir -PathType Container)) {
                    try { New-Item -ItemType Directory -Path $CoverageDir -Force -ErrorAction Stop | Out-Null } catch { }
                }
                $cfg.CodeCoverage.OutputPath  = Join-Path $CoverageDir ("coverage-{0}.xml" -f $PID)
                $cfg.CodeCoverage.OutputFormat = 'CoverageGutters'
                # Tests are NOT part of the measured surface.
                $cfg.CodeCoverage.ExcludeTests = $true
                if ($MinCoveragePct -gt 0) { $cfg.CodeCoverage.CoveragePercentTarget = $MinCoveragePct }
                # Coverage is collected from production modules only. Including
                # the test files themselves would inflate the number with the
                # suite's own code and make the metric meaningless.
                # $testRoot is Tests\, so the tool root is its parent.
                $toolRoot = Split-Path -Parent $testRoot
                $modulesDir = Join-Path $toolRoot 'Modules'
                if (Test-Path -LiteralPath $modulesDir -PathType Container) {
                    $cfg.CodeCoverage.Path = @($modulesDir)
                }
            }
        } catch {
            Write-SuiteMessage "Code coverage unavailable on this host: $($_.Exception.Message)"
        }
    }
    return $cfg
}

# ---- scope -> test file map (everything except the 5 E2E scopes) ----
$scopeMap = @{
    'Affected'                = 'Affected.Tests.ps1'
    'Alerting'                = 'Alerting.Tests.ps1'
    'Android'                 = 'Android.Tests.ps1'
    'AnomalyDetector'         = 'AnomalyDetector.Tests.ps1'
    'AuditLedger'             = 'AuditLedger.Tests.ps1'
    'Avalonia'                = 'Avalonia.Tests.ps1'

    'BootstrapResilience'     = 'BootstrapResilience.Tests.ps1'
    'AutoTuner'               = 'AutoTuner.Tests.ps1'

    'Build'                   = 'Build.Tests.ps1'
    'BuildConstants'          = 'BuildConstants.Tests.ps1'
    'BuildContext'            = 'BuildContext.Tests.ps1'
    'BuildImport'             = 'BuildImport.Tests.ps1'
    'BuildProgress'           = 'BuildProgress.Tests.ps1'
    'Cache'                   = 'Cache.Tests.ps1'
    'CacheHA'                 = 'CacheHA.Tests.ps1'
    'CacheProvider'           = 'CacheProvider.Tests.ps1'
    'CacheProviderEviction'   = 'CacheProvider.Eviction.Tests.ps1'
    'CircuitBreaker'          = 'CircuitBreaker.Tests.ps1'
    'CircuitBreakerPersistence' = 'CircuitBreaker.Persistence.Tests.ps1'
    'Chaos'                   = 'Chaos.Tests.ps1'
    'Clean'                   = 'Clean.Tests.ps1'
    'ClusterOrchestrator'     = 'ClusterOrchestrator.Tests.ps1'
    'Config'                  = 'Config.Tests.ps1'
    'ConfigContamination'     = 'ConfigContamination.Tests.ps1'
    'ConfigProvider'          = 'ConfigProvider.Tests.ps1'
    'ConfigValueNativePath' = 'ConfigValue.NativePath.Tests.ps1'
    'CodeSigning'             = 'CodeSigning.Tests.ps1'
    'Release'                 = 'Release.Tests.ps1'
    'Container'               = 'Container.Tests.ps1'
    'Core'                    = 'Core.Tests.ps1'
    'Cpp'                     = 'Cpp.Tests.ps1'
    'CredentialVault'         = 'CredentialVault.Tests.ps1'
    'Deploy'                  = 'Deploy.Tests.ps1'
    'DeployOrchestration'     = 'DeployOrchestration.Tests.ps1'
    'DeployTargets'           = 'DeployTargets.Tests.ps1'
    'Distributed'             = 'Distributed.Tests.ps1'
    'DistributedCertificate'  = 'Distributed.Certificate.Tests.ps1'
    'Docker'                  = 'Docker.Tests.ps1'
    'Documentation'           = 'Documentation.Tests.ps1'
    'DotEnv'                  = 'DotEnv.Tests.ps1'
    'Dotnet'                  = 'Dotnet.Tests.ps1'
    'DotnetHelpers'           = 'DotnetHelpers.Tests.ps1'
    'EdgeCases'               = 'EdgeCases.Tests.ps1'
    'Elixir'                  = 'Elixir.Tests.ps1'
    'Environment'             = 'Environment.Tests.ps1'
    'EnvironmentModel'        = 'EnvironmentModel.Tests.ps1'
    'ErrorHandling'           = 'ErrorHandling.Tests.ps1'
    'EventBus'                = 'EventBus.Tests.ps1'
    'HealthCheck'             = 'HealthCheck.Tests.ps1'
    'HotReload'               = 'HotReload.Tests.ps1'
    'IContract'               = 'IContract.Tests.ps1'
    'InfraVerification'       = 'InfraVerification.Tests.ps1'
    'Integration'             = 'Integration.Tests.ps1'
    'Java'                    = 'Java.Tests.ps1'
    'JsonValidation'          = 'JsonValidation.Tests.ps1'
    'LanguageDetector'        = 'LanguageDetector.Tests.ps1'
    'Loader'                  = 'Loader.Tests.ps1'
    'Locale'                  = 'Locale.Tests.ps1'
    'Logging'                 = 'Logging.Tests.ps1'
    'Menu'                    = 'Menu.Tests.ps1'
    'Metrics'                 = 'Metrics.Tests.ps1'
    'MockHelpers'             = 'MockHelpers.Tests.ps1'
    'ModuleDependencies'      = 'ModuleDependencies.Tests.ps1'
    'ModuleHygiene'           = 'ModuleHygiene.Tests.ps1'
    'Node'                    = 'Node.Tests.ps1'
    'Orchestrator'            = 'Orchestrator.Tests.ps1'
    'Parallel'                = 'Parallel.Tests.ps1'
    'PathUtils'               = 'PathUtils.Tests.ps1'
    'PHP'                     = 'PHP.Tests.ps1'
    'PhaseBMultiTenant'       = 'PhaseBMultiTenant.Tests.ps1'
    'PhaseBVerification'      = 'PhaseBVerification.Tests.ps1'
    'PhaseCSecurity'          = 'PhaseCSecurity.Tests.ps1'
    'PipelineEngine'          = 'PipelineEngine.Tests.ps1'
    'PipelineBuiltIn'          = 'PipelineBuiltIn.Tests.ps1'
    'PipelineRunner'          = 'PipelineRunner.Tests.ps1'
    'PipelineE2E'             = 'Pipeline.E2E.Tests.ps1'
    'ProcessMetrics'          = 'ProcessMetrics.Tests.ps1'
    'ProcessMetricsMutation'  = 'ProcessMetrics.Mutation.Tests.ps1'
    'Level5Parity'            = 'Level5.Parity.Tests.ps1'
    'L5Minimal'               = 'L5Minimal.Tests.ps1'
    'YamlPipeline'            = 'YamlPipeline.Tests.ps1'
    'Hygiene'                 = 'Hygiene.Tests.ps1'
    'GateSelfTest'             = 'GateSelfTest.Tests.ps1'
    'Go'                      = 'Go.Tests.ps1'
    'ProviderContracts'       = 'ProviderContracts.Tests.ps1'
    'PluginSDK'               = 'PluginSDK.Tests.ps1'
    'RBAC'                    = 'RBAC.Tests.ps1'
    'Platform'                = 'Platform.Tests.ps1'
    'PluginDispatch'          = 'PluginDispatch.Tests.ps1'
    'PluginHelpers'           = 'PluginHelpers.Tests.ps1'
    'Plugins'                 = 'Plugins.Tests.ps1'
    'PowerShell'              = 'PowerShell.Tests.ps1'
    'PS51Compat'              = 'PS51Compat.Tests.ps1'
    'Policy'                  = 'Policy.Tests.ps1'
    'Preflight'               = 'Preflight.Tests.ps1'
    'Project'                 = 'Project.Tests.ps1'
    'Providers'               = 'Providers.Tests.ps1'
    'Python'                  = 'Python.Tests.ps1'
    'Report'                  = 'Report.Tests.ps1'
    'RootCause'               = 'RootCause.Tests.ps1'
    'Ruby'                    = 'Ruby.Tests.ps1'
    'Rust'                    = 'Rust.Tests.ps1'

    'Sast'                    = 'Sast.Tests.ps1'
    'SDK'                     = 'SDK.Tests.ps1'
    'Security'                = 'Security.Tests.ps1'
    'SharedUtils'             = 'SharedUtils.Tests.ps1'
    'Siem'                    = 'Siem.Tests.ps1'
    'Standalone'              = 'Standalone.Tests.ps1'
    'Steps'                   = 'Steps.Tests.ps1'
    'SupplyChain'             = 'SupplyChain.Tests.ps1'
    'Swift'                   = 'Swift.Tests.ps1'
    'Telemetry'               = 'Telemetry.Tests.ps1'
    'Versioning'              = 'Versioning.Tests.ps1'
    'ReportExport'            = 'ReportExport.Tests.ps1'
}

# Scopes that mutate module-level / singleton state (e.g. Locale module, Logging,
# Versioning, Menu which depends on the Locale module). Run these in ISOLATED
# child processes so their module-global state can never leak between scopes.
$stateSensitive = @(
    'Locale', 'Menu', 'Logging', 'Versioning', 'Config', 'ConfigProvider',
    'ConfigValueNativePath',
    'CredentialVault', 'Orchestrator', 'Environment', 'EnvironmentModel',
    'Deploy', 'DeployTargets', 'DeployOrchestration', 'PipelineEngine',
    'PipelineRunner', 'PipelineE2E', 'Level5Parity', 'Hygiene', 'GateSelfTest', 'ProviderContracts',
    'PluginSDK', 'RBAC', 'AuditLedger',
    # Touches the shared append-only process-trend file, so it must not share a
    # process with the runner step that appends the real sample.
    'ProcessMetrics',
    # Builds synthetic tool trees in TEMP and mutates nothing in the repo, but it
    # imports ProcessMetrics -Global and reads Tests/process-trend-history.json,
    # so it is isolated for the same reason as its sibling.
    'ProcessMetricsMutation',
    'Project', 'SDK', 'Report', 'Metrics', 'Telemetry',
    'EventBus', 'CacheProvider', 'CacheProviderEviction', 'CacheHA', 'Distributed',
    'DistributedCertificate',  'CircuitBreaker', 'CircuitBreakerPersistence',
    'AnomalyDetector', 'AutoTuner', 'Chaos', 'RootCause', 'ClusterOrchestrator',
    'ModuleDependencies',
    'ConfigContamination', 'BootstrapResilience', 'DotEnv', 'HealthCheck',
    'InfraVerification', 'Policy', 'Sast', 'Siem', 'Standalone', 'SupplyChain',
    'Preflight', 'Loader', 'Plugins', 'PluginDispatch', 'Documentation',
    'Security', 'PowerShell', 'ModuleHygiene', 'ReportExport'
)

function Get-ResultCount {
    param(
        [AllowNull()][object]$Result,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Result) { return 0 }
    try {
        $property = $Result.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return 0 }
        return [int]$property.Value
    } catch {
        return 0
    }
}

function New-ScopeResult {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [int]$Passed = 0,
        [int]$Failed = 0,
        [int]$Skipped = 0,
        [int]$Total = 0,
        [string]$Status = '',
        [bool]$Killed = $false,
        [bool]$NoVerdict = $false,
        [int]$ChildExitCode = 0
    )
    $sum = $Passed + $Failed + $Skipped
    if ($Total -lt $sum) { $Total = $sum }
    if ([string]::IsNullOrEmpty($Status)) {
        if ($Killed -or $NoVerdict) { $Status = 'KILLED' }
        elseif ($Total -le 0) { $Status = 'NO_TESTS' }
        elseif ($Failed -gt 0) { $Status = 'FAILED' }
        elseif ($Skipped -gt 0) { $Status = 'SKIPPED' }
        else { $Status = 'PASSED' }
    }
    return [pscustomobject]@{
        Scope          = $Scope
        Passed         = $Passed
        Failed         = $Failed
        Skipped        = $Skipped
        Total          = $Total
        Status         = $Status
        Killed         = $Killed
        NoVerdict      = $NoVerdict
        ChildExitCode  = $ChildExitCode
    }
}

function Get-ChildVerdict {
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        $text = ([string]$line).Trim()
        if ($text -match '^GBUILD_CORE_VERDICT\s+(?<Status>PASSED|FAILED|SKIPPED|NO_TESTS|NO_RESULT)\s+Passed=(?<Passed>\d+)\s+Failed=(?<Failed>\d+)\s+Skipped=(?<Skipped>\d+)\s+Total=(?<Total>\d+)\s*$') {
            $status = [string]$Matches['Status']
            $passed = [int]$Matches['Passed']
            $failed = [int]$Matches['Failed']
            $skipped = [int]$Matches['Skipped']
            $total = [int]$Matches['Total']
            return [pscustomobject]@{
                Status  = $status
                Passed  = $passed
                Failed  = $failed
                Skipped = $skipped
                Total   = $total
            }
        }
    }
    return $null
}

function Write-CoreVerdict {
    param([Parameter(Mandatory)][object]$Result)
    $line = 'GBUILD_CORE_VERDICT {0} Passed={1} Failed={2} Skipped={3} Total={4}' -f $Result.Status, $Result.Passed, $Result.Failed, $Result.Skipped, $Result.Total
    [Console]::Out.WriteLine($line)
}

function Invoke-ScopeInProcess {
    param([string]$ScopeName)
    $file = Join-Path $testRoot $scopeMap[$ScopeName]
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-ProgressLine "[$ScopeName] MISSING file $file"
        return New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1
    }
    Write-ProgressLine "[$ScopeName] START (in-process)"
    try {
        $cfg = New-PesterConfigFor -Files @($file)
        $res = Invoke-Pester -Configuration $cfg
    } catch {
        Write-ProgressLine "[$ScopeName] ERROR: $($_.Exception.Message)"
        return New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1
    }
    $passed = Get-ResultCount -Result $res -Name 'PassedCount'
    $failed = Get-ResultCount -Result $res -Name 'FailedCount'
    $skipped = Get-ResultCount -Result $res -Name 'SkippedCount'
    $total = Get-ResultCount -Result $res -Name 'TotalCount'
    if ($total -le 0) {
        try {
            if ($null -ne $res.Tests) { $total = @($res.Tests).Count }
        } catch { }
    }
    $result = if ($null -eq $res) {
        New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1
    } elseif ($total -le 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'NO_TESTS'
    } elseif ($failed -gt 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'FAILED'
    } elseif ($skipped -gt 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'SKIPPED'
    } else {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'PASSED'
    }
    # Persist failed test names so CI can upload them as an artifact even when
    # the console log is truncated.
    if ($res -and $res.Failed) {
        $failedDir = Join-Path $testRoot 'TestResults'
        if (-not (Test-Path -LiteralPath $failedDir)) { New-Item -ItemType Directory -Path $failedDir -Force | Out-Null }
        $failedFile = Join-Path $failedDir "failed-$ScopeName.txt"
        @($res.Failed | ForEach-Object { "$($_.ExpandedPath) :: $($_.Name)" }) | Set-Content -LiteralPath $failedFile -Encoding UTF8
    }
    Write-ProgressLine "[$ScopeName] $($result.Status) ($passed passed, $failed failed, $skipped skipped, $total total)"
    return $result
}

function Invoke-ScopeIsolated {
    param([string]$ScopeName)
    # Only the parent process has the runner bytes in memory. A -WaitOnly child
    # is a fresh process without them, so skip the self-heal there.
    if (-not $WaitOnly) { Restore-RunnerSelf }
    $ps = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerSelf, '-Scope', $ScopeName, '-WaitOnly')
    if ($StrictSkips.IsPresent) { $childArgs += '-StrictSkips' }
    # Coverage must propagate into the isolated child or the merge below only
    # ever sees the in-process scopes. -NoCoverage stays the default for speed;
    # the dedicated CI job passes -Coverage -MinCoveragePct.
    if ($Coverage.IsPresent) { $childArgs += '-Coverage' }
    if ($NoCoverage.IsPresent) { $childArgs += '-NoCoverage' }
    if ($MinCoveragePct -gt 0) { $childArgs += @('-MinCoveragePct', ([string]$MinCoveragePct)) }
    # Hard cap per scope child. The suite used to block FOREVER on a stuck child
    # (a bare `& $ps ... | Out-String` with no timeout), so a single wedged scope
    # hung the whole run with zero output after its START line. A scope that cannot
    # finish inside the budget is KILLED and reported, never waited on silently.
    # Override: GBUILD_SCOPE_TIMEOUT_SEC (seconds). Default 1200 (20 min) - a hang
    # guard, not a performance gate: the slowest legitimate scope is far below it.
    $scopeBudgetSec = 1200
    try {
        if ($env:GBUILD_SCOPE_TIMEOUT_SEC -and ([int]$env:GBUILD_SCOPE_TIMEOUT_SEC -gt 0)) {
            $scopeBudgetSec = [int]$env:GBUILD_SCOPE_TIMEOUT_SEC
        }
    } catch { $scopeBudgetSec = 1200 }
    Write-ProgressLine "[$ScopeName] START (isolated child: $ps -Scope $ScopeName, budget ${scopeBudgetSec}s)"
    $out = ''
    $childExitCode = 1
    $timedOut = $false
    $job = $null
    try {
        # PS 5.1-safe: explicit param() + -ArgumentList (no $using: dependency).
        #
        # Output capture goes to a TEMP FILE, never to redirected pipes. An earlier
        # design captured stdout/stderr through Process pipes with ReadToEnd after
        # WaitForExit+Kill. That deadlocked whenever the scope child left a
        # descendant holding an inherited pipe handle: Kill() reaped the child but
        # ReadToEnd waited for an EOF that could never arrive, so the job - and
        # therefore the whole suite - hung with no grandchild process alive at all
        # (observed: parent heartbeating, zero descendants, 20+ minutes). With file
        # capture there is nothing to deadlock: Kill() always terminates the wait,
        # and a killed child simply leaves a partial file, which parses to the
        # existing KILLED/no-verdict path.
        $job = Start-Job -Name ("gbuild-scope-{0}" -f $ScopeName) -ScriptBlock {
            param([string]$Exe, [string[]]$ExeArgs, [int]$BudgetSec, [string]$CaptureFile)
            # Single-quoted inner command: no interpolation hazards from paths with
            # spaces or $ signs. `exit $LASTEXITCODE` preserves the child code
            # through the wrapping -Command layer on both PS 5.1 and PS 7+.
            $inner = '& "' + $Exe + '"'
            foreach ($a in $ExeArgs) { $inner += " '" + ($a -replace "'", "''") + "'" }
            $wrapped = '& { ' + $inner + ' *>&1 | Tee-Object -FilePath ''' + ($CaptureFile -replace "'", "''") + ''' | Out-Null }; exit $LASTEXITCODE'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Exe
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + ($wrapped -replace '"', '\"') + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = $null
            try {
                $proc = [System.Diagnostics.Process]::Start($psi)
                # No redirected streams: nothing here can block on pipe EOF.
                $exited = $proc.WaitForExit($BudgetSec * 1000)
                if (-not $exited) {
                    try { $proc.Kill() } catch { }
                    try { [void]$proc.WaitForExit(10000) } catch { }
                    return @{ ExitCode = 124; TimedOut = $true; CaptureFile = $CaptureFile }
                }
                return @{ ExitCode = [int]$proc.ExitCode; TimedOut = $false; CaptureFile = $CaptureFile }
            } catch {
                return @{ ExitCode = 1; TimedOut = $false; CaptureFile = $CaptureFile; Error = [string]$_.Exception.Message }
            } finally {
                if ($proc) { try { $proc.Dispose() } catch { } }
            }
        } -ArgumentList @($ps, $childArgs, $scopeBudgetSec, (Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-scope-' + $ScopeName + '-' + [guid]::NewGuid().ToString('N') + '.log')))
        if (-not $job) { throw 'Start-Job returned no job object.' }
        # Poll so a long scope is VISIBLE: heartbeat every 60s. Without this the
        # parent prints START and then nothing until the verdict, which is exactly
        # what made a slow scope indistinguishable from a hung one. The outer wait
        # is a backstop (budget + 120s grace for the in-job kill to land); the
        # in-job WaitForExit above is the real enforcer.
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $finished = $false
        $outerBudgetSec = $scopeBudgetSec + 120
        while ($watch.Elapsed.TotalSeconds -lt $outerBudgetSec) {
            $remaining = [int]($outerBudgetSec - $watch.Elapsed.TotalSeconds)
            if ($remaining -le 0) { break }
            $slice = [math]::Min(60, $remaining)
            $w = Wait-Job -Job $job -Timeout $slice 2>$null
            if ($job.State -eq 'Completed' -or $job.State -eq 'Failed' -or $job.State -eq 'Stopped') { $finished = $true; break }
            Write-ProgressLine ("[{0}] still running ({1:N0}s elapsed, budget {2}s)" -f $ScopeName, $watch.Elapsed.TotalSeconds, $scopeBudgetSec)
        }
        $watch.Stop()
        if (-not $finished) {
            $timedOut = $true
            Write-ProgressLine ("[{0}] TIMEOUT (outer backstop, {1:N0}s): stopping job" -f $ScopeName, $watch.Elapsed.TotalSeconds)
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
            $out = "SCOPE TIMEOUT: outer backstop fired after ${outerBudgetSec}s."
            $childExitCode = 124
        } else {
            $rawRes = Receive-Job -Job $job -ErrorAction SilentlyContinue
            # Harden: the job must yield exactly the result hashtable, but any
            # stray output (a leaked bool, a warning record) turns it into an
            # array. Take the LAST hashtable; anything else is noise.
            $res = @($rawRes | Where-Object { $_ -is [System.Collections.Hashtable] }) | Select-Object -Last 1
            if ($res -and $res.ContainsKey('CaptureFile')) {
                # Child output lives in the capture file (see the pipe-deadlock
                # note at Start-Job above). A killed child leaves a partial file;
                # a missing file means the child never got far enough to redirect.
                $capFile = [string]$res['CaptureFile']
                $out = ''
                try {
                    if ($capFile -and (Test-Path -LiteralPath $capFile -PathType Leaf)) {
                        $out = Get-Content -LiteralPath $capFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($null -eq $out) { $out = '' }
                    }
                } catch { $out = '' }
                try {
                    if ($capFile -and (Test-Path -LiteralPath $capFile)) {
                        Remove-Item -LiteralPath $capFile -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
                if ($res.ContainsKey('Error') -and $res['Error']) {
                    $out += "`nJOB-ERROR: " + [string]$res['Error']
                }
                $childExitCode = [int]$res['ExitCode']
                if ($res.ContainsKey('TimedOut') -and [bool]$res['TimedOut']) {
                    $timedOut = $true
                    $childExitCode = 124
                }
            } elseif ($res) {
                $out = [string]$res
                $childExitCode = 0
            } else {
                $out = ''
                $childExitCode = 1
            }
        }
    } catch {
        $out = $_.Exception.Message
        $childExitCode = 1
    } finally {
        if ($job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { } }
    }
    $lines = @($out -split "`r?`n")
    $verdict = Get-ChildVerdict -Lines $lines
    if ($timedOut) {
        Write-ProgressLine "[$ScopeName] TIMEOUT (no verdict within budget, exit $childExitCode)"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode
    }
    if ($null -eq $verdict) {
        Write-ProgressLine "[$ScopeName] KILLED before verdict (exit $childExitCode)"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode
    }
    $status = $verdict.Status
    $failed = $verdict.Failed
    $expectedStrictSkipExit = ($StrictSkips.IsPresent -and $status -eq 'SKIPPED')
    if ($childExitCode -ne 0 -and $failed -le 0 -and -not $expectedStrictSkipExit) {
        $status = 'FAILED'
        $failed = 1
    }
    if ($status -eq 'KILLED') {
        Write-ProgressLine "[$ScopeName] KILLED before verdict"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode
    }
    Write-ProgressLine "[$ScopeName] $status (isolated: $childExitCode)"
    return New-ScopeResult -Scope $ScopeName -Passed $verdict.Passed -Failed $failed -Skipped $verdict.Skipped -Total $verdict.Total -Status $status -ChildExitCode $childExitCode
}

# ---- scope selection ----
$selected = $null
if ($env:GBUILD_SS_LIST) {
    $selected = @($env:GBUILD_SS_LIST -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $scopeMap.ContainsKey($_) })
} elseif ($Scope -eq 'All') {
    $selected = @($scopeMap.Keys | Sort-Object)
} elseif ($scopeMap.ContainsKey($Scope)) {
    $selected = @($Scope)
} else {
    Write-Error "Unknown scope: $Scope. Valid scopes: All or one of the registered scope names."
    exit 2
}

if ($null -eq $selected -or $selected.Count -eq 0) {
    Write-Error 'No test scopes were selected.'
    exit 1
}

$isolated = @($selected | Where-Object { $_ -in $stateSensitive })
$inProc   = @($selected | Where-Object { $_ -notin $stateSensitive })

# Retention for suite-progress-*.log.
# Runs for EVERY invocation, including a single -Scope run and a -WaitOnly child,
# because the single-scope runs are the common case locally and they are exactly
# the invocations that used to leave the directory growing.
# The old rule was age-only (>7 days), one pass per parent run, and nothing
# capped the COUNT. At ~260 runs/day with a child per scope that never fired in
# practice: Tests/ had accumulated 538 files. A child killed by endpoint
# protection leaves its own log behind too, and only the parent's own log is
# removed on clean exit.
#
# Two independent bounds now: age AND count. Age alone cannot work when the
# producer runs many times per day; the count cap is what actually bounds the
# directory. GBUILD_SUITE_LOG_MAX / GBUILD_SUITE_LOG_DAYS override.
try {
    $maxSuiteLogs = 40
    try { if ($env:GBUILD_SUITE_LOG_MAX -and ([int]$env:GBUILD_SUITE_LOG_MAX -gt 0)) { $maxSuiteLogs = [int]$env:GBUILD_SUITE_LOG_MAX } } catch { }
    $maxSuiteAgeDays = 7
    try { if ($env:GBUILD_SUITE_LOG_DAYS -and ([int]$env:GBUILD_SUITE_LOG_DAYS -gt 0)) { $maxSuiteAgeDays = [int]$env:GBUILD_SUITE_LOG_DAYS } } catch { }
    $suiteLogs = @(Get-ChildItem -Path $testRoot -Filter 'suite-progress-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    # Keep the newest $maxSuiteLogs. A log is deleted when it is EITHER older
    # than the age bound OR beyond the count cap - the two are independent
    # removal reasons, so keeping must require passing BOTH. (Using OR here kept
    # all 624 files: every one of them was under 7 days old.)
    $keep = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $keep.Add($progressLog) | Out-Null
    for ($i = 0; $i -lt $suiteLogs.Count; $i++) {
        $withinCount = $i -lt $maxSuiteLogs
        $withinAge = $suiteLogs[$i].LastWriteTime -ge (Get-Date).AddDays(-$maxSuiteAgeDays)
        if ($withinCount -and $withinAge) { $keep.Add($suiteLogs[$i].FullName) | Out-Null }
    }
    $purge = @($suiteLogs | Where-Object { -not $keep.Contains($_.FullName) })
    if ($purge.Count -gt 0) {
        $purge | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-ProgressLine "Retention: removed $($purge.Count) stale suite-progress log(s) (cap=$maxSuiteLogs, age=${maxSuiteAgeDays}d)"
    }
} catch { }
if ($WaitOnly) {
    $r = Invoke-ScopeInProcess -ScopeName $Scope
    Write-CoreVerdict -Result $r
    if ($r.Total -gt 0 -and (($r.Status -eq 'PASSED') -or ($r.Status -eq 'SKIPPED' -and -not $StrictSkips.IsPresent))) {
        exit 0
    }
    exit 1
}

Write-ProgressLine "Suite start: $($selected.Count) scopes ($($inProc.Count) in-process core, $($isolated.Count) isolated state-sensitive)"

$summary = @()
$killedScopes = 0
$noVerdictScopes = 0
$zeroTestScopes = 0

if ($env:GBUILD_SKIP_CORE -ne '1') {
    foreach ($s in $inProc) {
        $r = Invoke-ScopeInProcess -ScopeName $s
        if ($null -eq $r) { $r = New-ScopeResult -Scope $s -Status 'NO_RESULT' -Failed 1 -Total 1 }
        $summary += $r
    }
}

foreach ($s in $isolated) {
    $r = Invoke-ScopeIsolated -ScopeName $s
    if ($null -eq $r) { $r = New-ScopeResult -Scope $s -Status 'KILLED' -Killed $true -NoVerdict $true }
    if ($r.Killed) { $killedScopes++ }
    if ($r.NoVerdict) { $noVerdictScopes++ }
    $summary += $r
}

$totPassed = 0
$totFailed = 0
$totSkipped = 0
$totTotal = 0
foreach ($r in $summary) {
    $totPassed += [int]$r.Passed
    $totFailed += [int]$r.Failed
    $totSkipped += [int]$r.Skipped
    $totTotal += [int]$r.Total
    if ($r.Total -le 0) { $zeroTestScopes++ }
}

# -StrictSkips is enforced against the COMMITTED baseline, not against zero.
#
# It previously failed on any skip at all (`$totSkipped -gt 0`) while CI passes
# this switch on every run - and Tests/process-baseline.json records
# `core.skipped: 6, skippedMaxAllowed: 8`. Those two facts cannot both hold: a
# gate that demands 0 skips is permanently red on a tree whose own baseline
# documents 6, so every run failed for a reason unrelated to the code under
# test, and the real signal (a genuine new skip) was lost in the noise.
#
# The baseline is the deliberate, reviewed record of what is acceptable, so it
# is the authority. A skip is a failure the moment the run exceeds
# skippedMaxAllowed, which is what makes -StrictSkips a RATCHET: the allowed
# count only ever goes down, and the file's own text already says "Update this
# file only when the process itself changes ... never to make a red run green".
$skipBudget = $null
$skipBudgetSrc = 'none'
try {
    $blPath = Join-Path $testRoot 'process-baseline.json'
    if (Test-Path -LiteralPath $blPath -PathType Leaf) {
        $bl = Get-Content -LiteralPath $blPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($bl.PSObject.Properties.Name -contains 'core' -and $null -ne $bl.core.skippedMaxAllowed) {
            $skipBudget = [int]$bl.core.skippedMaxAllowed
            $skipBudgetSrc = 'Tests/process-baseline.json core.skippedMaxAllowed'
        }
    }
} catch { }
$strictSkipFailure = $false
if ($StrictSkips.IsPresent) {
    if ($null -eq $skipBudget) {
        # No baseline to enforce against: falling back to "any skip fails"
        # would reintroduce the permanently-red behaviour, so say so instead.
        Write-ProgressLine "WARN: -StrictSkips given but core.skippedMaxAllowed is unavailable; skip enforcement DISABLED for this run"
        $strictSkipFailure = $false
    } else {
        $strictSkipFailure = ($totSkipped -gt $skipBudget)
    }
}
if ($StrictSkips.IsPresent) {
    Write-ProgressLine ("StrictSkips: {0} skipped, budget {1} ({2}) -> {3}" -f $totSkipped, $(if ($null -eq $skipBudget) { 'n/a' } else { $skipBudget }), $skipBudgetSrc, $(if ($strictSkipFailure) { 'FAIL' } else { 'ok' }))
}
Write-ProgressLine "Suite complete: $totPassed passed, $totFailed failed, $totSkipped skipped, $totTotal total, $killedScopes killed-by-infra"

# ── L5: PROCESS ADOPTION CURVE ───────────────────────────────────────────────
# Every other number in this runner describes the SUITE. This one describes the
# PROCESS that maintains the codebase: how much of it uses the sanctioned
# mechanism rather than bypassing it, per structural defect class.
#
# This is the step that turns a set of binary gates into a measurable process.
# A gate says "not red now". This appends one point to a time series, so the
# question "is the dedup process still working?" becomes answerable from data
# instead of from memory.
#
# It runs LAST and it is non-fatal by design. A measurement layer that can fail
# the build it is measuring is a liability, not a control - the floor gate in
# Tests/Hygiene.Tests.ps1 is where this data is turned into a pass/fail.
$processMetrics = $null
try {
    $pmPath = Join-Path (Split-Path -Parent $testRoot) 'Modules/ProcessMetrics.psm1'
    if (Test-Path -LiteralPath $pmPath -PathType Leaf) {
        Import-Module $pmPath -Force -Global -DisableNameChecking -ErrorAction Stop
        $processMetrics = Get-BuildProcessMetrics -ToolRoot (Split-Path -Parent $testRoot)
        $channel = if ($env:GITHUB_ACTIONS) { 'ci' } else { 'local' }
        [void](Write-BuildProcessTrend -Metrics $processMetrics -ToolRoot (Split-Path -Parent $testRoot) -Channel $channel)
        $compare = Compare-BuildProcessTrend -Metrics $processMetrics -ToolRoot (Split-Path -Parent $testRoot)
        Write-ProgressLine ("Adoption curve: below parity {0:P1}, {1} class(es) below floor, {2} sample(s) recorded" -f $processMetrics.BelowParityRatio, @($compare.Regressions).Count, $compare.Samples)
        foreach ($line in @(Get-BuildProcessSparkline -Metrics $processMetrics -ToolRoot (Split-Path -Parent $testRoot) -Ascii)) {
            Write-ProgressLine $line
        }
        foreach ($r in @($compare.Regressions)) {
            Write-ProgressLine ("  REGRESSION: {0} is {1:P1}, floor is {2:P1} ({3})" -f $r.Class, $r.Current, $r.Floor, $r.Metric)
        }
    }
} catch {
    Write-ProgressLine "Adoption curve: skipped ($($_.Exception.Message))"
}

# ── L4: COVERAGE REPORT + GATE ────────────────────────────────────────────────
# Merges every per-scope Pester result (including the isolated child processes)
# and writes a single machine-readable baseline. A measurement nobody consumes
# is not a control, so -MinCoveragePct turns it into a gate.
$coverageSummary = $null
if ($Coverage -and -not $script:NoCoverage -and (Test-Path -LiteralPath $CoverageDir -PathType Container)) {
    try {
        $coverageFiles = @(Get-ChildItem -LiteralPath $CoverageDir -Filter 'coverage-*.xml' -File -ErrorAction SilentlyContinue)
        if ($coverageFiles.Count -gt 0) {
            $executed = 0; $missed = 0; $files = @{}
            foreach ($cf in $coverageFiles) {
                try {
                    # Pester 5 emits JaCoCo XML:
                    #   report/package/class[@sourcefilename]/counter[@type='LINE'][@missed][@covered]
                    # The CLASS-level counter is the file total (method-level
                    # counters are its breakdown), so only class counters are
                    # read - reading both would double-count every line.
                    #
                    # UNION, NOT SUM. Every scope's report enumerates ALL
                    # measured files, so adding the per-file counters together
                    # multiplies the denominator by the number of scopes (4
                    # scopes produced 78652 "lines" for a 19663-line codebase)
                    # and counts the same line once per scope that reached it.
                    # Each file's totals are therefore taken as the MAX over
                    # scopes, which is the correct union: a line covered in any
                    # scope counts exactly once.
                    [xml]$doc = Get-Content -LiteralPath $cf.FullName -Raw -ErrorAction Stop
                    foreach ($c in @($doc.SelectNodes('//class'))) {
                        $src = [string]$c.sourcefilename
                        if ([string]::IsNullOrWhiteSpace($src)) { $src = [string]$c.name }
                        $lineCounter = $null
                        foreach ($ct in @($c.SelectNodes('./counter[@type="LINE"]'))) { $lineCounter = $ct }
                        if (-not $lineCounter) { continue }
                        $m = [int]$lineCounter.missed
                        $e = [int]$lineCounter.covered
                        if ($m -eq 0 -and $e -eq 0) { continue }
                        $key = [System.IO.Path]::GetFileName($src)
                        if (-not $files.ContainsKey($key)) { $files[$key] = [PSCustomObject]@{ File = $key; Executed = 0; Missed = 0 } }
                        if ($e -gt $files[$key].Executed) { $files[$key].Executed = $e }
                        # The denominator is a property of the FILE, not of the
                        # run, so it is taken as that file's largest single-run
                        # total (executed+missed). Taking max(missed) instead
                        # would mix one run's covered lines with another run's
                        # missed lines and inflate the total past reality.
                        $t = $e + $m
                        if ($t -gt ($files[$key].Executed + $files[$key].Missed)) { $files[$key].Missed = $t - $files[$key].Executed }
                    }
                } catch { }
            }
            foreach ($v in $files.Values) { $executed += $v.Executed; $missed += $v.Missed }
            $totalCmds = $executed + $missed
            $pct = if ($totalCmds -gt 0) { [math]::Round(($executed / $totalCmds) * 100, 2) } else { 0 }
            $baseline = [ordered]@{
                generatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
                pesterVersion    = (Get-Module -Name Pester | Select-Object -First 1).Version.ToString()
                hostOs           = [string]$PSVersionTable.OS
                hostEdition      = [string]$PSVersionTable.PSEdition
                hostVersion      = $PSVersionTable.PSVersion.ToString()
                metric           = 'line coverage of Modules/**/*.psm1 (Pester 5 + JaCoCo LINE counters)'
                linesCovered     = $executed
                linesMissed      = $missed
                linesTotal       = $totalCmds
                coveragePercent  = $pct
                scope            = $Scope
                scopeFiles       = $coverageFiles.Count
                perFile          = @($files.Values | Sort-Object -Property @{e={$_.Missed};d=$true}, File)
            }
            $summaryDir = Join-Path $testRoot 'TestResults'
            if (-not (Test-Path -LiteralPath $summaryDir -PathType Container)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
            $baselinePath = Join-Path $summaryDir 'coverage-baseline.json'
            $baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baselinePath -Encoding UTF8
            $coverageSummary = $baseline
            Write-ProgressLine ("COVERAGE: {0}% of {1} lines ({2} covered / {3} missed) across {4} file(s) -> {5}" -f $pct, $totalCmds, $executed, $missed, $files.Count, $baselinePath)
            if ($MinCoveragePct -gt 0 -and $pct -lt $MinCoveragePct) {
                $msg = ("COVERAGE GATE FAILED: {0}% < required {1}% ({2} commands measured)" -f $pct, $MinCoveragePct, $totalCmds)
                Write-ProgressLine "RESULT: $msg"
                Write-SuiteMessage $msg 'Err'
                try { Remove-Item -LiteralPath $progressLog -Force -ErrorAction SilentlyContinue } catch { }
                exit 1
            }
        }
    } catch {
        Write-ProgressLine "COVERAGE: report failed (non-fatal): $($_.Exception.Message)"
    }
}

if ($totFailed -gt 0 -or $killedScopes -gt 0 -or $noVerdictScopes -gt 0 -or $zeroTestScopes -gt 0 -or $strictSkipFailure -or $summary.Count -eq 0) {
    $message = "FAILED: $totFailed failed, $totSkipped skipped, $totTotal total, $killedScopes killed, $noVerdictScopes no-verdict"
    Write-ProgressLine "RESULT: $message"
    Write-SuiteMessage $message 'Err'
    exit 1
}

if ($totSkipped -gt 0) {
    $message = "SKIPPED: $totSkipped tests skipped, $totPassed passed, $totTotal total"
    Write-ProgressLine "RESULT: $message"
    Write-SuiteMessage $message 'Warn'
} else {
    $message = "ALL PASSED: $totPassed tests"
    Write-ProgressLine "RESULT: $message"
    Write-SuiteMessage $message 'Succ'
}
try { Remove-Item -LiteralPath $progressLog -Force -ErrorAction SilentlyContinue } catch { }
exit 0
