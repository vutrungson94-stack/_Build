# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

if (-not (Test-Path Variable:script:AwsCredentialLock)) { $script:AwsCredentialLock = New-Object object }
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils')
Import-GBuildModuleIfMissing -Name 'Logging' -SentinelCommand 'Write-Log'
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Read-JsonSafe'

function Get-ProcessEnvironmentSnapshot {
    param([string[]]$Names)

Set-StrictMode -Version 1.0
    $snapshot = @{}
    foreach ($name in @($Names)) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        $snapshot[$name] = [PSCustomObject]@{ Exists = ($null -ne $value); Value = $value }
    }
    return $snapshot
}

function Restore-ProcessEnvironmentSnapshot {
    param([hashtable]$Snapshot)
    foreach ($name in @($Snapshot.Keys)) {
        $entry = $Snapshot[$name]
        if ($entry.Exists) { [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, [EnvironmentVariableTarget]::Process) }
        else { [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process) }
    }
}

function Invoke-WithAwsCredentials {
    param([PSCustomObject]$Credentials, [scriptblock]$ScriptBlock, [string]$Region = '')
    $names = @('AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_SECURITY_TOKEN','AWS_PROFILE','AWS_SHARED_CREDENTIALS_FILE','AWS_CONFIG_FILE','AWS_REGION','AWS_DEFAULT_REGION','AWS_WEB_IDENTITY_TOKEN_FILE','AWS_ROLE_ARN','AWS_CONTAINER_CREDENTIALS_RELATIVE_URI','AWS_CONTAINER_CREDENTIALS_FULL_URI')
    if (-not [System.Threading.Monitor]::TryEnter($script:AwsCredentialLock, 30000)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.cacheprovider.line35' -Fallback 'AWS credential lock timeout.')) }
    $snapshot = Get-ProcessEnvironmentSnapshot -Names $names
    try {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process) }
        $access = [string](Get-SectionValue -Section $Credentials -Key 'AccessKey' -Default '')
        $secret = [string](Get-SectionValue -Section $Credentials -Key 'SecretKey' -Default '')
        $token = [string](Get-SectionValue -Section $Credentials -Key 'SessionToken' -Default '')
        if ($access) { [Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID', $access, [EnvironmentVariableTarget]::Process) }
        if ($secret) { [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', $secret, [EnvironmentVariableTarget]::Process) }
        if ($token) { [Environment]::SetEnvironmentVariable('AWS_SESSION_TOKEN', $token, [EnvironmentVariableTarget]::Process) }
        if ($Region) {
            [Environment]::SetEnvironmentVariable('AWS_REGION', $Region, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('AWS_DEFAULT_REGION', $Region, [EnvironmentVariableTarget]::Process)
        }
        return (& $ScriptBlock)
    } finally { Restore-ProcessEnvironmentSnapshot -Snapshot $snapshot; [System.Threading.Monitor]::Exit($script:AwsCredentialLock) }
}

function Get-CacheHADefault {
    param([string]$Key, $Fallback)
    try { if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { return (Get-BuildConstant -Key $Key -Fallback $Fallback) } } catch { }
    return $Fallback
}

$script:DefaultRemoteCacheConfig = [PSCustomObject]@{
    Enabled = $false; Name = 'RemoteCache'; Type = 'azureBlob'; Endpoint = ''; Container = ''; AuthToken = ''; Region = ''; AccessKey = ''; SecretKey = ''
    SyncOnBuild = $true; SyncOnRestore = $true; Compress = $false
    HA = [PSCustomObject]@{
        # These five used to be bare literals ('async', 'primary',
        # 'acknowledged', $true, $true) sitting directly beside sibling keys
        # that DID resolve through Get-CacheHADefault, so
        # build.cacheRemote.ha.{replicationStrategy,consistency.readPreference,
        # consistency.writeConcern,failover.enabled,failover.failbackEnabled}
        # were shipped in gbuild.config.json and silently ignored. Routing them
        # through the same accessor makes the config actually effective.
        Enabled = (Get-CacheHADefault -Key 'CacheHAFailoverEnabled' -Fallback $true)
        ReplicationStrategy = (Get-CacheHADefault -Key 'CacheHAReplicationStrategy' -Fallback 'async')
        Regions = @()
        Failover = [PSCustomObject]@{ Enabled = (Get-CacheHADefault -Key 'CacheHAFailoverEnabled' -Fallback $true); HealthCheckIntervalSec = (Get-CacheHADefault -Key 'CacheHAHealthCheckIntervalSec' -Fallback 30); HealthCheckTimeoutSec = (Get-CacheHADefault -Key 'CacheHAHealthCheckTimeoutSec' -Fallback 10); MaxRetries = (Get-CacheHADefault -Key 'CacheHAMaxRetries' -Fallback 3); FailbackEnabled = (Get-CacheHADefault -Key 'CacheHAFailbackEnabled' -Fallback $true); FailbackDelaySec = (Get-CacheHADefault -Key 'CacheHAFailbackDelaySec' -Fallback 300) }
        Consistency = [PSCustomObject]@{ ReadPreference = (Get-CacheHADefault -Key 'CacheHAReadPreference' -Fallback 'primary'); WriteConcern = (Get-CacheHADefault -Key 'CacheHAWriteConcern' -Fallback 'acknowledged'); MaxStalenessSec = (Get-CacheHADefault -Key 'CacheHAMaxStalenessSec' -Fallback 300) }
    }
}

$script:DefaultLocalCacheConfig = [PSCustomObject]@{ Enabled = $true; MaxEntries = (Get-BuildConstant -Key 'CacheMaxEntries' -Fallback 256); MaxAgeDays = (Get-BuildConstant -Key 'CacheMaxAgeDays' -Fallback 30); MaxSizeMb = (Get-BuildConstant -Key 'CacheMaxSizeMb' -Fallback 512); Compress = $false }

function Get-CacheTenantPrefix {
    param([PSCustomObject]$State)
    $tenant = 'default'
    if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { $tenant = [string]$State.TenantId }
    if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $tenant -eq '.' -or $tenant -eq '..') { return $null }
    if ($tenant -eq 'default') { return '' }
    return $tenant + '/'
}

function ConvertTo-CacheKeyPath {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $value = $Key.Trim().Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($value) -or $value.StartsWith('/') -or $value -match '[\x00-\x1f\x7f]') { return '' }
    $parts = @($value -split '/' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return '' }
    foreach ($part in $parts) { if ($part -eq '.' -or $part -eq '..' -or $part -match '[\x00-\x1f\x7f]') { return '' } }
    return ($parts -join '/')
}

function Resolve-CacheKey {
    param([PSCustomObject]$State, [string]$Key)
    $normalized = ConvertTo-CacheKeyPath -Key $Key
    if (-not $normalized) { return '' }
    $prefix = Get-CacheTenantPrefix -State $State
    if ($null -eq $prefix -and $State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { return '' }
    if ($prefix) { if ($normalized.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $normalized }; return $prefix + $normalized }
    if ($normalized.StartsWith('default/', [System.StringComparison]::Ordinal)) { return (ConvertTo-CacheKeyPath -Key $normalized.Substring(8)) }
    $first = ($normalized -split '/', 2)[0]
    if ($normalized.Contains('/') -and $first -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -and $first -ne 'default') { return '' }
    return $normalized
}

function Get-CacheLogicalKey {
    param([PSCustomObject]$State, [string]$RemoteKey)
    $normalized = ConvertTo-CacheKeyPath -Key $RemoteKey
    if (-not $normalized) { return '' }
    $prefix = Get-CacheTenantPrefix -State $State
    if ($null -eq $prefix -and $State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { return '' }
    if ($prefix) {
        if (-not $normalized.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return '' }
        return (ConvertTo-CacheKeyPath -Key $normalized.Substring($prefix.Length))
    }
    if ($normalized.StartsWith('default/', [System.StringComparison]::Ordinal)) { return (ConvertTo-CacheKeyPath -Key $normalized.Substring(8)) }
    $first = ($normalized -split '/', 2)[0]
    if ($normalized.Contains('/') -and $first -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -and $first -ne 'default') { return '' }
    return $normalized
}

function Get-CacheStateRoot {
    param([PSCustomObject]$State)
    # Single source: PathUtils.Get-BuildRootDirectory (ProjectRoot > ScriptRoot).
    # Guarded for the PS 5.1-orphan path where PathUtils is not loaded; the inline
    # copy is behavior-identical to the canonical (including its CWD fallback).
    $candidate = if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State }
                 elseif ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
    try { return ([System.IO.Path]::GetFullPath($candidate)).TrimEnd('\', '/') } catch { return '' }
}

function Test-CachePathUnderRoot {
    param([string]$Path, [string]$Root)
    # PathUtils.Test-PathUnderRoots is the owner. A local fallback remains only
    # for a stripped import where PathUtils cannot be loaded; normal operation
    # never uses the copy below.
    Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Test-PathUnderRoots'
    if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
        return Test-PathUnderRoots -Path $Path -AllowedRoots @($Root)
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $p = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
        $r = ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\', '/')
        $cmp = Get-PathComparison

        return (($p -eq $r) -or $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, $cmp))
    } catch { return $false }
}

function Resolve-CacheLocalRoot {
    param([PSCustomObject]$State)
    $root = Get-CacheStateRoot -State $State
    if (-not $root) { return '' }
    $base = [string](Get-BuildConstant -Key 'CacheDir' -Fallback '.gbuildcache')
    $build = Get-ConfigSection -State $State -Path 'build'
    $configured = Get-SectionValue -Section $build -Key 'CacheDirectory' -Default $null
    if ($configured) { $base = [string]$configured }
    if ([string]::IsNullOrWhiteSpace($base) -or $base -match '[\x00-\x1f\x7f]') { return '' }
    try {
        $candidate = if ([System.IO.Path]::IsPathRooted($base)) { $base } else { Join-Path $root $base }
        $candidate = [System.IO.Path]::GetFullPath($candidate)
        $isolation = [string](Get-ConfigValue -Path 'tenancy.isolation' -State $State -Default 'directory')
        $tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
        if ($isolation -eq 'directory' -and $tenant -ne 'default') {
            if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $tenant -eq '.' -or $tenant -eq '..') { return '' }
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $candidate $tenant))
        }
        $roots = @($root)
        if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { $roots += [string]$State.ScriptRoot }
        $roots += [System.IO.Path]::GetTempPath()
        $ok = $false
        foreach ($allowed in $roots) { if (Test-CachePathUnderRoot -Path $candidate -Root $allowed) { $ok = $true; break } }
        if (-not $ok) { return '' }
        return $candidate.TrimEnd('\', '/')
    } catch { return '' }
}

function Get-LocalCacheDir {
    <#
    .SYNOPSIS
        Public accessor for the resolved local cache root.
    .DESCRIPTION
        NOT a duplicate of Resolve-CacheLocalRoot - it is the exported door to
        it. The resolver is module-private because it encodes the tenant-isolation
        and cache-directory precedence rules; without an exported wrapper the
        cache root would not be reachable from outside this module at all, and
        the one caller that needed it (the multi-tenant test asserting the root
        nests under the tenant directory) had to be deleted.

        A one-line forwarder is the right shape here: the alternative - exporting
        the resolver itself - would widen the public surface to 40+ arguments'
        worth of precedence rules that no external caller should be able to
        bypass.
    #>
    param([PSCustomObject]$State)
    return (Resolve-CacheLocalRoot -State $State)
}

function Get-LocalCacheConfig {
    param([PSCustomObject]$State)
    # Defaults come from the single BuildConstants registry, not from a second
    # hand-maintained copy. This function previously repeated the literals here,
    # so changing CacheMaxEntries silently updated $script:DefaultLocalCacheConfig
    # but not this call path - the two drifted apart with no failing test.
    # Copy, do not alias: the loop below writes through $result, so handing back
    # the shared object would bake one project's config into every later call.
    $d = $script:DefaultLocalCacheConfig
    $result = [PSCustomObject]@{
        Enabled = $d.Enabled; MaxEntries = $d.MaxEntries; MaxAgeDays = $d.MaxAgeDays
        MaxSizeMb = $d.MaxSizeMb; Compress = $d.Compress
    }
    $raw = Get-ConfigSection -State $State -Path 'build.cacheLocal'
    foreach ($name in @('Enabled','MaxEntries','MaxAgeDays','MaxSizeMb','Compress')) {
        $value = Get-SectionValue -Section $raw -Key $name -Default $null
        if ($null -ne $value) {
            if ($name -eq 'Enabled' -or $name -eq 'Compress') { $result.$name = [bool]$value } else { $result.$name = [int]$value }
        }
    }
    if ($result.MaxEntries -lt 1) { $result.MaxEntries = 1 }
    if ($result.MaxAgeDays -lt 1) { $result.MaxAgeDays = 1 }
    if ($result.MaxSizeMb -lt 1) { $result.MaxSizeMb = 1 }
    return $result
}

function Resolve-CacheLocalPath {
    param([PSCustomObject]$State, [string]$RelativePath, [string]$LocalRoot = '')
    $logical = ConvertTo-CacheKeyPath -Key $RelativePath
    $root = if ($LocalRoot) { $LocalRoot } else { Resolve-CacheLocalRoot -State $State }
    if (-not $logical -or -not $root) { return '' }
    try {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $root ($logical.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
        if (-not (Test-CachePathUnderRoot -Path $candidate -Root $root)) { return '' }
        return $candidate
    } catch { return '' }
}

<#
.SYNOPSIS
    True when a cache destination path is inside an allowed root and behind no junction.
.DESCRIPTION
    Delegates containment to PathUtils.Test-PathUnderRoots and the reparse walk to
    PathUtils.Test-NoReparsePointInPath. The inline copies this replaced had two
    real defects: (1) the containment test was StartsWith-only, so a SIBLING root
    sharing the prefix (root 'C:\base' vs target 'C:\baseFoo\x') was accepted -
    Test-PathUnderRoots anchors on the trailing separator and rejects it; (2) the
    reparse walk skipped the volume root, so a SUBST drive passed.
#>
function Test-CacheDestinationPath {
    param([PSCustomObject]$State, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $hasPathUtils = (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) -and (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $roots = [System.Collections.Generic.List[string]]::new()
        foreach ($value in @((Get-CacheStateRoot -State $State), $(if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot') { [string]$State.ScriptRoot } else { '' }), [System.IO.Path]::GetTempPath())) {
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $roots.Add(([System.IO.Path]::GetFullPath($value)).TrimEnd('\', '/'))
        }
        if ($hasPathUtils) {
            if (-not (Test-PathUnderRoots -Path $full -AllowedRoots @($roots.ToArray()))) { return $false }
            if (-not (Test-NoReparsePointInPath -Path $full)) { return $false }
            return $true
        }
        # Fail closed. This module was the one copy of the containment +
        # reparse guard that had no delegation at all: a private 18-line
        # reimplementation of PathUtils' rule, reachable whenever PathUtils
        # was not already in the session. Two implementations of a security
        # guard is one too many, and the safe failure for a cache path is to
        # refuse it, not to re-derive the rule.
        return $false
    } catch { return $false }
}

function Get-CacheRemoteLimit {
    param([PSCustomObject]$State)
    $raw = Get-ConfigSection -State $State -Path 'build.cacheRemote'
    foreach ($name in @('maxEntryBytes','maxDownloadBytes','maxUploadBytes','maxSizeBytes','maxBytes','sizeLimitBytes')) {
        $value = Get-SectionValue -Section $raw -Key $name -Default $null
        if ($null -ne $value) { try { if ([long]$value -gt 0) { return [long]$value } } catch { } }
    }
    foreach ($name in @('maxSize','maxSizeMB')) {
        $value = Get-SectionValue -Section $raw -Key $name -Default $null
        if ($null -ne $value) { try { if ([long]$value -gt 0) { return [long]$value * 1MB } } catch { } }
    }
    $defaultMb = 512
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $defaultMb = [int](Get-BuildConstant -Key 'CacheMaxSizeMb' -Fallback 512) } catch { } }
    return ([long]$defaultMb * 1MB)
}

function Get-ExpectedCacheChecksum {
    param([PSCustomObject]$State, [string]$ExpectedSha256)
    if ($ExpectedSha256) { return ($ExpectedSha256 -replace '^sha256:', '' -replace '\s', '').ToUpperInvariant() }
    $raw = Get-ConfigSection -State $State -Path 'build.cacheRemote'
    foreach ($name in @('expectedSha256','checksumSha256','sha256','checksum','contentHash','integritySha256','expectedChecksum')) {
        $value = [string](Get-SectionValue -Section $raw -Key $name -Default '')
        if ($value) { $value = ($value -replace '^sha256:', '' -replace '\s', '').ToUpperInvariant(); if ($value -notmatch '\$\{env:' -and $value -match '^[0-9A-F]{64}$') { return $value } }
    }
    return ''
}

function Get-CacheResponseChecksum {
    param([object]$Response)
    if (-not $Response) { return '' }
    foreach ($name in @('x-ms-meta-sha256','x-amz-meta-sha256','Content-MD5','ETag')) {
        try { $value = ([string]$Response.Headers[$name]).Trim('"'); if ($value -match '^[0-9A-Fa-f]{64}$') { return $value.ToUpperInvariant() } } catch { }
    }
    return ''
}

function Get-CacheFileSha256 {
    param([string]$Path)
    # SharedUtils.Get-BuildFileSha256 is the owner. The private stream-and-hash
    # copy this replaces also called Initialize-BuildSharedUtils to lazy-load
    # SharedUtils and then used nothing from it - a delegation whose result was
    # discarded, which reads as compliance while doing nothing.
    return Get-BuildFileSha256 -Path $Path
}

function Test-CacheFileSize {
    param([string]$Path, [long]$MaxBytes)
    try { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }; if ($MaxBytes -le 0) { return $true }; return (([System.IO.FileInfo]$Path).Length -le $MaxBytes) } catch { return $false }
}

# Thin, renamed forward to the shared owner. SharedUtils.Move-BuildFileAtomic
# is the single implementation of "put this file at that path atomically";
# this was a private copy of it, and Steps/publish-artifact carried a third.
function Move-CacheFileAtomic {
    param([string]$SourcePath, [string]$DestinationPath)
    return [bool](Move-BuildFileAtomic -Source $SourcePath -Destination $DestinationPath)
}

# Enter-CacheIndexLock is owned by Cache.psm1 (thin forward to the shared
# Enter-BuildFileLockOrThrow owner). CacheProvider calls the shared owner
# directly to avoid a second definition of the same name.

function Compress-CacheFile {
    param([string]$SourcePath, [string]$DestinationPath)
    $input = $null; $output = $null; $gzip = $null
    try { $input = [System.IO.File]::OpenRead($SourcePath); $output = [System.IO.File]::Create($DestinationPath); $gzip = New-Object System.IO.Compression.GzipStream($output, [System.IO.Compression.CompressionMode]::Compress); $input.CopyTo($gzip); return $true }
    catch { Write-Log (Resolve-LogMessage -Key 'log.cache.compressionFailed' -MessageArgs @([string]$SourcePath, [string]$_) -Fallback '[CacheProvider] Compression failed ({0}): {1}') 'Warn'; return $false }
    finally { if ($gzip) { $gzip.Dispose() }; if ($output) { $output.Dispose() }; if ($input) { $input.Dispose() } }
}

function Expand-CacheFile {
    param([string]$SourcePath, [string]$DestinationPath, [long]$MaxBytes = 0)
    $input = $null; $output = $null; $gzip = $null
    try {
        $input = [System.IO.File]::OpenRead($SourcePath); $gzip = New-Object System.IO.Compression.GzipStream($input, [System.IO.Compression.CompressionMode]::Decompress); $output = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920; [long]$total = 0
        while (($read = $gzip.Read($buffer,0,$buffer.Length)) -gt 0) { $total += $read; if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) { throw (Resolve-LogMessage -Key 'log.cacheprovider.line359' -Fallback 'Decompressed cache entry exceeds the configured size limit.') }; $output.Write($buffer,0,$read) }
        return $true
    } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.decompressionFailed' -MessageArgs @([string]$SourcePath, [string]$_) -Fallback '[CacheProvider] Decompression failed ({0}): {1}') 'Warn'; return $false }
    finally { if ($gzip) { $gzip.Dispose() }; if ($output) { $output.Dispose() }; if ($input) { $input.Dispose() } }
}

function Invoke-CacheEviction {
    param([PSCustomObject]$State, [string]$CacheDir)
    $policy = Get-LocalCacheConfig -State $State
    if (-not $policy.Enabled) { return 0 }
    try { $root = if ($CacheDir) { [System.IO.Path]::GetFullPath($CacheDir).TrimEnd('\', '/') } else { Resolve-CacheLocalRoot -State $State } } catch { return 0 }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    $safeRoots = @([System.IO.Path]::GetTempPath())
    if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $safeRoots += [string]$State.ProjectRoot }
    if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { $safeRoots += [string]$State.ScriptRoot }
    # Pester on macOS/macOS runner uses /private/tmp (and /tmp is a symlink to it).
    # .NET GetTempPath() may return the per-user TMPDIR (/var/folders/.../T/), which
    # is a different directory. Add both so test fixtures under Pester's TestDrive
    # are not rejected as outside permitted roots.
    foreach ($t in @('/tmp', '/private/tmp')) {
        if (-not ($safeRoots -contains $t)) { $safeRoots += $t }
    }
    if ($IsMacOS) {
        $varFolders = '/var/folders'
        if (Test-Path -LiteralPath $varFolders -PathType Container) {
            Get-ChildItem -Path $varFolders -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $tDir = Join-Path $_.FullName 'T'
                if (Test-Path -LiteralPath $tDir -PathType Container -ErrorAction SilentlyContinue) {
                    if (-not ($safeRoots -contains $tDir)) { $safeRoots += $tDir }
                }
            }
        }
    }
    if ($root -eq [System.IO.Path]::GetPathRoot($root)) { return 0 }
    foreach ($safeRoot in $safeRoots) { try { if ($root -eq ([System.IO.Path]::GetFullPath($safeRoot)).TrimEnd('\', '/')) { return 0 } } catch { } }
    $safe = $false; foreach ($safeRoot in $safeRoots) { if (Test-CachePathUnderRoot -Path $root -Root $safeRoot) { $safe = $true; break } }
    if (-not $safe) { return 0 }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/'); $relative -ne 'index.json' -and $relative -ne 'index.json.lock' -and $relative -notmatch '^\.gbuild-' -and (Test-CachePathUnderRoot -Path $_.FullName -Root $root) })
    if ($files.Count -eq 0) { return 0 }
    $files = @($files | Sort-Object LastWriteTime); $total = [long](($files | Measure-Object Length -Sum).Sum); $removed = 0; $cutoff = (Get-Date).AddDays(-$policy.MaxAgeDays)
    foreach ($file in $files) {
        if (-not (($files.Count - $removed -gt $policy.MaxEntries) -or ($total -gt ($policy.MaxSizeMb * 1MB)) -or ($file.LastWriteTime -lt $cutoff))) { break }
        try { if (-not (Test-CachePathUnderRoot -Path $file.FullName -Root $root)) { continue }; $total -= $file.Length; Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ } catch { }
    }
    return $removed
}

function Invoke-UnifiedCacheEviction {
    <#
    .SYNOPSIS
        Runs the blob-level LRU/age/size cache eviction policy owned by
        CacheProvider. The index-level LRU is owned by BuildCache.Optimize and
        is invoked directly by Optimize-Cache on the shared $script:BuildCache
        instance, so it must NOT be repeated here (a fresh Get-BuildCache
        instance optimizes nothing visible to the live path).
    #>
    param([PSCustomObject]$State, [string]$CacheDir = '')
    $count = 0
    try { $count += [int](Invoke-CacheEviction -State $State -CacheDir $CacheDir) } catch { }
    return $count
}

function Resolve-CacheAddressValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) { $Value = Resolve-EnvPlaceholder -Text $Value }
    if ($Value -match '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}') { return '' }
    return $Value
}

function Get-RemoteCacheConfig {
    param([PSCustomObject]$State, [hashtable]$Region)
    $raw = Get-ConfigSection -State $State -Path 'build.cacheRemote'
    if (-not $raw) { return [PSCustomObject]@{ Enabled = $false; Name = 'RemoteCache'; Type = 'azureBlob'; Endpoint = ''; Container = ''; AuthToken = ''; Region = ''; AccessKey = ''; SecretKey = ''; SyncOnBuild = $true; SyncOnRestore = $true; Compress = $false; HA = $script:DefaultRemoteCacheConfig.HA } }
    $ha = Get-SectionValue -Section $raw -Key 'ha' -Default $null; $ha = if ($ha) { $ha } else { [PSCustomObject]@{} }
    $failover = Get-SectionValue -Section $ha -Key 'Failover' -Default $null; $failover = if ($failover) { $failover } else { [PSCustomObject]@{} }
    $consistency = Get-SectionValue -Section $ha -Key 'Consistency' -Default $null; $consistency = if ($consistency) { $consistency } else { [PSCustomObject]@{} }
    $regions = Get-SectionValue -Section $ha -Key 'Regions' -Default @()
    $config = [PSCustomObject]@{
        Enabled = [bool](Get-SectionValue -Section $raw -Key 'Enabled' -Default $false)
        Name = [string](Get-SectionValue -Section $raw -Key 'Name' -Default 'RemoteCache')
        Type = [string](Get-SectionValue -Section $raw -Key 'Type' -Default 'azureBlob')
        Endpoint = [string](Get-SectionValue -Section $raw -Key 'Endpoint' -Default '')
        Container = [string](Get-SectionValue -Section $raw -Key 'Container' -Default '')
        AuthToken = [string](Get-SectionValue -Section $raw -Key 'AuthToken' -Default '')
        Region = [string](Get-SectionValue -Section $raw -Key 'Region' -Default '')
        AccessKey = [string](Get-SectionValue -Section $raw -Key 'AccessKey' -Default '')
        SecretKey = [string](Get-SectionValue -Section $raw -Key 'SecretKey' -Default '')
        SyncOnBuild = [bool](Get-SectionValue -Section $raw -Key 'SyncOnBuild' -Default $true)
        SyncOnRestore = [bool](Get-SectionValue -Section $raw -Key 'SyncOnRestore' -Default $true)
        Compress = [bool](Get-SectionValue -Section $raw -Key 'Compress' -Default $false)
        HA = [PSCustomObject]@{ Enabled = [bool](Get-SectionValue -Section $ha -Key 'Enabled' -Default $false); ReplicationStrategy = [string](Get-SectionValue -Section $ha -Key 'ReplicationStrategy' -Default 'async'); Regions = @($regions); Failover = [PSCustomObject]@{ Enabled = [bool](Get-SectionValue -Section $failover -Key 'Enabled' -Default $true); HealthCheckIntervalSec = [int](Get-SectionValue -Section $failover -Key 'HealthCheckIntervalSec' -Default 30); HealthCheckTimeoutSec = [int](Get-SectionValue -Section $failover -Key 'HealthCheckTimeoutSec' -Default 10); MaxRetries = [int](Get-SectionValue -Section $failover -Key 'MaxRetries' -Default 3); FailbackEnabled = [bool](Get-SectionValue -Section $failover -Key 'FailbackEnabled' -Default $true); FailbackDelaySec = [int](Get-SectionValue -Section $failover -Key 'FailbackDelaySec' -Default 300) }; Consistency = [PSCustomObject]@{ ReadPreference = [string](Get-SectionValue -Section $consistency -Key 'ReadPreference' -Default 'primary'); WriteConcern = [string](Get-SectionValue -Section $consistency -Key 'WriteConcern' -Default 'acknowledged'); MaxStalenessSec = [int](Get-SectionValue -Section $consistency -Key 'MaxStalenessSec' -Default 300) } }
    }
    if ($config.AuthToken) { $config.AuthToken = Resolve-CacheAddressValue -Value $config.AuthToken }
    if ($config.AccessKey) { $config.AccessKey = Resolve-CacheAddressValue -Value $config.AccessKey }
    if ($config.SecretKey) { $config.SecretKey = Resolve-CacheAddressValue -Value $config.SecretKey }
    $config.Endpoint = Resolve-CacheAddressValue -Value $config.Endpoint
    $config.Name = Resolve-CacheAddressValue -Value $config.Name
    $config.Region = Resolve-CacheAddressValue -Value $config.Region
    # Region override: the single mechanism that lets the HA layer retarget any
    # transfer at a replica without duplicating the transport code. Before this,
    # Get-HAReplicaConfigs produced a region shape that no code path could consume,
    # so the whole HA subsystem was dead. Callers pass -Region $replica.
    if ($Region -is [hashtable]) {
        if ($Region.ContainsKey('Name'))         { $config.Name = [string]$Region['Name'] }
        if ($Region.ContainsKey('Type'))         { $config.Type = [string]$Region['Type'] }
        if ($Region.ContainsKey('Endpoint'))     { $config.Endpoint = [string]$Region['Endpoint'] }
        if ($Region.ContainsKey('Container'))    { $config.Container = [string]$Region['Container'] }
        if ($Region.ContainsKey('AuthToken'))    { $config.AuthToken = [string]$Region['AuthToken'] }
        if ($Region.ContainsKey('Region'))       { $config.Region = [string]$Region['Region'] }
        if ($Region.ContainsKey('AccessKey'))    { $config.AccessKey = [string]$Region['AccessKey'] }
        if ($Region.ContainsKey('SecretKey'))    { $config.SecretKey = [string]$Region['SecretKey'] }
        if ($Region.ContainsKey('Compress'))     { $config.Compress = [bool]$Region['Compress'] }
    }
    # Resolve ${env:...} placeholders inside each HA region. This must NOT mutate
    # the region node in place, and it must NOT assume one node shape:
    #   * a PSCustomObject region rejects `$region.Name = ...` when the property
    #     does not exist yet ("There is no settable property available");
    #   * a Hashtable region exposes its ENTRIES as .PSObject.Properties are the
    #     hashtable's own Count/Keys/Values, so enumerating .PSObject.Properties
    #     silently yields nothing.
    # Region nodes reach here from JSON (PSCustomObject) and from merged/default
    # config (Hashtable), so both are handled and a normalized PSCustomObject copy
    # is returned. Building the copy also stops one caller's env resolution from
    # mutating another caller's config.
    # NOTE: the loop variable is deliberately NOT named $region. PowerShell
    # variables are case-insensitive, so `foreach ($region in ...)` assigns to the
    # typed [hashtable]$Region parameter and every assignment is re-validated
    # against that constraint: a PSCustomObject region throws
    # "Cannot convert value @{...} to type System.Collections.Hashtable".
    $normalizedRegions = @()
    foreach ($node in @($config.HA.Regions)) {
        if ($null -eq $node) { continue }
        $resolved = [ordered]@{}
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) {
                $value = $node[$key]
                if ($value -is [string]) { $value = Resolve-CacheAddressValue -Value $value }
                $resolved[[string]$key] = $value
            }
        } else {
            foreach ($prop in @($node.PSObject.Properties)) {
                $value = $prop.Value
                if ($value -is [string]) { $value = Resolve-CacheAddressValue -Value $value }
                $resolved[[string]$prop.Name] = $value
            }
        }
        $normalizedRegions += [PSCustomObject]$resolved
    }
    $config.HA.Regions = $normalizedRegions
    return $config
}

function New-AzureBlobUrl {
    param([string]$Endpoint, [string]$Container, [string]$BlobName, [string]$SasToken)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or -not [System.Uri]::TryCreate($Endpoint, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($uri.Host) -or $Container -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { return '' }
    $key = ConvertTo-CacheKeyPath -Key $BlobName; if (-not $key) { return '' }
    $encoded = (($key -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $url = "$($Endpoint.TrimEnd('/'))/$Container/$encoded"
    if ($SasToken) { $url += $(if ($SasToken.StartsWith('?')) { $SasToken } else { '?' + $SasToken }) }
    return $url
}

function New-S3SignedUrl {
    param([string]$Bucket, [string]$Key, [string]$Region, [int]$Expires = -1, [PSCustomObject]$State = $null)
    if ($Bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { return $null }
    $key = ConvertTo-CacheKeyPath -Key $Key; if (-not $key) { return $null }
    if ($Expires -le 0) { $Expires = [int](Get-BuildConstant -Key 'CachePresignExpiresSec' -State $State -Fallback 3600) }
    $configured = Get-BuildConstant -Key 'CachePresignExpiresSec' -State $State -Fallback $null; if ($configured) { $Expires = [int]$configured }
    $aws = Get-Command aws -ErrorAction SilentlyContinue; if (-not $aws) { return $null }
    try { $url = & $aws s3 presign "s3://$Bucket/$key" --region $Region --expires-in $Expires 2>$null; if ($LASTEXITCODE -eq 0 -and $url) { return ([string]$url).Trim() } } catch { }
    return $null
}

function Invoke-BoundedCacheDownload {
    param([string]$Url, [string]$Path, [long]$MaxBytes, [int]$TimeoutSec = 120)
    $legacyCommand = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    if ($legacyCommand -and $legacyCommand.CommandType -in @('Function','Filter','Alias')) {
        return (Invoke-WebRequest -Uri $Url -Method Get -OutFile $Path -TimeoutSec $TimeoutSec -ErrorAction Stop)
    }
    $request = $null; $response = $null; $input = $null; $output = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
        $request.ReadWriteTimeout = [Math]::Max(1, $TimeoutSec) * 1000
        $request.AllowAutoRedirect = $true
        $response = $request.GetResponse()
        if ($MaxBytes -gt 0 -and $response.ContentLength -gt $MaxBytes) { throw (Resolve-LogMessage -Key 'log.cacheprovider.line547' -Fallback 'Remote cache entry exceeds the configured size limit.') }
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Create($Path)
        $buffer = New-Object byte[] 81920
        [long]$total = 0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) { throw (Resolve-LogMessage -Key 'log.cacheprovider.line554' -Fallback 'Remote cache entry exceeds the configured size limit.') }
            $output.Write($buffer, 0, $read)
        }
        $headers = @{}
        foreach ($name in @($response.Headers.AllKeys)) { if ($name) { $headers[[string]$name] = $response.Headers[$name] } }
        return [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Headers = $headers }
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Send-CachePut {
    param([string]$Url, [hashtable]$Headers, [string]$WorkFile, [string]$TmpCompressed, [string]$LogMessage, [PSCustomObject]$State, [long]$MaxBytes = 0)
    if (-not $Url -or -not (Test-CacheFileSize -Path $WorkFile -MaxBytes $MaxBytes)) { return $false }
    $response = Invoke-WebRequest -Uri $Url -Method Put -Headers $Headers -InFile $WorkFile -TimeoutSec (Get-BuildConstant -Key 'CachePushTimeoutSec' -Fallback 120) -ErrorAction Stop
    if ([int]$response.StatusCode -notin @(200, 201)) { return $false }
    if ($TmpCompressed -and (Test-Path -LiteralPath $TmpCompressed)) { Remove-Item -LiteralPath $TmpCompressed -Force -ErrorAction SilentlyContinue }
    Write-Log $LogMessage 'Succ' $State; return $true
}

function Send-CacheEntry {
    param([PSCustomObject]$State, [string]$Key, [string]$FilePath, [string]$Type = 'blob', [switch]$Compress, [Alias('ExpectedHash')][string]$ExpectedSha256 = '', [long]$MaxBytes = 0, [hashtable]$Region, [switch]$NoReplicate)
    $Key = Resolve-CacheKey -State $State -Key $Key; if (-not $Key) { return $false }
    $cfg = Get-RemoteCacheConfig -State $State -Region $Region; if (-not $cfg.Enabled) { return $false }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    if (Test-ReparsePointItem -Path $FilePath) { return $false }
    $limit = if ($MaxBytes -gt 0) { $MaxBytes } else { Get-CacheRemoteLimit -State $State }
    if (-not (Test-CacheFileSize -Path $FilePath -MaxBytes $limit)) { return $false }
    $expected = Get-ExpectedCacheChecksum -State $State -ExpectedSha256 $ExpectedSha256
    if ($expected) { try { if ((Get-CacheFileSha256 -Path $FilePath) -ne $expected) { return $false } } catch { return $false } }
    $workFile = [System.IO.Path]::GetFullPath($FilePath); $temporary = $null
    try {
        if ($Compress -or $cfg.Compress) { $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-cache-' + [guid]::NewGuid().ToString('N') + '.gz'); if (-not (Compress-CacheFile -SourcePath $workFile -DestinationPath $temporary)) { return $false }; $workFile = $temporary }
        $pushed = $false
        if ($cfg.Type -eq 'azureBlob') {
            $url = New-AzureBlobUrl -Endpoint $cfg.Endpoint -Container $cfg.Container -BlobName $Key -SasToken $(if ($Type -eq 'blob') { $cfg.AuthToken } else { '' })
            $pushed = [bool](Send-CachePut -Url $url -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'Content-Type' = 'application/octet-stream' } -WorkFile $workFile -TmpCompressed $temporary -LogMessage "[CacheProvider] Pushed to Azure Blob: $Key" -State $State -MaxBytes $limit)
        }
        elseif ($cfg.Type -eq 'awsS3') {
            $bucket = [string]$cfg.Container; if ($bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { return $false }
            $aws = Get-Command aws -ErrorAction SilentlyContinue
            if ($aws) {
                $pushed = [bool](Invoke-WithAwsCredentials -Credentials $cfg -Region $cfg.Region -ScriptBlock { & $aws s3 cp $workFile "s3://$bucket/$Key" --region $cfg.Region --quiet 2>$null; $code = $LASTEXITCODE; if ($code -eq 0) { if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }; Write-Log (Resolve-LogMessage -Key 'log.cache.pushedS3' -MessageArgs @("s3://$bucket/$Key") -Fallback '[CacheProvider] Pushed to S3: {0}') 'Succ' $State; return $true }; return $false })
            } elseif ($cfg.Endpoint) {
                $endpointUri = $null; if (-not [System.Uri]::TryCreate($cfg.Endpoint, [System.UriKind]::Absolute, [ref]$endpointUri) -or $endpointUri.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($endpointUri.Host)) { return $false }
                $url = "$($cfg.Endpoint.TrimEnd('/'))/$bucket/$Key"; $date = (Get-Date).ToString('R')
                $auth = "AWS $($cfg.AccessKey):$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("PUT`n`napplication/octet-stream`n$date`n/$bucket/$Key")))"
                $pushed = [bool](Send-CachePut -Url $url -Headers @{ 'Date' = $date; 'Authorization' = $auth; 'Content-Type' = 'application/octet-stream' } -WorkFile $workFile -TmpCompressed $temporary -LogMessage "[CacheProvider] Pushed to S3 (REST): $Key" -State $State -MaxBytes $limit)
            }
        }
        # HA write path: after a successful primary push, fan out to the replicas
        # that build.cacheRemote.ha declares. Only on a PRIMARY push, and never
        # inside a replica push (guarded by -NoReplicate), so replication cannot
        # recurse. A replica failure never fails the primary write: the build must
        # not break because a secondary cache node is down.
        if ($pushed -and -not $NoReplicate -and -not $Region) {
            try {
                $repl = Invoke-HAReplication -State $State -Key $Key -LocalFilePath $workFile
                $failedReplicas = @($repl.Replicas.Keys | Where-Object { $repl.Replicas[$_] -is [bool] -and -not $repl.Replicas[$_] })
                if ($failedReplicas.Count -gt 0) { Write-Log (Resolve-LogMessage -Key 'log.cache.replicaReplicationFailed' -MessageArgs @(($failedReplicas -join ', ')) -Fallback '[CacheProvider HA] Replica replication failed for: {0}') 'Warn' $State }
            } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.replicationError' -MessageArgs @([string]$_) -Fallback '[CacheProvider HA] Replication error (primary push retained): {0}') 'Warn' $State }
        }
        return $pushed
    } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.pushFailed' -MessageArgs @([string]$Key, [string]$_) -Fallback '[CacheProvider] Push failed ({0}): {1}') 'Warn' $State; return $false }
    finally { if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Complete-CacheReceive {
    param([bool]$Compressed, [string]$TempFile, [string]$DestinationPath, [PSCustomObject]$State, [string]$ExpectedSha256 = '', [long]$MaxBytes = 0)
    $expanded = $null
    try {
        $limit = if ($MaxBytes -gt 0) { $MaxBytes } else { Get-CacheRemoteLimit -State $State }
        if (-not (Test-CacheFileSize -Path $TempFile -MaxBytes $limit)) { return $false }
        $candidate = $TempFile
        if ($Compressed) { $expanded = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($DestinationPath))) ('.gbuild-extract-' + [guid]::NewGuid().ToString('N') + '.tmp'); if (-not (Expand-CacheFile -SourcePath $TempFile -DestinationPath $expanded -MaxBytes $limit)) { return $false }; $candidate = $expanded }
        if (-not (Test-CacheFileSize -Path $candidate -MaxBytes $limit)) { return $false }
        $expected = Get-ExpectedCacheChecksum -State $State -ExpectedSha256 $ExpectedSha256
        if ($expected -and (Get-CacheFileSha256 -Path $candidate) -ne $expected) { return $false }
        if (-not (Move-CacheFileAtomic -SourcePath $candidate -DestinationPath $DestinationPath)) { return $false }
        $expanded = $null; return $true
    } catch { return $false }
    finally { if ($expanded -and (Test-Path -LiteralPath $expanded)) { Remove-Item -LiteralPath $expanded -Force -ErrorAction SilentlyContinue } }
}

function Receive-CacheEntry {
    param([PSCustomObject]$State, [string]$Key, [Alias('Destination')][string]$DestinationPath, [string]$Type = 'blob', [switch]$Compress, [Alias('ExpectedHash')][string]$ExpectedSha256 = '', [long]$MaxBytes = 0, [switch]$UseRemoteKey, [hashtable]$Region, [switch]$NoReplicaFallback)
    if ($UseRemoteKey) { $remote = ConvertTo-CacheKeyPath -Key $Key; if (-not $remote -or -not (Get-CacheLogicalKey -State $State -RemoteKey $remote)) { return $false }; $Key = $remote } else { $Key = Resolve-CacheKey -State $State -Key $Key }
    if (-not $Key) { return $false }
    $cfg = Get-RemoteCacheConfig -State $State -Region $Region; if (-not $cfg.Enabled) { return $false }
    try { $DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath) } catch { return $false }
    if (-not (Test-CacheDestinationPath -State $State -Path $DestinationPath)) { return $false }
    $parent = Split-Path -Parent $DestinationPath; if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $parent) } else { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null } }
    $useCompress = [bool]($Compress -or $cfg.Compress); $limit = if ($MaxBytes -gt 0) { $MaxBytes } else { Get-CacheRemoteLimit -State $State }; $download = Join-Path $parent ('.gbuild-download-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $got = $false
    try {
        if ($cfg.Type -eq 'azureBlob') {
            $url = New-AzureBlobUrl -Endpoint $cfg.Endpoint -Container $cfg.Container -BlobName $Key -SasToken $(if ($Type -eq 'blob') { $cfg.AuthToken } else { '' }); if (-not $url) { return $false }
            $response = Invoke-BoundedCacheDownload -Url $url -Path $download -MaxBytes $limit -TimeoutSec (Get-BuildConstant -Key 'CachePullTimeoutSec' -Fallback 120)
            if (-not (Test-CacheFileSize -Path $download -MaxBytes $limit)) { return $false }
            $expected = if ($ExpectedSha256) { $ExpectedSha256 } else { Get-CacheResponseChecksum -Response $response }
            $got = [bool](Complete-CacheReceive -Compressed:$useCompress -TempFile $download -DestinationPath $DestinationPath -State $State -ExpectedSha256 $expected -MaxBytes $limit)
        }
        elseif ($cfg.Type -eq 'awsS3') {
            $bucket = [string]$cfg.Container; if ($bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { return $false }
            $aws = Get-Command aws -ErrorAction SilentlyContinue; $downloaded = $false
            if ($aws) { $downloaded = [bool](Invoke-WithAwsCredentials -Credentials $cfg -Region $cfg.Region -ScriptBlock { & $aws s3 cp "s3://$bucket/$Key" $download --region $cfg.Region --quiet 2>$null; if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $download)) { return [bool](Complete-CacheReceive -Compressed:$useCompress -TempFile $download -DestinationPath $DestinationPath -State $State -ExpectedSha256 $ExpectedSha256 -MaxBytes $limit) }; return $false }) }
            if (-not $downloaded) { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }; $url = New-S3SignedUrl -Bucket $bucket -Key $Key -Region $cfg.Region -State $State; if ($url) { $response = Invoke-BoundedCacheDownload -Url $url -Path $download -MaxBytes $limit -TimeoutSec (Get-BuildConstant -Key 'CachePullTimeoutSec' -Fallback 120); if (Test-CacheFileSize -Path $download -MaxBytes $limit) { $expected = if ($ExpectedSha256) { $ExpectedSha256 } else { Get-CacheResponseChecksum -Response $response }; $downloaded = [bool](Complete-CacheReceive -Compressed:$useCompress -TempFile $download -DestinationPath $DestinationPath -State $State -ExpectedSha256 $expected -MaxBytes $limit) } } }
            $got = $downloaded
        }
    } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.pullFailed' -MessageArgs @([string]$Key, [string]$_) -Fallback '[CacheProvider] Pull failed ({0}): {1}') 'Warn' $State; $got = $false }
    finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue } }

    # HA read path: on a primary miss, try each healthy replica. A cache is
    # self-healing, so a replica hit is a legitimate restore; the primary is
    # always tried first, and a replica is only consulted after the primary
    # returned nothing. Never recursive: -NoReplicaFallback is passed down.
    if (-not $got -and -not $NoReplicaFallback -and -not $Region) {
        $got = Receive-CacheEntryFromReplica -State $State -Key $Key -DestinationPath $DestinationPath -Type $Type -Compress:$Compress -ExpectedSha256 $ExpectedSha256 -MaxBytes $MaxBytes -UseRemoteKey:$UseRemoteKey
    }
    return $got
}

