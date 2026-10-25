# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
<#
.SYNOPSIS
    Supply-chain hardening for gbuild: SBOM (CycloneDX), SLSA provenance,
    artifact signing (cosign/notation) and container image scanning (trivy).
.DESCRIPTION
    All features are config-driven and graceful-degrade: if the external tool
    (cosign/notation/trivy) is not installed, or the publish folder is missing,
    the module logs Warn and returns status 'Skipped' instead of crashing the build.
#>

# -- Import Logging + SharedUtils + PathUtils (root-selection helper) --
Import-BuildModule -Dependencies @('SharedUtils', 'PathUtils', 'BuildProgress')
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Get-OSPlatform'


# Private helper: resolves project short name with standalone fallback.
function Get-SupplyChainProjectName {
    param([PSCustomObject]$State, [string]$Default = 'gbuild-project')

Set-StrictMode -Version 1.0
    if (Get-Command Get-ProjectShortName -ErrorAction SilentlyContinue) {
        $result = Get-ProjectShortName -State $State -Default $Default
        if ($result) { return $result }
    }
    if ($State -and $State.ProjectRoot) { return (Split-Path $State.ProjectRoot -Leaf) }
    return $Default
}

function Get-SupplyChainSection {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Section)
    $sec = Get-ConfigSection -State $State -Path 'security'
    if ($sec) {
        $has = if ($sec -is [System.Collections.IDictionary]) {
            $sec.ContainsKey($Section)
        } else {
            $sec.PSObject.Properties.Name -contains $Section
        }
        if ($has) { return $sec.$Section }
    }
    return $null
}

function Get-SupplyChainReportDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    return Get-ReportDirectory -State $State
}








<#
.SYNOPSIS
    Exports the aggregated compliance report for audit purposes.
.DESCRIPTION
    Writes build-reports/compliance-report.json: supply-chain check statuses,
    artifact list, license violations. Runs only when called with a valid State.
#>
function Export-ComplianceReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [hashtable]$Summary,
        [object[]]$LicenseResult
    )
    $reportDir = Get-SupplyChainReportDir -State $State
    if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { $null = Invoke-EnsureDirectory -Path $reportDir } elseif (-not (Test-Path $reportDir -PathType Container)) { New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null }
    $tenant = if ($State -and $State.TenantId) { [string]$State.TenantId } else { 'default' }

    $sbomPath = $null
    $checks = @()
    $artifacts = @()
    $pass = $null
    if ($Summary) {
        if ($Summary.ContainsKey('Pass'))      { $pass = [bool]$Summary['Pass'] }
        if ($Summary.ContainsKey('Checks'))    { $checks = @($Summary['Checks']) }
        if ($Summary.ContainsKey('Artifacts')) { $artifacts = @($Summary['Artifacts']) }
        $sbomCheck = @($checks | Where-Object { $_.Name -eq 'SBOM' }) | Select-Object -First 1
        if ($sbomCheck -and $sbomCheck.Path) { $sbomPath = $sbomCheck.Path }
    }

    $report = @{
        generatedAt   = (Get-Date).ToString('o')
        # Level 5 single-source: SupplyChainToolName (supplyChain.toolName).
        tool          = (Get-BuildConstant -Key 'SupplyChainToolName' -State $State -Fallback 'gbuild')
        tenant        = $tenant
        correlationId = if ($State -and $State.CorrelationId) { [string]$State.CorrelationId } else { '' }
        supplyChain   = @{
            pass      = $pass
            checks    = $checks
            sbomPath  = $sbomPath
            artifacts = $artifacts
        }
        license       = @{
            violations = @($LicenseResult)
            count      = @($LicenseResult).Count
        }
    }
    $path = Join-Path $reportDir 'compliance-report.json'
    # JSON write single-sourced via SharedUtils.Write-BuildJsonFile.
    $null = Write-BuildJsonFile -Path $path -Data $report -Depth 10
    return $path
}


