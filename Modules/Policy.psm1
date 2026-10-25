# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
<#
.SYNOPSIS
    Policy-as-code for gbuild: evaluates Rego policies (OPA) against the build input.
.DESCRIPTION
    Supports two modes:
      1. OPA CLI (opa eval) — when the `opa` binary is present on the machine, reads
         policies from `security.policy.dir` (.rego files) and evaluates the query
         `data.<package>.deny`.
      2. Built-in evaluator — a Rego-mini engine driven by a JSON allow/deny rule list
         (security.policy.rules) with no OPA binary needed. Exposes the same return
         contract (Pass/Violations) so the pipeline cannot tell the backends apart.
    Graceful-degrade: when both backends are unavailable, returns Pass with Status
    'Skipped' — never fails the build due to missing configuration.
#>

# -- Import Logging + SharedUtils + PathUtils (root-selection helper) --
Import-BuildModule -Dependencies @('SharedUtils', 'PathUtils')
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Get-OSPlatform'




<#
.SYNOPSIS
    Checks whether the OPA binary is available on this machine.
#>
function Test-OpaAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

Set-StrictMode -Version 1.0
    return [bool](Get-Command opa -ErrorAction SilentlyContinue)
}








function Get-PolicyConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $sec = Get-ConfigSection -State $State -Path 'security'
    if (-not $sec) { return $null }
    if ($sec -is [System.Collections.IDictionary]) { return $(if ($sec.ContainsKey('policy')) { $sec['policy'] } else { $null }) }
    if ($sec.PSObject.Properties.Name -contains 'policy') { return $sec.policy }
    return $null
}

