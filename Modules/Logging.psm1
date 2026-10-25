# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Logging.psm1 (Configuration-Driven, Portable, Professional)
# ==================================================================================================

# -- Module Configuration (Single Source of Truth) -----------------------------

# NOTE: Locale is intentionally NOT imported here. Locale is loaded globally by
# the Orchestrator (before this module) so that $script:CurrentLocale is shared.
# Write-Log resolves Get-LocaleMessage at runtime (Get-Command check below) and
# falls back to English when the Locale module is absent.
#
# SharedUtils/BuildConstants are intentionally NOT imported at module scope either.
# Importing SharedUtils here would circularly re-import Logging (SharedUtils ->
# ModuleBootstrap -> Import-BuildDependencies -> Logging), exceeding the PS 5.1
# module nesting limit and breaking the whole load chain. Instead resolve
# Get-BuildConstant at runtime via a Get-Command guard (same pattern as
# Project.psm1 / Deploy.psm1 / Preflight.psm1 / Siem.psm1) and fall back to the
# default values below.
$script:_maxLogSizeMB = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'MaxLogSizeMB' -Fallback 10 } else { 10 }
$script:_maxLogFiles  = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'MaxLogFiles' -Fallback 5 } else { 5 }

# Internal helper: consult the BuildConstants table if the module is loaded (Get-Command guard because
# Logging must NOT import BuildConstants at module scope — see the circular-import NOTE above).
# The literal fallback below must stay in sync with $script:BuildDefaults in
# BuildConstants.psm1 so the snapshot taken when gbuild.ps1 loads Logging BEFORE BuildConstants
# still carries the canonical values.
function Get-LogBootstrapConstant {
    [CmdletBinding()]
    param([string]$Key, [object]$Fallback)

Set-StrictMode -Version 1.0
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        return Get-BuildConstant -Key $Key -Fallback $Fallback
    }
    return $Fallback
}

$script:LogConfig = [PSCustomObject]@{
    # Terminal settings (single source: BuildConstants.Log* — literals are only the fallback
    # for when BuildConstants is not yet loaded; see helper above)
    MinWindowWidth      = Get-LogBootstrapConstant -Key 'LogMinWindowWidth' 80
    MaxWindowWidth      = Get-LogBootstrapConstant -Key 'LogMaxWindowWidth' 120
    DefaultWindowWidth  = Get-LogBootstrapConstant -Key 'LogDefaultWindowWidth' 100
    ContentWidthRatio   = Get-LogBootstrapConstant -Key 'LogContentWidthRatio' 0.60
    ProgressBarWidth    = Get-LogBootstrapConstant -Key 'LogProgressBarWidth' 20

    # Log file settings (retry: config logging.fileRetry* > BuildConstants > fallback)
    DefaultLogFileName  = ".gbuild.log"
    DefaultLogEncoding  = [System.Text.Encoding]::UTF8
    FileRetryDelayMs    = Get-LogBootstrapConstant -Key 'LogFileRetryDelayMs' 1000
    FileRetryAttempts   = Get-LogBootstrapConstant -Key 'LogFileRetryAttempts' 3
    MaxLogSizeMB        = $script:_maxLogSizeMB
    MaxLogFiles         = $script:_maxLogFiles

    # UI settings (single source: BuildConstants.Log*)
    BoxPaddingSmall     = Get-LogBootstrapConstant -Key 'LogBoxPadSmall' '   '
    BoxPaddingLarge     = Get-LogBootstrapConstant -Key 'LogBoxPadLarge' '      '
    SeparatorChar       = Get-LogBootstrapConstant -Key 'LogSeparatorChar' '-'
    DisplayTimestampFormat = Get-LogBootstrapConstant -Key 'TimestampDisplay' 'yyyy-MM-dd HH:mm:ss'

    # Messages: single source is Locale.psm1 (Get-LocaleMessage).
    # No duplication here — all message templates live in Locale.psm1.

    # Default colors — bootstrap fallback until BuildConstants loads.
    # At runtime, Set-StateColors resolves from Get-BuildConstant 'Colors' (the true single source).
    DefaultColors = [PSCustomObject]@{
        Header = 'Magenta'
        Info   = 'Cyan'
        Warn   = 'Yellow'
        Err    = 'Red'
        Succ   = 'Green'
        Gray   = 'DarkGray'
        White  = 'White'
    }
}

function Resolve-LogMessage {
    <#
    .SYNOPSIS
        Single guarded owner for "resolve a log message through the locale system".
    .DESCRIPTION
        Load order is the whole reason this exists. Modules\ErrorHandling.psm1 is
        the SECOND Tier-1 module (Orchestrator imports PathUtils, then
        ErrorHandling, ... and Locale is eighteenth), and ErrorHandling's retry,
        circuit-breaker and rollback paths all emit. A bare Get-LocaleMessage call
        there threw CommandNotFoundException whenever the module was loaded
        standalone - Locale had not loaded yet - which took 9 tests with it.

        So every emit site routes through this guarded accessor instead of calling
        Get-LocaleMessage directly: it uses the locale when available and degrades
        to -Fallback (the English text) when not. Degrading to the raw KEY, which
        is what this did before -Fallback existed, would print "log.error.timedOut"
        at a user, which is worse than English.

        Exported so ErrorHandling and any other early-loading module share this one
        owner. A per-module copy of a 3-line guarded accessor is the duplication
        class this repository already has seven instances of.
    .PARAMETER Key
        Locale key, e.g. 'log.error.timedOut'.
    .PARAMETER MessageArgs
        Values for the {0}-style placeholders in the message.
    .PARAMETER Fallback
        English text used when the locale system is not loaded. Formatted with
        MessageArgs exactly as the locale path would.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [string[]]$MessageArgs = @(),
        [string]$Fallback = ''
    )
    if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
        return Get-LocaleMessage -Key $Key -MessageArgs $MessageArgs -Fallback $Fallback
    }
    if ($MessageArgs.Count -gt 0 -and -not [string]::IsNullOrEmpty($Fallback)) {
        try { return [string]::Format($Fallback, [object[]]$MessageArgs) } catch { return $Fallback }
    }
    if (-not [string]::IsNullOrEmpty($Fallback)) { return $Fallback }
    return $Key
}

function Get-LogDisplayTimestamp {
    # Logging cannot import BuildConstants at module scope without a load-cycle,
    # so this is the one timestamp fallback. Normal operation delegates to the
    # canonical timestamp owner; the format literal lives only in LogConfig.
    if (Get-Command Get-BuildTimestamp -ErrorAction SilentlyContinue) {
        return Get-BuildTimestamp -Kind Display
    }
    return (Get-Date -Format $script:LogConfig.DisplayTimestampFormat)
}

