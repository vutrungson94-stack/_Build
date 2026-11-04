# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# CredentialVault.psm1 — Encryption at rest for sensitive config values
# Provides cross-platform AES-256-CBC encryption with PBKDF2 key derivation
# (portable: Windows/Linux/macOS) plus optional Windows DPAPI (ProtectedData,
# per-user) when available. When no keyfile is present, falls back to DPAPI on
# Windows or a machine-specific derived key (best-effort, non-portable) otherwise.
# Integration points:
#   - Security.psm1 secret scanner treats vault-encrypted values as already protected.
#   - Config loader decrypts through Resolve-ConfigSecrets (which recurses into
#     itself). Resolve-SecretValue used to be advertised here as the entry point
#     but nothing ever called it, so the header described a flow that did not
#     exist - the kind of claim that sends an operator to the wrong function.


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils')


# OS detection uses Get-OSPlatform from Environment.psm1 (Tier-1 import).
# No module-local $script:isWindows — call Get-OSPlatform directly for consistency.

Import-GBuildModule -Names @('SharedUtils', 'PathUtils') -Force
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Get-OSPlatform'
# Locale carries the vault's invariant messages. Every refusal in this module
# (an invalid path, a short salt, a disabled legacy ciphertext) reaches an
# operator as an exception message, and an operator who switched the UI
# language must not have a security refusal answer them in English. Declared,
# not assumed, so a standalone Import-Module resolves it too.
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

$script:EncPrefix = 'enc:'
$script:AesPrefix = 'enca:'
$script:VaultFormatVersion = 2
# AEAD parameters now single-sourced in BuildConstants (VaultNonceSize,
# VaultTagSize, VaultAssociatedDataUtf8, VaultKeyLengthBytes). The literal
# defaults keep this module importable before BuildConstants loads.
$script:VaultNonceSize = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'VaultNonceSize' -Fallback 12) } else { 12 }
$script:VaultTagSize = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'VaultTagSize' -Fallback 16) } else { 16 }
$aad = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'VaultAssociatedDataUtf8' -Fallback 'gbuild-vault-v2') } else { 'gbuild-vault-v2' }
$script:VaultAssociatedData = [System.Text.Encoding]::UTF8.GetBytes($aad)

function Get-SafeVaultTenant {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $tenant = 'default'
    if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) {
        $tenant = [string]$State.TenantId
    }
    if ($tenant -eq 'default') { return $tenant }
    if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $tenant.Contains('..') -or $tenant -match '[. ]$') {
        throw (Get-LocaleMessage -Key 'log.vault.tenantUnsafe' -Fallback 'Vault tenant identifier is not safe.')
    }
    return $tenant
}

function Get-VaultRootDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        return [string](Get-BuildRootDirectory -State $State)
    }
    if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) {
        return [string]$State.ProjectRoot
    }
    if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) {
        return [string]$State.ScriptRoot
    }
    return (Split-Path $PSScriptRoot -Parent)
}

function Resolve-SafeVaultPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [PSCustomObject]$State
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw (Get-LocaleMessage -Key 'log.vault.pathInvalid' -Fallback 'Vault path is invalid.')
    }
    $value = $Path
    if ($value -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
        $value = [string](Resolve-EnvPlaceholder -Text $value)
    }
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '\$\{env:') {
        throw (Get-LocaleMessage -Key 'log.vault.pathUnresolved' -Fallback 'Vault path is unresolved.')
    }
    $root = Get-VaultRootDirectory -State $State
    $candidate = if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $root $value }
    $full = [System.IO.Path]::GetFullPath($candidate)
    $tmpRoots = @([System.IO.Path]::GetTempPath())
    foreach ($v in @($env:TEMP, $env:TMP, $env:TMPDIR)) { if ($v -and -not $tmpRoots.Contains($v)) { $tmpRoots += $v } }
    # Pester on macOS/macOS runner uses /private/tmp (and /tmp is a symlink to it).
    # .NET GetTempPath() may return the per-user TMPDIR (/var/folders/.../T/), which
    # is a different directory. Add both so test fixtures under Pester's TestDrive
    # are not rejected as "outside permitted roots".
    $unixTmpRoots = @('/tmp', '/private/tmp')
    foreach ($t in $unixTmpRoots) {
        if (-not $tmpRoots.Contains($t)) { $tmpRoots += $t }
    }
    $allowedRoots = @($root) + $tmpRoots
    # Containment itself is owned by PathUtils.Test-PathUnderRoots. The null /
    # placeholder checks above remain here because they produce different
    # vault-specific errors than a failed containment check.
    $safe = Test-PathUnderRoots -Path $full -AllowedRoots @($allowedRoots)
    if (-not $safe) { throw (Get-LocaleMessage -Key 'log.vault.pathOutsideRoots' -Fallback 'Vault path is outside the permitted roots.') }
    return $full
}

