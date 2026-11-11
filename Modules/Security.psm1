# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# BuildImport defines Import-GBuildModule and Import-BuildDependencies

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ==================================================================================================
# Modules/Security.psm1 (Security Scanning)
# ==================================================================================================
#
# Provides:
#   - Secret detection (API keys, connection strings)
#   - NuGet vulnerability audit
#   - License compliance check
#   - .gitignore validation
#   - gbuild --security
# ==================================================================================================

# ── Import modules ─────────────────────────────────────────────────────────────
Import-BuildModule -Dependencies @('SharedUtils', 'PathUtils')
# Locale for i18n log messages (log.security.*) — sentinel keeps standalone-import safe
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

# ── Secret patterns (consolidated in SharedUtils) ────────────────────────────
function Get-SecretPatterns {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)

Set-StrictMode -Version 1.0
    return Get-SecretDetectionPatterns -State $State
}

function Get-SecurityConfigValue {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Path, $Default = $null)
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        return Get-ConfigValue -Path $Path -State $State -Default $Default
    }
    return $Default
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
# (SharedUtils is a declared dependency of Security). This module used to carry a
# byte-identical private copy which, never being exported, meant Security called its
# own clone instead of the "shared" helper.

<#
.SYNOPSIS
    Scrubs credentials/tokens out of scanner text before it reaches a report.
.DESCRIPTION
    Thin wrapper around the canonical redaction routine
    (SharedUtils.Protect-BuildSecretText). It used to apply
    Get-SecretRedactPatterns plus its own Bearer and assignment regexes, which meant
    a Critical finding from Find-SecretsInFile (e.g. an AWS key, which the
    default gbuild.config.json does not list in security.redactPatterns) could still
    reach a report in clear. Delegation now guarantees redaction is a superset of
    SharedUtils' own detection list, and produces the same single '***REDACTED***'
    marker as the logging path.
#>
function Protect-SecurityText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    return (Invoke-BuildSecretProtect -Text $Text -State $State)
}

function New-SecurityScannerError {
    [CmdletBinding()]
    param([string]$Tool, [string]$Operation, [int]$ExitCode = -1)
    return [PSCustomObject]@{
        Type       = 'ScannerError'
        Tool       = $Tool
        Operation  = $Operation
        ExitCode   = $ExitCode
        Package    = $Tool
        Advisory   = 'security scanner failed closed'
        Severity   = 'Critical'
        IsError    = $true
        Message    = 'security scanner failed closed'
        Status     = 'Failed'
        Error      = 'ToolError'
        File       = ''
        Line       = 0
        LineContent = ''
        Match       = '***REDACTED***'
        Context    = ''
        Pattern    = 'ScannerError'
    }
}

function Get-SecurityToolPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $value = [string](Get-SecurityConfigValue -State $State -Path 'security.vulnerabilityToolPolicy' -Default 'fail')
    if ($value -notin @('fail', 'block', 'warn', 'skip')) { return 'fail' }
    return $value.ToLowerInvariant()
}

function Get-CodeSigningStatus {
    <#
    .SYNOPSIS
        Reports whether code signing is configured and available on this machine.
    .DESCRIPTION
        INFORMATIONAL ONLY - this function never fails a build and never blocks a
        deploy. Its sole purpose is to tell the developer whether the artifacts
        this build produces will carry a verifiable signature.

        Why this exists: Windows SmartScreen warns on unsigned executables
        downloaded from the internet (reputation-based). An EV certificate avoids
        the warning; an OV certificate still warns until reputation accumulates.
        Unsigned artifacts can still be sold and distributed - signing is a
        trust signal, not a correctness requirement. So the right behaviour is a
        clear status line, not a gate.

        Three independent mechanisms are checked, because a project may use any
        combination:
          1. security.artifactSign   - cosign / notation (container & OCI artifacts)
          2. security.gpgSign        - GPG detached/cleared signatures (Steps/sign-gpg.ps1)
          3. security.auditLedger.signing - audit-ledger entry signing (RSA-SHA256)

        A mechanism counts as "active" only when it is BOTH enabled in config
        AND its tool is resolvable on PATH. A configured-but-missing tool is
        reported as a warning detail, not silently dropped, because a developer
        who enabled signing and did not notice the tool is absent has a real
        problem that a green "Signed" line would hide.

        .OUTPUTS
        hashtable with:
          Status      - 'Signed' when at least one mechanism is active
          Mechanisms  - ordered list of active mechanism names
          Details     - per-mechanism human-readable status (active / disabled / tool-missing)
          Tools       - tool name -> availability map
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)

    $mechanisms = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    $tools = @{}

    # --- 1. Container / OCI artifact signing (cosign / notation) ---
    # A failed config read must not report "disabled": $signCfg stays $null on
    # BOTH "absent/disabled" and "read threw", and the old code could not tell
    # them apart - so a transient config failure made the posture report assert
    # a control was OFF when it may have been ON. Track the read outcome and
    # report 'unknown' instead of 'disabled' when the read itself failed.
    $signCfg = $null
    $signReadOk = $true
    try { $signCfg = Get-ConfigValue -Path 'security.artifactSign' -State $State -Default $null } catch { $signReadOk = $false }
    $signEnabled = $false
    if ($signCfg) { $signEnabled = [bool](Get-SectionValue -Section $signCfg -Key 'enabled' -Default $false) }
    $signTool = ''
    if ($signCfg) { $signTool = [string](Get-SectionValue -Section $signCfg -Key 'tool' -Default '') }
    $signKey = ''
    if ($signCfg) { $signKey = [string](Get-SectionValue -Section $signCfg -Key 'key' -Default '') }
    $signKeyResolved = $signKey -and ($signKey -notmatch '\$\{env:')
    if ($signEnabled) {
        $toolCmd = if ($signTool -in @('cosign', 'notation')) { $signTool } else { 'cosign' }
        $found = Get-Command $toolCmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $tools[$toolCmd] = [bool]$found
        if ($found -and $signKeyResolved) {
            $mechanisms.Add('artifactSign') | Out-Null
            $details.Add("${toolCmd}: active (key configured)")
        } elseif ($found) {
            $details.Add("${toolCmd}: tool present but key unresolved - signing will be skipped at publish time")
        } else {
            $details.Add("${toolCmd}: enabled in config but not found on PATH")
        }
    } elseif (-not $signReadOk) {
        $details.Add('artifactSign: unknown (config read failed - posture unverified)')
    } else {
        $details.Add('artifactSign: disabled')
    }

    # --- 1b. Windows PE signing (Modules/CodeSigning.psm1) ---
    # The container mechanism above says nothing about the .exe/.dll a Windows
    # build produces, so the posture report used to claim "artifacts will be
    # unsigned (SmartScreen may warn)" even when security.peSign had just
    # signed every binary. Report the PE mechanism on its own line.
    #
    # The resolved config comes from the CodeSigning module, which merges the
    # MACHINE profile with the project config - reading only the config here
    # would report "disabled" on a machine where every project is signed.
    $peEnabled = $false
    $peTool = ''
    $peUnknown = $false
    try {
        if (-not (Get-Command Get-CodeSigningConfig -ErrorAction SilentlyContinue)) {
            if (Get-Command Import-ModuleOnDemand -ErrorAction SilentlyContinue) {
                Import-ModuleOnDemand -ModuleNames @('CodeSigning')
            }
        }
        if (Get-Command Get-CodeSigningConfig -ErrorAction SilentlyContinue) {
            $peCfg = Get-CodeSigningConfig -State $State
            $peEnabled = [bool]$peCfg.Enabled
            $peTool = [string]$peCfg.Tool
            # A config read that FAILED is not the same as a config that says
            # "off": report the posture as unverified instead of asserting it.
            if ($peCfg.PSObject.Properties.Name -contains 'ConfigReadFailed' -and $peCfg.ConfigReadFailed) {
                $peUnknown = $true
                $peEnabled = $false
            }
        }
    }
    catch { $peUnknown = $true }
    if (-not $peEnabled -and -not $peUnknown) {
        # Fallback for a host where the CodeSigning module cannot be loaded.
        $peCfg = $null
        try { $peCfg = Get-ConfigValue -Path 'security.peSign' -State $State -Default $null } catch { $peUnknown = $true }
        if ($peCfg) {
            $peEnabled = [bool](Get-SectionValue -Section $peCfg -Key 'enabled' -Default $false)
            $peTool = [string](Get-SectionValue -Section $peCfg -Key 'tool' -Default 'signtool')
        }
    }
    if ($peEnabled) {
        $mechanisms.Add('peSign') | Out-Null
        $details.Add("peSign: active (${peTool})")
    }
    elseif ($peUnknown) {
        $details.Add('peSign: unknown (config read failed - posture unverified)')
    }
    else {
        $details.Add('peSign: disabled')
    }

    # --- 2. GPG signing (Steps/sign-gpg.ps1) ---
    $gpgCfg = $null
    $gpgReadOk = $true
    try { $gpgCfg = Get-ConfigValue -Path 'security.gpgSign' -State $State -Default $null } catch { $gpgReadOk = $false }
    $gpgEnabled = $false
    if ($gpgCfg) { $gpgEnabled = [bool](Get-SectionValue -Section $gpgCfg -Key 'enabled' -Default $false) }
    $gpgKeyId = ''
    if ($gpgCfg) { $gpgKeyId = [string](Get-SectionValue -Section $gpgCfg -Key 'keyId' -Default '') }
    if ($gpgEnabled) {
        $gpgCmd = Get-Command 'gpg', 'gpg2' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $tools['gpg'] = [bool]$gpgCmd
        if ($gpgCmd -and -not [string]::IsNullOrWhiteSpace($gpgKeyId)) {
            $mechanisms.Add('gpgSign') | Out-Null
            $details.Add('gpg: active (key id configured)')
        } elseif ($gpgCmd) {
            $details.Add('gpg: tool present but no keyId configured')
        } else {
            $details.Add('gpg: enabled in config but gpg/gpg2 not found on PATH')
        }
    } elseif (-not $gpgReadOk) {
        $details.Add('gpgSign: unknown (config read failed - posture unverified)')
    } else {
        $details.Add('gpgSign: disabled')
    }

    # --- 3. Audit-ledger entry signing ---
    $ledgerCfg = $null
    $ledgerReadOk = $true
    try { $ledgerCfg = Get-ConfigValue -Path 'security.auditLedger.signing' -State $State -Default $null } catch { $ledgerReadOk = $false }
    $ledgerEnabled = $false
    if ($ledgerCfg) { $ledgerEnabled = [bool](Get-SectionValue -Section $ledgerCfg -Key 'enabled' -Default $false) }
    $ledgerKeyPath = ''
    if ($ledgerCfg) { $ledgerKeyPath = [string](Get-SectionValue -Section $ledgerCfg -Key 'keyPath' -Default '') }
    if ($ledgerEnabled) {
        if (-not [string]::IsNullOrWhiteSpace($ledgerKeyPath)) {
            $mechanisms.Add('auditLedger') | Out-Null
            $details.Add('auditLedger: active (signing key configured)')
        } else {
            $details.Add('auditLedger: enabled but no keyPath configured')
        }
    } elseif (-not $ledgerReadOk) {
        $details.Add('auditLedger: unknown (config read failed - posture unverified)')
    } else {
        $details.Add('auditLedger: disabled')
    }

    $postureUnknown = (-not $signReadOk) -or $peUnknown -or (-not $gpgReadOk) -or (-not $ledgerReadOk)
    return @{
        Status     = if ($mechanisms.Count -gt 0) { 'Signed' } elseif ($postureUnknown) { 'Unknown' } else { 'NotSigned' }
        Mechanisms = @($mechanisms)
        Details    = @($details)
        Tools      = $tools
    }
}

