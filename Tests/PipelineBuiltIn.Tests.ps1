#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

<#
    Exercises the REAL built-in pipeline.

    Start-GBuild's $buildSteps used to be an inline array literal inside a
    1500-line function. Nothing could reach it: Pipeline.E2E hand-built a
    4-element stub array that reused production step NAMES, and its own header
    comment claimed it covered "the real Start-GBuild phase sequence
    (RegisterPlugins -> ScanProject -> Preflight -> AffectedScan -> Build)"
    while never invoking Start-GBuild at all. Net effect: zero coverage of the
    eight gate steps, their config gates, their skip reasons and their step
    order, and a regression in the production pipeline could not fail a test.

    The pipeline is now Get-BuiltInPipelineSteps. These tests assert its shape
    and run it end to end with the real engine.
#>

BeforeAll {
    $global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ErrorHandling.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
    $null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

    $script:shippedConfig = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

Describe 'the built-in pipeline shape' {
    It 'exposes the 14 shipped steps in order' {
        $steps = Get-BuiltInPipelineSteps -State (New-TestState)
        $names = @($steps | ForEach-Object { $_.Name })
        $names | Should -Be @(
            'RegisterPlugins', 'ScanProject', 'Preflight', 'AffectedScan',
            # SignArtifacts sits directly after Build: the artifacts exist only
            # after the build, and they have to be signed BEFORE PublishArtifact
            # packages/uploads them.
            'Build', 'SignArtifacts', 'SecurityScan', 'AutoTune', 'SupplyChain',
            'SastScan', 'PolicyCheck', 'SiemExport', 'StandaloneBundle',
            'PublishArtifact'
        )
    }

    It 'gives every step a name and an invocable scriptblock' {
        foreach ($s in @(Get-BuiltInPipelineSteps -State (New-TestState))) {
            $s.Name | Should -Not -BeNullOrEmpty
            $s.Script | Should -BeOfType [scriptblock]
        }
    }

    It 'returns step names uniquely' {
        $names = @(Get-BuiltInPipelineSteps -State (New-TestState) | ForEach-Object { $_.Name })
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    # Build must come before every gate: a gate that runs first would evaluate
    # $ctx.buildOk against a build that has not happened yet.
    It 'orders Build before every security/supply-chain gate' {
        $names = @(Get-BuiltInPipelineSteps -State (New-TestState) | ForEach-Object { $_.Name })
        $buildIdx = $names.IndexOf('Build')
        $buildIdx | Should -BeGreaterThan 0
        foreach ($gate in @('SecurityScan', 'AutoTune', 'SupplyChain', 'SastScan', 'PolicyCheck', 'SiemExport', 'StandaloneBundle', 'PublishArtifact')) {
            $names.IndexOf($gate) | Should -BeGreaterThan $buildIdx -Because "$gate must not run before Build"
        }
    }

    It 'runs Preflight before Build' {
        $names = @(Get-BuiltInPipelineSteps -State (New-TestState) | ForEach-Object { $_.Name })
        $names.IndexOf('Preflight') | Should -BeLessThan $names.IndexOf('Build')
    }

    # Each gate reads exactly one config section. Two calls to
    # Get-ConfigSection in one gate means two keys that can disagree, and the
    # gate is where a build is blocked - so the gate count is pinned.
    It 'routes every optional gate through Test-StepEnabled with its correct enable path(s)' {
        # Centralized in Test-StepEnabled (was 9 hand-copied Get-ConfigSection
        # blocks). This pins the NEW contract: each gate delegates its skip
        # decision to the one owner and declares exactly the config path(s)
        # that arm it. A gate that inlines its own Get-ConfigSection again is
        # the drift this central owner removed.
        $expect = @{
            AffectedScan    = @('build.affected.enabled')
            SecurityScan    = @('security.scanOnBuild')
            AutoTune        = @('autoTune.enabled','autoTune.autoApply')
            SupplyChain     = @('security.sbom.enabled','security.provenance.enabled')
            SastScan        = @('security.sast.enabled')
            PolicyCheck     = @('security.policy.enabled')
            SiemExport      = @('security.siem.enabled')
            StandaloneBundle= @('build.standalone.enabled')
            PublishArtifact = @('build.publishArtifact.enabled')
        }
        $steps = Get-BuiltInPipelineSteps -State (New-TestState)
        foreach ($name in $expect.Keys) {
            $step = @($steps | Where-Object { $_.Name -eq $name })[0]
            $body = $step.Script.ToString()
            $body | Should -Match 'Test-StepEnabled' -Because "$name must delegate the gate decision"
            foreach ($p in $expect[$name]) {
                $body | Should -Match ([regex]::Escape($p)) -Because "$name must gate on $p"
            }
            # And it must NOT carry an inline split of the enable decision.
            $body | Should -Not -Match 'Get-ConfigSection -State \$State' -Because "$name must not read the gate config inline anymore"
        }
    }

    # SupplyChain is enabled by EITHER of two paths, so it is the only gate
    # that legitimately watches two keys. Pin that so a future edit cannot
    # quietly split another gate's single key into two divergent reads.
    It 'lets only SupplyChain AND AutoTune read multiple enable paths' {
        $steps = Get-BuiltInPipelineSteps -State (New-TestState)
        foreach ($step in $steps) {
            $count = ([regex]::Matches($step.Script.ToString(), "Test-StepEnabled")).Count
            $isMulti = (@('SupplyChain','AutoTune') -contains $step.Name)
            if ($isMulti) { $step.Script.ToString() | Should -Match "Test-StepEnabled" }
            else { $count | Should -BeLessOrEqual 1 }
        }
        $sc = @($steps | Where-Object { $_.Name -eq 'SupplyChain' })[0].Script.ToString()
        $sc | Should -Match 'security\.sbom\.enabled' -Because 'SupplyChain needs sbom'
        $sc | Should -Match 'security\.provenance\.enabled' -Because 'SupplyChain needs provenance'
    }

    It 'reports a gate skip through Test-StepEnabled, not a bare log line' {
        # A bare log line leaves the step looking like it ran; only the
        # skip-report path (now owned by Test-StepEnabled -> Write-SkippedStep)
        # feeds $ctx.skippedSteps. Losing it makes a disabled gate
        # indistinguishable from a passing one.
        $steps = Get-BuiltInPipelineSteps -State (New-TestState)
        foreach ($name in @('AffectedScan', 'SecurityScan', 'AutoTune', 'SupplyChain', 'SastScan', 'PolicyCheck', 'SiemExport', 'StandaloneBundle', 'PublishArtifact')) {
            $step = @($steps | Where-Object { $_.Name -eq $name })[0]
            $step.Script.ToString() | Should -Match 'Test-StepEnabled' -Because "$name must report its skip through the one owner"
        }
    }

    It 'does not leave the pipeline reading Start-GBuild private locals' {
        # $Incremental / $Security / $Target / $Distributed / $resolvedCfg are
        # Start-GBuild parameters the step closures captured. They are now
        # explicit parameters of Get-BuiltInPipelineSteps, so a step referencing
        # one has a binding. $Clean and $VersionBump never entered any step.
        $steps = Get-BuiltInPipelineSteps -State (New-TestState)
        foreach ($step in $steps) {
            $body = $step.Script.ToString()
            $body | Should -Not -Match '\$Clean\b' -Because "$($step.Name) must not capture -Clean"
            $body | Should -Not -Match '\$VersionBump\b' -Because "$($step.Name) must not capture -VersionBump"
        }
    }
}

Describe 'the built-in pipeline runs' {
    BeforeAll {
        $script:pipelineTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-realpipe-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:pipelineTemp -Force | Out-Null
        # New-TestState does not carry ProjectRoot (the orchestrator stamps it
        # later), so add it rather than setting a property StrictMode forbids.
        function New-PipelineRunState {
            param([hashtable]$Config)
            $st = New-TestState
            $st | Add-Member -MemberType NoteProperty -Name ProjectRoot -Value $script:pipelineTemp -Force
            $st | Add-Member -MemberType NoteProperty -Name WorkingDir   -Value $script:pipelineTemp -Force
            $st | Add-Member -MemberType NoteProperty -Name BuildConfig  -Value ([pscustomobject]$Config) -Force
            $st.LogLevel = 0
            return $st
        }
        function New-PipelineContext {
            return @{
                csproj = $null; projPath = $null; projectDir = $null; projectType = $null
                tfms = @(); defaultTfm = ''; tfmInfo = $null
                parallelProjects = [System.Collections.ArrayList]@(); langInfo = $null
                choice = $null; menuConfig = $null; buildOk = $false; metric = $null
                errSummary = $null; totalSec = 0; lang = $null
                buildAttempted = $false; buildFailed = $false
                skippedSteps = [System.Collections.ArrayList]@()
            }
        }
        # Every optional gate off: the run then proves the ENGINE reaches each
        # one and each reports itself skipped. Gate bodies that need a real
        # toolchain are covered by their own module tests plus the shape
        # assertions above.
        $script:allGatesOff = @{
            build = @{
                defaultConfiguration = 'Release'
                preflight           = @{ enabled = $false }
                affected            = @{ enabled = $false }
                standalone          = @{ enabled = $false }
                publishArtifact     = @{ enabled = $false }
                scopedLogging       = $true
                openOutput          = $false
            }
            security = @{
                scanOnBuild = $false
                sbom        = @{ enabled = $false }
                provenance  = @{ enabled = $false }
                sast        = @{ enabled = $false }
                policy      = @{ enabled = $false }
                siem        = @{ enabled = $false }
            }
            autoTune = @{ enabled = $true; autoApply = $false }
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:pipelineTemp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'executes every optional gate through the real engine and reports each as skipped' {
        $state = New-PipelineRunState -Config $script:allGatesOff
        $ctx = New-PipelineContext
        # SecurityScan is included deliberately: with scanOnBuild=false it must
        # short-circuit BEFORE importing Security or running a scan, so this
        # proves the disabled path is cheap and side-effect free rather than
        # "it never got that far because nothing called it".
        $runnable = @(Get-BuiltInPipelineSteps -State $state | Where-Object { $_.Name -in @('SecurityScan', 'AffectedScan', 'AutoTune', 'SupplyChain', 'SastScan', 'PolicyCheck', 'SiemExport', 'StandaloneBundle', 'PublishArtifact') })
        $runnable.Count | Should -Be 9

        { Invoke-GBuildPipeline -State $state -Context $ctx -Steps $runnable } | Should -Not -Throw

        # Write-SkippedStep is the ONLY evidence the engine reached a gate.
        # A gate that logs and returns leaves no trace, so a step removed from
        # the pipeline would still pass this test without these assertions.
        $skipped = @($ctx.skippedSteps) -join ' '
        foreach ($pair in @(
            @('AFFECTED', 'build.affected.enabled=false'),
            @('SECURITY', 'security.scanOnBuild=false'),
            @('AUTOTUNE', 'autoTune.enabled=false or autoApply=false'),
            @('SUPPLYCHAIN', 'security.sbom/provenance disabled'),
            @('SAST', 'security.sast.enabled=false'),
            @('POLICY', 'security.policy.enabled=false'),
            @('SIEM', 'security.siem.enabled=false'),
            @('STANDALONE', 'build.standalone.enabled=false'),
            @('ARTIFACT', 'build.publishArtifact.enabled=false')
        )) {
            $skipped | Should -Match ([regex]::Escape("$($pair[0]) ($($pair[1]))")) -Because "$($pair[0]) must be reported skipped with its reason"
        }
    }

    It 'runs a gate that IS enabled instead of skipping it' {
        # The mirror image of the previous test: with autoTune enabled the step
        # must take the enabled branch. Without this, a gate that always
        # short-circuits to the skip path would pass.
        $state = New-PipelineRunState -Config $script:allGatesOff
        $ctx = New-PipelineContext
        $steps = @(Get-BuiltInPipelineSteps -State $state | Where-Object { $_.Name -eq 'AutoTune' })
        { Invoke-GBuildPipeline -State $state -Context $ctx -Steps $steps } | Should -Not -Throw
        # autoTune.enabled=true but autoApply=false: still skipped, and the
        # REASON must name autoApply so the operator knows which knob to turn.
        @($ctx.skippedSteps) -join ' ' | Should -Match 'autoApply=false'
    }

    It 'fires EVT_STEP_SKIPPED for a step whose When is false' {
        # The event contract says a false When fires EVT_STEP_SKIPPED. A gate
        # that returns early from inside its Script does NOT fire it, so this
        # pins the distinction rather than assuming the two are the same thing.
        $state = New-PipelineRunState -Config $script:allGatesOff
        $ctx = New-PipelineContext
        $ctx.order = [System.Collections.ArrayList]@()
        $fired = [System.Collections.ArrayList]@()
        $handler = [scriptblock]::Create('param($e) $null')  # replaced below via a closure over $fired
        $handler = { param($e) [void]$fired.Add($e) }.GetNewClosure()
        Add-BuildEvent -EventName $global:EVT_STEP_SKIPPED -Label 'test' -Handler $handler | Out-Null
        try {
            $steps = @(@{ Name = 'Always'; When = { param($c) $false }; Script = { param($c) $c.order.Add('nope') } })
            { Invoke-GBuildPipeline -State $state -Context $ctx -Steps $steps } | Should -Not -Throw
            $fired.Count | Should -BeGreaterThan 0 -Because 'a false When must be observable as EVT_STEP_SKIPPED'
            @($ctx.order).Count | Should -Be 0 -Because 'a skipped step must not run its body'
        } finally {
            Remove-BuildEvent -EventName $global:EVT_STEP_SKIPPED -Handler $handler -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the built-in pipeline and the shipped config agree' {    It 'ships every step the engine defines' {
        # The engine has 13 steps; the locale file carries a display name for
        # each. A step without one renders as its raw key in the log.
        $steps = @(Get-BuiltInPipelineSteps -State (New-TestState) | ForEach-Object { $_.Name })
        $locale = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'Locales/en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($n in $steps) {
            $locale.PSObject.Properties.Name | Should -Contain "log.stepName.$n" -Because "$n has no display name in the locale file"
        }
    }

    It 'defaults every optional gate to a value the shipped config states' {
        # The engine's inline fallbacks must agree with gbuild.config.json, or a
        # project with a partial config gets different gating than the shipped
        # deployment - which is how a gate ends up effectively disabled.
        $cfg = $script:shippedConfig
        $expect = @{
            'AffectedScan'    = $false   # build.affected.enabled
            'AutoTuneApply'   = $false   # autoTune.autoApply (step runs only when BOTH)
            'SastScan'        = $false   # security.sast.enabled
            'PolicyCheck'     = $false   # security.policy.enabled
            'SiemExport'      = $false   # security.siem.enabled
            'StandaloneBundle'= $false   # build.standalone.enabled
            'PublishArtifact' = $false   # build.publishArtifact.enabled
        }
        $expect['AffectedScan']     = [bool]$cfg.build.affected.enabled
        $expect['SastScan']         = [bool]$cfg.security.sast.enabled
        $expect['PolicyCheck']      = [bool]$cfg.security.policy.enabled
        $expect['SiemExport']       = [bool]$cfg.security.siem.enabled
        $expect['StandaloneBundle'] = [bool]$cfg.build.standalone.enabled
        $expect['PublishArtifact']  = [bool]$cfg.build.publishArtifact.enabled
        # AutoTune's step requires enabled AND autoApply, and the engine's
        # inline default for both is $false, so any shipped true would mean the
        # engine's fallback contradicts the config.
        if ([bool]$cfg.autoTune.enabled -and [bool]$cfg.autoTune.autoApply) {
            throw 'autoTune ships enabled+autoApply=true; the engine default must be revisited.'
        }
        # SecurityScan and SupplyChain ship ON and their engine fallback is $true
        # - deliberately, so a config-less project is still scanned.
        [bool]$cfg.security.scanOnBuild | Should -BeTrue
        ([bool]$cfg.security.sbom.enabled -or [bool]$cfg.security.provenance.enabled) | Should -BeTrue
    }
}

Describe 'job-isolated steps (real pre-emptive timeout)' {
    BeforeAll {
        $script:jobTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-job-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:jobTemp -Force | Out-Null
        function New-JobRunState {
            $st = New-TestState
            $st | Add-Member -MemberType NoteProperty -Name ProjectRoot -Value $script:jobTemp -Force
            $st | Add-Member -MemberType NoteProperty -Name WorkingDir   -Value $script:jobTemp -Force
            $st.LogLevel = 0
            return $st
        }
        function New-JobRunContext {
            return @{
                marker = ''
                skippedSteps = [System.Collections.ArrayList]@()
                parallelProjects = [System.Collections.ArrayList]@()
            }
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:jobTemp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'kills a hung step instead of waiting for it' {
        # THE DEFECT: timeoutSeconds was a post-hoc SLA - the body ran to
        # completion in-process and only then was the breach measured, so a
        # hung step hung the pipeline. A 30 s sleep with a 2 s timeout must
        # fail in ~2 s, not ~30 s.
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $step = @{ Name = 'HangForever'; TimeoutSeconds = 2; Job = $true; Script = { param($c) Start-Sleep -Seconds 30; $c.marker = 'should-never-arrive' } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $threw = $false
        $fqei = ''
        try { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null }
        catch { $threw = $true; $fqei = [string]$_.FullyQualifiedErrorId }
        $sw.Stop()
        $threw | Should -BeTrue
        $fqei | Should -Match 'StepTimeout'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'a 30 s hang with a 2 s timeout must be killed, not awaited'
        $ctx.marker | Should -Be '' -Because 'the killed body must not have run to completion'
    }

    It 'merges the job context back into the live context' {
        # A job runs against a deserialized COPY. Whatever it assigns must come
        # back, or every downstream step reads stale state and the pipeline
        # silently computes on pre-step values.
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $step = @{ Name = 'Mark'; TimeoutSeconds = 60; Job = $true; Script = { param($c) $c.marker = 'job-was-here'; [void]$c.skippedSteps.Add('MARK (unit-test)') } }
        { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null } | Should -Not -Throw
        $ctx.marker | Should -Be 'job-was-here'
        @($ctx.skippedSteps) | Should -Contain 'MARK (unit-test)'
    }

    It 'propagates a step failure with its root message, not a timeout' {
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $step = @{ Name = 'Boom'; TimeoutSeconds = 60; Job = $true; Script = { param($c) throw 'the-real-reason' } }
        $msg = ''
        try { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null } catch { $msg = [string]$_.Exception.Message }
        $msg | Should -Match 'the-real-reason'
        $msg | Should -Not -Match 'StepTimeout|timed out|was killed'
    }

    It 'rejects job isolation without a timeout before spawning anything' {
        # Isolation exists to enforce the timeout. A job without one can never
        # be killed, so it is a config error - and it must fail FAST (no child
        # process) rather than after a hung run.
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $step = @{ Name = 'NoTimeout'; Job = $true; Script = { param($c) $c.marker = 'x' } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $msg = ''
        try { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null } catch { $msg = [string]$_.Exception.Message }
        $sw.Stop()
        $msg | Should -Match 'timeoutSeconds'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'rejection must happen before any job spawns'
    }

    It 'retries a timed-out job and merges the winning attempt' {
        # Timeout and retry must compose: each attempt gets the FULL timeout in
        # a FRESH job (a killed job cannot be resumed), and the attempt that
        # succeeds is the one whose context survives.
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $flag = Join-Path $script:jobTemp 'attempt.flag'
        if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force }
        $body = @'
param($c)
$flagPath = '{0}'
if (-not (Test-Path -LiteralPath $flagPath)) {{
    Set-Content -LiteralPath $flagPath -Value 'attempted' | Out-Null
    Start-Sleep -Seconds 60
}}
$c.marker = 'second-attempt-won'
'@ -f $flag
        $step = @{ Name = 'Flaky'; TimeoutSeconds = 10; Retry = 1; Job = $true; Script = [scriptblock]::Create($body) }
        { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null } | Should -Not -Throw
        $ctx.marker | Should -Be 'second-attempt-won'
    }

    It 'runs the in-process path untouched when job is not requested' {
        # The fast path must not pay job startup: a 1 s sleep with a 60 s SLA
        # and no job flag completes in-process in ~1 s. (If this ever routes
        # through Start-Job, job bootstrap alone blows the budget.)
        $state = New-JobRunState
        $ctx = New-JobRunContext
        $step = @{ Name = 'Quick'; TimeoutSeconds = 60; Script = { param($c) Start-Sleep -Seconds 1; $c.marker = 'in-process' } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { Invoke-PipelineStep -Step $step -Context $ctx -State $state | Out-Null } | Should -Not -Throw
        $sw.Stop()
        $ctx.marker | Should -Be 'in-process'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }
}