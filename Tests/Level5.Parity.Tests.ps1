#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Level 5 parity: early-boot mirrors + menu maps must match single source.
# Covers: ProjectMarkers (gbuild.ps1 vs BuildConstants vs config),
# ModuleMap/DefaultActions (Orchestrator defaults vs gbuild.config.json).

if (-not (Get-Module BuildConstants)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/BuildConstants.psm1') -Force
}

Describe 'Level 5 parity - single source of truth' {
    BeforeAll {
        $buildRoot = Split-Path -Parent $PSScriptRoot
        $configPath = Join-Path $buildRoot 'gbuild.config.json'
        $script:cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:gbuildPs1 = Get-Content (Join-Path $buildRoot 'gbuild.ps1') -Raw -Encoding UTF8
        $null = Import-Module (Join-Path $buildRoot 'Modules/ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    Context 'ProjectMarkers parity' {
        It 'BuildConstants.ProjectMarkers matches config build.projectMarkers' {
            $central = @(Get-BuildDefault -Key 'ProjectMarkers' -Fallback @())
            $cfgMarkers = @($script:cfg.build.projectMarkers)
            ($central -join '|') | Should -Be ($cfgMarkers -join '|')
        }
        It 'gbuild.ps1 does not duplicate the project-marker list' {
            $script:gbuildPs1 | Should -Not -Match 'GBuildEarlyProjectMarkers' -Because 'marker ownership stays in BuildConstants/config'
        }
        It 'exposes the same state-aware project marker owner through ConfigProvider' {
            # Contract (restored 2026-09): Get-ProjectMarkers returns the UNION
            # of the configured list, the static canonical list, the live
            # LanguageDetector map and the live plugin manifests. It used to let
            # build.projectMarkers REPLACE the canonical list, which is how a
            # 13-entry list missing Gemfile / composer.json / mix.exs /
            # Package.swift / Makefile / build.sbt / setup.py / setup.cfg became
            # the startup gate - 7 of the 14 shipped plugins had no project root
            # to resolve. A configured list may now only ADD coverage.
            $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ projectMarkers = @('*.owned') } } }
            foreach ($owner in @('Get-ConfigProjectMarkers','Get-ProjectMarkers')) {
                $markers = @(& $owner -State $state)
                $markers | Should -Contain '*.owned' -Because "$owner must honour the configured list"
                $markers | Should -Contain 'Gemfile' -Because "$owner must keep canonical language coverage"
                $markers | Should -Contain 'composer.json' -Because "$owner must keep canonical language coverage"
                $markers | Should -Contain 'Package.swift' -Because "$owner must keep canonical language coverage"
                $markers.Count | Should -BeGreaterThan 20 -Because "$owner must expose the full language union"
            }
        }
        It 'covers every shipped plugin manifest as a project marker' {
            # Anti-regression: if a plugin is added for a language whose manifest
            # is not a marker, that language becomes unstartable again.
            # Exception, by design: '*.ps1'/'*.psm1' are PowerShell *file*
            # patterns, not project manifests. A PowerShell project is any
            # directory of scripts, so admitting them would make any scratch
            # directory a project root. They stay valid Plugin ManifestFiles.
            $markers = @(Get-ProjectMarkers -State $null)
            $pluginDir = Join-Path (Split-Path -Parent $PSCommandPath) '../Modules/Plugins'
            $pluginDir = [System.IO.Path]::GetFullPath($pluginDir)
            foreach ($p in @(Get-ChildItem -LiteralPath $pluginDir -Filter '*.psm1' -File)) {
                $src = Get-Content -LiteralPath $p.FullName -Raw
                $m = [regex]::Match($src, 'ManifestFiles\s*=\s*@\(([^)]*)\)')
                if (-not $m.Success) { continue }
                foreach ($f in @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })) {
                    $ext = [System.IO.Path]::GetExtension($f)
                    if ($ext -eq '.ps1' -or $ext -eq '.psm1') { continue }
                    $markers | Should -Contain $f -Because "plugin $($p.BaseName) declares $f, which must be a project marker"
                }
            }
        }
        It 'does not treat loose script patterns as project-root markers' {
            $markers = @(Get-ProjectMarkers -State $null)
            $markers | Should -Not -Contain '*.ps1'
            $markers | Should -Not -Contain '*.psm1'
        }
    }

    Context 'ModuleMap parity' {
        It 'Orchestrator defaultMap matches config build.menu.moduleMap keys' {
            $orchFiles = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'Modules') -Filter 'Orchestrator*.ps*' -File -Recurse)
            $orchText = ($orchFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
            $cfgMap = $script:cfg.build.menu.moduleMap
            foreach ($k in $cfgMap.PSObject.Properties.Name) {
                $escaped = [regex]::Escape("'$k'")
                $orchText | Should -Match $escaped -Because "Orchestrator defaultMap must contain choice '$k'"
            }
        }
        It 'Get-ModuleMapFromConfig is exported (no orphan export gap)' {
            $orchFiles = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'Modules') -Filter 'Orchestrator*.ps*' -File -Recurse)
            $orchText = ($orchFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
            $orchText | Should -Match 'Get-ModuleMapFromConfig' -Because 'function must exist'
            $orchText | Should -Match "Export-ModuleMember.*Get-ModuleMapFromConfig" -Because 'function must be exported'
        }
    }

    Context 'New Level 5 keys parity' {
        It 'ProgressKillWaitMs config matches default' {
            $def = Get-BuildDefault -Key 'ProgressKillWaitMs' -Fallback 5000
            [int]$script:cfg.build.progress.killWaitMs | Should -Be ([int]$def)
        }
        It 'Anomaly new thresholds match defaults' {
            [double]$script:cfg.anomaly.criticalZScore | Should -Be ([double](Get-BuildDefault -Key 'AnomalyCriticalZScore' -Fallback 5.0))
            [double]$script:cfg.anomaly.highZScore | Should -Be ([double](Get-BuildDefault -Key 'AnomalyHighZScore' -Fallback 4.0))
            [double]$script:cfg.anomaly.ewmaMultiplier | Should -Be ([double](Get-BuildDefault -Key 'AnomalyEwmaMultiplier' -Fallback 2.0))
            [double]$script:cfg.anomaly.failureRateHighZScore2 | Should -Be ([double](Get-BuildDefault -Key 'AnomalyFailureRateHighZScore2' -Fallback 3.0))
        }
        It 'ClusterBuildTimeoutSec config matches default' {
            [int]$script:cfg.build.cluster.buildTimeoutSec | Should -Be ([int](Get-BuildDefault -Key 'ClusterBuildTimeoutSec' -Fallback 3600))
        }
        It 'AuditLedger memoryCap/ledger config matches defaults' {
            [int]$script:cfg.security.auditLedger.memoryCap | Should -Be ([int](Get-BuildDefault -Key 'AuditLedgerMemoryCap' -Fallback 5000))
            [int]$script:cfg.security.auditLedger.ledger.checkpointInterval | Should -Be ([int](Get-BuildDefault -Key 'AuditLedgerCheckpointInterval' -Fallback 1000))
        }

        It 'AuditLedger exposes no config key that nothing reads' {
            # security.auditLedger.file.compress and .ledger.treeDepth shipped in
            # the config for months while no module read them, so an operator who
            # tuned them got no effect and no warning. Every key under
            # security.auditLedger must now be consumed by AuditLedger.psm1.
            $moduleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
            $auditSource = Get-Content -LiteralPath (Join-Path $moduleRoot 'AuditLedger.psm1') -Raw
            $node = $script:cfg.security.auditLedger
            foreach ($prop in $node.PSObject.Properties) {
                $auditSource | Should -Match ([regex]::Escape([string]$prop.Name)) -Because "security.auditLedger.$($prop.Name) must be read by AuditLedger.psm1"
            }
        }
    }

    Context 'AutoTune posture parity (opt-in standalone, operational shipped)' {
        It 'standalone default is disabled (opt-in), shipped config enables observe' {
            # Documented steady state (see BuildConstants.Tests parityExempt):
            # default false keeps standalone imports side-effect free, shipped
            # config opts in (enabled=true). autoApply stays false on BOTH sides
            # — tunings never mutate without explicit operator approval.
            [bool](Get-BuildDefault -Key 'AutoTuneEnabled' -Fallback $false) | Should -Be $false
            [bool]$script:cfg.autoTune.enabled | Should -Be $true
            [bool](Get-BuildDefault -Key 'AutoTuneAutoApply' -Fallback $false) | Should -Be $false
            [bool]$script:cfg.autoTune.autoApply | Should -Be $false
        }
        It 'tuning thresholds config matches defaults' {
            [int]$script:cfg.autoTune.minSamplesBeforeTune | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneMinSamples' -Fallback 5))
            [int]$script:cfg.autoTune.defaultParallelMax | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneDefaultParallelMax' -Fallback 8))
            [int]$script:cfg.autoTune.parallelCeiling | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneParallelCeiling' -Fallback 16))
            [int]$script:cfg.autoTune.cacheMaxEntriesDefault | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneCacheMaxEntriesDefault' -Fallback 256))
            [int]$script:cfg.autoTune.cacheMaxSizeMbDefault | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneCacheMaxSizeMbDefault' -Fallback 512))
            [int]$script:cfg.autoTune.defaultTimeoutMinutes | Should -Be ([int](Get-BuildDefault -Key 'AutoTuneDefaultTimeoutMinutes' -Fallback 30))
            [double]$script:cfg.autoTune.failRateThresholdLow | Should -Be ([double](Get-BuildDefault -Key 'AutoTuneFailRateThresholdLow' -Fallback 0.1))
            [double]$script:cfg.autoTune.failRateThresholdHigh | Should -Be ([double](Get-BuildDefault -Key 'AutoTuneFailRateThresholdHigh' -Fallback 0.3))
            [bool]$script:cfg.autoTune.verifyEnabled | Should -Be ([bool](Get-BuildDefault -Key 'AutoTuneVerifyEnabled' -Fallback $true))
            [bool]$script:cfg.autoTune.rollbackEnabled | Should -Be ([bool](Get-BuildDefault -Key 'AutoTuneRollbackEnabled' -Fallback $true))
        }
    }

    Context 'CI and container wave contracts' {
        It 'uses the repository root for CI and Docker entrypoints' {
            $workflowText = Get-Content (Join-Path $buildRoot '.github/workflows/build.yml') -Raw -Encoding UTF8
            $dockerText = Get-Content (Join-Path $buildRoot 'Dockerfile') -Raw -Encoding UTF8
            $workflowText | Should -Not -Match '(?i)(?:_Build/|_Build\\\\|_Build\\b)'
            $dockerText | Should -Not -Match '(?i)(?:_Build/|_Build\\\\|_Build\\b)'
            $dockerText | Should -Match '"\./gbuild\.ps1"'
            $dockerText | Should -Match '(?m)^\s*USER\s+'
            $workflowText | Should -Not -Match 'ExcludeRule'
            $ignorePath = Join-Path $buildRoot '.dockerignore'
            Test-Path -LiteralPath $ignorePath -PathType Leaf | Should -BeTrue
            $ignoreText = Get-Content $ignorePath -Raw -Encoding UTF8
            $ignoreText | Should -Match '(?m)^\.git$'
            $ignoreText | Should -Match '(?m)^\*\*/\.gbuildcache$'
            $ignoreText | Should -Match '(?m)^\*\*/\*state\*$'
            $ignoreText | Should -Match '(?m)^\*\*/\*secret\*$'
            $ignoreText | Should -Match '(?m)^\*\*/\.env$'
            $ignoreText | Should -Match '(?m)^\*\*/keys$'
            $ignoreText | Should -Match '(?m)^\*\*/vendor$'
            $ignoreText | Should -Match '(?m)^\*\*/TestResults$'
        }

        It 'keeps strict result, skip, and kill gates in every runner' {
            $coreText = Get-Content (Join-Path $buildRoot 'Tests/Run-CoreTests.ps1') -Raw -Encoding UTF8
            $e2eText = Get-Content (Join-Path $buildRoot 'Tests/Run-E2ETests.ps1') -Raw -Encoding UTF8
            $smokeText = Get-Content (Join-Path $buildRoot 'Tests/Run-PS51Smoke.ps1') -Raw -Encoding UTF8
            $coreText | Should -Match '\[switch\]\$StrictSkips'
            $coreText | Should -Match 'GBUILD_CORE_VERDICT'
            $coreText | Should -Match 'GBUILD_CORE_VERDICT\s+\S+\s+Passed=.*Failed=.*Skipped=.*Total='
            $coreText | Should -Match 'Killed'
            $coreText | Should -Match 'NoVerdict'
            $coreText | Should -Match '\$null -eq \$verdict'
            $coreText | Should -Match 'SkippedCount'
            $coreText | Should -Match "'ClusterOrchestrator'\s*=\s*'ClusterOrchestrator.Tests.ps1'"
            $coreText | Should -Match "'ModuleDependencies'\s*=\s*'ModuleDependencies.Tests.ps1'"
            $e2eText | Should -Match '\[switch\]\$Strict'
            $e2eText | Should -Match '\[switch\]\$RequireNoSkips'
            $e2eText | Should -Match 'SkippedCount'
            $e2eText | Should -Match 'TotalCount'
            $e2eText | Should -Match '\$total\s+-le\s+0'
            $allBlock = [regex]::Match($e2eText, "'All'\s*\{\s*@\((?<body>[\s\S]*?)\)\s*\}")
            $allBlock.Success | Should -BeTrue
            # BuildE2E.Tests.ps1 had a named scope in Run-E2ETests but was missing
            # from the 'All' block, so the only test that exercises the real dotnet
            # pipeline never ran in CI or in a default local run. It MUST be listed.
            $allBlock.Groups['body'].Value | Should -Match 'BuildE2E\.Tests\.ps1'
            $coreText | Should -Not -Match '#Requires\s+-Module'
            $e2eText | Should -Not -Match '#Requires\s+-Module'
            $smokeText | Should -Match '\[switch\]\$Strict'
            $smokeText | Should -Match 'missing test file'
            $smokeText | Should -Match 'SkippedCount'
            $smokeText | Should -Match '\$total\s+-le\s+0'
        }

        It 'every shipped test file is reachable from a runner (no orphan tests)' {
            # Run-IntegrationTests.ps1 was deleted as 100% redundant, and
            # BuildE2E.Tests.ps1 had a named E2E scope but was missing from 'All',
            # so it never ran anywhere. This pins the invariant: every
            # *.Tests.ps1 under Tests/ must be referenced by Run-CoreTests.ps1 or
            # Run-E2ETests.ps1, or deletion/creation silently changes coverage.
            $testRoot = $PSScriptRoot
            $allFiles = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File | Select-Object -ExpandProperty Name)
            $coreText = Get-Content -LiteralPath (Join-Path $testRoot 'Run-CoreTests.ps1') -Raw
            $e2eText = Get-Content -LiteralPath (Join-Path $testRoot 'Run-E2ETests.ps1') -Raw
            $orphans = @($allFiles | Where-Object { $coreText -notmatch [regex]::Escape($_) -and $e2eText -notmatch [regex]::Escape($_) })
            $orphans | Should -BeNullOrEmpty -Because ('these test files run in NO runner: ' + ($orphans -join ', '))
        }

        It 'secret redaction has exactly one owner plus the documented Logging shim' {
            # Invoke-BuildSecretProtect existed as four byte-identical private
            # copies that only agreed by accident. Owner is SharedUtils (exported);
            # Logging keeps a shim only because SharedUtils->Logging is circular at
            # module scope. Any third definition is drift.
            $owners = @()
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'Modules') -Recurse -Filter '*.psm1' -File)) {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                if ($text -match '(?m)^function Invoke-BuildSecretProtect\s*\{') { $owners += $f.Name }
            }
            ($owners | Sort-Object) -join ',' | Should -Be 'Logging.psm1,SharedUtils.psm1'
        }
    }

