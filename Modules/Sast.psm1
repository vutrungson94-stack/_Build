# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
<#
.SYNOPSIS
    Multi-language SAST for gbuild: dispatches by the project's primary language to
    the matching tool (npm audit, bandit, cargo-audit, gosec, cppcheck, ...).
.DESCRIPTION
    Unlike PSScriptAnalyzer (PowerShell-only), this module detects the primary
    language via LanguageDetector and runs the appropriate SAST tool. The whole tool
    map can be overridden via the security.sast.tools config. Graceful-degrade: when a
    tool is not installed, log a Warn and return 'Skipped' instead of failing the build.
#>

# -- Import Logging + SharedUtils + BuildConstants (SastToolMap defaults) --
Import-BuildModule -Dependencies @('SharedUtils', 'BuildConstants', 'BuildProgress')

<#
.SYNOPSIS
    Reads the security.sast section from BuildConfig (or config profile).
#>
function Get-SastConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $sec = Get-ConfigSection -State $State -Path 'security'
    if ($sec -and ($sec.PSObject.Properties.Name -contains 'sast')) { return $sec.sast }
    return $null
}

<#
.SYNOPSIS
    Reads the per-tool SAST execution timeout (seconds).
.DESCRIPTION
    Resolution: security.sast.timeoutSec (config) -> BuildConstants SastTimeoutSec
    (default 120) -> literal 120. 0 disables the timeout (legacy unbounded wait).
#>
function Get-SastTimeoutSec {
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$State)
    $cfg = Get-SastConfig -State $State
    if ($cfg) {
        $v = Get-SectionValue -Section $cfg -Key 'timeoutSec' -Default $null
        if ($null -ne $v) {
            try { return [Math]::Max(0, [int]$v) } catch { }
        }
    }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [Math]::Max(0, [int](Get-BuildConstant -Key 'SastTimeoutSec' -Fallback 120)) } catch { }
    }
    return 120
}

<#
.SYNOPSIS
    Reads whether dotnet non-zero with no findings should be treated as Passed.
.DESCRIPTION
    Level 5 single-source: security.sast.dotnetIgnoreNoFindingsExitCode
    (BuildConstants SastDotnetIgnoreNoFindingsExitCode, default true).
#>
function Get-SastDotnetIgnoreNoFindings {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)
    $cfg = Get-SastConfig -State $State
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'dotnetIgnoreNoFindingsExitCode')) {
        try { return [bool]$cfg.dotnetIgnoreNoFindingsExitCode } catch { }
    }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [bool](Get-BuildConstant -Key 'SastDotnetIgnoreNoFindingsExitCode' -State $State -Fallback $true) } catch { }
    }
    return $true
}

<#
.SYNOPSIS
    Map language -> default SAST tool. Overridden by the security.sast.tools config.
.DESCRIPTION
    The default map comes from BuildConstants (key 'SastToolMap' — single source of truth,
    not re-declared as a literal here); security.sast.tools in config overrides each
    language at runtime.
#>
function Get-SastToolMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)
    $map = @{}
    $defaults = $null
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $defaults = Get-BuildConstant -Key 'SastToolMap' -Fallback $null
    }
    if ($defaults -is [System.Collections.IDictionary]) {
        foreach ($k in @($defaults.Keys)) { $map[[string]$k] = [string]$defaults[$k] }
    }
    $cfg = Get-SastConfig -State $State
    if ($cfg) {
        # Section accessor single-sourced via ConfigProvider.Get-SectionValue.
        $tools = Get-SectionValue -Section $cfg -Key 'tools' -Default $null
        if ($tools) {
            if ($tools -is [System.Collections.IDictionary]) {
                foreach ($k in $tools.Keys) { if ($tools[$k]) { $map[[string]$k] = [string]$tools[$k] } }
            } else {
                foreach ($prop in $tools.PSObject.Properties) {
                    if ($prop.Value) { $map[[string]$prop.Name] = [string]$prop.Value }
                }
            }
        }
    }
    return $map
}

<#
.SYNOPSIS
    Returns the command + args for a SAST tool by language.
#>
function Get-SastCommand {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Language, [PSCustomObject]$State)
    $map = Get-SastToolMap -State $State
    $tool = if ($map.ContainsKey($Language)) { $map[$Language] } else { $null }
    if (-not $tool) { return $null }
    # Directory-walking tools must skip embedded tool copies (_Build).
    # Reuse SyntaxCheckExcludeDirs filtered to the underscore family (single source);
    # fall back to the canonical _Build when BuildConstants is not loaded.
    $toolEx = @('_Build')
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $bcDirs = Get-BuildConstant -Key 'SyntaxCheckExcludeDirs' -Fallback $null
        if ($bcDirs) {
            $filtered = @(@($bcDirs) | Where-Object { $_ -like '_*' })
            if ($filtered.Count -gt 0) { $toolEx = $filtered }
        }
    }
    $exCsv = $toolEx -join ','
    switch ($tool) {
        'dotnet'      { return @{ Tool = 'dotnet'; Args = @('list', '{0}', 'package', '--vulnerable', '--include-transitive'); ToolLabel = 'dotnet vulnerability audit' } }
        'npm'         { return @{ Tool = 'npm'; Args = @('audit', '--json'); ToolLabel = 'npm audit' } }
        'bandit'      { return @{ Tool = 'bandit'; Args = @('-r', '{0}', '-f', 'json', '--exclude', $exCsv); ToolLabel = 'bandit (Python SAST)' } }
        'cargo-audit' { return @{ Tool = 'cargo-audit'; Args = @('audit', '--json'); ToolLabel = 'cargo-audit (Rust)' } }
        'gosec'       { return @{ Tool = 'gosec'; Args = @('-fmt', 'json', '{0}'); ToolLabel = 'gosec (Go SAST)' } }
        'mvn'         { return @{ Tool = 'mvn'; Args = @('org.owasp:dependency-check-maven:check', '-q'); ToolLabel = 'OWASP dependency-check (Java)' } }
        'brakeman'    { return @{ Tool = 'brakeman'; Args = @('-f', 'json', '{0}'); ToolLabel = 'brakeman (Ruby SAST)' } }
        'phpcs'       { return @{ Tool = 'phpcs'; Args = @('--report=json', "--ignore=$exCsv", '{0}'); ToolLabel = 'phpcs (PHP)' } }
        'cppcheck'    { return @{ Tool = 'cppcheck'; Args = (@(($toolEx | ForEach-Object { '-i', $_ }) + @('--xml', '{0}'))); ToolLabel = 'cppcheck (C/C++)' } }
        'swift'       { return @{ Tool = 'swiftlint'; Args = @('lint', '{0}'); ToolLabel = 'swiftlint (Swift SAST)' } }
        'mix'         { return @{ Tool = 'mix'; Args = @('format', '--check-formatted', '{0}'); ToolLabel = 'mix format check (Elixir SAST)' } }
        'trivy'       { return @{ Tool = (Get-SastToolName 'trivy'); Args = @('fs', '--format', 'json', '{0}'); ToolLabel = 'trivy fs (container/IaC SAST)' } }
        'psscriptanalyzer' { return @{ Tool = 'Invoke-ScriptAnalyzer'; Args = @(); ToolLabel = 'PSScriptAnalyzer (PowerShell)' } }
        default       { return @{ Tool = $tool; Args = @('{0}'); ToolLabel = $tool } }
    }
}

