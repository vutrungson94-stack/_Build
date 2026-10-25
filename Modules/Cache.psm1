# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# ModuleBootstrap.ps1 self-loads BuildImport.psm1 (defines Import-GBuildModule /
# Import-BuildDependencies) before resolving -Dependencies.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ==================================================================================================
# Modules/Cache.psm1 (Build Cache System)
# ==================================================================================================
#
# Provides:
#   - File hash-based cache invalidation
#   - Skip unchanged projects in multi-project solutions
#   - Cache .NET restore, compilation outputs
#   - Cache persistence across sessions
#   - Cache statistics & cleanup
#   - gbuild --cache-stats / --cache-clear
#
# State is now encapsulated in a BuildCache class instance (OOP adoption, Phase B1d);
# the exported functions remain thin backward-compatible wrappers.

# -- Import dependencies --
# Nested imports WITHOUT -Force: Logging references the globally loaded instance
# (gbuild.ps1 bootstrap) and SharedUtils must stay NESTED so the BuildCache class
# methods can resolve Read-JsonSafe/Save-JsonSafe in PS 5.1. A nested -Force
# re-import orphans the global Logging module (PS 5.1 module-table bug).
$imports = @{BuildConstants = 'BuildConstants.psm1'; Logging = 'Logging.psm1'; Environment = 'Environment.psm1'; SharedUtils = 'SharedUtils.psm1'}
foreach ($pair in $imports.GetEnumerator()) {
    $p = Join-Path $PSScriptRoot $pair.Value
    if (Test-Path $p) { $null = Import-Module $p -DisableNameChecking -ErrorAction SilentlyContinue }
}
# Locale for i18n log messages (log.cache.*) — sentinel keeps standalone imports safe
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'
# PathUtils for Get-BuildRootDirectory (root-selection) — imported -Force -Global via
# the canonical guard so class methods see it even when the module was already loaded
# nested by another module (a plain Import-Module here would silently no-op in that case).
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Get-BuildRootDirectory'

function Get-CanonicalCacheKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Key)

Set-StrictMode -Version 1.0
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $value = $Key.Trim().Replace('\', '/')
    if ($value.StartsWith('/') -or $value -match '^[A-Za-z]:' -or $value -match '[\x00-\x1f\x7f]') { return '' }
    $parts = @($value -split '/' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return '' }
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..' -or $part -match '[\x00-\x1f\x7f]') { return '' }
    }
    $canonical = $parts -join '/'
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) { return (Get-BuildStringHash -Text $canonical) }
    # Fail closed rather than re-derive the hash. The inline copy this replaces
    # was how the cache-key hash ended up case-inconsistent with
    # CacheProvider's (lowercase here, uppercase there) - two spellings of one
    # cache key. A cache that cannot produce its canonical key must skip, not
    # invent a weaker one.
    return ''
}

function Enter-CacheIndexLock {
    [CmdletBinding()]
    param([string]$IndexPath, [int]$TimeoutMs = 15000)
    # Thin forward to the single acquisition owner. This function used to
    # re-implement the open/poll/sleep loop and CacheProvider carried a second
    # byte-equivalent copy under the SAME name, so both bypassed the shared
    # lock and evaluated the timeout only AFTER a failed attempt.
    # -ReturnNullOnEmptyPath preserves this caller's contract of $null rather
    # than a throw for an absent path; the difference is now stated once, here,
    # instead of being re-decided in two copies of the same function.
    return Enter-BuildFileLockOrThrow -Path $IndexPath -TimeoutMs $TimeoutMs -What 'cache index' -ReturnNullOnEmptyPath
}

function Save-CacheIndexAtomic {
    [CmdletBinding()]
    [OutputType([bool])]
    param([object]$Data, [string]$FilePath)
    # SharedUtils.Write-BuildJsonFile -Atomic owns this. The 18-line private
    # reimplementation this replaces duplicated the temp-name, Replace,
    # backup-delete and cleanup shape exactly.
    return [bool](Write-BuildJsonFile -Path $FilePath -Data $Data -Depth 10 -Atomic)
}

function Test-CacheOutputPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$OutputPath, [string[]]$AllowedRoots = @())
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($OutputPath)
        $contained = $true
        if ($AllowedRoots.Count -gt 0) {
            $contained = $false
            foreach ($allowed in $AllowedRoots) { try { $r = ([System.IO.Path]::GetFullPath($allowed)).TrimEnd('\', '/'); $cmp = Get-PathComparison; if ($full.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, $cmp)) { $contained = $true; break } } catch { } }
        }
        if (-not $contained) { return $false }
        # Reparse-point (junction/symlink) guard. Five sibling guards already do
        # this walk (Android.psm1, Deploy.psm1, DeployTargets.psm1,
        # Distributed.psm1, CacheProvider.psm1, Steps/publish-artifact.ps1) but
        # the CACHE guard - the one that gates paths later handed to
        # Invoke-SafeRemove -Recurse in Optimize-Cache - had none. A directory
        # junction planted inside an allowed root passed the string containment
        # check, was accepted as a valid cache output, and Optimize-Cache then
        # deleted through it. The guard itself now lives in PathUtils
        # (Test-NoReparsePointInPath) as the single owner.
        if (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue) {
            if (-not (Test-NoReparsePointInPath -Path $full)) { return $false }
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) { return (([System.IO.FileInfo]$full).Length -gt 0) }
        if (Test-Path -LiteralPath $full -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue)
            return ($files.Count -gt 0 -and (@($files | Where-Object { $_.Length -gt 0 }).Count -gt 0))
        }
        return $false
    } catch { return $false }
}