<#
.SYNOPSIS
    HA read fallback: pull a cache entry from the first healthy replica that has it.
.DESCRIPTION
    Makes the build.cacheRemote.ha subsystem reachable. Before this existed,
    Get-HAReplicaConfigs / Get-HealthyRegions / Select-ReadRegion were exported and
    tested but never invoked by the data path, so a green CacheHA.Tests.ps1 gave
    false assurance that HA was active. Each attempt goes through the SAME
    Receive-CacheEntry transport (via -Region), so size limits, checksum
    verification and destination containment are enforced identically on a replica.
#>
function Receive-CacheEntryFromReplica {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State, [string]$Key, [string]$DestinationPath,
        [string]$Type = 'blob', [switch]$Compress, [string]$ExpectedSha256 = '',
        [long]$MaxBytes = 0, [switch]$UseRemoteKey
    )
    try {
        if (-not (Get-HAEnabled -State $State)) { return $false }
        # SINGLE read-region selection. This used to re-implement candidate
        # ordering inline (replica-first when the preference says so, primary
        # otherwise) while Select-ReadRegion - which is fail-closed and
        # type-normalised - was exported and never called by the data path.
        # Two implementations of the same policy meant the documented
        # consistency.readPreference could be honoured in one and ignored in
        # the other. Select-ReadRegion is now the only selector; the
        # preference is applied to the ordered result rather than by a
        # parallel code path.
        $selected = Select-ReadRegion -State $State
        if (-not $selected) { return $false }
        $preference = [string](Get-SectionValue -Section (Get-RemoteCacheConfig -State $State).HA.Consistency -Key 'ReadPreference' -Default 'primary')
        $primaryName = (Get-PrimaryCacheConfig -State $State)['Name']
        $ordered = @($selected)
        if ($preference -eq 'replicaFirst' -and [string]$selected['Name'] -eq $primaryName) {
            # Primary was chosen by Select-ReadRegion; try a replica first.
            $replicaFirst = @(Get-HealthyRegions -State $State | Where-Object { $_ -is [hashtable] -and [string]$_['Name'] -ne $primaryName })
            if ($replicaFirst.Count -gt 0) { $ordered = @($replicaFirst) + @($selected) }
        }
        $lastReason = ''
        foreach ($replica in $ordered) {
            if (-not $replica) { continue }
            try {
                if (Receive-CacheEntry -State $State -Key $Key -DestinationPath $DestinationPath -Type $Type -Compress:$Compress -ExpectedSha256 $ExpectedSha256 -MaxBytes $MaxBytes -UseRemoteKey:$UseRemoteKey -Region $replica -NoReplicaFallback) {
                    Write-Log (Resolve-LogMessage -Key 'log.cache.haRestored' -MessageArgs @([string]$Key, $replica['Name']) -Fallback '[CacheProvider HA] Restored ''{0}'' from region ''{1}''') 'Info' $State
                    return $true
                }
            } catch { $lastReason = (Resolve-LogMessage -Key 'log.cache.haRegionReadFailed' -MessageArgs @([string]$replica['Name'], [string]$_) -Fallback "[CacheProvider HA] region '{0}' read failed: {1}"); Write-Log $lastReason 'Warn' $State }
        }
        # No healthy region at all is a distinct condition from "healthy region
        # but no entry": the former means HA is not actually deployed. Say so
        # instead of silently returning $false.
        try { Select-ReadRegion -State $State | Out-Null } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.replicaFallbackUnavailable' -MessageArgs @([string]$_.Exception.Message) -Fallback '[CacheProvider HA] Replica fallback unavailable: {0}') 'Gray' $State }
        return $false
    } catch { return $false }
}