<#
.SYNOPSIS
    Checks whether a SAST tool is available on this machine (binary or cmdlet).
#>
function Resolve-SastToolPath {
      [CmdletBinding()]
      [OutputType([string])]
      param([string]$Tool, [PSCustomObject]$State = $null)
      # Resolves a scanner to an ABSOLUTE executable path, and for dotnet it goes
      # through SDK.psm1's Resolve-DotnetSdkCommand rather than plain PATH lookup.
      # The vulnerability audit is an SDK verb (`dotnet list ... package`), so a
      # runtime-only muxer on PATH cannot run it even though `Get-Command dotnet`
      # succeeds. That mismatch made the audit fail with "No .NET SDKs were
      # found" and then block the build reporting findings=0.
      if (-not $Tool) { return '' }
      if ($Tool -eq 'dotnet') {
          if (Get-Command Resolve-DotnetSdkCommand -ErrorAction SilentlyContinue) {
              try {
                  $resolved = Resolve-DotnetSdkCommand -State $State
                  if ($resolved) { return [string]$resolved }
              } catch { }
          } else {
              # SDK.psm1 is not loaded here. Do NOT fall through to a bare PATH
              # lookup: that is what selected the runtime-only muxer. Probe
              # capability the same way, and otherwise report the scanner as
              # unavailable so the step degrades instead of failing the build on
              # a tool that cannot run.
              $candidate = ''
              foreach ($var in @('DOTNET_ROOT', 'DOTNET_ROOT(x86)')) {
                  $root = [Environment]::GetEnvironmentVariable($var)
                  if ([string]::IsNullOrWhiteSpace($root)) { continue }
                  foreach ($leaf in @('dotnet.exe', 'dotnet')) {
                      $probe = Join-Path $root $leaf
                      if (Test-Path -LiteralPath $probe -PathType Leaf) { $candidate = $probe; break }
                  }
                  if ($candidate) { break }
              }
              if (-not $candidate) {
                  $onPath = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                  if ($onPath) { $candidate = if ($onPath.Source) { [string]$onPath.Source } else { [string]$onPath.Path } }
              }
              if ($candidate) {
                  try {
                      $out = & $candidate '--list-sdks' 2>&1
                      if ($LASTEXITCODE -eq 0 -and $null -ne $out -and @($out).Count -gt 0) { return [string]$candidate }
                  } catch { }
              }
              return ''
          }
      }
      $cmd = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $cmd) { $cmd = Get-Command $Tool -ErrorAction SilentlyContinue | Select-Object -First 1 }
      if (-not $cmd) { return '' }
      if ($cmd.Source) { return [string]$cmd.Source }
      if ($cmd.Path) { return [string]$cmd.Path }
      return ''
  }

  function Test-SastToolAvailable {
      [CmdletBinding()]
      [OutputType([bool])]
      param([string]$Tool, [PSCustomObject]$State = $null)
      if (-not $Tool) { return $false }
      # Ask the platform for its own bundled scanner BEFORE declaring the tool
      # missing. Invoke-ScriptAnalyzer ships inside this _Build copy
      # (.tools\Modules\PSScriptAnalyzer) but nothing on the runtime path ever put
      # that folder on PSModulePath - only Install-GBuild.ps1 did, and only for
      # the install location it wrote. So a repo-local run resolved no analyzer,
      # reported 'SAST tool not installed', and the tool-unavailable policy
      # failed the step: the build was blocked for code that had never been
      # scanned, with findings=0 and the operator told to install the tool.
      # Provisioning is a no-op when the cmdlet already resolves.
      if ($Tool -and -not (Get-Command $Tool -ErrorAction SilentlyContinue) -and (Get-Command Resolve-VendoredToolModule -ErrorAction SilentlyContinue)) {
          $provision = $null
          try { $provision = Resolve-VendoredToolModule -EntryPoint $Tool -State $State } catch { $provision = $null }
          if ($provision -and $provision.Status -eq 'Failed') {
              if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                  Write-Log (Resolve-LogMessage -Key 'log.sast.toolProvisionFailed' -MessageArgs @([string]$Tool, [string]$provision.Message) -Fallback "[SAST] Bundled scanner for {0} could not be provisioned: {1}") 'Warn' $State
              }
          }
      }
      $path = Resolve-SastToolPath -Tool $Tool -State $State
      if (-not $path) { return $false }
      # A muxer that exists but carries no SDK cannot run `dotnet list ...`, so
      # for dotnet "available" must mean "has an SDK", not "is on PATH". Resolve-
      # SastToolPath already enforced that; fall through to a bare existence
      # check for every other scanner.
      if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
      return [bool](Get-Command $Tool -ErrorAction SilentlyContinue)
  }