function Get-CacheIndexEntry {
    param([object]$Index, [string]$Key)
    if (-not $Index -or -not $Index.Entries) { return $null }
    $entries = $Index.Entries
    $canonical = Get-CanonicalCacheKey -Key $Key
    if ($entries -is [System.Collections.IDictionary]) {
        if ($canonical -and $entries.Contains($canonical)) { return $entries[$canonical] }
        $raw = $Key.Trim().Replace('\', '/')
        if ($entries.Contains($raw)) { return $entries[$raw] }
        return $null
    }
    if ($canonical) {
        $property = $entries.PSObject.Properties[$canonical]
        if ($property) { return $property.Value }
    }
    $raw = $Key.Trim().Replace('\', '/')
    $property = $entries.PSObject.Properties[$raw]
    if ($property) { return $property.Value }
    return $null
}

# -- BuildCache class (B1d): encapsulates cache root, index file, and stats --
class BuildCache {
    [string]   $CacheRoot
    [string]   $IndexPath
    [hashtable] $Stats
    [int]      $MaxSizeMB
    [string]   $ProjectRoot
    [string]   $ScriptRoot
    [string]   $TenantId
    # CONFIGURED cache-directory name (leaf of the caller's request, not of the
    # resolved path). Destructive ops compare the resolved root against it.
    [string]   $ConfiguredDirName

    BuildCache() {
        $this.Stats = @{ Hits = 0; Misses = 0; Invalidates = 0; Saves = 0; TotalSize = 0; Entries = 0 }
        $this.MaxSizeMB = Get-BuildConstant -Key 'MaxCacheSizeMB' -Fallback 2048
    }

    # Normalize a candidate root + cache dir into a supported absolute filesystem
    # path. Returns $null when the combination is not a valid path format (e.g.
    # provider-qualified or containing characters .NET rejects with
    # "The given path's format is not supported") so callers can fall back.
    [string] ResolveCachePath([string]$Root, [string]$CacheDir) {
        try {
            if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($CacheDir)) { return $null }
            $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
            $candidate = if ([System.IO.Path]::IsPathRooted($CacheDir)) { $CacheDir } else { Join-Path $rootFull $CacheDir }
            $full = [System.IO.Path]::GetFullPath($candidate)
            if ([string]::IsNullOrWhiteSpace($full)) { return $null }
            if ($full -eq [System.IO.Path]::GetPathRoot($full)) { return $null }
            $cmp = Get-PathComparison

            if (-not ($full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $cmp))) { return $null }
            if ($full.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { return $null }
            return $full
        } catch {
            return $null
        }
    }

    [string] Initialize([PSCustomObject]$State, [string]$CacheDir, [int]$MaxSizeMB) {
        $this.MaxSizeMB = $MaxSizeMB
        # Root-selection (ProjectRoot > ScriptRoot > cwd) single-sourced in PathUtils.
        # Level 5 resilience: class methods resolve commands in module scope, so a
        # missing/purged PathUtils (persistent session with several _Build copies,
        # swallowed import failure, facade flow) would fatal the whole build here.
        # Guard like CredentialVault/HotReload/SharedUtils do; fallback mirrors
        # Get-BuildRootDirectory semantics exactly (never extend — fix PathUtils).
        $root = $null
        if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
            try { $root = Get-BuildRootDirectory -State $State } catch { $root = $null }
        }
        if ([string]::IsNullOrWhiteSpace($root)) {
            if ($State -and $State.ProjectRoot) { $root = [string]$State.ProjectRoot }
            elseif ($State -and $State.ScriptRoot) { $root = [string]$State.ScriptRoot }
            else { $root = (Get-Location).ProviderPath }
        }
        $this.ProjectRoot = if ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } else { '' }
        $this.ScriptRoot = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { '' }
        $effectiveTenant = 'default'
        if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { $effectiveTenant = [string]$State.TenantId }
        if ($effectiveTenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $effectiveTenant -eq '.' -or $effectiveTenant -eq '..') {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.cache.invalidTenant' -Fallback '[CACHE] Invalid tenant identifier; cache disabled.') 'Err' $State }
            $this.CacheRoot = $null; $this.IndexPath = $null; return $null
        }
        $this.TenantId = $effectiveTenant
        $requestedCacheDir = $CacheDir
        if ($effectiveTenant -ne 'default') { $requestedCacheDir = Join-Path $requestedCacheDir $effectiveTenant }

        # Validate/normalize before touching the filesystem so an unsupported
        # path format degrades to a safe fallback instead of fataling the build.
        $cacheDirPath = $this.ResolveCachePath($root, $requestedCacheDir)
        if (-not $cacheDirPath) {
            # Guaranteed-valid fallback: a temp-scoped cache dir. The build
            # continues; cache is simply less effective across sessions.
            # Dir name single-sourced from BuildConstants.CacheDir.
            $cacheDirPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [string](Get-BuildConstant -Key 'CacheDir' -Fallback '.gbuildcache'))
            if ($effectiveTenant -ne 'default') { $cacheDirPath = Join-Path $cacheDirPath $effectiveTenant }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.cache.invalidPath' -MessageArgs @([string]("$root\$CacheDir"), $cacheDirPath) -Fallback '[CACHE] Invalid project cache path ''{0}''; using fallback: {1}') 'Warn' $State
            }
            $this.ConfiguredDirName = if ($effectiveTenant -ne 'default') { $effectiveTenant } else { Split-Path -Path $cacheDirPath.TrimEnd('\', '/') -Leaf }
        } else {
            $reqLeaf = ''
            try { $reqLeaf = Split-Path -Path ("$requestedCacheDir").TrimEnd('\', '/') -Leaf } catch { $reqLeaf = '' }
            if ($reqLeaf) { $this.ConfiguredDirName = $reqLeaf }
        }

        try {
            if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $cacheDirPath) } elseif (-not (Test-Path $cacheDirPath -PathType Container)) { New-Item -ItemType Directory -Path $cacheDirPath -Force -ErrorAction SilentlyContinue | Out-Null }
            $this.CacheRoot = $cacheDirPath
            $this.IndexPath = Join-Path $cacheDirPath 'index.json'
            if (-not (Test-Path -LiteralPath $this.IndexPath -PathType Leaf)) {
                $cacheVer = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'CacheIndexVersion' -Fallback '2.0' } else { '2.0' }
                $lock = Enter-CacheIndexLock -IndexPath $this.IndexPath
                if ($lock) {
                    try {
                        if (-not (Test-Path -LiteralPath $this.IndexPath -PathType Leaf)) { [void](Save-CacheIndexAtomic -Data @{ Version = $cacheVer; Entries = @{} } -FilePath $this.IndexPath) }
                    } finally { $lock.Dispose() }
                }
            }
            return $cacheDirPath
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.cache.initFailed' -MessageArgs @([string]$cacheDirPath, $_) -Fallback '[CACHE] Could not initialize cache at ''{0}'': {1}') 'Warn' $State
            }
            # Degrade gracefully: cache disabled, build proceeds without it.
            $this.CacheRoot = $null
            $this.IndexPath = $null
            return $null
        }
    }

    [string[]] GetOutputRoots() {
        $roots = [System.Collections.Generic.List[string]]::new()
        foreach ($value in @($this.CacheRoot, $this.ProjectRoot, $this.ScriptRoot)) {
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            try { $roots.Add(([System.IO.Path]::GetFullPath($value)).TrimEnd('\', '/')) } catch { }
        }
        return $roots.ToArray()
    }

    [object] GetEntry([string]$Key) {
        if (-not $this.IndexPath -or -not (Test-Path -LiteralPath $this.IndexPath -PathType Leaf)) { return $null }
        $lock = Enter-CacheIndexLock -IndexPath $this.IndexPath
        if (-not $lock) { return $null }
        try {
            $index = Read-JsonSafe -FilePath $this.IndexPath
            $entry = Get-CacheIndexEntry -Index $index -Key $Key
            if (-not $entry) { return $null }
            $outputPath = [string](Get-SectionValue -Section $entry -Key 'OutputPath' -Default '')
            if ($outputPath -and -not (Test-CacheOutputPath -OutputPath $outputPath -AllowedRoots $this.GetOutputRoots())) {
                $this.Stats.Invalidates++
                return $null
            }
            return $entry
        } finally { $lock.Dispose() }
    }

    [object] SaveEntry([string]$Key, [string]$ProjectHash, [string]$OutputPath, [hashtable]$Metadata) {
        if (-not $this.IndexPath) { return $null }
        $canonical = Get-CanonicalCacheKey -Key $Key
        if (-not $canonical) { return $null }
        if ($OutputPath -and $this.GetOutputRoots().Count -eq 0) { return $null }
        if ($OutputPath -and -not (Test-CacheOutputPath -OutputPath $OutputPath -AllowedRoots $this.GetOutputRoots())) { return $null }
        $lock = Enter-CacheIndexLock -IndexPath $this.IndexPath
        if (-not $lock) { return $null }
        try {
            $index = Read-JsonSafe -FilePath $this.IndexPath
            if (-not $index) {
                $version = '2.0'
                if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $version = [string](Get-BuildConstant -Key 'CacheIndexVersion' -Fallback '2.0') } catch { } }
                $index = [PSCustomObject]@{ Version = $version; Entries = [PSCustomObject]@{} }
            }
            if (-not $index.Entries) { $index | Add-Member -MemberType NoteProperty -Name Entries -Value ([PSCustomObject]@{}) -Force }
            $entry = [PSCustomObject]@{
                Hash       = $ProjectHash
                OutputPath = $OutputPath
                Metadata   = $Metadata
                CreatedAt  = (Get-Date).ToString('o')
                LastUsed   = (Get-Date).ToString('o')
                HitCount   = 0
            }
            if ($index.Entries -is [System.Collections.IDictionary]) { $index.Entries[$canonical] = $entry }
            elseif ($index.Entries.PSObject.Properties.Name -contains $canonical) { $index.Entries.$canonical = $entry }
            else { $index.Entries | Add-Member -MemberType NoteProperty -Name $canonical -Value $entry -Force }
            if (-not (Save-CacheIndexAtomic -Data $index -FilePath $this.IndexPath)) { return $null }
            $this.Stats.Saves++
            $this.Stats.Entries = @($index.Entries.PSObject.Properties).Count
            return $entry
        } finally { $lock.Dispose() }
    }

    [bool] IsValid([string]$Key, [string]$ProjectHash) {
        $canonical = Get-CanonicalCacheKey -Key $Key
        if (-not $canonical) { $this.Stats.Misses++; return $false }
        $entry = $this.GetEntry($Key)
        if (-not $entry) { $this.Stats.Misses++; return $false }
        if ([string]$entry.Hash -ne [string]$ProjectHash) { $this.Stats.Misses++; return $false }
        $outputPath = [string](Get-SectionValue -Section $entry -Key 'OutputPath' -Default '')
        if ($outputPath -and $this.GetOutputRoots().Count -eq 0) { $this.Stats.Misses++; return $false }
        if (-not (Test-CacheOutputPath -OutputPath $outputPath -AllowedRoots $this.GetOutputRoots())) { $this.Stats.Misses++; return $false }
        $lock = Enter-CacheIndexLock -IndexPath $this.IndexPath
        if (-not $lock) { $this.Stats.Misses++; return $false }
        try {
            $index = Read-JsonSafe -FilePath $this.IndexPath
            $current = Get-CacheIndexEntry -Index $index -Key $canonical
            if (-not $current -or [string]$current.Hash -ne [string]$ProjectHash -or -not (Test-CacheOutputPath -OutputPath ([string]$current.OutputPath) -AllowedRoots $this.GetOutputRoots())) { $this.Stats.Misses++; return $false }
            $current.HitCount = [int](Get-SectionValue -Section $current -Key 'HitCount' -Default 0) + 1
            $current.LastUsed = (Get-Date).ToString('o')
            if ($index.Entries -is [System.Collections.IDictionary]) { $index.Entries[$canonical] = $current }
            else { $index.Entries.$canonical = $current }
            if (-not (Save-CacheIndexAtomic -Data $index -FilePath $this.IndexPath)) { $this.Stats.Misses++; return $false }
            $this.Stats.Hits++
            return $true
        } finally { $lock.Dispose() }
    }

    [hashtable] GetStatistics() {
        if (-not $this.IndexPath -or -not (Test-Path $this.IndexPath)) {
            return @{ Hits = 0; Misses = 0; Invalidates = 0; Saves = 0; TotalSize = 0; Entries = 0; HitRatio = 'N/A' }
        }
        $index = Read-JsonSafe -FilePath $this.IndexPath
        $entryCount = 0
        $totalSize  = 0
        if ($index -and $index.Entries) {
            $entryCount = $index.Entries.PSObject.Properties.Count
            foreach ($prop in $index.Entries.PSObject.Properties) {
                $entry = $prop.Value
                $entryOutput = [string](Get-SectionValue -Section $entry -Key 'OutputPath' -Default '')
                if (Test-CacheOutputPath -OutputPath $entryOutput -AllowedRoots $this.GetOutputRoots()) {
                    $size = (Get-ChildItem -LiteralPath $entryOutput -Recurse -File -EA SilentlyContinue |
                             Measure-Object -Property Length -Sum).Sum
                    $totalSize += $size
                }
            }
        }
        $total = $this.Stats.Hits + $this.Stats.Misses
        $hitRatio = if ($total -gt 0) { "$([math]::Round($this.Stats.Hits / $total * 100, 1))%" } else { 'N/A' }
        return @{
            Hits        = $this.Stats.Hits
            Misses      = $this.Stats.Misses
            Invalidates = $this.Stats.Invalidates
            Saves       = $this.Stats.Saves
            TotalSize   = $totalSize
            TotalSizeMB = [math]::Round($totalSize / 1MB, 2)
            Entries     = $entryCount
            HitRatio    = $hitRatio
            CacheRoot   = $this.CacheRoot
        }
    }

    # Safety gate for destructive operations on the cache root. Returns $true
    # only when the RESOLVED root really is the configured cache directory:
    #   1) not a filesystem/drive root ("C:\", "/", UNC share root);
    #   2) its leaf name matches the CONFIGURED cache-directory name;
    #   3) it sits STRICTLY under the project/script root or the machine temp
    #      path — never equal to or an ancestor of them.
    # Blocks config values like '..' or absolute foreign paths from wiping
    # unintended trees (anchored comparisons mirror Test-SafePath).
    [bool] IsDeletionSafe([PSCustomObject]$State) {
        if (-not $this.CacheRoot) { return $false }
        try {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $cmp = Get-PathComparison
            $resolved = [System.IO.Path]::GetFullPath($this.CacheRoot)
            if ($resolved -eq [System.IO.Path]::GetPathRoot($resolved)) { return $false }
            $trimmed = $resolved.TrimEnd('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($this.ConfiguredDirName)) {
                $leaf = Split-Path -Path $trimmed -Leaf
                if (-not $leaf.Equals($this.ConfiguredDirName, $cmp)) { return $false }
            }
            $anchors = [System.Collections.Generic.List[string]]::new()
            foreach ($pn in @('ProjectRoot', 'ScriptRoot')) {
                if ($State -and ($State.PSObject.Properties.Name -contains $pn) -and $State.$pn) {
                    $a = ([System.IO.Path]::GetFullPath([string]$State.$pn)).TrimEnd('\', '/')
                    if ($a) { $anchors.Add($a) }
                }
            }
            $tempAnchor = ([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())).TrimEnd('\', '/')
            if ($tempAnchor) { $anchors.Add($tempAnchor) }
            foreach ($anchor in $anchors) {
                if (-not $anchor) { continue }
                if ($trimmed -eq $anchor) { return $false }
                # Resolved is an ANCESTOR of the anchor => absolutely forbidden.
                if ($anchor.StartsWith($trimmed + $sep, $cmp)) { return $false }
                # Strictly under a safe anchor => allowed.
                if ($trimmed.StartsWith($anchor + $sep, $cmp)) { return $true }
            }
            return $false
        } catch {
            return $false
        }
    }

    [bool] ClearCache([bool]$Force, [PSCustomObject]$State) {
        if (-not $this.CacheRoot) { return $false }
        # Containment gate: refuse to wipe anything that fails the safety check
        # (a config value of '..' or an absolute foreign path must never delete
        # unintended trees).
        if (-not $this.IsDeletionSafe($State)) {
            Write-Log (Resolve-LogMessage -Key 'log.cache.deleteRefused' -MessageArgs @([string]$this.CacheRoot) -Fallback '[CACHE] Refusing to delete ''{0}'': resolved cache root failed the deletion safety check.') 'Err' $State
            return $false
        }
        if (Test-Path $this.CacheRoot) {
            Invoke-SafeRemove -Path $this.CacheRoot -Recurse -Force
        }
        $this.Stats.Hits        = 0
        $this.Stats.Misses      = 0
        $this.Stats.Invalidates = 0
        $this.Stats.Saves       = 0
        $this.Stats.Entries     = 0
        Write-Log (Get-LocaleMessage -Key 'log.cache.cleared' -Fallback '? Cache cleared!') "Succ" $State
        return $true
    }

    [void] Optimize([int]$MaxSizeMB, [PSCustomObject]$State) {
        if (-not $this.CacheRoot -or -not (Test-Path $this.CacheRoot)) { return }
        $lock = Enter-CacheIndexLock -IndexPath $this.IndexPath
        if (-not $lock) { return }
        try {
        $snap = $this.GetStatistics()
        if ($snap.TotalSizeMB -le $MaxSizeMB) {
            Write-Log (Get-LocaleMessage -Key 'log.cache.sizeOk' -MessageArgs @([string]$snap.TotalSizeMB, [string]$MaxSizeMB) -Fallback "? [Cache] Size OK ($($snap.TotalSizeMB)MB / ${MaxSizeMB}MB)") "Succ" $State
            return
        }
        Write-Log (Get-LocaleMessage -Key 'log.cache.sizeExceeds' -MessageArgs @([string]$snap.TotalSizeMB, [string]$MaxSizeMB) -Fallback "??  [Cache] Size exceeds limit ($($snap.TotalSizeMB)MB > ${MaxSizeMB}MB). Cleaning LRU...") "Warn" $State
        $index = Read-JsonSafe -FilePath $this.IndexPath
        if (-not $index -or -not $index.Entries) { return }
        $entries = @()
        foreach ($prop in $index.Entries.PSObject.Properties) {
            $entries += [PSCustomObject]@{
                Key      = $prop.Name
                LastUsed = [datetime]$prop.Value.LastUsed
                Size     = if (Test-CacheOutputPath -OutputPath ([string](Get-SectionValue -Section $prop.Value -Key 'OutputPath' -Default '')) -AllowedRoots $this.GetOutputRoots()) {
                    (Get-ChildItem -LiteralPath ([string](Get-SectionValue -Section $prop.Value -Key 'OutputPath' -Default '')) -Recurse -File -EA SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } else { 0 }
            }
        }
        $entries = $entries | Sort-Object LastUsed
        $currentSize = $snap.TotalSize
        # Eviction target ratio single-sourced from BuildConstants.CacheEvictTargetRatio.
        $evictRatio = [double](Get-BuildConstant -Key 'CacheEvictTargetRatio' -Fallback 0.8)
        $targetSize = $MaxSizeMB * 1MB * $evictRatio
        $removed = 0
        foreach ($entry in $entries) {
            if ($currentSize -le $targetSize) { break }
            $rawEntry = $index.Entries.PSObject.Properties[$entry.Key]
            if (-not $rawEntry) { continue }
            $outPath = if ($rawEntry.Value.OutputPath) { [string]$rawEntry.Value.OutputPath } else { '' }
            $outputExists = ($outPath -and (Test-Path -LiteralPath $outPath))
            # Evict live entries (free space) AND dead rows whose output already
            # vanished (index hygiene — previously they stayed forever).
            if (($entry.Size -gt 0) -or (-not $outputExists)) {
                # Delete the evicted entry's output tree, but ONLY when it lives
                # strictly under the cache root: old index rows may reference
                # foreign absolute paths that must never be touched.
                if ($outputExists -and (Get-Command Invoke-SafeRemove -ErrorAction SilentlyContinue)) {
                    $outFull = try { [System.IO.Path]::GetFullPath($outPath).TrimEnd('\', '/') } catch { '' }
                    $cacheFull = [System.IO.Path]::GetFullPath($this.CacheRoot).TrimEnd('\', '/')
                    if ($outFull -and ($outFull -ne $cacheFull)) {
                        Invoke-SafeRemove -Path $outPath -AllowedRoots @($this.CacheRoot) -Recurse -Force
                    }
                }
                $index.Entries.PSObject.Properties.Remove($entry.Key)
                $currentSize -= $entry.Size
                $removed++
            }
        }
        if (-not (Save-CacheIndexAtomic -Data $index -FilePath $this.IndexPath)) { return }
        Write-Log (Get-LocaleMessage -Key 'log.cache.removedStale' -MessageArgs @([string]$removed) -Fallback "? [Cache] Removed $removed stale entries") "Succ" $State
        } finally {
            if ($lock) { try { $lock.Dispose() } catch { } }
        }
    }
}

$script:BuildCache = [BuildCache]::new()
$script:DefaultConfig = @{
    CacheDirectory = Get-BuildConstant -Key 'CacheDir' -Fallback '.gbuildcache'
    MaxCacheSizeMB = Get-BuildConstant -Key 'MaxCacheSizeMB' -Fallback 2048
}

function Ensure-BuildCacheForState {
    param([PSCustomObject]$State)
    $tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
    $project = if ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } else { '' }
    $scriptRoot = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { '' }
    $needs = -not $script:BuildCache.CacheRoot -or $script:BuildCache.TenantId -ne $tenant
    if (-not $needs) {
        try {
            $currentProject = if ($script:BuildCache.ProjectRoot) { [System.IO.Path]::GetFullPath($script:BuildCache.ProjectRoot) } else { '' }
            $currentScript = if ($script:BuildCache.ScriptRoot) { [System.IO.Path]::GetFullPath($script:BuildCache.ScriptRoot) } else { '' }
            $requestedProject = if ($project) { [System.IO.Path]::GetFullPath($project) } else { '' }
            $requestedScript = if ($scriptRoot) { [System.IO.Path]::GetFullPath($scriptRoot) } else { '' }
            if ($requestedProject -ne $currentProject -or $requestedScript -ne $currentScript) { $needs = $true }
        } catch { $needs = $true }
    }
    if ($needs) { return (Initialize-BuildCache -State $State) }
    return $script:BuildCache.CacheRoot
}

# -- Initialize cache ------------------------------------------------------------
function Initialize-BuildCache {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$CacheDir = '',
        # Default 0 = resolve from config in the body. Get-BuildDefault takes no
        # -State, so the previous parameter default ignored gbuild.config.json
        # entirely and build.maxCacheSizeMB had no effect.
        [int]$MaxSizeMB = 0
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir)) { $CacheDir = [string](Get-BuildConstant -Key 'CacheDir' -State $State -Fallback '.gbuildcache') }
    if ($MaxSizeMB -le 0) { $MaxSizeMB = [int](Get-BuildConstant -Key 'MaxCacheSizeMB' -State $State -Fallback 2048) }
    return $script:BuildCache.Initialize($State, $CacheDir, $MaxSizeMB)
}

# -- Compute hash of a file or set of files ------------------------------------------
function Get-FileHashFast {
    param([string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $combined = [System.IO.MemoryStream]::new()
    try {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $Paths) {
            if ([string]::IsNullOrWhiteSpace($p) -or -not [System.IO.File]::Exists($p)) { return $null }
            try {
                $full = [System.IO.Path]::GetFullPath($p)
                $items.Add([PSCustomObject]@{ Path = $full; Length = ([System.IO.FileInfo]$full).Length })
            } catch { return $null }
        }
        foreach ($item in @($items | Sort-Object Path)) {
            $nameBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$item.Path)
            $combined.Write($nameBytes, 0, $nameBytes.Length)
            $combined.WriteByte(0xFF)
            $lengthBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$item.Length)
            $combined.Write($lengthBytes, 0, $lengthBytes.Length)
            $combined.WriteByte(0xFE)
            $stream = [System.IO.File]::OpenRead([string]$item.Path)
            try { $stream.CopyTo($combined) } finally { $stream.Dispose() }
            $combined.WriteByte(0xFF)
        }
        $combined.Position = 0
        $hashBytes = $sha.ComputeHash($combined)
        # Lowercase, to match every other hash in this system. This function
        # emitted UPPERCASE while CacheProvider's and PluginHelpers' sibling
        # digests emitted lowercase, so the same content hashed to two different
        # cache keys depending on which module asked - the exact defect recorded
        # in Get-BuildStringHash's doc. Switching case invalidates existing
        # cache entries ONCE (they are content-addressed, so they repopulate);
        # leaving it inconsistent would keep invalidating them forever.
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } catch { return $null }
    finally {
        $sha.Dispose()
        $combined.Dispose()
    }
}

# -- Compute recursive hash for a project directory -----------------------------------
function Get-ProjectHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectPath,
        [string[]]$IncludeExtensions = @('.cs', '.csproj', '.config', '.json', '.razor', '.cshtml', '.js', '.ts', '.props', '.targets',
            '.xaml', '.axaml', '.resx', '.svg', '.css', '.scss', '.html', '.vue', '.jsx', '.tsx', '.fs', '.fsproj', '.vbproj',
            # Non-dotnet sources: an edit must invalidate the cache (no stale HIT).
            '.py', '.rs', '.go', '.java', '.kt', '.kts', '.scala', '.sbt', '.rb', '.php', '.c', '.h', '.cpp', '.hpp',
            '.swift', '.ex', '.exs', '.gradle', '.ps1', '.psm1', '.psd1', '.sln',
            # MAUI / mobile assets: must invalidate cache when images/audio/fonts change
            '.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.ico', '.mp3', '.wav', '.m4a', '.ogg', '.mp4',
            '.ttf', '.otf', '.woff', '.woff2', '.eot', '.plist', '.entitlements', '.txt', '.csv', '.sqlite', '.db')
    )
    if (-not ([System.IO.File]::Exists($ProjectPath))) { return $null }
    $projectDir = Split-Path $ProjectPath -Parent
    $hashInput  = [System.Collections.Generic.List[string]]::new()
    $hashInput.Add($ProjectPath)
    $scanFailed = $false
    # Level 5 single-source: CacheHashSearchDepth (build.cache.hashDepth).
    $hashDepth = 5
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $hashDepth = [int](Get-BuildConstant -Key 'CacheHashSearchDepth' -Fallback 5) } catch { $hashDepth = 5 }
    }
    $hashExcludeDirs = @(Get-SyntaxCheckExcludeDirs)
    # Degraded fallback when the shared owner is unavailable. It must MIRROR
    # BuildConstants.SyntaxCheckExcludeDirs exactly - it was missing '.tools', so
    # on any host where Get-SyntaxCheckExcludeDirs could not be loaded the
    # incremental cache key was computed over the vendored analyzer tree and
    # changed for edits that had nothing to do with the project.
    if ($hashExcludeDirs.Count -eq 0) { $hashExcludeDirs = @('obj','bin','.git','node_modules','TestResults','publish-output','.gbuildcache','build-reports','logs','_Build','.tools') }
    try {
        if (Get-Command Get-BoundedProjectFiles -ErrorAction SilentlyContinue) {
            $files = @(Get-BoundedProjectFiles -Root $projectDir -Depth $hashDepth -ExcludeDirs $hashExcludeDirs -File)
        } else {
            $files = Invoke-CompatibleChildItem -Path $projectDir -Recurse -File -Depth $hashDepth -ErrorAction Stop
        }
    } catch {
        Write-Warning (Resolve-LogMessage -Key 'log.cache.hashScanFailed' -MessageArgs @([string]$projectDir, [string]$_) -Fallback '[Cache] Failed to scan {0} for hash: {1}')
        $scanFailed = $true
        $files = $null
    }
    if ($scanFailed) { return $null }
    if ($files) {
        foreach ($file in $files) {
            if ($file.Extension -in $IncludeExtensions) {
                $hashInput.Add($file.FullName)
            }
        }
    }
    if ($hashInput.Count -eq 0) { return $null }
    return Get-FileHashFast -Paths $hashInput
}

