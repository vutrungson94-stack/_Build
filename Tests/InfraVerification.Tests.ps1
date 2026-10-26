#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

# New-FakeDotnet (Helpers/MockHelpers.psm1) writes dotnet.cmd on Windows and an
# executable `dotnet` sh script on POSIX, where .cmd cannot be launched.

Describe "InfraVerification (Level 5)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'InfraVerification.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:GBuildVerifyOrigFunctions = @('Get-DistributedConfig', 'Invoke-RemoteCommand', 'Get-RemoteCacheConfig')
    }
    AfterAll {
        foreach ($fn in $global:GBuildVerifyOrigFunctions) {
            if (Get-Command "global:$fn" -ErrorAction SilentlyContinue) {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
        }
    }

    It "Get-VerificationConfig returns safe defaults when State has no verification section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        $cfg = Get-VerificationConfig -State $state
        $cfg.Enabled | Should -BeFalse
        $cfg.Ssh | Should -BeTrue
        $cfg.Sdk | Should -BeTrue
        $cfg.OutputDir | Should -Be 'build-reports'
        $cfg.ConnectTimeout | Should -Be 10
        $cfg.WebhookSendTest | Should -BeFalse
    }

    It "Get-VerificationConfig reads values from the verification section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $true; ssh = $false; connectTimeout = 25; outputDir = 'reports/verify' } } }
        $cfg = Get-VerificationConfig -State $state
        $cfg.Enabled | Should -BeTrue
        $cfg.Ssh | Should -BeFalse
        $cfg.ConnectTimeout | Should -Be 25
        $cfg.OutputDir | Should -Be 'reports/verify'
    }

    It "Invoke-InfraVerification returns $null when verification.enabled=false and no -Force" {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false } } }
        $r = Invoke-InfraVerification -State $state
        $r | Should -BeNullOrEmpty
    }

    It "Invoke-InfraVerification -Force writes the JSON report and skips unconfigured items" {
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            ProjectRoot = $TestDrive
            BuildConfig = [PSCustomObject]@{
                verification = [PSCustomObject]@{ enabled = $false; sdk = $false; ssh = $true; remoteCache = $true; otel = $true; webhook = $true; outputDir = 'verify-out' }
                distributed  = [PSCustomObject]@{ hosts = @() }
                telemetry    = [PSCustomObject]@{ otel = [PSCustomObject]@{ enabled = $false } }
                alerting     = [PSCustomObject]@{ webhookUrl = '' }
            }
            DotnetCmd  = $null
        }
        $r = Invoke-InfraVerification -State $state -Force
        $r | Should -Not -BeNullOrEmpty
        $r.Overall | Should -Be 'skipped'
        $r.Skipped | Should -BeGreaterThan 0
        $report = Join-Path (Join-Path $TestDrive 'verify-out') 'infra-verification.json'
        Test-Path -LiteralPath $report | Should -BeTrue
        $parsed = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $parsed.Tool | Should -Be 'gbuild'
    }

    It "SDK check passes when dotnet actually answers --list-sdks" {
        $fakeBin = Join-Path $TestDrive 'okbin'
        $fakeDotnet = New-FakeDotnet -Directory $fakeBin -Output '8.0.400' -ExitCode 0
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = $null; DotnetCmd = $fakeDotnet }
        $r = Invoke-InfraVerification -State $state -Force
        $sdk = @($r.Checks | Where-Object { $_.Name -eq 'sdk.dotnet' } | Select-Object -First 1)
        $sdk.Status | Should -Be 'passed'
    }

    It "SDK check fails when dotnet is a ghost stub (exit 0 but no output)" {
        $fakeBin = Join-Path $TestDrive 'stubbin'
        $fakeDotnet = New-FakeDotnet -Directory $fakeBin -Output '' -ExitCode 0
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = $null; DotnetCmd = $fakeDotnet }
        $r = Invoke-InfraVerification -State $state -Force
        $sdk = @($r.Checks | Where-Object { $_.Name -eq 'sdk.dotnet' } | Select-Object -First 1)
        $sdk.Status | Should -Be 'failed'
        $sdk.Detail | Should -Match 'ghost|stub'
    }

    It "SSH check is skipped when no distributed.hosts are configured" {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; distributed = [PSCustomObject]@{ hosts = @() } }; DotnetCmd = $null }
        $r = Invoke-InfraVerification -State $state -Force
        $ssh = @($r.Checks | Where-Object { $_.Name -eq 'distributed.ssh' } | Select-Object -First 1)
        $ssh.Status | Should -Be 'skipped'
    }

    It "SSH check pass khi host reachable (mock Invoke-RemoteCommand)" {
        function global:Get-DistributedConfig { return [PSCustomObject]@{ hosts = @([PSCustomObject]@{ name = 'h1'; hostname = '10.0.0.1'; user = 'root'; port = 22 }) } }
        function global:Invoke-RemoteCommand { return [PSCustomObject]@{ Success = $true; Error = $null } }
        try {
            $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; distributed = [PSCustomObject]@{ hosts = @() } }; DotnetCmd = $null }
            $r = Invoke-InfraVerification -State $state -Force
            $ssh = @($r.Checks | Where-Object { $_.Name -eq 'distributed.ssh' } | Select-Object -First 1)
            $ssh.Status | Should -Be 'passed'
        } finally {
            Remove-Item Function:global:Get-DistributedConfig -ErrorAction SilentlyContinue
            Remove-Item Function:global:Invoke-RemoteCommand -ErrorAction SilentlyContinue
        }
    }

    It "SSH check fails when the host is unreachable (mocked error)" {
        function global:Get-DistributedConfig { return [PSCustomObject]@{ hosts = @([PSCustomObject]@{ name = 'h1'; hostname = '10.0.0.1'; user = 'root'; port = 22 }) } }
        function global:Invoke-RemoteCommand { return [PSCustomObject]@{ Success = $false; Error = 'Connection refused' } }
        try {
            $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; distributed = [PSCustomObject]@{ hosts = @() } }; DotnetCmd = $null }
            $r = Invoke-InfraVerification -State $state -Force
            $ssh = @($r.Checks | Where-Object { $_.Name -eq 'distributed.ssh' } | Select-Object -First 1)
            $ssh.Status | Should -Be 'failed'
        } finally {
            Remove-Item Function:global:Get-DistributedConfig -ErrorAction SilentlyContinue
            Remove-Item Function:global:Invoke-RemoteCommand -ErrorAction SilentlyContinue
        }
    }

    It "Remote cache is skipped when cacheRemote.enabled=false (mocked Get-RemoteCacheConfig)" {
        function global:Get-RemoteCacheConfig { return [PSCustomObject]@{ Enabled = $false; Type = 'azureBlob' } }
        try {
            $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false } }; DotnetCmd = $null }
            $r = Invoke-InfraVerification -State $state -Force
            $rc = @($r.Checks | Where-Object { $_.Name -eq 'cache.remote' } | Select-Object -First 1)
            $rc.Status | Should -Be 'skipped'
        } finally {
            Remove-Item Function:global:Get-RemoteCacheConfig -ErrorAction SilentlyContinue
        }
    }

    It "OTLP is skipped when the endpoint is an unresolved env placeholder" {
        Remove-Item Env:GBUILD_OTLP_TEST_EP -ErrorAction SilentlyContinue
        $state = [PSCustomObject]@{
            ScriptRoot  = $TestDrive
            ProjectRoot = $TestDrive
            BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; telemetry = [PSCustomObject]@{ otel = [PSCustomObject]@{ enabled = $true; endpoint = '${env:GBUILD_OTLP_TEST_EP}' } } }
            DotnetCmd  = $null
        }
        $r = Invoke-InfraVerification -State $state -Force
        $otel = @($r.Checks | Where-Object { $_.Name -eq 'telemetry.otel' } | Select-Object -First 1)
        $otel.Status | Should -Be 'skipped'
    }

    It "Webhook is skipped when alerting.webhookUrl is not configured" {
        Remove-Item Env:GBUILD_ALERT_WEBHOOK -ErrorAction SilentlyContinue
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; alerting = [PSCustomObject]@{ webhookUrl = '${env:GBUILD_ALERT_WEBHOOK}' } }; DotnetCmd = $null }
        $r = Invoke-InfraVerification -State $state -Force
        $wh = @($r.Checks | Where-Object { $_.Name -eq 'alerting.webhook' } | Select-Object -First 1)
        $wh.Status | Should -Be 'skipped'
    }

    It "Webhook passes (no test send) when the URL is configured" {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false }; alerting = [PSCustomObject]@{ webhookUrl = 'https://example.com/hook' } }; DotnetCmd = $null }
        $r = Invoke-InfraVerification -State $state -Force
        $wh = @($r.Checks | Where-Object { $_.Name -eq 'alerting.webhook' } | Select-Object -First 1)
        $wh.Status | Should -Be 'passed'
    }
}

