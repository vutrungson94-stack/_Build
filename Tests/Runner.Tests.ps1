#Requires -Version 5.1

<#
.SYNOPSIS
    Tests for the core test runner itself (Tests/Run-CoreTests.ps1).
.DESCRIPTION
    The runner is a script, not a module, so it cannot be imported and probed
    from a test. These tests drive it the way CI drives it - as a child
    process - and pin the behaviour the CI speed-up depends on:

      * the state-sensitive scopes keep their OWN process (that is the
        isolation guarantee, and the parallel speed-up must not weaken it),
      * the fast in-process core batch still runs in the parent,
      * the per-scope timing table is written, so "where does the suite spend
        its time" is answered by a measurement instead of by reading CI log
        timestamps by hand,
      * the exit code is still the verdict.
#>

Describe 'Core test runner' {
    BeforeAll {
        $script:runnerPath = Join-Path $PSScriptRoot 'Run-CoreTests.ps1'
        $script:resultsDir = Join-Path $PSScriptRoot 'TestResults'
        $script:timingsPath = Join-Path $script:resultsDir 'scope-timings.csv'
        # The runner re-executes ITSELF for every isolated scope, so the
        # executable is the one this session runs on.
        $script:psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    }

    It 'runs the selected scopes through the parallel pool and writes the timing table' {
        # One scope from the in-process core batch (MockHelpers) and one
        # state-sensitive scope (DotEnv). Both pass on every platform, so the
        # run is green everywhere and the assertions are about the SHAPE of
        # the run, not about a platform.
        $env:GBUILD_SS_LIST = 'MockHelpers,DotEnv'
        $env:GBUILD_SCOPE_PARALLELISM = '2'
        $code = 1
        $out = ''
        try {
            $out = & $script:psExe -NoProfile -ExecutionPolicy Bypass -File $script:runnerPath -StrictSkips 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            Remove-Item Env:GBUILD_SS_LIST -ErrorAction SilentlyContinue
            Remove-Item Env:GBUILD_SCOPE_PARALLELISM -ErrorAction SilentlyContinue
        }

        $code | Should -Be 0 -Because "the runner must report a green run as exit code 0; output was: $out"
        $out | Should -Match 'Parallel execution: degree 2' -Because 'an explicit degree must select the parallel path'
        # The state-sensitive scope keeps its own process: two concurrent
        # scopes must never share module-global state.
        $out | Should -Match '\[DotEnv\] START \(isolated child:' -Because 'a state-sensitive scope must run in its own child process'
        # The fast core batch runs in the parent - it has no shared state, so
        # a process of its own would only add startup cost.
        $out | Should -Match '\[MockHelpers\] START \(in-process\)' -Because 'the in-process core batch must stay in the parent'
    }

    It 'writes a per-scope timing table with a measured duration for every scope' {
        $timings = Join-Path $script:resultsDir 'scope-timings.csv'
        Test-Path -LiteralPath $timings | Should -BeTrue -Because 'the runner must publish where the suite spends its time'

        $rows = @(Import-Csv -LiteralPath $timings)
        $rows.Count | Should -BeGreaterThan 0
        $rows.Scope | Should -Contain 'MockHelpers'
        $rows.Scope | Should -Contain 'DotEnv'

        $dotEnv = @($rows | Where-Object { $_.Scope -eq 'DotEnv' })
        $dotEnv.Count | Should -Be 1
        $dotEnv[0].status | Should -Be 'PASSED'
        # A duration that is present AND positive: a table with zeros would
        # answer the question with a lie.
        [double]$dotEnv[0].seconds | Should -BeGreaterThan 0
    }

    It 'does not apply the global coverage floor to a shard measurement' {
        # A shard measures a SLICE of the suite, so its percentage is a PARTIAL
        # measurement of the codebase. Comparing it with the global floor made
        # shard 2 of 4 fail (20.67% against a 55% floor) while every test in
        # the shard passed - the job died against the very floor the merge job
        # exists to enforce. The floor belongs to the merge job.
        #
        # This test starts its OWN coverage run. Inside a run that is itself
        # instrumented the instrumentation would multiply, so the check is
        # skipped there: the coverage CI job exercises the shard path on every
        # run anyway, and a self-instrumenting test would be the next long pole
        # of the coverage job.
        if ($env:GBUILD_COVERAGE_ACTIVE -eq '1') {
            Set-ItResult -Skipped -Because 'a coverage run inside a coverage run multiplies the instrumentation'
            return
        }
        $env:GBUILD_SS_LIST = 'MockHelpers'
        try {
            $out = & $script:psExe -NoProfile -ExecutionPolicy Bypass -File $script:runnerPath -Coverage -Shard 1 -ShardCount 2 -StrictSkips 2>&1 | Out-String
            $code = $LASTEXITCODE
            $out | Should -Match 'PARTIAL measurement, not gated here' -Because 'a shard must report its partial figure as a diagnostic'
            $code | Should -Be 0 -Because "a partial shard measurement must not fail the run: $out"
            # A shard must not publish itself as the merged baseline.
            $shardReport = Join-Path $script:resultsDir 'coverage-shard-1-of-2.json'
            if (Test-Path -LiteralPath $shardReport -PathType Leaf) {
                $report = Get-Content -LiteralPath $shardReport -Raw -Encoding UTF8 | ConvertFrom-Json
                $report.coveragePercent | Should -BeLessThan 55 -Because 'one slice of the suite cannot reach the global floor'
            }
        } finally {
            Remove-Item Env:GBUILD_SS_LIST -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $script:resultsDir 'coverage-shard-1-of-2.json') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'opens a corrective-action record automatically when a scope failed' {
        # The causal loop has to be CLOSED, not merely open: a failed scope must
        # leave a CAR behind without a human remembering to write one. The runner
        # is driven the way CI drives it; -MergeOnly executes no scope but still
        # performs the end-of-run analysis, so the wiring is exercised without
        # inventing a failing test.
        $failedFile = Join-Path $script:resultsDir 'failed-CARProbe.txt'
        $carFile = Join-Path $script:resultsDir 'car/car-CARProbe.json'
        Set-Content -LiteralPath $failedFile -Value 'Suite.Probe :: fails on purpose' -Encoding UTF8
        try {
            $out = & $script:psExe -NoProfile -ExecutionPolicy Bypass -File $script:runnerPath -MergeOnly 2>&1 | Out-String
            Test-Path -LiteralPath $carFile -PathType Leaf | Should -BeTrue -Because "the runner must open a CAR for a failed scope automatically: $out"
            $car = Get-Content -LiteralPath $carFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $car.Schema | Should -Be 'car.record.v1'
            $car.Status | Should -Be 'Open'
            $car.Verification.Scope | Should -Be 'CARProbe'
            @($car.Verification.FailedTests).Count | Should -BeGreaterThan 0
            $out | Should -Match 'CAR opened for scope CARProbe'
        } finally {
            Remove-Item -LiteralPath $failedFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $carFile -Force -ErrorAction SilentlyContinue
        }
    }
}
