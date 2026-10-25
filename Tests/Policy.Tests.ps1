#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Policy.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "Policy-as-code (OPA + built-in, Level 5)" {
    It "Get-PolicyConfig returns $null when State has no policy section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        Get-PolicyConfig -State $state | Should -BeNullOrEmpty
    }

    It "Get-PolicyConfig reads the security.policy section correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; enforcement = 'block' } } } }
        $cfg = Get-PolicyConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.enforcement | Should -Be 'block'
    }

    It "Get-PolicyInput does not leak secrets and contains the build config subset" {
        $state = [PSCustomObject]@{
            ProjectRoot = $TestDrive
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{ defaultConfiguration = 'Debug'; enableParallel = $true; enableIncremental = $false; apiKey = 'SUPER-SECRET' }
            }
        }
        $policyInput = Get-PolicyInput -State $state -ProjectDir $TestDrive -ProjectType 'Web'
        $json = $policyInput | ConvertTo-Json -Depth 10
        $json | Should -Not -Match 'SUPER-SECRET'
        $policyInput.build.defaultConfiguration | Should -Be 'Debug'
        $policyInput.project.name | Should -Be (Split-Path $TestDrive -Leaf)
    }

    It "Get-PolicyDir honors an absolute path from config" {
        $dir = Join-Path $TestDrive 'opa-policy'
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ dir = $dir } } } }
        Get-PolicyDir -State $state | Should -Be $dir
    }

    It "Get-PolicyDir resolves a relative path against the project root" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ dir = 'policy' } } } }
        Get-PolicyDir -State $state | Should -Be (Join-Path $TestDrive 'policy')
    }

    It "Invoke-OpaPolicy returns Skipped when the policy dir has no .rego files" {
        $policyDir = Join-Path $TestDrive 'policy'
        New-Item -ItemType Directory -Path $policyDir -Force | Out-Null
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ dir = $policyDir } } } }
        $policyInput = Get-PolicyInput -State $state -ProjectDir $TestDrive
        $r = Invoke-OpaPolicy -State $state -InputObject $policyInput -ProjectDir $TestDrive
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'No Rego'
    }

    It "Invoke-OpaPolicy returns Skipped when OPA CLI is not installed but .rego files exist" {
        # Inverted guard: this test exercises the NO-opa path, so skip when opa IS installed.
        if (Test-OpaAvailable) { Set-ItResult -Skipped -Because 'opa is installed' }
        $policyDir = Join-Path $TestDrive 'policy'
        New-Item -ItemType Directory -Path $policyDir -Force | Out-Null
        Set-Content -Path (Join-Path $policyDir 'test.rego') -Value 'package gbuild.policy' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ dir = $policyDir } } } }
        $policyInput = Get-PolicyInput -State $state -ProjectDir $TestDrive
        $r = Invoke-OpaPolicy -State $state -InputObject $policyInput -ProjectDir $TestDrive
        $r.Status | Should -Be 'Failed'
        $r.Pass | Should -BeFalse
        $r.Reason | Should -Match 'opa CLI not installed'
    }

    It "Invoke-BuiltinPolicy is Passed when no rule is violated" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; rules = @([PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny' }) } } } }
        $policyInput = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Release' }; project = [PSCustomObject]@{ name = 'demo' } }
        $r = Invoke-BuiltinPolicy -State $state -InputObject $policyInput
        $r.Status | Should -Be 'Passed'
        $r.Violations.Count | Should -Be 0
    }

    It "Invoke-BuiltinPolicy is Blocked when a deny rule matches the value" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; rules = @([PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny' }) } } } }
        $policyInput = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Debug'; enableParallel = $true }; project = [PSCustomObject]@{ name = 'demo'; type = 'Web' } }
        $r = Invoke-BuiltinPolicy -State $state -InputObject $policyInput
        $r.Status | Should -Be 'Blocked'
        $r.Violations.Count | Should -BeGreaterThan 0
        $r.Violations[0].Rule | Should -Be 'no-debug-builds'
    }

    It "Invoke-BuiltinPolicy does not allow allow rules to bypass deny" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; rules = @(
            [PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny' },
            [PSCustomObject]@{ rule = 'allow-debug-local'; match = 'build.defaultConfiguration=*'; action = 'allow' }
        ) } } } }
        $policyInput = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Debug' }; project = [PSCustomObject]@{ name = 'demo' } }
        $r = Invoke-BuiltinPolicy -State $state -InputObject $policyInput
        $r.Status | Should -Be 'Blocked'
    }

    It "Invoke-PolicyChecks returns Skipped when security.policy.enabled=false" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $false; enforcement = 'block' } } } }
        $r = Invoke-PolicyChecks -State $state -ProjectDir $TestDrive
        $r.Status | Should -Be 'Skipped'
        $r.Pass | Should -BeTrue
    }

    It "Invoke-PolicyChecks with enforcement=block makes Pass=false on builtin violations" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Debug' }; security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; enforcement = 'block'; dir = (Join-Path $TestDrive 'builtin-policy-block'); rules = @([PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny' }) } } }; BuildConfigFallback = $null }
        $r = Invoke-PolicyChecks -State $state -ProjectDir $TestDrive
        $r.Status | Should -Be 'Blocked'
        $r.Pass | Should -BeFalse
        $r.Backend | Should -Be 'builtin'
    }

    It "Invoke-PolicyChecks with enforcement=warn still Pass=true on violations" {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Debug' }; security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; enforcement = 'warn'; dir = (Join-Path $TestDrive 'builtin-policy-warn'); rules = @([PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny' }) } } } }
        $r = Invoke-PolicyChecks -State $state -ProjectDir $TestDrive
        $r.Status | Should -Be 'Warned'
        $r.Pass | Should -BeTrue
        $r.Violations.Count | Should -BeGreaterThan 0
    }

    It "Invoke-BuiltinPolicy honors excludePaths for single-source files" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; rules = @([PSCustomObject]@{ rule = 'no-debug-builds'; path = 'build.defaultConfiguration'; value = 'Debug'; action = 'deny'; excludePaths = @('build.defaultConfiguration') }) } } } }
        $policyInput = [PSCustomObject]@{ build = [PSCustomObject]@{ defaultConfiguration = 'Debug' } }
        $r = Invoke-BuiltinPolicy -State $state -InputObject $policyInput
        $r.Status | Should -Be 'Passed'
        $r.Violations.Count | Should -Be 0
    }
}

