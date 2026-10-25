# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ========================================================================
# PluginSDK.psm1 — Formal plugin manifest + versioning API (Level 5+)
# ========================================================================
# Closes the "no formal plugin SDK" gap:
#   BEFORE: plugins were discovered by file name only; Get-PluginInfo returned
#   Name/SupportedLanguages/Priority with NO version, NO api contract, NO
#   dependency declaration, NO compatibility gate.
#   AFTER: every plugin MAY ship a sidecar manifest (<Name>.plugin.json) that
#   declares name/version/apiVersion/minGbuildVersion/supportedLanguages/
#   dependencies/capabilities. The SDK validates the manifest, checks semver
#   compatibility against the running gbuild + SDK API, resolves dependency
#   order, and honors config-driven policy (build.plugins).
#
# Backward compatible: plugins WITHOUT a manifest file are synthesized from
# Get-PluginInfo with safe defaults (version 1.0.0, apiVersion = current SDK
# API) so the 14 built-in plugins keep loading unchanged.
#
# PS 5.1-safe: no ?? / ?. operators, no ternary, only .NET + approved verbs.
# ========================================================================

# -- SDK API version (single source for the plugin contract) ------------------
# Owner: BuildConstants.PluginSdkApiVersion (verified, schema-gated). The
# literal below is the survival seed when BuildConstants has not loaded yet;
# it is overridden from the registry at module load, so bump MINOR for additive
# changes, MAJOR for breaking contract changes — by editing the constant, once.
$script:PluginSdkApiVersion = '1.0.0'
$script:PluginManifestSuffix = '.plugin.json'
# Single source: BuildConstants (PluginSdkApiVersion / PluginDefaultVersion).
# These local literals are survival seeds only; the values below are replaced
# from the registry at load time so a version bump is ONE edit, not two.
if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
    try { $v = [string](Get-BuildDefault -Key 'PluginSdkApiVersion' -Fallback ''); if (-not [string]::IsNullOrWhiteSpace($v)) { $script:PluginSdkApiVersion = $v } } catch { }
}
$script:PluginDefaultVersion = '1.0.0'
if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
    try { $v = [string](Get-BuildConstant -Key 'PluginDefaultVersion' -Fallback ''); if (-not [string]::IsNullOrWhiteSpace($v)) { $script:PluginDefaultVersion = $v } } catch { }
}

function Get-PluginSdkApiVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

Set-StrictMode -Version 1.0
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        $v = Get-BuildDefault -Key 'PluginSdkApiVersion' -Fallback $script:PluginSdkApiVersion
        if ($v) { return [string]$v }
    }
    return $script:PluginSdkApiVersion
}

function Get-GBuildToolVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
        $v = Get-BuildDefault -Key 'Version' -Fallback '2.0.0'
        if ($v) { return [string]$v }
    }
    return '2.0.0'
}

# -- Semver --------------------------------------------------------------------
function ConvertTo-PluginVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version
    )
    $result = [PSCustomObject]@{
        Raw        = $Version
        Major      = 0
        Minor      = 0
        Patch      = 0
        Prerelease = ''
        Valid      = $false
    }
    if ([string]::IsNullOrWhiteSpace($Version)) { return $result }
    $v = $Version.Trim()
    if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
    $m = [regex]::Match($v, '^(?<maj>\d+)\.(?<min>\d+)\.(?<pat>\d+)(?:-(?<pre>[A-Za-z0-9.-]+))?(?:\+[A-Za-z0-9.-]+)?$')
    if (-not $m.Success) {
        # Tolerate short forms "1" / "1.2" -> "1.0.0" / "1.2.0" (config ergonomics).
        $m2 = [regex]::Match($v, '^(?<maj>\d+)(?:\.(?<min>\d+))?$')
        if ($m2.Success) {
            $result.Major = [int]$m2.Groups['maj'].Value
            if ($m2.Groups['min'].Success) { $result.Minor = [int]$m2.Groups['min'].Value }
            $result.Patch = 0
            $result.Valid = $true
        }
        return $result
    }
    $result.Major = [int]$m.Groups['maj'].Value
    $result.Minor = [int]$m.Groups['min'].Value
    $result.Patch = [int]$m.Groups['pat'].Value
    if ($m.Groups['pre'].Success) { $result.Prerelease = $m.Groups['pre'].Value }
    $result.Valid = $true
    return $result
}