function ConvertTo-CanonicalLicenseKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $key = ([string]$Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($key)) { return '' }
    $key = [regex]::Replace($key, '^(?:nuget|npm|pypi|cargo|maven|go|github|composer)[/:]', '')
    $key = $key -replace '\s+', ''
    $key = $key -replace '_', '-'
    $key = $key -replace '^license[:\-]?', ''
    $key = $key -replace '^apache-?2(?:\.0)?$', 'apache-2.0'
    $key = $key -replace '^bsd-?3(?:[-.]?clause)?$', 'bsd-3-clause'
    $key = $key -replace '^bsd-?2(?:[-.]?clause)?$', 'bsd-2-clause'
    return $key
}

function Test-SecurityInventoryFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$FileName, [string]$Extension)
    $name = [string]$FileName
    $lower = $name.ToLowerInvariant()
    $extensions = @('.cs','.fs','.vb','.fsx','.ps1','.psm1','.psd1','.sh','.bash','.zsh','.bat','.cmd','.py','.pyw','.go','.rs','.java','.kt','.kts','.scala','.rb','.php','.swift','.m','.mm','.c','.h','.cpp','.hpp','.json','.jsonc','.json5','.yaml','.yml','.toml','.ini','.cfg','.conf','.config','.xml','.props','.targets','.env','.lock','.sum','.csproj','.fsproj','.vbproj','.sln','.gradle','.gradle.kts','.sbt','.nuspec','.dockerfile','.npmrc','.pypirc','.netrc','.txt','.tf','.tfvars','.hcl','.proto','.sql',
        # Key material and keystores. These were absent from the inventory, which
        # meant a committed SSH/TLS/PKCS12/JKS private key - the single highest-
        # value secret class - was never scanned. Standalone.psm1:283 already
        # refuses to BUNDLE exactly these extensions, so the platform knew they
        # mattered; the scanner simply never looked at them.
        '.pem','.key','.pub','.crt','.cer','.der','.pfx','.p12','.pkcs12','.ppk','.jks','.keystore','.asc','.gpg','.pgp','.kdbx','.ovpn','.ovpn')
    if ($extensions -contains $Extension.ToLowerInvariant()) { return $true }
    # Extension-less key files (OpenSSH writes id_rsa / id_ed25519 with none).
    $names = @('dockerfile','makefile','gemfile','rakefile','procfile','npmrc','yarnrc','pypirc','netrc','id_rsa','id_dsa','id_ecdsa','id_ed25519','id_ecdsa_sk','id_ed25519_sk','identity','authorized_keys','known_hosts','requirements.txt','requirements-dev.txt','requirements-prod.txt','package-lock.json','npm-shrinkwrap.json','yarn.lock','pnpm-lock.yaml','poetry.lock','pipfile.lock','composer.lock','cargo.lock','packages.lock.json','go.mod','go.sum','pom.xml','build.gradle','build.gradle.kts','build.sbt','global.json','directory.build.props','directory.build.targets')
    return ($names -contains $lower -or $lower -like '*.lock' -or $lower -like '*lock.json' -or $lower -like '.env*' -or $lower -like '*.env' -or $lower -like '.npmrc*' -or $lower -like '.yarnrc*' -or $lower -like '.pypirc*' -or $lower -like '.netrc*')
}

# ── Audit logging for privileged operations ─────────────────────────────────
# Records a structured, tamper-evident audit trail of privileged build actions
# (deploy, version bump, security scan, config changes) to a dedicated audit
# log file. Each entry carries tenant, correlation, user, action and outcome so
# security reviews can reconstruct "who did what, when".
$script:AuditLogPath = $null
<#
.SYNOPSIS
    Clears the memoised audit-log path so the next write re-resolves it.
.DESCRIPTION
    $script:AuditLogPath is memoised on first Write-AuditLog call. Without a
    reset, a second Start-GBuild in one session (long-lived host, different
    ProjectRoot/TenantId) appends run 2's audit entries to run 1's
    logs/<tenant>/audit.log. Called from Start-GBuild's per-run reset block.
#>
function Reset-AuditLogPath {
    [CmdletBinding()]
    param()
    $script:AuditLogPath = $null
}
function Write-AuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Outcome,
        [PSCustomObject]$State = $null,
        [string]$Detail = ''
    )
    try {
        if (-not $script:AuditLogPath) {
            $script:AuditLogPath = Get-AuditLogPath -State $State
        }
        $id = Get-BuildIdentity
        $entry = @{
            Timestamp    = (Get-Date).ToString('o')
            CorrelationId = Get-BuildCorrelationId -State $State
            TenantId     = Get-BuildTenantId -State $State
            User         = $id.User
            Host         = $id.Host
            Action       = $Action
            Outcome      = $Outcome
            Detail       = (Protect-SecurityText -Text $Detail -State $State)
        }
        $maxMb = Get-ConfigValue -Path 'security.auditLogMaxSizeMB' -State $State -Default (Get-BuildConstant -Key 'AuditLogMaxSizeMB' -Fallback 10)
        Write-BuildAuditLog -LogPath $script:AuditLogPath -Entry $entry -MaxSizeMB ([int]$maxMb) | Out-Null
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.audit.writeFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[AUDIT] Failed to write audit entry: {0}') 'Warn' $State
        }
    }
}

function Find-SecretsInFile {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [int]$ContextLines = -1,
        [PSCustomObject]$State = $null
    )
    if ($ContextLines -lt 0) { $ContextLines = [int](Get-BuildConstant -Key 'AuditContextLines' -Fallback 1) }
    $findings = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @() }
    try {
        $content = [System.IO.File]::ReadAllText($FilePath)
        if ([string]::IsNullOrEmpty($content)) { return @() }
        $lines = $content -split "`n"
        $patterns = @(Get-SecretPatterns -State $State)
        foreach ($patternDef in $patterns) {
            $pattern = [string]$patternDef.Pattern
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            try { $regex = [regex]::new($pattern) } catch {
                $findings.Add((New-SecurityScannerError -Tool 'secret-scanner' -Operation 'pattern'))
                continue
            }
            foreach ($match in $regex.Matches($content)) {
                $lineNum = ($content.Substring(0, $match.Index) -split "`n").Count
                $lineContent = if ($lineNum -ge 1 -and $lineNum -le $lines.Count) { $lines[$lineNum - 1].Trim() } else { '' }
                # Already-vault-encrypted payloads are expected noise: the vault
                # writes them as "enc:" / "enca:" (CredentialVault.psm1:36-37).
                # That exemption must be decided by the MATCHED SPAN, never by the
                # surrounding line - testing the line gave any file author a
                # whole-line kill switch ("# enc: ... <live key>") and also
                # false-negatived benign lines carrying an `enc:` substring
                # (encrypt:, ?enc=, base64 blobs containing "enc:").
                if ($match.Value -match '^(enc|enca):') { continue }
                $context = @()
                for ($i = [Math]::Max(0, $lineNum - 1 - $ContextLines); $i -lt [Math]::Min($lines.Count, $lineNum - 1 + $ContextLines + 1); $i++) {
                    $context += "$($i + 1): $($lines[$i].Trim())"
                }
                $safeLine = Protect-SecurityText -Text ($lineContent.Replace($match.Value, '***REDACTED***')) -State $State
                $safeContext = Protect-SecurityText -Text (($context -join "`n").Replace($match.Value, '***REDACTED***')) -State $State
                $safeMatch = Protect-SecurityText -Text $match.Value -State $State
                if (-not [string]::IsNullOrEmpty($match.Value) -and $safeMatch.Contains($match.Value)) { $safeMatch = '***REDACTED***' }
                # Bound the preview. SecretMatchPreviewLength existed with no
                # consumer, so a match on a minified/one-line file put the whole
                # (redacted but still structurally revealing) line into a report.
                $previewLen = 50
                if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $previewLen = [int](Get-BuildConstant -Key 'SecretMatchPreviewLength' -State $State -Fallback 50) } catch { $previewLen = 50 } }
                if ($previewLen -gt 0) {
                    if ($safeLine.Length -gt $previewLen) { $safeLine = $safeLine.Substring(0, $previewLen) + '...[truncated]' }
                    if ($safeContext.Length -gt ($previewLen * 4)) { $safeContext = $safeContext.Substring(0, $previewLen * 4) + '...[truncated]' }
                    if ($safeMatch.Length -gt $previewLen) { $safeMatch = $safeMatch.Substring(0, $previewLen) + '...[truncated]' }
                }
                $findings.Add([PSCustomObject]@{
                    File        = (Protect-SecurityText -Text $FilePath -State $State)
                    Line        = $lineNum
                    LineContent = $safeLine
                    Pattern     = (Protect-SecurityText -Text ([string]$patternDef.Name) -State $State)
                    Severity    = [string]$patternDef.Severity
                    Match       = $safeMatch
                    Context     = $safeContext
                    IsError     = $false
                })
            }
        }
    } catch {
        $findings.Add((New-SecurityScannerError -Tool 'secret-scanner' -Operation ([string]$FilePath)))
    }
    return @($findings.ToArray())
}

