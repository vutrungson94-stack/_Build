# ============================================================================
# Distributed.Certificate.Tests.ps1 (A2 - certificate-based auth pre-flight)
# ============================================================================
# Tests for Test-RemoteHostCertificate. Co-located with existing Distributed
# tests; run via:  .\_Build\Tests\Run-CoreTests.ps1 -Scope DistributedCertificate
# ============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$distModule = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'Distributed.psm1'))

Import-Module $distModule -Force -DisableNameChecking

Describe 'Distributed A2 - Test-RemoteHostCertificate' {

    It 'returns HasCertConfig=false when host has no certificate config' {
        $hostObj = [PSCustomObject]@{
            name     = 'plain'
            hostname = '10.0.0.1'
            user     = 'builder'
        }
        $r = Test-RemoteHostCertificate -TargetHost $hostObj -State $null
        $r.HasCertConfig | Should -BeFalse
        $r.Valid | Should -BeFalse
    }

    It 'rejects a certificate file that is not an X.509 certificate' {
        $tmp = New-TemporaryFile
        try {
            $hostObj = [PSCustomObject]@{
                name            = 'linux-cert'
                hostname        = '10.0.0.2'
                certificatePath = $tmp.FullName
            }
            $r = Test-RemoteHostCertificate -TargetHost $hostObj -State $null
            $r.HasCertConfig | Should -BeTrue
            $r.Valid | Should -BeFalse
            $r.Message | Should -Match 'parse'
        }
        finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
    }

    It 'flags a missing certificate file path as invalid' {
        $hostObj = [PSCustomObject]@{
            name            = 'linux-cert-missing'
            hostname        = '10.0.0.3'
            certificatePath = 'C:\no\such\cert.pem'
        }
        $r = Test-RemoteHostCertificate -TargetHost $hostObj -State $null
        $r.HasCertConfig | Should -BeTrue
        $r.Valid | Should -BeFalse
        $r.Message | Should -Match 'not found'
    }

    It 'gracefully handles a thumbprint when Cert: store is unavailable' {
        # In a sandbox (or non-Windows), Cert: may be absent -> soft "not available" result
        $hostObj = [PSCustomObject]@{
            name                 = 'win-cert'
            hostname             = '10.0.0.4'
            certificateThumbprint = '00AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899'
        }
        $r = Test-RemoteHostCertificate -TargetHost $hostObj -State $null
        $r.HasCertConfig | Should -BeTrue
        if (Test-Path 'Cert:\') {
            # On a real Windows host with the store present, result depends on presence
            $r | Should -Not -BeNullOrEmpty
        }
        else {
            $r.Valid | Should -BeFalse
            $r.Message | Should -Match 'not available'
        }
    }

    It 'rejects an unresolved certificate password placeholder' {
        $tmp = New-TemporaryFile
        try {
            $hostObj = [PSCustomObject]@{
                name                = 'linux-cert-pw'
                hostname            = '10.0.0.5'
                certificatePath     = $tmp.FullName
                certificatePassword = '${env:GBUILD_TEST_CERTPW_MISSING}'
            }
            $r = Test-RemoteHostCertificate -TargetHost $hostObj -State $null
            $r.HasCertConfig | Should -BeTrue
            $r.Valid | Should -BeFalse
            $r.Message | Should -Match 'password'
        }
        finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Distributed A2 - hard-gate (requireCert) decision' {

    BeforeAll {
        function global:Write-Log { param($m, $l, $s) }
    }

    AfterAll {
        Remove-Item Function:Write-Log -ErrorAction SilentlyContinue
    }

    It 'gates OUT a host when requireCert is set and its certificate is invalid' {
        $hostObj = [PSCustomObject]@{
            name            = 'bad-cert'
            hostname        = '10.0.0.9'
            certificatePath = 'C:\no\such\cert.pem'
            requireCert     = $true
        }
        Test-HostCertGate -TargetHost $hostObj -State $null | Should -BeFalse
    }

    It 'passes a host when requireCert is set and its certificate is valid' {
        Mock Test-RemoteHostCertificate { [PSCustomObject]@{ HasCertConfig = $true; Valid = $true; Message = 'valid' } } -ModuleName Distributed
        $hostObj = [PSCustomObject]@{
            name            = 'good-cert'
            hostname        = '10.0.0.10'
            user            = 'builder'
            certificatePath = 'certificate.pem'
            requireCert     = $true
        }
        Test-HostCertGate -TargetHost $hostObj -State $null | Should -BeTrue
    }

    It 'does not allow requireCert to bypass missing certificate configuration' {
        $hostObj = [PSCustomObject]@{
            name        = 'plain-require'
            hostname    = '10.0.0.11'
            user        = 'builder'
            requireCert = $true
        }
        Test-HostCertGate -TargetHost $hostObj -State $null | Should -BeFalse
    }

    It 'passes a host with invalid cert but requireCert absent (soft warning)' {
        $hostObj = [PSCustomObject]@{
            name            = 'soft-cert'
            hostname        = '10.0.0.12'
            user            = 'builder'
            certificatePath = 'C:\no\such\cert.pem'
        }
        Test-HostCertGate -TargetHost $hostObj -State $null | Should -BeTrue
    }
}