function Get-PolicyInput {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $projectPath = ''
    if ($ProjectDir) { try { $projectPath = [System.IO.Path]::GetFullPath($ProjectDir) } catch { $projectPath = '' } }
    $build = Get-ConfigSection -State $State -Path 'build'
    $defaultConfiguration = ''
    $enableParallel = $false
    $enableIncremental = $false
    if ($build) {
        if ($build -is [System.Collections.IDictionary]) {
            if ($build.Contains('defaultConfiguration')) { $defaultConfiguration = [string]$build['defaultConfiguration'] }
            if ($build.Contains('enableParallelBuild')) { $enableParallel = [bool]$build['enableParallelBuild'] }
            if ($build.Contains('enableIncremental')) { $enableIncremental = [bool]$build['enableIncremental'] }
        } else {
            if ($build.PSObject.Properties.Name -contains 'defaultConfiguration') { $defaultConfiguration = [string]$build.defaultConfiguration }
            if ($build.PSObject.Properties.Name -contains 'enableParallelBuild') { $enableParallel = [bool]$build.enableParallelBuild }
            if ($build.PSObject.Properties.Name -contains 'enableIncremental') { $enableIncremental = [bool]$build.enableIncremental }
        }
    }
    if ($defaultConfiguration -match '\$\{env:' -or $defaultConfiguration -match '(?i)(secret|password|token|key)') { $defaultConfiguration = '' }
    $safeBuild = [ordered]@{ defaultConfiguration = $defaultConfiguration; enableParallel = $enableParallel; enableIncremental = $enableIncremental }
$files = [System.Collections.Generic.List[object]]::new()
    # An INCOMPLETE file list must not read as "no violations". A recursive
    # Get-ChildItem -ErrorAction Stop throws on one unreadable subdirectory
    # (a monorepo with a single ACL-denied folder is enough); the old `catch { }`
    # swallowed it and returned a partial/empty `files`, so every rule matching on
    # file path or extension evaluated against nothing and the gate reported
    # Passed. Record the incompleteness so the evaluators can fail closed.
    $filesComplete = $true
    $filesError = ''
    if ($projectPath -and (Test-Path -LiteralPath $projectPath -PathType Container)) {
        try {
            # Single source for the scan-exclusion pattern: Security.Get-SecurityExcludeDirPattern,
            # which unions security.excludeDirs with build.syntaxCheck.excludeDirs and
            # honours config. This was a hand-written 5-entry literal, duplicated twice
            # IN THIS FILE and once more in Sast.psm1 and SupplyChain.psm1 (with a
            # different order), so security.excludeDirs was ignored by the policy gate.
    $policyExclude = Get-PolicyExcludePattern
    foreach ($file in @(Get-ChildItem -LiteralPath $projectPath -Recurse -File -ErrorAction Stop | Where-Object { $_.FullName -notmatch $policyExclude })) {
                $files.Add([PSCustomObject]@{ path = ($file.FullName.Substring($projectPath.Length).TrimStart('\','/') -replace '\\','/'); extension = $file.Extension.ToLowerInvariant() })
            }
        } catch {
            $filesComplete = $false
            $filesError = [string]$_.Exception.Message
        }
    }
    return [PSCustomObject]@{
        project = [PSCustomObject]@{ name = if ($projectPath) { Split-Path $projectPath -Leaf } else { '' }; type = [string]$ProjectType; path = $projectPath }
        build = [PSCustomObject]$safeBuild
        config = [PSCustomObject]@{ build = [PSCustomObject]$safeBuild }
        files = @($files)
        # Fail-closed signal for the evaluators: a partial scan must not be
        # indistinguishable from a clean one.
        filesComplete = $filesComplete
        filesError = $filesError
        os = if ($State -and $State.PSObject.Properties.Name -contains 'OS' -and $State.OS) { [string]$State.OS } else { '' }
        tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
        correlationId = if ($State -and $State.PSObject.Properties.Name -contains 'CorrelationId' -and $State.CorrelationId) { [string]$State.CorrelationId } else { '' }
    }
}

function Get-PolicyDir {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $cfg = Get-PolicyConfig -State $State
    $dir = if ($cfg) { [string](Get-SectionValue -Section $cfg -Key 'dir' -Default '') } else { '' }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = 'policy' }
    if ($dir -match '\$\{env:' -and (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue)) { $dir = [string](Resolve-EnvPlaceholder -Text $dir) }
    if ($dir -match '[\x00]' -or $dir -match '\$\{env:') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line129' -Fallback 'Policy directory is invalid.')) }
        # Root selection single-sourced in PathUtils.Get-BuildRootDirectory
        # (ProjectRoot > ScriptRoot); guarded for the PS 5.1-orphan path.
        $root = if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State }
                elseif ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
    $full = if ([System.IO.Path]::IsPathRooted($dir)) { [System.IO.Path]::GetFullPath($dir) } else { [System.IO.Path]::GetFullPath((Join-Path $root $dir)) }
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\','/')
    $allowExternal = $false
    if ($cfg) { $allowExternal = [bool](Get-SectionValue -Section $cfg -Key 'allowExternalDir' -Default $false) }
    if (-not $allowExternal) {
        # Policy directories use the same containment owner as every other
        # rooted resolver. Unlike the owner, an exact match on the project root
        # remains rejected here: selecting the whole repository as the policy
        # directory requires the explicit allowExternalDir opt-in.
        $contained = $false
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
            try { $contained = Test-PathUnderRoots -Path $full -AllowedRoots @($rootFull) } catch { $contained = $false }
        } else {
            $comparison = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison } else { if ((Get-OSPlatform) -eq 'Windows') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
            try { $contained = $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison) } catch { $contained = $false }
        }
        if (-not $contained -or $full -eq $rootFull) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line150' -Fallback 'Policy directory is outside the project root.')) }
    }
    return $full
}

function Get-PolicyRuleProperty {
    param($Rule, [string]$Name, $Default = $null)
    if ($null -eq $Rule) { return $Default }
    if ($Rule -is [System.Collections.IDictionary]) { if ($Rule.Contains($Name)) { return $Rule[$Name] }; return $Default }
    if ($Rule.PSObject.Properties.Name -contains $Name) { return $Rule.$Name }
    return $Default
}

function Test-PolicyPatternValue {
    param([string]$Value, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern) -or $Pattern -eq '*') { return $true }
    try {
        if ($Pattern.StartsWith('(?') -or $Pattern -match '\\[|\\]|\^|\$|\+|\{|\}|\(\?') { return $Value -match $Pattern }
    } catch { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line168' -Fallback 'Policy rule contains an invalid expression.')) }
    return $Value -like $Pattern
}

