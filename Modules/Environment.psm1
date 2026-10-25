# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Environment.psm1 - Cross-Platform Environment Setup & Utilities
# ==================================================================================================

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

Import-GBuildModule -Names @('SharedUtils', 'BuildConstants') -Force


# -- OS Detection ---------------------------------------------------------------
<#
.SYNOPSIS
    Detects the current operating system platform.
.OUTPUTS
    string: Windows, Linux, MacOS, or Unknown
#>
function Get-OSPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()

Set-StrictMode -Version 1.0

    # PS7+ automatic variables
    try {
        if ($IsWindows) { return 'Windows' }
        if ($IsLinux)   { return 'Linux' }
        if ($IsMacOS)   { return 'MacOS' }
    } catch { # PS5.1: $IsWindows/$IsLinux/$IsMacOS don't exist -> fall through
    }
    # PS 5.1 fallback: use .NET runtime info (works on all platforms)
    try {
        $platform = [System.Environment]::OSVersion.Platform
        if ($platform -eq 'Win32NT') { return 'Windows' }
        # Unix = 128 on Linux/macOS; check for specific indicators
        if ($platform -eq 'Unix' -or $platform -eq 128) {
            if (Test-Path '/proc/sys/kernel/ostype' -ErrorAction SilentlyContinue) {
                $ostype = Get-Content '/proc/sys/kernel/ostype' -ErrorAction SilentlyContinue
                if ($ostype -match 'Linux') { return 'Linux' }
            }
            if (Test-Path '/System/Library/CoreServices/SystemVersion.plist' -ErrorAction SilentlyContinue) { return 'MacOS' }
            return 'Linux'  # default Unix assumption
        }
    } catch { # benign
    }
    return 'Unknown'
}

$script:OS = Get-OSPlatform
$script:IsWindows = $script:OS -eq 'Windows'
$script:IsMacOS   = $script:OS -eq 'MacOS'
$script:IsLinux   = $script:OS -eq 'Linux'

# -- UTF-8 Configuration --------------------------------------------------------
<#
.SYNOPSIS
    Configures PowerShell session for UTF-8 encoding support.
.DESCRIPTION
    Sets output encoding and console encoding to UTF-8, and configures Windows
    console code page when running on Windows platform.
#>
if ($script:OS -eq 'Windows') {
    try { & chcp 65001 | Out-Null } catch {
        # benign: codepage change is best-effort; UTF-8 still set on .NET streams below
        }

}
$OutputEncoding           = [System.Text.Encoding]::UTF8
# [Console]::OutputEncoding throws IOException when the handle is a pipe rather
# than a real console (common in CI, SSH, and redirected hosts). This runs at
# module load with no caller to trap, so an unguarded assignment aborted the
# whole bootstrap chain. Encoding is a display concern: never fatal.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# Save original and set only OutputEncoding (InputEncoding stays default to avoid Read-Host breakage)

# -- Global State Initialization ------------------------------------------------
<#
.SYNOPSIS
    Initializes the global state object for script-level configuration.
.DESCRIPTION
    Sets up GState object with essential properties (ScriptRoot, TempFiles, CacheFile).
    Supports being called from any directory by resolving paths relative to module location.
