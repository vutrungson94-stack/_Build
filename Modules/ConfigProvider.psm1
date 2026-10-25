# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


$script:ConfigAliasMap = @{
    'build.enableParallel' = 'build.enableParallelBuild'
}

function Test-ConfigProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)

Set-StrictMode -Version 1.0
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.ContainsKey($Name) }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-ConfigProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-ConfigProperty -Object $Object -Name $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    return $Object.$Name
}

function Set-ConfigProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Remove-ConfigProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { $Object.Remove($Name) }
    } elseif ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Normalize-BuildAliases {
    param($BuildSection, [switch]$RemoveLegacy)
    if ($null -eq $BuildSection) { return $BuildSection }
    $hasCanonical = Test-ConfigProperty -Object $BuildSection -Name 'enableParallelBuild'
    $hasLegacy = Test-ConfigProperty -Object $BuildSection -Name 'enableParallel'
    if ($hasLegacy) {
        $legacyValue = Get-ConfigProperty -Object $BuildSection -Name 'enableParallel'
        if (-not $hasCanonical -or $null -eq (Get-ConfigProperty -Object $BuildSection -Name 'enableParallelBuild')) {
            Set-ConfigProperty -Object $BuildSection -Name 'enableParallelBuild' -Value $legacyValue
        }
        if ($RemoveLegacy) { Remove-ConfigProperty -Object $BuildSection -Name 'enableParallel' }
    }
    return $BuildSection
}

function Update-ConfigAliases {
    param($Config, [switch]$RemoveLegacy)
    if ($null -eq $Config) { return $Config }
    $build = Get-ConfigProperty -Object $Config -Name 'build'
    $null = Normalize-BuildAliases -BuildSection $build -RemoveLegacy:$RemoveLegacy
    $profiles = Get-ConfigProperty -Object $Config -Name 'profiles'
    if ($null -ne $profiles) {
        if ($profiles -is [System.Collections.IDictionary]) {
            foreach ($key in @($profiles.Keys)) { $null = Normalize-BuildAliases -BuildSection $profiles[$key] -RemoveLegacy:$RemoveLegacy }
        } else {
            foreach ($property in @($profiles.PSObject.Properties)) { $null = Normalize-BuildAliases -BuildSection $property.Value -RemoveLegacy:$RemoveLegacy }
        }
    }
    $tenancy = Get-ConfigProperty -Object $Config -Name 'tenancy'
    $overrides = Get-ConfigProperty -Object $tenancy -Name 'overrides'
    if ($null -ne $overrides) {
        if ($overrides -is [System.Collections.IDictionary]) {
            foreach ($key in @($overrides.Keys)) {
                $override = $overrides[$key]
                $null = Normalize-BuildAliases -BuildSection (Get-ConfigProperty -Object $override -Name 'build') -RemoveLegacy:$RemoveLegacy
            }
        } else {
            foreach ($property in @($overrides.PSObject.Properties)) {
                $null = Normalize-BuildAliases -BuildSection (Get-ConfigProperty -Object $property.Value -Name 'build') -RemoveLegacy:$RemoveLegacy
            }
        }
    }
    return $Config
}

function Resolve-ConfigAliasPath {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($legacy in $script:ConfigAliasMap.Keys) {
        if ($script:ConfigAliasMap[$legacy] -eq $Path) { return $legacy }
    }
    return $null
}

function Get-ConfigProjectMarkers {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    if (-not (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) -and -not (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue)) {
        $constantsPath = Join-Path $PSScriptRoot 'BuildConstants.psm1'
        if (Test-Path -LiteralPath $constantsPath -PathType Leaf) {
            Import-Module $constantsPath -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if (Get-Command Get-ProjectMarkers -ErrorAction SilentlyContinue) { return @(Get-ProjectMarkers -State $State) }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { return @(Get-BuildConstant -Key 'ProjectMarkers' -State $State -Fallback @()) }
    return @()
}

function Resolve-ConfigEnvironmentValue {
    param($Value, [PSCustomObject]$State = $null)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $overlay = $null
        if ($State -and (Test-ConfigProperty -Object $State -Name 'ConfigEnv')) { $overlay = $State.ConfigEnv }
        return [regex]::Replace([string]$Value, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
            param($match)
            $name = $match.Groups[1].Value
            $processValue = [Environment]::GetEnvironmentVariable($name)
            if ($null -ne $processValue) { return $processValue }
            if ($overlay -is [System.Collections.IDictionary] -and $overlay.ContainsKey($name)) { return [string]$overlay[$name] }
            return $match.Value
        })
    }
    if ($Value -is [System.Array]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(Resolve-ConfigEnvironmentValue -Value $item -State $State) }
        return ,$items
    }
    return $Value
}

function Enter-BuildConfigEnvironment {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $scope = [PSCustomObject]@{ Original = @{}; Keys = @() }
    if (-not $State -or -not (Test-ConfigProperty -Object $State -Name 'ConfigEnv')) { return $scope }
    $overlay = $State.ConfigEnv
    if ($overlay -isnot [System.Collections.IDictionary]) { return $scope }
    foreach ($key in @($overlay.Keys)) {
        $name = [string]$key
        $old = [Environment]::GetEnvironmentVariable($name)
        $scope.Original[$name] = $old
        if ($null -eq $old) {
            [Environment]::SetEnvironmentVariable($name, [string]$overlay[$name])
            $scope.Keys += $name
        }
    }
    return $scope
}

