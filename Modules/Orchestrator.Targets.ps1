# ============================================================================
# Orchestrator.Targets.ps1 - target helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Get-BuildTargetChoices {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $configured = $null
    try { $configured = Get-ConfigValue -Path 'build.targetCatalog.buildChoices' -State $null -Default $null } catch { $configured = $null }
    if ($null -ne $configured -and @($configured).Count -gt 0) { return @($configured | ForEach-Object { [string]$_ }) }
    return @('2','3','4','5','6','7','8','9','10','11','12','14','15','16','17')
}

<#
.SYNOPSIS
    Returns the canonical list of menu choices whose failure must abort the run.
.DESCRIPTION
    Privileged, non-build actions (cluster, distributed, deploy, security,
    chaos, test, lint). A failure here is always fatal.

    THREE layers, in precedence order:
      1. build.targetCatalog.fatalChoices (explicit operator override).
      2. The RBAC privileged set (resolved through Get-RbacPrivilegedActions,
         which is itself config-overridable via
         security.rbac.privilegedActions) UNION the execution-fatal extras
         below. Privilege and fatality are DIFFERENT concepts sharing one
         computation, not one list: X/Z/O/D need no authorization, but a
         failure in any of them must not report success.
      3. Hardcoded union fallback (only when neither RBAC nor BuildConstants
         can be loaded).

    Execution-fatal extras (present here, deliberately ABSENT from
    RbacPrivilegedActions):
      X - Multi-Host Distributed Build. Remote execution across hosts; a
          100%-failed remote run used to exit 0 because X was in neither the
          build set nor the fatal set.
      Z - Chaos drill. An explicitly requested resilience drill whose harness
          reports Degraded (drill failed to inject) is a failed operation.
      O - Cluster submit. An explicitly requested, opted-in
          (build.cluster.submit.enabled) remote build whose waited status is
          not Succeeded is a failed operation.
      D - Doctor. An explicitly requested health check on a broken environment
          reporting success is a lie; -Target D is the CI health gate.
    W (HotReload, long-running watcher), M (Anomaly, analysis completed =
    success even with Critical findings; execution errors already throw) and
    T/I (test/lint, already throw via Invoke-PluginTestAndLintGate) are
    deliberately NOT here.
#>

function Get-TargetCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([PSCustomObject]$State)
    $menu = $null
    try {
        if (Get-Command New-GuildMenuConfig -ErrorAction SilentlyContinue) {
            $menu = New-GuildMenuConfig -ProjectType '' -AndroidTfm '' -WinTfm '' -OS '' -ParallelProjects @() -State $State
        }
    } catch { $menu = $null }
    $modMap = @{}
    try {
        if (Get-Command Get-ModuleMapFromConfig -ErrorAction SilentlyContinue) { $modMap = Get-ModuleMapFromConfig -State $State }
    } catch { }
    $order = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','T','I','A','B','V','G','P','F','E','K','Y','N','W','D','S','H','R','C','L','0','X','Z','M','O')
    $seen = @{}
    foreach ($k in $order) { $seen[$k] = $true }
    $extra = @()
    foreach ($src in @($menu, $modMap)) {
        if ($src -is [hashtable]) {
            foreach ($k in @($src.Keys)) {
                if (-not $seen.ContainsKey([string]$k)) { $seen[[string]$k] = $true; $extra += [string]$k }
            }
        }
    }
    # Reverse default-action map: which project types default to each ID.
    # String values group directly; scriptblocks (MAUI-style conditionals) are
    # probed against the three canonical TFM contexts (android-only,
    # windows-only, neither) so the project type is attributed to every ID the
    # block can return. Deterministic with no TFM context required; a block
    # that yields nothing falls back to the 'conditional' bucket.
    $defaultFor = @{}
    # Single source for the TFM used to probe conditional default actions.
    $__probeTfm = 'net8.0'
    try {
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $__probeTfm = [string](Get-BuildSetting -Key 'DefaultTfm' -State $State -Fallback 'net8.0') }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($__probeTfm)) { $__probeTfm = 'net8.0' }
    try {
        if (Get-Command Get-DefaultActionsFromConfig -ErrorAction SilentlyContinue) {
            $defs = Get-DefaultActionsFromConfig -State $State
            if ($defs -is [hashtable]) {
                foreach ($pt in @($defs.Keys)) {
                    $v = $defs[$pt]
                    if ($v -is [string] -and $v) {
                        if (-not $defaultFor.ContainsKey($v)) { $defaultFor[$v] = [System.Collections.ArrayList]::new() }
                        [void]$defaultFor[$v].Add([string]$pt)
                    } elseif ($v -is [scriptblock]) {
                        $probeCtxs = @(
                            # Derive the probe TFM from the configured default instead
                            # of pinning .NET 10. These three contexts only answer
                            # "is this block android-only / windows-only / neither?",
                            # and that depends on the SHAPE of the TFM string. Pinning
                            # 'net10.0-android' meant a project really targeting
                            # net9.0-android or net11.0-android matched none of them
                            # and fell into the 'conditional' bucket, so its default
                            # action was silently mis-attributed.
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ($__probeTfm + '-android'); WinTfm = '' } },
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = ($__probeTfm + '-windows') } },
                            [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = '' } }
                        )
                        $candidateIds = @()
                        foreach ($pc in $probeCtxs) {
                            try {
                                $probeResult = & $v $pc
                                if ($probeResult -is [string] -and $probeResult) { $candidateIds += $probeResult }
                            } catch { }
                        }
                        $candidateIds = @($candidateIds | Select-Object -Unique)
                        if ($candidateIds.Count -eq 0) {
                            if (-not $defaultFor.ContainsKey('conditional')) { $defaultFor['conditional'] = [System.Collections.ArrayList]::new() }
                            [void]$defaultFor['conditional'].Add([string]$pt)
                        } else {
                            foreach ($cid in $candidateIds) {
                                if (-not $defaultFor.ContainsKey($cid)) { $defaultFor[$cid] = [System.Collections.ArrayList]::new() }
                                if ($defaultFor[$cid] -notcontains [string]$pt) { [void]$defaultFor[$cid].Add([string]$pt) }
                            }
                        }
                    }
                }
            }
        }
    } catch { }
    $rows = [System.Collections.ArrayList]::new()
    foreach ($k in @($order + $extra)) {
        $label = [string]$k; $title = ''
        if (($menu -is [hashtable]) -and $menu.ContainsKey($k) -and $menu[$k]) {
            try {
                if ($menu[$k].Label) { $label = [string]$menu[$k].Label }
                if ($menu[$k].Title) { $title = [string]$menu[$k].Title }
            } catch { }
        }
        $mods = @()
        if (($modMap -is [hashtable]) -and $modMap.ContainsKey($k) -and $modMap[$k]) { $mods = @($modMap[$k] | ForEach-Object { [string]$_ }) }
        $df = @()
        if ($defaultFor.ContainsKey($k)) { $df = @($defaultFor[$k]) }
        [void]$rows.Add([PSCustomObject]@{ Key = [string]$k; Label = $label; Title = $title; Modules = $mods; DefaultFor = $df })
    }
    return @($rows)
}

<#
.SYNOPSIS
    Prints the -Target catalog (like -Help, but for build target IDs).
.DESCRIPTION
    Invoked by `-Target list|help|?` (no project needed). Shows every menu ID
    with its purpose and engine modules, plus per-project-type defaults, so an
    ID from the help text (e.g. 2 = Publish Android APK) is always resolvable
    to a meaning without running interactively.
