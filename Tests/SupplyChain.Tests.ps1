#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Supply Chain (SBOM / Provenance / Sign / Scan)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SupplyChain.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:scTemp = New-IntegrationTempDir
        $global:scSrc = Join-Path $global:scTemp 'src'
        $global:scPub = Join-Path $global:scTemp 'publish'
        $global:scReports = Join-Path $global:scTemp 'build-reports'
        New-Item -ItemType Directory -Path $global:scSrc -Force | Out-Null
        New-Item -ItemType Directory -Path $global:scPub -Force | Out-Null
        New-Item -ItemType Directory -Path $global:scReports -Force | Out-Null

        Set-Content -Path (Join-Path $global:scSrc 'MyApp.csproj') -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
    <PackageReference Include="Serilog" Version="3.1.1" />
  </ItemGroup>
</Project>
'@
        Set-Content -Path (Join-Path $global:scSrc 'package.json') -Value @'
{ "dependencies": { "react": "^18.2.0" }, "devDependencies": { "typescript": "~5.3.0" } }
'@
        Set-Content -Path (Join-Path $global:scSrc 'requirements.txt') -Value "flask==3.0.0`nrequests>=2.31.0`n"
        Set-Content -Path (Join-Path $global:scSrc 'Cargo.toml') -Value @'
[dependencies]
serde = "1.0.0"
'@
        Set-Content -Path (Join-Path $global:scSrc 'go.mod') -Value @'
