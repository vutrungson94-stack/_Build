$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'CredentialVault — availability detection' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Test-CredentialVaultAvailable returns a boolean' {
        $r = Test-CredentialVaultAvailable
        $r | Should -BeOfType ([bool])
    }
}

Describe 'CredentialVault — protect/unprotect roundtrip' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Roundtrips a value with platform-appropriate protection' {
        $secret = 'super-secret-api-key-123'
        $enc = Protect-CredentialValue -Value $secret
        $enc | Should -Not -BeNullOrEmpty
        if (Test-CredentialVaultAvailable) {
            $enc | Should -Match '^(enca:v2:|enca:dpapi:v1:|enc:)'
            $dec = Unprotect-CredentialValue -ProtectedValue $enc
            $dec | Should -Be $secret
        } else {
            { Protect-CredentialValue -Value $secret } | Should -Throw
        }
    }

    It 'Protect-CredentialValue uses an authenticated or OS-protected envelope' {
        $enc = Protect-CredentialValue -Value 'abc'
        if (Test-CredentialVaultAvailable) {
            $enc | Should -Match '^(enca:v2:|enca:dpapi:v1:|enc:)'
        } else {
            { Protect-CredentialValue -Value 'abc' } | Should -Throw
        }
    }

    It 'Unprotect-CredentialValue returns non-encrypted values unchanged' {
        $plain = 'just-a-plain-value'
        Unprotect-CredentialValue -ProtectedValue $plain | Should -Be $plain
    }

    # Resolve-SecretValue was deleted: exported, documented in the module header
    # as the config-decryption entry point, and called by nothing - the header
    # described a flow that did not exist. The real entry point is
    # Resolve-ConfigSecrets, so the round-trip contract is asserted through it.
    It 'Resolve-ConfigSecrets decrypts an encrypted leaf and passes plaintext through' {
        $plain = 'hello-world'
        $node = [pscustomobject]@{ secret = $plain }
        $null = Resolve-ConfigSecrets -Node $node
        $node.secret | Should -Be $plain
        if (Test-CredentialVaultAvailable) {
            $enc = Protect-CredentialValue -Value 'xyz'
            $node2 = [pscustomobject]@{ secret = $enc }
            $null = Resolve-ConfigSecrets -Node $node2
            $node2.secret | Should -Be 'xyz'
        }
    }

    # ConvertTo-EncryptedSecret was removed: it was a one-line pass-through to
    # Protect-CredentialValue with the identical signature, exported, and had no
    # production caller. Protect-CredentialValue is the single entry point; the
    # round-trip contract it owns is asserted here.
    It 'Protect-CredentialValue produces a decryptable protected value' {
        $enc = Protect-CredentialValue -Value 'token-987'
        if (Test-CredentialVaultAvailable) {
            Unprotect-CredentialValue -ProtectedValue $enc | Should -Be 'token-987'
        } else {
            { Protect-CredentialValue -Value 'token-987' } | Should -Throw
        }
    }
    It 'exposes exactly one encryption entry point (no duplicate alias)' {
        $exported = @(Get-Command -Module 'CredentialVault' -CommandType Function -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $exported | Should -Not -Contain 'ConvertTo-EncryptedSecret'
        $exported | Should -Contain 'Protect-CredentialValue'
    }

    It 'Empty values roundtrip to empty' {
        Protect-CredentialValue -Value '' | Should -Be ''
        Unprotect-CredentialValue -ProtectedValue '' | Should -Be ''
    }
}

