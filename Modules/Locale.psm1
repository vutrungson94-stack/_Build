# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildDefault'

# NOTE: Locale deliberately does NOT import Logging — Logging already imports
# Locale (for Write-Log i18n), so importing back would create a circular
# dependency and hit the module nesting limit.

$script:LocaleMessages = @{
    'en' = [PSCustomObject]@{
        Done             = 'Completed'
        DoneWithTime     = 'Completed in {0}s'
        Fail             = 'Failed'
        FailWithTime     = 'Failed in {0}s'
        Processing       = 'Processing: {0}...'
        LoggingEnabled   = 'Logging enabled: {0}'
        StepRetry        = '{0} retry {1}/{2} after error: {3}'
        PipelineCancelled = 'Pipeline cancelled — skipping \''{0}\'''
        StepSkipped      = '{0} skipped (When condition false)'
        StepFailed       = '{0} failed: {1}'
        PipelineTimeout  = 'Pipeline timed out after {0}s at step \''{1}\'''
        StepTimeout      = 'Step \''{0}\'' timed out after {1}s'
        StepFailedJob    = 'Step \''{0}\'' failed in background job'
        BuildFailed      = 'Build failed: {0}'
        SecurityIssues   = 'Issues found - Critical={0}, High={1}, Medium={2}'
        NoSecurityIssues = 'No security issues found'
        # Runtime error strings (Steps/Hooks/bootstrap)
        GStateNotInitialized = 'GState not initialized.'
        RequiredModuleNotFound = 'Required module not found: {0}'
    }
    'vi' = [PSCustomObject]@{
        Done             = 'Hoàn thành'
        DoneWithTime     = 'Hoàn thành trong {0}s'
        Fail             = 'Thất bại'
        FailWithTime     = 'Thất bại trong {0}s'
        Processing       = 'Đang xử lý: {0}...'
        LoggingEnabled   = 'Logging đã bật: {0}'
        StepRetry        = '{0} thử lại {1}/{2} sau lỗi: {3}'
        PipelineCancelled = 'Pipeline bị hủy — bỏ qua \''{0}\'''
        StepSkipped      = '{0} bị bỏ qua (Điều kiện When false)'
        StepFailed       = '{0} thất bại: {1}'
        PipelineTimeout  = 'Pipeline timeout sau {0}s tại step \''{1}\'''
        StepTimeout      = 'Step \''{0}\'' timeout sau {1}s'
        StepFailedJob    = 'Step \''{0}\'' thất bại trong background job'
        BuildFailed      = 'Build thất bại: {0}'
        SecurityIssues   = 'Phát hiện vấn đề - Critical={0}, High={1}, Medium={2}'
        NoSecurityIssues = 'Không có vấn đề bảo mật'
        GStateNotInitialized = 'GState chưa được khởi tạo.'
        RequiredModuleNotFound = 'Không tìm thấy module bắt buộc: {0}'
    }
}

$script:CurrentLocale = 'en'
$script:ExplicitLocaleSet = $false

# ==== Resource file loading (Locales/<locale>.json) ====
# External JSON resource files override the built-in messages so translators can
# add/update locales without editing this module. Missing files fall back to the
# built-in map (graceful degrade, portable mode).
# Locale resource directory: defaults to ../Locales, overridable via paths.localeDir config
$script:LocaleResourceDir = Join-Path $PSScriptRoot '../Locales'
# Resolve relative to Modules/ when the module loads (default) — config override
# (paths.localeDir) is applied later via Set-LocaleResourceDir once config is available.
$script:LocaleModuleDir = $PSScriptRoot

function Import-LocaleResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Locale)

Set-StrictMode -Version 1.0
    $result = @{}
    if (-not (Test-Path $script:LocaleResourceDir)) { return $result }
    $resPath = Join-Path $script:LocaleResourceDir "$Locale.json"
    if (-not (Test-Path $resPath)) { return $result }
    try {
        $raw = Get-Content -Path $resPath -Raw -Encoding UTF8 -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $parsed.PSObject.Properties) {
            $result[$prop.Name] = [string]$prop.Value
        }
    } catch {
        $result = @{}
    }
    return $result
}

# Discover available locales by enumerating <locale>.json files in the resource
# directory (no hardcoded list — dropping in a new file makes it loadable).
# 'en' is always first: it backs the built-in fallback messages.
function Get-AvailableLocales {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $langs = @()
    if ($script:LocaleResourceDir -and (Test-Path $script:LocaleResourceDir)) {
        $langs = @(Get-ChildItem -Path $script:LocaleResourceDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName } |
            Where-Object { $_ -and $_ -match '^[a-z][a-z0-9_\-]*$' })
    }
    return @(@('en') + $langs | Select-Object -Unique)
}

# Reload all resource files from a (possibly config-driven) resource directory.
# Accepts a relative path (resolved against the Modules/ dir) or an absolute path.
function Set-LocaleResourceDir {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $resolved = if ([System.IO.Path]::IsPathRooted($Path)) { $Path }
                else { Join-Path $script:LocaleModuleDir $Path }
    if (-not (Test-Path $resolved)) { return }
    $script:LocaleResourceDir = $resolved
    $script:LocaleResources = @{}
    foreach ($lang in (Get-AvailableLocales)) {
        $script:LocaleResources[$lang] = Import-LocaleResource -Locale $lang
    }
}

$script:LocaleResources = @{}
foreach ($lang in (Get-AvailableLocales)) {
    $script:LocaleResources[$lang] = Import-LocaleResource -Locale $lang
}

function Get-CurrentLocale {
    [OutputType([string])]
    param()
    if ($script:ExplicitLocaleSet) { return $script:CurrentLocale }
    return 'en'
}

function Set-CurrentLocale {
    [CmdletBinding()]
    param([string]$Locale)
    # Accept both built-in locales and external JSON resource locales
    $allLocales = @($script:LocaleMessages.Keys) + @($script:LocaleResources.Keys)
    if ($allLocales -contains $Locale) {
        $script:CurrentLocale = $Locale
        $script:ExplicitLocaleSet = $true
    } else {
        $script:CurrentLocale = 'en'
        $script:ExplicitLocaleSet = $true
    }
    # Thread culture drives number/date/size formatting. `-Locale` previously
    # swapped only the message table; ToString('F1') and the ISO timestamp
    # template still formatted en-US under every locale. CultureInfo accepts
    # the bare locale codes we use ('vi', 'ja', 'de', 'zh', ...) and resolves
    # each to its default region culture.
    try {
        $ci = New-Object System.Globalization.CultureInfo($script:CurrentLocale)
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $ci
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $ci
    } catch { }
}

function Set-LocaleFromState {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    # Apply config-driven resource directory (paths.localeDir) when available —
    # relative paths resolve against the Modules/ directory (portable mode safe).
    $localeDir = Get-ConfigValue -Path 'paths.localeDir' -State $State
    if ($localeDir) {
        Set-LocaleResourceDir -Path ([string]$localeDir)
    }
    # 1. Explicit per-run override: GBUILD_LOCALE env (also set by -Locale).
    # Highest priority: a per-run choice always wins and is remembered.
    try {
        $envLoc = [Environment]::GetEnvironmentVariable('GBUILD_LOCALE')
        if (-not [string]::IsNullOrWhiteSpace($envLoc)) {
            $allLocales = @($script:LocaleMessages.Keys) + @($script:LocaleResources.Keys)
            $norm = $envLoc.Trim().ToLowerInvariant()
            if ($allLocales -contains $norm) {
                Set-CurrentLocale -Locale $norm
                $eff = Get-CurrentLocale
                Save-DeviceLocaleCache -State $State -Locale $eff -Source 'explicit' | Out-Null
                return $eff
            }
        }
    } catch { }
    # 2. Device cache: ONLY an explicitly chosen locale (switch/env/config)
    # beats the shipped config default. Legacy/auto-saved entries (no source)
    # are treated as absent so they can never resurrect an OS auto-detect.
    $cachePathUsable = [bool](Get-DeviceLocaleCachePath -State $State)
    $cache = Read-DeviceLocaleCache -State $State
    if ($cache -and $cache.Found -and -not $cache.Moved -and $cache.Locale -and (@('explicit', 'config') -contains $cache.Source)) {
        Set-CurrentLocale -Locale $cache.Locale
        return Get-CurrentLocale
    }
    if ($cache -and $cache.Moved) {
        Set-CurrentLocale -Locale 'en'
        if ($cachePathUsable) { Save-DeviceLocaleCache -State $State -Locale 'en' -Source 'default' | Out-Null }
        return 'en'
    }
    # 3. Config default (first run / no usable cache): build.locale.default
    # (string or { default }). Applied + remembered for this device.
    $locale = $null
    $buildLocale = Get-ConfigValue -Path 'build.locale' -State $State
    if ($buildLocale) {
        if ($buildLocale -is [string]) { $locale = $buildLocale }
        elseif ($buildLocale.PSObject.Properties.Name -contains 'default') { $locale = [string]$buildLocale.default }
    }
    if ($locale) {
        Set-CurrentLocale -Locale $locale
        $eff = Get-CurrentLocale
        if ($cachePathUsable) { Save-DeviceLocaleCache -State $State -Locale $eff -Source 'config' | Out-Null }
        return $eff
    }
    # 4. Final default is ALWAYS English (never OS auto-detect: the spec is
    # first-run-English, choice sticks per device, new machine resets).
    # Without a writable cache location (unit-test states) preserve legacy
    # behaviour and return the current locale untouched.
    if (-not $cachePathUsable) { return Get-CurrentLocale }
    Set-CurrentLocale -Locale 'en'
    Save-DeviceLocaleCache -State $State -Locale 'en' -Source 'default' | Out-Null
    return 'en'
}

function Get-LocaleMessage {
    [CmdletBinding()]
    [OutputType([string])]
      param(
          [Parameter(Mandatory)][string]$Key,
          # -Args is kept as an alias: _Build and _Sync ship the same command
          # name, so whichever module is imported last decides which one the
          # session sees. The two tools must expose the SAME contract for the
          # same command, otherwise a call site in one tool breaks as soon as
          # the other tool's module has been imported.
          [Alias('Args')][string[]]$MessageArgs = @(),
          [string]$Locale = '',
          [string]$Fallback = ''
      )
    $loc = if ($Locale) { $Locale } else { Get-CurrentLocale }
    $messages = $script:LocaleMessages[$loc]
    if (-not $messages) { $messages = $script:LocaleMessages['en'] }
    # 1) External JSON resource wins (override/extend built-ins)
    $resources = if ($script:LocaleResources.ContainsKey($loc)) { $script:LocaleResources[$loc] } else { $null }
    if ($resources -and $resources.ContainsKey($Key)) {
        $text = [string]$resources[$Key]
        if ($MessageArgs.Count -gt 0) { $text = [string]::Format($text, [object[]]$MessageArgs) }
        return $text
    }
    # 1b) Per-key fallback to the English resource. en.json is the key owner:
    # a key present in en.json but missing from the selected locale must degrade
    # to the English translation, not to the call-site literal. (Previously the
    # chain skipped en.json entirely and fell through to -Fallback, so a key
    # added to en.json but forgotten in one locale rendered raw English text
    # or, worse, the unformatted fallback literal.)
    if ($loc -ne 'en') {
        $enResources = if ($script:LocaleResources.ContainsKey('en')) { $script:LocaleResources['en'] } else { $null }
        if ($enResources -and $enResources.ContainsKey($Key)) {
            $text = [string]$enResources[$Key]
            if ($MessageArgs.Count -gt 0) { $text = [string]::Format($text, [object[]]$MessageArgs) }
            return $text
        }
    }
    # 2) Built-in locale message
    $template = $messages.PSObject.Properties[$Key]
    if (-not $template) {
        $enTemplate = $script:LocaleMessages['en'].PSObject.Properties[$Key]
        if ($enTemplate) { $template = $enTemplate } elseif ($Fallback) {
            # The fallback literal may itself carry {N} placeholders (it is the
            # English text the call-site was written with), so format it exactly
            # like every other path. try/catch: a fallback must never throw —
            # worst case the user sees the raw literal, as before.
            $fb = [string]$Fallback
            if ($MessageArgs.Count -gt 0) { try { $fb = [string]::Format($fb, [object[]]$MessageArgs) } catch { $fb = [string]$Fallback } }
            return $fb
        } else { return $Key }
    }
    $text = [string]$template.Value
    if ($MessageArgs.Count -gt 0) { $text = [string]::Format($text, [object[]]$MessageArgs) }
    return $text
}

# ==== Per-device locale persistence (bounded single-file cache) ====
# First run on a machine: no cache -> English is persisted for this device.
# User changes language (-> -Locale / GBUILD_LOCALE / config): choice saved.
# Copy carried to a NEW machine: deviceId mismatch -> reset to 'en' + overwrite.
# The file is ONE fixed-schema record (~150 bytes, 4KB hard cap) — it can
# never grow, so the system cannot get sluggish from cache bloat.
$script:DeviceLocaleCacheMaxBytes = 4096
$script:DeviceLocaleCacheRelPath = '.gbuild/locale.json'

# Native display names for known locales (meta labels, not translations).
$script:LocaleNativeNames = @{
    en = 'English'; vi = 'Tiếng Việt'; de = 'Deutsch'; es = 'Español'
    fr = 'Français'; ja = '日本語'; zh = '中文'
}
$script:LocaleAsciiNames = @{
    en = 'English'; vi = 'Vietnamese'; de = 'German'; es = 'Spanish'
    fr = 'French'; ja = 'Japanese'; zh = 'Chinese'
}

<#
.SYNOPSIS
    Stable cross-platform device identifier (SHA256 hex, no PII stored).
#>
function Get-DeviceId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $raw = $null
    # Test-IsWindowsHost is PathUtils-owned. Calling it unguarded meant a bare
    # `Import-Module Locale.psm1` (no PathUtils loaded) raised CommandNotFound,
    # which the try/catch below swallowed - so the machine GUID was skipped and
    # the id silently became a hash of COMPUTERNAME/USERNAME instead. That is not
    # a stable DEVICE id: it changes when the host is renamed or the account
    # differs, which is exactly what the persisted per-device locale cache keys
    # on. Resolve the owner explicitly rather than letting a missing command
    # decide which identity is used.
    $isWin = $false
    if (-not (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue)) {
        $pathUtilsPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
        if (Test-Path -LiteralPath $pathUtilsPath -PathType Leaf) {
            $null = Import-Module $pathUtilsPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) {
        try { $isWin = [bool](Test-IsWindowsHost) } catch { $isWin = $false }
    }
    try {
        if ($isWin) {
            # Registry/file sources are canonical in BuildConstants. Literals
            # below are only the survival fallbacks when BuildConstants cannot
            # be loaded.
            $registryPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
            $valueName = 'MachineGuid'
            if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
                try {
                    $registryPath = [string](Get-BuildDefault -Key 'OsMachineGuidRegistryPath' -Fallback $registryPath)
                    $valueName = [string](Get-BuildDefault -Key 'OsMachineGuidValueName' -Fallback $valueName)
                } catch { }
            }
            $g = Get-ItemProperty -LiteralPath $registryPath -Name $valueName -ErrorAction SilentlyContinue
            if ($g -and $g.$valueName) { $raw = "win:$($g.$valueName)" }
        }
    } catch { }
    if (-not $raw) {
        $machineIdPaths = @('/etc/machine-id', '/var/lib/dbus/machine-id')
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            try { $machineIdPaths = @(Get-BuildDefault -Key 'OsMachineIdPaths' -Fallback $machineIdPaths) } catch { }
        }
        foreach ($p in $machineIdPaths) {
            try {
                if (Test-Path -LiteralPath $p -PathType Leaf) {
                    $c = (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction SilentlyContinue)
                    if ($c -and "$c".Trim()) { $raw = "linux:$("$c".Trim())"; break }
                }
            } catch { }
        }
    }
    if (-not $raw) {
        try {
            $u = (& ioreg -rd1 -c IOPlatformExpertDevice 2>$null | Select-String 'IOPlatformUUID' | Select-Object -First 1)
            if ($u -and "$u" -match '"([^"]+)"\s*$') { $raw = "mac:$($Matches[1])" }
        } catch { }
    }
    if (-not $raw) {
        # Single owner: SharedUtils.Get-BuildIdentity owns the user/host chain.
        # The local copy used 'unknown-user'/'unknown-host' and no DNS fallback,
        # so the device id diverged from every other module's identity chain.
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildIdentity')
        $ident = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { Get-BuildIdentity } else { $null }
        $h = if ($ident) { [string]$ident.Host } else { '' }
        $u = if ($ident) { [string]$ident.User } else { '' }
        if (-not $h) { $h = 'unknown-host' }
        if (-not $u) { $u = 'unknown-user' }
        $raw = "fb:$h/$u"
    }
    # SharedUtils.Get-BuildStringHash owns UTF8 -> SHA256 -> lowercase hex.
    # The inline SHA256 block this replaces was unreachable dead weight: the
    # branch above already returned, so the duplicate never executed - and the
    # stringHashDelegation ratchet could not see it, which is exactly the class
    # of "helper extracted, copy left behind" residue it exists to catch.
    # When the owner cannot be resolved the device id degrades to a distinct
    # constant instead of silently becoming one shared value across every
    # machine running a stripped import.
    if (-not (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue)) {
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    }
    if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) {
        try { return (Get-BuildStringHash -Text ([string]$raw)) } catch { return 'unavailable' }
    }
    return 'unavailable'
}

function Get-DeviceLocaleCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    try {
        if (-not $State -or -not $State.ScriptRoot) { return $null }
        $root = [string]$State.ScriptRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }
        # MUST be rooted. A relative or un-normalized ScriptRoot (e.g. the '..\'
        # that a CWD-anchored state-file save used to persist) makes the Join-Path
        # result relative, so Save-DeviceLocaleCache wrote the per-device record
        # into whatever directory the launcher happened to run from. That is how
        # F:\.gbuild\locale.json appeared at the filesystem root.
        if (-not [System.IO.Path]::IsPathRooted($root)) { return $null }
        try { $root = [System.IO.Path]::GetFullPath($root) } catch { return $null }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
        return (Join-Path $root $script:DeviceLocaleCacheRelPath)
    } catch { return $null }
}

<#
.SYNOPSIS
    Reads the device locale cache. Returns @{ Found; Moved; Locale; Source }.
    Moved=$true means the copy now runs on a different machine.
    Source tracks HOW the saved choice originated: explicit (switch/env),
    config, default, auto (legacy pre-source caches report $null).
#>
function Read-DeviceLocaleCache {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $p = Get-DeviceLocaleCachePath -State $State
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        if ((Get-Item -LiteralPath $p -ErrorAction Stop).Length -gt $script:DeviceLocaleCacheMaxBytes) { return $null }
        $d = Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $d.deviceId -or -not $d.locale) { return $null }
        $allLocales = @($script:LocaleMessages.Keys) + @($script:LocaleResources.Keys)
        if ($allLocales -notcontains [string]$d.locale) { return $null }
        $src = $null
        try { if ($d.PSObject.Properties.Name -contains 'source') { $src = [string]$d.source } } catch { $src = $null }
        if ([string]$d.deviceId -ne (Get-DeviceId)) {
            return @{ Found = $true; Moved = $true; Locale = $null; Source = $src }
        }
        return @{ Found = $true; Moved = $false; Locale = [string]$d.locale; Source = $src }
    } catch { return $null }
}

function Save-DeviceLocaleCache {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory)][string]$Locale,
        [string]$Source = 'explicit'
    )
    $p = Get-DeviceLocaleCachePath -State $State
    if (-not $p) { return $false }
    try {
        $dir = Split-Path $p -Parent
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $dir) } else { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        }
        $payload = (@{ version = 1; deviceId = (Get-DeviceId); locale = $Locale; source = $Source; updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
        # SharedUtils.Write-BuildTextFileAtomic, not a private copy. The copy this
        # replaced wrote the temp file at a PREDICTABLE "$p.tmp" - which is a
        # collision between two concurrent writers and a symlink target for
        # anything able to write in that directory. The primitive GUIDs the temp
        # name, creates the parent directory, and guarantees the temp is cleaned
        # up on both the success and the failure path.
        if (Get-Command Write-BuildTextFileAtomic -ErrorAction SilentlyContinue) {
            Write-BuildTextFileAtomic -Path $p -Lines @($payload) | Out-Null
        } else {
            $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($p) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop
            } finally {
                try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
        return $true
    } catch { return $false }
}

<#
.SYNOPSIS
    Human-readable locale list for the build-log switch hint (e.g. "en English, vi Tiếng Việt").
#>
function Get-LocaleDisplayList {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Ascii)
    $langs = @()
    try { $langs = @(Get-AvailableLocales) } catch { $langs = @('en') }
    if (-not $langs -or $langs.Count -eq 0) { $langs = @('en') }
    $parts = foreach ($l in $langs) {
        $names = if ($Ascii) { $script:LocaleAsciiNames } else { $script:LocaleNativeNames }
        $nm = if ($names.ContainsKey($l)) { $names[$l] } else { $l }
        "$l $nm"
    }
    return ($parts -join ', ')
}

<#
.SYNOPSIS
    Prints the language-switch guide (like -Help, but for display language).
.DESCRIPTION
    Shows current language, available languages with native names, and the
    exact OS-correct commands to switch (per-run switch, env var, config).
    Invoked by `gbuild -Locale` with no value.
#>
function Show-LocaleHelp {
    [CmdletBinding()]
    param()
    # Location-correct commands: tool dir is the parent of Modules/.
    $toolRoot = try { (Split-Path $PSScriptRoot -Parent) } catch { '' }
    $helpCwd = try { ((Get-Location).ProviderPath) } catch { '' }
    # Default to a POSIX-correct invocation. The previous default was the literal
    # '.\_Build\gbuild.ps1' and Get-InvokeCommandHint is the ONLY thing that
    # replaced it - there was no else branch, so on Linux/macOS (or whenever the
    # helper was unavailable) this screen printed a command that cannot run.
    # Documentation.psm1:40-46 already does this fallback correctly.
    # NOT $isWindows: that is a READ-ONLY automatic variable from PowerShell 6.0
    # on, so assigning it emitted "Cannot overwrite variable IsWindows because
    # it is read-only or constant" and then SILENTLY left the platform value in
    # place - the local intent was discarded and the host decided instead.
    $onWindows = $false
    try { $onWindows = [bool](Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost) } catch { $onWindows = $false }
    $invoke = if ($onWindows) { '.\_Build\gbuild.ps1' } else { './_Build/gbuild' }
    if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
        try { $hint = Get-InvokeCommandHint -ScriptRoot $toolRoot -FromDirectory $helpCwd } catch { $hint = '' }
        if (-not [string]::IsNullOrWhiteSpace($hint)) { $invoke = $hint }
    }
    $cur = 'en'
    try { $cur = Get-CurrentLocale } catch { }
    $list = 'en English'
    try { $list = Get-LocaleDisplayList -Ascii } catch { }
    $lines = @(
        '',
        ('  ' + (Get-LocaleMessage -Key 'ui.locale.title' -Fallback 'gbuild display language')),
        ('    ' + (Get-LocaleMessage -Key 'ui.locale.current' -MessageArgs @($cur) -Fallback ('Current:   {0}' -f $cur))),
        ('    ' + (Get-LocaleMessage -Key 'ui.locale.available' -MessageArgs @($list) -Fallback ('Available: {0}' -f $list))),
        '',
        ('  ' + (Get-LocaleMessage -Key 'ui.locale.switchOneRun' -Fallback 'Switch for one run (also remembered on this device):')),
        "    $invoke -Locale vi",
        '',
        ('  ' + (Get-LocaleMessage -Key 'ui.locale.otherWays' -Fallback 'Other ways:')),
        (Get-LocaleMessage -Key 'ui.locale.switchEnv' -MessageArgs @('vi') -Fallback '    $env:GBUILD_LOCALE = "vi"      # per-run via environment'),
        (Get-LocaleMessage -Key 'ui.locale.switchConfig' -MessageArgs @('vi') -Fallback '    build.locale.default = "vi"    # per-project via gbuild.config.json'),
        (Get-LocaleMessage -Key 'ui.locale.noAutoDetect' -Fallback '    - No OS auto-detection; a new device starts in English.'),
        '',
        ('  ' + (Get-LocaleMessage -Key 'ui.locale.notes' -Fallback 'Notes:')),
        (Get-LocaleMessage -Key 'ui.locale.noteSave' -Fallback '    - The choice is saved per device (.gbuild/locale.json, one small record).'),
        (Get-LocaleMessage -Key 'ui.locale.noteReset' -Fallback '    - A copy carried to a new machine resets to English on first run.'),
        ''
    )
    foreach ($ln in $lines) {
        try { Write-Host $ln } catch { }
    }
}

Export-ModuleMember -Function @('Get-CurrentLocale', 'Set-CurrentLocale', 'Get-LocaleMessage', 'Set-LocaleFromState', 'Import-LocaleResource', 'Get-AvailableLocales', 'Get-DeviceId', 'Get-DeviceLocaleCachePath', 'Read-DeviceLocaleCache', 'Save-DeviceLocaleCache', 'Get-LocaleDisplayList', 'Show-LocaleHelp')
