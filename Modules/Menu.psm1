# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Menu.psm1 - build menu configuration and rendering


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Project', 'Environment')

# Fallback English labels for all menu keys (used when locale resources are unavailable)
$script:MenuFallbackLabels = @{
    'menu.debugAndroid'           = 'Debug on Android Device'
    'menu.debugAndroidTitle'      = 'Attach debugger to running Android app'
    'menu.publishApk'             = 'Publish Android APK'
    'menu.publishApkTitle'        = 'Build and sign release APK'
    'menu.publishAab'             = 'Publish Android App Bundle (AAB)'
    'menu.publishAabTitle'        = 'Build and sign release AAB for Play Store'
    'menu.publishIos'             = 'Publish iOS'
    'menu.publishIosTitle'        = 'Build and sign iOS IPA'
    'menu.publishMacCatalyst'     = 'Publish Mac Catalyst'
    'menu.publishMacCatalystTitle' = 'Build and sign Mac Catalyst app'
    'menu.publishMacOs'           = 'Publish macOS App'
    'menu.publishMacOsTitle'      = 'Build macOS app (osx-x64/osx-arm64)'
    'menu.publishWpf'             = 'Publish WPF'
    'menu.publishWpfTitle'        = 'Publish Windows Presentation Foundation app'
    'menu.publishConsole'         = 'Publish Console App'
    'menu.publishConsoleTitle'    = 'Publish Console Application'
    'menu.buildLibrary'           = 'Build Library'
    'menu.buildLibraryTitle'      = 'Build Class Library (DLL)'
    'menu.publishNativeAot'       = 'Publish Native AOT'
    'menu.publishNativeAotTitle'  = 'Publish Native AOT executable'
    'menu.publishAvalonia'        = 'Publish Avalonia'
    'menu.publishAvaloniaTitle'   = 'Publish Avalonia cross-platform app'
    'menu.publishWeb'             = 'Publish Web'
    'menu.publishWebTitle'        = 'Publish ASP.NET Core Web App'
    'menu.publishMsix'            = 'Publish MSIX'
    'menu.publishMsixTitle'       = 'Package as MSIX for Windows Store'
    'menu.githubCloudBuild'       = 'GitHub Cloud Build'
    'menu.githubCloudBuildTitle'  = 'Trigger GitHub Actions cloud build'
    'menu.parallelBuild'          = 'Parallel Build'
    'menu.parallelBuildTitle'     = 'Build independent projects in parallel'
    'menu.distributedBuild'       = 'Distributed Build'
    'menu.distributedBuildTitle'  = 'Distribute build across remote hosts'
    'menu.hotReload'              = 'Hot Reload'
    'menu.hotReloadTitle'         = 'Start hot reload development server'
    'menu.doctor'                 = 'Doctor'
    'menu.doctorTitle'            = 'Run health checks and diagnostics'
    'menu.security'               = 'Security'
    'menu.securityTitle'          = 'Run security scans (SAST, secrets, deps)'
    'menu.help'                   = 'Help'
    'menu.helpTitle'              = 'Show help and documentation'
    'menu.report'                 = 'Report'
    'menu.reportTitle'            = 'Show build reports and metrics'
    'menu.cache'                  = 'Cache'
    'menu.cacheTitle'             = 'Manage build cache'
    'menu.changelog'              = 'Changelog'
    'menu.changelogTitle'         = 'Generate changelog'
    'menu.exit'                   = 'Exit'
    'menu.exitTitle'              = 'Exit gbuild'
    'menu.deployAzure'            = 'Deploy to Azure'
    'menu.deployAzureTitle'       = 'Deploy to Azure App Service'
    'menu.deployAws'              = 'Deploy to AWS'
    'menu.deployAwsTitle'         = 'Deploy to AWS Elastic Beanstalk'
    'menu.deployVercel'           = 'Deploy to Vercel'
    'menu.deployVercelTitle'      = 'Deploy to Vercel platform'
    'menu.deployGcp'              = 'Deploy to GCP'
    'menu.deployGcpTitle'         = 'Deploy to Google Cloud Platform'
    'menu.deployAzureFunctions'   = 'Deploy Azure Functions'
    'menu.deployAzureFunctionsTitle' = 'Deploy Azure Functions app'
    'menu.deployAwsLambda'        = 'Deploy AWS Lambda'
    'menu.deployAwsLambdaTitle'   = 'Deploy AWS Lambda function'
    'menu.dockerCi'               = 'Docker CI'
    'menu.dockerCiTitle'          = 'Build and push Docker image'
    'menu.azurePipelines'         = 'Azure Pipelines'
    'menu.azurePipelinesTitle'    = 'Trigger Azure Pipelines build'
    'menu.promote'                = 'Promote'
    'menu.promoteTitle'           = 'Promote build to next environment'
    'menu.chaos'                  = 'Chaos'
    'menu.chaosTitle'             = 'Run chaos engineering scenarios'
    'menu.anomaly'                = 'Anomaly'
    'menu.anomalyTitle'           = 'Show anomaly detection report'
    'menu.cluster'                = 'Multi-Cluster'
    'menu.clusterTitle'           = 'Show multi-cluster orchestration status'
    'menu.runTest'                = 'Run Tests'
    'menu.runTestTitle'           = 'Execute test suite'
    'menu.runLint'                = 'Run Lint'
    'menu.runLintTitle'           = 'Execute linter'
    'menu.buildDefault'           = 'Build Default'
    'menu.buildDefaultTitle'      = 'Build with default settings'
    'menu.publishMauiDesktop'     = 'Publish MAUI Desktop'
    'menu.publishMauiDesktopTitle' = 'Publish MAUI Windows desktop app'
    'menu.select'                 = 'Select option'
    'menu.prompt'                 = 'Enter your choice'
}