function Get-SupplyChainCommand {
    [CmdletBinding()]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\x00;]') { return $null }
    return (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Write-SupplyChainJson {
    [CmdletBinding()]
    param([string]$Path, [object]$Data)
    # SharedUtils.Write-BuildJsonFile -Atomic is the owner; the inline
    # Replace-with-null-backup fallback this replaces could not have worked
    # (File.Replace treats $null as an empty backup path and throws).
    $ok = [bool](Write-BuildJsonFile -Path $Path -Data $Data -Depth 30 -Atomic)
    if (-not $ok -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line134' -Fallback 'Supply-chain report could not be written.')) }
    try { $null = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop } catch { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line135' -Fallback 'Supply-chain report verification failed.')) }
    return $Path
}

function Get-DependencyInventory {
    [CmdletBinding()]
    param([string]$ProjectDir, [string]$ProjectFile, [PSCustomObject]$State = $null)
    $deps = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    # Fail closed: the old final arm scanned the process CWD, so an SBOM built
    # without an explicit project directory silently inventoried the WRONG tree
    # (whatever the launcher ran from) and CI attested it. The sole production
    # caller passes -ProjectDir explicitly; anything else is a bug.
    $root = if ($ProjectDir) { $ProjectDir } elseif ($ProjectFile) { Split-Path $ProjectFile -Parent } else { '' }
    if ([string]::IsNullOrWhiteSpace($root) -and $State -and (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue)) { $root = Get-BuildRootDirectory -State $State }
    if ([string]::IsNullOrWhiteSpace($root)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line150' -Fallback 'Dependency inventory root is undetermined: pass -ProjectDir (or -ProjectFile). Refusing to inventory the current directory.')) }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { $errors.Add('project directory is unavailable'); $script:LastDependencyInventoryErrors = @($errors); return @() }
    # Was a hand-written literal; routed through the shared config-aware accessor.
    $scExclude = ''
    if (Get-Command Get-SecurityExcludeDirPattern -ErrorAction SilentlyContinue) { $scExclude = [string](Get-SecurityExcludeDirPattern) }
    if ([string]::IsNullOrWhiteSpace($scExclude)) { $scExclude = '[\\/](_Build|node_modules|bin|obj|\.git)[\\/]' }
    $allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop | Where-Object { $_.FullName -notmatch $scExclude })
    if ($ProjectFile) { $allFiles += @(Get-Item -LiteralPath $ProjectFile -ErrorAction SilentlyContinue) }
    $manifestNames = @('package.json','package-lock.json','npm-shrinkwrap.json','yarn.lock','pnpm-lock.yaml','bun.lockb','deno.lock','composer.json','composer.lock','requirements.txt','requirements-dev.txt','requirements-prod.txt','pyproject.toml','setup.py','setup.cfg','Pipfile','Pipfile.lock','poetry.lock','Cargo.toml','Cargo.lock','go.mod','go.sum','Gemfile','Gemfile.lock','pom.xml','build.gradle','build.gradle.kts','build.sbt','Directory.Packages.props','packages.lock.json','Package.resolved','gradle.lockfile')
    $files = @($allFiles | Where-Object { $_.Extension -in @('.csproj','.fsproj','.vbproj','.props','.targets','.nuspec') -or $_.Name -in $manifestNames -or $_.Name -like '*.lock' -or $_.Name -like '*.lockb' } | Sort-Object FullName -Unique)
    $add = {
        param([string]$Name, [string]$Version, [string]$Group)
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $deps.Add([PSCustomObject]@{ Name = $Name; Version = $Version; Group = $Group; Type = 'library' }) }
    }
    foreach ($file in $files) {
        $parseFailed = $false
        $seenDotNet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            if ($file.Extension -in @('.csproj','.fsproj','.vbproj','.props','.targets','.nuspec')) {
                $null = [xml]$text
                foreach ($m in [regex]::Matches($text, '<(?:PackageReference|PackageDownload|Reference)\s+[^>]*(?:Include|Update)\s*=\s*["'']([^"'']+)["''][^>]*?(?:Version|VersionOverride)\s*=\s*["'']([^"'']*)["'']')) { if ($seenDotNet.Add($m.Groups[1].Value)) { & $add $m.Groups[1].Value $m.Groups[2].Value '.NET' } }
                foreach ($m in [regex]::Matches($text, '<(?:PackageReference|PackageDownload|Reference)\s+[^>]*(?:Include|Update)\s*=\s*["'']([^"'']+)["'']')) { if ($m.Groups[0].Value -notmatch 'Version' -and $seenDotNet.Add($m.Groups[1].Value)) { & $add $m.Groups[1].Value '' '.NET' } }
            } elseif ($file.Extension -eq '.json' -or $file.Name -in @('package-lock.json','npm-shrinkwrap.json','composer.lock','packages.lock.json')) {
                # npm lockfile v2/v3 has an empty-string package key (""), which
                # Windows PowerShell 5.1 cannot represent via ConvertFrom-Json.
                # Parse canonical node_modules entries directly for npm locks.
                if ($file.Name -in @('package-lock.json','npm-shrinkwrap.json')) {
                    foreach ($m in [regex]::Matches($text, '(?ms)"node_modules/((?:@[^/"]+/)?[^"]+)"\s*:\s*\{.{0,2000}?"version"\s*:\s*"([^"]+)"')) {
                        & $add $m.Groups[1].Value $m.Groups[2].Value 'npm'
                    }
                } else {
                    $json = $text | ConvertFrom-Json -ErrorAction Stop
                    foreach ($section in @('dependencies','devDependencies','peerDependencies','optionalDependencies','require','require-dev','packages')) {
                        if ($json.PSObject.Properties.Name -contains $section -and $json.$section -and $json.$section.PSObject.Properties) {
                            foreach ($property in $json.$section.PSObject.Properties) {
                                $name = [string]$property.Name
                                if ($name -like 'node_modules/*') { $name = $name.Substring($name.LastIndexOf('node_modules/') + 13) }
                                if ($name -and $name -ne '') {
                                    $version = if ($property.Value -is [string]) { [string]$property.Value } elseif ($property.Value.PSObject.Properties.Name -contains 'version') { [string]$property.Value.version } else { '' }
                                    & $add $name $version $(if ($file.Name -like '*composer*') { 'composer' } else { 'npm' })
                                }
                            }
                        }
                    }
                }
            } elseif ($file.Name -eq 'yarn.lock' -or $file.Name -eq 'pnpm-lock.yaml') {
                foreach ($m in [regex]::Matches($text, '(?m)^\s*"?(@?[^"\s:]+(?:/[^"\s:]+)?)@')) { & $add $m.Groups[1].Value '' 'npm' }
            } elseif ($file.Name -like 'requirements*.txt' -or $file.Name -eq 'setup.py') {
                foreach ($line in ($text -split "`n")) { if ($line -match '^\s*([A-Za-z0-9_.-]+)\s*(?:[<>=!~]|$)') { & $add $matches[1] '' 'pip' } }
            } elseif ($file.Name -in @('Cargo.toml','Cargo.lock')) {
                foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:name\s*=\s*["'']([^"'']+)["''])|^([A-Za-z0-9_.-]+)\s*=\s*["'']')) { $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }; $version = ''; $vm = [regex]::Match($m.Value, '=\s*["'']([^"'']+)["'']'); if ($vm.Success) { $version = $vm.Groups[1].Value }; & $add $name $version 'cargo' }
            } elseif ($file.Name -eq 'go.mod' -or $file.Name -eq 'go.sum') {
                foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:require\s+)?([A-Za-z0-9._~/-]+)\s+(v[0-9][^\s]*)')) { & $add $m.Groups[1].Value $m.Groups[2].Value 'go' }
            } elseif ($file.Name -in @('Gemfile','Gemfile.lock')) {
                foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:gem\s+)?["'']([A-Za-z0-9_.-]+)["'']')) { & $add $m.Groups[1].Value '' 'ruby' }
            } else {
                foreach ($m in [regex]::Matches($text, '<artifactId>\s*([^<]+?)\s*</artifactId>|(?:implementation|api|compile)\s+["'']([^:"'']+):([^:"'']+)')) { $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }; $version = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '' }; & $add $name $version 'jvm' }
            }
        } catch { $parseFailed = $true }
        if ($parseFailed) { $errors.Add($file.FullName) }
    }
    $script:LastDependencyInventoryErrors = @($errors)
    return @($deps | Sort-Object Group,Name,Version -Unique)
}

