#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:state = New-FullTestState

Describe "Deploy Integration (graceful degradation)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Invoke-DeployGcp returns false (no gcloud) without throwing" {
        { Invoke-DeployGcp -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
        Invoke-DeployGcp -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DeployK8s returns false (no kubectl) without throwing" {
        { Invoke-DeployK8s -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
        Invoke-DeployK8s -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DeployAzureFunctions returns false (no az/func) without throwing" {
        { Invoke-DeployAzureFunctions -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
        Invoke-DeployAzureFunctions -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DeployAwsLambda returns false (no aws) without throwing" {
        { Invoke-DeployAwsLambda -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
        Invoke-DeployAwsLambda -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DockerCiDeploy returns false (ci.docker disabled / no docker) without throwing" {
        { Invoke-DockerCiDeploy -State $global:state -ProjectDir $global:state.ProjectRoot } | Should -Not -Throw
        Invoke-DockerCiDeploy -State $global:state -ProjectDir $global:state.ProjectRoot | Should -BeFalse
    }

    It "Invoke-AzurePipelineTrigger returns false (no az) without throwing" {
        { Invoke-AzurePipelineTrigger -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
        Invoke-AzurePipelineTrigger -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' | Should -BeFalse
    }
}

Describe "Deploy - config-driven success" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop

        function global:az     { $global:LASTEXITCODE = 0 }
        function global:aws    { $global:LASTEXITCODE = 0 }
        function global:vercel { $global:LASTEXITCODE = 0 }
        function global:gcloud { $global:LASTEXITCODE = 0 }
        function global:kubectl {
            $idx = [array]::IndexOf($args, '-f')
            if ($idx -ge 0 -and ($idx + 1) -lt $args.Count) {
                $mf = $args[$idx + 1]
                if (Test-Path -LiteralPath $mf) { $global:k8sManifestContent = (Get-Content -LiteralPath $mf -Raw) }
            }
            $global:LASTEXITCODE = if ($global:k8sRolloutExit -and ($args -contains 'rollout')) { 1 } else { 0 }
        }
        function global:docker { $global:LASTEXITCODE = 0 }
        function global:func   { $global:LASTEXITCODE = 0 }

        $global:td = New-IntegrationTempDir
        $global:publishOut = Join-Path (Join-Path $global:td 'publish-output') 'web'; New-Item -ItemType Directory -Path $global:publishOut -Force | Out-Null
        $global:wfd = Join-Path $global:td 'funcapp'; New-Item -ItemType Directory -Path $global:wfd -Force | Out-Null
        Set-Content -Path (Join-Path $global:wfd 'x.txt') -Value 'x' -Encoding UTF8
        Set-Content -Path (Join-Path $global:td 'Dockerfile') -Value 'FROM scratch' -Encoding UTF8

        $global:manifest = Join-Path (Join-Path $global:td 'k8s') 'deploy.yaml'
        New-Item -ItemType Directory -Path (Split-Path $global:manifest) -Force | Out-Null
        # A real Deployment manifest: Resolve-K8sDeploymentName needs exactly one
        # `kind: Deployment` document to derive the rollout target. A bare
        # `image:` line made the rollout-wait branch unreachable, so the
        # "rollout status fails" case could never actually be exercised.
        Set-Content -Path $global:manifest -Encoding UTF8 -Value @(
            'apiVersion: apps/v1'
            'kind: Deployment'
            'metadata:'
            '  name: web'
            'spec:'
            '  template:'
            '    spec:'
            '      containers:'
            '        - name: web'
            '          image: IMAGE_PLACEHOLDER'
        )

        $global:state = [PSCustomObject]@{
            ProjectRoot = $global:td
            ScriptRoot  = $global:td
            BuildConfig = [PSCustomObject]@{
                deploy = [PSCustomObject]@{
                    azure          = [PSCustomObject]@{ resourceGroup = 'rg'; appName = 'app'; plan = 'p'; location = 'westeurope' }
                    aws            = [PSCustomObject]@{ bucket = 'b'; prefix = 'web'; distributionId = 'E1' }
                    vercel         = [PSCustomObject]@{ project = 'vp' }
                    gcp            = [PSCustomObject]@{ project = 'gp'; service = 'gs'; region = 'us-central1'; image = 'gcr.io/gp/img:latest' }
                    kubernetes     = [PSCustomObject]@{ manifest = 'k8s/deploy.yaml'; imageRepo = 'user/app'; registry = 'docker.io'; namespace = 'default' }
                    azureFunctions = [PSCustomObject]@{ resourceGroup = 'rg'; appName = 'af'; workingDirectory = 'funcapp' }
                    awsLambda      = [PSCustomObject]@{ functionName = 'fn'; region = 'us-east-1'; workingDirectory = 'funcapp' }
                }
                ci = [PSCustomObject]@{
                    docker = [PSCustomObject]@{ enabled = $true; imagePrefix = 'user'; registry = 'docker.io'; autoTag = $false; useGhcr = $false }
                    azure  = [PSCustomObject]@{ projectName = 'azproj'; pipelineFile = 'azure-pipelines.yml'; orgUrl = 'https://dev.azure.com/o' }
                }
            }
        }
    }

    AfterAll {
        Remove-Item function:az -ErrorAction SilentlyContinue
        Remove-Item function:aws -ErrorAction SilentlyContinue
        Remove-Item function:vercel -ErrorAction SilentlyContinue
        Remove-Item function:gcloud -ErrorAction SilentlyContinue
        Remove-Item function:kubectl -ErrorAction SilentlyContinue
        Remove-Item function:docker -ErrorAction SilentlyContinue
        Remove-Item function:func -ErrorAction SilentlyContinue
        if ($global:td -and (Test-Path $global:td)) { Remove-Item $global:td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-DeployConfig returns the azure config object" {
        $mod = Get-Module DeployTargets
        $cfg = $mod.Invoke({ Get-DeployConfig -State $args[0] -Target $args[1] }, @($global:state, 'azure'))
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.appName | Should -BeExactly 'app'
    }

    It "Get-DeployConfig returns null for an unknown target" {
        $mod = Get-Module DeployTargets
        $mod.Invoke({ Get-DeployConfig -State $args[0] -Target $args[1] }, @($global:state, 'nonexistent')) | Should -BeNullOrEmpty
    }

    It "Invoke-DeployAzure returns true when azure+web publish present and az mocked" {
        Invoke-DeployAzure -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployAzure returns false when azure config is missing appName" {
        $incomplete = [PSCustomObject]@{
            ProjectRoot = $global:td
            ScriptRoot  = $global:td
            BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ azure = [PSCustomObject]@{ resourceGroup = 'rg' } } }
        }
        Invoke-DeployAzure -State $incomplete -ProjectDir $global:td -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DeployAws returns true when aws mocked" {
        Invoke-DeployAws -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployVercel returns true when vercel mocked" {
        Invoke-DeployVercel -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployGcp returns true when gcloud mocked" {
        Invoke-DeployGcp -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployK8s returns true and replaces the image placeholder" {
        $global:k8sManifestContent = $null
        $global:k8sRolloutExit = $false
        Invoke-DeployK8s -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
        $global:k8sManifestContent | Should -Not -BeNullOrEmpty
        $global:k8sManifestContent | Should -Not -BeLike "*IMAGE_PLACEHOLDER*"
        $global:k8sManifestContent | Should -BeLike "*user/app*"
    }

    It "Invoke-DeployK8s returns false when rollout status fails" {
        $global:k8sRolloutExit = $true
        Invoke-DeployK8s -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeFalse
        $global:k8sRolloutExit = $false
    }

    It "Invoke-DeployK8s requires an explicit namespace before rollout" {
        $namespaceLess = [PSCustomObject]@{
            ProjectRoot = $global:td
            ScriptRoot = $global:td
            BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ kubernetes = [PSCustomObject]@{ manifest = 'k8s/deploy.yaml'; imageRepo = 'user/app'; registry = 'docker.io' } } }
        }
        Invoke-DeployK8s -State $namespaceLess -ProjectDir $global:td -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DockerCiDeploy returns true when ci.docker enabled and Dockerfile present" {
        Invoke-DockerCiDeploy -State $global:state -ProjectDir $global:td | Should -BeTrue
    }

    It "Invoke-DockerCiDeploy returns false when ci.docker disabled" {
        $disabled = [PSCustomObject]@{
            ProjectRoot = $global:td
            ScriptRoot  = $global:td
            BuildConfig = [PSCustomObject]@{ ci = [PSCustomObject]@{ docker = [PSCustomObject]@{ enabled = $false } } }
        }
        Invoke-DockerCiDeploy -State $disabled -ProjectDir $global:td | Should -BeFalse
    }

    It "Invoke-AzurePipelineTrigger returns true when az mocked" {
        Invoke-AzurePipelineTrigger -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployAzureFunctions returns true when az+func mocked" {
        Invoke-DeployAzureFunctions -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployAwsLambda returns true when aws mocked" {
        Invoke-DeployAwsLambda -State $global:state -ProjectDir $global:td -ProjectType 'Web' | Should -BeTrue
    }

    It "Invoke-DeployAwsLambda rejects an option-like region value" {
        $badRegion = [PSCustomObject]@{ ProjectRoot = $global:td; ScriptRoot = $global:td; BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ awsLambda = [PSCustomObject]@{ functionName = 'fn'; region = '--profile'; workingDirectory = 'funcapp' } } } }
        Invoke-DeployAwsLambda -State $badRegion -ProjectDir $global:td -ProjectType 'Web' | Should -BeFalse
    }

    It "Invoke-DeployAwsLambda rejects a working directory traversal" {
        $bad = [PSCustomObject]@{ ProjectRoot = $global:td; ScriptRoot = $global:td; BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{ awsLambda = [PSCustomObject]@{ functionName = 'fn'; workingDirectory = '..\outside' } } } }
        Invoke-DeployAwsLambda -State $bad -ProjectDir $global:td -ProjectType 'Web' | Should -BeFalse
    }
}

