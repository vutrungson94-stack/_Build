Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/ConfigProvider.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'ConfigProvider - path resolution (Find-ConfigNode)' {
    It 'resolves a nested PSCustomObject path' {
        $root = [PSCustomObject]@{ a = [PSCustomObject]@{ b = 42 } }
        Find-ConfigNode -Root $root -Path 'a.b' | Should -Be 42
    }
    It 'resolves a nested IDictionary (hashtable) path' {
        $ht = @{ a = @{ b = 7 } }
        Find-ConfigNode -Root $ht -Path 'a.b' | Should -Be 7
    }
    It 'returns $null for a missing path segment' {
        $root = [PSCustomObject]@{ a = [PSCustomObject]@{ b = 42 } }
        Find-ConfigNode -Root $root -Path 'a.c' | Should -BeNull
    }
    It 'returns $null when Root is $null' {
        Find-ConfigNode -Root $null -Path 'a.b' | Should -BeNull
    }
}

Describe 'ConfigProvider - Get-ConfigValue' {
    BeforeAll {
        $script:State = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{ maxParallelJobs = 4; enabled = $true; name = 'demo' }
            }
        }
    }

    It 'resolves a nested value from State.BuildConfig' {
        Get-ConfigValue -Path 'build.maxParallelJobs' -State $script:State | Should -Be 4
    }
    It 'returns Default when the path is missing' {
        Get-ConfigValue -Path 'build.nope' -State $script:State -Default 99 | Should -Be 99
    }
    It 'coerces Type int' {
        Get-ConfigValue -Path 'build.maxParallelJobs' -State $script:State -Type 'int' | Should -BeOfType ([int])
    }
    It 'coerces Type bool' {
        Get-ConfigValue -Path 'build.enabled' -State $script:State -Type 'bool' | Should -BeTrue
    }
    It 'coerces Type string' {
        Get-ConfigValue -Path 'build.name' -State $script:State -Type 'string' | Should -Be 'demo'
    }
    It 'returns Default when no config is available' {
        Get-ConfigValue -Path 'x.y' -State $null -Default 'fallback' | Should -Be 'fallback'
    }
}

Describe 'ConfigProvider - Merge-ConfigObject (deep merge)' {
    It 'deep-merges nested objects with override winning on leaves' {
        $base = [PSCustomObject]@{ a = 1; nested = [PSCustomObject]@{ x = 1; y = 2 } }
        $ov   = [PSCustomObject]@{ b = 2; nested = [PSCustomObject]@{ y = 20; z = 30 } }
        $m = Merge-ConfigObject $base $ov
        $m.a | Should -Be 1
        $m.b | Should -Be 2
        $m.nested.x | Should -Be 1
        $m.nested.y | Should -Be 20
        $m.nested.z | Should -Be 30
    }
    It 'returns override when base is $null' {
        $ov = [PSCustomObject]@{ a = 1 }
        Merge-ConfigObject $null $ov | Should -Be $ov
    }
    It 'returns base when override is $null' {
        $base = [PSCustomObject]@{ a = 1 }
        Merge-ConfigObject $base $null | Should -Be $base
    }
    It 'preserves empty arrays during merge' {
        $base = [PSCustomObject]@{ list = @() }
        $result = Merge-ConfigObject $base ([PSCustomObject]@{ other = 1 })
        ($null -ne $result.list) | Should -BeTrue
        @($result.list).Count | Should -Be 0
    }
}

