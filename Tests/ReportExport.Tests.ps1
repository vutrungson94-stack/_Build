#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Report.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe 'Report exports (JUnit/SARIF/W3C trace)' {
    It 'Export-JUnitReport writes CI-consumable XML' {
        $out = Join-Path $TestDrive 'junit.xml'
        $results = @(
            @{ Name = 'a'; Class = 's'; Status = 'Passed' },
            @{ Name = 'b'; Class = 's'; Status = 'Failed'; Message = 'boom' },
            @{ Name = 'c'; Class = 's'; Status = 'Skipped' }
        )
        $p = Export-JUnitReport -Results $results -OutputPath $out -SuiteName 'gbuild-test'
        Test-Path $p | Should -BeTrue
        [xml]$doc = Get-Content -LiteralPath $p -Raw
        $doc.testsuite.tests | Should -Be '3'
        $doc.testsuite.failures | Should -Be '1'
        @($doc.testsuite.testcase).Count | Should -Be 3
    }

    It 'Export-SarifReport writes SARIF 2.1.0' {
        $out = Join-Path $TestDrive 'sarif.json'
        $p = Export-SarifReport -Findings @(@{ Rule = 'sec'; Message = 'm'; File = 'f.cs'; Line = 3 }) -OutputPath $out
        Test-Path $p | Should -BeTrue
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $j.version | Should -Be '2.1.0'
        @($j.runs[0].results).Count | Should -Be 1
        $j.runs[0].results[0].ruleId | Should -Be 'sec'
    }

    It 'Get-BuildTraceContext derives deterministic W3C traceparent' {
        $a = Get-BuildTraceContext -State ([pscustomobject]@{ CorrelationId = 'abc' })
        $b = Get-BuildTraceContext -State ([pscustomobject]@{ CorrelationId = 'abc' })
        $a.TraceId | Should -Be $b.TraceId
        $a.Traceparent | Should -Match '^00-[0-9a-f]{32}-[0-9a-f]{16}-01$'
        $a.TraceId.Length | Should -Be 32
        $a.SpanId.Length | Should -Be 16
    }
}
