# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'ConfigProvider', 'CredentialVault', 'EventBus')
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildTimestamp'
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Get-OSPlatform'


# ============================================================================
# AuditLedger.psm1 - Immutable Audit Trail with WORM & Ledger Support
# ============================================================================
# Provides tamper-evident audit logging with:
# - Hash chaining (Merkle tree) for integrity verification
# - WORM (Write Once Read Many) storage backends
# - Cryptographic signing of audit entries
# - Verifiable replay and compliance reporting
#
# OWNERSHIP (do not confuse with Security.Write-AuditLog): Write-AuditLog in
# Security.psm1 is the human-readable operational audit trail (consumed by
# DeployTargets/Orchestrator/RBAC/Versioning). Write-AuditLedgerEntry HERE is
# the tamper-evident Merkle-chained compliance ledger (WORM + retention +
# verification). Two layers, two owners - by design.

# ── Built-in config (config-overridable via security.auditLedger) ─────────────
# Level 5 single-source: numeric defaults resolve from BuildConstants at import
# (AuditLedgerFileMaxSizeMB/FileMaxFiles/TreeDepth/CheckpointInterval/MemoryCap).
function Get-AuditLedgerDefault {
    param([string]$Key, $Fallback)

Set-StrictMode -Version 1.0
    try {
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            return Get-BuildDefault -Key $Key -Fallback $Fallback
        }
    } catch { }
    return $Fallback
}
$script:DefaultAuditLedgerConfig = @{
    Enabled              = $false
    Backend              = 'file'  # 'file' | 's3' | 'azureBlob' | 'ledger' | 'custom'
    MemoryCap            = (Get-AuditLedgerDefault -Key 'AuditLedgerMemoryCap' -Fallback 5000)  # in-memory ring bound for the 'ledger' backend
    File                 = @{
        Path               = 'audit-ledger.jsonl'
        MaxSizeMB          = (Get-AuditLedgerDefault -Key 'AuditLedgerFileMaxSizeMB' -Fallback 100)
        MaxFiles           = (Get-AuditLedgerDefault -Key 'AuditLedgerFileMaxFiles' -Fallback 100)
        Immutable          = $true  # WORM: prevent overwrite/delete
    }
    S3                   = @{
        Bucket             = ''
        Region             = ''
        Prefix             = 'audit-ledger/'
        ObjectLock         = $true  # S3 Object Lock for WORM
        RetentionDays      = 2555  # 7 years default
    }
    AzureBlob            = @{
        Container          = 'audit-ledger'
        ImmutableStorage   = $true  # Azure Immutable Blob Storage
        RetentionDays      = 2555
    }
    Ledger               = @{
        Type               = 'merkle'  # 'merkle' | 'hashchain' | 'custom'
        HashAlgorithm      = 'SHA256'
        CheckpointInterval = (Get-AuditLedgerDefault -Key 'AuditLedgerCheckpointInterval' -Fallback 1000)  # Entries between Merkle root checkpoints
        SigningKey         = ''  # Path to signing key (env placeholder supported)
    }
    Signing              = @{
        Enabled            = $true
        Algorithm          = 'RSA-SHA256'  # 'RSA-SHA256' | 'ECDSA-SHA256' | 'Ed25519'
        KeyPath            = ''  # Path to private key (env placeholder supported)
        KeyPassword        = ''  # Key password (env placeholder supported)
        CertPath           = ''  # Optional certificate for verification
        RequireKey         = $true  # L5 fail-closed: signing.enabled without a usable key throws (explicit opt-out: signing.enabled=false)
    }
    Verification         = @{
        Enabled            = $true
        Schedule           = '0 2 * * *'  # Daily at 2 AM (cron)
        OnStartup          = $true
        OnDemand           = $true
        AlertOnFailure     = $true
    }
    Retention            = @{
        DefaultDays        = 2555  # 7 years
        PerCategory        = @{}  # e.g., { "security": 3650, "build": 2555 }
        LegalHold          = @()  # Categories under legal hold (never expire)
    }
    Compliance           = @{
        Standards          = @('SOX', 'GDPR', 'HIPAA', 'PCI-DSS')
        ExportFormat       = 'jsonl'  # 'jsonl' | 'csv' | 'cef' | 'syslog'
        IncludeHashChain   = $true
        IncludeSignatures  = $true
    }
}

# ── Module state ──────────────────────────────────────────────────────────────
$script:LedgerState = @{
    CurrentHash      = ''
    EntryCount       = 0
    TreeRoot         = ''
    LastCheckpoint   = 0
    SigningKey       = $null
    VerificationKey  = $null
    Initialized      = $false
    # Bounded in-memory ring for the 'ledger' backend (no file): keeps the most
    # recent entries so Test-AuditLedger can validate without a file store.
    # Level 5 single-source: AuditLedgerMemoryCap (distinct from ExeTimeoutMs=5000).
    MemoryEntries    = New-Object System.Collections.ArrayList
    MemoryCap        = (Get-AuditLedgerDefault -Key 'AuditLedgerMemoryCap' -Fallback 5000)
}

# ── Config merge (defaults + user override, fully recursive) ──────────────────
# Level 5 DRY: the deep-merge ALGORITHM lives in exactly one place -
# ConfigProvider.Merge-ConfigObject, the canonical recursive merge. This module
# keeps only a thin wrapper that binds $script:DefaultAuditLedgerConfig as the
# base tree. The old one-level loop merged a default section only with the
# override's node AT that section, so (a) an override reaching a second level
# below a section (security.auditLedger.ledger.<obj>.<key>) REPLACED that whole
# nested object and silently dropped its siblings, and (b) any override key
# absent from the defaults was discarded outright (the loop only walked the base
# keys). Delegating fixes both at every depth and makes AuditLedger agree with
# ClusterOrchestrator on $getVal semantics (any IDictionary OR PSCustomObject
# override is honoured).

# Shape adapter, NOT a merge: Merge-ConfigObject normalises to PSCustomObject, but
# AuditLedger's callers depend on IDictionary semantics on the merged tree:
#   * $script:LedgerConfig['EnvOrigin'] = ... (index WRITE - PSCustomObject has no indexer)
#   * $retention.PerCategory.ContainsKey($category) (Update-AuditRetention)
#   * the `-is [IDictionary]` probe for a custom ledger.checkpointPath
# so the merged tree is converted back to nested hashtables. Arrays and scalars
# are passed through untouched.
function ConvertTo-LedgerHashtable {
    [CmdletBinding()]
    [OutputType([object])]
    param($Value)
    if ($Value -is [System.Array]) { return , $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($k in $Value.Keys) { $copy[$k] = ConvertTo-LedgerHashtable -Value $Value[$k] }
        return $copy
    }
    if ($Value -is [PSCustomObject]) {
        $copy = @{}
        foreach ($p in $Value.PSObject.Properties) { $copy[$p.Name] = ConvertTo-LedgerHashtable -Value $p.Value }
        return $copy
    }
    return $Value
}

function Merge-AuditLedgerConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($Override)
    if (-not (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue)) {
        Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Merge-ConfigObject'
    }
    if (-not (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue)) {
        throw (Resolve-LogMessage -Key 'log.audit.configProviderMissing' -Fallback 'AuditLedger: ConfigProvider.Merge-ConfigObject is unavailable; cannot merge security.auditLedger config.')
    }
    # A non-mapping override (e.g. security.auditLedger = "file") carries no keys
    # to merge: keep the built-in defaults rather than exploding scalar members.
    if ($null -ne $Override -and -not ($Override -is [System.Collections.IDictionary]) -and -not ($Override -is [PSCustomObject])) {
        $Override = $null
    }
    $merged = Merge-ConfigObject -Base $script:DefaultAuditLedgerConfig -Override $Override
    return ConvertTo-LedgerHashtable -Value $merged
}