function Exit-BuildConfigEnvironment {
    [CmdletBinding()]
    param($Scope)
    if ($null -eq $Scope -or $null -eq $Scope.Original) { return }
    foreach ($name in @($Scope.Original.Keys)) {
        $old = $Scope.Original[$name]
        if ($null -eq $old) { Remove-Item -LiteralPath ("Env:\" + [string]$name) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable([string]$name, [string]$old) }
    }
}

# NOTE: intentionally NO ModuleBootstrap import here. ConfigProvider is a
# cross-cutting config helper loaded globally via BuildImport / Import-BuildDependencies
# so every module and test harness can resolve Get-ConfigValue. Its only external
# calls (Get-BuildState / Write-Log) are already guarded with Get-Command at runtime,
# so the module is safe standalone. Importing ModuleBootstrap here would create a
# ConfigProvider -> ModuleBootstrap -> BuildImport -> ConfigProvider import cycle.


<#
.SYNOPSIS
    Single-source tree-walk used by every config accessor (Get-ConfigValue,
    Resolve-ConfigValue, Get-ConfigSection) so the path-resolution logic lives
    in exactly one place. Supports both PSCustomObject and IDictionary nodes.
.PARAMETER Root
    The object to walk (e.g. $State.BuildConfig or $State directly).
.PARAMETER Path
    Dot-separated config path (e.g. 'build.maxParallelJobs').
.OUTPUTS
    The resolved node, or $null if any segment is missing.
#>
function Find-ConfigNode {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $Root,
        [Parameter(Mandatory)][string]$Path
    )
    if ($null -eq $Root) { return $null }
    $segments = $Path -split '\.'
    $current = $Root
    foreach ($seg in $segments) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $null }
        } elseif ($null -ne $current.PSObject -and ($current.PSObject.Properties.Name -contains $seg)) {
            $current = $current.$seg
        } else { return $null }
    }
    return $current
}

function Get-ConfigValue {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [PSCustomObject]$State,
        $Default = $null,
        [string]$Type,
        [switch]$ResolveEnv
    )
    $effectiveState = $State
    if (-not $effectiveState -and (Get-Command Get-BuildState -ErrorAction SilentlyContinue)) {
        $effectiveState = Get-BuildState -State $State
    }
    $cfg = $null
    if ($effectiveState -and $effectiveState.BuildConfig) { $cfg = $effectiveState.BuildConfig }
    if (-not $cfg) { return $Default }

    $val = Find-ConfigNode -Root $cfg -Path $Path
    if ($null -eq $val) {
        $legacyPath = Resolve-ConfigAliasPath -Path $Path
        if ($legacyPath) { $val = Find-ConfigNode -Root $cfg -Path $legacyPath }
    }
    if ($null -eq $val -and $script:ConfigAliasMap.ContainsKey($Path)) {
        $val = Find-ConfigNode -Root $cfg -Path $script:ConfigAliasMap[$Path]
    }
    if ($null -eq $val) { return $Default }

    if ($ResolveEnv) {
        $val = Resolve-ConfigEnvironmentValue -Value $val -State $effectiveState
    }
    # Single owner for coercion. This switch was a verbatim second copy of
    # ConvertTo-TargetType in the same file, so the bool vocabulary
    # (false/0/no/off/disabled vs true/1/yes/on/enabled) existed twice and the two
    # copies could disagree.
    if ($Type) { return (ConvertTo-TargetType -Value $val -Type $Type) }
    return $val
}

function Merge-ConfigSources {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$BasePath, [string[]]$OverridePaths, [PSCustomObject]$State)
    if (-not (Test-Path -LiteralPath $BasePath -PathType Leaf)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.config.baseNotFound' -Fallback 'Base config not found') 'Warn' $State }
        return New-ConfigStub
    }
    $merged = Get-Content $BasePath -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop
    $merged = Update-ConfigAliases -Config $merged
    $seen = @{}
    try { $seen[[System.IO.Path]::GetFullPath($BasePath).ToLowerInvariant()] = $true } catch { }
    foreach ($ovPath in $OverridePaths) {
        if (-not $ovPath -or -not (Test-Path -LiteralPath $ovPath -PathType Leaf)) { continue }
        $key = $null
        try { $key = [System.IO.Path]::GetFullPath($ovPath).ToLowerInvariant() } catch { $key = [string]$ovPath }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        try {
            $ov = Get-Content $ovPath -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop
            $ov = Update-ConfigAliases -Config $ov
            $merged = Merge-ConfigObject $merged $ov
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.config.badOverrideSkipped' -MessageArgs @([string]$ovPath) -Fallback 'Skip bad override: {0}') 'Warn' $State }
        }
    }
    return (Update-ConfigAliases -Config $merged -RemoveLegacy)
}

