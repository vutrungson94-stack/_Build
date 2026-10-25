#Requires -Version 5.1
Set-StrictMode -Version 1.0

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path $PSScriptRoot (Join-Path 'Helpers' 'PlatformShim.ps1'))

$global:GBuildTestRoot = $PSScriptRoot
$ErrorActionPreference = 'Stop'

$null = Import-Module (Join-Path $PSScriptRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction SilentlyContinue

Describe 'Report.psm1 telemetry functions' {

    BeforeAll {
        $loggingPath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'Logging.psm1')
        $reportPath  = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'Report.psm1')

        Import-Module $loggingPath -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module $reportPath  -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction SilentlyContinue

        $global:realConfigState = New-FullTestState
    }

    AfterAll {
        Remove-Module Report -Force -ErrorAction SilentlyContinue
        Remove-Module Logging -Force -ErrorAction SilentlyContinue
    }

    It 'Get-TelemetryConfigValue returns the configured telemetry value' {
        $state = [PSCustomObject]@{
            ScriptRoot  = $global:realConfigState.ScriptRoot
            BuildConfig = $global:realConfigState.BuildConfig
            CorrelationId = [guid]::NewGuid().ToString('N')
        }

        $val = Get-TelemetryConfigValue -State $state -Key 'enabled' -Default $false
        $val | Should -BeTrue
    }

    It 'Get-TelemetryConfigValue falls back to Default when key is missing' {
        $state = [PSCustomObject]@{
            ScriptRoot  = $global:realConfigState.ScriptRoot
            BuildConfig = [PSCustomObject]@{ telemetry = [PSCustomObject]@{ enabled = $true } }
            CorrelationId = [guid]::NewGuid().ToString('N')
        }

        $val = Get-TelemetryConfigValue -State $state -Key 'doesNotExist' -Default 'fallback'
        $val | Should -Be 'fallback'
    }

    It 'Write-TelemetryEntry returns null and writes no file when telemetry is disabled' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null

            $state = [PSCustomObject]@{
                ScriptRoot  = $sub
                BuildConfig = [PSCustomObject]@{ telemetry = [PSCustomObject]@{ enabled = $false } }
                CorrelationId = [guid]::NewGuid().ToString('N')
            }

            $result = Write-TelemetryEntry -State $state -Metric @{ Status = 'Success' }
            $result | Should -BeNullOrEmpty

            $expectedFile = Join-Path (Join-Path (Split-Path $sub -Parent) 'build-reports') 'telemetry.jsonl'
            Test-Path -LiteralPath $expectedFile | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-TelemetryEntry writes a valid JSONL line under the default (all-true) config' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null

            $state = [PSCustomObject]@{
                ScriptRoot  = $sub
                BuildConfig = $global:realConfigState.BuildConfig
                CorrelationId = [guid]::NewGuid().ToString('N')
            }

            Initialize-ReportDir -State $state | Out-Null

            $metric = @{
                Status   = 'Success'
                Duration = 1.5
                User     = 'bob'
                Hostname = 'pc'
                Project  = 'X'
            }

            $path = Write-TelemetryEntry -State $state -Metric $metric
            $path | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $path | Should -BeTrue

            $line  = (Get-Content -LiteralPath $path | Select-Object -Last 1)
            $entry = $line | ConvertFrom-Json

            $entry.Status  | Should -Be 'Success'
            $entry.Duration | Should -Be 1.5
            $entry.Project  | Should -Be 'X'

            ($entry.PSObject.Properties.Name -contains 'ErrorCount') | Should -BeTrue
            $entry.ErrorCount | Should -Be 0

            ($entry.PSObject.Properties.Name -contains 'User')     | Should -BeFalse
            ($entry.PSObject.Properties.Name -contains 'Hostname') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-TelemetryEntry strips Duration when collectBuildTimes is false' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null

            $state = [PSCustomObject]@{
                ScriptRoot  = $sub
                BuildConfig = [PSCustomObject]@{
                    telemetry = [PSCustomObject]@{
                        enabled          = $true
                        anonymousOnly    = $true
                        collectBuildTimes = $false
                        collectErrorStats = $true
                    }
                }
                CorrelationId = [guid]::NewGuid().ToString('N')
            }

            Initialize-ReportDir -State $state | Out-Null

            $path = Write-TelemetryEntry -State $state -Metric @{ Status = 'Success'; Duration = 1.5; User = 'bob'; Hostname = 'pc' }
            $path | Should -Not -BeNullOrEmpty

            $line  = (Get-Content -LiteralPath $path | Select-Object -Last 1)
            $entry = $line | ConvertFrom-Json

            ($entry.PSObject.Properties.Name -contains 'Duration') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-TelemetryEntry counts errors in ErrorCount when collectErrorStats is true' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null

            $state = [PSCustomObject]@{
                ScriptRoot  = $sub
                BuildConfig = [PSCustomObject]@{
                    telemetry = [PSCustomObject]@{
                        enabled           = $true
                        anonymousOnly     = $false
                        collectBuildTimes = $true
                        collectErrorStats = $true
                    }
                }
                Errors       = @(1, 2, 3)
                CorrelationId = [guid]::NewGuid().ToString('N')
            }

            Initialize-ReportDir -State $state | Out-Null

            $path = Write-TelemetryEntry -State $state -Metric @{ Status = 'Success'; Duration = 1.5 }
            $path | Should -Not -BeNullOrEmpty

            $line  = (Get-Content -LiteralPath $path | Select-Object -Last 1)
            $entry = $line | ConvertFrom-Json

            ($entry.PSObject.Properties.Name -contains 'ErrorCount') | Should -BeTrue
            $entry.ErrorCount | Should -Be 3
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-TelemetryEntry keeps User and Hostname when anonymousOnly is false' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null

            $state = [PSCustomObject]@{
                ScriptRoot  = $sub
                BuildConfig = [PSCustomObject]@{
                    telemetry = [PSCustomObject]@{
                        enabled           = $true
                        anonymousOnly     = $false
                        collectBuildTimes = $true
                        collectErrorStats = $true
                    }
                }
                CorrelationId = [guid]::NewGuid().ToString('N')
            }

            Initialize-ReportDir -State $state | Out-Null

            $path = Write-TelemetryEntry -State $state -Metric @{ Status = 'Success'; User = 'bob'; Hostname = 'pc' }
            $path | Should -Not -BeNullOrEmpty

            $line  = (Get-Content -LiteralPath $path | Select-Object -Last 1)
            $entry = $line | ConvertFrom-Json

            ($entry.PSObject.Properties.Name -contains 'User')     | Should -BeTrue
            ($entry.PSObject.Properties.Name -contains 'Hostname') | Should -BeTrue
            $entry.User     | Should -Be 'bob'
            $entry.Hostname | Should -Be 'pc'
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# The ring-trim called [System.IO.File]::Replace($tmp, $file, $null). File.Replace
# REQUIRES a destination backup path, and PowerShell binds $null to an empty
# String, so the call threw ArgumentException on EVERY build. The trim silently
# never happened, telemetry.jsonl grew past maxReportHistory without bound, and a
# stale telemetry.jsonl.tmp was left behind each run. Nothing tested the trim path
# because it needs more entries than the cap - hence this one.
Describe 'Write-TelemetryEntry ring-trim' {
    BeforeAll {
        # Pester 5 scopes BeforeAll to its own Describe, so this block cannot
        # borrow the module imports from the Describe above.
        $loggingPath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'Logging.psm1')
        $reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'Report.psm1')
        Import-Module $loggingPath -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module $reportPath -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }

    It 'trims to maxReportHistory and leaves no scratch files behind' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            $state = [PSCustomObject]@{
                ScriptRoot    = $sub
                CorrelationId = [guid]::NewGuid().ToString('N')
                BuildConfig   = [PSCustomObject]@{
                    telemetry = [PSCustomObject]@{ enabled = $true; collectBuildTimes = $true; anonymousOnly = $true }
                    report    = [PSCustomObject]@{ maxReportHistory = 5 }
                }
            }
            Initialize-ReportDir -State $state | Out-Null

            $path = $null
            1..9 | ForEach-Object {
                $r = Write-TelemetryEntry -State $state -Metric @{ Status = 'Success'; Seq = $_ }
                if ($r) { $path = $r }
            }
            $path | Should -Not -BeNullOrEmpty

            $lines = @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -Be 5
            # The newest entries are the ones kept.
            [int]($lines[-1] | ConvertFrom-Json).Seq | Should -Be 9
            [int]($lines[0] | ConvertFrom-Json).Seq  | Should -Be 5

            # The failure mode: a leftover scratch file on every single build.
            Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
            Test-Path -LiteralPath "$path.bak" | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not throw when the trim runs' {
        $temp = New-IntegrationTempDir
        try {
            $sub = Join-Path $temp 'src'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            $state = [PSCustomObject]@{
                ScriptRoot    = $sub
                CorrelationId = [guid]::NewGuid().ToString('N')
                BuildConfig   = [PSCustomObject]@{
                    telemetry = [PSCustomObject]@{ enabled = $true; anonymousOnly = $true }
                    report    = [PSCustomObject]@{ maxReportHistory = 3 }
                }
            }
            Initialize-ReportDir -State $state | Out-Null
            { 1..6 | ForEach-Object { Write-TelemetryEntry -State $state -Metric @{ Status = 'Success'; Seq = $_ } } } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