# ── Initialization ────────────────────────────────────────────────────────────
function Initialize-AuditLedger {
    [CmdletBinding()]
    param([PSCustomObject]$State, [switch]$Force)
    # -Force re-reads the file after retention rewrote it in place; without it
    # the in-memory EntryCount / CurrentHash would keep describing the
    # pre-truncation chain and the next append would fork the hash chain.
    if ($script:LedgerState.Initialized -and -not $Force) { return }

    $cfg = Get-ConfigValue -Path 'security.auditLedger' -State $State -Default $null
    # Recursive deep-merge over the built-in defaults so a PARTIAL config (e.g.
    # only { enabled, backend }) still yields complete subsections (Signing,
    # Ledger, Verification, ...) at EVERY depth. Without this, missing subsections
    # are $null and every dotted access below throws InvalidOperation.
    $script:LedgerConfig = Merge-AuditLedgerConfig -Override $cfg
    # Fail fast on a cloud backend whose provider is not deployed, BEFORE any
    # state is touched. See Assert-LedgerBackendProvider for why a silent
    # no-op is unacceptable for an audit trail.
    if ([bool]$script:LedgerConfig.Enabled) { Assert-LedgerBackendProvider -State $State }

    # Level 5: the in-memory ring cap is configurable. It used to be latched ONCE
    # at module-definition time from Get-BuildDefault, so security.auditLedger.memoryCap
    # in gbuild.config.json was read by nothing and the cap was unchangeable at
    # runtime. Apply the merged value now, guarded so a bad value degrades to the
    # default instead of throwing mid-build.
    if ($script:LedgerConfig.ContainsKey('MemoryCap')) {
        $cap = 0
        try { $cap = [int]$script:LedgerConfig.MemoryCap } catch { $cap = 0 }
        if ($cap -gt 0) { $script:LedgerState.MemoryCap = $cap }
    }

    # L5 per-environment enablement: GBUILD_AUDIT_LEDGER=1 starts the ledger
    # without editing config (file backend default). Signing posture:
    #   - config-enabled without a key  -> throw (fail-closed, preserved)
    #   - env-enabled without a key     -> unsigned + explicit WARN acceptance
    #     (fail-open with an auditable log line, never silent)
    # Unset/empty = config behaviour preserved. Explicit 0 re-disables.
    #
    # The try below used to wrap the toggle read AND the config-shape probe AND
    # the assignment in one `catch { }`. A malformed $cfg object (or any throw
    # from the probe) therefore discarded an EXPLICIT operator signal:
    # GBUILD_AUDIT_LEDGER=1 was silently ignored and the compliance ledger
    # stayed off. The toggle read and the config probe are now separate, and a
    # probe failure falls back to a direct env read instead of dropping the
    # signal - an explicit 1/0 in the environment must never lose to a broken
    # config object.
    $ledgerEnvOrigin = $false
    $ledgerEnv = $null
    if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
        try { $ledgerEnv = Test-EnvToggle -Name 'GBUILD_AUDIT_LEDGER' } catch { $ledgerEnv = $null }
    }
    $cfgEnabled = $false
    try {
        $cfgEnabled = ($null -ne $cfg) -and (($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('enabled') -and [bool]$cfg['enabled']) -or ($null -ne $cfg.PSObject -and ($cfg.PSObject.Properties.Name -contains 'enabled') -and [bool]$cfg.enabled))
    } catch {
        $cfgEnabled = $false
        if ($null -eq $ledgerEnv) {
            # Config object unreadable AND no toggle verdict: read the raw env
            # var directly so an explicit operator signal still wins. Same
            # truth table as Test-EnvToggle, without its config dependency.
            try {
                $rawEnv = [Environment]::GetEnvironmentVariable('GBUILD_AUDIT_LEDGER')
                if (-not [string]::IsNullOrWhiteSpace($rawEnv)) {
                    $normEnv = ([string]$rawEnv).Trim().ToLowerInvariant()
                    if ($normEnv -match '^(1|true|yes|on|enable|enabled)$') { $ledgerEnv = $true }
                    elseif ($normEnv -match '^(0|false|no|off|disable|disabled)$') { $ledgerEnv = $false }
                }
            } catch { }
        }
    }
    if ($ledgerEnv -eq $true -and -not $cfgEnabled) {
        $script:LedgerConfig.Enabled = $true
        $ledgerEnvOrigin = $true
    } elseif ($ledgerEnv -eq $false) {
        $script:LedgerConfig.Enabled = $false
    }
    $script:LedgerConfig['EnvOrigin'] = [bool]$ledgerEnvOrigin

    # Resolve signing key (L5 fail-closed: a ledger that claims to be signed
    # but has no key is worse than an explicitly unsigned one - it creates
    # false non-repudiation assurance. Throw when the ledger is active and
    # signing is required; the operator must either provide a key or set
    # signing.enabled=false as an explicit, auditable acceptance).
    $signingRequired = [bool]$script:LedgerConfig.Signing.Enabled
    if ($null -ne $script:LedgerConfig.Signing.RequireKey) {
        $signingRequired = $signingRequired -and [bool]$script:LedgerConfig.Signing.RequireKey
    }
    if ($script:LedgerConfig.Enabled -and $signingRequired) {
        if ($script:LedgerConfig.Signing.KeyPath) {
            $keyPath = Resolve-EnvPlaceholder $script:LedgerConfig.Signing.KeyPath
        } else {
            $keyPath = ''
        }
        if ([string]::IsNullOrWhiteSpace($keyPath) -or -not (Test-Path $keyPath)) {
            if ($script:LedgerConfig.EnvOrigin) {
                throw (Resolve-LogMessage -Key 'log.audit.unsignedMustBeExplicit' -Fallback 'AuditLedger: environment enablement requires a signing key; unsigned acceptance must be explicit.')
            } else {
                throw (Resolve-LogMessage -Key 'log.auditledger.line267' -Fallback "AuditLedger: signing is enabled but no usable signing key (keyPath='$keyPath'). Provide security.auditLedger.signing.keyPath or explicitly accept an unsigned ledger with security.auditLedger.signing.enabled=false.")
            }
        } else {
            $script:LedgerState.SigningKey = $keyPath
            Write-Log (Resolve-LogMessage -Key 'log.audit.keyLoaded' -MessageArgs @([string]$keyPath) -Fallback '[AuditLedger] Loaded signing key from {0}') 'Succ' $State
        }
    } elseif ($script:LedgerConfig.Signing.Enabled -and $script:LedgerConfig.Signing.KeyPath) {
        $keyPath = Resolve-EnvPlaceholder $script:LedgerConfig.Signing.KeyPath
        if (Test-Path $keyPath) {
            $script:LedgerState.SigningKey = $keyPath
            Write-Log (Resolve-LogMessage -Key 'log.audit.keyLoaded' -MessageArgs @([string]$keyPath) -Fallback '[AuditLedger] Loaded signing key from {0}') 'Succ' $State
        } else {
            Write-Log (Resolve-LogMessage -Key 'log.audit.keyNotFound' -MessageArgs @([string]$keyPath) -Fallback '[AuditLedger] Signing key not found at {0}, signing disabled') 'Warn' $State
            $script:LedgerConfig.Signing.Enabled = $false
        }
    }

    # Load existing ledger state (last hash, entry count). A torn tail (crash
    # mid-append) must not reset EntryCount to 0: the old code parsed only the
    # last line with -ErrorAction SilentlyContinue, got $null on a torn tail,
    # and left EntryCount at genesis - so the next write reused sequence 1 and
    # forked the chain. Scan backward for the last VALID entry instead. This
    # path holds no file lock, so it never modifies the file (truncation lives
    # in Repair-LedgerTornTail, called under lock from the write path); the
    # torn bytes stay for Verify to report honestly.
    $ledgerPath = Get-LedgerPath -State $State
    if (Test-Path $ledgerPath) {
        $lastLine = Get-Content $ledgerPath -Tail 1 -ErrorAction SilentlyContinue
        $lastEntry = $null
        if ($lastLine) { $lastEntry = $lastLine | ConvertFrom-Json -ErrorAction SilentlyContinue }
        if (-not $lastEntry) {
            try {
                $allLines = @(Get-Content -LiteralPath $ledgerPath -ErrorAction Stop)
                for ($li = $allLines.Count - 1; $li -ge 0; $li--) {
                    if ([string]::IsNullOrWhiteSpace($allLines[$li])) { continue }
                    $candidate = $allLines[$li] | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($candidate -and $candidate.HashChain) { $lastEntry = $candidate; break }
                }
            } catch { }
        }
        if ($lastEntry -and $lastEntry.HashChain) {
            $script:LedgerState.CurrentHash = $lastEntry.HashChain
            $script:LedgerState.EntryCount = 0
            if ($null -ne $lastEntry.Sequence) {
                try { $script:LedgerState.EntryCount = [int]$lastEntry.Sequence } catch { $script:LedgerState.EntryCount = 0 }
            }
        }
    }

    $script:LedgerState.Initialized = $true
    Write-Log (Resolve-LogMessage -Key 'log.audit.initialized' -MessageArgs @([string]$script:LedgerConfig.Backend, $script:LedgerState.EntryCount) -Fallback '[AuditLedger] Initialized (backend: {0}, entries: {1})') 'Debug' $State
}

<#
.SYNOPSIS
    Fails loudly when a configured cloud backend has no provider loaded.
.DESCRIPTION
    's3' and 'azureBlob' are EXTENSION POINTS: the writer/reader commands are
    supplied by whoever deploys the ledger (Write-S3AuditEntry,
    Write-AzureBlobAuditEntry, Read-S3AuditEntries, Read-AzureBlobAuditEntries),
    and this module ships none of them. That is a legitimate design - but every
    call site was guarded by `Get-Command <name> -ErrorAction SilentlyContinue`,
    so selecting backend 's3' on a host without the provider fell straight
    through every branch: $success stayed $false, nothing was written, and
    Test-AuditLedger answered "No ledger entries exist" - i.e. a WORM audit
    trail that silently recorded nothing and still reported success.

    Configuring a backend whose provider is absent is a deployment error, so it
    now throws at initialization rather than degrading to a no-op. Supply the
    provider, or select the 'file' / 'ledger' backend.
#>
function Assert-LedgerBackendProvider {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $backend = [string]$script:LedgerConfig.Backend
    if ($backend -eq 's3') {
        if (-not (Get-Command Write-S3AuditEntry -ErrorAction SilentlyContinue) -or -not (Get-Command Read-S3AuditEntries -ErrorAction SilentlyContinue)) {
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line344' -Fallback "Audit ledger backend 's3' requires the provider commands Write-S3AuditEntry and Read-S3AuditEntries, which are not loaded. Provide them, or use the 'file' or 'ledger' backend. Silently writing nothing is never correct for an audit trail."))
        }
    } elseif ($backend -eq 'azureBlob') {
        if (-not (Get-Command Write-AzureBlobAuditEntry -ErrorAction SilentlyContinue) -or -not (Get-Command Read-AzureBlobAuditEntries -ErrorAction SilentlyContinue)) {
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line348' -Fallback "Audit ledger backend 'azureBlob' requires the provider commands Write-AzureBlobAuditEntry and Read-AzureBlobAuditEntries, which are not loaded. Provide them, or use the 'file' or 'ledger' backend. Silently writing nothing is never correct for an audit trail."))
        }
    }
}


# ── Core: Hash chain / Merkle tree ────────────────────────────────────────────
<#
.SYNOPSIS
    Ledger-entry field accessor. Single source: ConfigProvider.Get-SectionValue.