#>

function Get-FatalActionChoices {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    # Layer 1: explicit operator override.
    try {
        $override = Get-ConfigValue -Path 'build.targetCatalog.fatalChoices' -State $State -Default $null
        if ($null -ne $override -and @($override).Count -gt 0) { return @(@($override) | ForEach-Object { [string]$_ }) }
    } catch { }
    # Layer 2: privileged set (single-sourced in the RBAC accessor) plus the
    # execution-fatal extras. The privileged list is READ here, never copied:
    # the previous implementation carried its own 14-key verbatim copy that had
    # already drifted twice from the owner.
    $privileged = @()
    try {
        if (Get-Command Get-RbacPrivilegedActions -ErrorAction SilentlyContinue) {
            $privileged = @(Get-RbacPrivilegedActions)
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $privileged = @(Get-BuildConstant -Key 'RbacPrivilegedActions' -State $State -Fallback @())
        }
    } catch { $privileged = @() }
    $fatal = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($privileged)) { $v = [string]$k; if ($v -and -not $fatal.Contains($v)) { [void]$fatal.Add($v) } }
    foreach ($k in @('X', 'Z', 'O', 'D')) { if (-not $fatal.Contains($k)) { [void]$fatal.Add($k) } }
    if ($fatal.Count -gt 0) { return @($fatal.ToArray()) }
    # Layer 3: nothing loaded. Verbatim union of the RbacPrivilegedActions
    # fallback (RBAC.psm1 Get-RbacPrivilegedActions) and the extras above.
    return @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13','X','Z','O','D')
}

<#
    .SYNOPSIS
        Main entry point for the gbuild build system.
    .DESCRIPTION
        Orchestrates the full build pipeline: config validation, SDK detection,
        profile loading, project scanning, menu display, and build dispatch.
        Handles standalone operations (clean, cache, version bump) as well.
    .PARAMETER GitHub
        Trigger GitHub Actions workflow (non-interactive mode).
    .PARAMETER NonInteractive
        Run without user prompts.
    .PARAMETER Incremental
        Skip clean step, build incrementally.
    .PARAMETER Clean
        Perform smart clean only (bin/obj/cache).
    .PARAMETER CacheClear
        Clear the build cache.
    .PARAMETER CacheOptimize
        Optimize the build cache.
    .PARAMETER CacheStats
        Display cache statistics.
    .PARAMETER VersionBump
        Auto-increment project version.
    .PARAMETER LogLevel
        Log verbosity level (Error, Warn, Info, Debug).
    #>

<#
.SYNOPSIS
    Resolves the effective pipeline step list from config + caller-supplied steps.
.DESCRIPTION
    When build.pipeline.steps is defined in config, those entries are used.
    Otherwise the caller-supplied $Steps array is returned as-is.
    Config steps: array of @{ Name; ScriptBlock; When; Retry; TimeoutSeconds }
    Level 5: build.pipeline.validate=true enforces required name+script and
    warns on unknown keys; script/when bodies are validated with the PowerShell
    parser before ScriptBlock::Create so config typos fail fast (no sandbox —
    config is trusted local input, same trust as gbuild.ps1).
#>
<#
.SYNOPSIS
    Resolves the effective pipeline step list from a gbuild.pipeline.yml file.
.DESCRIPTION
    Returns $null when no pipeline file is present, so the caller falls through
    to build.pipeline.steps. Returns an array when one is.

    The module is imported on demand rather than at Tier-1: it is only needed
    by projects that actually adopt pipeline-as-code, and it is a pure parser
    with no state. Validation failures PROPAGATE (do not get swallowed) - a
    malformed pipeline must fail the build loudly rather than silently
    reverting to the built-in pipeline.
.OUTPUTS
    Array of step hashtables, or $null.
#>

function Get-DefaultActionsFromConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)

    $defaultMap = @{
        'MAUI'       = { param($ctx) if ($ctx.tfmInfo.AndroidTfm) { '2' } elseif ($ctx.tfmInfo.WinTfm) { '8' } else { '12' } }
        'Web'        = '7'
        'BlazorWasm' = '7'
        'WinForms'   = '8'
        'WinExe'     = '8'
        'WPF'        = '9'
        'WinUI'      = '8'
        'Console'    = '10'
        'Library'    = '11'
        'Avalonia'   = '16'
        'Python'     = '12'
        'Node.js'    = '12'
        'TypeScript' = '12'
        'Rust'       = '12'
        'Go'         = '12'
        'Java'       = '12'
        'Kotlin'     = '12'
        'Ruby'       = '12'
        'PHP'        = '12'
        'C/C++'      = '12'
        'C'          = '12'
        'Docker'     = '12'
        'Elixir'     = '12'
        'Swift'      = '12'
        'PowerShell' = '12'
        'default'    = '12'
    }

    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.menu -or -not $State.BuildConfig.build.menu.defaultActions) {
        return $defaultMap
    }

    $cfgMap = $State.BuildConfig.build.menu.defaultActions
    $result = @{}
    foreach ($key in $cfgMap.PSObject.Properties.Name) {
        $val = $cfgMap.$key
        if ($val -is [scriptblock]) {
            $result[$key] = $val
        } elseif ($val -is [string]) {
            $result[$key] = $val
        } elseif ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [hashtable]) {
            # MAUI-style conditional: { androidTfm, windowsTfm, default }
            $androidChoice = if ($val.PSObject.Properties.Name -contains 'androidTfm') { $val.androidTfm } elseif ($val.ContainsKey('androidTfm')) { $val['androidTfm'] } else { '2' }
            $windowsChoice = if ($val.PSObject.Properties.Name -contains 'windowsTfm') { $val.windowsTfm } elseif ($val.ContainsKey('windowsTfm')) { $val['windowsTfm'] } else { '8' }
            $defaultChoice = if ($val.PSObject.Properties.Name -contains 'default') { $val.default } elseif ($val.ContainsKey('default')) { $val['default'] } else { '12' }
            $result[$key] = { param($ctx) if ($ctx.tfmInfo.AndroidTfm) { $androidChoice } elseif ($ctx.tfmInfo.WinTfm) { $windowsChoice } else { $defaultChoice } }.GetNewClosure()
        } else {
            $result[$key] = $defaultMap[$key]
        }
    }
    # Merge defaults for any missing keys
    foreach ($key in $defaultMap.Keys) {
        if (-not $result.ContainsKey($key)) { $result[$key] = $defaultMap[$key] }
    }
    return $result
}

<#
.SYNOPSIS
    Dispatches a deploy menu choice through the deploy-target plugin registry.
.DESCRIPTION
    Maps a menu choice letter to its registered deploy-target name and invokes it
    via Invoke-DeployTarget (the registry dispatcher). This replaces the previous
    hardcoded switch so newly registered targets are picked up automatically.
.PARAMETER Choice
    The menu choice letter (A/B/V/G/P/F/E/K/Y).
#>