# -- Localized log markers & level names --
# Resolves locale-aware markers (emoji on PS7+, ASCII on PS5.1) and level names.
# Automatically syncs with the active locale: when user calls Set-CurrentLocale,
# the next log output uses the new language's markers and level names.
function Get-LogLocalized {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Fallback = ''
    )
    $text = $null
    if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
        $msg = Get-LocaleMessage -Key $Key
        if ($msg -and $msg -ne $Key) { $text = $msg }
    }
    if (-not $text) { $text = $Fallback }
    # PS5.1 raster font cannot render Unicode emoji — use ASCII fallback
    if ($Host.Name -match 'Windows PowerShell' -or $PSVersionTable.PSVersion.Major -lt 7) {
        $asciiFallback = @{
            'log.marker.done'  = '[v]'
            'log.marker.fail'  = '[x]'
            'log.marker.info'  = '[i]'
            'log.marker.warn'  = '[!]'
            'log.marker.skip'  = '[sk]'
        }
        if ($asciiFallback.ContainsKey($Key)) { return $asciiFallback[$Key] }
        # Level names are ASCII already — return as-is
        if ($Key -like 'log.level.*') { return $text }
    }
    return $text
}

# -- Runtime State (Computed from Config) -------------------------------------
$script:GW = try {
    $w = [Console]::WindowWidth
    if ($w -le 0) { throw (Resolve-LogMessage -Key 'log.logging.line174' -Fallback "Invalid width") }
    [Math]::Min([Math]::Max($w, $script:LogConfig.MinWindowWidth), $script:LogConfig.MaxWindowWidth)
} catch {
    $script:LogConfig.DefaultWindowWidth
}
$script:GCL = [int]($script:GW * $script:LogConfig.ContentWidthRatio)

# Module-scoped state
$script:LogFilePath = $null
$script:JsonLogPath = $null
$script:LogLevel = "Info"

# -- Emoji / Symbol resolution --------------------------------------------------
$script:EmojiMap = @{}
if ($Host.Name -match 'Windows PowerShell' -or $PSVersionTable.PSVersion.Major -lt 7) {
    # PS5.1 raster font cannot render Unicode emoji
    # All replacements use plain ASCII since PS5.1 raster font
    # cannot render any Unicode beyond U+00FF
    $script:EmojiMap = @{
        '✅' = '[v]'; '❌' = '[x]'; '⚠' = '[!]'; 'ℹ' = '[i]'
        '☁' = '[~]'; '✗' = '[x]'; '✓' = '[v]'
        '•' = '*';   '⚙' = '[*]'; '✔' = '[v]'
        '💡' = '[i]'; '💾' = '[S]'; '📁' = '[D]'; '📄' = '[F]'
        '📈' = '[^]'; '📦' = '[P]'; '📱' = '[M]'; '🚨' = '[!]'
        '📊' = '[#]'; '📢' = '[!]'; '⏭' = '[sk]'
    }
}


<#
.SYNOPSIS
    Replaces emoji characters with ASCII equivalents for PS5.1 raster font compatibility.
.DESCRIPTION
    Iterates through the EmojiMap replacing each emoji key with its ASCII value.
    Returns the original text unchanged if the map is empty or text is null/empty.
.PARAMETER Text
    The text containing emoji characters to replace.
#>
function Resolve-BuildText {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text) -or $script:EmojiMap.Count -eq 0) { return $Text }
    foreach ($kv in $script:EmojiMap.GetEnumerator()) {
        $Text = $Text.Replace($kv.Key, $kv.Value)
    }
    return $Text
}

<#
.SYNOPSIS
    Retrieves a value from a PSCustomObject using a dot-separated property path.
.DESCRIPTION
    Level 5 accessor map (use the right one, do NOT add a fifth):
      - BuildConstants KEY (e.g. 'ParallelMaxJobs') → Get-BuildConstant (facade, config+defaults)
      - Raw config dot-path (e.g. 'build.maxParallelJobs') → Get-ConfigValue (ConfigProvider)
      - This function (Resolve-ConfigValue) = legacy compat for logging/boot paths
        only; new code should use Get-BuildConstant or Get-ConfigValue.
    Navigates nested properties following the Path (e.g. "logging.maxLogSizeMB")
    and returns the value, or a default if any segment is missing.
.PARAMETER State
    The PSCustomObject to search.
.PARAMETER Path
    Dot-separated property path to navigate.
.PARAMETER Default
    Value returned if the path does not exist.
#>
function Resolve-ConfigValue {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory=$true)] [string]$Path,
        $Default
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Default }

    # Single-source walk via ConfigProvider's Find-ConfigNode (loaded globally).
    # Direct $State path first, then $State.BuildConfig (config lives there).
    $val = $null
    if (Get-Command Find-ConfigNode -ErrorAction SilentlyContinue) {
        $val = Find-ConfigNode -Root $State -Path $Path
        if ($null -eq $val -and $State -and ($State.PSObject.Properties.Name -contains 'BuildConfig')) {
            $val = Find-ConfigNode -Root $State.BuildConfig -Path $Path
        }
    } else {
        # Defensive inline fallback for standalone import without ConfigProvider.
        $firstPart = ($Path -split '\.')[0]
        $hasDirect = $State -and ($State.PSObject.Properties.Name -contains $firstPart)
        $current = $State
        if (-not $hasDirect -and $State -and ($State.PSObject.Properties.Name -contains 'BuildConfig')) {
            $current = $State.BuildConfig
        }
        foreach ($part in ($Path -split '\.')) {
            if ($null -eq $current) { $val = $null; break }
            if ($current.PSObject.Properties.Name -contains $part) { $current = $current.$part } else { $val = $null; break }
        }
        $val = $current
    }

    if ($null -eq $val) { return $Default }
    return $val
}

<#
.SYNOPSIS
    Gets a configuration value from the logging section of a State object.
.DESCRIPTION
    Shorthand for Resolve-ConfigValue with the "logging." prefix prepended to Key.
.PARAMETER State
    The PSCustomObject containing logging configuration.
.PARAMETER Key
    The property key under the logging section.
.PARAMETER Default
    Value returned if the key is not found.
#>
function Get-LogConfigValue {
    param([PSCustomObject]$State, [string]$Key, $Default)
    return Resolve-ConfigValue -State $State -Path "logging.$Key" -Default $Default
}

# ==================================================================================
# LOG LEVEL & FILE MANAGEMENT
# ==================================================================================

<#
.SYNOPSIS
    Sets the current log level for filtering log output.
.DESCRIPTION
    Updates the module-scoped LogLevel and attempts to synchronise the value
    onto the Get-ModuleState object.
.PARAMETER Level
    The log level to set. Valid values: Error, Warn, Info, Debug.