# ── Auto-detect test directories (no hardcoded list) ──────────────────────────
function Get-TestDirectories {
    [CmdletBinding()]
    param(
        [string]$SearchRoot
    )

    $testDirs = @()

    # A directory is a "test directory" if it contains *.Tests.ps1 files.
    # This auto-discovers _Build/Tests, and any future test directory without
    # maintaining a hardcoded exclusion list.
    $testFiles = Get-ChildItem -Path $SearchRoot -Recurse -Filter "*.Tests.ps1" -File -EA SilentlyContinue
    foreach ($tf in $testFiles) {
        $rel = if (Get-Command ConvertTo-ForwardSlash -ErrorAction SilentlyContinue) { (ConvertTo-ForwardSlash -Path $tf.Directory.FullName.Substring($SearchRoot.Length)) -replace '^/', '' } else { $tf.Directory.FullName.Substring($SearchRoot.Length) -replace '\\', '/' -replace '^/', '' }
        if ($rel) { $testDirs += $rel }
    }

    return $testDirs | Select-Object -Unique
}

# ── Shared exclusion regex (single source) ─────────────────────────────────────
# UNION(SecurityExcludeDirs, SyntaxCheckExcludeDirs) compiled once into a single
# regex. Embedded tool copy (_Build) is tool code, never
# project code, so every project-wide scanner must skip it.
function Get-SecurityExcludeDirPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Single-source regex builder (PathUtils). UNION of both constant lists is
    # expressed by passing the first as -Dirs (resolved via its own guard below)
    # and the second as -FromConstant; dedup happens inside the helper.
    $secDirs = @()
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        $v = Get-BuildConstant -Key 'SecurityExcludeDirs' -Fallback $null
        if ($v) { $secDirs = @($v) }
    }
    # Standalone fallback via single sources (no hardcode in caller)
    if ($secDirs.Count -eq 0) {
        $fallback = @(Get-BuildConstant -Key 'SecurityExcludeDirs' -Fallback @())
        if ($fallback.Count -gt 0) { $secDirs = $fallback }
        elseif (Get-Command Get-SyntaxCheckExcludeDirs -ErrorAction SilentlyContinue) { $secDirs = @(Get-SyntaxCheckExcludeDirs) }
        # .tools must be excluded: it holds vendored tooling whose analyzer compat
        # JSONs would otherwise be walked by every scan.
        else { $secDirs = @(Get-BuildConstant -Key 'SyntaxCheckExcludeDirs' -Fallback @('obj','bin','.git','node_modules','TestResults','publish-output','.gbuildcache','build-reports','logs','_Build','.tools')) }
    }
    # Level 5 resilience: inline regex fallback when PathUtils was orphaned.
    if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
        return Get-ExcludeDirPattern -Dirs $secDirs -FromConstant 'SyntaxCheckExcludeDirs'
    }
    $sd = @($secDirs | Select-Object -Unique)
    return ('[\\/](' + (($sd | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')[\\/]')
}

function Invoke-SecretScan {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$SearchRoot = '',
        [string[]]$ExcludeDirs = @()
    )
    if ([string]::IsNullOrWhiteSpace($SearchRoot)) { $SearchRoot = Resolve-SecuritySearchRoot -State $State -Caller 'Invoke-SecretScan' }
    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        return @{ FilesScanned = 0; Findings = @((New-SecurityScannerError -Tool 'secret-scanner' -Operation 'search-root')); Errors = 1 }
    }
    Write-Log (Get-LocaleMessage -Key 'log.security.scanning' -MessageArgs @([string]$SearchRoot) -Fallback "[SECURITY] Scanning secrets in: $SearchRoot") 'Info' $State
    $effectiveExclusions = @()
    if ($PSBoundParameters.ContainsKey('ExcludeDirs')) {
        $effectiveExclusions = @($ExcludeDirs)
    } else {
        $configured = Get-SecurityConfigValue -State $State -Path 'security.excludeDirs' -Default $null
        if ($configured) { $effectiveExclusions += @($configured) } else { $effectiveExclusions += @(Get-BuildConstant -Key 'SecurityExcludeDirs' -Fallback @('bin','obj','node_modules','.git','publish-output','.gbuildcache','build-reports','wwwroot/lib','packages','TestResults','_Build','.tools')) }
        $syntaxDirs = Get-BuildConstant -Key 'SyntaxCheckExcludeDirs' -Fallback $null
        if ($syntaxDirs) { $effectiveExclusions += @($syntaxDirs) }
        $effectiveExclusions += @(Get-TestDirectories -SearchRoot $SearchRoot)
        $effectiveExclusions = @($effectiveExclusions | Select-Object -Unique)
    }
    $allFindings = [System.Collections.Generic.List[object]]::new()
    $filesScanned = 0
    $maxScanBytes = [int](Get-BuildConstant -Key 'SecretScanMaxFileMB' -Fallback 5) * 1MB
    $rootFull = [System.IO.Path]::GetFullPath($SearchRoot)
    # Level 5: security.scanDepth is a real bound, not decoration. It used to be
    # read by Get-SecurityScanDepth and nothing else, so the secret scanner walked
    # the entire tree regardless of configuration. Applied through the single-source
    # depth-aware enumerator so PS 5.1 (no Get-ChildItem -Depth) behaves the same.
    $scanDepth = Get-SecurityScanDepth -State $State
    try {
        $files = @(Get-SecurityScanFiles -Root $rootFull -Depth $scanDepth)
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\','/') -replace '\\','/'
            $excluded = $false
            foreach ($exDir in $effectiveExclusions) {
                if ($relative -match ('(^|/)' + [regex]::Escape([string]$exDir) + '(/|$)')) { $excluded = $true; break }
            }
            if ($excluded -or -not (Test-SecurityInventoryFile -FileName $file.Name -Extension $file.Extension)) { continue }
            $filesScanned++
            if ($file.Length -ge $maxScanBytes) {
                $allFindings.Add((New-SecurityScannerError -Tool 'secret-scanner' -Operation 'file-too-large'))
                continue
            }
            foreach ($finding in @(Find-SecretsInFile -FilePath $file.FullName -State $State)) { $allFindings.Add($finding) }
        }
    } catch {
        $allFindings.Add((New-SecurityScannerError -Tool 'secret-scanner' -Operation 'enumeration'))
    }
    $errors = @($allFindings | Where-Object { $_.IsError }).Count
    return @{ FilesScanned = $filesScanned; Findings = @($allFindings.ToArray()); Errors = $errors }
}

function Invoke-SecurityToolCapture {
    [CmdletBinding()]
    param([string]$Tool, [string[]]$Arguments, [string]$WorkingDirectory, [PSCustomObject]$State)
    # Resolve the EXECUTABLE, once, and use that path everywhere below.
    #
    # This used to resolve dotnet with plain `Get-Command $Tool`, i.e. by PATH
    # alone, while the rest of the tool resolved it through
    # SDK.Resolve-DotnetSdkCommand. The two disagreed, and the disagreement
    # blocked builds: on a machine with a runtime-only
    # C:\Program Files\dotnet (host + runtimes, no SDK) FIRST on PATH, the
    # build correctly reported "Found .NET SDK from the environment:
    # G:\TRUNG SON\Common\.sdk" and ran `dotnet publish net10.0` fine, while
    # this function handed the same command the SDK-less muxer. Every SDK verb
    # then failed with "No .NET SDKs were found", which Test-VulnerablePackages
    # records as a ScannerError, and `failOnVulnerabilityErrors` (default true)
    # turned it into "security scanner failed closed" - a supply-chain block on
    # a machine whose supply chain was fine.
    #
    # Resolve-DotnetSdkCommand exists for exactly this case and its own comment
    # names it ("the SAST vulnerability audit blocking on findings=0"). SAST was
    # routed through it; this caller was missed, so the same defect survived in
    # the security gate after being fixed in the analysis gate.
    #
    # Keep the fail-closed behaviour: when NO candidate muxer can run SDK
    # commands, return Available=$false exactly as before rather than falling
    # back to the known-broken PATH entry.
    $exePath = ''
    $isExecutable = $false
    if ($Tool -eq 'dotnet' -and (Get-Command Resolve-DotnetSdkCommand -ErrorAction SilentlyContinue)) {
        try {
            $preferred = ''
            if ($State -and ($State.PSObject.Properties.Name -contains 'DotnetCmd')) { $preferred = [string]$State.DotnetCmd }
            $candidate = [string](Resolve-DotnetSdkCommand -State $State -PreferredPath $preferred)
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $exePath = $candidate; $isExecutable = $true }
        } catch { $exePath = ''; $isExecutable = $false }
    }
    if ([string]::IsNullOrWhiteSpace($exePath)) {
        $exeResolved = Get-Command $Tool -ErrorAction SilentlyContinue
        if (-not $exeResolved) { return @{ ExitCode = 127; Output = ''; TimedOut = $false; Available = $false } }
        $exePath = [string]$exeResolved.Source
        # Only a real Application can be handed to Invoke-WithLiveOutput, which
        # spawns a process directly. On Windows the npm shim resolves to
        # npm.ps1 (ExternalScript) or npm.cmd, and passing either to a direct
        # spawn produced a ScannerError for a scanner that works fine from a
        # shell - so the CommandType gate is load-bearing, not decoration.
        $isExecutable = ($exeResolved.CommandType -eq 'Application')
    }
    $timeout = 120
    $vulnCfg = Get-SecurityConfigValue -State $State -Path 'security.vulnerabilityTimeoutSec' -Default 120
    try { $timeout = [Math]::Max(0, [int]$vulnCfg) } catch { }
    try {
        if ($isExecutable -and (Get-Command Invoke-WithLiveOutput -ErrorAction SilentlyContinue)) {
            $res = Invoke-WithLiveOutput -FilePath $exePath -ArgList $Arguments -State $State -Label "security $Tool" -WorkingDir $WorkingDirectory -Quiet -TimeoutSec $timeout
            return @{ ExitCode = [int]$res.ExitCode; Output = (@($res.Output) -join "`n"); TimedOut = [bool]$res.TimedOut; Available = $true }
        }
        Push-Location -LiteralPath $WorkingDirectory
        try {
            # A validated SDK path is executed directly; anything else keeps the
            # original by-NAME invocation, because only the shell knows how to run
            # a .ps1/.cmd shim and re-resolving by name here is what reintroduced
            # the PATH-ordering bug in the first place.
            $output = if ($isExecutable) { (& $exePath @Arguments 2>&1 | Out-String) } else { (& $Tool @Arguments 2>&1 | Out-String) }
            $exitCode = if ($null -ne (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue)) { [int]$LASTEXITCODE } else { 0 }
            return @{ ExitCode = $exitCode; Output = [string]$output; TimedOut = $false; Available = $true }
        } finally { Pop-Location }
    } catch {
        return @{ ExitCode = 1; Output = ''; TimedOut = $false; Available = $true; Error = $true }
    }
}