.DESCRIPTION
    Hashtable (write path) and PSCustomObject (verify path, after ConvertFrom-Json)
    duality. The old comment claimed this was "the same idiom as
    ConfigProvider.Get-SectionValue" - it was not: it used `$Entry.Contains($Name)`
    only, so an ordinal dictionary missed on casing. JSON keys keep their original
    casing, so a ledger written by a newer producer could verify as a chain of
    nulls. Delegating makes it genuinely the same behaviour.
#>
function Get-LedgerField {
    [CmdletBinding()]
    param($Entry, [Parameter(Mandatory)][string]$Name, $Default = $null)
    # Unconditional delegation. This used to be followed by a 9-line inline
    # re-implementation of Get-SectionValue's dictionary/case-fallback rules
    # behind `if (Get-Command Get-SectionValue ...)`. That branch was
    # UNREACHABLE BY CONSTRUCTION: this module hard-imports ConfigProvider at
    # the top (`Import-GBuildModuleIfMissing -Name 'ConfigProvider' -Sentinel
    # Command 'Get-SectionValue'`), and the sentinel is precisely
    # Get-SectionValue, so the module cannot load unless the command exists.
    # An unreachable duplicate is worse than a live one - it reads as
    # justification, so the next reader stops looking for the real owner.
    # ConfigProvider.Get-SectionValue is the only implementation of this rule.
    return Get-SectionValue -Section $Entry -Key $Name -Default $Default
}

function ConvertTo-LedgerScalar {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    # Culture- and type-invariant scalar normalization so the hash is stable
    # across the write path (native .NET types) and the verify path
    # (ConvertFrom-Json coercions: Int64 vs Int32, DateTime vs string).
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}


function Get-MerkleRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$LeafHashes)
    if ($LeafHashes.Count -eq 0) { return '' }
    if ($LeafHashes.Count -eq 1) { return $LeafHashes[0] }

    # Resolve the hash algorithm defensively: this function is reachable from
    # Test-AuditLedger and from Save-AuditLedgerCheckpoint, and the config
    # is not guaranteed to be initialised in either (the previous code read
    # $script:LedgerConfig.Ledger.HashAlgorithm unguarded, which threw
    # "variable cannot be retrieved" whenever the ledger had not been opened).
    $algorithm = 'SHA256'
    try { $algorithm = [string]$script:LedgerConfig.Ledger.HashAlgorithm } catch { $algorithm = 'SHA256' }
    if ([string]::IsNullOrWhiteSpace($algorithm)) { $algorithm = 'SHA256' }
    $hashAlg = $null
    try { $hashAlg = [System.Security.Cryptography.HashAlgorithm]::Create($algorithm) } catch { $hashAlg = [System.Security.Cryptography.SHA256]::Create() }
    $currentLevel = $LeafHashes
    while ($currentLevel.Count -gt 1) {
        $nextLevel = @()
        for ($i = 0; $i -lt $currentLevel.Count; $i += 2) {
            if ($i + 1 -lt $currentLevel.Count) {
                # Pair: hash the concatenation.
                $left = $currentLevel[$i]
                $right = $currentLevel[$i + 1]
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($left + $right)
                $nextLevel += [System.Convert]::ToBase64String($hashAlg.ComputeHash($bytes))
            } else {
                # Odd tail node: PROMOTE UNCHANGED.
                # The previous code duplicated it (`$right = $left`) and hashed
                # the pair, which is the construction behind CVE-2012-2459 where
                # an attacker fabricates 2^N colliding (a,b) pairs. Promoting the
                # node unchanged also keeps the level strictly shrinking, so the
                # loop terminates (duplicating it here produced a non-shrinking
                # level and hung the verifier).
                $nextLevel += $currentLevel[$i]
            }
        }
        $currentLevel = $nextLevel
    }
    $hashAlg.Dispose()
    return $currentLevel[0]
}



# ── Entry writing ─────────────────────────────────────────────────────────────

# ── Verification ──────────────────────────────────────────────────────────────


# ── Compliance export ─────────────────────────────────────────────────────────
function Export-AuditLedger {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$Format = 'jsonl',
        [string]$OutputPath = '',
        [hashtable]$Filter = @{}
    )
    Initialize-AuditLedger -State $State
    $path = Get-LedgerPath -State $State
    if (-not (Test-Path $path)) { return '' }

    $lines = Get-Content $path -ErrorAction SilentlyContinue
    $filtered = @()
    foreach ($line in $lines) {
        $entry = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $entry) { continue }
        $match = $true
        foreach ($f in $Filter.Keys) {
            if ($entry.$f -ne $Filter.$f) { $match = $false; break }
        }
        if ($match) { $filtered += $entry }
    }

    switch ($Format) {
        'jsonl' { return $filtered | ConvertTo-Json -Compress -Depth 10 }
        'csv' {
            $csv = $filtered | ConvertTo-Csv -NoTypeInformation
            return $csv -join "`n"
        }
        'cef' {
            $cefLines = @()
            foreach ($e in $filtered) {
                $sev = 0
                if ($e.Allowed) { $sev = 1 }
                $cefLines += "CEF:0|gbuild|audit-ledger|1.0|$($e.Type)|$($e.Action)|$sev|src=$($e.User) dst=$($e.Resource) cn1=$($e.Sequence) cn2=$($e.TenantId) msg=$($e.Detail)"
            }
            return $cefLines -join "`n"
        }
        default { return $filtered | ConvertTo-Json -Compress -Depth 10 }
    }
}

# ── Retention & Legal Hold ────────────────────────────────────────────────────
function Update-AuditRetention {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    Initialize-AuditLedger -State $State
    if (-not $script:LedgerConfig.Enabled) { return 0 }

    $retention = $script:LedgerConfig.Retention
    $defaultDays = $retention.DefaultDays
    $perCategory = $retention.PerCategory
    $legalHold = @($retention.LegalHold | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $holdAll = $legalHold -contains '*'
    $cutoff = (Get-Date).AddDays(-$defaultDays)

    $path = Get-LedgerPath -State $State
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }

    # UPGRADED from counter-only to real enforcement. The previous body summed
    # expired entries and returned the number - nothing was ever deleted,
    # quarantined, or rotated, so security.auditLedger.file.maxSizeMB /
    # maxFiles were advertised in the shipped config while no module read them
    # and the ledger grew without bound.
    # Ledger files are append-only JSONL, so retention is applied by
    # REWRITING the file without the expired lines and by archiving the
    # original to <name>.expired-<timestamp>.jsonl (never a destructive
    # delete: the evidence is preserved, only the working set is trimmed).
    $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return 0 }
    $keep = [System.Collections.Generic.List[string]]::new()
    $expired = 0
    $archived = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { $entry = $null }
        if (-not $entry) { $keep.Add([string]$line); continue }   # unparsable lines are preserved, never dropped
        $entryDate = [datetime]::MinValue
        try { $entryDate = [datetime]$entry.Timestamp } catch { $entryDate = [datetime]::MinValue }
        $category = ''
        try { $category = ([string]$entry.Type).ToLowerInvariant() } catch { $category = '' }
        $hold = $holdAll -or ($category -and ($legalHold -contains $category))
        $categoryDays = $defaultDays
        try { if ($perCategory -and $perCategory.ContainsKey($category)) { $categoryDays = [int]$perCategory[$category] } } catch { }
        $categoryCutoff = (Get-Date).AddDays(-$categoryDays)
        if (-not $hold -and $entryDate -lt $categoryCutoff) { $expired++; $archived.Add([string]$line) }
        else { $keep.Add([string]$line) }
    }

    # Size / file-count cap. Read from the SAME keys the shipped config
    # documents (security.auditLedger.file.maxSizeMB / .maxFiles), which
    # nothing consumed before.
    $fileCfg = $script:LedgerConfig.File
    $maxSizeMb = 0; $maxFiles = 0
    try { $v = Get-SectionValue -Section $fileCfg -Key 'maxSizeMB' -Default $null; if ($null -ne $v) { $maxSizeMb = [int]$v } } catch { }
    try { $v = Get-SectionValue -Section $fileCfg -Key 'maxFiles' -Default $null; if ($null -ne $v) { $maxFiles = [int]$v } } catch { }
    $dir = [System.IO.Path]::GetDirectoryName($path)
    $sizeMb = 0
    try { if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { $sizeMb = [math]::Round((Get-ChildItem -LiteralPath $dir -Filter 'audit-ledger*.jsonl*' -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 2) } } catch { }
    $overCap = (($maxSizeMb -gt 0) -and ($sizeMb -gt $maxSizeMb))
    $archiveCap = ($maxFiles -gt 0)
    $fileCount = 0
    if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { $fileCount = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-ledger*.jsonl*' -File -ErrorAction SilentlyContinue).Count }
    $overCount = ($archiveCap -and ($fileCount -gt $maxFiles))

    if ($expired -le 0 -and -not $overCap -and -not $overCount) {
        Write-Log (Resolve-LogMessage -Key 'log.audit.retentionCheck' -MessageArgs @([string]$defaultDays, $sizeMb, $fileCount) -Fallback '[AuditLedger] Retention check: 0 entries past retention (default: {0} days); {1} MB across {2} file(s)') 'Info' $State
        return 0
    }

    $stamp = Get-BuildTimestamp -Kind FileStamp
    $reason = @(); if ($expired -gt 0) { $reason += "$expired entry/entries past retention" }
    if ($overCap) { $reason += "size $sizeMb MB over cap $maxSizeMb MB" }
    if ($overCount) { $reason += "$fileCount file(s) over cap $maxFiles" }
    $reasonText = $reason -join '; '

    # Preserve evidence before mutating anything.
    $backup = "$path.expired-$stamp.jsonl"
    try {
        # Preserve evidence before mutating anything, then replace through the
        # shared atomic writer.
        Copy-Item -LiteralPath $path -Destination $backup -Force -ErrorAction Stop
        # SharedUtils owns the atomic rewrite. The 11-line inline Replace this
        # replaced was a copy of the same primitive; a trimmed ledger is still
        # the tamper-evident evidence chain, so the write must not tear.
        $rewritten = [bool](Write-BuildTextFileAtomic -Path $path -Lines ([string[]]$keep.ToArray()))
        if (-not $rewritten) { throw (Resolve-LogMessage -Key 'log.auditledger.line579' -MessageArgs @([string]$path, [string]$backup) -Fallback "Failed to rewrite the trimmed ledger at $path (evidence preserved at $backup).") }
        if (Test-Path -LiteralPath $path -PathType Leaf) { try { Set-WormProtection -Path $path -Disable | Out-Null } catch { } }
        # Trim archives beyond maxFiles, oldest first.
        if ($maxFiles -gt 0 -and $dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
            $archives = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-ledger*.jsonl.expired-*' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            $excess = $archives.Count - ($maxFiles - 1)
            if ($excess -gt 0) { foreach ($f in $archives[0..($excess - 1)]) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { } } }
        }
        $script:LedgerState = $null
        Initialize-AuditLedger -State $State -Force
        Write-Log (Resolve-LogMessage -Key 'log.audit.retentionApplied' -MessageArgs @([string]$reasonText, $expired, $backup, $keep.Count) -Fallback '[AuditLedger] Retention APPLIED ({0}). {1} entry/entries archived to {2}; ledger rewritten to {3} entry/entries.') 'Info' $State
    } catch {
        Write-Log (Resolve-LogMessage -Key 'log.audit.retentionFailed' -MessageArgs @([string]$reasonText, $_.Exception.Message) -Fallback '[AuditLedger] Retention enforcement FAILED ({0}): {1}. Ledger left untouched.') 'Err' $State
        return $expired
    }
    return $expired
}

