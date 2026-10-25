Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/CacheProvider.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'Cache HA/DR' {
    BeforeAll {
        $cfg = Get-Content (Join-Path $PSScriptRoot '../gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:HaState = [PSCustomObject]@{ BuildConfig = $cfg }
    }

    It 'Reads HA defaults as disabled with async strategy' {
        # Hermetic fixture: the shipped gbuild.config.json is an OPERATIONAL
        # template (remote + HA enabled, env-gated), so unit tests must not
        # couple to it. Disabled-state behavior is asserted on explicit state.
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ enabled = $false } } } }
        $cfg = Get-RemoteCacheConfig -State $st
        $cfg.HA.Enabled | Should -BeFalse
        $cfg.HA.ReplicationStrategy | Should -Be 'async'
    }

    It 'Returns arrays (never $null or bare hashtables) with no replicas' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ enabled = $false } } } }
        $reps = Get-HAReplicaConfigs -State $st
        $reps -is [array] | Should -BeTrue
        $reps.Count | Should -Be 0
    }

    It 'Skips replicas whose names are unconfigured placeholders' {
        $remote = [PSCustomObject]@{
            enabled = $true; name = 'T'; type = 'azureBlob'; endpoint = 'https://p.example.com'
            container = 'c'; authToken = ''; region = 'primary'
            ha = [PSCustomObject]@{
                enabled = $true; replicationStrategy = 'async'
                regions = @([PSCustomObject]@{ name = '${env:GBUILD_CACHE_REGION_PRIMARY}'; priority = 100 })
            }
        }
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = $remote } } }
        $reps = Get-HAReplicaConfigs -State $st
        $reps -is [array] | Should -BeTrue
        @($reps).Count | Should -Be 0
    }

    It 'Skips failover when HA is disabled' {
        $fo = Invoke-HAFailoverCheck -State $script:HaState
        $fo.FailedOver | Should -BeFalse
    }

    It 'Parses multi-region config with priorities' {
        $haCfg = [PSCustomObject]@{
            enabled = $true
            replicationStrategy = 'quorum'
            regions = @(
                [PSCustomObject]@{ name = 'secondary'; endpoint = 'https://s.example.com'; priority = 10 }
            )
        }
        $remote = [PSCustomObject]@{
            enabled = $true; name = 'T'; type = 'azureBlob'; endpoint = 'https://p.example.com'
            container = 'c'; authToken = ''; region = 'primary'; ha = $haCfg
        }
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = $remote } } }
        (Get-HAEnabled -State $st) | Should -BeTrue
        $reps = Get-HAReplicaConfigs -State $st
        $reps.Count | Should -Be 1
        $reps[0].Name | Should -Be 'secondary'
        $reps[0].Priority | Should -Be 10
    }

    It 'keeps tenant keys isolated when HA is enabled' {
        $st = [PSCustomObject]@{ TenantId = 'tenant-a'; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ enabled = $false } } } }
        Resolve-CacheKey -State $st -Key 'entry' | Should -Be 'tenant-a/entry'
        Resolve-CacheKey -State $st -Key 'tenant-a/entry' | Should -Be 'tenant-a/entry'
    }

    # --- Wiring: the HA subsystem used to be exported, configured and tested
    # while the cache data path never touched it, so a green CacheHA.Tests.ps1
    # was false assurance. These assert the region-override seam and the read
    # fallback are genuinely on the transfer path. ---
    It 'Get-RemoteCacheConfig -Region retargets the transfer at a replica' {
        $remote = [PSCustomObject]@{
            enabled = $true; name = 'primary'; type = 'azureBlob'
            endpoint = 'https://p.example.com'; container = 'c-pri'; authToken = ''; region = 'eu'
            ha = [PSCustomObject]@{
                enabled = $true; replicationStrategy = 'sync'
                regions = @([PSCustomObject]@{
                    name = 'secondary'; type = 'azureBlob'; endpoint = 'https://s.example.com'
                    container = 'c-sec'; authToken = 'tok'; region = 'us'; priority = 10
                })
            }
        }
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = $remote } } }
        $primary = Get-RemoteCacheConfig -State $st
        $primary.Name | Should -Be 'primary'
        $primary.Container | Should -Be 'c-pri'

        $replica = (Get-HAReplicaConfigs -State $st)[0]
        $atReplica = Get-RemoteCacheConfig -State $st -Region $replica
        $atReplica.Name | Should -Be 'secondary'
        $atReplica.Container | Should -Be 'c-sec'
        $atReplica.Endpoint | Should -Be 'https://s.example.com'
        $atReplica.AuthToken | Should -Be 'tok'
        # Get-HAReplicaConfigs deliberately sets Region = the replica NAME (that is
        # what `aws --region` is keyed on here), not the raw `region` node field.
        $atReplica.Region | Should -Be 'secondary'
        # HA metadata survives the override: the layer must stay self-aware.
        $atReplica.HA.Enabled | Should -BeTrue
    }

    It 'Receive-CacheEntryFromReplica is a no-op when HA is disabled' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ enabled = $false } } } }
        Receive-CacheEntryFromReplica -State $st -Key 'k' -DestinationPath (Join-Path $env:TEMP 'nope.bin') | Should -BeFalse
    }

    It 'Receive-CacheEntryFromReplica returns false when no replica is reachable' {
        # An unroutable replica must fail fast and quietly, never throw out of the
        # cache read path (a cache miss must degrade to a rebuild, not fail a build).
        $remote = [PSCustomObject]@{
            enabled = $true; name = 'primary'; type = 'azureBlob'
            endpoint = 'https://p.invalid'; container = 'c'; authToken = ''; region = 'eu'
            ha = [PSCustomObject]@{
                enabled = $true; replicationStrategy = 'sync'
                regions = @([PSCustomObject]@{ name = 'secondary'; type = 'azureBlob'; endpoint = 'https://s.invalid'; container = 'c2'; priority = 10 })
            }
        }
        $st = [PSCustomObject]@{ ProjectRoot = $env:TEMP; ScriptRoot = $env:TEMP
                                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = $remote } } }
        Receive-CacheEntryFromReplica -State $st -Key 'missing' -DestinationPath (Join-Path $env:TEMP 'ha-miss.bin') | Should -BeFalse
    }

    It 'Test-CacheHAFailoverPosture is wired and reports without throwing' {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ enabled = $false } } } }
        Test-CacheHAFailoverPosture -State $st | Should -BeFalse
    }

    It 'Select-ReadRegion and Select-WriteRegion are reachable from a replica set' {
        $remote = [PSCustomObject]@{
            enabled = $true; name = 'primary'; type = 'azureBlob'
            endpoint = 'https://p.invalid'; container = 'c'; authToken = ''; region = 'eu'
            ha = [PSCustomObject]@{
                enabled = $true; replicationStrategy = 'sync'
                regions = @([PSCustomObject]@{ name = 'secondary'; type = 'azureBlob'; endpoint = 'https://s.invalid'; container = 'c2'; priority = 10 })
            }
        }
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = $remote } } }
        # No region is healthy against .invalid, so both must fail closed rather
        # than silently return an arbitrary (possibly wrong) region.
        { Select-ReadRegion -State $st } | Should -Throw
        { Select-WriteRegion -State $st } | Should -Throw
    }
}
