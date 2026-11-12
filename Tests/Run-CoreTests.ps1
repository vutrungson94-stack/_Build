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
    # Pester COMMAND-coverage target. Requires -Coverage. This is NOT the
    # line-coverage floor: Tests/process-baseline.json states the two metrics
    # must never be compared. The merged LINE-coverage gate reads
    # coverage.floorPercent from that baseline instead.
    [double]$MinCoveragePct = 0,
    # Parallel scope execution. 0 = auto: sequential (degree 1) unless -Coverage
    # is present, in which case every scope is scheduled through a bounded pool
    # of isolated child processes (degree = min(ProcessorCount, 16)). An explicit
    # value > 0 always wins; GBUILD_SCOPE_PARALLELISM overrides the auto rule.
    # Pester coverage is breakpoint-based and roughly an order of magnitude
    # slower, so a sequential coverage run of 112 scopes takes ~2 h and blows
    # the CI budget. Parallel children are still separate processes, so the
    # state-contamination guarantee of the sequential path is preserved.
    [int]$ParallelScopes = 0,
    # Where an isolated child writes its own console output. Set by the
    # parent when it spawns the child; empty when the script is run by hand.
    [string]$CaptureFile = '',
    # Where an isolated child writes its verdict line. The verdict used to
    # travel back through the job host's output stream; a FILE is simpler,
    # needs no pipe, and cannot deadlock on a descendant that keeps the pipe
    # handle open.
    [string]$VerdictFile = '',
    # Sharding. -Shard N of -ShardCount M runs only the N-th slice of the
    # scope list. The slices are balanced by the MEASURED cost of each scope
    # (Tests/TestResults/scope-timings.csv), so the long poles do not all
    # land in the same slice. The coverage job uses this to spread one
    # serial measurement over several machines and merge the results.
    [int]$Shard = 0,
    [int]$ShardCount = 0,
    # Merge only: do not run any scope, just merge the coverage XMLs that are
    # already in Tests/TestResults/coverage and enforce the line-coverage
    # floor. This is the second half of a sharded coverage run: every shard
    # measures its slice, this job merges the slices.
    [switch]$MergeOnly,
    # Optional tag embedded in the coverage report file name. The sharded CI run
    # passes "<shard>-<scope>" so two shards on different machines cannot
    # collide on a reused PID; an untagged local run keeps the legacy name.
    [string]$CoverageTag = ''
)

Set-StrictMode -Version 1.0
# Merge-only does not execute Pester: it parses the JaCoCo XMLs the shard jobs
# already produced. Importing Pester unconditionally made the merge job require
# a Pester install just to read XML, so a minimal merge job could never run.
if (-not $MergeOnly) {
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
}
# -NoCoverage must actually win over -Coverage. This flag is read through
# $script:NoCoverage in New-PesterConfigFor and in the merge below; before it
# was materialised here, the variable was never set, so -NoCoverage silently
# did nothing and the coverage gate ran anyway.
$script:NoCoverage = $NoCoverage.IsPresent

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
# Snapshot of the coverage XMLs that already exist. The merge at the end must
# read only files written by THIS run: Pester names them coverage-<PID>.xml and
# PIDs are reused, so a stale file from an earlier run would otherwise be merged
# as if its lines had been covered today, silently inflating the percentage the
# ratchet enforces.
$preExistingCoverageFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
if ($Coverage -and -not $script:NoCoverage) {
    if (Test-Path -LiteralPath $CoverageDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $CoverageDir -Filter 'coverage-*.xml' -File -ErrorAction SilentlyContinue)) {
            [void]$preExistingCoverageFiles.Add($f.FullName)
        }
    }
}

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

# Every scope child this runner started. The children are separate processes:
# if the runner dies (Ctrl+C, an unhandled error) they would keep running and
# write into the repository. The list lets the runner take them down with it.
$script:ChildProcesses = [System.Collections.Generic.List[object]]::new()

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
                # The file name carries a unique tag: PIDs are per-machine, so
                # two shards running on different machines can produce the SAME
                # PID, and the merged artefact would lose one of the two
                # reports. The sharded CI run passes -CoverageTag
                # "<shard>-<scope>"; a local run keeps the legacy shard tag.
                $shardTag = ''
                if ($CoverageTag) { $shardTag = '-' + ($CoverageTag -replace '[^A-Za-z0-9_.-]', '_') }
                elseif ($Shard -gt 0) { $shardTag = "-s$Shard" }
                $cfg.CodeCoverage.OutputPath  = Join-Path $CoverageDir ("coverage-{0}{1}.xml" -f $PID, $shardTag)
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
    'BuildHelpers'            = 'Build.Helpers.Tests.ps1'
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
    'HotReloadHelpers'        = 'HotReload.Helpers.Tests.ps1'
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
    'OrchestratorHelpers'     = 'Orchestrator.Helpers.Tests.ps1'
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
    'ProcessMetricsControl'  = 'ProcessMetrics.Control.Tests.ps1'
    'ProcessMetricsEngine'   = 'ProcessMetrics.Engine.Tests.ps1'
    'ProcessMetricsMutation'  = 'ProcessMetrics.Mutation.Tests.ps1'
    'ProcessMetricsRatchet'  = 'ProcessMetrics.Ratchet.Tests.ps1'
    'ProcessMetricsTrend'    = 'ProcessMetrics.Trend.Tests.ps1'
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
    'Runner'                  = 'Runner.Tests.ps1'
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
    #
    # The measurement engine was ONE scope and it was the long pole of the
    # whole coverage run. A single scope cannot be spread across the CI shards
    # by the cost balancer, so the shard that received it ran twice as long as
    # its siblings. It is now four scopes split by WHAT they measure - the
    # measurement itself is unchanged, but the work can be scheduled.
    'ProcessMetricsControl', 'ProcessMetricsEngine',
    'ProcessMetricsRatchet', 'ProcessMetricsTrend',
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
    'Security', 'PowerShell', 'ModuleHygiene', 'ReportExport',
    # Drives the runner itself as a child process and reads the timing table
    # it writes into Tests/TestResults, so it must not share a process with
    # the runner that spawned it.
    'Runner'
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

# The MEASURED cost of every scope, read from the timing table the last run
# published. A scope that was never measured costs 1, so the split still
# works on a fresh checkout.
function Get-ScopeCostTable {
    param([string]$Path)
    $costs = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) { return $costs }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $costs }
    try {
        foreach ($row in @(Import-Csv -LiteralPath $Path)) {
            $name = [string]$row.scope
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $value = 0.0
            try { $value = [double]$row.seconds } catch { $value = 0.0 }
            if ($value -lt 0) { $value = 0 }
            $costs[$name] = $value
        }
    } catch { }
    return $costs
}

