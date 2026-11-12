# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('PathUtils', 'BuildConstants')

function Resolve-EnvPlaceholder {
    [CmdletBinding()]
    # -InputObject alias: external callers (ConfigProvider, Orchestrator) use that name.
    param([Alias('InputObject')][string]$Text)

Set-StrictMode -Version 1.0
    if (-not $Text) { return $Text }
    $resolved = [regex]::Replace($Text, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
        param($match)
        $varName = $match.Groups[1].Value
        $val = [Environment]::GetEnvironmentVariable($varName)
        # MatchEvaluator results are inserted LITERALLY by Regex.Replace — no
        # re-escaping needed. Escaping here doubled every backslash in the value
        # ('C:\Users' -> 'C:\\Users').
        if ($val) { return $val } else { return $match.Value }
    })
    return $resolved
}

<#
.SYNOPSIS
    Reports whether a config value still contains an unresolved ${env:VAR} placeholder.
.DESCRIPTION
    Single source for the "is this value really configured?" check. An unset
    env var leaves the literal placeholder in place (see Resolve-EnvPlaceholder),
    which is truthy but unusable as an endpoint/name/token. Callers treat such
    values as UNCONFIGURED (empty) so optional infra degrades gracefully instead
    of dialing literal '${env:...}' strings. Used by CacheProvider (endpoint /
    region names), Siem (endpoint), DeployTargets (registry), Orchestrator (OTEL).
#>
function Test-UnresolvedEnvPlaceholder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}')
}

<#
.SYNOPSIS
    Tri-state environment toggle for per-environment feature enablement (L5).
.DESCRIPTION
    Single source for GBUILD_* opt-in flags (GBUILD_PROMETHEUS, GBUILD_CHAOS,
    GBUILD_AUDIT_LEDGER, ...). Returns $true for 1/true/yes/on/enable/enabled,
    $false for 0/false/no/off/disable/disabled, $null when unset/empty/unrecognized.
    $null means "no environment opinion" so config-file behaviour is preserved
    and unit tests (no env set) are unaffected.
#>
function Test-EnvToggle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $v = $null
    try { $v = [Environment]::GetEnvironmentVariable($Name) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    switch -Regex ($v.Trim().ToLowerInvariant()) {
        '^(1|true|yes|on|enable|enabled)$' { return $true }
        '^(0|false|no|off|disable|disabled)$' { return $false }
        default { return $null }
    }
    return $null
}

<#
.SYNOPSIS
    OS- and location-correct launcher invocation for user-facing hints (L5).
.DESCRIPTION
    Single source for every "run gbuild like this" hint (LOCALE switch line,
    TIP lines, help text, guard messages). Two dimensions:
      OS  : Windows (PowerShell) uses backslash form, Linux/macOS/Git Bash slash form.
      CWD : commands are relative to where the USER stands, and _Build may live
            in ANY directory under ANY folder name (never hardcoded):
              cwd == tool dir    -> .\[gbuild.ps1|gbuild]      (e.g. PS <tool-dir>)
              cwd == tool parent -> .\[Folder\gbuild.ps1|Folder/gbuild]
              elsewhere          -> canonical from-parent form (documented default)
            Without -ScriptRoot (unknown tool location) falls back to the
            legacy .\ _Build / ./_Build forms.
    Self-contained probes (no module dependency — usable from gbuild.ps1
    early bootstrap, Documentation, Orchestrator and Install scripts).
#>
function Get-InvokeCommandHint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Arguments = '',
        [string]$ScriptRoot = '',
        [string]$FromDirectory = ''
    )
    $isWin = $false
    try {
        $autoWin = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $autoWin) { $isWin = [bool]$autoWin }
        else { $isWin = Test-IsWindowsHost }
    } catch { $isWin = Test-IsWindowsHost }
    $sep = if ($isWin) { '\' } else { '/' }
    $dot = if ($isWin) { '.\' } else { './' }
    $entry = if ($isWin) { 'gbuild.ps1' } else { 'gbuild' }
    $cmd = "${dot}_Build${sep}${entry}"
    try {
        if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
            $toolFull = [System.IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\', '/')
            $folder = Split-Path $toolFull -Leaf
            if ([string]::IsNullOrWhiteSpace($folder)) { $folder = '_Build' }
            $fromFull = if ([string]::IsNullOrWhiteSpace($FromDirectory)) { '' } else { [System.IO.Path]::GetFullPath($FromDirectory).TrimEnd('\', '/') }
            # Single source for path case sensitivity (PathUtils.Get-PathComparison).
    $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison } else { if ($isWin) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
            if ($fromFull -and [string]::Equals($fromFull, $toolFull, $cmp)) {
                # Standing inside the tool dir (e.g. PS <tool-dir>): no folder prefix.
                $cmd = "${dot}${entry}"
            } else {
                # Standing in the tool parent or anywhere else: canonical
                # from-parent form with the ACTUAL folder name.
                $cmd = "${dot}${folder}${sep}${entry}"
            }
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) { return "$cmd $Arguments" }
    return $cmd
}

<#
.SYNOPSIS
    Reads a raw environment string for mode-style flags (L5).
.DESCRIPTION
    Returns the lowercased trimmed value of $Name, or '' when unset. Used for
    multi-value flags like GBUILD_RBAC_MODE (audit|enforce) and
    GBUILD_CHAOS_SCENARIOS (comma-separated scenario list).
#>
function Get-EnvMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    try {
        $v = [Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($v)) { return '' }
        return $v.Trim().ToLowerInvariant()
    } catch { return '' }
}

# Internal shared .env parser: reads key=value pairs in FILE ORDER (duplicates
# preserved) and normalizes each line — strips a leading 'export', trims quotes,
# strips inline "# ..." comments for unquoted values, and drops invalid key names.
# Pure (no environment mutation); consumers decide whether/how to apply values.
function Read-DotEnvLines {
    [CmdletBinding()]
    [OutputType([array])]
    param([Parameter(Mandatory)][string]$Path)
    $parsed = [System.Collections.ArrayList]::new()
    if (-not (Test-Path $Path)) { return @($parsed) }
    $rawLines = Get-Content -Path $Path -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $rawLines) { return @($parsed) }
    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^export\s+(.+)$') { $trimmed = $Matches[1].Trim() }
        $eq = $trimmed.IndexOf('=')
        if ($eq -le 0) { continue }
        $key = $trimmed.Substring(0, $eq).Trim()
        $val = $trimmed.Substring($eq + 1).Trim()
        if (-not $key -or $key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        } else {
            $hashIdx = $val.IndexOf(' #')
            if ($hashIdx -ge 0) { $val = $val.Substring(0, $hashIdx).Trim() }
        }
        $parsed.Add([PSCustomObject]@{ Key = $key; Value = $val }) | Out-Null
    }
    return @($parsed.ToArray())
}

function Read-DotEnvFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    # Pure read — no environment mutation. Returns a hashtable (last duplicate key wins).
    # This is the ONLY .env entry point the system has, and it is the one
    # ConfigProvider.Read-ConfigEnvironmentFile uses to serve build.envFile.
    #
    # Two sibling mutators used to sit here: Import-DotEnvFile (writes every key
    # into the live process environment) and Remove-DotEnvFile (clears them
    # again). Neither had a single production caller, and the comment on
    # Read-DotEnvFile explains exactly why the mutating form is the wrong design
    # here: a build that writes into its own process environment leaks
    # GBUILD_PROJECT and friends into every later step and into the next run in
    # the same host. A build system should read configuration, not rewrite the
    # environment it was launched in, so the mutators were removed rather than
    # left as an unused capability.
    $result = @{}
    foreach ($entry in Read-DotEnvLines -Path $Path) { $result[$entry.Key] = $entry.Value }
    return $result
}

function Invoke-SafeRemove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowedRoots = @(),
        [switch]$Force,
        [switch]$Recurse
    )
    if (-not (Test-Path $Path)) { return }
    $resolved = (Resolve-Path $Path).Path
    # Containment check single-sourced in PathUtils.Test-PathUnderRoots.
    # Level 5 resilience: inline strictly-under fallback when PathUtils was
    # orphaned (PS 5.1 nested re-import). Fail-closed: any doubt => refuse.
    $allowed = if ($AllowedRoots.Count -gt 0) {
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) { Test-PathUnderRoots -Path $resolved -AllowedRoots $AllowedRoots }
        else {
            $underOk = $false
            try {
                $tFull = ([System.IO.Path]::GetFullPath([string]$resolved)).TrimEnd('\', '/')
                $cmp = Get-PathComparison

                foreach ($ar in $AllowedRoots) {
                    if ([string]::IsNullOrWhiteSpace([string]$ar)) { continue }
                    $aFull = ([System.IO.Path]::GetFullPath([string]$ar)).TrimEnd('\', '/')
                    if ($tFull.StartsWith($aFull + [System.IO.Path]::DirectorySeparatorChar, $cmp)) { $underOk = $true; break }
                }
            } catch { $underOk = $false }
            $underOk
        }
    } else { $true }
    if (-not $allowed) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.safe.removeRefused' -MessageArgs @([string]$resolved, ($AllowedRoots -join ', ')) -Fallback '[SAFE] Refusing to remove {0} (not under allowed roots: {1})') 'Warn'
        }
        return
    }
    # Clear explicit Deny ACLs before deleting. The chaos PermissionDenied drill
    # (and any hand-locked temp dir) denies 'Everyone', which includes the
    # deleter - so a plain Remove-Item fails and the path leaks. Same rule as
    # Chaos.Remove-ChaosInjection: strip Deny entries first, then delete. Best
    # effort and never throws; a path that still cannot be removed is left for
    # the operator (a failed cleanup must not fail the build it cleans for).
    # Test-IsWindowsHost (not $IsWindows): the automatic variable does not exist
    # on Windows PowerShell 5.1 and throws under Set-StrictMode.
    $isWinHost = $false
    try {
        if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { $isWinHost = [bool](Test-IsWindowsHost) }
        else { $isWinHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
    } catch { $isWinHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
    if ($isWinHost) {
        try {
            $acl = Get-Acl -LiteralPath $resolved -ErrorAction SilentlyContinue
            if ($acl -and $acl.Access) {
                $denyRules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })
                foreach ($r in $denyRules) { try { [void]$acl.RemoveAccessRule($r) } catch { } }
                if ($denyRules.Count -gt 0) {
                    try { Set-Acl -LiteralPath $resolved -AclObject $acl -ErrorAction SilentlyContinue } catch { }
                }
            }
        } catch { }
    }
    Remove-Item -Path $resolved -Recurse:$Recurse -Force:$Force -EA SilentlyContinue
}

function Get-BuildTenantId {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($State -and $State.TenantId) { return $State.TenantId }
    return $null
}

function Get-BuildCorrelationId {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($State -and $State.CorrelationId) { return $State.CorrelationId }
    return $null
}

function Get-BuildIdentity {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    # Single owner for the process-identity chain. Previously re-implemented in
    # 6 modules with 5 different fallbacks ('unknown' here, 'unknown-user' in
    # Locale/CredentialVault, DNS/MachineName in Report/Versioning/EnvironmentProvider,
    # '-' in Siem), so the same machine produced five identities in the audit
    # trail - and CredentialVault derived a PBKDF2 passphrase from the variant.
    # Chain extended to subsume the strictest callers: [Environment] for the
    # user, DNS for the host, 'unknown'/'unknown' as the terminal sentinel.
    $user = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { try { [System.Environment]::UserName } catch { 'unknown' } }
    if ([string]::IsNullOrWhiteSpace([string]$user)) { $user = 'unknown' }
    $hostname = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$hostname)) { try { $hostname = [System.Net.Dns]::GetHostName() } catch { $hostname = '' } }
    if ([string]::IsNullOrWhiteSpace([string]$hostname)) { $hostname = 'unknown' }
    return @{ User = $user; Host = $hostname }
}

function Get-AuditLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$DefaultFileName = 'audit.log'
    )
    $root = if ($State -and $State.ProjectRoot) { $State.ProjectRoot }
            elseif ($State -and $State.ScriptRoot) { $State.ScriptRoot }
            else { Split-Path $PSScriptRoot -Parent }
    $tenant = if ($State -and $State.TenantId) { $State.TenantId } else { 'default' }
    $cfgPath = $null
    if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and $State.BuildConfig.security.auditLogPath) {
        $cfgPath = $State.BuildConfig.security.auditLogPath
    }
    if ($cfgPath) {
        if ([System.IO.Path]::IsPathRooted($cfgPath)) { return $cfgPath }
        if ($cfgPath -match '[\\/]') { return Join-Path $root $cfgPath }
        $dir = Join-Path $root (Join-Path (Get-BuildConstant -Key 'LogsDir' -Fallback 'logs') $tenant)
        return Join-Path $dir $cfgPath
    }
    $dir = Join-Path $root (Join-Path (Get-BuildConstant -Key 'LogsDir' -Fallback 'logs') $tenant)
    return Join-Path $dir $DefaultFileName
}

<#
.SYNOPSIS
    Returns the ONE canonical map of cloud/API token families.
.DESCRIPTION
    Token families whose recogniser and whose redactor must never disagree.
    Before this owner existed the same three families were written THREE times
    with THREE different breadths inside this file - a narrow DETECTION pattern
    (SharedUtils.psm1 Get-SecretDetectionPatterns), a medium REDACTION pattern
    (Get-SecretRedactPatterns) and a wide UNION pattern
    (Get-BuildSecretRedactPatterns tier 2). The detection set was the narrowest
    of the three, so an Azure-style key 'sk-proj-…' was REDACTED on its way
    into a report while never being REPORTED by the secret scanner - which let
    blockOnCriticalVulns pass on a file that genuinely held a live key.

    Both the detector and the redactor now derive their token families from
    this single ordered map, so "detector is a superset of the redactor" is true
    by construction instead of by coincidence. Order matters: the longest, most
    specific family ('sk-or-v1-…') must precede the generic 'sk-…' family so the
    informative replacement prefix wins.

    Config projection: BuildConstants.SecuritySecretDetectionPatterns mirrors
    these families and is mapped to security.secretPatterns, so an operator can
    extend the detection set without editing code.