#>
function Set-LogLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Error', 'Warn', 'Info', 'Debug')]
        [string]$Level
    )
    $script:LogLevel = $Level

    $gstate = if (Get-Command Get-ModuleState -ErrorAction SilentlyContinue) { Get-ModuleState } else { $null }
    if ($gstate) {
        try {
            if (-not ($gstate.PSObject.Properties.Name -contains 'LogLevel')) {
                $gstate | Add-Member -MemberType NoteProperty -Name LogLevel -Value ($script:LogLevel) -Force
            } else {
                $gstate.LogLevel = $script:LogLevel
            }
        } catch { # benign — optional fallback; LogLevel defaults to $script:LogLevel
            }
    }
}

<#
.SYNOPSIS
    Rotates log files when the current log exceeds the configured size limit.
.DESCRIPTION
    Checks file size against maxLogSizeMB. If exceeded, rotates files up to
    maxLogFiles, removing the oldest and shifting the rest.
.PARAMETER Path
    Full path to the log file.
.PARAMETER State
    State object with logging configuration (enableRotation, maxLogSizeMB, maxLogFiles).
#>
function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Path,
        [PSCustomObject]$State
    )

    if (-not $Path -or -not (Test-Path -Path $Path -PathType Leaf)) { return }

    $enableRotation = [bool](Get-LogConfigValue -State $State -Key 'enableRotation' -Default $true)
    if (-not $enableRotation) { return }

    $maxLogFiles = [int](Get-LogConfigValue -State $State -Key 'maxLogFiles' -Default $script:LogConfig.MaxLogFiles)
    if ($maxLogFiles -lt 1) { return }

    $maxSizeMB = [int](Get-LogConfigValue -State $State -Key 'maxLogSizeMB' -Default $script:LogConfig.MaxLogSizeMB)
    $maxSizeBytes = [int64]$maxSizeMB * 1MB
    $fileInfo = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if (-not $fileInfo -or $fileInfo.Length -lt $maxSizeBytes) { return }

    $dir = Split-Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.log' }

    for ($i = $maxLogFiles; $i -ge 1; $i--) {
        $oldName = if ($i -eq 1) { $Path } else { Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext) }
        $newName = Join-Path $dir ("{0}_{1}{2}" -f $base, ($i + 1), $ext)
        if (Test-Path -Path $oldName) {
            if ($i -eq $maxLogFiles) { Remove-Item -Path $oldName -Force -EA SilentlyContinue }
            else { Rename-Item -Path $oldName -NewName $newName -Force -EA SilentlyContinue }
        }
    }
}

<#
.SYNOPSIS
    Purges aged build log files so per-run `build_yyyyMMdd_HHmmss.log` files
    (which rotation-by-size never cleans) cannot accumulate unbounded.
