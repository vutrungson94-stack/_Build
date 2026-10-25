$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Alerting — token generation' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Alerting.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'New-WebhookToken returns a non-empty url-safe token' {
        $t = New-WebhookToken
        $t | Should -Not -BeNullOrEmpty
        $t | Should -Not -Match '[=+/]'
    }

    It 'New-WebhookToken returns unique values across calls' {
        $a = New-WebhookToken
        $b = New-WebhookToken
        $a | Should -Not -Be $b
    }
}

Describe 'Alerting — expiration check' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Alerting.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Test-WebhookTokenExpired is true for MinValue' {
        Test-WebhookTokenExpired -CreatedAt ([DateTime]::MinValue) | Should -BeTrue
    }

    It 'Test-WebhookTokenExpired is false for a fresh token within interval' {
        Test-WebhookTokenExpired -CreatedAt (Get-Date) -IntervalHours 24 | Should -BeFalse
    }

    It 'Test-WebhookTokenExpired is true for an old token past interval' {
        $old = (Get-Date).AddHours(-48)
        Test-WebhookTokenExpired -CreatedAt $old -IntervalHours 24 | Should -BeTrue
    }
}

Describe 'Alerting — rotation' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Alerting.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Update-WebhookToken generates and stores a token on a fresh state' {
        $s = [PSCustomObject]@{}
        $tok = Update-WebhookToken -State $s -IntervalHours 24
        $tok | Should -Not -BeNullOrEmpty
        $s.AlertingToken | Should -Be $tok
        $s.AlertingTokenCreatedAt | Should -Not -BeNullOrEmpty
    }

    It 'Update-WebhookToken returns the same token when not expired' {
        $s = [PSCustomObject]@{ AlertingToken = 'fixed-token'; AlertingTokenCreatedAt = (Get-Date) }
        $tok = Update-WebhookToken -State $s -IntervalHours 24
        $tok | Should -Be 'fixed-token'
    }

    It 'Update-WebhookToken rotates when expired' {
        $s = [PSCustomObject]@{ AlertingToken = 'old-token'; AlertingTokenCreatedAt = (Get-Date).AddHours(-48) }
        $tok = Update-WebhookToken -State $s -IntervalHours 24
        $tok | Should -Not -Be 'old-token'
        $s.AlertingToken | Should -Be $tok
    }

    It 'Update-WebhookToken works without a State (returns token, no storage)' {
        $tok = Update-WebhookToken -IntervalHours 24
        $tok | Should -Not -BeNullOrEmpty
    }
}

Describe 'Alerting safety' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Alerting.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'redacts URL credentials and token assignments' {
        $text = Protect-AlertText 'https://user:pass@example.test/hook?token=super-secret&x=1 token=other-secret'
        $text | Should -Not -Match 'super-secret|other-secret|pass'
        $text | Should -Match 'REDACTED'
    }

    It 'returns false when the transport cannot deliver' {
        $ok = Invoke-WebhookPost -Url 'http://127.0.0.1:1/hook' -Payload @{ message = 'test' } -Label 'TEST' -MaxAttempts 1 -RetryDelayMs 0
        $ok | Should -BeFalse
    }

    It 'uses a stable idempotency key for equivalent payloads' {
        $payload = [ordered]@{ message = 'same'; severity = 'Critical'; data = @{ id = 'event-1' } }
        $first = Get-AlertIdempotencyKey -Label 'ALERT' -Payload $payload
        $second = Get-AlertIdempotencyKey -Label 'ALERT' -Payload $payload
        $first | Should -Be $second
    }
}