Describe 'ConfigProvider - Merge-ConfigTenantOverride' {
    BeforeAll {
        $script:config = [PSCustomObject]@{
            build   = [PSCustomObject]@{ maxParallelJobs = 4 }
            tenancy = [PSCustomObject]@{
                overrides = [PSCustomObject]@{
                    acme = [PSCustomObject]@{ build = [PSCustomObject]@{ maxParallelJobs = 1 } }
                }
            }
        }
    }

    It 'returns the config unchanged for the default tenant' {
        $s = [PSCustomObject]@{ TenantId = 'default' }
        $r = Merge-ConfigTenantOverride -Config $script:config -State $s
        $r.build.maxParallelJobs | Should -Be 4
    }
    It 'applies the tenant overlay for a matching tenant' {
        $s = [PSCustomObject]@{ TenantId = 'acme' }
        $r = Merge-ConfigTenantOverride -Config $script:config -State $s
        $r.build.maxParallelJobs | Should -Be 1
    }
    It 'returns the config unchanged for a tenant without an override' {
        $s = [PSCustomObject]@{ TenantId = 'other' }
        $r = Merge-ConfigTenantOverride -Config $script:config -State $s
        $r.build.maxParallelJobs | Should -Be 4
    }
    It 'returns the config unchanged when Config or State is $null' {
        Merge-ConfigTenantOverride -Config $null -State $script:config | Should -BeNull
        Merge-ConfigTenantOverride -Config $script:config -State $null | Should -Be $script:config
    }
}