function Get-MenuLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$Key)

Set-StrictMode -Version 1.0
    if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
        $msg = Get-LocaleMessage -Key $Key
        if ($msg -and $msg -ne $Key) { return [string]$msg }
    }
    if ($script:MenuFallbackLabels.ContainsKey($Key)) { return $script:MenuFallbackLabels[$Key] }
    return $Key
}

<#
.SYNOPSIS
    Creates a menu configuration hashtable with build options based on project type.
.DESCRIPTION
    Builds a hashtable of menu entries (1-13, W, D, S, 0) with labels, titles, and
    supported flags determined by the project type and target frameworks.
.PARAMETER ProjectType
    The project type (e.g. MAUI, Web, WinForms, Console, Library).
.PARAMETER AndroidTfm
    The Android target framework moniker (if applicable).
.PARAMETER WinTfm
    The Windows target framework moniker (if applicable).
.PARAMETER OS
    The operating system (Windows, MacOS, Linux).
#>
function New-GuildMenuConfig {
    [CmdletBinding()]
    param([string]$ProjectType, [string]$AndroidTfm, [string]$WinTfm, [string]$OS, [string[]]$ParallelProjects, [PSCustomObject]$State)
    $isMaui = ($ProjectType -eq 'MAUI')
    $isWeb = ($ProjectType -in @('Web', 'BlazorWasm'))
    $isDesktop = ($ProjectType -in @('WinForms', 'WinExe', 'WPF', 'WinUI'))
    $isConsole = ($ProjectType -eq 'Console')
    $isLib = ($ProjectType -eq 'Library')
    $dotnetTypes = Get-ProjectTypes -State $State
    $isNonDotNet = $ProjectType -and $ProjectType -notin $dotnetTypes
    $hasParallel = ($ParallelProjects -and $ParallelProjects.Count -gt 1)
    # Locale-aware labels: Get-LocaleMessage (when Locale module is loaded) with
    # English fallback so behaviour is identical without the Locale module.
    $l7 = if ($ProjectType -eq 'Web') { Get-MenuLabel -Key 'menu.publishWeb' } else { Get-MenuLabel -Key 'menu.publishBlazorWasm' }
    $t7 = if ($ProjectType -eq 'Web') { Get-MenuLabel -Key 'menu.publishWebTitle' } else { Get-MenuLabel -Key 'menu.publishBlazorWasmTitle' }
    $l8 = if ($isMaui) { Get-MenuLabel -Key 'menu.publishMauiDesktop' } else { Get-MenuLabel -Key 'menu.publishDesktop' }
    $t8 = if ($isMaui) { Get-MenuLabel -Key 'menu.publishMauiDesktopTitle' } else { Get-MenuLabel -Key 'menu.publishDesktopTitle' }
    $menu = @{
        '1' = @{ Label = Get-MenuLabel -Key 'menu.debugAndroid'; Title = Get-MenuLabel -Key 'menu.debugAndroidTitle'; Supported = ($isMaui -and $AndroidTfm) }
        '2' = @{ Label = Get-MenuLabel -Key 'menu.publishApk'; Title = Get-MenuLabel -Key 'menu.publishApkTitle'; Supported = ($isMaui -and $AndroidTfm) }
        '3' = @{ Label = Get-MenuLabel -Key 'menu.publishAab'; Title = Get-MenuLabel -Key 'menu.publishAabTitle'; Supported = ($isMaui -and $AndroidTfm) }
        '4' = @{ Label = Get-MenuLabel -Key 'menu.publishIos'; Title = Get-MenuLabel -Key 'menu.publishIosTitle'; Supported = ($isMaui -and $OS -eq 'MacOS') }
        '5' = @{ Label = Get-MenuLabel -Key 'menu.publishMacCatalyst'; Title = Get-MenuLabel -Key 'menu.publishMacCatalystTitle'; Supported = ($isMaui -and $OS -eq 'MacOS') }
        '17' = @{ Label = Get-MenuLabel -Key 'menu.publishMacOs'; Title = Get-MenuLabel -Key 'menu.publishMacOsTitle'; Supported = ($ProjectType -in $dotnetTypes) }
        '6' = @{ Label = Get-MenuLabel -Key 'menu.publishMsix'; Title = Get-MenuLabel -Key 'menu.publishMsixTitle'; Supported = ($isMaui -and $WinTfm -and $OS -eq 'Windows') }
        '7' = @{ Label = $l7; Title = $t7; Supported = $isWeb }
        '8' = @{ Label = $l8; Title = $t8; Supported = (($ProjectType -in @('WinForms', 'WinExe', 'WinUI') -or ($isMaui -and $WinTfm)) -and $OS -eq 'Windows') }
        '9' = @{ Label = Get-MenuLabel -Key 'menu.publishWpf'; Title = Get-MenuLabel -Key 'menu.publishWpfTitle'; Supported = ($ProjectType -eq 'WPF' -and $OS -eq 'Windows') }
        '10' = @{ Label = Get-MenuLabel -Key 'menu.publishConsole'; Title = Get-MenuLabel -Key 'menu.publishConsoleTitle'; Supported = $isConsole }
        '11' = @{ Label = Get-MenuLabel -Key 'menu.buildLibrary'; Title = Get-MenuLabel -Key 'menu.buildLibraryTitle'; Supported = $isLib }
        '12' = @{ Label = Get-MenuLabel -Key 'menu.buildDefault'; Title = Get-MenuLabel -Key 'menu.buildDefaultTitle'; Supported = ($ProjectType -eq 'Unknown' -or -not $ProjectType -or $isNonDotNet) }
        '13' = @{ Label = Get-MenuLabel -Key 'menu.githubCloudBuild'; Title = Get-MenuLabel -Key 'menu.githubCloudBuildTitle'; Supported = $true }
        '14' = @{ Label = Get-MenuLabel -Key 'menu.parallelBuild'; Title = Get-MenuLabel -Key 'menu.parallelBuildTitle'; Supported = $hasParallel }
        '15' = @{ Label = Get-MenuLabel -Key 'menu.publishNativeAot'; Title = Get-MenuLabel -Key 'menu.publishNativeAotTitle'; Supported = ($isWeb -or $isConsole -or $isLib -or $isDesktop) }
        '16' = @{ Label = Get-MenuLabel -Key 'menu.publishAvalonia'; Title = Get-MenuLabel -Key 'menu.publishAvaloniaTitle'; Supported = ($ProjectType -eq 'Avalonia') }
        'X' = @{ Label = Get-MenuLabel -Key 'menu.distributedBuild'; Title = Get-MenuLabel -Key 'menu.distributedBuildTitle'; Supported = ($hasParallel -and (Get-ConfigValue -Path 'distributed.enabled' -State $State -Type bool)) }
        'W' = @{ Label = Get-MenuLabel -Key 'menu.hotReload'; Title = Get-MenuLabel -Key 'menu.hotReloadTitle'; Supported = ($isWeb -or $isDesktop -or $isConsole) }
        'D' = @{ Label = Get-MenuLabel -Key 'menu.doctor'; Title = Get-MenuLabel -Key 'menu.doctorTitle'; Supported = $true }
        'S' = @{ Label = Get-MenuLabel -Key 'menu.security'; Title = Get-MenuLabel -Key 'menu.securityTitle'; Supported = $true }
        'H' = @{ Label = Get-MenuLabel -Key 'menu.help'; Title = Get-MenuLabel -Key 'menu.helpTitle'; Supported = $true }
        'R' = @{ Label = Get-MenuLabel -Key 'menu.report'; Title = Get-MenuLabel -Key 'menu.reportTitle'; Supported = $true }
        'C' = @{ Label = Get-MenuLabel -Key 'menu.cache'; Title = Get-MenuLabel -Key 'menu.cacheTitle'; Supported = $true }
        'L' = @{ Label = Get-MenuLabel -Key 'menu.changelog'; Title = Get-MenuLabel -Key 'menu.changelogTitle'; Supported = $true }
        '0' = @{ Label = Get-MenuLabel -Key 'menu.exit'; Title = Get-MenuLabel -Key 'menu.exitTitle'; Supported = $true }
        'A' = @{ Label = Get-MenuLabel -Key 'menu.deployAzure'; Title = Get-MenuLabel -Key 'menu.deployAzureTitle'; Supported = $true }
        'B' = @{ Label = Get-MenuLabel -Key 'menu.deployAws'; Title = Get-MenuLabel -Key 'menu.deployAwsTitle'; Supported = $true }
        'V' = @{ Label = Get-MenuLabel -Key 'menu.deployVercel'; Title = Get-MenuLabel -Key 'menu.deployVercelTitle'; Supported = $true }
        'G' = @{ Label = Get-MenuLabel -Key 'menu.deployGcp'; Title = Get-MenuLabel -Key 'menu.deployGcpTitle'; Supported = $true }
        'P' = @{ Label = Get-MenuLabel -Key 'menu.deployK8s'; Title = Get-MenuLabel -Key 'menu.deployK8sTitle'; Supported = $true }
        'F' = @{ Label = Get-MenuLabel -Key 'menu.deployAzureFunctions'; Title = Get-MenuLabel -Key 'menu.deployAzureFunctionsTitle'; Supported = $true }
        'E' = @{ Label = Get-MenuLabel -Key 'menu.deployAwsLambda'; Title = Get-MenuLabel -Key 'menu.deployAwsLambdaTitle'; Supported = $true }
        'K' = @{ Label = Get-MenuLabel -Key 'menu.dockerCi'; Title = Get-MenuLabel -Key 'menu.dockerCiTitle'; Supported = $true }
        'Y' = @{ Label = Get-MenuLabel -Key 'menu.azurePipelines'; Title = Get-MenuLabel -Key 'menu.azurePipelinesTitle'; Supported = $true }
        'N' = @{ Label = Get-MenuLabel -Key 'menu.promote'; Title = Get-MenuLabel -Key 'menu.promoteTitle'; Supported = $true }
        'Z' = @{ Label = Get-MenuLabel -Key 'menu.chaos'; Title = Get-MenuLabel -Key 'menu.chaosTitle'; Supported = $true }
        'M' = @{ Label = Get-MenuLabel -Key 'menu.anomaly'; Title = Get-MenuLabel -Key 'menu.anomalyTitle'; Supported = $true }
        'O' = @{ Label = Get-MenuLabel -Key 'menu.cluster'; Title = Get-MenuLabel -Key 'menu.clusterTitle'; Supported = [bool](Get-ConfigValue -Path 'build.cluster.enabled' -State $State -Type bool) }
        # Non-.NET language actions (visible when project is detected as non-.NET)
        'T' = @{ Label = Get-MenuLabel -Key 'menu.runTest'; Title = Get-MenuLabel -Key 'menu.runTestTitle'; Supported = $isNonDotNet }
        'I' = @{ Label = Get-MenuLabel -Key 'menu.runLint'; Title = Get-MenuLabel -Key 'menu.runLintTitle'; Supported = $isNonDotNet }
    }
    # Extensibility: merge config-driven custom menu entries (build.menu.customEntries)
    # so users can add menu items (with a handler command/function) without editing core.
    # Level 5 guard: built-in keys (1-16, A-Z letters) are reserved. A custom entry
    # colliding with a built-in key is SKIPPED with a warning so core flows
    # (e.g. Z=Chaos, M=Anomaly) can never be silently shadowed. Use a free key
    # (e.g. Q) for custom entries. Pass "override":true to intentionally replace.
    $customEntries = Get-ConfigValue -Path 'build.menu.customEntries' -State $State
    if ($customEntries) {
        foreach ($entry in $customEntries) {
            if ($entry -and $entry.key -and $entry.label) {
                $allowOverride = $false
                try {
                    if ($entry.PSObject.Properties.Name -contains 'override') { $allowOverride = [bool]$entry.override }
                    elseif ($entry -is [System.Collections.IDictionary] -and $entry.ContainsKey('override')) { $allowOverride = [bool]$entry['override'] }
                } catch { $allowOverride = $false }
                if ($menu.ContainsKey($entry.key) -and -not $allowOverride) {
                    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.menu.customKeyCollision' -MessageArgs @([string]$entry.key, [string]$menu[$entry.key].Label) -Fallback '[MENU] Custom entry key ''{0}'' collides with built-in ''{1}'' - skipped (use a free key like Q or set override:true)') 'Warn' $State }
                    continue
                }
                $menu[$entry.key] = @{ Label = $entry.label; Title = if ($entry.title) { $entry.title } else { $entry.label.ToUpper() }; Supported = $true; Handler = $entry.handler }
            }
        }
    }
    # L5 UI/policy coherence: an entry the RBAC allow-list denies must not be
    # advertised as Supported, otherwise the menu offers a choice that
    # Test-ActionAllowed rejects on selection (a dead-end for the operator).
    # Privilege set comes from BuildConstants.RbacPrivilegedActions; non-privileged
    # keys (0, H, D, R, 1-12, T, I, ...) are never filtered.
    try {
        if (Get-Command Test-ActionAllowed -ErrorAction SilentlyContinue) {
            # Single source: RBAC.Get-RbacPrivilegedActions. This was a
            # 3rd hand-written copy of the privileged-action list (the other two
            # lived inside Test-ActionAllowed) and drifted from them.
            #
            # Both fallbacks below carry N. They previously did not, while the
            # owner BuildConstants.RbacPrivilegedActions and
            # RBAC.Get-RbacPrivilegedActions both did - the same
            # regression BuildConstants:265-269 documents having already been
            # fixed once. N is menu.promote, staging -> production: a live
            # environment change. On the branch where Get-BuildConstant is
            # unavailable it was classified NON-privileged, so the loop below
            # skipped Test-ActionAllowed for it and the UI offered a promotion
            # that the gate would never check. Only this module's fallback can
            # still diverge, which is why the list is written once per branch
            # with the same 14 keys rather than 13.
            $privilegedKeys = $null
            if (Get-Command Get-RbacPrivilegedActions -ErrorAction SilentlyContinue) {
                $privilegedKeys = @(Get-RbacPrivilegedActions -Kind 'privileged')
            } elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                $privilegedKeys = @(Get-BuildConstant -Key 'RbacPrivilegedActions' -State $State -Fallback @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13'))
            } else {
                $privilegedKeys = @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13')
            }
            foreach ($key in @($menu.Keys)) {
                if ($key -notin $privilegedKeys) { continue }
                if (-not $menu[$key].Supported) { continue }
                $verdict = Test-ActionAllowed -State $State -Action $key
                if ($verdict -and ($verdict.Allowed -eq $false)) {
                    $menu[$key].Supported = $false
                    $menu[$key].DeniedReason = [string]$verdict.Reason
                }
            }
        }
    } catch { }
    return $menu
}