# SINGLE SOURCE for the policy gate's source-exclusion pattern. This literal
# was written out twice in this file and once more in Sast.psm1 and
# SupplyChain.psm1 (with a different ordering), so security.excludeDirs was
# ignored by the policy scanner while the secret scanner honoured it.
function Get-PolicyExcludePattern {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Get-SecurityExcludeDirPattern -ErrorAction SilentlyContinue) {
        $p = [string](Get-SecurityExcludeDirPattern)
        if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
    }
    if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
        try { $p = [string](Get-ExcludeDirPattern); if (-not [string]::IsNullOrWhiteSpace($p)) { return $p } } catch { }
    }
    # Documented standalone fallback: no module available (partial copy).
    return '[\\/](_Build|node_modules|\.git|bin|obj)[\\/]'
}

function Test-PolicyPathMatch {
    param([string]$Value, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }
    # Multi-glob: config rules separate alternatives with commas
    # ("**/*.ps1,**/*.cs,..."). The matcher used to treat the whole string as ONE
    # -like pattern, so a comma rule could never match a real filename and the
    # rule was silently dead. Split first, match ANY.
    foreach ($alt in @($Pattern -split ',')) {
        $alt = $alt.Trim()
        if ([string]::IsNullOrWhiteSpace($alt)) { continue }
        $normalized = ($alt -replace '\\','/') -replace '\*\*/','*'
        $normalized = $normalized -replace '\*\*/','*'
        $normalized = $normalized -replace '\*\*','*'
        if (($Value -replace '\\','/') -like $normalized) { return $true }
    }
    return $false
}

function Get-PolicyRuleMatches {
    param($Rule, [PSCustomObject]$InputObject, [string]$ProjectDir)
    $matchName = [string](Get-PolicyRuleProperty -Rule $Rule -Name 'match' -Default '')
    $pathPattern = [string](Get-PolicyRuleProperty -Rule $Rule -Name 'path' -Default '')
    $valuePattern = [string](Get-PolicyRuleProperty -Rule $Rule -Name 'value' -Default '')
    $exclude = @(Get-PolicyRuleProperty -Rule $Rule -Name 'excludePaths' -Default @())
    $found = [System.Collections.Generic.List[object]]::new()
    if ($matchName -eq 'FileContent') {
        $root = if ($ProjectDir) { $ProjectDir } else { [string]$InputObject.project.path }
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line218' -Fallback 'Policy file root is unavailable.')) }
        $rootFull = [System.IO.Path]::GetFullPath($root)
        $policyExclude2 = Get-PolicyExcludePattern
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction Stop | Where-Object { $_.FullName -notmatch $policyExclude2 })) {
            $relative = ($file.FullName.Substring($rootFull.Length).TrimStart('\','/') -replace '\\','/')
            if ($pathPattern -and -not (Test-PolicyPathMatch -Value $relative -Pattern $pathPattern)) { continue }
            $excluded = $false
            foreach ($x in $exclude) { if ((Test-PolicyPathMatch -Value $relative -Pattern ([string]$x)) -or (Test-PolicyPathMatch -Value $file.FullName -Pattern ([string]$x))) { $excluded = $true; break } }
            if ($excluded) { continue }
            $content = [System.IO.File]::ReadAllText($file.FullName)
            # Per-line findings with locations: a whole-file boolean told the
            # operator "N violations" with no file:line to open. Line text is
            # deliberately NOT carried (Value stays 'matched') so a secrets
            # rule can never leak the secret into reports and logs.
            $lineNo = 0
            foreach ($line in @($content -split "`r?`n")) {
                $lineNo++
                if (Test-PolicyPatternValue -Value $line -Pattern $valuePattern) { $found.Add([PSCustomObject]@{ Key = $relative; Line = $lineNo; Value = 'matched' }) }
            }
        }
        return @($found)
    }
    foreach ($entry in @(ConvertTo-PolicyFlatEntry -Root $InputObject)) {
        $key = if ($entry.Contains('=')) { $entry.Substring(0, $entry.IndexOf('=')) } else { $entry }
        $value = if ($entry.Contains('=')) { $entry.Substring($entry.IndexOf('=') + 1) } else { '' }
        if ($pathPattern -and -not (Test-PolicyPathMatch -Value $key -Pattern $pathPattern)) { continue }
        if ($matchName -and $matchName -notin @('ConfigKey','FileContent') -and $key -notlike $matchName -and $value -notlike $matchName) { continue }
        if (-not (Test-PolicyPatternValue -Value $value -Pattern $valuePattern)) { continue }
        $excluded = $false
        foreach ($x in $exclude) { if ($key -like ([string]$x)) { $excluded = $true; break } }
        if (-not $excluded) { $found.Add([PSCustomObject]@{ Key = $key; Value = $value }) }
    }
    return @($found)
}