# Split a scope list into balanced slices.
#
# Longest-processing-time-first: the most expensive scope goes to the slice
# that carries the least work so far. A round-robin would put Standalone,
# ProcessMetrics and Hygiene in the same slice whenever their names happen to
# line up, and that slice would then run twice as long as the others.
function Select-ShardScopes {
    param(
        [string[]]$Scopes,
        [int]$Shard,
        [int]$ShardCount,
        [hashtable]$Costs = @{}
    )
    if ($ShardCount -lt 1) { $ShardCount = 1 }
    if ($Shard -lt 1 -or $Shard -gt $ShardCount) { return @($Scopes) }
    $loads = New-Object double[] $ShardCount
    $assigned = @()
    for ($i = 0; $i -lt $ShardCount; $i++) { $assigned += ,([System.Collections.Generic.List[string]]::new()) }
    $ordered = @($Scopes | Sort-Object -Property `
        @{ Expression = { if ($Costs.ContainsKey($_)) { [double]$Costs[$_] } else { 1.0 } }; Descending = $true },
        @{ Expression = { $_ }; Descending = $false })
    foreach ($s in $ordered) {
        $cost = 1.0
        if ($Costs.ContainsKey($s)) { $cost = [double]$Costs[$s] }
        $lightest = 0
        for ($i = 1; $i -lt $ShardCount; $i++) {
            if ($loads[$i] -lt $loads[$lightest]) { $lightest = $i }
        }
        $assigned[$lightest].Add($s)
        $loads[$lightest] = $loads[$lightest] + $cost
    }
    return @($assigned[$Shard - 1])
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
        [int]$ChildExitCode = 0,
        # Wall-clock seconds this scope took. MEASURED, not estimated: before
        # this existed the suite could say how many tests passed but not WHERE
        # the time went, so every speed question was answered by reading
        # timestamps out of the CI log by hand.
        [double]$Seconds = 0
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
        Seconds        = [math]::Round($Seconds, 2)
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
    param(
        [Parameter(Mandatory)][object]$Result,
        # When set, the verdict is ALSO written to this file. The parent reads
        # it from there: a file cannot deadlock, and a pipe can.
        [string]$Path = ''
    )
    $line = 'GBUILD_CORE_VERDICT {0} Passed={1} Failed={2} Skipped={3} Total={4}' -f $Result.Status, $Result.Passed, $Result.Failed, $Result.Skipped, $Result.Total
    [Console]::Out.WriteLine($line)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Set-Content -LiteralPath $Path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

function Invoke-ScopeInProcess {
    param([string]$ScopeName)
    $file = Join-Path $testRoot $scopeMap[$ScopeName]
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-ProgressLine "[$ScopeName] MISSING file $file"
        return New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1
    }
    Write-ProgressLine "[$ScopeName] START (in-process)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cfg = New-PesterConfigFor -Files @($file)
        $res = Invoke-Pester -Configuration $cfg
    } catch {
        Write-ProgressLine "[$ScopeName] ERROR: $($_.Exception.Message)"
        return New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1 -Seconds $sw.Elapsed.TotalSeconds
    }
    $sw.Stop()
    $elapsed = $sw.Elapsed.TotalSeconds
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
        New-ScopeResult -Scope $ScopeName -Status 'NO_RESULT' -Failed 1 -Total 1 -Seconds $elapsed
    } elseif ($total -le 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'NO_TESTS' -Seconds $elapsed
    } elseif ($failed -gt 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'FAILED' -Seconds $elapsed
    } elseif ($skipped -gt 0) {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'SKIPPED' -Seconds $elapsed
    } else {
        New-ScopeResult -Scope $ScopeName -Passed $passed -Failed $failed -Skipped $skipped -Total $total -Status 'PASSED' -Seconds $elapsed
    }
    # Persist failed test names so CI can upload them as an artifact even when
    # the console log is truncated.
    #
    # A scope that PASSES removes its stale record. The files are what the CI
    # diagnosis step reads to find out WHICH scope failed, so a leftover from an
    # earlier run would send a maintainer to a scope that is green today - and
    # the artifact would claim a failure that no longer exists.
    if ($res -and $res.Failed) {
        $failedDir = Join-Path $testRoot 'TestResults'
        if (-not (Test-Path -LiteralPath $failedDir)) { New-Item -ItemType Directory -Path $failedDir -Force | Out-Null }
        $failedFile = Join-Path $failedDir "failed-$ScopeName.txt"
        @($res.Failed | ForEach-Object { "$($_.ExpandedPath) :: $($_.Name)" }) | Set-Content -LiteralPath $failedFile -Encoding UTF8
    } else {
        try { Remove-Item -LiteralPath (Join-Path $testRoot "TestResults/failed-$ScopeName.txt") -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-ProgressLine ("[$ScopeName] $($result.Status) ($passed passed, $failed failed, $skipped skipped, $total total, {0:N1}s)" -f $elapsed)
    return $result
}

function Start-ScopeChildJob {
    param([string]$ScopeName)
    # Only the parent process has the runner bytes in memory. A -WaitOnly child
    # is a fresh process without them, so skip the self-heal there.
    if (-not $WaitOnly) { Restore-RunnerSelf }
    $ps = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    # Hard cap per scope child. The suite used to block FOREVER on a stuck child
    # (a bare `& $ps ... | Out-String` with no timeout), so a single wedged scope
    # hung the whole run with zero output after its START line. A scope that cannot
    # finish inside the budget is KILLED and reported, never waited on silently.
    # Override: GBUILD_SCOPE_TIMEOUT_SEC (seconds). Default 1800 (30 min) - a hang
    # guard, not a performance gate. The slowest legitimate scope under
    # breakpoint-based coverage is ProcessMetrics (it rescans the tree ~12 times
    # per run, ~1100 s on a 28-core host); a budget below that silently kills it
    # and its module drops out of the coverage merge.
    $scopeBudgetSec = 1800
    try {
        if ($env:GBUILD_SCOPE_TIMEOUT_SEC -and ([int]$env:GBUILD_SCOPE_TIMEOUT_SEC -gt 0)) {
            $scopeBudgetSec = [int]$env:GBUILD_SCOPE_TIMEOUT_SEC
        }
    } catch { $scopeBudgetSec = 1800 }
    Write-ProgressLine "[$ScopeName] START (isolated child: $ps -Scope $ScopeName, budget ${scopeBudgetSec}s)"
    $captureFile = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-scope-' + $ScopeName + '-' + [guid]::NewGuid().ToString('N') + '.log')
    $verdictFile = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-verdict-' + $ScopeName + '-' + [guid]::NewGuid().ToString('N') + '.txt')
    $proc = $null
    try {
        # ONE process per scope.
        #
        # This used to be a Start-Job: the job host was a SECOND pwsh that
        # existed only to spawn the scope child and wait for it. On a four-core
        # runner that doubled the runnable processes per scope (job host +
        # child), so four concurrent scopes needed EIGHT processes plus the
        # parent - and every scope ran at a fraction of the speed it has alone.
        # Measured on the Ubuntu runner: the job took 589 s for 906 s of scope
        # work, where four-way scaling would give 227 s.
        #
        # The child writes its own console output to a capture FILE and its
        # verdict to a verdict FILE. No pipe is involved anywhere, which also
        # removes the deadlock class this file documents: an earlier design
        # captured stdout through .NET pipes and hung forever whenever a scope
        # child left a descendant holding the inherited pipe handle.
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + ($runnerSelf -replace '"', '') + '"' +
                   ' -Scope "' + ($ScopeName -replace '"', '') + '"' +
                   ' -WaitOnly' +
                   ' -CaptureFile "' + ($captureFile -replace '"', '') + '"' +
                   ' -VerdictFile "' + ($verdictFile -replace '"', '') + '"'
        if ($StrictSkips.IsPresent) { $argLine += ' -StrictSkips' }
        # Coverage must propagate into the isolated child or the merge below only
        # ever sees the in-process scopes. -NoCoverage stays the default for speed;
        # the dedicated CI job passes -Coverage.
        if ($Coverage.IsPresent) {
            $argLine += ' -Coverage'
            # A child's coverage file name must be unique across SHARDS, not
            # just across the scopes of one shard: the parent's own -Shard is
            # not passed down (the child runs exactly one scope, so sharding it
            # again would drop it), and PIDs are per-machine. The scope name is
            # unique within a run and the shard number separates the machines.
            $childTag = ('s{0}-{1}' -f $Shard, $ScopeName)
            $argLine += ' -CoverageTag "' + ($childTag -replace '"', '') + '"'
        }
        if ($NoCoverage.IsPresent) { $argLine += ' -NoCoverage' }
        if ($MinCoveragePct -gt 0) { $argLine += ' -MinCoveragePct ' + ([string]$MinCoveragePct) }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ps
        $psi.Arguments = $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # The child must NOT inherit this runner's stdin. A test that spawns an
        # MSYS2/mingw tool (git rev-parse in DeployTargets.Publish-Environment,
        # HealthCheck, Versioning) makes that runtime wait on stdin, and the
        # child - therefore the whole suite - hangs with no process left to
        # kill. Giving the child its own stdin pipe and closing it delivers
        # the EOF a non-interactive child expects.
        $psi.RedirectStandardInput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { throw 'the scope child could not be started.' }
        try { $proc.StandardInput.Close() } catch { }
        $script:ChildProcesses.Add($proc)
        return [pscustomobject]@{
            Scope       = $ScopeName
            Proc        = $proc
            BudgetSec   = $scopeBudgetSec
            CaptureFile = $captureFile
            VerdictFile = $verdictFile
            Started     = [System.Diagnostics.Stopwatch]::StartNew()
        }
    } catch {
        return [pscustomobject]@{
            Scope       = $ScopeName
            Proc        = $null
            BudgetSec   = $scopeBudgetSec
            CaptureFile = $captureFile
            VerdictFile = $verdictFile
            Started     = [System.Diagnostics.Stopwatch]::StartNew()
            StartError  = [string]$_.Exception.Message
        }
    }
}

function Complete-ScopeChildJob {
    param([Parameter(Mandatory)]$Wrapper)
    $ScopeName = [string]$Wrapper.Scope
    $scopeBudgetSec = [int]$Wrapper.BudgetSec
    $proc = $Wrapper.Proc
    $out = ''
    $childExitCode = 1
    $timedOut = $false
    # The wrapper's stopwatch starts when the child is LAUNCHED, so it covers
    # the whole life of the scope: spawn, run, verdict.
    $elapsed = 0.0
    try { $elapsed = [double]$Wrapper.Started.Elapsed.TotalSeconds } catch { $elapsed = 0.0 }
    if ($Wrapper.PSObject.Properties.Name -contains 'StartError' -and $Wrapper.StartError) {
        Write-ProgressLine "[$ScopeName] START-ERROR: $($Wrapper.StartError)"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode 1 -Seconds $elapsed
    }
    try {
        # Poll the child process so a long scope is VISIBLE: heartbeat every
        # 60 s. Without this the parent prints START and then nothing until
        # the verdict, which is exactly what made a slow scope
        # indistinguishable from a hung one.
        #
        # The budget is enforced HERE (the parent), not by the child: a child
        # that hangs cannot be trusted to time itself out.
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $exited = $false
        while ($watch.Elapsed.TotalSeconds -lt $scopeBudgetSec) {
            try { if ($proc.HasExited) { $exited = $true; break } } catch { $exited = $true; break }
            if ($watch.Elapsed.TotalSeconds -ge 60) {
                Write-ProgressLine ("[{0}] still running ({1:N0}s elapsed, budget {2}s)" -f $ScopeName, $watch.Elapsed.TotalSeconds, $scopeBudgetSec)
                $watch.Restart()
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $exited) {
            $timedOut = $true
            Write-ProgressLine ("[{0}] TIMEOUT (budget {1}s): killing the child" -f $ScopeName, $scopeBudgetSec)
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(10000) } catch { }
            $out = "SCOPE TIMEOUT: the child exceeded its ${scopeBudgetSec}s budget."
            $childExitCode = 124
        }
        else {
            try { $childExitCode = [int]$proc.ExitCode } catch { $childExitCode = 1 }
            # The verdict travels in a FILE, not through a pipe: no pipe can
            # deadlock on a descendant that keeps the handle open, and a
            # missing file simply means the child died before it could write
            # one (the KILLED/no-verdict path below).
            $verdictFile = [string]$Wrapper.VerdictFile
            if ($verdictFile -and (Test-Path -LiteralPath $verdictFile -PathType Leaf)) {
                try {
                    $out = Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($null -eq $out) { $out = '' }
                } catch { $out = '' }
                try { Remove-Item -LiteralPath $verdictFile -Force -ErrorAction SilentlyContinue } catch { }
            }
            else {
                $out = ''
            }
            # The child's console output lives in the capture file. It is kept
            # for the failure report: a red scope that only says "1 failed" is
            # not actionable, and the assertion text is right here.
            $capFile = [string]$Wrapper.CaptureFile
            if ($capFile -and (Test-Path -LiteralPath $capFile -PathType Leaf)) {
                try {
                    $captured = Get-Content -LiteralPath $capFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($captured) {
                        $tail = @($captured -split "`r?`n")
                        if ($tail.Count -gt 40) { $tail = $tail[($tail.Count - 40)..($tail.Count - 1)] }
                        $out += "`n" + ($tail -join "`n")
                    }
                } catch { }
                try { Remove-Item -LiteralPath $capFile -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch {
        $out = $_.Exception.Message
        $childExitCode = 1
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
    $lines = @($out -split "`r?`n")
    $verdict = Get-ChildVerdict -Lines $lines
    if ($timedOut) {
        Write-ProgressLine "[$ScopeName] TIMEOUT (no verdict within budget, exit $childExitCode)"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode -Seconds $elapsed
    }
    if ($null -eq $verdict) {
        Write-ProgressLine "[$ScopeName] KILLED before verdict (exit $childExitCode)"
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode -Seconds $elapsed
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
        return New-ScopeResult -Scope $ScopeName -Status 'KILLED' -Killed $true -NoVerdict $true -ChildExitCode $childExitCode -Seconds $elapsed
    }
    Write-ProgressLine ("[$ScopeName] $status (isolated: $childExitCode, {0:N1}s)" -f $elapsed)
    return New-ScopeResult -Scope $ScopeName -Passed $verdict.Passed -Failed $failed -Skipped $verdict.Skipped -Total $verdict.Total -Status $status -ChildExitCode $childExitCode -Seconds $elapsed
}


# Sequential path: start one child, wait for it, return its verdict. Kept as a
# thin wrapper so the sequential and parallel paths share ONE child-spawning
# implementation (Start-ScopeChildJob) and ONE verdict parser
# (Complete-ScopeChildJob) - a second copy of either would drift.
function Invoke-ScopeIsolated {
    param([string]$ScopeName)
    return Complete-ScopeChildJob -Wrapper (Start-ScopeChildJob -ScopeName $ScopeName)
}

# Resolve the concurrency degree for -ParallelScopes. Precedence:
#   1. an explicit -ParallelScopes N (N > 0)
#   2. GBUILD_SCOPE_PARALLELISM
#   3. auto: 1, or min(ProcessorCount, 8) when -Coverage is present
# The auto rule exists because a sequential coverage run of 112 scopes takes
# ~2 h (Pester coverage is breakpoint-based), which cannot fit any CI budget.
function Get-ParallelDegree {
    # $ExplicitDegree is passed in rather than read from $PSBoundParameters:
    # that automatic variable is scoped to the CURRENT command, so inside this
    # function it is the function's own (empty) parameter set and an explicit
    # -ParallelScopes on the runner would be silently ignored.
    param([int]$ExplicitDegree = 0)
    $degree = 1
    if ($ExplicitDegree -gt 0) {
        $degree = $ExplicitDegree
    } elseif ($env:GBUILD_SCOPE_PARALLELISM) {
        try { if ([int]$env:GBUILD_SCOPE_PARALLELISM -gt 0) { $degree = [int]$env:GBUILD_SCOPE_PARALLELISM } } catch { }
    } elseif ($Coverage.IsPresent) {
        $cores = 1
        try { $cores = [Environment]::ProcessorCount } catch { $cores = 1 }
        if ($cores -lt 1) { $cores = 1 }
        # 16, not 8: a full coverage run is now dominated by a single long
        # pole (ProcessMetrics measured 978 s while the whole suite was
        # 1,557 s), and the extra slots let the shorter scopes drain before
        # that pole finishes instead of queueing behind it. The cap still
        # scales down on small CI runners, and an explicit -ParallelScopes
        # or GBUILD_SCOPE_PARALLELISM always wins.
        $degree = [math]::Min($cores, 16)
    }
    if ($degree -lt 1) { $degree = 1 }
    return $degree
}

# Bounded pool over the scopes. Every scope in the pool runs as its own
# isolated child process (the same process boundary the sequential path uses
# for state isolation), so concurrency never reintroduces the module-global
# leakage the isolation exists to prevent. Each child still has its own
# budget; a wedged scope is killed and reported exactly as in the sequential
# path.
#
# -ForegroundScopes are the scopes the PARENT runs in-process while the pool
# works. The state-sensitive scopes keep their own child process (that is the
# isolation guarantee and it is not negotiable); the fast core batch has no
# shared state by definition, so it does not need a process of its own and
# would only pay a process startup for every one of its ~50 scopes. Running
# it here hides it INSIDE the pool's runtime instead of adding it to the
# critical path.
#
# -Costs is the measured per-scope cost table (scope-timings.csv). The queue
# is ordered LONGEST FIRST (longest-processing-time-first): the pool's wall
# clock is set by its slowest scope, so starting ProcessMetrics (measured
# 978 s) in the last wave instead of the first one added ~16 minutes to a
# measured full run. A scope with no measurement costs 1 s, so a fresh
# checkout still works and simply falls back to alphabetical order.
function Invoke-ScopesParallel {
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][int]$Degree,
        [string[]]$ForegroundScopes = @(),
        [hashtable]$Costs = @{}
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $orderedScopes = @($Scopes | Sort-Object -Property `
        @{ Expression = { if ($Costs.ContainsKey($_)) { [double]$Costs[$_] } else { 1.0 } }; Descending = $true },
        @{ Expression = { $_ }; Descending = $false })
    foreach ($s in $orderedScopes) { $queue.Enqueue($s) }
    $foreground = [System.Collections.Generic.Queue[string]]::new()
    foreach ($s in $ForegroundScopes) { $foreground.Enqueue($s) }
    $running = [System.Collections.Generic.Dictionary[string, object]]::new()
    $lastBeat = [System.Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0 -or $running.Count -gt 0 -or $foreground.Count -gt 0) {
        # Reap FIRST. A child that finished frees its slot, and a slot that is
        # freed late is a slot that stays empty while the next scope waits.
        $finished = @($running.Keys | Where-Object {
            $w = $running[$_]
            if ($w.PSObject.Properties.Name -contains 'StartError' -and $w.StartError) { return $true }
            $p = $w.Proc
            if (-not $p) { return $true }
            try { $p.HasExited } catch { $true }
        })
        foreach ($s in $finished) {
            $w = $running[$s]
            $results.Add((Complete-ScopeChildJob -Wrapper $w))
            # [void] is required: Dictionary.Remove returns [bool], and an
            # unsuppressed .NET return value is emitted into the pipeline,
            # which would add one stray item per scope to the suite summary.
            [void]$running.Remove($s)
        }
        # Then fill the pool up to the degree again.
        while ($queue.Count -gt 0 -and $running.Count -lt $Degree) {
            $s = $queue.Dequeue()
            $running[$s] = Start-ScopeChildJob -ScopeName $s
        }
        # Foreground work: ONE in-process scope per iteration. The children
        # keep running while the parent does this, so the core batch is
        # accounted for inside the pool's runtime instead of after it.
        if ($foreground.Count -gt 0) {
            $s = $foreground.Dequeue()
            $r = Invoke-ScopeInProcess -ScopeName $s
            if ($null -eq $r) { $r = New-ScopeResult -Scope $s -Status 'NO_RESULT' -Failed 1 -Total 1 }
            $results.Add($r)
            continue
        }
        if ($running.Count -eq 0 -and $queue.Count -eq 0) { break }
        if ($finished.Count -eq 0) {
            if ($lastBeat.Elapsed.TotalSeconds -ge 30) {
                $lastBeat.Restart()
                $runningList = (@($running.Keys | ForEach-Object {
                    $w = $running[$_]
                    ("{0} {1:N0}s/{2}s" -f $_, $w.Started.Elapsed.TotalSeconds, $w.BudgetSec)
                }) -join ', ')
                Write-ProgressLine ("[parallel] {0} running, {1} queued (degree {2}): {3}" -f $running.Count, $queue.Count, $Degree, $runningList)
            }
            # Poll: a short interval keeps the heartbeat uniform and lets a
            # finished child free its slot promptly. The interval was 5 s, and a
            # finished child waited that long for its slot to be reused - on a
            # 60-scope run that is up to 5 s of idle pool per scope, so the
            # pool ran at a fraction of its degree.
            Start-Sleep -Milliseconds 500
        }
    }
    return $results
}