#>
function Invoke-LogRetention {
    [CmdletBinding()] param([string]$Directory, [PSCustomObject]$State = $null)
    try {
        if (-not $Directory -or -not (Test-Path $Directory)) { return }
        $maxFiles = 5; $maxDays = 30
        try {
            if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) {
                # MaxLogFiles is the mapped key (logging.maxLogFiles); 'LogMaxFiles'
                # was never defined in BuildConstants. The literal and the fallback
                # must both be the registered 5 (BuildConstants.MaxLogFiles), else
                # a settings-provider miss silently keeps 20 regardless of the
                # configured 5 - the bug this comment documents has been fixed, so
                # the fallback literal must agree now.
                $maxFiles = [int](Get-BuildSetting -Key 'MaxLogFiles' -State $State -Fallback 5)
                $maxDays = [int](Get-BuildSetting -Key 'LogMaxAgeDays' -State $State -Fallback 30)
            }
        } catch { }
        $files = @(Get-ChildItem -Path $Directory -Filter 'build_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($files.Count -gt $maxFiles) { $files | Select-Object -Skip $maxFiles | Remove-Item -Force -ErrorAction SilentlyContinue }
        $cutoff = (Get-Date).AddDays(-$maxDays)
        @(Get-ChildItem -Path $Directory -Filter 'build_*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }) | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

<#
.SYNOPSIS
    Initialises logging to a file with optional rotation and cleanup.
.DESCRIPTION
    Resolves the log file path, rotates existing logs if configured, removes any
    existing file, creates a new empty file, and sets the module-scoped log state.
.PARAMETER Path
    Path to the log file. Defaults to ScriptRoot/.gbuild.log.
.PARAMETER Level
    Initial log level. Defaults to "Info".
.PARAMETER State
    Optional state object for configuration lookups.
#>
function Start-Log {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Level = "Info",
        [PSCustomObject]$State = $null
    )

    if (-not $Path) {
        $root = if ($State -and $State.ScriptRoot) { $State.ScriptRoot } else { $PSScriptRoot }
        $Path = Join-Path $root $script:LogConfig.DefaultLogFileName
    }
    $script:LogFilePath = $Path
    $script:LogLevel = $Level
    $script:JsonLogPath = $null

    Invoke-LogRotation -Path $Path -State $State
    Invoke-LogRetention -Directory (Split-Path $Path -Parent) -State $State
    # NEVER delete an existing file here. The name carries only second
    # resolution (build_<yyyyMMdd_HHmmss>.log), so two concurrent builds in the
    # same second and tenant computed the SAME path - and this Remove-Item
    # deleted the peer build's entire log, after which every contending
    # AppendAllText that lost the FileShare race was silently dropped. Instead,
    # claim a collision-free name: try the requested path with an atomic
    # CreateNew (which fails if the file appeared between our check and our
    # create), and suffix _2, _3, ... until the create wins. Both builds keep
    # their logs; the suffix is the honest signal that a collision happened.
    $finalPath = $Path
    $attempt = 1
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($finalPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try { $fs.Dispose() } catch { }
            break
        } catch [System.IO.IOException] {
            $attempt++
            if ($attempt -gt 100) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.logging.line454' -Fallback "Cannot claim a unique log path near '$Path' after 100 attempts.")) }
            $dir = Split-Path -Parent $Path
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $ext = [System.IO.Path]::GetExtension($Path)
            $finalPath = Join-Path $dir ($leaf + '_' + [string]$attempt + $ext)
        }
    }
    $Path = $finalPath
    $script:LogFilePath = $Path

    # Initialize structured JSON log (JSONL) when enabled via logging.enableJsonLog
    # Only activate JSONL after the startup banner so the structured log contains real events only
    $enableJson = [bool](Get-LogConfigValue -State $State -Key 'enableJsonLog' -Default $false)
    if ($enableJson) {
        $jsonPath = Join-Path (Split-Path $Path -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.jsonl')
        # Same no-delete rule as the text log above: claim, don't clobber.
        $finalJson = $jsonPath
        $jAttempt = 1
        while ($true) {
            try {
                $jfs = [System.IO.File]::Open($finalJson, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                try { $jfs.Dispose() } catch { }
                break
            } catch [System.IO.IOException] {
                $jAttempt++
                if ($jAttempt -gt 100) { break }
                $jDir = Split-Path -Parent $jsonPath
                $jLeaf = [System.IO.Path]::GetFileNameWithoutExtension($jsonPath)
                $finalJson = Join-Path $jDir ($jLeaf + '_' + [string]$jAttempt + '.jsonl')
            }
        }
        $jsonPath = $finalJson
    }

    $msg = Resolve-LogMessage -Key 'LoggingEnabled' -MessageArgs @($Path)
    Write-Log $msg 'Gray' $State
    if ($enableJson) {
        $script:JsonLogPath = $jsonPath
    }
}

<#
.SYNOPSIS
    Stops logging by writing a final end-of-log entry.
.DESCRIPTION
    If a log file path is active, writes a termination message with the current
    timestamp to the log file.
#>
function Stop-Log {
    if ($script:LogFilePath) {
        $endedAt = Get-LogDisplayTimestamp
        Write-Log (Resolve-LogMessage -Key 'log.system.logEnded' -MessageArgs @($endedAt)) -Level Info
        # Idempotent: clear the active path so a second Stop-Log call (e.g. the
        # gbuild.ps1 finally block after Start-GBuild already stopped logging)
        # becomes a no-op instead of writing a duplicate end-of-log marker.
        $script:LogFilePath = $null
        $script:JsonLogPath = $null
    }
}

# ==================================================================================
# UTILITY FUNCTION: CALCULATE DISPLAY WIDTH (FIX UNICODE / EMOJI)
# ==================================================================================
<#
.SYNOPSIS
    Calculates the visual display width of a string, stripping ANSI and zero-width chars.
.DESCRIPTION
    Removes ANSI escape sequences, zero-width joiners, variation selectors, and
    other non-printing characters before calculating length for alignment.
.PARAMETER Text
    The string to measure.
#>
function Get-VisualLength {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    # 1. Strip ANSI escape sequences (terminal color codes)
    $clean = $Text -replace '\x1b\[[0-9;]*m', ''
    # 2. Strip Zero-width characters (ZWJ, ZWNJ, Variation Selectors)
    $clean = $clean -replace '[\u200B-\u200D\uFE00-\uFE0F\u2060\uFEFF]', ''
    # Count terminal CELLS, not UTF-16 code units. A CJK ideograph or
    # fullwidth form occupies two console columns, so ("xxxx").Length rules
    # misaligned every boxed section under ja/zh/ko locales. Count surrogate
    # pairs once, at width 2 (typical emoji render as two cells).
    $w = 0
    for ($i = 0; $i -lt $clean.Length; $i++) {
        $c = [int]$clean[$i]
        if ([char]::IsHighSurrogate($clean[$i]) -and $i + 1 -lt $clean.Length -and [char]::IsLowSurrogate($clean[$i + 1])) {
            $w += 2
            $i++
            continue
        }
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0x9FFF) -or
            ($c -ge 0xA000 -and $c -le 0xA4CF) -or
            ($c -ge 0xA960 -and $c -le 0xA97F) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or
            ($c -ge 0x20000 -and $c -le 0x3FFFD)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

<#
.SYNOPSIS
    Resolves a color name to a System.ConsoleColor from State, config, or fallback.
.DESCRIPTION
    Checks State.Colors, global GState.Colors, LogConfig.DefaultColors, and the
    provided fallback in order. Parses the result to a valid ConsoleColor.
.PARAMETER ColorName
    The name of the color to resolve.
.PARAMETER State
    State object that may contain a Colors dictionary.
.PARAMETER Fallback
    Default color name if resolution fails.
#>
function Resolve-SafeColor {
    [CmdletBinding()]
    param(
        [string]$ColorName,
        [PSCustomObject]$State,
        [string]$Fallback = 'White'
    )

    # Try to get color from State, then BuildContext (via DI), then default config, then parameter
    $raw = $null
    $gStateRef = Get-BuildState -State $State
    $colorSources = @($State, $gStateRef)

    foreach ($source in $colorSources) {
        if ($source -and $source.Colors -and $source.Colors.$ColorName) {
            $raw = $source.Colors.$ColorName
            break
        }
    }

    if (-not $raw -and $script:LogConfig.DefaultColors.$ColorName) {
        $raw = $script:LogConfig.DefaultColors.$ColorName
    }

    if (-not $raw) {
        $raw = if ($ColorName) { $ColorName } else { $Fallback }
    }

    # Parse to ConsoleColor with robust error handling
    try {
        return [System.ConsoleColor]([System.Enum]::Parse([System.ConsoleColor], [string]$raw, $true))
    }
    catch {
        try { return [System.ConsoleColor]$Fallback }
        catch { return [System.ConsoleColor]::White }
    }
}

<#
.SYNOPSIS
    Wrapper around Resolve-SafeColor that returns a typed ConsoleColor value.
.DESCRIPTION
    Delegates to Resolve-SafeColor with the given parameters.
.PARAMETER State
    State object for color resolution.
.PARAMETER Name
    The color name to resolve.
.PARAMETER Fallback
    Default ConsoleColor name if not found.
#>
function Resolve-ConsoleColor {
    [CmdletBinding()]
    [OutputType([System.ConsoleColor])]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory=$true)] [string]$Name,
        [string]$Fallback = 'White'
    )
    if (-not $State) { return [System.ConsoleColor]$Fallback }
    return Resolve-SafeColor -ColorName $Name -State $State -Fallback $Fallback
}

# ==================================================================================
# CORE LOG ENGINE (ANTI FILE-LOCK)
# ==================================================================================
<#
.SYNOPSIS
    Core logging function that writes messages to console and optionally to a log file.
.DESCRIPTION
    Applies log-level filtering, resolves color via Resolve-SafeColor, writes to
    console with emoji-safe text, and appends to the log file with retry logic.
.PARAMETER Message
    The log message to write.
.PARAMETER Color
    Color name for the console output.
.PARAMETER State
    State object for configuration and color resolution.
.PARAMETER Level
    Log level severity (ERROR, WARN, INFO, DEBUG).
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [string]$Color = "White",
        [Parameter(Position=2)] [PSCustomObject]$State = $null,
        [string]$Level = "INFO"
    )

    # Sanitize credentials before any write (console/file/JSON) using config patterns
    $Message = Remove-Credentials -Text $Message -State $State

    # Convention repair (scoped logging): many callers pass a level name
    # ('Debug') in the Color slot. 'Debug' is not a palette color (it falls back
    # to White), so when -Level was not explicitly bound, honor it as the message
    # level instead of leaking Debug notes at INFO on every unrelated build.
    if ($Color -ieq 'Debug' -and -not $PSBoundParameters.ContainsKey('Level')) {
        $Level = 'DEBUG'; $Color = 'Gray'
    }

    # Normalize level
    $levelNum = switch ($Level) {
        'ERROR'   { 0 }
        'WARN'    { 1 }
        'INFO'    { 2 }
        'DEBUG'   { 3 }
        default   { 2 }
    }

    # Get current log level — prefer State, then BuildContext (via DI), then module default.
    # Normalize EVERY branch to an int immediately: Set-LogLevel stores a STRING
    # ("Debug"/"Error"/...) on State.LogLevel, and a raw string fell through the
    # `-is [int]` clamp below back to 2 (Info) — so CLI -LogLevel Debug/Error was
    # silently dead (Debug messages suppressed, Error allowed to pass).
    $levelToInt = {
        param($val)
        switch ("$val") {
            'Error' { 0 }
            'Warn'  { 1 }
            'Info'  { 2 }
            'Debug' { 3 }
            default { if ($val -is [int]) { [int]$val } else { 2 } }
        }
    }
    $currentLevel = 2
    if ($State -and $null -ne $State.LogLevel) {
        $currentLevel = & $levelToInt $State.LogLevel
    } elseif ($script:LogLevel) {
        $currentLevel = & $levelToInt $script:LogLevel
    } else {
        $diState = Get-BuildState -State $State
        if ($diState -and $null -ne $diState.LogLevel) {
            $currentLevel = & $levelToInt $diState.LogLevel
        }
    }

    if ($levelNum -gt $currentLevel) { return }

    if ([string]::IsNullOrWhiteSpace($Color)) { $Color = "White" }

    # Resolve color using centralized function
    $fg = Resolve-ConsoleColor -Name $Color -State $State -Fallback 'White'

    # 1. Console output with error handling (emoji → ASCII on PS5.1)
    $consoleMsg = Resolve-BuildText -Text $Message
    try { Write-Host $consoleMsg -ForegroundColor $fg } catch { Write-Host $consoleMsg }

    # 2. File output with retry logic using .NET API (preserve emoji)
    if ($script:LogFilePath) {
        $timestamp = Get-LogDisplayTimestamp
        $localizedLevel = switch ($Level) {
            'ERROR' { Get-LogLocalized -Key 'log.level.error' -Fallback 'ERROR' }
            'WARN'  { Get-LogLocalized -Key 'log.level.warn'  -Fallback 'WARN' }
            'INFO'  { Get-LogLocalized -Key 'log.level.info'  -Fallback 'INFO' }
            'DEBUG' { Get-LogLocalized -Key 'log.level.debug' -Fallback 'DEBUG' }
            default { $Level }
        }
        $logLine = "[$timestamp] [$localizedLevel] $Message$([System.Environment]::NewLine)"
        $encoding = $script:LogConfig.DefaultLogEncoding
        $retryAttempts = [int](Resolve-ConfigValue -State $State -Path 'logging.fileRetryAttempts' -Default $script:LogConfig.FileRetryAttempts)
        $retryDelayMs = [int](Resolve-ConfigValue -State $State -Path 'logging.fileRetryDelayMs' -Default $script:LogConfig.FileRetryDelayMs)

        for ($i = 0; $i -lt $retryAttempts; $i++) {
            try {
                [System.IO.File]::AppendAllText($script:LogFilePath, $logLine, $encoding)
                break
            } catch {
                if ($i -lt ($retryAttempts - 1) -and $retryDelayMs -gt 0) {
                    Start-Sleep -Milliseconds $retryDelayMs
                }
            }
        }
    }

    # 3. Structured JSON log (machine-parseable) when enabled via logging.enableJsonLog
    if ($script:JsonLogPath) {
        Write-JsonLog -Message $Message -Level $Level -State $State
    }
}