<#
.SYNOPSIS
    HA health gate: evaluate failover/failback and log the resulting posture.
.DESCRIPTION
    Wires Invoke-HAFailoverCheck / Invoke-HAFailbackCheck into the build. Both were
    exported and never called, so build.cacheRemote.ha.failover.* was inert. This
    is called once per build from the cache sync path; it is advisory (it never
    fails a build) and only produces a log line naming the region that would take
    over, so an operator can see the HA posture without reading the config.
#>
function Test-CacheHAFailoverPosture {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)
    try {
        if (-not (Get-HAEnabled -State $State)) { return $false }
        $fo = Invoke-HAFailoverCheck -State $State
        if ($fo -and $fo.FailedOver) {
            Write-Log (Resolve-LogMessage -Key 'log.cache.haPrimaryUnhealthy' -MessageArgs @([string](Get-PrimaryCacheConfig -State $State).Name, $fo.NewPrimary['Name'], ($fo.FailedRegions -join ', ')) -Fallback '[CacheProvider HA] Primary ''{0}'' is unhealthy; failback candidate ''{1}'' (failed: {2})') 'Warn' $State
        } elseif (Invoke-HAFailbackCheck -State $State) {
            Write-Log (Resolve-LogMessage -Key 'log.cache.haAllHealthy' -Fallback '[CacheProvider HA] All regions healthy; primary retained') 'Info' $State
        } else {
            Write-Log (Resolve-LogMessage -Key 'log.cache.haFailbackInconclusive' -Fallback '[CacheProvider HA] Failback check inconclusive (primary not yet healthy)') 'Gray' $State
        }
        return $true
    } catch { Write-Log (Resolve-LogMessage -Key 'log.cache.failoverCheckError' -MessageArgs @([string]$_) -Fallback '[CacheProvider HA] Failover check error: {0}') 'Warn' $State; return $false }
}