function Compare-PluginVersion {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    $l = ConvertTo-PluginVersion -Version $Left
    $r = ConvertTo-PluginVersion -Version $Right
    if (-not $l.Valid -or -not $r.Valid) {
        return [string]::Compare($Left, $Right, [System.StringComparison]::Ordinal)
    }
    foreach ($field in @('Major', 'Minor', 'Patch')) {
        if ($l.$field -lt $r.$field) { return -1 }
        if ($l.$field -gt $r.$field) { return 1 }
    }
    # Release > prerelease; prerelease ordered lexically (semver rule 11).
    $lPre = $l.Prerelease
    $rPre = $r.Prerelease
    if ([string]::IsNullOrEmpty($lPre) -and (-not [string]::IsNullOrEmpty($rPre))) { return 1 }
    if ((-not [string]::IsNullOrEmpty($lPre)) -and [string]::IsNullOrEmpty($rPre)) { return -1 }
    return [string]::Compare($lPre, $rPre, [System.StringComparison]::Ordinal)
}

function Test-PluginVersionConstraint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Constraint
    )
    if ([string]::IsNullOrWhiteSpace($Constraint)) { return $true }
    $c = $Constraint.Trim()
    if ($c -eq '*' -or $c -eq 'x' -or $c -eq 'latest') { return $true }
    $ver = ConvertTo-PluginVersion -Version $Version
    if (-not $ver.Valid) { return $false }
    # Multi-clause: space-separated AND (e.g. ">=1.2.0 <2.0.0").
    $clauses = @($c -split '\s+' | Where-Object { $_ -ne '' })
    foreach ($clause in $clauses) {
        $ok = $true
        if ($clause.StartsWith('^')) {
            $base = ConvertTo-PluginVersion -Version $clause.Substring(1)
            if (-not $base.Valid) { return $false }
            $upper = ('{0}.0.0' -f ($base.Major + 1))
            if ($base.Major -eq 0 -and $base.Minor -gt 0) { $upper = ('0.{0}.0' -f ($base.Minor + 1)) }
            $ok = ((Compare-PluginVersion -Left $Version -Right $clause.Substring(1)) -ge 0) -and ((Compare-PluginVersion -Left $Version -Right $upper) -lt 0)
        } elseif ($clause.StartsWith('~')) {
            $base = ConvertTo-PluginVersion -Version $clause.Substring(1)
            if (-not $base.Valid) { return $false }
            $upper = ('{0}.{1}.0' -f $base.Major, ($base.Minor + 1))
            $ok = ((Compare-PluginVersion -Left $Version -Right $clause.Substring(1)) -ge 0) -and ((Compare-PluginVersion -Left $Version -Right $upper) -lt 0)
        } elseif ($clause.StartsWith('>=')) {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause.Substring(2)) -ge 0
        } elseif ($clause.StartsWith('<=')) {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause.Substring(2)) -le 0
        } elseif ($clause.StartsWith('>')) {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause.Substring(1)) -gt 0
        } elseif ($clause.StartsWith('<')) {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause.Substring(1)) -lt 0
        } elseif ($clause.StartsWith('=')) {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause.Substring(1)) -eq 0
        } else {
            $ok = (Compare-PluginVersion -Left $Version -Right $clause) -eq 0
        }
        if (-not $ok) { return $false }
    }
    # Prerelease gate: a stable version never satisfies a prerelease-only range
    # unless the caller opts in via build.plugins.allowPrerelease (checked by
    # Test-PluginCompatibility, not here).
    return $true
}

# -- Manifest ------------------------------------------------------------------

function Read-PluginManifestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if (Get-Command Remove-JsonComments -ErrorAction SilentlyContinue) {
            $raw = Remove-JsonComments -JsonWithComments $raw
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return [PSCustomObject]@{ __ManifestError = $_.Exception.Message; __ManifestPath = $Path }
    }
}



