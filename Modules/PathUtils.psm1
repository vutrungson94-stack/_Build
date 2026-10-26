# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


<#
.SYNOPSIS
    Centralized, cross-platform path utilities for the _Build system.
.DESCRIPTION
    Consolidates the portable path-handling patterns that were previously
    inlined across modules (forward-slash normalization, safe joins, and
    path-traversal guards) so every caller behaves consistently on Windows,
    Linux and macOS. The module has zero external dependencies so it can be
    imported standalone by any caller (including test harnesses) without
    pulling in the rest of the module graph.
#>

<#
.SYNOPSIS
    Converts every backslash in a path to a forward slash.
.DESCRIPTION
    Forward slashes are accepted by the .NET/PowerShell path APIs on every
    supported OS, so this is the canonical normalization for portable output.
#>
function ConvertTo-ForwardSlash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)][string]$Path
    )

Set-StrictMode -Version 1.0
    return $Path.Replace('\', '/')
}

<#
.SYNOPSIS
    Normalizes a path to the OS-preferred separator and (optionally) anchors it under a base.
#>
function Format-Path {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Base
    )
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $p = $Path.Replace('\', $sep).Replace('/', $sep)
    if ($Base -and -not [System.IO.Path]::IsPathRooted($p)) {
        $p = Join-Path $Base $p
    }
    return $p
}

<#
.SYNOPSIS
    Joins a base and child path using the OS separator, normalizing mixed input.
.DESCRIPTION
    The base MUST be rooted: joining onto a relative base produces a
    CWD-relative result that callers mistake for an anchored path (this is one of
    the shapes that historically let artifacts escape the project). A relative
    base throws instead of silently producing a relative path. '..' segments are
    folded by GetFullPath so no parent traversal survives the join.
#>
function Get-SafeJoinPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Child
    )
    if (-not [System.IO.Path]::IsPathRooted($Base)) {
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.pathutils.line74' -Fallback 'Get-SafeJoinPath requires a rooted Base path.'))
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $joined = Join-Path $Base $Child
    try { $joined = [System.IO.Path]::GetFullPath($joined) } catch { }
    return $joined.Replace('\', $sep).Replace('/', $sep)
}

<#
.SYNOPSIS
    Returns the StringComparison to use for PATH containment tests on this OS.
.DESCRIPTION
    SINGLE SOURCE for "are paths case-sensitive here?". This exact one-line
    ternary was written out 14 times across Android, Cache (x3),
    CacheProvider (x2), Clean, ClusterOrchestrator, Deploy, DeployTargets (x2),
    Distributed, HealthCheck, Standalone (x3) and PluginHelpers - each
    independently deciding that Windows needs OrdinalIgnoreCase and everything
    else needs Ordinal.

    That is a correctness gate, not a style choice: using OrdinalIgnoreCase on
    Linux makes a case-SENSITIVE filesystem look case-insensitive, so
    `/repo/App` would appear to contain `/repo/app/.env` and a containment
    check would pass for a path outside the tree. Centralising it means a future
    platform (a case-sensitive macOS volume, a case-insensitive WSL mount) is
    handled in one place.

    Resolution order: Environment.Get-OSPlatform (the canonical resolver, which
    distinguishes Windows / Linux / macOS), then a .NET Platform check.

    UNKNOWN FILESYSTEM => Ordinal (case-SENSITIVE), and that is the correct
    default for a containment guard. This docstring previously claimed the
    opposite - it said the function fails CLOSED to OrdinalIgnoreCase "the safer
    default for a containment guard" while the code has always returned Ordinal.
    The code is right and the prose was wrong.

    Case-insensitivity is the PERMISSIVE choice, not the strict one. On a
    case-sensitive filesystem `/repo` and `/REPO` are two different
    directories; a guard that compares them as equal would accept
    `/REPO/../../etc` as being inside `/repo`. Ordinal can only ever fail a
    legitimate path, while OrdinalIgnoreCase can wave a real escape through.
    Unknown filesystem therefore means "assume nothing is equal", which is the
    direction a security check has to err in.
#>
function Get-PathComparison {
    [CmdletBinding()]
    [OutputType([System.StringComparison])]
    param()
    $os = ''
    try { if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { $os = [string](Get-OSPlatform) } } catch { $os = '' }
    if (-not $os) {
        try {
            $plat = [System.Environment]::OSVersion.Platform
            if ($plat -eq [System.PlatformID]::Win32NT) { $os = 'Windows' }
            elseif ($plat -eq [System.PlatformID]::MacOSX) { $os = 'MacOS' }
            else { $os = 'Linux' }
        } catch { $os = '' }
    }
    # Case-insensitivity is only claimed where the platform is KNOWN to be
    # case-insensitive. Anything else, including a failed probe, stays Ordinal.
    if ($os -eq 'Windows') { return [System.StringComparison]::OrdinalIgnoreCase }
    return [System.StringComparison]::Ordinal
}

<#
.SYNOPSIS
    Returns $true when the current OS is Windows.
.DESCRIPTION
    Convenience wrapper over the canonical resolver, for the many call sites
    that only need the boolean and previously inlined the PlatformID
    comparison themselves.
#>
function Test-IsWindowsHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try { if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { return ([string](Get-OSPlatform) -eq 'Windows') } } catch { }
    try { return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) } catch { return $false }
}