function New-BuildSbom {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectName, [string]$ProjectVersion = '0.0.0', [string]$SbomPath)
    $components = [System.Collections.Generic.List[object]]::new()
    foreach ($dependency in @(Get-DependencyInventory -ProjectDir $ProjectDir)) { $components.Add([ordered]@{ type = 'library'; name = [string]$dependency.Name; version = [string]$dependency.Version; group = [string]$dependency.Group }) }
    # An inventory ERROR is a real failure. An inventory that is merely EMPTY is
    # not: a dependency-free project (plain console app, no PackageReference) is
    # a legitimate CycloneDX document with zero components. The previous code
    # threw on both, so SBOM generation - a blocking, default-enabled gate -
    # made every dependency-free project unbuildable.
    if (@($script:LastDependencyInventoryErrors).Count -gt 0) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line226' -Fallback 'SBOM dependency inventory could not be read.')) }
    if (-not $ProjectName) { $ProjectName = Get-SupplyChainProjectName -State $State }
    $tool = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'SupplyChainToolName' -State $State -Fallback 'gbuild') } else { 'gbuild' }
    $sbom = [ordered]@{ bomFormat = 'CycloneDX'; specVersion = '1.4'; serialNumber = 'urn:uuid:' + [guid]::NewGuid().ToString('N'); version = 1; metadata = [ordered]@{ timestamp = (Get-Date).ToString('o'); component = [ordered]@{ type = 'application'; name = $ProjectName; version = $ProjectVersion }; tools = @([ordered]@{ vendor = $tool; name = $tool }) }; components = @($components) }
    if ($SbomPath) { [void](Write-SupplyChainJson -Path $SbomPath -Data $sbom) }
    return $sbom
}

function Get-SupplyChainProvenanceValue {
    param([PSCustomObject]$State, [string]$Path)
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { return [string](Get-ConfigValue -Path $Path -State $State -Default '') }
    return ''
}

function New-BuildProvenance {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$SubjectName, [string]$SubjectPath, [string]$ProvenancePath)
    if ([string]::IsNullOrWhiteSpace($SubjectName) -or -not $SubjectPath -or -not (Test-Path -LiteralPath $SubjectPath)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line243' -Fallback 'Provenance subject is unavailable.')) }
    $repo = Get-SupplyChainProvenanceValue -State $State -Path 'releases.repo'
    $builder = Get-SupplyChainProvenanceValue -State $State -Path 'releases.builder.id'
    $buildType = Get-SupplyChainProvenanceValue -State $State -Path 'releases.builder.type'
    # Source metadata that is UNCONFIGURED (empty, or still an unresolved
    # ${env:...} placeholder) means the operator never asked for provenance -
    # that is a skip, not a violation. Source metadata that is present but
    # UNSAFE (localhost / loopback) is a genuine finding and still throws.
    $unconfigured = @($repo, $builder, $buildType) | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '\$\{env:' }
    if ($unconfigured.Count -gt 0) {
        Write-Log (Resolve-LogMessage -Key 'log.supplychain.provenanceSkipped' -Fallback '[SUPPLYCHAIN] Provenance skipped: releases.repo / releases.builder are not configured (set GBUILD_GITHUB_REPO to enable).') 'Gray' $State
        return $null
    }
    foreach ($value in @($repo, $builder, $buildType)) { if ($value -match '(?i)localhost|127\.0\.0\.1|\[::1\]') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line256' -Fallback 'Provenance source metadata is unsafe.')) } }
    # Declared fallbacks for genuinely unknown provenance source metadata. These
    # keys existed with no consumer, so the 'unknown' placeholder was spelled
    # differently in three places.
    $unknownRepo = [string](Get-BuildConstant -Key 'SupplyChainUnknownRepo' -State $State -Fallback 'unknown')
    $unknownBuildType = [string](Get-BuildConstant -Key 'SupplyChainUnknownBuildType' -State $State -Fallback 'unknown')
    $digest = Get-ArtifactDigest -Path $SubjectPath
    if ([string]::IsNullOrWhiteSpace($digest)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line263' -Fallback 'Provenance subject digest is unavailable.')) }
    $corr = if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId' -and $State.CorrelationId) { [string]$State.CorrelationId } else { [guid]::NewGuid().ToString('N') }
    $statement = [ordered]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @([ordered]@{ name = $SubjectName; digest = [ordered]@{ sha256 = $digest } }); predicateType = 'https://slsa.dev/provenance/v0.2'; predicate = [ordered]@{ builder = [ordered]@{ id = $builder }; buildType = $buildType; invocation = [ordered]@{ configSource = [ordered]@{ uri = $repo }; parameters = [ordered]@{ correlationId = $corr } }; buildConfig = [ordered]@{ os = if ($State -and $State.PSObject.Properties.Name -contains 'OS' -and $State.OS) { [string]$State.OS } else { $unknownRepo } }; metadata = [ordered]@{ buildInvocationID = $corr; completeness = [ordered]@{ parameters = $true; environment = $false; materials = $false }; reproducible = $false }; materials = @([ordered]@{ uri = $repo; digest = [ordered]@{} }) } }
    if ($ProvenancePath) { [void](Write-SupplyChainJson -Path $ProvenancePath -Data $statement) }
    # L5 transparency: best-effort chained entry for this attestation. Silent
    # by design (never changes the statement verdict): gives
    # Write-TransparencyLogEntry a production caller in this same module.
    try { [void](Write-TransparencyLogEntry -Statement $statement -State $State) } catch { }
    return $statement
}

