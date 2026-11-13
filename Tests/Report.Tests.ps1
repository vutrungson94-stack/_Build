#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Report" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Report.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:td = New-IntegrationTempDir
        $global:state = [PSCustomObject]@{
            ScriptRoot  = Join-Path $global:td 'app'
            ProjectRoot = $global:td
            WorkingDir  = $global:td
            BuildConfig = [PSCustomObject]@{ }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3
        }
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Initialize-ReportDir creates and returns the report directory" {
        $dir = Initialize-ReportDir -State $global:state
        $dir | Should -Not -BeNullOrEmpty
        Test-Path $dir | Should -Be $true
        (Split-Path $dir -Leaf) | Should -Be 'build-reports'
    }

    It "Write-BuildMetric returns metric hashtable with Status and Duration" {
        $m = Write-BuildMetric -State $global:state -Status 'Success' -Duration 1.5 -ProjectName 'P1'
        $m | Should -BeOfType [hashtable]
        $m.Status | Should -Be 'Success'
        $m.Duration | Should -Be 1.5
    }

    It "Save-BuildReport writes a build_*.json and returns its path" {
        $m = Write-BuildMetric -State $global:state -Status 'Success' -Duration 2.0 -ProjectName 'P2'
        $path = Save-BuildReport -State $global:state -Metric $m
        $path | Should -Not -BeNullOrEmpty
        Test-Path $path | Should -Be $true
        (Split-Path $path -Leaf) | Should -Match '^build_.*\.json$'
    }

    It "Get-BuildTrend returns report data after a saved report" {
        $m = Write-BuildMetric -State $global:state -Status 'Success' -Duration 3.0 -ProjectName 'P3'
        $null = Save-BuildReport -State $global:state -Metric $m
        $trend = Get-BuildTrend -State $global:state
        @($trend).Count | Should -BeGreaterThan 0
    }

    It "Reset-ReportCache does not throw" {
        { Reset-ReportCache } | Should -Not -Throw
    }

    It "Reset-ReportCache clears the memoised dir (per-run reset)" {
        # A second Start-GBuild in one session wrote project B's reports into
        # project A's build-reports/, because $script:ReportDir was memoised on
        # first Initialize-ReportDir and never cleared. After Reset, the next
        # Initialize must resolve from the CURRENT State, not the memo.
        $tmpA = New-IntegrationTempDir
        $tmpB = New-IntegrationTempDir
        try {
            $stA = [PSCustomObject]@{ ProjectRoot = $tmpA; ScriptRoot = $tmpA; BuildConfig = [PSCustomObject]@{} }
            $dirA = Initialize-ReportDir -State $stA
            $dirA | Should -Not -BeNullOrEmpty
            Reset-ReportCache
            $stB = [PSCustomObject]@{ ProjectRoot = $tmpB; ScriptRoot = $tmpB; BuildConfig = [PSCustomObject]@{} }
            $dirB = Initialize-ReportDir -State $stB
            $dirB | Should -Not -Be $dirA -Because 'the memoised run-1 dir must not survive into run 2'
            $dirB | Should -Match ([regex]::Escape($tmpB))
        } finally {
            Remove-Item $tmpA -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpB -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Initialize-ReportDir throws instead of creating the report dir in the CWD" {
        # The old fallback returned the bare 'build-reports' name, so
        # Invoke-EnsureDirectory created it in the launch directory and every
        # report/telemetry/SBOM write relocated silently.
        $origLoc = $PWD.Path
        $cwd = New-IntegrationTempDir
        try {
            Set-Location -LiteralPath $cwd
            { Initialize-ReportDir -State ([PSCustomObject]@{}) } | Should -Throw
            { Initialize-ReportDir -State ([PSCustomObject]@{ ProjectRoot = '.' }) } | Should -Throw
            @(Get-ChildItem -LiteralPath $cwd -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Report - trace, field extraction, and artifact export" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Report.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $script:ReportTmp = New-IntegrationTempDir
    }
    AfterAll {
        if ($script:ReportTmp -and (Test-Path $script:ReportTmp)) { Remove-Item $script:ReportTmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-BuildTraceContext returns deterministic W3C-shaped identifiers" {
        $st = [PSCustomObject]@{ CorrelationId = 'corr-12345' }
        $a = Get-BuildTraceContext -State $st
        $b = Get-BuildTraceContext -State $st
        $a.TraceId | Should -Match '^[0-9a-f]{32}$'
        $a.SpanId  | Should -Match '^[0-9a-f]{16}$'
        $a.Traceparent | Should -Be ("00-{0}-{1}-01" -f $a.TraceId, $a.SpanId)
        $a.CorrelationId | Should -Be 'corr-12345'
        $a.TraceId | Should -Be $b.TraceId
        $a.SpanId  | Should -Be $b.SpanId
        $noCorr = Get-BuildTraceContext -State ([PSCustomObject]@{})
        $noCorr.TraceId | Should -Match '^[0-9a-f]{32}$'
        $noCorr.CorrelationId | Should -Not -BeNullOrEmpty
    }

    It "Get-ReportFieldValue reads hashtable/object fields and falls back to defaults" {
        $ht = @{ Status = 'Failed'; message = 'boom' }
        Get-ReportFieldValue -Object $ht -Name 'Status' -Default 'x' | Should -Be 'Failed'
        Get-ReportFieldValue -Object $ht -Name 'Message' -Default 'fallback' | Should -Be 'boom'
        Get-ReportFieldValue -Object $ht -Name 'Missing' -Default 'dflt' | Should -Be 'dflt'
        $obj = [PSCustomObject]@{ Status = 'Skipped'; Reason = 'why' }
        Get-ReportFieldValue -Object $obj -Name 'Status' -Default 'x' | Should -Be 'Skipped'
        Get-ReportFieldValue -Object $obj -Name 'Reason' -Default 'x' | Should -Be 'why'
        Get-ReportFieldValue -Object $null -Name 'Any' -Default 'n' | Should -Be 'n'
    }

    It "Add-BuildTestResult accumulates records with normalized fields on state" {
        $st = [PSCustomObject]@{ ProjectRoot = $script:ReportTmp; ScriptRoot = $script:ReportTmp }
        $c1 = Add-BuildTestResult -State $st -Result @{ Status = 'Failed'; Message = 'err1' } -Suite 'SuiteA'
        $c2 = Add-BuildTestResult -State $st -Result @{ Status = 'Skipped'; Message = 'skip' } -Suite 'SuiteB'
        $c1 | Should -Be 1
        $c2 | Should -Be 2
        @($st.TestResults).Count | Should -Be 2
        $st.TestResults[0].Name | Should -Be 'SuiteA'
        $st.TestResults[0].Status | Should -Be 'Failed'
        $st.TestResults[0].Message | Should -Be 'err1'
        $st.TestResults[1].Status | Should -Be 'Skipped'
    }

    It "Export-JUnitReport writes valid XML with counts, failures and skipped cases" {
        $out = Join-Path $script:ReportTmp (Join-Path 'junit' 'results.xml')
        $results = @(
            @{ Name = 'ok';   Status = 'Succeeded' },
            @{ Name = 'bad';  Status = 'Failed';  Message = 'boom & <x>' },
            @{ Name = 'skip'; Status = 'Skipped' }
        )
        $path = Export-JUnitReport -Results $results -OutputPath $out -SuiteName 'gbuild&suite'
        $path | Should -Be $out
        Test-Path -LiteralPath $out | Should -BeTrue
        $xml = [xml](Get-Content -LiteralPath $out -Raw)
        $suite = $xml.testsuite
        [int]$suite.tests | Should -Be 3
        [int]$suite.failures | Should -Be 1
        [int]$suite.skipped | Should -Be 1
        $cases = @($suite.testcase)
        ($cases | Where-Object { $_.name -eq 'bad' }).failure | Should -Not -BeNullOrEmpty
        $skipCase = @($cases | Where-Object { $_.name -eq 'skip' })[0]
        $null -ne $skipCase.skipped | Should -BeTrue -Because 'skipped testcase must contain a skipped element'
    }

    It "Export-SarifReport writes SARIF 2.1.0 with rules, levels and locations" {
        $out = Join-Path $script:ReportTmp (Join-Path 'sarif' 'results.sarif')
        $findings = @(
            @{ Rule = 'R1'; Severity = 'Critical'; Message = 'critical issue'; File = 'a.ps1'; Line = 10 },
            @{ Rule = 'R2'; Severity = 'Warning';  Message = 'warn issue';     File = 'b.ps1'; Line = 5 },
            @{ Rule = 'R1'; Severity = 'Note';     Message = 'note issue';     File = 'c.ps1'; Line = 1 }
        )
        $path = Export-SarifReport -Findings $findings -OutputPath $out -ToolName 'gbuild-test'
        $path | Should -Be $out
        Test-Path -LiteralPath $out | Should -BeTrue
        $sarif = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $sarif.version | Should -Be '2.1.0'
        $run = $sarif.runs[0]
        $run.tool.driver.name | Should -Be 'gbuild-test'
        @($run.tool.driver.rules).Count | Should -Be 2
        @($run.results).Count | Should -Be 3
        ($run.results | Where-Object { $_.ruleId -eq 'R1' -and $_.level -eq 'error' }).Count | Should -Be 1
        ($run.results | Where-Object { $_.ruleId -eq 'R2' -and $_.level -eq 'warning' }).Count | Should -Be 1
    }

    It "Publish-BuildJUnitArtifact and Publish-BuildSarifArtifact write under the report directory" {
        $root = Join-Path $script:ReportTmp 'pub'
        $null = New-Item -ItemType Directory -Path $root -Force
        $st = [PSCustomObject]@{ ProjectRoot = $root; ScriptRoot = $root; BuildConfig = [PSCustomObject]@{} }
        Reset-ReportCache
        [void](Add-BuildTestResult -State $st -Result @{ Status = 'Failed'; Message = 'x' } -Suite 'S1')
        $j = Publish-BuildJUnitArtifact -State $st -SuiteName 'gbuild'
        $j | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $j | Should -BeTrue
        $j | Should -Match 'junit'

        Reset-ReportCache
        $st2 = [PSCustomObject]@{ ProjectRoot = $root; ScriptRoot = $root; BuildConfig = [PSCustomObject]@{} }
        $s = Publish-BuildSarifArtifact -State $st2 -Findings @(@{ Rule = 'R'; Severity = 'Warning'; Message = 'm'; File = 'f'; Line = 1 }) -ToolName 'gbuild'
        $s | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $s | Should -BeTrue
        $s | Should -Match 'sarif'
        Reset-ReportCache
    }
}
