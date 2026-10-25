# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ========================================================================
# ModuleBootstrap.ps1 — single reusable import bootstrap (centralized).
#
# Dot-source from any module to load BuildImport (Logging) + dependencies in
# one line, replacing the duplicated 2-line `$buildImportPath` preamble and
# the scattered `Import-BuildDependencies -Modules @(...)` calls:
#
#   . (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Environment','Project')
#
# Why dot-source (not a function)? So the helper runs WITHOUT BuildImport
# needing to be pre-loaded first — it self-loads BuildImport here using its
# own $PSScriptRoot, then delegates to Import-BuildDependencies. This makes
# it safe for both the gbuild bootstrap flow AND standalone Import-Module.
# ========================================================================
param(
    [string[]]$Dependencies = @()
)

$buildImportPath = Join-Path $PSScriptRoot 'BuildImport.psm1'
if (Test-Path $buildImportPath) {
    $null = Import-Module $buildImportPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

if (Get-Command Import-BuildDependencies -ErrorAction SilentlyContinue) {
    Import-BuildDependencies -Modules $Dependencies
} else {
    # Fallback when BuildImport is missing or failed to load: minimal inline
    # loader so standalone module imports do not hard-fail on the BuildImport SPOF.
    # Mirrors Import-GBuildModule + Import-BuildDependencies core behavior.
    foreach ($dep in $Dependencies) {
        $depPath = Join-Path $PSScriptRoot ($dep + '.psm1')
        if (Test-Path $depPath) {
            Import-Module $depPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    # Ensure Logging is available for Write-Log guards even in fallback path.
    $loggingPath = Join-Path $PSScriptRoot 'Logging.psm1'
    if ((-not (Get-Module -Name 'Logging' -ErrorAction SilentlyContinue)) -and (Test-Path $loggingPath)) {
        $null = Import-Module $loggingPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

# ========================================================================
# Import-GBuildModuleIfMissing — shared guard for standalone module imports.
# Replaces the duplicated per-module preambles of the form:
#   if (-not (Get-Command <Sentinel> ...)) { Import-Module <Name>.psm1 -Global ... }
# Idempotent: imports only when $SentinelCommand cannot yet be resolved in the session.
# Note: dot-sourced into each module, so it must NOT leak into the API exports.
# ========================================================================
function Import-GBuildModuleIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SentinelCommand
    )
    if (Get-Command $SentinelCommand -ErrorAction SilentlyContinue) { return }
    $depPath = Join-Path $PSScriptRoot ($Name + '.psm1')
    if (Test-Path $depPath) {
        Import-Module $depPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

# ========================================================================
# Initialize-BuildSharedUtils — single owner of the "make sure SharedUtils is
# loaded" step.
#
# SharedUtils is the foundation for the atomic text write, the file lock and the
# config read helpers, but it is NOT loaded by ModuleBootstrap itself, so a
# module that uses one of those helpers standalone has to import it lazily.
# That lazy-import block was written out 11 times across 4 modules
# (AnomalyDetector x3, AutoTuner x3, RootCause x3, Logging, Standalone) - nine
# of them byte-identical. One owner here removes the copy-paste and the risk of
# the copies drifting.
#
# Returns nothing unless -PassThru is given. This is deliberate: an earlier
# revision returned a bare $true, and a caller that forgot to discard it emitted
# "True" into that function's output stream. In Read-RootCauseLines and its two
# siblings that value became a literal history line, so 6 concurrent appends
# wrote 12 rows. A loader helper must be invisible to the pipeline.
function Initialize-BuildSharedUtils {
    [CmdletBinding()]
    param(
        [string]$SentinelCommand = 'Get-BuildTextLines',
        [switch]$PassThru
    )
    $ok = $false
    if (Get-Command $SentinelCommand -ErrorAction SilentlyContinue) { $ok = $true }
    else {
        $sharedUtilsPath = Join-Path $PSScriptRoot 'SharedUtils.psm1'
        if (Test-Path -LiteralPath $sharedUtilsPath -PathType Leaf) {
            Import-Module $sharedUtilsPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
        $ok = [bool](Get-Command $SentinelCommand -ErrorAction SilentlyContinue)
    }
    if ($PassThru) { return $ok }
}

# =====================================================================
# Enter-BuildFileLockOrThrow — single owner for "make sure SharedUtils is
# loaded, take the lock, and fail loudly if it cannot be taken".
#
# Six modules needed exactly this and each wrote its own copy of the same
# three-step preamble: ensure SharedUtils, probe for the sentinel, call
# Enter-BuildFileLock, then decide what an absent lock means. AnomalyDetector,
# AutoTuner and RootCause threw with their own wording; Cache and
# CacheProvider returned $null; AuditLedger threw AND had a duplicated
# try-throw-twice shape. Cache and CacheProvider also shipped two functions
# with the identical name Enter-CacheIndexLock.
#
# The lock PRIMITIVE was already shared (SharedUtils.Enter-BuildFileLock is
# the only module in the tree that opens a FileShare]::None stream, which
# the fileLockDelegation adoption class enforces). What was duplicated was
# the ACQUISITION POLICY around it - which is a bootstrap concern, so it
# lives here beside Initialize-BuildSharedUtils rather than in any consumer.
#
# Dot-sourced into each module, so it must NOT leak into the API exports.
# =====================================================================
function Enter-BuildFileLockOrThrow {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        # Mirrors BuildConstants.HistoryLockTimeoutMs (measured 15s budget).
        # Callers pass no literal here: the budget is owned in exactly one
        # place, and every explicit -TimeoutMs 5000 that used to sit at the
        # call sites has been removed so a future retune lands everywhere.
        [int]$TimeoutMs = 15000,
        # Human name of what is being locked, used only in the failure message
        # so the operator is told WHICH lock timed out.
        [string]$What = 'file',
        # Cache's index lock returns $null for an empty path instead of
        # throwing; that is a legitimate caller-side difference, so it is an
        # explicit switch rather than something each module re-decides.
        [switch]$ReturnNullOnEmptyPath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($ReturnNullOnEmptyPath) { return $null }
        throw (Resolve-LogMessage -Key 'log.modulebootstrap.lockNoPath' -MessageArgs @([string]$What) -Fallback "Cannot lock $What : no path was supplied.")
    }
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Enter-BuildFileLock')
    if (-not (Get-Command Enter-BuildFileLock -ErrorAction SilentlyContinue)) {
        throw (Resolve-LogMessage -Key 'log.modulebootstrap.sharedUtilsRequired' -MessageArgs @([string]$What) -Fallback "SharedUtils is required to lock $What but could not be loaded.")
    }
    $lock = Enter-BuildFileLock -Path $Path -TimeoutMs $TimeoutMs
    if ($null -eq $lock) {
        if ($ReturnNullOnEmptyPath) { return $null }
        throw (Resolve-LogMessage -Key 'log.modulebootstrap.lockTimeout' -MessageArgs @([string]$What, [string]$TimeoutMs, [string]$Path) -Fallback "Unable to lock $What within ${TimeoutMs}ms: $Path")
    }
    return $lock
}

# =====================================================================
# Shared history-file helpers. AnomalyDetector, AutoTuner and RootCause each
# carried the same lock/read/write wrapper triple, differing only in the lock
# label. Those nine wrappers are replaced by these three helpers: label and
# path stay caller-specific, while acquisition policy, retry-safe reads and
# atomic writes stay in one place.
# =====================================================================
function Enter-BuildHistoryLock {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HistoryName
    )
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildConstant')
    $timeout = 15000
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $timeout = [int](Get-BuildConstant -Key 'HistoryLockTimeoutMs' -Fallback 15000) } catch { }
    }
    return Enter-BuildFileLockOrThrow -Path $Path -TimeoutMs $timeout -What ("$HistoryName history")
}

function Read-BuildHistoryLines {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildTextLines')
    if (Get-Command Get-BuildTextLines -ErrorAction SilentlyContinue) { return @(Get-BuildTextLines -Path $Path) }
    return @()
}

function Write-BuildHistoryLines {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Write-BuildTextFileAtomic')
    if (Get-Command Write-BuildTextFileAtomic -ErrorAction SilentlyContinue) { return [bool](Write-BuildTextFileAtomic -Path $Path -Lines $Lines) }
    return $false
}

# ============================================================================
# Shared diagnostic path helpers (AnomalyDetector + RootCause). Moved here so
# the two modules do not carry byte-identical copies.
# ============================================================================
function Get-DiagnosticRoot {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    foreach ($name in @('ProjectRoot', 'WorkingDir', 'ScriptRoot')) {
        $value = if ($State) { [string](Get-SectionValue -Section $State -Key $name -Default '') } else { '' }
        if ($value) {
            try { if ($name -eq 'ScriptRoot' -and (Split-Path -Leaf $value) -ieq 'Modules') { return (Split-Path -Parent $value) } } catch { }
            return $value
        }
    }
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        return [string](Get-BuildRootDirectory -State $State)
    }
    throw (Get-LocaleMessage -Key 'log.diagnostic.noRoot')
}

function Resolve-DiagnosticPath {
    param([PSCustomObject]$State, [string]$Path)
    $root = Get-DiagnosticRoot $State
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $root $Path)) }
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($root))) { return '' }
    return $candidate
}
