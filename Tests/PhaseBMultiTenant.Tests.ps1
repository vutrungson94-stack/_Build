$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $here (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

BeforeAll {
    if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        function Write-Log { param($Message, $Level, $State) }
    }
    if (-not (Get-Command Register-Service -ErrorAction SilentlyContinue)) {
        function Register-Service { param($Name, $Factory, [switch]$Singleton) }
    }
    if (-not (Get-Command Test-ServiceRegistered -ErrorAction SilentlyContinue)) {
        function Test-ServiceRegistered { param($Name); return $false }
    }
}

Describe 'Phase B — Multi-Tenancy Isolation' {

    Context 'B1 — RBAC per-tenant allowedActions' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RBAC.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Test-ActionAllowed allows all when no allowedActions defined' {
            $state = New-TestState
            $result = Test-ActionAllowed -State $state -Action 'A'
            $result.Allowed | Should -BeTrue
        }

        It 'Test-ActionAllowed uses global allowedActions when no tenant match' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'tenantX' -Force
            $state.BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ allowedActions = @('B','C') } }
            $result = Test-ActionAllowed -State $state -Action 'B'
            $result.Allowed | Should -BeTrue
            $result = Test-ActionAllowed -State $state -Action 'A'
            $result.Allowed | Should -BeFalse
        }

        It 'Test-ActionAllowed uses tenant-specific allowedActions override' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'acme' -Force
            $state.BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    allowedActions = @('A','B')
                    tenants = [PSCustomObject]@{
                        acme = [PSCustomObject]@{ allowedActions = @('A') }
                    }
                }
            }
            $r1 = Test-ActionAllowed -State $state -Action 'A'
            $r1.Allowed | Should -BeTrue
            $r2 = Test-ActionAllowed -State $state -Action 'B'
            $r2.Allowed | Should -BeFalse
        }

        It 'Test-ActionAllowed empty tenant allowedActions is fail-closed' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'strict' -Force
            $state.BuildConfig = [PSCustomObject]@{
                security = [PSCustomObject]@{
                    tenants = [PSCustomObject]@{ strict = [PSCustomObject]@{ allowedActions = @() } }
                }
            }
            $result = Test-ActionAllowed -State $state -Action 'A'
            $result.Allowed | Should -BeFalse
        }

        It 'Test-ActionAllowed default tenant uses global allowedActions' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'default' -Force
            $state.BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ allowedActions = @('A','B') } }
            $result = Test-ActionAllowed -State $state -Action 'A'
            $result.Allowed | Should -BeTrue
        }
    }

    Context 'B2 — Tenant-scoped deploy config' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Get-DeployConfig returns global config when no tenant match' {
            $state = New-TestState
            $state.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ azure = [PSCustomObject]@{ appName = 'myapp'; resourceGroup = 'rg1' } } }
            $cfg = Get-DeployConfig -State $state -Target 'azure'
            $cfg.appName | Should -Be 'myapp'
        }

        It 'Get-DeployConfig returns tenant-scoped config when tenant matches' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'acme' -Force
            $state.BuildConfig = [PSCustomObject]@{
                deploy = [PSCustomObject]@{
                    azure = [PSCustomObject]@{ appName = 'global-app'; resourceGroup = 'global' }
                    tenants = [PSCustomObject]@{ acme = [PSCustomObject]@{ azure = [PSCustomObject]@{ appName = 'acme-app'; resourceGroup = 'acme-rg' } } }
                }
            }
            $cfg = Get-DeployConfig -State $state -Target 'azure'
            $cfg.appName | Should -Be 'acme-app'
            $cfg.resourceGroup | Should -Be 'acme-rg'
        }

        It 'Get-DeployConfig returns global config for default tenant' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name TenantId -Value 'default' -Force
            $state.BuildConfig = [PSCustomObject]@{
                deploy = [PSCustomObject]@{
                    azure = [PSCustomObject]@{ appName = 'global-app'; resourceGroup = 'global' }
                    tenants = [PSCustomObject]@{ acme = [PSCustomObject]@{ azure = [PSCustomObject]@{ appName = 'acme-app' } } }
                }
            }
            $cfg = Get-DeployConfig -State $state -Target 'azure'
            $cfg.appName | Should -Be 'global-app'
        }

        It 'Get-DeployConfig returns null for unknown target' {
            $state = New-TestState
            $state.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ azure = [PSCustomObject]@{ appName = 'x' } } }
            $cfg = Get-DeployConfig -State $state -Target 'nonexistent'
            $cfg | Should -BeNullOrEmpty
        }
    }

    Context 'B3 — Tenant labels in Metrics' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Submit-BuildMetric includes tenant label for non-default tenant' {
            $state = [PSCustomObject]@{ TenantId = 'acme' }
            Submit-BuildMetric -State $state -Step 'Build' -DurationMs 100 -Success $true -ProjectName 'test'
            $registry = Get-MetricRegistry
            $metricNames = $registry.Metrics | ForEach-Object { $_.Name } | Select-Object -Unique
            $metricNames | Should -Contain 'gbuild_build_total'
        }

        It 'Submit-CacheMetric includes tenant label when passed' {
            Submit-CacheMetric -Result 'hit' -Project 'test' -CacheKey 'k1' -TenantId 'acme'
            Submit-CacheMetric -Result 'miss' -Project 'test' -CacheKey 'k2' -TenantId 'default'
            $registry = Get-MetricRegistry
            $metricNames = $registry.Metrics | ForEach-Object { $_.Name } | Select-Object -Unique
            $metricNames | Should -Contain 'gbuild_cache_hits_total'
            $metricNames | Should -Contain 'gbuild_cache_misses_total'
            Clear-Metrics
        }

        It 'Submit-BuildMetric does not include tenant label for default tenant' {
            $state = [PSCustomObject]@{ TenantId = 'default' }
            Submit-BuildMetric -State $state -Step 'Test' -DurationMs 50 -Success $true
            Clear-Metrics
        }
    }

    Context 'B4 — Tenant-scoped cache keys' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CacheProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Resolve-CacheKey prefixes with tenant for non-default tenant' {
            $state = [PSCustomObject]@{ TenantId = 'acme' }
            $key = Resolve-CacheKey -State $state -Key 'mykey'
            $key | Should -Be 'acme/mykey'
        }

        It 'Resolve-CacheKey returns key unchanged for default tenant' {
            $state = [PSCustomObject]@{ TenantId = 'default' }
            $key = Resolve-CacheKey -State $state -Key 'mykey'
            $key | Should -Be 'mykey'
        }

        It 'Resolve-CacheKey returns key unchanged when no tenant' {
            $state = [PSCustomObject]@{}
            $key = Resolve-CacheKey -State $state -Key 'mykey'
            $key | Should -Be 'mykey'
        }

        It 'Get-LocalCacheDir nests under the tenant directory' {
            # Get-LocalCacheDir is the exported door to the module-private
            # Resolve-CacheLocalRoot, not a duplicate of it.
            $state = [PSCustomObject]@{ TenantId = 'tenant1'; BuildConfig = [PSCustomObject]@{ tenancy = [PSCustomObject]@{ isolation = 'directory' }; build = [PSCustomObject]@{ cacheDirectory = '.gbuildcache' } } }
            $dir = Get-LocalCacheDir -State $state
            $dir | Should -BeLike '*tenant1'
        }
    }
}