function Invoke-SupplyChainTool {
    param([string]$Tool, [string[]]$Arguments, [string]$WorkingDirectory, [PSCustomObject]$State, [int]$TimeoutSec = 120)
    $command = Get-SupplyChainCommand -Name $Tool
    if (-not $command) { return @{ Available = $false; ExitCode = 127; Output = ''; TimedOut = $false } }
    try {
        if ($command.CommandType -eq 'Application' -and (Get-Command Invoke-WithLiveOutput -ErrorAction SilentlyContinue)) {
            $result = Invoke-WithLiveOutput -FilePath $command.Source -ArgList $Arguments -State $State -Label "supply-chain $Tool" -WorkingDir $WorkingDirectory -Quiet -TimeoutSec $TimeoutSec
            return @{ Available = $true; ExitCode = [int]$result.ExitCode; Output = @($result.Output) -join "`n"; TimedOut = [bool]$result.TimedOut }
        }
        Push-Location -LiteralPath $WorkingDirectory
        try { $baseline = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue)) { [int]$LASTEXITCODE } else { 0 }; $output = (& $Tool @Arguments 2>&1 | Out-String); $exitCode = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) -and [int]$LASTEXITCODE -ne $baseline) { [int]$LASTEXITCODE } else { 0 }; return @{ Available = $true; ExitCode = $exitCode; Output = [string]$output; TimedOut = $false } } finally { Pop-Location }
    } catch { return @{ Available = $true; ExitCode = 1; Output = ''; TimedOut = $false } }
}

function Invoke-ArtifactSign {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ArtifactDir)
    $cfg = Get-SupplyChainSection -State $State -Section 'artifactSign'
    if (-not $cfg -or -not (Get-SectionValue -Section $cfg -Key 'enabled' -Default $false)) { return @{ Status = 'Skipped'; Pass = $true; Reason = 'security.artifactSign.enabled is false'; Tool = ''; Count = 0 } }
    $tool = [string](Get-SectionValue -Section $cfg -Key 'tool' -Default 'cosign')
    $command = Get-SupplyChainCommand -Name $tool
    # DELIBERATE fail-closed, and checked BEFORE the key test: signing is enabled,
    # so a missing signing tool is a hard failure regardless of key state.
    # Covered by SupplyChain.Tests.ps1 ("P0 fail-closed regressions" / "fails
    # closed when signing is enabled but its tool is absent"). Do not weaken this -
    # to make signing optional, turn security.artifactSign.enabled off in config.
    if (-not $command) { return @{ Status = 'Failed'; Pass = $false; Reason = 'signing tool unavailable'; Tool = $tool; Count = 0 } }
    $key = [string](Get-SectionValue -Section $cfg -Key 'key' -Default '')
    if ($key -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) { $key = [string](Resolve-EnvPlaceholder -Text $key) }
    # Reached only when the tool IS installed. An unconfigured signing key (still
    # an unresolved ${env:...} placeholder, or blank) means signing was never
    # requested: skip rather than block. Without this, the shipped default -
    # artifactSign.enabled=true with a ${env:...} key placeholder - blocked EVERY
    # build on any machine without a configured cosign keypair.
    if ($tool -ne 'notation' -and [string]::IsNullOrWhiteSpace($key)) {
        return @{ Status = 'Skipped'; Pass = $true; Reason = 'no signing key configured (security.artifactSign.key)'; Tool = $tool; Count = 0 }
    }
    $signed = 0
    # Supply-chain signing/verdict must not depend on the launch directory: a
    # cosign/SBOM tool that resolves signatures or policy.json by CWD would read
    # the wrong inputs and could produce a false Pass. Anchor on the artifact dir
    # when present, else on the single-source build root - never Get-Location.
    $toolWorkDir = if ($ArtifactDir -and (Test-Path -LiteralPath $ArtifactDir -PathType Container)) { [string]$ArtifactDir }
                   elseif (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State }
                   else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line318' -Fallback 'Supply-chain tool working directory is undetermined: no artifact directory and PathUtils is unavailable.')) }
    if ($tool -eq 'notation') {
        $images = @(Get-SectionValue -Section $cfg -Key 'images' -Default @() | Where-Object { $_ })
        if ($images.Count -eq 0) { return @{ Status = 'Skipped'; Pass = $true; Reason = 'no images configured'; Tool = $tool; Count = 0 } }
        foreach ($image in $images) {
            if ([string]$image -match '\$\{env:') { continue }
            $sign = Invoke-SupplyChainTool -Tool $tool -Arguments @('sign', [string]$image) -WorkingDirectory $toolWorkDir -State $State
            $verify = Invoke-SupplyChainTool -Tool $tool -Arguments @('verify', [string]$image) -WorkingDirectory $toolWorkDir -State $State
            if (-not $sign.Available -or $sign.ExitCode -ne 0 -or $verify.ExitCode -ne 0) { return @{ Status = 'Failed'; Pass = $false; Reason = 'signing verification failed'; Tool = $tool; Count = $signed } }
            $signed++
        }
    } else {
        if (-not $ArtifactDir -or -not (Test-Path -LiteralPath $ArtifactDir -PathType Container)) { return @{ Status = 'Failed'; Pass = $false; Reason = 'publish output unavailable'; Tool = $tool; Count = 0 } }
        $files = @(Get-ChildItem -LiteralPath $ArtifactDir -Recurse -File -ErrorAction Stop)
        if ($files.Count -eq 0) { return @{ Status = 'Skipped'; Pass = $true; Reason = 'no artifacts to sign'; Tool = $tool; Count = 0 } }
        foreach ($file in $files) {
            $args = @('sign-blob'); if ($key) { $args += @('--key',$key) }; $signature = $file.FullName + '.sig'; $args += @('--output-signature',$signature,$file.FullName)
            $sign = Invoke-SupplyChainTool -Tool $tool -Arguments $args -WorkingDirectory $file.DirectoryName -State $State
            if (-not $sign.Available -or $sign.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $signature -PathType Leaf)) { return @{ Status = 'Failed'; Pass = $false; Reason = 'artifact signing failed'; Tool = $tool; Count = $signed } }
            $verifyArgs = @('verify-blob'); if ($key) { $verifyArgs += @('--key',$key) }; $verifyArgs += @('--signature',$signature,$file.FullName)
            $verify = Invoke-SupplyChainTool -Tool $tool -Arguments $verifyArgs -WorkingDirectory $file.DirectoryName -State $State
            if ($verify.ExitCode -ne 0) { return @{ Status = 'Failed'; Pass = $false; Reason = 'signature verification failed'; Tool = $tool; Count = $signed } }
            $signed++
        }
    }
    return @{ Status = 'Passed'; Pass = $true; Reason = ''; Tool = $tool; Count = $signed }
}

