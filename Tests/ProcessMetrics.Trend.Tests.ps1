#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Trend.Tests.ps1 - the time series of the CMMI L5
# self-measurement apparatus, plus the coverage-gate reconciliation.
#
# One scope of the measurement engine (see ProcessMetrics.Engine.Tests.ps1 for
# why the engine is split): a time series is worthless if two runs of the same
# tree disagree, so the round-trip through the append-only JSONL file and the
# tolerance of a killed run are pinned here.

Set-StrictMode -Version 1.0

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
    $script:M = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
}
Describe 'ProcessMetrics - time series' {
    It 'round-trips a record through the append-only JSONL file' {
        $tmp = Join-Path $TestDrive 'trend'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        # Write-BuildProcessTrend derives its path from the tool root, so exercise
        # the reader/writer contract against a real tool root and then clean up.
        $before = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot).Count
        $m = $script:M
        $path = Write-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot -RunId 'testrun01' -Channel 'test'
        $path | Should -Match 'process-trend\.jsonl$'
        Test-Path -LiteralPath $path | Should -BeTrue
        $after = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot)
        $after.Count | Should -Be ($before + 1) -Because 'the trend is append-only: one run adds exactly one sample'
        $last = $after[$after.Count - 1]
        $last.runId | Should -Be 'testrun01'
        $last.schema | Should -Be 'gbuild.process-trend.v2'
        $last.channel | Should -Be 'test'
        @($last.classes).Count | Should -Be $m.Classes.Count -Because 'a truncated record would silently flatten a series'
        foreach ($c in $m.Classes) {
            $hit = @($last.classes | Where-Object { $_.class -eq $c.Class })
            $hit.Count | Should -Be 1
            [double]$hit[0].adoption | Should -Be $c.Adoption
        }
        # Remove the sample this test created so the suite is side-effect free.
        $lines = @(Get-Content -LiteralPath $path)
        $kept = @($lines | Where-Object { $_ -notmatch '"runId":"testrun01"' })
        Set-Content -LiteralPath $path -Value $kept -Encoding UTF8
    }

    It 'tolerates a corrupt trailing line from a killed run' {
        $path = Get-BuildProcessTrendPath -ToolRoot $script:ToolRoot
        $backup = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) { $backup = @(Get-Content -LiteralPath $path) }
        try {
            # Seed one valid record so the assertion below is about SURVIVAL of
            # the corrupt line, not about an empty file.
            $m = $script:M
            [void](Write-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot -RunId 'corrupttest' -Channel 'test')
            $beforeCount = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot).Count
            $beforeCount | Should -BeGreaterThan 0

            # A half-written line from an aborted run.
            Add-Content -LiteralPath $path -Value '{"schema":"gbuild.process-trend.v1","runId":"hal' -Encoding UTF8
            $records = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot)
            # Must not throw, and must keep every GOOD record.
            $records.Count | Should -Be $beforeCount -Because 'the corrupt line must be skipped, not parsed into a phantom record'
            foreach ($r in $records) { $r.runId | Should -Not -BeNullOrEmpty }
            # The renderer must also survive it, since the runner renders the
            # curve immediately after a run that may have been interrupted.
            $lines = @(Get-BuildProcessSparkline -ToolRoot $script:ToolRoot -Ascii)
            $lines.Count | Should -BeGreaterThan 1
        } finally {
            if ($null -ne $backup) { Set-Content -LiteralPath $path -Value $backup -Encoding UTF8 }
            else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'renders a curve with one row per measured class' {
        $m = $script:M
        $lines = @(Get-BuildProcessSparkline -Metrics $m -ToolRoot $script:ToolRoot -Ascii)
        $lines.Count | Should -Be ($m.Classes.Count + 1) -Because 'a header plus one row per class'
        ($lines[0]) | Should -Match 'ADOPTION CURVE'
        # -Ascii must produce no block glyphs, or a legacy console renders '?'.
        ($lines -join '') | Should -Not -Match ([regex]::Escape([string][char]0x2581))
        foreach ($c in $m.Classes) {
            ($lines -join "`n") | Should -Match ([regex]::Escape($c.Class))
        }
    }
}
Describe 'ProcessMetrics - one coverage gate over one artefact set' {
    It 'declares exactly ONE enforced coverage floor and states how the views relate' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        # The repository used to publish a line figure from the merged JaCoCo
        # reports and a command figure from Pester's in-process analysis, and
        # the baseline carried both numbers without saying how they relate -
        # the classic "two metrics, no reconciliation" trap.
        $b.coverage.PSObject.Properties.Name | Should -Contain 'floorPercent'
        $b.coverage.PSObject.Properties.Name | Should -Contain 'reconciliation' -Because 'the second view must state how it relates to the enforced one'
        $b.coverage.reconciliation | Should -Not -BeNullOrEmpty
        $b.coverage.reconciliation | Should -Match 'never be compared'
        # One gate: the LINE view is the enforced one.
        $b.coverage.metric | Should -Match 'LINE coverage'
        # The secondary view is published without a floor of its own.
        $b.coverage.publishedSecondaryView | Should -Match 'NO floor'
        $b.coverage.PSObject.Properties.Name | Should -Not -Contain 'commandFloorPercent' -Because 'a second floor over a different metric is the thing this reconciliation removes'
    }

    It 'records the two views from the same merge so they are comparable with each other' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        [double]$b.coverage.measuredMergedLineCoverage | Should -BeGreaterOrEqual ([double]$b.coverage.floorPercent) -Because 'the committed measurement must satisfy the committed floor'
        [double]$b.coverage.measuredMergedInstructionCoverage | Should -BeGreaterThan 0
        $b.coverage.measuredInstructionsCovered | Should -BeLessOrEqual $b.coverage.measuredInstructionsTotal
    }
}