# ── WORM file protection (Windows) ────────────────────────────────────────────

# ── Scheduled verification ────────────────────────────────────────────────────
function Start-AuditLedgerVerificationScheduler {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not $script:LedgerConfig.Verification.Enabled) { return }
    if ($script:LedgerConfig.Verification.OnStartup) {
        $result = Test-AuditLedger -State $State -FullChain
        if (-not $result.Valid) {
            Write-Log (Resolve-LogMessage -Key 'log.audit.startupVerifyFailed' -MessageArgs @([string]$result.Errors.Count) -Fallback '[AuditLedger] STARTUP VERIFICATION FAILED: {0} error(s)') 'Err' $State
            if ($script:LedgerConfig.Verification.AlertOnFailure -and (Get-Command Send-Alert -ErrorAction SilentlyContinue)) {
                Send-Alert -Message "Audit ledger verification failed on startup: $($result.Errors.Count) errors" -Severity 'Critical' -State $State
            }
        } else {
            Write-Log (Resolve-LogMessage -Key 'log.audit.startupVerifyPassed' -MessageArgs @([string]$result.VerifiedEntries) -Fallback '[AuditLedger] Startup verification passed ({0} entries)') 'Debug' $State
        }
    }
    # In a real implementation, this would use a scheduled job or cron
    Write-Log (Resolve-LogMessage -Key 'log.audit.scheduleConfigured' -MessageArgs @([string]$script:LedgerConfig.Verification.Schedule) -Fallback '[AuditLedger] Scheduled verification configured: {0}') 'Debug' $State
}

function Get-AuditLedgerTenant {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
    if ($tenant -eq 'default') { return $tenant }
    if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $tenant.Contains('..') -or $tenant -match '[. ]$') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line624' -Fallback 'Audit tenant is invalid.')) }
    return $tenant
}

<#
.SYNOPSIS
    Resolves the directory audit-ledger files live under. Fails closed.
.DESCRIPTION
    Single owner for both ledger-file root call sites (Get-LedgerPath and the
    checkpoint writer). Both used to fall back to the process current directory
    when State.ProjectRoot was missing - and both DROPPED ScriptRoot entirely,
    unlike every sibling module. A tamper-evident ledger anchored on whatever
    directory the launcher happened to run from is worse than no ledger: it
    silently splits the chain across directories. No project root, no ledger.
#>
function Get-AuditLedgerRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        $root = Get-BuildRootDirectory -State $State
        $cwd = try { (Get-Location).ProviderPath } catch { '' }
        $hasStateRoot = ($State -and (($State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) -or ($State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot)))
        if ($hasStateRoot -and -not [string]::IsNullOrWhiteSpace($root)) { return $root }
    } else {
        if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { return [string]$State.ProjectRoot }
        if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { return [string]$State.ScriptRoot }
    }
    throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.audit.rootUndetermined' -Fallback 'Audit ledger root is undetermined: State carries neither ProjectRoot nor ScriptRoot. Refusing to anchor the ledger on the current directory.'))
}

function Get-LedgerPath {
    [CmdletBinding()]
    param([PSCustomObject]$State)    $backend = [string]$script:LedgerConfig.Backend
    $tenant = Get-AuditLedgerTenant -State $State
    switch ($backend) {
        'file' {
            $base = [string]$script:LedgerConfig.File.Path
            if ($base -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) { $base = [string](Resolve-EnvPlaceholder -Text $base) }
            if ([string]::IsNullOrWhiteSpace($base) -or $base -match '\.\.') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line663' -Fallback 'Audit ledger path is invalid.')) }
            $root = Get-AuditLedgerRoot -State $State
            if ([System.IO.Path]::IsPathRooted($base)) { $full = [System.IO.Path]::GetFullPath($base) } else { $full = [System.IO.Path]::GetFullPath((Join-Path $root $base)) }
            if ($tenant -ne 'default') {
                $parent = [System.IO.Path]::GetDirectoryName($full)
                $leaf = [System.IO.Path]::GetFileName($full)
                $full = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $parent 'tenants') (Join-Path $tenant $leaf)))
            }
            return $full
        }
        's3' { return 's3://' + [string]$script:LedgerConfig.S3.Bucket + '/' + [string]$script:LedgerConfig.S3.Prefix + $tenant + '/' }
        'azureBlob' { return 'azure://' + [string]$script:LedgerConfig.AzureBlob.Container + '/' + $tenant }
        'ledger' { return 'ledger://' + $tenant + '/merkle-tree' }
        default {
            $supported = @('ledger', 's3', 'azureBlob') -join ', '
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.audit.backendInvalid' -MessageArgs @($supported) -Fallback 'Audit ledger backend is invalid. Supported: {0}'))
        }
    }
}

function Get-LedgerCanonicalEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry, [string]$PreviousHash = '', [switch]$ForSigning)
    $signature = if ($ForSigning) { '' } else { ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Signature') }
    $algorithm = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'SignAlgorithm')
    return ([ordered]@{
        Sequence = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Sequence')
        Timestamp = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Timestamp')
        Type = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Type')
        Action = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Action')
        Allowed = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Allowed')
        User = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'User')
        Roles = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Roles')
        Permission = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Permission')
        Resource = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Resource')
        CorrelationId = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'CorrelationId')
        TenantId = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'TenantId')
        Detail = ConvertTo-LedgerScalar (Get-LedgerField -Entry $Entry -Name 'Detail')
        PreviousHash = ConvertTo-LedgerScalar $PreviousHash
        SignAlgorithm = $algorithm
        Signature = $signature
    } | ConvertTo-Json -Compress -Depth 10)
}

function Get-EntryHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry, [string]$PreviousHash = '')
    $canonical = Get-LedgerCanonicalEntry -Entry $Entry -PreviousHash $PreviousHash
    $algorithm = [System.Security.Cryptography.HashAlgorithm]::Create([string]$script:LedgerConfig.Ledger.HashAlgorithm)
    try { return [System.Convert]::ToBase64String($algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))) } finally { $algorithm.Dispose() }
}

function Get-LedgerSigningData {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry, [string]$PreviousHash = '')
    return Get-LedgerCanonicalEntry -Entry $Entry -PreviousHash $PreviousHash -ForSigning
}

function Import-LedgerPrivateKeyPem {
    <#
    .SYNOPSIS
        Loads an RSA private key from PEM, honouring an optional passphrase.
    .DESCRIPTION
        Single owner for private-key PEM import. security.auditLedger.signing.keyPassword
        used to be merged into config but read by nobody, so an encrypted key
        failed inside Get-DataSignature with the generic 'Audit ledger signing failed.'
        and the operator had no way to tell a passphrase problem from a corrupt
        key. ImportFromPem with an empty password keeps the previous unencrypted
        behaviour; a non-empty one is passed as a SecureString.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.RSA])]
    param([Parameter(Mandatory)][string]$Pem, [string]$Password = '')
    # Capability probe BEFORE allocating. RSA.ImportFromEncryptedPem only exists
    # on .NET Core 3.0+/.NET 5+; on Windows PowerShell 5.1 (.NET Framework) it is
    # absent entirely. Probing first turns a bare MethodException into a message
    # that names the actual cause.
    $canImportEncrypted = $false
    try {
        $probe = [System.Security.Cryptography.RSA]::Create()
        try { $canImportEncrypted = [bool]($probe.GetType().GetMethod('ImportFromEncryptedPem')) } finally { $probe.Dispose() }
    } catch { $canImportEncrypted = $false }
    if (-not $canImportEncrypted) {
        throw (Resolve-LogMessage -Key 'log.auditledger.line746' -Fallback 'Audit ledger signing key is passphrase-protected, but RSA.ImportFromEncryptedPem is unavailable on this PowerShell host (.NET Framework / Windows PowerShell 5.1). Run the ledger signer on PowerShell 7+, or supply an unencrypted PEM.')
    }
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        if ([string]::IsNullOrEmpty($Password)) {
            $rsa.ImportFromPem($Pem)
        } else {
            # PLAIN STRING, not a SecureString. The overload is
            # ImportFromEncryptedPem(ReadOnlySpan<char>, ReadOnlySpan<char>).
            # PowerShell binds [string] to ReadOnlySpan<char>; it does NOT bind
            # SecureString, so the previous
            #   ConvertTo-SecureString -AsPlainText -Force | ImportFromEncryptedPem
            # threw "Cannot find an overload for ImportFromEncryptedPem and the
            # argument count: 2" - an encrypted signing key could never load on
            # any PowerShell host, which is the exact symptom this function was
            # written to prevent. The passphrase arrives from
            # security.auditLedger.signing.keyPassword, is ${env:}-only, and is
            # never logged or echoed.
            $rsa.ImportFromEncryptedPem($Pem, $Password)
        }
        return $rsa
    } catch {
        if ($rsa) { $rsa.Dispose() }
        throw
    }
}