function New-PluginManifestTemplate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$SupportedLanguages = @()
    )
    return [PSCustomObject]@{
        name              = $Name
        version           = '1.0.0'
        apiVersion        = (Get-PluginSdkApiVersion)
        minGbuildVersion  = (Get-GBuildToolVersion)
        maxGbuildVersion  = ''
        author            = ''
        description       = ''
        supportedLanguages = @($SupportedLanguages)
        priority          = 5
        dependencies      = @()
        capabilities      = @('build', 'test', 'lint', 'preflight')
        entryPoint        = ('{0}.psm1' -f $Name)
    }
}

# -- Policy / compatibility ------------------------------------------------------
function Get-PluginSdkConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $cfg = [PSCustomObject]@{
        Enabled          = $true
        StrictApiCheck   = $false
        AllowPrerelease  = $false
        Disabled         = @()
        AllowList        = @()
        RequireManifest  = $false
    }
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        $get = { param($suffix, $fb) Get-ConfigValue -Path ('build.plugins.{0}' -f $suffix) -State $State -Default $fb }
        $cfg.Enabled = [bool](& $get 'enabled' $true)
        $cfg.StrictApiCheck = [bool](& $get 'strictApiCheck' $false)
        $cfg.AllowPrerelease = [bool](& $get 'allowPrerelease' $false)
        $cfg.RequireManifest = [bool](& $get 'requireManifest' $false)
        $d = & $get 'disabled' $null
        if ($null -ne $d) { $cfg.Disabled = @($d) }
        $a = & $get 'allowList' $null
        if ($null -ne $a) { $cfg.AllowList = @($a) }
    } elseif ($null -ne $State -and $null -ne $State.BuildConfig) {
        try {
            $raw = $State.BuildConfig.build.plugins
            if ($null -ne $raw) {
                if ($null -ne $raw.enabled) { $cfg.Enabled = [bool]$raw.enabled }
                if ($null -ne $raw.strictApiCheck) { $cfg.StrictApiCheck = [bool]$raw.strictApiCheck }
                if ($null -ne $raw.allowPrerelease) { $cfg.AllowPrerelease = [bool]$raw.allowPrerelease }
                if ($null -ne $raw.requireManifest) { $cfg.RequireManifest = [bool]$raw.requireManifest }
                if ($null -ne $raw.disabled) { $cfg.Disabled = @($raw.disabled) }
                if ($null -ne $raw.allowList) { $cfg.AllowList = @($raw.allowList) }
            }
        } catch { }
    }
    return $cfg
}



function Get-PluginManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PluginPath)
    if ([string]::IsNullOrWhiteSpace($PluginPath) -or $PluginPath -match '[\x00]') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.pluginsdk.line268' -Fallback 'Plugin path is invalid.')) }
    $full = [System.IO.Path]::GetFullPath($PluginPath)
    if ([System.IO.Path]::GetExtension($full) -ne '.psm1') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.pluginsdk.line270' -Fallback 'Plugin path must identify a PowerShell module.')) }
    $dir = [System.IO.Path]::GetDirectoryName($full)
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $suffix = $script:PluginManifestSuffix
    if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) { $value = Get-BuildDefault -Key 'PluginManifestSuffix' -Fallback $suffix; if ($value) { $suffix = [string]$value } }
    return [System.IO.Path]::GetFullPath((Join-Path $dir ($leaf + $suffix)))
}