function Invoke-OpaPolicy {
    [CmdletBinding()]
    param([PSCustomObject]$State, [PSCustomObject]$InputObject, [string]$ProjectDir)
    $policyDir = Get-PolicyDir -State $State
    $regoFiles = @()
    if (Test-Path -LiteralPath $policyDir -PathType Container) { $regoFiles = @(Get-ChildItem -LiteralPath $policyDir -Filter '*.rego' -File -Recurse -ErrorAction Stop) }
    if ($regoFiles.Count -eq 0) { return @{ Status = 'Skipped'; Reason = 'No Rego policies found'; Violations = @(); Backend = 'opa' } }
    if (-not (Test-OpaAvailable)) { return @{ Status = 'Failed'; Reason = 'opa CLI not installed'; Violations = @(); Backend = 'opa' } }
    # Same fail-closed rule as Invoke-BuiltinPolicy: a truncated project file
    # list would hand `opa eval` a partial input and any path/extension rule
    # would silently match nothing.
    if ($InputObject -and $InputObject.PSObject.Properties.Name -contains 'filesComplete' -and -not [bool]$InputObject.filesComplete) {
        $why = [string]$InputObject.filesError
        if (-not $why) { $why = 'project file scan incomplete' }
        return @{ Status = 'Failed'; Reason = "policy scan incomplete: $why"; Violations = @(); Backend = 'opa' }
    }
    $cfg = Get-PolicyConfig -State $State
    $package = [string](Get-SectionValue -Section $cfg -Key 'package' -Default 'gbuild.policy')
    if ($package -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') { return @{ Status = 'Failed'; Reason = 'OPA package is invalid'; Violations = @(); Backend = 'opa' } }
    $inputFile = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-opa-input-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = $InputObject | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } else { 20 }) -Compress
        [System.IO.File]::WriteAllText($inputFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        $arguments = @('eval', '--data', $policyDir, '--input', $inputFile, '--format', 'json', ('data.' + $package + '.deny'))
        $resolved = Get-Command opa -ErrorAction Stop
        if ($resolved.CommandType -eq 'Application' -and (Get-Command Invoke-WithLiveOutput -ErrorAction SilentlyContinue)) {
            $timeout = 30
            # opaServerTimeoutSec is the schema-declared key for this transport
            # (security.policy: opaServerTimeoutSec). 'timeoutSec' was the legacy
            # alias the code used to read - it is NOT in the schema and so could
            # never be set by an operator. Keep the alias read for backwards
            # compat, opaServerTimeoutSec wins when both are present.
            if ($cfg) {
                foreach ($k in @('opaServerTimeoutSec','timeoutSec')) {
                    if ($cfg.PSObject.Properties.Name -contains $k -and $cfg.$k) {
                        try { $timeout = [Math]::Max(1, [int]$cfg.$k) } catch { }
                        break
                    }
                }
            }
            $run = Invoke-WithLiveOutput -FilePath $resolved.Source -ArgList $arguments -State $State -Label 'OPA eval' -Quiet -TimeoutSec $timeout
            if ($run.TimedOut -or [int]$run.ExitCode -ne 0) {
                # Propagate the underlying cause instead of a bare 'OPA evaluation
                # failed': a governance gate that turns red with no diagnostic is
                # worse than the failure itself, because no one can tell whether
                # to fix the policy, the tool, or the data shape.
                $detail = 'OPA evaluation failed'
                if ($run.TimedOut) { $detail = 'OPA evaluation timed out after ' + [string]$timeout + 's' }
                try { if ($run.Output) { $detail = $detail + ' | ' + ($run.Output | Out-String).Trim() } } catch { }
                return @{ Status = 'Failed'; Reason = $detail; Violations = @(); Backend = 'opa' }
            }
            $output = @($run.Output) -join "`n"
        } else {
            Push-Location -LiteralPath $policyDir
            try { $output = (& opa @arguments 2>&1 | Out-String); $exitCode = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue)) { [int]$LASTEXITCODE } else { 0 } } finally { Pop-Location }
            if ($exitCode -ne 0) { return @{ Status = 'Failed'; Reason = 'OPA evaluation failed'; Violations = @(); Backend = 'opa' } }
        }
        $parsed = $output | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'result')) { throw (Resolve-LogMessage -Key 'log.policy.line311' -Fallback 'OPA result missing') }
        $violations = [System.Collections.Generic.List[object]]::new()
        foreach ($result in @($parsed.result)) {
            if ($null -eq $result -or -not ($result.PSObject.Properties.Name -contains 'expressions')) { throw (Resolve-LogMessage -Key 'log.policy.line314' -Fallback 'OPA expression missing') }
            foreach ($expression in @($result.expressions)) {
                foreach ($item in @($expression.value)) {
                    if ($item -is [array] -and $item.Count -ge 2) { $violations.Add([PSCustomObject]@{ Rule = [string]$item[0]; Message = [string]$item[1] }) }
                    elseif ($null -ne $item) { $violations.Add([PSCustomObject]@{ Rule = 'opa'; Message = [string]$item }) }
                }
            }
        }
        if ($violations.Count -gt 0) { return @{ Status = 'Blocked'; Reason = "$($violations.Count) OPA violation(s)"; Violations = @($violations); Backend = 'opa' } }
        return @{ Status = 'Passed'; Reason = ''; Violations = @(); Backend = 'opa' }
    } catch {
        $msg = $_.Exception.Message
        if (-not $msg) { $msg = 'OPA evaluation failed' }
        return @{ Status = 'Failed'; Reason = ('OPA evaluation failed: ' + $msg); Violations = @(); Backend = 'opa' }
    } finally {
        if (Test-Path -LiteralPath $inputFile) { Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-OpaServerPolicy {
    [CmdletBinding()]
    param([PSCustomObject]$State, [PSCustomObject]$InputObject)
    $cfg = Get-PolicyConfig -State $State
    $url = [string](Get-BuildConstant -Key 'PolicyOpaServerUrl' -State $State -Fallback '')
    if ([string]::IsNullOrWhiteSpace($url)) { return @{ Status = 'Skipped'; Reason = 'OPA server URL not configured'; Violations = @(); Backend = 'opa-server' } }
    try {
        $uri = [Uri]$url
        if ($uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $uri.Fragment) { throw (Resolve-LogMessage -Key 'log.policy.line341' -Fallback 'invalid URL') }
        if ($uri.Scheme -eq 'http' -and $uri.Host -notin @('localhost','127.0.0.1','::1')) { throw (Resolve-LogMessage -Key 'log.policy.line342' -Fallback 'insecure URL') }
    } catch { return @{ Status = 'Failed'; Reason = 'OPA server URL is invalid'; Violations = @(); Backend = 'opa-server' } }
    $package = if ($cfg) { [string](Get-SectionValue -Section $cfg -Key 'package' -Default 'gbuild.policy') } else { 'gbuild.policy' }
    if ($package -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') { return @{ Status = 'Failed'; Reason = 'OPA package is invalid'; Violations = @(); Backend = 'opa-server' } }
    $path = '/v1/data/' + ($package -replace '\.', '/')
    try {
        $timeout = [int](Get-BuildConstant -Key 'PolicyOpaServerTimeoutSec' -State $State -Fallback 10)
        if ($timeout -le 0) { $timeout = 10 }
        $body = @{ input = $InputObject } | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDeepDepth' -Fallback 20) } else { 20 }) -Compress
        $response = Invoke-RestMethod -Uri ($url.TrimEnd('/') + $path) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeout -ErrorAction Stop
        if ($null -eq $response -or -not ($response.PSObject.Properties.Name -contains 'result')) { throw (Resolve-LogMessage -Key 'log.policy.line352' -Fallback 'missing result') }
        $result = $response.result
        if ($null -eq $result) { throw (Resolve-LogMessage -Key 'log.policy.line354' -Fallback 'missing result') }
        $deny = if ($result -is [System.Collections.IDictionary]) { if ($result.Contains('deny')) { $result['deny'] } else { throw (Resolve-LogMessage -Key 'log.policy.line355' -Fallback 'missing deny') } } elseif ($result.PSObject.Properties.Name -contains 'deny') { $result.deny } else { $result }
        $violations = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($deny)) {
            if ($item -is [array] -and $item.Count -ge 2) { $violations.Add([PSCustomObject]@{ Rule = [string]$item[0]; Message = [string]$item[1] }) }
            elseif ($item -is [string]) { $violations.Add([PSCustomObject]@{ Rule = 'opa-server'; Message = $item }) }
            elseif ($item.PSObject.Properties.Name -contains 'msg') { $violations.Add([PSCustomObject]@{ Rule = [string]$item.rule; Message = [string]$item.msg }) }
        }
        if ($violations.Count -gt 0) { return @{ Status = 'Blocked'; Reason = "$($violations.Count) OPA violation(s)"; Violations = @($violations); Backend = 'opa-server' } }
        return @{ Status = 'Passed'; Reason = ''; Violations = @(); Backend = 'opa-server' }
    } catch { return @{ Status = 'Failed'; Reason = 'OPA server evaluation failed'; Violations = @(); Backend = 'opa-server' } }
}

function Invoke-BuiltinPolicy {
    [CmdletBinding()]
    param([PSCustomObject]$State, [PSCustomObject]$InputObject)
    $cfg = Get-PolicyConfig -State $State
    if (-not $cfg) { return @{ Status = 'Failed'; Reason = 'security.policy is not configured'; Violations = @(); Backend = 'builtin' } }
    # A PARTIAL file scan cannot conclude "no violations". Get-PolicyInput sets
    # filesComplete=$false when the recursive enumeration threw; evaluating
    # path/extension rules against a truncated list would report Passed for a
    # tree that was never fully examined.
    if ($InputObject -and $InputObject.PSObject.Properties.Name -contains 'filesComplete' -and -not [bool]$InputObject.filesComplete) {
        $why = [string]$InputObject.filesError
        if (-not $why) { $why = 'project file scan incomplete' }
        return @{ Status = 'Failed'; Reason = "policy scan incomplete: $why"; Violations = @(); Backend = 'builtin' }
    }
    $rules = @(Get-SectionValue -Section $cfg -Key 'rules' -Default @())
    if ($rules.Count -eq 0) { return @{ Status = 'Failed'; Reason = 'security.policy.rules is empty'; Violations = @(); Backend = 'builtin' } }
    $projectDir = if ($InputObject -and $InputObject.project) { [string]$InputObject.project.path } else { '' }
    $violations = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($rule in $rules) {
            $action = [string](Get-PolicyRuleProperty -Rule $rule -Name 'action' -Default 'deny')
            if ($action -notin @('deny','allow')) { throw (Resolve-LogMessage -Key 'log.policy.line388' -Fallback 'invalid policy action') }
            if ($action -eq 'allow') { continue }
            $ruleName = [string](Get-PolicyRuleProperty -Rule $rule -Name 'rule' -Default 'policy')
            foreach ($match in @(Get-PolicyRuleMatches -Rule $rule -InputObject $InputObject -ProjectDir $projectDir)) {
                # Carry the location (file:line for FileContent, config key
                # otherwise): a bare "Policy rule matched" names nothing to
                # open, which is why violations were undebuggable.
                $loc = ''
                try {
                    if ($match -is [System.Collections.IDictionary]) {
                        if ($match.Contains('Key')) { $loc = [string]$match['Key'] }
                        if ($match.Contains('Line') -and [int]$match['Line'] -gt 0) { $loc += ':' + [string]$match['Line'] }
                    } else {
                        if ($match.PSObject.Properties.Name -contains 'Key') { $loc = [string]$match.Key }
                        if ($match.PSObject.Properties.Name -contains 'Line' -and [int]$match.Line -gt 0) { $loc += ':' + [string]$match.Line }
                    }
                } catch { $loc = '' }
                $msg = if ($loc) { "Policy rule matched at $loc" } else { 'Policy rule matched' }
                $violations.Add([PSCustomObject]@{ Rule = $ruleName; Message = $msg })
            }
        }
    } catch { return @{ Status = 'Failed'; Reason = 'Builtin policy evaluation failed'; Violations = @(); Backend = 'builtin' } }
    if ($violations.Count -gt 0) { return @{ Status = 'Blocked'; Reason = "$($violations.Count) policy violation(s)"; Violations = @($violations); Backend = 'builtin' } }
    return @{ Status = 'Passed'; Reason = ''; Violations = @(); Backend = 'builtin' }
}

function Invoke-PolicyChecks {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-PolicyConfig -State $State
    if (-not $cfg -or -not $cfg.enabled) { return @{ Pass = $true; Status = 'Skipped'; Reason = 'security.policy.enabled is false'; Violations = @(); Backend = ''; Enforcement = '' } }
    $enforcement = [string](Get-SectionValue -Section $cfg -Key 'enforcement' -Default 'block')
    $inputObject = Get-PolicyInput -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType
    $server = Invoke-OpaServerPolicy -State $State -InputObject $inputObject
    $result = $null
    if ($server.Status -ne 'Skipped') { $result = $server }
    else {
        $local = Invoke-OpaPolicy -State $State -InputObject $inputObject -ProjectDir $ProjectDir
        if ($local.Status -eq 'Failed' -or $local.Status -eq 'Blocked' -or $local.Status -eq 'Passed') { $result = $local }
        else { $result = Invoke-BuiltinPolicy -State $State -InputObject $inputObject }
    }
    if ($result.Status -eq 'Failed') {
        if ($enforcement -eq 'fail') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line430' -Fallback 'Policy backend evaluation failed.')) }
        $pass = ($enforcement -eq 'warn')
        return @{ Pass = $pass; Status = 'Failed'; Reason = $result.Reason; Violations = @(); Backend = $result.Backend; Enforcement = $enforcement }
    }
    if ($result.Status -eq 'Passed' -or $result.Status -eq 'Skipped') { return @{ Pass = $true; Status = $result.Status; Reason = $result.Reason; Violations = @(); Backend = $result.Backend; Enforcement = $enforcement } }
    $out = Invoke-PolicyEnforcement -Scope 'POLICY' -Violations @($result.Violations) -Enforcement $enforcement -State $State
    $out['Backend'] = $result.Backend
    $out['Reason'] = $result.Reason
    $out['Enforcement'] = $enforcement
    return $out
}

function Invoke-PolicyEnforcement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Violations, [string]$Enforcement = 'block', [PSCustomObject]$State = $null)
    $count = @($Violations).Count
    if ($count -eq 0) { return @{ Pass = $true; Status = 'Passed'; Violations = @() } }
    $safe = [string]$Scope
    switch ($Enforcement.ToLowerInvariant()) {
        'block' { return @{ Pass = $false; Status = 'Blocked'; Violations = @($Violations) } }
        'fail' { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.policy.line450' -MessageArgs @([string]$safe, [string]$count) -Fallback "[$safe] 'fail' triggered: $count violation(s).")) }
        'warn' { return @{ Pass = $true; Status = 'Warned'; Violations = @($Violations) } }
        default { return @{ Pass = $false; Status = 'Blocked'; Violations = @($Violations) } }
    }
}