<#
.SYNOPSIS
    Returns the canonical OS name ('Windows' | 'Linux' | 'MacOS').
.DESCRIPTION
    Prefers the shared resolver so modules do not each re-implement the mapping
    and disagree about macOS - which is exactly how AndroidSdkProvider came to
    report macOS as 'Linux'.
#>
function Get-CanonicalOSName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Canonicalises an ARBITRARY provider-supplied OS string instead of
        # probing the current host. There was no owner for this mapping, so every
        # producer invented its own literal and no consumer agreed with it:
        #   [System.Environment]::OSVersion.Platform.ToString() -> 'Win32NT'|'Unix'|'MacOSX'
        #   $env:CI_RUNNER_OS (GitLab)                          -> 'linux'|'windows'|'darwin'
        #   $env:RUNNER_OS (GitHub)                             -> 'Linux'|'Windows'|'macOS'
        # Every consumer compares against 'Windows'|'Linux'|'MacOS', so a value
        # in ANY of the other spellings silently took the POSIX branch - a
        # Windows CI host behaving as though it were Linux. Passing -OS is how a
        # producer reports a host other than the one it is running on; omit it
        # and the current host is probed exactly as before.
        [Alias('Value','Raw')]
        [string]$OS = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($OS)) {
        $k = $OS.Trim().ToLowerInvariant()
        switch ($k) {
            'win32nt'   { return 'Windows' }
            'win32s'    { return 'Windows' }
            'windows'   { return 'Windows' }
            'win32'     { return 'Windows' }
            # Azure Pipelines sets AGENT_OS='Windows_NT' / 'Linux' / 'Darwin'.
            'windows_nt' { return 'Windows' }
            'windows server 2022' { return 'Windows' }
            'macosx'    { return 'MacOS' }
            'macos'     { return 'MacOS' }
            'osx'       { return 'MacOS' }
            'darwin'    { return 'MacOS' }
            'unix'      { return 'Linux' }
            'linux'     { return 'Linux' }
            default     { return 'Unknown' }
        }
    }
    try { if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { $n = [string](Get-OSPlatform); if ($n) { return $n } } } catch { }
    try {
        $plat = [System.Environment]::OSVersion.Platform
        if ($plat -eq [System.PlatformID]::Win32NT) { return 'Windows' }
        if ($plat -eq [System.PlatformID]::MacOSX) { return 'MacOS' }
        return 'Linux'
    } catch { return 'Unknown' }
}

<#
.SYNOPSIS
    Tests whether a directory itself carries a project marker (build file at top level).
.DESCRIPTION
    Owns the "is this directory a project root?" test. Resolves the marker list
    through Get-ProjectMarkers (BuildConstants) so config overrides apply and no
    module re-declares the pattern list. Returns $false on any fault (fail
    closed -> the caller treats the directory as NOT a project).
#>
function Test-BuildProjectMarker {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
        # Single resolver. This re-implemented the same 4-step
        # Get-Command ladder that ConfigProvider.Get-ConfigProjectMarkers owns,
        # so there were two copies of "where do project markers come from" that
        # could drift - and the ConfigProvider copy had no production caller.
        $markers = @()
        if (Get-Command Get-ConfigProjectMarkers -ErrorAction SilentlyContinue) {
            $markers = @(Get-ConfigProjectMarkers)
        } elseif (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) {
            $markers = @(Get-ProjectMarkers)
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $markers = @(Get-BuildConstant -Key 'ProjectMarkers' -Fallback @())
        } else {
            $constantsPath = Join-Path $PSScriptRoot 'BuildConstants.psm1'
            if (Test-Path -LiteralPath $constantsPath -PathType Leaf) {
                Import-Module $constantsPath -DisableNameChecking -ErrorAction SilentlyContinue
                if (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) { $markers = @(Get-ProjectMarkers) }
            }
        }
        if ($markers.Count -eq 0) { return $false }
        foreach ($marker in $markers) {
            if (-not $marker) { continue }
            if (Get-ChildItem -LiteralPath $Path -Filter ([string]$marker) -File -ErrorAction SilentlyContinue) { return $true }
        }
        return $false
    } catch { return $false }
}

<#
.SYNOPSIS
    Resolves the effective project root BEFORE a build starts.