function Test-PluginManifest {
    [CmdletBinding()]
    param($Manifest)
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Manifest) { return @{ Valid = $false; Errors = @('Manifest is null'); Warnings = @() } }
    if ($Manifest.PSObject.Properties.Name -contains '__ManifestError') { return @{ Valid = $false; Errors = @('Manifest JSON is invalid'); Warnings = @() } }
    if ($Manifest.PSObject.Properties.Name -contains 'manifestError' -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.manifestError)) { return @{ Valid = $false; Errors = @([string]$Manifest.manifestError); Warnings = @() } }
    $found = ($Manifest.PSObject.Properties.Name -contains 'manifestFound' -and [bool]$Manifest.manifestFound)
    foreach ($field in @('name','version')) { if (-not ($Manifest.PSObject.Properties.Name -contains $field) -or [string]::IsNullOrWhiteSpace([string]$Manifest.$field)) { [void]$errors.Add('Missing required field: ' + $field) } }
    if (($Manifest.PSObject.Properties.Name -contains 'name') -and ([string]$Manifest.name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$')) { [void]$errors.Add('name must match ^[A-Za-z][A-Za-z0-9_-]*$') }
    if ($found) {
        if (-not ($Manifest.PSObject.Properties.Name -contains 'pluginFile') -or -not $Manifest.pluginFile) { [void]$errors.Add('Manifest is not bound to pluginFile') }
        if (-not ($Manifest.PSObject.Properties.Name -contains 'manifestPath') -or -not $Manifest.manifestPath) { [void]$errors.Add('Manifest is not bound to manifestPath') }
        if (-not ($Manifest.PSObject.Properties.Name -contains 'entryPoint') -or [string]::IsNullOrWhiteSpace([string]$Manifest.entryPoint)) { [void]$errors.Add('Missing required field: entryPoint') }
        if (-not ($Manifest.PSObject.Properties.Name -contains 'apiVersion') -or [string]::IsNullOrWhiteSpace([string]$Manifest.apiVersion)) { [void]$errors.Add('Manifest apiVersion is required') }
        if (-not ($Manifest.PSObject.Properties.Name -contains 'capabilities')) { [void]$errors.Add('Manifest capabilities are required') }
        if ($Manifest.PSObject.Properties.Name -contains 'pluginFile' -and $Manifest.pluginFile) {
            try {
                $pluginFull = [System.IO.Path]::GetFullPath([string]$Manifest.pluginFile)
                if (-not (Test-Path -LiteralPath $pluginFull -PathType Leaf)) { [void]$errors.Add('pluginFile does not exist') }
                $moduleBase = [System.IO.Path]::GetFileNameWithoutExtension($pluginFull)
                if ([string]$Manifest.name -cne $moduleBase) { [void]$errors.Add('name must match the plugin module identity') }
                if ($Manifest.PSObject.Properties.Name -contains 'manifestPath' -and $Manifest.manifestPath) {
                    $expectedManifest = Get-PluginManifestPath -PluginPath $pluginFull
                    if ([System.IO.Path]::GetFullPath([string]$Manifest.manifestPath) -ne $expectedManifest) { [void]$errors.Add('manifestPath does not match pluginFile') }
                    if (-not (Test-Path -LiteralPath ([string]$Manifest.manifestPath) -PathType Leaf)) { [void]$errors.Add('manifestPath does not exist') }
                }
                if ($Manifest.PSObject.Properties.Name -contains 'entryPoint' -and $Manifest.entryPoint) {
                    $entry = [string]$Manifest.entryPoint
                    if ([System.IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[\\/])\.\.([\\/]|$)') { [void]$errors.Add('entryPoint must be a local module path') }
                    else {
                        $entryFull = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetDirectoryName($pluginFull)) $entry))
                        if ($entryFull -ne $pluginFull) { [void]$errors.Add('entryPoint must identify the bound plugin module') }
                    }
                }
            } catch { [void]$errors.Add('Manifest path binding is invalid') }
        }
    }
    foreach ($field in @('version','apiVersion','minGbuildVersion','maxGbuildVersion')) {
        if (($Manifest.PSObject.Properties.Name -contains $field) -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.$field)) { if (-not (ConvertTo-PluginVersion -Version ([string]$Manifest.$field)).Valid) { [void]$errors.Add('Invalid semver in ' + $field) } }
    }
    if ($Manifest.PSObject.Properties.Name -contains 'priority') { try { $priority = [int]$Manifest.priority; if ($priority -lt 1 -or $priority -gt 10) { [void]$errors.Add('priority must be 1..10') } } catch { [void]$errors.Add('priority must be an integer 1..10') } }
    if ($Manifest.PSObject.Properties.Name -contains 'supportedLanguages') {
        $languages = @($Manifest.supportedLanguages)
        if ($found -and $languages.Count -eq 0) { [void]$errors.Add('supportedLanguages must not be empty') }
        foreach ($language in $languages) { if ([string]::IsNullOrWhiteSpace([string]$language)) { [void]$errors.Add('supportedLanguages contains an empty entry'); break } }
    } elseif ($found) { [void]$errors.Add('supportedLanguages is required') }
    if ($Manifest.PSObject.Properties.Name -contains 'capabilities') {
        $capabilities = @($Manifest.capabilities)
        if ($found -and $capabilities.Count -eq 0) { [void]$errors.Add('capabilities must not be empty') }
        $allowed = @('build','test','lint','preflight','clean','run','security','policy','supply-chain')
        foreach ($capability in $capabilities) { if ($capability -notin $allowed) { [void]$errors.Add('capability is not allowed'); break } }
    }
    if ($Manifest.PSObject.Properties.Name -contains 'dependencies') { foreach ($dependency in @($Manifest.dependencies)) { $name = ''; if ($dependency -is [string]) { $name = $dependency } elseif ($null -ne $dependency -and $dependency.PSObject.Properties.Name -contains 'name') { $name = [string]$dependency.name }; if ([string]::IsNullOrWhiteSpace($name)) { [void]$errors.Add('every dependency needs a name') } } }
    if (-not $found) { [void]$warnings.Add('manifest absent; legacy plugin policy applies') }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