<#
.SYNOPSIS
    Runs a script block, swallowing and logging any error instead of throwing.
.DESCRIPTION
    Consolidates the repeated try/catch + Write-Log fallback pattern that
    appeared across modules (SDK detection, parse fallbacks, audit writes, etc.).
    On success the script block's output is returned; on any error the message is
    logged at the given color level and $null is returned, so callers continue
    gracefully. This is the helper referenced by the "Reduce duplicate try/catch +
    Write-Log wrapper" item in the 10/10 hardening plan.
#>
function Write-ErrorSafe {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [scriptblock]$ScriptBlock,
        [Parameter(Position = 1)] [string]$Message = 'Operation failed',
        [string]$Color = 'Debug'
    )
    try {
        return & $ScriptBlock
    } catch {
        Write-Log $Message $Color
        return $null
    }
}

<#
.SYNOPSIS
    Safe logging wrapper that works regardless of whether Logging module is loaded.
    Replaces the repeated `if (Get-Command Write-Log) { Write-Log ... } else { Write-Host ... }`
    pattern found across 115+ locations. Uses Write-Log when available, otherwise
    falls back to Write-Host with basic color mapping.
.DESCRIPTION
    Centralizes the fallback logic so callers don't need to duplicate the guard.
    Accepts the same parameters as Write-Log plus an optional State for color resolution.
    When Write-Log is available, delegates fully (including credential redaction, JSONL, file retry).
    When not, writes to console with ANSI-safe colors and minimal formatting.
.PARAMETER Message
    The log message to write.
.PARAMETER Color
    Color name (Header, Info, Warn, Err, Succ, Gray, White) or ConsoleColor.
.PARAMETER State
    Optional state object for color resolution and config.
.PARAMETER Level
    Log level (ERROR, WARN, INFO, DEBUG).
#>
function Write-LogSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [string]$Color = "White",
        [Parameter(Position=2)] [PSCustomObject]$State = $null,
        [string]$Level = "INFO"
    )

    # Sanitize credentials before any write
    $Message = Remove-Credentials -Text $Message -State $State

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message $Message -Color $Color -State $State -Level $Level
        return
    }

    # Fallback: direct Write-Host with basic color mapping
    $colorMap = @{
        'Header' = 'Magenta'; 'Info' = 'Cyan'; 'Warn' = 'Yellow'
        'Err'    = 'Red';     'Succ' = 'Green'; 'Gray' = 'DarkGray'; 'White' = 'White'
        'Error'  = 'Red';     'Warning' = 'Yellow'; 'Debug' = 'Gray'
    }
    $fg = 'White'
    if ($colorMap.ContainsKey($Color)) { $fg = $colorMap[$Color] }
    elseif ($Color -in [System.Enum]::GetNames([System.ConsoleColor])) { $fg = $Color }

    $prefix = switch ($Level) {
        'ERROR' { '[FATAL] ' }
        'WARN'  { '[WARN]  ' }
        'INFO'  { '[INFO]  ' }
        'DEBUG' { '[DEBUG] ' }
        default { '' }
    }
    try { Write-Host "$prefix$Message" -ForegroundColor $fg } catch { Write-Host "$prefix$Message" }
}