function Invoke-ContainerScan {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$LocalDir)
    $cfg = Get-SupplyChainSection -State $State -Section 'containerScan'
    if (-not $cfg -or -not (Get-SectionValue -Section $cfg -Key 'enabled' -Default $false)) { return @{ Status = 'Skipped'; Pass = $true; Reason = 'disabled'; Critical = 0; High = 0; Findings = @(); Tool = ''; Errors = 0 } }
    $tool = [string](Get-SectionValue -Section $cfg -Key 'tool' -Default (Get-BuildConstant -Key 'TrivyToolName' -Fallback 'trivy'))
    $command = Get-SupplyChainCommand -Name $tool
    # DELIBERATE fail-closed, symmetric with Invoke-ArtifactSign: a gate that is
    # ENABLED must actually evaluate. A missing scanner is not "no findings", it
    # is "no verdict" - skipping it would let a release ship an unscanned image
    # that reads as clean. The posture is consistent across supply-chain gates:
    #   enabled + tool present  -> run it, block on real findings
    #   enabled + tool missing  -> BLOCK (cannot verify what you asked for)
    #   disabled                -> skip
    # To make scanning optional on a machine without the scanner, set
    # security.containerScan.enabled = false (the shipped default).
    if (-not $command) { return @{ Status = 'Failed'; Pass = $false; Reason = 'container scanner unavailable'; Critical = 0; High = 0; Findings = @(); Tool = $tool; Errors = 1 } }
    $images = @(Get-SectionValue -Section $cfg -Key 'images' -Default @() | Where-Object { $_ })
    $targets = @($images)
    if ($LocalDir -and (Test-Path -LiteralPath $LocalDir -PathType Container)) { $targets += $LocalDir }
    if ($targets.Count -eq 0) { return @{ Status = 'Skipped'; Pass = $true; Reason = 'no scan targets'; Critical = 0; High = 0; Findings = @(); Tool = $tool; Errors = 0 } }
    $severity = [string](Get-SectionValue -Section $cfg -Key 'severity' -Default 'HIGH,CRITICAL')
    $failOn = [string](Get-SectionValue -Section $cfg -Key 'failOnSeverity' -Default 'CRITICAL')
    # Same anchoring rule as Invoke-ArtifactSign: the scanner working directory is
    # the single-source build root, never the launch directory.
    $scanWorkDir = if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State }
                   else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line372' -Fallback 'Container scan working directory is undetermined: PathUtils is unavailable.')) }
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = 0
    foreach ($target in $targets) {
        if ([string]$target -match '\$\{env:') { $errors++; continue }
        $kind = if ($targets.IndexOf($target) -lt $images.Count) { 'image' } else { 'fs' }
        $result = Invoke-SupplyChainTool -Tool $tool -Arguments @($kind,'--severity',$severity,'--format','json',[string]$target) -WorkingDirectory $scanWorkDir -State $State
        if (-not $result.Available -or $result.TimedOut -or $result.ExitCode -ne 0) { $errors++; continue }
        try {
            $report = $result.Output | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $report -or -not ($report.PSObject.Properties.Name -contains 'Results')) { throw (Resolve-LogMessage -Key 'log.supplychain.line382' -Fallback 'invalid report') }
            foreach ($item in @($report.Results)) { foreach ($v in @($item.Vulnerabilities)) { if ($null -ne $v) { $findings.Add([PSCustomObject]@{ Severity = [string]$v.Severity; Id = [string]$v.VulnerabilityID; Pkg = [string]$v.PkgName; Fixed = [string]$v.FixedVersion }) } } }
        } catch { $errors++ }
    }
    $critical = @($findings | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
    $high = @($findings | Where-Object { $_.Severity -eq 'HIGH' }).Count
    $failRank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity $failOn) } else { 0 }
    if ($failRank -le 0) { $errors++; $failRank = 3 }
    $blocked = @($findings | Where-Object { $rank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity ([string]$_.Severity)) } else { 0 }; $rank -ge $failRank }).Count -gt 0
    $pass = $errors -eq 0 -and -not $blocked
    return @{ Status = if ($pass) { 'Passed' } else { 'Blocked' }; Pass = $pass; Reason = ''; Critical = $critical; High = $high; Findings = @($findings); Tool = $tool; Errors = $errors }
}