module example.com/myapp
go 1.21
require github.com/gorilla/mux v1.8.0
'@
        Set-Content -Path (Join-Path $global:scPub 'MyApp.dll') -Value 'binary payload'

        $sec = @{
            sbom = @{ enabled = $true; format = 'cyclonedx' }
            provenance = @{ enabled = $true }
            artifactSign = @{ enabled = $false; tool = 'cosign'; key = ''; identity = ''; images = @() }
            containerScan = @{ enabled = $false; images = @(); severity = 'HIGH,CRITICAL'; failOnSeverity = 'CRITICAL' }
        }
        $cfg = @{ build = @{}; report = @{ outputDir = 'build-reports' }; releases = @{ repo = 'https://github.com/example/project'; builder = @{ id = 'https://github.com/example/project/_Build'; type = 'https://github.com/example/project/.github/workflows/build.yml' } }; security = $sec; paths = @{ publishOutput = $null } }
        $global:scState = [PSCustomObject]@{ ScriptRoot = $global:scTemp; BuildConfig = $cfg }
    }
    AfterAll {
        if ($global:scTemp -and (Test-Path $global:scTemp)) { Remove-Item $global:scTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'Dependency inventory' {
        It "Discovers .csproj automatically from ProjectDir" {
            $inv = Get-DependencyInventory -ProjectDir $global:scSrc
            @($inv | Where-Object { $_.Group -eq '.NET' }).Count | Should -Be 2
            $inv | Where-Object { $_.Name -eq 'Newtonsoft.Json' } | Should -Not -BeNullOrEmpty
        }

        It "Parses npm, pip, cargo and go manifests" {
            $inv = Get-DependencyInventory -ProjectDir $global:scSrc
            @($inv | Where-Object { $_.Group -eq 'npm' }).Count | Should -Be 2
            @($inv | Where-Object { $_.Group -eq 'pip' }).Count | Should -Be 2
            @($inv | Where-Object { $_.Group -eq 'cargo' -and $_.Name -eq 'serde' }).Count | Should -Be 1
            @($inv | Where-Object { $_.Group -eq 'go' -and $_.Name -eq 'github.com/gorilla/mux' }).Count | Should -Be 1
        }

        It "Returns empty for an empty directory" {
            $empty = Join-Path $global:scTemp 'empty'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            @(Get-DependencyInventory -ProjectDir $empty).Count | Should -Be 0
        }
    }

    Context 'Artifact digest' {
        It "Is deterministic and changes with content" {
            $d1 = Get-ArtifactDigest -Path $global:scPub
            $d2 = Get-ArtifactDigest -Path $global:scPub
            $d1 | Should -Be $d2
            $d1 | Should -Match '^[a-f0-9]{64}$'
            Set-Content -Path (Join-Path $global:scPub 'extra.txt') -Value 'added'
            $d3 = Get-ArtifactDigest -Path $global:scPub
            $d3 | Should -Not -Be $d1
            Remove-Item -Path (Join-Path $global:scPub 'extra.txt') -Force
        }

        It "Returns null for a missing path" {
            Get-ArtifactDigest -Path (Join-Path $global:scTemp 'nope') | Should -BeNullOrEmpty
        }
    }

    Context 'SBOM' {
        It "Generates a CycloneDX 1.4 document with components" {
            $sbomPath = Join-Path $global:scReports 'sbom.json'
            $sbom = New-BuildSbom -State $global:scState -ProjectDir $global:scSrc -ProjectName 'MyApp' -SbomPath $sbomPath
            $sbom.bomFormat | Should -Be 'CycloneDX'
            $sbom.specVersion | Should -Be '1.4'
            @($sbom.components).Count | Should -BeGreaterThan 0
            @($sbom.components | Where-Object { $_.name -eq 'Newtonsoft.Json' }).Count | Should -Be 1
            Test-Path $sbomPath | Should -BeTrue
            (Get-Content $sbomPath -Raw | ConvertFrom-Json).bomFormat | Should -Be 'CycloneDX'
        }
    }

    Context 'Provenance' {
        It "Generates an in-toto v0.1 / SLSA v0.2 statement with matching digest" {
            $provPath = Join-Path $global:scReports 'provenance.json'
            $prov = New-BuildProvenance -State $global:scState -SubjectName 'MyApp' -SubjectPath $global:scPub -ProvenancePath $provPath
            $prov._type | Should -Be 'https://in-toto.io/Statement/v0.1'
            $prov.predicateType | Should -Be 'https://slsa.dev/provenance/v0.2'
            $prov.subject[0].digest.sha256 | Should -Be (Get-ArtifactDigest -Path $global:scPub)
            Test-Path $provPath | Should -BeTrue
        }
    }

    Context 'Artifact signing' {
        It "Gracefully skips when disabled in config" {
            $r = Invoke-ArtifactSign -State $global:scState -ArtifactDir $global:scPub
            $r.Status | Should -Be 'Skipped'
            $r.Reason | Should -Match 'enabled is false'
        }

        It "Gracefully skips when the signing tool is missing" {
            $sec = @{
                sbom = @{ enabled = $false }
                provenance = @{ enabled = $false }
                artifactSign = @{ enabled = $true; tool = 'cosign-not-installed'; key = ''; identity = ''; images = @() }
                containerScan = @{ enabled = $false }
            }
            $cfg = @{ security = $sec }
            $st = [PSCustomObject]@{ ScriptRoot = $global:scTemp; BuildConfig = $cfg }
            $r = Invoke-ArtifactSign -State $st -ArtifactDir $global:scPub
            $r.Status | Should -Be 'Failed'
            $r.Pass | Should -BeFalse
            $r.Reason | Should -Match 'unavailable|not installed'
        }
    }

    Context 'Container scanning' {
        It "Gracefully skips when disabled in config" {
            $r = Invoke-ContainerScan -State $global:scState -LocalDir $global:scPub
            $r.Status | Should -Be 'Skipped'
            $r.Pass | Should -BeTrue
        }

        It "Blocks on a CRITICAL vulnerability found by trivy" {
            function global:trivy {
                param($cmd, $argsList)
                @{ Results = @(
                    @{ Vulnerabilities = @(
                        @{ VulnerabilityID = 'CVE-2026-0001'; Severity = 'CRITICAL'; PkgName = 'libssl'; FixedVersion = '1.1.1w' },
                        @{ VulnerabilityID = 'CVE-2026-0002'; Severity = 'HIGH'; PkgName = 'zlib'; FixedVersion = '1.3.1' }
                    ) }
                ) } | ConvertTo-Json -Depth 10
            }
            $sec = @{
                sbom = @{ enabled = $false }
                provenance = @{ enabled = $false }
                artifactSign = @{ enabled = $false }
                containerScan = @{ enabled = $true; images = @(); severity = 'HIGH,CRITICAL'; failOnSeverity = 'CRITICAL' }
            }
            $cfg = @{ security = $sec }
            $st = [PSCustomObject]@{ ScriptRoot = $global:scTemp; BuildConfig = $cfg }
            $r = Invoke-ContainerScan -State $st -LocalDir $global:scPub
            $r.Status | Should -Be 'Blocked'
            $r.Pass | Should -BeFalse
            $r.Critical | Should -Be 1
            $r.High | Should -Be 1
        }
    }

    Context 'Orchestrator' {
        It "Generates SBOM + provenance and passes when scans are disabled" {
            $res = Invoke-SupplyChainChecks -State $global:scState -ProjectDir $global:scSrc -PublishOutput $global:scPub
            $res.Sbom | Should -BeTrue
            $res.Provenance | Should -BeTrue
            $res.Pass | Should -BeTrue
            $res.Checks | Where-Object { $_.Name -eq 'SBOM' } | ForEach-Object { $_.Status | Should -Be 'Generated' }
            $res.Checks | Where-Object { $_.Name -eq 'Provenance' } | ForEach-Object { $_.Status | Should -Be 'Generated' }
            @($res.Artifacts).Count | Should -Be 2
        }

        It "Fails the whole check set when a scan blocks" {
            function global:trivy {
                param($cmd, $argsList)
                @{ Results = @(
                    @{ Vulnerabilities = @(
                        @{ VulnerabilityID = 'CVE-2026-0009'; Severity = 'CRITICAL'; PkgName = 'libc'; FixedVersion = '2.39' }
                    ) }
                ) } | ConvertTo-Json -Depth 10
            }
            $sec = @{
                sbom = @{ enabled = $false }
                provenance = @{ enabled = $false }
                artifactSign = @{ enabled = $false }
                containerScan = @{ enabled = $true; images = @(); severity = 'HIGH,CRITICAL'; failOnSeverity = 'CRITICAL' }
            }
            $cfg = @{ security = $sec }
            $st = [PSCustomObject]@{ ScriptRoot = $global:scTemp; BuildConfig = $cfg }
            $res = Invoke-SupplyChainChecks -State $st -ProjectDir $global:scSrc -PublishOutput $global:scPub
            $res.Pass | Should -BeFalse
            $res.ContainerScan.Status | Should -Be 'Blocked'
        }
    }

    Context 'SBOM policy gate' {
        BeforeAll {
            $global:scSbom = @{
                bomFormat  = 'CycloneDX'
                specVersion = '1.4'
                components = @(
                    @{ name = 'Newtonsoft.Json'; version = '13.0.3' }
                    @{ name = 'Serilog'; version = '3.1.1' }
                )
            }
        }

        It "Skipped when no SBOM is provided" {
            $r = Invoke-SbomPolicyGate -State $global:scState -Sbom $null
            $r.Pass | Should -BeFalse
            $r.Status | Should -Be 'Failed'
        }

        It "Skipped when security.sbom is not configured" {
            $r = Invoke-SbomPolicyGate -State $global:scState -Sbom $global:scSbom
            $r.Status | Should -Be 'Skipped'
        }

        It "Skipped when policy is disabled" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $false; allowList = @(); denyList = @(); enforcement = 'warn' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            $r.Pass | Should -BeTrue
            $r.Status | Should -Be 'Skipped'
            $r.Reason | Should -Match 'enabled is false'
        }

        It "Skipped when no allowList/denyList is configured" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @(); denyList = @(); enforcement = 'warn' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            $r.Status | Should -Be 'Skipped'
        }

        It "Warns (not blocks) on denyList violation with warn enforcement" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @(); denyList = @('Serilog'); enforcement = 'warn' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            $r.Pass | Should -BeTrue
            $r.Status | Should -Be 'Warned'
            @($r.Violations).Count | Should -Be 1
            $r.Violations[0].Component | Should -Be 'Serilog'
        }

        It "Blocks on denyList violation with block enforcement" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @(); denyList = @('Serilog'); enforcement = 'block' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            $r.Pass | Should -BeFalse
            $r.Status | Should -Be 'Blocked'
            @($r.Violations).Count | Should -Be 1
        }

        It "Throws on denyList violation with fail enforcement" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @(); denyList = @('Serilog'); enforcement = 'fail' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            { Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom } | Should -Throw 'SBOM policy*'
        }

        It "Flags components not present in the allowList" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @('Newtonsoft.Json'); denyList = @(); enforcement = 'warn' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            @($r.Violations) | Where-Object { $_.Component -eq 'Serilog' } | Should -Not -BeNullOrEmpty
        }

        It "Passes when every component is in the allowList" {
            $cfg = @{ security = @{ sbom = @{ policy = @{ enabled = $true; allowList = @('Newtonsoft.Json', 'Serilog'); denyList = @(); enforcement = 'warn' } } } }
            $st = [PSCustomObject]@{ BuildConfig = $cfg }
            $r = Invoke-SbomPolicyGate -State $st -Sbom $global:scSbom
            $r.Pass | Should -BeTrue
            $r.Status | Should -Be 'Passed'
        }
    }

    Context 'Compliance report' {
        It "Writes compliance-report.json with tenant and supply-chain summary" {
            $st = [PSCustomObject]@{
                ScriptRoot = $global:scTemp
                TenantId   = 'acme'
                BuildConfig = @{ report = @{ outputDir = 'build-reports' }; security = @{} }
            }
            $summary = @{
                Pass      = $false
                Checks    = @(@{ Name = 'SBOM'; Status = 'Generated'; Path = (Join-Path $global:scReports 'sbom.json') })
                Artifacts = @(@{ Name = 'MyApp.dll' })
            }
            $license = @(@{ Package = 'Serilog'; License = 'MIT'; Status = 'Denied' })
            $path = Export-ComplianceReport -State $st -Summary $summary -LicenseResult $license
            $path | Should -Not -BeNullOrEmpty
            Test-Path $path | Should -BeTrue
            $report = Get-Content $path -Raw | ConvertFrom-Json
            $report.tool | Should -Be 'gbuild'
            $report.tenant | Should -Be 'acme'
            $report.supplyChain.pass | Should -BeFalse
            $report.license.count | Should -Be 1
            $report.license.violations[0].Package | Should -Be 'Serilog'
        }
    }
}