Describe 'Policy - P0 fail-closed regressions' {
    It 'returns Failed for configured OPA when the CLI is unavailable' {
        if (Test-OpaAvailable) { Set-ItResult -Skipped -Because 'opa is installed' }
        $dir = Join-Path $TestDrive 'rego-failure'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'policy.rego') -Value 'package gbuild.policy' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; enforcement = 'block'; dir = $dir } } } }
        $r = Invoke-PolicyChecks -State $state -ProjectDir $TestDrive
        $r.Status | Should -Be 'Failed'
        $r.Pass | Should -BeFalse
    }
    It 'evaluates FileContent rules against source files' {
        $root = Join-Path $TestDrive 'file-content-policy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'unsafe.cs') -Value 'password = "not-allowed"' -Encoding UTF8
        $state = [PSCustomObject]@{ ProjectRoot = $root; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true; enforcement = 'block'; dir = (Join-Path $root 'empty'); rules = @([PSCustomObject]@{ rule = 'no-hardcoded'; match = 'FileContent'; path = '**/*.cs'; value = '(?i)password\s*='; action = 'deny' }) } } } }
        $result = Invoke-PolicyChecks -State $state -ProjectDir $root
        $result.Status | Should -Be 'Blocked'
        $result.Pass | Should -BeFalse
    }
    It 'keeps secret fields out of OPA input' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ apiKey = 'do-not-send' } } }
        $input = Get-PolicyInput -State $state -ProjectDir $TestDrive
        ($input | ConvertTo-Json -Depth 10) | Should -Not -Match 'do-not-send'
    }

    It 'Test-PolicyPathMatch supports comma-separated multi-globs' {
        # Config rules separate alternatives with commas. The matcher used to
        # treat the whole string as ONE -like pattern, so a comma rule could
        # never match a real filename and the rule was silently dead.
        Test-PolicyPathMatch -Value 'src/a.ps1' -Pattern '**/*.ps1,**/*.psm1' | Should -BeTrue
        Test-PolicyPathMatch -Value 'Modules/Cache.psm1' -Pattern '**/*.ps1,**/*.psm1' | Should -BeTrue
        Test-PolicyPathMatch -Value 'src/a.cs' -Pattern '**/*.ps1,**/*.psm1' | Should -BeFalse
        Test-PolicyPathMatch -Value 'src/a.ps1' -Pattern '**/*.ps1' | Should -BeTrue
        Test-PolicyPathMatch -Value 'anything' -Pattern '' | Should -BeTrue
    }

    It 'reports FileContent violations per line with file:line locations' {
        $root = Join-Path $TestDrive 'policy-lines'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'a.ps1') -Value ('x = 1', 'password = "abc12345"', 'password = "def67890"' -join "`n") -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true } } } }
        $input = [PSCustomObject]@{ project = [PSCustomObject]@{ path = $root; name = 'demo' } }
        $rule = [PSCustomObject]@{ rule = 'no-hardcoded'; match = 'FileContent'; path = '**/*.ps1'; value = '(?i)password\s*='; action = 'deny' }
        $found = @(Get-PolicyRuleMatches -Rule $rule -InputObject $input -ProjectDir $root)
        $found.Count | Should -Be 2
        $found[0].Line | Should -Be 2
        $found[1].Line | Should -Be 3
    }

    It 'shipped path/port patterns ignore PSDrives and timeout magnitudes' {
        # Reads the SHIPPED patterns (not copies) so the test fails if the
        # config regresses: function:/Env: are PowerShell drives, never disk
        # paths, and a bare 5000 is a timeout, not a port.
        $shipCfg = Get-Content -LiteralPath (Join-Path $global:GBuildModuleRoot '../gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $rules = @($shipCfg.security.policy.rules)
        $pathsValue = @($rules | Where-Object { $_.rule -eq 'DenyHardcodedPaths' })[0].value
        $portsValue = @($rules | Where-Object { $_.rule -eq 'DenyHardcodedPorts' })[0].value
        $pathsValue | Should -Not -BeNullOrEmpty
        $portsValue | Should -Not -BeNullOrEmpty
        $root = Join-Path $TestDrive 'policy-shipped-patterns'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'clean.ps1') -Value ('Get-Item "function:\$fn"', 'Remove-Item Env:\$key -ErrorAction SilentlyContinue', '$TimeoutMilliseconds = 5000' -join "`n") -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'dirty.ps1') -Value ('$p = "C:\Temp\x"', '$url = "http://localhost:8080/api"', '$Port = 8080' -join "`n") -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true } } } }
        $input = [PSCustomObject]@{ project = [PSCustomObject]@{ path = $root; name = 'demo' } }
        $pathsRule = [PSCustomObject]@{ rule = 'DenyHardcodedPaths'; match = 'FileContent'; path = '**/*.ps1'; value = $pathsValue; action = 'deny' }
        $portsRule = [PSCustomObject]@{ rule = 'DenyHardcodedPorts'; match = 'FileContent'; path = '**/*.ps1'; value = $portsValue; action = 'deny' }
        $pathHits = @(Get-PolicyRuleMatches -Rule $pathsRule -InputObject $input -ProjectDir $root)
        $portHits = @(Get-PolicyRuleMatches -Rule $portsRule -InputObject $input -ProjectDir $root)
        @($pathHits | Where-Object { $_.Key -like '*clean.ps1' }).Count | Should -Be 0
        @($portHits | Where-Object { $_.Key -like '*clean.ps1' }).Count | Should -Be 0
        @($pathHits | Where-Object { $_.Key -like '*dirty.ps1' }).Count | Should -BeGreaterThan 0
        @($portHits | Where-Object { $_.Key -like '*dirty.ps1' }).Count | Should -BeGreaterThan 0
    }
}