Describe 'CredentialVault — Resolve-ConfigSecrets (auto-decrypt on load)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop

        $env:GBUILD_TEST_SECRET = 'from-env-var'
    }

    AfterAll {
        Remove-Item Env:GBUILD_TEST_SECRET -ErrorAction SilentlyContinue
    }

    It 'resolves ${env:VAR} placeholders anywhere in the config tree' {
        $cfg = [PSCustomObject]@{
            deploy = [PSCustomObject]@{
                azure = [PSCustomObject]@{ sasToken = '${env:GBUILD_TEST_SECRET}' }
}


            list = @('${env:GBUILD_TEST_SECRET}', 'static')
        }
        $resolved = Resolve-ConfigSecrets -Node $cfg
        $resolved.deploy.azure.sasToken | Should -Be 'from-env-var'
        $resolved.list[0] | Should -Be 'from-env-var'
        $resolved.list[1] | Should -Be 'static'
    }

    It 'decrypts enca: values when vault available, leaves value as-is on other OS' {
        $secret = 'vault-secret-42'
        $enc = Protect-CredentialValue -Value $secret
        $cfg = [PSCustomObject]@{ security = [PSCustomObject]@{ password = $enc } }
        $resolved = Resolve-ConfigSecrets -Node $cfg
        if (Test-CredentialVaultAvailable) {
            $resolved.security.password | Should -Be $secret
        } else {
            { Resolve-ConfigSecrets -Node $cfg } | Should -Throw
        }
    }

    It 'leaves non-secret strings untouched' {
        $cfg = [PSCustomObject]@{ build = [PSCustomObject]@{ maxParallelJobs = 4; name = 'rel' } }
        $resolved = Resolve-ConfigSecrets -Node $cfg
        $resolved.build.maxParallelJobs | Should -Be 4
        $resolved.build.name | Should -Be 'rel'
    }
}