# ---- scope selection ----
$swSuite = [System.Diagnostics.Stopwatch]::StartNew()
$summary = @()
$killedScopes = 0
$noVerdictScopes = 0
$zeroTestScopes = 0

$selected = $null
if ($MergeOnly) {
    # Merge a sharded coverage run: the per-shard XMLs are already present in
    # Tests/TestResults/coverage, so there is nothing to execute. The merge and
    # the line-coverage gate run below, and the run is a success when the gate
    # passes. $summary stays empty on purpose: the test verdict was decided by
    # the shard jobs that produced these reports.
    Write-ProgressLine "Merge-only: combining coverage reports from $CoverageDir"
    $script:NoCoverage = $false
    $selected = @()
}
elseif ($env:GBUILD_SS_LIST) {
    $selected = @($env:GBUILD_SS_LIST -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $scopeMap.ContainsKey($_) })
} elseif ($Scope -eq 'All') {
    $selected = @($scopeMap.Keys | Sort-Object)
} elseif ($scopeMap.ContainsKey($Scope)) {
    $selected = @($Scope)
} else {
    Write-Error "Unknown scope: $Scope. Valid scopes: All or one of the registered scope names."
    exit 2
}

if (-not $MergeOnly -and ($null -eq $selected -or $selected.Count -eq 0)) {
    Write-Error 'No test scopes were selected.'
    exit 1
}

