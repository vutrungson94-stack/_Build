Set-StrictMode -Version 1.0
# ============================================================================
# Orchestrator.Config.ps1 - config helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Initialize-BuildConfigAndProfile {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $strictValidation = Resolve-ConfigValue -State $State -Path 'health.failOnInvalidConfig' -Default $false
    $warnEv = $false
    if ($State.BuildConfig) {
        try {
            $configValid = Test-BuildConfig -State $State -Strict:$strictValidation
        } catch {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m54' -MessageArgs @(${lb}, ${rb}, $($_.Exception.Message))) 'Err' $State
            return $false
        }
        if (-not $configValid) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m55' -MessageArgs @(${lb}, ${rb})) 'Warn' $State; $warnEv = $true }
        $expectedCfgVer = [version](Get-BuildConstant -Key 'Version' -Fallback '2.0.0')
        $cfgVer = if ($State.BuildConfig.PSObject.Properties.Name -contains 'version') { try { [version]::Parse($State.BuildConfig.version) } catch { $null } } else { $null }
        if ($null -eq $cfgVer) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m56' -MessageArgs @(${lb}, ${rb})) 'Warn' $State
            $warnEv = $true
        } elseif ($cfgVer -lt $expectedCfgVer) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m57' -MessageArgs @(${lb}, ${rb}, $($cfgVer), $($expectedCfgVer))) 'Warn' $State
            $warnEv = $true
        }
        if ($warnEv -and (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue)) {
            Send-BuildEvent -EventName $EVT_BUILD_WARNING -Source $State -Data @{ Message = 'Config validation warnings detected' } | Out-Null
        }
    }
    $activeProfile = if ($State.PSObject.Properties.Name -contains 'ActiveProfile') { $State.ActiveProfile } else { if ($State.BuildConfig -and $State.BuildConfig.build) { $State.BuildConfig.build.defaultConfiguration } elseif (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { [string](Get-BuildSetting -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } else { 'Release' } }
    $sprofile = Get-ActiveProfile -State $State -ProfileName $activeProfile
    if ($sprofile) {
        Write-Log (Get-LocaleMessage -Key 'log.system.profile' -MessageArgs @($activeProfile)) "Info" $State
        if ($sprofile.logLevel) { Set-LogLevel -Level $sprofile.logLevel }
        # Apply profile overrides onto live config so they actually take effect
        if ($sprofile.PSObject.Properties.Name -contains 'enableParallelBuild' -and $null -ne $sprofile.enableParallelBuild) {
            $State.BuildConfig.build.enableParallelBuild = [bool]$sprofile.enableParallelBuild
        }
        if ($sprofile.PSObject.Properties.Name -contains 'enableBuildCache' -and $null -ne $sprofile.enableBuildCache) {
            $State.BuildConfig.build.enableBuildCache = [bool]$sprofile.enableBuildCache
        }
        if ($sprofile.PSObject.Properties.Name -contains 'enableJsonLog' -and $null -ne $sprofile.enableJsonLog) {
            $State.BuildConfig.logging.enableJsonLog = [bool]$sprofile.enableJsonLog
        }
        if ($sprofile.PSObject.Properties.Name -contains 'nonInteractive' -and $sprofile.nonInteractive) {
            $State | Add-Member -MemberType NoteProperty -Name NonInteractive -Value $true -Force -EA SilentlyContinue
        }
        if ($sprofile.PSObject.Properties.Name -contains 'targetFramework' -and -not [string]::IsNullOrWhiteSpace($sprofile.targetFramework)) {
            Set-BuildStateProperty -State $State -Name 'CurrentTfm' -Value ([string]$sprofile.targetFramework) -Force
        }
    }
    return $true
}

<#
.SYNOPSIS
    Centralized health gate for Tier-1 commands that must resolve globally.
.DESCRIPTION
    Level 5 structural fix for the PS 5.1 module-scope orphan incident (FATAL
    Invoke-EnsureDirectory in Save-BuildState): instead of guarding every call
    site, assert the invariant ONCE at pipeline checkpoints. When commands are
    missing it warns LOUDLY (never degraded-silent), emits an event, attempts
    a -Global repair re-import of PathUtils, and returns $false when still
    unhealthy so the caller fails fast with a clear cause. Never throws.
    5.1-safe: statements only, no (if) subexpressions, no ?. / ??.
#>

function Merge-Profile {
    [CmdletBinding()]
    param([PSCustomObject]$Base, [PSCustomObject]$Override)
    # Level 5 DRY: deep-merge single-sourced via ConfigProvider.Merge-ConfigObject.
    # Fallback inline merge kept for standalone survival (ConfigProvider absent).
    if (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue) {
        try { return Merge-ConfigObject -Base $Base -Override $Override } catch { }
    }
    if (-not $Base) { return $Override }
    if (-not $Override) { return $Base }
    $merged = [PSCustomObject]@{}
    foreach ($p in $Base.PSObject.Properties) {
        $merged | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
    }
    foreach ($p in $Override.PSObject.Properties) {
        if ($p.Value -is [PSCustomObject] -and $merged.($p.Name) -is [PSCustomObject]) {
            $merged.($p.Name) = Merge-Profile -Base $merged.($p.Name) -Override $p.Value
        } else {
            $merged | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        }
    }
    return $merged
}

function Get-ActiveProfile {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProfileName = 'Release')
    if (-not ($State -and $State.BuildConfig -and $State.BuildConfig.profiles)) { return $null }
    $profiles = $State.BuildConfig.profiles
    if (-not $profiles.$ProfileName) { return $null }

    # Build inheritance chain via explicit `extends` (resolved recursively, cycle-guarded).
    # Level 5: max depth single-sourced via BuildConstants.ProfileInheritanceMaxDepth.
    $maxDepth = 10
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $maxDepth = [int](Get-BuildConstant -Key 'ProfileInheritanceMaxDepth' -Fallback 10) } catch { $maxDepth = 10 }
    }
    $chain = @()
    $cur = $ProfileName
    $guard = 0
    while ($cur -and $guard -lt $maxDepth) {
        if (-not $profiles.$cur) { break }
        $chain = @($cur) + $chain
        $ext = $null
        if ($profiles.$cur.PSObject.Properties.Name -contains 'extends') { $ext = $profiles.$cur.extends }
        if ($ext -eq $cur) { break }
        $cur = $ext
        $guard++
    }

    # Implicit base `default` profile merges first when present
    if ($profiles.default -and $chain -notcontains 'default') { $chain = @('default') + $chain }

    $result = $null
    foreach ($name in $chain) {
        $result = Merge-Profile -Base $result -Override $profiles.$name
    }
    return $result
}