# -- Compute recursive hash for a directory (plugin path: no single project file) --
function Get-DirectoryHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Directory,
        [string[]]$IncludeExtensions = @(
            '.cs', '.csproj', '.fsproj', '.vbproj', '.config', '.json', '.razor', '.cshtml',
            '.js', '.ts', '.tsx', '.jsx', '.vue', '.props', '.targets',
            '.rs', '.go', '.py', '.toml', '.yaml', '.yml', '.xml', '.html', '.css', '.scss', '.sass',
            '.java', '.kt', '.kts', '.scala', '.swift', '.sbt', '.ex', '.exs', '.gradle', '.groovy',
            '.c', '.h', '.cpp', '.hpp', '.cxx', '.hxx', '.cc', '.rb', '.php', '.twig', '.dart', '.dockerfile',
            '.ps1', '.psm1', '.psd1'
        )
    )
    if (-not ([System.IO.Directory]::Exists($Directory))) { return $null }
    $hashInput = [System.Collections.Generic.List[string]]::new()
    $scanFailed = $false
    $nameOnly = @('Dockerfile', 'Gemfile', 'Makefile', 'go.mod', 'go.sum',
                  'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'poetry.lock',
                  'Pipfile', 'Pipfile.lock', 'CMakeLists.txt', 'composer.lock', 'Gemfile.lock')
    # Level 5 single-source: CacheHashSearchDepth (build.cache.hashDepth).
    $dirHashDepth = 5
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $dirHashDepth = [int](Get-BuildConstant -Key 'CacheHashSearchDepth' -Fallback 5) } catch { $dirHashDepth = 5 }
    }
    $dirExcludeDirs = @(Get-SyntaxCheckExcludeDirs) + @('target','dist','.venv','venv','__pycache__','vendor') | Where-Object { $_ } | Select-Object -Unique
    try {
        if (Get-Command Get-BoundedProjectFiles -ErrorAction SilentlyContinue) {
            $files = @(Get-BoundedProjectFiles -Root $Directory -Depth $dirHashDepth -ExcludeDirs $dirExcludeDirs -File)
        } else {
            $files = Invoke-CompatibleChildItem -Path $Directory -Recurse -File -Depth $dirHashDepth
        }
    } catch {
        Write-Warning (Resolve-LogMessage -Key 'log.cache.hashScanFailed' -MessageArgs @([string]$Directory, [string]$_) -Fallback '[Cache] Failed to scan {0} for hash: {1}')
        $scanFailed = $true
        $files = $null
    }
    if ($scanFailed) { return $null }
    if ($files) {
        foreach ($file in $files) {
            if ($file.Extension -in $IncludeExtensions -or $file.Name -in $nameOnly) {
                $hashInput.Add($file.FullName)
            }
        }
    }
    if ($hashInput.Count -eq 0) { return $null }
    return Get-FileHashFast -Paths $hashInput
}