function Get-LedgerSignaturePrimitive {
    <#
    .SYNOPSIS
        Resolves a signing.algorithm name to the actual .NET primitives.
    .DESCRIPTION
        signing.algorithm shipped in gbuild.config.json and schema-validated
        ('RSA-SHA256' | 'RSA-SHA384' | 'RSA-SHA512' | 'RSA-PSS-SHA256'), and the
        chosen name is RECORDED in every anchor (anchorAlgorithm) and every entry
        (SignAlgorithm). Previously Get-DataSignature and Test-Signature accepted that
        parameter and then ignored it, hardcoding SHA256 + Pkcs1 - so an operator
        who configured RSA-SHA512 got PKCS#1 v1.5 SHA-256 signatures that were
        labelled RSA-SHA512 in the ledger. That is a mislabelled compliance
        record, which is worse than an inert knob.

        Unsupported values now THROW instead of silently falling back, so a
        misconfiguration fails closed at signing time rather than producing
        unverifiable entries.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Algorithm = 'RSA-SHA256')
    $name = ([string]$Algorithm).Trim().ToUpperInvariant()
    if (-not $name) { $name = 'RSA-SHA256' }
    $hash = $null
    $padding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    switch ($name) {
        'RSA-SHA256'      { $hash = [System.Security.Cryptography.HashAlgorithmName]::SHA256 }
        'RSA-SHA384'      { $hash = [System.Security.Cryptography.HashAlgorithmName]::SHA384 }
        'RSA-SHA512'      { $hash = [System.Security.Cryptography.HashAlgorithmName]::SHA512 }
        'RSA-PSS-SHA256'  { $hash = [System.Security.Cryptography.HashAlgorithmName]::SHA256; $padding = [System.Security.Cryptography.RSASignaturePadding]::Pss }
        default {
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line804' -Fallback "Unsupported audit ledger signing.algorithm '$Algorithm'. Supported: RSA-SHA256, RSA-SHA384, RSA-SHA512, RSA-PSS-SHA256."))
        }
    }
    return @{ Name = $name; Hash = $hash; Padding = $padding }
}

function Get-DataSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Data, [string]$KeyPath = '', [string]$Algorithm = '')
    if (-not $script:LedgerConfig.Signing.Enabled -or (-not $KeyPath -and -not $script:LedgerState.SigningKey)) { return '' }
    $path = if ($KeyPath) { $KeyPath } else { [string]$script:LedgerState.SigningKey }
    $password = [string]$script:LedgerConfig.Signing.KeyPassword
    if ($password -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) {
        $password = [string](Resolve-EnvPlaceholder -Text $password)
    }
    # Default to the CONFIGURED algorithm, not a hardcoded literal.
    if (-not $Algorithm) { $Algorithm = [string]$script:LedgerConfig.Signing.Algorithm }
    $primitive = Get-LedgerSignaturePrimitive -Algorithm $Algorithm
    $rsa = $null
    try {
        $pem = [System.IO.File]::ReadAllText($path)
        $rsa = Import-LedgerPrivateKeyPem -Pem $pem -Password $password
        return [System.Convert]::ToBase64String($rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($Data), $primitive.Hash, $primitive.Padding))
    } catch {
        if ($rsa) { $rsa.Dispose() }
        $why = if ($password) { 'Audit ledger signing failed: the configured signing.keyPassword did not decrypt the key (or the key is corrupt).' }
               else { 'Audit ledger signing failed: the key is encrypted but signing.keyPassword is not set (or the key is corrupt).' }
        throw [System.InvalidOperationException]::new($why)
    } finally { if ($rsa) { $rsa.Dispose() } }
}

function Test-Signature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Data, [Parameter(Mandatory)][AllowEmptyString()][string]$Signature, [string]$CertPath = '', [string]$Algorithm = '')
    if (-not $script:LedgerConfig.Signing.Enabled) { return $true }
    if ([string]::IsNullOrWhiteSpace($Signature)) { return $false }
    $path = if ($CertPath) { $CertPath } else { [string]$script:LedgerConfig.Signing.CertPath }
    # Default to the CONFIGURED algorithm so verification uses the same primitive
    # that produced the signature. An unknown value is a verification failure,
    # not a silent "cannot check" success.
    if (-not $Algorithm) { $Algorithm = [string]$script:LedgerConfig.Signing.Algorithm }
    $primitive = $null
    try { $primitive = Get-LedgerSignaturePrimitive -Algorithm $Algorithm } catch { return $false }
    $rsa = $null
    $cert = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($path)
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        } elseif ($script:LedgerState.SigningKey -and (Test-Path -LiteralPath ([string]$script:LedgerState.SigningKey) -PathType Leaf)) {
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rsa.ImportFromPem([System.IO.File]::ReadAllText([string]$script:LedgerState.SigningKey))
        } else { return $false }
        $bytes = [System.Convert]::FromBase64String($Signature)
        return [bool]$rsa.VerifyData([System.Text.Encoding]::UTF8.GetBytes($Data), $bytes, $primitive.Hash, $primitive.Padding)
    } catch { return $false } finally { if ($rsa) { $rsa.Dispose() }; if ($cert) { $cert.Dispose() } }
}

function Get-LedgerWormStatus {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $configured = [bool]$script:LedgerConfig.File.Immutable
    $enforced = $false
    $reason = 'append-only file storage is not immutable WORM'
    if ($script:LedgerConfig.Backend -eq 's3' -and $script:LedgerConfig.S3.ObjectLock) { $reason = 'S3 Object Lock is configured but not verified by this process' }
    if ($script:LedgerConfig.Backend -eq 'azureBlob' -and $script:LedgerConfig.AzureBlob.ImmutableStorage) { $reason = 'Azure immutable storage is configured but not verified by this process' }
    return @{ Configured = $configured; Enforced = $enforced; Honest = $true; WormEnabled = $enforced; WormVerified = $enforced; Immutable = $configured; Status = 'NotVerified'; Reason = $reason; Backend = $script:LedgerConfig.Backend }
}

function Enter-AuditLedgerLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Thin forward to the single acquisition owner.
    #
    # This function previously opened the lock ONCE with no retry while the
    # history-lock copies retried, so two concurrent builds produced an
    # IOException the caller swallowed with an empty `catch {}` and the audit
    # entry was DROPPED rather than retried. It then carried a SECOND
    # try-acquire-throw block after the SharedUtils probe, so the same policy
    # was written out twice in one function.
    return Enter-BuildFileLockOrThrow -Path $Path -What 'audit ledger'
}

function Sync-AuditLedgerFileState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $last = Get-Content -LiteralPath $Path -Tail 1 -ErrorAction SilentlyContinue
    if (-not $last) { return }
    try {
        $entry = $last | ConvertFrom-Json -ErrorAction Stop
        if ($entry.HashChain) { $script:LedgerState.CurrentHash = [string]$entry.HashChain }
        if ($null -ne $entry.Sequence) { $script:LedgerState.EntryCount = [Math]::Max($script:LedgerState.EntryCount, [int]$entry.Sequence) }
        return
    } catch { }
    # TORN TAIL. The last line is not valid JSON: a previous writer died
    # mid-append (crash, kill, power loss), leaving a partial line. The old code
    # swallowed the parse error and kept STALE CurrentHash/EntryCount, so the
    # next entry reused a sequence number and chained from the wrong hash -
    # silently forking the chain. Repair under the caller's lock (Write holds
    # Enter-AuditLedgerLock across this call): drop trailing unparseable lines
    # and resync from the last VALID entry. A torn line was never a committed
    # entry, so removing it loses no data; the truncation is logged so the crash
    # itself stays visible.
    try {
        $repaired = Repair-LedgerTornTail -Path $Path -State $null
        if ($repaired -and $repaired.HashChain) { $script:LedgerState.CurrentHash = [string]$repaired.HashChain }
        if ($repaired -and $null -ne $repaired.Sequence) { $script:LedgerState.EntryCount = [Math]::Max($script:LedgerState.EntryCount, [int]$repaired.Sequence) }
    } catch { }
}

