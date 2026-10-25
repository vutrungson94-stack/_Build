# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

param(
    [string]$SourceDir,
    [string]$OutputDir,
    [string]$ArchiveName = 'build-output',
    [switch]$Zip,
    [switch]$Directory,
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

function Resolve-StepPath {
    param([string]$Base, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f\x7f]') { return '' }
    try {
        $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
        $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $baseFull $Path }
        return [System.IO.Path]::GetFullPath($candidate)
    } catch { return '' }
}

<#
.SYNOPSIS
    True when a publish path is inside Root and behind no junction/symlink.
.DESCRIPTION
    Prefers the single-source guards in Modules\PathUtils.psm1
    (Test-PathUnderRoots + Test-NoReparsePointInPath) when that module is
    available. The inline copy this replaced stopped its reparse walk BEFORE the
    volume root (a SUBST drive passed) and used Get-Item -ErrorAction Stop (an
    unreadable intermediate directory turned a valid path into a rejection). The
    local fallback is retained so the step still works when the module cannot be
    imported (PS 5.1 orphan), and the module presence is detected, not assumed.
#>
function Test-StepOutputPath {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    if ((Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) -and (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue)) {
        try {
            if (-not (Test-PathUnderRoots -Path $Path -AllowedRoots @($Root))) { return $false }
            return [bool](Test-NoReparsePointInPath -Path $Path)
        } catch { return $false }
    }
    # Fail closed. This was the sixth copy of the containment + reparse walk
    # (Android, CacheProvider, Deploy, DeployTargets, Distributed and this
    # step), each with its own hand-inlined copy of PathUtils' canonical rule.
    # The safe answer when that single source is unavailable is to refuse the
    # path - an archive must never be written outside its declared root.
    return $false
}

function Test-StepPathUnderAny {
    param([string]$Path, [string[]]$Roots)
    foreach ($candidateRoot in @($Roots)) {
        if (Test-StepOutputPath -Path $Path -Root $candidateRoot) { return $true }
    }
    return $false
}

# Thin forward to the shared owner (SharedUtils.Move-BuildFileAtomic). This was
# a second private copy of the Replace/backup/delete shape.
function Move-StepFileAtomic {
    param([string]$Source, [string]$Destination)
    if (-not (Move-BuildFileAtomic -Source $Source -Destination $Destination)) {
        throw (Resolve-LogMessage -Key 'log.publish-artifact.line80' -Fallback "Failed to move '$Source' to '$Destination' atomically.")
    }
}

