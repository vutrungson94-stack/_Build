# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

param(
    [string]$Path,
    [string]$OutputDir,
    [string]$KeyId,
    [switch]$DetachSign,
    [PSCustomObject]$State
)
Set-StrictMode -Version 1.0
# Self-healing bootstrap (standalone-safe). Single owner:
# Modules/StepBootstrap.ps1. When this script runs outside an Orchestrator
# session the shared libs are absent; that file walks up to the _Build root and
# imports them. No-op inside a normal gbuild run.
$__gbuildModulesDir = Split-Path -Parent $PSScriptRoot
$__gbuildStepBootstrap = Join-Path $__gbuildModulesDir 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildStepBootstrap -PathType Leaf) {
    . $__gbuildStepBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildModulesDir, __gbuildStepBootstrap -ErrorAction SilentlyContinue
$State = Resolve-BuildState $State

function Resolve-SignPath {
    param([string]$Path, [string]$Base = '')
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f\x7f]') { return '' }
    try {
        if (-not [string]::IsNullOrWhiteSpace($Base) -and -not [System.IO.Path]::IsPathRooted($Path)) {
            $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
            return [System.IO.Path]::GetFullPath((Join-Path $baseFull $Path))
        }
        return [System.IO.Path]::GetFullPath($Path)
    } catch { return '' }
}

function Test-SignPathUnder {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    if ((Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) -and (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue)) {
        try {
            if (-not (Test-PathUnderRoots -Path $Path -AllowedRoots @($Root))) { return $false }
            return [bool](Test-NoReparsePointInPath -Path $Path)
        } catch { return $false }
    }
    try {
        $p = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
        $r = ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\', '/')
        $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison } else { [System.StringComparison]::OrdinalIgnoreCase }
        return (($p -eq $r) -or $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, $cmp))
    } catch { return $false }
}