#>
function Get-SecretTokenFamilyMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Ordered: the most specific member of each prefix family comes first.
    # OpenAI Key uses a NEGATIVE LOOKAHEAD to exclude the OpenRouter prefix
    # (sk-or-v1-...), so the two patterns are DISJOINT and the same secret
    # is never reported twice. The order in the map still matters for the
    # redactor (most-specific-first so the informative prefix wins).
    return [ordered]@{
        'OpenRouter Key' = @{ Pattern = 'sk-or-v1-[A-Za-z0-9_-]{20,}';      Replacement = 'sk-or-v1-***REDACTED***'; Severity = 'Critical' }
        'OpenAI Key'    = @{ Pattern = 'sk-(?!or-v1-)[A-Za-z0-9_-]{20,}';    Replacement = 'sk-***REDACTED***';        Severity = 'Critical' }
        'GitHub Token'  = @{ Pattern = 'gh[pousr]_[A-Za-z0-9_]{20,}';       Replacement = 'ghp_***REDACTED***';      Severity = 'Critical' }
        'Google API Key' = @{ Pattern = 'AIza[0-9A-Za-z_-]{20,}';            Replacement = 'AIza***REDACTED***';       Severity = 'High' }
    }
}

function Get-SecretDetectionPatterns {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and $State.BuildConfig.security.secretPatterns) {
        return $State.BuildConfig.security.secretPatterns
    }
    # Token families come from the single canonical owner, so the detector can
    # never be narrower than the redactor. (This used to be the narrowest of the
    # three copies, which is what let Azure OpenAI keys through.)
    $family = Get-SecretTokenFamilyMap

    return @(
        @{ Name = 'OpenAI Key';         Pattern = $family['OpenAI Key'].Pattern;    Severity = $family['OpenAI Key'].Severity }
        @{ Name = 'OpenRouter Key';     Pattern = $family['OpenRouter Key'].Pattern; Severity = $family['OpenRouter Key'].Severity }
        @{ Name = 'AWS Access Key';     Pattern = 'AKIA[0-9A-Z]{16}';                     Severity = 'Critical' }
        @{ Name = 'AWS Secret Key';     Pattern = 'aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}'; Severity = 'Critical' }
        @{ Name = 'GitHub Token';       Pattern = $family['GitHub Token'].Pattern;    Severity = $family['GitHub Token'].Severity }
        @{ Name = 'Google API Key';     Pattern = $family['Google API Key'].Pattern;  Severity = $family['Google API Key'].Severity }
        @{ Name = 'Generic API Key';    Pattern = "(?i)api[_-]?key\s*[:=]\s*['""]?[a-zA-Z0-9_\-]{20,}"; Severity = 'Medium' }
        @{ Name = 'Connection String';  Pattern = '(?i)(server|host|data source).*?(password|pwd)\s*=\s*[^;]+'; Severity = 'High' }
        @{ Name = 'Private Key Block';  Pattern = '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'; Severity = 'Critical' }
        @{ Name = 'JWT Token';          Pattern = 'eyJ[A-Za-z0-9_=]+\.[A-Za-z0-9_=]+\.?[A-Za-z0-9_.+/=]*'; Severity = 'Medium' }
        @{ Name = 'Slack Token';        Pattern = 'xox[baprs]-[0-9]{10,12}-[0-9]{10,12}-[A-Za-z0-9]{20,}'; Severity = 'High' }
        @{ Name = 'Stripe Key';         Pattern = 'sk_(test|live)_[A-Za-z0-9]{24,}';       Severity = 'Critical' }
    )
}

function Get-SecretRedactPatterns {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and $State.BuildConfig.security.redactPatterns) {
        return $State.BuildConfig.security.redactPatterns
    }
    return @(
        @{ Name = 'OpenRouter Key';    Pattern = 'sk-or-v1-[A-Za-z0-9_-]{20,}';     Replacement = 'sk-or-v1-***REDACTED***' }
        @{ Name = 'OpenAI Key';        Pattern = 'sk-(?!or-v1-)[A-Za-z0-9_-]{20,}';    Replacement = 'sk-***REDACTED***' }
        @{ Name = 'AWS Access Key';    Pattern = 'AKIA[0-9A-Z]{16}';                Replacement = 'AKIA***REDACTED***' }
        @{ Name = 'AWS Secret Key';    Pattern = 'aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}'; Replacement = 'aws_secret_access_key=***REDACTED***' }
        @{ Name = 'GitHub Token';      Pattern = 'gh[pousr]_[A-Za-z0-9_]{20,}';      Replacement = 'ghp_***REDACTED***' }
        @{ Name = 'Google API Key';    Pattern = 'AIza[0-9A-Za-z_-]{20,}';           Replacement = 'AIza***REDACTED***' }
        @{ Name = 'Private Key Block'; Pattern = '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'; Replacement = '-----BEGIN ***REDACTED*** KEY-----' }
        @{ Name = 'JWT Token';         Pattern = 'eyJ[A-Za-z0-9_=]+\.[A-Za-z0-9_=]+\.?[A-Za-z0-9_.+/=]*'; Replacement = 'eyJ***REDACTED***' }
        @{ Name = 'Slack Token';       Pattern = 'xox[baprs]-[0-9]{10,12}-[0-9]{10,12}-[A-Za-z0-9]{20,}'; Replacement = 'xox***REDACTED***' }
        @{ Name = 'Stripe Key';        Pattern = 'sk_(test|live)_[A-Za-z0-9]{24,}';  Replacement = 'sk_***REDACTED***' }
        @{ Name = 'Bearer Token';      Pattern = 'Bearer\s+[A-Za-z0-9\-._~+/]+=*';  Replacement = 'Bearer ***REDACTED***' }
        @{ Name = 'Secret Assignment'; Pattern = '(?i)(password|passwd|token|secret|api_?key|access_?key|client_?secret)\s*[=:]\s*\S+'; Replacement = '$1=***REDACTED***' }
    )
}

# ==================================================================================
# CANONICAL SECRET REDACTION — the single routine every consumer must go through
# ==================================================================================
# Before this block the build carried SIX independent secret-redaction
# implementations whose pattern sets disagreed, and the effective result depended on
# which module happened to be loaded first (silently — nothing was logged):
#   Logging.Remove-Credentials          -> Get-SecretRedactPatterns (12 entries)
#   Security.Protect-SecurityText       -> Get-SecretRedactPatterns + Bearer + assignment
#   Sast.Protect-SastText               -> Remove-Credentials + inline sk- + Bearer + assignment
#   Alerting.Protect-AlertText          -> fully inline, ignored security.redactPatterns
#   Standalone.Assert-StandaloneConfigSafe -> 4th hand-rolled alternation
#   Remove-Credentials' empty-pattern path -> returned the text UNCHANGED (fail-open)
# Two markers were in use (***REDACTED*** vs [REDACTED]), and SharedUtils' own
# DETECTION list and REDACTION list disagreed ('Generic API Key' + 'Connection String'
# existed only in detection), so a secret that Find-SecretsInFile reported as Critical
# was not guaranteed to be redacted on the way into a report. Both lists are now
# reconciled through Get-BuildSecretRedactPatterns + Protect-BuildSecretText below.

<#
.SYNOPSIS
    Case-insensitive field read for a secret-pattern definition.
.DESCRIPTION
    Pattern definitions reach the union in two shapes: hashtables (the module's own
    defaults) and PSCustomObjects (ConvertFrom-Json output of security.redactPatterns),
    with differing field casings. Normalising the read here is what lets one union be
    assembled from both without duplicating the accessor at every call site.
#>
function Get-SecretPatternField {
    [CmdletBinding()]
    param($Object, [string[]]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            foreach ($candidate in $Name) { if ([string]$key -eq $candidate) { return $Object[$key] } }
        }
        return $null
    }
    $properties = $Object.PSObject.Properties
    foreach ($candidate in $Name) {
        $property = $properties[$candidate]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the canonical UNION of every secret-redaction pattern in the build.
.DESCRIPTION
    One list, built in two tiers:
      Tier 1 - config-driven entries from security.redactPatterns (via
               Get-SecretRedactPatterns, the config-driven source). Honoured
               verbatim, including their configured replacements. Applied FIRST and
               tagged Configured=$true so a configured replacement is not later
               overwritten by the generic assignment rule.
      Tier 2 - the canonical union (a superset of every pattern the six previous
               implementations used):
                 * the 12 Get-SecretRedactPatterns defaults, with the OpenAI /
                   GitHub / Google families WIDENED to the loosest variant any of
                   those implementations used (Sast/Alerting/Standalone matched
                   'sk-…_-', 'gh[pousr]_' and 'AIza' at 20 chars where the defaults
                   demanded 36/35 and allowed no '-' or '_', so Azure-style
                   'sk-proj-…' keys were matched by some paths and not others);
                 * 'Secret Assignment' replaced by a widened key/value rule that
                   unions the SharedUtils/Security/Sast key list with Alerting's
                   extra keys (authorization, credential, sas, signature, auth,
                   jwt, session) and preserves the original separator;
                 * 'Generic API Key' and 'Connection String' ADDED — they were in
                   Get-SecretDetectionPatterns only, so Critical/High findings were
                   not guaranteed to be redacted.
               Tier 2 order matters: token families first (their replacements keep
               the informative 'sk-***REDACTED***' prefix), broad rules last.
    Duplicate patterns are dropped (first occurrence wins, so config wins).
.PARAMETER State
    Optional state object; its BuildConfig.security.redactPatterns form tier 1.
.PARAMETER Patterns
    Explicit caller-supplied list. Remove-Credentials documents -Patterns as
    overriding config and defaults, so it replaces the canonical union rather than
    extending it. It is still fail-safe: an empty list is not honoured and falls
    back to the canonical union rather than disabling redaction.
#>
function Get-BuildSecretRedactPatterns {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [PSCustomObject]$State = $null,
        [array]$Patterns = $null
    )

    $union = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $add = {
        param($Source, [bool]$Configured, [string]$Name = '', [string]$Pattern = '', [string]$Replacement = '', [string]$Kind = '')
        $patternText = if ($Pattern) { $Pattern } else { [string](Get-SecretPatternField $Source @('pattern')) }
        if ([string]::IsNullOrWhiteSpace($patternText)) { return }
        if (-not $seen.Add($patternText)) { return }
        $nameText = if ($Name) { $Name } else { [string](Get-SecretPatternField $Source @('name')) }
        $replacementText = if ($Replacement) { $Replacement } else { [string](Get-SecretPatternField $Source @('replacement')) }
        $union.Add([PSCustomObject]@{
            Name        = $nameText
            Pattern     = $patternText
            Replacement = $replacementText
            Kind        = $Kind
            Configured  = $Configured
        })
    }

    # ── tier 1: caller-supplied list, else the config-driven source ──────────────
    $explicit = ($null -ne $Patterns)
    if ($explicit) {
        # Remove-Credentials documents -Patterns as overriding config and defaults.
        foreach ($entry in @($Patterns)) { & $add $entry $true }
    } elseif ($State -and $State.BuildConfig -and $State.BuildConfig.security -and $State.BuildConfig.security.redactPatterns) {
        # Only consulted when the config really carries the key, so this function's
        # own built-in defaults never masquerade as user configuration.
        foreach ($entry in @(Get-SecretRedactPatterns -State $State)) { & $add $entry $true }
    }

    # ── tier 2: the canonical union (skipped for an explicit -Patterns) ─────────
    if (-not $explicit) {
        $widenedPatterns = @{
            'OpenAI Key'     = 'sk-(?:or-v1-)?[A-Za-z0-9_-]{20,}'
            'GitHub Token'   = 'gh[pousr]_[A-Za-z0-9_]{20,}'
            'Google API Key' = 'AIza[0-9A-Za-z_-]{20,}'
        }
        $widenedReplacements = @{
            'OpenAI Key'     = 'sk-***REDACTED***'
            'GitHub Token'   = 'ghp_***REDACTED***'
            'Google API Key' = 'AIza***REDACTED***'
        }
        foreach ($entry in @(Get-SecretRedactPatterns)) {
            $entryName = [string](Get-SecretPatternField $entry @('name'))
            # Superseded by the widened key/value rule below, which matches a strict
            # superset of this one.
            if ($entryName -eq 'Secret Assignment') { continue }
            if ($widenedPatterns.ContainsKey($entryName)) {
                & $add $entry $false -Name $entryName -Pattern $widenedPatterns[$entryName] -Replacement $widenedReplacements[$entryName]
            } else {
                & $add $entry $false
            }
        }
        & $add $null $false -Name 'Secret Assignment' -Kind 'Assignment' -Pattern '(?i)(?<gbuild_key>authorization|credentials?|signature|session|access[_-]?key|client_?secret|api_?key|password|passwd|token|secret|sas|auth|jwt)\s*(?<gbuild_sep>[=:]\s*)(?!(?i:Bearer|Basic|Negotiate|Digest|token)\b)(?<gbuild_value>\S+)'
        & $add $null $false -Name 'Generic API Key' -Pattern "(?i)api[_-]?key\s*[:=]\s*['""]?[a-zA-Z0-9_\-]{20,}"
        & $add $null $false -Name 'Connection String' -Pattern '(?i)(server|host|data source).*?(password|pwd)\s*=\s*[^;]+'
    }

    # ── fail safe ────────────────────────────────────────────────────────────────
    # An empty pattern set must never mean "return the text unchanged" (the old
    # Remove-Credentials fail-open bug): fall back to the generic assignment rule.
    if ($union.Count -eq 0) {
        & $add $null $false -Name 'Secret Assignment' -Kind 'Assignment' -Pattern '(?i)(?<gbuild_key>password|passwd|token|secret|api_?key|access[_-]?key|client_?secret|authorization|credential|sas|signature|auth|jwt|session)\s*(?<gbuild_sep>[=:]\s*)(?!(?i:Bearer|Basic|Negotiate|Digest|token)\b)(?<gbuild_value>\S+)'
    }
    return @($union.ToArray())
}

