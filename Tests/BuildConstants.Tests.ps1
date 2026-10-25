#Requires -Version 5.1
Set-StrictMode -Version 1.0

if (-not (Get-Module BuildConstants)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/BuildConstants.psm1') -Force
}

Describe 'Get-BuildSetting config-first lookup' {
    BeforeAll {
        $buildRoot = Split-Path -Parent $PSScriptRoot
        $configPath = Join-Path $buildRoot 'gbuild.config.json'
        $script:cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:state = [pscustomobject]@{ BuildConfig = $script:cfg }
        $script:constantsModule = Get-Module BuildConstants
        $script:mapKeys = @(& $script:constantsModule { $script:ConfigKeyMap.Keys })
        # Get-BuildConfigPath was deleted: it wrapped this map and nothing else,
        # and being exported-but-uncalled it read as reachable surface that did
        # not exist. The parity tests still need the mapping, so they read the
        # single source directly instead of going through a wrapper nobody calls.
        function script:Get-TestConfigPath([string]$Key) {
            & (Get-Module BuildConstants) { param($k) if ($script:ConfigKeyMap.ContainsKey($k)) { $script:ConfigKeyMap[$k] } else { '' } } $Key
        }
        # Reviewed exemptions: shipped gbuild.config.json INTENTIONALLY differs
        # from the standalone-safe BuildConstants default. Categories:
        #   operational = opinionated shipped deployment vs opt-in default;
        #   env         = ${env:VAR} placeholder resolved at runtime.
        # Every entry MUST carry a reason (enforced below) so exemptions stay
        # audited instead of silently growing. Do NOT add entries to hide drift:
        # typos/wrong values must be fixed in data, not exempted here.
        $script:parityExempt = @{
            'AutoTuneEnabled'    = 'operational: shipped config enables self-tuning; default false keeps standalone imports opt-in'
            'AutoTuneAutoApply'  = 'operational: shipped config auto-applies tunings; default false never mutates without explicit consent'
            'DistributedEnabled' = 'operational: shipped config enables multi-host dispatch; default false keeps single-machine standalone safe'
            'DistributedRepoRoot' = 'env: ${env:GBUILD_DISTRIBUTED_REPO_ROOT} resolved at runtime per machine'
            'MetricsBindAddress' = 'operational: shipped binds 0.0.0.0 for container scraping; default localhost is the secure standalone. Operators must restrict via firewall/auth'
            'OpenOutput' = 'operational: shipped config reveals publish-output for the interactive dev loop; default false keeps standalone imports and CI quiet'
        }
    }

    Context 'parity: every mapped config path resolves' {
        It 'every mapped config path resolves' {
            foreach ($k in $script:mapKeys) {
                Get-TestConfigPath -Key $k | Should -Not -BeNullOrEmpty
            }
        }
        It 'every mapped config path resolves in gbuild.config.json' {
            $missing = @()
            foreach ($k in $script:mapKeys) {
                $path = Get-TestConfigPath -Key $k
                $current = $script:cfg
                foreach ($seg in $path -split '\.') {
                    if ($null -eq $current -or $current.PSObject.Properties.Name -notcontains $seg) {
                        $missing += $path
                        break
                    }
                    $current = $current.$seg
                }
            }
            $missing.Count | Should -Be 0 -Because ($missing -join ', ')
        }
        It 'every mapped key has a registered BuildDefault' {
            $missing = @($script:mapKeys | Where-Object {
                -not (& $script:constantsModule {
                    param($Key)
                    $script:BuildDefaults.ContainsKey($Key)
                } $_)
            })
            $missing.Count | Should -Be 0 -Because ($missing -join ', ')
        }
        It 'config value and BuildDefault agree (single source of truth)' {
            foreach ($k in $script:mapKeys) {
                if ($script:parityExempt.ContainsKey($k)) { continue }
                $def = Get-BuildDefault -Key $k
                $cfgVal = Get-BuildSetting -Key $k -State $script:state
                # Numeric-aware comparison: ConvertFrom-Json parses 3.0 as
                # [decimal] while the .psm1 literal is [double]; both stringify
                # differently ('3.0' vs '3') for the same numeric value.
                $defNum = $def -is [double] -or $def -is [decimal] -or $def -is [int] -or $def -is [long]
                $cfgNum = $cfgVal -is [double] -or $cfgVal -is [decimal] -or $cfgVal -is [int] -or $cfgVal -is [long]
                if ($defNum -and $cfgNum) {
                    [double]$cfgVal | Should -Be ([double]$def) -Because "key '$k' config must match its BuildConstants default"
                } else {
                    $defStr = if ($def -is [array]) { ($def -join ',') } else { [string]$def }
                    $cfgStr = if ($cfgVal -is [array]) { ($cfgVal -join ',') } else { [string]$cfgVal }
                    $defStr | Should -Be $cfgStr -Because "key '$k' config must match its BuildConstants default"
                }
            }
        }
        It 'every parity exemption carries a reason and still resolves' {
            foreach ($k in $script:parityExempt.Keys) {
                [string]$script:parityExempt[$k] | Should -Not -BeNullOrEmpty
                Get-TestConfigPath -Key $k | Should -Not -BeNullOrEmpty
                (& $script:constantsModule {
                    param($Key)
                    $script:BuildDefaults.ContainsKey($Key)
                } $k) | Should -BeTrue
            }
        }
    }

    Context 'no dead lookups (regression: undefined key silently returns Fallback)' {
        # A Get-BuildSetting/Get-BuildDefault call for a key that does not exist
        # is indistinguishable from a working one: it just returns -Fallback
        # forever. Five of these shipped (LogMaxFiles, LogMaxAgeDays,
        # RetryBackoffMaxMs, DoraWindowHours, AutoTuneEwmaAlpha) and were
        # invisible because nothing asserted the key exists.
        BeforeDiscovery {
            $script:defaultKeys = @(& (Get-Module BuildConstants) { $script:BuildDefaults.Keys })
        }
        It 'every -Key literal passed to Get-BuildSetting/Get-BuildDefault/Get-BuildConstant is a defined BuildConstants key' {
            $root = Split-Path -Parent $PSScriptRoot
            $defs = @(& (Get-Module BuildConstants) { $script:BuildDefaults.Keys })
            $unmapped = @('LogMaxFiles')  # legitimate: LogConfig snapshot key, not a default
            $orphans = [System.Collections.Generic.List[string]]::new()
            . (Join-Path $root 'Tests/GateDetectors.ps1')
            foreach ($file in @(Get-ChildItem -Path (Join-Path $root 'Modules') -Recurse -File -Filter '*.psm1')) {
                # Comments are BLANKED, not deleted: otherwise the explanatory
                # comment naming the previously-broken key would itself match
                # and the gate would flag its own fix.
                $text = Get-GateCodeWithoutComments -Path $file.FullName
                # Named-parameter form: -Key '<literal>'  /  -Key $var (skip dynamic)
                foreach ($m in [regex]::Matches($text, "(?:Get-BuildSetting|Get-BuildDefault|Get-BuildConstant)\s+(?:-[A-Za-z]+\s+)*-Key\s+'([^']+)'")) {
                    $key = $m.Groups[1].Value
                    if ($defs -contains $key -or $unmapped -contains $key) { continue }
                    $orphans.Add(('{0}: {1}' -f $file.Name, $key))
                }
            }
            $orphans | Should -BeNullOrEmpty -Because ('undefined constant keys always return -Fallback: ' + ($orphans -join '; '))
        }
    }

    Context 'lookup precedence' {
        It 'config override wins when -State is provided' {
            $st = [pscustomobject]@{
                BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ defaultPort = 9999 } }
            }
            Get-BuildSetting -Key 'DefaultPort' -State $st -Fallback 42 | Should -Be 9999
        }
        It 'resolves OTLP paths from telemetry.otel' {
            $st = [pscustomobject]@{
                BuildConfig = [pscustomobject]@{
                    telemetry = [pscustomobject]@{
                        otel = [pscustomobject]@{
                            metricsPath = '/custom/metrics'
                            tracesPath = '/custom/traces'
                            jsonDepth = 7
                        }
                    }
                }
            }
            Get-BuildSetting -Key 'OtlpMetricsPath' -State $st | Should -Be '/custom/metrics'
            Get-BuildSetting -Key 'OtlpTracesPath' -State $st | Should -Be '/custom/traces'
            Get-BuildSetting -Key 'OtlpJsonDepth' -State $st | Should -Be 7
        }
        It 'falls back to BuildDefault when config value is absent' {
            Get-BuildSetting -Key 'DefaultPort' -Fallback 42 | Should -Be 5000
        }
        It 'centralizes removable-media mount roots' {
            @(Get-BuildDefault -Key 'OsRemovableMountRoots' -Fallback @()) | Should -Be @('/mnt', '/media', '/run/media')
            Get-BuildDefault -Key 'OsMacOSVolumeRoot' -Fallback '' | Should -Be '/Volumes'
        }
        It 'falls back to -Fallback when neither config nor default exists' {
            Get-BuildSetting -Key 'NoSuchKey' -Fallback 123 | Should -Be 123
        }
        It 'unknown mapped key is absent from the config path map' {
            Get-TestConfigPath -Key 'NoSuchKey' | Should -Be ''
        }
        It 'resolves the legacy parallel alias only when canonical is absent' {
            $legacyState = [pscustomobject]@{ BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ enableParallel = $true } } }
            $canonicalState = [pscustomobject]@{ BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ enableParallel = $true; enableParallelBuild = $false } } }
            Get-BuildSetting -Key 'EnableParallelBuild' -State $legacyState | Should -BeTrue
            Get-BuildSetting -Key 'EnableParallelBuild' -State $canonicalState | Should -BeFalse
        }
        It 'uses the configured parallel job ceiling' {
            $state = [pscustomobject]@{ BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ maxParallelJobs = 3; maxJobsMax = 7 } } }
            Get-BuildSetting -Key 'ParallelMaxJobs' -State $state | Should -Be 3
            Get-BuildSetting -Key 'ParallelMaxJobsMax' -State $state | Should -Be 7
        }
        It 'resolves project markers from BuildConstants state' {
            # Get-ProjectMarkers returns the UNION of configured + canonical +
            # live language map + live plugin manifests. A configured list may
            # ADD coverage but never replace the canonical set, because a
            # narrower list silently makes a supported language unstartable
            # (7 of 14 shipped plugins were affected by exactly that).
            $state = [pscustomobject]@{ BuildConfig = [pscustomobject]@{ build = [pscustomobject]@{ projectMarkers = @('*.custom') } } }
            $markers = @(Get-ProjectMarkers -State $state)
            $markers | Should -Contain '*.custom'
            $markers | Should -Contain '*.csproj'
            $markers | Should -Contain 'Gemfile'
            $markers | Should -Contain 'composer.json'
            $markers | Should -Contain 'Package.swift'
            $markers | Should -Contain 'mix.exs'
        }
        It 'project markers cover every language in the shipped language map' {
            # '*.psm1'/'*.ps1' are excluded by design: they identify the
            # PowerShell language but not a project root.
            $markers = @(Get-ProjectMarkers -State $null)
            if (Get-Command Get-LanguageMap -ErrorAction SilentlyContinue) {
                foreach ($entry in @(Get-LanguageMap)) {
                    $bf = [string]$entry.BuildFile
                    $ext = [System.IO.Path]::GetExtension($bf)
                    if ($ext -eq '.ps1' -or $ext -eq '.psm1') { continue }
                    $markers | Should -Contain $bf -Because "language $($entry.Language) is detected via $bf"
                }
            }
            $markers | Should -Not -Contain '*.ps1'
            $markers | Should -Not -Contain '*.psm1'
        }
    }

    Context 'canonical timestamp kinds' {
        It 'formats each timestamp kind from the single-source table' {
            $at = Get-Date -Year 2026 -Month 1 -Day 2 -Hour 3 -Minute 4 -Second 5 -Millisecond 0
            Get-BuildTimestamp -Kind FileStamp -At $at | Should -Be '20260102_030405'
            Get-BuildTimestamp -Kind RotationStamp -At $at | Should -Be '20260102-030405'
            Get-BuildTimestamp -Kind ImageTag -At $at | Should -Be '202601020304'
            Get-BuildTimestamp -Kind Display -At $at | Should -Be '2026-01-02 03:04:05'
            Get-BuildTimestamp -Kind Date -At $at | Should -Be '2026-01-02'
            Get-BuildTimestamp -Kind RoundTrip -At $at | Should -Be $at.ToString('o')
        }

        It 'defaults to the artifact filename stamp' {
            $at = Get-Date -Year 2026 -Month 1 -Day 2 -Hour 3 -Minute 4 -Second 5 -Millisecond 0
            Get-BuildTimestamp -At $at | Should -Be '20260102_030405'
        }
    }
}