#>
# Merge essential properties if GState is not fully initialized (standalone usage)
$hasGState = (Get-Variable -Name GState -Scope Global -ErrorAction SilentlyContinue) -and $global:GState
if (-not $hasGState) {
    $global:GState = [PSCustomObject]@{
        TempFiles  = [System.Collections.Generic.List[string]]::new()
        ScriptRoot = $null
        CacheFile  = $null
        SDKCache   = $null
    }
}
$envState = $global:GState
# SDK cache path: same file as CacheFile for compatibility with gbuild.ps1
# GState (which exposes the path as State.SDKCache — SDK.Get-SdkCacheFile reads it).
# Leaf name is single-sourced in BuildConstants.SdkCacheUserRelativePath.
$sdkCacheRel = if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { [string](Get-BuildDefault -Key 'SdkCacheUserRelativePath' -Fallback '.gbuild/sdkcache.json') } else { '.gbuild/sdkcache.json' }
$sdkCacheDefault = Join-Path ([Environment]::GetFolderPath('UserProfile')) $sdkCacheRel
if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
    if (-not ((Get-BuildState -State $envState).PSObject.Properties.Name -contains 'TempFiles')) {
        Set-BuildStateProperty -State $envState -Name 'TempFiles' -Value ([System.Collections.Generic.List[string]]::new()) -Force
    }
    $hasSR = (Get-BuildState -State $envState).PSObject.Properties.Name -contains 'ScriptRoot' -and $null -ne $envState.ScriptRoot
    # ScriptRoot is the BUILD-TOOL root everywhere else (config base, module dir,
    # hook dir). Seeding it from the process CWD made _Build believe the project
    # directory was its own installation. The final fallback is the tool root
    # derived from this module's own location - always absolute, never the CWD.
    $scriptRoot = if ($hasSR) { $envState.ScriptRoot }
                  elseif (Get-Variable -Name ScriptRoot -Scope Global -EA SilentlyContinue) { $global:ScriptRoot }
                       elseif (Get-Variable -Name PSScriptRoot -Scope Script -EA SilentlyContinue) { Split-Path $PSScriptRoot -Parent }
                  else { Split-Path $PSScriptRoot -Parent }
    if (-not ((Get-BuildState -State $envState).PSObject.Properties.Name -contains 'ScriptRoot') -or [string]::IsNullOrEmpty($envState.ScriptRoot)) {
        Set-BuildStateProperty -State $envState -Name 'ScriptRoot' -Value $scriptRoot -Force
    }
    # SDK cache path mirror (CacheFile alias) — SDK.Get-SdkCacheFile reads State.SDKCache.
    if (-not ((Get-BuildState -State $envState).PSObject.Properties.Name -contains 'CacheFile') -or [string]::IsNullOrEmpty($envState.CacheFile)) {
        Set-BuildStateProperty -State $envState -Name 'CacheFile' -Value $sdkCacheDefault -Force
    }
    if (-not ((Get-BuildState -State $envState).PSObject.Properties.Name -contains 'SDKCache') -or [string]::IsNullOrEmpty($envState.SDKCache)) {
        Set-BuildStateProperty -State $envState -Name 'SDKCache' -Value $sdkCacheDefault -Force
    }
} else {
    # Fallback: direct global state mutation (standalone mode without Logging)
    $hasProps = @($envState.PSObject.Properties.Name)
    if ($hasProps -notcontains 'TempFiles') {
        $envState | Add-Member -MemberType NoteProperty -Name TempFiles -Value ([System.Collections.Generic.List[string]]::new()) -Force
    }
    if ($hasProps -notcontains 'ScriptRoot' -or -not $envState.ScriptRoot) {
        # Same tool-root fallback as the Set-BuildStateProperty path above: never CWD.
        $scriptRoot2 = if ($hasProps -contains 'ScriptRoot' -and $envState.ScriptRoot) { $envState.ScriptRoot }
                       elseif (Get-Variable -Name ScriptRoot -Scope Global -EA SilentlyContinue) { $global:ScriptRoot }
                  elseif (Get-Variable -Name PSScriptRoot -Scope Script -EA SilentlyContinue) { Split-Path $PSScriptRoot -Parent }
                       else { Split-Path $PSScriptRoot -Parent }
        $envState | Add-Member -MemberType NoteProperty -Name ScriptRoot -Value $scriptRoot2 -Force
    }
    if ($hasProps -notcontains 'CacheFile' -or -not $envState.CacheFile) {
        $envState | Add-Member -MemberType NoteProperty -Name CacheFile -Value $sdkCacheDefault -Force
    }
    if ($hasProps -notcontains 'SDKCache' -or -not $envState.SDKCache) {
        $envState | Add-Member -MemberType NoteProperty -Name SDKCache -Value $sdkCacheDefault -Force
    }
}
# -- Temporary Files Management -------------------------------------------------
<#
.SYNOPSIS
    Registers a temporary file for automatic cleanup on PowerShell exit.
.DESCRIPTION
    Adds a file path to the global temp file list that will be automatically
    deleted when the PowerShell session exits. Supports cross-module state sharing.
.PARAMETER State
    The state object to register the temp file with (uses GState.TempFiles).
.PARAMETER Path
    The path of the temporary file to register.
#>
function Register-TempFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$State,
        [string]$Path
    )

    # Initialize TempFiles list if not present in State
    if (-not $State.TempFiles) {
        $State | Add-Member -MemberType NoteProperty -Name "TempFiles" -Value ([System.Collections.Generic.List[string]]::new()) -Force
    }

    # REFUSED, not registered. Register-TempFile accepts an arbitrary Path from
    # any caller; its two consumers (the PowerShell.Exiting handler below and
    # Start-GBuild's finally) both delete with -Recurse -Force. Registering an
    # out-of-scope path therefore handed every caller a recursive delete
    # primitive against a path of their choosing. Containment is enforced at
    # registration - the same allow-list the cleanup handlers use.
    if (-not $Path) { return }
    try { $Path = [System.IO.Path]::GetFullPath($Path) } catch { return }
    $allowedRoots = @()
    try { if ($PSScriptRoot) { $allowedRoots += [System.IO.Path]::GetFullPath($PSScriptRoot) } } catch { }
    try { $allowedRoots += [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()) } catch { }
    try { if ($State.ScriptRoot) { $allowedRoots += [System.IO.Path]::GetFullPath([string]$State.ScriptRoot) } } catch { }
    try { if ($State.ProjectRoot) { $allowedRoots += [System.IO.Path]::GetFullPath([string]$State.ProjectRoot) } } catch { }
    if ($allowedRoots.Count -eq 0) { return }
    $contained = $false
    # Containment guard for temp-file registration. Must follow the host
    # filesystem's case sensitivity: OrdinalIgnoreCase on a case-sensitive
    # volume let a temp path outside the approved roots match an approved root
    # that differed only by letter case, so the file would be registered for
    # later deletion outside the tree the caller authorised.
    $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
           else { if ((Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost)) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
    foreach ($root in $allowedRoots) {
        if ($Path.Equals($root, $cmp)) { $contained = $true; break }
        $prefix = $root.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
        if ($Path.StartsWith($prefix, $cmp)) { $contained = $true; break }
    }
    if (-not $contained) {
        Write-Warning (Resolve-LogMessage -Key 'log.temp.pathRefused' -MessageArgs @([string]$Path) -Fallback '[TEMP] Refusing to register temp path outside the tool/temp/project roots: {0}')
        return
    }
    if (Test-Path -LiteralPath $Path) {
        $State.TempFiles.Add($Path)
    }
}

# -- Cleanup Handler ------------------------------------------------------------
<#
.SYNOPSIS
    Registers an engine event to clean up temporary files on PowerShell exit.
