# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'ConfigProvider', 'EventBus', 'Metrics', 'Distributed')

# ============================================================================
# ClusterOrchestrator.psm1 — Multi-Cluster Build Orchestration
# ============================================================================
# Provides Kubernetes operator integration, multi-cluster coordination,
# and distributed build scheduling across cluster fleets.

# ── Built-in cluster config (config-overridable via build.cluster) ────────────
# Level 5 single-source: every literal below resolves via Get-BuildDefault at
# module load so BuildConstants.psm1 remains the ONE place for defaults.
function Get-ClusterDefault {
    param([string]$Key, $Fallback)

Set-StrictMode -Version 1.0
    try {
        if (Get-Command Get-BuildDefault -ErrorAction SilentlyContinue) {
            return Get-BuildDefault -Key $Key -Fallback $Fallback
        }
    } catch { }
    return $Fallback
}
$script:DefaultClusterConfig = @{
    Enabled              = $false
    Coordinator          = @{
        Type               = (Get-ClusterDefault -Key 'ClusterCoordinatorType' -Fallback 'leader-election')
        Endpoint           = ''
        LeaseName          = (Get-ClusterDefault -Key 'ClusterLeaseName' -Fallback 'gbuild-coordinator')
        LeaseNamespace     = (Get-ClusterDefault -Key 'ClusterLeaseNamespace' -Fallback 'gbuild-system')
        ElectionTTL        = (Get-ClusterDefault -Key 'ClusterElectionTTL' -Fallback 15)
        RenewalInterval    = (Get-ClusterDefault -Key 'ClusterRenewalInterval' -Fallback 5)
    }
    Clusters             = @()
    Scheduling           = @{
        Strategy           = (Get-ClusterDefault -Key 'ClusterSchedulingStrategy' -Fallback 'least-loaded')
        MaxConcurrentPerCluster = (Get-ClusterDefault -Key 'ClusterMaxConcurrentPerCluster' -Fallback 8)
        AffinityRules      = @()
        TaintsTolerations  = @()
    }
    # Per-build Job sizing, consumed by the submit manifest. Previously the
    # manifest hardcoded 500m/1Gi + 2000m/4Gi and 86400/2 while the configured
    # scheduling.resourceCpu/resourceMemory were resolved and discarded.
    Job                  = @{
        RequestCpu         = (Get-ClusterDefault -Key 'ClusterJobRequestCpu' -Fallback '500m')
        RequestMemory      = (Get-ClusterDefault -Key 'ClusterJobRequestMemory' -Fallback '1Gi')
        LimitCpu           = (Get-ClusterDefault -Key 'ClusterJobLimitCpu' -Fallback '2000m')
        LimitMemory        = (Get-ClusterDefault -Key 'ClusterJobLimitMemory' -Fallback '4Gi')
        TtlSecondsAfterFinished = (Get-ClusterDefault -Key 'ClusterJobTtlSeconds' -Fallback 86400)
        BackoffLimit       = (Get-ClusterDefault -Key 'ClusterJobBackoffLimit' -Fallback 2)
        Namespace          = (Get-ClusterDefault -Key 'ClusterJobsNamespace' -Fallback 'gbuild-jobs')
    }
    WorkloadIdentity     = @{
        Enabled            = $false
        ServiceAccount     = (Get-ClusterDefault -Key 'ClusterServiceAccount' -Fallback 'gbuild-worker')
        Namespace          = (Get-ClusterDefault -Key 'ClusterNamespace' -Fallback 'gbuild-system')
        TokenAudience      = (Get-ClusterDefault -Key 'ClusterTokenAudience' -Fallback 'gbuild')
    }
    Observability        = @{
        MetricsPort        = (Get-ClusterDefault -Key 'ClusterMetricsPort' -Fallback 9101)
        HealthPort         = (Get-ClusterDefault -Key 'ClusterHealthPort' -Fallback 9102)
        LogLevel           = (Get-ClusterDefault -Key 'ClusterLogLevel' -Fallback 'Info')
    }
}

# ── Module state ──────────────────────────────────────────────────────────────
$script:ClusterCache = @{}
$script:Initialized = $false
$script:CompletedBuilds = @{}
$script:LeaderCancellation = $false

function Test-ClusterNamespace {
    param([string]$Namespace)
    return (-not [string]::IsNullOrWhiteSpace($Namespace) -and $Namespace.Length -le 63 -and $Namespace -match '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')
}

function Test-ClusterContext {
    param([string]$Context)
    return (-not [string]::IsNullOrWhiteSpace($Context) -and $Context -notmatch '[\x00-\x1f\x7f]' -and $Context -notmatch '^[-\\/]' -and $Context -notmatch '[\s;=\\/]' -and $Context -notmatch '(^|\.)\.\.($|\.)')
}

function Resolve-ClusterKubeconfig {
    param([string]$Path, [PSCustomObject]$State)
    $value = $Path
    if (-not $value) { $value = $env:KUBECONFIG }
    if (-not $value) { return '' }
    if ($value.StartsWith('~')) {
        # NOT $home: read-only automatic variable on PowerShell 6+, where the
        # assignment was a silent no-op and the HOST's home decided the expansion.
        $userHome = [Environment]::GetFolderPath('UserProfile')
        if (-not $userHome) { $userHome = $env:HOME }
        if (-not $userHome) { return '' }
        $value = $value.Replace('~', $userHome)
    }
    if ($value -match '[\x00-\x1f\x7f]' -or $value -match '[;|]') { return '' }
    try {
        # Base single-sourced in PathUtils.Get-BuildRootDirectory. The old CWD
        # fallback made the containment check below circular when ScriptRoot was
        # missing: a relative kubeconfig anywhere under the launch directory was
        # accepted. Guarded for the PS 5.1-orphan path.
        $base = if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State }
                elseif ($State -and $State.PSObject.Properties.Name -contains 'ScriptRoot' -and $State.ScriptRoot) { [string]$State.ScriptRoot }
                elseif ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { [string]$State.ProjectRoot }
                else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.clusterorchestrator.line109' -Fallback 'Cluster config base is undetermined: State carries neither ScriptRoot nor ProjectRoot.')) }
        $full = if ([System.IO.Path]::IsPathRooted($value)) { [System.IO.Path]::GetFullPath($value) } else { [System.IO.Path]::GetFullPath((Join-Path $base $value)) }
        if (-not [System.IO.Path]::IsPathRooted($value)) {
            # Relative kubeconfigs stay under the cluster base. The comparison
            # itself is delegated when PathUtils is available; absolute values
            # intentionally retain their existing behavior below.
            $contained = $false
            if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
                try { $contained = Test-PathUnderRoots -Path $full -AllowedRoots @($base) } catch { $contained = $false }
            } else {
                $baseFull = ([System.IO.Path]::GetFullPath($base)).TrimEnd('\', '/')
                $cmp = Get-PathComparison

                $contained = $full.StartsWith($baseFull + [System.IO.Path]::DirectorySeparatorChar, $cmp)
            }
            if (-not $contained) { return '' }
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
        return $full
    } catch { return '' }
}

