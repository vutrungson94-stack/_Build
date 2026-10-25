# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


<#
.SYNOPSIS
    Install-GBuild — Register gbuild as a global PowerShell function.
.DESCRIPTION
    Adds a global 'gbuild' function to your PowerShell $PROFILE so you can
    build any project from any directory without typing the full path.

    Supports three modes:
      1. Embedded  : _Build/ lives inside a project repo
      2. Portable  : _Build/ is standalone (USB, shared folder, separate clone)
      3. Project   : explicit -Project path

.EXAMPLE
    Install-GBuild -GbBuildHome 'G:\tools\gbuild'
    # After this, from any directory:
    #   gbuild                        # auto-detect project from cwd
    #   gbuild -Project E:\my-project # explicit project path
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$GbBuildHome
)

Set-StrictMode -Version 1.0

# Version and vendored-tools layout come from the platform's own constant
# registry so the installer and runtime resolver cannot disagree. They are
# resolved before the profile template is rendered; literals remain only for a
# partial copy where BuildConstants cannot be imported.
$analyzerVersion = '1.25.0'
$vendoredToolsRelative = '.tools/Modules'
try {
    $bcPath = Join-Path $GbBuildHome 'Modules/BuildConstants.psm1'
    if (Test-Path -LiteralPath $bcPath -PathType Leaf) {
        Import-Module $bcPath -Force -Global -DisableNameChecking -ErrorAction Stop
        $v = Get-BuildConstant -Key 'ScriptAnalyzerVersion' -Fallback ''
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $analyzerVersion = [string]$v }
        $r = Get-BuildConstant -Key 'VendoredToolsDirName' -Fallback $vendoredToolsRelative
        if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $vendoredToolsRelative = [string]$r }
    }
} catch { }

$profilePath = $PROFILE
if (-not $profilePath) {
    # Resolve the localized Windows Documents folder through the OS-known-folder
    # API rather than assuming an English "Documents" leaf. USERPROFILE alone
    # points at a localized folder incorrectly on non-English Windows.
    if ($env:USERPROFILE -and ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) {
        $documents = [System.Environment]::GetFolderPath('MyDocuments')
        if ([string]::IsNullOrWhiteSpace($documents)) { $documents = Join-Path $env:USERPROFILE 'Documents' }
        $profileDir = Join-Path $documents 'PowerShell'
    } elseif ($env:HOME) {
        $profileDir = Join-Path $env:HOME '.config/powershell'
    } else {
        # Fail closed: the old fallback walked ABOVE $HOME (Split-Path -Parent),
        # creating and writing a profile directory in the home directory's parent.
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.install.line62' -Fallback 'Cannot determine a PowerShell profile directory: $PROFILE, $env:USERPROFILE and $env:HOME are all empty. Set $PROFILE or pass an explicit profile path.'))
    }
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $profilePath = Join-Path $profileDir 'Microsoft.PowerShell_profile.ps1'
}
if (-not (Test-Path $profilePath)) {
    $null = New-Item -ItemType File -Path $profilePath -Force | Out-Null
}
$current = Get-Content $profilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$escapedHome = $GbBuildHome.Replace("'", "''")
$marker = "# gbuild -- portable build system"
$template = @'
# gbuild -- portable build system
if (-not (Test-Path Variable:global:GBuildHome) -or -not $global:GBuildHome) { $global:GBuildHome = '__GBUILD_HOME__' }
# Expose the bundled .tools modules (PSScriptAnalyzer from Install-GBuild) to this
        # session so IDE linting and PowerShell SAST scans find them without admin or a
        # per-machine PSModulePath.
        $_toolsModules = Join-Path $global:GBuildHome '__VENDORED_TOOLS_RELATIVE__'
