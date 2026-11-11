# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# CodeSigning.psm1 - signs the Windows PE artifacts a build produced.
#
# WHY THIS EXISTS
#   A Windows executable downloaded from the internet carries the Mark of the
#   Web, so SmartScreen asks the end user to confirm an unsigned publisher.
#   An Authenticode signature with a certificate a CA chain trusts removes
#   that prompt (a self-signed certificate does NOT - the publisher stays
#   untrusted, the user still has to click through).
#
#   gbuild already has security.artifactSign, but that is cosign/notation for
#   CONTAINER and OCI artifacts - it cannot sign a Windows PE file. This
#   module owns the PE case, which is a different domain: a different tool
#   chain, a different verification (Get-AuthenticodeSignature) and a
#   different artifact set (.exe/.dll instead of images and blobs).
#
# TWO SIGNERS, ONE SWITCH
#   signtool  - Windows SDK signtool.exe with a local PFX. Works with a CA
#               certificate and with a self-signed one.
#   powershell- Set-AuthenticodeSignature from Microsoft.PowerShell.Security.
#               Needs no Windows SDK, so it works on a build agent that only
#               has the .NET SDK - the usual case for this platform.
#   external  - any command line that signs one file, e.g. a SignPath CLI
#               wrapper or an Azure Artifact Signing helper. The command
#               template may contain the placeholder {file}.
#
# EVERYTHING IS OFF BY DEFAULT
#   Nothing runs unless security.peSign.enabled is true, so an existing
#   project keeps its exact behaviour until it opts in.
#
# SignPath Foundation (free code signing for qualifying open-source projects)
# is NOT wired in here on purpose: its service issues the certificate in
# SignPath's own name and the signing itself runs inside SignPath's CI
# integration, not from a local build agent. Use the SignPath GitHub Action
# for that; this module covers the local/offline signing path.

Set-StrictMode -Version 1.0

# ConfigProvider is a real dependency, not a convenience: every value this
# module reads comes from Get-ConfigValue, and a module that only works when
# some other module happened to be imported first is a module that fails in
# the one place nobody tested. Imported with -Global so the command is visible
# from every scope on Windows PowerShell 5.1 (a nested -Force import without
# -Global orphans the global copy there - see Tests/ModuleHygiene.Tests.ps1).
if (-not (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue)) {
    $configProviderPath = Join-Path $PSScriptRoot 'ConfigProvider.psm1'
    if (Test-Path -LiteralPath $configProviderPath -PathType Leaf) {
        $null = Import-Module $configProviderPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

$script:CodeSigningDefaultArtifacts = @('*.exe', '*.dll')

<#
.SYNOPSIS
    Reads the security.peSign configuration section into a normalized hashtable.
.DESCRIPTION
    Every default lives here (single source for the module); the config file
    only overrides what the project sets. Returns a hashtable with the keys
    Enabled, Tool, Artifacts, Recursive, CertificatePath,
    CertificatePasswordEnv, TimestampUrl, ExternalCommand, ExternalArguments,
    Verify and FailOnError.
#>
function Get-CodeSigningConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($State)

    $cfg = @{
        Enabled                = $false
        Tool                   = 'signtool'
        Artifacts              = @($script:CodeSigningDefaultArtifacts)
        Recursive              = $true
        CertificatePath        = ''
        CertificateThumbprint  = ''
        CertificatePasswordEnv = ''
        TimestampUrl           = 'http://timestamp.digicert.com'
        ExternalCommand        = ''
        ExternalArguments      = '{file}'
        Verify                 = 'valid'
        FailOnError            = $true
    }

    if (-not (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue)) { return $cfg }

    try {
        $cfg.Enabled = [bool](Get-ConfigValue -Path 'security.peSign.enabled' -State $State -Default $false -Type bool)
        $cfg.Tool = [string](Get-ConfigValue -Path 'security.peSign.tool' -State $State -Default 'signtool' -Type string)
        $cfg.Recursive = [bool](Get-ConfigValue -Path 'security.peSign.recursive' -State $State -Default $true -Type bool)
        $cfg.CertificatePath = [string](Get-ConfigValue -Path 'security.peSign.certificatePath' -State $State -Default '' -Type string)
        $cfg.CertificateThumbprint = [string](Get-ConfigValue -Path 'security.peSign.certificateThumbprint' -State $State -Default '' -Type string)
        $cfg.CertificatePasswordEnv = [string](Get-ConfigValue -Path 'security.peSign.certificatePasswordEnv' -State $State -Default '' -Type string)
        $cfg.TimestampUrl = [string](Get-ConfigValue -Path 'security.peSign.timestampUrl' -State $State -Default 'http://timestamp.digicert.com' -Type string)
        $cfg.ExternalCommand = [string](Get-ConfigValue -Path 'security.peSign.externalCommand' -State $State -Default '' -Type string)
        $cfg.ExternalArguments = [string](Get-ConfigValue -Path 'security.peSign.externalArguments' -State $State -Default '{file}' -Type string)
        $cfg.Verify = [string](Get-ConfigValue -Path 'security.peSign.verify' -State $State -Default 'valid' -Type string)
        $cfg.FailOnError = [bool](Get-ConfigValue -Path 'security.peSign.failOnError' -State $State -Default $true -Type bool)

        $patterns = Get-ConfigValue -Path 'security.peSign.artifacts' -State $State -Default $null
        if ($patterns) {
            $list = @()
            foreach ($p in @($patterns)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$p)) { $list += [string]$p }
            }
            if ($list.Count -gt 0) { $cfg.Artifacts = $list }
        }
    }
    catch {
        # A broken config section must not take the build down: fall back to the
        # module defaults (signing disabled).
        $cfg.Enabled = $false
    }

    # Normalize the verification mode: valid (default) | signature | none
    $verifyMode = ([string]$cfg.Verify).Trim().ToLowerInvariant()
    if ($verifyMode -notin @('valid', 'signature', 'none')) { $verifyMode = 'valid' }
    $cfg.Verify = $verifyMode

    return $cfg
}