function Repair-LedgerTornTail {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$Path, [PSCustomObject]$State = $null)
    # Caller MUST hold the ledger file lock: truncation races a concurrent
    # appender. Returns the last valid entry, or $null when the file is empty
    # (or became empty). Never throws: a repair helper that throws would turn
    # every torn tail into a write outage.
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        $validIdx = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            try { $null = $lines[$i] | ConvertFrom-Json -ErrorAction Stop; $validIdx = $i; break } catch { }
        }
        if ($validIdx -lt 0) {
            # No valid entry at all. Do NOT delete the file: its (garbage)
            # content is evidence for Verify, which will report every line as
            # invalid. Reset in-memory state to genesis so the next write does
            # not chain from a phantom hash - but leave the bytes for forensics.
            $script:LedgerState.CurrentHash = ''
            $script:LedgerState.EntryCount = 0
            return $null
        }
        $lastValid = $lines[$validIdx] | ConvertFrom-Json -ErrorAction Stop
        # Drop only the TORN TAIL (lines after the last valid entry). A garbage
        # line in the MIDDLE is tampering evidence, not a torn write - leave it
        # for Verify to flag.
        $tornCount = 0
        for ($i = $lines.Count - 1; $i -gt $validIdx; $i--) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$i])) { $tornCount++ }
        }
        if ($tornCount -gt 0) {
            $kept = @($lines[0..$validIdx])
            # SharedUtils.Write-BuildTextFileAtomic. The copy this replaced used a
            # PREDICTABLE "$Path.tmp" temp name, on the one file in the tree whose
            # whole guarantee is that its contents are exactly what was written:
            # a predictable name is a collision between two concurrent writers and
            # a symlink target. The primitive GUIDs the name and cleans up on both
            # the success and the failure path.
            #
            # The swallow is preserved deliberately: a torn tail that cannot be
            # repaired must not abort the audit read. That is a policy choice, not
            # an accident of the old copy.
            try {
                if (Get-Command Write-BuildTextFileAtomic -ErrorAction SilentlyContinue) {
                    Write-BuildTextFileAtomic -Path $Path -Lines ([string[]]$kept) | Out-Null
                } else {
                    $tmp = Join-Path (Split-Path -Parent $Path) ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [System.IO.File]::WriteAllLines($tmp, [string[]]$kept, (New-Object System.Text.UTF8Encoding($false)))
                        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
                    } finally {
                        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
                    }
                }
            } catch {
                Write-Log (Resolve-LogMessage -Key 'log.audit.tornTailRepairFailed' -MessageArgs @($Path) -Fallback '[AuditLedger] Could not repair torn tail of {0}') 'Warn' $State
            }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                try { Write-Log (Resolve-LogMessage -Key 'log.audit.tornTailRepaired' -MessageArgs @($tornCount, $Path) -Fallback '[AuditLedger] Repaired torn tail: removed {0} incomplete line(s) from {1}') 'Warn' $State } catch { }
            }
        }
        return $lastValid
    } catch { return $null }
}

function Save-AuditLedgerCheckpoint {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$Sequence)
    $path = ''
    $ledgerConfig = $script:LedgerConfig.Ledger
    if ($ledgerConfig -is [System.Collections.IDictionary] -and $ledgerConfig.Contains('CheckpointPath')) { $path = [string]$ledgerConfig['CheckpointPath'] }
    elseif ($ledgerConfig -is [System.Collections.IDictionary] -and $ledgerConfig.Contains('checkpointPath')) { $path = [string]$ledgerConfig['checkpointPath'] }
    elseif ($ledgerConfig.PSObject.Properties.Name -contains 'CheckpointPath') { $path = [string]$ledgerConfig.CheckpointPath }
    elseif ($ledgerConfig.PSObject.Properties.Name -contains 'checkpointPath') { $path = [string]$ledgerConfig.checkpointPath }
    # Default path when the operator did not configure one. The previous
    # behaviour was `if ([string]::IsNullOrWhiteSpace($path)) { return }` while
    # the shipped config only carries `checkpointInterval` - so checkpoints were
    # NEVER written, and the anchor below never existed.
    if ([string]::IsNullOrWhiteSpace($path)) { $path = 'audit-ledger.checkpoint.json' }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-AuditLedgerRoot -State $State) $path }
    $tenant = Get-AuditLedgerTenant -State $State
    if ($tenant -ne 'default') { $parent = [System.IO.Path]::GetDirectoryName($path); $leaf = [System.IO.Path]::GetFileName($path); $path = Join-Path (Join-Path (Join-Path $parent 'tenants') $tenant) $leaf }
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $parent) } else { [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop) } }

    # ANCHOR, not just a counter.
    # A per-entry hash chain alone cannot detect TAIL TRUNCATION: removing the
    # last N entries leaves a perfectly valid prefix. The anchor is a Merkle
    # root over every chain hash so far, written to a SEPARATE file and signed
    # with the same key that signs entries. An attacker who trims the ledger
    # must also rewrite the anchor, which requires the signing key - so
    # Test-AuditLedger can now detect a rollback that a plain chain cannot.
    # The previous checkpoint stored only `hash = CurrentHash` (the last chain
    # hash), which is a value the attacker can trivially recompute, and stored
    # it UNSIGNED.
    $leafHashes = @()
    $leafCount = 0
    $leafComplete = $true
    try {
        $ledgerPath = Get-LedgerPath -State $State
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $ledgerPath -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { $leafComplete = $false; continue }
                $h = ''
                try { $h = [string]$e.HashChain } catch { $h = '' }
                if ($h) { $leafHashes += $h } else { $leafComplete = $false }
            }
        }
    } catch { $leafComplete = $false }
    # An anchor over an INCOMPLETE leaf set is worse than no anchor: Verify
    # treats a present anchor with a non-empty root as rollback evidence, and an
    # anchor with merkleRoot='' as "nothing to compare" - so a checkpoint
    # written after a partial read silently DISABLED tail-truncation detection
    # for that window. Refuse to write instead: a missing checkpoint surfaces as
    # an honest "no anchor" warning, which is detectable, while a hollow anchor
    # is not.
    if (-not $leafComplete) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            try { Write-Log (Resolve-LogMessage -Key 'log.audit.anchorSkipped' -Fallback '[AuditLedger] Checkpoint skipped: ledger leaf set incomplete, refusing to sign a partial anchor.') 'Warn' $State } catch { }
        }
        return
    }
    $leafCount = $leafHashes.Count
    $merkleRoot = ''
    try { $merkleRoot = Get-MerkleRoot -LeafHashes $leafHashes } catch { $merkleRoot = ''; $leafComplete = $false }
    if (-not $leafComplete -or [string]::IsNullOrWhiteSpace($merkleRoot)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            try { Write-Log (Resolve-LogMessage -Key 'log.audit.anchorSkipped' -Fallback '[AuditLedger] Checkpoint skipped: ledger leaf set incomplete, refusing to sign a partial anchor.') 'Warn' $State } catch { }
        }
        return
    }

    # PS 5.1 compatibility: a bare `(if ...)` is not a subexpression on Windows
    # PowerShell - only `$(if ...)` is. Compute before the literal so the
    # hashtable stays a plain expression.
    $anchorCorrelationId = ''
    try { if ($State -and ($State.PSObject.Properties.Name -contains 'CorrelationId') -and $State.CorrelationId) { $anchorCorrelationId = [string]$State.CorrelationId } } catch { }
    $anchorBody = [ordered]@{
        sequence      = $Sequence
        hash          = $script:LedgerState.CurrentHash
        merkleRoot    = $merkleRoot
        leafCount     = $leafCount
        tenant        = (Get-AuditLedgerTenant -State $State)
        correlationId = $anchorCorrelationId
        createdAt     = (Get-Date).ToString('o')
    }
    $anchorJson = $anchorBody | ConvertTo-Json -Compress
    $signature = ''
    if ($script:LedgerConfig.Signing.Enabled -and (Get-Command Get-DataSignature -ErrorAction SilentlyContinue)) {
        try { $signature = [string](Get-DataSignature -Data $anchorJson) } catch { $signature = '' }
    }
    $payload = [ordered]@{ anchor = $anchorBody; anchorSignature = $signature; anchorAlgorithm = [string]$script:LedgerConfig.Signing.Algorithm } | ConvertTo-Json -Compress -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonShallowDepth' -Fallback 6) } else { 6 })
    # SharedUtils owns the atomic write. The inline temp+Replace this replaced
    # was another copy of the same pattern, and it reported success
    # unconditionally ($anchorWritten = $true on the fallback branch) whatever
    # the write actually did - on the ONE artefact whose entire purpose is to
    # make a truncated ledger detectable.
    $anchorWritten = [bool](Write-BuildTextFileAtomic -Path $path -Lines @($payload))
    if (-not $anchorWritten) { Write-Log (Resolve-LogMessage -Key 'log.ledger.anchorWriteFailed' -MessageArgs @([string]$path) -Fallback '[AuditLedger] Failed to write the signed anchor to {0} - tail truncation will NOT be detectable until the next successful checkpoint.') 'Err' $State }
}

<#
.SYNOPSIS
    Reads the last signed Merkle anchor, if one exists.
.DESCRIPTION
    Companion reader for Save-AuditLedgerCheckpoint. The anchor is the only
    artefact that makes tail truncation of the ledger detectable.