function Get-PluginManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PluginPath, $PluginInfo = $null, [PSCustomObject]$State = $null)
    $manifestPath = Get-PluginManifestPath -PluginPath $PluginPath
    $fileManifest = Read-PluginManifestFile -Path $manifestPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFullPath($PluginPath))
    $merged = [PSCustomObject]@{ name = $baseName; version = $script:PluginDefaultVersion; apiVersion = (Get-PluginSdkApiVersion); minGbuildVersion = ''; maxGbuildVersion = ''; supportedLanguages = @(); priority = 5; dependencies = @(); capabilities = @(); entryPoint = [System.IO.Path]::GetFileName($PluginPath); manifestPath = $manifestPath; manifestFound = $false; manifestValid = $true; pluginFile = [System.IO.Path]::GetFullPath($PluginPath) }
    if ($null -ne $fileManifest) {
        $merged.manifestFound = $true
        if ($fileManifest.PSObject.Properties.Name -contains '__ManifestError') {
            $merged.manifestValid = $false
            $merged | Add-Member -MemberType NoteProperty -Name manifestError -Value ([string]$fileManifest.__ManifestError) -Force
            return $merged
        }
        foreach ($property in $fileManifest.PSObject.Properties) { if ($property.Name -notin @('__ManifestError','__ManifestPath')) { $merged | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force } }
        $missingFields = @('name','version','apiVersion','entryPoint','capabilities','supportedLanguages') | Where-Object { $fileManifest.PSObject.Properties.Name -notcontains $_ }
        if (@($missingFields).Count -gt 0) { $merged | Add-Member -MemberType NoteProperty -Name manifestError -Value ('Missing manifest fields: ' + (@($missingFields) -join ', ')) -Force; $merged.manifestValid = $false }
        $merged.manifestPath = $manifestPath
        $merged.pluginFile = [System.IO.Path]::GetFullPath($PluginPath)
        if (-not ($fileManifest.PSObject.Properties.Name -contains 'entryPoint')) { $merged.entryPoint = [System.IO.Path]::GetFileName($PluginPath) }
    } elseif ($null -ne $PluginInfo) {
        if ($PluginInfo.PSObject.Properties.Name -contains 'Name' -and $PluginInfo.Name) { $merged.name = [string]$PluginInfo.Name }
        if ($PluginInfo.PSObject.Properties.Name -contains 'SupportedLanguages' -and $null -ne $PluginInfo.SupportedLanguages) { $merged.supportedLanguages = @($PluginInfo.SupportedLanguages) }
        if ($PluginInfo.PSObject.Properties.Name -contains 'Priority') { try { $merged.priority = [int]$PluginInfo.Priority } catch { } }
    }
    return $merged
}