<#
.SYNOPSIS
    Canonical secret redaction: strips credentials/tokens from a string.
.DESCRIPTION
    The ONE redaction routine in the build. Remove-Credentials (Logging),
    Protect-SecurityText (Security), Protect-SastText (Sast) and Protect-AlertText
    (Alerting) are thin wrappers around this function, and Standalone's config
    secret scan matches the same pattern set, so redaction can no longer depend on
    module load order or on which module is doing the writing.
    Pattern set: Get-BuildSecretRedactPatterns (config tier + canonical union).
    Marker: exactly one, '***REDACTED***' by default. A '***REDACTED***' token
    inside a pattern's own Replacement (module defaults and gbuild.config.json
    both use it) is rewritten to -Marker, so a configured replacement keeps its
    shape (e.g. 'sk-***REDACTED***') while still emitting the single marker.
    FAIL SAFE: an unresolvable/empty pattern set still applies the generic
    assignment rule, and an unexpected failure returns the marker rather than the
    unscrubbed text.
.PARAMETER Text
    The text to scrub. $null becomes ''.
.PARAMETER State
    Optional state object; supplies BuildConfig.security.redactPatterns.
.PARAMETER Patterns
    Optional explicit pattern list, honoured as an override of the union (an empty
    list falls back to it rather than disabling redaction).
.PARAMETER RedactUrls
    Opt-in URL scrubbing. Only Protect-AlertText used to do this, so it is the only
    caller that sets it: URL redaction in a generic scrubber is over-broad (it eats
    query strings and path segments that are usually harmless), so it must be asked
    for explicitly. Runs before the pattern pass so the later rules see a sanitised
    URL.
.PARAMETER Marker
    Redaction marker. Defaults to '***REDACTED***'.
.PARAMETER UrlRedactor
    Optional [string] -> [string] scriptblock for -RedactUrls, letting a caller
    keep its own URL policy (Alerting passes Get-AlertRedactedUrl). Without one, a
    generic structural pass masks userinfo and drops the query string.
#>
<#
.SYNOPSIS
    Single owner of the redaction ENTRY POINT: lazily resolves Protect-BuildSecretText
    and forwards, degrading to a fully-redacted marker if SharedUtils logic is missing.
.DESCRIPTION
    This wrapper existed as FOUR byte-identical private copies (Logging, Alerting,
    Sast, Security). Because none of them exported it, each module silently called
    its own copy, so "one shared secret-redaction helper" was four independent
    implementations that only agreed by accident - any change to one would have
    left the other three behind. SharedUtils is the right owner (Protect-BuildSecretText
    already lives here), so it is exported from here and the copies are gone.

    Logging keeps a local shim because SharedUtils -> ModuleBootstrap -> Logging is
    a circular module-scope dependency; it forwards to this one.
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
    if (-not (Get-Command Protect-BuildSecretText -ErrorAction SilentlyContinue)) { return '***REDACTED***' }
    $arguments = @{ Text = $Text; State = $State }
    if ($null -ne $Patterns) { $arguments.Patterns = $Patterns }
    if ($RedactUrls) {
        $arguments.RedactUrls = $true
        if ($null -ne $UrlRedactor) { $arguments.UrlRedactor = $UrlRedactor }
    }
    return [string](Protect-BuildSecretText @arguments)
}

function Protect-BuildSecretText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Text,
        [PSCustomObject]$State = $null,
        [array]$Patterns = $null,
        [switch]$RedactUrls,
        [string]$Marker = '***REDACTED***',
        [scriptblock]$UrlRedactor = $null
    )
    if ($null -eq $Text) { return '' }
    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) { return $value }
    if ([string]::IsNullOrEmpty($Marker)) { $Marker = '***REDACTED***' }

    try {
        $entries = @(Get-BuildSecretRedactPatterns -State $State -Patterns $Patterns)
        if ($entries.Count -eq 0) { $entries = @(Get-BuildSecretRedactPatterns) }
        if ($entries.Count -eq 0) { return $Marker }

        if ($RedactUrls) {
            $marker = $Marker
            $urlRedactor = $UrlRedactor
            $urlEvaluator = {
                param($match)
                $candidate = [string]$match.Value
                if ($urlRedactor) {
                    $safe = ''
                    try { $safe = [string](& $urlRedactor $candidate) } catch { $safe = '' }
                    if ($safe) { return $safe }
                    return $marker
                }
                try {
                    $uri = [System.Uri]::new($candidate)
                    if ($uri.Scheme -notin @('http', 'https')) { return $marker }
                    $builder = [System.UriBuilder]::new($uri)
                    if (-not [string]::IsNullOrWhiteSpace($builder.UserName) -or -not [string]::IsNullOrWhiteSpace($builder.Password)) {
                        $builder.UserName = '***'
                        $builder.Password = '***'
                    }
                    $builder.Query = ''
                    $builder.Fragment = ''
                    $safe = [string]$builder.Uri.AbsoluteUri
                    if ($safe -match '\?') { return ($safe -split '\?', 2)[0] }
                    return $safe
                } catch { return $marker }
            }.GetNewClosure()
            $value = [regex]::Replace($value, 'https?://[^\s"'']+', $urlEvaluator)
        }

        # A configured replacement must survive the built-in rules: a user's
        # 'CUSTOMKEY-***' must not be overwritten by the generic assignment rule.
        # Only literal configured replacements (no $ backreferences) are recognisable.
        $protected = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $entries) {
            if (-not $entry.Configured) { continue }
            $declared = [string]$entry.Replacement
            if ([string]::IsNullOrEmpty($declared)) { continue }
            $literal = $declared.Replace('***REDACTED***', $Marker)
            if ([string]::IsNullOrEmpty($literal) -or $literal.Contains('$')) { continue }
            $protected.Add($literal)
        }

        foreach ($entry in $entries) {
            $pattern = [string]$entry.Pattern
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            $declared = [string]$entry.Replacement
            $replacement = if ([string]::IsNullOrEmpty($declared)) { $Marker } else { $declared.Replace('***REDACTED***', $Marker) }
            try {
                if ($entry.Kind -eq 'Assignment') {
                    $marker = $Marker
                    $keep = $protected
                    $assignmentEvaluator = {
                        param($match)
                        $matched = [string]$match.Groups['gbuild_value'].Value
                        foreach ($literal in $keep) {
                            if ($matched.StartsWith($literal, [System.StringComparison]::Ordinal)) { return [string]$match.Value }
                        }
                        return ([string]$match.Groups['gbuild_key'].Value + [string]$match.Groups['gbuild_sep'].Value + $marker)
                    }.GetNewClosure()
                    $value = [regex]::Replace($value, $pattern, $assignmentEvaluator)
                } else {
                    $value = $value -replace $pattern, $replacement
                }
            } catch {
                # Malformed regex (typically config-supplied) or an evaluator fault:
                # skip this one pattern and keep redacting with the rest. Never
                # abandon the text, never fall open.
            }
        }
    } catch {
        # Fail CLOSED: an unexpected fault must not leak the original text.
        return $Marker
    }
    return $value
}

function Write-BuildAuditLog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][hashtable]$Entry,
        # -1 = sentinel "use default" (BuildConstants.AuditLogMaxSizeMB > 10).
        # Do NOT use 0 as the sentinel: 0 is a valid "always rotate" value (any
        # content exceeds 0MB — CredentialVault.Tests relies on this with 0.000001MB).
        [int]$MaxSizeMB = -1
    )
    if ($MaxSizeMB -lt 0) {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $MaxSizeMB = Get-BuildConstant -Key 'AuditLogMaxSizeMB' -Fallback 10
        } else {
            # BuildConstants not loaded: single-source fallback from BuildConstants.AuditLogMaxSizeMB = 10
            $MaxSizeMB = 10
        }
    }
    if (-not $Entry.ContainsKey('Timestamp')) { $Entry.Timestamp = (Get-Date).ToString('o') }
    $lock = $null
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { $null = Invoke-EnsureDirectory -Path $dir } elseif (-not (Test-Path $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null } }
        # Serialize append+rotation like the Merkle ledger does. The audit sink
        # previously wrote unlocked while the ledger locked, so concurrent builds
        # interleaved or lost entries here while the ledger stayed consistent.
        # A 5s budget (not the 15s default): an audit append must stay fast, and
        # a lock failure falls back to the previous unlocked behaviour rather
        # than failing the audited action outright.
        try { $lock = Enter-BuildFileLock -Path $LogPath -TimeoutMs 5000 } catch { $lock = $null }
        # Size-based rotation: rename to audit-<timestamp>.log and start fresh so
        # the audit trail never exceeds the configured size.
        if (Test-Path $LogPath -PathType Leaf) {
            try {
                if ((Get-Item $LogPath -EA Stop).Length -gt ($MaxSizeMB * 1MB)) {
                    $stamp = Get-BuildTimestamp -Kind RotationStamp
                    $rotated = Join-Path $dir ('audit-{0}.log' -f $stamp)
                    Move-Item -Path $LogPath -Destination $rotated -Force -ErrorAction SilentlyContinue
                }
            } catch {
                # benign — rotation is best-effort; continue appending
                }
        }
        $line = $Entry | ConvertTo-Json -Compress
        # No -ErrorAction SilentlyContinue on the append itself: it used to
        # suppress the write, so a failed privileged-action audit entry vanished
        # with zero signal. Failures now reach the catch below, which reports at
        # Warn (not Debug) and returns $false so strict-mode callers can fail
        # closed instead of authorizing unrecorded actions.
        if (-not (Write-BuildTextFileUtf8 -Path $LogPath -Value @($line) -Append -NoNewline)) { throw [System.IO.IOException]::new((Resolve-LogMessage -Key 'log.sharedutils.line787' -Fallback 'Failed to append the audit entry.')) }
        return $true
    } catch {
        $action = if ($Entry.ContainsKey('Action')) { [string]$Entry.Action } else { '' }
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            try { Write-Log (Resolve-LogMessage -Key 'log.audit.writeFailed' -MessageArgs @($action, [string]$_.Exception.Message) -Fallback 'Audit log write failed for action {0}: {1}') 'Warn' } catch { }
        }
        return $false
    } finally {
        if ($lock) { try { $lock.Dispose() } catch { } }
    }
}

<#
.SYNOPSIS
    Resolves a list constant from the single source (BuildConstants).
.DESCRIPTION
    Parameterized core for Get-SyntaxCheckExcludeDirs/Files so the
    on-demand-import + fallback logic lives in ONE place (Level 5 DRY).
#>
function Get-BuildListConstant {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [string[]]$Fallback = @()
    )
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $v = Get-BuildConstant -Key $Key -Fallback $null
        if ($v) { return @($v) }
    }
    # On-demand import of the zero-dep constants module (standalone import path).
    $bcPath = Join-Path $PSScriptRoot 'BuildConstants.psm1'
    if (Test-Path $bcPath) {
        $null = Import-Module $bcPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $v = Get-BuildConstant -Key $Key -Fallback $null
        if ($v) { return @($v) }
    }
    return @($Fallback)
}

<#
.SYNOPSIS
    Resolves the SyntaxCheck exclude-dir list from the single source
    (BuildConstants.SyntaxCheckExcludeDirs).
.DESCRIPTION
    Thin wrapper over Get-BuildListConstant (kept for backward compat).
#>
function Get-SyntaxCheckExcludeDirs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $r = Get-BuildListConstant -Key 'SyntaxCheckExcludeDirs' -Fallback @()
    if ($r.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.sharedutils.buildConstantsMissing' -Fallback '[SharedUtils] BuildConstants unavailable - SyntaxCheck exclude list is empty') 'Warn'
        }
    }
    return $r
}

function Get-SyntaxCheckExcludeFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return Get-BuildListConstant -Key 'SyntaxCheckExcludeFiles' -Fallback @('gbuild', 'gbuild.ps1', 'gbuild.bat')
}

function Get-BoundedProjectFiles {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Filters = @('*'),
        [int]$Depth = 999,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$File
    )
    $itemsFound = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    if ($Depth -lt 0) { $Depth = 999 }
    $excludedDirSet = @{}
    foreach ($d in @($ExcludeDirs)) { if ($d) { $excludedDirSet[[string]$d.ToLowerInvariant()] = $true } }
    $excludedFileSet = @{}
    foreach ($f in @($ExcludeFiles)) { if ($f) { $excludedFileSet[[string]$f.ToLowerInvariant()] = $true } }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([PSCustomObject]@{ Path = $Root; Level = 0 })
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        try { $children = @(Get-ChildItem -LiteralPath $node.Path -Force -ErrorAction Stop) } catch { continue }
        foreach ($item in $children) {
            if ($item.PSIsContainer) {
                if ($node.Level -ge $Depth) { continue }
                if ($excludedDirSet.ContainsKey(([string]$item.Name).ToLowerInvariant())) { continue }
                $queue.Enqueue([PSCustomObject]@{ Path = $item.FullName; Level = $node.Level + 1 })
                continue
            }
            $nameKey = ([string]$item.Name).ToLowerInvariant()
            if ($excludedFileSet.ContainsKey($nameKey)) { continue }
            $include = $false
            if (-not $Filters -or $Filters.Count -eq 0 -or ($Filters.Count -eq 1 -and $Filters[0] -eq '*')) {
                $include = $true
            } else {
                foreach ($pattern in $Filters) {
                    if ($item.Name -like $pattern) { $include = $true; break }
                }
            }
            if ($include) { $itemsFound.Add([System.IO.FileInfo]$item) }
        }
    }
    return $itemsFound.ToArray()
}