<#
.SYNOPSIS
    Resolves the canonical secret-redaction routine and delegates to it.
.DESCRIPTION
    Internal guard shared by this module's redaction wrapper. The canonical routine
    is SharedUtils.Protect-BuildSecretText, resolved on every call (importing
    SharedUtils on demand when it is not loaded yet) so redaction never depends on
    module load order. It never falls back to a narrower, locally maintained
    pattern set: when the canonical routine cannot be resolved at all the text is
    fail-closed to the redaction marker rather than emitted unscrubbed.
#>
# Invoke-BuildSecretProtect is NOT defined here: SharedUtils owns and exports it
# (SharedUtils is a declared dependency of Sast). This module used to carry a
# byte-identical private copy which, never being exported, meant Sast called its
# own clone instead of the "shared" helper.

<#
.SYNOPSIS
    Scrubs credentials/tokens out of SAST tool output before it reaches a report.
.DESCRIPTION
    Thin wrapper around the canonical redaction routine
    (SharedUtils.Protect-BuildSecretText). It used to run Remove-Credentials (only
    when Logging happened to be loaded) plus its own inline sk- / Bearer / assignment
    regexes and emit the '[REDACTED]' marker, so the effective pattern set and the
    marker both varied by load order. Delegation now guarantees the full canonical
    union and the single '***REDACTED***' marker.
#>
function Protect-SastText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    return (Invoke-BuildSecretProtect -Text $Text -State $State)
}

# SINGLE SOURCE for the trivy executable name. BuildConstants.TrivyToolName
# existed and was mapped to nothing while two call sites hardcoded 'trivy', so
# a site with trivy installed under a different name (or a wrapper) could not
# be configured.
function Get-SastToolName {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Fallback = 'trivy')
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $v = [string](Get-BuildConstant -Key 'TrivyToolName' -Fallback $Fallback); if (-not [string]::IsNullOrWhiteSpace($v)) { return $v } } catch { }
    }
    return $Fallback
}

function Get-SastToolPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $cfg = Get-SastConfig -State $State
    $value = 'fail'
    if ($cfg) {
        if (($cfg.PSObject.Properties.Name -contains 'requireTools' -and -not [bool]$cfg.requireTools) -or ($cfg.PSObject.Properties.Name -contains 'failOnToolUnavailable' -and -not [bool]$cfg.failOnToolUnavailable)) { $value = 'skip' }
        foreach ($key in @('toolUnavailablePolicy','unavailablePolicy','missingToolPolicy')) {
            if ($cfg.PSObject.Properties.Name -contains $key -and $cfg.$key) { $value = [string]$cfg.$key; break }
        }
    }
    if ($value -notin @('fail','block','warn','skip')) { return 'fail' }
    return $value.ToLowerInvariant()
}

function Get-SastExcludePattern {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Single source for "directories no scanner walks": dependency trees,
    # build outputs and embedded tool copies. Was inline in
    # Get-SastProjectLanguages; the PowerShell analyzer branch needs the same
    # boundary (it used to -Recurse the whole tree, including node_modules).
    $pattern = ''
    if (Get-Command Get-SecurityExcludeDirPattern -ErrorAction SilentlyContinue) {
        try { $pattern = [string](Get-SecurityExcludeDirPattern) } catch { $pattern = '' }
    }
    if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = '[\\/](_Build|node_modules|bin|obj|\\.git)[\\/]' }
    return $pattern
}

function Test-SastTestFixturePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$FullName)
    # Sample/template files must not declare project languages: a lone
    # Go-default.go fixture is not a Go project. Only bare source-extension
    # evidence is gated here; manifest evidence (go.mod, package.json, ...)
    # still counts everywhere because it declares a real module boundary.
    if ([string]::IsNullOrWhiteSpace($FullName)) { return $false }
    return ([string]$FullName -match '(?i)[\\/](tests?|_tests?|testdata|fixtures?|__tests__|\.mktest)([\\/]|$)')
}

function Get-SastProjectLanguages {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$ProjectDir, [PSCustomObject]$State)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
    # Was a hand-written literal with a different ordering than Policy's copy
    # of the same idea. Routed through the shared, config-aware accessor.
    $sastExclude = Get-SastExcludePattern
    $files = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction Stop | Where-Object { $_.FullName -notmatch $sastExclude })
        foreach ($file in $files) {
            $ext = $file.Extension.ToLowerInvariant()
            $name = $file.Name.ToLowerInvariant()
            $fixture = Test-SastTestFixturePath -FullName $file.FullName
            if (-not $fixture) {
            switch ($ext) {
                '.cs' { [void]$set.Add('C#') }
                '.csproj' { [void]$set.Add('C#') }
                '.fs' { [void]$set.Add('F#') }
                '.fsproj' { [void]$set.Add('F#') }
                '.vb' { [void]$set.Add('VB.NET') }
                '.vbproj' { [void]$set.Add('VB.NET') }
                '.py' { [void]$set.Add('Python') }
                '.go' { [void]$set.Add('Go') }
                '.rs' { [void]$set.Add('Rust') }
                '.java' { [void]$set.Add('Java') }
                '.kt' { [void]$set.Add('Kotlin') }
                '.kts' { [void]$set.Add('Kotlin') }
                '.scala' { [void]$set.Add('Scala') }
                '.rb' { [void]$set.Add('Ruby') }
                '.php' { [void]$set.Add('PHP') }
                '.swift' { [void]$set.Add('Swift') }
                '.ex' { [void]$set.Add('Elixir') }
                '.exs' { [void]$set.Add('Elixir') }
                '.c' { [void]$set.Add('C') ; [void]$set.Add('C/C++') }
                '.h' { [void]$set.Add('C/C++') }
                '.cpp' { [void]$set.Add('C/C++') }
                '.hpp' { [void]$set.Add('C/C++') }
                '.ts' { [void]$set.Add('TypeScript') }
                '.js' { [void]$set.Add('Node.js') }
                '.ps1' { [void]$set.Add('PowerShell') }
                '.psm1' { [void]$set.Add('PowerShell') }
                '.yaml' { }
                '.yml' { }
                default {
                    if ($name -eq 'dockerfile') { [void]$set.Add('Docker') }
                    elseif ($name -eq 'mix.exs') { [void]$set.Add('Elixir') }
                }
            }
            }
            if ($name -in @('cargo.toml','cargo.lock')) { [void]$set.Add('Rust') }
            # Project-file manifests declare a real compilable unit wherever
            # they live (a test csproj is still C# that gets audited), so -
            # unlike loose source extensions - they are not gated on fixture
            # directories.
            if ($name -like '*.csproj') { [void]$set.Add('C#') }
            if ($name -like '*.fsproj') { [void]$set.Add('F#') }
            if ($name -like '*.vbproj') { [void]$set.Add('VB.NET') }
            if ($name -like '*.sln') { [void]$set.Add('C#') }
            if ($name -eq 'go.mod') { [void]$set.Add('Go') }
            if ($name -eq 'package.json') { [void]$set.Add('Node.js') }
            if ($name -in @('pom.xml','build.gradle','build.gradle.kts')) { [void]$set.Add('Java') }
            if ($name -eq 'Gemfile') { [void]$set.Add('Ruby') }
            if ($name -in @('requirements.txt','pyproject.toml','setup.py')) { [void]$set.Add('Python') }
        }
    } catch { }
    if (Get-Command Get-PrimaryLanguage -ErrorAction SilentlyContinue) {
        try {
            $primary = Get-PrimaryLanguage -SearchRoot $ProjectDir -State $State
            if ($primary -and $primary.Language) { [void]$set.Add([string]$primary.Language) }
        } catch { }
    }
    return @($set | Sort-Object)
}