function Test-ClusterEndpoint {
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return $true }
    $uri = $null
    return [System.Uri]::TryCreate($Endpoint, [System.UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('https','http')
}

function Invoke-ClusterKubectl {
    [CmdletBinding()]
    param(
        [hashtable]$Cluster,
        [string[]]$Arguments,
        [int]$TimeoutSec = 30,
        [PSCustomObject]$State = $null
    )
    $result = [PSCustomObject]@{ Output = ''; ExitCode = 127; Success = $false }
    $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
    if (-not $kubectl) { return $result }
    $args = @()
    $kubeconfig = Resolve-ClusterKubeconfig -Path ([string]$Cluster.Kubeconfig) -State $State
    if ($Cluster.Kubeconfig -and -not $kubeconfig) { return $result }
    if ($kubeconfig) { $args += @('--kubeconfig', $kubeconfig) }
    if ($Cluster.Context) {
        if (-not (Test-ClusterContext -Context ([string]$Cluster.Context))) { return $result }
        $args += @('--context', [string]$Cluster.Context)
    }
    if ($TimeoutSec -gt 0) { $args += ('--request-timeout={0}s' -f $TimeoutSec) }
    $args += @($Arguments)
    $before = $null
    $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($variable) { $before = $variable.Value }
    try {
        if ($kubectl.CommandType -eq 'Application') {
            $kubectlPath = if ($kubectl.Path) { [string]$kubectl.Path } else { [string]$kubectl.Source }
            if (-not $kubectlPath) { return $result }
            $output = & $kubectlPath @args 2>&1
        } else {
            $output = & $kubectl.Name @args 2>&1
        }
        $after = $null
        $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($variable) { $after = $variable.Value }
        $exit = if ($null -ne $after -and ($after -is [int])) { [int]$after } else { 0 }
        $result.Output = ($output | Out-String)
        $result.ExitCode = $exit
        $result.Success = ($exit -eq 0)
        return $result
    } catch {
        $result.Output = $_.Exception.Message
        return $result
    }
}

function Test-ClusterManifestValue {
    param([string]$Value, [int]$MaxLength = 253)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -le $MaxLength -and $Value -notmatch '[\x00-\x1f\x7f]')
}


# ── Config merge (defaults + user override, fully recursive) ──────────────────
# Level 5 DRY: the deep-merge ALGORITHM lives in exactly one place -
# ConfigProvider.Merge-ConfigObject, the canonical recursive merge. This module
# keeps only a thin wrapper that binds $script:DefaultClusterConfig as the base
# tree. The old one-level loop merged each default section only with the
# override's node AT that section, so a nested key
# (build.cluster.job.<obj>.<key>) silently REPLACED that whole nested object and
# dropped its siblings - it only appeared to work because Job / Scheduling /
# Coordinator / Observability / WorkloadIdentity are flat today. Delegating fixes
# that at every depth and makes this module agree with AuditLedger on $getVal
# semantics (any IDictionary OR PSCustomObject override is honoured).
#
# Shape: Merge-ConfigObject returns PSCustomObject, and every consumer of
# $script:ClusterConfig here uses property-style access ($script:ClusterConfig.Job
# .RequestCpu, .Scheduling.Strategy, .WorkloadIdentity.ServiceAccount,
# .Coordinator.Type, .Clusters) - which PowerShell resolves identically on a
# PSCustomObject. No hashtable normalisation is required, so none is done.
function Merge-ClusterConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Override)
    if (-not (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue)) {
        Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Merge-ConfigObject'
    }
    if (-not (Get-Command Merge-ConfigObject -ErrorAction SilentlyContinue)) {
        throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line215' -Fallback 'ClusterOrchestrator: ConfigProvider.Merge-ConfigObject is unavailable; cannot merge build.cluster config.')
    }
    # A non-mapping override (e.g. build.cluster = true) carries no keys to merge:
    # keep the built-in defaults rather than exploding scalar members.
    if ($null -ne $Override -and -not ($Override -is [System.Collections.IDictionary]) -and -not ($Override -is [PSCustomObject])) {
        $Override = $null
    }
    return Merge-ConfigObject -Base $script:DefaultClusterConfig -Override $Override
}