<#
.SYNOPSIS
    Writes a structured JSON log entry (JSONL) for machine consumption / monitoring.
.DESCRIPTION
    Emits one JSON object per line with timestamp (UTC ISO-8601), level, message,
    the originating module (derived from the call stack, skipping Logging.psm1),
    and an optional correlation id from State. No-op when JSON logging is disabled.
.PARAMETER Message
    The log message to write.
.PARAMETER Level
    Log level severity (ERROR, WARN, INFO, DEBUG).
.PARAMETER State
    State object for correlation id resolution.
#>
function Write-JsonLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [string]$Level = "INFO",
        [PSCustomObject]$State = $null
    )
    if (-not $script:JsonLogPath) { return }
    $Message = Remove-Credentials -Text $Message -State $State
    $entry = [PSCustomObject]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        level         = $Level
        message       = $Message
        module        = $null
        correlationId = if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId') { $State.CorrelationId } else { $null }
    }
    try {
        $stack = Get-PSCallStack
        foreach ($frame in $stack) {
            if ($frame.ScriptName -and -not $frame.ScriptName.EndsWith('Logging.psm1')) {
                $entry.module = [System.IO.Path]::GetFileNameWithoutExtension($frame.ScriptName)
                break
            }
        }
    } catch { # benign — call-stack inspection is best-effort
        }
    try {
        [System.IO.File]::AppendAllText(
            $script:JsonLogPath,
            (($entry | ConvertTo-Json -Compress) + [System.Environment]::NewLine),
            [System.Text.Encoding]::UTF8)
    } catch { # benign — JSON log write is best-effort; logging continues without it
        }
}

<#
.SYNOPSIS
    Resolves the canonical secret-redaction routine and delegates to it.
.DESCRIPTION
    Internal guard shared by every redaction wrapper in this module. The canonical
    routine is SharedUtils.Protect-BuildSecretText; it is resolved on every call
    (importing SharedUtils on demand when it is not loaded yet) instead of being
    captured at module-load time, which is what used to make redaction depend on
    module load order. It never falls back to a narrower, locally maintained
    pattern set: when the canonical routine cannot be resolved at all the text is
    fail-closed to the redaction marker rather than emitted unscrubbed.
#>
<#
.SYNOPSIS
    Circular-dependency shim: forwards to the single owner, SharedUtils.
.DESCRIPTION
    The real implementation is SharedUtils.Invoke-BuildSecretProtect (exported).
    Logging cannot import SharedUtils at MODULE scope - SharedUtils ->
    ModuleBootstrap -> Import-BuildDependencies -> Logging is circular and exceeds
    the PS 5.1 re-import depth - so this lazy shim exists only so Logging can call
    the shared helper by name. It imports SharedUtils on demand, then delegates.
    The other three historical copies (Alerting, Sast, Security) are deleted.
#>
function Invoke-BuildSecretProtect {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Text,
        [PSCustomObject]$State = $null,
        [array]$Patterns = $null,
        [switch]$RedactUrls,
        [scriptblock]$UrlRedactor = $null
    )
    # Guard checks Protect-BuildSecretText (the TARGET routine), never this shim's
    # own name: Get-Command Invoke-BuildSecretProtect always finds this function
    # itself, so guarding on it would skip the on-demand import and every call
    # without SharedUtils loaded would return '***REDACTED***' for the WHOLE text.
    if (-not (Get-Command Protect-BuildSecretText -ErrorAction SilentlyContinue) -and
        -not (Get-Module -Name 'SharedUtils' -ErrorAction SilentlyContinue)) {
        # This inline import is REGISTERED, not forgotten: Logging is the root of
        # the bootstrap chain. ModuleBootstrap.ps1 dot-sources BuildImport, which
        # loads Logging, so Logging cannot dot-source ModuleBootstrap without a
        # cycle - it is the one module that cannot defer to the shared owner.
        # Measured by Modules/ProcessMetrics.psm1 and registered as an exemption
        # there for exactly this reason.
        $sharedUtilsPath = Join-Path $PSScriptRoot 'SharedUtils.psm1'
        if (Test-Path $sharedUtilsPath) {
            $null = Import-Module $sharedUtilsPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-Command Protect-BuildSecretText -ErrorAction SilentlyContinue)) { return '***REDACTED***' }
    $arguments = @{ Text = $Text; State = $State }
    if ($null -ne $Patterns) { $arguments.Patterns = $Patterns }
    if ($RedactUrls) {
        $arguments.RedactUrls = $true
        if ($null -ne $UrlRedactor) { $arguments.UrlRedactor = $UrlRedactor }
    }
    return [string](Protect-BuildSecretText @arguments)
}

<#
.SYNOPSIS
    Strips credentials/tokens from a string to prevent leakage into logs.
.DESCRIPTION
    Thin wrapper around the canonical redaction routine
    (SharedUtils.Protect-BuildSecretText). This used to capture
    Get-SecretRedactPatterns at module-load time, which meant the effective
    pattern set depended on whether SharedUtils happened to be loaded yet — the
    same message could be scrubbed or not depending on import order, silently.
    Delegation goes through Invoke-BuildSecretProtect, which resolves the routine
    on every call and imports SharedUtils on demand, so the behaviour is identical
    whatever the load order. Config-driven patterns
    (State.BuildConfig.security.redactPatterns) keep working via -State, and an
    explicit list can still be supplied via -Patterns. Safe to call on any message.
.PARAMETER Text
    The text to sanitize.
.PARAMETER State
    Optional state object carrying BuildConfig.security.redactPatterns.
.PARAMETER Patterns
    Optional explicit pattern list (array of objects with name/pattern/replacement).
    Overrides both config and built-in defaults when provided.
#>
function Remove-Credentials {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)] [string]$Text,
        [PSCustomObject]$State = $null,
        [array]$Patterns = $null
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return (Invoke-BuildSecretProtect -Text $Text -State $State -Patterns $Patterns)
}

# ==================================================================================
# DISPLAY FUNCTIONS (FIXED UNICODE ALIGNMENT)
# ==================================================================================

<#
.SYNOPSIS
    Displays text in a two-column layout with colour-coded left and right sections.
.DESCRIPTION
    Writes left-aligned text and right-aligned text on the same line, padded to
    the content width. Uses visual length (stripped of ANSI/emoji) for alignment.