$root = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
$safeRoots = @($root)
if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $safeRoots += [string]$State.ProjectRoot }
if ($State -and $State.PSObject.Properties.Name -contains 'WorkingDir' -and $State.WorkingDir) { $safeRoots += [string]$State.WorkingDir }
if (-not $SourceDir) {
    $publishOutput = Resolve-ConfigValue -State $State -Path 'paths.publishOutput' -Default (Get-BuildConstant -Key 'PublishOutputDir' -Fallback 'publish-output')
    $SourceDir = Resolve-StepPath -Base $root -Path $publishOutput
}
$SourceDir = Resolve-StepPath -Base $root -Path $SourceDir
if (-not $SourceDir -or -not (Test-StepPathUnderAny -Path $SourceDir -Roots $safeRoots)) { Write-Log (Resolve-LogMessage -Key 'log.artifact.sourceContainmentFailed' -MessageArgs @([string]$SourceDir) -Fallback '[ARTIFACT] Source failed containment validation: {0}') 'Err' $State; exit 1 }
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { Write-Log (Resolve-LogMessage -Key 'log.artifact.sourceNotFound' -MessageArgs @([string]$SourceDir) -Fallback '[ARTIFACT] Source not found: {0}') 'Err' $State; exit 1 }
if (Test-ReparsePointItem -Path $SourceDir) { Write-Log (Resolve-LogMessage -Key 'log.artifact.reparseSourceRejected' -Fallback '[ARTIFACT] Reparse-point source is not accepted.') 'Err' $State; exit 1 }
try {
    $sourceEntries = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -Force -ErrorAction Stop)
    if (@($sourceEntries | Where-Object { Test-ReparsePointItem -Path $_.FullName }).Count -gt 0) { Write-Log (Resolve-LogMessage -Key 'log.artifact.reparseEntriesRejected' -Fallback '[ARTIFACT] Reparse-point entries are not accepted.') 'Err' $State; exit 1 }
} catch {
    Write-Log (Resolve-LogMessage -Key 'log.artifact.scanFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[ARTIFACT] Source scan failed: {0}') 'Err' $State
    exit 1
}
if (-not $OutputDir) { $OutputDir = Join-Path $root (Get-BuildConstant -Key 'ReportOutputDir' -Fallback 'build-reports') }
$OutputDir = Resolve-StepPath -Base $root -Path $OutputDir
if (-not $OutputDir -or -not (Test-StepPathUnderAny -Path $OutputDir -Roots $safeRoots)) { Write-Log (Resolve-LogMessage -Key 'log.artifact.invalidOutputDir' -Fallback '[ARTIFACT] Invalid output directory.') 'Err' $State; exit 1 }
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null }
if (Test-ReparsePointItem -Path $OutputDir) { Write-Log (Resolve-LogMessage -Key 'log.artifact.reparseOutputRejected' -Fallback '[ARTIFACT] Reparse-point output is not accepted.') 'Err' $State; exit 1 }
$archiveLeaf = [System.IO.Path]::GetFileName($ArchiveName.Replace('\', '/'))
if (-not $archiveLeaf -or $archiveLeaf -ne $ArchiveName.Replace('\', '/') -or $archiveLeaf -eq '.' -or $archiveLeaf -eq '..' -or $archiveLeaf -match '[\x00-\x1f\x7f]') { Write-Log (Resolve-LogMessage -Key 'log.artifact.invalidArchiveName' -Fallback '[ARTIFACT] Invalid archive name.') 'Err' $State; exit 1 }
try {
    if ($Zip -or (-not $Directory)) {
        $zipPath = Join-Path $OutputDir ($archiveLeaf + '.zip')
        if (-not (Test-StepOutputPath -Path $zipPath -Root $OutputDir)) { throw (Resolve-LogMessage -Key 'log.publish-artifact.line113' -Fallback 'Archive path escaped output directory') }
        $tempZip = Join-Path $OutputDir ('.artifact-' + [guid]::NewGuid().ToString('N') + '.zip')
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $tempZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
            Move-StepFileAtomic -Source $tempZip -Destination $zipPath
        } finally { if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue } }
        Write-Log (Resolve-LogMessage -Key 'log.artifact.archiveCreated' -MessageArgs @([string]$zipPath) -Fallback '[ARTIFACT] Archive created: {0}') 'Info' $State
    }
    if ($Directory) {
        $destDir = Join-Path $OutputDir $archiveLeaf
        if (-not (Test-StepOutputPath -Path $destDir -Root $OutputDir)) { throw (Resolve-LogMessage -Key 'log.publish-artifact.line124' -Fallback 'Directory path escaped output directory') }
        $tempDir = Join-Path $OutputDir ('.artifact-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction Stop | Out-Null
            Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction Stop | Copy-Item -Destination $tempDir -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force -ErrorAction Stop }
            [System.IO.Directory]::Move($tempDir, $destDir)
        } finally { if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } }
        Write-Log (Resolve-LogMessage -Key 'log.artifact.dirCopied' -MessageArgs @([string]$destDir) -Fallback '[ARTIFACT] Directory copied: {0}') 'Info' $State
    }
} catch {
    Write-Log (Resolve-LogMessage -Key 'log.artifact.createFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[ARTIFACT] Artifact creation failed: {0}') 'Err' $State
    exit 1
}