function Get-VaultKeyFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$DefaultPath
    )
    $tenant = Get-SafeVaultTenant -State $State
    $configured = ''
    if ($State -and $State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -and
        $State.BuildConfig.PSObject.Properties.Name -contains 'security' -and $State.BuildConfig.security -and
        $State.BuildConfig.security.PSObject.Properties.Name -contains 'vaultKeyFile') {
        $configured = [string]$State.BuildConfig.security.vaultKeyFile
    }
    if ($configured -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
        $resolvedConfigured = [string](Resolve-EnvPlaceholder -Text $configured)
        if ([string]::IsNullOrWhiteSpace($resolvedConfigured) -or $resolvedConfigured -match '\$\{env:') { $configured = '' }
    }
    $value = if (-not [string]::IsNullOrWhiteSpace($configured)) { $configured } else { $DefaultPath }
    $usedDefaultName = $false
    if ([string]::IsNullOrWhiteSpace($value)) {
        $usedDefaultName = ($tenant -eq 'default')
        if ($tenant -ne 'default') {
            $root = Get-VaultRootDirectory -State $State
            $logs = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'LogsDir' -Fallback 'logs') } else { 'logs' }
            $value = Join-Path $root (Join-Path $logs (Join-Path $tenant 'vault.key'))
        } else {
            # Unpredictable default key filename. The old fixed name
            # '<TEMP>\gbuild-vault.key' lived in a world-writable directory under
            # a constant name, so any local principal could pre-create (or
            # symlink) it before the first build; Get-OrCreateVaultKeyFile then
            # trusted the planted content as the AES key (TOCTOU). The name is
            # now SHA256(vaultRoot + tenant), truncated - unguessable without
            # knowing the project root, and distinct per project/tenant.
            $root = Get-VaultRootDirectory -State $State
            $tag = ''
            # SharedUtils.Get-BuildStringHash owns UTF8 -> SHA256 -> lowercase
            # hex. This inline copy produced the SAME digest, so the tenant
            # key-file tag was stable either way - but it was a fourth place to
            # get wrong, and it truncated the hex itself.
            if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) {
                try {
                    $full = Get-BuildStringHash -Text ('vault-key|' + [string]$root + '|' + $tenant).ToLowerInvariant()
                    if ($full) { $tag = $full.Substring(0, 16) }
                } catch { $tag = '' }
            }
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = [guid]::NewGuid().ToString('N').Substring(0, 16) }
            $value = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-vault-' + $tag + '.key')
        }
    }
    if ($tenant -ne 'default') {
        $resolved = if ([System.IO.Path]::IsPathRooted($value)) { [System.IO.Path]::GetFullPath($value) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-VaultRootDirectory -State $State) $value)) }
        $parent = [System.IO.Path]::GetDirectoryName($resolved)
        $leaf = [System.IO.Path]::GetFileName($resolved)
        $value = Join-Path (Join-Path (Join-Path $parent 'tenants') $tenant) $leaf
    }
    # Backward compatibility: vaults sealed before the hashed default name read
    # '<TEMP>\gbuild-vault.key'. If the hashed file does not exist yet but the
    # legacy one does, keep reading the legacy file (new writes still go to the
    # hashed name once the legacy file is gone).
    #
    # Ordering is load-bearing: the DECISION ($value = $legacy) is assigned
    # before any logging is attempted, and the rotation warning lives in its own
    # inner try/catch. An earlier shape warned first inside the same try block,
    # so a Write-Log failure (e.g. a minimal State without Colors, or Logging
    # unloaded) jumped to the outer catch and silently reverted the decision
    # back to the hashed name - the test suite caught exactly that.
    if ($usedDefaultName) {
        $legacy = ''
        try {
            $legacy = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-vault.key'
            if (-not (Test-Path -LiteralPath $value -PathType Leaf) -and (Test-Path -LiteralPath $legacy -PathType Leaf)) {
                $value = $legacy
            } else {
                $legacy = ''
            }
        } catch { $legacy = '' }
        if ($legacy) {
            try {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Resolve-LogMessage -Key 'log.vault.legacyKey' -Fallback '[VAULT] Using legacy predictable key file gbuild-vault.key. Rotate it: delete the file and re-seal so a hashed name is issued.') 'Warn' $State
                }
            } catch { }
        }
    }
    return (Resolve-SafeVaultPath -Path $value -State $State)
}

