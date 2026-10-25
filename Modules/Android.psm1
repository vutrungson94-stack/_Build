# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# ModuleBootstrap.ps1 self-loads BuildImport.psm1 (defines Import-GBuildModule /
# Import-BuildDependencies) before resolving -Dependencies.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# -- Import dependency modules (safe for both standalone and launcher loading) --
Import-BuildModule -Dependencies @('Environment')
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

# Import Android SDK Provider (single source for ADB/SDK discovery).
# Nested Join-Path (no backslash literal) so it resolves on Windows + Linux/macOS.
# Orchestrator Tier-1 already loads it globally; this is a standalone-import fallback.
if (-not (Get-Command Find-AdbPath -ErrorAction SilentlyContinue)) {
    $__androidProv = Join-Path (Join-Path $PSScriptRoot 'Providers') 'AndroidSdkProvider.psm1'
    if (Test-Path -LiteralPath $__androidProv) {
        Import-Module $__androidProv -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name __androidProv -Scope Script -ErrorAction SilentlyContinue
}

function Test-AndroidAppId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$AppId)

Set-StrictMode -Version 1.0
    return (-not [string]::IsNullOrWhiteSpace($AppId) -and $AppId.Length -le 255 -and $AppId -match '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
}

<#
.SYNOPSIS
    Resolves an Android path, refusing escapes and junction/symlink traversal.
.DESCRIPTION
    Delegates to PathUtils.Test-PathUnderRoots / Test-NoReparsePointInPath. The
    inline copy this replaced stopped its reparse walk BEFORE the volume root, so a
    SUBST drive or mapped share passed the junction check - exactly the case an
    Android SDK path (frequently a redirected/junctioned location) hits.
#>
function Resolve-AndroidContainedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Base, [string]$Path, [switch]$MustExist)
    # Delegates to PathUtils.Resolve-BuildContainedPath, the single owner of the
    # containment + reparse rule. This wrapper used to carry a third byte-comparable
    # copy of it; all copies already delegated the guards themselves, so what was
    # duplicated was the fail-closed plumbing around them.
    if ([string]::IsNullOrWhiteSpace($Base)) { return '' }
    if (-not (Get-Command Resolve-BuildContainedPath -ErrorAction SilentlyContinue)) {
        $pathUtilsPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
        if (Test-Path -LiteralPath $pathUtilsPath -PathType Leaf) {
            $null = Import-Module $pathUtilsPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    return (Resolve-BuildContainedPath -Path $Path -Base $Base -MustExist:$MustExist)
}

function Get-AndroidEnvironmentSecret {
    param([string[]]$Names)
    foreach ($name in @($Names)) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($value)) { return $value }
    }
    return ''
}