<#
.SYNOPSIS
    Lists the artifact files under a directory that match the configured patterns.
.DESCRIPTION
    Returns a sorted array of full paths. A missing directory yields an empty
    array rather than an error, so a project without a publish output is a
    no-op instead of a failed build.
#>
function Get-CodeSigningArtifact {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Path,
        [string[]]$Pattern = @('*.exe', '*.dll'),
        [bool]$Recursive = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }

    $found = @()
    foreach ($p in @($Pattern)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
            $items = @(Get-ChildItem -LiteralPath $Path -Filter $p -File -Recurse:$Recursive -ErrorAction SilentlyContinue)
            foreach ($i in $items) { $found += $i.FullName }
        }
        catch { }
    }

    # Return the array PLAINLY. `return ,$r` hands the caller a one-element
    # array that CONTAINS the array, and a caller that wraps the call in
    # @() then sees one "artifact" that is an array - which then fails to
    # bind to a [string] parameter. Every caller wraps the call in @(), so
    # the plain return is both correct and empty-safe.
    $r = @($found | Sort-Object -Unique)
    if ($r.Count -eq 0) { return @() }
    return $r
}

<#
.SYNOPSIS
    Reports whether the configured signer can run on this machine.
.DESCRIPTION
    signtool needs the Windows SDK tool on PATH. external needs the configured
    command to be resolvable. On a non-Windows host both are unavailable, so
    the caller skips the step instead of failing the build.
#>
function Test-CodeSigningToolAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Tool = 'signtool',
        [string]$ExternalCommand = ''
    )

    if ($Tool -eq 'external') {
        if ([string]::IsNullOrWhiteSpace($ExternalCommand)) { return $false }
        $cmd = Get-Command -Name $ExternalCommand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        return [bool]$cmd
    }

    if ($Tool -eq 'powershell') {
        return [bool](Get-Command -Name 'Set-AuthenticodeSignature' -ErrorAction SilentlyContinue)
    }

    $cmd = Get-Command -Name 'signtool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$cmd
}

<#
.SYNOPSIS
    Signs one file with the Windows SDK signtool.exe.
.DESCRIPTION
    Uses the Authenticode SHA-256 digest and a RFC-3161 timestamp so the
    signature stays valid after the certificate expires. The certificate
    password is never read from the config file - it comes from the
    environment variable named by CertificatePasswordEnv.
#>
function Invoke-SignToolCodeSigning {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CertificatePath = '',
        [string]$Password = '',
        [string]$TimestampUrl = 'http://timestamp.digicert.com'
    )

    $result = @{ Signed = $false; Message = ''; ExitCode = -1 }

    $signtool = Get-Command -Name 'signtool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $signtool) {
        $result.Message = 'signtool.exe was not found on PATH'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($CertificatePath) -or -not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        $result.Message = "certificate not found: $CertificatePath"
        return $result
    }

    $args = @('sign', '/fd', 'SHA256', '/td', 'SHA256')
    if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) { $args += @('/tr', $TimestampUrl) }
    $args += @('/f', $CertificatePath)
    if (-not [string]::IsNullOrWhiteSpace($Password)) { $args += @('/p', $Password) }
    $args += $Path

    $output = ''
    try {
        $output = (& $signtool.Source @args 2>&1 | Out-String).Trim()
        $result.ExitCode = $LASTEXITCODE
    }
    catch {
        $result.Message = $_.Exception.Message
        return $result
    }

    $result.Signed = ($result.ExitCode -eq 0)
    if (-not $result.Signed) { $result.Message = $output }
    return $result
}