.DESCRIPTION
    Prevents race conditions during module re-import by unregistering old
    event subscribers before creating new ones. Automatically removes all
    registered temporary files when the PowerShell session terminates.
#>
if ($PSVersionTable.PSEdition -eq 'Core') {
    # Unregister old event to prevent duplicate cleanup (race condition on re-import)
    try {
        Get-EventSubscriber -SourceIdentifier 'PowerShell.Exiting' -ErrorAction Stop |
            Unregister-Event -Force -ErrorAction Stop
    } catch { # No subscribers registered
    }

    # Register new cleanup event with optimized cleanup logic.
    # The allowlist is the TOOL directory plus the SYSTEM TEMP directory - the two
    # places Register-TempFile is allowed to point at. The process CWD used to be
    # listed here, which meant any registered path resolving under the directory
    # the user's shell happened to be in at exit time was permanently deleted
    # with -Recurse -Force. $PWD is evaluated at event-fire time, not registration
    # time, so it could be anywhere.
    Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        if ($global:GState -and $global:GState.TempFiles) {
            $allowedRoots = @($PSScriptRoot, [System.IO.Path]::GetTempPath())
            $global:GState.TempFiles | Where-Object { Test-Path $_ -PathType Leaf } | ForEach-Object {
                try {
                    Invoke-SafeRemove -Path $_ -AllowedRoots $allowedRoots -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Warning (Resolve-LogMessage -Key 'log.temp.removeFailed' -MessageArgs @([string]$_, [string]$_) -Fallback 'Failed to remove temp file ''{0}'': {1}')
                }
            } | Out-Null
        }
    } | Out-Null
}

# -- PowerShell Version Compatibility Checks ------------------------------------
$script:PowerShellMajorVersion = $PSVersionTable.PSVersion.Major
$script:IsPwsh7 = $script:PowerShellMajorVersion -ge 7
$script:SupportsDepth = if ($script:IsPwsh7) { $true } else {
    (Get-Command Get-ChildItem -ErrorAction Stop).Parameters.ContainsKey('Depth')
}

# ==================================================================================
# GENERAL UTILITY FUNCTIONS
# ==================================================================================
# -- Utility Functions ----------------------------------------------------------
<#
.SYNOPSIS
    Calculates the relative directory depth between a root path and a child path.
.DESCRIPTION
    Compares two full paths and returns an integer representing how many directory levels
    the child path is below the root path. Returns 0 if they are the same or if the child
    is not a sub-path of the root. Returns a large number (999999) on error.
.PARAMETER Root
    The absolute path of the root directory.
.PARAMETER Child
    The absolute path of the child directory or file.
.OUTPUTS
    int: The relative depth, or 0, or 999999 on error.
#>
function Get-RelativeDepth {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Root,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Child
    )
    try {
        $rootNorm  = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        $childNorm = [System.IO.Path]::GetFullPath($Child).TrimEnd('\','/')

        # If child is not a sub-path or is the same path
        # Single source for path case sensitivity (PathUtils.Get-PathComparison).
        $caseOpt = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison } else { if ($script:IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
        if (-not $childNorm.StartsWith($rootNorm, $caseOpt)) {
            return 0
        }
        if ($childNorm.Length -le $rootNorm.Length) { return 0 }

        $relative = $childNorm.Substring($rootNorm.Length).TrimStart('\','/')
        if ([string]::IsNullOrWhiteSpace($relative)) { return 0 }
        return ($relative -split '[\\/]').Count
    }
    catch {
        Write-Warning (Resolve-LogMessage -Key 'log.path.relativeDepthFailed' -MessageArgs @([string]$Root, [string]$Child, [string]$_) -Fallback 'Could not calculate relative depth for Root: ''{0}'', Child: ''{1}''. Error: {2}')
        # Level 5 single-source: RelativeDepthErrorSentinel (BuildConstants).
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { return [int](Get-BuildConstant -Key 'RelativeDepthErrorSentinel' -Fallback 999999) } catch { return 999999 }
        }
        return 999999 # Indicate an error or a very deep path
    }
}

# -- Cross-Platform Get-ChildItem Wrapper ---------------------------------------
<#
.SYNOPSIS
    Provides Get-ChildItem with depth parameter support across PowerShell versions.
.DESCRIPTION
    Automatically uses the built-in -Depth parameter in PowerShell 6+,
    falls back to manual depth filtering for older versions.
.PARAMETER Path
    The path to search.
.PARAMETER Filter
    The filter to apply (e.g., *.ps1).
.PARAMETER File
    Only return files.
.PARAMETER Directory
    Only return directories.
.PARAMETER Recurse
    Search recursively.
.PARAMETER Depth
    Maximum depth to search (default: 999).
.OUTPUTS
    FileSystemInfo[]: Collection of file system items.
#>
function Invoke-CompatibleChildItem {
    [CmdletBinding()]
    [OutputType([System.IO.FileSystemInfo[]])]
    param(
        [string]$Path,
        [string]$Filter = '*',
        [switch]$File,
        [switch]$Directory,
        [switch]$Recurse,
        [int]$Depth = -1,
        [PSCustomObject]$State = $null
    )

    # Resolve default depth from BuildConstants if not explicitly provided
    if ($Depth -lt 0) {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $Depth = [int](Get-BuildConstant -Key 'CompatibleChildItemMaxDepth' -State $State -Fallback 2)
        } else {
            $Depth = 2
        }
    }

    if (-not (Test-Path -Path $Path)) { return @() }

    if ($script:SupportsDepth) {
        # PowerShell 6+: Use native -Depth parameter
        $gciArgs = @{
            Path        = $Path
            Force       = $true
            ErrorAction = 'SilentlyContinue'
            Recurse     = $Recurse
            Depth       = $Depth
        }
        if ($Filter -and $Filter -ne '*') { $gciArgs['Filter'] = $Filter }
        if ($File)      { $gciArgs['File'] = $true }
        if ($Directory) { $gciArgs['Directory'] = $true }
        return Get-ChildItem @gciArgs
    }

    # PowerShell 5.1: Manual depth filtering
    $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
    if ($File)      { $items = $items | Where-Object { -not $_.PSIsContainer } }
    if ($Directory) { $items = $items | Where-Object { $_.PSIsContainer } }
    if ($Recurse) {
        $items = $items | Where-Object { (Get-RelativeDepth -Root $Path -Child $_.FullName) -le $Depth }
    }
    return $items
}