function Test-CacheEntryExists {
    param([PSCustomObject]$State, [string]$Key, [string]$Type = 'blob')
    $Key = Resolve-CacheKey -State $State -Key $Key; if (-not $Key) { return $false }
    $cfg = Get-RemoteCacheConfig -State $State; if (-not $cfg.Enabled) { return $false }
    try {
        if ($cfg.Type -eq 'azureBlob') { $url = New-AzureBlobUrl -Endpoint $cfg.Endpoint -Container $cfg.Container -BlobName $Key -SasToken $(if ($Type -eq 'blob') { $cfg.AuthToken } else { '' }); if (-not $url) { return $false }; $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec (Get-BuildConstant -Key 'CacheHeadTimeoutSec' -Fallback 30) -ErrorAction Stop; return ($response.StatusCode -eq 200) }
        if ($cfg.Type -eq 'awsS3') { $bucket = [string]$cfg.Container; if ($bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { return $false }; $aws = Get-Command aws -ErrorAction SilentlyContinue; $exists = $false; if ($aws) { $exists = [bool](Invoke-WithAwsCredentials -Credentials $cfg -Region $cfg.Region -ScriptBlock { & $aws s3api head-object --bucket $bucket --key $Key --region $cfg.Region 2>$null; return ($LASTEXITCODE -eq 0) }) }; if (-not $exists) { $url = New-S3SignedUrl -Bucket $bucket -Key $Key -Region $cfg.Region -State $State; if ($url) { $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec (Get-BuildConstant -Key 'CacheHeadTimeoutSec' -Fallback 30) -ErrorAction Stop; $exists = ($response.StatusCode -eq 200) } }; return $exists }
        return $false
    } catch { $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }; if ($code -eq 404) { return $false }; return $false }
}