function ConvertTo-SecurityJson {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw (Resolve-LogMessage -Key 'log.security.line588' -Fallback 'empty tool output') }
    $value = $Text.Trim()
    $first = $value.IndexOf('{')
    $last = $value.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) { $value = $value.Substring($first, $last - $first + 1) }

    # npm writes the root project into package-lock.json under an empty-string key
    # (`"": { "name": ... }`). ConvertFrom-Json refuses a property with an empty name
    # unless -AsHashtable is passed, so every Node project using a lockfile failed
    # this module with "Manifest could not be validated" and blocked its build on a
    # licence gate that had never actually looked at a licence.
    #
    # -AsHashtable is the real fix but it changes the return type, and every caller
    # here reads the result as a PSCustomObject ($json.PSObject.Properties.Name,
    # $json.packages.PSObject.Properties). Rewriting those call sites is a wider change
    # than this bug warrants, so the empty key is renamed to a sentinel that cannot
    # collide with an install path, and the object type every caller already expects
    # is preserved. The sentinel is reported as a package name, exactly as the empty
    # string was — it carries no licence either, so it cannot pass anything.
    $value = $value -replace '(?m)(^|[,{\s])""\s*:', '$1"__gbuild_root__":'

    return ($value | ConvertFrom-Json -ErrorAction Stop)
}

<#
.SYNOPSIS
    Resolves the directory a security scanner runs against. Fails closed.
.DESCRIPTION
    Single owner for the "which tree do we scan?" decision. Every scanner used to
    fall back to '.' (the process current directory) when State.WorkingDir was
    missing. With security.blockOnCriticalVulns=true and licenseEnforcement=block,
    a missing WorkingDir then made the secret scanner, all five vulnerability
    scanners and the license gate scan the WRONG tree and report Pass - a silent
    security-control bypass, not just a wrong path. A missing root now throws:
    the gate fails LOUDLY instead of passing silently.
#>
function Resolve-SecuritySearchRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State, [string]$Caller = '')
    # Default Caller evaluates in the CALLER's scope at bind time, so an omitted
    # -Caller still names the scanner that asked. Explicit is preferred.
    if ([string]::IsNullOrWhiteSpace($Caller)) {
        try { $Caller = $MyInvocation.MyCommand.Name } catch { $Caller = 'unknown' }
        if ([string]::IsNullOrWhiteSpace($Caller)) { $Caller = 'unknown' }
    }
    $root = ''
    # ROOT PRECEDENCE. This used to read $State.WorkingDir - the LAUNCH directory -
    # and nothing else. So `gbuild -Project D:\app` launched from the tool directory
    # scanned the BUILD TOOL for secrets and never scanned D:\app at all: a
    # committed credential in the shipped project passed a green gate while the
    # scan reported "Scanning secrets in: <tool dir>". The subject of a secret scan
    # is the code being shipped, so an explicit root wins, then ProjectRoot, and
    # WorkingDir is only the last resort. The refusal to guess a process CWD is
    # kept: an undetermined root must fail, not silently become somewhere else.
    if ($State -and $State.PSObject.Properties.Name -contains 'ExplicitProject' -and $State.ExplicitProject) {
        $root = [string]$State.ExplicitProject
    }
    if ([string]::IsNullOrWhiteSpace($root) -and $State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) {
        $root = [string]$State.ProjectRoot
    }
    if ([string]::IsNullOrWhiteSpace($root) -and $State -and $State.PSObject.Properties.Name -contains 'WorkingDir' -and $State.WorkingDir) {
        $root = [string]$State.WorkingDir
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw [System.InvalidOperationException]::new($(if (Get-Command Resolve-LogMessage -ErrorAction SilentlyContinue) { Resolve-LogMessage -Key 'log.security.scanRootUndetermined' -MessageArgs @([string]$Caller) -Fallback ("Security scan root is undetermined ({0}): State.ProjectRoot and State.WorkingDir are both missing. Refusing to scan the process current directory." -f $Caller) } else { ("Security scan root is undetermined ({0}): State.ProjectRoot and State.WorkingDir are both missing. Refusing to scan the process current directory." -f $Caller) }))
    }
    try { $root = [System.IO.Path]::GetFullPath($root) } catch { }
    return $root
}

<#
.SYNOPSIS
    Returns the recursion depth bound for the per-ecosystem manifest scanners.
.DESCRIPTION
    SINGLE SOURCE. All five scanners (dotnet, npm, go, pip, cargo) enumerated
    with an unbounded `-Recurse` while BuildConstants declared
    SecurityManifestSearchDepth with no consumer at all - so a monorepo walked
    the entire tree five times per security scan and the tuning knob did
    nothing. 0 or less means unbounded.
#>
function Get-SecurityManifestSearchDepth {
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$State = $null)
    $d = 6
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $d = [int](Get-BuildConstant -Key 'SecurityManifestSearchDepth' -State $State -Fallback 6) } catch { $d = 6 }
    }
    return $d
}

function Get-SecurityScanDepth {
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$State)
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [int](Get-BuildConstant -Key 'SecurityScanDepth' -State $State -Fallback 2) } catch { }
    }
    return 2
}

<#
.SYNOPSIS
    Depth-bounded recursive file enumeration, identical on PS 5.1 and PS 7+.
.DESCRIPTION
    Single owner for "list files under a root, at most N levels deep". PS 6+ has
    Get-ChildItem -Depth; PS 5.1 does not, so a naive call silently degrades to an
    unbounded walk on the oldest supported host. Route through
    Environment.Invoke-CompatibleChildItem when it is loaded, otherwise emulate
    the depth filter manually. -Depth 0 or less means unbounded (the caller's
    documented escape hatch).
#>
function Get-SecurityScanFiles {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Depth = 2
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    if ($Depth -le 0) { return @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue) }
    if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
        return @(Invoke-CompatibleChildItem -Path $Root -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue)
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $maxSegments = $Depth + 1
    return @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        @($rel -split '[\\/]').Count -le $maxSegments
    })
}
function Test-VulnerablePackages {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $projects = @(Get-SecurityScanFiles -Root $searchRoot -Depth (Get-SecurityManifestSearchDepth -State $State) | Where-Object { ($_.Extension -eq '.csproj' -or $_.Name -in @('packages.lock.json','project.assets.json')) -and $_.FullName -notmatch $exPattern })
    if ($projects.Count -eq 0) { return @() }
    $vulns = [System.Collections.Generic.List[object]]::new()
    $policy = Get-SecurityToolPolicy -State $State
    foreach ($project in $projects) {
        $res = Invoke-SecurityToolCapture -Tool 'dotnet' -Arguments @('list', $project.DirectoryName, 'package', '--vulnerable', '--include-transitive') -WorkingDirectory $project.DirectoryName -State $State
        if (-not $res.Available) {
            if ($policy -ne 'skip') { $vulns.Add((New-SecurityScannerError -Tool 'dotnet' -Operation 'vulnerable-packages' -ExitCode $res.ExitCode)) }
            continue
        }
        if ($res.TimedOut) { $vulns.Add((New-SecurityScannerError -Tool 'dotnet' -Operation 'timeout' -ExitCode 124)); continue }
        $output = [string]$res.Output
        if ([string]::IsNullOrWhiteSpace($output) -and $res.ExitCode -eq 0) { $vulns.Add((New-SecurityScannerError -Tool 'dotnet' -Operation 'empty-output' -ExitCode $res.ExitCode)); continue }
        $hasFinding = $false
        $currentPackage = ''
        foreach ($line in ($output -split "`n")) {
            $trim = [string]$line.Trim()
            if ([string]::IsNullOrWhiteSpace($trim)) { continue }
            if ($trim -match '^\>\s+(.+)$') {
                $parts = $trim.Substring(1).Trim() -split '\s+'
                if ($parts.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace([string]$parts[0])) { $currentPackage = [string]$parts[0] }
                $rowSev = if ($parts.Count -ge 3) { [string]$parts[2] } else { 'High' }
                if ($trim -match '(GHSA-[A-Za-z0-9-]+|CVE-[0-9]{4}-[0-9]+)') {
                    $adv = [string]$matches[0]
                    $hasFinding = $true
                    $vulns.Add([PSCustomObject]@{ Package = Protect-SecurityText -Text $currentPackage; Advisory = Protect-SecurityText -Text $adv; Severity = [string]$rowSev })
                }
                continue
            }
            if ($trim -match '(GHSA-[A-Za-z0-9-]+|CVE-[0-9]{4}-[0-9]+)') {
                $cols = $trim -split '\s+'
                $rowSev = if ($cols.Count -ge 1) { [string]$cols[0] } else { 'Medium' }
                if ($rowSev -notmatch '^(Critical|High|Moderate|Medium|Low)$') { $rowSev = 'Medium' }
                $hasFinding = $true
                $pkg = if ([string]::IsNullOrWhiteSpace($currentPackage)) { 'dotnet-package' } else { $currentPackage }
                $adv = ''
                if ($trim -match '(GHSA-[A-Za-z0-9-]+|CVE-[0-9]{4}-[0-9]+)') { $adv = [string]$matches[0] }
                $vulns.Add([PSCustomObject]@{ Package = Protect-SecurityText -Text $pkg; Advisory = Protect-SecurityText -Text $adv; Severity = [string]$rowSev })
            }
        }
        if ($res.ExitCode -ne 0 -and -not $hasFinding -and $output -notmatch '(?i)no vulnerable|no vulnerabilities|vulnerab.*found') {
            $vulns.Add((New-SecurityScannerError -Tool 'dotnet' -Operation 'vulnerable-packages' -ExitCode $res.ExitCode))
        }
        if ($res.ExitCode -ne 0 -and $hasFinding) { continue }
    }
    return @($vulns.ToArray())
}