function Test-PluginCompatibility {
    [CmdletBinding()]
    param($Manifest, [PSCustomObject]$State = $null, [object[]]$KnownManifests = @())
    $reasons = [System.Collections.Generic.List[string]]::new()
    $check = Test-PluginManifest -Manifest $Manifest
    $valid = [bool]$check.Valid
    foreach ($errorText in @($check.Errors)) { [void]$reasons.Add('Manifest: ' + [string]$errorText) }
    $sdk = Get-PluginSdkConfig -State $State
    $name = if ($null -ne $Manifest -and $Manifest.PSObject.Properties.Name -contains 'name') { [string]$Manifest.name } else { '' }
    if (-not $sdk.Enabled) { return @{ Compatible = $false; Reasons = @('Plugin SDK disabled'); Manifest = $Manifest } }
    if ($sdk.Disabled -contains $name) { return @{ Compatible = $false; Reasons = @(('Plugin disabled: ' + $name)); Manifest = $Manifest } }
    if ($sdk.AllowList.Count -gt 0 -and $sdk.AllowList -notcontains $name) { return @{ Compatible = $false; Reasons = @(('Plugin not in allowList: ' + $name)); Manifest = $Manifest } }
    if ($sdk.RequireManifest -and ($null -eq $Manifest -or -not [bool]$Manifest.manifestFound)) { $valid = $false; [void]$reasons.Add('Manifest required') }
    $found = $null -ne $Manifest -and ($Manifest.PSObject.Properties.Name -contains 'manifestFound' -and [bool]$Manifest.manifestFound)
    $sdkVersion = ConvertTo-PluginVersion -Version (Get-PluginSdkApiVersion)
    $hasApi = $null -ne $Manifest -and $Manifest.PSObject.Properties.Name -contains 'apiVersion' -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.apiVersion)
    if ($hasApi) {
        $pluginVersion = ConvertTo-PluginVersion -Version ([string]$Manifest.apiVersion)
        if (-not $pluginVersion.Valid -or -not $sdkVersion.Valid) { $valid = $false; [void]$reasons.Add('API version is invalid') }
        elseif ($pluginVersion.Major -ne $sdkVersion.Major -or (Compare-PluginVersion -Left ([string]$Manifest.apiVersion) -Right (Get-PluginSdkApiVersion)) -gt 0) { $valid = $false; [void]$reasons.Add('Plugin API is incompatible') }
        elseif ($sdk.StrictApiCheck -and $pluginVersion.Minor -gt $sdkVersion.Minor) { $valid = $false; [void]$reasons.Add('Plugin API is newer') }
    } else { $valid = $false; [void]$reasons.Add('API version is required') }
    $toolVersion = ConvertTo-PluginVersion -Version (Get-GBuildToolVersion)
    if ($toolVersion.Valid -and $Manifest -and $Manifest.PSObject.Properties.Name -contains 'minGbuildVersion' -and $Manifest.minGbuildVersion -and (Compare-PluginVersion -Left (Get-GBuildToolVersion) -Right ([string]$Manifest.minGbuildVersion)) -lt 0) { $valid = $false; [void]$reasons.Add('gbuild version is below minimum') }
    if ($toolVersion.Valid -and $Manifest -and $Manifest.PSObject.Properties.Name -contains 'maxGbuildVersion' -and $Manifest.maxGbuildVersion -and (Compare-PluginVersion -Left (Get-GBuildToolVersion) -Right ([string]$Manifest.maxGbuildVersion)) -gt 0) { $valid = $false; [void]$reasons.Add('gbuild version is above maximum') }
    if ($Manifest -and $Manifest.PSObject.Properties.Name -contains 'version') { $pv = ConvertTo-PluginVersion -Version ([string]$Manifest.version); if ($pv.Valid -and $pv.Prerelease -and -not $sdk.AllowPrerelease) { $valid = $false; [void]$reasons.Add('Prerelease is disabled') } }
    if ($found -and @($Manifest.dependencies).Count -gt 0) {
        $known = @{}
        foreach ($item in @($KnownManifests)) { if ($item -and $item.PSObject.Properties.Name -contains 'name') { $known[[string]$item.name] = $item } }
        if ($known.Count -eq 0) {
            $pluginDirectory = Join-Path $PSScriptRoot 'Plugins'
            if (Test-Path -LiteralPath $pluginDirectory -PathType Container) {
                foreach ($file in @(Get-ChildItem -LiteralPath $pluginDirectory -Filter '*.psm1' -File -ErrorAction SilentlyContinue)) {
                    try { $candidate = Get-PluginManifest -PluginPath $file.FullName; if ($candidate -and $candidate.PSObject.Properties.Name -contains 'name') { $known[[string]$candidate.name] = $candidate } } catch { }
                }
            }
        }
        foreach ($dependency in @($Manifest.dependencies)) { $dependencyName = if ($dependency -is [string]) { [string]$dependency } else { [string]$dependency.name }; if ($dependencyName -and -not $known.ContainsKey($dependencyName)) { $valid = $false; [void]$reasons.Add('Missing dependency: ' + $dependencyName) } }
    }
    return @{ Compatible = $valid; Reasons = @($reasons); Manifest = $Manifest; Warnings = @($check.Warnings) }
}