# -- Get cache entry -----------------------------------------------------------
function Get-CacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Key)
    return $script:BuildCache.GetEntry($Key)
}

# -- Save cache entry -----------------------------------------------------------
function Save-CacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$ProjectHash,
        [string]$OutputPath = '',
        [hashtable]$Metadata = @{}
    )
    return $script:BuildCache.SaveEntry($Key, $ProjectHash, $OutputPath, $Metadata)
}

# -- Check whether cache is valid -------------------------------------------
function Test-CacheValid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$ProjectHash
    )
    return $script:BuildCache.IsValid($Key, $ProjectHash)
}

# -- Remove a single cache entry (per-key invalidation) -----------------------
<#
.SYNOPSIS
    Removes ONE cache entry by key (index-only; build outputs on disk are kept).
.DESCRIPTION
    Used by the stale-artifact guard in Build.psm1: when a cache hit points at
    an output directory that no longer contains artifacts, the entry must be
    invalidated so the next run rebuilds. Unlike Clear-BuildCache this never
    touches other entries and never prompts.
#>
function Remove-CacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Key)
    if (-not $script:BuildCache.CacheRoot) { return $false }
    $canonical = Get-CanonicalCacheKey -Key $Key
    if (-not $canonical) { return $false }
    $lock = Enter-CacheIndexLock -IndexPath $script:BuildCache.IndexPath
    if (-not $lock) { return $false }
    try {
        $index = Read-JsonSafe -FilePath $script:BuildCache.IndexPath
        $entry = Get-CacheIndexEntry -Index $index -Key $canonical
        if (-not $entry) { return $false }
        if ($index.Entries -is [System.Collections.IDictionary]) { $index.Entries.Remove($canonical) }
        else { $index.Entries.PSObject.Properties.Remove($canonical) }
        return [bool](Save-CacheIndexAtomic -Data $index -FilePath $script:BuildCache.IndexPath)
    } finally { $lock.Dispose() }
}