Describe 'InfraVerification safety' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'InfraVerification.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'does not remediate during a default verification' {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false; sdk = $false; ssh = $false; remoteCache = $false; otel = $false; webhook = $false; outputDir = 'verify-readonly' } } }
        $result = Invoke-InfraVerification -State $state -Force
        $result.ReadOnly | Should -BeTrue
        $result.Remediation | Should -BeNullOrEmpty
    }

    It 'redacts configured webhook credentials from the report' {
        $secret = 'infra-secret-token'
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false; sdk = $false; ssh = $false; remoteCache = $false; otel = $false; webhook = $true; webhookSendTest = $false; outputDir = 'verify-redaction' }; alerting = [PSCustomObject]@{ webhookUrl = "https://user:pass@example.test/hook?token=$secret" } } }
        $result = Invoke-InfraVerification -State $state -Force
        $result.ReportPath | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $result.ReportPath -Raw) | Should -Not -Match $secret
        $result.Checks[0].Target | Should -Not -Match $secret
    }

    It 'marks remediation explicitly when requested' {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ verification = [PSCustomObject]@{ enabled = $false; sdk = $false; ssh = $false; remoteCache = $false; otel = $false; webhook = $false; outputDir = 'verify-remediate' } } }
        $result = Invoke-InfraVerification -State $state -Force -Remediate
        $result.ReadOnly | Should -BeFalse
        $result.MutationRequested | Should -BeTrue
        $result.Remediation | Should -Not -BeNullOrEmpty
    }
}