# ── Initialization ────────────────────────────────────────────────────────────
function Initialize-ClusterOrchestrator {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if ($script:Initialized) { return }
    $script:Initialized = $true

    $cfg = Get-ConfigValue -Path 'build.cluster' -State $State -Default $null
    # Merge user config over defaults (recursively) so a PARTIAL config (e.g.
    # only { enabled, clusters }) keeps complete Coordinator / Scheduling /
    # WorkloadIdentity / Observability subsections at every depth.
    $script:ClusterConfig = Merge-ClusterConfig -Override $cfg

    # Load cluster definitions from config through the same imperative API used
    # for runtime registration. The cache entry used to be constructed inline
    # here, separately from Register-Cluster, so the two shapes could drift and
    # config-declared clusters never emitted EVT_CLUSTER_REGISTERED.
    if ($script:ClusterConfig.Clusters) {
        $capCpuDefault = (Get-ClusterDefault -Key 'ClusterCapacityCpu' -Fallback '8')
        $capMemDefault = (Get-ClusterDefault -Key 'ClusterCapacityMemory' -Fallback '32Gi')
        $maxConcDefault = (Get-ClusterDefault -Key 'ClusterDefaultMaxConcurrent' -Fallback 8)
        if ($script:ClusterConfig.Scheduling -and $script:ClusterConfig.Scheduling.MaxConcurrentPerCluster) {
            $maxConcDefault = [int]$script:ClusterConfig.Scheduling.MaxConcurrentPerCluster
        }
        foreach ($cluster in $script:ClusterConfig.Clusters) {
            $capacityArg = @{}
            try {
                if ($cluster.Capacity) {
                    if ($cluster.Capacity.Cpu) { $capacityArg['Cpu'] = [string]$cluster.Capacity.Cpu }
                    if ($cluster.Capacity.Memory) { $capacityArg['Memory'] = [string]$cluster.Capacity.Memory }
                }
            } catch { $capacityArg = @{} }
            $requestedMaxConc = 0
            try { if ($cluster.MaxConcurrent) { $requestedMaxConc = [int]$cluster.MaxConcurrent } } catch { $requestedMaxConc = 0 }
            if ($requestedMaxConc -le 0) { $requestedMaxConc = [int]$maxConcDefault }
            try {
                Register-Cluster -Name ([string]$cluster.Name) -Endpoint ([string]$cluster.Endpoint) `
                    -Kubeconfig ([string]$cluster.Kubeconfig) -Context ([string]$cluster.Context) `
                    -Region ([string]$cluster.Region) -Zone ([string]$cluster.Zone) `
                    -Capacity $capacityArg -Labels @($cluster.Labels) -Taints @($cluster.Taints) `
                    -MaxConcurrent $requestedMaxConc -State $State
            } catch {
                # Preserve the old fail-open posture: a bad declarative entry is
                # rejected with a warning, not a fatal build error.
                if ([string]$_.Exception.Message -eq 'Invalid cluster kubeconfig path.') {
                    Write-Log (Resolve-LogMessage -Key 'log.cluster.invalidKubeconfig' -Fallback '[ClusterOrchestrator] Rejected cluster with invalid kubeconfig path.') 'Warn' $State
                } else {
                    Write-Log (Resolve-LogMessage -Key 'log.cluster.invalidDefinition' -Fallback '[ClusterOrchestrator] Rejected invalid cluster definition.') 'Warn' $State
                }
            }
        }
    }

    Write-Log (Resolve-LogMessage -Key 'log.cluster.initialized' -MessageArgs @([string]$script:ClusterCache.Count) -Fallback '[ClusterOrchestrator] Initialized with {0} cluster(s)') 'Info' $State
}

# ── Cluster registration & discovery ──────────────────────────────────────────
function Register-Cluster {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$Kubeconfig = '',
        [string]$Context = '',
        [string]$Region = '',
        [string]$Zone = '',
        [hashtable]$Capacity = @{},
        [string[]]$Labels = @(),
        [string[]]$Taints = @(),
        [int]$MaxConcurrent = 0,
        [PSCustomObject]$State
    )
    Initialize-ClusterOrchestrator -State $State
    if (-not (Test-ClusterManifestValue -Value $Name -MaxLength 63) -or -not (Test-ClusterEndpoint -Endpoint $Endpoint) -or ($Context -and -not (Test-ClusterContext -Context $Context))) {
        throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line299' -Fallback 'Invalid cluster definition.')
    }
    if ($Kubeconfig -and $Kubeconfig -notmatch '\$\{env:' -and -not (Resolve-ClusterKubeconfig -Path $Kubeconfig -State $State)) {
        throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line302' -Fallback 'Invalid cluster kubeconfig path.')
    }
    if ($MaxConcurrent -le 0) {
        $MaxConcurrent = (Get-ClusterDefault -Key 'ClusterDefaultMaxConcurrent' -Fallback 8)
    }
    $capCpuDefault = (Get-ClusterDefault -Key 'ClusterCapacityCpu' -Fallback '8')
    $capMemDefault = (Get-ClusterDefault -Key 'ClusterCapacityMemory' -Fallback '32Gi')
    $script:ClusterCache[$Name] = @{
        Name          = $Name
        Endpoint      = $Endpoint
        Kubeconfig    = $Kubeconfig
        Context       = $Context
        Region        = $Region
        Zone          = $Zone
        Capacity      = @{ cpu = if ($Capacity.Cpu) { $Capacity.Cpu } else { $capCpuDefault }; memory = if ($Capacity.Memory) { $Capacity.Memory } else { $capMemDefault } }
        Labels        = @($Labels)
        Taints        = @($Taints)
        Status        = 'Registering'
        LastHeartbeat = (Get-Date)
        ActiveBuilds  = 0
        MaxConcurrent = $MaxConcurrent
    }
    Write-Log (Resolve-LogMessage -Key 'log.cluster.registered' -MessageArgs @([string]$Name, $Endpoint) -Fallback '[ClusterOrchestrator] Registered cluster ''{0}'' at {1}') 'Succ' $State
    Send-BuildEvent -EventName $EVT_CLUSTER_REGISTERED -Source $State -Data @{ Cluster = $Name; Endpoint = $Endpoint } | Out-Null
}

function Get-Cluster {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [PSCustomObject]$State
    )
    Initialize-ClusterOrchestrator -State $State
    return $script:ClusterCache[$Name]
}

function Get-AllClusters {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([PSCustomObject]$State)
    Initialize-ClusterOrchestrator -State $State
    # Unary comma: a single registered cluster would otherwise unroll to a bare
    # hashtable on return, and callers reading .Count would get the KEY count.
    return ,@($script:ClusterCache.Values)
}

function Get-HealthyClusters {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([PSCustomObject]$State)
    Initialize-ClusterOrchestrator -State $State
    $now = Get-Date
    $healthy = @()
    foreach ($cluster in $script:ClusterCache.Values) {
        if ($cluster.Status -eq 'Ready' -and $cluster.LastHeartbeat -and ($now - $cluster.LastHeartbeat).TotalSeconds -lt 60) {
            $healthy += $cluster
        }
    }
    # Unary comma: preserve the array contract for 0/1 healthy clusters.
    return ,@($healthy)
}