if (-not $Path) { Write-Log (Resolve-LogMessage -Key 'log.sign.usage' -Fallback '[SIGN] Usage: -Path <file-or-dir> [-KeyId <gpg-key>] [-DetachSign]') 'Warn' $State; exit 1 }
$Path = Resolve-SignPath -Path $Path
if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Write-Log (Resolve-LogMessage -Key 'log.sign.pathNotFound' -Fallback '[SIGN] Path not found.') 'Err' $State; exit 1 }
if (Test-ReparsePointItem -Path $Path) { Write-Log (Resolve-LogMessage -Key 'log.sign.reparsePathsRejected' -Fallback '[SIGN] Reparse-point paths are not accepted.') 'Err' $State; exit 1 }
if (-not $OutputDir) { $OutputDir = Split-Path -Parent $Path }
$OutputDir = Resolve-SignPath -Path $OutputDir
if (-not $OutputDir) { Write-Log (Resolve-LogMessage -Key 'log.sign.invalidOutputDir' -Fallback '[SIGN] Invalid output directory.') 'Err' $State; exit 1 }
$allowedRoots = @((Split-Path -Parent $Path))
if ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { $allowedRoots += [string]$State.ScriptRoot }
if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $allowedRoots += [string]$State.ProjectRoot }
$outputAllowed = $false
foreach ($allowedRoot in $allowedRoots) { if (Test-SignPathUnder -Path $OutputDir -Root $allowedRoot) { $outputAllowed = $true; break } }
if (-not $outputAllowed) { Write-Log (Resolve-LogMessage -Key 'log.sign.outputContainmentFailed' -Fallback '[SIGN] Output directory failed containment validation.') 'Err' $State; exit 1 }
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $OutputDir) } else { New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null } }
try {
    $pathItem = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($pathItem.PSIsContainer) {
        $treeEntries = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
        if (@($treeEntries | Where-Object { Test-ReparsePointItem -Path $_.FullName }).Count -gt 0) { Write-Log (Resolve-LogMessage -Key 'log.sign.reparseEntriesRejected' -Fallback '[SIGN] Reparse-point entries are not accepted.') 'Err' $State; exit 1 }
        # SURVIVAL FALLBACK, deliberately NOT a copy of
        # BuildConstants.SignArtifactExtensions. SignArtifactExtensions stays the
        # single source for the real filter, so editing it needs one edit - but
        # the fallback only runs when BuildConstants cannot be loaded at all, and
        # it must not be Windows-shaped while it is. The previous
        # @('.exe','.dll','.zip') listed three Windows families only, so a
        # degraded run on Linux/macOS matched no .so/.dylib/.jar, signed nothing,
        # and still exited 0 - a filter that silently excludes, reported as
        # success. This list spans the deployable families per platform; it
        # intentionally omits .pdb/.xml/.map (debug/documentation output) for the
        # same reason SignArtifactExtensions omits them.
        $signExts = @(
            '.exe', '.dll', '.msi', '.msix', '.appx', '.appxbundle'
            '.zip', '.nupkg', '.snupkg', '.jar', '.war'
            '.so', '.dylib', '.a', '.o'
            '.apk', '.aab', '.ipa', '.pkg', '.app', '.wasm', '.deb', '.rpm'
        )
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $configured = @(Get-BuildConstant -Key 'SignArtifactExtensions' -State $State -Fallback $signExts) } catch { $configured = @() }
            if ($configured.Count -gt 0) { $signExts = $configured }
        }
        $items = @($treeEntries | Where-Object { -not $_.PSIsContainer -and $_.Extension -in $signExts })
    } else { $items = @($pathItem) }
} catch {
    Write-Log (Resolve-LogMessage -Key 'log.sign.enumerateFailed' -Fallback '[SIGN] Failed to enumerate input path.') 'Err' $State
    exit 1
}
$gpgTool = Get-Command 'gpg','gpg2' -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
if (-not $gpgTool) { Write-Log (Resolve-LogMessage -Key 'log.sign.gpgNotFound' -Fallback '[SIGN] GPG not found. Install gnupg.') 'Err' $State; exit 1 }
$gpgCmd = $gpgTool.Source
$gpgArgs = if ($DetachSign) { @('--detach-sign','--armor') } else { @('--clearsign') }
if ($KeyId) { $gpgArgs += @('--default-key',$KeyId) }
$failed = $false
foreach ($item in $items) {
    $itemPath = Resolve-SignPath -Path $item.FullName
            if (-not $itemPath -or (Test-ReparsePointItem -Path $itemPath)) { $failed = $true; continue }
    $sigName = if ($DetachSign) { "$($itemPath).sig" } else { "$($itemPath).asc" }
    $tempSig = Join-Path $OutputDir ('.gpg-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        & $gpgCmd @gpgArgs -o $tempSig $itemPath 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempSig -PathType Leaf)) { $failed = $true; Write-Log (Resolve-LogMessage -Key 'log.sign.itemFailed' -MessageArgs @([string]$item.Name) -Fallback '[SIGN] Failed: {0}') 'Err' $State; continue }
        $sigFile = Join-Path $OutputDir ([System.IO.Path]::GetFileName($sigName))
        if (-not (Test-SignPathUnder -Path $sigFile -Root $OutputDir)) { $failed = $true; continue }
        try {
            if (-not (Move-BuildFileAtomic -Source $tempSig -Destination $sigFile)) { $failed = $true; continue }
            $tempSig = $null
            Write-Log (Resolve-LogMessage -Key 'log.sign.signed' -MessageArgs @([string]$item.Name, $sigFile) -Fallback '[SIGN] Signed: {0} -> {1}') 'Info' $State
        } finally {
            if ($tempSig -and (Test-Path -LiteralPath $tempSig)) { Remove-Item -LiteralPath $tempSig -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $failed = $true
        Write-Log (Resolve-LogMessage -Key 'log.sign.failed' -MessageArgs @([string]$item.Name) -Fallback '[SIGN] Failed: {0}') 'Err' $State
    } finally { if (Test-Path -LiteralPath $tempSig) { Remove-Item -LiteralPath $tempSig -Force -ErrorAction SilentlyContinue } }
}
if ($failed) { exit 1 }
exit 0