function Get-ConfigEnvironmentFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$BasePath,
        [string[]]$OverridePaths = @(),
        [string]$ProjectRoot = '',
        [string]$ScriptRoot = '',
        [PSCustomObject]$State = $null
    )
    $cfg = $null
    try { $cfg = Merge-ConfigSources -BasePath $BasePath -OverridePaths $OverridePaths -State $State } catch { $cfg = $null }
    $build = Get-ConfigProperty -Object $cfg -Name 'build'
    $configured = [string](Get-ConfigProperty -Object $build -Name 'envFile')
    $root = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) { $root = $ScriptRoot }
        elseif (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { $root = Get-BuildRootDirectory -State $State }
        else { $root = Split-Path $PSScriptRoot -Parent }
    }
    # The .env discovery root decides which secrets file is loaded into the process
    # environment. It must never be the process CWD: an attacker-planted .env in
    # the launch directory would otherwise be read and injected. The chain above
    # ends at the tool root, never at Get-Location.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.Path]::IsPathRooted($configured)) { $candidates += $configured }
        else { $candidates += (Join-Path $root $configured) }
    } else {
        $candidates += (Join-Path $root '.env')
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -match '\$\{env:') { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            if (-not [System.IO.Path]::IsPathRooted($configured) -and -not [string]::IsNullOrWhiteSpace($configured)) {
                $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
                $sep = [System.IO.Path]::DirectorySeparatorChar
                # Containment guard for a config-supplied env-file path. The
                # comparison follows the host filesystem: OrdinalIgnoreCase here
                # would let a relative-path config on a case-sensitive volume
                # escape the root (root /repo/app, file /repo/App/.env matches
                # case-insensitively but is a different directory entirely).
                $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
                       else { if ((Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost)) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
                if (-not (($full -eq $rootFull) -or $full.StartsWith($rootFull + $sep, $cmp))) { continue }
            }
            return $full
        } catch { }
    }
    return ''
}

function Read-ConfigEnvironmentFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    if (Get-Command Read-DotEnvFile -ErrorAction SilentlyContinue) {
        $loaded = Read-DotEnvFile -Path $Path
        foreach ($key in @($loaded.Keys)) { $result[[string]$key] = [string]$loaded[$key] }
        return $result
    }
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $text = ([string]$line).Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -match '^export\s+(.+)$') { $text = $Matches[1].Trim() }
        $eq = $text.IndexOf('=')
        if ($eq -le 0) { continue }
        $key = $text.Substring(0, $eq).Trim()
        $value = $text.Substring($eq + 1).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        if ($value.Length -ge 2 -and ((($value.StartsWith('"')) -and ($value.EndsWith('"'))) -or (($value.StartsWith("'")) -and ($value.EndsWith("'"))))) { $value = $value.Substring(1, $value.Length - 2) }
        $result[$key] = $value
    }
    return $result
}

function Set-ConfigEnvironmentOverlay {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Path = '')
    $overlay = @{}
    if ($Path) {
        $loaded = Read-ConfigEnvironmentFile -Path $Path
        foreach ($key in @($loaded.Keys)) { $overlay[[string]$key] = [string]$loaded[$key] }
    }
    if ($State) {
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'ConfigEnv' -Value $overlay -Force
            Set-BuildStateProperty -State $State -Name 'ConfigEnvFile' -Value ([string]$Path) -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name ConfigEnv -Value $overlay -Force
            $State | Add-Member -MemberType NoteProperty -Name ConfigEnvFile -Value ([string]$Path) -Force
        }
    }
    return $overlay
}

<#
.SYNOPSIS
    Loads gbuild.config.json into the live build State before any config consumer runs.
.DESCRIPTION
    Single canonical config loader for production Start-GBuild flows. The shipped
    _Build/gbuild.config.json is the base config; a project-local gbuild.config.json
    is an optional deep-merged override. The loader stamps both ConfigPath and
    BuildConfig, so Build.psm1, Menu.psm1, Orchestrator.psm1 and tests all consume
    the same effective config object instead of silently seeing $null.
.PARAMETER State
    Live state object carrying ScriptRoot and optional ProjectRoot.