function Resolve-PluginDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Manifests)
    $byName = @{}; $errors = [System.Collections.Generic.List[string]]::new(); $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($manifest in $Manifests) { if ($null -eq $manifest -or -not ($manifest.PSObject.Properties.Name -contains 'name')) { [void]$errors.Add('Manifest has no name'); continue }; $name = [string]$manifest.name; if ($byName.ContainsKey($name)) { [void]$errors.Add('Duplicate plugin: ' + $name) } else { $byName[$name] = $manifest } }
    $ordered = [System.Collections.Generic.List[object]]::new(); $visited = @{}; $visiting = @{}; $valid = $true
    $visit = {
        param([string]$Name)
        if ($visited.ContainsKey($Name)) { return $true }
        if ($visiting.ContainsKey($Name)) { [void]$errors.Add('Circular plugin dependency: ' + $Name); return $false }
        if (-not $byName.ContainsKey($Name)) { [void]$missing.Add($Name); return $false }
        $visiting[$Name] = $true; $node = $byName[$Name]
        foreach ($dependency in @($node.dependencies)) { $dependencyName = if ($dependency -is [string]) { [string]$dependency } elseif ($null -ne $dependency -and $dependency.PSObject.Properties.Name -contains 'name') { [string]$dependency.name } else { '' }; if (-not $dependencyName) { [void]$errors.Add('Malformed dependency'); continue }; if (-not $byName.ContainsKey($dependencyName)) { [void]$missing.Add($dependencyName); continue }; $constraint = if ($dependency -isnot [string] -and $dependency.PSObject.Properties.Name -contains 'version') { [string]$dependency.version } else { '' }; if ($constraint -and -not (Test-PluginVersionConstraint -Version ([string]$byName[$dependencyName].version) -Constraint $constraint)) { [void]$errors.Add('Dependency version mismatch: ' + $dependencyName) }; if (-not (& $visit $dependencyName)) { $valid = $false } }
        $visiting.Remove($Name); $visited[$Name] = $true; [void]$ordered.Add($node); return $true
    }
    foreach ($manifest in @($Manifests | Sort-Object @{Expression={try{[int]$_.priority}catch{5}}}, @{Expression={[string]$_.name}})) { $name = if ($manifest -and $manifest.PSObject.Properties.Name -contains 'name') { [string]$manifest.name } else { '' }; if ($name -and -not (& $visit $name)) { $valid = $false } }
    if ($errors.Count -gt 0 -or $missing.Count -gt 0) { $valid = $false }
    return @{ Ordered = @($ordered); Valid = $valid; Errors = @($errors); Missing = @($missing | Select-Object -Unique) }
}

Export-ModuleMember -Function @(
    'Get-PluginSdkApiVersion',
    'Get-GBuildToolVersion',
    'ConvertTo-PluginVersion',
    'Compare-PluginVersion',
    'Test-PluginVersionConstraint',
    'Get-PluginManifestPath',
    'Read-PluginManifestFile',
    'Test-PluginManifest',
    'Get-PluginManifest',
    'New-PluginManifestTemplate',
    'Get-PluginSdkConfig',
    'Test-PluginCompatibility',
    'Resolve-PluginDependencies'
)