function Invoke-WithAndroidSecretEnvironment {
    param([string]$StorePassword, [string]$KeyPassword, [scriptblock]$ScriptBlock)
    $storeName = 'GBUILD_ANDROID_STORE_' + [guid]::NewGuid().ToString('N')
    $keyName = 'GBUILD_ANDROID_KEY_' + [guid]::NewGuid().ToString('N')
    $oldStore = [Environment]::GetEnvironmentVariable($storeName, [EnvironmentVariableTarget]::Process)
    $oldKey = [Environment]::GetEnvironmentVariable($keyName, [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable($storeName, $StorePassword, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable($keyName, $KeyPassword, [EnvironmentVariableTarget]::Process)
        return (& $ScriptBlock $storeName $keyName)
    } finally {
        [Environment]::SetEnvironmentVariable($storeName, $oldStore, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable($keyName, $oldKey, [EnvironmentVariableTarget]::Process)
    }
}

function Get-AndroidProjectDirectory {
    param([string]$ProjectDir)
    if ([string]::IsNullOrWhiteSpace($ProjectDir)) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($ProjectDir)
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return '' }
        return $full
    } catch { return '' }
}

# ==================================================================================
# Modules/Android.psm1
# ==================================================================================
function Find-AndroidKeystore {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,
        [string]$ProjectDir
    )
    $project = Get-AndroidProjectDirectory -ProjectDir $ProjectDir
    if (-not $project) { return $null }
    Write-Log (Get-LocaleMessage -Key 'log.android.searchKeystore') $State.Colors.Gray
    $propsFile = Join-Path $project 'signing.properties'
    $props = @{}
    if (Test-Path -LiteralPath $propsFile -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $propsFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*([^#=\s]+)\s*=\s*(.*)$') { $props[$matches[1].Trim()] = $matches[2].Trim() }
        }
        $storePath = Resolve-AndroidContainedPath -Base $project -Path ([string]$props['storeFile']) -MustExist
        if ($storePath -and (Test-Path -LiteralPath $storePath -PathType Leaf) -and ([System.IO.Path]::GetExtension($storePath) -in @('.keystore','.jks'))) {
            $isDebug = [System.IO.Path]::GetFileName($storePath) -eq 'debug.keystore'
            $storePass = Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_STORE_PASS','ANDROID_KEYSTORE_PASS')
            $keyPass = Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_KEY_PASS','ANDROID_KEY_PASS')
            if ($isDebug -and -not $storePass) { $storePass = [string](Get-BuildConstant -Key 'AndroidDebugStorePass' -State $State -Fallback 'android') }
            if ($isDebug -and -not $keyPass) { $keyPass = $storePass }
            $alias = [string]$props['keyAlias']
            if (-not $alias -and $isDebug) { $alias = [string](Get-BuildConstant -Key 'AndroidDebugAlias' -State $State -Fallback 'androiddebugkey') }
            if ($alias -and $alias -notmatch '^[A-Za-z0-9._-]+$') { return $null }
            return @{ Path = $storePath; StorePass = $storePass; Alias = $alias; KeyPass = $keyPass; Source = 'properties' }
        }
    }
    $keystore = Get-ChildItem -LiteralPath $project -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $relative = $_.FullName.Substring($project.Length).TrimStart('\', '/')
        $_.Extension -in @('.keystore','.jks') -and $relative -notmatch '(^|[\\/])(obj|bin)([\\/]|$)' -and -not (Test-ReparsePointItem -Path $_.FullName)
    } | Select-Object -First 1
    if ($keystore -and (Resolve-AndroidContainedPath -Base $project -Path $keystore.FullName -MustExist)) {
        $isDebug = $keystore.Name -eq 'debug.keystore'
        $storePass = if ($isDebug) { Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_STORE_PASS','ANDROID_KEYSTORE_PASS') } else { '' }
        $keyPass = if ($isDebug) { Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_KEY_PASS','ANDROID_KEY_PASS') } else { '' }
        if ($isDebug -and -not $storePass) { $storePass = [string](Get-BuildConstant -Key 'AndroidDebugStorePass' -State $State -Fallback 'android') }
        if ($isDebug -and -not $keyPass) { $keyPass = $storePass }
        $alias = if ($isDebug) { [string](Get-BuildConstant -Key 'AndroidDebugAlias' -State $State -Fallback 'androiddebugkey') } else { '' }
        return @{ Path = $keystore.FullName; StorePass = $storePass; Alias = $alias; KeyPass = $keyPass; Source = 'file' }
    }
    return $null
}

function New-DebugKeystore {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,
        [string]$ProjectDir
    )
    $project = Get-AndroidProjectDirectory -ProjectDir $ProjectDir
    if (-not $project) { return $null }
    $genPath = Resolve-AndroidContainedPath -Base $project -Path 'debug.keystore'
    $propsFile = Resolve-AndroidContainedPath -Base $project -Path 'signing.properties'
    if (-not $genPath -or -not $propsFile) { return $null }
    if (Test-ReparsePointItem -Path $genPath) { return $null }
    if (Test-ReparsePointItem -Path $propsFile) { return $null }
    Write-Log (Get-LocaleMessage -Key 'log.android.loadedProps' -MessageArgs @($propsFile)) $State.Colors.Gray $State
    Write-Log (Get-LocaleMessage -Key 'log.android.initKeystore') $State.Colors.Gray $State
    $javaSdk = [string]$State.JavaSdk
    if ([string]::IsNullOrWhiteSpace($javaSdk)) { return $null }
    try { $keytoolExe = [System.IO.Path]::GetFullPath((Join-Path $javaSdk ("bin" + [System.IO.Path]::DirectorySeparatorChar + 'keytool' + (Get-ExecutableExtension -State $State)))) } catch { return $null }
    if (-not (Test-Path -LiteralPath $keytoolExe -PathType Leaf)) {
        Write-Log (Get-LocaleMessage -Key 'log.android.keytoolNotFound' -MessageArgs $keytoolExe) $State.Colors.Err $State
        return $null
    }
    try {
        $storePass = Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_STORE_PASS','ANDROID_KEYSTORE_PASS')
        $keyPass = Get-AndroidEnvironmentSecret -Names @('GBUILD_ANDROID_KEY_PASS','ANDROID_KEY_PASS')
        if (-not $storePass) { $storePass = [string](Get-BuildConstant -Key 'AndroidDebugStorePass' -State $State -Fallback 'android') }
        if (-not $keyPass) { $keyPass = [string](Get-BuildConstant -Key 'AndroidDebugKeyPass' -State $State -Fallback 'android') }
        $alias = [string](Get-BuildConstant -Key 'AndroidDebugAlias' -State $State -Fallback 'androiddebugkey')
        $keySize = [int](Get-BuildConstant -Key 'AndroidDebugKeySize' -State $State -Fallback 2048)
        $validityDays = [int](Get-BuildConstant -Key 'AndroidDebugValidityDays' -State $State -Fallback 10000)
        $dname = [string](Get-BuildConstant -Key 'AndroidDebugDname' -State $State -Fallback 'CN=GBuild Debug, O=Development, C=VN')
        $ks = Get-ConfigSection -State $State -Path 'android.keystore'
        if ($ks) {
            if ($ks.alias) { $alias = [string]$ks.alias }
            if ($ks.keySize) { $keySize = [int]$ks.keySize }
            if ($ks.validityDays) { $validityDays = [int]$ks.validityDays }
            if ($ks.distinguishedName) { $dname = [string]$ks.distinguishedName }
        }
        if ($keySize -lt 1024 -or $validityDays -lt 1 -or $alias -notmatch '^[A-Za-z0-9._-]+$' -or $dname -match '[\x00-\x1f\x7f]') { return $null }
        $keytoolBaseArgs = @('-genkeypair','-v','-keystore',$genPath,'-alias',$alias,'-keyalg','RSA','-keysize',[string]$keySize,'-validity',[string]$validityDays,'-dname',$dname)
        $exitCode = 0
        $keytoolInvoker = {
            param($storeName, $keyName)
            $keytoolArgs = @($keytoolBaseArgs,'-storepass:env',$storeName,'-keypass:env',$keyName)
            & $keytoolExe @keytoolArgs 2>$null | Out-Null
            $script:AndroidKeytoolExitCode = [int]$LASTEXITCODE
        }.GetNewClosure()
        $null = Invoke-WithAndroidSecretEnvironment -StorePassword $storePass -KeyPassword $keyPass -ScriptBlock $keytoolInvoker
        $exitCode = if (Get-Variable -Name AndroidKeytoolExitCode -Scope Script -ErrorAction SilentlyContinue) { [int]$script:AndroidKeytoolExitCode } else { 1 }
        Remove-Variable -Name AndroidKeytoolExitCode -Scope Script -ErrorAction SilentlyContinue
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $genPath -PathType Leaf)) { throw (Resolve-LogMessage -Key 'log.android.line196' -MessageArgs @([string]$exitCode) -Fallback "Keytool failed with error code: $exitCode") }
        $propsContent = "storeFile=debug.keystore`nkeyAlias=$alias`n"
        # SharedUtils owns the temp-then-replace primitive. The inline
        # File.Replace + backup dance this replaced was a fifth copy of a
        # pattern that lives in exactly one place; the keystore properties file
        # is rewritten on every debug build, so a partial write there breaks
        # signing. No guarded fallback: SharedUtils is Tier-1, and a fallback
        # branch that can never execute reads as justification for the next
        # reader while never being exercised.
        if (-not (Write-BuildTextFileAtomic -Path $propsFile -Lines @(($propsContent -split "`r?`n")))) {
            throw (Resolve-LogMessage -Key 'log.android.line206' -MessageArgs @([string]$propsFile) -Fallback "Failed to write keystore properties atomically to $propsFile")
        }
        Write-Log (Get-LocaleMessage -Key 'log.android.keystoreGenerated') $State.Colors.Succ $State
        return @{ Path = $genPath; StorePass = $storePass; Alias = $alias; KeyPass = $keyPass; Source = 'generated' }
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.android.keystoreInitFailed' -MessageArgs $_.Exception.Message) $State.Colors.Err $State
        return $null
    }
}