.DESCRIPTION
    Single owner of "where does this run belong?". Previously gbuild.ps1 simply
    set ProjectRoot to the launch directory, so a run started from a directory
    with no build file of its own still wrote .gbuild-state.gbuildstate,
    .gbuildcache\ and build-reports\ into that launch directory -- including a
    filesystem volume root such as F:\.

    Precedence:
      1. -ExplicitProject wins unconditionally when it is an existing directory.
      2. Otherwise walk UP from -StartDir looking for a project marker, bounded
         by -MaxDepth (default BuildConstants.ProjectRootMaxDepth). This is the
         standard monorepo behaviour: running from src\App\ resolves to the repo
         root that owns the build file.
      3. If no marker is found, fall back to -StartDir and report HasMarker=$false
         so the caller can decide (the launcher refuses a volume root).

    Returns a PSCustomObject: Root, Explicit, HasMarker, IsVolumeRoot,
    IsToolRoot, Depth, Marker, Candidates. Never returns $null, so callers
    can use it unconditionally.
#>
function Resolve-BuildProjectRoot {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$StartDir = '',
        [string]$ExplicitProject = '',
        [int]$MaxDepth = 0,
        [object]$State = $null
    )
    $result = [PSCustomObject]@{
        Root = ''; Explicit = $false; HasMarker = $false
        IsVolumeRoot = $false; IsToolRoot = $false
        Depth = 0; Marker = ''; Candidates = @()
    }

    # The _Build tree itself. Running the tool from inside its own directory is
    # legitimate (self-test, -SyntaxCheck, -SelfTest, docs generation) even when
    # the install root carries no project manifest, so it is exempt from the
    # marker-less refusal below.
    $toolRoot = ''
    if ($State -and ($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot) {
        $toolRoot = [string]$State.ScriptRoot
    }

    # 1. Explicit -Project: authoritative, never overridden by discovery.
    if (-not [string]::IsNullOrWhiteSpace($ExplicitProject)) {
        $ep = $null
        try { $ep = [System.IO.Path]::GetFullPath([string]$ExplicitProject) } catch { $ep = [string]$ExplicitProject }
        $result.Root = $ep
        $result.Explicit = $true
        $result.HasMarker = (Test-BuildProjectMarker -Path $ep)
        $result.IsVolumeRoot = Test-BuildVolumeRoot -Path $ep
        return $result
    }

    $start = $StartDir
    if ([string]::IsNullOrWhiteSpace($start)) {
        try { $start = (Get-Location).ProviderPath } catch { $start = $null }
    }
    if ([string]::IsNullOrWhiteSpace($start)) { return $result }
    try { $start = [System.IO.Path]::GetFullPath($start) } catch { return $result }

    if ($MaxDepth -le 0) {
        $MaxDepth = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [int](Get-BuildConstant -Key 'ProjectRootMaxDepth' -State $State -Fallback 10)
        } else { 10 }
    }
    if ($MaxDepth -le 0) { $MaxDepth = 10 }

    # 2. Walk up looking for a build file. StartDir itself wins (a repo root that
    #    is also a package root is the common case), then each ancestor.
    $current = $start
    $depth = 0
    while ($current -and $depth -le $MaxDepth) {
        if (Test-BuildProjectMarker -Path $current) {
            $result.Root = $current
            $result.HasMarker = $true
            $result.Depth = $depth
            $result.IsVolumeRoot = Test-BuildVolumeRoot -Path $current
            $result.IsToolRoot = (Test-BuildPathEqual -PathA $current -PathB $toolRoot)
            return $result
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
        $depth++
    }

    # 3. No marker anywhere above the launch directory.
    #
    # The fall-through used to return $start unconditionally, which made a
    # directory that merely CONTAINS projects (a folder of repos) look like a
    # project. Every writer then joins its artefact name onto that root:
    # .gbuild-state.gbuildstate, .gbuildcache\, build-reports\, logs\ all landed
    # NEXT TO the _Build folder, and state/cache became shared by every project
    # underneath it, so incremental cache entries collided across projects.
    # The volume-root guard alone cannot catch this - a folder of repos is a
    # perfectly legal directory. The launcher therefore also refuses a
    # marker-less, non-tool root; Candidates carries the real projects found
    # below it so the refusal can name them.
    $result.Root = $start
    $result.IsVolumeRoot = Test-BuildVolumeRoot -Path $start
    $result.IsToolRoot = (Test-BuildPathEqual -PathA $start -PathB ([string]$toolRoot))
    $result.Candidates = @(Get-BuildProjectCandidateDirectories -Path $start -MaxDepth $MaxDepth)
    return $result
}

<#
.SYNOPSIS
    True when two paths name the same location (case/separator aware).