function Invoke-SyntaxCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$IncludeExtensions = @('.ps1','.psm1','.psd1'),
        # Default single-sourced via Get-SyntaxCheckExcludeDirs (BuildConstants is the
        # only place the literal list exists; on-demand import covers standalone use).
        [string[]]$ExcludeDirs = @(Get-SyntaxCheckExcludeDirs),
        # Default single-sourced via Get-SyntaxCheckExcludeFiles: build-system launcher
        # files (gbuild, gbuild.ps1, gbuild.bat) matched by name at any depth —
        # they are build-system artifacts, not project source.
        [string[]]$ExcludeFiles = @(Get-SyntaxCheckExcludeFiles),
        [switch]$Recurse
    )
    $files = Get-BoundedProjectFiles -Root $Root -Depth 999 -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles -File |
        Where-Object {
            $ext = $_.Extension.ToLowerInvariant()
            return ($ext -in $IncludeExtensions)
        }
    $checked = 0; $errors = 0; $errorLines = @()
    foreach ($f in $files) {
        $checked++
        $parseErrors = $null
        try {
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
        } catch {
            $parseErrors = @("Parse exception: $_")
        }
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $errors++
            foreach ($e in $parseErrors) {
                $errorLines += ("{0}:{1}: {2}" -f $f.FullName, $e.Extent.StartLineNumber, $e.Message)
            }
        }
    }
    # Dedupe: junctions/symlinks can yield the same file twice via -Recurse.
    $errorLines = @($errorLines | Sort-Object -Unique)
    return [pscustomobject]@{
        FilesChecked      = $checked
        FilesWithErrors   = $errors
        Errors            = $errorLines
    }
}

<#
.SYNOPSIS
    Universal syntax validator for multi-language projects.
.DESCRIPTION
    Validates project files by extension:
      - .ps1/.psm1/.psd1  : PowerShell parser
      - .cs/.fs/.vb       : bracket/statement balance heuristic
      - .csproj/.xml      : XML well-formed
      - .json             : JSON syntax
      - .toml             : TOML structure heuristic
      - .yml/.yaml        : YAML basic read
      - Dockerfile        : Dockerfile directive basic check
      - .gradle/.kts      : Groovy/Kotlin basic read
      - CMakeLists.txt    : CMake command basic check
#>
function Invoke-UniversalSyntaxCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Root, [switch]$Recurse)
    $psExt = @('.ps1','.psm1','.psd1')
    $csExt = @('.cs','.fs','.vb')
    $xmlExt = @('.csproj','.fsproj','.vbproj','.xml')
    $jsonExt = @('.json')
    $tomlExt = @('.toml')
    $yamlExt = @('.yml','.yaml')
    $dockerExt = @('dockerfile')
    $gradleExt = @('.gradle','.kts')
    $cmakeExt = @('cmakelists.txt')

    # Exclusion regex single-sourced: dir list via Get-SyntaxCheckExcludeDirs
    # (BuildConstants is the only literal source), regex compiled by
    # PathUtils.Get-ExcludeDirPattern. Computed ONCE, never inside the per-file loop.
    $exDirs = Get-SyntaxCheckExcludeDirs
    if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
        $exPattern = Get-ExcludeDirPattern -Dirs $exDirs
    } else {
        # PathUtils not loaded — fallback: build pattern inline from dir list
        if ($exDirs.Count -gt 0) {
            $exPattern = '[\\/](' + (($exDirs | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/]'
        } else {
            $exPattern = ''
        }
    }

    # Build-system launcher files matched BY NAME at any depth (single source via
    # Get-SyntaxCheckExcludeFiles). Prevents preflight from being blocked by a project's
    # own stale/PS7-only gbuild copy sitting at the project root or in an embedded _Build.
    $exFileNames = Get-SyntaxCheckExcludeFiles
    $exFileNameSet = @{}
    foreach ($en in $exFileNames) { $exFileNameSet[$en.ToLowerInvariant()] = $true }

    # JSON strictness knobs (computed once, outside the per-file loop):
    # -AsHashTable exists on PS 6+ and tolerates "" property keys (package-lock.json).
    $supportsJsonHash = ($PSVersionTable.PSVersion.Major -ge 6)
    $lockFileNames = @('package-lock.json', 'npm-shrinkwrap.json', 'packages.lock.json')

    $files = Get-BoundedProjectFiles -Root $Root -Depth 999 -ExcludeDirs $exDirs -ExcludeFiles $exFileNames -File |
        Where-Object {
            $rel = $_.FullName.Substring($Root.Length).Replace('\','/')
            $fileName = $_.Name.ToLowerInvariant()
            return ($rel -notmatch 'patch_userfacing' -and -not $exFileNameSet.ContainsKey($fileName))
        }
    $checked = 0; $errors = 0; $errorLines = @()
    foreach ($f in $files) {
        $ext = $f.Extension.ToLowerInvariant()
        $name = $f.Name.ToLowerInvariant()
        $checked++
        try {
            if ($ext -in $psExt) {
                $parseErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
                if ($parseErrors -and $parseErrors.Count -gt 0) {
                    $errors++
                    foreach ($e in $parseErrors) { $errorLines += ("{0}:{1}: {2}" -f $f.FullName, $e.Extent.StartLineNumber, $e.Message) }
                }
            } elseif ($ext -in $xmlExt) {
                $null = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
            } elseif ($ext -in $jsonExt) {
                # Generated lockfiles (npm/NuGet) legally contain empty-string property
                # keys ("") that desktop ConvertFrom-Json cannot represent; only validate
                # them strictly when -AsHashTable (PS 6+) is available.
                $isLockfile = $name -in $lockFileNames
                if ($isLockfile -and -not $supportsJsonHash) {
                    $null = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
                } else {
                    $raw = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
                    $raw = Remove-JsonComments -JsonWithComments $raw
                    if ($supportsJsonHash) {
                        $null = $raw | ConvertFrom-Json -AsHashTable -EA Stop
                    } else {
                        $null = $raw | ConvertFrom-Json -EA Stop
                    }
                }
            } elseif ($ext -in $tomlExt) {
                $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
                if ($content -notmatch '^\s*\[') { $errorLines += ("{0}: suspicious TOML (no section header)" -f $f.FullName); $errors++ }
            } elseif ($ext -in $yamlExt) {
                $null = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
            } elseif ($name -in $dockerExt) {
                $lines = Get-Content -Path $f.FullName -EA Stop
                $hasFrom = $false
                foreach ($line in $lines) {
                    if ($line -match '^\s*FROM\s+\S+') { $hasFrom = $true; break }
                }
                if (-not $hasFrom) { $errorLines += ("{0}: Dockerfile missing FROM directive" -f $f.FullName); $errors++ }
            } elseif ($name -in $cmakeExt) {
                $lines = Get-Content -Path $f.FullName -EA Stop
                $hasProject = $false
                foreach ($line in $lines) {
                    if ($line -match '^\s*project\s*\(') { $hasProject = $true; break }
                }
                if (-not $hasProject) { $errorLines += ("{0}: CMakeLists.txt missing project()" -f $f.FullName); $errors++ }
            } elseif ($ext -in $gradleExt) {
                $null = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
            } elseif ($ext -in $csExt) {
                $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -EA Stop
                # Strip string/char literals + comments before counting braces — otherwise,
                # '{' inside strings/comments causes false-positive bracket mismatches.
                $content = [regex]::Replace($content, '@"[^"]*"', '""')            # verbatim string (simplified)
                $content = [regex]::Replace($content, '"(?:[^"\\\r\n]|\\.)*"', '""')
                $content = [regex]::Replace($content, "'(?:[^'\\\r\n]|\\.)*'", "''")
                $content = [regex]::Replace($content, '//[^\r\n]*', '')
                $content = [regex]::Replace($content, '/\*[\s\S]*?\*/', '')
                $open = ([regex]::Matches($content, '\{')).Count
                $close = ([regex]::Matches($content, '\}')).Count
                if ($open -ne $close) { $errorLines += ("{0}: bracket mismatch (open={1}, close={2})" -f $f.FullName, $open, $close); $errors++ }
            }
        } catch {
            $errors++
            $errorLines += ("{0}: {1}" -f $f.FullName, $_.Exception.Message)
        }
    }
    # Dedupe: junctions/symlinks can yield the same file twice via -Recurse.
    $errorLines = @($errorLines | Sort-Object -Unique)
    return [pscustomobject]@{
        FilesChecked      = $checked
        FilesWithErrors   = $errors
        Errors            = $errorLines
    }
}

<#
.SYNOPSIS
    Writes an object as a JSON report file, creating parent directories first.
.DESCRIPTION
    Single implementation of the "ensure dir -> ConvertTo-Json | Set-Content UTF8"
    scaffolding that was duplicated across InfraVerification / Distributed /
    SupplyChain (SBOM, provenance, compliance report). Supports atomic write
    (temp file + move) for cache/index files. Returns $true on success,
    $false on any failure (callers log their own context-specific warning).
#>
<#
.SYNOPSIS
    Single owner of "atomically replace a text file" and "cross-process lock".
.DESCRIPTION
    The following triple was byte-identical in AnomalyDetector, AutoTuner and
    RootCause, with a hardcoded 100 attempts x 25 ms spin:

        Enter-<X>HistoryLock   (lock file, retry loop)
        Read-<X>Lines          (read, drop blanks)
        Write-<X>Lines         (temp -> File.Replace -> delete temp)

    and a 4th near-identical variant in AuditLedger. Consequences of the copies:
      * the catch arm of the writer DELETED the destination and then moved the
        temp file, so a process death between the two lost the file outright;
      * the lock budget was 2500 ms in three modules and 5000 ms in Cache.psm1
        for the same filesystem concern;
      * a fix had to be applied in N places and one was always missed.

    SharedUtils.Write-BuildJsonFile already had the correct File.Replace +
    backup behaviour but was JSON-specific. This is the general text version.

    Never throws: a telemetry/history write must not fail a build.
#>
function Get-BuildStringHash {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 (or another algorithm) of a UTF-8 string.
    .DESCRIPTION
    The 2026-09 audit found 16 hand-rolled "UTF8 -> SHA256 -> hex" sites across
    12 modules and NO shared helper. Two of them (Alerting and Siem) were
    logically identical and differed only in name. Worse, the two cache-key
    hashes disagreed on CASE for the same computation - Cache.psm1 emitted
    lowercase hex and CacheProvider.psm1 emitted UPPERCASE - so the same cache
    entry hashed to two different keys depending on which module asked.

    This is the single owner. Case is a parameter only so a caller that must
    match a pre-existing uppercase key store can say so explicitly; the default
    is lowercase, which is what every consumer in this system already assumed.

    -OnFailure returns a value when hashing cannot proceed (Alerting and Siem
    degrade to a random correlation id rather than failing a build).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('SHA256', 'SHA384', 'SHA512', 'MD5')]
        [string]$Algorithm = 'SHA256',
        [ValidateSet('Lower', 'Upper')]
        [string]$Case = 'Lower',
        [string]$OnFailure = ''
    )
    try {
        $hashAlg = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $digest = $hashAlg.ComputeHash($bytes)
        } finally { $hashAlg.Dispose() }
        $hex = [System.BitConverter]::ToString($digest).Replace('-', '')
        if ($Case -eq 'Upper') { return $hex.ToUpperInvariant() }
        return $hex.ToLowerInvariant()
    } catch {
        return $OnFailure
    }
}

function Get-BuildFileSha256 {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 of a file's CONTENTS.
    .DESCRIPTION
        File bytes are a different question from a string (Get-BuildStringHash)
        and from an in-memory byte buffer (Get-BuildBytesHash): this streams the
        file so a large artifact never has to be resident.

        CacheProvider.Get-CacheFileSha256 was the only such implementation and it
        carried two defects: it returned UPPERCASE while the sibling cache-key
        hash in Cache.psm1 returned lowercase (so the same content hashed to two
        keys depending on which module asked - the exact bug Get-BuildStringHash's
        doc records), and it called Initialize-BuildSharedUtils to lazy-load
        SharedUtils and then never used anything from it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # AllowNull/AllowEmptyString so the guards in the body decide, rather than
        # parameter binding throwing first. Mandatory stays, for discoverability:
        # these are real arguments, not defaults.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Path,
        [ValidateSet('Lower', 'Upper')]
        [string]$Case = 'Lower'
    )
    $sha = $null; $stream = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return '' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($Path)
        $hex = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        if ($Case -eq 'Upper') { return $hex.ToUpperInvariant() }
        return $hex.ToLowerInvariant()
    } catch {
        return ''
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($sha) { try { $sha.Dispose() } catch { } }
    }
}