# ADB/SDK discovery functions are now provided by AndroidSdkProvider.psm1
# This module retains keystore management and launcher activity detection.

function Get-LauncherActivity {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,
        [string]$AdbPath = "",
        [string]$Device = "",
        [string]$AppId = ""
    )
    if (-not (Test-AndroidAppId -AppId $AppId)) {
        Write-Log (Resolve-LogMessage -Key 'log.android.invalidAppId' -Fallback '[SIGN] Invalid Android application id.') 'Warn' $State
        return '.MainActivity'
    }
    if ([string]::IsNullOrWhiteSpace($AdbPath) -or -not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
        Write-Log (Get-LocaleMessage -Key 'log.android.adbUnavailableLauncher') $State.Colors.Warn $State
        return '.MainActivity'
    }
    if ($Device -and ($Device -match '[\x00-\x1f\x7f\s]')) { return '.MainActivity' }
    $adbArgs = @()
    if ($Device) { $adbArgs += @('-s',$Device) }
    $adbArgs += @('shell','cmd','package','resolve-activity','--brief',$AppId)
    $out = & $AdbPath @adbArgs 2>&1
    $line = $out | Select-String -Pattern ([regex]::Escape($AppId) + '/')
    if ($line) {
        $activity = ([string]$line.ToString() -split '/')[-1].Trim()
        if ($activity -match '^[A-Za-z0-9_.$]+$') {
            Write-Log (Get-LocaleMessage -Key 'log.android.foundActivity' -MessageArgs $activity) $State.Colors.Gray $State
            return $activity
        }
    }
    Write-Log (Get-LocaleMessage -Key 'log.android.activityNotFound' -MessageArgs $AppId) $State.Colors.Warn $State
    return '.MainActivity'
}

Export-ModuleMember -Function @(
    'Find-AndroidKeystore', 'New-DebugKeystore', 'Get-LauncherActivity'
)