function Get-BuildTestConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)
    $build = Get-ConfigSection -State $State -Path 'build'
    $test = Get-SectionValue -Section $build -Key 'test' -Default $null
    $legacyValue = Get-SectionValue -Section $build -Key 'runTestLint' -Default $null
    $legacyPresent = $null -ne $legacyValue
    $legacy = if ($legacyPresent) { [bool]$legacyValue } else { $null }
    $defaultTest = $true
    # Mirrors BuildConstants.TestLintEnabled ($false): lint is an opt-in step,
    # not part of the default test phase.
    $defaultLint = $false
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $defaultTest = [bool](Get-BuildConstant -Key 'TestEnabled' -State $State -Fallback $true)
        $defaultLint = [bool](Get-BuildConstant -Key 'TestLintEnabled' -State $State -Fallback $false)
    }
    $testValue = Get-SectionValue -Section $test -Key 'enabled' -Default $null
    $lintValue = Get-SectionValue -Section $test -Key 'lintEnabled' -Default $null
    $testEnabled = if ($null -ne $testValue) { [bool]$testValue } elseif ($null -ne $legacy) { $legacy } else { $defaultTest }
    $lintEnabled = if ($null -ne $lintValue) { [bool]$lintValue } elseif ($null -ne $legacy) { $legacy } else { $defaultLint }
    return @{ TestEnabled = $testEnabled; LintEnabled = $lintEnabled }
}

<#
.SYNOPSIS
    Auto-detects Java JDK and Android SDK for MAUI/Android projects.
.DESCRIPTION

        Checks if project type or TFMs require Java/Android SDKs and triggers
        Get-SmartSdk if not already resolved in State.
    .PARAMETER State
        Global state object with JavaSdk and AndroidSdk properties.
    .PARAMETER ProjectType
        The detected project type (e.g., MAUI, Web).
    .PARAMETER Tfms
        Array of target framework monikers.
    #>