function Get-VaultPbkdf2Iterations {
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$State)
    # SINGLE SOURCE for the iteration FLOOR. The literal 100000 appeared three
    # times in this function while BuildConstants declared
    # VaultMinIterations = 1000 - a value the code would have rejected. A
    # constant that contradicts the enforcement it names is worse than no
    # constant: it reads as "the minimum is 1000" to anyone auditing the table.
    # VaultMinIterations now IS the floor, and the default is derived from the
    # working iteration count so the two can never disagree.
    $floor = 100000
    $defaultIterations = 100000
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $floor = [int](Get-BuildConstant -Key 'VaultMinIterations' -Fallback 100000) } catch { $floor = 100000 }
        try { $defaultIterations = [int](Get-BuildConstant -Key 'VaultPbkdf2Iterations' -Fallback 100000) } catch { $defaultIterations = 100000 }
    }
    # Never let the floor be weaker than the value the vault actually uses.
    if ($floor -lt $defaultIterations) { $floor = $defaultIterations }
    if ($floor -lt 100000) { $floor = 100000 }
    if ($defaultIterations -lt $floor) { $defaultIterations = $floor }

    $v = $null
    if ($State -and $State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -and
        $State.BuildConfig.PSObject.Properties.Name -contains 'security' -and $State.BuildConfig.security -and
        $State.BuildConfig.security.PSObject.Properties.Name -contains 'vault' -and $State.BuildConfig.security.vault -and
        $State.BuildConfig.security.vault.PSObject.Properties.Name -contains 'pbkdf2Iterations') {
        $v = [string]$State.BuildConfig.security.vault.pbkdf2Iterations
        if ($v -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
            $v = [string](Resolve-EnvPlaceholder -Text $v)
        }
        # An env var that is NOT set leaves the literal ${env:...} text in
        # place (Resolve-EnvPlaceholder returns the match verbatim when the
        # variable is empty). That text is not a number, so the numeric check
        # below would THROW on every host that simply does not export
        # GBUILD_VAULT_PBKDF2_ITERATIONS - which is the shipped default config.
        # The throw was swallowed by the credential-protection call sites, so
        # the whole at-rest encryption control silently no-opped while the
        # module still reported as loaded. Get-VaultSalt already treats an
        # unresolved placeholder as UNCONFIGURED; this reader now does the
        # same, so an unset variable falls through to the derived default
        # instead of aborting the vault.
        if (Test-UnresolvedEnvPlaceholder -Text $v) { $v = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '^\d+$') {
        throw (Get-LocaleMessage -Key 'log.vault.pbkdf2SettingInvalid' -Fallback 'Vault PBKDF2 iteration setting is invalid.')
    }
    if (-not [string]::IsNullOrWhiteSpace($v) -and [int64]$v -lt $floor) {
        throw (Get-LocaleMessage -Key 'log.vault.pbkdf2IterationsFloor' -MessageArgs @([string]$floor) -Fallback 'Vault PBKDF2 iterations must be at least {0}.')
    }
    if (-not [string]::IsNullOrWhiteSpace($v)) { return [int]$v }
    return $defaultIterations
}

function Get-VaultSalt {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [PSCustomObject]$State
    )
    if ($Key -notmatch '^[A-Za-z0-9._-]+$') { throw (Get-LocaleMessage -Key 'log.vault.saltKeyInvalid' -Fallback 'Vault salt key is invalid.') }
    if ($State -and $State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -and
        $State.BuildConfig.PSObject.Properties.Name -contains 'security' -and $State.BuildConfig.security -and
        $State.BuildConfig.security.PSObject.Properties.Name -contains 'vault' -and $State.BuildConfig.security.vault -and
        $State.BuildConfig.security.vault.PSObject.Properties.Name -contains $Key) {
        $v = [string]$State.BuildConfig.security.vault.$Key
        if ($v -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
            $v = [string](Resolve-EnvPlaceholder -Text $v)
        }
        if (-not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '\$\{env:') {
            try { $bytes = [System.Convert]::FromBase64String($v); if ($bytes.Count -ge 16) { return $v } } catch { }
            throw (Get-LocaleMessage -Key 'log.vault.saltConfiguredInvalid' -Fallback 'Configured vault salt is invalid.')
        }
    }
    $persisted = Get-OrCreateVaultSaltFile -Key $Key -State $State
    if ($persisted) { return $persisted }
    $eph = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($eph) } finally { $rng.Dispose() }
    return [System.Convert]::ToBase64String($eph)
}