<#
.SYNOPSIS
    Signs one file with an external command line.
.DESCRIPTION
    The argument template may contain the placeholder {file}, which is
    replaced with the full path of the artifact. This is the escape hatch for
    signers whose CLI is not signtool (a SignPath wrapper, an Azure Artifact
    Signing helper, ...).
#>
function Invoke-ExternalCodeSigning {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Command,
        [string]$Arguments = '{file}'
    )

    $result = @{ Signed = $false; Message = ''; ExitCode = -1 }

    $cmd = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        $result.Message = "signing command was not found on PATH: $Command"
        return $result
    }

    $argList = @()
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        foreach ($token in ($Arguments -split '\s+')) {
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            $argList += ($token -replace '\{file\}', $Path)
        }
    }
    if ($argList.Count -eq 0) { $argList = @($Path) }

    $output = ''
    try {
        $output = (& $cmd.Source @argList 2>&1 | Out-String).Trim()
        $result.ExitCode = $LASTEXITCODE
    }
    catch {
        $result.Message = $_.Exception.Message
        return $result
    }

    $result.Signed = ($result.ExitCode -eq 0)
    if (-not $result.Signed) { $result.Message = $output }
    return $result
}

<#
.SYNOPSIS
    Signs one file with Set-AuthenticodeSignature (Microsoft.PowerShell.Security).
.DESCRIPTION
    The signer that needs NO Windows SDK: Set-AuthenticodeSignature ships with
    PowerShell itself. The certificate comes either from the store (looked up
    by thumbprint) or from a .pfx, which is imported for the duration of the
    call and removed afterwards so no private key stays behind in the store.
.PARAMETER CertificateThumbprint
    Thumbprint of the certificate in CurrentUser\My (or LocalMachine\My).