if ((Test-Path $_toolsModules) -and ($env:PSModulePath -notlike "$_toolsModules*")) { $env:PSModulePath = "$_toolsModules$([System.IO.Path]::PathSeparator)$env:PSModulePath" }
if (-not (Get-Command gbuild -ErrorAction SilentlyContinue)) {
function gbuild {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
        param(
            [Parameter(Position=0)]
            [string]$Project = '',
            # Every alias here MUST match gbuild.ps1's param() block. This shim
            # is the CLI surface a user actually gets after installing, and it
            # declared none of the eight: `gbuild -gh` worked only by accident,
            # because ValueFromRemainingArguments swept `-gh` into
            # $AdditionalArgs and gbuild.ps1 happened to understand it there.
            # Tab-completion, Get-Command -Syntax and Get-Help all advertised a
            # DIFFERENT surface from the real entrypoint - a third launcher
            # contract, in a tool whose stated principle is one surface.
            [Alias('gh')][switch]$GitHub,
            [Alias('i')][switch]$Incremental,
            [Alias('c')][switch]$Clean,
            [Alias('cc')][switch]$CacheClear,
            [Alias('co')][switch]$CacheOptimize,
            [switch]$CacheStats,
            [switch]$VersionBump,
            [Alias('sec')][switch]$Security,
            [Alias('dist')][switch]$Distributed,
            [switch]$NonInteractive,
            [switch]$Force,
            [string]$Target = '',
            [string]$Locale = '',
            [switch]$SyntaxCheck,
            [switch]$License,
            [switch]$Help,
            [Alias('vrf')][switch]$VerifyInfra,
            [switch]$SelfTest,
            [string]$LogLevel = 'Info',
            [Parameter(ValueFromRemainingArguments)]
            [string[]]$AdditionalArgs
        )
        # GBuildHome may contain spaces (e.g. a "FIRST LAST" user profile); Join-Path handles it, and
        # PowerShell's call operator "&" preserves spaces in $Project.
        $script = Join-Path $global:GBuildHome 'gbuild.ps1'
        if (-not (Test-Path $script)) {
            Write-Error "[gbuild] gbuild.ps1 not found in $global:GBuildHome. Move the _Build folder or set `$global:GBuildHome to its new location."
            return
        }
        # When $Project is empty, -Project '' would be passed as explicit empty string
        # and gbuild.ps1 would treat it as "not specified" (whitespace check). To avoid
        # an unnecessary empty positional, only pass -Project when non-empty.
        # Same for -Locale: an explicit empty -Locale triggers the locale guide,
        # so only forward it when a value was given.
        # @localeFwd guard: gbuild.ps1 treats an EMPTY -Target as "Target guide" (prints
# the target catalog and exits 0 - see gbuild.ps1:81-82), and a non-bound
# -Target is "not specified". Following -Locale exactly: only forward when
# non-empty, otherwise gbuild.ps1 resolves from config. Without this, every
# 'gbuild' typed after install prints the catalog and never builds.
$localeFwd = if ([string]::IsNullOrWhiteSpace($Locale)) { @() } else { @('-Locale', $Locale) }
$targetFwd = if ([string]::IsNullOrWhiteSpace($Target)) { @() } else { @('-Target', $Target) }
        if ([string]::IsNullOrWhiteSpace($Project)) {
            & $script -GitHub:$GitHub -Incremental:$Incremental -Clean:$Clean -CacheClear:$CacheClear -CacheOptimize:$CacheOptimize -CacheStats:$CacheStats -VersionBump:$VersionBump -Security:$Security -Distributed:$Distributed -NonInteractive:$NonInteractive -Force:$Force @targetFwd @localeFwd -LogLevel $LogLevel -SelfTest:$SelfTest -SyntaxCheck:$SyntaxCheck -License:$License -Help:$Help -VerifyInfra:$VerifyInfra @AdditionalArgs
        } else {
            & $script -Project $Project -GitHub:$GitHub -Incremental:$Incremental -Clean:$Clean -CacheClear:$CacheClear -CacheOptimize:$CacheOptimize -CacheStats:$CacheStats -VersionBump:$VersionBump -Security:$Security -Distributed:$Distributed -NonInteractive:$NonInteractive -Force:$Force @targetFwd @localeFwd -LogLevel $LogLevel -SelfTest:$SelfTest -SyntaxCheck:$SyntaxCheck -License:$License -Help:$Help -VerifyInfra:$VerifyInfra @AdditionalArgs
        }
    }
    Set-Alias -Name gb -Value gbuild -Scope Global -ErrorAction SilentlyContinue
}
'@
$block = $template.Replace('__GBUILD_HOME__', $escapedHome).Replace('__VENDORED_TOOLS_RELATIVE__', $vendoredToolsRelative)
# -WhatIf / -Confirm are honoured: $PSCmdlet.ShouldProcess gates the profile
# edit so the installer never rewrites $PROFILE when the operator declines.
$profileAction = if ($current -match [regex]::Escape($marker)) { "update the existing gbuild block in $profilePath" } else { "add a gbuild function to $profilePath" }
if (-not $PSCmdlet.ShouldProcess($profilePath, $profileAction)) {
    Write-Host (Resolve-LogMessage -Key 'log.install.line153' -Fallback "[gbuild] profile not modified (-WhatIf / declined). Re-run without -WhatIf to install the gbuild function.") -ForegroundColor Yellow
    return
}
if ($current -match [regex]::Escape($marker)) {
    # Replace ONLY the previously installed gbuild block: lazy match from the marker up
# to (not including) the next profile entry ("\n# "), a blank line, or EOF.
# Singleline makes "." span newlines so multi-line blocks are replaced in one pass.
$blockPattern = [regex]::Escape($marker) + ".*?(?=`n# |`n`n|$)"
    $new = [regex]::Replace($current, $blockPattern, $block, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Set-Content -Path $profilePath -Value $new -Encoding UTF8
    Write-Host (Resolve-LogMessage -Key 'log.install.line163' -MessageArgs @([string]$profilePath) -Fallback "Updated existing gbuild function in $profilePath") -ForegroundColor Green
} else {
    Add-Content -Path $profilePath -Value "`n$block" -Encoding UTF8
    Write-Host (Resolve-LogMessage -Key 'log.install.line166' -MessageArgs @([string]$profilePath) -Fallback "Added gbuild function to $profilePath") -ForegroundColor Green
}
# --- Bundled PSScriptAnalyzer (portable, no admin or machine module store) ---
# $analyzerVersion and $vendoredToolsRelative were resolved from BuildConstants
# before the profile template was rendered above.
$toolsModuleDir = Join-Path $GbBuildHome $vendoredToolsRelative
$analyzerHome = Join-Path $toolsModuleDir 'PSScriptAnalyzer'
# Verify the BUNDLED VERSION, not just that a directory exists. The previous
# check only printed whatever subdirectory name it found first, so a partial or
# stale install - exactly the case a repair script must catch - was reported as
# "already bundled" and never redownloaded.
$foundVersion = $null
try { $foundVersion = Get-ChildItem $analyzerHome -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name } catch { $foundVersion = $null }
$analyzerPresent = ($foundVersion -eq $analyzerVersion) -and (Test-Path (Join-Path $analyzerHome $analyzerVersion))
if ($analyzerPresent) {
    Write-Host (Resolve-LogMessage -Key 'log.install.line181' -MessageArgs @([string]$analyzerVersion, [string]$foundVersion) -Fallback "[gbuild] PSScriptAnalyzer $analyzerVersion already bundled (.tools/Modules/PSScriptAnalyzer/$foundVersion)") -ForegroundColor Green
} elseif ($foundVersion) {
    Write-Host (Resolve-LogMessage -Key 'log.install.line183' -Fallback "[gbuild] PSScriptAnalyzer version mismatch: found '$foundVersion', want '$analyzerVersion'. Re-downloading ...") -ForegroundColor Yellow
    try { Remove-Item (Join-Path $analyzerHome $foundVersion) -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $foundVersion = $null
}
if (-not $analyzerPresent -and -not $foundVersion) {
    Write-Host (Resolve-LogMessage -Key 'log.install.line188' -MessageArgs @([string]$analyzerVersion) -Fallback "[gbuild] Downloading PSScriptAnalyzer $analyzerVersion into .tools/Modules ...") -ForegroundColor Cyan
    try {
        $null = New-Item -ItemType Directory -Path $toolsModuleDir -Force
        Save-Module -Name PSScriptAnalyzer -RequiredVersion $analyzerVersion -Path $toolsModuleDir -Repository PSGallery -ErrorAction Stop
        # Re-verify after the download so a silent partial fetch is not reported
        # as success.
        $after = Get-ChildItem $analyzerHome -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name
        if ($after -eq $analyzerVersion) {
            Write-Host (Resolve-LogMessage -Key 'log.install.line196' -MessageArgs @([string]$analyzerVersion) -Fallback "[gbuild] PSScriptAnalyzer $analyzerVersion bundled and verified (portable within _Build\.tools)") -ForegroundColor Green
        } else {
            Write-Host (Resolve-LogMessage -Key 'log.install.line198' -Fallback "[gbuild] WARN: download completed but '$analyzerVersion' was not found under .tools\Modules (got '$after'). PowerShell SAST will stay Skipped until it is installed.") -ForegroundColor Yellow
        }
    } catch {
        Write-Host (Resolve-LogMessage -Key 'log.install.line201' -MessageArgs @([string]$_.Exception.Message) -Fallback "[gbuild] SKIP: could not download PSScriptAnalyzer ($($_.Exception.Message)). It is optional - PowerShell SAST scans and IDE linting will be unavailable until it is bundled.") -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host (Resolve-LogMessage -Key 'log.install.line205' -Fallback "=== IMPORTANT ===") -ForegroundColor Cyan
Write-Host (Resolve-LogMessage -Key 'log.install.line206' -Fallback " Run this to use gbuild immediately:")
Write-Host "   . `$PROFILE"
Write-Host ""
Write-Host (Resolve-LogMessage -Key 'log.install.line209' -Fallback " Or start a new PowerShell window and type:")
Write-Host (Resolve-LogMessage -Key 'log.install.line210' -Fallback "   gbuild")
Write-Host ""
Write-Host (Resolve-LogMessage -Key 'log.install.line212' -MessageArgs @([string]$profilePath) -Fallback "If you move the _Build folder later, update `$global:GBuildHome in $profilePath")
Write-Host ""
Write-Host (Resolve-LogMessage -Key 'log.install.line214' -Fallback "Usage:")
Write-Host "   gbuild                        # auto-detect project from current directory"
Write-Host "   gbuild -Project /path/to/project # explicit project path"
Write-Host "   gb                            # alias for gbuild"