.DESCRIPTION
    Single source for "is this the tool root?". Used by
    Resolve-BuildProjectRoot so the launcher can exempt the _Build tree itself
    from the marker-less refusal: running gbuild from inside the tool is a
    legitimate self-test / -SyntaxCheck / -SelfTest invocation even on an
    installation whose root carries no project manifest.
#>
function Test-BuildPathEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$PathA = '',
        [AllowEmptyString()][string]$PathB = ''
    )
    if ([string]::IsNullOrWhiteSpace($PathA) -or [string]::IsNullOrWhiteSpace($PathB)) { return $false }
    try {
        $cmp = if (Test-IsWindowsHost) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        $a = [System.IO.Path]::GetFullPath($PathA).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($PathB).TrimEnd('\', '/')
        return [string]::Equals($a, $b, $cmp)
    } catch { return $false }
}

<#
.SYNOPSIS
    Lists project directories at or below -Path, for "which one did you mean?".
.DESCRIPTION
    Only used on the failure path of Resolve-BuildProjectRoot: when the launch
    directory has no manifest, the refusal message can name the real projects
    instead of just saying "no". Bounded by -MaxDepth and by a hard directory
    cap so a misdirected run at C:\ cannot turn an error message into a
    full-disk scan.
#>
function Get-BuildProjectCandidateDirectories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Path = '',
        [int]$MaxDepth = 2,
        [int]$MaxResults = 12
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    if ($MaxDepth -le 0) { $MaxDepth = 2 }
    if ($MaxResults -le 0) { $MaxResults = 12 }
    $out = [System.Collections.Generic.List[string]]::new()
    # Never descend into build output / VCS / cache trees: they are large,
    # never contain a project manifest worth offering, and are exactly the
    # directories a recursive scan must not walk.
    $skip = @('.git', '.vs', '.idea', 'node_modules', 'bin', 'obj', 'packages', 'TestResults', '.gbuildcache', 'build-reports', 'publish-output')
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([PSCustomObject]@{ Dir = (Get-Item -LiteralPath $Path); Depth = 0 })
    $scanned = 0
    while ($stack.Count -gt 0 -and $out.Count -lt $MaxResults -and $scanned -lt 4000) {
        $node = $stack.Pop()
        $scanned++
        if ($node.Depth -gt 0 -and (Test-BuildProjectMarker -Path $node.Dir.FullName)) {
            $out.Add($node.Dir.FullName)
            # A project root does not need to be scanned further: nested
            # projects are reached through their own pipeline invocation.
            continue
        }
        if ($node.Depth -ge $MaxDepth) { continue }
        $children = @(Get-ChildItem -LiteralPath $node.Dir.FullName -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name -and -not (Test-ReparsePointItem -Path $_.FullName) })
        foreach ($c in $children) { $stack.Push([PSCustomObject]@{ Dir = $c; Depth = $node.Depth + 1 }) }
    }
    return @($out.ToArray())
}

<#
.SYNOPSIS
    True when a path IS a filesystem volume root (F:\, /, \\server\share).
.DESCRIPTION
    A volume root is never a project root and must never become an artifact
    root: writing .gbuild-state.gbuildstate into a drive root is the leak this
    whole resolution path exists to prevent. UNC shares are treated as volume
    roots too, because \\server\share is the share, not a project inside it.
#>
function Test-BuildVolumeRoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { return $false }
        $rootTrim = $root.TrimEnd('\', '/')
        $fullTrim = $full.TrimEnd('\', '/')
        # POSIX root is '/' itself; trimming '/' from '/' yields '' for EVERY
        # POSIX path's root, so compare the trimmed full path against the trimmed
        # root, treating an empty trimmed full path as the root itself.
        if ([string]::IsNullOrEmpty($rootTrim)) { return ($fullTrim -eq '' -or $full -eq $root) }
        return ($fullTrim -eq $rootTrim)
    } catch { return $false }
}

<#
.SYNOPSIS
    Guards against path traversal: ensures a resolved path stays within a base directory.
.DESCRIPTION
    Resolves $Path against $Base and returns $true only if the resolved
    location is equal to $Base or nested beneath it. Relative '..' segments
    and rooted escapes are rejected.

    NOTE: this function deliberately has NO -AllowRelative bypass switch. An
    earlier revision carried one that returned $true unconditionally, which
    silently disabled the guard for any caller that passed it while READING as
    "containment enforced". A caller that genuinely accepts relative paths must
    resolve them first (Resolve-BuildRootedPath) and then test containment -
    never bypass it.