#>
function Initialize-BuildConfigState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([PSCustomObject]$State)
    if (-not $State) { return New-ConfigStub }

    $scriptRoot = ''
    if ($State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { $scriptRoot = [string]$State.ScriptRoot }
    if (-not $scriptRoot -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $scriptRoot = [string]$State.ProjectRoot }
    # The whole config layer must never be sourced from a foreign gbuild.config.json
    # sitting in the launch directory. Final fallback is the tool root (where the
    # shipped config lives), never the CWD.
    if (-not $scriptRoot) { $scriptRoot = Split-Path $PSScriptRoot -Parent }
    $basePath = Join-Path $scriptRoot 'gbuild.config.json'

    $overrides = @()
    $projectRoot = ''
    if ($State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $projectRoot = [string]$State.ProjectRoot }
    if ($projectRoot) {
        $projectConfig = Join-Path $projectRoot 'gbuild.config.json'
        if ($projectConfig -ne $basePath -and (Test-Path -LiteralPath $projectConfig -PathType Leaf)) {
            $overrides += $projectConfig
        }
    }

    $hasBase = Test-Path -LiteralPath $basePath -PathType Leaf
    if (-not $hasBase -and $overrides.Count -gt 0) {
        $basePath = $overrides[0]
        $overrides = @()
        $hasBase = $true
    }

    $envPath = ''
    if ($hasBase) {
        $envPath = Get-ConfigEnvironmentFile -BasePath $basePath -OverridePaths $overrides -ProjectRoot $projectRoot -ScriptRoot $scriptRoot -State $State
    }
    $null = Set-ConfigEnvironmentOverlay -State $State -Path $envPath

    if (-not $hasBase) {
        $cfg = New-ConfigStub
        $schemaPath = Join-Path $scriptRoot 'gbuild.config.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { $schemaPath = [System.IO.Path]::ChangeExtension($basePath, '.schema.json') }
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'ConfigPath' -Value $basePath -Force
            Set-BuildStateProperty -State $State -Name 'ConfigSchemaPath' -Value $schemaPath -Force
            Set-BuildStateProperty -State $State -Name 'BuildConfig' -Value $cfg -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name 'ConfigPath' -Value $basePath -Force -ErrorAction SilentlyContinue
            $State | Add-Member -MemberType NoteProperty -Name 'ConfigSchemaPath' -Value $schemaPath -Force -ErrorAction SilentlyContinue
            $State | Add-Member -MemberType NoteProperty -Name 'BuildConfig' -Value $cfg -Force -ErrorAction SilentlyContinue
        }
        return $cfg
    }

    $cfg = Merge-ConfigSources -BasePath $basePath -OverridePaths $overrides -State $State
    $cfg = Update-ConfigAliases -Config $cfg -RemoveLegacy
    # DECRYPT SECRETS AT CONFIG-LOAD TIME. CredentialVault shipped the whole
    # pipeline for this - Resolve-ConfigSecrets walks the tree and Resolve-SecretValue
    # unwraps an `enca:`/`encv:` ciphertext (and ${env:} placeholders) - but nothing
    # ever called it, so a vaulted credential written into gbuild.config.json was
    # handed to every consumer as its own literal ciphertext. Sealing a secret was
    # therefore a one-way operation that silently broke the value it protected.
    # Resolution is best-effort by design: a value that cannot be decrypted (no key
    # file on this machine, wrong tenant, corrupted blob) is left EXACTLY as written
    # so the consumer reports the real "not configured" error instead of the tree
    # walk throwing and taking the whole build down.
    if ($null -ne $cfg -and (Get-Command Resolve-ConfigSecrets -ErrorAction SilentlyContinue)) {
        try {
            $resolvedCfg = Resolve-ConfigSecrets -Node $cfg -State $State
            if ($null -ne $resolvedCfg) { $cfg = $resolvedCfg }
        } catch { }
    }
    $configPath = $basePath
    if ($overrides.Count -gt 0) { $configPath = $overrides[$overrides.Count - 1] }
    $schemaPath = Join-Path $scriptRoot 'gbuild.config.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { $schemaPath = [System.IO.Path]::ChangeExtension($basePath, '.schema.json') }
    if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
        Set-BuildStateProperty -State $State -Name 'ConfigPath' -Value $configPath -Force
        Set-BuildStateProperty -State $State -Name 'ConfigSchemaPath' -Value $schemaPath -Force
        Set-BuildStateProperty -State $State -Name 'BuildConfig' -Value $cfg -Force
    } else {
        $State | Add-Member -MemberType NoteProperty -Name 'ConfigPath' -Value $configPath -Force -ErrorAction SilentlyContinue
        $State | Add-Member -MemberType NoteProperty -Name 'ConfigSchemaPath' -Value $schemaPath -Force -ErrorAction SilentlyContinue
        $State | Add-Member -MemberType NoteProperty -Name 'BuildConfig' -Value $cfg -Force -ErrorAction SilentlyContinue
    }
    return $cfg
}

function Merge-ConfigObject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Base, $Override)
    if (-not $Base) { return $Override }
    if (-not $Override) { return $Base }

    function ConvertTo-ConfigObject {
        param($InputObject)
        if ($InputObject -is [System.Array]) {
            return ,$InputObject
        }
        if ($InputObject -is [pscustomobject]) {
            $result = [pscustomobject]@{}
            foreach ($p in $InputObject.PSObject.Properties) {
                $result | Add-Member -MemberType NoteProperty -Name $p.Name -Value (ConvertTo-ConfigObject $p.Value) -Force
            }
            return $result
        }
        # IDictionary (not just [hashtable]) so ordered/other dictionaries are
        # treated as config nodes too. Checking [hashtable] alone exploded an
        # [ordered]@{} into Count/Keys/Values/... and silently dropped its data.
        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = [pscustomobject]@{}
            foreach ($k in @($InputObject.Keys)) {
                $result | Add-Member -MemberType NoteProperty -Name $k -Value (ConvertTo-ConfigObject $InputObject[$k]) -Force
            }
            return $result
        }
        return $InputObject
    }

    $Base = ConvertTo-ConfigObject $Base
    $Override = ConvertTo-ConfigObject $Override

    $result = [pscustomobject]@{}
    $seen = @{}
    foreach ($p in $Base.PSObject.Properties) {
        $result | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        $seen[$p.Name] = $true
    }
    foreach ($p in $Override.PSObject.Properties) {
        if ($seen.Contains($p.Name) -and $p.Value -is [pscustomobject] -and $result.($p.Name) -is [pscustomobject]) {
            $result.($p.Name) = Merge-ConfigObject $result.($p.Name) $p.Value
        } else {
            $result | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        }
        $seen[$p.Name] = $true
    }
    return $result
}

<#
.SYNOPSIS
    Deep-merges tenancy.overrides.<tenantId> over the effective config.