function Protect-VaultSecretFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ((Get-OSPlatform) -eq 'Windows') {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $acl.SetAccessRuleProtection($true, $false)
            $winId = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($winId.User, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        } else {
            & chmod 600 $Path
            if ($LASTEXITCODE -ne 0) { throw (Get-LocaleMessage -Key 'log.vault.chmodFailed' -Fallback 'chmod failed') }
        }
    } catch {
        throw (Get-LocaleMessage -Key 'log.vault.permissionsRestrictedFailed' -Fallback 'Vault secret file permissions could not be restricted.')
    }
}

function Write-VaultSecretFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [switch]$Replace
    )
    # SharedUtils owns the atomic primitive; this module owns the one thing
    # that has to happen to the bytes BEFORE they land: the vault file must
    # have its permissions hardened while it is still the temp file, because
    # after the Replace it is already at its final path.
    #
    # This was the ONLY writer in the tree with no delegation at all - a
    # private 15-line copy of the temp/Replace/move shape. -PreCommit exists on
    # the shared primitive precisely so this case does not need that copy.
    if (-not $Replace -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (Get-LocaleMessage -Key 'log.vault.fileExists' -Fallback 'Vault file already exists.')
    }
    $ok = Write-BuildTextFileAtomic -Path $Path -Lines @($Content) -PreCommit { param($tempPath) Protect-VaultSecretFile -Path $tempPath }
    if (-not $ok) { throw (Get-LocaleMessage -Key 'log.vault.writeAtomicFailed' -Fallback 'Vault secret file could not be written atomically.') }
}

function Get-OrCreateVaultSaltFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [PSCustomObject]$State
    )
    $keyFile = Get-VaultKeyFile -State $State
    $dir = [System.IO.Path]::GetDirectoryName($keyFile)
    $saltPath = Join-Path $dir ('gbuild.' + $Key + '.salt')
    if (Test-Path -LiteralPath $saltPath -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($saltPath).Trim()
            $bytes = [System.Convert]::FromBase64String($raw)
            if ($bytes.Count -lt 16) { throw (Get-LocaleMessage -Key 'log.vault.saltTooShort' -Fallback 'salt too short') }
            return $raw
        } catch {
            throw (Get-LocaleMessage -Key 'log.vault.saltFileCorrupt' -Fallback 'Vault salt file is corrupt.')
        }
    }
    $fresh = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($fresh) } finally { $rng.Dispose() }
    $b64 = [System.Convert]::ToBase64String($fresh)
    Write-VaultSecretFile -Path $saltPath -Content $b64
    return $b64
}

function Get-DerivedKey {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][SecureString]$Passphrase,
        [byte[]]$Salt,
        [int]$Iterations = (Get-VaultPbkdf2Iterations -State $null)
    )
    if ($Iterations -lt 100000) { throw (Get-LocaleMessage -Key 'log.vault.iterationsTooLow' -Fallback 'Vault PBKDF2 iterations must be at least 100000.') }
    $passPlain = [System.Net.NetworkCredential]::new('', $Passphrase).Password
    $passBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$passPlain)
    try {
        if ($null -eq $Salt -or $Salt.Count -eq 0) { $Salt = [System.Text.Encoding]::UTF8.GetBytes((Get-VaultSalt -Key 'VaultStaticSalt' -State $null)) }
        $pbkdf2 = $null
        try {
            $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passBytes, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        } catch {
            $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passBytes, $Salt, $Iterations)
        }
        $keyLen = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'VaultKeyLengthBytes' -Fallback 32) } else { 32 }
        try { return [byte[]]($pbkdf2.GetBytes($keyLen)) } finally { if ($pbkdf2) { $pbkdf2.Dispose() } }
    } finally {
        [Array]::Clear($passBytes, 0, $passBytes.Length)
        $passPlain = $null
    }
}

function Get-VaultAeadType {
    [CmdletBinding()]
    param()
    $type = $null
    try { $type = [Type]::GetType('System.Security.Cryptography.AesGcm, System.Security.Cryptography') } catch { }
    if ($null -eq $type) {
        try { $type = [Type]::GetType('System.Security.Cryptography.AesGcm, System.Runtime') } catch { }
    }
    return $type
}