# -- Build wrapper with cache ---------------------------------------------------
<#
.SYNOPSIS
    Single write-path for a successful build: saves the cache entry AND the
    per-project content fingerprint used by Get-AffectedProjects.
    Shared by Invoke-BuildWithCache and Build.psm1 (avoids double hashing:
    callers compute Get-ProjectHash once and pass it here).
#>
function Save-BuildCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$ProjectHash,
        [string]$OutputPath = '',
        [hashtable]$Metadata = @{},
        [string]$ProjectPath = ''
    )
    $savedEntry = Save-CacheEntry -Key $Key -ProjectHash $ProjectHash -OutputPath $OutputPath -Metadata $Metadata
    if ($ProjectPath) {
        $projFingerprintKey = 'proj-' + ([System.IO.Path]::GetFullPath($ProjectPath) -replace '[^A-Za-z0-9]', '_')
        Save-CacheEntry -Key $projFingerprintKey -ProjectHash $ProjectHash | Out-Null
    }
    if ($savedEntry) { Write-Log (Get-LocaleMessage -Key 'log.cache.savedEntry' -MessageArgs @([string]$Key) -Fallback "?? [Cache] Saved entry (key: $Key)") 'Succ' }
    else { Write-Log (Resolve-LogMessage -Key 'log.cache.entryNotSaved' -Fallback '[Cache] Entry was not saved because its output is missing or invalid.') 'Warn' }
    return $savedEntry
}