#>
function Test-SafePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Base
    )
    try {
        $baseFull = [System.IO.Path]::GetFullPath($Base.TrimEnd('\', '/'))
        $target = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $baseFull $Path }
        $targetFull = [System.IO.Path]::GetFullPath($target)
        $sep = [System.IO.Path]::DirectorySeparatorChar
        # SAME comparison rule as Test-PathUnderRoots (:581): ordinal on
        # case-sensitive hosts, OrdinalIgnoreCase on Windows. The parameterless
        # StartsWith overload this used to call is culture-sensitive, which makes
        # it case-INsensitive on every OS - on a case-sensitive Linux/macOS volume
        # /repo/App then compared equal to base /repo/app, so a delete guard
        # (Clean.Assert-SafePath, Standalone bundle extraction) accepted a sibling
        # path it should have refused.
        $cmp = Get-PathComparison
        return ($targetFull -eq $baseFull) -or $targetFull.StartsWith($baseFull + $sep, $cmp)
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns the active build root directory (ProjectRoot > ScriptRoot > cwd).
.DESCRIPTION
    Single source for the root-selection logic that used to be inlined as a
    3-line ternary across modules (Cache/Loader/Siem/SupplyChain/Policy/...):
        $root = ProjectRoot; elseif ScriptRoot; else (Get-Location)
    Zero-dependency by design: accepts the State object as an untyped parameter
    and only reads ProjectRoot/ScriptRoot properties.

    KNOWN INTENTIONAL DIVERGENCES (do NOT "fix" these into this function without
    a product decision - they resolve a DIFFERENT root on purpose):
      * HealthCheck.psm1 Get-HealthRoot / Metrics.psm1 / Siem.psm1 /
        AnomalyDetector.psm1 / RootCause.psm1 / AutoTuner.psm1 / Sast.psm1 -
        prefer WorkingDir because their "root" is where REPORTS and HISTORY live
        (the launch directory), not where the project sources live.
      * Distributed.psm1 Resolve-DistributedReportRoot - now ProjectRoot-first;
        it historically preferred ScriptRoot, which wrote reports into _Build.
      * Clean.psm1 Invoke-SmartClean - falls back to $PSScriptRoot (module dir),
        deliberately SAFER than the CWD for a recursive-delete allowlist.
      * Standalone.psm1 (2 sites) - ScriptRoot-only; the bundle is emitted from
        the tool tree by design.
    A ModuleHygiene test pins this list: a NEW inline ProjectRoot/ScriptRoot/CWD
    ternary anywhere else fails the suite until it is either routed through this
    function or registered above with justification.

    DELIBERATE NON-FAIL-CLOSED DESIGN (do not "fix" without a migration plan):
    the final CWD arm stays because standalone Steps/Hooks scripts legitimately
    run with $State=$null and must resolve reads against SOMETHING. Write paths
    must NOT rely on this: every writer (state files, locale cache, version
    manifest, changelog, reports, vault, ledger, standalone bundle, SBOM, hook
    installer) resolves its own destination through an explicit rooted check and
    throws when no rooted ProjectRoot/ScriptRoot exists. Reads may fall back to
    the CWD; writes never do.
#>
function Get-BuildRootDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$State = $null)
    if ($null -ne $State) {
        foreach ($prop in @('ProjectRoot', 'ScriptRoot')) {
            if (($State.PSObject.Properties.Name -contains $prop) -and $State.$prop) {
                return [string]$State.$prop
            }
        }
    }
    return (Get-Location).ProviderPath
}

<#
.SYNOPSIS
    Resolves a relative path against the build root (ProjectRoot > ScriptRoot > cwd).
.DESCRIPTION
    Root selection single-sourced in Get-BuildRootDirectory. Rooted paths pass
    through unchanged.
#>
function Resolve-BuildRootedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [object]$State = $null
    )
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { return $RelativePath }
    $root = Get-BuildRootDirectory -State $State
    # Join single-sourced via Get-SafeJoinPath (Join-Path + OS-separator normalize).
    return [System.IO.Path]::GetFullPath((Get-SafeJoinPath -Base $root -Child $RelativePath))
}

<#
.SYNOPSIS
    Multi-root containment check: is Path inside ANY of AllowedRoots?
.DESCRIPTION
    Single implementation of the "GetFullPath both sides + StartsWith" guard that
    was duplicated in Clean.Assert-SafePath and SharedUtils.Invoke-SafeRemove.
    Semantics preserved exactly from Clean.Assert-SafePath (OrdinalIgnoreCase,
    trailing separators trimmed, missing/unparseable roots skipped, empty path
    or empty root list => $false).
