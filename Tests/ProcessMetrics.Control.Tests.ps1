#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Control.Tests.ps1 - the statistical control limits and the QPM
# measures of the CMMI L5 self-measurement apparatus.
#
# One scope of the measurement engine (see ProcessMetrics.Engine.Tests.ps1 for
# why the engine is split). These two families work on SYNTHETIC trends and a
# synthetic ledger, so they cost no tree scan at all - which is why they are
# worth a scope of their own: the cheap scopes keep the expensive ones
# schedulable.

Set-StrictMode -Version 1.0

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
}
Describe 'ProcessMetrics - control limits (SPC gate)' {
    BeforeAll {
        function New-SyntheticTrend {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][double[]]$AdoptionAlpha,
                [datetime]$Start = (Get-Date '2026-10-01T00:00:00Z')
            )
            $dir = Join-Path $Root 'Tests/TestResults'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'process-trend.jsonl'
            $lines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $AdoptionAlpha.Count; $i++) {
                $a = [double]$AdoptionAlpha[$i]
                $at = $Start.AddMinutes(5 * $i)
                $rec = [ordered]@{
                    schema = 'gbuild.process-trend.v2'; runId = ('s{0:D3}' -f $i); recordedAtUtc = $at.ToString('o'); channel = 'test'; projectType = 'unknown'; host = 'test'
                    psVersion = '7.0.0'; os = 'test'; filesScanned = 10; classCount = 1; classesAtParity = $(if ($a -ge 1.0) { 1 } else { 0 }); meanAdoption = $a; totalRemaining = 0; atParity = ($a -ge 1.0)
                    classes = @([ordered]@{ class = 'alpha'; adopted = [int]([math]::Round($a * 10)); total = 10; adoption = $a; remaining = (10 - [int]([math]::Round($a * 10))) })
                }
                $lines.Add(([PSCustomObject]$rec | ConvertTo-Json -Compress -Depth 6)) | Out-Null
            }
            [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        function New-SyntheticMetrics {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Classes
            )
            $list = @()
            foreach ($c in $Classes) { $list += [PSCustomObject]$c }
            return [PSCustomObject]@{
                ToolRoot = 'synthetic'; FilesScanned = 10; ClassCount = $list.Count
                ClassesAtParity = @($list | Where-Object { $_.Adoption -ge 1.0 }).Count
                MeanAdoption = 1.0; TotalRemaining = 0; AtParity = ($list.Count -gt 0 -and @($list | Where-Object { $_.Adoption -lt 1.0 }).Count -eq 0)
                Classes = $list
            }
        }
        function New-SyntheticLedger {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Json
            )
            $dir = Join-Path $Root 'Tests'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'qpm-ledger.json'
            [System.IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        $script:MinimalLedger = '{ "$schema": "./qpm-ledger.schema.json", "description": "test", "entries": [ { "id": "QPM-2026-001", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "resolvedAtUtc": "2026-10-01T00:05:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "synthetic", "summary": "synthetic entry for test" } ] }'
    }

    It 'fails when the current run falls below the LCL computed from history (downward shift)' {
        $tmp = Join-Path $TestDrive 'ooc'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 20))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=7; Total=10; Adoption=0.7; Remaining=3 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp -Window 50 -MinSamples 12
        $r.HasLimits | Should -BeTrue
        $r.Passed | Should -BeFalse -Because 'a run below the effective LCL is a process shift down'
        @($r.OutOfControl).Class | Should -Contain 'alpha'
    }

    It 'keeps a single slipped item in control in a perfect process; two fail' {
        $tmp = Join-Path $TestDrive 'quantum'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 20))
        $one = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=9; Total=10; Adoption=0.9; Remaining=1 })
        $r1 = Compare-BuildProcessControl -Metrics $one -ToolRoot $tmp
        $r1.Passed | Should -BeTrue -Because 'one item in a perfect process is noise, not a signal'
        $two = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=8; Total=10; Adoption=0.8; Remaining=2 })
        $r2 = Compare-BuildProcessControl -Metrics $two -ToolRoot $tmp
        $r2.Passed | Should -BeFalse -Because 'two items below a zero-variance mean is a signal'
    }

    It 'passes when the current run stays inside the limits' {
        $tmp = Join-Path $TestDrive 'inside'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9)))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue
    }

    It 'fails open without a verdict when history is thinner than MinSamples' {
        $tmp = Join-Path $TestDrive 'thin'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 3))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=2; Total=10; Adoption=0.2; Remaining=8 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp -MinSamples 12
        $r.HasLimits | Should -BeFalse
        $r.Passed | Should -BeTrue -Because 'a thin history never fails a build'
    }

    It 'fails open when the trend file does not exist' {
        $tmp = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=1; Total=10; Adoption=0.1; Remaining=9 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.HasLimits | Should -BeFalse
        $r.Passed | Should -BeTrue
    }

    It 'reports a class missing from history as insufficient instead of failing it' {
        $tmp = Join-Path $TestDrive 'missingclass'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 15))
        $m = New-SyntheticMetrics -Classes @(
            @{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 }
            @{ Class='omega'; Metric='m'; Description='d'; Adopted=0; Total=10; Adoption=0.0; Remaining=10 }
        )
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue -Because 'a never-seen class cannot be out of control against its own history'
        @($r.Insufficient) | Should -Contain 'omega'
    }

    It 'reports an above-UCL run without failing it' {
        $tmp = Join-Path $TestDrive 'ucl'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.9) * 2))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue -Because 'above the UCL is improvement, never a failure'
        @($r.Classes | Where-Object { $_.Class -eq 'alpha' })[0].Notes | Should -Match 'above UCL'
    }
}
Describe 'ProcessMetrics - QPM measures' {
    BeforeAll {
        function Write-QpmTrend {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][bool[]]$Parity, [datetime]$Start = (Get-Date '2026-10-01T00:00:00Z'))
            $dir = Join-Path $Root 'Tests/TestResults'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'process-trend.jsonl'
            $lines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $Parity.Count; $i++) {
                $p = [bool]$Parity[$i]
                $at = $Start.AddMinutes(10 * $i)
                $rec = [ordered]@{
                    schema = 'gbuild.process-trend.v2'; runId = ('q{0:D3}' -f $i); recordedAtUtc = $at.ToString('o'); channel = 'test'; projectType = 'unknown'; host = 'test'
                    filesScanned = 10; classCount = 1; classesAtParity = $(if ($p) { 1 } else { 0 }); meanAdoption = $(if ($p) { 1.0 } else { 0.5 }); atParity = $p
                    classes = @([ordered]@{ class = 'alpha'; adopted = $(if ($p) { 10 } else { 5 }); total = 10; adoption = $(if ($p) { 1.0 } else { 0.5 }); remaining = $(if ($p) { 0 } else { 5 }) })
                }
                $lines.Add(([PSCustomObject]$rec | ConvertTo-Json -Compress -Depth 6)) | Out-Null
            }
            [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
        }
        $script:QpmLedger = '{ "$schema": "./qpm-ledger.schema.json", "description": "test", "entries": [ { "id": "QPM-2026-001", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "resolvedAtUtc": "2026-10-01T00:10:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "synthetic", "summary": "synthetic escaped defect" }, { "id": "QPM-2026-002", "detectedAtUtc": "2026-10-02T00:00:00+00:00", "class": "near-miss", "severity": "low", "scope": "synthetic", "summary": "synthetic near miss" } ] }'
    }

    It 'computes change failure rate and MTTR from a failing streak that recovers' {
        $tmp = Join-Path $TestDrive 'qpm'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        Write-QpmTrend -Root $tmp -Parity (@($true,$true,$true) + @($false,$false) + @($true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true))
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $script:QpmLedger, (New-Object System.Text.UTF8Encoding($false)))
        $q = Get-BuildQpmMeasures -ToolRoot $tmp -WindowSamples 50
        $q.Samples | Should -Be 20
        $q.Failures | Should -Be 2
        $q.ChangeFailureRate | Should -Be 0.1
        $q.RecoveryIncidents | Should -Be 1 -Because 'one failing streak recovers at the first passing sample'
        $q.MeanRecoveryTimeSeconds | Should -BeGreaterThan 0
        $q.EscapedDefects | Should -Be 1
        $q.DataQuality | Should -Be 'measured'
    }

    It 'reports insufficient history and no fabricated numbers on an empty trend' {
        $tmp = Join-Path $TestDrive 'qpmthin'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $script:QpmLedger, (New-Object System.Text.UTF8Encoding($false)))
        $q = Get-BuildQpmMeasures -ToolRoot $tmp -WindowSamples 50
        $q.Samples | Should -Be 0
        $q.ChangeFailureRate | Should -BeNullOrEmpty
        $q.DataQuality | Should -Be 'insufficient-history'
        $q.LedgerValid | Should -BeTrue
    }

    It 'flags an invalid ledger with readable errors' {
        $tmp = Join-Path $TestDrive 'qpmbad'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        $bad = '{ "$schema": "x", "description": "bad", "entries": [ { "id": "WRONG-1", "detectedAtUtc": "not-a-date", "class": "nope", "severity": "nope" }, { "id": "WRONG-1", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "s", "summary": "s" } ] }'
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $bad, (New-Object System.Text.UTF8Encoding($false)))
        $l = Test-BuildQpmLedger -ToolRoot $tmp
        $l.Passed | Should -BeFalse
        @($l.Errors).Count | Should -BeGreaterThan 3
    }

    It 'the shipped escaped-defect ledger validates' {
        $l = Test-BuildQpmLedger -ToolRoot $script:ToolRoot
        $l.Passed | Should -BeTrue -Because "the ledger is evidence; it must never drift: $(@($l.Errors) -join '; ')"
        @($l.Entries).Count | Should -BeGreaterOrEqual 2
    }

    It 'the committed baseline carries the QPM ceiling as a ratchet' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $b.qpm | Should -Not -BeNullOrEmpty
        [double]$b.qpm.maxChangeFailureRate | Should -BeGreaterThan 0
        [double]$b.qpm.maxChangeFailureRate | Should -BeLessOrEqual 1
        $b.qpm.windowSamples | Should -BeGreaterOrEqual 20
        $b.qpm.note | Should -Match 'never raise'
    }
}