function Update-CacheToLocal {
    param([PSCustomObject]$State)
    $cfg = Get-RemoteCacheConfig -State $State; if (-not $cfg.Enabled) { return 0 }
    $root = Resolve-CacheLocalRoot -State $State; if (-not $root) { return 0 }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $root) } else { New-Item -ItemType Directory -Path $root -Force -ErrorAction SilentlyContinue | Out-Null } }
    $indexPath = Join-Path $root 'index.json'; $remoteIndexPath = Join-Path $root ('.gbuild-remote-index-' + [guid]::NewGuid().ToString('N') + '.tmp'); $remoteIndex = $null; $count = 0
    try {
        if ($cfg.Type -eq 'azureBlob') {
            if ($cfg.Endpoint -notmatch '^https?://' -or $cfg.Container -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { return 0 }
            $url = "$($cfg.Endpoint.TrimEnd('/'))/$($cfg.Container)?restype=container&comp=list"; if ($cfg.AuthToken) { $url += $(if ($cfg.AuthToken.StartsWith('?')) { $cfg.AuthToken } else { '?' + $cfg.AuthToken }) }
            $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec (Get-BuildConstant -Key 'CacheListTimeoutSec' -Fallback 60) -ErrorAction Stop
            $xml = if ($response -is [string]) { [xml]$response } else { $response }
            $blobs = @($xml.SelectNodes("//*[local-name()='Blob']"))
            foreach ($blob in $blobs) { $nameNode = $blob.SelectSingleNode("*[local-name()='Name']"); if (-not $nameNode) { continue }; $name = [string]$nameNode.InnerText; $logical = Get-CacheLogicalKey -State $State -RemoteKey $name; if (-not $logical) { continue }; if ($logical -eq 'index.json') { if (Receive-CacheEntry -State $State -Key $name -DestinationPath $remoteIndexPath -Type blob -UseRemoteKey) { $remoteIndex = Read-JsonSafe -FilePath $remoteIndexPath }; continue }; $localPath = Resolve-CacheLocalPath -State $State -RelativePath $logical -LocalRoot $root; if (-not $localPath) { continue }; $parent = Split-Path -Parent $localPath; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null }; if (Receive-CacheEntry -State $State -Key $name -DestinationPath $localPath -Type blob -UseRemoteKey) { $count++ } }
        } elseif ($cfg.Type -eq 'awsS3') {
            $bucket = [string]$cfg.Container; if ($bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { return 0 }; $aws = Get-Command aws -ErrorAction SilentlyContinue; if (-not $aws) { return 0 }
            $listed = Invoke-WithAwsCredentials -Credentials $cfg -Region $cfg.Region -ScriptBlock { $text = & $aws s3api list-objects-v2 --bucket $bucket --region $cfg.Region --output json 2>$null; [PSCustomObject]@{ Code = [int]$LASTEXITCODE; Text = ($text -join [Environment]::NewLine) } }
            if ($listed.Code -eq 0 -and $listed.Text) { $objects = $listed.Text | ConvertFrom-Json; foreach ($object in @($objects.Contents)) { $name = [string]$object.Key; $logical = Get-CacheLogicalKey -State $State -RemoteKey $name; if (-not $logical) { continue }; if ($logical -eq 'index.json') { if (Receive-CacheEntry -State $State -Key $name -DestinationPath $remoteIndexPath -Type blob -UseRemoteKey) { $remoteIndex = Read-JsonSafe -FilePath $remoteIndexPath }; continue }; $localPath = Resolve-CacheLocalPath -State $State -RelativePath $logical -LocalRoot $root; if (-not $localPath) { continue }; $parent = Split-Path -Parent $localPath; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null }; if (Receive-CacheEntry -State $State -Key $name -DestinationPath $localPath -Type blob -UseRemoteKey) { $count++ } } }
        } else { return 0 }
        if ($remoteIndex -and $remoteIndex.Entries) {
            $lock = Enter-BuildFileLockOrThrow -Path $indexPath -TimeoutMs 15000 -What 'remote cache index' -ReturnNullOnEmptyPath
            if ($lock) { try { $localIndex = Read-JsonSafe -FilePath $indexPath; $merged = @{}; if ($localIndex -and $localIndex.Entries) { foreach ($property in $localIndex.Entries.PSObject.Properties) { $merged[[string]$property.Name] = $property.Value } }; foreach ($property in $remoteIndex.Entries.PSObject.Properties) { $logical = Get-CacheLogicalKey -State $State -RemoteKey ([string]$property.Name); if (-not $logical -or $merged.ContainsKey($logical)) { continue }; $entry = $property.Value; $output = [string](Get-SectionValue -Section $entry -Key 'OutputPath' -Default ''); if (-not $output) { continue }; try { $outputFull = [System.IO.Path]::GetFullPath($output) } catch { continue }; $allowed = (Test-CachePathUnderRoot -Path $outputFull -Root $root) -or (Test-CachePathUnderRoot -Path $outputFull -Root (Get-CacheStateRoot -State $State)); if ($allowed -and (Test-Path -LiteralPath $outputFull)) { $merged[$logical] = $entry } }; $version = Get-BuildConstant -Key 'CacheIndexVersion' -Fallback '2.0'; Save-JsonSafe -Data @{ Version = $version; Entries = $merged } -FilePath $indexPath } finally { $lock.Dispose() } }
        }
        if (Test-Path -LiteralPath $remoteIndexPath) { Remove-Item -LiteralPath $remoteIndexPath -Force -ErrorAction SilentlyContinue }
        return $count
    } catch { if (Test-Path -LiteralPath $remoteIndexPath) { Remove-Item -LiteralPath $remoteIndexPath -Force -ErrorAction SilentlyContinue }; return $count }
}