# ── Check npm vulnerable packages ──────────────────────────────────────────────
function Test-NpmVulnerabilities {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $manifests = @(Get-SecurityScanFiles -Root $searchRoot -Depth (Get-SecurityManifestSearchDepth -State $State) | Where-Object { $_.Name -eq 'package.json' -and $_.DirectoryName -notmatch 'node_modules' -and $_.FullName -notmatch $exPattern })
    if ($manifests.Count -eq 0) { return @() }
    $vulns = [System.Collections.Generic.List[object]]::new()
    $policy = Get-SecurityToolPolicy -State $State
    foreach ($manifest in $manifests) {
        $res = Invoke-SecurityToolCapture -Tool 'npm' -Arguments @('audit', '--json') -WorkingDirectory $manifest.DirectoryName -State $State
        if (-not $res.Available) {
            if ($policy -ne 'skip') { $vulns.Add((New-SecurityScannerError -Tool 'npm' -Operation 'audit' -ExitCode $res.ExitCode)) }
            continue
        }
        if ($res.TimedOut) { $vulns.Add((New-SecurityScannerError -Tool 'npm' -Operation 'timeout' -ExitCode 124)); continue }
        try {
            $audit = ConvertTo-SecurityJson -Text ([string]$res.Output)
            if ($audit.PSObject.Properties.Name -contains 'error') { throw (Resolve-LogMessage -Key 'log.security.line792' -Fallback 'audit error') }
            if ($audit.PSObject.Properties.Name -contains 'vulnerabilities' -and $null -ne $audit.vulnerabilities) {
                foreach ($prop in $audit.vulnerabilities.PSObject.Properties) {
                    $severity = if ($prop.Value.PSObject.Properties.Name -contains 'severity') { [string]$prop.Value.severity } else { 'unknown' }
                    $vulns.Add([PSCustomObject]@{ Package = Protect-SecurityText -Text ([string]$prop.Name); Advisory = 'npm audit'; Severity = $severity })
                }
            }
            if ($res.ExitCode -ne 0 -and -not ($audit.PSObject.Properties.Name -contains 'vulnerabilities')) { throw (Resolve-LogMessage -Key 'log.security.line799' -Fallback 'invalid audit result') }
        } catch {
            $vulns.Add((New-SecurityScannerError -Tool 'npm' -Operation 'audit' -ExitCode $res.ExitCode))
        }
    }
    return @($vulns.ToArray())
}

# ── Check Go vulnerabilities via govulncheck (graceful when absent) ───────────
function Test-GoVulnerabilities {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $manifests = @(Get-SecurityScanFiles -Root $searchRoot -Depth (Get-SecurityManifestSearchDepth -State $State) | Where-Object { $_.Name -eq 'go.mod' -and $_.FullName -notmatch $exPattern })
    if ($manifests.Count -eq 0) { return @() }
    $vulns = [System.Collections.Generic.List[object]]::new()
    $policy = Get-SecurityToolPolicy -State $State
    foreach ($manifest in $manifests) {
        $res = Invoke-SecurityToolCapture -Tool 'govulncheck' -Arguments @('-json', './...') -WorkingDirectory $manifest.DirectoryName -State $State
        if (-not $res.Available) { if ($policy -ne 'skip') { $vulns.Add((New-SecurityScannerError -Tool 'govulncheck' -Operation 'audit' -ExitCode $res.ExitCode)) }; continue }
        if ($res.TimedOut) { $vulns.Add((New-SecurityScannerError -Tool 'govulncheck' -Operation 'timeout' -ExitCode 124)); continue }
        if ([string]::IsNullOrWhiteSpace([string]$res.Output)) { $vulns.Add((New-SecurityScannerError -Tool 'govulncheck' -Operation 'empty-output' -ExitCode $res.ExitCode)); continue }
        $parsedAny = $false
        $parseError = $false
        $localFindings = 0
        foreach ($line in ([string]$res.Output -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
                $parsedAny = $true
                if ($entry.PSObject.Properties.Name -contains 'finding' -and $entry.finding) {
                    $finding = $entry.finding
                    $osv = if ($finding.PSObject.Properties.Name -contains 'osv') { [string]$finding.osv } else { 'unknown' }
                    $vulns.Add([PSCustomObject]@{ Package = 'go-module'; Advisory = Protect-SecurityText -Text $osv; Severity = 'High' })
                    $localFindings++
                }
            } catch { $parseError = $true }
        }
        if ($parseError -or (-not $parsedAny -and -not [string]::IsNullOrWhiteSpace([string]$res.Output))) { $vulns.Add((New-SecurityScannerError -Tool 'govulncheck' -Operation 'parse' -ExitCode $res.ExitCode)) }
        elseif ($res.ExitCode -ne 0 -and $localFindings -eq 0) { $vulns.Add((New-SecurityScannerError -Tool 'govulncheck' -Operation 'audit' -ExitCode $res.ExitCode)) }
    }
    return @($vulns.ToArray())
}

# ── Check Python vulnerabilities via pip-audit (graceful when absent) ─────────
function Test-PythonVulnerabilities {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $manifests = @(Get-SecurityScanFiles -Root $searchRoot -Depth (Get-SecurityManifestSearchDepth -State $State) | Where-Object { ($_.Name -like 'requirements*.txt' -or $_.Name -in @('pyproject.toml','setup.py','setup.cfg','Pipfile','poetry.lock','Pipfile.lock')) -and $_.FullName -notmatch $exPattern })
    if ($manifests.Count -eq 0) { return @() }
    $vulns = [System.Collections.Generic.List[object]]::new()
    $policy = Get-SecurityToolPolicy -State $State
    foreach ($manifest in $manifests) {
        $res = Invoke-SecurityToolCapture -Tool 'pip-audit' -Arguments @('--format=json') -WorkingDirectory $manifest.DirectoryName -State $State
        if (-not $res.Available) { if ($policy -ne 'skip') { $vulns.Add((New-SecurityScannerError -Tool 'pip-audit' -Operation 'audit' -ExitCode $res.ExitCode)) }; continue }
        if ($res.TimedOut) { $vulns.Add((New-SecurityScannerError -Tool 'pip-audit' -Operation 'timeout' -ExitCode 124)); continue }
        try {
            $audit = ConvertTo-SecurityJson -Text ([string]$res.Output)
            $localFindings = 0
            foreach ($dep in @($audit.dependencies)) {
                foreach ($v in @($dep.vulns)) {
                    $vulns.Add([PSCustomObject]@{ Package = Protect-SecurityText -Text ([string]$dep.name); Advisory = Protect-SecurityText -Text ([string]$v.id); Severity = 'High' })
                    $localFindings++
                }
            }
            if ($res.ExitCode -ne 0 -and $localFindings -eq 0) { throw (Resolve-LogMessage -Key 'log.security.line867' -Fallback 'audit failed without findings') }
        } catch { $vulns.Add((New-SecurityScannerError -Tool 'pip-audit' -Operation 'parse' -ExitCode $res.ExitCode)) }
    }
    return @($vulns.ToArray())
}

# ── Check Rust vulnerabilities via cargo-audit (graceful when absent) ─────────
function Test-RustVulnerabilities {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $manifests = @(Get-SecurityScanFiles -Root $searchRoot -Depth (Get-SecurityManifestSearchDepth -State $State) | Where-Object { $_.Name -in @('Cargo.toml','Cargo.lock') -and $_.FullName -notmatch $exPattern })
    if ($manifests.Count -eq 0) { return @() }
    $vulns = [System.Collections.Generic.List[object]]::new()
    $policy = Get-SecurityToolPolicy -State $State
    foreach ($manifest in $manifests) {
        $res = Invoke-SecurityToolCapture -Tool 'cargo-audit' -Arguments @('audit', '--json') -WorkingDirectory $manifest.DirectoryName -State $State
        if (-not $res.Available) { if ($policy -ne 'skip') { $vulns.Add((New-SecurityScannerError -Tool 'cargo-audit' -Operation 'audit' -ExitCode $res.ExitCode)) }; continue }
        if ($res.TimedOut) { $vulns.Add((New-SecurityScannerError -Tool 'cargo-audit' -Operation 'timeout' -ExitCode 124)); continue }
        try {
            $audit = ConvertTo-SecurityJson -Text ([string]$res.Output)
            $localFindings = 0
            foreach ($v in @($audit.vulnerabilities.list)) {
                $vulns.Add([PSCustomObject]@{ Package = Protect-SecurityText -Text ([string]$v.package_name); Advisory = Protect-SecurityText -Text ([string]$v.advisory.id); Severity = [string]$v.severity })
                $localFindings++
            }
            if ($res.ExitCode -ne 0 -and $localFindings -eq 0) { throw (Resolve-LogMessage -Key 'log.security.line894' -Fallback 'audit failed without findings') }
        } catch { $vulns.Add((New-SecurityScannerError -Tool 'cargo-audit' -Operation 'parse' -ExitCode $res.ExitCode)) }
    }
    return @($vulns.ToArray())
}

# ── Check license compliance against config allow/deny lists ──────────────────

<#
.SYNOPSIS
    Enforces license compliance policy: warn, block, or fail the build.
.DESCRIPTION
    Calls Test-LicenseCompliance and applies the configured policy:
    - 'warn': log violations but continue
    - 'block': return $false (caller should abort build)
    - 'fail': throw (hard stop)
    Policy is read from security.licenseEnforcement (default 'warn').
.PARAMETER State
    Build state (carries BuildConfig + license config).