<#
.SYNOPSIS
    Returns $true only when remote-cache sync for the given direction is actually
    enabled: State present, CacheProvider loaded, build.cacheRemote Enabled, and
    the matching syncOnBuild/syncOnRestore flag set. Anything missing (CacheProvider
    not loaded / remote disabled / flag off / no State) → $false, a safe no-op.
    This is what activates the previously parsed-but-never-consumed config keys.
#>
function Test-RemoteCacheSyncEnabled {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory = $true)]
        [ValidateSet('SyncOnBuild', 'SyncOnRestore')]
        [string]$Flag
    )
    if (-not $State) { return $false }
    $cmd = Get-Command Get-RemoteCacheConfig -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $cfg = Get-RemoteCacheConfig -State $State
        if (-not $cfg) { return $false }
        if (-not $cfg.Enabled) { return $false }
        return [bool]$cfg.$Flag
    } catch {
        return $false
    }
}

function Test-CacheBuildResult {
    param([object]$Result)
    if ($null -eq $Result -or $Result -is [bool]) { return [bool]$Result }
    if ($Result -is [System.Collections.IDictionary]) {
        if ($Result.Contains('Success')) { return [bool]$Result['Success'] }
        if ($Result.Contains('Status')) { return ([string]$Result['Status'] -eq 'Succeeded') }
    } else {
        if ($Result.PSObject.Properties.Name -contains 'Success') { return [bool]$Result.Success }
        if ($Result.PSObject.Properties.Name -contains 'Status') { return ([string]$Result.Status -eq 'Succeeded') }
    }
    return $true
}