#>
function Invoke-PowerShellCodeSigning {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CertificatePath = '',
        [string]$Password = '',
        [string]$CertificateThumbprint = '',
        [string]$TimestampUrl = 'http://timestamp.digicert.com'
    )

    $result = @{ Signed = $false; Message = ''; ExitCode = 0 }

    if (-not (Get-Command Set-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        $result.Message = 'Set-AuthenticodeSignature is not available in this PowerShell'
        return $result
    }

    $imported = $null
    try {
        $cert = $null
        if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
            if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
                $result.Message = "certificate not found: $CertificatePath"
                return $result
            }
            $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
            $imported = Import-PfxCertificate -FilePath $CertificatePath -CertStoreLocation 'Cert:\CurrentUser\My' -Password $secure -Exportable:$false -ErrorAction Stop
            $cert = if ($imported) { @($imported)[0] } else { $null }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
            $thumb = ($CertificateThumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
            $cert = @(Get-ChildItem -Path 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1)
            if ($cert -and $cert -is [array]) { $cert = $cert[0] }
        }

        if (-not $cert) {
            $result.Message = 'no signing certificate was found (set certificatePath or certificateThumbprint)'
            return $result
        }

        $params = @{
            FilePath      = $Path
            Certificate   = $cert
            HashAlgorithm = 'SHA256'
            ErrorAction   = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) { $params['TimestampServer'] = $TimestampUrl }

        $sig = Set-AuthenticodeSignature @params
        $result.Signed = ($null -ne $sig) -and ([string]$sig.Status -ne 'NotSigned')
        if (-not $result.Signed) { $result.Message = "signature status: $([string]$sig.Status)" }
    }
    catch {
        $result.Message = $_.Exception.Message
        $result.ExitCode = 1
    }
    finally {
        # The PFX was imported only for this call - take it back out again so no
        # private key is left behind in the user's certificate store.
        if ($imported) {
            try { Remove-Item -LiteralPath $imported.PSPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    return $result
}

<#
.SYNOPSIS
    Verifies the Authenticode signature of a file.
.DESCRIPTION
    Returns a hashtable with Valid (the chain is trusted), HasSignature (the
    file carries a signature at all), Status and StatusMessage. On a host
    without Authenticode support (non-Windows) the file is reported as
    unsigned rather than invalid.
#>
function Test-CodeSignatureStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{ Valid = $false; HasSignature = $false; Status = 'Unknown'; StatusMessage = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $result.Status = [string]$sig.Status
        $result.StatusMessage = [string]$sig.StatusMessage
        $result.Valid = ($result.Status -eq 'Valid')
        $result.HasSignature = ($result.Status -ne 'NotSigned') -and ($null -ne $sig.SignerCertificate)
    }
    catch {
        $result.Status = 'Unknown'
    }
    return $result
}

<#
.SYNOPSIS
    Signs every artifact under a directory and reports the outcome.
.DESCRIPTION
    The single entry point used by the build pipeline. Returns a hashtable
    with Status (Succeeded / Failed / Skipped), Signed (count), Failed
    (count), Skipped (count) and a human readable Message.
.PARAMETER State
    The build state, used to read the security.peSign configuration.
.PARAMETER InputPath
    Directory that holds the artifacts to sign.
#>
function Invoke-CodeSigning {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        $State,
        [string]$InputPath = ''
    )

    $result = @{ Status = 'Skipped'; Signed = 0; Failed = 0; Skipped = 0; Message = '' }

    $cfg = Get-CodeSigningConfig -State $State
    if (-not $cfg.Enabled) {
        $result.Message = 'security.peSign.enabled is false'
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        $result.Status = 'Failed'
        $result.Message = 'no input path was provided'
        return $result
    }

    if (-not (Test-CodeSigningToolAvailable -Tool $cfg.Tool -ExternalCommand $cfg.ExternalCommand)) {
        $result.Status = 'Skipped'
        $result.Message = "signing tool is not available on this machine: $($cfg.Tool)"
        return $result
    }

    $artifacts = @(Get-CodeSigningArtifact -Path $InputPath -Pattern $cfg.Artifacts -Recursive $cfg.Recursive)
    if ($artifacts.Count -eq 0) {
        $result.Status = 'Skipped'
        $result.Message = 'no artifact matched the configured patterns'
        return $result
    }

    $password = ''
    if (-not [string]::IsNullOrWhiteSpace($cfg.CertificatePasswordEnv)) {
        $password = [string][Environment]::GetEnvironmentVariable($cfg.CertificatePasswordEnv)
    }

    $failed = @()
    $signed = 0

    foreach ($artifact in $artifacts) {
        if ($cfg.Tool -eq 'external') {
            $sign = Invoke-ExternalCodeSigning -Path $artifact -Command $cfg.ExternalCommand -Arguments $cfg.ExternalArguments
        }
        elseif ($cfg.Tool -eq 'powershell') {
            $sign = Invoke-PowerShellCodeSigning -Path $artifact -CertificatePath $cfg.CertificatePath -Password $password -CertificateThumbprint $cfg.CertificateThumbprint -TimestampUrl $cfg.TimestampUrl
        }
        else {
            $sign = Invoke-SignToolCodeSigning -Path $artifact -CertificatePath $cfg.CertificatePath -Password $password -TimestampUrl $cfg.TimestampUrl
        }

        if (-not $sign.Signed) {
            $failed += $artifact
            continue
        }

        if ($cfg.Verify -ne 'none') {
            $check = Test-CodeSignatureStatus -Path $artifact
            $ok = if ($cfg.Verify -eq 'signature') { $check.HasSignature } else { $check.Valid }
            if (-not $ok) {
                $failed += $artifact
                continue
            }
        }

        $signed++
    }

    $result.Signed = $signed
    $result.Failed = $failed.Count
    $result.Skipped = $artifacts.Count - $signed - $failed.Count

    if ($failed.Count -gt 0) {
        $result.Status = 'Failed'
        # Name a few files, not all of them: a build with 400 artifacts would
        # otherwise print a paragraph-long path list into the log.
        $shown = @($failed | Select-Object -First 3)
        $more = $failed.Count - $shown.Count
        $list = ($shown -join '; ')
        if ($more -gt 0) { $list += "; (+$more more)" }
        $result.Message = ("{0} artifact(s) could not be signed: {1}" -f $failed.Count, $list)
    }
    else {
        $result.Status = 'Succeeded'
        $result.Message = ("{0} artifact(s) signed" -f $signed)
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-CodeSigningConfig',
    'Get-CodeSigningArtifact',
    'Test-CodeSigningToolAvailable',
    'Invoke-SignToolCodeSigning',
    'Invoke-PowerShellCodeSigning',
    'Invoke-ExternalCodeSigning',
    'Test-CodeSignatureStatus',
    'Invoke-CodeSigning'
)