.DESCRIPTION
    Per-tenant config overlay without editing the base config. Example:
        "tenancy": { "overrides": { "acme": { "build": { "maxParallelJobs": 1 } } } }
    The 'acme' tenant then runs with build.maxParallelJobs = 1 while the
    'default' tenant (and tenants without an override) keep the base config.
    Accepts both PSCustomObject and hashtable config trees.
.PARAMETER Config
    The merged (base + project-local) config tree.
.PARAMETER State
    Build state carrying TenantId (set by Initialize-BuildIdentity).
#>
function Merge-ConfigTenantOverride {
    [CmdletBinding()]
    param($Config, [PSCustomObject]$State)
    if ($null -eq $Config -or $null -eq $State) { return $Config }
    $tenant = $null
    if ($State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { $tenant = [string]$State.TenantId }
    if (-not $tenant -or $tenant -eq 'default') { return $Config }

    $tenancy = $null
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.ContainsKey('tenancy')) { $tenancy = $Config['tenancy'] }
    } elseif ($Config.PSObject.Properties.Name -contains 'tenancy') {
        $tenancy = $Config.tenancy
    }
    if ($null -eq $tenancy) { return $Config }

    $overrides = $null
    if ($tenancy -is [System.Collections.IDictionary]) {
        if ($tenancy.ContainsKey('overrides')) { $overrides = $tenancy['overrides'] }
    } elseif ($tenancy.PSObject.Properties.Name -contains 'overrides') {
        $overrides = $tenancy.overrides
    }
    if ($null -eq $overrides) { return $Config }

    $override = $null
    if ($overrides -is [System.Collections.IDictionary]) {
        if ($overrides.ContainsKey($tenant)) { $override = $overrides[$tenant] }
    } elseif ($overrides.PSObject.Properties.Name -contains $tenant) {
        $override = $overrides.$tenant
    }
    if ($null -eq $override) { return $Config }

    $merged = Merge-ConfigObject $Config $override
    return (Update-ConfigAliases -Config $merged -RemoveLegacy)
}

function New-ConfigStub {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return [pscustomobject]@{
        version = '0.0.0'
        build = [pscustomobject]@{ defaultConfiguration = 'Release' }
        logging = [pscustomobject]@{}
        health = [pscustomobject]@{}
        projects = [pscustomobject]@{}
    }
}

<#
.SYNOPSIS
    Extracts one property from a config section that may be a Hashtable OR a
    PSCustomObject (the IDictionary/PSCustomObject duality).
.DESCRIPTION
    Single implementation of the 5-line accessor idiom that was hand-rolled
    ~15 times across Siem/Policy/Standalone/Sast/SupplyChain. Returns $Default
    when the section is $null or the key is absent.
#>
function Get-SectionValue {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $Section,
        [Parameter(Mandatory)][string]$Key,
        [object]$Default = $null
    )
    if ($null -eq $Section) { return $Default }
    if ($Section -is [System.Collections.IDictionary]) {
        # `.Contains` (not `.ContainsKey`) so OrderedDictionary works - hashtables
        # implement both, OrderedDictionary only `.Contains`. The previous
        # `.ContainsKey` call threw MethodNotFound on an ordered override.
        if ($Section.Contains($Key)) { return $Section[$Key] }
        # Case-insensitive fallback. The PSCustomObject branch below is already
        # case-insensitive (`-contains`), and 8 module-local helpers delegated
        # here expecting case-insensitive dictionary lookup, so an ordinal
        # IDictionary miss silently returned the default instead of the
        # configured value.
        foreach ($dictKey in $Section.Keys) {
            if ([string]$dictKey -ieq $Key) { return $Section[$dictKey] }
        }
        return $Default
    }
    if ($Section.PSObject.Properties.Name -contains $Key) { return $Section.$Key }
    return $Default
}

# Internal helper for type conversion
function ConvertTo-TargetType {
    param($Value, [string]$Type)
    switch ($Type) {
        'int' { return [int]$Value }
        'bool' {
            if ($Value -is [string]) {
                if ($Value.Trim().ToLowerInvariant() -in @('false','0','no','off','disabled')) { return $false }
                if ($Value.Trim().ToLowerInvariant() -in @('true','1','yes','on','enabled')) { return $true }
            }
            return [bool]$Value
        }
        'string' { return [string]$Value }
        'array' { return @($Value) }
        default { return $Value }
    }
}