#>
function Test-PathUnderRoots {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # AllowEmptyString: the caller (e.g. Clean.Assert-SafePath) must receive $false for
        # an empty target - a ParameterBindingValidationException must not be thrown at binding.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRoots
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $canonical = try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    # Case-insensitive matching ONLY on Windows (NTFS is case-insensitive);
    # ordinal everywhere else (Linux/macOS paths are case-sensitive).
    $cmp = Get-PathComparison
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootNorm = try { [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/') } catch { continue }
        # Anchor on the trailing separator (mirrors Test-SafePath): exact match
        # is accepted, but a SIBLING sharing the prefix (root 'C:\base' vs
        # target 'C:\baseFoo\...') must be rejected.
        if (($canonical -eq $rootNorm) -or
            $canonical.StartsWith($rootNorm + [System.IO.Path]::DirectorySeparatorChar, $cmp)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Rejects a path whose chain contains a reparse point (junction / symlink).
.DESCRIPTION
    Single canonical implementation of the "walk from the leaf up to the volume
    root, reject if any segment is a ReparsePoint" guard. That walk was
    copy-pasted into six modules (Android, Deploy, DeployTargets, Distributed,
    CacheProvider, Steps\publish-artifact) with no owner, so a containment fix
    had to be applied in six places.

    String containment (Test-PathUnderRoots) is NOT sufficient on its own: a
    directory junction planted inside an allowed root still string-matches the
    root while every write/delete actually lands somewhere else. Pair this with
    Test-PathUnderRoots whenever a path is about to be written to or deleted.

    Returns $true when no reparse point is found (or the path does not exist yet,
    which cannot itself be a reparse point). Returns $false on any fault, so an
    unreadable path fails closed.
#>
function Test-ReparsePointItem {
    <#
    .SYNOPSIS
        Is this ONE filesystem item a reparse point (symlink / junction / mount)?
    .DESCRIPTION
        Single-node counterpart to Test-NoReparsePointInPath, which asks about
        the whole chain. Use this when the question is about the specific item
        being read, written or enumerated; use the chain test before trusting a
        path whose ANCESTORS matter.

        The inline form
            (Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
        was written out 17 times across Android, CacheProvider, Clean,
        DeployTargets, Standalone and three Steps, with three slightly different
        spellings of the same predicate. Each one had to be reasoned about
        separately, and two of them (`-band` truthiness vs `-ne 0`) read as if
        they meant different things when they did not.

        A path that does not exist cannot itself be a reparse point, so a
        missing item returns $false. Any fault fails closed to $true, because
        every caller uses this to REJECT an item.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        return [bool](($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $true }
}

function Test-NoReparsePointInPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $current = [System.IO.Path]::GetFullPath($Path)
        while ($current) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
            }
            $root = [System.IO.Path]::GetPathRoot($current)
            if ($root -and $current.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) { break }
            $parent = Split-Path -Parent $current
            if (-not $parent -or $parent -eq $current) { break }
            $current = $parent
        }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Compiles a directory-exclusion regex from a single dir list (single source).
.DESCRIPTION
    Single implementation of the "fetch keys -> [regex]::Escape -> join '|' ->
    wrap [\\/]" idiom that was duplicated across SharedUtils / Preflight /
    Security / Cache / Project / Parallel / LanguageDetector. The returned
    pattern matches directory segments delimited by EITHER separator, so it
    works on both raw Windows paths and forward-slash-normalized relative
    paths. Escape is applied per entry (dots in '.git' are literals, fixing
    the '\\.' copy-drift bug where dot-dirs silently failed to match).
    Zero-dependency: resolves BuildConstants via a Get-Command guard so a
    standalone import never fails.
#>
function Get-ExcludeDirPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Explicit dir names (merged, deduped).
        [string[]]$Dirs = @(),
        # Extra domain-specific dirs merged in (e.g. 'target','.venv' for hash scans).
        [string[]]$Extra = @(),
        # BuildConstants key to resolve the primary list from (config-first via
        # Get-BuildConstant when the module is loaded).
        [string]$FromConstant = '',
        # Literal fallback list when the constant is unavailable (standalone import).
        [string[]]$FallbackDirs = @(),
        [object]$State = $null
    )
    $all = [System.Collections.Generic.List[string]]::new()
    if ($FromConstant) {
        $v = $null
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $v = Get-BuildConstant -Key $FromConstant -State $State -Fallback $null
        }
        if ($v) { foreach ($d in @($v)) { $all.Add([string]$d) } }
        elseif ($FallbackDirs.Count -gt 0) { foreach ($d in $FallbackDirs) { $all.Add([string]$d) } }
    }
foreach ($d in @($Dirs + $Extra)) { if ($d) { $all.Add([string]$d) } }
    $uniq = @($all | Select-Object -Unique | Where-Object { $_ })
    if ($uniq.Count -eq 0) { return '' }
    # Every SEPARATOR inside an entry becomes a separator CLASS, not a literal.
    # A multi-segment entry such as 'wwwroot/lib' (a real value of
    # security.excludeDirs) used to be escaped verbatim, so the pattern required
    # a forward slash inside the entry: on Windows FullName spells that segment
    # 'wwwroot\lib', the pattern never matched, and the exclusion was silently a
    # no-op on exactly the host where it was configured. Splitting on the
    # separator and rejoining with [\\/] makes one config entry host-independent.
    $alternatives = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $uniq) {
        $segs = @(([string]$d) -split '[\\/]+' | Where-Object { $_ })
        if ($segs.Count -eq 0) { continue }
        $alternatives.Add((($segs | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]'))
    }
    if ($alternatives.Count -eq 0) { return '' }
    return '[\\/](' + ($alternatives -join '|') + ')[\\/]'
}

<#
.SYNOPSIS
    Guarantees a directory exists, creating it (and parents) if needed.
.DESCRIPTION
    Single implementation of the "ensure dir" idiom (the repeated
    `if (-not (Test-Path $dir)) { New-Item -ItemType Directory ... }`) previously
    inlined across ~20 modules. Returns $true when the directory exists or was
    created, $false otherwise (never throws). No-op for an empty/whitespace path.
#>
function Invoke-EnsureDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (Test-Path $Path -PathType Container) { return $true }
    try {
        $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
        return (Test-Path $Path -PathType Container)
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Normalizes any path form (Git-Bash/WSL Unix drive paths like /g/..., mixed
    separators, relative) into a canonical, absolute NATIVE filesystem path for
    the current host. Strict .NET path APIs (Path.GetFullPath, File.WriteAllText)
    reject unsupported formats with "The given path's format is not supported";
    this guarantees the resolved path always uses a format those APIs accept.
.DESCRIPTION
    Cross-platform path normalization that handles:
      - Unix-style paths on Windows (Git Bash / WSL): /c/... -> C:\...
      - Mixed separators: normalizes to OS-native separator
      - Relative paths: resolves against current location
      - Non-Windows hosts: passes through unchanged (already native)
.PARAMETER Path
    The path to normalize.
.OUTPUTS
    Canonical absolute native filesystem path, or $null if input is empty.
#>
function Resolve-NativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $trimmed = $Path.Trim()

    # PS 5.1-safe Windows detection: $IsWindows exists only on PS 6+.
    # Use the canonical resolver (works on 5.1 + 7+), avoids StrictMode
    # "variable not found" when referencing $IsWindows on 5.1, and keeps the
    # macOS/Linux/Windows mapping in ONE place.
    $isWin = Test-IsWindowsHost
    # Non-Windows hosts: the input is already a native Unix path. No Git-Bash
    # drive mapping and NO '/' -> '\' rewriting — '\' is a plain character in
    # .NET paths on Linux/macOS and would corrupt absolute Unix paths.
    if (-not $isWin) {
        try {
            return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($trimmed)
        } catch {
            try { return [System.IO.Path]::GetFullPath($trimmed) } catch { return $trimmed }
        }
    }

    # /x/... (Git Bash / WSL) -> X:\...  (PowerShell does not auto-map this)
    if ($trimmed -match '^/(?<drive>[a-zA-Z])/(?<rest>.+)$') {
        $trimmed = "$($Matches['drive'].ToUpper()):\$($Matches['rest'])"
    }
    $normalized = $trimmed.Replace('/', '\')
    try {
        return [System.IO.Path]::GetFullPath($normalized)
    } catch {
        try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
        catch { return $normalized }
    }
}

<#
.SYNOPSIS
    Finds project manifest files (csproj, fsproj, vbproj, package.json, etc.) under a root directory.
<#
.SYNOPSIS
    Resolves a path to an absolute path proven to stay inside an allowed root.
.DESCRIPTION
    Single owner of the "resolve a contained path" rule: reject control
    characters, make the path absolute relative to an allowed root, then apply
    BOTH canonical guards - Test-PathUnderRoots (containment) and
    Test-NoReparsePointInPath (junction/symlink traversal).

    This rule existed three times as byte-comparable private copies
    (Deploy.Resolve-DeployStatePath, DeployTargets.Resolve-DeployContainedPath,
    Android.Resolve-AndroidContainedPath). All three already delegated the actual
    checks to this module; what they duplicated was the wrapper. Fails closed -
    returns '' - whenever the single source is unreachable, because guessing at a
    security guard is worse than refusing the path.
.PARAMETER Path
    The candidate path, absolute or relative to the root.
.PARAMETER Base
    Allowed root. Defaults to Get-BuildRootDirectory for -State.
.PARAMETER State
    Build state used to resolve the root when -Base is not supplied.
.PARAMETER RequireDirectory
    Reject unless the resolved path is an existing directory.
.PARAMETER MustExist
    Reject unless the resolved path exists at all.
.OUTPUTS
    string - the absolute path, or '' when it is not acceptable.
#>
function Resolve-BuildContainedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Base,
        [PSCustomObject]$State,
        [switch]$RequireDirectory,
        [switch]$MustExist
    )
    # Control characters in a path are the classic argument-injection and
    # path-parsing split; refuse before doing anything with the value.
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f\x7f]') { return '' }
    $root = $Base
    if ([string]::IsNullOrWhiteSpace($root)) {
        if (-not (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue)) { return '' }
        try { $root = [string](Get-BuildRootDirectory -State $State) } catch { return '' }
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue)) { return '' }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootFull $Path }
        $full = [System.IO.Path]::GetFullPath($candidate)
        if (-not (Test-PathUnderRoots -Path $full -AllowedRoots @($rootFull))) { return '' }
        if (-not (Test-NoReparsePointInPath -Path $full)) { return '' }
        if ($RequireDirectory -and -not (Test-Path -LiteralPath $full -PathType Container)) { return '' }
        if ($MustExist -and -not (Test-Path -LiteralPath $full)) { return '' }
        return $full
    } catch { return '' }
}