function Get-OrCreateVaultKey {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$KeyFilePath,
        [switch]$AllowCreate
    )
    $keyFile = if ($KeyFilePath) { Resolve-SafeVaultPath -Path $KeyFilePath -State $State } else { Get-VaultKeyFile -State $State }
    if ($KeyFilePath -and $State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId -and [string]$State.TenantId -ne 'default') {
        $tenant = Get-SafeVaultTenant -State $State
        $parent = [System.IO.Path]::GetDirectoryName($keyFile)
        $leaf = [System.IO.Path]::GetFileName($keyFile)
        $tenantRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $parent 'tenants') $tenant))
        # TENANT ISOLATION BOUNDARY. A per-tenant key file must live under that
        # tenant's own directory. Comparing case-insensitively on a
        # case-sensitive volume would accept tenant 'acme' reading tenant
        # 'Acme''s key file, because the two roots are distinct directories that
        # differ only by case. Get-PathComparison is the single source.
        $tenantContained = $false
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
            try { $tenantContained = Test-PathUnderRoots -Path $keyFile -AllowedRoots @($tenantRoot) } catch { $tenantContained = $false }
        } else {
            $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
                   else { if ((Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost)) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
            try { $tenantContained = $keyFile.StartsWith($tenantRoot + [System.IO.Path]::DirectorySeparatorChar, $cmp) } catch { $tenantContained = $false }
        }
        if (-not $tenantContained -or $keyFile -eq $tenantRoot) { $keyFile = Join-Path $tenantRoot $leaf }
    }
    if (Test-Path -LiteralPath $keyFile -PathType Leaf) {
        try {
            $b64 = [System.IO.File]::ReadAllText($keyFile).Trim()
            $key = [System.Convert]::FromBase64String($b64)
            $expectedLen = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'VaultKeyLengthBytes' -Fallback 32) } else { 32 }
            if ($key.Length -ne $expectedLen) { throw (Get-LocaleMessage -Key 'log.vault.keyLengthInvalid' -Fallback 'invalid key length') }
            return [byte[]]$key
        } catch {
            throw (Get-LocaleMessage -Key 'log.vault.keyFileInvalid' -Fallback 'Vault key file is invalid.')
        }
    }
    if (-not $AllowCreate) { throw (Get-LocaleMessage -Key 'log.vault.keyFileMissing' -Fallback 'Vault key file is missing.') }
    # Single owner: SharedUtils.Get-BuildIdentity. The local variant used
    # 'unknown-host'/'unknown-user' sentinels while every other site used a
    # different chain, so the PBKDF2 passphrase below depended on which module
    # happened to derive it on a given host. The derivation and identity now
    # share one chain ('unknown' | DNS fallback | env), so a host produces the
    # SAME derived key regardless of which entry point ran first.
    $ident = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { Get-BuildIdentity -State $State } else { $null }
    $machineId = if ($ident) { [string]$ident.Host } else { 'unknown' }
    $user = if ($ident) { [string]$ident.User } else { 'unknown' }
    $salt = [System.Text.Encoding]::UTF8.GetBytes((Get-VaultSalt -Key 'VaultMachineSalt' -State $State))
    $passphraseText = "$machineId|$user|gbuild"
    $secure = New-Object System.Security.SecureString
    foreach ($character in $passphraseText.ToCharArray()) { [void]$secure.AppendChar($character) }
    $secure.MakeReadOnly()
    $passphraseText = $null
    $key = Get-DerivedKey -Passphrase $secure -Salt $salt -Iterations (Get-VaultPbkdf2Iterations -State $State)
    Write-VaultSecretFile -Path $keyFile -Content ([System.Convert]::ToBase64String($key))
    return $key
}

function Get-VaultLegacyCbcAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)
    $value = $false
    if ($State -and $State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -and
        $State.BuildConfig.PSObject.Properties.Name -contains 'security' -and $State.BuildConfig.security -and
        $State.BuildConfig.security.PSObject.Properties.Name -contains 'vault' -and $State.BuildConfig.security.vault) {
        $v = $State.BuildConfig.security.vault
        foreach ($key in @('allowLegacyCbc', 'legacyCbc', 'allowLegacy', 'legacyCbcEnabled', 'readLegacyCbc')) {
            if ($v -is [System.Collections.IDictionary] -and $v.Contains($key)) { $raw = [string]$v[$key]; $value = $raw -in @('1','true','yes','on','read','read-only'); $source = "config:security.vault.$key"; break }
            if ($v.PSObject.Properties.Name -contains $key) { $raw = [string]$v.$key; $value = $raw -in @('1','true','yes','on','read','read-only'); $source = "config:security.vault.$key"; break }
        }
    }
    if (-not $value -and $env:GBUILD_VAULT_ALLOW_LEGACY_CBC -eq '1') { $value = $true; $source = 'env:GBUILD_VAULT_ALLOW_LEGACY_CBC' }
    # Fail-visible, not fail-silent: re-enabling legacy CBC is a deliberate
    # crypto downgrade (flagged by the 2026-10 hardcode audit as an unlogged
    # convenience switch). Record it in the security audit trail with the
    # source, so an operator reviewing the log can answer "who downgraded?".
    if ($value) { try { Write-SecretAuditLog -SecretName 'vault.legacyCbc' -Action 'read' -Module "CredentialVault:$source" -State $State } catch { } }
    return $value
}