function Write-BuildTextFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        # Runs against the TEMP file, after it is written and BEFORE it replaces
        # the destination. CredentialVault is the reason this exists: it has to
        # harden the permissions of the file it is about to move into place
        # (Protect-VaultSecretFile), and it was previously the ONLY writer in the
        # tree with no delegation at all - a 15-line private copy of the Replace
        # dance. A hook is the alternative to that copy: the primitive owns
        # atomicity, the caller owns whatever must happen to the bytes first.
        # The hook can abort the write two ways, both honoured: by throwing, and
        # by leaving a non-zero LASTEXITCODE after running a native tool.
        [scriptblock]$PreCommit
    )
    $temp = $null
    try {
        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop)
        }
        # A GUID in the temp name is load-bearing, not decoration: a PREDICTABLE
        # name ('<path>.tmp') is a collision between two concurrent writers and a
        # symlink target for anything that can write to the directory. The
        # telemetry ring-trim used exactly that name and was the reason.
        $temp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($temp, [string[]]$Lines, $utf8)

        # The hook runs OUTSIDE the replace try/catch below, deliberately, and
        # that placement is the whole point. Sharing one try meant a FAILING
        # hook fell into the non-destructive fallback, which copies the temp
        # over the destination - so a hook whose whole job was to harden the
        # bytes before they landed (CredentialVault) would, on failure, land
        # the UN-hardened bytes anyway and report success. A hook failure must
        # abort, never downgrade to "best effort".
        if ($PreCommit) {
            # Read LASTEXITCODE through the global scope behind an existence
            # test. A bare $LASTEXITCODE is undefined until some native command
            # has run, and under Set-StrictMode reading it then THROWS - which
            # landed in the outer catch and turned every hooked write into a
            # silent no-op that reported failure.
            $beforeExit = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }
            try {
                $null = & $PreCommit $temp
            } catch {
                Write-Warning ("Pre-commit hook failed; '{0}' left unchanged: {1}" -f $Path, $_.Exception.Message)
                return $false
            }
            # A hook that shells out (gpg, chmod) signals failure through
            # LASTEXITCODE rather than by throwing. Compare against the value
            # from before the hook ran, so a stale non-zero left by an unrelated
            # earlier command cannot veto every subsequent write.
            $afterExit = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }
            if ($afterExit -ne 0 -and $afterExit -ne $beforeExit) {
                Write-Warning ("Pre-commit hook exited {0}; '{1}' left unchanged." -f $afterExit, $Path)
                return $false
            }
        }

        try {
            if (-not (Move-StagedBuildFile -Source $temp -Destination $Path)) {
                throw [System.IO.IOException]::new((Resolve-LogMessage -Key 'log.sharedutils.line1270' -Fallback 'Staged atomic replacement did not complete.'))
            }
        } catch {
            # NON-DESTRUCTIVE fallback. The old copy did
            # `Remove-Item $Path; File.Move($temp,$Path)`, which loses the
            # destination if the process dies in between. Try copy-over first
            # (the destination is never unlinked) and only then consider the
            # move. This is the fault-recovery path, not the normal one.
            try {
                [System.IO.File]::Copy($temp, $Path, $true)
                [System.IO.File]::Delete($temp)
            } catch {
                if ([System.IO.File]::Exists($Path)) { try { [System.IO.File]::Delete($Path) } catch { } }
                try { [System.IO.File]::Move($temp, $Path) } catch { }
            }
        }
        return $true
    } catch { return $false }
    finally {
        if ($temp -and [System.IO.File]::Exists($temp)) { try { [System.IO.File]::Delete($temp) } catch { } }
    }
}

function Move-StagedBuildFile {
    <#
    .SYNOPSIS
        Swaps one staged file onto its destination without exposing a partial file.
    .DESCRIPTION
        Internal owner for every staged-file replacement in SharedUtils. The text
        writer, prebuilt-file mover, and JSON writer previously carried separate
        direct swap calls; keeping them separate recreated the module-local drift
        that broader consolidation had just removed from the rest of the tree.
        Callers retain their own staging, permission, backup-cleanup, and failure
        behavior. This helper owns only the existence check, parent creation,
        destination replacement, backup treatment, and concurrent-create retry.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$UseBackup
    )
    $backup = $null
    try {
        $target = [System.IO.Path]::GetFullPath($Destination)
        $parent = [System.IO.Path]::GetDirectoryName($target)
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop)
        }

        # The destination swap has one spelling. Local closures are used rather
        # than a second module function because the backup path is only an
        # intermediate value for this call; a separately exported helper would
        # need its own public contract for a private implementation detail.
        $startBackup = {
            param([string]$TargetFile, [string]$ParentDirectory)
            if (-not $UseBackup) { return $null }
            return (Join-Path $ParentDirectory ('.' + [System.IO.Path]::GetFileName($TargetFile) + '.' + [guid]::NewGuid().ToString('N') + '.bak'))
        }
        $replaceStagedFile = {
            param([string]$StagedFile, [string]$TargetFile, $BackupFile)
            [System.IO.File]::Replace($StagedFile, $TargetFile, $BackupFile, $true)
        }
        $finishBackup = {
            param($BackupFile)
            if ($BackupFile -and [System.IO.File]::Exists($BackupFile)) {
                [System.IO.File]::Delete($BackupFile)
            }
        }
        $swapExistingTarget = {
            param([string]$TargetFile, [string]$ParentDirectory)
            $candidate = & $startBackup $TargetFile $ParentDirectory
            & $replaceStagedFile $Source $TargetFile $candidate
            & $finishBackup $candidate
            return $candidate
        }

        if ([System.IO.File]::Exists($target)) {
            $backup = & $swapExistingTarget $target $parent
        } else {
            try {
                [System.IO.File]::Move($Source, $target)
            } catch {
                # A concurrent writer may create the destination after the check
                # above. Retry once through replacement rather than failing.
                if ([System.IO.File]::Exists($target)) {
                    $backup = & $swapExistingTarget $target $parent
                } else {
                    throw
                }
            }
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($backup -and [System.IO.File]::Exists($backup)) { try { [System.IO.File]::Delete($backup) } catch { } }
    }
}

function Move-BuildFileAtomic {
    <#
    .SYNOPSIS
        Atomically move an already-written file onto a destination path.
    .DESCRIPTION
        The companion to Write-BuildTextFileAtomic. That primitive answers
        "write these BYTES"; this one answers "this file already exists on
        disk - put it at that path without a window where the destination is
        absent or half-written".

        It existed as THREE private copies before: Move-CacheFileAtomic
        (CacheProvider), Move-StepFileAtomic (Steps/publish-artifact) and an
        inline Replace in Steps/sign-gpg, plus the tail of the Android
        keystore-properties write. All four were the same Replace-with-backup,
        backup-delete, cleanup-temp shape, and all four differed slightly in
        whether they guarded a missing parent directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    try {
        return Move-StagedBuildFile -Source $Source -Destination $Destination -UseBackup
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Reads a text/JSONL file, dropping blank lines. Returns @() when absent.
#>
function Get-BuildTextLines {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        return @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    } catch { return @() }
}

<#
.SYNOPSIS
    Acquires a cross-process lock file, with a bounded, Stopwatch-measured wait.
.DESCRIPTION
    Returns the open FileStream on success and $null on timeout - it does not
    throw, because a contended history file must degrade, not abort a build.
    This is the ONLY file-lock implementation in the system: it owns the
    <path>.lock convention for the cache index (Cache.psm1 and CacheProvider.psm1
    both delegate here), the three history files, and the audit ledger. The
    per-module copies that used to exist each evaluated the timeout only AFTER a
    failed attempt and so blocked for a full poll interval past the budget.
#>
function Enter-BuildFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutMs = 15000,
        [int]$PollMs = 25
    )
    try {
        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue) }
        $lockPath = $Path + '.lock'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # L5 robustness: under parallel-suite load (Pester Start-Job x N) 5s
        # proved too short (AutoTuner safety took 43s, lock timed out). 15s
        # only extends the wait budget on contention; uncontended acquire
        # still returns on first attempt with no behaviour change.
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            try { return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) } catch { }
            Start-Sleep -Milliseconds $PollMs
        }
        return $null
    } catch { return $null }
}

<#
.SYNOPSIS
    Releases a lock stream obtained from Enter-BuildFileLock.
#>
function Exit-BuildFileLock {
    [CmdletBinding()]
    param($Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.Dispose() } catch { }
}

<#
.SYNOPSIS
    Writes text as UTF-8 with NO byte-order mark, identically on every host.
.DESCRIPTION
    `Set-Content -Encoding UTF8` is NOT the same operation on Windows
    PowerShell 5.1 and PowerShell 7: 5.1 emits a BOM (EF BB BF), 7 emits none.
    Both were used interchangeably across ~11 write sites, so the same build
    produced byte-different JSON / SARIF / cache files depending on which shell
    ran it. That breaks content-hash cache keys (Cache.psm1) and the
    provenance digests in SupplyChain.psm1, and makes a BOM show up mid-JSONL
    when a 5.1 host appends to a log a 7 host created.

    Everything routed through here is byte-identical across engines. Use
    Write-BuildJsonFile -Atomic when the write also needs to be crash-safe;
    use this when a plain append/overwrite is enough.
.PARAMETER Append
    Append instead of overwrite.
#>
function Write-BuildTextFileUtf8 {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][AllowNull()][string[]]$Value,
        [switch]$Append,
        [switch]$NoNewline
    )
    try {
        $text = (@($Value) -join [Environment]::NewLine)
        if (-not $NoNewline -and $text.Length -gt 0) { $text += [Environment]::NewLine }
        $enc = New-Object System.Text.UTF8Encoding($false)
        if ($Append) {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try { $bytes = $enc.GetBytes($text); $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        } else {
            [System.IO.File]::WriteAllText($Path, $text, $enc)
        }
        return $true
    } catch { return $false }
}

function Read-BuildJsonFile {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$FilePath)
    # Missing files are a normal "nothing saved yet" signal, not an error.
    if (-not (Test-Path -Path $FilePath)) { return $null }
    try {
        # .NET text read preserves UTF-8 without a BOM on every supported host.
        $jsonString = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        return $jsonString | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.json.corruptReinit' -MessageArgs @([string]$FilePath) -Fallback '[JSON] File {0} is corrupt or unreadable, reinitializing...') 'Yellow'
        }
        return $null
    }
}

function Write-BuildJsonFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data,
        [int]$Depth = -1,
        [switch]$Atomic
    )

    # Resolve default JSON depth from BuildConstants if not explicitly provided
    if ($Depth -lt 0) {
        $Depth = Get-BuildDefault -Key 'JsonDefaultDepth' -Fallback 10
    }

    $tempPath = $null
    try {
        $outDir = Split-Path -Parent $Path
        if ($outDir) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { $null = Invoke-EnsureDirectory -Path $outDir } elseif (-not (Test-Path $outDir -PathType Container)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null } }
        $jsonString = $Data | ConvertTo-Json -Depth $Depth
        if ($Atomic) {
            $fullPath = [System.IO.Path]::GetFullPath($Path)
            $fullParent = [System.IO.Path]::GetDirectoryName($fullPath)
            $leaf = [System.IO.Path]::GetFileName($fullPath)
            $tempPath = Join-Path $fullParent ('.' + $leaf + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            [System.IO.File]::WriteAllText($tempPath, $jsonString, (New-Object System.Text.UTF8Encoding($false)))
            # The replacement itself is owned above. A second direct replacement
            # lived in the concurrent-create retry; sharing it keeps one swap
            # shape for text, prebuilt-file, and JSON writers.
            if (-not (Move-StagedBuildFile -Source $tempPath -Destination $fullPath -UseBackup)) {
                throw [System.IO.IOException]::new((Resolve-LogMessage -Key 'log.sharedutils.line1551' -Fallback 'Staged JSON replacement did not complete.'))
            }
            $tempPath = $null
        } else {
            if (-not (Write-BuildTextFileUtf8 -Path $Path -Value @($jsonString))) { throw [System.IO.IOException]::new((Resolve-LogMessage -Key 'log.sharedutils.line1555' -Fallback 'Failed to write JSON file.')) }
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($tempPath -and [System.IO.File]::Exists($tempPath)) {
            try { [System.IO.File]::Delete($tempPath) } catch { }
        }
    }
}

<#
.SYNOPSIS
    Resolves the publish-output directory name (config paths.publishOutput first).
.DESCRIPTION
    Single implementation of the one-liner duplicated across Build / Clean /
    Deploy / HotReload / DeployTargets / SupplyChain:
        Get-BuildConstant -Key 'PublishOutputDir' -State $State -Fallback 'publish-output'
#>
function Resolve-PublishOutputDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    return [string](Get-BuildConstant -Key 'PublishOutputDir' -State $State -Fallback 'publish-output')
}

<#
.SYNOPSIS
    Decides whether a successful build reveals its publish-output folder.
.DESCRIPTION
    Single owner for the build.openOutput decision, previously an undocumented
    raw-config read inside Build.psm1 (no schema entry, no constant, no way to
    discover it) while the Orchestrator plugin path opened unconditionally -
    so CI popped Explorer windows and interactive runs sometimes did not.
    Explicit config wins via Get-BuildConstant (shipped true for the dev
    loop, false stays quiet everywhere); even when enabled, CI and
    -NonInteractive runs never open, and fully stripped hosts fall back to
    the interactive probe instead of guessing.
.OUTPUTS
    bool
#>
function Resolve-BuildOpenOutput {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)
    $open = $false
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $open = [bool](Get-BuildConstant -Key 'OpenOutput' -State $State -Fallback $false)
        } elseif (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
            $raw = Get-ConfigValue -Path 'build.openOutput' -State $State
            if ($null -ne $raw) { $open = [bool]$raw }
        }
    } catch { $open = $false }
    if (-not $open) { return $false }
    try {
        if ($State -and ($State.NonInteractive -or $State.IsCI)) { return $false }
    } catch { }
    try {
        if (Get-Command Test-InteractiveSession -ErrorAction SilentlyContinue) {
            return [bool](Test-InteractiveSession -State $State)
        }
    } catch { }
    return $true
}

<#
.SYNOPSIS
    Resolves the report-output directory name to a rooted path.