<#
.SYNOPSIS
    Converts a long path to a short path on Windows, and escapes spaces on Unix/MacOS.
.DESCRIPTION
    On Windows, this function attempts to convert a long file path to its 8.3 short path
    format, which can be useful for compatibility with older tools or systems that don't
    handle long paths or spaces well. It prioritizes .NET P/Invoke for speed, then
    falls back to FileSystemObject. On Unix-like systems there is no short-name
    concept, so the fully-resolved absolute path is returned verbatim.
.PARAMETER Path
    The original file or directory path.
.OUTPUTS
    string: A FILESYSTEM PATH that is safe to hand to an external tool. Never a
    shell-escaped word - see the note in the function body.
#>
function Get-SafePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # CORRECTED. The non-Windows arm used to `return $Path -replace ' ', '\ '`,
    # i.e. return a SHELL-ESCAPED word from a function whose return value is
    # consumed as a FILESYSTEM PATH by all 8 call sites:
    #   SDK.psm1:884  -> DOTNET_ROOT / JAVA_HOME / ANDROID_HOME set to a value
    #                   containing a literal backslash -> every toolchain breaks
    #   Build.psm1:575-576, 926-928, 957 -> `dotnet publish "/home/my\ app/A.csproj"`
    #                   -> "file not found"; core build broken
    #   Deploy.psm1:299 -> Start-Process -FilePath -> web app auto-launch always
    #                   failed when the path contained a space
    #   HotReload.psm1:62 -> corrupt watch path
    # A path containing a space is the NORMAL case on macOS (/Users/First Last)
    # and common on Linux, so this was a hard break on exactly the platforms
    # that are hardest to test. Escaping for a shell is the CALLER's job and
    # only when the value is concatenated into a command string; every call
    # site here uses argument arrays, which need no escaping at all.
    # Unix has no 8.3 short names: return the resolved absolute path.
    if ($script:OS -ne 'Windows') {
        try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
    }

    # Windows-specific logic for short paths
    $absPathItem = Get-Item -Path $Path -ErrorAction SilentlyContinue
    $absPath = if ($absPathItem) { $absPathItem.FullName } else { $null }
    if (-not $absPath) {
        Write-Debug "Path '$Path' not found or resolved, returning original path."
        return $Path
    }

    # If no problematic characters, return as is
    if ($absPath -notmatch '[\s\u0080-\uFFFF]') { return $absPath }

    # Try P/Invoke for GetShortPathName (fastest)
    try {
        if (-not ([System.Management.Automation.PSTypeName]'GBuild.PathHelper').Type) {
            Add-Type -Namespace 'GBuild' -Name 'PathHelper' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetShortPathName(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);
'@ -ErrorAction Stop
        }
        # Buffer sized to MAX_PATH, then retried at MAX_PATH*4 so projects
        # living beyond the legacy 260-char limit are shortened instead of
        # silently skipped.
        $limit = 260
        $sb  = [System.Text.StringBuilder]::new($limit)
        $len = [GBuild.PathHelper]::GetShortPathName($absPath, $sb, $limit)
        if ($len -gt $limit) {
            $limit = 32768
            $sb  = [System.Text.StringBuilder]::new($limit)
            $len = [GBuild.PathHelper]::GetShortPathName($absPath, $sb, $limit)
        }
        if ($len -gt 0 -and $len -le $limit) {
            return $sb.ToString(0, [int]$len)
        }
    } catch {
        Write-Debug "P/Invoke for GetShortPathName failed for '$absPath': $_"
    }

    # Fallback to FileSystemObject (slower, but reliable)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFile($absPath).ShortPath
        if (-not [string]::IsNullOrWhiteSpace($short)) { return $short }
        return $absPath
    } catch {
        Write-Debug "Could not get short path for '$absPath'. Error: $_"
        return $absPath # Return original path if all attempts fail
    }
}

function Read-JsonSafe {
    param([string]$FilePath)

    # SharedUtils.Read-BuildJsonFile owns safe JSON reads. The name is
    # deliberately different from this compatibility wrapper: probing for
    # Read-JsonSafe as a sentinel always resolved to this function itself, so
    # the probe entered the wrong branch and invoked a nonexistent command in
    # SharedUtils' session state. Probing for the distinct owner avoids that.
    Import-GBuildModuleIfMissing -Name 'SharedUtils' -SentinelCommand 'Read-BuildJsonFile'
    return Read-BuildJsonFile -FilePath $FilePath
}