function ConvertTo-PolicyFlatEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)
    $list = [System.Collections.Generic.List[string]]::new()
    $walk = {
        param($Node, [string]$Prefix)
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in $Node.Keys) { $next = if ($Prefix) { "$Prefix.$k" } else { [string]$k }; & $walk -Node $Node[$k] -Prefix $next }
        } elseif ($Node -is [string]) { [void]$list.Add("$Prefix=$Node") }
        elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [pscustomobject]) {
            $i = 0
            foreach ($item in $Node) { & $walk -Node $item -Prefix "$Prefix[$i]"; $i++ }
        } elseif ($Node -is [pscustomobject]) {
            foreach ($property in $Node.PSObject.Properties) { $next = if ($Prefix) { "$Prefix.$($property.Name)" } else { $property.Name }; & $walk -Node $property.Value -Prefix $next }
        } elseif ($null -ne $Node) { [void]$list.Add("$Prefix=$([string]$Node)") }
        else { [void]$list.Add("$Prefix=") }
    }
    & $walk -Node $Root -Prefix ''
    return @($list.ToArray())
}

Export-ModuleMember -Function @(
    'Get-PolicyConfig',
    'Get-PolicyInput',
    'Test-OpaAvailable',
    'Get-PolicyDir',
    'Test-PolicyPathMatch',
    'Get-PolicyRuleMatches',
    'Invoke-OpaServerPolicy',
    'Invoke-OpaPolicy',
    'Invoke-BuiltinPolicy',
    'Invoke-PolicyChecks',
    'Invoke-PolicyEnforcement'
)




