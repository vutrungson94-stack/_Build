#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Siem.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "SIEM export (Level 5)" {
    It "Get-SiemConfig returns $null when State has no siem section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        Get-SiemConfig -State $state | Should -BeNullOrEmpty
    }

    It "Get-SiemConfig reads the security.siem section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'cef' } } } }
        $cfg = Get-SiemConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.format | Should -Be 'cef'
    }

    It "Get-SiemReportDir returns build-reports under the project root" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ } }
        Get-SiemReportDir -State $state | Should -Be (Join-Path $TestDrive 'build-reports')
    }

    It "Get-SiemReportDir reads report.outputDir from config" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ report = [PSCustomObject]@{ outputDir = 'reports/siem' } } }
        Get-SiemReportDir -State $state | Should -Be (Join-Path $TestDrive 'reports/siem')
    }

    It "ConvertTo-CefEvent builds the CEF header with severity mapping OK->0" {
        $entry = @{ Action = 'build'; Outcome = 'OK'; Detail = 'built ok'; Timestamp = '2026-01-01 00:00:00'; User = 'tester'; Host = 'build01'; TenantId = 'default'; CorrelationId = 'corr-1' }
        $cef = ConvertTo-CefEvent -Entry $entry
        $cef | Should -Match '^CEF:0\|gbuild\|gbuild-build-system\|1.0\|build\|build\|0\|'
        $cef | Should -Match 'cs3=OK'
        $cef | Should -Match 'suser=tester'
    }

    It "ConvertTo-CefEvent maps Warn->5 and Failed->7" {
        $w = ConvertTo-CefEvent -Entry @{ Action = 'warn-x'; Outcome = 'Warn'; Detail = '' }
        $w | Should -Match '\|5\|'
        $f = ConvertTo-CefEvent -Entry @{ Action = 'fail-x'; Outcome = 'Failed'; Detail = '' }
        $f | Should -Match '\|7\|'
    }

    It "ConvertTo-CefEvent escapes pipe and equals characters in values" {
        $entry = @{ Action = 'build'; Outcome = 'OK'; Detail = 'a=b|c'; Timestamp = $null }
        $cef = ConvertTo-CefEvent -Entry $entry
        $cef | Should -Match 'cs4=.*a\\=b\|c'
    }

    It "ConvertTo-SyslogEvent builds RFC5424 with structured data" {
        $entry = @{ Action = 'deploy'; Outcome = 'Warn'; Detail = 'slow'; Timestamp = '2026-01-01 00:00:00'; CorrelationId = 'corr-9'; TenantId = 'acme' }
        $sys = ConvertTo-SyslogEvent -Entry $entry -HostName 'build01'
        $sys | Should -Match '^<\d+>1 2026-01-01'
        $sys | Should -Match 'build01 gbuild 1 '
        $sys | Should -Match '\[gbuild@32473 action="deploy" outcome="Warn" correlationId="corr-9" tenant="acme"\]'
        $sys | Should -Match 'deploy - slow'
    }

    It "Get-AuditEntries parse JSONL audit log" {
        $log = Join-Path $TestDrive 'audit.log'
        Set-Content -Path $log -Value @(
            '{"Action":"build","Outcome":"OK","Detail":"done"}',
            '{"Action":"scan","Outcome":"Warn","Detail":"2 findings"}'
        ) -Encoding UTF8
        $entries = Get-AuditEntries -AuditLogPath $log
        $entries.Count | Should -Be 2
        $entries[0]['Action'] | Should -Be 'build'
    }

    It "Get-AuditEntries returns empty when the file does not exist" {
        Get-AuditEntries -AuditLogPath (Join-Path $TestDrive 'nope.log') | Should -HaveCount 0
    }

    It "Write-SiemFile writes the lines to a file" {
        $out = Join-Path (Join-Path $TestDrive 'reports') 'siem.log'
        Write-SiemFile -OutputPath $out -Lines @('line1', 'line2')
        Test-Path -LiteralPath $out | Should -BeTrue
        @(Get-Content -LiteralPath $out).Count | Should -Be 2
    }

    It "Export-SiemEvents returns Skipped when security.siem.enabled=false" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $false } } } }
        $r = Export-SiemEvents -State $state
        $r.Status | Should -Be 'Skipped'
    }

    It "Export-SiemEvents returns Skipped when the audit log is empty" {
        $log = Join-Path $TestDrive 'audit.log'
        Set-Content -Path $log -Value '' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'cef'; transport = 'file' } } } }
        $r = Export-SiemEvents -State $state -AuditLogPath $log
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'empty|not found'
    }

    It "Export-SiemEvents exports CEF to a local file when no endpoint is set" {
        $log = Join-Path $TestDrive 'audit.log'
        Set-Content -Path $log -Value '{"Action":"build","Outcome":"OK","Detail":"done"}' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'cef'; transport = 'file'; outputFile = 'siem-events.log' } } } }
        $r = Export-SiemEvents -State $state -AuditLogPath $log
        $r.Status | Should -Be 'Exported'
        $r.Count | Should -Be 1
        $r.Format | Should -Be 'cef'
        $r.Sample | Should -Match '^CEF:0\|'
        Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'build-reports') 'siem-events.log') | Should -BeTrue
    }

    It "Export-SiemEvents exports the syslog format" {
        $log = Join-Path $TestDrive 'audit.log'
        Set-Content -Path $log -Value '{"Action":"scan","Outcome":"Warn","Detail":"1 finding"}' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'syslog'; transport = 'file'; outputFile = 'siem-syslog.log' } } } }
        $r = Export-SiemEvents -State $state -AuditLogPath $log
        $r.Status | Should -Be 'Exported'
        $r.Format | Should -Be 'syslog'
        $r.Sample | Should -Match '^<\d+>1 '
    }

    It "Export-SiemEvents exports the json format" {
        $log = Join-Path $TestDrive 'audit.log'
        Set-Content -Path $log -Value '{"Action":"build","Outcome":"OK","Detail":"done"}' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'json'; transport = 'file'; outputFile = 'siem-json.log' } } } }
        $r = Export-SiemEvents -State $state -AuditLogPath $log
        $r.Status | Should -Be 'Exported'
        $r.Format | Should -Be 'json'
        $r.Sample | Should -Match 'Action'
    }
}