.PARAMETER L
    Left column text.
.PARAMETER R
    Right column text.
.PARAMETER LC
    Color name for left column text.
.PARAMETER RC
    Color name for right column text.
.PARAMETER State
    State object for color resolution.
#>
function _2Col {
    [CmdletBinding()]
    param(
        [string]$L,
        [string]$R = "",
        [string]$LC = "White",
        [string]$RC = "DarkGray",
        [PSCustomObject]$State
    )
    $consoleL = Resolve-BuildText -Text $L
    $consoleR = Resolve-BuildText -Text $R
    $visualLen = Get-VisualLength -Text $consoleL
    $pad = [Math]::Max($script:GCL - $visualLen, 1)

    $fgL = Resolve-ConsoleColor -Name $LC -State $State -Fallback 'White'
    $rcName = if ($RC) { $RC } else { 'DarkGray' }
    $fgR = Resolve-ConsoleColor -Name $rcName -State $State -Fallback 'DarkGray'

    Write-Host $consoleL -NoNewline -ForegroundColor $fgL
    Write-Host (' ' * $pad) -NoNewline
    if ($consoleR) { Write-Host $consoleR -ForegroundColor $fgR }
    else           { Write-Host "" }
}

<#
.SYNOPSIS
    Displays a progress bar with percentage and label.
.DESCRIPTION
    Renders a console progress bar using the configured width, showing a
    percentage indicator and descriptive label beneath.
.PARAMETER Current
    Current progress value.
.PARAMETER Total
    Total value representing completion.
.PARAMETER Label
    Descriptive text shown next to the progress bar.
#>
function Show-ProgressBar {
    [CmdletBinding()]
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label
    )
    if ($Total -le 0) { $Total = 1 }
    $pct  = [int][Math]::Min([Math]::Ceiling($Current / $Total * 100), 100)
    $barWidth = $script:LogConfig.ProgressBarWidth
    $fill = [int][Math]::Min([Math]::Floor($pct / 100.0 * $barWidth), $barWidth)
    $bar  = "#" * $fill + "." * ($barWidth - $fill)

    $infoColor = Resolve-SafeColor -ColorName 'Info' -Fallback 'Cyan'
    $grayColor = Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray'

    Write-Host ""
    Write-Host "  [ $($pct.ToString('D2'))%] $bar  > $Label" -ForegroundColor $infoColor
    Write-Host ($script:LogConfig.SeparatorChar * $script:GW) -ForegroundColor $grayColor
}

<#
.SYNOPSIS
    Renders text inside a bordered box with visual character-width alignment.
.DESCRIPTION
    Draws a box using separator characters around the given text. Supports small
    and large padding, and an optional trailing separator line.
.PARAMETER Text
    The text to display inside the box.
.PARAMETER Color
    Color name for the text.
.PARAMETER ShowSeparator
    Whether to append a blank line after the box.
.PARAMETER Large
    Switch to use larger padding and blank lines around the text.
.PARAMETER State
    State object for color resolution.
#>
function Write-VisualBox {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$Color = "White",
        [bool]$ShowSeparator = $true,
        [switch]$Large,
        [PSCustomObject]$State
    )
    $padding = if ($Large) { $script:LogConfig.BoxPaddingLarge } else { $script:LogConfig.BoxPaddingSmall }
    $inner   = "$padding$Text$padding"
    $visualLen = Get-VisualLength -Text $inner
    $hLine   = $script:LogConfig.SeparatorChar * $visualLen

    $fg = Resolve-ConsoleColor -Name $Color -State $State -Fallback 'White'
    $grayColor = Resolve-ConsoleColor -Name 'Gray' -State $State -Fallback 'DarkGray'

    $displayInner = Resolve-BuildText -Text $inner
    if ($Large) { Write-Host "" }
    Write-Host "  +$hLine+" -ForegroundColor $grayColor
    if ($Large) { Write-Host "  |$(' ' * $visualLen)|" -ForegroundColor $grayColor }
    Write-Host "  |$displayInner|" -ForegroundColor $fg
    if ($Large) { Write-Host "  |$(' ' * $visualLen)|" -ForegroundColor $grayColor }
    Write-Host "  +$hLine+" -ForegroundColor $grayColor
    if ($ShowSeparator) { Write-Host "" }
}

<#
.SYNOPSIS
    Renders a step title using Write-VisualBox with standard padding.
#>
function Write-StepTitle { param([string]$Text, [string]$Color = "White", [bool]$ShowSeparator = $true, [PSCustomObject]$State) Write-VisualBox -Text $Text -Color $Color -ShowSeparator $ShowSeparator -State $State }
<#
.SYNOPSIS
    Renders a section title using Write-VisualBox with large padding and spacing.
#>
function Write-SectionBox { param([string]$Title, [string]$Color = "White", [PSCustomObject]$State) Write-VisualBox -Text $Title -Color $Color -Large -State $State }

<#
.SYNOPSIS
    Safely imports a module only if the file exists on disk.
.DESCRIPTION
    Checks for module file existence before importing, avoiding errors when
    modules are loaded in different contexts (standalone vs gbuild orchestrated).
    Returns $true if the module was loaded, $false if the file was missing.
.PARAMETER ModulePath
    Full path to the .psm1 file to import.
.PARAMETER Required
    If set, throws an error when the module file is not found (instead of returning $false).
#>
# Import-ModuleIfExists was deleted: exported, and called by nothing. The
# codebase's lazy-import owner is ModuleBootstrap.ps1, and every module that
# needs a conditional import goes through it; a second, differently-shaped
# helper with no caller was a third way to do the same thing.
<#
.SYNOPSIS
    Assign default console colors to State.Colors if not already present.
#>
function Set-StateColors {
    [CmdletBinding()]
    [OutputType([void])]
    param([PSCustomObject]$State)
    if (-not $State) { return }
    $existing = $State.PSObject.Properties.Name -contains 'Colors'
    if (-not $existing -or -not $State.Colors) {
        $colorMap = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            Get-BuildConstant -Key 'Colors'
        } else { $null }
        if (-not $colorMap) { $colorMap = $script:LogConfig.DefaultColors }
        $State | Add-Member -MemberType NoteProperty -Name Colors -Value (
            [PSCustomObject]@{
                Gray   = $colorMap.Gray
                Warn   = $colorMap.Warn
                Err    = $colorMap.Err
                Succ   = $colorMap.Succ
                Info   = $colorMap.Info
                Header = $colorMap.Header
                White  = $colorMap.White
            }
        ) -Force
    }
}

<#
.SYNOPSIS
    Renders a processing status message with the configured template.
.DESCRIPTION
    Formats the message using the Processing template (e.g. "Processing: {0}...")
    and writes it to the console in Gray.