Describe 'CredentialVault — audit log wiring' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }

    It 'Write-SecretAuditLog writes a JSON entry to file' {
        $tmpLog = Join-Path $( [System.IO.Path]::GetTempPath() ) "audit-test-$(Get-Random).log"
        $mockState = [PSCustomObject]@{ TenantId = 'test'; CorrelationId = 'abc123' }
        Write-SecretAuditLog -SecretName 'test.secret' -Action 'read' -Module 'test' -LogPath $tmpLog -State $mockState
        $content = Get-Content $tmpLog -Raw
        $content | Should -Not -BeNullOrEmpty
        $parsed = $content | ConvertFrom-Json -EA Stop
        $parsed.SecretName | Should -Be 'test.secret'
        $parsed.Action | Should -Be 'read'
        $parsed.TenantId | Should -Be 'test'
        Remove-Item $tmpLog -Force -EA 0
    }

    It 'Protect-CredentialValue does not throw when auditing' {
        $mockState = [PSCustomObject]@{ TenantId = 'test'; CorrelationId = 'xyz' }
        { Protect-CredentialValue -Value 'test-val' -Purpose 'test.audit' -State $mockState } | Should -Not -Throw
    }

    It 'Unprotect-CredentialValue does not throw when auditing' {
        $mockState = [PSCustomObject]@{ TenantId = 'test'; CorrelationId = 'xyz' }
        if (Test-CredentialVaultAvailable) {
            $enc = Protect-CredentialValue -Value 'audit-roundtrip' -State $mockState
            { Unprotect-CredentialValue -ProtectedValue $enc -Purpose 'test.audit' -State $mockState } | Should -Not -Throw
        }
    }

    It 'Write-BuildAuditLog rotates to audit-<timestamp>.log when MaxSizeMB is exceeded' {
        $testDir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('audit-rot-test-' + (Get-Random))
        $null = New-Item -ItemType Directory -Path $testDir -Force -ErrorAction SilentlyContinue
        $tmpLog = Join-Path $testDir 'audit.log'
        try {
            # Force rotation by using a very small size
            $firstEntry = @{ N = 1; Timestamp = (Get-Date).ToString('o') }
            Write-BuildAuditLog -LogPath $tmpLog -Entry $firstEntry -MaxSizeMB 0.000001

            # Write a second entry which should trigger rotation
            $secondEntry = @{ N = 2; Timestamp = (Get-Date).ToString('o') }
            Write-BuildAuditLog -LogPath $tmpLog -Entry $secondEntry -MaxSizeMB 0.000001

            # Check for rotated file (only in our test directory)
            $after = @(Get-ChildItem $testDir -Filter 'audit-*.log' -ErrorAction SilentlyContinue)
            $rotated = $after | Where-Object { $_ -ne $tmpLog }

            # Verify rotation happened
            $rotated.Count | Should -Be 1

            # Verify main file contains only second entry
            $mainContent = @(Get-Content $tmpLog -ErrorAction Stop)
            $mainContent.Count | Should -Be 1
            (Get-Content $rotated[0].FullName -Raw -ErrorAction Stop | ConvertFrom-Json).N | Should -Be 1
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'CredentialVault - L5 per-deployment salts (no shared literal)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Get-VaultSalt never returns a shared literal' {
        $s1 = Get-VaultSalt -Key 'VaultStaticSalt' -State $null
        $s1 | Should -Not -BeNullOrEmpty
        $s1 | Should -Not -Be 'gbuild-static-salt-v2'
        $s2 = Get-VaultSalt -Key 'VaultMachineSalt' -State $null
        $s2 | Should -Not -BeNullOrEmpty
        $s2 | Should -Not -Be 'gbuild-machine-salt-v2'
    }
    It 'Get-VaultSalt is stable within a deployment (persisted file)' {
        $a = Get-VaultSalt -Key 'VaultStaticSalt' -State $null
        $b = Get-VaultSalt -Key 'VaultStaticSalt' -State $null
        $b | Should -Be $a
    }
    It 'BuildConstants carries no shared salt literal' {
        $bc = Get-Content (Join-Path $global:GBuildModuleRoot 'BuildConstants.psm1') -Raw -Encoding UTF8
        $bc | Should -Not -Match 'gbuild-static-salt-v2'
        $bc | Should -Not -Match 'gbuild-machine-salt-v2'
    }
}

Describe 'CredentialVault - authenticated envelope regressions' {
    It 'writes version, nonce and tag and rejects tampering' {
        $keyFile = Join-Path $TestDrive 'authenticated-vault.key'
        $value = Protect-CredentialAes -Value 'authenticated-secret' -KeyFilePath $keyFile
        $value | Should -Match '^enca:(v2:|dpapi:v1:)'
        if ($value.StartsWith('enca:v2:')) {
            $payload = [Convert]::FromBase64String($value.Substring(8))
            $payload.Length | Should -BeGreaterThan 28
        }
        $tampered = $value.Substring(0, $value.Length - 1) + ($(if ($value.EndsWith('A')) { 'B' } else { 'A' }))
        { Unprotect-CredentialAes -ProtectedValue $tampered -KeyFilePath $keyFile } | Should -Throw
    }
    It 'rejects malformed protected values instead of returning ciphertext' {
        { Unprotect-CredentialAes -ProtectedValue 'enca:not-base64' -KeyFilePath (Join-Path $TestDrive 'missing-vault.key') } | Should -Throw
    }
    It 'isolates tenant key paths' {
        $a = [pscustomobject]@{ TenantId = 'tenant-a'; ProjectRoot = $TestDrive }
        $b = [pscustomobject]@{ TenantId = 'tenant-b'; ProjectRoot = $TestDrive }
        (Get-VaultKeyFile -State $a) | Should -Not -Be (Get-VaultKeyFile -State $b)
    }
    It 'decrypts an encrypted value supplied through an environment placeholder' {
        $keyFile = Join-Path $TestDrive 'env-vault.key'
        $env:GBUILD_VAULT_TEST_VALUE = Protect-CredentialValue -Value 'env-secret' -KeyFilePath $keyFile
        try {
            $cfg = [pscustomobject]@{ value = '${env:GBUILD_VAULT_TEST_VALUE}' }
            (Resolve-ConfigSecrets -Node $cfg -KeyFilePath $keyFile).value | Should -Be 'env-secret'
        } finally { Remove-Item Env:GBUILD_VAULT_TEST_VALUE -ErrorAction SilentlyContinue }
    }
}

Describe 'CredentialVault - default key filename is unguessable (no fixed TEMP name)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CredentialVault.psm1') -Force -DisableNameChecking -ErrorAction Stop
        # Hermetic TEMP: the machine may own a real legacy gbuild-vault.key (which
        # the fallback path must honour). Point TEMP at a REAL isolated dir (a
        # PSDrive path like $TestDrive is meaningless to .NET GetTempPath, which
        # would fall through to the real TEMP) so the assertions are deterministic.
        $script:VaultOrigTmp = $env:TMP
        $script:VaultOrigTemp = $env:TEMP
        $script:VaultOrigTmpDir = $env:TMPDIR
        $script:VaultIsoTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-vault-test-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:VaultIsoTemp -Force
        $env:TMP = $script:VaultIsoTemp
        $env:TEMP = $script:VaultIsoTemp
        $env:TMPDIR = $script:VaultIsoTemp
    }
    AfterAll {
        $env:TMP = $script:VaultOrigTmp
        $env:TEMP = $script:VaultOrigTemp
        $env:TMPDIR = $script:VaultOrigTmpDir
        if ($script:VaultIsoTemp -and (Test-Path $script:VaultIsoTemp)) { Remove-Item $script:VaultIsoTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-VaultKeyFile issues a hashed name, never the fixed gbuild-vault.key' {
        # The fixed '<TEMP>\gbuild-vault.key' name let any local principal
        # pre-create the file; the key loader then trusted the planted content.
        $td = Join-Path $script:VaultIsoTemp 'projA'
        $null = New-Item -ItemType Directory -Path $td -Force
        $st = [PSCustomObject]@{ ProjectRoot = $td; ScriptRoot = $td }
        $p = Get-VaultKeyFile -State $st
        [System.IO.Path]::GetFileName($p) | Should -Not -Be 'gbuild-vault.key'
        $p | Should -Match 'gbuild-vault-[0-9a-f]{16}\.key$'
    }

    It 'Get-VaultKeyFile names differ per project root (no cross-project key reuse)' {
        $a = Join-Path $script:VaultIsoTemp 'projB1'
        $b = Join-Path $script:VaultIsoTemp 'projB2'
        $null = New-Item -ItemType Directory -Path $a -Force
        $null = New-Item -ItemType Directory -Path $b -Force
        $pa = Get-VaultKeyFile -State ([PSCustomObject]@{ ProjectRoot = $a; ScriptRoot = $a })
        $pb = Get-VaultKeyFile -State ([PSCustomObject]@{ ProjectRoot = $b; ScriptRoot = $b })
        $pa | Should -Not -Be $pb
    }

    It 'Get-VaultKeyFile falls back to the legacy fixed name only when it already exists' {
        # Backward compatibility for vaults sealed before the hashed name: an
        # EXISTING legacy file is still honoured (with a rotation warning);
        # otherwise the hashed name is always issued. Runs inside the isolated
        # TEMP so the machine's real vault (if any) is never touched.
        $td = Join-Path $script:VaultIsoTemp 'projC'
        $null = New-Item -ItemType Directory -Path $td -Force
        $legacy = Join-Path $script:VaultIsoTemp 'gbuild-vault.key'
        $st = [PSCustomObject]@{ ProjectRoot = $td; ScriptRoot = $td }
        Get-VaultKeyFile -State $st | Should -Not -Be $legacy
        'legacy-placeholder' | Set-Content -LiteralPath $legacy -Encoding UTF8 -Force
        $first = Get-VaultKeyFile -State $st
        if (-not (Test-Path -LiteralPath $first -PathType Leaf)) {
            # Hashed file absent + legacy present -> legacy honoured.
            $first | Should -Be $legacy
        }
        Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    }
}