.DESCRIPTION
    Single implementation of the identical resolver previously duplicated in
    Siem.Get-SiemReportDir and SupplyChain.Get-SupplyChainReportDir. Reads
    config report.outputDir (default BuildConstants.ReportOutputDir) and
    delegates root-selection to PathUtils.Resolve-BuildRootedPath.
.PARAMETER State
    The build state object.
.OUTPUTS
    string
#>
function Get-ReportDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $rel = Get-BuildConstant -Key 'ReportOutputDir' -State $State -Fallback 'build-reports'
    # A $null State means "standalone script, resolve against the launch
    # directory" - the documented standalone contract. A PRESENT state that
    # carries no roots is a broken build state, not a standalone run: resolving
    # it against the CWD once relocated an entire build's compliance evidence
    # into the launch directory, so fail loudly instead. Checked BEFORE any
    # delegation so no backend can reintroduce the CWD fallback.
    if ($null -ne $State) {
        $hasRoot = (($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) -or
                   (($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot)
        if (-not $hasRoot) {
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.sharedutils.line1650' -Fallback 'Report directory is undetermined: State carries neither ProjectRoot nor ScriptRoot. Refusing to resolve reports against the current directory.'))
        }
    }
    # Level 5 resilience: inline root-selection fallback (ProjectRoot >
    # ScriptRoot > cwd) when PathUtils.Resolve-BuildRootedPath is unavailable.
    if (Get-Command Resolve-BuildRootedPath -ErrorAction SilentlyContinue) {
        return Resolve-BuildRootedPath -RelativePath $rel -State $State
    }
    $rt = if ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
    if ([System.IO.Path]::IsPathRooted([string]$rel)) { return [string]$rel }
    return (Join-Path $rt $rel)
}

<#
.SYNOPSIS
    Returns the short project name (leaf of ProjectRoot).
.DESCRIPTION
    Single implementation of the "Split-Path -Leaf $State.ProjectRoot else
    fallback" idiom previously duplicated across SupplyChain/Report/DeployTargets.
    Root selection delegates to PathUtils.Get-BuildRootDirectory when available.
#>
function Get-ProjectShortName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$Default = ''
    )
    if ([string]::IsNullOrWhiteSpace($Default)) {
        $Default = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [string](Get-BuildConstant -Key 'DefaultProjectShortName' -Fallback 'gbuild-project')
        } else { 'gbuild-project' }
    }
    $root = $null
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        try { $root = Get-BuildRootDirectory -State $State } catch { $root = $null }
    }
    if (-not $root -and $State -and $State.ProjectRoot) { $root = [string]$State.ProjectRoot }
    if ($root) {
        try { $leaf = Split-Path $root -Leaf; if ($leaf) { return $leaf } } catch { }
    }
    return $Default
}

function Get-BuildConstant {
    <#
    .SYNOPSIS
        Primary public facade for reading build constants (config-first).
    .DESCRIPTION
        Unified accessor for all BuildConstants keys. Resolution order:
        1. gbuild.config.json via ConfigKeyMap dot-path (when State available)
        2. BuildConstants registered default ($script:BuildDefaults)
        3. Caller-provided -Fallback
        Use this instead of Get-BuildSetting / Get-BuildDefault / Get-ConfigValue
        for any key present in ConfigKeyMap. All call sites should migrate here.
    .PARAMETER Key
        BuildConstants key name (e.g. 'DefaultPort', 'MinDiskMB', 'ParallelMaxJobs').
    .PARAMETER State
        Global state object carrying BuildConfig. Optional; falls back to $global:GState.
    .PARAMETER Fallback
        Final fallback if neither config nor default is available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [object]$Fallback = $null,
        [PSCustomObject]$State = $null
    )
    # Config-first resolution: prefer gbuild.config.json (via Get-BuildSetting,
    # which reads the ConfigKeyMap dot-path), then the registered default, then
    # the caller fallback. This makes all call sites config-driven without
    # changing their signatures. At runtime $global:GState carries the loaded
    # config; when absent (standalone import) we degrade to the default table.
    if (-not $State -and (Test-Path variable:global:GState)) { $State = $global:GState }
    if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) {
        return (Get-BuildSetting -Key $Key -State $State -Fallback $Fallback)
    }
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        return (Get-BuildDefault -Key $Key -Fallback $Fallback)
    }
    return $Fallback
}

function Get-ConfigSection {
    <#
    .SYNOPSIS
        Legacy compat: raw config section walk. New code: Get-ConfigValue (dot-path)
        or Get-BuildConstant (BuildConstants key). Kept for standalone survival only.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not $State -or -not $State.BuildConfig) { return $null }
    if (Get-Command Find-ConfigNode -ErrorAction SilentlyContinue) {
        return Find-ConfigNode -Root $State.BuildConfig -Path $Path
    }
    # Defensive inline fallback for standalone import without ConfigProvider.
    $segments = $Path -split '\.'
    $current = $State.BuildConfig
    foreach ($seg in $segments) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $null }
        } elseif ($current.PSObject.Properties.Name -contains $seg) {
            $current = $current.$seg
        } else { return $null }
    }
    return $current
}

function Test-ToolAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string[]]$Aliases = @()
    )
    if (Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    foreach ($alias in $Aliases) {
        if (Get-Command $alias -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Absolute path of the folder holding the tooling this _Build copy ships.
.DESCRIPTION
    Single source for "where does the platform keep its own modules". The relative
    folder comes from paths.vendoredTools (BuildConstants.VendoredToolsDirName)
    and is resolved against the SCRIPT ROOT OF THE RUNNING TREE - never the
    install location and never the current directory, so a run started from a
    project elsewhere still finds the tooling that shipped next to the gbuild.ps1
    that is executing. Returns '' when the folder does not exist.
#>
function Get-BuildVendoredToolsRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State = $null)
    $rel = '.tools/Modules'
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try {
            $v = [string](Get-BuildConstant -Key 'VendoredToolsDirName' -State $State -Fallback $rel)
            if (-not [string]::IsNullOrWhiteSpace($v)) { $rel = $v }
        } catch { }
    }
    $rel = $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $roots = @()
    if ($State) {
        foreach ($prop in @('ScriptRoot', 'ProjectRoot')) {
            if (($State.PSObject.Properties.Name -contains $prop) -and $State.$prop) { $roots += [string]$State.$prop }
        }
    }
    # $PSScriptRoot is <tree>\Modules\SharedUtils.psm1, so its parent is the tree.
    if ($PSScriptRoot) { $roots += (Split-Path -Parent $PSScriptRoot) }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        try {
            $candidate = Join-Path ([string]$root) $rel
            if (Test-Path -LiteralPath $candidate -PathType Container) { return [string]$candidate }
        } catch { }
    }
    return ''
}

<#
.SYNOPSIS
    Makes a PowerShell module the platform bundles itself importable.
.DESCRIPTION
    Level 5 platform contract: a scanner the platform claims to support must be
    runnable without asking the project to install anything. PowerShell SAST needs
    Invoke-ScriptAnalyzer and _Build ships PSScriptAnalyzer under
    .tools\Modules, but only Install-GBuild.ps1 ever added that folder to
    PSModulePath - and only for the install location it wrote. A repo-local run
    therefore resolved no analyzer, the tool-unavailable policy failed the step,
    and the build was blocked for code that was never scanned while the operator
    was told to install the tool. This function is the one runtime path that
    resolves the bundled copy, and it is a no-op when the cmdlet already exists.

    Also prepends THIS tree's tooling folder to $env:PSModulePath, so a stale
    entry pointing at another copy (or another drive) cannot decide which analyzer
    a run gets, and so Get-Module -ListAvailable sees the bundled copy for every
    later consumer. Session-scoped only: the process environment is not modified.

    Returns a result object; never throws.
    Name        - module folder name to import (defaults to the constant map for EntryPoint)
    EntryPoint  - cmdlet that must resolve afterwards ('' = import is enough)
    Version     - pinned version folder to try first (default: BuildConstants)
    Status      - AlreadyAvailable | Loaded | NotFound | Failed
#>
function Resolve-VendoredToolModule {
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$EntryPoint = '',
        [string]$Version = '',
        [PSCustomObject]$State = $null
    )
    $result = [ordered]@{ Name = $Name; EntryPoint = [string]$EntryPoint; Status = 'NotFound'; Version = ''; Path = ''; Message = '' }
    if ([string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($EntryPoint)) {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try {
                $map = Get-BuildConstant -Key 'VendoredToolModuleMap' -State $State -Fallback $null
                if ($map -is [System.Collections.IDictionary]) {
                    foreach ($key in @($map.Keys)) {
                        if ([string]$key -eq $EntryPoint) { $Name = [string]$map[$key]; break }
                    }
                }
            } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $EntryPoint }
    }
    $result['Name'] = [string]$Name
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $result['Status'] = 'Failed'
        $result['Message'] = 'Neither a module name nor an entry point was supplied'
        return [PSCustomObject]$result
    }
    if (-not [string]::IsNullOrWhiteSpace($EntryPoint) -and (Get-Command $EntryPoint -ErrorAction SilentlyContinue)) {
        $cmd = Get-Command $EntryPoint -ErrorAction SilentlyContinue | Select-Object -First 1
        $result['Status'] = 'AlreadyAvailable'
        if ($cmd -and $cmd.Module) {
            if ($cmd.Module.Version) { $result['Version'] = [string]$cmd.Module.Version }
            if ($cmd.Module.Path) { $result['Path'] = [string]$cmd.Module.Path }
        }
        $result['Message'] = "$EntryPoint already resolves ($($result['Version']))"
        return [PSCustomObject]$result
    }
    $root = Get-BuildVendoredToolsRoot -State $State
    if ([string]::IsNullOrWhiteSpace($root)) {
        $result['Message'] = "No bundled tooling folder found (expected .tools\Modules inside the running _Build tree)"
        return [PSCustomObject]$result
    }
    try {
        $sep = [System.IO.Path]::PathSeparator
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($env:PSModulePath)) { $parts = @($env:PSModulePath -split [regex]::Escape($sep)) }
        if ($parts -notcontains $root) {
            $env:PSModulePath = if ($parts.Count -eq 0) { $root } else { $root + $sep + ($parts -join $sep) }
        }
    } catch { }
    $moduleHome = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $moduleHome -PathType Container)) {
        $result['Message'] = "This _Build copy ships no '$Name' under $root"
        return [PSCustomObject]$result
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try {
                if ($Name -eq 'PSScriptAnalyzer') {
                    $v = [string](Get-BuildConstant -Key 'ScriptAnalyzerVersion' -State $State -Fallback '')
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $Version = $v }
                }
            } catch { }
        }
    }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $pinned = Join-Path $moduleHome $Version
        if (Test-Path -LiteralPath $pinned -PathType Container) { $candidates += $pinned }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $moduleHome -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)) {
        if ($candidates -notcontains [string]$dir.FullName) { $candidates += [string]$dir.FullName }
    }
    if ($candidates.Count -eq 0) {
        $result['Message'] = "No versioned folder for '$Name' under $moduleHome"
        return [PSCustomObject]$result
    }
    $problems = @()
    foreach ($dir in $candidates) {
        $manifest = Join-Path $dir "$Name.psd1"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { $manifest = Join-Path $dir "$Name.psm1" }
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $label = Split-Path -Leaf $dir
        try {
            $null = Import-Module $manifest -Force -Global -DisableNameChecking -ErrorAction Stop
            $result['Path'] = [string]$manifest
            $result['Version'] = [string]$label
            if ([string]::IsNullOrWhiteSpace($EntryPoint)) {
                $result['Status'] = 'Loaded'
                $result['Message'] = "Imported $Name $label bundled with this _Build copy"
                return [PSCustomObject]$result
            }
            if (Get-Command $EntryPoint -ErrorAction SilentlyContinue) {
                $result['Status'] = 'Loaded'
                $result['Message'] = "Imported $Name $label bundled with this _Build copy; $EntryPoint now resolves"
                return [PSCustomObject]$result
            }
            $problems += "$label imported but '$EntryPoint' still does not resolve"
        } catch {
            $problems += "$label import failed: $($_.Exception.Message)"
        }
    }
    $result['Status'] = 'Failed'
    $result['Message'] = "No usable copy of '$Name' in $moduleHome. " + ($problems -join ' | ')
    return [PSCustomObject]$result
}

function Test-BuildCIHost {
    <#
    .SYNOPSIS
        Reports whether the current process is running inside a CI system.
    .DESCRIPTION
        SINGLE owner of the raw $env: CI probe. Three sites used to carry their
        own copy of this probe - EnvironmentProvider.Get-BuildEnvironment,
        Preflight.psm1 and SDK.psm1 - and one of them (Preflight) probed only
        GITHUB_ACTIONS/$env:CI, so a run inside Azure DevOps or GitLab (where
        $env:CI is often unset) was reported as NOT CI and the network-preflight
        skip silently did not apply. Callers that can afford the dependency on
        the provider should prefer EnvironmentProvider.Test-CIEnvironment (it also
        names the CI system); this helper exists for the standalone-import path
        where the provider is absent.

        Live here rather than in EnvironmentProvider because SharedUtils is the
        root of the bootstrap chain and is therefore resolvable from every module
        that needs the probe, including a bare Import-Module of a single module.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Azure DevOps sets TF_BUILD='True' (capital T) and may leave CI unset;
    # GitLab sets GITLAB_CI='true'. All three spellings are checked so the
    # fallback cannot report a real CI run as local.
    if ($env:GITHUB_ACTIONS -eq 'true') { return $true }
    if ($env:TF_BUILD -eq 'True') { return $true }
    if ($env:GITLAB_CI -eq 'true') { return $true }
    return [bool]($env:CI -eq 'true' -or $env:CI -eq '1')
}

