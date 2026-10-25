Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/ClusterOrchestrator.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'ClusterOrchestrator' {
    BeforeAll {
        $cfg = Get-Content (Join-Path $PSScriptRoot '../gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:ClusterState = [PSCustomObject]@{ BuildConfig = $cfg }
        Initialize-ClusterOrchestrator -State $script:ClusterState
    }

    It 'Registers clusters and returns arrays (no scalar unrolling)' {
        Register-Cluster -Name 'ut-east' -Endpoint 'https://k8s-east.example.com' -Region 'us-east-1' -State $script:ClusterState
        $all = Get-AllClusters -State $script:ClusterState
        $all -is [array] | Should -BeTrue
        $all.Count | Should -BeGreaterOrEqual 1
        @($all | Where-Object { $_.Name -eq 'ut-east' }).Count | Should -Be 1
    }

    It 'Tracks heartbeats and reports healthy clusters' {
        Update-ClusterHeartbeat -ClusterName 'ut-east' -Status 'Ready' -State $script:ClusterState
        $h = Get-HealthyClusters -State $script:ClusterState
        $h -is [array] | Should -BeTrue
        @($h | Where-Object { $_.Name -eq 'ut-east' }).Count | Should -Be 1
    }

    It 'Survives a partial cluster config' {
        $partial = [PSCustomObject]@{ build = [PSCustomObject]@{ cluster = [PSCustomObject]@{ enabled = $true } } }
        { Initialize-ClusterOrchestrator -State ([PSCustomObject]@{ BuildConfig = $partial }) } | Should -Not -Throw
    }

    It 'Ships valid operator CRDs' {
        $crds = Get-GBuildCRDs
        $crds.Count | Should -Be 2
        foreach ($c in $crds) {
            $c | Should -Match 'kind: CustomResourceDefinition'
        }
    }

    It 'does not evaluate kubectl commands' {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/ClusterOrchestrator.psm1') -Raw
        $source | Should -Not -Match 'Invoke-Expression'
    }

    It 'rejects namespace and context injection values' {
        { Register-Cluster -Name 'bad' -Endpoint 'https://k8s.example.com' -Context 'primary;Write-Output injected' -State $script:ClusterState } | Should -Throw
        { Get-ClusterBuildStatus -BuildId '../job' -ClusterName 'ut-east' -Namespace 'gbuild-jobs' -State $script:ClusterState } | Should -Throw
    }

    It 'requires an explicit non-latest operator version' {
        Install-GBuildOperator -State $script:ClusterState | Should -BeFalse
    }
}