<#
.SYNOPSIS
    Single source for project manifest discovery. Replaces scattered Get-ChildItem -Filter *.csproj
    patterns across 8+ modules. Uses BuildConstants.ProjectMarkers as canonical filter list,
    with optional custom filters.
.PARAMETER Root
    Root directory to search.
.PARAMETER Filters
    Optional custom filter patterns. Defaults to BuildConstants.ProjectMarkers (13 entries).
.PARAMETER Recurse
    Whether to search recursively. Default $true.
.PARAMETER MaxDepth
    Maximum recursion depth. Default from BuildConstants.ProjectRootMaxDepth (10).
.OUTPUTS
    FileInfo[] - Matching manifest files.
#>
function Find-ProjectManifest {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string[]]$Filters,
        [switch]$Recurse,
        [int]$MaxDepth = 0,
        [object]$State = $null
    )

    if (-not (Test-Path $Root -PathType Container)) { return @() }

    $canonicalFilters = @()
    if (-not (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) -and -not (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) {
        $constantsPath = Join-Path $PSScriptRoot 'BuildConstants.psm1'
        if (Test-Path -LiteralPath $constantsPath -PathType Leaf) {
            Import-Module $constantsPath -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) {
        $canonicalFilters = @(Get-ProjectMarkers -State $State)
    } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $canonicalFilters = @(Get-BuildConstant -Key 'ProjectMarkers' -State $State -Fallback @())
    } elseif (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        $canonicalFilters = @(Get-BuildDefault -Key 'ProjectMarkers' -Fallback @())
    }
    if ($canonicalFilters.Count -eq 0) { return @() }

    $patterns = if ($Filters -and $Filters.Count -gt 0) { $Filters } else { $canonicalFilters }

    # Resolve depth
    if ($MaxDepth -le 0) {
        $MaxDepth = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            Get-BuildConstant -Key 'ProjectRootMaxDepth' -State $State -Fallback 10
        } else { 10 }
    }

    $results = @()
    # PS 5.1 has no Get-ChildItem -Depth. Route through the single-source
    # compatible enumerator (Environment.Invoke-CompatibleChildItem) when it is
    # loaded; otherwise fall back to native -Depth on PS 6+ only, and to a
    # manual relative-depth filter on PS 5.1 without the helper.
    $useCompat = [bool](Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue)
    $supportsDepth = $false
    try { $supportsDepth = ($PSVersionTable.PSVersion.Major -ge 6) } catch { $supportsDepth = $false }
    foreach ($pattern in $patterns) {
        if ($Recurse) {
            if ($useCompat) {
                $results += @(Invoke-CompatibleChildItem -Path $Root -Filter $pattern -File -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue)
            } elseif ($supportsDepth) {
                $results += Get-ChildItem -Path $Root -Filter $pattern -File -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue
            } else {
                $results += @(Get-ChildItem -Path $Root -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        $rel = $_.FullName.Substring($Root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                        @($rel -split '[\\/]').Count -le ($MaxDepth + 1)
                    })
            }
        } else {
            $results += Get-ChildItem -Path $Root -Filter $pattern -File -ErrorAction SilentlyContinue
        }
    }

    return $results | Select-Object -Unique
}

Export-ModuleMember -Function @('ConvertTo-ForwardSlash', 'Format-Path', 'Get-SafeJoinPath', 'Test-SafePath', 'Get-BuildRootDirectory', 'Resolve-BuildRootedPath', 'Test-PathUnderRoots', 'Test-ReparsePointItem', 'Test-NoReparsePointInPath', 'Get-ExcludeDirPattern', 'Invoke-EnsureDirectory', 'Resolve-NativePath', 'Find-ProjectManifest', 'Test-BuildProjectMarker', 'Resolve-BuildProjectRoot', 'Test-BuildVolumeRoot', 'Test-BuildPathEqual', 'Get-BuildProjectCandidateDirectories', 'Get-PathComparison', 'Test-IsWindowsHost', 'Get-CanonicalOSName', 'Resolve-BuildContainedPath')