function Invoke-SbomPolicyGate {
    [CmdletBinding()]
    param([PSCustomObject]$State, $Sbom)
    if (-not $Sbom) { return @{ Pass = $false; Violations = @(); Status = 'Failed'; Reason = 'No SBOM to evaluate' } }
    $cfg = Get-SupplyChainSection -State $State -Section 'sbom'
    $policy = if ($cfg) { Get-SectionValue -Section $cfg -Key 'policy' -Default $null } else { $null }
    if (-not $cfg -or -not $policy -or -not (Get-SectionValue -Section $policy -Key 'enabled' -Default $false)) { return @{ Pass = $true; Violations = @(); Status = 'Skipped'; Reason = 'security.sbom.policy.enabled is false' } }
    $components = @($Sbom.components)
    # Zero components means there is nothing the policy could possibly violate
    # (a dependency-free project). That is a pass, not a block: the previous
    # code failed the build, so any project without PackageReference could not
    # pass the default-enabled SBOM policy gate.
    if ($components.Count -eq 0) { return @{ Pass = $true; Violations = @(); Status = 'Skipped'; Reason = 'SBOM has no components to evaluate' } }
    $allow = @(Get-SectionValue -Section $policy -Key 'allowList' -Default @() | Where-Object { $_ })
    $deny = @(Get-SectionValue -Section $policy -Key 'denyList' -Default @() | Where-Object { $_ })
    $enforcement = [string](Get-SectionValue -Section $policy -Key 'enforcement' -Default 'block')
    if ($allow.Count -eq 0 -and $deny.Count -eq 0) { return @{ Pass = $true; Violations = @(); Status = 'Skipped'; Reason = 'No allowList/denyList configured' } }
    $violations = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $components) {
        $name = [string]$component.name
        $denied = @($deny | Where-Object { $name -like ([string]$_) }).Count -gt 0
        $allowed = $allow.Count -eq 0 -or @($allow | Where-Object { $name -like ([string]$_) }).Count -gt 0
        if ($denied) { $violations.Add([PSCustomObject]@{ Component = $name; Version = [string]$component.version; Reason = 'Denied by policy' }) }
        elseif (-not $allowed) { $violations.Add([PSCustomObject]@{ Component = $name; Version = [string]$component.version; Reason = 'Not in allowlist' }) }
    }
    if ($violations.Count -gt 0) {
        if ($enforcement -eq 'fail') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.supplychain.line421' -Fallback 'SBOM policy failed.')) }
        if ($enforcement -eq 'warn') { return @{ Pass = $true; Violations = @($violations); Status = 'Warned'; Reason = '' } }
        return @{ Pass = $false; Violations = @($violations); Status = 'Blocked'; Reason = '' }
    }
    return @{ Pass = $true; Violations = @(); Status = 'Passed'; Reason = '' }
}

function Invoke-SupplyChainChecks {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$PublishOutput)
    $pass = $true
    $checks = [System.Collections.Generic.List[object]]::new()
    $artifacts = [System.Collections.Generic.List[string]]::new()
    $reportDir = Get-SupplyChainReportDir -State $State
    $sbomCfg = Get-SupplyChainSection -State $State -Section 'sbom'
    $provCfg = Get-SupplyChainSection -State $State -Section 'provenance'
    if ($sbomCfg -and (Get-SectionValue -Section $sbomCfg -Key 'enabled' -Default $false)) {
        try {
            $path = Join-Path $reportDir 'sbom.json'
            # The SBOM must carry the project's real version - the csproj is the
            # single source of truth. Omitting -ProjectVersion made every SBOM
            # report 0.0.0, so the supply-chain evidence did not identify which
            # build it belonged to.
            $projectVersion = ''
            try { Import-ModuleOnDemand -ModuleNames @('Versioning') } catch { }
            if (Get-Command Get-CurrentVersion -ErrorAction SilentlyContinue) {
                try { $projectVersion = [string](Get-CurrentVersion -State $State).Version } catch { $projectVersion = '' }
            }
            if ([string]::IsNullOrWhiteSpace($projectVersion)) {
                try { $projectVersion = [string](Get-VersionValue -State $State).Version } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($projectVersion)) { $projectVersion = '0.0.0' }

            $sbom = New-BuildSbom -State $State -ProjectDir $ProjectDir -ProjectName (Get-SupplyChainProjectName -State $State) -ProjectVersion $projectVersion -SbomPath $path
            $artifacts.Add($path)
            $checks.Add([PSCustomObject]@{ Name = 'SBOM'; Status = 'Generated'; Path = $path })
            $gate = Invoke-SbomPolicyGate -State $State -Sbom $sbom
            $checks.Add([PSCustomObject]@{ Name = 'SbomPolicy'; Status = $gate.Status; Path = '' })
            if (-not $gate.Pass) { $pass = $false }
        } catch { $pass = $false; $checks.Add([PSCustomObject]@{ Name = 'SBOM'; Status = 'Failed'; Path = '' }) }
    }
    if ($provCfg -and (Get-SectionValue -Section $provCfg -Key 'enabled' -Default $false)) {
        # A run that produces NO local artifact cannot be attested, and that is
        # not a supply-chain violation. Menu actions 13 (trigger GitHub Actions),
        # N (promote an existing environment), Z (chaos), M (anomaly report) and
        # X (distributed) deliberately write nothing into publish-output. This
        # block used to `throw 'publish output unavailable'`, which the catch
        # turned into Status=Failed and $pass=$false - so the DEFAULT-ENABLED
        # supply-chain step failed EVERY such build even though the build was
        # correct. Provenance is skipped with a stated reason instead; a genuine
        # attestation failure against a subject that DOES exist still fails.
        if (-not $PublishOutput -or -not (Test-Path -LiteralPath $PublishOutput -PathType Container)) {
            $checks.Add([PSCustomObject]@{ Name = 'Provenance'; Status = 'Skipped'; Path = ''; Reason = 'no local artifact to attest' })
        } else {
            try {
                $path = Join-Path $reportDir 'provenance.json'
                $prov = New-BuildProvenance -State $State -SubjectName (Get-SupplyChainProjectName -State $State -Default 'artifact') -SubjectPath $PublishOutput -ProvenancePath $path
                if ($null -eq $prov) {
                    # New-BuildProvenance returns $null when releases.* is unconfigured.
                    $checks.Add([PSCustomObject]@{ Name = 'Provenance'; Status = 'Skipped'; Path = ''; Reason = 'releases.repo / releases.builder not configured' })
                } else {
                    $artifacts.Add($path)
                    $checks.Add([PSCustomObject]@{ Name = 'Provenance'; Status = 'Generated'; Path = $path; Reason = '' })
                }
            } catch { $pass = $false; $checks.Add([PSCustomObject]@{ Name = 'Provenance'; Status = 'Failed'; Path = ''; Reason = $_.Exception.Message }) }
        }
    }
    $sign = Invoke-ArtifactSign -State $State -ArtifactDir $PublishOutput
    $checks.Add([PSCustomObject]@{ Name = 'ArtifactSign'; Status = $sign.Status; Path = '' })
    if (-not $sign.Pass) { $pass = $false }
    $scan = Invoke-ContainerScan -State $State -LocalDir $PublishOutput
    $checks.Add([PSCustomObject]@{ Name = 'ContainerScan'; Status = $scan.Status; Path = '' })
    if (-not $scan.Pass) { $pass = $false }
    $summary = [ordered]@{ Pass = $pass; Checks = @($checks); Sbom = [bool]($sbomCfg -and (Get-SectionValue -Section $sbomCfg -Key 'enabled' -Default $false)); Provenance = [bool]($provCfg -and (Get-SectionValue -Section $provCfg -Key 'enabled' -Default $false)); Sign = $sign; ContainerScan = $scan; Artifacts = @($artifacts) }
    if ($summary.Sbom -or $summary.Provenance -or $sign.Status -ne 'Skipped' -or $scan.Status -ne 'Skipped') {
        try { $summary.ComplianceReport = Export-ComplianceReport -State $State -Summary $summary -LicenseResult @() } catch { $summary.ComplianceReport = ''; $summary.Pass = $false }
    }
    return $summary
}

