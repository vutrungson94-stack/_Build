#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Distributed', 'CacheProvider', 'Metrics', 'Enterprise', 'BuildE2E', 'All')]
    [string]$Scope = 'All',
    [switch]$RealInfra,
    [switch]$Strict,
    [switch]$RequireNoSkips
)

Set-StrictMode -Version 1.0
Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
$strictSkips = $Strict.IsPresent -or $RequireNoSkips.IsPresent

function Write-RunnerMessage {
    param([string]$Message, [string]$Level = 'Info')
    if (Get-Command Write-LogSafe -ErrorAction SilentlyContinue) { Write-LogSafe $Message $Level }
    else { Write-Host $Message }
}

$xmlDir = Join-Path (Join-Path $testRoot 'TestResults') 'xml'
New-Item -ItemType Directory -Path $xmlDir -Force -ErrorAction Stop | Out-Null
Get-ChildItem -LiteralPath $xmlDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction Stop

if ($RealInfra) {
    $env:GBUILD_REAL_INFRA = '1'
    Write-RunnerMessage 'Real-infra mode ENABLED: tests may contact external services (S3/SSH/OTLP).' 'Warn'
} else {
    Remove-Item Env:\GBUILD_REAL_INFRA -ErrorAction SilentlyContinue
    Write-RunnerMessage 'Real-infra mode disabled (mock-only).' 'Gray'
}

$testFiles = switch ($Scope) {
    'Distributed' { @(Join-Path $testRoot 'Distributed.E2E.Tests.ps1') }
    'CacheProvider' { @(Join-Path $testRoot 'CacheProvider.E2E.Tests.ps1') }
    'Metrics'     { @(Join-Path $testRoot 'Metrics.E2E.Tests.ps1') }
    'Enterprise'  { @(Join-Path $testRoot 'Enterprise.E2E.Tests.ps1') }
    'BuildE2E'    { @(Join-Path $testRoot 'BuildE2E.Tests.ps1') }
    'All'         { @(
        (Join-Path $testRoot 'Distributed.E2E.Tests.ps1')
        (Join-Path $testRoot 'CacheProvider.E2E.Tests.ps1')
        (Join-Path $testRoot 'Metrics.E2E.Tests.ps1')
        (Join-Path $testRoot 'Enterprise.E2E.Tests.ps1')
        # BuildE2E has a named scope but was missing from 'All', so the real
        # dotnet-pipeline test was never executed by CI or by a default local run.
        (Join-Path $testRoot 'BuildE2E.Tests.ps1')
    ) }
}

$testFiles = @($testFiles)
$missing = @($testFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($testFiles.Count -eq 0 -or $missing.Count -gt 0) {
    if ($missing.Count -gt 0) { Write-Error ("Missing E2E test file(s): {0}" -f ($missing -join ', ')) }
    else { Write-Error "No E2E test files found for scope: $Scope" }
    exit 1
}

$config = New-PesterConfiguration
$config.Run.Path = $testFiles
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path $xmlDir 'e2e-results.xml'
$config.Output.Verbosity = 'Detailed'

Write-RunnerMessage "Running Build Platform E2E tests: $Scope"
try {
    $result = Invoke-Pester -Configuration $config
} catch {
    Write-Error "Pester invocation failed: $($_.Exception.Message)"
    exit 1
}

if ($null -eq $result) {
    Write-Error 'Pester returned no result.'
    exit 1
}

function Get-PesterCount {
    param([string]$Name)
    try {
        $property = $result.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return 0 }
        return [int]$property.Value
    } catch {
        return 0
    }
}

$passed = Get-PesterCount 'PassedCount'
$failed = Get-PesterCount 'FailedCount'
$skipped = Get-PesterCount 'SkippedCount'
$total = Get-PesterCount 'TotalCount'
if ($total -le 0) {
    try {
        if ($null -ne $result.Tests) { $total = @($result.Tests).Count }
    } catch { }
}
if ($total -lt ($passed + $failed + $skipped)) { $total = $passed + $failed + $skipped }

if ($total -le 0 -or $failed -gt 0 -or ($strictSkips -and $skipped -gt 0)) {
    $message = "FAILED: $failed failed, $skipped skipped, $total total"
    Write-RunnerMessage $message 'Err'
    exit 1
}

if ($skipped -gt 0) {
    Write-RunnerMessage "SKIPPED: $skipped tests skipped, $passed passed, $total total" 'Warn'
} else {
    Write-RunnerMessage "ALL PASSED: $passed tests" 'Succ'
}
exit 0