function Resolve-AutoBuildChoice {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$MenuConfig, [PSCustomObject]$State, [string]$ProjectType, [PSCustomObject]$BuildContext)
    $choice = '12'
    try {
        if (Get-Command Get-DefaultActionsFromConfig -ErrorAction SilentlyContinue) {
            $defaultActions = Get-DefaultActionsFromConfig -State $State
            $action = $defaultActions[$ProjectType]
            if ($null -eq $action) { $action = $defaultActions['default'] }
            if ($null -ne $action) {
                if ($action -is [scriptblock]) { $choice = [string](& $action $BuildContext) }
                else { $choice = [string]$action }
            }
        }
    } catch { $choice = '12' }
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '12' }
    if ($MenuConfig.ContainsKey($choice) -and $MenuConfig[$choice].Supported -ne $false) {
        return $choice
    }
    if ($MenuConfig.ContainsKey('12') -and $MenuConfig['12'].Supported -ne $false) {
        return '12'
    }
    $supported = @($MenuConfig.Keys | Where-Object { $MenuConfig[$_] -and $MenuConfig[$_].Supported } | Sort-Object)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Resolve-LogMessage -Key 'log.target.noSupportedDefault' -MessageArgs @([string]$ProjectType, $choice, ($supported -join ', ')) -Fallback '[TARGET] No supported default for product type {0} (resolved ''{1}'' unavailable; fallback ''12'' unsupported). Supported: {2}. Pass -Target <id> explicitly.') 'Err' $State
    }
    return ''
}