function ConvertTo-ScriptAnalyzerFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Records = @())
    # Native PSScriptAnalyzer diagnostics mapped 1:1 (rule/severity/file/line).
    # The old path stringified the whole formatted table into a single
    # Severity='Info' blob, so a real Error hid behind an unblockable,
    # unactionable entry while the finding COUNT still looked meaningful.
    # Severity scale follows the analyzer's own contract: an Error is a broken
    # rule (High), a Warning is guidance (Medium), Information is noise (Low).
    $findings = [System.Collections.Generic.List[object]]::new()
    $maxLength = 500
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $maxLength = [int](Get-BuildConstant -Key 'SastFallbackTruncateLength' -Fallback 500) } catch { $maxLength = 500 }
    }
    foreach ($item in @($Records)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $text = Protect-SastText -Text ([string]$item.Exception.Message) -State $null
            if ($text.Length -gt $maxLength) { $text = $text.Substring(0, $maxLength) + '...' }
            $findings.Add([PSCustomObject]@{ Tool = 'PSScriptAnalyzer'; Severity = 'High'; Rule = 'ParserError'; File = ''; Line = ''; Message = $text })
            continue
        }
        if ($item -is [string]) {
            if ([string]::IsNullOrWhiteSpace($item)) { continue }
            $text = Protect-SastText -Text ([string]$item).Trim() -State $null
            if (-not $text) { continue }
            if ($text.Length -gt $maxLength) { $text = $text.Substring(0, $maxLength) + '...' }
            $findings.Add([PSCustomObject]@{ Tool = 'PSScriptAnalyzer'; Severity = 'Low'; Rule = ''; File = ''; Line = ''; Message = $text })
            continue
        }
        $names = @()
        try {
            if ($item -is [System.Collections.IDictionary]) { $names = @($item.Keys) }
            else { $names = @($item.PSObject.Properties.Name) }
        } catch { $names = @() }
        if ($names -notcontains 'RuleName' -and $names -notcontains 'Severity') { continue }
        $get = {
            param($n)
            try {
                if ($item -is [System.Collections.IDictionary]) { if ($item.Contains($n)) { return [string]$item[$n] } }
                elseif ($item.PSObject.Properties.Name -contains $n) { return [string]$item.$n }
            } catch { }
            return ''
        }
        $rawSev = & $get 'Severity'
        $mapped = if ($rawSev -ieq 'Error') { 'High' } elseif ($rawSev -ieq 'Warning') { 'Medium' } elseif ($rawSev -ieq 'Information') { 'Low' } else { $rawSev }
        $text = Protect-SastText -Text (& $get 'Message') -State $null
        if ($text.Length -gt $maxLength) { $text = $text.Substring(0, $maxLength) + '...' }
        $findings.Add([PSCustomObject]@{
            Tool = 'PSScriptAnalyzer'; Severity = $mapped; Rule = (& $get 'RuleName')
            File = (& $get 'ScriptName'); Line = (& $get 'Line'); Message = $text
        })
    }
    return @($findings.ToArray())
}