# ── Cluster health & heartbeats ───────────────────────────────────────────────
function Update-ClusterHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$Status = 'Ready',
        [int]$ActiveBuilds = -1,
        [PSCustomObject]$State
    )
    Initialize-ClusterOrchestrator -State $State
    if ($script:ClusterCache.ContainsKey($ClusterName)) {
        $script:ClusterCache[$ClusterName].LastHeartbeat = Get-Date
        if ($Status) { $script:ClusterCache[$ClusterName].Status = $Status }
        if ($ActiveBuilds -ge 0) { $script:ClusterCache[$ClusterName].ActiveBuilds = $ActiveBuilds }
    }
}

function Test-ClusterHealth {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Cluster,
        [PSCustomObject]$State,
        # Level 5 single-source: 0 = resolve centrally via ClusterHealthTimeoutSec.
        [int]$TimeoutSec = 0
    )
    if ($TimeoutSec -le 0) {
        $TimeoutSec = (Get-ClusterDefault -Key 'ClusterHealthTimeoutSec' -Fallback 10)
    }
    $result = @{ Healthy = $false; LatencyMs = -1; Error = '' }
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $commandResult = Invoke-ClusterKubectl -Cluster $Cluster -Arguments @('get','nodes','--no-headers') -TimeoutSec $TimeoutSec -State $State
        $sw.Stop()
        $result.LatencyMs = $sw.ElapsedMilliseconds
        if ($commandResult.Success) {
            $result.Healthy = $true
            $result.NodeCount = @(($commandResult.Output -split "`r?`n") | Where-Object { $_ -match '\bReady\b' }).Count
        } else {
            $result.Error = $commandResult.Output
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Start-ClusterHealthMonitor {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    Initialize-ClusterOrchestrator -State $State
    $interval = (Get-ClusterDefault -Key 'ClusterHealthMonitorIntervalSec' -Fallback 30)
    while ($true) {
        foreach ($cluster in $script:ClusterCache.Values) {
            $health = Test-ClusterHealth -Cluster $cluster -State $State
            $newStatus = if ($health.Healthy) { 'Ready' } else { 'NotReady' }
            if ($cluster.Status -ne $newStatus) {
                Write-Log (Resolve-LogMessage -Key 'log.cluster.statusChanged' -MessageArgs @([string]$cluster.Name, $cluster.Status, $newStatus) -Fallback '[ClusterOrchestrator] Cluster ''{0}'' status changed: {1} -> {2}') 'Warn' $State
                Send-BuildEvent -EventName $EVT_CLUSTER_STATUS_CHANGED -Source $State -Data @{ Cluster = $cluster.Name; OldStatus = $cluster.Status; NewStatus = $newStatus } | Out-Null
            }
            Update-ClusterHeartbeat -ClusterName $cluster.Name -Status $newStatus -State $State
        }
        Start-Sleep -Seconds $interval
    }
}

# ── Distributed scheduling ────────────────────────────────────────────────────
function Select-ClusterForBuild {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [PSCustomObject]$State,
        [hashtable]$BuildRequirements,
        [string]$Strategy = ''
    )
    Initialize-ClusterOrchestrator -State $State
    $healthy = @(Get-HealthyClusters -State $State | Where-Object { [int]$_.ActiveBuilds -lt [int]$_.MaxConcurrent })
    if ($healthy.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line442' -Fallback "No healthy clusters available") }

    $schedulingConfig = $script:ClusterConfig.Scheduling
    $strategy = if ($Strategy) { $Strategy } else { $schedulingConfig.Strategy }

    switch ($strategy) {
        'least-loaded' {
            $selected = $healthy | Sort-Object @{ Expression = { $_.ActiveBuilds / $_.MaxConcurrent }; Ascending = $true } | Select-Object -First 1
        }
        'round-robin' {
            $script:rrIndex = if ($script:rrIndex) { ($script:rrIndex + 1) % $healthy.Count } else { 0 }
            $selected = $healthy[$script:rrIndex]
        }
        'affinity' {
            # Match build labels to cluster labels
            $buildLabels = if ($BuildRequirements.Labels) { @($BuildRequirements.Labels) } else { @() }
            $scored = @()
            foreach ($cluster in $healthy) {
                $score = 0
                foreach ($label in $buildLabels) {
                    if ($cluster.Labels -contains $label) { $score += 10 }
                }
                # Prefer clusters with matching region/zone
                if ($BuildRequirements.Region -and $cluster.Region -eq $BuildRequirements.Region) { $score += 5 }
                if ($BuildRequirements.Zone -and $cluster.Zone -eq $BuildRequirements.Zone) { $score += 3 }
                # Prefer less loaded
                $loadFactor = $cluster.ActiveBuilds / $cluster.MaxConcurrent
                $score += (1 - $loadFactor) * 2
                $scored += @{ Cluster = $cluster; Score = $score }
            }
            $selected = ($scored | Sort-Object Score -Descending | Select-Object -First 1).Cluster
        }
        default { $selected = $healthy[0] }
    }
    return $selected
}

function Submit-ClusterBuild {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][hashtable]$BuildSpec,
        [hashtable]$Requirements = @{}
    )
    Initialize-ClusterOrchestrator -State $State
    $cluster = Select-ClusterForBuild -State $State -BuildRequirements $Requirements
    if (-not $cluster) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line489' -Fallback "No suitable cluster found") }

    # Per-build Job sizing + namespace come from config (build.cluster.job.*),
    # not from literals baked into the manifest.
    $jobCfg = $script:ClusterConfig.Job
    if (-not $jobCfg) { $jobCfg = $script:DefaultClusterConfig.Job }

    $buildId = "gbuild-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $namespace = if ($jobCfg.Namespace) { [string]$jobCfg.Namespace } else { 'gbuild-jobs' }
    if ($BuildSpec.ContainsKey('Namespace') -and (-not [string]::IsNullOrWhiteSpace([string]$BuildSpec.Namespace))) { $namespace = [string]$BuildSpec.Namespace }
    if (-not (Test-ClusterNamespace -Namespace $namespace)) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line499' -Fallback 'Invalid Kubernetes namespace.') }
    $projectName = if ($BuildSpec.PSObject.Properties.Name -contains 'Project' -and $BuildSpec.Project) { [string]$BuildSpec.Project } elseif ($BuildSpec.PSObject.Properties.Name -contains 'ProjectName' -and $BuildSpec.ProjectName) { [string]$BuildSpec.ProjectName } else { '' }
    if (-not (Test-ClusterManifestValue -Value $projectName -MaxLength 63) -or $projectName -match '[\s]') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line501' -Fallback 'Invalid build project.') }
    $builderImage = [string]$BuildSpec.BuilderImage
    if (-not $builderImage) { $builderImage = [string]$BuildSpec.Image }
    $imageLeaf = ($builderImage -replace '@.*$', '' -split '/')[-1]
    $hasImmutableDigest = $builderImage -match '(?i)@sha256:[0-9a-f]{64}$'
    $hasExplicitTag = $imageLeaf -match ':[^:]+$'
    if (-not $builderImage -or -not ($hasImmutableDigest -or $hasExplicitTag) -or $builderImage -match '(?i)(^|[:/])latest($|@)' -or $builderImage -match '[\x00-\x1f\x7f]') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line507' -Fallback 'A non-latest builder image is required.') }
    $commandValue = $BuildSpec.Command
    if ($commandValue -is [array]) { $commandValue = ($commandValue -join ' ') }
    $commandValue = [string]$commandValue
    if ([string]::IsNullOrWhiteSpace($commandValue) -or $commandValue -match '[\x00-\x1f\x7f]') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line511' -Fallback 'Invalid build command.') }
    $serviceAccount = [string]$script:ClusterConfig.WorkloadIdentity.ServiceAccount
    if (-not (Test-ClusterManifestValue -Value $serviceAccount -MaxLength 253) -or $serviceAccount -match '[\s:]') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line513' -Fallback 'Invalid Kubernetes service account.') }
    $envVars = @()
    $identity = Get-SectionValue -Section $State -Key 'BuildIdentity' -Default $null
    $triggeredBy = if ($identity -and $identity.User) { [string]$identity.User } else { 'unknown' }
    $correlationId = [string](Get-SectionValue -Section $State -Key 'CorrelationId' -Default '')
    if ($BuildSpec.ContainsKey('EnvVars') -and $null -ne $BuildSpec.EnvVars) {
        foreach ($envVar in @($BuildSpec.EnvVars)) {
            $envName = [string](Get-SectionValue -Section $envVar -Key 'name' -Default '')
            $envValue = [string](Get-SectionValue -Section $envVar -Key 'value' -Default '')
            if ($envName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $envValue -match '[\x00-\x1f\x7f]') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line522' -Fallback 'Invalid environment variable.') }
            $envVars += @{ name = $envName; value = $envValue }
        }
    }

    $jobManifest = @{
        apiVersion = 'batch/v1'
        kind       = 'Job'
        metadata   = @{
            name      = $buildId
            namespace = $namespace
            labels    = @{
                'gbuild.io/build-id'   = $buildId
                'gbuild.io/cluster'    = $cluster.Name
                'gbuild.io/project'    = $projectName
                'gbuild.io/triggered-by' = $triggeredBy
            }
        }
        spec = @{
            ttlSecondsAfterFinished = $jobCfg.TtlSecondsAfterFinished
            backoffLimit            = $jobCfg.BackoffLimit
            template = @{
                spec = @{
                    serviceAccountName = $script:ClusterConfig.WorkloadIdentity.ServiceAccount
                    restartPolicy      = 'Never'
                    containers = @(
                        @{
                            name            = 'build'
                            image           = $builderImage
                            command         = @('/bin/sh', '-c')
                            args            = @($commandValue)
                            env             = @(
                                @{ name = 'GBUILD_PROJECT'; value = $projectName }
                                @{ name = 'GBUILD_BUILD_ID'; value = $buildId }
                                @{ name = 'GBUILD_CLUSTER'; value = $cluster.Name }
                                @{ name = 'GBUILD_CORRELATION_ID'; value = $correlationId }
                            ) + $envVars
                            resources       = @{
                                requests = @{ cpu = $jobCfg.RequestCpu; memory = $jobCfg.RequestMemory }
                                limits   = @{ cpu = $jobCfg.LimitCpu; memory = $jobCfg.LimitMemory }
                            }
                            volumeMounts    = @(
                                @{ name = 'workspace'; mountPath = '/workspace' }
                                @{ name = 'cache'; mountPath = '/cache' }
                            )
                        }
                    )
                    volumes = @(
                        @{ name = 'workspace'; emptyDir = @{} }
                        @{ name = 'cache'; emptyDir = @{} }
                    )
                }
            }
        }
    }

    $manifestJson = $jobManifest | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } else { 10 }) -Compress
    $tempManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("$buildId-job.json")
    try {
        [System.IO.File]::WriteAllText($tempManifest, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
        $applyResult = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('apply','-f',$tempManifest) -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
        if (-not $applyResult.Success) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line583' -Fallback "Failed to submit build to cluster '$($cluster.Name)': $($applyResult.Output)") }
    } finally {
        if (Test-Path -LiteralPath $tempManifest) { Remove-Item -LiteralPath $tempManifest -Force -ErrorAction SilentlyContinue }
    }
    $script:ClusterCache[$cluster.Name].ActiveBuilds++
    $script:CompletedBuilds["$($cluster.Name)/$buildId"] = $false

    Write-Log (Resolve-LogMessage -Key 'log.cluster.buildSubmitted' -MessageArgs @([string]$buildId, $cluster.Name) -Fallback '[ClusterOrchestrator] Submitted build ''{0}'' to cluster ''{1}''') 'Succ' $State
    Send-BuildEvent -EventName $EVT_CLUSTER_BUILD_SUBMITTED -Source $State -Data @{ BuildId = $buildId; Cluster = $cluster.Name; Project = $projectName } | Out-Null

    return @{
        BuildId   = $buildId
        Cluster   = $cluster.Name
        Namespace = $namespace
        Status    = 'Submitted'
    }
}