function Test-BuildConfig {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State,
        [switch]$Strict,
        # Explicit escape hatch for the two checks that are now fail-CLOSED
        # (missing schema file, no usable validator). Never inferred: an
        # accident must not be able to turn validation off.
        [switch]$NonStrict
    )
    if (-not $State -or -not $State.BuildConfig) {
        if ($Strict) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m01') "Warn" $State; return $false }
        return $false
    }
    if (-not $State.ConfigPath -or -not (Test-Path $State.ConfigPath)) {
        if ($Strict) { throw (Get-LocaleMessage -Key 'log.orch.configFileNotFound' -MessageArgs @([string]$State.ConfigPath) -Fallback 'Config file not found: {0}') }
        return $false
    }
    $schemaPath = if ($State.PSObject.Properties.Name -contains 'ConfigSchemaPath' -and $State.ConfigSchemaPath) {
        [string]$State.ConfigSchemaPath
    } elseif ($State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) {
        Join-Path ([string]$State.ScriptRoot) 'gbuild.config.schema.json'
    } else {
        [System.IO.Path]::ChangeExtension([string]$State.ConfigPath, '.schema.json')
    }
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        # Fail CLOSED by default. Returning $true here meant that deleting,
        # renaming or botching the copy of gbuild.config.schema.json silently
        # disabled schema validation for the whole platform - and because the
        # schema is 4 000+ lines of property types and additionalProperties
        # rules, everything a consumer mistypes would then be accepted.
        # Opt out explicitly with -NonStrict, never by accident.
        $msg = (Get-LocaleMessage -Key 'log.orch.schemaFileNotFound' -MessageArgs @([string]$schemaPath) -Fallback 'Schema file not found: {0}')
        if ($NonStrict) { Write-Log "[WARN] $msg" "Warn" $State; return $true }
        throw $msg
    }
    $testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
    $hasSchemaParam = $testJsonCmd -and $testJsonCmd.Parameters.ContainsKey('Schema')

    if ($hasSchemaParam) {
        try {
            # ${env:VAR} placeholders are neutralised by the shared helper - see
            # Resolve-ConfigJsonForSchema for why they must not be resolved here.
            $json = Resolve-ConfigJsonForSchema -Config $State.BuildConfig
            $schema = Get-Content $schemaPath -Raw -EA Stop
            $result = $json | Test-Json -Schema $schema -EA Stop
            if (-not $result) {
                $msg = "Config validation failed against schema"
                if ($Strict) { throw $msg }
                Write-Log "[WARN] $msg" "Warn" $State
            }
            return $result
        } catch {
            $msg = "Config validation error: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }

    # REAL schema validation, reachable on every host. This branch used to be
    #
    #     if (Get-Command Test-JsonSchema -ErrorAction SilentlyContinue) { ... }
    #
    # `Test-JsonSchema` is not a PowerShell cmdlet and was never defined in this
    # repository, so all 20 lines were unreachable everywhere. The comment above
    # them reasoned about that branch as if it were live, which is how the gap
    # stayed invisible: on Windows PowerShell 5.1 (no Test-Json) validation
    # quietly fell through to Test-ConfigSchema, and that function only checked
    # FIVE top-level property names. The same config file therefore got a full
    # type/enum/required check on pwsh 7 and a "looks fine" on 5.1.
    #
    # ConfigProvider.Test-BuildConfigSchema is the single owner now, and it
    # implements exactly the keyword subset gbuild.config.schema.json uses. The
    # SAME placeholder-safe config view is used as in the Test-Json branch above,
    # so the two validators cannot disagree about the same file.
    if (Get-Command Test-BuildConfigSchema -ErrorAction SilentlyContinue) {
        try {
            $config = Resolve-ConfigJsonForSchema -Config $State.BuildConfig | ConvertFrom-Json -EA Stop
            $schema = Get-Content $schemaPath -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop
            return [bool](Test-BuildConfigSchema -Instance $config -Schema $schema)
        } catch {
            $msg = "Config validation error: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }

    # Level 5: ConfigProvider.Test-ConfigSchema as structural fallback when neither
    # Test-Json -Schema nor Test-JsonSchema is available (was test-only).
    if (Get-Command Test-ConfigSchema -ErrorAction SilentlyContinue) {
        try {
            $schemaResult = Test-ConfigSchema -State $State -Strict:$Strict
            if ($null -ne $schemaResult) { return [bool]$schemaResult }
        } catch {
            if ($Strict) { throw }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m02' -MessageArgs @($_)) "Warn" $State
            return $false
        }
    }

    # Last resort: the file parses as JSON. This validates NOTHING beyond
    # well-formedness, so it is a fail-CLOSED branch by default too: on a host
    # with neither Test-Json nor a schema-aware validator, reporting "valid"
    # would silently downgrade a full type/property check to a syntax check.
    if ($NonStrict) {
        try {
            $null = Get-Content $State.ConfigPath -Raw -EA Stop | ConvertFrom-Json -EA Stop
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m03') 'Gray' $State
            return $true
        } catch {
            $msg = "Config JSON is invalid: $_"
            if ($Strict) { throw $msg }
            Write-Log "[WARN] $msg" "Warn" $State
            return $false
        }
    }
    throw (Get-LocaleMessage -Key 'log.orch.configNoValidator' -Fallback 'No JSON-Schema validator is available on this host, so gbuild.config.json cannot be validated. Install PowerShell 6+ (Test-Json) or supply a validator.')
}

<#
    .SYNOPSIS
        Runs quick health checks before the build starts.
    .PARAMETER State
        Global state object.
    #>

function Resolve-ConfigJsonForSchema {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Config)
    # SINGLE SOURCE for "the config as schema-validation input".
    #
    # ${env:VAR} placeholders must NOT be resolved to their real values before
    # validation: resolving e.g. ${env:APPDATA} to C:\Users\... injects raw
    # backslashes that are invalid JSON escapes and make Test-Json fail on pwsh 7
    # with "Cannot parse the JSON". Schema checks only need the structure, so a
    # placeholder-safe literal is sufficient (and avoids leaking secrets).
    #
    # This was applied ONLY inside the Test-Json branch. The Test-JsonSchema
    # fallback (the branch PowerShell 5.1 actually takes - it has no Test-Json
    # at all) validated the raw placeholder strings, so the same config was
    # accepted on pwsh 7 and rejected on Windows PowerShell 5.1 whenever the
    # schema constrained a placeholder's shape.
    $json = $Config | ConvertTo-Json -Depth 100
    if (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) {
        $json = $json -replace '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '/tmp/placeholder'
    }
    return $json
}

function Initialize-BuildIdentity {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not $State.PSObject.Properties.Name -contains 'CorrelationId') {
        # Level 5 single-source: CorrelationIdLength (was literal 12).
        $corrLen = 12
        try {
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                $corrLen = [int](Get-BuildConstant -Key 'CorrelationIdLength' -State $State -Fallback 12)
            }
        } catch { $corrLen = 12 }
        if ($corrLen -le 0) { $corrLen = 12 }
        $State | Add-Member -MemberType NoteProperty -Name CorrelationId -Value ([guid]::NewGuid().ToString('N').Substring(0,$corrLen)) -Force
    }
    $tenantRaw = if ($State.BuildConfig -and $State.BuildConfig.tenancy -and $State.BuildConfig.tenancy.tenantId) { $State.BuildConfig.tenancy.tenantId }
                 elseif ($State.BuildConfig -and $State.BuildConfig.tenancy -and $State.BuildConfig.tenancy.defaultTenant) { $State.BuildConfig.tenancy.defaultTenant }
                 else { 'default' }
    $tenantId = 'default'
    if ($tenantRaw -match '^\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}$') {
        $envVal = [Environment]::GetEnvironmentVariable($Matches[1])
        if (-not [string]::IsNullOrEmpty($envVal)) { $tenantId = $envVal }
    } elseif (-not [string]::IsNullOrWhiteSpace($tenantRaw)) {
        $tenantId = $tenantRaw
    }
    if (-not ($State.PSObject.Properties.Name -contains 'TenantId')) {
        $State | Add-Member -MemberType NoteProperty -Name TenantId -Value $tenantId -Force
    } else {
        $State.TenantId = $tenantId
    }
    # Apply tenant overrides (tenancy.overrides) now that TenantId is resolved so
    # downstream config consumers see the merged values for the active tenant.
    # ConfigProvider.Merge-ConfigTenantOverride is guarded: absent overrides (and any
    # standalone import without it) return the config unchanged.
    if ($State -and $State.BuildConfig -and (Get-Command Merge-ConfigTenantOverride -ErrorAction SilentlyContinue)) {
        $State.BuildConfig = Merge-ConfigTenantOverride -Config $State.BuildConfig -State $State
    }
}