function Protect-CredentialAes {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [PSCustomObject]$State,
        [string]$KeyFilePath
    )
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $type = Get-VaultAeadType
    if ($null -eq $type) {
        if (-not (Initialize-DpapiProvider)) { throw (Get-LocaleMessage -Key 'log.vault.aesGcmUnavailable' -Fallback 'AES-GCM is unavailable.') }
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
            $purposeBytes = [System.Text.Encoding]::UTF8.GetBytes($(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'VaultAesPurposeUtf8' -Fallback 'gbuild-vault-aead') } else { 'gbuild-vault-aead' }))
            $protected  = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $purposeBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return ($script:AesPrefix + 'dpapi:v1:' + [System.Convert]::ToBase64String($protected))
        } catch { throw (Get-LocaleMessage -Key 'log.vault.encryptionFailed' -Fallback 'Vault encryption failed.') + ' [' + [string]$_.Exception.Message + ']' }
    }
    $gcm = $null
    $rng = $null
    try {
        $key = Get-OrCreateVaultKey -State $State -KeyFilePath $KeyFilePath -AllowCreate
        $nonce = New-Object byte[] $script:VaultNonceSize
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($nonce)
        $plain = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $cipher = New-Object byte[] $plain.Length
        $tag = New-Object byte[] $script:VaultTagSize
        $gcm = New-Object -TypeName $type.FullName -ArgumentList (,$key)
        $gcm.Encrypt($nonce, $plain, $cipher, $tag, $script:VaultAssociatedData)
        $payload = New-Object byte[] ($nonce.Length + $tag.Length + $cipher.Length)
        [Array]::Copy($nonce, 0, $payload, 0, $nonce.Length)
        [Array]::Copy($tag, 0, $payload, $nonce.Length, $tag.Length)
        [Array]::Copy($cipher, 0, $payload, $nonce.Length + $tag.Length, $cipher.Length)
        return ($script:AesPrefix + 'v2:' + [System.Convert]::ToBase64String($payload))
    } catch {
        throw (Get-LocaleMessage -Key 'log.vault.encryptionFailed' -Fallback 'Vault encryption failed.') + ' [' + [string]$_.Exception.Message + ']'
    } finally {
        if ($gcm -and ($gcm -is [System.IDisposable])) { $gcm.Dispose() }
        if ($rng) { $rng.Dispose() }
    }
}

function Unprotect-CredentialAes {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProtectedValue,
        [PSCustomObject]$State,
        [string]$KeyFilePath
    )
    if ([string]::IsNullOrEmpty($ProtectedValue)) { return '' }
    if (-not $ProtectedValue.StartsWith($script:AesPrefix)) { return $ProtectedValue }
    $gcm = $null
    $aes = $null
    try {
        $body = $ProtectedValue.Substring($script:AesPrefix.Length)
        if ($body.StartsWith('dpapi:v1:')) {
            if (-not (Initialize-DpapiProvider)) { throw (Get-LocaleMessage -Key 'log.vault.dpapiUnavailable' -Fallback 'DPAPI unavailable') }
            $protected = [System.Convert]::FromBase64String($body.Substring(9))
            $purposeBytes = [System.Text.Encoding]::UTF8.GetBytes($(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'VaultAesPurposeUtf8' -Fallback 'gbuild-vault-aead') } else { 'gbuild-vault-aead' }))
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $purposeBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            return $strict.GetString($bytes)
        }
        $key = Get-OrCreateVaultKey -State $State -KeyFilePath $KeyFilePath
        if ($body.StartsWith('v2:')) {
            $type = Get-VaultAeadType
            if ($null -eq $type) { throw (Get-LocaleMessage -Key 'log.vault.aesGcmUnavailable' -Fallback 'AES-GCM unavailable') }
            $payload = [System.Convert]::FromBase64String($body.Substring(3))
            if ($payload.Length -lt ($script:VaultNonceSize + $script:VaultTagSize)) { throw (Get-LocaleMessage -Key 'log.vault.payloadShort' -Fallback 'short payload') }
            $nonce = New-Object byte[] $script:VaultNonceSize
            $tag = New-Object byte[] $script:VaultTagSize
            $cipher = New-Object byte[] ($payload.Length - $script:VaultNonceSize - $script:VaultTagSize)
            [Array]::Copy($payload, 0, $nonce, 0, $nonce.Length)
            [Array]::Copy($payload, $nonce.Length, $tag, 0, $tag.Length)
            [Array]::Copy($payload, $nonce.Length + $tag.Length, $cipher, 0, $cipher.Length)
            $plain = New-Object byte[] $cipher.Length
            $gcm = New-Object -TypeName $type.FullName -ArgumentList (,$key)
            $gcm.Decrypt($nonce, $cipher, $tag, $plain, $script:VaultAssociatedData)
            return [System.Text.Encoding]::UTF8.GetString($plain)
        }
        if (-not (Get-VaultLegacyCbcAllowed -State $State)) { throw (Get-LocaleMessage -Key 'log.vault.legacyCiphertextDisabled' -Fallback 'legacy ciphertext disabled') }
        $full = [System.Convert]::FromBase64String($body)
        if ($full.Length -lt 32) { throw (Get-LocaleMessage -Key 'log.vault.legacyPayloadShort' -Fallback 'short legacy payload') }
        $iv = New-Object byte[] 16
        $cipher = New-Object byte[] ($full.Length - 16)
        [Array]::Copy($full, 0, $iv, 0, 16)
        [Array]::Copy($full, 16, $cipher, 0, $cipher.Length)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $decryptor = $aes.CreateDecryptor()
        $plain = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($plain)
    } catch {
        throw (Get-LocaleMessage -Key 'log.vault.decryptionFailed' -Fallback 'Vault decryption failed.')
    } finally {
        if ($gcm -and ($gcm -is [System.IDisposable])) { $gcm.Dispose() }
        if ($aes) { $aes.Dispose() }
    }
}