function Resolve-TransparencyLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    # Next to the other supply-chain reports (no new config key, no schema
    # change): the transparency ledger lives where provenance.json lives.
    $dir = Get-SupplyChainReportDir -State $State
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    return (Join-Path $dir 'transparency-log.jsonl')
}

<#
.SYNOPSIS
    Appends a hash-chained transparency entry for a provenance statement.
.DESCRIPTION
    L5 supply-chain (Rekor-style, local-first): each entry binds
    { index, statementHash, prevHash } under entryHash, so a trimmed or
    reordered log is detectable without a remote server. The statement hash
    uses SharedUtils.Get-BuildStringHash (never an inline digest). File errors
    return $false instead of throwing; callers treat this as best-effort.
#>
function Write-TransparencyLogEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Statement, [PSCustomObject]$State = $null)
    try {
        $path = Resolve-TransparencyLogPath -State $State
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $depth = 20
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $depth = [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } catch { $depth = 20 }
        }
        $canonical = ($Statement | ConvertTo-Json -Depth $depth -Compress)
        if ([string]::IsNullOrWhiteSpace($canonical)) { return $false }
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
        $statementHash = ''
        if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) {
            try { $statementHash = [string](Get-BuildStringHash -Text $canonical -OnFailure '') } catch { $statementHash = '' }
        }
        if ([string]::IsNullOrWhiteSpace($statementHash)) { return $false }
        $existing = @()
        try { if (Test-Path -LiteralPath $path -PathType Leaf) { $existing = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } } catch { $existing = @() }
        $prevHash = 'GENESIS'
        if ($existing.Count -gt 0) {
            try {
                $last = ($existing[$existing.Count - 1] | ConvertFrom-Json -ErrorAction Stop)
                if ($null -ne $last -and $last.PSObject.Properties.Name -contains 'entryHash' -and -not [string]::IsNullOrWhiteSpace([string]$last.entryHash)) { $prevHash = [string]$last.entryHash }
            } catch { }
        }
        $index = $existing.Count
        $entryHash = ''
        if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) {
            try { $entryHash = [string](Get-BuildStringHash -Text ($prevHash + ':' + $statementHash + ':' + [string]$index) -OnFailure '') } catch { $entryHash = '' }
        }
        if ([string]::IsNullOrWhiteSpace($entryHash)) { return $false }
        $entry = [ordered]@{ schema = 'transparency.entry.v1'; index = $index; timestamp = (Get-Date).ToString('o'); statementHash = $statementHash; prevHash = $prevHash; entryHash = $entryHash }
        $line = ([PSCustomObject]$entry | ConvertTo-Json -Compress)
        $all = @($existing) + @($line)
        if (Get-Command Write-BuildTextFileAtomic -ErrorAction SilentlyContinue) {
            [void](Write-BuildTextFileAtomic -Path $path -Lines $all)
        } else {
            $dir = Split-Path $path -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
            $tmp = Join-Path (Split-Path $path -Parent) ('.' + [System.IO.Path]::GetFileName($path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::WriteAllLines($tmp, [string[]]$all, (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
            } finally {
                try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
        # L5 Rekor: best-effort remote mirror of the stored entry. Silent and
        # non-blocking: env unset (all tests, all default builds) short-circuits
        # inside without touching the network, and any failure is swallowed so
        # the local verdict (stored) stands.
        try { [void](Send-TransparencyEntryToRekor -Entry $entry -State $State) } catch { }
        # Read-back self-verify of the append above. Silent: a failure here is
        # reported by Test-TransparencyLog callers, never by the write path.
        try { [void](Test-TransparencyLog -State $State) } catch { }
        return $true
    } catch { return $false }
}

<#
.SYNOPSIS
    Mirrors a transparency entry to a remote Rekor-style log (best-effort).
.DESCRIPTION
    L5 supply-chain, remote half: the endpoint comes ONLY from
    $env:GBUILD_REKOR_URL (no new config key, no schema change). Unset ->
    Skipped without touching the network (all tests and default builds take
    this path); invalid URL or transport error -> Failed. Never throws: the
    local ledger is the source of truth, the mirror must not break a build.
#>
function Send-TransparencyEntryToRekor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry, [PSCustomObject]$State = $null)
    $url = [System.Environment]::GetEnvironmentVariable('GBUILD_REKOR_URL')
    if ([string]::IsNullOrWhiteSpace($url)) { return [PSCustomObject]@{ Status = 'Skipped'; Reason = 'GBUILD_REKOR_URL is not set' } }
    try { $uri = [System.Uri]::new([string]$url) } catch { return [PSCustomObject]@{ Status = 'Failed'; Reason = 'GBUILD_REKOR_URL is invalid' } }
    if ($uri.Scheme -notin @('http', 'https')) { return [PSCustomObject]@{ Status = 'Failed'; Reason = 'GBUILD_REKOR_URL is invalid' } }
    try {
        $depth = 20
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $depth = [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } catch { $depth = 20 }
        }
        $body = ($Entry | ConvertTo-Json -Depth $depth -Compress)
        $null = Invoke-RestMethod -Uri ([string]$url).TrimEnd('/') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
        return [PSCustomObject]@{ Status = 'Stored'; Reason = '' }
    } catch { return [PSCustomObject]@{ Status = 'Failed'; Reason = [string]$_.Exception.Message } }
}

