# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


# Locale is a real dependency, not a convenience: the manifest/payload
# validation below reports its findings by throwing user-facing text, and that
# text now routes through Get-LocaleMessage. Declaring it here means a standalone
# `Import-Module Standalone.psm1` still resolves the resolver, and the declared
# graph (ModuleDependencies) records the edge instead of leaving it implicit.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SupplyChain', 'Locale')
<#
.SYNOPSIS
    Standalone packaging for gbuild: packs the entire _Build tree (gbuild.ps1 + Modules/*.psm1
    + Locales/*.json + optional config) into ONE self-contained .ps1 file.
.DESCRIPTION
    Self-extract bundle: when run on any machine (no _Build tree required),
    it decodes the embedded content (base64, byte-preserving → BOM safe) into a temp dir,
    then invokes gbuild.ps1 from there. All features (SDK discovery, menu,
    security, plugins...) therefore work in single-file form.
    Config: build.standalone.{enabled, outputFile, includeConfig, embedLocales}.
    PIPELINE WIRING (not an orphan — enabled=false by default so it rarely runs visibly):
      Orchestrator $buildSteps step 'StandaloneBundle' (:1557) — When reads
      build.standalone.enabled; Script calls Import-ModuleOnDemand('Standalone') then
      New-StandaloneBundle. End-to-end verification: enable
      "build": { "standalone": { "enabled": true } } in gbuild.config.json
      then run `gbuild` — the bundle is emitted at build.standalone.outputFile.
      Test coverage: Tests/Standalone.Tests.ps1 (bundle + base64 roundtrip).
#>

# -- Import Logging + SharedUtils --
# (Get-StandaloneOutputPath uses ScriptRoot-first ordering — DIFFERENT semantics from
#  PathUtils.Resolve-BuildRootedPath which is ProjectRoot-first, so NOT delegated.)
Import-BuildModule -Dependencies @('SharedUtils')

<#
.SYNOPSIS
    Reads the build.standalone section from BuildConfig.
#>
function Get-StandaloneConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $build = Get-ConfigSection -State $State -Path 'build'
    if ($build) {
        $has = if ($build -is [System.Collections.IDictionary]) { $build.ContainsKey('standalone') }
               else { $build.PSObject.Properties.Name -contains 'standalone' }
        if ($has) { return $build.standalone }
    }
    return $null
}

# Level 5 single-source: StandaloneBundleVersion (build.standalone.bundleVersion).
function Get-StandaloneBundleVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [string](Get-BuildConstant -Key 'StandaloneBundleVersion' -State $State -Fallback '1.0.0') } catch { }
    }
    return '1.0.0'
}

<#
.SYNOPSIS
    Signs the standalone bundle using cosign.
.DESCRIPTION
    Uses cosign to sign the bundle artifact. Requires cosign in PATH and
    GBUILD_COSIGN_KEY / GBUILD_COSIGN_IDENTITY env vars.
#>
function Get-StandaloneBundleSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [PSCustomObject]$State,
        [switch]$Detailed
    )
    $enabled = [bool](Get-ConfigValue -Path 'security.artifactSign.enabled' -State $State -Default $false -Type bool)
    if (-not $enabled) {
        $result = @{ Status = 'Skipped'; Reason = 'security.artifactSign.enabled is false'; ArtifactPath = '' }
        if ($Detailed) { return $result }
        return $false
    }
    $tool = [string](Get-ConfigValue -Path 'security.artifactSign.tool' -State $State -Default 'cosign' -Type string)
    if ($tool -ne 'cosign') {
        $result = @{ Status = 'Failed'; Reason = "Unsupported standalone signing tool '$tool'"; ArtifactPath = '' }
        Write-Log "[STANDALONE] $($result.Reason)" 'Err' $State
        if ($Detailed) { return $result }
        return $false
    }
    if (-not (Get-Command cosign -CommandType Application -ErrorAction SilentlyContinue)) {
        $result = @{ Status = 'Failed'; Reason = 'cosign is enabled but not installed'; ArtifactPath = '' }
        Write-Log "[STANDALONE] $($result.Reason)" 'Err' $State
        if ($Detailed) { return $result }
        return $false
    }
    # Prefer the config values (the documented owner of these fields), which
    # carry the same environment placeholders. Only fall back to the raw
    # process env when the config field is absent/empty - so a deployment
    # can override via gbuild.config.json instead of the environment.
    $cosignKey = ''
    $cosignIdentity = ''
    try { $cosignKey = [string](Get-ConfigValue -Path 'security.artifactSign.key' -State $State -ResolveEnv -Default '' -ErrorAction SilentlyContinue) } catch { $cosignKey = '' }
    try { $cosignIdentity = [string](Get-ConfigValue -Path 'security.artifactSign.identity' -State $State -ResolveEnv -Default '' -ErrorAction SilentlyContinue) } catch { $cosignIdentity = '' }
    if ([string]::IsNullOrWhiteSpace($cosignKey)) { $cosignKey = $env:GBUILD_COSIGN_KEY }
    if ([string]::IsNullOrWhiteSpace($cosignIdentity)) { $cosignIdentity = $env:GBUILD_COSIGN_IDENTITY }
    if ([string]::IsNullOrWhiteSpace($cosignKey) -or [string]::IsNullOrWhiteSpace($cosignIdentity)) {
        $result = @{ Status = 'Failed'; Reason = 'GBUILD_COSIGN_KEY or GBUILD_COSIGN_IDENTITY is not set'; ArtifactPath = '' }
        Write-Log "[STANDALONE] $($result.Reason)" 'Err' $State
        if ($Detailed) { return $result }
        return $false
    }
    $signaturePath = $BundlePath + '.sig'
    try {
        $cosignArgs = @('sign-blob', '-key', $cosignKey, '-identity', $cosignIdentity, '-output-signature', $signaturePath, $BundlePath)
        $toolOutput = & cosign @cosignArgs 2>&1
        $toolExitCode = $LASTEXITCODE
        if ($toolExitCode -ne 0) {
            throw (Get-LocaleMessage -Key 'log.standalone.cosignSignBlobFailed' -MessageArgs @([string]$toolExitCode, [string]$toolOutput) -Fallback 'cosign sign-blob failed (exit {0}): {1}')
        }
        if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf) -or (Get-Item -LiteralPath $signaturePath).Length -le 0) {
            throw (Resolve-LogMessage -Key 'log.standalone.cosignNoSignature' -Fallback 'cosign did not create a non-empty signature')
        }
        Write-Log (Resolve-LogMessage -Key 'log.standalone.signed' -MessageArgs @([string]$signaturePath) -Fallback '[STANDALONE] Bundle signed with cosign: {0}') 'Succ' $State
        $result = @{ Status = 'Signed'; Reason = ''; ArtifactPath = $signaturePath }
        if ($Detailed) { return $result }
        return $true
    } catch {
        Write-Log (Resolve-LogMessage -Key 'log.standalone.signBlobFailed' -MessageArgs @([string]$_) -Fallback '[STANDALONE] cosign sign-blob error: {0}') 'Err' $State
        $result = @{ Status = 'Failed'; Reason = $_.Exception.Message; ArtifactPath = $signaturePath }
        if ($Detailed) { return $result }
        return $false
    }
}

<#
.SYNOPSIS
    Generates SBOM and provenance for the standalone bundle.
.DESCRIPTION
    Creates CycloneDX SBOM and SLSA provenance for the bundle artifact.
#>
function New-StandaloneBundleSupplyChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [PSCustomObject]$State,
        [switch]$Detailed
    )
    $projectDir = Split-Path -Parent $BundlePath
    $projectName = Split-Path -Leaf $BundlePath
    $sbomEnabled = [bool](Get-ConfigValue -Path 'security.sbom.enabled' -State $State -Default $false -Type bool)
    $provenanceEnabled = [bool](Get-ConfigValue -Path 'security.provenance.enabled' -State $State -Default $false -Type bool)
    $sbomResult = $null
    $provenanceResult = $null
    if ($sbomEnabled) {
        $sbomPath = $BundlePath + '.sbom.json'
        try {
            if (-not (Get-Command New-BuildSbom -ErrorAction SilentlyContinue)) { throw (Resolve-LogMessage -Key 'log.standalone.sbomHelperMissing' -Fallback 'New-BuildSbom is unavailable') }
            $sbom = New-BuildSbom -State $State -ProjectDir $projectDir -ProjectName $projectName -SbomPath $sbomPath
            if (-not $sbom) { throw (Resolve-LogMessage -Key 'log.standalone.sbomNoResult' -Fallback 'New-BuildSbom returned no result') }
            if (-not (Test-Path -LiteralPath $sbomPath -PathType Leaf) -or (Get-Item -LiteralPath $sbomPath).Length -le 0) { throw (Resolve-LogMessage -Key 'log.standalone.sbomOutputMissing' -Fallback 'SBOM output is missing or empty') }
            $sbomResult = @{ Status = 'Generated'; Reason = ''; ArtifactPath = $sbomPath }
            Write-Log (Resolve-LogMessage -Key 'log.standalone.sbomGenerated' -MessageArgs @([string]$sbomPath) -Fallback '[STANDALONE] SBOM generated: {0}') 'Succ' $State
        } catch {
            $sbomResult = @{ Status = 'Failed'; Reason = $_.Exception.Message; ArtifactPath = $sbomPath }
            Write-Log (Resolve-LogMessage -Key 'log.standalone.sbomFailed' -MessageArgs @([string]$_) -Fallback '[STANDALONE] SBOM generation failed: {0}') 'Err' $State
        }
    } else {
        $sbomResult = @{ Status = 'Skipped'; Reason = 'security.sbom.enabled is false'; ArtifactPath = '' }
    }
    if ($provenanceEnabled) {
        $provenancePath = $BundlePath + '.intoto.jsonl'
        try {
            if (-not (Get-Command New-BuildProvenance -ErrorAction SilentlyContinue)) { throw (Resolve-LogMessage -Key 'log.standalone.provenanceHelperMissing' -Fallback 'New-BuildProvenance is unavailable') }
            $provenance = New-BuildProvenance -State $State -SubjectName $projectName -SubjectPath $BundlePath -ProvenancePath $provenancePath
            if (-not $provenance) { throw (Resolve-LogMessage -Key 'log.standalone.provenanceNoResult' -Fallback 'New-BuildProvenance returned no result') }
            if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf) -or (Get-Item -LiteralPath $provenancePath).Length -le 0) { throw (Resolve-LogMessage -Key 'log.standalone.provenanceOutputMissing' -Fallback 'Provenance output is missing or empty') }
            $provenanceResult = @{ Status = 'Generated'; Reason = ''; ArtifactPath = $provenancePath }
            Write-Log (Resolve-LogMessage -Key 'log.standalone.provenanceGenerated' -MessageArgs @([string]$provenancePath) -Fallback '[STANDALONE] Provenance generated: {0}') 'Succ' $State
        } catch {
            $provenanceResult = @{ Status = 'Failed'; Reason = $_.Exception.Message; ArtifactPath = $provenancePath }
            Write-Log (Resolve-LogMessage -Key 'log.standalone.provenanceFailed' -MessageArgs @([string]$_) -Fallback '[STANDALONE] Provenance generation failed: {0}') 'Err' $State
        }
    } else {
        $provenanceResult = @{ Status = 'Skipped'; Reason = 'security.provenance.enabled is false'; ArtifactPath = '' }
    }
    $failed = @(@($sbomResult, $provenanceResult) | Where-Object { $_.Status -eq 'Failed' })
    $generated = @(@($sbomResult, $provenanceResult) | Where-Object { $_.Status -eq 'Generated' })
    $status = if ($failed.Count -gt 0) { 'Failed' } elseif ($generated.Count -gt 0) { 'OK' } else { 'Skipped' }
    $reason = if ($failed.Count -gt 0) { (($failed | ForEach-Object { $_.Reason }) -join '; ') } else { '' }
    $result = @{ Status = $status; Reason = $reason; SBOM = $sbomResult; Provenance = $provenanceResult }
    if ($Detailed) { return $result }
    return ($status -eq 'OK')
}

<#
.SYNOPSIS
    Returns the absolute path for the bundle file.
.DESCRIPTION
    outputFile may be a file name (placed next to ScriptRoot), a relative path
    (relative to ScriptRoot), or an absolute path.
#>
function Get-StandaloneOutputPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $cfg = Get-StandaloneConfig -State $State
    # Section accessor single-sourced via ConfigProvider.Get-SectionValue.
    $name = [string](Get-SectionValue -Section $cfg -Key 'outputFile' -Default 'gbuild-standalone.ps1')
    # Fail closed: the old fallback was the process CWD, and the Test-SafePath
    # containment check below was then circular ($root IS the CWD, so anything
    # under it passes). A standalone bundle emitted to an operator's launch
    # directory is a supply-chain artifact in the wrong place.
    if ($State -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) { $root = [string]$State.ScriptRoot }
    elseif ($State -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) { $root = [string]$State.ProjectRoot }
    else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.standalone.outputRootUndetermined' -Fallback 'Standalone output root is undetermined: State carries neither a rooted ScriptRoot nor a rooted ProjectRoot.')) }
    if ([System.IO.Path]::IsPathRooted($name)) { return $name }
    # Path-traversal guard (PathUtils): a relative outputFile must stay inside the root;
    # if it escapes (e.g. '..\..\x.ps1') → fall back to the default name.
    if (Get-Command Test-SafePath -ErrorAction SilentlyContinue) {
        if (-not (Test-SafePath -Path $name -Base $root)) {
            Write-Log (Resolve-LogMessage -Key 'log.standalone.outputOutsideRoot' -MessageArgs @([string]$name) -Fallback '[STANDALONE] outputFile ''{0}'' is outside the root directory - using the default name') 'Warn' $State
            return Join-Path $root 'gbuild-standalone.ps1'
        }
    }
    return Join-Path $root $name
}

function Expand-StandaloneFileList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$FileList)
    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($initial in @($FileList)) {
        if ($null -eq $initial) { continue }
        $pending = [System.Collections.Stack]::new()
        $pending.Push($initial)
        while ($pending.Count -gt 0) {
            $item = $pending.Pop()
            if (($item -is [System.Collections.IEnumerable]) -and -not ($item -is [string]) -and -not ($item -is [System.Collections.IDictionary])) {
                $nestedItems = @($item)
                for ($i = $nestedItems.Count - 1; $i -ge 0; $i--) {
                    if ($null -ne $nestedItems[$i]) { $pending.Push($nestedItems[$i]) }
                }
            } else {
                $flat.Add($item)
            }
        }
    }
    return $flat.ToArray()
}

function ConvertTo-StandaloneRelPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $relative = $Path.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.IndexOf([char]0) -ge 0) { throw (Get-LocaleMessage -Key 'log.standalone.pathInvalid' -MessageArgs @([string]$Path) -Fallback "Invalid standalone path '{0}'") }
    if ($relative.StartsWith('/') -or $relative -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($relative)) { throw (Get-LocaleMessage -Key 'log.standalone.pathMustBeRelative' -MessageArgs @([string]$Path) -Fallback "Standalone path must be relative: '{0}'") }
    while ($relative.StartsWith('./')) { $relative = $relative.Substring(2) }
    $segments = @($relative.Split('/'))
    if ($segments.Count -eq 0) { throw (Get-LocaleMessage -Key 'log.standalone.pathInvalid' -MessageArgs @([string]$Path) -Fallback "Invalid standalone path '{0}'") }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..' -or $segment -match ':') {
            throw (Get-LocaleMessage -Key 'log.standalone.pathNonCanonical' -MessageArgs @([string]$Path) -Fallback "Non-canonical standalone path '{0}'")
        }
    }
    return ($segments -join '/')
}

function Test-StandaloneExcludedPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RelPath)
    $segments = @($RelPath.Split('/'))
    $blocked = @('.git', '.gbuild', '.gbuildcache', '.tools', 'logs', 'log', 'reports', 'report', 'build-reports', 'distributed-report', 'cache', 'caches', 'vendor', 'node_modules', 'secrets', 'secret', 'keys', 'key', 'state', 'TestResults', 'test-results', 'coverage')
    for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
        if ($blocked -contains $segments[$i]) { return $true }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf -match '(?i)^\.env(?:\.|$)|\.gbuildstate$|\.log$|\.tmp$|\.sig$|\.sbom\.json$|\.intoto\.jsonl$|\.key$|\.pem$|\.pfx$|\.p12$') { return $true }
    return $false
}

<#
.SYNOPSIS
    Resolves the canonical secret pattern set used by the standalone config scan.
.DESCRIPTION
    The scan below used to carry its own 4-alternative regex (private key / AKIA /
    gh[pousr]_ / sk-), a fourth divergent copy of the redaction rules that missed
    the Slack, Stripe, JWT, Google, Bearer and generic assignment families. It now
    takes its patterns from SharedUtils.Get-BuildSecretRedactPatterns — the same
    union the redactors use — resolved on demand so it also works when this module
    is imported before SharedUtils. Matching stays a detection (the caller throws);
    only the pattern set is shared.
#>
$script:StandaloneSecretPatterns = $null

function Get-StandaloneSecretPatterns {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    if ($null -ne $script:StandaloneSecretPatterns) { return $script:StandaloneSecretPatterns }
    if (-not (Get-Command Get-BuildSecretRedactPatterns -ErrorAction SilentlyContinue) -and
        -not (Get-Module -Name 'SharedUtils' -ErrorAction SilentlyContinue)) {
        # ModuleBootstrap's Initialize-BuildSharedUtils owns the lazy SharedUtils
        # import. This was the second of the last two hand-rolled copies of that
        # step (the other was Logging.psm1); both now go through the one owner.
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildSecretRedactPatterns')
    }
    $resolved = New-Object System.Collections.Generic.List[string]
    if (Get-Command Get-BuildSecretRedactPatterns -ErrorAction SilentlyContinue) {
        foreach ($entry in @(Get-BuildSecretRedactPatterns)) {
            $pattern = [string]$entry.Pattern
            if (-not [string]::IsNullOrWhiteSpace($pattern)) { $resolved.Add($pattern) }
        }
    }
    $script:StandaloneSecretPatterns = [string[]]$resolved.ToArray()
    return $script:StandaloneSecretPatterns
}

function Assert-StandaloneConfigSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $secretPatterns = @(Get-StandaloneSecretPatterns)
    if ($secretPatterns.Count -eq 0) {
        # Fail CLOSED: without the canonical pattern set the scan cannot make any
        # guarantee, so it must not report the config as safe.
        throw (Resolve-LogMessage -Key 'log.standalone.redactPatternsMissing' -Fallback 'Cannot verify optional config safety: SharedUtils.Get-BuildSecretRedactPatterns is unavailable')
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $config = $raw | ConvertFrom-Json -ErrorAction Stop
    # security.redactPatterns / security.secretPatterns hold secret-pattern
    # DEFINITIONS and their labels (e.g. "name": "Bearer Token"), which the union
    # correctly recognises as token-shaped text. Scanning them would make every
    # project that configures redaction patterns un-bundleable, so they are exempt.
    $isPatternMetadata = { param([string]$PropertyPath) return [bool]($PropertyPath -match '(?i)(^|\.)(redactPatterns|secretPatterns)(\.|\[|$)') }
    $visit = {
        param($Node, [string]$PropertyPath)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                $childPath = if ($PropertyPath) { $PropertyPath + '.' + [string]$key } else { [string]$key }
                $value = $Node[$key]
                if ([string]$key -match '(?i)(password|passwd|secret|token|credential|connectionstring|accesskey|sharedkey|certificate)$|(^|[._-])api[_-]?key($|[._-])|(^|[._-])private[_-]?key($|[._-])') {
                    if ($null -ne $value -and -not ($value -is [string]) -and -not ($value -is [System.Collections.IEnumerable])) { throw (Get-LocaleMessage -Key 'log.standalone.secretAtConfigPath' -MessageArgs @([string]$childPath) -Fallback "Potential secret at config path '{0}'") }
                    if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value) -and [string]$value -notmatch '^\$\{env:[A-Za-z_][A-Za-z0-9_]*\}$' -and [string]$value -notmatch '^\*+$') {
                        throw (Get-LocaleMessage -Key 'log.standalone.secretAtConfigPath' -MessageArgs @([string]$childPath) -Fallback "Potential secret at config path '{0}'")
                    }
                }
                & $visit $value $childPath
            }
            return
        }
        if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
            $index = 0
            foreach ($item in $Node) { & $visit $item ($PropertyPath + '[' + $index + ']'); $index++ }
            return
        }
        if ($Node -is [string]) {
            if (-not (& $isPatternMetadata $PropertyPath)) {
                foreach ($pattern in $secretPatterns) {
                    if ([string]$Node -match $pattern) { throw (Get-LocaleMessage -Key 'log.standalone.secretInOptionalConfig' -MessageArgs @([string]$PropertyPath) -Fallback "Potential secret in optional config at '{0}'") }
                }
            }
            return
        }
        foreach ($property in $Node.PSObject.Properties) {
            $childPath = if ($PropertyPath) { $PropertyPath + '.' + $property.Name } else { $property.Name }
            $value = $property.Value
            if ($property.Name -match '(?i)(password|passwd|secret|token|credential|connectionstring|accesskey|sharedkey|certificate)$|(^|[._-])api[_-]?key($|[._-])|(^|[._-])private[_-]?key($|[._-])') {
                if ($null -ne $value -and -not ($value -is [string]) -and -not ($value -is [System.Collections.IEnumerable])) { throw (Get-LocaleMessage -Key 'log.standalone.secretAtConfigPath' -MessageArgs @([string]$childPath) -Fallback "Potential secret at config path '{0}'") }
                if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value) -and [string]$value -notmatch '^\$\{env:[A-Za-z_][A-Za-z0-9_]*\}$' -and [string]$value -notmatch '^\*+$') {
                    throw (Get-LocaleMessage -Key 'log.standalone.secretAtConfigPath' -MessageArgs @([string]$childPath) -Fallback "Potential secret at config path '{0}'")
                }
            }
            & $visit $value $childPath
        }
    }
    & $visit $config ''
}

# The module-scope byte digest. This had a second, byte-identical copy inlined
# into the standalone bundle template below (see the comment there). The template
# copy has to exist - a generated bundle cannot call back into Standalone's
# private functions - but there was no reason for the LIVE module to carry a
# third spelling, and the two names were called interchangeably from five sites.
# One name now, UPPERCASE hex, matching what the manifest has always stored: this
# value is the manifest's `sha256` field and is compared against already-shipped
# bundles, so changing the case would invalidate every one of them.
function Get-StandaloneHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

<#
.SYNOPSIS
    Config-node accessor. Single source: ConfigProvider.Get-SectionValue.
.DESCRIPTION
    The local implementation had two defects: (1) `$Object.Contains($Name)` only,
    so an ordinal dictionary missed on casing and returned $null; (2) NO NULL GUARD
    on the IDictionary branch ordering meant a $null Object skipped to
    `$Object.PSObject.Properties`, which under Set-StrictMode is a latent throw.
    Delegating fixes both.
#>
function Get-StandaloneObjectProperty {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    # Unconditional delegation; see AuditLedger.Get-LedgerField. This module
    # already calls Get-SectionValue directly and unguarded elsewhere (the
    # outputFile / includeConfig / embedLocales lookups), so the guarded fallback
    # this replaces was never the path taken.
return Get-SectionValue -Section $Object -Key $Name -Default $Default
}

function Assert-StandaloneResourceSet {
    [CmdletBinding()]
    param([object[]]$FileList)
    $files = @(Expand-StandaloneFileList -FileList $FileList)
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $rel = [string]$file.RelPath
        $isDuplicate = -not $paths.Add((ConvertTo-StandaloneRelPath -Path $rel))
        if ($isDuplicate) { throw (Get-LocaleMessage -Key 'log.standalone.resourceDuplicate' -MessageArgs @([string]$rel) -Fallback "Duplicate standalone resource '{0}'") }
    }
    foreach ($required in @('gbuild.ps1', 'Modules/ModuleBootstrap.ps1', 'Modules/Orchestrator.psm1', 'Modules/Loader.psm1', 'Modules/Plugins/BasePlugin.ps1', 'gbuild.config.schema.json', 'gbuild.plugin.schema.json')) {
        if (-not $paths.Contains($required)) { throw (Get-LocaleMessage -Key 'log.standalone.resourceMissing' -MessageArgs @([string]$required) -Fallback 'Required standalone resource missing: {0}') }
    }
    $pluginModules = @($files | Where-Object { $_.RelPath -match '^Modules/Plugins/(?!helpers/)(.+/)?[^/]+\.psm1$' -and [System.IO.Path]::GetFileName([string]$_.RelPath) -notmatch 'Helpers\.psm1$' })
    $pluginManifests = @($files | Where-Object { $_.RelPath -match '^Modules/Plugins/(?!helpers/).+\.plugin\.json$' })
    if ($pluginModules.Count -eq 0 -or $pluginModules.Count -ne $pluginManifests.Count) { throw (Resolve-LogMessage -Key 'log.standalone.pluginPairMismatch' -Fallback 'Plugin module and manifest counts do not match') }
    foreach ($module in $pluginModules) {
        $modulePath = [string]$module.RelPath
        $manifestPath = [System.IO.Path]::ChangeExtension($modulePath, '.plugin.json')
        if (-not $paths.Contains($manifestPath.Replace('\', '/'))) { throw (Get-LocaleMessage -Key 'log.standalone.pluginManifestMissing' -MessageArgs @([string]$modulePath) -Fallback "Plugin manifest missing for '{0}'") }
    }
    foreach ($manifest in $pluginManifests) {
        $manifestPath = [string]$manifest.RelPath
        $modulePath = $manifestPath.Substring(0, $manifestPath.Length - '.plugin.json'.Length) + '.psm1'
        if (-not $paths.Contains($modulePath.Replace('\', '/'))) { throw (Get-LocaleMessage -Key 'log.standalone.pluginModuleMissing' -MessageArgs @([string]$manifestPath) -Fallback "Plugin module missing for '{0}'") }
    }
}

function Get-EmbeddedFiles {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([PSCustomObject]$State)
    $cfg = Get-StandaloneConfig -State $State
    $includeConfig = [bool](Get-SectionValue -Section $cfg -Key 'includeConfig' -Default $false)
    $embedLocales = [bool](Get-SectionValue -Section $cfg -Key 'embedLocales' -Default $true)
    # Same fail-closed root as Get-StandaloneOutputPath: the bundle file list must
    # be enumerated from the tool tree, never from the launch directory.
    if ($State -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) { $root = [string]$State.ScriptRoot }
    elseif ($State -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) { $root = [string]$State.ProjectRoot }
    else { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.standalone.resourceRootUndetermined' -Fallback 'Standalone resource root is undetermined: State carries neither a rooted ScriptRoot nor a rooted ProjectRoot.')) }
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    # Shared accessors, with a local fallback: this module also runs inside the
    # emitted self-contained bundle, where PathUtils may not be present, and an
    # unresolved command here aborted the whole bundle.
    $comparison = 'Ordinal'
    if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { $comparison = [string](Get-PathComparison) }
    else {
        # $IsWindows does NOT exist on Windows PowerShell 5.1, and this module
        # runs under Set-StrictMode -Version 1.0, where touching an undefined
        # variable is a TERMINATING error rather than $false. Testing it first
        # therefore threw on 5.1 and made the correct fallbacks below
        # unreachable. Both checks used here are 5.1-safe.
        $sbIsWin = $false
        if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { try { $sbIsWin = [bool](Test-IsWindowsHost) } catch { $sbIsWin = $false } }
        else { try { $sbIsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) } catch { $sbIsWin = $false } }
        if ($sbIsWin) { $comparison = 'OrdinalIgnoreCase' }
    }

    $files = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $addFile = {
        param([string]$RelPath, [string]$FullPath, [bool]$Required)
        $canonical = ConvertTo-StandaloneRelPath -Path $RelPath
        if (Test-StandaloneExcludedPath -RelPath $canonical) { return }
        $full = [System.IO.Path]::GetFullPath($FullPath)
        $resourceOk = $false
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
            try { $resourceOk = Test-PathUnderRoots -Path $full -AllowedRoots @($rootFull) } catch { $resourceOk = $false }
        } else {
            try { $resourceOk = $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison) } catch { $resourceOk = $false }
        }
        if (-not $resourceOk) { throw (Get-LocaleMessage -Key 'log.standalone.resourceEscapesRoot' -MessageArgs @([string]$full) -Fallback 'Standalone resource escapes root: {0}') }
        if (-not $files.ContainsKey($canonical)) { $files[$canonical] = @{ RelPath = $canonical; FullPath = $full; Required = $Required } }
    }
    foreach ($name in @('gbuild.ps1', 'gbuild', 'gbuild.bat', 'LICENSE', 'copyright.txt')) {
        $path = Join-Path $rootFull $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { & $addFile $name $path ($name -eq 'gbuild.ps1') }
    }
    foreach ($schema in @(Get-ChildItem -LiteralPath $rootFull -Filter '*.schema.json' -File -Force -ErrorAction SilentlyContinue)) {
        & $addFile $schema.Name $schema.FullName $true
    }
    $modulesRoot = Join-Path $rootFull 'Modules'
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $modulesRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object -Property FullName)) {
            if (Test-ReparsePointItem -Path $item.FullName) { continue }
            if ($item.Extension -notin @('.ps1', '.psm1') -and $item.Name -notlike '*.plugin.json' -and $item.Name -notlike '*.schema.json') { continue }
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            & $addFile $relative $item.FullName $true
        }
    }
    foreach ($directoryName in @('Steps', 'Hooks')) {
        $directory = Join-Path $rootFull $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force -ErrorAction Stop | Sort-Object -Property FullName)) {
            if ((Test-ReparsePointItem -Path $item.FullName) -or $item.Extension -ne '.ps1') { continue }
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            & $addFile $relative $item.FullName $true
        }
    }
    $localesRoot = Join-Path $rootFull 'Locales'
    if ($embedLocales -and (Test-Path -LiteralPath $localesRoot -PathType Container)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $localesRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object -Property FullName)) {
            if ((Test-ReparsePointItem -Path $item.FullName) -or $item.Extension -ne '.json') { continue }
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
            & $addFile $relative $item.FullName $false
        }
    }
    if ($includeConfig) {
        $configPath = Join-Path $rootFull 'gbuild.config.json'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw (Resolve-LogMessage -Key 'log.standalone.optionalConfigMissing' -Fallback 'Optional standalone config is missing') }
        Assert-StandaloneConfigSafe -Path $configPath
        & $addFile 'gbuild.config.json' $configPath $false
    }
    $paths = [string[]]@($files.Keys)
    [Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) { $ordered.Add($files[$path]) }
    return ,@($ordered.ToArray())
}

function New-StandaloneManifest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]]$FileList,
        [string]$Version = '1.0.0'
    )
    if ([string]::IsNullOrWhiteSpace($Version)) { throw (Resolve-LogMessage -Key 'log.standalone.manifestVersionEmpty' -Fallback 'Standalone manifest version is empty') }
    $files = @(Expand-StandaloneFileList -FileList $FileList)
    if ($files.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.noFilesToEmbed' -Fallback 'No files to embed') }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entryMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $relative = ConvertTo-StandaloneRelPath -Path ([string]$file.RelPath)
        $isDuplicate = -not $seen.Add($relative)
        if ($isDuplicate) { throw (Get-LocaleMessage -Key 'log.standalone.pathDuplicate' -MessageArgs @([string]$relative) -Fallback "Duplicate standalone path '{0}'") }
        if (Test-StandaloneExcludedPath -RelPath $relative) { throw (Get-LocaleMessage -Key 'log.standalone.pathExcluded' -MessageArgs @([string]$relative) -Fallback "Excluded standalone path '{0}'") }
        if ([string]::IsNullOrWhiteSpace([string]$file.FullPath) -or -not (Test-Path -LiteralPath ([string]$file.FullPath) -PathType Leaf)) { throw (Get-LocaleMessage -Key 'log.standalone.fileMissing' -MessageArgs @([string]$relative) -Fallback 'Standalone file missing: {0}') }
        $bytes = [System.IO.File]::ReadAllBytes([string]$file.FullPath)
        if ($bytes.Length -eq 0) { throw (Get-LocaleMessage -Key 'log.standalone.fileEmpty' -MessageArgs @([string]$relative) -Fallback 'Standalone file is empty: {0}') }
        $requiredValue = Get-StandaloneObjectProperty -Object $file -Name 'Required'
        if ($null -eq $requiredValue) { $requiredValue = $true }
        $entryMap[$relative] = [PSCustomObject][ordered]@{
            path = $relative
            size = [long]$bytes.Length
            sha256 = (Get-StandaloneHash -Bytes $bytes)
            required = [bool]$requiredValue
        }
    }
    $paths = [string[]]@($entryMap.Keys)
    [Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) { $entries.Add($entryMap[$path]) }
    return [PSCustomObject][ordered]@{ version = $Version; files = @($entries.ToArray()) }
}

function Assert-StandaloneManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest, [switch]$RequireRuntimeResources)
    $version = [string](Get-StandaloneObjectProperty -Object $Manifest -Name 'version')
    if ([string]::IsNullOrWhiteSpace($version)) { throw (Resolve-LogMessage -Key 'log.standalone.manifestVersionMissing' -Fallback 'Standalone manifest version is missing') }
    $files = @(Get-StandaloneObjectProperty -Object $Manifest -Name 'files')
    if ($files.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.manifestNoFiles' -Fallback 'Standalone manifest has no files') }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $previous = ''
    foreach ($file in $files) {
        $path = [string](Get-StandaloneObjectProperty -Object $file -Name 'path')
        $path = ConvertTo-StandaloneRelPath -Path $path
        $isDuplicate = -not $seen.Add($path)
        if ($isDuplicate) { throw (Get-LocaleMessage -Key 'log.standalone.manifestPathDuplicate' -MessageArgs @([string]$path) -Fallback "Duplicate standalone manifest path '{0}'") }
        if ($previous -and [string]::Compare($previous, $path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw (Get-LocaleMessage -Key 'log.standalone.manifestNotSorted' -MessageArgs @([string]$path) -Fallback "Standalone manifest paths are not strictly sorted at '{0}'") }
        $previous = $path
        $sizeValue = Get-StandaloneObjectProperty -Object $file -Name 'size'
        try { $size = [long]$sizeValue } catch { throw (Get-LocaleMessage -Key 'log.standalone.manifestSizeInvalid' -MessageArgs @([string]$path) -Fallback "Invalid standalone size for '{0}'") }
        if ($size -le 0) { throw (Resolve-LogMessage -Key 'log.standalone.line595' -Fallback "Standalone file is empty or has invalid size: '$path'") }
        $hash = [string](Get-StandaloneObjectProperty -Object $file -Name 'sha256')
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw (Get-LocaleMessage -Key 'log.standalone.manifestHashInvalid' -MessageArgs @([string]$path) -Fallback "Invalid standalone SHA-256 for '{0}'") }
        $required = Get-StandaloneObjectProperty -Object $file -Name 'required'
        if ($required -isnot [bool]) { throw (Get-LocaleMessage -Key 'log.standalone.manifestRequiredFlagInvalid' -MessageArgs @([string]$path) -Fallback "Invalid standalone required flag for '{0}'") }
    }
    if ($RequireRuntimeResources) {
        foreach ($requiredPath in @('gbuild.ps1', 'Modules/ModuleBootstrap.ps1', 'Modules/Orchestrator.psm1', 'Modules/Loader.psm1', 'Modules/Plugins/BasePlugin.ps1', 'gbuild.config.schema.json', 'gbuild.plugin.schema.json')) {
            $entry = @($files | Where-Object { ([string](Get-StandaloneObjectProperty -Object $_ -Name 'path')).Equals($requiredPath, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($entry.Count -ne 1 -or (Get-StandaloneObjectProperty -Object $entry[0] -Name 'required') -ne $true) { throw (Get-LocaleMessage -Key 'log.standalone.manifestRequiredEntryMissing' -MessageArgs @([string]$requiredPath) -Fallback 'Required manifest entry missing or not required: {0}') }
        }
    }
}

function ConvertTo-StandaloneJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '"') { [void]$builder.Append('\"') }
        elseif ($character -eq '\') { [void]$builder.Append('\\') }
        elseif ($character -eq "`b") { [void]$builder.Append('\b') }
        elseif ($character -eq "`f") { [void]$builder.Append('\f') }
        elseif ($character -eq "`n") { [void]$builder.Append('\n') }
        elseif ($character -eq "`r") { [void]$builder.Append('\r') }
        elseif ($character -eq "`t") { [void]$builder.Append('\t') }
        elseif ([int][char]$character -lt 32) { [void]$builder.Append(('\u{0:x4}' -f [int][char]$character)) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-StandaloneManifestJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Manifest)
    Assert-StandaloneManifest -Manifest $Manifest
    $version = [string](Get-StandaloneObjectProperty -Object $Manifest -Name 'version')
    $files = @(Get-StandaloneObjectProperty -Object $Manifest -Name 'files')
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $size = [long](Get-StandaloneObjectProperty -Object $file -Name 'size')
        $required = if ((Get-StandaloneObjectProperty -Object $file -Name 'required')) { 'true' } else { 'false' }
        $parts.Add('{"path":' + (ConvertTo-StandaloneJsonString -Text ([string](Get-StandaloneObjectProperty -Object $file -Name 'path'))) + ',"size":' + $size.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ',"sha256":' + (ConvertTo-StandaloneJsonString -Text ([string](Get-StandaloneObjectProperty -Object $file -Name 'sha256'))) + ',"required":' + $required + '}')
    }
    return '{"version":' + (ConvertTo-StandaloneJsonString -Text $version) + ',"files":[' + ($parts -join ',') + ']}'
}

function ConvertFrom-StandalonePayload {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string[]]$PayloadLines)
    if (-not $PayloadLines -or $PayloadLines.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.payloadEmpty' -Fallback 'Standalone payload is empty') }
    $records = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentPath = ''
    $buffer = [System.Text.StringBuilder]::new()
    $complete = {
        param([string]$Path, [System.Text.StringBuilder]$Builder)
        $canonical = ConvertTo-StandaloneRelPath -Path $Path
        $isDuplicate = -not $seen.Add($canonical)
        if ($isDuplicate) { throw (Get-LocaleMessage -Key 'log.standalone.payloadPathDuplicate' -MessageArgs @([string]$canonical) -Fallback "Duplicate standalone payload path '{0}'") }
        if ($Builder.Length -eq 0) { throw (Get-LocaleMessage -Key 'log.standalone.payloadEntryEmpty' -MessageArgs @([string]$canonical) -Fallback "Standalone payload is empty: '{0}'") }
        try { $bytes = [System.Convert]::FromBase64String($Builder.ToString()) }
        catch { throw (Get-LocaleMessage -Key 'log.standalone.payloadBase64Invalid' -MessageArgs @([string]$canonical, [string]$_.Exception.Message) -Fallback "Invalid standalone base64 for '{0}': {1}") }
        if ($bytes.Length -eq 0) { throw (Get-LocaleMessage -Key 'log.standalone.payloadEntryEmpty' -MessageArgs @([string]$canonical) -Fallback "Standalone payload is empty: '{0}'") }
        $records.Add([PSCustomObject][ordered]@{ path = $canonical; size = [long]$bytes.Length; sha256 = (Get-StandaloneHash -Bytes $bytes); required = $true })
        [void]$Builder.Clear()
    }
    foreach ($line in $PayloadLines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('=')) {
            if (-not $currentPath) { throw (Resolve-LogMessage -Key 'log.standalone.payloadContinuationNoFile' -Fallback 'Standalone payload continuation has no file') }
            [void]$buffer.Append($line.Substring(1))
            continue
        }
        if ($currentPath) { & $complete $currentPath $buffer }
        $separator = $line.IndexOf(';')
        if ($separator -le 0 -or $separator -eq ($line.Length - 1)) { throw (Get-LocaleMessage -Key 'log.standalone.payloadLineInvalid' -MessageArgs @([string]$line) -Fallback "Invalid standalone payload line '{0}'") }
        $currentPath = $line.Substring(0, $separator)
        [void]$buffer.Append($line.Substring($separator + 1))
    }
    if ($currentPath) { & $complete $currentPath $buffer }
    if ($records.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.payloadNoFiles' -Fallback 'Standalone payload has no files') }
    $previous = ''
    foreach ($record in $records) {
        if ($previous -and [string]::Compare($previous, [string]$record.path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw (Get-LocaleMessage -Key 'log.standalone.payloadNotSorted' -MessageArgs @([string]$record.path) -Fallback "Standalone payload paths are not strictly sorted at '{0}'") }
        $previous = [string]$record.path
    }
    return $records.ToArray()
}

function Assert-StandalonePayloadMatchesManifest {
    [CmdletBinding()]
    param([string[]]$PayloadLines, [Parameter(Mandatory)]$Manifest)
    Assert-StandaloneManifest -Manifest $Manifest
    $manifestFiles = @(Get-StandaloneObjectProperty -Object $Manifest -Name 'files')
    $payloadFiles = @(ConvertFrom-StandalonePayload -PayloadLines $PayloadLines)
    if ($manifestFiles.Count -ne $payloadFiles.Count) { throw (Resolve-LogMessage -Key 'log.standalone.payloadManifestCountMismatch' -Fallback 'Standalone payload and manifest file counts differ') }
    for ($i = 0; $i -lt $manifestFiles.Count; $i++) {
        $expected = $manifestFiles[$i]
        $actual = $payloadFiles[$i]
        foreach ($field in @('path', 'size', 'sha256')) {
            $expectedValue = Get-StandaloneObjectProperty -Object $expected -Name $field
            $actualValue = Get-StandaloneObjectProperty -Object $actual -Name $field
            if ($field -eq 'path') { $equal = [string]::Equals([string]$expectedValue, [string]$actualValue, [System.StringComparison]::Ordinal) }
            elseif ($field -eq 'size') { $equal = ([long]$expectedValue -eq [long]$actualValue) }
            else { $equal = [string]::Equals([string]$expectedValue, [string]$actualValue, [System.StringComparison]::OrdinalIgnoreCase) }
            if (-not $equal) { throw (Get-LocaleMessage -Key 'log.standalone.payloadFieldMismatch' -MessageArgs @([string]$field, [string]$i) -Fallback "Standalone payload does not match manifest field '{0}' at index {1}") }
        }
    }
}

function ConvertTo-Base64Payload {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [object[]]$FileList,
        [switch]$Strict,
        $Manifest,
        [string]$Version = '1.0.0'
    )
    $flat = @(Expand-StandaloneFileList -FileList $FileList)
    $expected = $null
    if ($Strict) {
        if ($null -eq $Manifest) { $Manifest = New-StandaloneManifest -FileList $flat -Version $Version }
        Assert-StandaloneManifest -Manifest $Manifest
        $expected = @{}
        foreach ($entry in @(Get-StandaloneObjectProperty -Object $Manifest -Name 'files')) { $expected[[string](Get-StandaloneObjectProperty -Object $entry -Name 'path')] = $entry }
    }
    $sorted = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $flat) {
        $relative = ConvertTo-StandaloneRelPath -Path ([string]$file.RelPath)
        $isDuplicate = -not $seen.Add($relative)
        if ($isDuplicate) {
            if ($Strict) { throw (Get-LocaleMessage -Key 'log.standalone.pathDuplicate' -MessageArgs @([string]$relative) -Fallback "Duplicate standalone path '{0}'") }
            continue
        }
        $sorted.Add($file)
    }
    $paths = [string[]]@($sorted | ForEach-Object { [string]$_.RelPath } | ForEach-Object { $_.Replace('\', '/') })
    $byPath = @{}
    foreach ($file in $sorted) { $byPath[(ConvertTo-StandaloneRelPath -Path ([string]$file.RelPath))] = $file }
    [Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in $paths) {
        $file = $byPath[$relative]
        $base64 = ''
        if ($file.FullPath -and (Test-Path -LiteralPath ([string]$file.FullPath) -PathType Leaf)) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes([string]$file.FullPath)
                if ($Strict -and $bytes.Length -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.line750' -Fallback "Standalone file is empty: '$relative'") }
                if ($Strict) {
                    if (-not $expected.ContainsKey($relative)) { throw (Get-LocaleMessage -Key 'log.standalone.payloadFileUnmanifested' -MessageArgs @([string]$relative) -Fallback "Standalone payload has an unmanifested file: '{0}'") }
                    $entry = $expected[$relative]
                    if ([long](Get-StandaloneObjectProperty -Object $entry -Name 'size') -ne [long]$bytes.Length) { throw (Get-LocaleMessage -Key 'log.standalone.fileSizeChanged' -MessageArgs @([string]$relative) -Fallback "Standalone file size changed: '{0}'") }
                    if (-not [string]::Equals([string](Get-StandaloneObjectProperty -Object $entry -Name 'sha256'), (Get-StandaloneHash -Bytes $bytes), [System.StringComparison]::OrdinalIgnoreCase)) { throw (Get-LocaleMessage -Key 'log.standalone.fileHashChanged' -MessageArgs @([string]$relative) -Fallback "Standalone file SHA-256 changed: '{0}'") }
                }
                $base64 = [System.Convert]::ToBase64String($bytes)
            } catch {
                if ($Strict) { throw }
                $base64 = ''
            }
        }
        if (-not $base64) {
            if ($Strict) { throw (Resolve-LogMessage -Key 'log.standalone.line764' -Fallback "Standalone file missing: '$relative'") }
            $out.Add($relative + ';')
            continue
        }
        for ($offset = 0; $offset -lt $base64.Length; $offset += 76) {
            $length = [Math]::Min(76, $base64.Length - $offset)
            $chunk = $base64.Substring($offset, $length)
            if ($offset -eq 0) { $out.Add($relative + ';' + $chunk) } else { $out.Add('=' + $chunk) }
        }
    }
    if ($Strict -and $out.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.payloadEmpty' -Fallback 'Standalone payload is empty') }
    return ,@($out.ToArray())
}

function New-StandaloneBundleScript {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$OutputPath,
        [string[]]$PayloadLines,
        [string]$Version = '',
        $Manifest
    )
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-StandaloneBundleVersion -State $State }
    if (-not $PayloadLines -or $PayloadLines.Count -eq 0) { return @{ Status = 'Failed'; Reason = 'No files to embed'; OutputPath = $OutputPath } }
    try {
        if ($null -eq $Manifest) {
            $records = @(ConvertFrom-StandalonePayload -PayloadLines $PayloadLines)
            $Manifest = [PSCustomObject][ordered]@{ version = $Version; files = @($records | ForEach-Object { [PSCustomObject][ordered]@{ path = $_.path; size = $_.size; sha256 = $_.sha256; required = $_.required } }) }
        }
        Assert-StandaloneManifest -Manifest $Manifest
        Assert-StandalonePayloadMatchesManifest -PayloadLines $PayloadLines -Manifest $Manifest
        $manifestJson = ConvertTo-StandaloneManifestJson -Manifest $Manifest
        $manifestBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($manifestJson))
    } catch {
        return @{ Status = 'Failed'; Reason = "Manifest generation failed: $($_.Exception.Message)"; OutputPath = $OutputPath }
    }
    $payloadText = $PayloadLines -join "`n"
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('[CmdletBinding()]')
    $null = $sb.AppendLine('param(')
    $null = $sb.AppendLine('    [Parameter(Position=0)][string]$Project = '''',')
    $null = $sb.AppendLine('    [Alias(''gh'')][switch]$GitHub,')
    $null = $sb.AppendLine('    [Alias(''i'')][switch]$Incremental,')
    $null = $sb.AppendLine('    [Alias(''c'')][switch]$Clean,')
    $null = $sb.AppendLine('    [Alias(''cc'')][switch]$CacheClear,')
    $null = $sb.AppendLine('    [Alias(''co'')][switch]$CacheOptimize,')
    $null = $sb.AppendLine('    [switch]$CacheStats,')
    $null = $sb.AppendLine('    [switch]$VersionBump,')
    $null = $sb.AppendLine('    [Alias(''sec'')][switch]$Security,')
    $null = $sb.AppendLine('    [Alias(''dist'')][switch]$Distributed,')
    $null = $sb.AppendLine('    [switch]$NonInteractive,')
    $null = $sb.AppendLine('    [switch]$Force,')
    $null = $sb.AppendLine('    [string]$Target = '''',')
    $null = $sb.AppendLine('    [string]$Locale = '''',')
    $null = $sb.AppendLine('    [string]$LogLevel = ''Info'',')
    $null = $sb.AppendLine('    [switch]$License,')
    $null = $sb.AppendLine('    [switch]$Help,')
    $null = $sb.AppendLine('    [Alias(''vrf'')][switch]$VerifyInfra,')
    $null = $sb.AppendLine('    [switch]$SyntaxCheck,')
    $null = $sb.AppendLine('    [switch]$SelfTest,')
    $null = $sb.AppendLine('    [Parameter(ValueFromRemainingArguments)]')
    $null = $sb.AppendLine('    [string[]]$AdditionalArgs = @()')
    $null = $sb.AppendLine(')')
    $null = $sb.AppendLine('Set-StrictMode -Version 1.0')
    $null = $sb.AppendLine('$ErrorActionPreference = ''Continue''')
    $null = $sb.AppendLine('$manifestBase64 = ''' + $manifestBase64 + '''')
    $null = $sb.AppendLine('$manifestJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($manifestBase64))')
    $null = $sb.AppendLine('$manifest = $manifestJson | ConvertFrom-Json -ErrorAction Stop')
    $null = $sb.AppendLine('$payload = @''')
    $null = $sb.Append($payloadText)
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("'@")
    $null = $sb.AppendLine(@'
# The bundle's byte digest. This duplicate is deliberate and must stay: the
# generated bundle below is a self-contained artifact, so it cannot call back into
# Standalone's private module-scope functions. It is kept byte-identical to the
# module-scope Get-StandaloneHash and under the SAME NAME on purpose - the two
# names previously in play here (Get-StandaloneSha256 and Get-StandaloneHash) were
# called interchangeably from five sites in one file, which is exactly the shape
# where a fix to one copy silently invalidates the manifests the other writes.

function Assert-StandaloneRelativePath {
    param([string]$Target, [string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath) -or $RelPath.IndexOf([char]0) -ge 0) { throw 'Standalone path is empty or invalid' }
    if ($RelPath.Contains('\') -or $RelPath.StartsWith('/') -or $RelPath -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($RelPath)) { throw "Standalone path is not canonical: '$RelPath'" }
    $segments = @($RelPath.Split('/'))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..' -or $segment -match ':') { throw "Standalone path traversal or invalid segment: '$RelPath'" }
    }
    $root = [System.IO.Path]::GetFullPath($Target).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath((Join-Path $Target $RelPath))
    # Shared accessors, with a local fallback: this module also runs inside the
    # emitted self-contained bundle, where PathUtils may not be present, and an
    # unresolved command here aborted the whole bundle.
    $comparison = 'Ordinal'
    if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { $comparison = [string](Get-PathComparison) }
    else {
        # $IsWindows does NOT exist on Windows PowerShell 5.1, and this module
        # runs under Set-StrictMode -Version 1.0, where touching an undefined
        # variable is a TERMINATING error rather than $false. Testing it first
        # therefore threw on 5.1 and made the correct fallbacks below
        # unreachable. Both checks used here are 5.1-safe.
        $sbIsWin = $false
        if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { try { $sbIsWin = [bool](Test-IsWindowsHost) } catch { $sbIsWin = $false } }
        else { try { $sbIsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) } catch { $sbIsWin = $false } }
        if ($sbIsWin) { $comparison = 'OrdinalIgnoreCase' }
    }

    $contained = $false
    if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
        try { $contained = Test-PathUnderRoots -Path $full -AllowedRoots @($root) } catch { $contained = $false }
    } else {
        try { $contained = $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $comparison) } catch { $contained = $false }
    }
    if (-not $contained) { throw "Standalone path escapes extraction root: '$RelPath'" }
}

function Assert-StandaloneRuntimeManifest {
    if ($null -eq $manifest -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) { throw (Resolve-LogMessage -Key 'log.standalone.manifestVersionMissing' -Fallback 'Standalone manifest version is missing') }
    $files = @($manifest.files)
    if ($files.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.manifestNoFiles' -Fallback 'Standalone manifest has no files') }
    $map = @{}
    $previous = ''
    foreach ($file in $files) {
        $path = [string]$file.path
        Assert-StandaloneRelativePath -Target $extractDir -RelPath $path
        if ($map.ContainsKey($path)) { throw (Get-LocaleMessage -Key 'log.standalone.manifestPathDuplicate' -MessageArgs @([string]$path) -Fallback "Duplicate standalone manifest path '{0}'") }
        if ($previous -and [string]::Compare($previous, $path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw (Get-LocaleMessage -Key 'log.standalone.manifestNotSorted' -MessageArgs @([string]$path) -Fallback "Standalone manifest paths are not strictly sorted at '{0}'") }
        $previous = $path
        $size = 0L
        if (-not [long]::TryParse([string]$file.size, [ref]$size) -or $size -le 0) { throw "Standalone manifest size is invalid for '$path'" }
        if ([string]$file.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Standalone manifest SHA-256 is invalid for '$path'" }
        if ($file.required -isnot [bool]) { throw "Standalone manifest required flag is invalid for '$path'" }
        $map[$path] = $file
    }
    foreach ($requiredPath in @('gbuild.ps1', 'Modules/ModuleBootstrap.ps1', 'Modules/Orchestrator.psm1', 'Modules/Loader.psm1', 'Modules/Plugins/BasePlugin.ps1', 'gbuild.config.schema.json', 'gbuild.plugin.schema.json')) {
        if (-not $map.ContainsKey($requiredPath) -or $map[$requiredPath].required -ne $true) { throw "Required standalone resource is missing or optional: $requiredPath" }
    }
    $orderedPaths = [string[]]@($files | ForEach-Object { [string]$_.path })
    [Array]::Sort($orderedPaths, [System.StringComparer]::OrdinalIgnoreCase)
    return [PSCustomObject]@{ Map = $map; Paths = $orderedPaths }
}

function Restore-StandaloneFiles {
    param($ManifestData)
    $ManifestMap = $ManifestData.Map
    $payloadMap = @{}
    $currentPath = ''
    $payloadIndex = 0
    $buffer = [System.Text.StringBuilder]::new()
    $complete = {
        param([string]$Path, [System.Text.StringBuilder]$Builder)
        if ([string]::IsNullOrWhiteSpace($Path) -or $Builder.Length -eq 0) { throw "Standalone payload is empty for '$Path'" }
        try { $bytes = [System.Convert]::FromBase64String($Builder.ToString()) }
        catch { throw "Invalid standalone base64 for '$Path': $($_.Exception.Message)" }
        if ($bytes.Length -eq 0) { throw "Standalone payload decoded to an empty file: '$Path'" }
        if ($payloadMap.ContainsKey($Path)) { throw "Duplicate standalone payload path '$Path'" }
        $payloadMap[$Path] = $bytes
        [void]$Builder.Clear()
    }
    foreach ($line in $payload -split "\r?\n") {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('=')) {
            if (-not $currentPath) { throw (Resolve-LogMessage -Key 'log.standalone.payloadContinuationNoFile' -Fallback 'Standalone payload continuation has no file') }
            [void]$buffer.Append($line.Substring(1))
            continue
        }
        if ($currentPath) { & $complete $currentPath $buffer }
        if ($payloadIndex -ge $ManifestMap.Count) { throw "Unexpected standalone payload path '$line'" }
        $separator = $line.IndexOf(';')
        if ($separator -le 0 -or $separator -eq ($line.Length - 1)) { throw (Get-LocaleMessage -Key 'log.standalone.payloadLineInvalid' -MessageArgs @([string]$line) -Fallback "Invalid standalone payload line '{0}'") }
        $currentPath = $line.Substring(0, $separator)
        Assert-StandaloneRelativePath -Target $extractDir -RelPath $currentPath
        if ($payloadMap.ContainsKey($currentPath)) { throw "Duplicate standalone payload path '$currentPath'" }
        $expectedPath = [string]$ManifestData.Paths[$payloadIndex]
        if (-not [string]::Equals($expectedPath, $currentPath, [System.StringComparison]::Ordinal)) { throw "Standalone payload order mismatch: expected '$expectedPath', got '$currentPath'" }
        $payloadIndex++
        [void]$buffer.Append($line.Substring($separator + 1))
    }
    if ($currentPath) { & $complete $currentPath $buffer }
    if ($payloadIndex -ne $ManifestMap.Count -or $payloadMap.Count -ne $ManifestMap.Count) { throw 'Standalone payload is missing manifest files' }
    foreach ($path in $ManifestMap.Keys) {
        $bytes = [byte[]]$payloadMap[$path]
        $entry = $ManifestMap[$path]
        if ([long]$bytes.Length -ne [long]$entry.size) { throw "Standalone size verification failed for '$path'" }
        if (-not [string]::Equals((Get-StandaloneHash -Bytes $bytes), [string]$entry.sha256, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Standalone SHA-256 verification failed for '$path'" }
    }
    foreach ($path in $ManifestMap.Keys) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $extractDir $path))
        Assert-StandaloneRelativePath -Target $extractDir -RelPath $path
        $directory = [System.IO.Path]::GetDirectoryName($full)
        [void][System.IO.Directory]::CreateDirectory($directory)
        [System.IO.File]::WriteAllBytes($full, [byte[]]$payloadMap[$path])
    }
}

function Invoke-StandaloneSelfTest {
    $files = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force -ErrorAction Stop | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') } | Sort-Object -Property FullName)
    if ($files.Count -eq 0) { throw 'Standalone self-test found no PowerShell files' }
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) { throw "Standalone syntax verification failed for '$($file.FullName)': $($parseErrors[0].Message)" }
    }
    $orchestratorPath = Join-Path $extractDir 'Modules/Orchestrator.psm1'
    $loaderPath = Join-Path $extractDir 'Modules/Loader.psm1'
    foreach ($modulePath in @($orchestratorPath, $loaderPath)) {
        $loaded = Get-Module -Name ([System.IO.Path]::GetFileNameWithoutExtension($modulePath)) -ErrorAction SilentlyContinue
        if ($loaded -and $loaded.Path -and $loaded.Path -ne $modulePath) { Remove-Module -Name $loaded.Name -Force -ErrorAction SilentlyContinue }
        $null = Import-Module $modulePath -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    if (-not (Get-Command Start-GBuild -ErrorAction SilentlyContinue)) { throw 'Orchestrator import did not expose Start-GBuild' }
    if (-not (Get-Command Register-Plugins -ErrorAction SilentlyContinue)) { throw 'Loader import did not expose Register-Plugins' }
    $selfTestState = [PSCustomObject]@{
        ScriptRoot = $extractDir
        ProjectRoot = $extractDir
        WorkingDir = $extractDir
        TenantId = 'standalone-selftest'
        CorrelationId = 'standalone-selftest'
        BuildConfig = [PSCustomObject]@{
            version = '2.0.0'
            build = [PSCustomObject]@{ pluginDirs = @() }
            security = [PSCustomObject]@{}
        }
    }
    Register-Plugins -State $selfTestState -ErrorAction Stop
    $pluginRoot = Join-Path $extractDir 'Modules/Plugins'
    $pluginModules = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File -Filter '*.psm1' -ErrorAction Stop | Where-Object { $_.FullName -notmatch '[\\/]helpers[\\/]' -and $_.Name -notmatch 'Helpers\.psm1$' } | Sort-Object -Property FullName)
    $pluginManifests = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File -Filter '*.plugin.json' -ErrorAction Stop | Sort-Object -Property FullName)
    if ($pluginModules.Count -eq 0 -or $pluginModules.Count -ne $pluginManifests.Count) { throw 'Plugin manifest pairing count mismatch' }
    $manifestSet = @{}
    foreach ($pluginManifest in $pluginManifests) {
        $modulePath = $pluginManifest.FullName.Substring(0, $pluginManifest.FullName.Length - '.plugin.json'.Length) + '.psm1'
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Plugin module missing for '$($pluginManifest.FullName)'" }
        $manifest = Get-Content -LiteralPath $pluginManifest.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $baseName = $pluginManifest.Name.Substring(0, $pluginManifest.Name.Length - '.plugin.json'.Length)
        if ([string]::IsNullOrWhiteSpace([string]$manifest.name) -or [string]$manifest.name -ne $baseName) { throw "Plugin manifest name mismatch for '$($pluginManifest.Name)'" }
        if ([string]::IsNullOrWhiteSpace([string]$manifest.entryPoint) -or [System.IO.Path]::GetFileName([string]$manifest.entryPoint) -ne ([System.IO.Path]::GetFileName($modulePath))) { throw "Plugin manifest entryPoint mismatch for '$($pluginManifest.Name)'" }
        $manifestSet[$modulePath] = $true
    }
    foreach ($pluginModule in $pluginModules) {
        if (-not $manifestSet.ContainsKey($pluginModule.FullName)) { throw "Plugin manifest missing for '$($pluginModule.FullName)'" }
    }
    $registered = @(Get-RegisteredPlugins)
    if ($registered.Count -ne $pluginModules.Count) { throw "Plugin registration count mismatch: expected $($pluginModules.Count), got $($registered.Count)" }
    Write-Host ("[SELFTEST] PASS: {0} scripts, {1} plugins, manifest verified" -f $files.Count, $registered.Count)
}

function Remove-StandaloneModules {
    $prefix = $extractDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    # Shared accessors, with a local fallback: this module also runs inside the
    # emitted self-contained bundle, where PathUtils may not be present, and an
    # unresolved command here aborted the whole bundle.
    $comparison = 'Ordinal'
    if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { $comparison = [string](Get-PathComparison) }
    else {
        # $IsWindows does NOT exist on Windows PowerShell 5.1, and this module
        # runs under Set-StrictMode -Version 1.0, where touching an undefined
        # variable is a TERMINATING error rather than $false. Testing it first
        # therefore threw on 5.1 and made the correct fallbacks below
        # unreachable. Both checks used here are 5.1-safe.
        $sbIsWin = $false
        if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { try { $sbIsWin = [bool](Test-IsWindowsHost) } catch { $sbIsWin = $false } }
        else { try { $sbIsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) } catch { $sbIsWin = $false } }
        if ($sbIsWin) { $comparison = 'OrdinalIgnoreCase' }
    }

    foreach ($module in @(Get-Module -ErrorAction SilentlyContinue)) {
        if ($module.Path -and $module.Path.StartsWith($prefix, $comparison)) { Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue }
    }
}

$extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-standalone-' + [guid]::NewGuid().ToString('N'))
$script:StandaloneExitCode = 1
$hadGlobalState = Test-Path Variable:global:GState
$priorGlobalState = if ($hadGlobalState) { $global:GState } else { $null }
try {
    [void][System.IO.Directory]::CreateDirectory($extractDir)
    $manifestData = Assert-StandaloneRuntimeManifest
    Restore-StandaloneFiles -ManifestData $manifestData
    $bundleRoot = Join-Path $extractDir 'gbuild.ps1'
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Leaf)) { throw 'Extracted gbuild.ps1 is missing' }
    if ($SelfTest.IsPresent) {
        Invoke-StandaloneSelfTest
        $script:StandaloneExitCode = 0
    } else {
        $gbParams = @{}
        if ($Project) { $gbParams['Project'] = $Project }
        if ($GitHub.IsPresent) { $gbParams['GitHub'] = $true }
        if ($Incremental.IsPresent) { $gbParams['Incremental'] = $true }
        if ($Clean.IsPresent) { $gbParams['Clean'] = $true }
        if ($CacheClear.IsPresent) { $gbParams['CacheClear'] = $true }
        if ($CacheOptimize.IsPresent) { $gbParams['CacheOptimize'] = $true }
        if ($CacheStats.IsPresent) { $gbParams['CacheStats'] = $true }
        if ($VersionBump.IsPresent) { $gbParams['VersionBump'] = $true }
        if ($Security.IsPresent) { $gbParams['Security'] = $true }
        if ($Distributed.IsPresent) { $gbParams['Distributed'] = $true }
        if ($NonInteractive.IsPresent) { $gbParams['NonInteractive'] = $true }
        if ($Force.IsPresent) { $gbParams['Force'] = $true }
        if ($Target) { $gbParams['Target'] = $Target }
        if ($Locale) { $gbParams['Locale'] = $Locale }
        if ($LogLevel) { $gbParams['LogLevel'] = $LogLevel }
        if ($License.IsPresent) { $gbParams['License'] = $true }
        if ($Help.IsPresent) { $gbParams['Help'] = $true }
        if ($VerifyInfra.IsPresent) { $gbParams['VerifyInfra'] = $true }
        if ($SyntaxCheck.IsPresent) { $gbParams['SyntaxCheck'] = $true }
        $global:GState = $null
        & $bundleRoot @gbParams @AdditionalArgs
        $script:StandaloneExitCode = if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    }
} catch {
    Write-Host ("[FATAL] " + $_.Exception.Message) -ForegroundColor Red
    $script:StandaloneExitCode = 1
} finally {
    try { Remove-StandaloneModules } catch {
        Write-Host ((Resolve-LogMessage -Key 'log.standalone.removeModulesFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[FATAL] Failed to remove extracted modules: {0}')) -ForegroundColor Red
        $script:StandaloneExitCode = 1
    }
    try {
        if ($hadGlobalState) { $global:GState = $priorGlobalState } else { Remove-Variable -Name GState -Scope Global -ErrorAction SilentlyContinue }
    } catch {
        Write-Host ((Resolve-LogMessage -Key 'log.standalone.restoreStateFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[FATAL] Failed to restore global state: {0}')) -ForegroundColor Red
        $script:StandaloneExitCode = 1
    }
    try {
        if ([System.IO.Directory]::Exists($extractDir)) { [System.IO.Directory]::Delete($extractDir, $true) }
    } catch {
        Write-Host ((Resolve-LogMessage -Key 'log.standalone.cleanDirFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[FATAL] Failed to clean extraction directory: {0}')) -ForegroundColor Red
        $script:StandaloneExitCode = 1
    }
}
exit $script:StandaloneExitCode
'@)
    $body = ($sb.ToString() -replace "`r`n", "`n") -replace "`r", "`n"
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { return @{ Status = 'Failed'; Reason = "Generated bundle parse failed: $($parseErrors[0].Message)"; OutputPath = $OutputPath } }
    try {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($OutputPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return @{ Status = 'Failed'; Reason = "Write failed: $($_.Exception.Message)"; OutputPath = $OutputPath }
    }
    $fileCount = @(Get-StandaloneObjectProperty -Object $Manifest -Name 'files').Count
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $manifestHash = Get-StandaloneHash -Bytes ([System.Text.Encoding]::UTF8.GetBytes($manifestJson))
    return @{ Status = 'OK'; Reason = ''; OutputPath = $OutputPath; Files = $fileCount; Bytes = $bodyBytes.Length; SHA256 = (Get-StandaloneHash -Bytes $bodyBytes); ManifestSHA256 = $manifestHash; Version = $Version }
}

function New-StandaloneBundle {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$OutputPath = ''
    )
    $cfg = Get-StandaloneConfig -State $State
    if (-not $cfg -or -not $cfg.enabled) {
        return @{ Status = 'Skipped'; Reason = 'build.standalone.enabled is false'; OutputPath = ''; Files = 0; Bytes = 0; Sidecars = $null }
    }
    if (-not $OutputPath) { $OutputPath = Get-StandaloneOutputPath -State $State }
    try {
        $files = Get-EmbeddedFiles -State $State
        if ($files.Count -eq 0) { throw (Resolve-LogMessage -Key 'log.standalone.noEmbeddableFiles' -Fallback 'No embeddable files found') }
        Assert-StandaloneResourceSet -FileList $files
        $version = Get-StandaloneBundleVersion -State $State
        if ([string]::IsNullOrWhiteSpace($version)) { throw (Resolve-LogMessage -Key 'log.standalone.bundleVersionEmpty' -Fallback 'Standalone bundle version is empty') }
        $manifest = New-StandaloneManifest -FileList $files -Version $version
        Assert-StandaloneManifest -Manifest $manifest -RequireRuntimeResources
        $payload = ConvertTo-Base64Payload -FileList $files -Strict -Manifest $manifest -Version $version
    } catch {
        return @{ Status = 'Failed'; Reason = $_.Exception.Message; OutputPath = $OutputPath; Files = 0; Bytes = 0; Sidecars = $null }
    }
    $result = New-StandaloneBundleScript -State $State -OutputPath $OutputPath -PayloadLines $payload -Version $version -Manifest $manifest
    if ($result.Status -ne 'OK') { return $result }
    Write-Log (Resolve-LogMessage -Key 'log.standalone.bundleCreated' -MessageArgs @([string]$OutputPath, $files.Count, $result.Bytes) -Fallback '[STANDALONE] Bundle created: {0} ({1} files, {2} bytes)') 'Info' $State
    try {
        $signing = Get-StandaloneBundleSignature -BundlePath $OutputPath -State $State -Detailed
    } catch {
        $signing = @{ Status = 'Failed'; Reason = $_.Exception.Message; ArtifactPath = '' }
    }
    try {
        $supplyChain = New-StandaloneBundleSupplyChain -BundlePath $OutputPath -State $State -Detailed
    } catch {
        $supplyChain = @{ Status = 'Failed'; Reason = $_.Exception.Message; SBOM = @{ Status = 'Failed'; Reason = $_.Exception.Message; ArtifactPath = '' }; Provenance = @{ Status = 'Skipped'; Reason = 'Not attempted after supply-chain failure'; ArtifactPath = '' } }
    }
    $result['Sidecars'] = [PSCustomObject]@{ Signing = $signing; SBOM = $supplyChain.SBOM; Provenance = $supplyChain.Provenance; SupplyChain = $supplyChain.Status }
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($signing.Status -eq 'Failed') { $failures.Add('Signing: ' + $signing.Reason) }
    if ($supplyChain.Status -eq 'Failed') { $failures.Add('SupplyChain: ' + $supplyChain.Reason) }
    if ($failures.Count -gt 0) {
        $result['Status'] = 'Failed'
        $result['Reason'] = $failures -join '; '
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-StandaloneConfig',
    'Get-StandaloneBundleVersion',
    'Get-StandaloneOutputPath',
    'Get-EmbeddedFiles',
    'New-StandaloneManifest',
    'ConvertTo-Base64Payload',
    'New-StandaloneBundleScript',
    'New-StandaloneBundle',
    'Get-StandaloneBundleSignature',
    'New-StandaloneBundleSupplyChain'
)