function Get-ClusterBuildStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$Namespace = 'gbuild-jobs',
        [PSCustomObject]$State
    )
    if ($BuildId -notmatch '^[a-z0-9]([-a-z0-9.]{0,61}[a-z0-9])?$' -or -not (Test-ClusterNamespace -Namespace $Namespace)) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line610' -Fallback 'Invalid build identity or namespace.') }
    Initialize-ClusterOrchestrator -State $State
    $cluster = Get-Cluster -Name $ClusterName -State $State
    if (-not $cluster) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line613' -Fallback "Cluster '$ClusterName' not found") }
    $commandResult = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('-n',$Namespace,'get','job',$BuildId,'-o','json') -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
    if (-not $commandResult.Success) { return @{ Status = 'NotFound'; BuildId = $BuildId; Cluster = $ClusterName } }
    try { $job = $commandResult.Output | ConvertFrom-Json } catch { return @{ Status = 'Failed'; BuildId = $BuildId; Cluster = $ClusterName; Error = 'Invalid job status response' } }
    $status = @{ BuildId = $BuildId; Cluster = $ClusterName; Namespace = $Namespace }
    $succeeded = [int](Get-SectionValue -Section $job.status -Key 'succeeded' -Default 0)
    $failed = [int](Get-SectionValue -Section $job.status -Key 'failed' -Default 0)
    $active = [int](Get-SectionValue -Section $job.status -Key 'active' -Default 0)
    if ($succeeded -gt 0) { $status.Status = 'Succeeded' }
    elseif ($failed -gt 0) { $status.Status = 'Failed' }
    elseif ($active -gt 0) { $status.Status = 'Running' }
    else { $status.Status = 'Pending' }
    $stateKey = "$ClusterName/$BuildId"
    if ($status.Status -in @('Succeeded','Failed') -and (-not $script:CompletedBuilds.ContainsKey($stateKey) -or -not [bool]$script:CompletedBuilds[$stateKey])) {
        $current = [int]$script:ClusterCache[$ClusterName].ActiveBuilds
        $script:ClusterCache[$ClusterName].ActiveBuilds = [Math]::Max(0, $current - 1)
        $script:CompletedBuilds[$stateKey] = $true
    }
    if ($status.Status -in @('Running','Failed','Succeeded')) {
        $podResult = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('-n',$Namespace,'get','pods','-l',('job-name=' + $BuildId),'-o','jsonpath={.items[0].metadata.name}') -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
        $podName = if ($podResult.Success) { $podResult.Output.Trim() } else { '' }
        if ($podName -and $podName -notmatch '[\r\n]') {
            $logResult = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('-n',$Namespace,'logs',$podName,'--tail=100') -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
            if ($logResult.Success) { $status.Logs = $logResult.Output }
        }
    }
    return $status
}