function Save-JsonSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Data,
        [Parameter(Mandatory=$true)] [string]$FilePath
    )
    # Single source: SharedUtils.Write-BuildJsonFile is ATOMIC (unique temp name +
    # File.Replace), writes UTF-8 WITHOUT a BOM, and takes a depth. The old
    # inline fallback was non-atomic (Remove-Item then Move-Item, leaving a window
    # where the target does not exist), used a PREDICTABLE temp name
    # "$FilePath.tmp" (two concurrent writers clobber each other), and wrote with
    # [System.Text.Encoding]::UTF8, which EMITS A BOM on PS 5.1 / .NET Framework.
    # SharedUtils.Write-BuildJsonFile -Atomic is the owner. The 21-line
    # "standalone fallback" this replaced called [System.IO.File]::Replace with
    # a $null backup path, which does NOT mean "no backup": PowerShell binds
    # $null to an empty String and File.Replace then throws ArgumentException
    # on every call - so this fallback could never have worked even if it had
    # been reached.
    $ok = Write-BuildJsonFile -Path $FilePath -Data $Data -Depth 10 -Atomic
    if (-not $ok) { Write-Log (Resolve-LogMessage -Key 'log.json.saveUnsafe' -MessageArgs @([string]$FilePath) -Fallback '[JSON] Cannot safely save {0} : Write-BuildJsonFile returned false') 'Yellow' }
    return
}