Describe 'ConfigProvider - Test-BuildConfigSchema (the 5.1-capable validator)' {
    # Test-BuildConfigSchema exists because Orchestrator.Test-BuildConfig used to
    # probe for `Get-Command Test-JsonSchema` - a cmdlet that does not exist in
    # PowerShell and was never defined in this repository. On pwsh 7 validation
    # ran through the real Test-Json; on Windows PowerShell 5.1 it fell through
    # to a check of FIVE top-level property names. The same config file got two
    # different verdicts depending on which shell ran it.
    #
    # These cases are the PARITY contract: when Test-Json exists (pwsh 6+), the
    # two validators must return the same verdict, or the platform has restored
    # the exact bug it was built to remove.
    BeforeAll {
        $script:cpBuildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:cpSchemaPath = Join-Path $script:cpBuildRoot 'gbuild.config.schema.json'
        $script:cpSchemaRaw = Get-Content -LiteralPath $script:cpSchemaPath -Raw -Encoding UTF8
        $script:cpSchema    = $script:cpSchemaRaw | ConvertFrom-Json
        $script:cpCfgText   = Get-Content -LiteralPath (Join-Path $script:cpBuildRoot 'gbuild.config.json') -Raw -Encoding UTF8
        $script:cpHasTestJson = [bool](Get-Command Test-Json -ErrorAction SilentlyContinue)
    }

    It 'accepts the shipped gbuild.config.json' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema |
            Should -BeTrue -Because 'the shipped config must validate, or -SelfTest fails on a clean tree'
    }

    It 'rejects an undeclared top-level property (additionalProperties: false)' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName 'zzzBogusKey' -NotePropertyValue 1 -Force
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema | Should -BeFalse
    }

    It 'rejects a wrong scalar type' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.version = 123
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema | Should -BeFalse
    }

    It 'rejects a missing required property' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.PSObject.Properties.Remove('health')
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema | Should -BeFalse
    }

    It 'rejects a value outside a declared enum' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.logging.level = 'NOT_A_REAL_LEVEL'
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema | Should -BeFalse
    }

    It 'rejects a number below its declared minimum' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.build.timeoutMinutes = -5
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema | Should -BeFalse
    }

    It 'accepts a key inside a deliberately OPEN map (additionalProperties not false)' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.build | Add-Member -NotePropertyName 'someForwardCompatKey' -NotePropertyValue 'anything' -Force
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema |
            Should -BeTrue -Because 'the schema opens build.* on purpose; rejecting unknown keys there would break forward compatibility'
    }

    It 'validates patternProperties maps by key pattern (rbac.roles)' {
        $cfg = $script:cpCfgText | ConvertFrom-Json
        $cfg.security.rbac.roles | Add-Member -NotePropertyName 'GoodName' -NotePropertyValue ([pscustomobject]@{ description = 'x' }) -Force
        Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema |
            Should -BeTrue -Because 'patternProperties exists precisely so an open map of role names can still be shape-checked'

        $bad = $script:cpCfgText | ConvertFrom-Json
        $bad.security.rbac.roles | Add-Member -NotePropertyName '0-not-a-valid-name' -NotePropertyValue ([pscustomobject]@{ description = 'x' }) -Force
        Test-BuildConfigSchema -Instance $bad -Schema $script:cpSchema |
            Should -BeFalse -Because 'the declared key pattern must actually be enforced, not just present in the schema'
    }

    It 'enforces uniqueItems where the schema declares it' {
        $dup = $script:cpCfgText | ConvertFrom-Json
        $dup.health | Add-Member -NotePropertyName 'ports' -NotePropertyValue @(8080, 8080) -Force
        Test-BuildConfigSchema -Instance $dup -Schema $script:cpSchema | Should -BeFalse

        $ok = $script:cpCfgText | ConvertFrom-Json
        $ok.health | Add-Member -NotePropertyName 'ports' -NotePropertyValue @(8080, 9090) -Force
        Test-BuildConfigSchema -Instance $ok -Schema $script:cpSchema | Should -BeTrue
    }

    It 'REPORT a schema keyword it does not implement instead of ignoring it' {
        # The failure mode this guards is the dangerous one: a validator that
        # skips a constraint it does not understand keeps reporting "valid" with
        # no signal at all. A new keyword must be loud.
        $schema = [pscustomobject]@{ type = 'object'; properties = @{}; allOf = @() }
        $r = { Test-BuildConfigSchema -Instance ([pscustomobject]@{}) -Schema $schema -Strict }
        { & $r } | Should -Throw -ExpectedMessage '*allOf*'
    }

    It 'agrees with Test-Json on every verdict when Test-Json is available' {
        if (-not $script:cpHasTestJson) { Set-ItResult -Skipped -Because 'Test-Json requires PowerShell 6+'; return }
        $cases = @(
            @{ Name = 'shipped';        Mutate = { param($c) $c } }
            @{ Name = 'bogus top-level'; Mutate = { param($c) $c | Add-Member -NotePropertyName 'zzzBogusKey' -NotePropertyValue 1 -Force; $c } }
            @{ Name = 'wrong type';      Mutate = { param($c) $c.version = 123; $c } }
            @{ Name = 'missing required';Mutate = { param($c) $c.PSObject.Properties.Remove('health'); $c } }
            @{ Name = 'bad enum';        Mutate = { param($c) $c.logging.level = 'NOT_A_REAL_LEVEL'; $c } }
            @{ Name = 'below minimum';   Mutate = { param($c) $c.build.timeoutMinutes = -5; $c } }
            @{ Name = 'open map key';    Mutate = { param($c) $c.build | Add-Member -NotePropertyName 'someForwardCompatKey' -NotePropertyValue 'x' -Force; $c } }
        )
        $mismatch = @()
        foreach ($case in $cases) {
            $cfg = & $case.Mutate ($script:cpCfgText | ConvertFrom-Json)
            $mine = Test-BuildConfigSchema -Instance $cfg -Schema $script:cpSchema
            # Test-Json reports a failure BOTH by returning false and by writing to
            # the error stream. -EA Stop turns the second into a catch so a
            # deliberately-invalid case does not spray red text into a green run.
            $theirs = $false
            try { $theirs = Test-Json -Json ($cfg | ConvertTo-Json -Depth 40 -Compress) -Schema $script:cpSchemaRaw -EA Stop } catch { $theirs = $false }
            if ($mine -ne [bool]$theirs) { $mismatch += "$($case.Name): mine=$mine Test-Json=$theirs" }
        }
        $mismatch | Should -BeNullOrEmpty -Because 'two validators disagreeing on the same file is the defect this validator was added to remove'
    }
}