.PARAMETER msg
    The item being processed, inserted into the template string.
#>
function Write-SubLog {
    [CmdletBinding()]
    param([string]$msg)
    $text = Resolve-LogMessage -Key 'Processing' -MessageArgs @($msg)
    Write-Log "  > $text" 'Gray' $null
}

<#
.SYNOPSIS
    Renders a completion message with optional elapsed time.
.DESCRIPTION
    Displays a ✅-prefixed completion message. If secs >= 0, appends elapsed
    time formatted to one decimal place.
.PARAMETER msg
    The completion message text.
.PARAMETER secs
    Elapsed time in seconds. -1 omits the time display.
.PARAMETER State
    State object for color resolution.
#>
function Write-Done {
    [CmdletBinding()]
    param(
        [string]$msg,
        [double]$secs = -1,
        [PSCustomObject]$State
    )
    $marker = Get-LogLocalized -Key 'log.marker.done' -Fallback '[v]'
    $status = if ($secs -ge 0) {
        Resolve-LogMessage -Key 'DoneWithTime' -MessageArgs @($secs.ToString('F1'))
    } else {
        Resolve-LogMessage -Key 'Done'
    }
    $text = if (-not [string]::IsNullOrWhiteSpace($msg)) { "$msg - $status" } else { $status }
    Write-Log "$marker $text" 'Succ' $State
}

<#
.SYNOPSIS
    Renders a failure message with optional elapsed time.
.DESCRIPTION
    Displays a ❌-prefixed failure message. If secs >= 0, appends elapsed
    time formatted to one decimal place.
.PARAMETER msg
    The failure message text.
.PARAMETER secs
    Elapsed time in seconds. -1 omits the time display.
.PARAMETER State
    State object for color resolution.
#>
function Write-Fail {
    [CmdletBinding()]
    param(
        [string]$msg,
        [double]$secs = -1,
        [PSCustomObject]$State
    )
    $marker = Get-LogLocalized -Key 'log.marker.fail' -Fallback '[x]'
    $status = if ($secs -ge 0) {
        Resolve-LogMessage -Key 'FailWithTime' -MessageArgs @($secs.ToString('F1'))
    } else {
        Resolve-LogMessage -Key 'Fail'
    }
    $text = if (-not [string]::IsNullOrWhiteSpace($msg)) { "$msg - $status" } else { $status }
    Write-Log "$marker $text" 'Err' $State
}

<#
.SYNOPSIS
    Renders an info message with ℹ prefix using the _2Col layout.
.PARAMETER msg
    The info message text.
.PARAMETER State
    State object for color resolution.
#>
function Write-Info {
    [CmdletBinding()]
    param([string]$msg, [PSCustomObject]$State)
    # The doc-comment already promised an info marker and log.marker.info
    # shipped in every locale, but the marker was never applied. Write-Log
    # already does this for log.marker.done / log.marker.fail; these two were
    # the asymmetric remainder. Get-LogLocalized supplies the PS 5.1 ASCII
    # fallback ([i]) where the glyph is not renderable.
    Write-Log "$(Get-LogLocalized -Key 'log.marker.info' -Fallback '[i]') $msg" 'Info' $State
}

<#
.SYNOPSIS
    Renders a warning message with ⚠ prefix using the _2Col layout.
.PARAMETER msg
    The warning message text.
.PARAMETER State
    State object for color resolution.
#>
function Write-Warn {
    [CmdletBinding()]
    param([string]$msg, [PSCustomObject]$State)
    Write-Log "$(Get-LogLocalized -Key 'log.marker.warn' -Fallback '[!]') $msg" 'Warn' $State
}


<#
.SYNOPSIS
    Renders a separator line spanning the full window width.
.DESCRIPTION
    Writes a line of separator characters across the entire console width
    using the configured SeparatorChar and Gray colour.
#>
function Write-Sep {
    [CmdletBinding()]
    param()
    $grayColor = Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray'
    Write-Host ($script:LogConfig.SeparatorChar * $script:GW) -ForegroundColor $grayColor
}


$script:HasWriteLog = $true
function Set-BuildStateProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [object]$Value,
        [switch]$Force
    )
    $State | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force:$Force -ErrorAction SilentlyContinue
}


# Get-BuildState - canonical state accessor (DI-first, no global fallback).
# Defined here (foundational module) so it is available to every module and step that
# previously reached for the mutable global state directly. After the DI container
# registers the BuildContext singleton (Orchestrator.psm1 seeds it from the global),
# the container-managed instance becomes the source of truth.
# During bootstrap callers must pass `$State explicitly.

function Get-BuildState {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State
    )
    if ($State) { return $State }
    if ((Test-Path Variable:global:GBuildServices) -and $null -ne $global:GBuildServices -and $global:GBuildServices.ContainsKey('BuildContext')) {
        try { return Resolve-Service -Name 'BuildContext' } catch {
            # benign - DI container not available yet
            }
    }
    if (Test-Path Variable:global:GState) { return $global:GState }
    return $null
}

<#
.SYNOPSIS
    DRY helper for standalone scripts (Steps/Hooks/Tools) that need a State object.
.DESCRIPTION
    Replaces the repeated `if (-not $State) { $State = Get-BuildState }` pattern.
    Returns the passed State when present, otherwise resolves the active build
    state via Get-BuildState (DI BuildContext -> $global:GState -> $null).
.PARAMETER State
    Optional State object; when null/empty the active build state is resolved.
.OUTPUTS
    PSCustomObject - the effective state (may be $null if none is active).
#>
function Resolve-BuildState {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$State
    )
    # Get-BuildState already handles: explicit State first, then DI BuildContext,
    # then $global:GState, then $null — so fully delegate here.
    return (Get-BuildState -State $State)
}

Export-ModuleMember -Function @('Set-LogLevel', 'Write-Log', 'Write-ErrorSafe', 'Write-LogSafe', 'Write-JsonLog', 'Remove-Credentials', 'Invoke-LogRotation', 'Invoke-LogRetention',
'Get-LogConfigValue', 'Resolve-ConfigValue', '_2Col', 'Show-ProgressBar', 'Write-VisualBox', 'Write-StepTitle', 'Write-SectionBox',
'Write-SubLog', 'Write-Done', 'Write-Fail', 'Write-Info', 'Write-Warn', 'Write-Sep', 'Start-Log', 'Stop-Log', 'Get-VisualLength', 'Resolve-SafeColor',
'Resolve-ConsoleColor', 'Resolve-BuildText', 'Set-StateColors', 'Get-BuildState', 'Resolve-BuildState', 'Set-BuildStateProperty', 'Resolve-LogMessage',
'Get-LogLocalized')