<#
.SYNOPSIS
    Displays the interactive build menu and returns the user's choice.
.DESCRIPTION
    Renders the menu entries from the config hashtable with color-coded labels,
    prompts for input, and returns the selected key. In non-interactive or GitHub
    mode, returns '13' (GitHub Build) automatically.
.PARAMETER MenuConfig
    Hashtable of menu entries created by New-GuildMenuConfig.
.PARAMETER State
    The build state object containing configuration and color settings.
.PARAMETER GitHub
    If specified, skips interactive display and returns GitHub Build choice.
.OUTPUTS
    string
#>
function Show-GuildMenu {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$MenuConfig, [PSCustomObject]$State, [switch]$GitHub, [switch]$Simple)
    if (Get-Command Test-InteractiveSession -ErrorAction SilentlyContinue) {
        $isInteractive = Test-InteractiveSession -State $State
        if ($GitHub -or -not $isInteractive) { Write-Log (Resolve-LogMessage -Key 'log.menu.nonInteractiveGithub' -Fallback '[MODE] Non-interactive -> GitHub Build') "Info" $State; return '13' }
    } else { return '13' }
    $mo = if ($Simple) { @('12','D','S','H','R','C','L','13','0') } else { @('1','2','3','4','5','6','7','8','9','10','11','12','14','15','16','T','I','A','B','V','G','P','F','E','K','Y','N','W','D','S','H','R','C','L','13','0','X','Z','M','O') }
    # Level 5: custom menu keys (build.menu.customEntries) must also render.
    # Append any Supported MenuConfig key not in the hardcoded order so future
    # custom entries (e.g. Q) are never orphaned by the order list.
    foreach ($k in @($MenuConfig.Keys)) {
        if ($k -notin $mo) { $mo += @($k) }
    }
    $cc = @{}
    foreach ($k in $mo) {
        $item = $MenuConfig[$k]
        if (-not $item -or -not $item.Supported) { continue }
        $c = if ($k -in @('W','2','3','7')) { Resolve-SafeColor -ColorName 'Info' -State $State -Fallback 'Cyan' }
        elseif ($k -in @('4','5')) { Resolve-SafeColor -ColorName 'Header' -State $State -Fallback 'Magenta' }
        elseif ($k -in @('D','S')) { Resolve-SafeColor -ColorName 'Warn' -State $State -Fallback 'Yellow' }
        elseif ($k -in @('H','R','C','L')) { Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'DarkGray' }
        elseif ($k -in @('13','14','15','16','A','B','V','G','P','F','E','K','Y','N','X','Z','M','O')) { Resolve-SafeColor -ColorName 'Succ' -State $State -Fallback 'Green' }
        elseif ($k -eq '0') { Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'DarkGray' }
        else { Resolve-SafeColor -ColorName 'Info' -State $State -Fallback 'DarkYellow' }
        $cc[$k] = $c
    }
    Write-Log "`n  [INPUT] $(Get-MenuLabel -Key 'menu.prompt')" (Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'DarkGray') $State; Write-Log ' ' "White" $State
    foreach ($k in $mo) {
        $item = $MenuConfig[$k]
        if ($item -and $item.Supported) {
            Write-Log (("  [{0}]" -f $k).PadRight(7) + " " + $item.Label) $cc[$k] $State
        }
    }
    Write-Log ' ' "White" $State
    $supported = @($mo | Where-Object { $MenuConfig[$_].Supported })
    $choice = if (Test-InteractiveSession -State $State) { Read-Host (Get-MenuLabel -Key 'menu.select') } else { $supported[0] }
    if ([string]::IsNullOrWhiteSpace($choice)) { return '0' }
    return $choice.Trim()
}