Describe 'SupplyChain - P0 fail-closed regressions' {
    It 'discovers nested lockfiles and rejects empty SBOM inventories' {
        $root = Join-Path $TestDrive 'nested-supply'
        New-Item -ItemType Directory -Path (Join-Path $root 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'nested/package-lock.json') -Value '{"lockfileVersion":3,"packages":{"node_modules/nested-lib":{"version":"1.0.0"}}}' -Encoding UTF8
        $inventory = @(Get-DependencyInventory -ProjectDir $root)
        $inventory.Name | Should -Contain 'nested-lib'
        $state = [PSCustomObject]@{ ProjectRoot = $root; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
        { New-BuildSbom -State $state -ProjectDir (Join-Path $root 'empty') } | Should -Throw
    }
    It 'fails closed when signing is enabled but its tool is absent' {
        $state = [PSCustomObject]@{ ProjectRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ artifactSign = [PSCustomObject]@{ enabled = $true; tool = 'definitely-missing-signer' } } } }
        $result = Invoke-ArtifactSign -State $state -ArtifactDir $TestDrive
        $result.Status | Should -Be 'Failed'
        $result.Pass | Should -BeFalse
    }

    It 'Get-DependencyInventory throws instead of inventorying the CWD' {
        # The old fallback recursively scanned the launch directory, so an SBOM
        # built without an explicit project directory attested the WRONG tree.
        $origLoc = $PWD.Path
        $cwd = New-IntegrationTempDir
        try {
            Set-Location -LiteralPath $cwd
            Set-Content -LiteralPath (Join-Path $cwd 'package.json') -Value '{"name":"decoy"}' -Encoding UTF8
            { Get-DependencyInventory } | Should -Throw
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