function Open-Target {
    param([string]$Target, [PSCustomObject]$State = $null)
    # Unify "reveal publish output after build": always surface the path, then open it.
    # Without a $State we fall back to Write-Host so standalone callers still see it.
    # Level 5: color via Resolve-SafeColor so retheme covers the fallback path.
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue -and $State) {
            $msg = if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.env.outputPath' -MessageArgs $Target } else { "  [OUTPUT] $Target" }
            Write-Log $msg 'Succ' $State
        } else {
            $succColor = if (Get-Command Resolve-SafeColor -ErrorAction SilentlyContinue) { Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green' } else { 'Green' }
            try { Write-Host "  [OUTPUT] $Target" -ForegroundColor $succColor } catch { Write-Host "  [OUTPUT] $Target" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($Target)) { return }
    try {
        if ($script:OS -eq 'Windows') {
            if ($Target -match '^https?://') { Start-Process $Target }
            else { Start-Process explorer.exe -ArgumentList "`"$Target`"" }
        }
        elseif ($script:OS -eq 'MacOS') { Start-Process open    -ArgumentList @($Target) }
        elseif ($script:OS -eq 'Linux') { Start-Process xdg-open -ArgumentList @($Target) }
    } catch { if (Get-Command Write-Warn -ErrorAction SilentlyContinue) { Write-Warn (Resolve-LogMessage -Key 'log.open.manual' -MessageArgs @([string]$Target) -Fallback 'Cannot auto-open. Please access manually: {0}') } }
}

function Get-AvailableDrives {
    if ($script:OS -eq 'Windows') {
        return Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -ExpandProperty DeviceID
    }
    if ($script:OS -eq 'Linux') {
        # Mount roots are canonical in BuildConstants.OsRemovableMountRoots. The
        # literal remains only as the survival fallback when BuildConstants is
        # unavailable. Missing mount roots are skipped individually so one
        # absent path cannot suppress the other removable-media locations.
        $mountRoots = @('/mnt', '/media', '/run/media')
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $mountRoots = @(Get-BuildConstant -Key 'OsRemovableMountRoots' -Fallback $mountRoots) } catch { }
        }
        $found = [System.Collections.Generic.List[string]]::new()
        $found.Add('/') | Out-Null
        foreach ($mountRoot in @($mountRoots | Where-Object { $_ })) {
            foreach ($drive in @(Get-ChildItem -LiteralPath $mountRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
                if ($drive -and ($found -notcontains $drive)) { $found.Add($drive) | Out-Null }
            }
        }
        return @($found.ToArray())
    }
    if ($script:OS -eq 'MacOS') {
        $volumeRoot = '/Volumes'
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $volumeRoot = [string](Get-BuildConstant -Key 'OsMacOSVolumeRoot' -Fallback $volumeRoot) } catch { }
        }
        $found = @('/')
        foreach ($drive in @(Get-ChildItem -LiteralPath $volumeRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
            if ($drive -and ($found -notcontains $drive)) { $found += $drive }
        }
        return $found
    }
    return @('/')
}

function Get-RuntimeIdentifier {
    $isArm = try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        $arch -eq [System.Runtime.InteropServices.Architecture]::Arm64
    } catch {
        # Absolutely safe fallback for old PS 5.1
        $env:PROCESSOR_ARCHITECTURE -match 'ARM64'
    }
    switch ($script:OS) {
        'Windows' { return $(if ($isArm) { 'win-arm64'   } else { 'win-x64'   }) }
        'MacOS'   { return $(if ($isArm) { 'osx-arm64'   } else { 'osx-x64'   }) }
        'Linux'   { return $(if ($isArm) { 'linux-arm64' } else { 'linux-x64' }) }
        default {
            # Unknown OS: infer from the host instead of assuming Windows.
            if ($script:IsWindows) { return $(if ($isArm) { 'win-arm64' } else { 'win-x64' }) }
            return $(if ($isArm) { 'linux-arm64' } else { 'linux-x64' })
        }
    }
}

function Test-PortListening {
    param([int]$Port)
    try {
        if ($script:OS -eq 'Windows') {
            return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue)
        } elseif ($script:OS -eq 'Linux') {
            # 2>$null, not 2>/dev/null. On Windows PowerShell a redirection to
            # /dev/null is a write to a file literally named "dev\null" in the
            # current drive, not a discard. These branches only run on their own
            # OS, but the parse is shared, so the redirect must be portable.
            $out = & ss -tlnp 2>$null | Select-String ":$Port\s"
            return [bool]$out
        } elseif ($script:OS -eq 'MacOS') {
            $out = & lsof -iTCP:$Port -sTCP:LISTEN 2>$null
            return [bool]$out
        }
    } catch {
        # benign: lsof not available or port-listening check failed; fall through to $false
        }
    return $false
}

# Checks if a port is truly BINDABLE (not just not-listening, but actually available
# for a new socket bind). This catches TIME_WAIT state which Test-PortListening misses.
# Level 5 single-source: primary is BuildConstants.LoopbackAddress
# (config-overridable). The '127.0.0.1' literal below is emergency standalone
# fallback only (BuildConstants module absent) — never extend, fix constants instead.
function Test-PortBindable {
    param([int]$Port, [string]$IP = '')
    if ([string]::IsNullOrWhiteSpace($IP)) {
        $IP = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [string](Get-BuildConstant -Key 'LoopbackAddress' -Fallback '127.0.0.1')
        } else { '127.0.0.1' }
    }
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($IP), $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

# Waits until a port is released (single source for the Build.psm1 web-port
# guard and the Deploy.psm1 stale-instance guard, which previously duplicated
# the same PortWaitAttempts x PortWaitDelayMs polling loop with different
# predicates). Mode 'Listening' waits until nothing listens; mode 'Bindable'
# additionally requires a fresh socket bind (catches TIME_WAIT).
# Returns $true when released, $false after exhausting attempts. Never throws.
function Wait-PortRelease {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [PSCustomObject]$State = $null,
        [ValidateSet('Listening', 'Bindable')][string]$Mode = 'Listening',
        [int]$Attempts = 0,
        [int]$DelayMs = 0
    )
    if ($Attempts -le 0) {
        $Attempts = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'PortWaitAttempts' -State $State -Fallback 20) } else { 20 }
    }
    if ($DelayMs -le 0) {
        $DelayMs = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'PortWaitDelayMs' -State $State -Fallback 1000) } else { 1000 }
    }
    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Milliseconds $DelayMs
        $released = if ($Mode -eq 'Bindable') { Test-PortBindable -Port $Port } else { -not (Test-PortListening -Port $Port) }
        if ($released) { return $true }
    }
    return $false
}

# Single-source, OS-aware lookup of the process(es) LISTENING on a port.
# Shared by Build.psm1 (Stop-ProcessByPort) and HealthCheck.psm1 (Invoke-AutoFix)
# so the Get-NetTCPConnection/lsof/fuser branching lives in exactly one place.
function Get-PortOwnerProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)

    $procs = @()
    if ($script:OS -eq 'Windows') {
        $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        foreach ($conn in $conns) {
            if ($conn.OwningProcess -le 0) { continue }
            $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { $procs += $p }
        }
    } elseif ($script:OS -eq 'Linux' -or $script:OS -eq 'MacOS') {
        $lsofPids = @(& lsof -ti "tcp:$Port" -sTCP:LISTEN 2>$null)
        foreach ($lsofPid in $lsofPids) {
            if ($lsofPid -and $lsofPid -match '^\d+$') {
                $p = Get-Process -Id $lsofPid -ErrorAction SilentlyContinue
                if ($p) { $procs += $p }
            }
        }
        if ($procs.Count -eq 0 -and (Get-Command fuser -ErrorAction SilentlyContinue)) {
            $fuserOut = @(& fuser "$Port/tcp" 2>$null)
            foreach ($line in $fuserOut) {
                if ($line -match '\b(\d+)\b') {
                    $p = Get-Process -Id ([int]$matches[1]) -ErrorAction SilentlyContinue
                    if ($p) { $procs += $p }
                }
            }
        }
    }
    return ,$procs
}

# -- Unix process helpers (canonical home) --------------------------------------
# Single source for non-Windows process introspection, shared by
# Get-ProcessCommandLine (below), HotReload.psm1 (watch-tree kill) and any
# future Unix process consumer. Previously duplicated between this module
# (inline /proc + ps blocks inside Get-ProcessCommandLine) and HotReload.psm1
# (private copies invisible to other modules) — now exactly one implementation.
# Resolution order per helper: /proc/<pid>/cmdline (Linux, no external binary)
# -> `ps` (PATH discovery, then BuildConstants.PsBinaryFallbackPaths) ->
# process-name last resort. Never throws.

$script:PsBinary = $null
function Get-PsBinary {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:PsBinary) { return $script:PsBinary }
    $cmd = Get-Command ps -ErrorAction SilentlyContinue
    if ($cmd) { $script:PsBinary = $cmd.Source }
    else {
        $fallbacks = @('/bin/ps', '/usr/bin/ps')
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            $fallbacks = @(Get-BuildDefault -Key 'PsBinaryFallbackPaths' -Fallback @('/bin/ps', '/usr/bin/ps'))
        }
        foreach ($p in $fallbacks) {
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf -ErrorAction SilentlyContinue)) {
                $script:PsBinary = $p; break
            }
        }
    }
    return $script:PsBinary
}

# Linux: /proc/<pid>/cmdline (NUL-separated, no ps needed). macOS: ps fallback.
function Get-UnixProcessCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$ProcessId)
    $cmdlinePath = "/proc/$ProcessId/cmdline"
    if (Test-Path -LiteralPath $cmdlinePath -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($cmdlinePath)
            if ($bytes -and $bytes.Length -gt 0) {
                return [System.Text.Encoding]::UTF8.GetString($bytes).Replace([char]0, ' ').Trim()
            }
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.env.procDecodeFallback' -MessageArgs @([string]$ProcessId) -Fallback 'UTF-8 decode fallback for /proc/{0}/cmdline') -Color DarkGray -Level DEBUG
            }
        }
    }
    $psBin = Get-PsBinary
    if ($psBin) {
        $cmdline = (& $psBin -p $ProcessId -o command= 2>$null)
        if ($cmdline) { return ($cmdline -join ' ').Trim() }
    }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return $null
}

# Build parent->children map from a single `ps -o pid=,ppid=` call (Linux + macOS).
function Get-UnixProcessTreeMap {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[int, object]])]
    param()
    $map = [System.Collections.Generic.Dictionary[int, object]]::new()
    $psBin = Get-PsBinary
    if (-not $psBin) { return $map }
    $rows = (& $psBin -e -o pid=,ppid= 2>$null)
    foreach ($row in $rows) {
        if (-not $row) { continue }
        $parts = ($row.Trim() -split '\s+')
        if ($parts.Count -lt 2) { continue }
        $childId = 0; $parentId = 0
        if (-not [int]::TryParse($parts[0], [ref]$childId)) { continue }
        if (-not [int]::TryParse($parts[1], [ref]$parentId)) { continue }
        if (-not $map.ContainsKey($parentId)) { $map[$parentId] = [System.Collections.Generic.List[int]]::new() }
        $map[$parentId].Add($childId)
    }
    return $map
}

# BFS descendants of RootId using the pre-built tree map.
function Get-UnixProcessDescendants {
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)]$Tree,
        [Parameter(Mandatory)][int]$RootId
    )
    $result = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($Tree.ContainsKey($cur)) {
            foreach ($childId in $Tree[$cur]) {
                if ($result.Contains($childId)) { continue }
                $result.Add($childId)
                $queue.Enqueue($childId)
            }
        }
    }
    return $result.ToArray()
}

# OS-aware lookup of a process's full command line. Used to identify a leftover
# process from a previous build of OUR project even when it hosts the app under a
# runtime host (e.g. `dotnet MultiAiAgent.dll --urls=http://localhost:5104` runs as
# dotnet.exe, so name/exe-match misses it). Falls back to the process name when the
# command line cannot be read -- never throws.
function Get-ProcessCommandLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        if ($script:OS -eq 'Windows') {
            $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
            if ($cim -and $cim.CommandLine) { return [string]$cim.CommandLine }
            return $null
        } elseif ($script:OS -eq 'Linux' -or $script:OS -eq 'MacOS') {
            # Single source: Get-UnixProcessCommandLine (/proc first, ps fallback,
            # process-name last resort) — no inline duplicate of that logic here.
            return Get-UnixProcessCommandLine -ProcessId $ProcessId
        }
    } catch {
        # benign: command-line read failed; caller falls back to name matching
    }
    return $null
}

# -- Environment Model (Phase 14) ----------------------------------------------
$script:EnvironmentModel = $null

<#
.SYNOPSIS
    Initializes a comprehensive environment model (OS, shell, SDKs, tools, paths).
.DESCRIPTION
    Detects host OS, architecture, PowerShell version, .NET SDKs, Node.js, Python,
    Go, Rust, Java, Docker, and package managers. Stores the result for fast access.
    PS 5.1 safe (no $IsWindows standalone, no classes).
#>
function Initialize-EnvironmentModel {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)

    $os = Get-OSPlatform
    $arch = try {
        [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    } catch {
        if ($os -eq 'Windows') { $env:PROCESSOR_ARCHITECTURE } else { 'Unknown' }
    }

    $dotnetVer = Write-ErrorSafe -ScriptBlock { & dotnet --list-sdks 2>$null | Select-Object -First 1 } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'dotnet') -Fallback 'SDK not detected: dotnet')
    $nodeVer   = Write-ErrorSafe -ScriptBlock { & node --version 2>$null } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'node') -Fallback 'SDK not detected: node')
    $pythonVer = Write-ErrorSafe -ScriptBlock { & python --version 2>$null } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'python') -Fallback 'SDK not detected: python')
    $goVer     = Write-ErrorSafe -ScriptBlock { & go version 2>$null | ForEach-Object { ($_ -split '\s+')[-1] } } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'go') -Fallback 'SDK not detected: go')
    $rustVer   = Write-ErrorSafe -ScriptBlock { & rustc --version 2>$null | ForEach-Object { ($_ -split ' ')[1] } } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'rustc') -Fallback 'SDK not detected: rustc')
    $javaVer   = Write-ErrorSafe -ScriptBlock { & java -version 2>&1 | Select-Object -First 1 } -Message (Resolve-LogMessage -Key 'log.sdk.notDetected' -MessageArgs @([string]'java') -Fallback 'SDK not detected: java')
    $sdkObj = [PSCustomObject]@{
        Dotnet = $dotnetVer; Node = $nodeVer; Python = $pythonVer
        Go = $goVer; Rust = $rustVer; Java = $javaVer
    }

    $model = [PSCustomObject]@{
        GeneratedAt = [datetime]::UtcNow.ToString('o')
        Host        = [PSCustomObject]@{
            OS           = $os
            Architecture = $arch
            PSVersion    = $PSVersionTable.PSVersion.ToString()
            PSEdition    = $PSVersionTable.PSEdition
            IsAdmin      = try {
                if ($os -eq 'Windows') {
                    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                    ([System.Security.Principal.WindowsPrincipal]$id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
                } else {
                    # `id` is an external binary, so it may be absent (a minimal
                    # container with no coreutils) or may print to stderr. A bare
                    # `(id -u)` under a non-terminating-failure default evaluates
                    # to $false, i.e. "not root", silently - so a root user in a
                    # slim image was reported as non-admin and lost the elevation
                    # decisions that depend on it. Probe for the tool first, then
                    # require a clean integer answer; anything ambiguous stays
                    # $false, which is the fail-closed direction.
                    $isRoot = $false
                    $idCmd = Get-Command 'id' -ErrorAction SilentlyContinue
                    if ($idCmd) {
                        try {
                            $uidOut = (& $idCmd -u 2>$null | Out-String).Trim()
                            if ($uidOut -match '^\d+$') { $isRoot = ([int]$uidOut -eq 0) }
                        } catch { $isRoot = $false }
                    }
                    $isRoot
                }
            } catch { $false }
        }
        SDKs        = $sdkObj
        Tools       = [PSCustomObject]@{
            Docker   = [bool](Get-Command docker -ErrorAction SilentlyContinue)
            Git      = [bool](Get-Command git -ErrorAction SilentlyContinue)
            NuGet    = [bool](Get-Command nuget -ErrorAction SilentlyContinue)
            Npm      = [bool](Get-Command npm -ErrorAction SilentlyContinue)
            Pip      = [bool](Get-Command pip -ErrorAction SilentlyContinue)
            Cargo    = [bool](Get-Command cargo -ErrorAction SilentlyContinue)
            Gradle   = [bool](Get-Command gradle -ErrorAction SilentlyContinue)
            Maven    = [bool](Get-Command mvn -ErrorAction SilentlyContinue)
            Ssh      = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
        }
        Paths       = [PSCustomObject]@{
            Home      = if ($os -eq 'Windows') { $env:USERPROFILE } else { $env:HOME }
            Temp      = [System.IO.Path]::GetTempPath()
            ScriptRoot = if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot') { $State.ScriptRoot } else { Split-Path $PSScriptRoot -Parent }
        }
    }

    $script:EnvironmentModel = $model
    return $model
}