# Sharding: keep only this shard's slice of the scope list. The slices are
# balanced by the MEASURED cost of every scope, so the three or four most
# expensive scopes end up in DIFFERENT shards instead of the same one.
# The same table orders the parallel pool (longest first), so it is read once.
$costTable = Get-ScopeCostTable -Path (Join-Path $testRoot 'TestResults/scope-timings.csv')
if (-not $MergeOnly -and $ShardCount -gt 1 -and $Shard -ge 1) {
    $selected = @(Select-ShardScopes -Scopes $selected -Shard $Shard -ShardCount $ShardCount -Costs $costTable)
    Write-ProgressLine "Shard $Shard of ${ShardCount}: $($selected.Count) scope(s) ($($selected -join ', '))"
    if ($selected.Count -eq 0) {
        Write-Error "Shard $Shard of $ShardCount has no scope to run."
        exit 1
    }
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
    # An isolated child. It runs its scope and reports the verdict.
    #
    # The console output is captured to a FILE by the child itself, and the
    # verdict is written to a FILE. Both used to travel through a job host
    # (a second pwsh per scope) and a pipe; a file needs neither, so the
    # scope costs ONE process and cannot deadlock on a descendant that keeps
    # an inherited pipe handle open.
    $r = $null
    if (-not [string]::IsNullOrWhiteSpace($CaptureFile)) {
        $script:__childScopeResult = $null
        & {
            $script:__childScopeResult = Invoke-ScopeInProcess -ScopeName $Scope
        } *>&1 | Tee-Object -FilePath $CaptureFile | Out-Null
        $r = $script:__childScopeResult
    }
    else {
        $r = Invoke-ScopeInProcess -ScopeName $Scope
    }
    Write-CoreVerdict -Result $r -Path $VerdictFile
    if ($r.Total -gt 0 -and (($r.Status -eq 'PASSED') -or ($r.Status -eq 'SKIPPED' -and -not $StrictSkips.IsPresent))) {
        exit 0
    }
    exit 1
}