function ConvertTo-SastFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Tool, [string]$Output, [string]$Language)
    $findings = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }
    if ($Tool -eq 'npm') {
        # npm writes its payload to stdout but keeps warnings on stderr, and this
        # path merges both (2>&1). Parse the outermost JSON object so a warning
        # line cannot turn a valid audit report into a parse failure.
        $json = $Output
        $first = $json.IndexOf('{')
        $last = $json.LastIndexOf('}')
        if ($first -ge 0 -and $last -gt $first) { $json = $json.Substring($first, ($last - $first + 1)) }
        try { $audit = $json | ConvertFrom-Json -ErrorAction Stop }
        catch { throw (Resolve-LogMessage -Key 'log.sast.line493' -MessageArgs @([string]$_.Exception.Message) -Fallback "npm audit output is not valid JSON: $($_.Exception.Message)") }
        if ($audit.PSObject.Properties.Name -contains 'error') {
            # npm reports its own failure (no lockfile, offline, bad registry) in
            # the payload with a non-zero exit code. Discarding that text produced
            # a bare 'npm audit returned an error' naming nothing the operator can act on.
            $code = ''; $summary = ''
            try { if ($audit.error.PSObject.Properties.Name -contains 'code') { $code = [string]$audit.error.code } } catch { }
            try { if ($audit.error.PSObject.Properties.Name -contains 'summary') { $summary = [string]$audit.error.summary } } catch { }
            $detail = if ($summary) { $summary } elseif ($code) { $code } else { 'npm reported no detail' }
            throw (Resolve-LogMessage -Key 'log.sast.line502' -MessageArgs @([string]$detail) -Fallback "npm audit failed: $detail")
        }
        if (-not ($audit.PSObject.Properties.Name -contains 'vulnerabilities') -and -not ($audit.PSObject.Properties.Name -contains 'auditReportVersion') -and -not ($audit.PSObject.Properties.Name -contains 'metadata')) { throw (Resolve-LogMessage -Key 'log.sast.line504' -Fallback 'npm audit result is incomplete') }
        if ($audit.PSObject.Properties.Name -contains 'vulnerabilities' -and $audit.vulnerabilities) {
            foreach ($prop in $audit.vulnerabilities.PSObject.Properties) {
                $severity = if ($prop.Value.PSObject.Properties.Name -contains 'severity') { [string]$prop.Value.severity } else { 'unknown' }
                $findings.Add([PSCustomObject]@{ Tool = 'npm audit'; Severity = $severity; Rule = 'npm-audit'; File = 'package.json'; Line = ''; Message = Protect-SastText -Text ([string]$prop.Name) -State $null })
            }
        }
        $result = @($findings.ToArray())
        if ($result.Count -eq 0) { return @() }
        return ,$result
    }
    if ($Tool -eq 'bandit') {
        $result = $Output | ConvertFrom-Json -ErrorAction Stop
        if (-not ($result.PSObject.Properties.Name -contains 'results')) { throw (Resolve-LogMessage -Key 'log.sast.line515' -Fallback 'bandit result is incomplete') }
        foreach ($item in @($result.results)) {
            if ($null -eq $item) { continue }
            $findings.Add([PSCustomObject]@{ Tool = 'bandit'; Severity = [string]$item.issue_severity; Rule = [string]$item.test_id; File = [string]$item.filename; Line = [string]$item.line_number; Message = Protect-SastText -Text ([string]$item.issue_text) -State $null })
        }
        $result = @($findings.ToArray())
        if ($result.Count -eq 0) { return @() }
        return ,$result
    }
    if ($Tool -eq 'dotnet') {
        # A zero-finding report must yield ZERO findings. The `return ,@(...)`
        # idiom used here wraps the array so the pipeline does not unroll it, but
        # for an EMPTY list that emits a single empty array as one item: a clean
        # project then counted 1 finding, surfaced as a blank severity-less entry,
        # and flipped the scan to Warned. Every caller wraps the result in @(),
        # so returning the list plainly is correct for both empty and non-empty.
        $recognized = $false
        foreach ($line in ($Output -split "`n")) {
            if ($line -match '\b(GHSA-|CVE-)[^\s]+') {
                $recognized = $true
                $findings.Add([PSCustomObject]@{ Tool = 'dotnet audit'; Severity = 'High'; Rule = $Matches[0]; File = ''; Line = ''; Message = Protect-SastText -Text $line.Trim() -State $null })
            }
        }
        if (-not $recognized -and $Output -notmatch '(?i)no vulnerable|no vulnerabilities|vulnerab.*found') {
            # Include what the tool actually said. The previous bare
            # "unrecognized dotnet output" was swallowed by the caller's catch and
            # re-reported as "SAST parser or tool failed", so a muxer without an
            # SDK looked like a parser bug instead of "this tool cannot run here".
            $snippet = (Protect-SastText -Text (($Output -replace '\s+', ' ').Trim()) -State $null)
            if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
            throw (Resolve-LogMessage -Key 'log.sast.line543' -MessageArgs @([string]$snippet) -Fallback "unrecognized dotnet output: $snippet")
        }
        $result = @($findings.ToArray())
        if ($result.Count -eq 0) { return @() }
        return ,$result
    }
    if ($Tool -eq 'cargo-audit') {
        $result = $Output | ConvertFrom-Json -ErrorAction Stop
        if (-not ($result.PSObject.Properties.Name -contains 'vulnerabilities') -or $null -eq $result.vulnerabilities -or -not ($result.vulnerabilities.PSObject.Properties.Name -contains 'list')) { throw (Resolve-LogMessage -Key 'log.sast.line549' -Fallback 'cargo audit result is incomplete') }
        foreach ($v in @($result.vulnerabilities.list)) {
            $findings.Add([PSCustomObject]@{ Tool = 'cargo-audit'; Severity = [string]$v.severity; Rule = [string]$v.advisory.id; File = ''; Line = ''; Message = Protect-SastText -Text ([string]$v.advisory.title) -State $null })
        }
        $result = @($findings.ToArray())
        if ($result.Count -eq 0) { return @() }
        return ,$result
    }
    if ($Tool -eq 'gosec') {
        $result = $Output | ConvertFrom-Json -ErrorAction Stop
        if (-not ($result.PSObject.Properties.Name -contains 'Issues')) { throw (Resolve-LogMessage -Key 'log.sast.line557' -Fallback 'gosec result is incomplete') }
        foreach ($i in @($result.Issues)) {
            $findings.Add([PSCustomObject]@{ Tool = 'gosec'; Severity = [string]$i.severity; Rule = [string]$i.rule_id; File = [string]$i.file; Line = [string]$i.line; Message = Protect-SastText -Text ([string]$i.details) -State $null })
        }
        $result = @($findings.ToArray())
        if ($result.Count -eq 0) { return @() }
        return ,$result
    }
    $safe = Protect-SastText -Text $Output.Trim() -State $null
    if ($safe) {
        $maxLength = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'SastFallbackTruncateLength' -Fallback 500) } else { 500 }
        $findings.Add([PSCustomObject]@{ Tool = $Tool; Severity = 'Info'; Rule = ''; File = ''; Line = ''; Message = $safe.Substring(0, [Math]::Min($maxLength, $safe.Length)) })
    }
    # Same zero-finding contract as the branches above: a whitespace-only report
    # from an unrecognised tool must yield zero findings, not one empty one.
    $result = @($findings.ToArray())
    if ($result.Count -eq 0) { return @() }
    return ,$result
}