Describe 'Level 5 parity - the platform tools stay independent' {
    BeforeAll {
        $buildRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'no production code reaches into a sibling tool' {
        # _Tests, _Build and _Sync are INDEPENDENT systems. They borrow each
        # other - a gate invoked as a process, its exit code read as the verdict
        # - and they must never contain or depend on each other. A production
        # file that READS or IMPORTS a sibling tool's tree is a code-level
        # dependency and breaks the boundary (ADR-0007): the two trees then
        # have to be released together, and the fix for a defect stops having
        # one owner.
        #
        # Naming a sibling tool is NOT a dependency. The exclusion lists (the
        # gitignore patterns, the tool-folder names, the syntax-check exclude
        # dirs) mention the sibling folders on purpose - to keep them OUT. Only
        # a line that ACCESSES a path of a sibling counts, so the gate does not
        # punish the very lines that enforce the boundary.
        $accessPattern = '(?i)\b(?:Import-Module|Import-ModuleOnDemand|Import-ModuleIfExists|Import-ModuleIfMissing|Get-Content|Get-ChildItem|Get-Item|Test-Path|Join-Path|Resolve-Path|Copy-Item|Move-Item|Remove-Item)\b'
        $siblingPattern = '(?i)(?:^|[\s''"(=/\\])_(?:Tests|Sync)(?:[\\/''"]|\b)'
        $roots = @('Modules', 'Steps', 'Hooks')
        $offenders = @()
        foreach ($r in $roots) {
            $dir = Join-Path $buildRoot $r
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue)) {
                foreach ($line in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                    # Comments are prose, not dependencies: strip them first.
                    $code = ($line -replace '\s+#(?![{]).*$', '').Trim()
                    if ([string]::IsNullOrWhiteSpace($code)) { continue }
                    if (($code -match $accessPattern) -and ($code -match $siblingPattern)) {
                        $offenders += ('{0}: {1}' -f $f.Name, $code)
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ('production code must not read or import a sibling tool: ' + ($offenders -join ' | '))
    }

    It 'no sibling tool is contained in this repository' {
        # Containment is the other half of the same rule: a tool that lives
        # inside another tool's tree is a vendored copy that drifts.
        foreach ($name in @('_Tests', '_Sync')) {
            Test-Path -LiteralPath (Join-Path $buildRoot $name) |
                Should -BeFalse -Because "a tool inside another breaks the boundary (ADR-0007): $name"
        }
    }
}

    Context 'the coverage shards are balanced on measured coverage costs' {
        It 'the committed coverage cost table carries every scope' {
            # The coverage shards are balanced on Tests/coverage-costs.json, not
            # on the plain timing table: the coverage instrumentation multiplies
            # the scopes by very different factors, so the plain table balances
            # the shards by the wrong weights. A scope missing from the table is
            # balanced as if it were free - which is the bug the table removes.
            $costPath = Join-Path $buildRoot 'Tests/coverage-costs.json'
            Test-Path -LiteralPath $costPath -PathType Leaf | Should -BeTrue -Because 'a fresh CI checkout has no history to learn the coverage costs from'
            $j = Get-Content -LiteralPath $costPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $names = @($j.scopes.PSObject.Properties.Name)
            $names.Count | Should -BeGreaterThan 0
            $b = Get-Content -LiteralPath (Join-Path $buildRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $names.Count | Should -Be ([int]$b.core.scopes) -Because 'a scope that is missing from the table is balanced as if it were free'
            foreach ($n in $names) {
                $value = $j.scopes.PSObject.Properties[$n].Value
                [double]$value | Should -BeGreaterThan 0 -Because "every scope must carry its measured coverage cost: $n"
            }
        }
    }
}