Describe 'Menu module map is the only load path for 8 modules - so it is verified' {
    # build.menu.moduleMap is the ONLY place Build, Deploy, Android, Chaos,
    # ClusterOrchestrator, HealthCheck, HotReload and Documentation are named
    # for loading. None appears in any Import-ModuleOnDemand call. Get-ModuleMapFromConfig
    # used to return @{} when the section was absent, which turned a config
    # typo into eight targets that silently did nothing.
    BeforeAll {
        $script:cpRoot2 = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:cpCfg2  = Get-Content -LiteralPath (Join-Path $script:cpRoot2 'gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:cpMapOnly = @('Build','Deploy','Android','Chaos','ClusterOrchestrator','HealthCheck','HotReload','Documentation')
        # Get-ModuleMapFromConfig and Test-BuildMenuModuleMap live in
        # Orchestrator, not ConfigProvider; import it here so these assertions
        # exercise the shipped functions rather than failing on resolution.
        $null = Import-Module (Join-Path $script:cpRoot2 'Modules/BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $null = Import-Module (Join-Path $script:cpRoot2 'Modules/Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It 'names every one of those modules in the shipped map' {
        $named = @($script:cpCfg2.build.menu.moduleMap.PSObject.Properties |
                   ForEach-Object { @($_.Value) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $unreachable = @($script:cpMapOnly | Where-Object { $named -notcontains $_ })
        $unreachable | Should -BeNullOrEmpty -Because 'these 8 modules have no other load path, so an absent map entry disables the whole subsystem'
    }

    It 'maps every module it names to a .psm1 that actually ships' {
        $bad = @()
        foreach ($p in $script:cpCfg2.build.menu.moduleMap.PSObject.Properties) {
            foreach ($m in @($p.Value)) {
                $name = ([string]$m).Trim()
                if (-not $name) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $script:cpRoot2 "Modules/$name.psm1") -PathType Leaf)) {
                    $bad += "choice '$($p.Name)' names module '$name', which has no Modules/$name.psm1"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'a map entry naming a module that does not exist fails at runtime, after the user has already chosen a target'
    }

    It 'THROWS naming the missing path instead of returning an empty map' {
        foreach ($bad in @(
            [PSCustomObject]@{ ScriptRoot = $script:cpRoot2; BuildConfig = $null },
            [PSCustomObject]@{ ScriptRoot = $script:cpRoot2; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } },
            [PSCustomObject]@{ ScriptRoot = $script:cpRoot2; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ menu = [PSCustomObject]@{} } } }
        )) {
            # Get-ModuleMapFromConfig stays silent for a synthetic State (a
            # programmatic Invoke-GuildChoice caller that passed -MenuConfig has
            # already declared the menu). The startup gate is what must be loud.
            { Get-ModuleMapFromConfig -State $bad } | Should -Not -Throw -Because 'a caller that supplied its own menu must not be made to satisfy a config requirement it never made'
            { Test-BuildMenuModuleMap -State $bad } | Should -Throw -ExpectedMessage '*moduleMap*'
        }
    }

    It 'still returns the full map for a valid state' {
        $st = [PSCustomObject]@{ ScriptRoot = $script:cpRoot2; BuildConfig = $script:cpCfg2 }
        (Get-ModuleMapFromConfig -State $st).Count | Should -BeGreaterThan 30 -Because '39 choices are mapped today; a near-empty map means the config stopped loading'
    }
}

Describe 'ConfigProvider - schema stub validation' {
    It 'New-ConfigStub returns a config with required sections' {
        $stub = New-ConfigStub
        $stub.version | Should -Be '0.0.0'
        ($stub.PSObject.Properties.Name -contains 'build') | Should -BeTrue
    }
    It 'Test-ConfigSchema returns true for a complete config' {
        $s = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                version = '1.0.0'; build = @{}; logging = @{}; health = @{}; projects = @{}
            }
        }
        Test-ConfigSchema -State $s | Should -BeTrue
    }
    It 'Test-ConfigSchema returns false (non-strict) for a missing required key' {
        $s = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ version = '1.0.0' } }
        Test-ConfigSchema -State $s | Should -BeFalse
    }
}

