# ============================================================================
            # every build to the shared release folder.
            Import-ModuleOnDemand -ModuleNames @('Release')
            Import-ModuleOnDemand -ModuleNames @('CodeSigning')
            $relCfg = $null
function Get-BuiltInPipelineSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [PSCustomObject]$State,
        [string]$ResolvedCfg = '',
        [switch]$Distributed,
        [string]$Target = '',
        [switch]$Security,
        [switch]$Incremental,
        [switch]$GitHub
    )
    $resolvedCfg = $ResolvedCfg
    # Bound as locals: the step scripts close over these names, exactly as they
    # did when the literal sat inside Start-GBuild.
    $Distributed = $Distributed
    $Target = $Target
    $Security = $Security
    # -Incremental closes over the same way. The Build step references
    # -Incremental:$Incremental at :2965 and :3066, but this function never
    # declared it: the closure resolved an UNSET variable to $null silently
    # (an uninitialized variable in a GetNewClosure() dynamic-module scope is
    # $null even under Set-StrictMode 1.0), so `-Incremental` was always $false
    # and the plugin cache short-circuit at Loader.psm1:639 never fired.
    $Incremental = $Incremental
    # Same class for -GitHub: the Build step passes it to Show-GuildMenu (:3074)
    # but it was never bound into this scope, so `-GitHub` was always $false.
    $GitHub = $GitHub
    # Each step script is bound to THIS function's scope with GetNewClosure().
    # A bare scriptblock resolves variables through the CALLER's live scope
    # chain, so $State / $resolvedCfg / $Distributed / $Target / $Security only
    # resolved because Start-GBuild happened to still be on the stack. Call the
    # pipeline from anywhere else - a test, a plugin, a future refactor - and
    # under Set-StrictMode every one of those steps throws
    # "The variable '$Security' cannot be retrieved because it has not been set."
    # GetNewClosure captures the values now, at definition time.
    $built = @(
    @{
        Name = 'RegisterPlugins'
        Script = {
            param($ctx)
            Register-Plugins -State $State
            Invoke-GBuildHook -HookName 'before-build' -State $State
        }
    },
    @{
        Name = 'ScanProject'
        Script = {
            param($ctx)
            Show-ProgressBar -Current 1 -Total 4 -Label (Get-LocaleMessage -Key 'log.project.searchingCsproj')
            Write-SubLog (Get-LocaleMessage -Key 'log.project.searchingCsproj')
            # Prefer the csproj resolved directly from -Project in gbuild.ps1.
            # This bypasses Find-Project entirely so a stale/cached Find-Project
            # (which could ignore -Project and re-detect WebUI) can never override
            # the explicit project. Fall back to Find-Project only when -Project
            # was not supplied.
            if ($State.ProjectCsproj -and (Test-Path $State.ProjectCsproj)) {
                $csproj = Get-Item -Path $State.ProjectCsproj
                Write-SubLog (Get-LocaleMessage -Key 'log.project.explicitCsproj' -MessageArgs @($State.ProjectCsproj))
            } elseif (Get-Command Find-Project -ErrorAction SilentlyContinue) {
                $csproj = Find-Project -State $State
            } else { $null }
            $ctx.csproj = $csproj
            if (-not $csproj) {
                Write-Log (Get-LocaleMessage -Key 'log.project.noCsproj') 'Info' $State
                Import-ModuleOnDemand -ModuleNames @('LanguageDetector')
                $searchRoot = if ($State.ProjectRoot -and (Test-Path $State.ProjectRoot)) { $State.ProjectRoot } else { $State.ScriptRoot }
                $langInfo = Get-PrimaryLanguage -SearchRoot $searchRoot -State $State
                if (-not $langInfo) { Write-Fail (Get-LocaleMessage -Key 'log.project.noSupported') -State $State; return }
                Write-Done (Get-LocaleMessage -Key 'log.project.detected' -MessageArgs @($langInfo.Language, $langInfo.BuildFile)) -State $State
                $ctx.projPath = $langInfo.BuildFilePath
                $ctx.projectDir = $langInfo.ProjectDir
                $ctx.projectType = $langInfo.Language
                $ctx.tfms = @()
                $ctx.defaultTfm = ''
                $ctx.tfmInfo = $null
                $ctx.langInfo = $langInfo
                $ctx.lang = $langInfo.Language
            } else {
                $ctx.projPath = $csproj.FullName
                $ctx.projectDir = $csproj.DirectoryName
                Import-ModuleOnDemand -ModuleNames @('Project')
                $meta = if (Get-Command Get-ProjectMetadata -ErrorAction SilentlyContinue) { Get-ProjectMetadata -CsprojPath $ctx.projPath -State $State } else { $null }
                $ctx.projectType = if ($meta -and $meta.ProjectType) { [string]$meta.ProjectType } else { 'Unknown' }
                $ctx.tfms = if ($meta -and $meta.Tfms) { ,$meta.Tfms } else { @() }
                $ctx.defaultTfm = if ($ctx.tfms.Count -gt 0) { $ctx.tfms[0] } else { $State.CurrentTfm }
                Invoke-SdkDetection -State $State -ProjectType $ctx.projectType -Tfms $ctx.tfms
                $ctx.tfmInfo = Resolve-TargetFrameworks -Tfms $ctx.tfms -ProjectType $ctx.projectType -DefaultTfm $ctx.defaultTfm
                Write-Done (Get-LocaleMessage -Key 'log.project.projectFound' -MessageArgs @($csproj.Name, $ctx.projectType)) -State $State
                $buildCfg = if ($State.BuildConfig -and $State.BuildConfig.build) { $State.BuildConfig.build } else { $null }
                $parallelEnabled = [bool](Get-BuildConstant -Key 'EnableParallelBuild' -State $State -Fallback $true)
                if ($parallelEnabled) {
                    # The module map in Get-ModuleMapFromConfig loads Parallel for
                    # target '14' only, and that map is consulted INSIDE
                    # Invoke-GuildChoice - i.e. AFTER this step. So this guard
                    # could never be true: Find-IndependentProjects was
                    # unresolvable at ScanProject time, $ctx.parallelProjects
                    # was therefore always empty, Menu.New-GuildMenuConfig
                    # computed $hasParallel = $false from it, and BOTH the
                    # Parallel Build (target 14) and Multi-Host Distributed
                    # Build (target X) were reported as "not supported for
                    # project type ..." for every project. Load it here
                    # instead. On-demand rather than Tier-1: the scan is the
                    # only consumer before a parallel build is chosen, and
                    # paying the import on every ordinary build would be a
                    # regression for a feature most runs never use.
                    Import-ModuleOnDemand -ModuleNames @('Parallel')
                    if (Get-Command Find-IndependentProjects -ErrorAction SilentlyContinue) {
                        $projInfo = Find-IndependentProjects -State $State
                        if ($projInfo.Independent -and $projInfo.Independent.Count -gt 1) {
                            $pp = [System.Collections.ArrayList]@()
                            $projInfo.Independent | ForEach-Object { $pp.Add($_.Path) | Out-Null }
                            $ctx.parallelProjects = $pp
                            Write-Log (Get-LocaleMessage -Key 'log.project.parallelDetected' -MessageArgs @($projInfo.Independent.Count)) "Info" $State
                        }
                    }
                }
            }
            # Scoped-logging anchor: every later step reports against this scope.
            $scopeLabel = if ($ctx.lang) { "$($ctx.projectType)/$($ctx.lang)" } elseif ($ctx.projectType) { [string]$ctx.projectType } else { 'Unknown' }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m67' -MessageArgs @($scopeLabel)) 'Debug' $State
        }
    },
    @{
        Name = 'Preflight'
        Script = {
            param($ctx)
            $cfg = Get-ConfigSection -State $State -Path 'build.preflight'
            $enabled = if ($cfg -and $null -ne $cfg.enabled) { [bool]$cfg.enabled } else { $true }
            if (-not $enabled) { Write-Log "[PREFLIGHT] $(Get-LocaleMessage -Key 'log.status.skipped') (build.preflight.enabled=false)" 'Gray' $State; return }
            Import-ModuleOnDemand -ModuleNames @('Preflight')
            if (Get-Command Invoke-PreflightValidation -ErrorAction SilentlyContinue) {
                $projDir = if ($ctx.projectDir) { $ctx.projectDir } elseif ($State.ProjectRoot) { $State.ProjectRoot } else { $State.ScriptRoot }
                $projFile = if ($ctx.projPath) { $ctx.projPath } else { '' }
                $pf = Invoke-PreflightValidation -State $State -ProjectDir $projDir -ProjectFile $projFile
                if (-not $pf.Passed) {
                    $msg = Get-LocaleMessage -Key 'log.system.preflightFailed' -MessageArgs @(($pf.Errors -join '; '))
                    Write-Log $msg 'Err' $State
                    throw $msg
                }
                Write-Log (Get-LocaleMessage -Key 'log.system.preflightPassed' -MessageArgs @($pf.Checks.Count)) 'Succ' $State
            } else { Write-Log "[PREFLIGHT] $(Get-LocaleMessage -Key 'log.status.skipped') (module unavailable)" 'Gray' $State }
        }
    },
    @{
        Name = 'AffectedScan'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'AFFECTED' -Reason 'build.affected.enabled=false' -EnablePaths @('build.affected.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Cache')
            if (Get-Command Get-AffectedProjects -ErrorAction SilentlyContinue) {
                $projFiles = @()
                if ($ctx.parallelProjects -and $ctx.parallelProjects.Count -gt 0) { $projFiles = [string[]]$ctx.parallelProjects }
                elseif ($ctx.projPath) { $projFiles = @([string]$ctx.projPath) }
                elseif ($State.ProjectRoot) {
                    $all = if (Get-Command Get-AllProjects -ErrorAction SilentlyContinue) { Get-AllProjects -SearchRoot $State.ProjectRoot -State $State } else { @() }
                    $projFiles = @($all | ForEach-Object { $_.FullName })
                }
                if ($projFiles.Count -eq 0) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m68') 'Gray' $State; return }
                $res = Get-AffectedProjects -ProjectFiles $projFiles -State $State
                if ($res -and $res.Affected) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m69' -MessageArgs @($($res.Affected.Count), $($res.Unchanged.Count))) 'Info' $State
                    # Read build.affected.skipUnchanged from THIS step's own config
                    # section. This used to test `$cfg.skipUnchanged`, a variable
                    # that exists only in the Preflight step's scope (:2904), so it
                    # always resolved to $null and build.affected.skipUnchanged was
                    # never honoured.
                    $skipUnchanged = [bool](Get-ConfigValue -Path 'build.affected.skipUnchanged' -State $State -Type bool)
                    if ($skipUnchanged -and $res.Unchanged.Count -gt 0 -and $ctx.parallelProjects.Count -gt 0) {
                        $filtered = @($ctx.parallelProjects | Where-Object { $_ -in $res.Affected })
                        $ctx.parallelProjects = [System.Collections.ArrayList]@($filtered)
                        # Name the projects being dropped. Previously only a
                        # count was logged, so a project silently vanishing
                        # from the build set had to be diagnosed by
                        # reconstructing the affected-graph by hand.
                        $droppedNames = @()
                        try { $droppedNames = @($ctx.parallelProjects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_) }) } catch { $droppedNames = @() }
                        if ($droppedNames.Count -gt 0) {
                            Write-Log (Get-LocaleMessage -Key 'log.cache.noSourceChanges' -MessageArgs @(($droppedNames -join ', '))) 'Gray' $State
                        }
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m70' -MessageArgs @($($filtered.Count))) 'Info' $State
                    }
                } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m71') 'Gray' $State }
            } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m72') 'Gray' $State }
        }
    },
    @{
        Name = 'Build'
        Script = {
            param($ctx)
            $csproj = $ctx.csproj
            if ($null -eq $csproj -and $ctx.langInfo) {
                $ctx.buildAttempted = $true
                Show-ProgressBar -Current 2 -Total 4 -Label "Building $($ctx.langInfo.Language)"
                $lang = $ctx.langInfo.Language
                $ctx.lang = $lang
                $fallbackLang = ''
                try {
                    $langOverrides = Get-ConfigValue -Path 'build.pluginDispatch.languageOverrides' -State $State
                    $fallbackLang = [string](Get-SectionValue -Section $langOverrides -Key $lang -Default '')
                } catch { }
                $null = Assert-BuildCommandAvailable -Command 'Invoke-PluginBuildSafe' -MessageKey 'log.orch.moduleLoaderMissing' -Fallback 'Loader (plugin system) not loaded.'
                $buildResult = Invoke-PluginBuildSafe -State $State -Language $lang -ProjectDir $ctx.projectDir -ProjectFile $ctx.projPath -FallbackLanguage $fallbackLang -Incremental:$Incremental -Detailed
                $buildOk = Test-RequiredResult -Result $buildResult -Operation "build:$lang"
                if (-not $buildOk) {
                    $buildDetail = if ($buildResult -and $buildResult.Message) { [string]$buildResult.Message } else { '' }
                    $message = Get-LocaleMessage -Key 'log.plugin.buildFailed' -MessageArgs @($lang, $buildDetail)
                    Write-Fail $message -State $State
                    throw $message
                }
                $ctx.buildOk = $buildOk
                $testFlags = Get-BuildTestConfig -State $State
                if ($testFlags.TestEnabled -or $testFlags.LintEnabled) {
                    # Shared gate, same definition as menu 'T'/'I' below.
                    Invoke-PluginTestAndLintGate -State $State -ProjectDir $ctx.projectDir -Language $lang -TestFlags $testFlags | Out-Null
                }
                # Stamp the publish location while the plugin result (with its
                # OutputPath) is still in hand. Without this the downstream
                # provenance/deploy chain resolves blind and a green build
                # with no artifacts passes silently.
                Update-BuildPublishOutput -Context $ctx -State $State -PluginResult $buildResult -ProjectDir $ctx.projectDir | Out-Null
                # Same reveal rule as the .NET path (Build.Invoke-BuildOutputReveal):
                # open only when the shared resolver allows it, so CI stays quiet.
                $openPublish = $false
                try {
                    if (Get-Command Resolve-BuildOpenOutput -ErrorAction SilentlyContinue) { $openPublish = [bool](Resolve-BuildOpenOutput -State $State) }
                } catch { $openPublish = $false }
                if ($openPublish -and $ctx.projectDir -and (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) -and (Get-Command Open-Target -ErrorAction SilentlyContinue)) {
                    $poRoot = Join-Path $ctx.projectDir (Resolve-PublishOutputDir -State $State)
                    if (Test-Path -LiteralPath $poRoot) { Open-Target $poRoot -State $State }
                }                    $totalSec = [math]::Round(((Get-Date) - $State.StartTime).TotalSeconds, 1)
                $ctx.totalSec = $totalSec
                # The summary LINE is a log message and goes through Write-Log, so it
                # lands in the log file and the JSONL stream like every other
                # message. Only the decoration (blank line + separator rules) stays
                # on Write-Host: Write-Log prefixes each line with a level and
                # cannot draw the rule, so replacing it there is not possible.
                Write-Host "`n"; Write-Sep
                Write-Log ((Get-LocaleMessage -Key 'log.system.buildDone') + ' ' + (Get-LocaleMessage -Key 'log.system.completed') + ' - ' + (Get-LocaleMessage -Key 'log.system.total' -MessageArgs @($totalSec))) 'Succ' $State
                Write-Sep
                if (Get-Command Write-BuildMetric -ErrorAction SilentlyContinue) {
                    $metric = Write-BuildMetric -State $State -Status 'Success' -Duration $totalSec -ProjectName (Split-Path $ctx.projectDir -Leaf) -Configuration $resolvedCfg -OutputType $lang
                    $ctx.metric = $metric
                    if (Get-Command Save-BuildReport -ErrorAction SilentlyContinue) {
                        try { $null = Save-BuildReport -State $State -Metric $metric } catch { }
                    }
                    if (Get-Command Write-TelemetryEntry -ErrorAction SilentlyContinue) { Write-TelemetryEntry -State $State -Metric $metric | Out-Null }
                    if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) { Submit-BuildMetric -State $State -Step $lang -DurationMs ($totalSec * 1000) -Success:$buildOk -ProjectName (Split-Path $ctx.projectDir -Leaf) -Configuration $resolvedCfg -OutputType $lang | Out-Null }
                }
            } else {
                Show-ProgressBar -Current 2 -Total 4 -Label (Get-LocaleMessage -Key 'log.system.selectMode')
                $menuConfig = New-GuildMenuConfig -ProjectType $ctx.projectType -AndroidTfm $ctx.tfmInfo.AndroidTfm -WinTfm $ctx.tfmInfo.WinTfm -OS $State.OS -ParallelProjects $ctx.parallelProjects -State $State
                $ctx.menuConfig = $menuConfig
                if ($Distributed.IsPresent) {
                    if ($menuConfig.ContainsKey('X') -and $menuConfig['X'].Supported) {
                        $choice = 'X'
                        Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m73') 'Info' $State
                    } else {
                        # Name the gate that actually closed. This used to emit
                        # a single message blaming distributed.enabled, which
                        # ships TRUE - so when target X was unavailable for the
                        # other reason (fewer than two independent projects)
                        # the diagnostic pointed at a config key that was
                        # already set, and the real cause was undiscoverable
                        # from the output.
                        $distEnabled = [bool](Get-ConfigValue -Path 'distributed.enabled' -State $State -Type bool)
                        $msgKey = if ($distEnabled) { 'log.orchestrator.parallelUnavailable' } else { 'log.orchestrator.m74' }
                        Write-Log (Get-LocaleMessage -Key $msgKey) 'Warn' $State
                        return
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($Target)) {
                    $choice = $Target.Trim()
                    if (-not $menuConfig.ContainsKey($choice)) {
                        $listCmd = 'gbuild -Target list'
                        if (Get-Command Get-InvokeCommandHint -ErrorAction SilentlyContinue) {
                            try { $listCmd = Get-InvokeCommandHint -Arguments '-Target list' -ScriptRoot $State.ScriptRoot -FromDirectory ((Get-Location).ProviderPath) } catch { }
                        }
                         $message = Get-LocaleMessage -Key 'log.target.invalid' -MessageArgs @($choice, $listCmd)
                         Write-Log $message 'Err' $State
                         throw $message

                    }
                    if ($menuConfig[$choice].Supported -eq $false) {
                         $message = Get-LocaleMessage -Key 'log.target.unsupported' -MessageArgs @($choice, $menuConfig[$choice].Label, $ctx.projectType)
                         Write-Log $message 'Err' $State
                         throw $message

                    }
                    Write-Log (Get-LocaleMessage -Key 'log.target.using' -MessageArgs @($choice, $menuConfig[$choice].Label)) 'Info' $State
                } elseif ($State.ExplicitProject) {
                    # -Project given without -Target: auto-pick the PRODUCT's default
                    # build action so the shortest command (.\_Build\gbuild -Project "<product>")
                    # builds that product directly instead of prompting a menu. The factory
                    # (_Build) location is never used as the product.
                     $choice = Resolve-AutoBuildChoice -MenuConfig $menuConfig -State $State -ProjectType $ctx.projectType -BuildContext $ctx
                     if ([string]::IsNullOrWhiteSpace($choice)) { throw (Get-LocaleMessage -Key 'log.orch.noSupportedBuildTarget' -Fallback 'No supported build target is available for this project.') }

                    Write-Log (Get-LocaleMessage -Key 'log.target.auto' -MessageArgs @($choice, $menuConfig[$choice].Label, $ctx.projectType)) 'Info' $State
                    # Discoverability tip: tell the operator how to reach the FULL feature set
                    # (menu / -Target / deploy / CI / security ...) instead of only auto-build.
                    if (-not $State.NonInteractive -and -not $State.IsCI -and (Get-Command Test-InteractiveSession -ErrorAction SilentlyContinue)) {
                        Show-TargetUsageTip -MenuConfig $menuConfig -State $State
                    }
                } else {
                    $choice = Show-GuildMenu -MenuConfig $menuConfig -State $State -GitHub:$GitHub
                }
                $ctx.choice = $choice
                if ($choice -eq '0') { return }
                 $ctx.buildAttempted = $true
                 Show-ProgressBar -Current 3 -Total 4 -Label $menuConfig[$choice].Label
                 $choiceResult = Invoke-GuildChoice -Choice $choice -MenuConfig $menuConfig -State $State -ProjPath $ctx.projPath -ProjectDir $ctx.projectDir -ProjectType $ctx.projectType -Tfms $ctx.tfms -DefaultTfm $ctx.defaultTfm -WinTfm $ctx.tfmInfo.WinTfm -AndroidTfm $ctx.tfmInfo.AndroidTfm -IosTfm $ctx.tfmInfo.IosTfm -MacTfm $ctx.tfmInfo.MacTfm -ParallelProjects ([string[]]$ctx.parallelProjects) -Incremental:$Incremental -PipelineContext $ctx
                 $buildChoices = Get-BuildTargetChoices
                 # Config-driven project-type list. This used to be a
                 # hardcoded 10-item array that omitted 'Unknown' and
                 # therefore could not honour a build.menu.dotnetTypes
                 # override the way Menu.psm1:132 does.
                 $dotnetTypes = @(Get-ProjectTypes -State $State)
                 $testFlags = Get-BuildTestConfig -State $State
                 $buildOk = $false
                 if ($choice -in $buildChoices) {
                     # Invoke-GuildChoice already validated build targets and
                     # threw on failure, so this is a READ of the verdict,
                     # not a second validation.
                     $buildOk = Test-RequiredResult -Result $choiceResult -Operation "target:$choice"
                 } else {
                     $actionResult = ConvertTo-OperationResult -Value $choiceResult -Operation "target:$choice"
                     $buildOk = ($actionResult.Status -eq 'Succeeded')
                     if ($choice -in (Get-FatalActionChoices) -and -not $buildOk) {
                         $message = if ($choiceResult -and $choiceResult.Message) { [string]$choiceResult.Message } else { "Target '$choice' failed" }
                         Write-Fail $message -State $State
                         throw $message
                     }
                 }
                  $ctx.buildOk = $buildOk
                  if ($choice -in $buildChoices) {
                      Update-BuildPublishOutput -Context $ctx -State $State -PluginResult $choiceResult -ProjectDir $ctx.projectDir | Out-Null
                  }
                  if ($choice -in $buildChoices -and ($testFlags.TestEnabled -or $testFlags.LintEnabled)) {
                      # Prefer the DETECTED language, exactly as the interactive 'T'/'I' arms do at
                  # the top of this function. This line used to collapse every
                  # .NET project type to the literal 'C#' BEFORE consulting
                  # langInfo, so an Avalonia project auto-built through
                  # Invoke-PluginTestFor with Language='C#'. Loader resolves
                  # a plugin by matching SupportedLanguages and then taking
                  # the LOWEST priority, so 'C#' routed to Dotnet (priority
                  # 1) and the Avalonia plugin (priority 10) was never
                  # consulted - the same project therefore tested DIFFERENTLY
                  # depending on whether you ran `gbuild` or `gbuild -Target T`.
                  # $dotnetTypes is retained only as the fallback for when
                  # detection produced nothing at all.
                   $testLang = if ($ctx.langInfo -and $ctx.langInfo.Language) { [string]$ctx.langInfo.Language } elseif ($ctx.langInfo) { [string]$ctx.langInfo } elseif ($ctx.projectType -in $dotnetTypes) { 'C#' } else { $ctx.projectType }
                       if ($testFlags.TestEnabled) { Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningTests' -MessageArgs @([string]$testLang) -Fallback 'Running tests for {0}...') }
                       if ($testFlags.LintEnabled) { Write-SubLog (Resolve-LogMessage -Key 'log.orchestrator.runningLint' -MessageArgs @([string]$testLang) -Fallback 'Running lint for {0}...') }
                       Invoke-PluginTestAndLintGate -State $State -ProjectDir $ctx.projectDir -Language $testLang -TestFlags $testFlags -Detailed | Out-Null
                   }
                 if (Get-Command Get-ErrorSummary -ErrorAction SilentlyContinue) { $errSummary = Get-ErrorSummary; if ($errSummary -and $errSummary.Total -gt 0 -and $State.LogLevel -ge 1 -and (Get-Command Show-ErrorReport -ErrorAction SilentlyContinue)) { Show-ErrorReport -State $State } }
                 $totalSec = [math]::Round(((Get-Date) - $State.StartTime).TotalSeconds, 1)
                 $ctx.totalSec = $totalSec
                 Write-Host "`n"; Write-Sep
                 Write-Log ((Get-LocaleMessage -Key 'log.system.pipelineDone') + ' ' + (Get-LocaleMessage -Key 'log.system.completed') + ' - ' + (Get-LocaleMessage -Key 'log.system.total' -MessageArgs @($totalSec))) 'Succ' $State
                 Write-Sep
                 if (Get-Command Write-BuildMetric -ErrorAction SilentlyContinue) {
                     $metric = Write-BuildMetric -State $State -Status $(if ($buildOk) { 'Success' } else { 'Failure' }) -Duration $totalSec -ProjectName $csproj.BaseName -Configuration $resolvedCfg -TargetFramework $ctx.defaultTfm -OutputType $ctx.projectType
                     $ctx.metric = $metric
                     if (Get-Command Save-BuildReport -ErrorAction SilentlyContinue) {
                         try { $null = Save-BuildReport -State $State -Metric $metric } catch { }
                     }
                     if (Get-Command Write-TelemetryEntry -ErrorAction SilentlyContinue) { Write-TelemetryEntry -State $State -Metric $metric | Out-Null }
                     if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) { Submit-BuildMetric -State $State -Step $ctx.projectType -DurationMs ($totalSec * 1000) -Success:$buildOk -ProjectName $csproj.BaseName -Configuration $resolvedCfg -TargetFramework $ctx.defaultTfm -OutputType $ctx.projectType | Out-Null }
                 }

            }
        }
    },
    @{
        Name = 'SignArtifacts'
        Script = {
            param($ctx)
            # Authenticode signing of the Windows PE artifacts the build just
            # produced. Sits directly after Build so the files are signed
            # BEFORE they are packaged/uploaded by PublishArtifact.
            #
            # The gate reads the RESOLVED config (the machine profile merged with
            # the project config), not the raw config path: the tool ships
            # security.peSign.enabled = false, and a project that forgot to
            # enable it must not silently opt the machine out of signing. A
            # project that opts in but has no signer on the machine gets a clear
            # skip message instead of a hard failure (unless failOnError is set).
            Import-ModuleOnDemand -ModuleNames @('CodeSigning')
            $peCfg = $null
            try { if (Get-Command Get-CodeSigningConfig -ErrorAction SilentlyContinue) { $peCfg = Get-CodeSigningConfig -State $State } } catch { }
            if ($null -eq $peCfg -or -not $peCfg.Enabled) {
                Write-Log (Get-LocaleMessage -Key 'log.codesign.disabled' -Fallback '[SIGN] Code signing is not enabled for this build - skipping.') 'Gray' $State
                return
            }
            if (-not (Get-Command Invoke-CodeSigning -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.codesign.moduleUnavailable' -Fallback '[SIGN] Code signing module unavailable - skipping.') 'Gray' $State
                return
            }

            $target = ''
            try { $target = [string]$ctx.publishOutput } catch { $target = '' }
            if ([string]::IsNullOrWhiteSpace($target)) {
                try {
                    $pubName = 'publish-output'
                    if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) { $pubName = [string](Resolve-PublishOutputDir -State $State) }
                    $anchor = ''
                    if ($ctx.projectDir) { $anchor = [string]$ctx.projectDir }
                    elseif ($State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $anchor = [string]$State.ProjectRoot }
                    if ($anchor) {
                        $target = if ([System.IO.Path]::IsPathRooted($pubName)) { $pubName } else { Join-Path $anchor $pubName }
                    }
                } catch { $target = '' }
            }
            if ([string]::IsNullOrWhiteSpace($target)) {
                Write-Log (Get-LocaleMessage -Key 'log.codesign.noOutput' -Fallback '[SIGN] No publish output to sign - skipping.') 'Gray' $State
                return
            }

            $result = Invoke-CodeSigning -State $State -InputPath $target
            $status = [string]$result.Status
            $detail = [string]$result.Message

            # Say WHICH signer ran: the Artifact Signing account, or the machine's
            # own certificate. "Configured" and "signed" are different claims.
            try {
                $signerCfg = Get-CodeSigningConfig -State $State
                if ($signerCfg.AzureAvailable) {
                    Write-Log (Get-LocaleMessage -Key 'log.setupSigning.accountDetected' -MessageArgs @([string]$signerCfg.ExternalCommand)) 'Info' $State
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$signerCfg.AzureReason)) {
                    Write-Log (Get-LocaleMessage -Key 'log.setupSigning.accountMissing' -MessageArgs @([string]$signerCfg.AzureReason)) 'Gray' $State
                }
            }
            catch { }

            if ($status -eq 'Succeeded') {
                Write-Log (Get-LocaleMessage -Key 'log.codesign.signed' -MessageArgs @($detail)) 'Succ' $State
            }
            elseif ($status -eq 'Skipped') {
                Write-Log (Get-LocaleMessage -Key 'log.codesign.skipped' -MessageArgs @($detail)) 'Gray' $State
            }
            else {
                $failOnError = $true
                try {
                    if (Get-Command Get-CodeSigningConfig -ErrorAction SilentlyContinue) {
                        $failOnError = [bool](Get-CodeSigningConfig -State $State).FailOnError
                    }
                } catch { $failOnError = $true }

                # A signing failure the project explicitly tolerates (failOnError
                # false) is a warning, not an error: the build continues on
                # purpose, so logging it at Err level would cry wolf.
                $level = if ($failOnError) { 'Err' } else { 'Warn' }
                Write-Log (Get-LocaleMessage -Key 'log.codesign.failed' -MessageArgs @($detail)) $level $State
                if ($failOnError) {
                    if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 2 -Reason 'code-signing' }
                    throw (Get-LocaleMessage -Key 'log.codesign.failed' -MessageArgs @($detail) -Fallback ('[SIGN] Code signing failed: ' + $detail))
                }
            }
        }
    },
    @{
        Name = 'ReleaseArtifact'
        Script = {
            param($ctx)
            # Turns the build output into something you can SELL: one archive,
            # a .sha256 the buyer verifies the download with, and a .json
            # manifest (version, commit, signed or not).
            #
            # It runs right AFTER SignArtifacts, so the binaries inside the
            # archive are already signed. The destination is configured ONCE
            # per machine (the signing profile), so no project has to be set up
            # by hand: every project that builds publishes itself.
            # The gate reads the RESOLVED config (machine profile merged with
            # the project config) - the machine profile owns the decision to
            # publish every build to the shared release folder.
            Import-ModuleOnDemand -ModuleNames @('Release')
            Import-ModuleOnDemand -ModuleNames @('CodeSigning')
            $relCfg = $null
            try { if (Get-Command Get-ReleaseConfig -ErrorAction SilentlyContinue) { $relCfg = Get-ReleaseConfig -State $State } } catch { }
            if ($null -eq $relCfg -or -not $relCfg.Enabled) {
                Write-Log (Get-LocaleMessage -Key 'log.release.disabled' -Fallback '[RELEASE] Releasing is not enabled for this build - skipping.') 'Gray' $State
                return
            }
            if (-not (Get-Command New-BuildReleasePackage -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.release.moduleUnavailable' -Fallback '[RELEASE] Release module unavailable - skipping.') 'Gray' $State
                return
            }
            $source = ''
            try { $source = [string]$ctx.publishOutput } catch { $source = '' }
            if ([string]::IsNullOrWhiteSpace($source)) {
                try {
                    $pubName = 'publish-output'
                    if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) { $pubName = [string](Resolve-PublishOutputDir -State $State) }
                    $anchor = ''
                    if ($ctx.projectDir) { $anchor = [string]$ctx.projectDir }
                    elseif ($State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { $anchor = [string]$State.ProjectRoot }
                    if ($anchor) {
                        $source = if ([System.IO.Path]::IsPathRooted($pubName)) { $pubName } else { Join-Path $anchor $pubName }
                    }
                } catch { $source = '' }
            }
            if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Container)) {
                Write-Log (Get-LocaleMessage -Key 'log.release.noOutput' -Fallback '[RELEASE] No publish output to package - skipping.') 'Gray' $State
                return
            }

            $projectName = ''
            $projectDir = ''
            # $ctx is a hashtable: read its entries DIRECTLY. Asking
            # $ctx.PSObject.Properties.Name would list the hashtable's own
            # members (Count, Keys, ...), never the context keys, and every
            # lookup below would silently miss.
            try { $csprojObj = $ctx.csproj } catch { $csprojObj = $null }
            if ($csprojObj) {
                $projectName = [IO.Path]::GetFileNameWithoutExtension([string]$csprojObj.FullName)
                $projectDir = [string]$csprojObj.DirectoryName
            }
            if ([string]::IsNullOrWhiteSpace($projectName)) {
                try {
                    $projPathValue = [string]$ctx.projPath
                    if ($projPathValue) {
                        $projectName = [IO.Path]::GetFileNameWithoutExtension($projPathValue)
                        $projectDir = [IO.Path]::GetDirectoryName($projPathValue)
                    }
                } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($projectName)) {
                try {
                    $dirValue = [string]$ctx.projectDir
                    if ($dirValue) {
                        $proj = Get-ChildItem -LiteralPath $dirValue -Filter '*.csproj' -File -ErrorAction SilentlyContinue |
                            Select-Object -First 1
                        if ($proj) { $projectName = $proj.BaseName; $projectDir = $proj.DirectoryName }
                        else { $projectName = (Split-Path -Leaf $dirValue); $projectDir = $dirValue }
                    }
                } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($projectName)) { $projectName = 'build' }
            if ([string]::IsNullOrWhiteSpace($projectDir)) { $projectDir = [string]$ctx.projectDir }

            # The shared release folder comes from the MACHINE profile first
            # (one setup for every project), then from the project config.
            $destination = ''
            try {
                if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
                    $destination = [string](Get-ConfigValue -Path 'security.release.outputDir' -State $State -Default '' -Type string)
                }
            } catch { $destination = '' }
            try {
                if (Get-Command Get-CodeSigningProfile -ErrorAction SilentlyContinue) {
                    $profile = Get-CodeSigningProfile
                    if ($profile.Release -and $profile.Release.ContainsKey('outputDir') -and -not [string]::IsNullOrWhiteSpace([string]$profile.Release['outputDir'])) {
                        $destination = [string]$profile.Release['outputDir']
                    }
                }
            } catch { }

            $result = New-BuildReleasePackage -SourceDir $source -ProjectRoot ([string]$ctx.projectDir) `
                -ProjectName $projectName -DestinationDir $destination
            $status = [string]$result.Status
            if ($status -eq 'Succeeded') {
                Write-Log (Get-LocaleMessage -Key 'log.release.published' -MessageArgs @([string]$result.Archive, [string]$result.SizeBytes)) 'Succ' $State
                if ($result.Copied) {
                    Write-Log (Get-LocaleMessage -Key 'log.release.copied' -MessageArgs @([string]$result.Copied)) 'Info' $State
                }
            }
            elseif ($status -eq 'Failed') {
                Write-Log (Get-LocaleMessage -Key 'log.release.failed' -MessageArgs @([string]$result.Message)) 'Warn' $State
            }
            else {
                Write-Log (Get-LocaleMessage -Key 'log.release.skipped' -MessageArgs @([string]$result.Message)) 'Gray' $State
            }
        }
    },
    @{
        Name = 'SecurityScan'
        Script = {
            param($ctx)
            # L5 GATE WIRING. This gate used to live ONLY in the finally block
            # behind `if ($Security.IsPresent)`, so the secret scan, the
            # vulnerable-package audit and license compliance never ran on a
            # default build and never ran in CI (build.yml drives
            # `-Target 10 -NonInteractive`, with no -Security). A gate that
            # only runs when someone remembers a switch is not a gate.
            # It is now a first-class pipeline step, enabled by
            # security.scanOnBuild (ships TRUE). -Security still forces it on.
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SECURITY' -Reason 'security.scanOnBuild=false' -EnablePaths @('security.scanOnBuild') -DefaultEnabled $true -ForceOn:$Security.IsPresent)) { return }
            Import-ModuleOnDemand -ModuleNames @('Security')
            if (-not (Get-Command Invoke-SecurityScan -ErrorAction SilentlyContinue)) { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m86' -MessageArgs @(${lb}, ${rb})) 'Gray' $State; return }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m83' -MessageArgs @(${lb}, ${rb})) 'Info' $State
            $secResult = Invoke-SecurityScan -State $State
            if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) { Set-BuildStateProperty -State $State -Name 'SecurityScanCompleted' -Value $true -Force }
            # PERSIST THE EVIDENCE, not just the in-memory flag. State is a
            # PowerShell object that dies with the process, so setting
            # SecurityScanCompleted left CI with nothing to assert against: the
            # "the security gate must run on a default build" check in
            # .github/workflows/build.yml could only read security.scanOnBuild
            # back out of the config, which is the very claim it was supposed
            # to test. This file is what makes the step observable.
            if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) {
                try {
                    $secDir = Get-ReportDirectory -State $State
                    if ($secDir) {
                        $null = Write-BuildJsonFile -Path (Join-Path $secDir 'security-scan.json') -Atomic -Data ([PSCustomObject]@{
                                CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                                Pass           = [bool]$secResult.Pass
                                Critical       = $secResult.Critical
                                High           = $secResult.High
                                Medium         = $secResult.Medium
                                Vulnerabilities = $secResult.Vulnerabilities
                                License        = $secResult.License
                            })
                    }
                } catch { }
            }
            if ($secResult -and -not $secResult.Pass) {
                # ENFORCEMENT. security.blockOnCriticalVulns=true and
                # security.licenseEnforcement='block' were decorative while this
                # only logged: a committed AWS key produced a green build.
                $detail = "Critical=$($secResult.Critical), High=$($secResult.High), Medium=$($secResult.Medium), Vulnerabilities=$($secResult.Vulnerabilities), LicenseViolations=$($secResult.License)"
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m84' -MessageArgs @(${lb}, ${rb}, $detail)) 'Err' $State
                Set-GBuildExitCode -Code 2 -Reason 'security-scan'
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    # Write-AuditLog declares -Action/-Outcome/-State/-Detail. This
                    # used to pass -Type/-Result, which do not exist: parameter
                    # binding threw inside the try/catch and the denial entry was
                    # silently dropped - on exactly the event an auditor queries.
                    try { Write-AuditLog -Action 'security:scan' -Outcome 'Denied' -Detail $detail -State $State } catch { }
                }
                throw (Get-LocaleMessage -Key 'log.security.failed')
            }
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m85' -MessageArgs @(${lb}, ${rb})) 'Succ' $State
        }
    },
    @{
        Name = 'AutoTune'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'AUTOTUNE' -Reason 'autoTune.enabled=false or autoApply=false' -EnablePaths @('autoTune.enabled','autoTune.autoApply') -RequireAll)) { return }
            Import-ModuleOnDemand -ModuleNames @('AutoTuner')
            if (Get-Command Invoke-AutoTuneApply -ErrorAction SilentlyContinue) {
                $applied = Invoke-AutoTuneApply -State $State
                if ($applied.Count -gt 0) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m75' -MessageArgs @($($applied -join ', '))) 'Succ' $State
                } else {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m76') 'Info' $State
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m77') 'Gray' $State }
        }
    },
    @{
        Name = 'SupplyChain'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SUPPLYCHAIN' -Reason 'security.sbom/provenance disabled' -EnablePaths @('security.sbom.enabled','security.provenance.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('SupplyChain')
            if (Get-Command Invoke-SupplyChainChecks -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.supplychain.running') 'Info' $State
                # PublishOutput was never passed here, so provenance (enabled by
                # default via security.provenance.enabled) always threw
                # 'publish output unavailable' and the default-enabled
                # supply-chain step failed EVERY build even though the build
                # had just produced its artifacts. Resolve the same publish
                # root Build.psm1 writes to (Resolve-PublishOutputDir).
                $publishOut = [string]$ctx.publishOutput
                if ([string]::IsNullOrWhiteSpace($publishOut) -and $ctx.projectDir) {
                    $pubRoot = if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) { [string](Resolve-PublishOutputDir -State $State) } else { 'publish-output' }
                    if (-not [string]::IsNullOrWhiteSpace($pubRoot)) {
                        $candidate = if ([System.IO.Path]::IsPathRooted($pubRoot)) { $pubRoot } else { Join-Path ([string]$ctx.projectDir) $pubRoot }
                        if (Test-Path -LiteralPath $candidate -PathType Container) { $publishOut = $candidate }
                    }
                }
                $sc = Invoke-SupplyChainChecks -State $State -ProjectDir $ctx.projectDir -PublishOutput $publishOut
                # Invoke-SupplyChainChecks returns a hashtable with Pass; it has
                # no Status property, so the previous `$sc.Status -eq 'Skipped'`
                # branch was always false.
                $status = if ($sc -and $sc.Pass) { 'Passed' } else { 'Failed' }
                $statusText = Get-LocaleMessage -Key "log.status.$($status.ToLowerInvariant())"
                Write-Log (Get-LocaleMessage -Key 'log.supplychain.status' -MessageArgs @($statusText)) $(if ($status -eq 'Passed' -or $status -eq 'Skipped') { 'Succ' } else { 'Warn' }) $State
                if (-not $sc.Pass) { throw (Get-LocaleMessage -Key 'log.supplychain.failed') }
            } else { Write-Log (Get-LocaleMessage -Key 'log.supplychain.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'SastScan'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SAST' -Reason 'security.sast.enabled=false' -EnablePaths @('security.sast.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Sast')
            if (Get-Command Invoke-SastScan -ErrorAction SilentlyContinue) {
                $dir = if ($ctx.projectDir) { $ctx.projectDir } elseif ($State.ProjectRoot) { $State.ProjectRoot } else { $State.ScriptRoot }
                $sr = Invoke-SastScan -State $State -ProjectDir $dir
                $icon = switch ($sr.Status) { 'Passed' { 'Succ' } 'Skipped' { 'Gray' } 'Warned' { 'Warn' } default { 'Warn' } }
                $statusText = Get-LocaleMessage -Key "log.status.$(([string]$sr.Status).ToLowerInvariant())" -Fallback ([string]$sr.Status)
                Write-Log (Get-LocaleMessage -Key 'log.sast.status' -MessageArgs @($statusText, $sr.TotalFindings)) $icon $State
                # "Blocked (findings=0)" named the finding count as the reason for
                # a block even when nothing had been scanned - the scanner was not
                # installed. The scan now reports why it closed; print it, so the
                # operator is told what the platform could not run rather than being
                # pointed at a count of zero.
                if ((-not $sr.Pass) -and $sr.Reason) {
                    Write-Log (Resolve-LogMessage -Key 'log.sast.gateReason' -MessageArgs @([string]$sr.Reason) -Fallback '[SAST] Gate closed because: {0}') 'Warn' $State
                }
                # PUBLISH THE FINDINGS. Invoke-SastScan already produces
                # findings in the SARIF shape, and Report.psm1 already ships a
                # SARIF 2.1.0 writer - but nothing connected the two, so the
                # findings died with the process and no code-scanning consumer
                # ever received a file. This runs BEFORE the verdict is thrown
                # so a FAILED scan still leaves the evidence on disk.
                Import-ModuleOnDemand -ModuleNames @('Report')
                if (Get-Command Publish-BuildSarifArtifact -ErrorAction SilentlyContinue) {
                    try {
                        $sarifFindings = @()
                        foreach ($check in @($sr.Checks)) {
                            if ($null -eq $check) { continue }
                            foreach ($f in @($check.Findings)) { if ($null -ne $f) { $sarifFindings += $f } }
                        }
                        if ($sarifFindings.Count -gt 0) {
                            $sarifPath = Publish-BuildSarifArtifact -State $State -Findings $sarifFindings -ToolName 'gbuild-sast'
                            if ($sarifPath) { Write-Log (Resolve-LogMessage -Key 'log.sast.sarifWritten' -MessageArgs @([string]$sarifPath) -Fallback '[SAST] SARIF findings written: {0}') 'Gray' $State }
                        }
                    } catch { }
                }
                if (-not $sr.Pass) { Write-Log (Get-LocaleMessage -Key 'log.sast.failed') 'Err' $State; throw (Get-LocaleMessage -Key 'log.sast.failed') }
            } else { Write-Log (Get-LocaleMessage -Key 'log.sast.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'PolicyCheck'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'POLICY' -Reason 'security.policy.enabled=false' -EnablePaths @('security.policy.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Policy')
            if (Get-Command Invoke-PolicyChecks -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.policy.running') 'Info' $State
                $pr = Invoke-PolicyChecks -State $State -ProjectDir $ctx.projectDir
                $status = if ($pr -and $pr.Pass) { 'Passed' } elseif ($pr -and $pr.Status -eq 'Skipped') { 'Skipped' } else { 'Failed' }
                $statusText = Get-LocaleMessage -Key "log.status.$($status.ToLowerInvariant())"
                Write-Log (Get-LocaleMessage -Key 'log.policy.status' -MessageArgs @($statusText)) $(if ($status -eq 'Passed' -or $status -eq 'Skipped') { 'Succ' } else { 'Warn' }) $State
                # Read the enforcement mode FROM THE MODULE RESULT. This used to
                # test `$cfg.enforcement`, a variable that does not exist in this
                # step's closure ($cfg is a local of the Preflight step, :2904) -
                # an unset variable in a GetNewClosure() scope resolves to $null
                # silently, so the test was always false and
                # security.policy.enforcement="block" NEVER threw. Policy
                # violations shipped green. Invoke-PolicyChecks already returns
                # the resolved Enforcement (:364, :377, :383), so this consumes
                # the module's own decision instead of re-deriving it.
                $enforcement = ''
                if ($pr -and $pr.PSObject.Properties.Name -contains 'Enforcement') { $enforcement = [string]$pr.Enforcement }
                if (-not $enforcement) {
                    # Single-value reader, not Get-ConfigSection: the gate
                    # contract (pinned by PipelineBuiltIn.Tests) forbids inlining
                    # the section read - the step-enabled helper owns the enable
                    # decision, and enforcement is a separate concern resolved
                    # here through the same accessor every other value uses.
                    try { $enforcement = [string](Get-ConfigValue -Path 'security.policy.enforcement' -State $State -Default 'block') } catch { $enforcement = 'block' }
                    if ([string]::IsNullOrWhiteSpace($enforcement)) { $enforcement = 'block' }
                }
                if ($status -eq 'Failed' -and $enforcement -in @('block', 'fail') -and -not $pr.Pass) { throw (Get-LocaleMessage -Key 'log.policy.failed') }
                # A backend-evaluation failure under 'warn' is the one case that
                # must still surface as an error: the gate did not actually run.
                if ($status -eq 'Failed' -and $enforcement -eq 'warn' -and $pr.Status -eq 'Failed') {
                    Write-Log (Get-LocaleMessage -Key 'log.policy.status' -MessageArgs @($statusText)) 'Warn' $State
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.policy.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'SiemExport'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'SIEM' -Reason 'security.siem.enabled=false' -EnablePaths @('security.siem.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Siem')
            if (Get-Command Export-SiemEvents -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.siem.running') 'Info' $State
                $se = Export-SiemEvents -State $State
                # Two defects in this step's verdict handling:
                #  1. It read $se.OutputFile, which does not exist - Export-SiemEvents
                #     returns OutputPath, so the destination always printed empty.
                #  2. It logged 'Succ' UNCONDITIONALLY. Export-SiemEvents sets
                #     Status='Failed' when the HTTP transport rejects the batch or
                #     the file write fails, so a failed SIEM export reported
                #     success and the pipeline continued.
                # The step is an export/telemetry sink, not an enforcement gate,
                # so a failed export is reported as an error but does NOT fail
                # the build (security.siem has no enforcement mode); making it
                # fatal would let an unreachable SIEM break every build.
                $seStatus = [string]$se.Status
                $seColor = if ($seStatus -eq 'Exported') { 'Succ' } elseif ($seStatus -eq 'Skipped') { 'Gray' } else { 'Err' }
                $statusText = Get-LocaleMessage -Key "log.status.$($seStatus.ToLowerInvariant())" -Fallback $seStatus
                Write-Log (Get-LocaleMessage -Key 'log.siem.status' -MessageArgs @($statusText, $se.Count, $se.OutputPath)) $seColor $State
            } else { Write-Log (Get-LocaleMessage -Key 'log.siem.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'StandaloneBundle'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'STANDALONE' -Reason 'build.standalone.enabled=false' -EnablePaths @('build.standalone.enabled'))) { return }
            Import-ModuleOnDemand -ModuleNames @('Standalone')
            if (Get-Command New-StandaloneBundle -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.standalone.running') 'Info' $State
                $sb = New-StandaloneBundle -State $State
                # The step logged 'Succ' unconditionally and never read $sb.Status,
                # but New-StandaloneBundle returns Status='Failed' when the module
                # set could not be embedded or when signing / SBOM / provenance
                # failed - so a bundle that could not be produced reported
                # success and the pipeline continued. Producing a signed
                # standalone artifact is the point of this step, so a Failed
                # verdict fails the run.
                $sbStatus = [string]$sb.Status
                $sbColor = if ($sbStatus -eq 'Succeeded') { 'Succ' } elseif ($sbStatus -eq 'Skipped') { 'Gray' } else { 'Err' }
                $statusText = Get-LocaleMessage -Key "log.status.$($sbStatus.ToLowerInvariant())" -Fallback $sbStatus
                Write-Log (Get-LocaleMessage -Key 'log.standalone.status' -MessageArgs @($statusText, $sb.OutputFile)) $sbColor $State
                if ($sbStatus -eq 'Failed') {
                    if (Get-Command Set-GBuildExitCode -ErrorAction SilentlyContinue) { Set-GBuildExitCode -Code 2 -Reason 'standalone-bundle' }
                    throw (Get-LocaleMessage -Key 'log.standalone.failed' -MessageArgs @($statusText) -Fallback 'Standalone bundle generation failed.')
                }
            } else { Write-Log (Get-LocaleMessage -Key 'log.standalone.moduleUnavailable') 'Gray' $State }
        }
    },
    @{
        Name = 'PublishArtifact'
        Script = {
            param($ctx)
            if (-not (Test-StepEnabled -State $State -Context $ctx -StepLabel 'ARTIFACT' -Reason 'build.publishArtifact.enabled=false' -EnablePaths @('build.publishArtifact.enabled'))) { return }
            $artifactStep = Join-Path $State.ScriptRoot 'Steps/publish-artifact.ps1'
            if (Test-Path $artifactStep) {
                try {
                    & $artifactStep -State $State -ErrorAction Stop
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m78' -MessageArgs @($_)) 'Warn' $State
                }
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m79') 'Gray' $State
            }
        }
    }
    )
    foreach ($s in $built) { if ($s.Script) { $s.Script = $s.Script.GetNewClosure() } }
    return $built
}

<#
.SYNOPSIS
    Records a step that was skipped because its feature is disabled.
.DESCRIPTION
    Scoped pipeline logging: disabled optional steps are collected into
    $Context.skippedSteps and reported as ONE summary line so each build only
    shows logs relevant to its own project type. Set build.scopedLogging=false
    for the legacy per-step lines.
#>

function Resolve-PipelineSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [PSCustomObject]$State,
        [array]$CallerSteps
    )
    # Normalize caller steps to an array: PowerShell unrolls a 1-element array into a scalar
    # both at parameter binding and at return, so EVERY return path must wrap with ,@() once
    # to preserve the "returns an array of steps" contract (even when CallerSteps is scalar/$null).
    if ($null -eq $CallerSteps) { return ,@() }
    $callerArr = @($CallerSteps)

    $cfg = Get-ConfigSection -State $State -Path 'build.pipeline'

    # -- Pipeline-as-code (gbuild.pipeline.yml) --------------------------------
    # A YAML pipeline, when present, takes precedence over build.pipeline.steps
    # in gbuild.config.json. Previously README documented this whole feature
    # while nothing implemented it: no YAML parser existed, no example file was
    # shipped, and Resolve-PipelineSteps only ever read the JSON key - so a
    # `gbuild.pipeline.yml` was silently ignored.
    $yamlSteps = Resolve-PipelineYamlSteps -State $State
    if ($yamlSteps) { return ,@($yamlSteps) }

    if (-not $cfg -or -not ($cfg.PSObject.Properties.Name -contains 'steps')) {
        return ,@($callerArr)
    }

    $rawSteps = $cfg.steps
    if ($null -eq $rawSteps) { return ,@($callerArr) }
    $validate = $true
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $validate = [bool](Get-BuildConstant -Key 'PipelineValidate' -State $State -Fallback $true)
        } elseif ($cfg.PSObject.Properties.Name -contains 'validate') {
            $validate = [bool]$cfg.validate
        }
    } catch { $validate = $true }
    $resolved = [System.Collections.ArrayList]::new()
    $cfgSteps = @($rawSteps)
    if ($cfgSteps.Count -eq 0) { return ,@($callerArr) }
    # L5: pipeline mode (default 'replace' = legacy behaviour). 'append' runs
    # caller steps then config steps; 'merge' overrides same-name caller steps
    # in place and appends new names. Previously any non-empty config steps
    # REPLACED the 12 built-in steps, so a one-step typo silently dropped
    # RegisterPlugins..Build. Mode is additive and defaults to replace, so
    # existing configs/tests are unaffected.
    $mode = 'replace'
    try {
        if ($cfg.PSObject.Properties.Name -contains 'mode' -and $cfg.mode) { $mode = ([string]$cfg.mode).ToLowerInvariant() }
    } catch { $mode = 'replace' }
    if ($mode -notin @('replace','merge','append')) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m31' -MessageArgs @("mode='$mode'", 'replace, merge, append')) 'Warn' $State
        }
        $mode = 'replace'
    }
    $allowedKeys = @('name', 'script', 'when', 'retry', 'timeoutSeconds', 'jobIsolated')
    foreach ($cfgStep in @($cfg.steps)) {
        $propNames = @($cfgStep.PSObject.Properties.Name)
        if ($validate) {
            # Missing 'script' is fatal (nothing to run); missing 'name' stays
            # backward-compatible (defaults to StepN, covered by PipelineRunner.Tests).
            if (-not ($propNames -contains 'script')) {
                throw (Get-LocaleMessage -Key 'log.orch.pipelineStepMissingScript' -MessageArgs @([string]($propNames -join ', ')) -Fallback "Invalid build.pipeline.steps entry: each step requires 'script' (got: {0}).")
            }
            if (-not ($propNames -contains 'name') -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m30' -MessageArgs @($($resolved.Count))) 'Warn' $State
            }
            $unknown = @($propNames | Where-Object { $_ -notin $allowedKeys })
            if ($unknown.Count -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m31' -MessageArgs @($($unknown -join ', '), $($allowedKeys -join ', '))) 'Warn' $State
            }
        }
        $scriptBody = if ($propNames -contains 'script') { [string]$cfgStep.script } else { '' }
        $whenBody = if ($propNames -contains 'when') { [string]$cfgStep.when } else { $null }
        # Fail fast on PowerShell parse errors (trusted local config, no sandbox).
        foreach ($body in @(@{ Label = 'script'; Text = $scriptBody }, @{ Label = 'when'; Text = $whenBody })) {
            if ([string]::IsNullOrWhiteSpace($body.Text)) { continue }
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($body.Text, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                throw (Get-LocaleMessage -Key 'log.orch.pipelineStepParseError' -MessageArgs @([string]$cfgStep.name, [string]$body.Label, [string]$parseErrors.Count, [string]$parseErrors[0].Message) -Fallback "Invalid build.pipeline.steps entry '{0}': {1} has {2} parse error(s): {3")
            }
        }
        $entry = @{
            Name = if ($propNames -contains 'name') { $cfgStep.name } else { "Step$($resolved.Count)" }
            Script = if ($propNames -contains 'script') { [scriptblock]::Create($scriptBody) } else { { } }
        }
        if ($propNames -contains 'when') {
            $entry.When = [scriptblock]::Create($whenBody)
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'retry') {
            $entry.Retry = [int]$cfgStep.retry
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'timeoutSeconds') {
            $entry.TimeoutSeconds = [int]$cfgStep.timeoutSeconds
        }
        if ($cfgStep.PSObject.Properties.Name -contains 'jobIsolated') {
            $entry.JobIsolated = [bool]$cfgStep.jobIsolated
        }
        $resolved.Add($entry) | Out-Null
    }
    if ($mode -eq 'append') {
        $combined = [System.Collections.ArrayList]::new()
        foreach ($c in @($callerArr)) { [void]$combined.Add($c) }
        foreach ($e in @($resolved.ToArray())) { [void]$combined.Add($e) }
        return ,@($combined.ToArray())
    }
    if ($mode -eq 'merge') {
        $merged = [System.Collections.ArrayList]::new()
        foreach ($c in @($callerArr)) { [void]$merged.Add($c) }
        $nameIndex = @{}
        for ($i = 0; $i -lt $merged.Count; $i++) {
            $n = ''
            try {
                $item = $merged[$i]
                if ($item -is [System.Collections.IDictionary]) { if ($item.Contains('Name')) { $n = [string]$item['Name'] } }
                elseif ($item -and $item.PSObject -and $item.PSObject.Properties.Name -contains 'Name') { $n = [string]$item.Name }
            } catch { $n = '' }
            if ($n -ne '') { $nameIndex[$n] = $i }
        }
        foreach ($e in @($resolved.ToArray())) {
            $en = [string]$e['Name']
            if ($en -ne '' -and $nameIndex.ContainsKey($en)) { $merged[$nameIndex[$en]] = $e }
            else { [void]$merged.Add($e) }
        }
        return ,@($merged.ToArray())
    }
    # Preserve the documented "Returns: array" contract even for a single config
    # step — $resolved.ToArray() unrolls to a bare hashtable on a single item.
    return ,@($resolved.ToArray())
}

function Resolve-PipelineYamlSteps {
    [CmdletBinding()]
    [OutputType([array])]
    param([PSCustomObject]$State)

    $hasCommand = [bool](Get-Command Get-BuildYamlPipelineDocument -ErrorAction SilentlyContinue)
    if (-not $hasCommand) {
        # This file lives in Modules/Orchestrator since the split; the module
        # root is its parent (or $PSScriptRoot itself if dot-sourced from
        # Modules/ root, which is how the test suite dot-sources it).
        $yamlDir = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'YamlPipeline.psm1') -PathType Leaf) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
        $yamlPath = Join-Path $yamlDir 'YamlPipeline.psm1'
        if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) { return $null }
        Import-ModuleOnDemand -ModuleNames @('YamlPipeline')
        if (-not (Get-Command Get-BuildYamlPipelineDocument -ErrorAction SilentlyContinue)) { return $null }
    }

    $doc = Get-BuildYamlPipelineDocument -State $State
    if ($null -eq $doc) { return $null }

    # Throws on an invalid pipeline: the operator asked for this file, so
    # silently building something else would be worse than failing.
    Test-PipelineYamlDocument -Document $doc -State $State | Out-Null

    $envApplied = Set-PipelineYamlEnvironment -Document $doc -State $State
    try {
        $steps = ConvertFrom-PipelineYamlStep -Document $doc -State $State
    } finally {
        Clear-PipelineYamlEnvironment -Applied $envApplied
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $src = ''
        try { if ($doc.PSObject.Properties.Name -contains 'SourcePath') { $src = [string]$doc.SourcePath } } catch { }
        Write-Log (Get-LocaleMessage -Key 'log.pipeline.yamlLoaded' -MessageArgs @(@($steps).Count, $src)) 'Info' $State
    }
    return ,@($steps)
}

function Get-PipelineStepDisplayName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StepName)
    $key = "log.stepName.$StepName"
    $text = Get-LocaleMessage -Key $key -Fallback $StepName
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq $key) { return $StepName }
    return $text
}

<#
.SYNOPSIS
    Executes a single pipeline step with optional retry.
.DESCRIPTION
    Per-step timeoutSeconds is cooperatively enforced as an SLA: the step runs
    in-process, wall-clock is measured, and exceeding the SLA fails the step
    (retry if enabled). True preemptive kill is deliberately NOT attempted —
    killing a step mid-execution in-process would corrupt shared build state.
    Whole-pipeline stepTimeoutSeconds watchdog shares the same post-hoc semantics.
#>
<#
.SYNOPSIS
    Runs one pipeline-step attempt inside a background job with a hard timeout.
.DESCRIPTION
    This is the REAL pre-emptive enforcement behind timeoutSeconds. The
    in-process path can only measure a breach after the step body returns -
    a hung step hangs the pipeline. A Start-Job child is a separate process:
    when Wait-Job exceeds the timeout, Stop-Job kills it and the step fails
    with a StepTimeout error that the normal retry loop then handles exactly
    like the in-process SLA breach (same FullyQualifiedErrorId).

    CONTRACT (must hold for the merge-back to be faithful):
      * The step body runs against a DESERIALIZED COPY of $Context. Whatever
        it assigns is merged back key-by-key on success, so $ctx.csproj,
        $ctx.buildOk, $ctx.skippedSteps and friends survive. New keys the
        step creates are added too.
      * $State travels as a read-only snapshot. A step that MUTATES $State
        (rather than $ctx) loses those writes in job mode - every built-in
        step communicates via $ctx, so this only binds custom steps, and it
        is stated here rather than discovered in production.
      * Module functions the step calls (Register-Plugins, Write-Log,
        Import-ModuleOnDemand, ...) resolve because the job bootstraps the
        real module tree from $ModulesRoot. A step that depends on the
        CALLER's live session (closures, $script: state, runspace-bound COM
        objects) cannot cross the process boundary and must stay in-process.
      * Step output objects do not survive serialization with their types;
        they come back as strings/property bags. The engine discards step
        output (Out-Null), so this binds direct callers only.
.OUTPUTS
    The step's output array (stringified for safe transport).
#>

function Invoke-PipelineStepJobAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Step,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [int]$TimeoutSec,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$ModulesRoot
    )
    $scriptText = [string]$Step.Script
    # PID-qualified: two concurrent builds running the same step name would
    # otherwise share one job name, so Get-Job/Wait-Job/Stop-Job could attach
    # to the sibling build's job. (The cluster daemon jobs above dedupe by
    # fixed name intentionally - they are singletons. Step attempts are not.)
    $jobName = 'gbuild-step-{0}-{1}' -f ([string]$Step.Name -replace '[^A-Za-z0-9_-]', '_'), $PID
    $job = $null
    try {
        $job = Start-Job -Name $jobName -ScriptBlock {
            param($ScriptText, $CtxData, $StateData, $Root)
            $ErrorActionPreference = 'Stop'
            # Locale first: the bootstrap failure below must itself be
            # localizable, and Locale is a leaf module with no dependencies.
            $localeMod = Join-Path $Root 'Locale.psm1'
            if (Test-Path -LiteralPath $localeMod -PathType Leaf) {
                Import-Module $localeMod -Global -DisableNameChecking -ErrorAction SilentlyContinue | Out-Null
            }
            $modPath = Join-Path $Root 'Orchestrator.psm1'
            if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) {
                $bootMsg = 'log.pipeline.jobBootstrap'
                if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
                    $bootMsg = Get-LocaleMessage -Key 'log.pipeline.jobBootstrap' -MessageArgs @($Root)
                }
                throw $bootMsg
            }
            Import-Module $modPath -Global -DisableNameChecking -ErrorAction Stop | Out-Null
            $Context = $CtxData
            $State = $StateData
            $stepBody = [scriptblock]::Create($ScriptText)
            $output = & $stepBody $Context 2>&1
            # Same failure contract as the in-process path: an ErrorRecord or
            # Exception anywhere in the output stream fails the attempt, with
            # the root message preserved.
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw (Resolve-LogMessage -Key 'log.orchestrator.stepFailed' -MessageArgs @([string]$detail) -Fallback ('STEPFAILED: {0}' -f $detail))
                }
            }
            return @{ Output = @($output); Context = $Context }
        } -ArgumentList @($scriptText, $Context, $State, $ModulesRoot)
        $done = Wait-Job -Job $job -Timeout $TimeoutSec
        if (-not $done) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new((Get-LocaleMessage -Key 'log.pipeline.jobKilled' -MessageArgs @($DisplayName, $TimeoutSec))),
                'StepTimeout',
                'InvalidOperation',
                $null
            )
        }
        $envelope = Receive-Job -Job $job
        if ($job.State -eq 'Failed') {
            $reason = ''
            try { $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason.Message } catch { $reason = '' }
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "job '$jobName' failed without a recorded reason" }
            if ($reason.StartsWith('STEPFAILED: ')) { throw $reason.Substring('STEPFAILED: '.Length) }
            throw $reason
        }
        if ($null -ne $envelope -and $envelope -is [System.Collections.IDictionary] -and $envelope.Contains('Context')) {
            $back = $envelope['Context']
            if ($back -is [System.Collections.IDictionary]) {
                foreach ($k in @($back.Keys)) {
                    try { $Context[$k] = $back[$k] } catch { }
                }
            }
            if ($envelope.Contains('Output')) { return @($envelope['Output']) }
        }
        return @()
    } finally {
        if ($null -ne $job) {
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-PipelineStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Step,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [string]$LeftBracket = '[',
        [string]$RightBracket = ']'
    )
    $stepName = $Step.Name
    $displayStepName = Get-PipelineStepDisplayName -StepName $stepName
    $stepScript = $Step.Script
    $stepKeys = @($Step.Keys)
    # L5 watchdog: if stepTimeoutSeconds is configured (ROOT-level stepTimeoutSeconds,
    # we monitor elapsed wall-clock time. When exceeded, we log and treat the
    # step as failed (retry if enabled, otherwise pipeline continues). This avoids
    # the Start-Job sandbox isolation problem entirely — the step runs in-process
    # and we simply cut it off after the threshold.
    $stepTimeoutSec = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        [int](Get-BuildConstant -Key 'StepTimeoutSeconds' -State $State -Fallback 0)
    } else { 0 }
    # Always initialize: under Set-StrictMode, referencing an unset $stepWatch
    # inside $action below throws for every step when no timeout is configured.
    $stepWatch = $null
    if ($stepTimeoutSec -gt 0) {
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $retryEnabled = [bool](Get-BuildConstant -Key 'PipelineRetryEnabled' -State $State -Fallback $true)
    $maxRetries = if ($stepKeys -contains 'Retry') { [int]$Step.Retry } else {
        # Fallback to config maxRetries
        [int](Get-BuildConstant -Key 'PipelineMaxRetries' -State $State -Fallback 0)
    }
    if (-not $retryEnabled) { $maxRetries = 0 }
    $timeoutSec = if ($stepKeys -contains 'TimeoutSeconds') { [int]$Step.TimeoutSeconds } else { 0 }
    if ($timeoutSec -lt 0) { $timeoutSec = 0 }

    # Job isolation (opt-in per step via 'job' / 'jobIsolated'). A step that
    # opts in runs its body in a background job with a HARD timeout:
    # Wait-Job stops waiting, Stop-Job kills the hung child process, and the
    # attempt fails with StepTimeout. The in-process path below can only
    # measure a breach after the body returns, so without this a hung step
    # hangs the pipeline. Isolation REQUIRES a timeout: a job without one is
    # rejected loudly rather than silently run in-process.
    $jobIsolated = ($stepKeys -contains 'JobIsolated' -and [bool]$Step.JobIsolated) -or ($stepKeys -contains 'Job' -and [bool]$Step.Job)
    if ($jobIsolated -and $timeoutSec -le 0) {
        throw (Get-LocaleMessage -Key 'log.pipeline.jobNoTimeout' -MessageArgs @($displayStepName))
    }

    # L5: per-step timeoutSeconds is now cooperatively enforced (SLA check).
    # Previously any step setting it threw immediately without running.
    # True preemptive kill is unsafe in-process (state corruption), so we run
    # the step, measure wall-clock, and fail it when the SLA is exceeded —
    # same semantics as the root stepTimeoutSeconds watchdog below. Honest
    # enforcement without pretending to kill mid-execution.
    $stepTimer = $null
    if ($timeoutSec -gt 0) { $stepTimer = [System.Diagnostics.Stopwatch]::StartNew() }

    # Delegate retry logic to ErrorHandling.Invoke-WithRetry (single source for retry semantics)
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        if ($jobIsolated) {
            $action = {
                if ($stepWatch) { $stepWatch.Start() }
                # Each attempt gets the FULL timeout (a killed job is dead and
                # cannot be resumed), matching the standalone fallback below.
                $output = Invoke-PipelineStepJobAttempt -Step $Step -Context $Context -State $State -TimeoutSec $timeoutSec -DisplayName $displayStepName -ModulesRoot $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.psm1') -PathType Leaf) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot })
                if ($stepWatch) { $stepWatch.Stop() }
                # Root watchdog still applies post-hoc: a step that finished
                # inside its own timeout may still have blown the pipeline-wide
                # budget, and that breach must fail the step the same way.
                if ($stepTimeoutSec -gt 0 -and $stepWatch -and $stepWatch.Elapsed.TotalSeconds -ge $stepTimeoutSec) {
                    Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $stepTimeoutSec)) 'Warn' $State
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.Exception]::new("Step '$displayStepName' timed out after $stepTimeoutSec s"),
                        "StepTimeout",
                        'InvalidOperation',
                        $null
                    )
                }
                return $output
            }
            return Invoke-WithRetry -Action $action -OperationName "Pipeline step [$displayStepName] (job)" -MaxRetries $maxRetries -State $State
        }
        $action = {
            if ($stepWatch) { $stepWatch.Start() }
            $output = & $stepScript $Context 2>&1
            if ($stepTimer) { $stepTimer.Stop() }
            # Per-step SLA: fail when the step's own timeoutSeconds is exceeded.
            if ($timeoutSec -gt 0 -and $stepTimer -and $stepTimer.Elapsed.TotalSeconds -ge $timeoutSec) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $timeoutSec)) 'Warn' $State
                }
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' exceeded its timeoutSeconds SLA of $timeoutSec s (took $([math]::Round($stepTimer.Elapsed.TotalSeconds,1)) s)"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            # Watchdog: if stepTimeoutSec is configured and step exceeds it, cut off.
            if ($stepTimeoutSec -gt 0 -and $stepWatch -and $stepWatch.IsRunning -and $stepWatch.Elapsed.TotalSeconds -ge $stepTimeoutSec) {
                $stepWatch.Stop()
                Write-Log (Get-LocaleMessage -Key 'log.step.timeout' -MessageArgs @($displayStepName, $stepTimeoutSec)) 'Warn' $State
                # Throw an ErrorRecord so Invoke-WithRetry treats this as a step
                # failure (retry if enabled, otherwise the pipeline sees the
                # timeout). A discarded $null = ErrorRecord would silently
                # swallow the breach — log-only is not enforcement.
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' timed out after $stepTimeoutSec s"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            if ($stepWatch) { $stepWatch.Stop() }
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    # Preserve the root cause: the legacy generic message hid which
                    # command inside the step actually failed (undebuggable builds).
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw ((Get-LocaleMessage -Key 'log.step.failed' -MessageArgs $displayStepName) + ": $detail")
                }
            }
            return $output
        }
        return Invoke-WithRetry -Action $action -OperationName "Pipeline step [$displayStepName]" -MaxRetries $maxRetries -State $State
    }

    # Fallback when ErrorHandling is not loaded (standalone bundle without the
    # Tier-1 chain). This MUST mirror Invoke-WithRetry's contract, otherwise the
    # two paths disagree: the previous version retried EVERY error - including
    # permanent compile/config failures - with NO delay, so maxRetries iterations
    # completed in microseconds and a step with a side effect (publish, deploy,
    # artifact upload) that failed AFTER the side effect was re-executed
    # immediately N times, turning one network timeout into N duplicate uploads.
    $baseDelayMs = 500
    $maxDelayMs = 10000
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $baseDelayMs = [int](Get-BuildConstant -Key 'RetryBaseDelay' -State $State -Fallback 500) } catch { }
        try { $maxDelayMs = [int](Get-BuildConstant -Key 'RetryMaxDelayMs' -State $State -Fallback 10000) } catch { }
    }
    $attempt = 0
    while ($true) {
        try {
            if ($jobIsolated) {
                $output = Invoke-PipelineStepJobAttempt -Step $Step -Context $Context -State $State -TimeoutSec $timeoutSec -DisplayName $displayStepName -ModulesRoot $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Orchestrator.psm1') -PathType Leaf) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot })
                return $output
            }
            if ($stepTimer) { try { $stepTimer.Restart() } catch { } }
            $output = & $stepScript $Context 2>&1
            if ($stepTimer) { try { $stepTimer.Stop() } catch { } }
            if ($timeoutSec -gt 0 -and $stepTimer -and $stepTimer.Elapsed.TotalSeconds -ge $timeoutSec) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Step '$displayStepName' exceeded its timeoutSeconds SLA of $timeoutSec s"),
                    "StepTimeout",
                    'InvalidOperation',
                    $null
                )
            }
            foreach ($o in @($output)) {
                if ($o -is [System.Management.Automation.ErrorRecord] -or $o -is [System.Exception]) {
                    $detail = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { $o.Message }
                    throw ((Get-LocaleMessage -Key 'log.step.failed' -MessageArgs $displayStepName) + ": $detail")
                }
            }
            return $output
        } catch {
            $attempt++
            # Same transient-only classification as Get-ErrorCategory: retry
            # network/lock/IO style failures, fail fast on anything permanent.
            $category = 'Permanent'
            if (Get-Command Get-ErrorCategory -ErrorAction SilentlyContinue) {
                try { $category = [string](Get-ErrorCategory -ErrorRecord $_) } catch { $category = 'Permanent' }
            } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                $msg = [string]$_.Exception.Message
                if ($msg -match '(?i)timeout|timed out|connection|network|unavailable|temporar|being used by another process|could not obtain a lock') { $category = 'Transient' }
            }
            if ($category -ne 'Transient' -or $attempt -gt $maxRetries) { throw }
            $delay = [Math]::Min($baseDelayMs * [Math]::Pow(2, $attempt - 1), $maxDelayMs)
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                $lb = if ($LeftBracket) { $LeftBracket } else { '[' }
                $rb = if ($RightBracket) { $RightBracket } else { ']' }
                Write-Log "$lb$(Get-LocaleMessage -Key 'log.step.retry' -MessageArgs $displayStepName, $attempt, $maxRetries, $_.Exception.Message) (retry in ${delay}ms)$rb" 'Warn' $State
            }
            Start-Sleep -Milliseconds $delay
        }
    }
}

<#
.SYNOPSIS
    Executes a build pipeline: a sequence of named steps with events, metrics,
    optional retry, timeout, and When conditions.
.DESCRIPTION
    Provides the pipeline step abstraction for Start-GBuild. Each step is a
    hashtable with Name + Script ({ param($ctx) ... }). The runner emits
    EventBus lifecycle events (EVT_BUILD_START / EVT_STEP_START / EVT_STEP_COMPLETE /
    EVT_STEP_ERROR / EVT_BUILD_COMPLETE), records per-step duration metrics,
    honours step-level When/Retry, enforces the whole-pipeline timeout, and
    re-throws on the first step failure so the caller's error handling
    (rollback, telemetry) is preserved.
#>

function Invoke-GBuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [Parameter(Mandatory=$true)] [hashtable]$Context,
        [Parameter(Mandatory=$true)] [array]$Steps
    )

    $lb = if ($State.PSObject.Properties.Name -contains 'LeftBracket') { $State.LeftBracket } else { '[' }
    $rb = if ($State.PSObject.Properties.Name -contains 'RightBracket') { $State.RightBracket } else { ']' }

    $effectiveSteps = Resolve-PipelineSteps -State $State -CallerSteps $Steps
    $cancelled = $false

    # Pipeline-level timeout enforcement
    $pipelineTimeout = 0
    $pipelineTimeout = [int](Get-BuildConstant -Key 'PipelineTimeoutSeconds' -State $State -Fallback 0)
    $pipelineSw = [System.Diagnostics.Stopwatch]::StartNew()

    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        Send-BuildEvent -EventName $EVT_BUILD_START -Source $State -Data @{ Steps = $effectiveSteps.Count } | Out-Null
    }

    # Level 5 wiring: quick pre-flight health gate runs at pipeline start.
    # Test-PreFlight is a no-op when HealthCheck is absent, so this never
    # breaks minimal/standalone flows.
    if (Get-Command Test-PreFlight -ErrorAction SilentlyContinue) {
        try { [void](Test-PreFlight -State $State) } catch { }
    }
    # Ensure project .gitignore covers gbuild runtime artifacts (no hardcode:
    # patterns come from BuildConstants.ProjectGitignorePatterns / config).
    if (Get-Command Update-ProjectGitignore -ErrorAction SilentlyContinue) {
        try { Update-ProjectGitignore -State $State -ProjectDir $State.ProjectRoot } catch { }
    }

    foreach ($step in $effectiveSteps) {
        $stepName = $step.Name
        $displayStepName = Get-PipelineStepDisplayName -StepName $stepName
        $Context.CurrentStep = $stepName

        # Cancellation check (supports external abort via $Context.PipelineCancelled)
        if ($Context.PipelineCancelled) {
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.cancelled' -MessageArgs $displayStepName)$rb" 'Warn' $State
            $cancelled = $true
            break
        }

        # When condition: skip step if scriptblock returns false/null/0
        if ($step.When) {
            try {
                $whenResult = [bool](& $step.When $Context)
            } catch {
                 Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.whenError' -MessageArgs $displayStepName, $_.Exception.Message)$rb" 'Warn' $State
                $whenResult = $true
            }
            if (-not $whenResult) {
                 Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.skipped' -MessageArgs $displayStepName)$rb" 'Info' $State
                if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                    Send-BuildEvent -EventName $EVT_STEP_SKIPPED -Source $State -Data @{ Step = $stepName; Reason = 'WhenConditionFalse' } | Out-Null
                }
                continue
            }
        }

        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_STEP_START -Source $State -Data @{ Step = $stepName } | Out-Null
        }
         Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.running' -MessageArgs $displayStepName)$rb" 'Info' $State

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-PipelineStep -Step $step -Context $Context -State $State -LeftBracket $lb -RightBracket $rb | Out-Null
            $sw.Stop()
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_STEP_COMPLETE -Source $State -Data @{ Step = $stepName; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) } | Out-Null
            }
            if (Get-Command Add-Metric -ErrorAction SilentlyContinue) {
                Add-Metric -Metric (New-MetricHistogram -Name 'gbuild_step_duration_seconds' -Help 'Per-step build duration in seconds' -Value ([math]::Round($sw.Elapsed.TotalSeconds, 4)) -Labels @{ step = $stepName })
            }
        } catch {
            $sw.Stop()
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_STEP_ERROR -Source $State -Data @{ Step = $stepName; Error = $_.Exception.Message } | Out-Null
            }
            if (Get-Command Add-Metric -ErrorAction SilentlyContinue) {
                Add-Metric -Metric (New-MetricHistogram -Name 'gbuild_step_duration_seconds' -Help 'Per-step build duration in seconds' -Value ([math]::Round($sw.Elapsed.TotalSeconds, 4)) -Labels @{ step = $stepName; status = 'failed' })
            }
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.failed' -MessageArgs $displayStepName, $_.Exception.Message)$rb" 'Err' $State
            throw
        }

        # Pipeline-level timeout check
        if ($pipelineTimeout -gt 0 -and $pipelineSw.Elapsed.TotalSeconds -ge $pipelineTimeout) {
             Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.timeout' -MessageArgs $pipelineTimeout)$rb" 'Warn' $State
            $cancelled = $true
            break
        }
    }

    if (-not $cancelled) {
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_BUILD_COMPLETE -Source $State -Data @{ Status = 'Success' } | Out-Null
        }
    }

    if ($cancelled) {
         Write-Log "$lb$(Get-LocaleMessage -Key 'log.pipeline.cancelledAt' -MessageArgs $stepName)$rb" 'Warn' $State
    }
    $pipelineSw.Stop()
}

<#
.SYNOPSIS
    Resolves builder correlation id + tenant id and stamps them onto State.
#>

function Test-StepEnabled {
    # Single owner of the step enable/disable prologue that was hand-copied
    # into each of the nine optional gate steps (AffectedScan, SecurityScan,
    # AutoTune, SupplyChain, SastScan, PolicyCheck, SiemExport,
    # StandaloneBundle, PublishArtifact). Each copy read Get-ConfigSection,
    # pulled its 'enabled' value, and Write-SkippedStep'd when off - but the
    # copies had already started to drift (SupplyChain used one value key,
    # SecurityScan ORed a CLI switch into the same decision, AutoTune
    # conjoined a second key). This helper owns the decision; the step keeps
    # only its own body.
    #
    # Keys: config dot-paths resolved by Get-ConfigSection's own
    # enabled/value lookup. Sections: for gates keyed off a non-'enabled'
    # value, set -ValueKey. OnePath/OneKey pairs are the simple case; the
    # SupplyChain gate passes two (sbom | provenance).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$StepLabel,
        [Parameter(Mandatory)] [string]$Reason,
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [PSCustomObject]$State,
        # Dot-paths (read by Get-ConfigValue) to the boolean enablement values.
        # One path = a single gate switch; several = OR (SupplyChain:
        # 'security.sbom.enabled' OR 'security.provenance.enabled').
        [Parameter(Mandatory)] [string[]]$EnablePaths,
        # When no path yields a value, this default decides (single-source
        # fallback for a config-less project). RequireAll mode ignores it (a
        # AND-gate without every key cannot prove it is armed, so it is off).
        [bool]$DefaultEnabled = $false,
        # Every path must be present AND true (AutoTune: enabled AND autoApply).
        [switch]$RequireAll,
        # A CLI switch that forces the gate on (SecurityScan's -Security).
        [bool]$ForceOn
    )
    # Resolve over Get-ConfigValue so leaves and sections read uniformly.
    # OR mode (default): true if any path's value is truthy. If NO path
    # yields a value (key absent everywhere), the gate's DefaultEnabled wins.
    # RequireAll: every path's value must be truthy; a null/absent path counts
    # as false (a gate without its config cannot prove it is armed).
    # ForceOn (a CLI switch) always wins.
    $enabled = $DefaultEnabled
    $saw = $false; $anyTrue = $false
    foreach ($pp in $EnablePaths) {
        $v = Get-ConfigValue -Path $pp -State $State -Default $null
        if ($null -ne $v) {
            $saw = $true
            $b = $false
            try { $b = [bool]$v } catch { $b = ($v -is [string] -and $v.ToLowerInvariant() -eq 'true') }
            if ($b) { $anyTrue = $true }
            elseif ($RequireAll) { $anyTrue = $false; break }
        } elseif ($RequireAll) { $anyTrue = $false; break }
    }
    if ($RequireAll) {
        # All must be present-and-true; a single absent path already failed
        # above. Count true-only paths.
        $trueCount = 0
        foreach ($pp in $EnablePaths) {
            $v = Get-ConfigValue -Path $pp -State $State -Default $null
            if ($null -eq $v) { $trueCount = -1; break }
            try { if ([bool]$v) { $trueCount++ } } catch { $trueCount = -1; break }
        }
        $enabled = ($trueCount -ne -1 -and $trueCount -eq $EnablePaths.Count)
    } elseif ($saw) {
        $enabled = $anyTrue
    }
    if ($ForceOn) { $enabled = $true }
    if (-not $enabled) {
        Write-SkippedStep -Step $StepLabel -Reason $Reason -Context $Context -State $State
        return $false
    }
    return $true
}

function Write-SkippedStep {
    param([string]$Step, [string]$Reason, $Context, $State)

        $scoped = $true
        try {
            if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { $scoped = [bool](Get-BuildSetting -Key 'LogScopedLogging' -State $State -Fallback $true) }
            elseif (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { $scoped = [bool](Get-ConfigValue -Path 'build.scopedLogging' -State $State -Default $true) }
        } catch { $scoped = $true }
        if ($scoped) { [void]$Context.skippedSteps.Add("$Step ($Reason)") }
        else { Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m66' -MessageArgs @($Step, $Reason)) 'Gray' $State }
    }

<#
.SYNOPSIS
    Single writer for the pipeline publish-output location.
.DESCRIPTION
    Both build branches (plugin dispatch and menu-driven .NET) funnel through
    here so downstream consumers (SupplyChain provenance, deploy targets, GPG
    signing) share one source. Previously every consumer read
    $ctx.publishOutput, which nothing in either branch ever assigned, so the
    provenance/deploy chain always fell back to re-resolving a directory
    that might not exist - and a green build with no artifacts passed
    silently, leaving the operator to discover the missing folder.
    Never throws: returns '' when nothing was produced, and says so loudly.
#>

function Invoke-PluginTestAndLintGate {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectDir = '',
        [Parameter(Mandatory)][string]$Language,
        $TestFlags,
        [switch]$Detailed
    )
    if ($null -eq $TestFlags) { $TestFlags = Get-BuildTestConfig -State $State }
    if ($TestFlags.TestEnabled) {
        if (-not (Get-Command Invoke-PluginTestFor -ErrorAction SilentlyContinue)) {
            throw (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Invoke-PluginTestFor') -Fallback 'Invoke-PluginTestFor not loaded.')
        }
        $testResult = Invoke-PluginTestFor -State $State -Language $Language -ProjectDir $ProjectDir -Detailed:$Detailed
        $testGate = Test-BuildGateResult -Result $testResult -Operation "test:$Language" -StageLabel 'Tests' -State $State
        if ($testGate.Skipped) { Write-SubLog ("Skipped tests for {0}: {1}" -f $Language, $testGate.Message) }
        # PUBLISH THE VERDICT. The gate produced a verdict and dropped it: the
        # build kept no record of which language was tested, and no JUnit
        # artifact was ever written, so a CI consumer had nothing to consume
        # even though the exporter existed and the shipped schema advertised
        # report.format = "junit". Record it on the state and publish the
        # artifact; both are best-effort and must never fail the build.
        if (Get-Command Add-BuildTestResult -ErrorAction SilentlyContinue) {
            try { $null = Add-BuildTestResult -State $State -Result $testGate -Suite $Language } catch { }
        }
        if (Get-Command Publish-BuildJUnitArtifact -ErrorAction SilentlyContinue) {
            try { $null = Publish-BuildJUnitArtifact -State $State -SuiteName 'gbuild' } catch { }
        }
        if (-not $testGate.Passed) {
            if (Get-Command Write-BuildGateDiagnostics -ErrorAction SilentlyContinue) { Write-BuildGateDiagnostics -Gate $testGate -State $State }
            $testDetail = if ($testGate.Message) { [string]$testGate.Message } else { '' }
            $message = Get-LocaleMessage -Key 'log.plugin.testFailed' -MessageArgs @($Language, $testDetail)
            Write-Fail $message -State $State
            throw $message
        }
    }
    if ($TestFlags.LintEnabled) {
        if (-not (Get-Command Invoke-PluginLintFor -ErrorAction SilentlyContinue)) {
            throw (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Invoke-PluginLintFor') -Fallback 'Invoke-PluginLintFor not loaded.')
        }
        $lintResult = Invoke-PluginLintFor -State $State -Language $Language -ProjectDir $ProjectDir -Detailed:$Detailed
        $lintGate = Test-BuildGateResult -Result $lintResult -Operation "lint:$Language" -StageLabel 'Lint' -State $State
        if ($lintGate.Skipped) { Write-SubLog ("Skipped lint for {0}: {1}" -f $Language, $lintGate.Message) }
        if (-not $lintGate.Passed) {
            if (Get-Command Write-BuildGateDiagnostics -ErrorAction SilentlyContinue) { Write-BuildGateDiagnostics -Gate $lintGate -State $State }
            $lintDetail = if ($lintGate.Message) { [string]$lintGate.Message } else { '' }
            $message = Get-LocaleMessage -Key 'log.plugin.lintFailed' -MessageArgs @($Language, $lintDetail)
            Write-Fail $message -State $State
            throw $message
        }
    }
    return $true
}

<#
.SYNOPSIS
    Resolves deploy-choice MSBuild args from config (Level 5 single-source).
.DESCRIPTION
    Reads build.deployChoiceArgs.* via Get-BuildConstant so MSBuild args change
    without code edits. Falls back to BuildConstants defaults when config is absent.
#>

# NOTE: Register-BuildEventSubscribers / Unregister-BuildEventSubscribers /
# Register-BuildServices are now in Orchestrator.Pipeline.Events.ps1 so the
# event-wiring surface is explicit and discoverable. Orchestrator.psm1 dot-sources
            # The gate reads the RESOLVED config (machine profile merged with the
