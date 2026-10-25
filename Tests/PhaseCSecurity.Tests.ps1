# Phase C Security Tests — AES cross-platform encryption, secret audit, license enforcement
# Validates the hardened security features of the _Build system.
# Run separately from other test files to avoid module session state pollution.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Phase C — CredentialVault AES cross-platform encryption' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $keyFile = Join-Path $TestDrive 'vault-test.key'
        if (Test-Path $keyFile) { Remove-Item $keyFile -Force }
    }

    It 'AES encrypt/decrypt round-trips correctly' {
        $plain = 'super-secret-password-123!@#'
        $enc = Protect-CredentialAes -Value $plain -KeyFilePath $keyFile
        $enc | Should -Not -BeNullOrEmpty
        $enc | Should -Match '^enca:'
        $dec = Unprotect-CredentialAes -ProtectedValue $enc -KeyFilePath $keyFile
        $dec | Should -Be $plain
    }

    It 'AES encryption is non-deterministic (unique IV per call)' {
        $plain = 'same-input'
        $e1 = Protect-CredentialAes -Value $plain -KeyFilePath $keyFile
        $e2 = Protect-CredentialAes -Value $plain -KeyFilePath $keyFile
        $e1 | Should -Not -Be $e2
        Unprotect-CredentialAes -ProtectedValue $e1 -KeyFilePath $keyFile | Should -Be $plain
        Unprotect-CredentialAes -ProtectedValue $e2 -KeyFilePath $keyFile | Should -Be $plain
    }

    It 'Protect-CredentialValue prefers AES on all platforms' {
        $plain = 'cross-platform-secret'
        $enc = Protect-CredentialValue -Value $plain -KeyFilePath $keyFile
        $enc | Should -Match '^enca:'
        # Resolve-SecretValue was removed: Unprotect-CredentialAes is the only
        # decrypt path (CredentialVault keeps exactly one implementation). This
        # test kept calling the deleted name, so the scope failed with
        # CommandNotFoundException on every run.
        $dec = Unprotect-CredentialAes -ProtectedValue $enc -KeyFilePath $keyFile
        $dec | Should -Be $plain
    }

    It 'Resolve-ConfigSecrets decrypts enca: values in config tree' {
        $config = [PSCustomObject]@{
            deploy = [PSCustomObject]@{
                azure = [PSCustomObject]@{
                    password = Protect-CredentialAes -Value 'azure-secret' -KeyFilePath $keyFile
                }
            }
        }
        $resolved = Resolve-ConfigSecrets -Node $config -KeyFilePath $keyFile
        $resolved.deploy.azure.password | Should -Be 'azure-secret'
    }
}

Describe 'Phase C — Secret audit logging' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $auditLog = Join-Path $TestDrive 'secret-audit.log'
        if (Test-Path $auditLog) { Remove-Item $auditLog -Force }
    }

    It 'Write-SecretAuditLog records access events' {
        $state = [PSCustomObject]@{ TenantId = 't1'; CorrelationId = 'c1' }
        Write-SecretAuditLog -SecretName 'deploy.azure.password' -Action 'read' -Module 'DeployTargets' -LogPath $auditLog -State $state
        Test-Path $auditLog | Should -Be $true
        $logContent = Get-Content $auditLog -Raw -ErrorAction SilentlyContinue
        $logContent | Should -Match 'deploy.azure.password'
        $logContent | Should -Match 'DeployTargets'
    }
}

Describe 'Phase C — License compliance enforcement' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Security.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $testDir = Join-Path $TestDrive 'licproj'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        # Create a project with a denied package
        $csproj = Join-Path $testDir 'Test.csproj'
        Set-Content -Path $csproj -Value '<Project><ItemGroup><PackageReference Include="Banned.Package" Version="1.0" /></ItemGroup></Project>' -Encoding UTF8
    }

    It 'Invoke-LicenseCompliance returns $true with warn policy (no block)' {
        $state = [PSCustomObject]@{
            WorkingDir = $testDir
            BuildConfig = [PSCustomObject]@{
                license = [PSCustomObject]@{
                    deny = @('Banned.*')
                }
                security = [PSCustomObject]@{
                    licenseEnforcement = 'warn'
                }
            }
        }
        $result = Invoke-LicenseCompliance -State $state
        $result | Should -Be $true
    }

    It 'Invoke-LicenseCompliance returns $false with block policy' {
        $state = [PSCustomObject]@{
            WorkingDir = $testDir
            BuildConfig = [PSCustomObject]@{
                license = [PSCustomObject]@{
                    deny = @('Banned.*')
                }
                security = [PSCustomObject]@{
                    licenseEnforcement = 'block'
                }
            }
        }
        $result = Invoke-LicenseCompliance -State $state
        $result | Should -Be $false
    }

    It 'Invoke-LicenseCompliance throws with fail policy' {
        $state = [PSCustomObject]@{
            WorkingDir = $testDir
            BuildConfig = [PSCustomObject]@{
                license = [PSCustomObject]@{
                    deny = @('Banned.*')
                }
                security = [PSCustomObject]@{
                    licenseEnforcement = 'fail'
                }
            }
        }
        { Invoke-LicenseCompliance -State $state } | Should -Throw
    }
}
