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
}