<#
.SYNOPSIS
    Wires EventBus alerting subscribers for build error / rollback events.
#>
<#
.SYNOPSIS
    Flow-scoped log level (P1 scoped logging).
.DESCRIPTION
    Routine high-volume flow logs (per-step/plugin/cache/telemetry) report at
    $ScopedLevel (default Debug) under build.scopedLogging, and at $VerboseLevel
    when verbose. Warnings/errors/alerts never go through here — they always show.
#>

function Initialize-BuildLogging {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$LogLevel = 'Info')
    # Log directory base comes from config logging.path (new/optional) with the
    # single-sourced BuildConstants LogsDir as default ('logs'), so operators can
    # relocate build logs without editing core. Empty/absent falls back to 'logs'.
    $rawLogDir = Resolve-ConfigValue -State $State -Path 'logging.path' -Default (Get-BuildConstant -Key 'LogsDir' -Fallback 'logs')
    $logNameDir = if ([string]::IsNullOrWhiteSpace([string]$rawLogDir)) { Get-BuildConstant -Key 'LogsDir' -Fallback 'logs' } else { [string]$rawLogDir }
    $logDir = Join-Path $State.ScriptRoot (Join-Path $logNameDir $State.TenantId)
    if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $logDir) } elseif (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Start-Log -Path (Join-Path $logDir "build_$(Get-BuildTimestamp -Kind FileStamp).log")
    $safeLogLevel = if ($LogLevel -in @('Error','Warn','Info','Debug')) { $LogLevel } else { 'Info' }
    Set-LogLevel -Level $safeLogLevel
    Write-Log (Get-LocaleMessage -Key 'log.system.building') 'Succ' $State -Level $safeLogLevel
    if (Get-Command Start-MetricsEndpoint -ErrorAction SilentlyContinue) {
        $promCfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.telemetry -and $State.BuildConfig.telemetry.prometheus) { $State.BuildConfig.telemetry.prometheus } else { $null }
        if (-not $promCfg) {
            # DI fallback: read prometheus config from the registered MetricRegistry service
            try { $reg = Resolve-Service -Name 'MetricRegistry'; if ($reg -and $reg.PrometheusConfig) { $promCfg = $reg.PrometheusConfig } } catch {
                # benign - service not registered, metrics start skipped
                }
        }
        if ($promCfg -and $promCfg.enabled) {
            if (Get-Command Test-EnvToggle -ErrorAction SilentlyContinue) {
                try {
                    if ((Test-EnvToggle -Name 'GBUILD_PROMETHEUS') -eq $true -and -not [bool]$State.BuildConfig.telemetry.prometheus.enabled) {
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m49' -MessageArgs @($($promCfg.port))) 'Info' $State
                    }
                } catch { }
            }
            Start-MetricsEndpoint -Port ([int]$promCfg.port) -State $State | Out-Null
        }
    }
}

<#
.SYNOPSIS
    Handles standalone operations (CacheClear/Optimize/Stats/VersionBump). Returns $true if handled.
#>

function Get-FlowLogLevel {
    [CmdletBinding()] param([PSCustomObject]$State, [string]$ScopedLevel = 'Debug', [string]$VerboseLevel = 'Info')
    $scoped = $true
    try {
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $scoped = [bool](Get-BuildSetting -Key 'LogScopedLogging' -State $State -Fallback $true) }
        elseif (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { $scoped = [bool](Get-ConfigValue -Path 'build.scopedLogging' -State $State -Default $true) }
    } catch { $scoped = $true }
    if ($scoped) { return $ScopedLevel } else { return $VerboseLevel }
}