function Initialize-DpapiProvider {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ((Get-OSPlatform) -ne 'Windows') { return $false }
    try { Add-Type -AssemblyName 'System.Security' -ErrorAction Stop } catch { }
    try { $null = [System.Security.Cryptography.ProtectedData]; return $true } catch { return $false }
}

function Test-CredentialVaultAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($null -ne (Get-VaultAeadType)) { return $true }
    if ((Get-OSPlatform) -eq 'Windows') { return (Initialize-DpapiProvider) }
    return $false
}

function Protect-CredentialValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string]$Purpose = 'gbuild',
        [PSCustomObject]$State,
        [string]$KeyFilePath
    )
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $result = ''
    try {
        if (Test-CredentialVaultAvailable) {
            $result = Protect-CredentialAes -Value $Value -State $State -KeyFilePath $KeyFilePath
        }
    } catch {
        $result = ''
    }
    if ([string]::IsNullOrEmpty($result) -and (Get-OSPlatform) -eq 'Windows') {
        try {
            if (-not (Initialize-DpapiProvider)) { throw (Get-LocaleMessage -Key 'log.vault.dpapiUnavailable' -Fallback 'DPAPI unavailable') }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
            $purposeBytes = [System.Text.Encoding]::UTF8.GetBytes($Purpose)
            $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $purposeBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $result = $script:EncPrefix + [System.Convert]::ToBase64String($protected)
        } catch {
            $result = ''
        }
    }
    if ([string]::IsNullOrEmpty($result)) { throw (Get-LocaleMessage -Key 'log.vault.noProvider' -Fallback 'No secure credential provider is available.') }
    Write-SecretAuditLog -SecretName $Purpose -Action 'write' -Module $MyInvocation.MyCommand -State $State
    return $result
}

function Unprotect-CredentialValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProtectedValue,
        [string]$Purpose = 'gbuild',
        [PSCustomObject]$State,
        [string]$KeyFilePath
    )
    if ([string]::IsNullOrEmpty($ProtectedValue)) { return '' }
    if ($ProtectedValue.StartsWith($script:AesPrefix)) {
        $plaintext = Unprotect-CredentialAes -ProtectedValue $ProtectedValue -State $State -KeyFilePath $KeyFilePath
    } elseif ($ProtectedValue.StartsWith($script:EncPrefix)) {
        if ((Get-OSPlatform) -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.vault.dpapiWrongPlatform' -Fallback 'DPAPI credential cannot be decrypted on this platform.') }
        try {
            $protected = [System.Convert]::FromBase64String($ProtectedValue.Substring($script:EncPrefix.Length))
            $purposeBytes = [System.Text.Encoding]::UTF8.GetBytes($Purpose)
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $purposeBytes, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $plaintext = $strict.GetString($bytes)
        } catch {
            throw (Get-LocaleMessage -Key 'log.vault.credentialDecryptionFailed' -Fallback 'Credential decryption failed.')
        }
    } else {
        return $ProtectedValue
    }
    Write-SecretAuditLog -SecretName $Purpose -Action 'read' -Module $MyInvocation.MyCommand -State $State
    return $plaintext
}