function Show-TargetList {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $rows = @()
    try { $rows = @(Get-TargetCatalog -State $State) } catch { $rows = @() }
    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add('')
    [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.title' -Fallback 'gbuild target catalog — IDs usable with -Target <id>'))
    [void]$lines.Add('')
    $groups = @(
        @{ Name = 'BUILD'; Keys = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','T','I') },
        @{ Name = 'DEPLOY'; Keys = @('A','B','V','G','P','F','E','K','Y','N') },
        @{ Name = 'OPS'; Keys = @('W','D','S','H','R','C','L','0','X','Z','M','O') }
    )
    $byKey = @{}
    foreach ($r in $rows) { $byKey[$r.Key] = $r }
    $shown = @{}
    foreach ($g in $groups) {
        [void]$lines.Add("  $($g.Name):")
        foreach ($k in $g.Keys) {
            if (-not $byKey.ContainsKey($k)) { continue }
            $shown[$k] = $true
            $r = $byKey[$k]
            $mods = if ($r.Modules.Count -gt 0) { " (modules: $($r.Modules -join ', '))" } else { '' }
            $df = if ($r.DefaultFor.Count -gt 0) { " [default for: $($r.DefaultFor -join ', ')]" } else { '' }
            $ttl = if ($r.Title) { " — $($r.Title)" } else { '' }
            [void]$lines.Add(("    [{0}]" -f $k).PadRight(9) + "$($r.Label)$ttl$mods$df")
        }
    }
    $rest = @($rows | Where-Object { -not $shown.ContainsKey($_.Key) })
    if ($rest.Count -gt 0) {
        [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.custom' -Fallback 'CUSTOM:'))
        foreach ($r in $rest) {
            $mods = if ($r.Modules.Count -gt 0) { " (modules: $($r.Modules -join ', '))" } else { '' }
            [void]$lines.Add(("    [{0}]" -f $r.Key).PadRight(9) + "$($r.Label)$mods")
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('  ' + (Get-LocaleMessage -Key 'ui.target.notes' -Fallback 'Notes:'))
    [void]$lines.Add('    - ' + (Get-LocaleMessage -Key 'ui.target.noteAvailability' -Fallback 'Availability depends on the detected project type and OS;'))
    [void]$lines.Add('      ' + (Get-LocaleMessage -Key 'ui.target.noteSubset' -Fallback 'run interactively in a project to see its supported subset.'))
    [void]$lines.Add('    - ' + (Get-LocaleMessage -Key 'ui.target.noteRecord' -Fallback 'A build log always records the used ID: [TARGET] Using -Target <id> (<purpose>).'))
    [void]$lines.Add('')
    foreach ($ln in $lines) {
        try { Write-Host $ln } catch { }
    }
}

<#
.SYNOPSIS
    Resolves the auto-build choice for -Project runs without -Target.
.DESCRIPTION
    Looks up the product type in build.menu.defaultActions (falls back to the
    'default' entry, then to '12'). The fallback chain validates ITSELF: '12'
    (Build default) is only a fallback when the menu actually supports it
    (Unknown / non-dotnet products). Otherwise returns '' and logs an Err
    naming the supported IDs, so the caller fails loudly instead of dying
    later at "Invalid choice". Never throws for config gaps.
.PARAMETER MenuConfig
    Hashtable from New-GuildMenuConfig (keys carry Supported flags).
.PARAMETER State
    Build state (reads build.menu.defaultActions).
.PARAMETER ProjectType
    Detected product type (e.g. 'WinForms', 'MAUI').
.PARAMETER BuildContext
    Context object passed to conditional (scriptblock) default actions.
.OUTPUTS
    [string] a supported menu choice key, or '' when none applies.
#>

function Invoke-GuildChoice {    [CmdletBinding()]
    param([string]$Choice = "", [hashtable]$MenuConfig, [PSCustomObject]$State, [string]$ProjPath = "", [string]$ProjectDir = "", [string]$ProjectType = "", [string[]]$Tfms = @(), [string]$DefaultTfm = "", [string]$WinTfm = "", [string]$AndroidTfm = "", [string]$IosTfm = "", [string]$MacTfm = "", [string[]]$ParallelProjects = @(), [switch]$Incremental, [hashtable]$PipelineContext = @{})
    # StrictMode-safe: typed-with-default above guarantees every variable exists
    # even when a `Set-StrictMode -Version Latest` caller omits arguments.
    try { if ($null -eq $ProjectType) { $ProjectType = "" } } catch { $ProjectType = "" }
    $choiceResult = $null
    if (-not $MenuConfig.ContainsKey($Choice) -or -not $MenuConfig[$Choice].Supported) {
        # Actionable: name what THIS project actually supports so a habit-typed
        # ID (e.g. '12', valid only for Unknown / non-.NET products) tells the
        # operator what to pick instead, and where ALL commands live (-Help).
        # 5.1-safe: statements only, no ternary. Numbers sort numerically.
        $supportedIds = @($MenuConfig.Keys | Where-Object { $MenuConfig[$_] -and $MenuConfig[$_].Supported })
        $numIds = @($supportedIds | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ })
        $alphaIds = @($supportedIds | Where-Object { $_ -notmatch '^\d+$' } | Sort-Object)
        $supportedIds = @($numIds + $alphaIds)
        $helpHint = 'gbuild -Help'
        if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
            try {
                $hintCwd = try { ((Get-Location).ProviderPath) } catch { '' }
                $hintRoot = if ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { '' }
                $helpHint = Get-InvokeCommandHint -Arguments '-Help' -ScriptRoot $hintRoot -FromDirectory $hintCwd
            } catch { }
        }
        $message = "Invalid choice: '$Choice' is not supported for this project. Supported: $($supportedIds -join ', '). Run '$helpHint' for ALL commands."
        Write-Fail $message -State $State
        throw $message
    }
    # RBAC: privileged actions require an allow-list when security.allowedActions is
    # configured. An action not in the allow-list (and not explicitly denied) is blocked.
    # Single source: BuildConstants.RbacPrivilegedActions (security.rbac.privilegedActions).
    $privileged = @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13')
    # Single source: RBAC.Get-RbacPrivilegedActions (config-overridable via
    # security.rbac.privilegedActions), then BuildConstants, then the hardcoded
    # mirror below (only when neither module chain loads). The literal is a
    # verbatim copy of the RBAC fallback - never edited independently.
    try {
        if (Get-Command Get-RbacPrivilegedActions -ErrorAction SilentlyContinue) {
            $viaRbac = @(Get-RbacPrivilegedActions -Kind 'privileged')
            if ($viaRbac.Count -gt 0) { $privileged = $viaRbac }
        } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $resolved = @(Get-BuildConstant -Key 'RbacPrivilegedActions' -State $State -Fallback $privileged)
            if ($resolved.Count -gt 0) { $privileged = $resolved }
        }
    } catch { }
    if ($Choice -in $privileged) {
        # Test-ActionAllowed lives in RBAC.psm1: ensure it is loaded for
        # standalone-Orchestrator sessions. No-op inside a normal run.
        Import-ModuleOnDemand -ModuleNames @('RBAC')
        $allowed = Test-ActionAllowed -State $State -Action $Choice
        if (-not $allowed.Allowed) {
            Write-Fail $allowed.Reason -State $State
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                Write-AuditLog -Action "choice:$Choice" -Outcome 'Denied' -State $State -Detail $allowed.Reason
            }
            return $false
        }
    }
    $sc = if ($Choice -eq '13') { 'Succ' } elseif ($Choice -eq '0') { 'Gray' } else { 'Info' }
    Write-StepTitle $MenuConfig[$Choice].Title -Color $sc -State $State
    # Audit privileged actions on success-path entry.
    if ($Choice -in $privileged -and (Get-Command Write-AuditLog -ErrorAction SilentlyContinue)) {
        Write-AuditLog -Action "choice:$Choice" -Outcome 'Started' -State $State
    }
    # Lazy-load the modules this choice depends on (keeps startup lean).
    $moduleMap = Get-ModuleMapFromConfig -State $State
    if ($moduleMap.ContainsKey($Choice)) {
        Import-ModuleOnDemand -ModuleNames $moduleMap[$Choice]
    }
    switch ($Choice) {
        '0' { Write-Info (Get-LocaleMessage -Key 'log.orchestrator.m06') $State; return }
        'D' {
            if (Get-Command Invoke-Doctor -ErrorAction SilentlyContinue) {
                $doctorOk = [bool](Invoke-Doctor -State $State)
                # The bool verdict used to be discarded: a broken environment
                # reported Succeeded/NoArtifact and -Target D exited 0. D is in
                # Get-FatalActionChoices, so an unhealthy environment now fails
                # the run (interactive sessions get the continue prompt; CI gets
                # a nonzero exit, which is the point of a health gate).
                $choiceResult = New-OperationResult -Status $(if ($doctorOk) { 'Succeeded' } else { 'Failed' }) -Operation 'target:D' -ReasonCode $(if ($doctorOk) { 'OK' } else { 'DoctorFailed' }) -Message $(if ($doctorOk) { 'Environment health check passed' } else { 'Environment health check failed' })
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('HealthCheck') -Fallback 'HealthCheck module not loaded.') -State $State
            }
        }
        'S' {
            if (Get-Command Invoke-SecurityScan -ErrorAction SilentlyContinue) {
                # The menu result is user-facing, but a FAILING scan must still
                # leave a non-zero exit code behind: `-Security`/CI callers read
                # it, and an operator who drives a scan from the menu must not
                # get a green pipeline out of a red gate.
                $menuScan = Invoke-SecurityScan -State $State
                if ($menuScan -and -not $menuScan.Pass) {
                    Set-GBuildExitCode -Code 2 -Reason 'security-scan'
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Security') -Fallback 'Security module not loaded.') -State $State
            }
        }
        '1' { if (Get-Command Invoke-DeviceDebug -ErrorAction SilentlyContinue) { return (Invoke-DeviceDebug -State $State -Project $ProjPath -Tfm $AndroidTfm) } else { throw (Get-LocaleMessage -Key 'log.orch.moduleAndroidMissing' -Fallback 'Android module not loaded.') } }
        '2' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $AndroidTfm -OutputSubDir 'apk' -BuildArgs (Get-DeployChoiceArgs -Kind Apk -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '3' { if (-not (Get-Command Invoke-AndroidAabBuild -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-AndroidAabBuild -State $State -ProjPath $ProjPath -AndroidTfm $AndroidTfm -ProjectDir $ProjectDir -ProjectType $ProjectType -Incremental:$Incremental) }
        '4' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $IosTfm -OutputSubDir 'ios' -BuildArgs (Get-DeployChoiceArgs -Kind Ios -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '5' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $MacTfm -OutputSubDir 'mac' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '6' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.msixNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'Windows MSIX requires Windows (current: {0})') }; $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $WinTfm -OutputSubDir 'win' -BuildArgs (Get-DeployChoiceArgs -Kind WinMsix -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '7' { if (-not (Get-Command Invoke-WebPublish -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-WebPublish -State $State -ProjPath $ProjPath -DefaultTfm $DefaultTfm -ProjectType $ProjectType -ProjectDir $ProjectDir -Incremental:$Incremental) }
        '8' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.desktopPublishNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'Desktop publish requires Windows (current: {0})') }; if (-not (Get-Command Invoke-DesktopPublish -ErrorAction SilentlyContinue)) { throw (Get-LocaleMessage -Key 'log.orch.moduleDeployMissing' -Fallback 'Deploy module not loaded.') }; $choiceResult = (Invoke-DesktopPublish -State $State -ProjPath $ProjPath -WinTfm $WinTfm -Tfms $Tfms -DefaultTfm $DefaultTfm -ProjectType $ProjectType -Incremental:$Incremental) }
        '9' { if ($State.OS -ne 'Windows') { throw (Get-LocaleMessage -Key 'log.orch.wpfPublishNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'WPF publish requires Windows (current: {0})') }; $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $WinTfm -OutputSubDir 'wpf' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '10' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'console' -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        '11' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'lib' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '12' { $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'; $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'default' -ProjectType $ProjectType -Incremental:$Incremental -Detailed) }
        '13' {
            $fmtNonInteractive = 'aab'
            $fmtInteractive = 'apk'
            try {
                if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                    $fmtNonInteractive = [string](Get-BuildConstant -Key 'CiPackageFormatNonInteractive' -State $State -Fallback 'aab')
                    $fmtInteractive = [string](Get-BuildConstant -Key 'CiPackageFormatInteractive' -State $State -Fallback 'apk')
                }
            } catch { }
            $fmt = if ($State.NonInteractive -or $State.IsCI) { $fmtNonInteractive } else { $fmtInteractive }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.ghTriggeringFormat' -MessageArgs @([string]$fmt) -Fallback 'Triggering GitHub Actions workflow - format: {0}')
            # The verdict must come from the callee. Invoke-GitHubBuild returns
            # early when the `gh` CLI is absent, and this arm used to print
            # "GitHub Actions triggered (fmt)" unconditionally - so a machine with
            # no gh CLI produced a GREEN "triggered" for a build that was never
            # triggered. That is the worst class of lie in a build tool: it
            # converts a missing prerequisite into a silent pass. Combined with
            # the uniform-return contract at the end of this function, which
            # turns an unset $choiceResult into Succeeded/NoArtifact, a
            # non-interactive run with no gh reported total success.
            $ghResult = $null
            if (Get-Command Invoke-GitHubBuild -ErrorAction SilentlyContinue) {
                $ghResult = Invoke-GitHubBuild -State $State -PackageFormat $fmt
            }
            if ($ghResult -and ($ghResult.ContainsKey('Success')) -and -not [bool]$ghResult.Success) {
                $choiceResult = New-BuildResult -Status Failed -Operation 'target:13' -ReasonCode 'GitHubTriggerFailed' -Message ([string]$ghResult.Message)
            } elseif ($ghResult -and $ghResult.ContainsKey('Success') -and [bool]$ghResult.Success) {
                Write-Done (Resolve-LogMessage -Key 'log.orchestrator.githubTriggered' -MessageArgs @([string]$fmt) -Fallback 'GitHub Actions triggered ({0})') -State $State
                $choiceResult = New-BuildResult -Status Succeeded -Operation 'target:13' -ReasonCode 'OK' -Message ([string]$ghResult.Message)
            } else {
                # No verdict available (Build module absent, or a callee that
                # predates the Success key). Say so rather than claim success.
                Write-Warn (Resolve-LogMessage -Key 'log.orchestrator.githubTriggerUnverified' -Fallback 'GitHub build dispatch returned no verdict; treat the remote workflow as NOT triggered') -State $State
                $choiceResult = New-BuildResult -Status Skipped -Operation 'target:13' -ReasonCode 'NoVerdict' -Message 'GitHub build dispatch returned no verdict'
            }
        }
        '14' {
            # The result must be CAPTURED. '14' is in Get-BuildTargetChoices, so
            # the single validation point at the end of this function runs
            # Test-RequiredResult against $choiceResult; with the assignment
            # missing that variable was still $null, Test-RequiredResult read it
            # as a failed result, and the dispatcher threw "Build target '14'
            # failed" AFTER the parallel build had already reported
            # "3 succeeded, 0 failed". The bug was invisible only because target
            # 14 was unreachable (see the ScanProject import fix); the moment the
            # flow became reachable the false failure surfaced.
            if ($ParallelProjects -and $ParallelProjects.Count -gt 0) {
                $choiceResult = Invoke-GuildParallelBuild -State $State -Projects $ParallelProjects -Tfm $DefaultTfm -MaxJobs (Get-BuildConstant -Key 'ParallelMaxJobs' -State $State -Fallback 8)
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.orchestrator.parallelUnavailable' -Fallback 'Parallel build not available: no independent projects detected') -State $State
                $choiceResult = New-BuildResult -Status Skipped -Operation 'target:14' -ReasonCode 'NoProjects' -Message 'Parallel build needs independent projects'
            }
        }
        'X' {
            $choiceResult = Invoke-GuildDistributedBuild -State $State -Projects $ParallelProjects
        }
        '15' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'aot' -BuildArgs (Get-DeployChoiceArgs -Kind Aot -State $State) -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        'A' { return (Invoke-RegisteredDeploy -Choice 'A' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'B' { return (Invoke-RegisteredDeploy -Choice 'B' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'V' { return (Invoke-RegisteredDeploy -Choice 'V' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'H' {
            if (Get-Command Show-GBuildHelp -ErrorAction SilentlyContinue) {
                Show-GBuildHelp
            } elseif (Get-Command Get-Help -ErrorAction SilentlyContinue) {
                Get-Help Start-GBuild
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m07') 'Warn' $State
            }
        }
        'R' {
            if (Get-Command Show-BuildReport -ErrorAction SilentlyContinue) {
                Show-BuildReport -State $State
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Report') -Fallback 'Report module not loaded.') -State $State
            }
        }
        'C' {
            if (Get-Command Get-CacheStatistics -ErrorAction SilentlyContinue) {
                Get-CacheStatistics -State $State
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m08') 'Warn' $State
            }
        }
        'L' {
            # versioning.generateChangelog gates changelog emission. The key was
            # declared in config but never read, so operators could not suppress
            # changelog generation. Defaults to true (previous behaviour).
            $genChangelog = $true
            if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
                $cfgGen = Get-ConfigValue -Path 'versioning.generateChangelog' -State $State
                if ($null -ne $cfgGen) { $genChangelog = [bool]$cfgGen }
            }
            if (-not $genChangelog) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m09') 'Gray' $State
            } elseif (Get-Command New-Changelog -ErrorAction SilentlyContinue) {
                New-Changelog -State $State
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m10') 'Warn' $State
            }
        }
        'W' { Invoke-HotReload -State $State -ProjPath $ProjPath -ProjectDir $projectDir -ProjectType $projectType }
        'G' { return (Invoke-RegisteredDeploy -Choice 'G' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'P' { return (Invoke-RegisteredDeploy -Choice 'P' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'F' { return (Invoke-RegisteredDeploy -Choice 'F' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'E' { return (Invoke-RegisteredDeploy -Choice 'E' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'K' { return (Invoke-RegisteredDeploy -Choice 'K' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        'Y' { return (Invoke-RegisteredDeploy -Choice 'Y' -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType) }
        '16' {
            if ($ProjectType -ne 'Avalonia') { throw (Get-LocaleMessage -Key 'log.orch.linuxDesktopNeedsAvalonia' -MessageArgs @([string]$ProjectType) -Fallback 'Linux Desktop publish requires an Avalonia project (current: {0})') }
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            # Fallback is the CONFIGURED deploy RID (Get-DeployDefaultRid),
            # not a hardcoded 'linux-x64' - that literal made a Linux Desktop
            # publish target linux-x64 even on Windows/macOS.
            $rid = if (Get-Command Get-RuntimeIdentifier -ErrorAction SilentlyContinue) { [string](Get-RuntimeIdentifier) } else { [string](Get-DeployDefaultRid -State ) }
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'linux' -BuildArgs @('-r', $rid, '--self-contained', 'true') -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        '17' {
            $null = Assert-BuildCommandAvailable -Command 'Start-ProjectPublish' -MessageKey 'log.orch.moduleBuildMissing' -Fallback 'Build module not loaded.'
            $rid = if ($State.OS -eq 'MacOS') { if (Get-Command Get-RuntimeIdentifier -ErrorAction SilentlyContinue) { [string](Get-RuntimeIdentifier) } else { 'osx-arm64' } } else { 'osx-x64' }
            $choiceResult = (Start-ProjectPublish -State $State -ProjPath $ProjPath -Tfm $DefaultTfm -OutputSubDir 'macos' -BuildArgs @('-r', $rid, '--self-contained', 'true') -ProjectType $ProjectType -Incremental:$Incremental -Detailed)
        }
        'N' {
            $null = Assert-BuildCommandAvailable -Command 'Publish-Environment' -MessageKey 'log.orch.moduleDeployTargetsMissing' -Fallback 'DeployTargets module not loaded.'
            if ($PipelineContext -and ($PipelineContext.ContainsKey('NewEnvironment')) -and $PipelineContext.NewEnvironment) {
                $null = Assert-BuildCommandAvailable -Command 'Add-DeployEnvironment' -MessageKey 'log.orch.deployEnvRegUnavailable' -Fallback 'DeployTargets environment registration is unavailable.'
                $ne = $PipelineContext.NewEnvironment
                Add-DeployEnvironment -State $State -Name ([string]$ne.Name) -Branch ([string]$ne.Branch) -Targets @($ne.Targets) | Out-Null
            }
            if (Get-Command Invoke-DeployGroup -ErrorAction SilentlyContinue) {
                $hasGroups = $false
                $og = Get-ConfigSection -State $State -Path 'deploy.order'
                if ($og -and ($og.PSObject.Properties.Name -contains 'groups') -and @($og.groups).Count -gt 0) { $hasGroups = $true }
                if ($hasGroups) {
                    $groupResult = Invoke-DeployGroup -State $State
                    if (-not (Test-RequiredResult -Result $groupResult -Operation 'deploy:group')) { throw (Get-LocaleMessage -Key 'log.orch.deployGroupFailed' -Fallback 'Deploy group failed.') }
                }
            }
            $fromEnv = Get-ConfigValue -Path 'deploy.promotion.from' -State $State -Default 'staging'
            $toEnv = Get-ConfigValue -Path 'deploy.promotion.to' -State $State -Default 'production'
            Write-Info (Get-LocaleMessage -Key 'log.orchestrator.m11' -MessageArgs @($fromEnv, $toEnv)) $State
            $choiceResult = Publish-Environment -State $State -From $fromEnv -To $toEnv
            if (-not (Test-RequiredResult -Result $choiceResult -Operation 'deploy:promotion')) { throw (Get-LocaleMessage -Key 'log.orch.envPromotionFailed' -MessageArgs @([string]$fromEnv, [string]$toEnv) -Fallback "Environment promotion '{0}' -> '{1}' failed.") }
        }
        'Z' {
            if (Get-Command Invoke-ChaosSuite -ErrorAction SilentlyContinue) {
                $suite = Invoke-ChaosSuite -State $State
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m12' -MessageArgs @($($suite.Status), $($suite.Passed), $($suite.Failed), $($suite.Skipped))) $(if ($suite.Status -eq 'Passed') { 'Succ' } elseif ($suite.Status -eq 'Partial') { 'Warn' } else { 'Err' }) $State
                # The suite result used to be log-only: $choiceResult stayed $null
                # and the tail of this function reported Succeeded/NoArtifact, so
                # a Degraded drill (drill harness broke) exited 0. A drill the
                # operator explicitly requested is an operation like any other:
                # Skipped (chaos disabled) and Passed/Partial (drills injected)
                # succeed; Degraded (a scenario Failed/Errored, i.e. the drill
                # itself broke) fails. Z is in Get-FatalActionChoices, so a
                # Failed verdict aborts the run instead of reporting success.
                $zStatus = if ($suite -and $suite.Status -eq 'Degraded') { 'Failed' } elseif ($null -eq $suite) { 'Failed' } else { 'Succeeded' }
                $zReason = if ($null -eq $suite) { 'NullResult' } elseif ($suite.Status -eq 'Degraded') { 'DrillFailed' } elseif ($suite.Status -eq 'Skipped') { 'Skipped' } else { 'OK' }
                $zDetail = if ($suite) { "Chaos suite: $($suite.Status) (passed $($suite.Passed), failed $($suite.Failed), skipped $($suite.Skipped))" } else { 'Chaos suite returned no result' }
                $choiceResult = New-OperationResult -Status $zStatus -Operation 'target:Z' -ReasonCode $zReason -Message $zDetail
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Chaos') -Fallback 'Chaos module not loaded.') -State $State
            }
        }
        'M' {
            if (Get-Command Get-AnomalyReport -ErrorAction SilentlyContinue) {
                $report = Get-AnomalyReport -State $State
                if ($report.Status -eq 'Disabled') {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m13') 'Gray' $State
                } elseif ($report.Status -eq 'InsufficientData') {
                    $anCfg = Get-AnomalyConfig -State $State
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m14' -MessageArgs @($($report.SampleCount), $($anCfg.minSamples))) 'Warn' $State
                } else {
                    $icon = if ($report.MaxSeverity -in @('High','Critical')) { 'Err' } elseif ($report.MaxSeverity -eq 'Medium') { 'Warn' } else { 'Succ' }
                    Write-Log "[ANOMALY] $($report.Summary)" $icon $State
                    foreach ($a in $report.Anomalies) {
                        $aIcon = switch ($a.Severity) { 'Critical' { 'Err' } 'High' { 'Err' } 'Medium' { 'Warn' } default { 'Warn' } }
                        Write-Log "  [$($a.Dimension)] $($a.Suggestion)" $aIcon $State
                    }
                    if (Get-Command Write-AnomalyHistory -ErrorAction SilentlyContinue) { [void](Write-AnomalyHistory -Report $report -State $State) }
                    [void](Send-AnomalyAlertIfNeeded -Report $report -State $State)
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('AnomalyDetector') -Fallback 'AnomalyDetector module not loaded.') -State $State
            }
        }
        'T' {
            $testFlags = Get-BuildTestConfig -State $State
            if (-not $testFlags.TestEnabled) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m15') 'Gray' $State
                $choiceResult = [pscustomobject]@{ Status = 'Succeeded'; Skipped = $true; Message = 'Tests disabled by configuration' }
                break
            }
            $testLang = if ($PipelineContext -and $PipelineContext.langInfo) {
                if ($PipelineContext.langInfo.Language) { [string]$PipelineContext.langInfo.Language } else { [string]$PipelineContext.langInfo }
            } else { $ProjectType }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningTests' -MessageArgs @([string]$testLang) -Fallback 'Running tests for {0}...')
            # Menu 'T' must not also run lint when lintEnabled is true; scope the
            # shared gate to this stage, while keeping the real implementation here.
            $testOnlyFlags = [PSCustomObject]@{ TestEnabled = $true; LintEnabled = $false }
            [void](Invoke-PluginTestAndLintGate -State $State -ProjectDir $ProjectDir -Language $testLang -TestFlags $testOnlyFlags -Detailed)
            $choiceResult = [pscustomobject]@{ Status = 'Succeeded' }
            Write-Done (Resolve-LogMessage -Key 'log.orchestrator.testsPassed' -MessageArgs @([string]$testLang) -Fallback 'Tests passed ({0})') -State $State
        }
        'I' {
            $testFlags = Get-BuildTestConfig -State $State
            if (-not $testFlags.LintEnabled) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m16') 'Gray' $State
                $choiceResult = [pscustomobject]@{ Status = 'Succeeded'; Skipped = $true; Message = 'Lint disabled by configuration' }
                break
            }
            $lintLang = if ($PipelineContext -and $PipelineContext.langInfo) {
                if ($PipelineContext.langInfo.Language) { [string]$PipelineContext.langInfo.Language } else { [string]$PipelineContext.langInfo }
            } else { $ProjectType }
            Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningLint' -MessageArgs @([string]$lintLang) -Fallback 'Running lint for {0}...')
            # Menu 'I' must not also run tests when testEnabled is true; scope the
            # shared gate to this stage, while keeping the real implementation here.
            $lintOnlyFlags = [PSCustomObject]@{ TestEnabled = $false; LintEnabled = $true }
            [void](Invoke-PluginTestAndLintGate -State $State -ProjectDir $ProjectDir -Language $lintLang -TestFlags $lintOnlyFlags -Detailed)
            $choiceResult = [pscustomobject]@{ Status = 'Succeeded' }
            Write-Done (Resolve-LogMessage -Key 'log.orchestrator.lintPassed' -MessageArgs @([string]$lintLang) -Fallback 'Lint passed ({0})') -State $State
        }
        'O' {
            Write-StepTitle 'MULTI-CLUSTER ORCHESTRATION' 'Info' $State
            if (Get-Command Get-AllClusters -ErrorAction SilentlyContinue) {
                $clusters = Get-AllClusters -State $State
                if ($clusters.Count -eq 0) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m17') 'Warn' $State
                } else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m18' -MessageArgs @($($clusters.Count))) 'Info' $State
                    foreach ($c in $clusters) {
                        $status = if ($c.Status -eq 'Ready') { 'Succ' } elseif ($c.Status -eq 'Registering') { 'Warn' } else { 'Err' }
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m19' -MessageArgs @($($c.Name), $($c.Region), $($c.Zone), $($c.Status), $($c.ActiveBuilds), $($c.MaxConcurrent))) $status $State
                    }
                }
                $healthy = Get-HealthyClusters -State $State
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m20' -MessageArgs @($($healthy.Count))) 'Info' $State
                # Level 5: wire cluster build submission when PipelineContext carries
                # a ClusterBuildSpec (opt-in, one-shot). Daemon entry points
                # (Start-ClusterHealthMonitor, Start/Stop-CoordinatorLeaderElection)
                # are intentionally NOT run synchronously here (infinite loops);
                # they are launched as background jobs only when cluster.enabled,
                # and Install-GBuildOperator is invoked for operator setup.
                try {
                    $spec = $null
                    if ($PipelineContext -and ($PipelineContext.ContainsKey('ClusterBuildSpec'))) { $spec = $PipelineContext.ClusterBuildSpec }
                    # Producer for ClusterBuildSpec. Submit-ClusterBuild /
                    # Get-ClusterBuildStatus / Wait-ClusterBuild / Stop-ClusterBuild
                    # / Install-GBuildOperator / Get-GBuildCRDs (~350 lines) were
                    # all gated on PipelineContext.ClusterBuildSpec, and NOTHING
                    # ever set that key - so the entire Kubernetes build
                    # submission path was unreachable in every run. Build the
                    # spec from the resolved project when
                    # build.cluster.submit.enabled is true.
                    if (-not $spec) {
                        try {
                            $submitEnabled = [bool](Get-ConfigValue -Path 'build.cluster.submit.enabled' -State $State -Default $false)
                            if ($submitEnabled -and (Get-Command Submit-ClusterBuild -ErrorAction SilentlyContinue)) {
                                # Submit-ClusterBuild declares -BuildSpec as
                                # [hashtable]; a PSCustomObject is not bindable.
                                # Resolve the name WITHOUT a nested (if ...) -
                                # that is not a subexpression on PS 5.1.
                                $specBase = ''
                                if ($State.ProjectRoot) { $specBase = [string]$State.ProjectRoot } else { $specBase = [string]$State.ScriptRoot }
                                $specProject = [string]$ProjectType
                                if ([string]::IsNullOrWhiteSpace($specProject)) { $specProject = (Split-Path $specBase -Leaf) }
                                $spec = @{
                                    ProjectName    = $specProject
                                    Namespace      = [string](Get-ConfigValue -Path 'build.cluster.job.namespace' -State $State -Fallback 'gbuild-jobs')
                                    BuilderImage   = [string](Get-ConfigValue -Path 'build.cluster.submit.builderImage' -State $State -Fallback (Get-ConfigValue -Path 'build.cluster.builderImage' -State $State -Fallback ''))
                                    ServiceAccount = [string](Get-ConfigValue -Path 'build.cluster.workloadIdentity.serviceAccount' -State $State -Fallback '')
                                    RepoRoot       = $specBase
                                    Command        = [string](Get-ConfigValue -Path 'build.cluster.submit.command' -State $State -Fallback '')
                                }
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m21' -MessageArgs @($($spec.ProjectName))) 'Info' $State
                            }
                        } catch { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m22' -MessageArgs @($($_.Exception.Message))) 'Warn' $State }
                    }
                    if ($spec -and (Get-Command Submit-ClusterBuild -ErrorAction SilentlyContinue) -and (Get-Command Wait-ClusterBuild -ErrorAction SilentlyContinue)) {
                        $sub = Submit-ClusterBuild -State $State -BuildSpec $spec
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m23' -MessageArgs @($($sub.BuildId), $($sub.Cluster))) 'Succ' $State
                        if (Get-Command Get-ClusterBuildStatus -ErrorAction SilentlyContinue) {
                            $st = Get-ClusterBuildStatus -BuildId $sub.BuildId -ClusterName $sub.Cluster -State $State
                            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m24' -MessageArgs @($($st.Status))) 'Info' $State
                        }
                        $waited = Wait-ClusterBuild -BuildId $sub.BuildId -ClusterName $sub.Cluster -State $State
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m25' -MessageArgs @($($waited.Status))) $(if ($waited.Status -eq 'Succeeded') { 'Succ' } else { 'Err' }) $State
                        # A submitted-and-waited remote build that did not succeed
                        # used to end here as an Err-colored log line with no
                        # verdict: the arm assigns nothing, the tail reports
                        # Succeeded/NoArtifact, and a failed cluster build exited
                        # 0. O is in Get-FatalActionChoices, so record the real
                        # verdict and let the pipeline abort on failure. (Viewing
                        # clusters without submitting still succeeds: this only
                        # runs after a real submit+wait.)
                        $oStatus = if ($waited -and $waited.Status -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
                        $oReason = if ($waited -and $waited.Status -eq 'Succeeded') { 'OK' } else { 'ClusterBuildFailed' }
                        $oMsg = if ($waited) { "Cluster build $($sub.BuildId) on $($sub.Cluster): $($waited.Status)" } else { "Cluster build $($sub.BuildId) on $($sub.Cluster) returned no result" }
                        $choiceResult = New-OperationResult -Status $oStatus -Operation 'target:O' -ReasonCode $oReason -Message $oMsg -Details $waited
                    }
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m26' -MessageArgs @($($_.Exception.Message))) 'Warn' $State
                }
                try {
                    $clusterEnabled = $false
                    try {
                        # Canonical path is build.cluster (same as Menu 'O'
                        # Supported flag + ClusterOrchestrator init). The old
                        # top-level 'cluster' path never exists in config, so
                        # this gate must read build.cluster or the daemon
                        # wiring below (health job, leader election, operator)
                        # silently never runs.
                        $cc = Get-ConfigSection -State $State -Path 'build.cluster'
                        if ($cc -and ($cc.PSObject.Properties.Name -contains 'enabled')) { $clusterEnabled = [bool]$cc.enabled }
                    } catch { }
                    if ($clusterEnabled) {
                        # Health monitor + leader election run as background jobs (never block the menu).
                        # Both jobs re-derive their own State from gbuild.config.json. The previous
                        # version passed `-State $null` into the job, so
                        # Initialize-ClusterOrchestrator saw no BuildConfig, $script:ClusterCache
                        # stayed empty, and the health monitor spun on an empty collection with
                        # Start-Sleep 30 forever - a permanently running background job that could
                        # never observe anything, in every session where build.cluster.enabled is
                        # true (the shipped default).
                        $jobModules = @('Modules/ConfigProvider.psm1','Modules/Logging.psm1','Modules/PathUtils.psm1','Modules/Environment.psm1','Modules/ErrorHandling.psm1','Modules/SDK.psm1','Modules/EventBus.psm1','Modules/BuildConstants.psm1','Modules/ClusterOrchestrator.psm1')
                        $monitorBody = {
                            param($sr, $mods, $pr)
                            foreach ($m in $mods) { Import-Module (Join-Path $sr $m) -Force -DisableNameChecking -ErrorAction SilentlyContinue }
                            $st = [PSCustomObject]@{ ScriptRoot = $sr; ProjectRoot = $pr; BuildConfig = $null; WorkingDir = $pr }
                            try { $st = Initialize-BuildConfigState -State $st } catch { }
                            Start-ClusterHealthMonitor -State $st
                        }
                        if (Get-Command Start-ClusterHealthMonitor -ErrorAction SilentlyContinue) {
                            $existingHM = Get-Job -Name 'gbuild-cluster-health' -ErrorAction SilentlyContinue
                            if (-not $existingHM) {
                                Start-Job -Name 'gbuild-cluster-health' -ScriptBlock $monitorBody -ArgumentList @([string]$State.ScriptRoot, $jobModules, [string]$State.ProjectRoot) -ErrorAction SilentlyContinue | Out-Null
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m27') 'Gray' $State
                            }
                        }
                        # Leader election was exported, implemented (83 lines of K8s Lease
                        # acquire/renew/release) and never started: the block only logged
                        # "available as background job" and did nothing, so the whole
                        # coordination.k8s.io/v1 path was unreachable. Start it for real.
                        if (Get-Command Start-CoordinatorLeaderElection -ErrorAction SilentlyContinue) {
                            $existingLE = Get-Job -Name 'gbuild-coordinator-leader' -ErrorAction SilentlyContinue
                            if (-not $existingLE) {
                                $leaderBody = {
                                    param($sr, $mods, $pr)
                                    foreach ($m in $mods) { Import-Module (Join-Path $sr $m) -Force -DisableNameChecking -ErrorAction SilentlyContinue }
                                    $st = [PSCustomObject]@{ ScriptRoot = $sr; ProjectRoot = $pr; BuildConfig = $null; WorkingDir = $pr }
                                    try { $st = Initialize-BuildConfigState -State $st } catch { }
                                    Start-CoordinatorLeaderElection -State $st
                                }
                                Start-Job -Name 'gbuild-coordinator-leader' -ScriptBlock $leaderBody -ArgumentList @([string]$State.ScriptRoot, $jobModules, [string]$State.ProjectRoot) -ErrorAction SilentlyContinue | Out-Null
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m28') 'Gray' $State
                            }
                            # StopLeaderElection previously had no producer either.
                            $stopRequested = $false
                            try {
                                if ($PipelineContext -and ($PipelineContext.ContainsKey('StopLeaderElection'))) { $stopRequested = [bool]$PipelineContext.StopLeaderElection }
                            } catch { }
                            # Reads build.cluster.stopLeaderElection, the key that is
                            # actually SHIPPED in gbuild.config.json and declared in the
                            # schema. The old path 'build.cluster.coordinator.stopLeaderElection'
                            # is unshippable (build.cluster is additionalProperties:false),
                            # so this always evaluated the $false default and the shipped
                            # knob was dead.
                            if (-not $stopRequested) { try { $stopRequested = [bool](Get-ConfigValue -Path 'build.cluster.stopLeaderElection' -State $State -Default $false) } catch { } }
                            if ($stopRequested) {
                                $job = Get-Job -Name 'gbuild-coordinator-leader' -ErrorAction SilentlyContinue
                                if ($job) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m29') 'Gray' $State
                            }
                        }
                        if (Get-Command Install-GBuildOperator -ErrorAction SilentlyContinue) {
                            $opRequested = $false
                            try { if ($PipelineContext -and ($PipelineContext.ContainsKey('InstallOperator'))) { $opRequested = [bool]$PipelineContext.InstallOperator } } catch { }
                            # Producer from config: build.cluster.operator.install
                            if (-not $opRequested) { try { $opRequested = [bool](Get-ConfigValue -Path 'build.cluster.operator.install' -State $State -Default $false) } catch { } }
                            if ($opRequested) { Install-GBuildOperator -State $State | Out-Null }
                        }
                        # Reference Stop entry point so it stays wired (no-op unless election running).
                        if (Get-Command Stop-CoordinatorLeaderElection -ErrorAction SilentlyContinue) {
                            $stopRequested = $false
                            try { if ($PipelineContext -and ($PipelineContext.ContainsKey('StopLeaderElection'))) { $stopRequested = [bool]$PipelineContext.StopLeaderElection } } catch { }
                            if ($stopRequested) { Stop-CoordinatorLeaderElection -State $State }
                        }
                    }
                } catch {
                    # benign: cluster daemons must never break the menu
                }
            } else {
                Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('ClusterOrchestrator') -Fallback 'ClusterOrchestrator module not loaded.') -State $State
            }
        }
        default {
            # Extensibility: config-driven custom menu entries (build.menu.customEntries).
            # The MenuConfig entry carries a Handler (command name or scriptblock).
            $entry = if ($MenuConfig -and $MenuConfig.ContainsKey($Choice)) { $MenuConfig[$Choice] } else { $null }
            if ($entry -and $entry.Handler) {
                if ($entry.Handler -is [scriptblock]) {
                    & $entry.Handler -State $State -ProjPath $ProjPath -ProjectDir $ProjectDir -ProjectType $ProjectType
                } elseif (Get-Command $entry.Handler -ErrorAction SilentlyContinue) {
                    & $entry.Handler -State $State -ProjPath $ProjPath -ProjectDir $ProjectDir -ProjectType $ProjectType
                } else {
                    Write-Fail (Resolve-LogMessage -Key 'log.menu.handlerNotFound' -MessageArgs @([string]$entry.Handler) -Fallback 'Custom menu handler ''{0}'' not found') -State $State
                }
            } else {
                throw (Get-LocaleMessage -Key 'log.orch.unknownChoice' -MessageArgs @([string]$Choice) -Fallback 'Unknown choice: {0}')
            }
        }
    }
    # SINGLE validation point for build-target results.
    # This list is the canonical "these menu choices produce a build artifact"
    # set. It used to be duplicated verbatim in the pipeline body (with a
    # narrower list) which meant the dispatcher always threw FIRST and the
    # pipeline copy was dead code - its Write-Fail could never run, and its
    # $ctx.buildOk assignment only ever saw success because a failure had
    # already propagated. The pipeline now reads the verdict instead of
    # recomputing it.
    if ($Choice -in (Get-BuildTargetChoices)) {
        if (-not (Test-RequiredResult -Result $choiceResult -Operation "target:$Choice")) {
            $message = if ($choiceResult -and $choiceResult.Message) { [string]$choiceResult.Message } else { "Build target '$Choice' failed" }
            throw $message
        }
    }
    # UNIFORM RETURN CONTRACT. Operations that produce no build artifact - the
    # doctor/security-scan/cache-stats/changelog/gitHub/chaos/anomaly/cluster
    # arms, and '0' (quit) - assign nothing to $choiceResult, so this function
    # used to return $null for them. The pipeline's non-build branch then ran
    # ConvertTo-OperationResult -Value $null, which is Failed/NullResult, and
    # because those same keys (13, S, C, L, ...) are in the privileged set it
    # threw "Target 'X' failed" AFTER the operation had already succeeded. Since
    # Show-GuildMenu answers '13' when non-interactive, EVERY non-interactive
    # build reported failure. Reaching here means the arm completed without
    # throwing, so an explicit Succeeded verdict is the truthful answer.
    if ($null -eq $choiceResult) {
        return New-OperationResult -Status Succeeded -Operation "target:$Choice" -ReasonCode 'NoArtifact' -Message "Target '$Choice' completed (produces no build artifact)"
    }
    return $choiceResult
}

<#
.SYNOPSIS
    Returns the canonical list of menu choices that produce a build artifact.
.DESCRIPTION
    Single source for the build-target verdict. Used by Invoke-GuildChoice to
    validate and by the pipeline to decide whether the result is a build
    result (and therefore whether to run the post-build test/lint stages).
    Previously declared three times in Orchestrator + Menu with drifting
    membership.
#>