function Resolve-PowerShellHost {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Single source for the cross-platform PowerShell host used to spawn child
    # gbuild/Steps scripts. Prefers pwsh (PS7+, all OSes), falls back to the
    # legacy Windows-only powershell host. Never hardcode 'powershell' at call sites.
    if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { return 'pwsh' }
    if (Get-Command powershell -CommandType Application -ErrorAction SilentlyContinue) { return 'powershell' }
    $isWinHost = Test-IsWindowsHost
    $pwshExe = if ($isWinHost) { 'pwsh.exe' } else { 'pwsh' }
    if (Get-Command $pwshExe -CommandType Application -ErrorAction SilentlyContinue) { return $pwshExe }
    if ($isWinHost) {
        if (Get-Command 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue) { return 'powershell.exe' }
    }
    return 'pwsh'
}

function Remove-JsonComments {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$JsonWithComments
    )
    if ([string]::IsNullOrWhiteSpace($JsonWithComments)) { return $JsonWithComments }
    $sb = [System.Text.StringBuilder]::new($JsonWithComments.Length)
    $i = 0
    $len = $JsonWithComments.Length
    while ($i -lt $len) {
        $c = $JsonWithComments[$i]
        if ($c -eq '"') {
            [void]$sb.Append($c); $i++
            while ($i -lt $len) {
                $c = $JsonWithComments[$i]; [void]$sb.Append($c)
                if ($c -eq '\') { $i++; if ($i -lt $len) { [void]$sb.Append($JsonWithComments[$i]) } } elseif ($c -eq '"') { break }
                $i++
            }
            $i++; continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $len -and $JsonWithComments[$i + 1] -eq '/') {
            $i += 2; while ($i -lt $len -and $JsonWithComments[$i] -ne "`n") { $i++ }; continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $len -and $JsonWithComments[$i + 1] -eq '*') {
            $i += 2
            while ($i -lt $len) {
                if ($JsonWithComments[$i] -eq '*' -and ($i + 1) -lt $len -and $JsonWithComments[$i + 1] -eq '/') { $i += 2; break }
                $i++
            }
            continue
        }
        [void]$sb.Append($c); $i++
    }
    return $sb.ToString()
}

function New-OperationResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Succeeded', 'Failed', 'Skipped', 'Blocked')]
        [string]$Status = 'Succeeded',
        [Parameter(Mandatory)]
        [string]$Operation,
        [string]$ReasonCode = '',
        [string]$Message = '',
        [int]$ExitCode = 0,
        [double]$DurationMs = 0,
        [AllowNull()]
        [object]$Details = $null
    )
    $effectiveExitCode = if ($Status -in @('Failed', 'Blocked') -and $ExitCode -eq 0) { 1 } else { $ExitCode }
    $effectiveReasonCode = if ($ReasonCode) { $ReasonCode } else { switch ($Status) { 'Succeeded' { 'OK' } 'Failed' { 'Failed' } 'Skipped' { 'Skipped' } 'Blocked' { 'Blocked' } } }
    $effectiveMessage = if ($Message) { $Message } else { "$Operation $Status" }
    return [PSCustomObject]@{
        Status      = [string]$Status
        Operation   = [string]$Operation
        ReasonCode  = [string]$effectiveReasonCode
        Message     = [string]$effectiveMessage
        ExitCode    = [int]$effectiveExitCode
        DurationMs  = [double]$DurationMs
        Details     = $Details
    }
}

function ConvertTo-OperationResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [Alias('InputObject', 'Result')]
        [AllowNull()]
        [object]$Value,
        [string]$Operation = 'operation',
        [string]$ReasonCode = '',
        [string]$Message = '',
        [int]$ExitCode = 0,
        [double]$DurationMs = 0,
        [AllowNull()]
        [object]$Details = $null
    )

    if ($null -eq $Value) {
        $code = if ($ReasonCode) { $ReasonCode } else { 'NullResult' }
        $text = if ($Message) { $Message } else { "$Operation returned no result" }
        return New-OperationResult -Status Failed -Operation $Operation -ReasonCode $code -Message $text -ExitCode ([Math]::Max(1, $ExitCode)) -DurationMs $DurationMs -Details $Details
    }

    if ($Value -is [System.Management.Automation.ErrorRecord]) {
        $text = if ($Message) { $Message } else { $Value.Exception.Message }
        return New-OperationResult -Status Failed -Operation $Operation -ReasonCode 'Exception' -Message $text -ExitCode ([Math]::Max(1, $ExitCode)) -DurationMs $DurationMs -Details $Value
    }
    if ($Value -is [System.Exception]) {
        $text = if ($Message) { $Message } else { $Value.Message }
        return New-OperationResult -Status Failed -Operation $Operation -ReasonCode 'Exception' -Message $text -ExitCode ([Math]::Max(1, $ExitCode)) -DurationMs $DurationMs -Details $Value
    }

    if ($Value -is [bool]) {
        $status = if ($Value) { 'Succeeded' } else { 'Failed' }
        $code = if ($Value) { $(if ($ReasonCode) { $ReasonCode } else { 'OK' }) } else { $(if ($ReasonCode) { $ReasonCode } else { 'FalseResult' }) }
        $text = if ($Message) { $Message } elseif ($Value) { "$Operation succeeded" } else { "$Operation returned false" }
        $codeValue = if ($Value) { $ExitCode } else { [Math]::Max(1, $ExitCode) }
        return New-OperationResult -Status $status -Operation $Operation -ReasonCode $code -Message $text -ExitCode $codeValue -DurationMs $DurationMs -Details $(if ($null -ne $Details) { $Details } else { $Value })
    }

    $valueProps = $null
    if ($Value -is [System.Collections.IDictionary]) { $valueProps = $Value.Keys } else { $valueProps = @($Value.PSObject.Properties.Name) }
    if ($valueProps -contains 'Status') {
        $statusValue = if ($Value -is [System.Collections.IDictionary]) { [string]$Value['Status'] } else { [string]$Value.Status }
        if ($statusValue -notin @('Succeeded', 'Failed', 'Skipped', 'Blocked')) {
            $text = if ($Message) { $Message } else { "$Operation returned an invalid status: $statusValue" }
            return New-OperationResult -Status Failed -Operation $Operation -ReasonCode 'InvalidResult' -Message $text -ExitCode ([Math]::Max(1, $ExitCode)) -DurationMs $DurationMs -Details $Value
        }
        $valueCode = if ($Value -is [System.Collections.IDictionary]) { if ($Value.Contains('ReasonCode')) { [string]$Value['ReasonCode'] } else { '' } } else { if ($Value.PSObject.Properties.Name -contains 'ReasonCode') { [string]$Value.ReasonCode } else { '' } }
        $valueMessage = if ($Value -is [System.Collections.IDictionary]) { if ($Value.Contains('Message')) { [string]$Value['Message'] } else { '' } } else { if ($Value.PSObject.Properties.Name -contains 'Message') { [string]$Value.Message } else { '' } }
        $valueExit = if ($Value -is [System.Collections.IDictionary]) { if ($Value.Contains('ExitCode')) { [int]$Value['ExitCode'] } else { 0 } } else { if ($Value.PSObject.Properties.Name -contains 'ExitCode') { [int]$Value.ExitCode } else { 0 } }
        $valueDuration = if ($Value -is [System.Collections.IDictionary]) { if ($Value.Contains('DurationMs')) { [double]$Value['DurationMs'] } else { 0 } } else { if ($Value.PSObject.Properties.Name -contains 'DurationMs') { [double]$Value.DurationMs } else { 0 } }
        $valueDetails = if ($Value -is [System.Collections.IDictionary]) { if ($Value.Contains('Details')) { $Value['Details'] } else { $Value } } else { if ($Value.PSObject.Properties.Name -contains 'Details') { $Value.Details } else { $Value } }
        $code = if ($ReasonCode) { $ReasonCode } elseif ($valueCode) { $valueCode } else { if ($statusValue -eq 'Succeeded') { 'OK' } else { 'OperationResult' } }
        $text = if ($Message) { $Message } elseif ($valueMessage) { $valueMessage } else { "$Operation $statusValue" }
        return New-OperationResult -Status $statusValue -Operation $Operation -ReasonCode $code -Message $text -ExitCode $valueExit -DurationMs $(if ($DurationMs -gt 0) { $DurationMs } else { $valueDuration }) -Details $(if ($null -ne $Details) { $Details } else { $valueDetails })
    }

    $isArray = $Value -is [System.Array]
    if (-not $isArray -and $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { $isArray = $true }
    if ($isArray) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            $code = if ($ReasonCode) { $ReasonCode } else { 'EmptyResult' }
            $text = if ($Message) { $Message } else { "$Operation returned an empty result" }
            return New-OperationResult -Status Skipped -Operation $Operation -ReasonCode $code -Message $text -ExitCode $ExitCode -DurationMs $DurationMs -Details $Value
        }
        $results = @()
        foreach ($item in $items) {
            $results += ConvertTo-OperationResult -Value $item -Operation $Operation -DurationMs $DurationMs
        }
        $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
        $blocked = @($results | Where-Object { $_.Status -eq 'Blocked' })
        $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
        $status = if ($failed.Count -gt 0) { 'Failed' } elseif ($blocked.Count -gt 0) { 'Blocked' } elseif ($skipped.Count -gt 0) { 'Skipped' } else { 'Succeeded' }
        $code = if ($ReasonCode) { $ReasonCode } elseif ($failed.Count -gt 0) { $failed[0].ReasonCode } elseif ($blocked.Count -gt 0) { $blocked[0].ReasonCode } elseif ($skipped.Count -gt 0) { $skipped[0].ReasonCode } else { 'OK' }
        $text = if ($Message) { $Message } else { "$Operation returned $($items.Count) result(s): $status" }
        $exit = if ($failed.Count -gt 0) { [Math]::Max(1, $failed[0].ExitCode) } else { $ExitCode }
        return New-OperationResult -Status $status -Operation $Operation -ReasonCode $code -Message $text -ExitCode $exit -DurationMs $DurationMs -Details $(if ($null -ne $Details) { $Details } else { $Value })
    }

    $text = if ($Message) { $Message } else { "$Operation succeeded" }
    $code = if ($ReasonCode) { $ReasonCode } else { 'OK' }
    return New-OperationResult -Status Succeeded -Operation $Operation -ReasonCode $code -Message $text -ExitCode $ExitCode -DurationMs $DurationMs -Details $(if ($null -ne $Details) { $Details } else { $Value })
}

function Test-RequiredResult {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Alias('InputObject')]
        [AllowNull()]
        [object]$Result,
        [string]$Operation = 'operation',
        [switch]$Throw
    )
    $normalized = ConvertTo-OperationResult -Value $Result -Operation $Operation
    if ($normalized.Status -eq 'Succeeded') { return $true }
    if ($Throw) {
        $reason = if ($normalized.ReasonCode) { $normalized.ReasonCode } else { $normalized.Status }
        $message = if ($normalized.Message) { $normalized.Message } else { "$Operation failed" }
        throw (Resolve-LogMessage -Key 'log.sharedutils.line2167' -MessageArgs @([string]$Operation, [string]$message, [string]$reason) -Fallback "$Operation failed: $message [$reason]")
    }
    return $false
}

function Test-BuildGateResult {
    <#
    .SYNOPSIS
        Tri-state gate verdict for an optional pipeline stage (test, lint, ...).
    .DESCRIPTION
        Test-RequiredResult only accepts Status 'Succeeded', so a stage that
        correctly reported "nothing to run" - Status 'Skipped' with a
        ReasonCode like 'NoTests' or 'ToolMissing', which is exactly what the
        plugin layer emits - was treated as a FAILURE and failed the whole
        build. A .NET project with no test project could not be built at all.

        This gate keeps the three outcomes distinct:
          Succeeded -> pass
          Skipped   -> pass, with a warning (nothing to run is not a failure)
          anything else -> fail
        Genuine test/lint FAILURES still fail the build unchanged.

        When -State is supplied and the gate FAILS, the operation family
        ('lint', 'test', ...) is stamped onto the state via
        Set-NonRetryableOperation. A failing verification tool is deterministic
        - re-running it yields the same verdict - so ErrorHandling must classify
        the resulting throw as Permanent. Without the stamp the generic
        "failed with exit code" branch classified it Transient and the enclosing
        pipeline step was re-run three more times in full. Centralising the
        stamp here covers every gate call site instead of relying on each caller
        remembering to mark its own throw.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Alias('InputObject')]
        [AllowNull()]
        [object]$Result,
        [string]$Operation = 'operation',
        [string]$StageLabel = '',
        [PSCustomObject]$State = $null
    )
    $normalized = ConvertTo-OperationResult -Value $Result -Operation $Operation
    $status = [string]$normalized.Status
    $label = if ($StageLabel) { $StageLabel } else { $Operation }
    # The failing tool's own output travels WITH the verdict. Details was being
    # dropped here, which is why a lint failure reached the user as nothing more
    # than "Command failed with exit code 2": for `dotnet format
    # --verify-no-changes` that exit code is the ONLY thing the developer was
    # shown, while the 100+ captured lines naming every offending file, line and
    # rule were discarded one layer above. Carrying it costs nothing (the value is
    # already built by New-OperationResult) and makes EVERY failing gate
    # actionable, not just this one.
    $gateDetails = $normalized.Details
    if ($status -eq 'Succeeded') {
        return @{ Passed = $true; Skipped = $false; Status = $status; ReasonCode = [string]$normalized.ReasonCode; Message = [string]$normalized.Message; Label = $label; Details = $gateDetails }
    }
    if ($status -eq 'Skipped') {
        return @{ Passed = $true; Skipped = $true; Status = $status; ReasonCode = [string]$normalized.ReasonCode; Message = [string]$normalized.Message; Label = $label; Details = $gateDetails }
    }
    $message = if ($normalized.Message) { [string]$normalized.Message } else { "$Operation failed" }
    # Mark deterministic-on-failure BEFORE the caller throws, while the failing
    # operation is still the one in scope. 'lint:C#' -> 'lint'.
    if ($State -and (Get-Command Set-NonRetryableOperation -ErrorAction SilentlyContinue)) {
        $family = ([string]$Operation -split ':')[0].Trim().ToLowerInvariant()
        if ($family) { Set-NonRetryableOperation -State $State -Operation $family }
    }
    return @{ Passed = $false; Skipped = $false; Status = $status; ReasonCode = [string]$normalized.ReasonCode; Message = $message; Label = $label; Details = $gateDetails }
}