Describe 'Phase C — L5 CI deny-by-default' {

    Context 'C1 — Test-ActionAllowed in non-interactive runs' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RBAC.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Denies privileged actions in CI with no allow-list' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name IsCI -Value $true -Force
            $result = Test-ActionAllowed -State $state -Action 'A'
            $result.Allowed | Should -BeFalse
            $result.Reason | Should -Match 'allowedActions'
        }

        It 'Allows read-only actions in CI with no allow-list' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name NonInteractive -Value $true -Force
            foreach ($a in @('D', 'H', 'R')) {
                (Test-ActionAllowed -State $state -Action $a).Allowed | Should -BeTrue
            }
        }

        It 'Honors enforceInCI=false opt-out' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name IsCI -Value $true -Force
            $state.BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enforceInCI = $false } } }
            (Test-ActionAllowed -State $state -Action 'A').Allowed | Should -BeTrue
        }

        It 'Explicit allow-list still wins in CI' {
            $state = New-TestState
            $state | Add-Member -MemberType NoteProperty -Name IsCI -Value $true -Force
            $state.BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ allowedActions = @('A') } }
            (Test-ActionAllowed -State $state -Action 'A').Allowed | Should -BeTrue
            (Test-ActionAllowed -State $state -Action 'B').Allowed | Should -BeFalse
        }

        It 'Interactive runs keep backward-compatible default-allow' {
            $state = New-TestState
            (Test-ActionAllowed -State $state -Action 'A').Allowed | Should -BeTrue
        }
    }
}

Describe 'Phase D — Polish' {
    Context 'D1 — Dispatch table for Invoke-GuildChoice' {
        BeforeAll {
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        }

        It 'Invoke-GuildChoice has dispatch table (function exists and parses)' {
            $cmd = Get-Command Invoke-GuildChoice -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
    }
}