function Invoke-BuildWithCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [Parameter(Mandatory=$true)][string]$CacheKey,
        [Parameter(Mandatory=$true)][scriptblock]$BuildAction,
        [hashtable]$Metadata = @{},
        [PSCustomObject]$State,
        # Callers that already computed Get-ProjectHash for their pre-check pass it
        # here — prevents the double recursive SHA256 scan per build (single hash flow).
        [string]$PrecomputedHash = '',
        # Extra metadata merged into the saved entry (e.g. BuiltAt from the caller).
        [hashtable]$BuildMetadata = @{}
    )

    Ensure-BuildCacheForState -State $State | Out-Null

    if ($PrecomputedHash) {
        $projectHash = $PrecomputedHash
    } else {
        Write-Log (Get-LocaleMessage -Key 'log.cache.computingHash' -Fallback '?? [Cache] Computing project hash...') "Gray" $State
        $projectHash = Get-ProjectHash -ProjectPath $ProjectPath
    }
    if (-not $projectHash) {
        Write-Log (Get-LocaleMessage -Key 'log.cache.cannotCompute' -Fallback '??  [Cache] Cannot compute hash. Skipping cache.') "Warn" $State
        return & $BuildAction
    }

    $shortLen = 8
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $shortLen = [int](Get-BuildConstant -Key 'ShortHashLength' -State $State -Fallback 8) } catch { $shortLen = 8 }
    }
    if ($shortLen -lt 4) { $shortLen = 4 }
    if ($shortLen -gt $projectHash.Length) { $shortLen = $projectHash.Length }
    $shortHash = $projectHash.Substring(0, $shortLen)
    Write-Log (Get-LocaleMessage -Key 'log.cache.hash' -MessageArgs @([string]$shortHash) -Fallback "?? [Cache] Hash: $shortHash") "Gray" $State

    if (Test-CacheValid -Key $CacheKey -ProjectHash $projectHash) {
        $entry = Get-CacheEntry -Key $CacheKey
        Write-Log (Get-LocaleMessage -Key 'log.cache.hit' -MessageArgs @([string]$entry.CreatedAt) -Fallback "? [Cache] HIT! Skip build (reused from $($entry.CreatedAt)) - code unchanged; edit .cs/.xaml/.json will be MISS, use -CacheClear to force") "Succ" $State
        return @{
            Cached   = $true
            Hash     = $projectHash
            Output   = $entry.OutputPath
            Metadata = $entry.Metadata
        }
    }

    Write-Log (Get-LocaleMessage -Key 'log.cache.miss' -Fallback '? [Cache] MISS. Running build...') "Info" $State

    # syncOnRestore: pull remote entries into the local cache first, so a miss may
    # become a hit without running the build. No-op unless CacheProvider is loaded
    # AND build.cacheRemote is enabled with syncOnRestore=true.
    if ((Test-RemoteCacheSyncEnabled -State $State -Flag 'SyncOnRestore') -and (Get-Command Update-CacheToLocal -ErrorAction SilentlyContinue)) {
        $null = Update-CacheToLocal -State $State
        # HA posture gate. Test-CacheHAFailoverPosture (and through it
        # Invoke-HAFailoverCheck / Invoke-HAFailbackCheck) was exported, tested
        # and never called - its own docstring claimed "called once per build
        # from the cache sync path", which was false, so
        # build.cacheRemote.ha.failover.* was inert in practice. Advisory only:
        # it never fails a build, it names the region that would take over.
        if (Get-Command Test-CacheHAFailoverPosture -ErrorAction SilentlyContinue) {
            try { $null = Test-CacheHAFailoverPosture -State $State } catch { }
        }
        if (Test-CacheValid -Key $CacheKey -ProjectHash $projectHash) {
            $entry = Get-CacheEntry -Key $CacheKey
            Write-Log (Get-LocaleMessage -Key 'log.cache.hit' -MessageArgs @([string]$entry.CreatedAt) -Fallback "? [Cache] HIT (remote sync)! Skip build (reused from $($entry.CreatedAt))") "Succ" $State
            return @{
                Cached   = $true
                Hash     = $projectHash
                Output   = $entry.OutputPath
                Metadata = $entry.Metadata
            }
        }
    }

    $result = & $BuildAction

    if (Test-CacheBuildResult -Result $result) {
        # A string BuildAction result is an OUTPUT PATH only when it actually
        # resolves to a non-empty artifact under an allowed root. Anything else
        # ('ok', a status token, a bare name) is a result marker, not a path.
        # Treating every string as a path made $canSave false for non-path
        # results, which silently skipped BOTH the artifact entry and the
        # per-project fingerprint - leaving Get-AffectedProjects permanently
        # cold and the build cache at a 0% hit rate forever.
        $candidate = if ($result -is [string]) { $result } else { [string](Get-SectionValue -Section $result -Key 'OutputPath' -Default '') }
        $outputPath = ''
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-CacheOutputPath -OutputPath $candidate -AllowedRoots $script:BuildCache.GetOutputRoots())) {
            $outputPath = $candidate
        }
        $saveMeta = @{}
        foreach ($k in @($Metadata.Keys)) { $saveMeta[$k] = $Metadata[$k] }
        foreach ($k in @($BuildMetadata.Keys)) { $saveMeta[$k] = $BuildMetadata[$k] }
        # The fingerprint is a separate concern from artifact output: record it on
        # EVERY successful build so affected-detection warms up even for builds
        # that emit no cacheable artifact. Only the recorded OutputPath is
        # subject to the containment guard above.
        $saved = Save-BuildCacheEntry -Key $CacheKey -ProjectHash $projectHash -OutputPath $outputPath -Metadata $saveMeta -ProjectPath $ProjectPath
        if ($saved -and (Test-RemoteCacheSyncEnabled -State $State -Flag 'SyncOnBuild') -and (Get-Command Update-CacheToRemote -ErrorAction SilentlyContinue)) {
            $null = Update-CacheToRemote -State $State
        }
    }
    return $result
}

# -- Cache statistics ----------------------------------------------------------
function Get-CacheStatistics {
    return $script:BuildCache.GetStatistics()
}

function Show-CacheStats {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $stats = Get-CacheStatistics
    Write-SectionBox "?? CACHE STATISTICS" -Color "Info" -State $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statRoot' -MessageArgs @([string]$stats.CacheRoot) -Fallback "  ?? Cache root: $($stats.CacheRoot)") 'Info' $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statEntries' -MessageArgs @([string]$stats.Entries) -Fallback "  ?? Entries   : $($stats.Entries)") 'Info' $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statSize' -MessageArgs @([string]$stats.TotalSizeMB) -Fallback "  ?? Size      : $($stats.TotalSizeMB) MB") 'Info' $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statHits' -MessageArgs @([string]$stats.Hits) -Fallback "  ? Hits      : $($stats.Hits)") 'Succ' $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statMisses' -MessageArgs @([string]$stats.Misses) -Fallback "  ? Misses    : $($stats.Misses)") 'Warn' $State
    Write-Log (Get-LocaleMessage -Key 'log.cache.statHitRatio' -MessageArgs @([string]$stats.HitRatio) -Fallback "  ?? Hit ratio : $($stats.HitRatio)") 'Info' $State
}

# -- Cache cleanup -------------------------------------------------------------
function Clear-BuildCache {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$State,
        [switch]$Force
    )
    Ensure-BuildCacheForState -State $State | Out-Null
    if (-not $Force) {
        $stats = Get-CacheStatistics
        Write-Log ' ' 'Detail' $State
        Write-Log (Get-LocaleMessage -Key 'log.cache.confirmDelete' -Fallback '  ??  You are about to delete all build cache:') 'Warn' $State
        Write-Log (Get-LocaleMessage -Key 'log.cache.confirmPath' -MessageArgs @([string]$stats.CacheRoot) -Fallback "     ?? Path : $($stats.CacheRoot)") 'Gray' $State
        Write-Log (Get-LocaleMessage -Key 'log.cache.confirmSize' -MessageArgs @([string]$stats.TotalSizeMB) -Fallback "     ?? Size : $($stats.TotalSizeMB) MB") 'Gray' $State
        Write-Log (Get-LocaleMessage -Key 'log.cache.confirmEntries' -MessageArgs @([string]$stats.Entries) -Fallback "     ?? Entries: $($stats.Entries)") 'Gray' $State
        Write-Log ' ' 'Detail' $State
        $confirm = Read-Host "  Type 'YES' to confirm deletion"
        if ($confirm -ne 'YES') {
            Write-Log (Get-LocaleMessage -Key 'log.cache.cancelled' -Fallback '? Cancelled.') "Warn" $State
            return
        }
    }
    if ($PSCmdlet.ShouldProcess("Cache at $($script:BuildCache.CacheRoot)", "Delete all cache")) {
        $cleared = $script:BuildCache.ClearCache($true, $State)
        if (-not $cleared) {
            Write-Log (Resolve-LogMessage -Key 'log.cache.clearRefused' -Fallback '[CACHE] Cache clear refused (resolved cache root failed the deletion safety check).') 'Err' $State
        }
    }
}