<#
.SYNOPSIS
    Returns the cached environment model, or initializes one if not yet built.
#>
function Get-EnvironmentModel {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)

    if (-not $script:EnvironmentModel) {
        return Initialize-EnvironmentModel -State $State
    }
    return $script:EnvironmentModel
}

<#
.SYNOPSIS
    Level 5 single-source HTTP readiness probe (one GET, timeout-bounded).
.DESCRIPTION
    Central implementation for all readiness layers so HttpClient/HttpWebRequest
    branching lives in exactly one place:
      - Deploy.Test-UrlServing (fast single probe, used by Test-WebAppReady loop)
      - DeployTargets.Test-DeployHealth (retry wrapper around this probe)
      - HealthCheck endpoint checks (via Test-PortListening + this)
    Any HTTP response (any status) = serving. Timeout from
    BuildConstants.WebProbeTimeoutMs (config-overridable). Never throws.
#>
function Test-HttpEndpoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][string]$Url = '',
        [int]$TimeoutMs = 0,
        [PSCustomObject]$State = $null
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($TimeoutMs -le 0) {
        $TimeoutMs = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'WebProbeTimeoutMs' -State $State -Fallback 700) } else { 700 }
    }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
    try {
        if ([System.Net.Http.HttpClient] -as [type]) {
            $hc = [System.Net.Http.HttpClient]::new()
            $hc.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
            try {
                $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
                $resp = $hc.SendAsync($msg, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $resp.Dispose()
                return $true
            } finally { $hc.Dispose() }
        }
    } catch { }
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        $resp2 = $req.GetResponse()
        $resp2.Dispose()
        return $true
    } catch { return $false }
}

<#
.SYNOPSIS
    Exports the environment model to a JSON file.
.PARAMETER Path
    Output file path (defaults to env-model.json in ScriptRoot).
#>
# NOTE: do not export the IsWindows/IsMacOS/IsLinux variables to outer scope.
# Export -Variable pollutes the global session, overrides/redefines PS7 automatic variables,
# and Remove-Module would delete pre-existing global variables (breaking PlatformShim in tests).
# Only export the Get-OSPlatform function — modules compute their own $script:IsWindows via it.
Export-ModuleMember -Function @('Invoke-CompatibleChildItem', 'Get-SafePath', 'Save-JsonSafe', 'Read-JsonSafe',
    'Get-OSPlatform', 'Open-Target', 'Get-AvailableDrives', 'Get-RuntimeIdentifier', 'Test-PortListening',
    'Test-PortBindable', 'Wait-PortRelease', 'Get-PortOwnerProcess', 'Get-ProcessCommandLine', 'Register-TempFile', 'Get-EnvironmentModel',
    'Get-PsBinary', 'Get-UnixProcessCommandLine', 'Get-UnixProcessTreeMap', 'Get-UnixProcessDescendants', 'Test-HttpEndpoint')