#>
function Test-LicenseCompliance {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $cfg = Get-ConfigSection -State $State -Path 'license'
    $security = Get-ConfigSection -State $State -Path 'security'
    $securityLicense = if ($security -is [System.Collections.IDictionary] -and $security.Contains('license')) { $security['license'] } elseif ($security -and $security.PSObject.Properties.Name -contains 'license') { $security.license } else { $null }
    if (-not $cfg) { $cfg = $securityLicense }
    if (-not $cfg -and $State -and $State.PSObject.Properties.Name -contains 'BuildConfig' -and $State.BuildConfig -is [System.Collections.IDictionary] -and $State.BuildConfig.Contains('license')) { $cfg = $State.BuildConfig['license'] }
    # Allow-list source. A dedicated license section wins; otherwise fall back to
    # security.allowedLicenseTypes. That key shipped in gbuild.config.json but was
    # read by NOTHING, which made security.licenseEnforcement:"block" an inert
    # control: with no license section at all this function returned @() before
    # ever scanning, so a build "passed" a gate that was never evaluated.
    $denyValue  = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('deny')) { $cfg['deny'] } elseif ($cfg -and $cfg.PSObject.Properties.Name -contains 'deny') { $cfg.deny } else { @() }
    $allowValue = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('allowed')) { $cfg['allowed'] } elseif ($cfg -and $cfg.PSObject.Properties.Name -contains 'allowed') { $cfg.allowed } else { @() }
    if (@($allowValue).Count -eq 0) {
        $allowValue = Get-SecurityConfigValue -State $State -Path 'security.allowedLicenseTypes' -Default @()
    }
    $deny = @($denyValue | Where-Object { $_ })
    $allow = @($allowValue | Where-Object { $_ })
    if ($deny.Count -eq 0 -and $allow.Count -eq 0) { return @() }
    $searchRoot = Resolve-SecuritySearchRoot -State $State
    $exPattern = Get-SecurityExcludeDirPattern
    $licenseManifests = @('package.json', 'composer.json')
    $otherManifests = @('package-lock.json','npm-shrinkwrap.json','go.mod','go.sum','Cargo.toml','Cargo.lock','Gemfile','Gemfile.lock','requirements.txt','requirements-dev.txt','pyproject.toml','setup.py','setup.cfg','Pipfile','Pipfile.lock','poetry.lock','pom.xml','build.gradle','build.gradle.kts','build.sbt')
    # Depth-bounded. The enumeration used to be an unbounded `-Recurse`, while
    # BuildConstants declared SecurityManifestSearchDepth and
    # SecurityLicenseSearchDepth with no consumer at all - so a monorepo walked
    # the whole tree on every license check and the two knobs did nothing.
    $licenseDepth = 6
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $licenseDepth = [int](Get-BuildConstant -Key 'SecurityLicenseSearchDepth' -State $State -Fallback 6) } catch { $licenseDepth = 6 } }
    $files = @(Get-SecurityScanFiles -Root $searchRoot -Depth $licenseDepth | Where-Object {
        $_.FullName -notmatch $exPattern -and ($_.Name -in $licenseManifests -or $_.Name -in $otherManifests -or $_.Extension -in @('.csproj','.fsproj','.vbproj','.props','.targets','.nuspec','.sbt'))
    })
    $violations = [System.Collections.Generic.List[object]]::new()
    $uncovered = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $parseFailed = $false
        $packages = [System.Collections.Generic.List[object]]::new()
        try {
            if ($file.Name -in $licenseManifests) {
                $json = ConvertTo-SecurityJson -Text ([System.IO.File]::ReadAllText($file.FullName))
                $selfLic = if ($json.PSObject.Properties.Name -contains 'license') { $json.license } else { $null }
                $selfName = if ($json.PSObject.Properties.Name -contains 'name') { [string]$json.name } else { $file.Directory.Name }
                $selfId = if ($selfLic -is [string]) { [string]$selfLic } elseif ($selfLic -and ($selfLic.PSObject.Properties.Name -contains 'type')) { [string]$selfLic.type } else { '' }
                $packages.Add([PSCustomObject]@{ Name = $selfName; License = $selfId }) | Out-Null
                foreach ($section in @('dependencies','devDependencies','optionalDependencies')) {
                    if (($json.PSObject.Properties.Name -contains $section) -and $json.$section -and $json.$section.PSObject) {
                        foreach ($p in $json.$section.PSObject.Properties) {
                            $decl = $p.Value
                            $lic = if ($decl -is [string]) { '' } elseif ($decl -and ($decl.PSObject.Properties.Name -contains 'license')) { [string]$decl.license } else { '' }
                            $packages.Add([PSCustomObject]@{ Name = [string]$p.Name; License = $lic }) | Out-Null
                        }
                    }
                }
            } elseif ($file.Name -in @('package-lock.json','npm-shrinkwrap.json')) {
                # lockfile v2/v3: "packages" maps install paths -> { version, license }
                $json = ConvertTo-SecurityJson -Text ([System.IO.File]::ReadAllText($file.FullName))
                if ($json.PSObject.Properties.Name -contains 'packages' -and $json.packages -and $json.packages.PSObject) {
                    foreach ($p in $json.packages.PSObject.Properties) {
                        $lic = if ($p.Value -and ($p.Value.PSObject.Properties.Name -contains 'license')) { [string]$p.Value.license } else { '' }
                        $packages.Add([PSCustomObject]@{ Name = [string]$p.Name; License = $lic }) | Out-Null
                    }
                }
            } elseif ($file.Name -in @('go.mod','go.sum')) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:require\s+)?([A-Za-z0-9._~/-]+)\s+v[0-9]')) { $packages.Add([PSCustomObject]@{ Name = $m.Groups[1].Value; License = '' }) | Out-Null }
            } elseif ($file.Name -in @('Cargo.toml','Cargo.lock','pyproject.toml','Pipfile','Pipfile.lock','poetry.lock','setup.cfg')) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($m in [regex]::Matches($text, '(?m)^\s*([A-Za-z0-9_.-]+)\s*=\s*["'']')) { $packages.Add([PSCustomObject]@{ Name = $m.Groups[1].Value; License = '' }) | Out-Null }
            } elseif ($file.Name -like 'requirements*.txt' -or $file.Name -eq 'setup.py') {
                foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                    if ($line -match '^\s*([A-Za-z0-9_.-]+)\s*(?:[<>=!~]|$)') { $packages.Add([PSCustomObject]@{ Name = $matches[1]; License = '' }) | Out-Null }
                }
            } elseif ($file.Name -in @('Gemfile','Gemfile.lock')) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($m in [regex]::Matches($text, '(?m)^\s*(?:gem\s+)?["'']([A-Za-z0-9_.-]+)["'']')) { $packages.Add([PSCustomObject]@{ Name = $m.Groups[1].Value; License = '' }) | Out-Null }
            } else {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($m in [regex]::Matches($text, '<(?:PackageReference|PackageDownload)\s+[^>]*(?:Include|Update)\s*=\s*["'']([^"'']+)["'']|<artifactId>\s*([^<]+?)\s*</artifactId>|(?:implementation|api|compile)\s+["'']([^:"'']+):')) {
                    $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
                    $packages.Add([PSCustomObject]@{ Name = $name; License = '' }) | Out-Null
                }
            }
        } catch { $parseFailed = $true }
        if ($parseFailed) {
            $violations.Add([PSCustomObject]@{ Package = '[manifest]'; Location = $file.FullName; Reason = 'Manifest could not be validated' })
            continue
        }
        # Manifests with no license metadata at all: record the coverage gap so an
        # unchecked ecosystem is never reported as "compliant".
        if ($file.Name -notin $licenseManifests -and @($packages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.License) }).Count -eq 0) {
            $uncovered.Add([string]$file.Name) | Out-Null
        }
        foreach ($entry in @($packages.ToArray() | Sort-Object -Property Name -Unique)) {
            $name = [string]$entry.Name
            $lic = [string]$entry.License
            # (1) Name denylist. deny[] is honoured as a package-NAME blocklist in
            #     addition to a license denylist: an operator writing
            #     deny: ['left-pad'] wants that package gone, not a license check.
            $nameCanonical = ConvertTo-CanonicalLicenseKey $name
            if (@($deny | ForEach-Object { ConvertTo-CanonicalLicenseKey $_ } | Where-Object { $_ -and ($nameCanonical -like $_) }).Count -gt 0) {
                $violations.Add([PSCustomObject]@{ Package = $name; Location = $file.FullName; Reason = 'Package denied by license.deny' })
                continue
            }
            # (2) License rules. Only decidable when the manifest declares one;
            #     a package with no license metadata is NOT a violation (guessing
            #     would make the gate impossible to satisfy).
            if ([string]::IsNullOrWhiteSpace($lic)) { continue }
            $canonical = ConvertTo-CanonicalLicenseKey $lic
            $denied  = @($deny  | ForEach-Object { ConvertTo-CanonicalLicenseKey $_ } | Where-Object { $_ -and ($canonical -like $_) }).Count -gt 0
            $allowed = @($allow | ForEach-Object { ConvertTo-CanonicalLicenseKey $_ } | Where-Object { $_ -and ($canonical -like $_) }).Count -gt 0
            if ($denied) { $violations.Add([PSCustomObject]@{ Package = "$name ($lic)"; Location = $file.FullName; Reason = 'License denied by license.deny' }) }
            elseif (-not $allowed) { $violations.Add([PSCustomObject]@{ Package = "$name ($lic)"; Location = $file.FullName; Reason = 'License not in the allowed list' }) }
        }
    }
    # Coverage gap is reported ONLY when nothing else failed. A real violation must
    # not be diluted by advisory rows (the caller counts violations to decide
    # block/warn), and a coverage gap on its own must still be visible so an
    # unchecked ecosystem is never mistaken for full compliance.
    if ($uncovered.Count -gt 0 -and $violations.Count -eq 0) {
        $kinds = @($uncovered | Sort-Object -Unique)
        $violations.Add([PSCustomObject]@{
            Package   = '[coverage]'
            Location  = $searchRoot
            Reason    = "No license metadata in manifest(s): $($kinds -join ', '). These ecosystems are name-blocklist-checked only, not license-checked."
        })
    }
    return @($violations.ToArray())
}

