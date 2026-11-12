#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Ratchet.Tests.ps1 - the floor is a ratchet, not a snapshot.
#
# One scope of the measurement engine (see ProcessMetrics.Engine.Tests.ps1 for
# why the engine is split). The floor gate decides "not worse than the
# committed minimum"; these tests prove it can actually FAIL, and that an
# improvement is reported separately from a regression.

Set-StrictMode -Version 1.0

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
    $script:M = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
}
Describe 'ProcessMetrics - the floor is a ratchet' {
    It 'finds a floor entry for every class and reports no regression today' {
        $m = $script:M
        $c = Compare-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot
        $c.HasFloor | Should -BeTrue
        @($c.Untracked) | Should -BeNullOrEmpty -Because 'a measured class with no floor is ungoverned'
        @($c.Regressions) | Should -BeNullOrEmpty -Because 'the committed floor was seeded from this tree; a regression here means the measurement or the tree changed since'
        $c.Passed | Should -BeTrue
    }

    It 'detects a regression when a class drops below its floor' {
        # Prove the gate can actually FAIL. A gate that has only ever passed is
        # indistinguishable from a gate that cannot fail.
        $m = $script:M
        $target = @($m.Classes)[0]
        $tampered = [PSCustomObject]@{
            Classes   = @($m.Classes | ForEach-Object {
                if ($_.Class -eq $target.Class) {
                    [PSCustomObject]@{ Class = $_.Class; Description = $_.Description; Adopted = [int]($_.Adopted / 2); Total = $_.Total; Adoption = [math]::Round(([int]($_.Adopted / 2)) / [double]$_.Total, 4); Metric = $_.Metric }
                } else { $_ }
            })
            FilesScanned = $m.FilesScanned
        }
        $c = Compare-BuildProcessTrend -Metrics $tampered -ToolRoot $script:ToolRoot
        $c.Passed | Should -BeFalse -Because 'halving an adopted count must trip the floor'
        @($c.Regressions).Count | Should -Be 1
        @($c.Regressions)[0].Class | Should -Be $target.Class
    }

    It 'reports an improvement separately from a regression' {
        # The fifth step of the improvement loop is "did the change help?", which
        # requires the engine to distinguish better from worse, not just flag bad.
        #
        # Self-contained on purpose. This used to force every class to 1.0 and
        # assert an improvement appeared, which only worked while at least one
        # committed floor sat BELOW 1.0. Raising every class to full adoption - the
        # thing the ratchet is for - made the assertion vacuous: with every floor at
        # 1.0, "1.0 is better" is false, so the test failed for the right reason and
        # the wrong one. It now lowers a floor in a THROWAWAY baseline and measures
        # against that, so it proves the engine's behaviour rather than the
        # repository's current state.
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pmfloor_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'Tests') -Force
            $real = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $target = @($real.adoptionFloor.PSObject.Properties)[0]
            $real.adoptionFloor.($target.Name) | ForEach-Object { $_.minAdoption = 0.5 }
            [System.IO.File]::WriteAllText(
                (Join-Path $tmpRoot 'Tests/process-baseline.json'),
                ($real | ConvertTo-Json -Depth 20),
                (New-Object System.Text.UTF8Encoding($false)))

            # Measure the REAL tree, but read the FLOOR from the throwaway
            # baseline: -Metrics supplies the measurements (the temp root has no
            # tree to scan) while -ToolRoot selects which process-baseline.json
            # the floor comes from.
            $c = Compare-BuildProcessTrend -Metrics (Get-BuildProcessMetrics -ToolRoot $script:ToolRoot) -ToolRoot $tmpRoot
            $c.HasFloor | Should -BeTrue
            $c.Passed | Should -BeTrue
            @($c.Regressions) | Should -BeNullOrEmpty
            @($c.Improvements).Count | Should -BeGreaterThan 0 -Because 'a class measured above its floor must register as improvement, not silence'
            @($c.Improvements).Class | Should -Contain $target.Name
        } finally { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