<#
.SYNOPSIS
    Sample custom-menu handler demonstrating config-driven extensibility.
.DESCRIPTION
    Prints a concise summary of the resolved build environment. Registered as the
    handler for the sample custom menu entry 'Q' (build.menu.customEntries). Any
    user-defined handler can follow the same parameter contract (State, ProjPath,
    ProjectDir, ProjectType).
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Optional path to the active project file.
.PARAMETER ProjectDir
    Optional path to the active project directory.
.PARAMETER ProjectType
    Optional resolved project type (Web, Console, ...).
#>
function Show-BuildEnvironmentSummary {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$ProjPath,
        [string]$ProjectDir,
        [string]$ProjectType
    )
    Write-Log (Resolve-LogMessage -Key 'log.menu.envSummary' -Fallback '[ENV] Build environment summary') 'Info' $State
    # Enterprise environment model: single source for OS/arch/PSVersion/SDKs/tools/paths.
    # Gracefully degrades when the Environment module is unavailable (standalone use).
    $model = $null
    if (Get-Command Get-EnvironmentModel -ErrorAction SilentlyContinue) {
        try { $model = Get-EnvironmentModel -State $State } catch { $model = $null }
    }
    # Scoped logging: resolve the active toolchain for THIS project type so the
    # summary leads with what matters to the current build (full SDK dump stays
    # below for diagnostics).
    $activeToolchain = ''
    try {
        if ($ProjectType -and (Get-Command Resolve-PluginForLanguage -ErrorAction SilentlyContinue)) {
            $plg = Resolve-PluginForLanguage -Language $ProjectType
            if ($plg -and $plg.Info -and $plg.Info.ToolName) { $activeToolchain = "$($plg.Info.ToolName) via $($plg.Info.Name) plugin" }
        }
    } catch { $activeToolchain = '' }
    if (-not $activeToolchain) {
        $activeToolchain = if ($ProjectType -in @('Web','Console','Library','WinForms','WPF','MAUI','BlazorWasm')) { 'dotnet via Dotnet plugin' } elseif ($ProjectType) { "$ProjectType toolchain" } else { 'auto-detect' }
    }
    if ($model) {
        $lines = @(
            "  Config        : $($State.BuildConfig.version)"
            "  OS            : $($model.Host.OS) ($($model.Host.Architecture)) PS $($model.Host.PSVersion)/$($model.Host.PSEdition) Admin:$($model.Host.IsAdmin)"
            "  DefaultTfm    : $($State.DefaultTfm)"
            "  ProjectRoot   : $($State.ProjectRoot)"
            "  ProjectType   : $($ProjectType)"
            "  Toolchain     : $($activeToolchain)"
            "  CorrelationId : $($State.CorrelationId)"
            "  SDKs          : dotnet $($model.SDKs.Dotnet) | node $($model.SDKs.Node) | python $($model.SDKs.Python) | go $($model.SDKs.Go) | rust $($model.SDKs.Rust) | java $($model.SDKs.Java)"
            "  Tools         : docker:$($model.Tools.Docker) git:$($model.Tools.Git) npm:$($model.Tools.Npm) pip:$($model.Tools.Pip) cargo:$($model.Tools.Cargo) ssh:$($model.Tools.Ssh)"
            "  Paths         : Home=$($model.Paths.Home) Temp=$($model.Paths.Temp) ScriptRoot=$($model.Paths.ScriptRoot)"
            "  GeneratedAt   : $($model.GeneratedAt)"
        )
    } else {
        $lines = @(
            "  Config        : $($State.BuildConfig.version)"
            "  OS            : $($State.OS)"
            "  DefaultTfm    : $($State.DefaultTfm)"
            "  ProjectRoot   : $($State.ProjectRoot)"
            "  ProjectType   : $($ProjectType)"
            "  CorrelationId  : $($State.CorrelationId)"
        )
    }
    foreach ($l in $lines) { Write-Log $l -State $State }
    return $true
}

Export-ModuleMember -Function @('New-GuildMenuConfig','Show-GuildMenu','Get-MenuLabel','Show-BuildEnvironmentSummary')