function Invoke-LicenseCompliance {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $violations = Test-LicenseCompliance -State $State
    if ($null -eq $violations -or $violations.Count -eq 0) { return $true }

    $policy = [string](Get-SecurityConfigValue -State $State -Path 'security.licenseEnforcement' -Default 'warn')
    if ($policy -eq 'warn' -and (Get-SecurityConfigValue -State $State -Path 'license.blockOnViolation' -Default $false)) { $policy = 'block' }
    $hasParseError = @($violations | Where-Object { [string]$_.Reason -eq 'Manifest could not be validated' }).Count -gt 0
    # A "[coverage]" finding is informational: it records that some ecosystems
    # expose no license metadata. It must never block a build on its own, or
    # every .NET/Go/Rust project would fail a gate it can never satisfy.
    $coverageNote = @($violations | Where-Object { [string]$_.Package -eq '[coverage]' })
    if ($coverageNote.Count -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        foreach ($c in $coverageNote) { Write-Log (Resolve-LogMessage -Key 'log.security.licenseCoverageGap' -MessageArgs @((Protect-SecurityText -Text ([string]$c.Reason) -State $State)) -Fallback '[SECURITY] License coverage gap: {0}') 'Warn' $State }
    }
    $blocking = @($violations | Where-Object { [string]$_.Package -ne '[coverage]' })
    $msg = "License compliance: $($blocking.Count) violation(s) found"
    foreach ($v in $blocking) { $msg += "`n  - $(Protect-SecurityText -Text ([string]$v.Package) -State $State): $(Protect-SecurityText -Text ([string]$v.Reason) -State $State) @ $(Protect-SecurityText -Text ([string]$v.Location) -State $State)" }
    switch ($policy) {
        'warn' {
            Write-Log "[SECURITY] $msg" 'Warn' $State
            return (-not $hasParseError)
        }
        'block' {
            # Decide on BLOCKING violations, never on the raw list. A project with
            # zero license violations but an ecosystem that publishes no license
            # metadata produced one "[coverage]" row, and because this branch
            # returned $false on ANY non-empty $violations it failed the build with
            # "0 violation(s) found" printed right above it. That is the exact
            # outcome the [coverage] contract above exists to prevent, and it made
            # security.licenseEnforcement='block' unsatisfiable for every .NET, Go
            # and Rust project - which in turn would have made a default-on
            # security gate red on every build.
            if ($blocking.Count -eq 0) {
                Write-Log (Resolve-LogMessage -Key 'log.security.licenseClean' -Fallback '[SECURITY] License compliance: no blocking violation(s)') 'Info' $State
                return $true
            }
            Write-Log "[SECURITY] $msg" 'Err' $State
            return $false
        }
        'fail' {
            if ($blocking.Count -eq 0) { return $true }
            Write-Log "[SECURITY] $msg" 'Err' $State
            throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.security.line1090' -Fallback "License compliance policy 'fail' triggered: $($blocking.Count) violation(s)."))
        }
        default {
            if ($blocking.Count -eq 0) { return $true }
            Write-Log "[SECURITY] $msg" 'Err' $State
            return $false
        }
    }
}

# ── Main security scan orchestrator ───────────────────────────────────────────

