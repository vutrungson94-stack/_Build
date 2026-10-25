<#
    DeployTargets registry tests (Phase E2).
    Validates Register/Get/Invoke-DeployTarget dispatch without touching real clouds.
#>
$module = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'DeployTargets.psm1'))
Import-Module $module -Force -DisableNameChecking

Describe 'DeployTarget registry' {
    BeforeAll {
        $global:dtState = [PSCustomObject]@{
            ScriptRoot   = $PSScriptRoot
            BuildConfig  = [PSCustomObject]@{ deploy = [PSCustomObject]@{} }
            CorrelationId = 'deploy-test'
        }
    }

    It 'Registers a target and retrieves it by name' {
        Register-DeployTarget -Name 'testTarget' -Function 'Write-Host' -ConfigKey 'testTarget' -RequiredFields @('bucket')
        $t = Get-DeployTarget -Name 'testTarget'
        $t | Should -Not -BeNullOrEmpty
        $t.Name | Should -Be 'testTarget'
        $t.ConfigKey | Should -Be 'testTarget'
        $t.RequiredFields | Should -Contain 'bucket'
    }

    It 'Get-DeployTarget with no name returns all registered targets' {
        $all = @(Get-DeployTarget)
        $all.Count | Should -BeGreaterThan 0
        $all | Should -Contain (Get-DeployTarget -Name 'azure')
    }

    It 'Invoke-DeployTarget returns false for an unknown target' {
        Invoke-DeployTarget -Name 'doesNotExist' -State $global:dtState | Should -Be $false
    }

    It 'Invoke-DeployTarget -DryRun validates config and returns true when required fields present' {
        $global:dtState.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ testTarget = [PSCustomObject]@{ bucket = 'mybucket' } } }
        Invoke-DeployTarget -Name 'testTarget' -State $global:dtState -DryRun | Should -Be $true
    }

    It 'Invoke-DeployTarget returns false when required config missing' {
        $global:dtState.BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ testTarget = [PSCustomObject]@{} } }
        Invoke-DeployTarget -Name 'testTarget' -State $global:dtState | Should -Be $false
    }

    It 'Built-in targets are registered (azure, aws, vercel, kubernetes)' {
        foreach ($n in @('azure','aws','vercel','kubernetes','gcp','azureFunctions','awsLambda','dockerCi','azurePipeline')) {
            Get-DeployTarget -Name $n | Should -Not -BeNullOrEmpty -Because "built-in target '$n' should be registered"
        }
    }
}

Describe 'Invoke-GpgSign graceful gates (opt-in, never breaks a build)' {
    BeforeAll {
        $modRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
        $null = Import-Module (Join-Path $modRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'returns true when gpgSign config is absent' {
        $s = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{}; LogLevel = 3 }
        Invoke-GpgSign -State $s -Path '' | Should -Be $true
    }

    It 'returns true when gpgSign is explicitly disabled' {
        $s = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ gpgSign = [PSCustomObject]@{ enabled = $false } } }
            LogLevel = 3
        }
        Invoke-GpgSign -State $s -Path '' | Should -Be $true
    }

    It 'returns true with a warning when enabled but no artifacts exist' {
        $s = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ gpgSign = [PSCustomObject]@{ enabled = $true } } }
            LogLevel = 3
        }
        $missing = Join-Path $TestDrive 'no-artifacts-here'
        { Invoke-GpgSign -State $s -Path $missing } | Should -Not -Throw
        Invoke-GpgSign -State $s -Path $missing | Should -Be $true
    }
}

Describe 'Invoke-DeployTarget fail-closed result' {
    BeforeAll {
        function global:Invoke-FalseDeployTarget {
            param($State, $ProjectDir, $ProjectType)
            $global:falseDeployProjectDir = $ProjectDir
            $global:falseDeployProjectType = $ProjectType
            return $false
        }
        Register-DeployTarget -Name 'falseTarget' -Function 'Invoke-FalseDeployTarget'
        if (-not (Get-Command Write-AuditLog -ErrorAction SilentlyContinue)) {
            function global:Write-AuditLog { param($Action, $Outcome, $State, $Detail) }
        }
        $global:falseDeployAudits = @()
        Mock Write-AuditLog -ModuleName DeployTargets -MockWith {
            param($Action, $Outcome, $State, $Detail)
            $global:falseDeployAudits += [PSCustomObject]@{ Action = $Action; Outcome = $Outcome; Detail = $Detail }
        }
    }

    It 'returns false, audits Failed, and does not emit Completed' {
        $global:falseDeployAudits = @()
        $result = Invoke-DeployTarget -Name 'falseTarget' -State $global:dtState -ProjectDir 'project-dir' -ProjectType 'Web'
        $result | Should -BeFalse
        $global:falseDeployProjectDir | Should -Be 'project-dir'
        $global:falseDeployProjectType | Should -Be 'Web'
        $global:falseDeployAudits | Should -Not -BeNullOrEmpty
        @($global:falseDeployAudits | Where-Object { $_.Outcome -eq 'Failed' }).Count | Should -BeGreaterThan 0
        @($global:falseDeployAudits | Where-Object { $_.Outcome -eq 'Completed' }).Count | Should -Be 0
    }

    It 'returns a structured Failed result in Detailed mode' {
        $structured = Invoke-DeployTarget -Name 'falseTarget' -State $global:dtState -Detailed
        $structured | Should -BeOfType [PSCustomObject]
        $structured.Status | Should -Be 'Failed'
        Test-RequiredResult -Result $structured | Should -BeFalse
    }

    It 'runs rollback and returns false for a failed deploy' {
        $global:rollbackRan = $false
        $result = Invoke-DeployWithRollback -State $global:dtState -TargetName 'falseTarget' -RollbackAction { $global:rollbackRan = $true }
        $result | Should -BeFalse
        $global:rollbackRan | Should -BeTrue
    }

    AfterAll {
        Remove-Item function:Invoke-FalseDeployTarget -ErrorAction SilentlyContinue
        Remove-Variable -Name falseDeployProjectDir,falseDeployProjectType,falseDeployAudits -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-K8sDeploymentName reads the manifest Deployment' {
    It 'returns the Deployment metadata name' {
        $path = Join-Path $TestDrive 'deploy.yaml'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value "apiVersion: apps/v1`nkind: Deployment`nmetadata:`n  name: web-api`n"
        Resolve-K8sDeploymentName -ManifestPath $path | Should -Be 'web-api'
    }

    It 'ignores non-Deployment documents and rejects ambiguous manifests' {
        $path = Join-Path $TestDrive 'multi.yaml'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value "kind: Service`nmetadata:`n  name: web-svc`n---`nkind: Deployment`nmetadata:`n  name: web-api`n"
        Resolve-K8sDeploymentName -ManifestPath $path | Should -Be 'web-api'
        $ambiguous = Join-Path $TestDrive 'ambiguous.yaml'
        Set-Content -LiteralPath $ambiguous -Encoding UTF8 -Value "kind: Deployment`nmetadata:`n  name: one`n---`nkind: Deployment`nmetadata:`n  name: two`n"
        Resolve-K8sDeploymentName -ManifestPath $ambiguous | Should -Be ''
    }
}