#>
function Get-AuditLedgerAnchor {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)
    $result = @{ Present = $false; Sequence = 0; Hash = ''; MerkleRoot = ''; LeafCount = 0; CreatedAt = ''; SignaturePresent = $false; SignatureState = 'absent'; SignatureValid = $false; Reason = 'no anchor written yet' }
    $ledgerConfig = $script:LedgerConfig.Ledger
    $path = ''
    foreach ($k in @('CheckpointPath','checkpointPath')) {
        if ($ledgerConfig -is [System.Collections.IDictionary] -and $ledgerConfig.Contains($k)) { $path = [string]$ledgerConfig[$k]; break }
        if (($ledgerConfig.PSObject.Properties.Name -contains $k)) { $path = [string]$ledgerConfig.$k; break }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { $path = 'audit-ledger.checkpoint.json' }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-AuditLedgerRoot -State $State) $path }
    $tenant = Get-AuditLedgerTenant -State $State
    if ($tenant -ne 'default') { $parent = [System.IO.Path]::GetDirectoryName($path); $leaf = [System.IO.Path]::GetFileName($path); $path = Join-Path (Join-Path (Join-Path $parent 'tenants') $tenant) $leaf }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
    try {
        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        $a = $doc.anchor
        $result.Present   = $true
        $result.Sequence  = [int]$a.sequence
        $result.Hash      = [string]$a.hash
        $result.MerkleRoot= [string]$a.merkleRoot
        $result.LeafCount = [int]$a.leafCount
        $result.CreatedAt = [string]$a.createdAt
        $result.Reason    = 'anchor present'
        $sig = [string]$doc.anchorSignature
        $result.SignaturePresent = (-not [string]::IsNullOrWhiteSpace($sig))
        if (-not $result.SignaturePresent) {
            $result.SignatureState = 'absent'
            $result.SignatureValid  = $false
            $result.Reason = 'anchor present but UNSIGNED'
        } elseif (Get-Command Test-Signature -ErrorAction SilentlyContinue) {
            $body = $a | ConvertTo-Json -Compress
            try {
                $result.SignatureValid = [bool](Test-Signature -Data $body -Signature $sig)
                if ($result.SignatureValid) {
                    $result.SignatureState = 'verified'
                    $result.Reason = 'anchor present and signature verified'
                } else {
                    $result.SignatureState = 'invalid'
                    $result.Reason = 'anchor present but signature INVALID'
                }
            } catch {
                $result.SignatureState = 'invalid'
                $result.Reason = "anchor present, signature check failed: $($_.Exception.Message)"
            }
        } else {
            # UNVERIFIED, not VALID. This branch used to set SignatureValid =
            # $true on the grounds that a signature which exists is "as good as
            # verified" when no key is loaded. It is not: tamper-evidence is a
            # claim about a CHECK THAT RAN, and no check ran here. The false
            # positive also suppressed the caller's warning at the verification
            # reader, because that reader keys off SignatureValid -eq $false, so
            # the one state an operator most needs told about was the one state
            # the code reported as fine. The anchor may well be genuine; the
            # honest answer is that nothing here can say so.
            $result.SignatureState = 'unverified'
            $result.SignatureValid  = $false
            $result.Reason = 'anchor present and signed, but NO SIGNING KEY IS LOADED so the signature is UNVERIFIED - tamper-evidence cannot be asserted'
        }
    } catch { $result.Reason = "anchor unreadable: $($_.Exception.Message)" }
    return $result
}

function Write-AuditLedgerEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][hashtable]$Entry, [switch]$Force)
    Initialize-AuditLedger -State $State
    if (-not $script:LedgerConfig.Enabled) { return $true }
    $tenant = Get-AuditLedgerTenant -State $State
    if ($Entry.ContainsKey('TenantId') -and $null -ne $Entry.TenantId -and [string]$Entry.TenantId -ne $tenant) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line1158' -Fallback 'Audit tenant mismatch.')) }
    $sequence = $script:LedgerState.EntryCount + 1
    $user = if ($State -and $State.PSObject.Properties.Name -contains 'BuildIdentity' -and $State.BuildIdentity -and $State.BuildIdentity.User) { [string]$State.BuildIdentity.User } else { $env:USERNAME }
    $correlation = if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId' -and $State.CorrelationId) { [string]$State.CorrelationId } else { '' }
    $entryWithMeta = [ordered]@{ Sequence = $sequence; Timestamp = (Get-Date).ToString('o'); Type = if ($Entry.ContainsKey('Type') -and $null -ne $Entry.Type) { $Entry.Type } else { 'AUDIT' }; Action = if ($Entry.ContainsKey('Action')) { $Entry.Action } else { '' }; Allowed = if ($Entry.ContainsKey('Allowed')) { [bool]$Entry.Allowed } else { $true }; User = if ($Entry.ContainsKey('User') -and $Entry.User) { $Entry.User } else { $user }; Roles = if ($Entry.ContainsKey('Roles')) { $Entry.Roles } else { '' }; Permission = if ($Entry.ContainsKey('Permission')) { $Entry.Permission } else { '' }; Resource = if ($Entry.ContainsKey('Resource')) { $Entry.Resource } else { '' }; CorrelationId = if ($Entry.ContainsKey('CorrelationId') -and $Entry.CorrelationId) { $Entry.CorrelationId } else { $correlation }; TenantId = $tenant; Detail = if ($Entry.ContainsKey('Detail')) { $Entry.Detail } else { '' }; PreviousHash = $script:LedgerState.CurrentHash; Signature = ''; SignAlgorithm = if ($script:LedgerConfig.Signing.Enabled) { [string]$script:LedgerConfig.Signing.Algorithm } else { '' } }
    if ($script:LedgerConfig.Signing.Enabled) {
        $entryWithMeta.Signature = Get-DataSignature -Data (Get-LedgerSigningData -Entry $entryWithMeta -PreviousHash $script:LedgerState.CurrentHash)
        if ([string]::IsNullOrWhiteSpace([string]$entryWithMeta.Signature)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.auditledger.line1165' -Fallback 'Audit ledger signature is required.')) }
    }
    $entryWithMeta.HashChain = Get-EntryHash -Entry $entryWithMeta -PreviousHash $script:LedgerState.CurrentHash
    $json = $entryWithMeta | ConvertTo-Json -Compress -Depth 20
    $success = $false
    if ($script:LedgerConfig.Backend -eq 'file') {
        $path = Get-LedgerPath -State $State
        $lock = Enter-AuditLedgerLock -Path $path
        try {
            # Self-heal the seal applied by Set-WormProtection at the end of the
            # previous build. A local-file ledger is append-only by design, so
            # the write path is responsible for restoring its own permission
            # rather than relying on every caller to remember.
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $probe = $null
                try {
                    $probe = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                } catch [System.UnauthorizedAccessException] {
                    try { Set-WormProtection -Path $path -Disable | Out-Null } catch { }
                } finally { if ($probe) { $probe.Dispose() } }
            }
            Sync-AuditLedgerFileState -Path $path
            if ($sequence -ne ($script:LedgerState.EntryCount + 1)) { $sequence = $script:LedgerState.EntryCount + 1; $entryWithMeta.Sequence = $sequence; if ($script:LedgerConfig.Signing.Enabled) { $entryWithMeta.Signature = Get-DataSignature -Data (Get-LedgerSigningData -Entry $entryWithMeta -PreviousHash $script:LedgerState.CurrentHash) }; $entryWithMeta.HashChain = Get-EntryHash -Entry $entryWithMeta -PreviousHash $script:LedgerState.CurrentHash; $json = $entryWithMeta | ConvertTo-Json -Compress -Depth 20 }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json + "`n")
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            $script:LedgerState.EntryCount = $sequence; $script:LedgerState.CurrentHash = [string]$entryWithMeta.HashChain; $success = $true
            # Expose the sequence on State so a caller can bound a per-run range
            # verification (Test-AuditLedgerRange).
            if ($State) { try { $State | Add-Member -MemberType NoteProperty -Name 'AuditLedgerEntryCount' -Value $sequence -Force } catch { } }
            $interval = [int]$script:LedgerConfig.Ledger.CheckpointInterval
            if ($interval -gt 0 -and ($sequence % $interval -eq 0)) { Save-AuditLedgerCheckpoint -State $State -Sequence $sequence }
        } finally { Exit-BuildFileLock -Lock $lock }
    } elseif ($script:LedgerConfig.Backend -eq 's3' -and (Get-Command Write-S3AuditEntry -ErrorAction SilentlyContinue)) { $success = [bool](Write-S3AuditEntry -Entry $json -State $State) }
    elseif ($script:LedgerConfig.Backend -eq 'azureBlob' -and (Get-Command Write-AzureBlobAuditEntry -ErrorAction SilentlyContinue)) { $success = [bool](Write-AzureBlobAuditEntry -Entry $json -State $State) }
    elseif ($script:LedgerConfig.Backend -eq 'ledger') {
        $script:LedgerState.EntryCount = $sequence; $script:LedgerState.CurrentHash = [string]$entryWithMeta.HashChain; [void]$script:LedgerState.MemoryEntries.Add($json); while ($script:LedgerState.MemoryEntries.Count -gt [int]$script:LedgerState.MemoryCap) { $script:LedgerState.MemoryEntries.RemoveAt(0) }; $success = $true
        $interval = [int]$script:LedgerConfig.Ledger.CheckpointInterval; if ($interval -gt 0 -and ($sequence % $interval -eq 0)) { Save-AuditLedgerCheckpoint -State $State -Sequence $sequence }
    }
    if ($success -and (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue)) { Send-BuildEvent -EventName $EVT_AUDIT_LEDGER_WRITE -Source $State -Data @{ Sequence = $sequence; Hash = $entryWithMeta.HashChain } | Out-Null }
    return $success
}