function Test-BuildConfigSchemaObject {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Instance,
        [Parameter(Mandatory)][AllowNull()]$Schema,
        [string]$Path = '$',
        [int]$MaxErrors = 50
    )
    # A real JSON-Schema subset validator, and the OWNER of config shape.
    #
    # Why it exists: Orchestrator.psm1's Test-BuildConfig fell back to
    #   Get-Command Test-JsonSchema
    # which is not a PowerShell cmdlet and was not defined anywhere in this
    # repository, so that 20-line branch was unreachable on every host. On
    # Windows PowerShell 5.1 - which has no Test-Json either - validation
    # therefore degraded to Test-ConfigSchema, which checks FIVE top-level
    # property names. A config with a wrong type, a bad enum member or an
    # undeclared key under `security.` validated clean on 5.1 and failed on
    # 7.x: the same file, two verdicts, selected by which shell ran it.
    #
    # Deliberately a SUBSET, and this is the whole feature set
    # gbuild.config.schema.json actually uses:
    #   type (string or array), properties, additionalProperties, required,
    #   enum, const, minimum, maximum, minLength, pattern, items, not
    # There is no $ref / $defs / definitions / oneOf / anyOf / allOf / if-then
    # in the shipped schema (verified), and no combinator support means no
    # combinator can be used without this function being extended first -
    # which is the intended failure mode: an unknown keyword must not silently
    # pass. Unknown keywords are reported rather than ignored.
    $errs = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Schema) { return $errs }
    if ($null -eq $Instance) {
        # A null Instance satisfies only a schema whose type admits "null".
        if ($Schema.PSObject.Properties.Name -contains 'type') {
            $t = $Schema.type
            $admits = $false
            if ($t -is [array]) { $admits = (@($t) | Where-Object { [string]$_ -eq 'null' }).Count -gt 0 }
            elseif ([string]$t -eq 'null') { $admits = $true }
            if (-not $admits) { $errs.Add("$Path : expected $($Schema.type) but found null") }
        }
        return $errs
    }

    # Every keyword gbuild.config.schema.json actually uses, enumerated by
    # walking the parsed schema rather than by grepping for names. Annotations
    # carry no validation semantics; everything else must be implemented below.
    # A keyword that is neither implemented nor annotated is REPORTED, never
    # ignored: silently skipping a constraint is how a "validated" config stops
    # being validated without anybody editing a line.
    $annotations = @('$schema','$id','title','description','default','$comment','examples')
    $keywords    = @('type','properties','additionalProperties','required','enum','const',
                     'minimum','maximum','exclusiveMinimum','exclusiveMaximum',
                     'minLength','maxLength','pattern','items','not',
                     'patternProperties','uniqueItems')

    # --- type ---------------------------------------------------------------
    if ($Schema.PSObject.Properties.Name -contains 'type') {
        $declared = @()
        if ($Schema.type -is [array]) { $declared = @($Schema.type | ForEach-Object { [string]$_ }) }
        else { $declared = @([string]$Schema.type) }
        $ok = $false
        foreach ($t in $declared) {
            switch ($t) {
                'object'  { if ($Instance -is [psobject] -and $Instance -isnot [string] -and $Instance.PSObject.Properties -and -not ($Instance -is [System.Collections.IEnumerable])) { $ok = $true } }
                'array'   { if ($Instance -is [System.Collections.IEnumerable] -and $Instance -isnot [string]) { $ok = $true } }
                'string'  { if ($Instance -is [string]) { $ok = $true } }
                'boolean' { if ($Instance -is [bool]) { $ok = $true } }
                'null'    { if ($null -eq $Instance) { $ok = $true } }
                'integer' { if ($Instance -is [int] -or $Instance -is [long] -or $Instance -is [Int16] -or $Instance -is [byte]) { $ok = $true }
                            elseif ($Instance -is [double] -or $Instance -is [decimal]) { if ([Math]::Floor([double]$Instance) -eq [double]$Instance) { $ok = $true } } }
                'number'  { if ($Instance -is [int] -or $Instance -is [long] -or $Instance -is [double] -or $Instance -is [decimal] -or $Instance -is [Int16] -or $Instance -is [byte]) { $ok = $true } }
            }
            if ($ok) { break }
        }
        if (-not $ok) {
            $actual = if ($Instance -is [bool]) { 'boolean' } elseif ($Instance -is [string]) { 'string' }
                      elseif ($Instance -is [int] -or $Instance -is [long] -or $Instance -is [Int16] -or $Instance -is [byte]) { 'integer' }
                      elseif ($Instance -is [double] -or $Instance -is [decimal]) { 'number' }
                      elseif ($Instance -is [System.Collections.IEnumerable]) { 'array' } else { 'object' }
            $errs.Add("$Path : Value is '$actual' but should be '$(@($declared) -join '|')'")
            return $errs
        }
    }

    # --- enum / const -------------------------------------------------------
    if ($Schema.PSObject.Properties.Name -contains 'enum') {
        $hit = $false
        foreach ($e in @($Schema.enum)) { if ([string]$e -eq [string]$Instance) { $hit = $true; break } }
        if (-not $hit) { $errs.Add("$Path : value '$Instance' is not one of: " + ((@($Schema.enum) | ForEach-Object { [string]$_ }) -join ', ')) }
    }
    if ($Schema.PSObject.Properties.Name -contains 'const') {
        if ([string]$Schema.const -ne [string]$Instance) { $errs.Add("$Path : value must be '$($Schema.const)'") }
    }

    # --- numeric bounds -----------------------------------------------------
    foreach ($pair in @(@('minimum',$true), @('maximum',$false))) {
        $kw = $pair[0]; $isMin = $pair[1]
        if ($Schema.PSObject.Properties.Name -contains $kw) {
            $inst = $null
            $isNum = $Instance -is [int] -or $Instance -is [long] -or $Instance -is [double] -or $Instance -is [decimal] -or $Instance -is [Int16] -or $Instance -is [byte]
            if ($isNum) { $inst = [double]$Instance }
            if ($null -ne $inst) {
                $bound = [double]$Schema.$kw
                if ($isMin -and $inst -lt $bound) { $errs.Add("$Path : value $inst is less than the minimum of $bound") }
                if (-not $isMin -and $inst -gt $bound) { $errs.Add("$Path : value $inst is greater than the maximum of $bound") }
            }
        }
    }

    # --- string constraints -------------------------------------------------
    if ($Instance -is [string]) {
        $sv = [string]$Instance
        if ($Schema.PSObject.Properties.Name -contains 'minLength') { if ($sv.Length -lt [int]$Schema.minLength) { $errs.Add("$Path : string is shorter than minLength $($Schema.minLength)") } }
        if ($Schema.PSObject.Properties.Name -contains 'maxLength') { if ($sv.Length -gt [int]$Schema.maxLength) { $errs.Add("$Path : string is longer than maxLength $($Schema.maxLength)") } }
        if ($Schema.PSObject.Properties.Name -contains 'pattern') {
            try { if ($sv -notmatch [string]$Schema.pattern) { $errs.Add("$Path : string does not match pattern $($Schema.pattern)") } } catch { }
        }
    }

    # --- not ----------------------------------------------------------------
    if ($Schema.PSObject.Properties.Name -contains 'not') {
        $inner = Test-BuildConfigSchemaObject -Instance $Instance -Schema $Schema.not -Path ($Path + '!') -MaxErrors 1
        if ($inner.Count -eq 0) { $errs.Add("$Path : value is disallowed by 'not'") }
    }

    # --- object -------------------------------------------------------------
    $isObj = ($Instance -is [psobject]) -and ($Instance -isnot [string]) -and ($Instance -isnot [System.Collections.IEnumerable])
    if ($isObj) {
        $present = @($Instance.PSObject.Properties | ForEach-Object { $_.Name })

        if ($Schema.PSObject.Properties.Name -contains 'required') {
            foreach ($r in @($Schema.required)) {
                if ($present -notcontains [string]$r) { $errs.Add("$Path : Required properties ['$r'] are not present") }
            }
        }

        $props = $null
        if ($Schema.PSObject.Properties.Name -contains 'properties') { $props = $Schema.properties }

        $ap = $true
        if ($Schema.PSObject.Properties.Name -contains 'additionalProperties') {
            if ($Schema.additionalProperties -is [bool]) { $ap = [bool]$Schema.additionalProperties }
            else { $ap = $true }
        }

        $patterns = $null
        if ($Schema.PSObject.Properties.Name -contains 'patternProperties') { $patterns = $Schema.patternProperties }

        foreach ($p in $present) {
            $sub = $null
            if ($props -and $props.PSObject.Properties.Name -contains $p) { $sub = $props.$p }

            # patternProperties: "any key matching this regex validates against
            # this subschema". This is how security.rbac.roles / .resources are
            # expressed - an open map of role names, each constrained to the same
            # object shape. Before this existed the validator reported them as
            # an unimplemented keyword, which is how the gap was found.
            if ($null -eq $sub -and $patterns) {
                $matched = $false
                foreach ($pe in @($patterns.PSObject.Properties)) {
                    try { if ($p -match ('^(?:' + [string]$pe.Name + ')$')) { $matched = $true } } catch { }
                    if ($matched) { break }
                }
                if ($matched) {
                    foreach ($pe in @($patterns.PSObject.Properties)) {
                        try { $hit = ($p -match ('^(?:' + [string]$pe.Name + ')$')) } catch { $hit = $false }
                        if (-not $hit) { continue }
                        foreach ($e in (Test-BuildConfigSchemaObject -Instance $Instance.$p -Schema $pe.Value -Path "$Path/$p" -MaxErrors $MaxErrors)) {
                            $errs.Add($e)
                        }
                        break
                    }
                    continue
                }
            }

            if ($null -eq $sub) {
                if (-not $ap) { $errs.Add("$Path/$p : property is not declared and additionalProperties is false") }
                elseif ($null -ne $Schema.additionalProperties -and -not ($Schema.additionalProperties -is [bool])) {
                    # An `additionalProperties` SUBSCHEMA is how an open map gets its
                    # shape: the node has no `properties` sibling (that is the whole
                    # point of the pattern), so `$props` is $null here. Gating this
                    # branch on `$props` therefore silently skipped the subschema for
                    # every additionalProperties-only node in the schema - profiles,
                    # build.menu.moduleMap, build.projectTypeActions,
                    # build.cacheArtifactPatterns, build.cleanTargetsPerProjectType,
                    # security.sast.tools, deploy.environments, alerting.headers, ...
                    # Those sections validated nothing and Test-BuildConfig still
                    # reported "valid". The subschema must apply whether or not a
                    # sibling `properties` block exists.
                    foreach ($e in (Test-BuildConfigSchemaObject -Instance $Instance.$p -Schema $Schema.additionalProperties -Path "$Path/$p" -MaxErrors 3)) { $errs.Add($e) }
                }
                continue
            }
            foreach ($e in (Test-BuildConfigSchemaObject -Instance $Instance.$p -Schema $sub -Path "$Path/$p" -MaxErrors $MaxErrors)) {
                $errs.Add($e)
                if ($errs.Count -ge $MaxErrors) { return $errs }
            }
        }

        foreach ($n in @($Schema.PSObject.Properties.Name)) {
            if ($keywords -contains $n) { continue }
            if ($annotations -contains $n) { continue }
            if ($n.StartsWith('$')) { continue }
            $errs.Add("$Path : schema uses keyword '$n' which this validator does not implement (add it before using it)")
        }
    }

    # --- array --------------------------------------------------------------
    if ($Instance -is [System.Collections.IEnumerable] -and $Instance -isnot [string]) {
        if ($Schema.PSObject.Properties.Name -contains 'uniqueItems') {
            if ($Schema.uniqueItems -eq $true) {
                $seenVals = [System.Collections.Generic.HashSet[string]]::new()
                $dup = $null
                foreach ($item in $Instance) {
                    $sig = if ($item -is [psobject] -and -not ($item -is [string])) { ($item | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } else { 20 }) -Compress -EA SilentlyContinue) } else { [string]$item }
                    if ($null -eq $sig) { $sig = [string]$item }
                    if (-not $seenVals.Add([string]$sig)) { $dup = $sig; break }
                }
                if ($null -ne $dup) { $errs.Add("$Path : items must be unique, but '$dup' appears more than once") }
            }
        }
        if ($Schema.PSObject.Properties.Name -contains 'items') {
            $i = 0
            foreach ($item in $Instance) {
                foreach ($e in (Test-BuildConfigSchemaObject -Instance $item -Schema $Schema.items -Path ("$Path[$i]") -MaxErrors $MaxErrors)) {
                    $errs.Add($e)
                    if ($errs.Count -ge $MaxErrors) { return $errs }
                }
                $i++
            }
        }
    }

    return $errs
}