function Resolve-ConfigSecrets {
    [CmdletBinding()]
    param($Node, [PSCustomObject]$State, [string]$KeyFilePath)
    if ($null -eq $Node) { return $Node }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { $Node[$k] = (Resolve-ConfigSecrets $Node[$k] -State $State -KeyFilePath $KeyFilePath) }
        return $Node
    }
    if ($Node -is [PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $prop.Value = (Resolve-ConfigSecrets $prop.Value -State $State -KeyFilePath $KeyFilePath)
        }
        return $Node
    }
    if ($Node -is [Array]) {
        # PRESERVE THE ARRAY. `for (...) { $Node[$i] = (...) }; return $Node` was
        # wrong: a PowerShell function writes its result to the PIPELINE, which
        # unrolls an array, so the caller at the $prop.Value assignment received
        # the ELEMENTS rather than the array. An empty array produced no output at
        # all and the parent property was set to $null - which then failed schema
        # validation with "Value is not valid with the schema: Value is \"null\"
        # but should be \"array\"". Rebuild into a list and return it wrapped, so a
        # 0-, 1- and n-element array all survive the round trip.
        $resolvedItems = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Node) { $resolvedItems.Add((Resolve-ConfigSecrets -Node $item -State $State -KeyFilePath $KeyFilePath)) }
        return ,$resolvedItems.ToArray()
    }
    if ($Node -is [string]) {
        $value = $Node
        if ($value -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
            $value = [string](Resolve-EnvPlaceholder -Text $value)
        }
        if ($value.StartsWith($script:AesPrefix) -or $value.StartsWith($script:EncPrefix)) {
            return Unprotect-CredentialValue -ProtectedValue $value -State $State -KeyFilePath $KeyFilePath
        }
        return $value
    }
    return $Node
}

# --- Export ---

<#
.SYNOPSIS
    Records a secret access event in the security audit log.
.DESCRIPTION
    Tracks who accessed which secret, when, and from which module. Writes to the
    configurable audit log path (security.auditLogPath) resolved via Get-AuditLogPath,
    or the default logs/<tenant>/audit.log under the project root.
    This provides compliance traceability for secret access.
.PARAMETER SecretName
    Logical name of the secret (e.g. 'deploy.azure.password').
.PARAMETER Action
    'read' | 'write' | 'rotate' — what was done with the secret.
.PARAMETER Module
    Name of the calling module/function for traceability.
.PARAMETER State
    Build state (carries BuildConfig + TenantId + CorrelationId).
#>
function Write-SecretAuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [ValidateSet('read', 'write', 'rotate')][string]$Action = 'read',
        [string]$Module = 'unknown',
        [string]$LogPath,
        [PSCustomObject]$State
    )
    $tenant = Get-SafeVaultTenant -State $State
    $logPath = if ($LogPath) {
        $LogPath
    } else {
        Get-AuditLogPath -State $State
    }
    try {
        $id = Get-BuildIdentity
        $entry = @{
            Timestamp    = (Get-Date).ToString('o')
            SecretName   = $SecretName
            Action       = $Action
            Module       = $Module
            TenantId     = $tenant
            CorrelationId = Get-BuildCorrelationId -State $State
            User         = $id.User
            Host         = $id.Host
        }
        # Single source: BuildConstants.AuditLogMaxSizeMB (config security.auditLogMaxSizeMB wins).
        $maxMb = if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
            [int](Get-ConfigValue -Path 'security.auditLogMaxSizeMB' -State $State -Default (
                (Get-BuildConstant -Key 'AuditLogMaxSizeMB' -Fallback 10)
            ))
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'AuditLogMaxSizeMB' -Fallback 10) } else { 10 }
        Write-BuildAuditLog -LogPath $logPath -Entry $entry -MaxSizeMB $maxMb | Out-Null
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.vault.auditWriteFailed' -MessageArgs @([string]$_) -Fallback '[CredentialVault] Audit log write failed: {0}') 'Warn' $State
        }
    }
}

Export-ModuleMember -Function @(
    'Test-CredentialVaultAvailable',
    'Protect-CredentialValue',
    'Unprotect-CredentialValue',
    'Resolve-ConfigSecrets',
    'Protect-CredentialAes',
    'Unprotect-CredentialAes',
    'Get-VaultKeyFile',
    'Get-VaultSalt',
    'Write-SecretAuditLog'
)