Describe 'ConfigProvider - Initialize-BuildConfigState' {
    It 'loads the shipped _Build config into live State' {
        $buildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $state = [PSCustomObject]@{ ScriptRoot = $buildRoot; ProjectRoot = $TestDrive }
        $cfg = Initialize-BuildConfigState -State $state
        $state.PSObject.Properties.Name | Should -Contain 'BuildConfig'
        $state.PSObject.Properties.Name | Should -Contain 'ConfigPath'
        $state.BuildConfig | Should -Not -BeNullOrEmpty
        $state.ConfigPath | Should -Be (Join-Path $buildRoot 'gbuild.config.json')
        $cfg.build.projectTypeActions.WinForms.default | Should -Contain '--self-contained'
        $cfg.build.locale.default | Should -Be 'en'
    }

    It 'keeps the base schema path when a project config is an override' {
        $buildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $projectConfig = Join-Path $TestDrive 'gbuild.config.json'
        [PSCustomObject]@{
            description = 'project override'
            build = [PSCustomObject]@{ enableIncremental = $false }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $projectConfig -Encoding UTF8
        $state = [PSCustomObject]@{ ScriptRoot = $buildRoot; ProjectRoot = $TestDrive }
        $cfg = Initialize-BuildConfigState -State $state
        $state.PSObject.Properties.Name | Should -Contain 'BuildConfig'
        $state.PSObject.Properties.Name | Should -Contain 'ConfigPath'
        $state.BuildConfig | Should -Not -BeNullOrEmpty
        $state.ConfigPath | Should -Be $projectConfig
        $state.ConfigSchemaPath | Should -Be (Join-Path $buildRoot 'gbuild.config.schema.json')
        $cfg.description | Should -Be 'project override'
        $cfg.logging | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConfigProvider - source and alias contracts' {
    It 'normalizes the parallel alias once and keeps canonical precedence' {
        $cfg = [PSCustomObject]@{ build = [PSCustomObject]@{ enableParallel = $true; enableParallelBuild = $false } }
        $normalized = Update-ConfigAliases -Config $cfg -RemoveLegacy
        $normalized.build.enableParallelBuild | Should -BeFalse
        $normalized.build.PSObject.Properties.Name | Should -Not -Contain 'enableParallel'
        Get-ConfigValue -Path 'build.enableParallel' -State ([pscustomobject]@{ BuildConfig = $normalized }) | Should -BeFalse
    }

    It 'parses string boolean values consistently' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ enabled = 'false' } } }
        Get-ConfigValue -Path 'build.enabled' -State $state -Type bool | Should -BeFalse
    }

    It 'skips an unknown source and applies a repeated source only once' {
        $base = Join-Path $TestDrive 'base.json'
        $override = Join-Path $TestDrive 'override.json'
        [PSCustomObject]@{ build = [PSCustomObject]@{ maxParallelJobs = 2 } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $base -Encoding UTF8
        [PSCustomObject]@{ build = [PSCustomObject]@{ maxParallelJobs = 5 } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $override -Encoding UTF8
        $missing = Join-Path $TestDrive 'missing.json'
        $merged = Merge-ConfigSources -BasePath $base -OverridePaths @($missing, $override, $override)
        $merged.build.maxParallelJobs | Should -Be 5
    }

    It 'loads an env file into the state overlay without permanently changing the process environment' {
        $buildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $projectConfig = Join-Path $TestDrive 'gbuild.config.json'
        $envFile = Join-Path $TestDrive '.env'
        [PSCustomObject]@{ build = [PSCustomObject]@{ envFile = '.env' }; marker = '${env:GBUILD_CONFIG_CONTRACT}' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $projectConfig -Encoding UTF8
        Set-Content -LiteralPath $envFile -Value 'GBUILD_CONFIG_CONTRACT=loaded' -Encoding UTF8
        $old = [Environment]::GetEnvironmentVariable('GBUILD_CONFIG_CONTRACT')
        try {
            $state = [PSCustomObject]@{ ScriptRoot = $buildRoot; ProjectRoot = $TestDrive }
            $null = Initialize-BuildConfigState -State $state
            Get-ConfigValue -Path 'marker' -State $state -ResolveEnv | Should -Be 'loaded'
            $scope = Enter-BuildConfigEnvironment -State $state
            [Environment]::GetEnvironmentVariable('GBUILD_CONFIG_CONTRACT') | Should -Be 'loaded'
            Exit-BuildConfigEnvironment -Scope $scope
            [Environment]::GetEnvironmentVariable('GBUILD_CONFIG_CONTRACT') | Should -Be $old
        } finally {
            if ($null -eq $old) { Remove-Item Env:\GBUILD_CONFIG_CONTRACT -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('GBUILD_CONFIG_CONTRACT', $old) }
        }
    }
}