function Test-BuildConfigSchema {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Instance,
        [Parameter(Mandatory)][AllowNull()]$Schema,
        [switch]$Strict
    )
    # Single owner. Test-ConfigSchema below delegates here, and
    # Orchestrator.Test-BuildConfig calls this directly, so the 5.1 path and the
    # 7.x path (Test-Json -Schema) are now backed by the SAME vocabulary
    # instead of "five property names" on one host and full validation on the
    # other.
    $errs = @(Test-BuildConfigSchemaObject -Instance $Instance -Schema $Schema)
    if ($errs.Count -eq 0) { return $true }
    $msg = 'Config schema validation failed (' + $errs.Count + '): ' + (($errs | Select-Object -First 10) -join ' | ')
    if ($Strict) { throw $msg }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $msg 'Warn' $null }
    return $false
}

function Test-ConfigSchema {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State, [switch]$Strict)
    if (-not $State -or -not $State.BuildConfig) {
        if ($Strict) { throw (Resolve-LogMessage -Key 'log.configprovider.line911' -Fallback 'BuildConfig not loaded') }
        return $false
    }
    # Two tiers, strongest available wins.
    #
    # Tier 1 (the real one): validate against gbuild.config.schema.json using
    # Test-BuildConfigSchema, the subset validator that also backs the pwsh 7
    # path. This function used to check FIVE top-level property names and
    # nothing else, so a wrong type, a bad enum member or an undeclared key
    # anywhere in a 35-section config reported "valid". It is the structural
    # fallback for hosts without Test-Json, so a weak fallback was the one place
    # weakness was least acceptable.
    #
    # Tier 2: no schema file is reachable at all (a detached State, a partial
    # install). Keep the original structural contract here rather than failing
    # closed on it - this is the documented degrade path and callers depend on
    # it. It is explicitly the weaker of the two, and the tier that reaches it
    # says so out loud.
    $schemaPath = ''
    if ($State.PSObject.Properties.Name -contains 'ConfigSchemaPath' -and $State.ConfigSchemaPath) {
        $schemaPath = [string]$State.ConfigSchemaPath
    } elseif ($State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) {
        $p = Join-Path $State.ScriptRoot 'gbuild.config.schema.json'
        if (Test-Path -LiteralPath $p -PathType Leaf) { $schemaPath = $p }
    }
    $schema = $null
    if ($schemaPath) {
        try { $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop } catch { $schema = $null }
    }
    if ($null -ne $schema) {
        return Test-BuildConfigSchema -Instance $State.BuildConfig -Schema $schema -Strict:$Strict
    }

    if ($Strict) { throw (Resolve-LogMessage -Key 'log.configprovider.line944' -Fallback 'gbuild.config.schema.json not reachable; cannot validate config against its schema') }
    $cfg = $State.BuildConfig
    $valid = $true
    $errs = @()
    foreach ($key in @('version', 'build', 'logging', 'health', 'projects')) {
        if (-not ($cfg.PSObject.Properties.Name -contains $key)) {
            $errs += "Missing required property: $key"
            $valid = $false
        }
    }
    if ($errs.Count -gt 0) {
        $msg = 'Config validation (structural only - schema not reachable: ' + $errs.Count + ' issue(s)): ' + ($errs -join '; ')
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $msg 'Warn' $State }
    }
    return $valid
}

Export-ModuleMember -Function @(
    'Get-ConfigValue',
    'Find-ConfigNode',
    'Merge-ConfigSources',
    'Initialize-BuildConfigState',
    'Merge-ConfigObject',
    'Merge-ConfigTenantOverride',
    'New-ConfigStub',
    'Test-ConfigSchema',
    'Test-BuildConfigSchema',
    'Get-SectionValue',
    'Update-ConfigAliases',
    'Get-ConfigProjectMarkers',
    'Resolve-ConfigEnvironmentValue',
    'Enter-BuildConfigEnvironment',
    'Exit-BuildConfigEnvironment',
    'Get-ConfigEnvironmentFile',
    'Read-ConfigEnvironmentFile'
)