function Invoke-SastTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Language, [string]$ProjectDir, [PSCustomObject]$State)
    $command = Get-SastCommand -Language $Language -State $State
    if (-not $command) { return @{ Status = 'Skipped'; Reason = 'No SAST tool mapped'; ReasonCode = 'NoToolMapped'; Tool = ''; Findings = @(); Command = ''; PolicyRequired = $true } }
    # Test-SastToolAvailable provisions the bundled copy first, so reaching here
    # means the platform could not supply the scanner either. Name that fact
    # instead of the old bare 'SAST tool not installed': the two are different
    # problems (a project asked to install a tool the platform ships vs. the
    # platform's own copy being broken) and only one of them is the operator's.
    if (-not (Test-SastToolAvailable -Tool $command.Tool -State $State)) { return @{ Status = 'Skipped'; Reason = "SAST tool unavailable: $($command.ToolLabel) is neither bundled with this _Build copy nor on PATH"; ReasonCode = 'ToolUnavailable'; Tool = $command.Tool; Findings = @(); Command = ''; PolicyRequired = $true } }
    # Does this project even have the input the scanner needs? Running a scanner
    # that cannot report anything and calling the outcome a failure made a
    # lockfile-free Node.js project fail a security gate with findings=0.
    $requiredInputs = @()
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try {
            $map = Get-BuildConstant -Key 'SastToolRequiredInputs' -State $State -Fallback $null
            if ($map -is [System.Collections.IDictionary]) {
                foreach ($key in @($map.Keys)) { if ([string]$key -eq [string]$command.Tool) { $requiredInputs = @($map[$key]); break } }
            }
        } catch { $requiredInputs = @() }
    }
    if ($requiredInputs.Count -gt 0 -and $ProjectDir) {
        $present = @($requiredInputs | Where-Object { Test-Path -LiteralPath (Join-Path $ProjectDir $_) -PathType Leaf })
        if ($present.Count -eq 0) {
            return @{ Status = 'Skipped'; Reason = "SAST tool cannot run: $($command.ToolLabel) needs one of $($requiredInputs -join ', ') in the project root"; ReasonCode = 'ToolInputMissing'; Tool = $command.Tool; Findings = @(); Command = ''; PolicyRequired = $true }
        }
    }
    $toolPath = Resolve-SastToolPath -Tool $command.Tool -State $State
    $arguments = @($command.Args | ForEach-Object { if ($_ -eq '{0}') { $ProjectDir } else { $_ } })
    $timeout = Get-SastTimeoutSec -State $State
    $output = ''
    $exitCode = 0
    try {
        if ($command.Tool -eq 'Invoke-ScriptAnalyzer') {
            # Scope to project scripts: a whole-tree -Recurse also linted
            # node_modules/.opencode vendored tooling and build outputs, so
            # third-party diagnostics Warned the build while the project's own
            # findings drowned in half a megabyte of formatted table text.
            $sastScope = Get-SastExcludePattern
            $psFiles = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $sastScope -and $_.Extension.ToLowerInvariant() -in @('.ps1', '.psm1', '.psd1') } |
                Select-Object -ExpandProperty FullName)
            if ($psFiles.Count -eq 0) {
                return @{ Status = 'Passed'; Reason = 'No PowerShell scripts found'; ReasonCode = 'OK'; Tool = $command.Tool; Findings = @(); Command = "$($command.Tool) $($arguments -join ' ')" }
            }
            # -Path takes a single path (Invoke-ScriptAnalyzer 1.x), so scan
            # file by file; one unreadable file must not abort the whole scan.
            $records = [System.Collections.Generic.List[object]]::new()
            foreach ($psFile in $psFiles) {
                try { foreach ($rec in @(& Invoke-ScriptAnalyzer -Path $psFile 2>&1)) { $records.Add($rec) | Out-Null } }
                catch { $records.Add($_) | Out-Null }
            }
            $psFindings = @(ConvertTo-ScriptAnalyzerFindings -Records @($records.ToArray()))
            $psStatus = if ($psFindings.Count -gt 0) { 'Warned' } else { 'Passed' }
            return @{ Status = $psStatus; Reason = ''; ReasonCode = 'OK'; Tool = $command.Tool; Findings = $psFindings; Command = "$($command.Tool) $($arguments -join ' ')" }
        } elseif ((Get-Command Invoke-WithLiveOutput -ErrorAction SilentlyContinue) -and $toolPath -and (Get-Command $command.Tool -ErrorAction SilentlyContinue).CommandType -eq 'Application') {
            # Name the tool and its arguments before it runs. Without this a hung
            # or crashed scanner produced only "SAST tool timed out" with no way
            # to tell which tool or which invocation was responsible.
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.sast.runningTool' -MessageArgs @([string]$command.ToolLabel, ($arguments -join ' '), $timeout)) 'Info' $State
            }
            $result = Invoke-WithLiveOutput -FilePath $toolPath -ArgList $arguments -State $State -Label "SAST $($command.ToolLabel)" -WorkingDir $ProjectDir -Quiet -TimeoutSec $timeout
            if ($result.TimedOut) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Get-LocaleMessage -Key 'log.sast.timeout' -MessageArgs @([string]$command.Tool, $timeout)) 'Warn' $State
                }
                return @{ Status = 'Failed'; Reason = 'SAST tool timed out'; Tool = $command.Tool; Findings = @(); Command = "$($command.Tool) $($arguments -join ' ')" }
            }
            $output = @($result.Output) -join "`n"
            $exitCode = [int]$result.ExitCode
        } else {
            Push-Location -LiteralPath $ProjectDir
            try {
                $baseline = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue)) { [int]$LASTEXITCODE } else { 0 }
                $output = (& $command.Tool @arguments 2>&1 | Out-String)
                $exitCode = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) -and [int]$LASTEXITCODE -ne $baseline) { [int]$LASTEXITCODE } else { 0 }
            } finally { Pop-Location }
        }
        if ($command.Tool -ne 'Invoke-ScriptAnalyzer' -and [string]::IsNullOrWhiteSpace($output)) { return @{ Status = 'Failed'; Reason = 'SAST tool returned no report'; Tool = $command.Tool; Findings = @(); Command = "$($command.Tool) $($arguments -join ' ')" } }
        if ($exitCode -ne 0) {
            $ignoreDotnet = $command.Tool -eq 'dotnet' -and (Get-SastDotnetIgnoreNoFindings -State $State) -and $output -match '(?i)no vulnerable|no vulnerabilities'
            # npm audit exits 1 whenever it found anything. Reading that as a tool
            # failure threw the report away and blocked with findings=0; the
            # findings must be parsed instead.
            $exitSignalsFindings = $false
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                try { $exitSignalsFindings = @(Get-BuildConstant -Key 'SastToolsExitCodeSignalsFindings' -State $State -Fallback @()) -contains $command.Tool } catch { $exitSignalsFindings = $false }
            }
            if (-not ($ignoreDotnet -or $exitSignalsFindings)) { return @{ Status = 'Failed'; Reason = "Tool exited with code $exitCode"; ReasonCode = 'ToolExitCode'; Tool = $command.Tool; Findings = @(); Command = "$($command.Tool) $($arguments -join ' ')" } }
        }
        $findings = @(ConvertTo-SastFindings -Tool $command.Tool -Output $output -Language $Language)
        $status = if ($findings.Count -gt 0) { 'Warned' } else { 'Passed' }
        return @{ Status = $status; Reason = ''; Tool = $command.Tool; Findings = $findings; Command = "$($command.Tool) $($arguments -join ' ')" }
    } catch {
        # Keep the underlying reason. The blanket "SAST parser or tool failed"
        # told the user nothing about which tool failed or why, and the step then
        # blocked the build reporting findings=0 - indistinguishable from "the
        # scanner found something" when nothing was actually scanned.
        $why = ''
        try { $why = (Protect-SastText -Text ([string]$_.Exception.Message) -State $null) } catch { }
        if ($why.Length -gt 300) { $why = $why.Substring(0, 300) + '...' }
        $reason = if ($why) { "SAST tool or parser failed: $why" } else { 'SAST tool or parser failed' }
        return @{ Status = 'Failed'; Reason = $reason; Tool = $command.Tool; Findings = @(); Command = "$($command.Tool) $($arguments -join ' ')" }
    }
}