function Stop-ClusterBuild {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$Namespace = 'gbuild-jobs',
        [PSCustomObject]$State
    )
    if ($BuildId -notmatch '^[a-z0-9]([-a-z0-9.]{0,61}[a-z0-9])?$' -or -not (Test-ClusterNamespace -Namespace $Namespace)) { return $false }
    $cluster = Get-Cluster -Name $ClusterName -State $State
    if (-not $cluster) { return $false }
    $result = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('-n',$Namespace,'delete','job',$BuildId,'--ignore-not-found=true') -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
    $stateKey = "$ClusterName/$BuildId"
    if ($result.Success -and (-not $script:CompletedBuilds.ContainsKey($stateKey) -or -not [bool]$script:CompletedBuilds[$stateKey])) {
        $current = [int]$script:ClusterCache[$ClusterName].ActiveBuilds
        $script:ClusterCache[$ClusterName].ActiveBuilds = [Math]::Max(0, $current - 1)
        $script:CompletedBuilds[$stateKey] = $true
    }
    return [bool]$result.Success
}


function Wait-ClusterBuild {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$Namespace = 'gbuild-jobs',
        [int]$TimeoutSec = 0,
        [PSCustomObject]$State,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    if ($TimeoutSec -le 0) {
        $TimeoutSec = 3600
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $TimeoutSec = [int](Get-BuildConstant -Key 'ClusterBuildTimeoutSec' -State $State -Fallback 3600) } catch { $TimeoutSec = 3600 }
        }
    }
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        if ($CancellationToken.IsCancellationRequested) {
            [void](Stop-ClusterBuild -BuildId $BuildId -ClusterName $ClusterName -Namespace $Namespace -State $State)
            throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line686' -MessageArgs @([string]$BuildId, [string]$ClusterName) -Fallback "Build $BuildId on cluster $ClusterName was cancelled")
        }
        $status = Get-ClusterBuildStatus -BuildId $BuildId -ClusterName $ClusterName -Namespace $Namespace -State $State
        if ($status.Status -in @('Succeeded', 'Failed')) { return $status }
        if ($status.Status -eq 'NotFound') { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line690' -MessageArgs @([string]$BuildId, [string]$ClusterName) -Fallback "Build $BuildId on cluster $ClusterName was not found") }
        $pollSec = [Math]::Max(1, [int](Get-ClusterDefault -Key 'ClusterBuildPollSec' -Fallback 10))
        $remaining = [int]([Math]::Max(1, $TimeoutSec - ((Get-Date) - $start).TotalSeconds))
        $sleepMs = [Math]::Min($pollSec * 1000, [Math]::Min(1000, $remaining * 1000))
        Start-Sleep -Milliseconds $sleepMs
    }
    [void](Stop-ClusterBuild -BuildId $BuildId -ClusterName $ClusterName -Namespace $Namespace -State $State)
    throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line697' -MessageArgs @([string]$BuildId, [string]$ClusterName, [string]$TimeoutSec) -Fallback "Build $BuildId on cluster $ClusterName timed out after $TimeoutSec seconds")
}