<#
.SYNOPSIS
    Verifies the local transparency log chain (no server needed).
.DESCRIPTION
    Recomputes every entryHash from (prevHash:statementHash:index), checks
    prevHash linkage and index order, and - when -ExpectedTip is supplied -
    compares the tip hash (a pinned tip, e.g. from an audit manifest, is what
    makes tail truncation detectable: a trimmed prefix is otherwise still
    valid). Never throws for I/O problems: they are Reasons with Valid=$false.
#>
function Test-TransparencyLog {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null, [string]$ExpectedTip = '')
    $checked = 0
    $invalid = 0
    $reasons = [System.Collections.Generic.List[string]]::new()
    $tip = ''
    try {
        $path = Resolve-TransparencyLogPath -State $State
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [PSCustomObject]@{ Valid = $false; Checked = 0; Invalid = 0; Tip = ''; Reasons = @('transparency log is not present') }
        }
        $hasHash = [bool](Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue)
        if (-not $hasHash) {
            try { [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash'); $hasHash = [bool](Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) } catch { $hasHash = $false }
        }
        if (-not $hasHash) {
            return [PSCustomObject]@{ Valid = $false; Checked = 0; Invalid = 0; Tip = ''; Reasons = @('hash primitive is unavailable') }
        }
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $prev = 'GENESIS'
        $idx = 0
        foreach ($line in $lines) {
            $bad = ''
            try {
                $e = $line | ConvertFrom-Json -ErrorAction Stop
                if ([string]$e.schema -ne 'transparency.entry.v1') { $bad = 'unexpected schema' }
                elseif ([int]$e.index -ne $idx) { $bad = 'index out of order' }
                elseif ([string]$e.prevHash -ne $prev) { $bad = 'linkage break' }
                else {
                    $want = [string](Get-BuildStringHash -Text ($prev + ':' + [string]$e.statementHash + ':' + [string]$idx) -OnFailure '')
                    if ([string]::IsNullOrWhiteSpace($want) -or $want -ne [string]$e.entryHash) { $bad = 'entry hash mismatch' }
                }
                if ([string]::IsNullOrWhiteSpace($bad)) { $prev = [string]$e.entryHash; $tip = [string]$e.entryHash }
            } catch { $bad = 'unparseable entry' }
            if (-not [string]::IsNullOrWhiteSpace($bad)) { $invalid++; $reasons.Add(('entry ' + [string]$idx + ': ' + $bad)) | Out-Null }
            $checked++
            $idx++
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTip) -and $tip -ne $ExpectedTip) {
            $invalid++
            $reasons.Add('tip mismatch against the pinned hash (possible truncation)') | Out-Null
        }
    } catch {
        return [PSCustomObject]@{ Valid = $false; Checked = $checked; Invalid = ($invalid + 1); Tip = $tip; Reasons = @($reasons) + @('log is unreadable') }
    }
    return [PSCustomObject]@{ Valid = ($invalid -eq 0); Checked = $checked; Invalid = $invalid; Tip = $tip; Reasons = @($reasons) }
}

function Get-ArtifactDigest {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $root = [System.IO.Path]::GetFullPath($Path)
            $parts = foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop | Sort-Object FullName)) {
                $relative = $file.FullName.Substring($root.Length).TrimStart('\','/') -replace '\\','/'
                $hash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))
                $relative + ':' + ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
            }
            $manifest = [string]::Join("`n", @($parts))
            # SharedUtils.Get-BuildStringHash owns UTF8 -> SHA256 -> lowercase
            # hex for the string form. The per-file digests above stay on the
            # byte-stream path (Get-BuildStringHash hashes a STRING; file content
            # is bytes), which is a different question, not a duplicate.
            [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
            $mh = Get-BuildStringHash -Text $manifest
            if (-not $mh) { return '' }
            return $mh
        }
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

Export-ModuleMember -Function @(
    'New-BuildSbom',
    'New-BuildProvenance',
    'Invoke-ArtifactSign',
    'Invoke-ContainerScan',
    'Invoke-SupplyChainChecks',
    'Invoke-SbomPolicyGate',
    'Export-ComplianceReport',
    'Get-DependencyInventory',
    'Get-ArtifactDigest',
    'Resolve-TransparencyLogPath',
    'Write-TransparencyLogEntry',
    'Send-TransparencyEntryToRekor',
    'Test-TransparencyLog'
)