function Invoke-SastScan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State, [string]$ProjectDir)
    $cfg = Get-SastConfig -State $State
    if (-not $cfg -or -not $cfg.enabled) { return @{ Pass = $true; Status = 'Skipped'; Reason = 'security.sast.enabled is false'; Checks = @(); TotalFindings = 0; SeverityCounts = @{}; Languages = @() } }
    $dir = if ($ProjectDir) { $ProjectDir } elseif ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and $State.WorkingDir) { [string]$State.WorkingDir } else { (Get-Location).ProviderPath }
    # Announce the scan. log.sast.running and log.sast.primaryLanguage shipped in
    # every locale but were never emitted, so a SAST phase produced no start line
    # and never named the language it was reasoning about.
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log (Get-LocaleMessage -Key 'log.sast.running') 'Info' $State
        try {
            $primaryLang = $null
            if (Get-Command Get-PrimaryLanguage -ErrorAction SilentlyContinue) { $primaryLang = Get-PrimaryLanguage -SearchRoot $dir -State $State }
            if ($primaryLang -and $primaryLang.Language) {
                Write-Log (Get-LocaleMessage -Key 'log.sast.primaryLanguage' -MessageArgs @([string]$primaryLang.Language)) 'Info' $State
            }
        } catch { }
    }
    # Confine the scan root before handing it to any external tool or recursive
    # enumeration. Steps/vulnerability-scan.ps1 enforced both of these but was a
    # standalone manual utility, so the guards protected a path that never ran in
    # the pipeline; Sast is the wired owner and now carries them. String
    # containment alone is not enough - a junction inside the root still
    # string-matches it while reads/writes land elsewhere - so the reparse walk
    # is required too (PathUtils owns both guards).
    $scanRoots = @()
    if ($State) {
        foreach ($prop in @('ProjectRoot', 'WorkingDir', 'ScriptRoot')) {
            if (($State.PSObject.Properties.Name -contains $prop) -and $State.$prop) { $scanRoots += [string]$State.$prop }
        }
    }
    if ($scanRoots.Count -gt 0 -and (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) {
        if (-not (Test-PathUnderRoots -Path $dir -AllowedRoots $scanRoots)) {
            Write-Log (Resolve-LogMessage -Key 'log.sast.rootContainmentFailed' -MessageArgs @([string]$dir) -Fallback '[SAST] Scan root failed containment validation: {0}') 'Err' $State
            return @{ Pass = $false; Status = 'Failed'; Reason = 'Scan root failed containment validation (outside the build roots)'; Checks = @(); TotalFindings = 0; SeverityCounts = @{}; Languages = @() }
        }
    }
    if (Get-Command Test-NoReparsePointInPath -ErrorAction SilentlyContinue) {
        if (-not (Test-NoReparsePointInPath -Path $dir)) {
            Write-Log (Resolve-LogMessage -Key 'log.sast.rootReparsePoint' -MessageArgs @([string]$dir) -Fallback '[SAST] Scan root traverses a reparse point (junction/symlink): {0}') 'Err' $State
            return @{ Pass = $false; Status = 'Failed'; Reason = 'Scan root traverses a reparse point'; Checks = @(); TotalFindings = 0; SeverityCounts = @{}; Languages = @() }
        }
    }
    $languages = @(Get-SastProjectLanguages -ProjectDir $dir -State $State)
    if ($languages.Count -eq 0) { return @{ Pass = $false; Status = 'Failed'; Reason = 'No supported project language detected'; Checks = @(); TotalFindings = 0; SeverityCounts = @{}; Languages = @() } }
    $checks = [System.Collections.Generic.List[object]]::new()
    $allFindings = [System.Collections.Generic.List[object]]::new()
    $pass = $true
    $toolFailed = $false
    $unavailable = @()
    $unmapped = @()
    $noInput = @()
    $blockingFindings = 0
    $toolPolicy = Get-SastToolPolicy -State $State
    $failOnFindings = if ($cfg.PSObject.Properties.Name -contains 'failOnFindings') { [bool]$cfg.failOnFindings } else { $false }
    $threshold = if ($cfg.PSObject.Properties.Name -contains 'severityThreshold') { [string]$cfg.severityThreshold } else { 'high' }
    $thresholdRank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity $threshold) } else { 3 }
    if ($thresholdRank -le 0) {
        # An unrecognised severityThreshold silently became rank 3 (high), so a
        # typo like "critcal" or "blocker" quietly changed which findings fail
        # the build. That decision must be visible.
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.sast.unknownThreshold' -MessageArgs @($threshold)) 'Warn' $State
        }
        $thresholdRank = 3
    }