# -- Cache size limit enforcement ----------------------------------------------
function Optimize-Cache {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        # Default 0 = resolve from config inside the body. The parameter default
        # used to call Get-BuildDefault, which takes NO -State and therefore
        # never sees gbuild.config.json - so build.maxCacheSizeMB was dead on
        # the live path even though it is a shipped, documented key.
        [int]$MaxSizeMB = 0
    )
    if ($MaxSizeMB -le 0) { $MaxSizeMB = [int](Get-BuildConstant -Key 'MaxCacheSizeMB' -State $State -Fallback 2048) }
    $script:BuildCache.Optimize($MaxSizeMB, $State)
    # Also apply the blob-level LRU / age / size policy owned by CacheProvider.
    # It was dead code with zero production callers, which left
    # build.cacheLocal.{maxEntries,maxAgeDays,maxSizeMb} unread even though all
    # three are shipped in gbuild.config.json. Best-effort: a missing or
    # disabled CacheProvider must never fail a build.
    try {
        if (Get-Command Invoke-UnifiedCacheEviction -ErrorAction SilentlyContinue) {
            Invoke-UnifiedCacheEviction -State $State -MaxSizeMB $MaxSizeMB | Out-Null
        }
    } catch { }
}

<#
.SYNOPSIS
    Returns a new BuildCache instance (OOP core factory, B1d/B4).
#>
function Get-BuildCache {
    return [BuildCache]::new()
}

<#
.SYNOPSIS
    Nx-style affected-project detection using content fingerprints + git diff.
.DESCRIPTION
    For each project file, computes a content fingerprint (Get-ProjectHash) and
    compares it against the persisted per-project fingerprint (saved by the normal
    build-cache write-path in Invoke-BuildWithCache). A project is "affected" when:
      - no cached fingerprint exists (first run / cache cleared), or
      - the current fingerprint differs from the cached one, or
      - (git mode) a working-tree/committed change touches the project directory or
        a shared root build file (Directory.Build.props, Directory.Build.targets,
        Directory.Packages.props, global.json).
    The function is read-only: it never writes fingerprints, so a failed build never
    produces a false "unchanged".
#>
function Get-AffectedProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ProjectFiles,
        [string]$SinceRef = 'HEAD',
        [switch]$SkipGitDiff,
        [PSCustomObject]$State
    )

    $existing = @($ProjectFiles | Where-Object { $_ -and [System.IO.File]::Exists($_) })
    if ($existing.Count -eq 0) {
        return [PSCustomObject]@{
            Affected     = [string[]]@()
            Unchanged    = [string[]]@()
            ChangedFiles = [string[]]@()
            Mode         = 'None'
            RepoRoot     = $null
        }
    }

    # -- 1) Locate the git repository root (shared by all project files) --
    $repoRoot = $null
    $probeDir = Split-Path -Parent $existing[0]
    while ($probeDir -and $probeDir.Length -gt 3) {
        if (Test-Path (Join-Path $probeDir '.git')) { $repoRoot = $probeDir; break }
        $parent = Split-Path -Parent $probeDir
        if (-not $parent -or $parent -eq $probeDir) { break }
        $probeDir = $parent
    }

    # -- 2) Collect changed files via git (when available) --
    $changed  = [System.Collections.Generic.List[string]]::new()
    $gitMode  = $false
    if (-not $SkipGitDiff -and $repoRoot -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitMode = $true
        try {
            Push-Location $repoRoot
            $porcelain = & git status --porcelain 2>$null
            if ($LASTEXITCODE -eq 0 -and $porcelain) {
                foreach ($line in $porcelain) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $pathPart = $line.Substring(3).Trim('"')
                    $pathPart = (($pathPart -split '\s*->\s*')[0]).Trim()
                    if ($pathPart) { $changed.Add($pathPart) }
                }
            }
            $diffLines = & git diff --name-only $SinceRef 2>$null
            if ($LASTEXITCODE -eq 0 -and $diffLines) {
                foreach ($line in $diffLines) {
                    if ($line -and -not $changed.Contains($line)) { $changed.Add($line) }
                }
            }
        } finally {
            Pop-Location
        }
    }
    $changedArr = [string[]]$changed

    # Shared root build files affect every project when changed
    $sharedRootPatterns = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json')
    $rootFileChanged = $false
    if ($gitMode -and $repoRoot -and $changedArr.Count -gt 0) {
        foreach ($f in $changedArr) {
            $abs = Join-Path $repoRoot (($f -replace '/', [System.IO.Path]::DirectorySeparatorChar) -replace '\\', [System.IO.Path]::DirectorySeparatorChar)
            $leaf = Split-Path -Leaf $abs
            if ($leaf -in $sharedRootPatterns) { $rootFileChanged = $true; break }
        }
    }

    # -- 3) Per-project fingerprint comparison --
    $affected  = [System.Collections.Generic.List[string]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()

    Ensure-BuildCacheForState -State $State | Out-Null

    foreach ($proj in $existing) {
        $normPath = [System.IO.Path]::GetFullPath($proj)
        $cacheKey = 'proj-' + ($normPath -replace '[^A-Za-z0-9]', '_')
        $hash = Get-ProjectHash -ProjectPath $normPath

        $cacheValid = $false
        if ($hash) {
            $entry = Get-CacheEntry -Key $cacheKey
            if ($entry -and $entry.Hash -eq $hash) { $cacheValid = $true }
        }

        $gitTouched = $false
        if ($gitMode -and $repoRoot -and $changedArr.Count -gt 0) {
            if ($rootFileChanged) {
                $gitTouched = $true
            } else {
                $projDir = if (Get-Command ConvertTo-ForwardSlash -ErrorAction SilentlyContinue) { ConvertTo-ForwardSlash -Path (Split-Path -Parent $normPath) } else { (Split-Path -Parent $normPath) -replace '\\', '/' }
                $repoRootSlash = if (Get-Command ConvertTo-ForwardSlash -ErrorAction SilentlyContinue) { ConvertTo-ForwardSlash -Path $repoRoot } else { $repoRoot -replace '\\', '/' }
                if ($projDir.StartsWith($repoRootSlash)) {
                    $relDir = $projDir.Substring($repoRootSlash.Length).TrimStart('/')
                    foreach ($f in $changedArr) {
                        if ($f -like "$relDir*") { $gitTouched = $true; break }
                    }
                } else {
                    $gitTouched = $true
                }
            }
        }

        if ((-not $hash) -or (-not $cacheValid) -or $gitTouched) {
            $affected.Add($normPath)
        } else {
            $unchanged.Add($normPath)
        }
    }

    return [PSCustomObject]@{
        Affected     = [string[]]$affected
        Unchanged    = [string[]]$unchanged
        ChangedFiles = $changedArr
        Mode         = if ($gitMode) { 'Git+Hash' } else { 'Hash' }
        RepoRoot     = $repoRoot
    }
}

Export-ModuleMember -Function @(    'Initialize-BuildCache', 'Get-CanonicalCacheKey', 'Get-FileHashFast', 'Get-ProjectHash', 'Get-DirectoryHash', `
    'Get-CacheEntry', 'Save-CacheEntry', 'Test-CacheValid', `
    'Invoke-BuildWithCache', 'Save-BuildCacheEntry', 'Get-CacheStatistics', 'Show-CacheStats', `
    'Clear-BuildCache', 'Optimize-Cache', 'Get-BuildCache', 'Get-AffectedProjects', 'Remove-CacheEntry')