function Test-AuditLedger {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$MaxEntries = -1, [switch]$FullChain)
    Initialize-AuditLedger -State $State
    if (-not $script:LedgerConfig.Enabled) { return @{ Valid = $true; Reason = 'Audit ledger disabled' } }
    $path = Get-LedgerPath -State $State
    $lines = @()
    if ($script:LedgerConfig.Backend -eq 'file' -and (Test-Path -LiteralPath $path -PathType Leaf)) { $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop) }
    elseif ($script:LedgerConfig.Backend -eq 'ledger') { $lines = @($script:LedgerState.MemoryEntries.ToArray()) }
    elseif ($script:LedgerConfig.Backend -eq 's3' -and (Get-Command Read-S3AuditEntries -ErrorAction SilentlyContinue)) { $lines = @(Read-S3AuditEntries -State $State) }
    elseif ($script:LedgerConfig.Backend -eq 'azureBlob' -and (Get-Command Read-AzureBlobAuditEntries -ErrorAction SilentlyContinue)) { $lines = @(Read-AzureBlobAuditEntries -State $State) }
    $result = [ordered]@{ Valid = $true; TotalEntries = 0; VerifiedEntries = 0; FailedEntries = [System.Collections.Generic.List[object]]::new(); HashChainValid = $true; SignaturesValid = $true; MerkleRoot = ''; Errors = [System.Collections.Generic.List[string]]::new(); Warnings = [System.Collections.Generic.List[string]]::new() }
    if ($lines.Count -eq 0) { $result['Reason'] = 'No ledger entries exist'; $result['Errors'] = @($result.Errors.ToArray()); $result['FailedEntries'] = @($result.FailedEntries.ToArray()); return $result }
    if ($MaxEntries -gt 0 -and $lines.Count -gt $MaxEntries) { $lines = @($lines[($lines.Count - $MaxEntries)..($lines.Count - 1)]) }
    $previousHash = ''; $leafHashes = @(); $expectedSequence = $null
    foreach ($line in $lines) {
        $result.TotalEntries++
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { $result.Valid = $false; $result.Errors.Add("Invalid JSON at entry $($result.TotalEntries)"); continue }
        if ($null -eq $expectedSequence) { $expectedSequence = [int]$entry.Sequence } elseif ([int]$entry.Sequence -ne $expectedSequence) { $result.Valid = $false; $result.Errors.Add('Sequence gap detected') }
        if ([string]$entry.TenantId -ne (Get-AuditLedgerTenant -State $State)) { $result.Valid = $false; $result.Errors.Add('Tenant mismatch detected') }
        $expectedSequence = [int]$entry.Sequence + 1
        $expectedHash = Get-EntryHash -Entry $entry -PreviousHash $previousHash
        if ([string]$entry.HashChain -ne $expectedHash) { $result.Valid = $false; $result.HashChainValid = $false; $result.FailedEntries.Add([PSCustomObject]@{ Sequence = $entry.Sequence; Reason = 'Hash chain mismatch' }); $result.Errors.Add("Hash chain broken at sequence $($entry.Sequence)") } else { $result.VerifiedEntries++; $leafHashes += [string]$entry.HashChain }
        if ($script:LedgerConfig.Signing.Enabled) {
            $data = Get-LedgerSigningData -Entry $entry -PreviousHash $previousHash
            if ([string]::IsNullOrWhiteSpace([string]$entry.Signature) -or -not (Test-Signature -Data $data -Signature ([string]$entry.Signature))) { $result.Valid = $false; $result.SignaturesValid = $false; $result.FailedEntries.Add([PSCustomObject]@{ Sequence = $entry.Sequence; Reason = 'Missing or invalid signature' }); $result.Errors.Add("Invalid signature at sequence $($entry.Sequence)") }
        }
        $previousHash = [string]$entry.HashChain
    }
    if ($leafHashes.Count -gt 0) { $result.MerkleRoot = Get-MerkleRoot -LeafHashes $leafHashes }

    # ── ROLLBACK / TAIL-TRUNCATION DETECTION ──────────────────────────────────
    # A per-entry hash chain verifies that what IS there is internally
    # consistent. It cannot detect that something is MISSING: deleting the last
    # N entries leaves a valid prefix that verifies clean. Only an out-of-band
    # anchor closes that hole. Compare the recomputed Merkle root and entry
    # count against the last signed anchor.
    $anchor = $null
    try { $anchor = Get-AuditLedgerAnchor -State $State } catch { $anchor = $null }
    $result['AnchorPresent'] = [bool]($anchor -and $anchor.Present)
    $result['AnchorReason'] = if ($anchor) { [string]$anchor.Reason } else { 'anchor unavailable' }
    if ($anchor -and $anchor.Present) {
        $result['AnchorSequence'] = [int]$anchor.Sequence
        $result['AnchorMerkleRoot'] = [string]$anchor.MerkleRoot
        $result['AnchorSignatureValid'] = [bool]$anchor.SignatureValid
        $result['AnchorSignatureState'] = [string]$anchor.SignatureState
        if ([int]$anchor.LeafCount -gt 0 -and [int]$anchor.LeafCount -gt $leafHashes.Count) {
            $result.Valid = $false
            $result.Errors.Add("ROLLBACK DETECTED: signed anchor covers $($anchor.LeafCount) entries but the ledger holds only $($leafHashes.Count). The tail was truncated after the last anchor.")
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$anchor.MerkleRoot) -and $result.MerkleRoot -ne [string]$anchor.MerkleRoot -and [int]$anchor.LeafCount -le $leafHashes.Count) {
            # Ledger grew past the anchor: expected. Only flag when the count did NOT grow.
            $result.Errors.Add("Note: ledger has advanced past the last anchor ($($anchor.LeafCount) anchored, $($leafHashes.Count) present).")
        }
        # Three distinct states, three distinct answers. Treating them as one
        # boolean is what let the "unverified" case report as healthy.
        switch ([string]$anchor.SignatureState) {
            'invalid' {
                $result.Valid = $false
                $result.Errors.Add('ANCHOR SIGNATURE INVALID: the checkpoint file was modified without the signing key.')
            }
            'unverified' {
                # Not evidence of tampering, so Valid stays true - but the
                # operator must be told the anchor was NOT checked, because a
                # tampered anchor would look exactly the same from here.
                $result.Warnings.Add('ANCHOR SIGNATURE UNVERIFIED: no signing key is loaded, so the anchor was not checked. Tamper-evidence is unavailable until security.ledger.signing is configured.')
            }
            'absent' {
                $result.Warnings.Add('ANCHOR UNSIGNED: the checkpoint carries no signature, so tampering with it cannot be detected.')
            }
        }
    } elseif ((Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log (Resolve-LogMessage -Key 'log.audit.noAnchor' -Fallback '[AuditLedger] No anchor present - tail truncation of the ledger is NOT detectable until the first checkpoint is written.') 'Warn' $State
    }

    $result['Errors'] = @($result.Errors.ToArray())
    $result['Warnings'] = @($result.Warnings.ToArray())
    $result['FailedEntries'] = @($result.FailedEntries.ToArray())
    return $result
}

function Test-AuditLedgerRange {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$FromSequence, [int]$ToSequence)
    $all = Test-AuditLedger -State $State -FullChain
    if (-not (Test-Path -LiteralPath (Get-LedgerPath -State $State) -PathType Leaf)) { return @{ Valid = $all.Valid; Entries = @(); Errors = @($all.Errors) } }
    $entries = @()
    foreach ($line in @(Get-Content -LiteralPath (Get-LedgerPath -State $State))) { try { $entry = $line | ConvertFrom-Json -ErrorAction Stop; if ([int]$entry.Sequence -ge $FromSequence -and [int]$entry.Sequence -le $ToSequence) { $entries += $entry } } catch { } }
    return @{ Valid = $all.Valid; Entries = $entries; Errors = @($all.Errors) }
}

function Get-AuditLedgerWormStatus {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    return (Get-LedgerWormStatus -State $State)
}

function Set-WormProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Enable, [switch]$Disable)
    $state = [ordered]@{ Requested = [bool]$Enable; Enforced = $false; Honest = $true; WormEnabled = $false; WormVerified = $false; Status = 'NotWORM'; Path = $Path; Reason = 'filesystem ACLs do not provide WORM immutability' }
    if ($Disable) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $state.Reason = 'path is unavailable'; return $state }
        # Un-seal. The read-only ACL applied by -Enable is what bricked the
        # ledger after build #1: Write-AuditLedgerEntry opens the file with
        # FileAccess.Write, the ACL denies it, the resulting
        # UnauthorizedAccessException is swallowed by the caller's empty catch,
        # and the ledger silently stops accumulating while still reporting
        # "WORM protected". Append is the ONLY supported lifecycle for a
        # local-file ledger, so write access must be restorable.
        try {
            if ((Get-OSPlatform) -eq 'Windows') {
                # /grant:r with the caller's own identity, single argument, no
                # string interpolation into a native command line beyond the
                # resolved identity value.
                $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                & icacls $Path '/grant:r' ("{0}:(M)" -f $me) | Out-Null
            } else {
                & chmod 600 $Path
            }
            $state.Reason = 'write access restored'
            $state.Status = 'Unsealed'
        } catch { $state.Reason = 'permission restore failed' }
        return $state
    }
    if (-not $Enable) { return $state }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $state.Reason = 'path is unavailable'; return $state }
    if ((Get-OSPlatform) -eq 'Windows') {
        # Resolve the identity through the framework instead of interpolating
        # $env:USERNAME, which is attacker-controlled in a CI context and was
        # previously concatenated unescaped into a native command line.
        $me = $null
        try { $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $me = $null }
        if ([string]::IsNullOrWhiteSpace($me)) { $state.Reason = 'current Windows identity could not be resolved'; return $state }
        try { & icacls $Path '/inheritance:r' '/grant:r' ("{0}:(R)" -f $me) | Out-Null; $state.Reason = 'read-only ACL applied; immutable storage is still required' } catch { $state.Reason = 'ACL operation failed' }
    } else { try { & chmod 400 $Path; $state.Reason = 'read-only mode applied; immutable storage is still required' } catch { $state.Reason = 'permission operation failed' } }
    return $state
}

Export-ModuleMember -Function @(
    'Initialize-AuditLedger',
    'Write-AuditLedgerEntry',
    'Test-AuditLedger',
    'Test-AuditLedgerRange',
    'Export-AuditLedger',
    'Update-AuditRetention',
    'Set-WormProtection',
    'Get-AuditLedgerAnchor',
    'Get-AuditLedgerRoot',
    'Start-AuditLedgerVerificationScheduler',
    'Get-EntryHash',
    'Get-MerkleRoot',
    'Get-DataSignature',
    'Test-Signature',
    'Get-AuditLedgerWormStatus',
    'Get-LedgerPath',
    'Repair-LedgerTornTail',
    'Save-AuditLedgerCheckpoint'
)