foreach ($language in $languages) {
        $result = Invoke-SastTool -Language $language -ProjectDir $dir -State $State
        $checks.Add([PSCustomObject]@{ Name = "SAST:$language"; Status = $result.Status; Reason = $result.Reason; ReasonCode = $result.ReasonCode; Tool = $result.Tool; Findings = @($result.Findings); Command = $result.Command })
        foreach ($finding in @($result.Findings)) { $allFindings.Add($finding) }
        if ($result.Status -eq 'Failed') { $pass = $false; $toolFailed = $true; continue }
        if ($result.Status -eq 'Skipped') {
            # A skipped tool is NOT a finding. Record which scanner did not run so
            # the verdict can name it; without this the step reported
            # "Blocked (findings=0)", which is indistinguishable from "the scanner
            # found something" and from "nothing was scanned at all".
            $code = if ($result.ReasonCode) { [string]$result.ReasonCode } else { 'Skipped' }
            if ($code -eq 'ToolUnavailable') {
                $unavailable += ('{0} ({1})' -f $language, $result.Tool)
            } elseif ($code -eq 'ToolInputMissing') {
                $noInput += ('{0} ({1}: {2})' -f $language, $result.Tool, $result.Reason)
            } elseif ($code -eq 'NoToolMapped') {
                $unmapped += [string]$language
            }
            if ($toolPolicy -in @('fail', 'block')) { $pass = $false; continue }
            if ($toolPolicy -eq 'warn' -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Write-Log (Resolve-LogMessage -Key 'log.sast.scannerSkipped' -MessageArgs @([string]$language, [string]$result.Reason) -Fallback '[SAST] The scanner for {0} did not run: {1}') 'Warn' $State
            }
        }
    }
    if ($failOnFindings) {
        # Count the findings that actually cross the threshold instead of
        # stopping at the first one: the reported reason has to distinguish
        # "N findings at or above high" from "1 finding below the threshold",
        # and the total finding count does neither.
        foreach ($finding in $allFindings) {
            $rank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity ([string]$finding.Severity)) } else { 0 }
            if ($rank -eq 4 -or ($rank -gt 0 -and $rank -ge $thresholdRank)) { $blockingFindings++; $pass = $false }
        }
    }
    $counts = @{}
    foreach ($finding in $allFindings) {
        $severity = if ($finding.Severity) { [string]$finding.Severity } else { 'unknown' }
        if ($counts.ContainsKey($severity)) { $counts[$severity]++ } else { $counts[$severity] = 1 }
    }
    $status = if ($pass) { 'Passed' } elseif ($toolFailed) { 'Failed' } else { 'Blocked' }
    # Say WHY the gate closed. With no findings the only remaining causes are the
    # tool-unavailable policy and languages with no scanner, so name them; a
    # silent Blocked (findings=0) is the failure mode this replaces.
    $reason = ''
    if (-not $pass) {
        $parts = @()
        if ($blockingFindings -gt 0) { $parts += ('{0} finding(s) at or above the {1} threshold' -f $blockingFindings, $threshold) }
        elseif ($allFindings.Count -gt 0) { $parts += ('{0} finding(s), all below the {1} threshold' -f $allFindings.Count, $threshold) }
        if ($unavailable.Count -gt 0) { $parts += ('required scanner(s) unavailable: {0}' -f ($unavailable -join ', ')) }
        if ($noInput.Count -gt 0) { $parts += ('scanner(s) that could not run because the project has no input for them: {0}' -f ($noInput -join ', ')) }
        if ($unmapped.Count -gt 0) { $parts += ('no scanner is mapped for: {0}' -f ($unmapped -join ', ')) }
        if (($unavailable.Count + $noInput.Count + $unmapped.Count) -gt 0) {
            $parts += 'set security.sast.toolUnavailablePolicy to warn or skip to let a scanner that could not run degrade instead of blocking'
        }
        $reason = ($parts -join '; ')
    }
    return @{ Pass = $pass; Status = $status; Reason = $reason; Checks = @($checks); TotalFindings = $allFindings.Count; SeverityCounts = $counts; Languages = $languages; UnavailableTools = @($unavailable); UnmappedLanguages = @($unmapped); ScannersWithoutInput = @($noInput) }
}

Export-ModuleMember -Function @(
    'Get-SastConfig',
    'Get-SastTimeoutSec',
    'Get-SastDotnetIgnoreNoFindings',
    'Get-SastToolMap',
    'Get-SastCommand',
    'ConvertTo-SastFindings',
    'ConvertTo-ScriptAnalyzerFindings',
    'Get-SastProjectLanguages',
    'Invoke-SastTool',
    'Invoke-SastScan',
    'Resolve-SastToolPath',
    'Test-SastToolAvailable'
)




