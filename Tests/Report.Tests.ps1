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