function Write-BuildGateDiagnostics {
    <#
    .SYNOPSIS
        Prints the failing tool's own captured output after a test/lint gate fails.
    .DESCRIPTION
        A gate verdict carries a Message that is a summary ("Command failed with
        exit code 2"), never the tool's report. Every verification tool writes
        the actionable part - offending file, line and rule - to stdout/stderr,
        which the plugin layer already captured into the result's Details. Until
        this existed, that output stopped one layer above the user: `dotnet format
        --verify-no-changes` failed the build over whitespace and the console
        showed only the exit code, forcing a blind re-run of the tool to learn
        anything.

        All six gate call sites in the Orchestrator share one shape, so they all
        call this instead of re-implementing printing. Output is bounded so a
        tool that emits thousands of lines cannot flood the log, and the overflow
        is counted rather than silently dropped.

        Follows the existing convention in HealthCheck.psm1 for surfacing Details:
        Write-Log with an [INFO] prefix. No-ops when the gate passed, was skipped,
        captured nothing, or when Logging is unavailable.    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Gate,
        [PSCustomObject]$State = $null,
        [int]$MaxLines = 20
    )
    if ($null -eq $Gate) { return }
    if ($Gate.PSObject.Properties.Name -notcontains 'Details' -and $Gate -isnot [System.Collections.IDictionary]) { return }
    $passed = if ($Gate -is [System.Collections.IDictionary]) { if ($Gate.Contains('Passed')) { [bool]$Gate['Passed'] } else { $false } } else { [bool]$Gate.Passed }
    # Defensive: callers already only invoke this on a failure, but a helper that
    # prints "Succeeded diagnostics" would be actively misleading if one ever did.
    if ($passed) { return }
    $raw = if ($Gate -is [System.Collections.IDictionary]) { if ($Gate.Contains('Details')) { $Gate['Details'] } else { $null } } else { $Gate.Details }
    if ($null -eq $raw) { return }
    # Details is a free-form field, not a diagnostics contract: some plugins put a
    # scalar in it (a bool flag, a ref id). Rendering those as diagnostic lines
    # is pure noise - "False" is not a finding. Only string payloads and real
    # collections of strings count as tool output.
    if ($raw -is [string]) { $rawItems = @($raw) }
    elseif ($raw -is [System.Collections.IEnumerable]) { $rawItems = @($raw) }
    else { $rawItems = @() }
    if ($rawItems.Count -eq 0) { return }
    # Normalise to non-empty lines. Tools interleave blank lines and ANSI colour
    # escapes; neither helps the reader and both inflate the line count.
    $lines = @(foreach ($item in $rawItems) {
            if ($null -eq $item -or $item -isnot [string]) { continue }
            $text = $item -replace "`e\[[0-9;]*[A-Za-z]", ''
            if (-not [string]::IsNullOrWhiteSpace($text)) { $text.TrimEnd() }
        })
    if ($lines.Count -eq 0) { return }
    if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) { return }
    $label = if ($Gate -is [System.Collections.IDictionary] -and $Gate.Contains('Label') -and $Gate['Label']) { [string]$Gate['Label'] } else { [string]$Gate.Label }
    $kind = if ($Gate -is [System.Collections.IDictionary] -and $Gate.Contains('Status')) { [string]$Gate['Status'] } else { [string]$Gate.Status }
    $head = if ($label) { "{0} diagnostics ({1}):" -f $label, $kind } else { "{0} diagnostics:" -f $kind }
    Write-Log "     [INFO] $head" 'Yellow' $State
    $shown = if ($MaxLines -gt 0 -and $lines.Count -gt $MaxLines) { $MaxLines } else { $lines.Count }
    for ($i = 0; $i -lt $shown; $i++) { Write-Log ("     [INFO]   " + $lines[$i]) 'Gray' $State }
    if ($shown -lt $lines.Count) {
        $hidden = $lines.Count - $shown
        Write-Log ("     [INFO]   ... and {0} more line(s). Re-run the tool directly for the full report." -f $hidden) 'Gray' $State
    }
}

function Get-ExecutableExtension {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State = $null,
        [string]$Fallback = ''
    )
    # Single source for the OS-specific executable extension (.exe on Windows,
    # empty elsewhere). Callers use this instead of re-implementing the
    # `if ($os -eq 'Windows') { '.exe' } else { '' }` ternary across modules.
    $os = $null
    if ($State -and $State.OS) { $os = $State.OS }
    elseif (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { $os = Get-OSPlatform }
    if ($os -eq 'Windows') { return '.exe' }
    return $Fallback
}


function ConvertTo-BuildArgument {
    <#
    .SYNOPSIS
        Quotes a single argument for a native command line (OS-aware).
    .DESCRIPTION
        Single owner for argument quoting. Windows: backslash-doubling before
        quotes, quote escaping, trailing-backslash doubling. POSIX: single-quote
        wrapping with '\'' escaping. Four helpers previously carried three
        different escape rules; this consolidates them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $value = [string]$Value
    if ($value -eq '') { return '""' }
    if (Test-IsWindowsHost) {
        if ($value -notmatch '[\s"]') { return $value }
        return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    # POSIX: leave simple arguments unquoted so callers and tests receive the
    # literal token when no shell metacharacter requires quoting/escaping.
    if ($value -match '^[A-Za-z0-9_./:=+,@%-]+$') { return $value }
    return "'" + ($value -replace "'", "'\''") + "'"
}

function New-BuildProcessStartInfo {
    <#
    .SYNOPSIS
        Single owner for ProcessStartInfo construction across all launchers.
    .DESCRIPTION
        Four sites independently built ProcessStartInfo with the same
        UseShellExecute/Redirect/CreateNoWindow/UTF-8 encoding guards. This
        consolidates that construction so a fix to encoding or batch routing
        lands in one place. Callers still own their output-reading strategy
        (live pump vs async capture vs simple ReadToEnd).
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.ProcessStartInfo])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [switch]$AllowBatch
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $ext = [System.IO.Path]::GetExtension($FilePath)
    if ($AllowBatch -and $ext -in @('.cmd', '.bat')) {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { return $null }
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /c "' + $FilePath + '" ' + $Arguments
    } else {
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
    }
    return $psi
}

function Stop-BuildProcess {
    <#
    .SYNOPSIS
        Terminates a child process and bounds the wait for its teardown.
    .DESCRIPTION
        Internal teardown owner for the .NET process launchers. Process STARTUP
        remains intentionally distributed: InfraVerification probes short-lived
        tools, Distributed SSH streams asynchronously, and BuildProgress pumps
        live output while heartbeating. Those launch paths are different
        questions. Their teardown was the duplicated part: check HasExited,
        prefer whole-tree termination where supported, wait briefly, then let
        the caller dispose. On runtimes without Process.Kill(bool), the
        whole-tree call is retried as a process-only kill, preserving the
        previous Distributed/BuildProgress behavior on Windows PowerShell 5.1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][System.Diagnostics.Process]$Process,
        [int]$WaitMs = 1000,
        [switch]$EntireTree
    )
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            if ($EntireTree) {
                try { $Process.Kill($true) } catch { try { $Process.Kill() } catch { } }
            } else {
                $Process.Kill()
            }
        }
    } catch { }
    if ($WaitMs -gt 0) {
        try { [void]$Process.WaitForExit($WaitMs) } catch { }
    }
}

function Update-ProjectGitignore {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir)
    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        if ($State -and ($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) { $ProjectDir = [string]$State.ProjectRoot }
        elseif ($State -and ($State.PSObject.Properties.Name -contains 'WorkingDir') -and $State.WorkingDir) { $ProjectDir = [string]$State.WorkingDir }
    }
    if ([string]::IsNullOrWhiteSpace($ProjectDir) -or -not (Test-Path -LiteralPath $ProjectDir -PathType Container)) { return }
    $patterns = @()
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { $patterns = @(Get-BuildConstant -Key 'ProjectGitignorePatterns' -State $State -Fallback @()) }
    } catch { $patterns = @() }
    if ($patterns.Count -eq 0) {
        try {
            $cfg = if ($State) { Get-ConfigValue -Path 'project.gitignorePatterns' -State $State -Default $null } else { $null }
            if ($cfg) { $patterns = @($cfg) }
        } catch { $patterns = @() }
    }
    if ($patterns.Count -eq 0) { return }

    # A tool's own .gitignore must never name a platform tool folder. The
    # default pattern set contains '_Build/' and '_Sync/', so writing it
    # into _Build/.gitignore made the tool ignore its own source - and the
    # repository then tracked NONE of the code. The tool-folder patterns
    # are dropped whenever the target is inside a tool folder or holds one.
    $toolFolderNames = @('_Build', '_Sync', '_Tests')
    $resolvedProjectDir = $null
    try { $resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir -ErrorAction Stop).Path } catch { }
    $projectSegments = @()
    if ($resolvedProjectDir) { $projectSegments = @(($resolvedProjectDir -replace '\\', '/') -split '/') }
    $insideToolFolder = @($projectSegments | Where-Object { $_ -in $toolFolderNames }).Count -gt 0
    if ($insideToolFolder) { return }
    $holdsToolFolders = @($toolFolderNames | Where-Object { Test-Path -LiteralPath (Join-Path $ProjectDir $_) -PathType Container }).Count -gt 0
    if ($holdsToolFolders) {
        $patterns = @($patterns | Where-Object { ([string]$_).Trim().TrimEnd('/') -notin $toolFolderNames })
    }
    if ($patterns.Count -eq 0) { return }

    $giPath = Join-Path $ProjectDir '.gitignore'
    $existing = @()
    if (Test-Path -LiteralPath $giPath -PathType Leaf) {
        $existing = @(Get-Content -LiteralPath $giPath -ErrorAction SilentlyContinue)
    }
    $existingSet = @{}
    foreach ($e in $existing) { $t = $e.Trim(); if ($t) { $existingSet[$t] = $true } }
    $toAdd = @()
    foreach ($p in $patterns) {
        $pt = [string]$p
        if (-not $existingSet.ContainsKey($pt)) { $toAdd += $pt }
    }
    if ($toAdd.Count -eq 0) { return }
    $block = @('', '# Auto-added by gbuild (project gitignore patterns)')
    $block += $toAdd
    $content = ($existing + $block) -join [Environment]::NewLine
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($giPath, $content + [Environment]::NewLine, $utf8)
    } catch { }
}

Export-ModuleMember -Function @(
    'New-BuildProcessStartInfo',
    'Stop-BuildProcess',
    'Move-BuildFileAtomic',
    'Update-ProjectGitignore',
# Get-BuildBytesHash was deleted. Its own header explains it existed to replace
# two byte-identical copies inside Standalone.psm1; that migration happened, and
# nothing outside the test suite has called it since. A digest helper that only
# tests exercise is not a shared primitive, it is a private detail of one test.
    'Get-BuildFileSha256'
    'Get-ExecutableExtension'
    'New-OperationResult'
    'ConvertTo-OperationResult'
    'Test-RequiredResult'
    'Test-BuildGateResult'
    'Get-BuildVendoredToolsRoot'
    'Resolve-VendoredToolModule'
    'Write-BuildGateDiagnostics'
    'Resolve-EnvPlaceholder'
    'Test-UnresolvedEnvPlaceholder'
    'Test-EnvToggle'
    'Get-EnvMode'
    'Get-InvokeCommandHint'
    'Resolve-PowerShellHost'
    'Read-DotEnvFile'
    'Invoke-SafeRemove'
    'Get-BuildTenantId'
    'Get-BuildCorrelationId'
    'Get-BuildIdentity'
    'Get-BuildConstant'
    'Get-ConfigSection'
    'Get-SyntaxCheckExcludeDirs'
    'Get-SyntaxCheckExcludeFiles'
    'Get-BoundedProjectFiles'
    'Get-BuildListConstant'
    'Test-ToolAvailable'
    'Test-BuildCIHost'
    'Remove-JsonComments'
    'Get-SecretDetectionPatterns'
    'Write-BuildTextFileAtomic'
    'Get-BuildStringHash'
    'Get-BuildTextLines'
    'Enter-BuildFileLock'
    'Exit-BuildFileLock'
    'Get-SecretRedactPatterns'
    'Get-BuildSecretRedactPatterns'
    'Protect-BuildSecretText'
    'Invoke-BuildSecretProtect'
    'Get-AuditLogPath'
    'Write-BuildAuditLog'
    'Write-BuildJsonFile'
    'Read-BuildJsonFile'
    'Resolve-PublishOutputDir'
    'Resolve-BuildOpenOutput'
    'Get-ReportDirectory'
    'Get-ProjectShortName'
    'Invoke-SyntaxCheck'
    # Exported because Preflight.psm1 prefers it via its Get-Command check over Invoke-SyntaxCheck.
    'Invoke-UniversalSyntaxCheck'
    'ConvertTo-BuildArgument'
    'Write-BuildTextFileUtf8'
)