function Update-CacheToRemote {
    param([PSCustomObject]$State)
    $cfg = Get-RemoteCacheConfig -State $State; if (-not $cfg.Enabled) { return 0 }
    $root = Resolve-CacheLocalRoot -State $State; if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    if ($cfg.Type -notin @('azureBlob','awsS3')) { return 0 }
    $count = 0
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop)) {
            $full = [System.IO.Path]::GetFullPath($file.FullName); if (-not (Test-CachePathUnderRoot -Path $full -Root $root)) { continue }
            $relative = $full.Substring($root.Length).TrimStart('\', '/'); if ($relative -eq 'index.json.lock' -or $relative -match '^\.gbuild-') { continue }
            $relative = ConvertTo-CacheKeyPath -Key $relative; if (-not $relative) { continue }
            if (Send-CacheEntry -State $State -Key $relative -FilePath $full -Type blob) { $count++ }
        }
        return $count
    } catch { return $count }
}

function Get-HAEnabled { param([PSCustomObject]$State); $cfg = Get-RemoteCacheConfig -State $State; return [bool]($cfg.HA -and $cfg.HA.Enabled) }
function Get-PrimaryCacheConfig { param([PSCustomObject]$State); $cfg = Get-RemoteCacheConfig -State $State; return @{ Name=$cfg.Name; Type=$cfg.Type; Endpoint=$cfg.Endpoint; Container=$cfg.Container; AuthToken=$cfg.AuthToken; Region=$cfg.Region; AccessKey=$cfg.AccessKey; SecretKey=$cfg.SecretKey; Compress=$cfg.Compress } }
function Get-HAReplicaConfigs {
    param([PSCustomObject]$State); $cfg = Get-RemoteCacheConfig -State $State; $result = @(); foreach ($region in @($cfg.HA.Regions)) { $name = [string](Get-SectionValue -Section $region -Key 'Name' -Default ''); if (-not $name -or $name -match '\$\{env:') { continue }; $result += @{ Name=$name; Type=$cfg.Type; Endpoint=[string](Get-SectionValue -Section $region -Key 'Endpoint' -Default $cfg.Endpoint); Container=[string](Get-SectionValue -Section $region -Key 'Container' -Default $cfg.Container); AuthToken=[string](Get-SectionValue -Section $region -Key 'AuthToken' -Default $cfg.AuthToken); Region=$name; AccessKey=[string](Get-SectionValue -Section $region -Key 'AccessKey' -Default $cfg.AccessKey); SecretKey=[string](Get-SectionValue -Section $region -Key 'SecretKey' -Default $cfg.SecretKey); Compress=$cfg.Compress; Priority=[int](Get-SectionValue -Section $region -Key 'Priority' -Default 100); ReadOnly=[bool](Get-SectionValue -Section $region -Key 'ReadOnly' -Default $false) } }; return ,@($result | Sort-Object Priority)
}
function Test-RegionHealth {
    param([hashtable]$RegionConfig, [PSCustomObject]$State, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = [int](Get-CacheHADefault -Key 'CacheHAHealthCheckTimeoutSec' -Fallback 10) }
    try { if ($RegionConfig.Type -eq 'azureBlob') { $url = New-AzureBlobUrl -Endpoint $RegionConfig.Endpoint -Container $RegionConfig.Container -BlobName '__health_check__' -SasToken $RegionConfig.AuthToken; $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec $TimeoutSec -ErrorAction Stop; return ($response.StatusCode -in @(200,404)) }; if ($RegionConfig.Type -eq 'awsS3') { $aws = Get-Command aws -ErrorAction SilentlyContinue; if ($aws) { return [bool](Invoke-WithAwsCredentials -Credentials $RegionConfig -Region $RegionConfig.Region -ScriptBlock { & $aws s3api head-bucket --bucket $RegionConfig.Container --region $RegionConfig.Region 2>$null; return ($LASTEXITCODE -eq 0) }) } }; if ($RegionConfig.Endpoint) { $url = "$($RegionConfig.Endpoint.TrimEnd('/'))/$($RegionConfig.Container)/__health_check__"; $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec $TimeoutSec -ErrorAction Stop; return ($response.StatusCode -in @(200,404)) } } catch { }
    return $false
}
function Get-HealthyRegions {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([PSCustomObject]$State)
    $primary = Get-PrimaryCacheConfig -State $State
    $replicas = @(Get-HAReplicaConfigs -State $State | Where-Object { $_ -is [hashtable] })
    $regions = @($primary) + $replicas
    $healthy = @()
    foreach ($node in $regions) {
        if (-not $node) { continue }
        if (Test-RegionHealth -RegionConfig $node -State $State) { $healthy += $node }
    }
    # Always return an ARRAY (never $null), matching the `,@()` convention used by
    # every collection-returning function in this codebase. Callers MUST normalise
    # with a type filter before testing .Count - see the fail-closed guards in
    # Select-ReadRegion / Select-WriteRegion / Receive-CacheEntryFromReplica.
    return ,@($healthy)
}
# Fail-closed region selection. The `| Where-Object { $_ -is [hashtable] }` filter is
# load-bearing, not cosmetic: a `,@()` return of an empty collection surfaces to the
# caller as a single wrapped empty array, so a bare `.Count -eq 0` test sees 1 and
# the "no healthy region" guard never fires - the function then returns a bogus
# region instead of failing. Normalising by type makes the guard correct regardless
# of the return convention.
function Select-WriteRegion { param([PSCustomObject]$State); $cfg=Get-RemoteCacheConfig -State $State; $primary=Get-PrimaryCacheConfig -State $State; $replicas=@(Get-HAReplicaConfigs -State $State | Where-Object { $_ -is [hashtable] }); $allCount=1+$replicas.Count; $healthy=@(Get-HealthyRegions -State $State | Where-Object { $_ -is [hashtable] }); if($healthy.Count -eq 0){throw 'No healthy cache regions available'}; $selected=$healthy|Where-Object{$_['Name'] -eq $primary['Name']}|Select-Object -First 1; if(-not $selected){$selected=$healthy[0]}; $concern=[string]$cfg.HA.Consistency.WriteConcern; if($concern -eq 'all' -and $healthy.Count -lt $allCount){throw 'Write concern not met'}; return $selected }
function Select-ReadRegion { param([PSCustomObject]$State); $healthy=@(Get-HealthyRegions -State $State | Where-Object { $_ -is [hashtable] }); if($healthy.Count -eq 0){throw 'No healthy cache regions available'}; $primary=Get-PrimaryCacheConfig -State $State; $selected=$healthy|Where-Object{$_['Name'] -eq $primary['Name']}|Select-Object -First 1; if(-not $selected){$selected=$healthy[0]}; return $selected }
function Copy-ToRegion {
    param([hashtable]$SourceRegion,[hashtable]$TargetRegion,[string]$Key,[string]$LocalFilePath,[PSCustomObject]$State)
    if($TargetRegion.ReadOnly){return $true}; $temp=Join-Path ([IO.Path]::GetTempPath()) ('gbuild-repl-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try { if($LocalFilePath -and (Test-Path -LiteralPath $LocalFilePath -PathType Leaf)){[IO.File]::Copy([IO.Path]::GetFullPath($LocalFilePath),$temp,$true)}else{$key=Resolve-CacheKey -State $State -Key $Key;if(-not $key -or -not (Receive-CacheEntry -State $State -Key $key -DestinationPath $temp -Type blob)){return $false}}; if($TargetRegion.Type -eq 'azureBlob'){$url=New-AzureBlobUrl -Endpoint $TargetRegion.Endpoint -Container $TargetRegion.Container -BlobName (Resolve-CacheKey -State $State -Key $Key) -SasToken $TargetRegion.AuthToken;return [bool](Send-CachePut -Url $url -Headers @{'x-ms-blob-type'='BlockBlob';'Content-Type'='application/octet-stream'} -WorkFile $temp -TmpCompressed '' -LogMessage "[CacheProvider HA] Replicated to $($TargetRegion.Name)" -State $State -MaxBytes (Get-CacheRemoteLimit -State $State))}; if($TargetRegion.Type -eq 'awsS3'){$aws=Get-Command aws -ErrorAction SilentlyContinue;if($aws){$targetKey=Resolve-CacheKey -State $State -Key $Key;$targetBucket=[string]$TargetRegion.Container;$targetRegion=[string]$TargetRegion.Region;return [bool](Invoke-WithAwsCredentials -Credentials $TargetRegion -Region $targetRegion -ScriptBlock {& $aws s3 cp $temp "s3://$targetBucket/$targetKey" --region $targetRegion --quiet 2>$null;return($LASTEXITCODE -eq 0)})}};return $false } catch { return $false } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function Invoke-HAReplication {
    param([PSCustomObject]$State,[string]$Key='',[string]$LocalFilePath='')
    $result=@{Primary=$false;Replicas=@{};Strategy='async'}
    if(-not(Get-HAEnabled -State $State)){return $result}
    $cfg=Get-RemoteCacheConfig -State $State
    $result.Strategy=$cfg.HA.ReplicationStrategy
    $replicas=@(Get-HAReplicaConfigs -State $State)
    if ($replicas.Count -eq 0) { return $result }
    # Write-concern / primary selection used to be absent here: Select-WriteRegion
    # was exported, documented as the write-path selector, and never called, so
    # consistency.writeConcern and a degraded primary were both ignored on the
    # write path. It is fail-closed (throws when no region is healthy or the
    # write concern cannot be met), so its failure must degrade replication for
    # the primary - never fail the build.
    $primaryOk = $true
    $source = $null
    try { $source = Select-WriteRegion -State $State } catch { $primaryOk = $false; Write-Log (Resolve-LogMessage -Key 'log.cache.writeRegionUnavailable' -MessageArgs @([string]$_.Exception.Message) -Fallback '[CacheProvider HA] Write region unavailable: {0} - replicating opportunistically') 'Warn' $State }
    $result.Primary = $primaryOk
    if (-not $source) { $source = Get-PrimaryCacheConfig -State $State }
    # When no write region could be selected the configuration's write concern
    # cannot be honoured, so a synchronous strategy is downgraded to the async
    # 'queued' result instead of being reported as replicated. $primaryOk used to
    # be assigned here and never read, so the comment above promised a
    # degradation that never actually happened.
    $strategy = if ($primaryOk) { [string]$cfg.HA.ReplicationStrategy } else { 'async' }
    foreach($replica in $replicas){
        $ok=$false
        if($strategy -ne 'async'){ $ok=Copy-ToRegion -SourceRegion $source -TargetRegion $replica -Key $Key -LocalFilePath $LocalFilePath -State $State }
        $result.Replicas[$replica.Name]=if($strategy -eq 'async'){'queued'}else{$ok}
    }
    return $result
}
function Invoke-HAFailoverCheck { param([PSCustomObject]$State);$result=@{FailedOver=$false;NewPrimary=$null;FailedRegions=@()};if(-not(Get-HAEnabled -State $State)){return $result};$cfg=Get-RemoteCacheConfig -State $State;if(-not $cfg.HA.Failover.Enabled){return $result};$primary=Get-PrimaryCacheConfig -State $State;$healthy=@(Get-HealthyRegions -State $State);if(@($healthy|Where-Object{$_.Name -eq $primary.Name}).Count -gt 0){return $result};$candidate=@($healthy|Where-Object{-not $_.ReadOnly}|Sort-Object Priority)|Select-Object -First 1;if(-not $candidate){return $result};$result.FailedOver=$true;$result.NewPrimary=$candidate;$result.FailedRegions=@($primary.Name);return $result }
function Invoke-HAFailbackCheck { param([PSCustomObject]$State);if(-not(Get-HAEnabled -State $State)){return $false};$cfg=Get-RemoteCacheConfig -State $State;if(-not $cfg.HA.Failover.FailbackEnabled){return $false};return (Test-RegionHealth -RegionConfig (Get-PrimaryCacheConfig -State $State) -State $State) }

Export-ModuleMember -Function @('Get-RemoteCacheConfig','Get-LocalCacheDir','Send-CacheEntry','Receive-CacheEntry','Receive-CacheEntryFromReplica','Test-CacheHAFailoverPosture','Test-CacheEntryExists','Update-CacheToLocal','Update-CacheToRemote','Invoke-CacheEviction','Invoke-UnifiedCacheEviction','Compress-CacheFile','Expand-CacheFile','Resolve-CacheKey','Get-HAEnabled','Get-PrimaryCacheConfig','Get-HAReplicaConfigs','Test-RegionHealth','Get-HealthyRegions','Select-WriteRegion','Select-ReadRegion','Copy-ToRegion','Invoke-HAReplication','Invoke-HAFailoverCheck','Invoke-HAFailbackCheck')