Describe "Deploy - readiness probe (Test-ProcessExited / Test-WebAppReady contracts)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Deploy.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Environment.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Test-WebAppReady is exported and callable" {
        # Assert resolvability ONLY. Invoking Test-WebAppReady bare used to be part
        # of this test, which burned the full production retry budget (30 port
        # probes + 30 URL probes, ~42s) against an empty URL and port 0. The
        # closed-port behaviour is covered by the dedicated test below with an
        # explicit small budget.
        (Get-Command Test-WebAppReady -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Test-ProcessExited returns false when Proc is null" {
        $mod = Get-Module Deploy
        $mod.Invoke({ Test-ProcessExited -Proc $null -State $args[0] }, @($global:state)) | Should -BeFalse
    }

    It "Test-ProcessExited returns true for an already-exited process" {
        $mod = Get-Module Deploy
        # powershell.exe and -WindowStyle are Windows-only. Use the host pwsh
        # elsewhere and only pass -WindowStyle where the parameter exists.
        $onWindows = ($env:OS -eq 'Windows_NT')
        $shell = if ($onWindows) { (Get-Command 'powershell.exe' -ErrorAction Stop).Source } else { (Get-Command 'pwsh' -ErrorAction Stop).Source }
        $spArgs = @{ FilePath = $shell; ArgumentList = '-NoProfile -Command exit 0'; PassThru = $true }
        if ($onWindows) { $spArgs['WindowStyle'] = 'Hidden' }
        $p = Start-Process @spArgs
        $null = $p.WaitForExit(5000)
        $mod.Invoke({ param($Proc, $State) Test-ProcessExited -Proc $Proc -State $State }, @($p, $global:state)) | Should -BeTrue
    }

    It "Test-ProcessExited returns false for a still-running process" {
        $mod = Get-Module Deploy
        $onWindows = ($env:OS -eq 'Windows_NT')
        $shell = if ($onWindows) { (Get-Command 'powershell.exe' -ErrorAction Stop).Source } else { (Get-Command 'pwsh' -ErrorAction Stop).Source }
        $spArgs = @{ FilePath = $shell; ArgumentList = '-NoProfile -Command Start-Sleep 5'; PassThru = $true }
        if ($onWindows) { $spArgs['WindowStyle'] = 'Hidden' }
        $p = Start-Process @spArgs
        try {
            $mod.Invoke({ param($Proc, $State) Test-ProcessExited -Proc $Proc -State $State }, @($p, $global:state)) | Should -BeFalse
        } finally {
            if (-not $p.HasExited) { $p.Kill(); $null = $p.WaitForExit(2000) }
        }
    }

    It "Test-WebAppReady returns false for a closed port without throwing" {
        # Pick a port very unlikely to be in use.
        $probePort = 53123
        # NOTE: call DIRECTLY (not inside { } | Should -Not -Throw): Pester 5
        # runs that scriptblock in an isolated scope so outer assignments do
        # NOT propagate, which vacuous-passes/fails the value assert. A throw
        # here fails the test natively = nothrow guard kept, and $res now
        # holds the REAL return value so the assert is genuine.
        # Explicit small budget: the production default is 30 attempts per phase
        # (~84s against a closed port), which is a production concern, not a test
        # concern. The retry-until-exhausted semantics are unchanged - only the
        # budget is bounded.
        $res = Test-WebAppReady -Proc $null -Url "http://127.0.0.1:$probePort/" -Port $probePort -State $global:state -MaxAttempts 2 -ProbeDelayMs 10 -ProbeDelayMinMs 10
        $res | Should -BeFalse
    }

    It "Test-UrlServing returns false for a closed port without throwing" {
        # Regression guard for the PS 5.1 HttpClient fix: with no listener, the
        # probe must return false (not throw, not hang). Uses a just-released
        # ephemeral port verified closed via Test-PortListening first. There is
        # deliberately NO concurrent in-test server in this suite, so no
        # ephemeral-port collision can flip this to true. (Live-server
        # positive/negative round-trips are verified standalone + by the real
        # WebUI build launching and serving HTTP 200; they are too timing-
        # sensitive for Pester's shared runspace on this machine.)
        # NOTE: call DIRECTLY (not inside { } | Should -Not -Throw): Pester 5
        # runs that scriptblock in an isolated scope so outer assignments do
        # NOT propagate, which vacuous-passes/fails the value assert. A throw
        # here fails the test natively, which is the desired nothrow guard.
        $tmp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $tmp.Start()
        $closedPort = ([System.Net.IPEndPoint]$tmp.LocalEndpoint).Port
        $tmp.Stop()
        if (Test-PortListening -Port $closedPort) {
            Set-ItResult -Skipped -Because "port $closedPort unexpectedly listening; avoiding flake"
            return
        }
        $negRes = [bool](Test-UrlServing -Url "http://127.0.0.1:$closedPort/")
        $negRes | Should -BeFalse
    }
}