function Invoke-SecurityScan {
    [CmdletBinding()]
    param([PSCustomObject]$State, [switch]$SkipSecrets, [switch]$SkipVulnerable)
    if (Get-Command Write-SectionBox -ErrorAction SilentlyContinue) { Write-SectionBox '[SECURITY] SECURITY SCAN' -Color 'Warn' -State $State }
    $critical = 0
    $high = 0
    $medium = 0
    $vulnerabilityCount = 0
    $acceptedCount = 0
    $acceptedVulns = [System.Collections.Generic.List[object]]::new()
    $vulnsForBlocking = @()
    $vulnerabilityHigh = 0
    $vulnerabilityCritical = 0
    $scannerErrors = 0
    $licenseCount = 0
    $licensePass = $true
    # Level 5: these three shipped in gbuild.config.json but were read by nothing,
    # so the scans ran unconditionally and the flags were decorative. Config is
    # now authoritative: a deployment that turns a scan off actually turns it off,
    # and the decision is recorded in the log instead of being invisible.
    $scanSecrets = [bool](Get-SecurityConfigValue -State $State -Path 'security.scanSecrets' -Default $true)
    $checkVulns = [bool](Get-SecurityConfigValue -State $State -Path 'security.checkVulnerablePackages' -Default $true)
    $validateLicenses = [bool](Get-SecurityConfigValue -State $State -Path 'security.validateLicenses' -Default $true)
    $doSecrets = (-not $SkipSecrets) -and $scanSecrets
    $doVulns = (-not $SkipVulnerable) -and $checkVulns
    # Phase banners. These keys shipped in all 7 locales but nothing emitted them,
    # so a security scan produced one summary line and no indication of which
    # phase was running. Localized banners were therefore dead weight.
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        if ($doSecrets) { Write-Log (Get-LocaleMessage -Key 'log.security.phaseScan') 'Info' $State }
        if ($doVulns) { Write-Log (Get-LocaleMessage -Key 'log.security.phasePackages') 'Info' $State }
        if ($validateLicenses) { Write-Log (Get-LocaleMessage -Key 'log.security.phaseLicenses') 'Info' $State }
    }
    if ($SkipSecrets -and $scanSecrets) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.secretScanSkipped' -Fallback '[SECURITY] Secret scan skipped by caller') 'Gray' $State } }
    if ($SkipVulnerable -and $checkVulns) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.vulnScanSkipped' -Fallback '[SECURITY] Vulnerability scan skipped by caller') 'Gray' $State } }
    if ((-not $SkipSecrets) -and -not $scanSecrets) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.secretScanDisabled' -Fallback '[SECURITY] Secret scan disabled (security.scanSecrets=false)') 'Gray' $State } }
    if ((-not $SkipVulnerable) -and -not $checkVulns) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.vulnScanDisabled' -Fallback '[SECURITY] Vulnerability scan disabled (security.checkVulnerablePackages=false)') 'Gray' $State } }
    if (-not $validateLicenses) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.licenseValidationDisabled' -Fallback '[SECURITY] License validation disabled (security.validateLicenses=false)') 'Gray' $State } }
    if ($doSecrets) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.phaseScan' -Fallback '[SECURITY] Scanning secrets') 'Info' $State }
        $secretResult = Invoke-SecretScan -State $State
        $scannerErrors += [int]$secretResult.Errors
        foreach ($finding in @($secretResult.Findings)) {
            if ($finding.IsError) { continue }
            switch ([string]$finding.Severity) {
                'Critical' { $critical++ }
                'High' { $high++ }
                default { $medium++ }
            }
        }
        foreach ($finding in @($secretResult.Findings | Select-Object -First 10)) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.security.finding' -MessageArgs @([string](Protect-SecurityText -Text ([string]$finding.Severity) -State $State), (Protect-SecurityText -Text ([string]$finding.File) -State $State), $finding.Line, (Protect-SecurityText -Text ([string]$finding.Match) -State $State)) -Fallback '[SECURITY] {0} {1}:{2} {3}') 'Warn' $State
            }
        }
    }
    $vulns = @()
    if ($doVulns) {
        $checks = @(
            @{ Name = 'NuGet'; Script = { Test-VulnerablePackages -State $State } },
            @{ Name = 'npm'; Script = { Test-NpmVulnerabilities -State $State } },
            @{ Name = 'Go'; Script = { Test-GoVulnerabilities -State $State } },
            @{ Name = 'Python'; Script = { Test-PythonVulnerabilities -State $State } },
            @{ Name = 'Rust'; Script = { Test-RustVulnerabilities -State $State } }
        )
        foreach ($check in $checks) {
            try { $vulns += @(& $check.Script) } catch { $vulns += @(New-SecurityScannerError -Tool $check.Name -Operation 'invocation') }
        }
        # Guard against a scanner contributing nothing at all. The real defect was
        # `return ,@($list.ToArray())`: the comma operator wraps the array so the
        # pipeline does not unroll it, but combined with the @() it nested an array
        # INSIDE the result list. An empty scanner list then arrived as one
        # "finding" (Vulnerabilities=1 with zero real findings, and the log line
        # rendered "[SECURITY] vulnerability  " with both fields blank), while a
        # single real finding arrived wrapped, so `-not $_.IsError` resolved
        # through member enumeration and the counter could not tell a finding
        # from a container. Sast.psm1 hit the same trap and documents the fix at
        # its own `return @(...)`. Every caller here wraps in @(), so the
        # scanners now return the list plainly and this filter only drops nulls.
        $vulns = @($vulns | Where-Object { $null -ne $_ })

        # ---- per-advisory accepted risk with AUDIT TRAIL --------------------
        # _Build does not and MUST NOT edit the dependency graph (project's
        # authority). What _Build owns is POLICY + TRANSPARENCY: a finding is
        # blocked by default; a team may accept it ONLY with a named advisory +
        # justification (schema minLength 20) + expiry date (YYYY-MM-DD).
        # The decision is recorded in the audit ledger, which is the single
        # thing separating "we accepted a risk" from "we bypassed the gate".
        $acceptedVulns = [System.Collections.Generic.List[object]]::new()
        $staleEntries  = [System.Collections.Generic.List[object]]::new()
        $allowlist = @()
        try { $allowlist = @((Get-SecurityConfigValue -State $State -Path 'security.vulnerabilityAllowlist' -Default @())) } catch { $allowlist = @() }
        $today = [DateTime]::UtcNow.Date
        foreach ($entry in @($allowlist)) {
            if ($null -eq $entry) { continue }
            $targetAdv = if ($entry.PSObject.Properties.Name -contains 'advisory') { [string]$entry.advisory } else { '' }
            $targetPkg = if ($entry.PSObject.Properties.Name -contains 'package') { [string]$entry.package } else { '' }
            $targetSev = if ($entry.PSObject.Properties.Name -contains 'severity') { [string]$entry.severity } else { '' }
            $entryUntil = $null
            if ($entry.PSObject.Properties.Name -contains 'until') { try { $entryUntil = [DateTime]::ParseExact([string]$entry.until, 'yyyy-MM-dd', $null) } catch { $entryUntil = $null } }
            $liveMatch = $false
            foreach ($v in $vulns) {
                if ($v.IsError) { continue }
                if ($targetAdv -and ([string]$v.Advisory) -ne $targetAdv) { continue }
                if ($targetPkg -and ([string]$v.Package -notmatch [regex]::Escape($targetPkg))) { continue }
                if ($targetSev -and ([string]$v.Severity) -ne $targetSev) { continue }
                $liveMatch = $true; break
            }
            $expired = ($null -ne $entryUntil) -and ($today -gt $entryUntil)
            if ($expired -or (-not $liveMatch)) { $null = $staleEntries.Add($entry); continue }
            foreach ($v in $vulns) {
                if ($v.IsError) { continue }
                if ($targetAdv -and ([string]$v.Advisory) -ne $targetAdv) { continue }
                if ($targetPkg -and ([string]$v.Package -notmatch [regex]::Escape($targetPkg))) { continue }
                if ($targetSev -and ([string]$v.Severity) -ne $targetSev) { continue }
                if (-not $acceptedVulns.Contains($v)) { $null = $acceptedVulns.Add($v) }
            }
        }
        if ($staleEntries.Count -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            foreach ($e in $staleEntries) {
                $m = (Get-LocaleMessage -Key 'log.security.staleVulnAllow' -MessageArgs @(([string]$e.advisory),([string]$e.until)) -Fallback ("[SECURITY] stale vulnerability allowlist entry (advisory='" + [string]$e.advisory + "', until='" + [string]$e.until + "'): no live finding or it lapsed - re-verify and renew/remove/replace (keeps a forgotten entry from silently protecting a real CVE)."))
                Write-Log $m 'Warn' $State
            }
        }
        $acceptedCount = $acceptedVulns.Count
        if ($acceptedCount -gt 0 -and (Get-Command Write-AuditLog -ErrorAction SilentlyContinue)) {
            foreach ($v in $acceptedVulns) {
                $matching = $null
                foreach ($e in $allowlist) {
                    if ($null -eq $e) { continue }
                    if ($e.PSObject.Properties.Name -contains 'advisory' -and ([string]$e.advisory) -ne [string]$v.Advisory) { continue }
                    $p = if ($e.PSObject.Properties.Name -contains 'package') { [string]$e.package } else { '' }
                    if ($p -and ([string]$v.Package -notmatch [regex]::Escape($p))) { continue }
                    $matching = $e; break
                }
                $reason = if ($matching -and ($matching.PSObject.Properties.Name -contains 'reason')) { [string]$matching.reason } else { 'no reason recorded (entry malformed)' }
                $until  = if ($matching -and ($matching.PSObject.Properties.Name -contains 'until')) { [string]$matching.until } else { '' }
                Write-AuditLog -State $State -Action 'VulnerabilityAccept' -Outcome 'Accepted' -Detail ("Advisory=$([string]$v.Advisory); Package=$([string]$v.Package); Severity=$([string]$v.Severity); Until=$until; Reason=$reason")
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    $m = (Get-LocaleMessage -Key 'log.security.vulnAllowed' -MessageArgs @(([string]$v.Package),([string]$v.Advisory),$until,$reason) -Fallback ("[SECURITY] accepted risk: $([string]$v.Package) / $([string]$v.Advisory) until $until - $reason"))
                    Write-Log $m 'Warn' $State
                }
            }
        }
        foreach ($v in $vulns) {
            if ($v.IsError -or $acceptedVulns.Contains($v)) { continue }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                $m = (Get-LocaleMessage -Key 'log.security.vulnRemediation' -MessageArgs @(([string]$v.Package),([string]$v.Advisory)) -Fallback ("[SECURITY] remediation: update the dependency (`dotnet nuget why <project.csproj> $([string]$v.Package)` to find the constraint, `dotnet add <project> package $([string]$v.Package) --version <patched>`); or accept explicitly via security.vulnerabilityAllowlist with reason + until (and have the decision recorded in the audit ledger)."))
                Write-Log $m 'Info' $State
            }
        }
        # make accepted count visible even outside this block
        Set-Variable -Name 'acceptedCount' -Value $acceptedVulns.Count -Scope Local
        $vulnerabilityCount = @($vulns | Where-Object { -not $_.IsError }).Count
        foreach ($v in $vulns) {
            if ($v.IsError) { $scannerErrors++; continue }
            $rank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity ([string]$v.Severity)) } else { switch -Regex ([string]$v.Severity) { 'critical' { 4; break }; 'high' { 3; break }; 'medium|moderate' { 2; break }; 'low' { 1; break }; default { 0 } } }
            # Cut-offs from the declared constants rather than inline 3 / 4:
            # VulnDefaultFailRank existed with no consumer, so the severity
            # banding was hardcoded in three modules and could not be tuned.
            $highCut = 3
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $highCut = [int](Get-BuildConstant -Key 'VulnDefaultFailRank' -Fallback 3) } catch { $highCut = 3 } }
            if ($rank -ge $highCut) { $vulnerabilityHigh++ }
            if ($rank -gt $highCut) { $vulnerabilityCritical++ }
        }
        foreach ($v in @($vulns | Select-Object -First 10)) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.vulnerability' -MessageArgs @((Protect-SecurityText -Text ([string]$v.Package) -State $State), (Protect-SecurityText -Text ([string]$v.Advisory) -State $State)) -Fallback '[SECURITY] vulnerability {0} {1}') 'Warn' $State }
        }
    }
    if ($validateLicenses) {
        try {
            $licenseViolations = @(Test-LicenseCompliance -State $State)
            # "[coverage]" rows record ecosystems that expose no license metadata;
            # they are logged by Invoke-LicenseCompliance and are not violations.
            $licenseCount = @($licenseViolations | Where-Object { [string]$_.Package -ne '[coverage]' }).Count
            if (Get-Command Invoke-LicenseCompliance -ErrorAction SilentlyContinue) { $licensePass = [bool](Invoke-LicenseCompliance -State $State) }
            elseif ($licenseCount -gt 0) { $licensePass = $false }
        } catch {
            $licensePass = $false
            $scannerErrors++
        }
    }
    # Code-signing status is INFORMATIONAL. SmartScreen warns on unsigned binaries
    # but they can still be sold and distributed, so this never fails the build.
    # It exists so a developer can see at a glance whether the artifacts this run
    # produces will carry a verifiable signature, and which mechanism provides it.
    $reportSigning = [bool](Get-SecurityConfigValue -State $State -Path 'security.reportCodeSigning' -Default $true)
    if ($reportSigning) {
        $signing = Get-CodeSigningStatus -State $State
        $signingDetail = ($signing.Details -join '; ')
        if ($signing.Status -eq 'Signed') {
            # "configured" and "signed" are different claims. peSign only says a
            # mechanism is armed - whether the artifacts of THIS run carry a
            # signature is what the SignArtifacts step reports. Claiming
            # "Signed" from a config read alone would assert something the
            # posture reader cannot know (and would be false whenever the
            # certificate is missing on the build agent).
            $nonPe = @(@($signing.Mechanisms) | Where-Object { $_ -ne 'peSign' })
            $key = if ($nonPe.Count -eq 0) { 'log.security.codeSigningConfigured' } else { 'log.security.codeSigningSigned' }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key $key -MessageArgs @([string]($signing.Mechanisms -join ', ')) -Fallback ('[SECURITY] Code signing: configured ({0}) - the SignArtifacts step reports whether the artifacts were signed' -f ($signing.Mechanisms -join ', '))) 'Info' $State
            }
        } elseif ($signing.Status -eq 'Unknown') {
            # Posture read failed: report unverified, not "not configured".
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.security.codeSigningUnknown' -Fallback '[SECURITY] Code signing: posture unverified (config read failed) - signing state unknown') 'Warn' $State
            }
        } else {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Resolve-LogMessage -Key 'log.security.codeSigningNotSigned' -Fallback '[SECURITY] Code signing: Not configured - artifacts will be unsigned (SmartScreen may warn on download)') 'Warn' $State
            }
        }
        if (Get-Command Write-Log -ErrorAction SilentlyContinue -and $signingDetail) {
            Write-Log (Resolve-LogMessage -Key 'log.security.codeSigningDetail' -MessageArgs @($signingDetail) -Fallback '[SECURITY] Signing detail: {0}') 'Gray' $State
        }
    }
    $blockCritical = [bool](Get-SecurityConfigValue -State $State -Path 'security.blockOnCriticalVulns' -Default $true)
    $thresholdName = [string](Get-SecurityConfigValue -State $State -Path 'security.vulnerabilitySeverityThreshold' -Default 'high')
    $thresholdRank = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity $thresholdName) } else { 3 }
    if ($thresholdRank -le 0) { $thresholdRank = 3 }    $vulnsForBlocking = @($vulns | Where-Object { -not $_.IsError -and (-not $acceptedVulns.Contains($_)) })
    $blockingVulns = @($vulnsForBlocking | Where-Object {
        $r = if (Get-Command Get-VulnSeverityRank -ErrorAction SilentlyContinue) { [int](Get-VulnSeverityRank -Severity ([string]$_.Severity)) } else { 0 }
        $r -gt 0 -and $r -ge $thresholdRank
    }).Count
    $failErrors = [bool](Get-SecurityConfigValue -State $State -Path 'security.failOnVulnerabilityErrors' -Default $true)
    $pass = $true
    if (($critical -gt 0 -and $blockCritical) -or $blockingVulns -gt 0 -or ($scannerErrors -gt 0 -and $failErrors) -or -not $licensePass) { $pass = $false }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.security.scanResult' -MessageArgs @([string]$pass,$critical,$high,$vulnerabilityCount,$scannerErrors,$licenseCount) -Fallback '[SECURITY] Result: Pass={0} Critical={1} High={2} Vulnerabilities={3} ScannerErrors={4} License={5}') ($(if($pass){'Info'}else{'Err'})) $State }
    return @{ Pass = $pass; Critical = $critical; High = $high; Medium = $medium; Vulnerabilities = $vulnerabilityCount; VulnerabilityHigh = $vulnerabilityHigh; VulnerabilityCritical = $vulnerabilityCritical; ScannerErrors = $scannerErrors; License = $licenseCount; LicensePass = $licensePass; Findings = @($vulns) }
}

Export-ModuleMember -Function @('Find-SecretsInFile', 'Invoke-SecretScan', 'Resolve-SecuritySearchRoot', 'Get-SecurityScanDepth', 'Get-SecurityScanFiles', 'Test-VulnerablePackages', `
    'Test-NpmVulnerabilities', 'Test-GoVulnerabilities', 'Test-PythonVulnerabilities', 'Test-RustVulnerabilities', 'Test-LicenseCompliance', 'Invoke-LicenseCompliance', 'Invoke-SecurityScan', 'Write-AuditLog', 'Reset-AuditLogPath', `
    'Get-SecurityExcludeDirPattern', 'Get-CodeSigningStatus'
)