if (-not $MergeOnly) {
    Write-ProgressLine "Suite start: $($selected.Count) scopes ($($inProc.Count) in-process core, $($isolated.Count) isolated state-sensitive)"
}
$parallelDegree = Get-ParallelDegree -ExplicitDegree $ParallelScopes
if (-not $MergeOnly -and $parallelDegree -gt 1 -and $selected.Count -gt 0) {
    if ($Coverage.IsPresent) {
        # Coverage path: EVERY scope is its own isolated child, scheduled
        # through a bounded pool. This is the coverage path: Pester coverage is
        # ~10x slower, so 112 sequential scopes take ~2 h. Children are still
        # separate processes, so the isolation guarantee is unchanged.
        # NB: the local is deliberately NOT named $parallelScopes. PowerShell
        # variable names are case-insensitive, so that name IS the [int]
        # -ParallelScopes parameter and assigning an array to it is a type error.
        $parallelScopeNames = $selected
        if ($env:GBUILD_SKIP_CORE -eq '1') {
            $parallelScopeNames = @($selected | Where-Object { $_ -in $stateSensitive })
        }
        Write-ProgressLine "Parallel execution: degree $parallelDegree over $($parallelScopeNames.Count) scope(s) (coverage: every scope is its own child, longest first)"
        $summary = @(Invoke-ScopesParallel -Scopes $parallelScopeNames -Degree $parallelDegree -Costs $costTable)
    }
    else {
        # HYBRID path: the SAME process topology as the sequential run - the
        # state-sensitive scopes keep their own child process, the fast core
        # batch runs in the parent - with the children running CONCURRENTLY.
        #
        # The isolation contract is untouched: a scope that mutates
        # module-global state still gets a process of its own, so two
        # concurrent scopes can never share that state. The only thing that
        # changed is WHEN the children run.
        #
        # This is what makes the CI job fast. Measured on the Ubuntu runner
        # (job "Core test suite (Ubuntu)", 114 scopes): the 64 state-sensitive
        # scopes cost 823 s one after another and the 50 in-process scopes
        # another 83 s - 945 s of critical path. With four children at a time
        # the same work is ~230 s.
        $foreground = if ($env:GBUILD_SKIP_CORE -eq '1') { @() } else { $inProc }
        Write-ProgressLine "Parallel execution: degree $parallelDegree over $($isolated.Count) isolated scope(s); $($foreground.Count) in-process scope(s) run in the parent meanwhile"
        $summary = @(Invoke-ScopesParallel -Scopes $isolated -Degree $parallelDegree -ForegroundScopes $foreground -Costs $costTable)
    }
} elseif (-not $MergeOnly) {
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
        $summary += $r
    }
}