Describe 'SIEM safety' {
    It 'deduplicates events and assigns a sequence' {
        $log = Join-Path $TestDrive 'audit-duplicate.log'
        Set-Content -Path $log -Value @('{"Action":"build","Outcome":"OK","Detail":"same","Timestamp":"2026-01-01T00:00:00Z"}', '{"Action":"build","Outcome":"OK","Detail":"same","Timestamp":"2026-01-01T00:00:00Z"}') -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'cef'; transport = 'file'; outputFile = 'dedup.log' } } } }
        $result = Export-SiemEvents -State $state -AuditLogPath $log
        $result.Status | Should -Be 'Exported'
        $result.Count | Should -Be 1
        $result.DuplicateCount | Should -Be 1
        $result.SequenceCount | Should -Be 1
        $result.Sample | Should -Match 'cs5=1'
    }

    It 'does not report a failed HTTP transport as exported' {
        $log = Join-Path $TestDrive 'audit-http.log'
        Set-Content -Path $log -Value '{"Action":"build","Outcome":"OK","Detail":"done"}' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ siem = [PSCustomObject]@{ enabled = $true; format = 'cef'; transport = 'http'; endpoint = 'http://127.0.0.1:1/siem'; timeoutSec = 1 } } } }
        $result = Export-SiemEvents -State $state -AuditLogPath $log
        $result.Status | Should -Be 'Failed'
        $result.TransportStatus | Should -Be 'Failed'
    }

    It 'escapes structured syslog values' {
        $event = ConvertTo-SyslogEvent -Entry @{ Action = 'build"injected'; Outcome = 'OK'; Detail = "a]b`nnext"; CorrelationId = 'c' }
        $event | Should -Not -Match '\[gbuild@32473 action="build"injected"'
        $event | Should -Match '\\\]'
    }
}