Describe "Deploy - configuration validation (Test-DeployTargets)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "returns Overall=$true when no targets are enabled" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ deploy = [PSCustomObject]@{} } }
        $r = Test-DeployTargets -State $state
        $r.Overall | Should -BeTrue
    }

    It "flags an enabled target with missing required fields as invalid" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                deploy = [PSCustomObject]@{
                    aws = [PSCustomObject]@{ enabled = $true }   # missing 'bucket'
                }
            }
        }
        $r = Test-DeployTargets -State $state
        $aws = @($r.Targets | Where-Object { $_.Name -eq 'aws' })[0]
        $aws.Enabled | Should -BeTrue
        $aws.Valid | Should -BeFalse
        $aws.Missing | Should -Contain 'bucket'
        $r.Overall | Should -BeFalse
    }

    It "marks an enabled, fully-configured target as valid" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                deploy = [PSCustomObject]@{
                    aws = [PSCustomObject]@{ enabled = $true; bucket = 'my-bucket' }
                }
            }
        }
        $r = Test-DeployTargets -State $state
        $aws = @($r.Targets | Where-Object { $_.Name -eq 'aws' })[0]
        $aws.Valid | Should -BeTrue
        $r.Overall | Should -BeTrue
    }
}

Describe 'Start-ProjectPublish result propagation' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Deploy.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:publishResultState = [PSCustomObject]@{ ProjectRoot = $TestDrive; ScriptRoot = $TestDrive; BuildConfig = [PSCustomObject]@{} }
        Mock Start-BuildAndShow -ModuleName Deploy -MockWith { return $false }
    }

    It 'returns false instead of discarding a failed build result' {
        Start-ProjectPublish -State $global:publishResultState -ProjPath (Join-Path $TestDrive 'sample.csproj') -Tfm 'net8.0' -OutputSubDir 'default' | Should -BeFalse
    }

    It 'returns a structured failed result in Detailed mode' {
        $result = Start-ProjectPublish -State $global:publishResultState -ProjPath (Join-Path $TestDrive 'sample.csproj') -Tfm 'net8.0' -OutputSubDir 'default' -Detailed
        $result.Status | Should -Be 'Failed'
        $result.ReasonCode | Should -Be 'FalseResult'
    }
}
