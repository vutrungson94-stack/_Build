#Requires -Version 5.1
#Requires -Module Pester
# EscapeRate / change-failure-rate gate: validates the committed CI run
# history snapshot (`Tests/ci-run-history.json`).
#
# Honest framing: it reports the change-failure rate of the primary workflow
# runs on main. It is NOT a production escape rate; it is NOT an SLO or an
# MTTR target; no SLO can be honestly set until a production incident feed
# exists. The snapshot itself says so and the gate fails if it stops saying
# so.
Set-StrictMode -Version 1.0

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Path = Join-Path $PSScriptRoot 'ci-run-history.json'
    $script:Doc = $null
    if (Test-Path -LiteralPath $script:Path -PathType Leaf) {
        try { $script:Doc = Get-Content -LiteralPath $script:Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $script:Doc = $null }
    }
}

Describe 'CI run history snapshot (Tests/ci-run-history.json)' {
    It 'exists, parses, and carries the expected schema and window' {
        $script:Doc | Should -Not -BeNullOrEmpty
        $script:Doc.schema | Should -Be 'gsync.ci-run-history.v1'
        $script:Doc.windowDays | Should -Be 90
        $script:Doc.workflow | Should -Match 'CI$'
    }

    It 'covers the declared window with >= 30 main-workflow runs' {
        @($script:Doc.runs).Count | Should -BeGreaterOrEqual 30 -Because 'the snapshot must represent the declared window'
        $script:Doc.runsInWindow | Should -Be @($script:Doc.runs).Count
    }

    It 'recomputes failure rate and matches the recorded value exactly' {
        $runs = @($script:Doc.runs)
        $succ = @($runs | Where-Object { $_.conclusion -eq 'success' }).Count
        $fail = @($runs | Where-Object { $_.conclusion -eq 'failure' }).Count
        $canc = @($runs | Where-Object { $_.conclusion -eq 'cancelled' }).Count

        $script:Doc.totals.success | Should -Be $succ
        $script:Doc.totals.failure | Should -Be $fail
        $script:Doc.totals.cancelled | Should -Be $canc

        $denom = $succ + $fail
        $script:Doc.nNonCancelled | Should -Be $denom
        $expected = if ($denom -gt 0) { [math]::Round($fail / [double]$denom * 100.0, 2) } else { 0.0 }
        [math]::Abs([double]$script:Doc.changeFailureRatePct - $expected) | Should -BeLessOrEqual 0.005 -Because 'the recorded rate must reconcile with the raw runs'
    }

    It 'does not claim an escape-rate, an SLO or an MTTR target' {
        $script:Doc.note | Should -Match 'NOT'
        $script:Doc.disclaimer | Should -Match 'not an SLO'
    }
}