# ── Leader election for coordinator HA ────────────────────────────────────────
function Start-CoordinatorLeaderElection {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    Initialize-ClusterOrchestrator -State $State
    $coord = $script:ClusterConfig.Coordinator
    if ($coord.Type -ne 'leader-election') { return }
    $leaseName = [string]$coord.LeaseName
    $namespace = [string]$coord.LeaseNamespace
    $ttl = [int]$coord.ElectionTTL
    if ($leaseName -notmatch '^[a-z0-9]([-a-z0-9.]{0,61}[a-z0-9])?$' -or -not (Test-ClusterNamespace -Namespace $namespace) -or $ttl -lt 1) { throw (Resolve-LogMessage -Key 'log.clusterorchestrator.line710' -Fallback 'Invalid coordinator lease configuration.') }
    $identity = "$env:COMPUTERNAME-$PID"
    $leaseCluster = @($script:ClusterCache.Values) | Select-Object -First 1
    if (-not $leaseCluster) { $leaseCluster = @{ Kubeconfig = ''; Context = '' } }
    $script:LeaderCancellation = $false
    $script:IsLeader = $false
    while (-not $script:LeaderCancellation) {
        $leader = $false
        try {
            $getResult = Invoke-ClusterKubectl -Cluster $leaseCluster -Arguments @('-n',$namespace,'get','lease',$leaseName,'-o','json') -TimeoutSec (Get-ClusterDefault -Key 'ClusterLeaderTimeoutSec' -Fallback 10) -State $State
            $lease = $null
            if ($getResult.Success) {
                try { $lease = $getResult.Output | ConvertFrom-Json } catch { $lease = $null }
            }
            if ($lease) {
                $holder = [string](Get-SectionValue -Section $lease.spec -Key 'holderIdentity' -Default '')
                $renew = [datetime]::MinValue
                [datetime]::TryParse([string](Get-SectionValue -Section $lease.spec -Key 'renewTime' -Default ''), [ref]$renew) | Out-Null
                $expired = $renew -eq [datetime]::MinValue -or ((Get-Date) - $renew).TotalSeconds -ge $ttl
                if ($holder -eq $identity -or $expired) {
                    $lease.spec.holderIdentity = $identity
                    $lease.spec.leaseDurationSeconds = $ttl
                    $lease.spec.renewTime = (Get-Date).ToUniversalTime().ToString('o')
                    $tempLease = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-lease-' + [guid]::NewGuid().ToString('N') + '.json')
                    try {
                        [System.IO.File]::WriteAllText($tempLease, ($lease | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
                        $replaceResult = Invoke-ClusterKubectl -Cluster $leaseCluster -Arguments @('-n',$namespace,'replace','-f',$tempLease) -TimeoutSec (Get-ClusterDefault -Key 'ClusterLeaderTimeoutSec' -Fallback 10) -State $State
                        $leader = [bool]$replaceResult.Success
                    } finally { if (Test-Path -LiteralPath $tempLease) { Remove-Item -LiteralPath $tempLease -Force -ErrorAction SilentlyContinue } }
                }
            } else {
                $newLease = [PSCustomObject]@{
                    apiVersion = 'coordination.k8s.io/v1'
                    kind = 'Lease'
                    metadata = [PSCustomObject]@{ name = $leaseName; namespace = $namespace }
                    spec = [PSCustomObject]@{ holderIdentity = $identity; leaseDurationSeconds = $ttl; renewTime = (Get-Date).ToUniversalTime().ToString('o') }
                }
                $tempLease = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-lease-' + [guid]::NewGuid().ToString('N') + '.json')
                try {
                    [System.IO.File]::WriteAllText($tempLease, ($newLease | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
                    $createResult = Invoke-ClusterKubectl -Cluster $leaseCluster -Arguments @('-n',$namespace,'create','-f',$tempLease) -TimeoutSec (Get-ClusterDefault -Key 'ClusterLeaderTimeoutSec' -Fallback 10) -State $State
                    $leader = [bool]$createResult.Success
                } finally { if (Test-Path -LiteralPath $tempLease) { Remove-Item -LiteralPath $tempLease -Force -ErrorAction SilentlyContinue } }
            }
            if ($leader) {
                $script:IsLeader = $true
                Write-Log (Resolve-LogMessage -Key 'log.cluster.leaseAcquired' -Fallback '[ClusterOrchestrator] Acquired coordinator lease') 'Succ' $State
                Send-BuildEvent -EventName $EVT_COORDINATOR_LEADER_ACQUIRED -Source $State | Out-Null
                while ($script:IsLeader -and -not $script:LeaderCancellation) {
                    $wait = [Math]::Max(1, [int]$coord.RenewalInterval)
                    for ($i = 0; $i -lt ($wait * 10) -and $script:IsLeader -and -not $script:LeaderCancellation; $i++) { Start-Sleep -Milliseconds 100 }
                    if ($script:LeaderCancellation) { break }
                    $currentResult = Invoke-ClusterKubectl -Cluster $leaseCluster -Arguments @('-n',$namespace,'get','lease',$leaseName,'-o','json') -TimeoutSec (Get-ClusterDefault -Key 'ClusterLeaderTimeoutSec' -Fallback 10) -State $State
                    if (-not $currentResult.Success) { $script:IsLeader = $false; break }
                    try { $current = $currentResult.Output | ConvertFrom-Json } catch { $script:IsLeader = $false; break }
                    if ([string](Get-SectionValue -Section $current.spec -Key 'holderIdentity' -Default '') -ne $identity) { $script:IsLeader = $false; break }
                    $current.spec.renewTime = (Get-Date).ToUniversalTime().ToString('o')
                    $tempRenew = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-lease-' + [guid]::NewGuid().ToString('N') + '.json')
                    try {
                        [System.IO.File]::WriteAllText($tempRenew, ($current | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
                        $renewResult = Invoke-ClusterKubectl -Cluster $leaseCluster -Arguments @('-n',$namespace,'replace','-f',$tempRenew) -TimeoutSec (Get-ClusterDefault -Key 'ClusterLeaderTimeoutSec' -Fallback 10) -State $State
                        if (-not $renewResult.Success) { $script:IsLeader = $false }
                    } finally { if (Test-Path -LiteralPath $tempRenew) { Remove-Item -LiteralPath $tempRenew -Force -ErrorAction SilentlyContinue } }
                }
            }
        } catch {
            Write-Log (Resolve-LogMessage -Key 'log.cluster.leaseError' -MessageArgs @([string]$_) -Fallback '[ClusterOrchestrator] Leader election error: {0}') 'Warn' $State
        }
        if (-not $script:LeaderCancellation) {
            $backoff = [Math]::Max(1, [int](Get-ClusterDefault -Key 'ClusterElectionBackoffSec' -Fallback 5))
            for ($i = 0; $i -lt ($backoff * 10) -and -not $script:LeaderCancellation; $i++) { Start-Sleep -Milliseconds 100 }
        }
    }
}

function Stop-CoordinatorLeaderElection {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $script:LeaderCancellation = $true
    $script:IsLeader = $false
    Write-Log (Resolve-LogMessage -Key 'log.cluster.leaseReleased' -Fallback '[ClusterOrchestrator] Released coordinator lease') 'Info' $State
    Send-BuildEvent -EventName $EVT_COORDINATOR_LEADER_RELEASED -Source $State | Out-Null
}

# ── K8s Operator CRD definitions (for kubebuilder/operator-sdk) ───────────────
function Get-GBuildCRDs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        @'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: buildjobs.gbuild.io
spec:
  group: gbuild.io
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                project:
                  type: string
                builderImage:
                  type: string
                command:
                  type: string
                envVars:
                  type: array
                  items:
                    type: object
                    properties:
                      name: { type: string }
                      value: { type: string }
                resources:
                  type: object
                  properties:
                    requests:
                      type: object
                    limits:
                      type: object
            status:
              type: object
              properties:
                phase:
                  type: string
                buildId:
                  type: string
                cluster:
                  type: string
                startTime:
                  type: string
                completionTime:
                  type: string
  scope: Namespaced
  names:
    plural: buildjobs
    singular: buildjob
    kind: BuildJob
    shortNames: [gbj]
'@
        @'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: buildclusters.gbuild.io
spec:
  group: gbuild.io
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                endpoint:
                  type: string
                region:
                  type: string
                zone:
                  type: string
                capacity:
                  type: object
                  properties:
                    cpu: { type: string }
                    memory: { type: string }
                maxConcurrent:
                  type: integer
            status:
              type: object
              properties:
                phase:
                  type: string
                activeBuilds:
                  type: integer
                lastHeartbeat:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
  scope: Cluster
  names:
    plural: buildclusters
    singular: buildcluster
    kind: BuildCluster
    shortNames: [gbc]
'@
    )
}

function Install-GBuildOperator {
    [CmdletBinding()]
    param(
        [string]$Namespace = 'gbuild-system',
        [string]$Version = '',
        [PSCustomObject]$State
    )
    if (-not (Test-ClusterNamespace -Namespace $Namespace)) { return $false }
    if (-not $Version) {
        $Version = [string](Get-ConfigValue -Path 'build.cluster.operator.version' -State $State -Default '')
        if (-not $Version) { $Version = [string](Get-ConfigValue -Path 'build.cluster.operator.tag' -State $State -Default '') }
    }
    if (-not $Version -or $Version -match '(?i)latest' -or $Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        Write-Log (Resolve-LogMessage -Key 'log.cluster.operatorVersionRequired' -Fallback '[ClusterOrchestrator] An explicit non-latest operator version is required.') 'Err' $State
        return $false
    }
    $cluster = @{ Kubeconfig = ''; Context = '' }
    $allApplied = $true
    foreach ($crd in @(Get-GBuildCRDs)) {
        $tempCrd = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-crd-' + [guid]::NewGuid().ToString('N') + '.yaml')
        try {
            [System.IO.File]::WriteAllText($tempCrd, [string]$crd, (New-Object System.Text.UTF8Encoding($false)))
            $result = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('apply','-f',$tempCrd) -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
            if (-not $result.Success) { $allApplied = $false; Write-Log (Resolve-LogMessage -Key 'log.cluster.crdInstallFailed' -MessageArgs @([string]$result.Output) -Fallback '[ClusterOrchestrator] CRD install failed: {0}') 'Err' $State }
        } finally { if (Test-Path -LiteralPath $tempCrd) { Remove-Item -LiteralPath $tempCrd -Force -ErrorAction SilentlyContinue } }
    }
    if (-not $allApplied) { return $false }
    $operatorYaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gbuild-operator
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gbuild-operator
  template:
    metadata:
      labels:
        app: gbuild-operator
    spec:
      serviceAccountName: gbuild-operator
      containers:
      - name: operator
        image: gbuild/operator:$Version
        env:
        - name: WATCH_NAMESPACE
          value: "$Namespace"
        - name: OPERATOR_NAME
          value: "gbuild-operator"
"@
    $tempOp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-operator-' + [guid]::NewGuid().ToString('N') + '.yaml')
    try {
        [System.IO.File]::WriteAllText($tempOp, $operatorYaml, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-ClusterKubectl -Cluster $cluster -Arguments @('apply','-f',$tempOp) -TimeoutSec (Get-ClusterDefault -Key 'ClusterApplyTimeoutSec' -Fallback 30) -State $State
        if (-not $result.Success) { $allApplied = $false; Write-Log (Resolve-LogMessage -Key 'log.cluster.operatorDeployFailed' -MessageArgs @([string]$result.Output) -Fallback '[ClusterOrchestrator] Operator deploy failed: {0}') 'Err' $State }
        else { Write-Log (Resolve-LogMessage -Key 'log.cluster.operatorDeployed' -MessageArgs @([string]$Namespace) -Fallback '[ClusterOrchestrator] Operator deployed to namespace {0}') 'Succ' $State }
    } finally { if (Test-Path -LiteralPath $tempOp) { Remove-Item -LiteralPath $tempOp -Force -ErrorAction SilentlyContinue } }
    return $allApplied
}

Export-ModuleMember -Function @(
    'Initialize-ClusterOrchestrator',
    'Register-Cluster',
    'Get-Cluster',
    'Get-AllClusters',
    'Get-HealthyClusters',
    'Update-ClusterHeartbeat',
    'Test-ClusterHealth',
    'Start-ClusterHealthMonitor',
    'Select-ClusterForBuild',
    'Submit-ClusterBuild',
    'Get-ClusterBuildStatus',
    'Stop-ClusterBuild',
    'Wait-ClusterBuild',
    'Start-CoordinatorLeaderElection',
    'Stop-CoordinatorLeaderElection',
    'Get-GBuildCRDs',
    'Install-GBuildOperator'
)
