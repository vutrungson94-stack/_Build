#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:temp = New-IntegrationTempDir

Describe "Logging Integration" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Start-Log + Write-Log + Stop-Log writes a readable text log file" {
        $logPath = Join-Path $temp 'build.log'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ Logging = [PSCustomObject]@{ logLevel = 'Info'; enableJsonLog = $false } }; CorrelationId = 'log-it' }
        Start-Log -Path $logPath -Level Info -State $state
        Write-Log 'Integration log line' -Level Info -State $state
        Stop-Log
        Test-Path $logPath | Should -BeTrue
        $content = Get-Content -LiteralPath $logPath -Raw
        $content | Should -Match 'Integration log line'
    }

    It "JSON log emits one valid JSON object per line when enableJsonLog is set" {
        $logPath = Join-Path $temp 'build2.log'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ Logging = [PSCustomObject]@{ logLevel = 'Info'; enableJsonLog = $true } }; CorrelationId = 'json-it' }
        Start-Log -Path $logPath -Level Info -State $state
        Write-Log 'Structured message' -Level Warn -State $state
        Stop-Log
        $jsonl = Join-Path $temp 'build2.jsonl'
        Test-Path $jsonl | Should -BeTrue
        $lines = Get-Content -LiteralPath $jsonl
        $lines.Count | Should -BeGreaterThan 0
        foreach ($l in $lines) {
            { $l | ConvertFrom-Json } | Should -Not -Throw
        }
        $parsed = ($lines | Select-Object -First 1 | ConvertFrom-Json)
        $parsed.level | Should -Be 'Warn'
        $parsed.correlationId | Should -Be 'json-it'
        $parsed.message | Should -Be 'Structured message'
    }

    It "Write-JsonLog is a no-op before Start-Log (no JSON path configured)" {
        # Should not throw even when JSON logging was never initialised
        { Write-JsonLog -Message 'no-op' -Level Info } | Should -Not -Throw
    }
}

Describe "Logging Helpers" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Get-VisualLength measures plain ASCII and empty strings" {
        Get-VisualLength -Text 'abc' | Should -Be 3
        Get-VisualLength -Text '' | Should -Be 0
        Get-VisualLength -Text 'hello' | Should -Be 5
    }

    It "Get-VisualLength returns a positive count for emoji text" {
        $len = Get-VisualLength -Text 'a🔥b'
        $len | Should -BeOfType [int]
        $len | Should -BeGreaterOrEqual 2
    }

    It "Resolve-SafeColor resolves a known color name" {
        $c = Resolve-SafeColor -ColorName 'Succ' -Fallback 'White'
        $c | Should -BeOfType [System.ConsoleColor]
        $c | Should -Be ([System.ConsoleColor]::Green)
    }

    It "Resolve-SafeColor falls back gracefully for an unknown color" {
        $c = Resolve-SafeColor -ColorName 'NonexistentX' -Fallback 'White'
        $c | Should -BeOfType [System.ConsoleColor]
        $c | Should -Be ([System.ConsoleColor]::White)
    }

    It "Resolve-ConsoleColor returns a ConsoleColor with null State" {
        $c = Resolve-ConsoleColor -State $null -Name 'Err'
        $c | Should -BeOfType [System.ConsoleColor]
    }

    It "Resolve-BuildText returns a non-null string for emoji and plain text" {
        $emoji = Resolve-BuildText -Text '✅ done'
        $emoji | Should -Not -BeNullOrEmpty
        $emoji | Should -BeOfType [string]
        Resolve-BuildText -Text 'plain' | Should -Be 'plain'
    }

    It "Resolve-ConfigValue walks nested config paths and returns defaults" {
        $cfg = [PSCustomObject]@{
            logging = [PSCustomObject]@{ maxLogSizeMB = 9 }
            a       = [PSCustomObject]@{ b = 5 }
        }
        Resolve-ConfigValue -State $cfg -Path 'logging.maxLogSizeMB' -Default 1 | Should -Be 9
        Resolve-ConfigValue -State $cfg -Path 'a.b' -Default 0 | Should -Be 5
        Resolve-ConfigValue -State $cfg -Path 'missing.x' -Default 42 | Should -Be 42
    }

    It "Get-LogConfigValue reads from the logging section" {
        $cfg = [PSCustomObject]@{ logging = [PSCustomObject]@{ maxLogSizeMB = 9 } }
        Get-LogConfigValue -State $cfg -Key 'maxLogSizeMB' -Default 1 | Should -Be 9
    }

    It "Invoke-LogRotation does not throw on a small/non-existent file" {
        $tf = Join-Path $temp 'rotate.log'
        New-Item -Path $tf -ItemType File -Force | Out-Null
        { Invoke-LogRotation -Path $tf -State $null } | Should -Not -Throw
    }

    It "Display helpers do not throw" {
        { _2Col -L 'left' -R 'right' -State $null } | Should -Not -Throw
        { Write-VisualBox -Text 'x' -State $null } | Should -Not -Throw
        { Write-SectionBox -Title 'x' -State $null } | Should -Not -Throw
        { Write-StepTitle -Text 'x' -State $null } | Should -Not -Throw
        { Write-SubLog -msg 'x' } | Should -Not -Throw
        { Write-Done -msg 'x' -State $null } | Should -Not -Throw
        { Write-Fail -msg 'x' -State $null } | Should -Not -Throw
        { Write-Info -msg 'x' -State $null } | Should -Not -Throw
        { Write-Warn -msg 'x' -State $null } | Should -Not -Throw
        { Write-Sep } | Should -Not -Throw
    }

    It "Show-ProgressBar does not throw" {
        { Show-ProgressBar -Current 1 -Total 4 -Label 'x' } | Should -Not -Throw
    }

    It "Set-StateColors adds a Colors property to a bare State" {
        $s = [PSCustomObject]@{}
        Set-StateColors -State $s
        $s.Colors | Should -Not -BeNullOrEmpty
    }

    It "Start-Log + Write-Log + Stop-Log persists the message to the file" {
        $logPath = Join-Path $temp 'build3.log'
        Start-Log -Path $logPath -Level 'Info' -State $null
        Write-Log -Message 'hello' -Color 'Info' -State $null
        Stop-Log
        Test-Path $logPath | Should -BeTrue
        $content = [System.IO.File]::ReadAllText($logPath)
        $content | Should -Match 'hello'
    }

    It "Set-BuildStateProperty adds a new property to a live state" {
        $s = [PSCustomObject]@{ A = 1 }
        { Set-BuildStateProperty -State $s -Name 'StartTime' -Value (Get-Date) -Force } | Should -Not -Throw
        $s.StartTime | Should -Not -BeNullOrEmpty
    }

    It "Set-BuildStateProperty works on a deserialized (CliXml) state" {
        # Deserialized states refuse new-member assignment via `=` on every
        # engine ("cannot be found on this object"); the bootstrap must use
        # this primitive. Round-trip through the serializer (no file needed).
        $live = [PSCustomObject]@{ ScriptRoot = $temp }
        $ser = [System.Management.Automation.PSSerializer]::Serialize($live)
        $d = [System.Management.Automation.PSSerializer]::Deserialize($ser)
        { Set-BuildStateProperty -State $d -Name 'StartTime' -Value (Get-Date) -Force } | Should -Not -Throw
        $d.StartTime | Should -Not -BeNullOrEmpty
        $d.ScriptRoot | Should -Be $temp
    }
}