# Take the scope children down with the runner. A child is a separate
# process: if the runner is interrupted (Ctrl+C, an unhandled error) the
# children would keep running and keep writing into the repository.
try {
    foreach ($p in @($script:ChildProcesses)) {
        try {
            if ($p -and -not $p.HasExited) {
                $p.Kill()
                Write-ProgressLine "Cleanup: stopped a scope child that was still running."
            }
        } catch { }
        try { $p.Dispose() } catch { }
    }
    $script:ChildProcesses.Clear()
} catch { }

foreach ($r in $summary) {
    if ($r.Killed) { $killedScopes++ }
    if ($r.NoVerdict) { $noVerdictScopes++ }
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

# ── L5: CLOSED CAUSAL LOOP ────────────────────────────────────────────────────
# A failed scope must OPEN a corrective-action record automatically. The causal
# loop used to be OPEN but not CLOSED: a red gate printed a line, the run
# ended, and opening the analysis record was a MANUAL step - so a defect could
# reach a green state with nothing behind it.
#
# RootCause.psm1 owns the CAR shape (New-CARRecord / New-VerificationCAR). The
# runner contributes only the evidence it already has: the failing scope, the
# failing test names, and the gate that fired. The record is written to the run
# artefact directory (Tests/TestResults/car) so CI can publish it, and to the
# CAR ledger next to the other root-cause evidence.
function Open-VerificationCARs {
    $resultDir = Join-Path $testRoot 'TestResults'
    $failedFiles = @(Get-ChildItem -LiteralPath $resultDir -Filter 'failed-*.txt' -File -ErrorAction SilentlyContinue)
    if ($failedFiles.Count -eq 0) { return 0 }
    $toolRoot = Split-Path -Parent $testRoot
    $rcPath = Join-Path $toolRoot 'Modules/RootCause.psm1'
    if (-not (Get-Command New-VerificationCAR -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $rcPath -PathType Leaf) {
            try { $null = Import-Module $rcPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue } catch { }
        }
    }
    if (-not (Get-Command New-VerificationCAR -ErrorAction SilentlyContinue)) {
        Write-ProgressLine 'CAR: skipped (RootCause module unavailable - the corrective-action record could not be opened)'
        return 0
    }
    $opened = 0
    foreach ($f in $failedFiles) {
        $scopeName = $f.BaseName -replace '^failed-', ''
        if ([string]::IsNullOrWhiteSpace($scopeName)) { continue }
        $names = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        try {
            $record = New-VerificationCAR -Scope $scopeName -FailedTests $names `
                -GateThatMissed 'core suite scope verdict (Tests/Run-CoreTests.ps1)' `
                -DetectedBy ("Pester scope {0}" -f $scopeName)
            $carDir = Join-Path $resultDir 'car'
            if (-not (Test-Path -LiteralPath $carDir -PathType Container)) {
                New-Item -ItemType Directory -Path $carDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $carDir ("car-{0}.json" -f $scopeName)) -Encoding UTF8
            try {
                $null = Write-CARRecord -Record $record -State ([PSCustomObject]@{ WorkingDir = $toolRoot })
            } catch { }
            Write-ProgressLine ("CAR opened for scope {0}: {1} (Tests/TestResults/car/car-{0}.json)" -f $scopeName, $record.Id)
            $opened++
        } catch {
            Write-ProgressLine ("CAR for scope {0} could not be opened: {1}" -f $scopeName, $_.Exception.Message)
        }
    }
    return $opened
}

# ── PER-SCOPE TIMING ──────────────────────────────────────────────────────────
# The suite can say how many tests passed, but until now it could not say
# WHERE the time went: every speed question was answered by scraping
# timestamps out of the CI log by hand. The measurement is written next to the
# results so the next person does not have to redo it, and the slowest scopes
# are named in the log so the hot spot is visible without any tooling.
#
# The CSV is a DIAGNOSTIC, not a gate: nothing fails because of it, and the
# order of the rows is by cost so the head of the file is the answer.
try {
    $timingDir = Join-Path $testRoot 'TestResults'
    if (-not (Test-Path -LiteralPath $timingDir -PathType Container)) {
        New-Item -ItemType Directory -Path $timingDir -Force | Out-Null
    }
    $byCost = @($summary | Sort-Object -Property @{ Expression = { $_.Seconds }; Descending = $true })
    # MERGE with the table that is already there. A partial run (one scope, the
    # way a developer reproduces a failure) used to REPLACE the table with its
    # own single row - and the table is the cost input of the longest-first
    # scheduler, so the next full run fell back to "every scope costs 1 s" and
    # started the long pole last. The rows of the scopes this run did NOT
    # execute keep their last measurement; the rows it did execute are
    # replaced by the fresh measurement.
    $timingPath = Join-Path $timingDir 'scope-timings.csv'
    $timings = [ordered]@{}
    try {
        if (Test-Path -LiteralPath $timingPath -PathType Leaf) {
            foreach ($row in @(Import-Csv -LiteralPath $timingPath -ErrorAction SilentlyContinue)) {
                $name = [string]$row.scope
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                # A row for a scope that no longer EXISTS is dropped: the table
                # describes the suite as it is, and a leftover row for a scope
                # that was split or renamed would keep a cost that nothing pays.
                if (-not $scopeMap.ContainsKey($name)) { continue }
                $timings[$name] = [PSCustomObject]@{
                    Scope = $name
                    Seconds = [double]$row.seconds
                    Status = [string]$row.status
                    Passed = [int]$row.passed
                    Skipped = [int]$row.skipped
                    Total = [int]$row.total
                }
            }
        }
    } catch { }
    foreach ($r in $summary) {
        $timings[$r.Scope] = [PSCustomObject]@{
            Scope = $r.Scope
            Seconds = [double]$r.Seconds
            Status = [string]$r.Status
            Passed = [int]$r.Passed
            Skipped = [int]$r.Skipped
            Total = [int]$r.Total
        }
    }
    $lines = @('scope,seconds,status,passed,skipped,total')
    foreach ($row in @($timings.Values | Sort-Object -Property @{ Expression = { $_.Seconds }; Descending = $true })) {
        $lines += ('{0},{1},{2},{3},{4},{5}' -f $row.Scope, $row.Seconds, $row.Status, $row.Passed, $row.Skipped, $row.Total)
    }
    $lines | Set-Content -LiteralPath $timingPath -Encoding UTF8
    $slow = @($byCost | Select-Object -First 10)
    if ($slow.Count -gt 0) {
        Write-ProgressLine ("Slowest scopes: " + (($slow | ForEach-Object { "{0} {1:N1}s" -f $_.Scope, $_.Seconds }) -join ', '))
    }
    $wallTotal = 0.0
    foreach ($r in $summary) { $wallTotal += [double]$r.Seconds }
    Write-ProgressLine ("Scope timing: {0:N1}s of scope work over {1:N1}s of wall clock (degree {2})" -f $wallTotal, $swSuite.Elapsed.TotalSeconds, $parallelDegree)
    Write-ProgressLine ("Scope cost table: {0} scope(s) known ({1} measured by this run)" -f $timings.Count, $summary.Count)
}
catch {
    Write-ProgressLine "Scope timing: not written ($($_.Exception.Message))"
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

# ── L5: AUTOMATIC CORRECTIVE-ACTION RECORDS ───────────────────────────────────
# Every failed scope opens a CAR here, BEFORE the verdict is printed, so the
# analysis record exists even when the run ends in a red exit code (and even in
# the merge job, where the shard artefacts carry the failed-scope files).
try {
    $carsOpened = Open-VerificationCARs
    if ($carsOpened -gt 0) { Write-ProgressLine "Corrective-action records opened: $carsOpened" }
} catch {
    Write-ProgressLine "Corrective-action records could not be opened: $($_.Exception.Message)"
}

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
#
# A SHARD IS NOT A SUITE. A shard measures a slice of the scopes, so its
# percentage is a PARTIAL measurement of the codebase - comparing it with the
# global floor is a category error: shard 2 of 4 measured 20.67% of the lines
# while the whole suite measures 56%, and the shard job failed against the very
# floor the merge job exists to enforce. The floor is therefore enforced in
# exactly two places: a whole-suite run (no sharding) and the merge job that
# holds every shard's reports. A shard publishes its partial figure as a
# diagnostic and never as the baseline.
$coverageSummary = $null
$isPartialShard = ($ShardCount -gt 1 -and $Shard -ge 1 -and -not $MergeOnly)
if ((($Coverage -and -not $script:NoCoverage) -or $MergeOnly) -and (Test-Path -LiteralPath $CoverageDir -PathType Container)) {
    try {
        # The "ignore what was already there" filter protects a normal run
        # from merging a stale report. A MERGE run is the opposite: the
        # reports it merges were DOWNLOADED into the folder before this
        # process started, so filtering them out would merge nothing at all.
        $coverageFiles = @(Get-ChildItem -LiteralPath $CoverageDir -Filter 'coverage-*.xml' -File -ErrorAction SilentlyContinue |
            Where-Object { $MergeOnly -or -not $preExistingCoverageFiles.Contains($_.FullName) })
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
                        $instrCounter = $null
                        foreach ($ct in @($c.SelectNodes('./counter'))) {
                            if ([string]$ct.type -eq 'LINE') { $lineCounter = $ct }
                            elseif ([string]$ct.type -eq 'INSTRUCTION') { $instrCounter = $ct }
                        }
                        if (-not $lineCounter) { continue }
                        $m = [int]$lineCounter.missed
                        $e = [int]$lineCounter.covered
                        if ($m -eq 0 -and $e -eq 0) { continue }
                        # The INSTRUCTION counter is the same run's BYTECODE
                        # view of the same files. It is collected here so every
                        # published coverage number comes from ONE artefact set
                        # with ONE union rule - the repository used to publish a
                        # line figure from the merged XMLs and a command figure
                        # from Pester's in-process analysis, which are different
                        # metrics over different data and cannot be compared.
                        $im = 0; $ie = 0
                        if ($instrCounter) { $im = [int]$instrCounter.missed; $ie = [int]$instrCounter.covered }
                        $key = [System.IO.Path]::GetFileName($src)
                        if (-not $files.ContainsKey($key)) { $files[$key] = [PSCustomObject]@{ File = $key; Executed = 0; Total = 0; InstrExecuted = 0; InstrTotal = 0 } }
                        if ($e -gt $files[$key].Executed) { $files[$key].Executed = $e }
                        # The denominator is a property of the FILE, not of the
                        # run: a line covered in ANY scope counts once, so the
                        # covered count is the max over scopes and the total is
                        # the file's largest single-run total (executed+missed).
                        #
                        # Missed must be DERIVED as Total-Executed afterwards.
                        # Updating Missed directly (as this code used to) only
                        # refreshed it when the total grew, so a later run that
                        # covered more lines left the earlier run's Missed in
                        # place and the denominator was inflated: SDK.psm1
                        # reported 375 covered + 995 missed = 1370 lines when
                        # the file has 995, i.e. the merge silently deflated the
                        # percentage it exists to enforce.
                        $t = $e + $m
                        if ($t -gt $files[$key].Total) { $files[$key].Total = $t }
                        if ($ie -gt $files[$key].InstrExecuted) { $files[$key].InstrExecuted = $ie }
                        $it = $ie + $im
                        if ($it -gt $files[$key].InstrTotal) { $files[$key].InstrTotal = $it }
                    }
                } catch { }
            }
            $instrExecuted = 0
            $instrTotal = 0
            foreach ($v in $files.Values) {
                $executed += $v.Executed
                $missed += ($v.Total - $v.Executed)
                $instrExecuted += $v.InstrExecuted
                $instrTotal += $v.InstrTotal
            }
            $totalCmds = $executed + $missed
            $pct = if ($totalCmds -gt 0) { [math]::Round(($executed / $totalCmds) * 100, 2) } else { 0 }
            $instrTotalCmds = $instrExecuted + ($instrTotal - $instrExecuted)
            $instrPct = if ($instrTotalCmds -gt 0) { [math]::Round(($instrExecuted / $instrTotalCmds) * 100, 2) } else { 0 }
            $baseline = [ordered]@{
                generatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
                pesterVersion    = $(if ($MergeOnly) { $pm = Get-Module -ListAvailable -Name Pester | Select-Object -First 1; if ($pm) { $pm.Version.ToString() } else { 'n/a (merge-only)' } } else { (Get-Module -Name Pester | Select-Object -First 1).Version.ToString() })
                hostOs           = [string]$PSVersionTable.OS
                hostEdition      = [string]$PSVersionTable.PSEdition
                hostVersion      = $PSVersionTable.PSVersion.ToString()
                metric           = 'line coverage of Modules/**/*.psm1 (Pester 5 + JaCoCo LINE counters)'
                linesCovered     = $executed
                linesMissed      = $missed
                linesTotal       = $totalCmds
                coveragePercent  = $pct
                # The same run's BYTECODE view over the same files and the same
                # union rule. Published for trend only: it is NOT a floor (see
                # Tests/process-baseline.json .coverage.reconciliation).
                instructionCoveragePercent = $instrPct
                instructionsCovered = $instrExecuted
                instructionsTotal   = $instrTotalCmds
                scope            = $Scope
                scopeFiles       = $coverageFiles.Count
                partialShard     = [bool]$isPartialShard
                perFile          = @($files.Values | ForEach-Object { [PSCustomObject]@{ File = $_.File; Executed = $_.Executed; Missed = $_.Total - $_.Executed; InstructionsCovered = $_.InstrExecuted; InstructionsTotal = $_.InstrTotal } } | Sort-Object -Property @{e={$_.Missed};d=$true}, File)
            }
            $summaryDir = Join-Path $testRoot 'TestResults'
            if (-not (Test-Path -LiteralPath $summaryDir -PathType Container)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
            # A shard writes its PARTIAL figure under its own name. It must not
            # overwrite coverage-baseline.json: that file is the merged, gated
            # measurement, and a shard's number would be read as the baseline by
            # anyone (or anything) that looks at the artefact afterwards.
            $baselineName = if ($isPartialShard) { "coverage-shard-{0}-of-{1}.json" -f $Shard, $ShardCount } else { 'coverage-baseline.json' }
            $baselinePath = Join-Path $summaryDir $baselineName
            $baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baselinePath -Encoding UTF8
            $coverageSummary = $baseline
            Write-ProgressLine ("COVERAGE: {0}% of {1} lines ({2} covered / {3} missed) across {4} file(s) -> {5}" -f $pct, $totalCmds, $executed, $missed, $files.Count, $baselinePath)
            Write-ProgressLine ("COVERAGE (bytecode view, same reports): {0}% of {1} instructions covered" -f $instrPct, $instrTotalCmds)
            # The merge gate is the LINE-coverage floor from the baseline, NOT
            # $MinCoveragePct. The two are different metrics and
            # Tests/process-baseline.json says so explicitly: the CI job gates
            # Pester COMMAND coverage at 55%, while this merge measures LINE
            # coverage. Comparing the line percentage against the
            # command-coverage target made the job permanently red (54.47%
            # line vs a 55% command threshold), which is exactly the failure
            # mode the baseline note warns about.
            $lineFloorPct = $null
            try {
                $covBlPath = Join-Path $testRoot 'process-baseline.json'
                if (Test-Path -LiteralPath $covBlPath -PathType Leaf) {
                    $covBl = Get-Content -LiteralPath $covBlPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($covBl.PSObject.Properties.Name -contains 'coverage' -and $null -ne $covBl.coverage.floorPercent) {
                        $lineFloorPct = [double]$covBl.coverage.floorPercent
                    }
                }
            } catch { }
            if ($isPartialShard) {
                # A shard measures a SLICE. Its percentage is not comparable with
                # the global floor, so it is published and NOT gated. The floor
                # is enforced by the merge job, which holds every shard's
                # reports and computes the union.
                Write-ProgressLine ("COVERAGE (shard {0} of {1}): {2}% of {3} lines - PARTIAL measurement, not gated here; the merged floor ({4}%) is enforced by the merge job" -f $Shard, $ShardCount, $pct, $totalCmds, $(if ($null -ne $lineFloorPct) { $lineFloorPct } else { 'n/a' }))
            } elseif ($null -ne $lineFloorPct) {
                Write-ProgressLine ("COVERAGE GATE: line floor {0}% (Tests/process-baseline.json coverage.floorPercent); measured {1}%" -f $lineFloorPct, $pct)
            }
            if ((-not $isPartialShard) -and ($null -ne $lineFloorPct) -and ($pct -lt $lineFloorPct)) {
                $msg = ("COVERAGE GATE FAILED: line coverage {0}% < baseline floor {1}% ({2} lines measured)" -f $pct, $lineFloorPct, $totalCmds)
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

if ($MergeOnly) {
    # The shard jobs decided the test verdict; this job decides the merge and
    # the line-coverage gate. A gate failure exits above, so reaching here
    # means the merged report is good.
    $mergeMsg = 'MERGE OK'
    if ($coverageSummary) {
        $mergeMsg = "MERGE OK: $($coverageSummary.coveragePercent)% line coverage ($($coverageSummary.linesCovered)/$($coverageSummary.linesTotal))"
    }
    Write-ProgressLine "RESULT: $mergeMsg"
    Write-SuiteMessage $mergeMsg 'Succ'
    try { Remove-Item -LiteralPath $progressLog -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
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
