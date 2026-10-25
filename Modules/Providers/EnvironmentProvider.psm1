# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# EnvironmentProvider.psm1 - Build environment detection (CI vs Local)

# Get-CanonicalOSName is the owner of the OS-string vocabulary. The provider is
# the only module that reports a host OTHER than the one it runs on (CI runners
# name the remote host), so it is also the only one that needs to canonicalise a
# supplied string. Imported before the class definitions below because a
# property initialiser that references it must resolve when the class is used.
$null = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

class GitHubActionsBuildEnvironment {
    [string] $Name = 'GitHubActions'
    [bool] $IsCI = $true
    [string] $OS = $(if (Get-Command Get-CanonicalOSName -ErrorAction SilentlyContinue) { Get-CanonicalOSName -OS $env:RUNNER_OS } else { [string]$env:RUNNER_OS })

    [hashtable] GetConfig() {
        return @{
            IsCI       = $true
            RunnerOS   = $this.OS
            Repository = $env:GITHUB_REPOSITORY
            Ref        = $env:GITHUB_REF
            SHA        = $env:GITHUB_SHA
            Actor      = $env:GITHUB_ACTOR
        }
    }
}

class AzureDevOpsBuildEnvironment {
    [string] $Name = 'AzureDevOps'
    [bool] $IsCI = $true
    [string] $OS = $(if (Get-Command Get-CanonicalOSName -ErrorAction SilentlyContinue) { Get-CanonicalOSName -OS $env:AGENT_OS } else { [string]$env:AGENT_OS })

    [hashtable] GetConfig() {
        return @{
            IsCI     = $true
            Pipeline = $env:BUILD_BUILDID
            Project  = $env:SYSTEM_TEAMPROJECT
            Org      = $env:SYSTEM_COLLECTIONURI
            OS       = $this.OS
        }
    }
}

class GitLabBuildEnvironment {
    [string] $Name = 'GitLabCI'
    [bool] $IsCI = $true
    # Canonicalised. CI_RUNNER_OS is 'linux'/'windows'/'darwin' (lowercase, and
    # 'darwin' rather than 'macos'), so it was previously compared against the
    # canonical set as-is and NEVER matched: `-eq 'Windows'` is false for
    # 'windows' in PowerShell. Every consumer that branched on $State.OS took
    # the non-Windows path on GitLab. Get-CanonicalOSName owns this mapping.
    [string] $OS = $(if (Get-Command Get-CanonicalOSName -ErrorAction SilentlyContinue) { Get-CanonicalOSName -OS $env:CI_RUNNER_OS } else { [string]$env:CI_RUNNER_OS })

    [hashtable] GetConfig() {
        return @{
            IsCI   = $true
            Project = $env:CI_PROJECT_NAME
            Ref    = $env:CI_COMMIT_REF_NAME
            SHA    = $env:CI_COMMIT_SHA
            OS     = $this.OS
        }
    }
}

class LocalBuildEnvironment {
    [string] $Name = 'Local'
    [bool] $IsCI = $false
    # Canonicalised. OSVersion.Platform.ToString() yields 'Win32NT'/'Unix'/'MacOSX',
    # none of which equals the canonical 'Windows'/'Linux'/'MacOS' that every
    # consumer compares against (Menu.psm1, Clean.psm1, HotReload.psm1, the
    # $State.OS checks in Build.psm1/Deploy.psm1/Orchestrator.psm1). So a Local
    # state on Windows read as a non-Windows host and took the POSIX branch.
    # AndroidSdkProvider.psm1:39 shows the correct pattern.
    [string] $OS = $(if (Get-Command Get-CanonicalOSName -ErrorAction SilentlyContinue) { Get-CanonicalOSName } else { [System.Environment]::OSVersion.Platform.ToString() })

    [hashtable] GetConfig() {
        $ident = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) {
            Get-BuildIdentity
        } else {
            $u = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { [System.Environment]::UserName }
            $h = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { [System.Net.Dns]::GetHostName() }
            @{ User = $u; Host = $h }
        }
        return @{
            IsCI = $false
            # Cross-platform identity: $env:USERNAME/$env:COMPUTERNAME are
            # Windows-only; Unix uses USER/HOSTNAME (or the hostname binary).
            # The shared owner owns the chain when co-loaded; local literals
            # are the standalone fallback so User/Machine are never empty.
            User = [string]$ident.User
            Machine = [string]$ident.Host
            OS = $this.OS
        }
    }
}

function Get-BuildEnvironment {
    [CmdletBinding()]
    [OutputType([object])]
    param()

Set-StrictMode -Version 1.0
    # Vendor selection stays here: this chain names the CI system, which is more
    # than a boolean. SharedUtils.Test-BuildCIHost owns the *IsCI* probe that
    # call sites without a provider need (Preflight, SDK) so they do not each
    # carry a divergent copy of it.
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $e = [GitHubActionsBuildEnvironment]::new()
    } elseif ($env:TF_BUILD -eq 'True') {
        $e = [AzureDevOpsBuildEnvironment]::new()
    } elseif ($env:GITLAB_CI -eq 'true') {
        $e = [GitLabBuildEnvironment]::new()
    } else {
        $e = [LocalBuildEnvironment]::new()
    }
    # Canonicalize: every consumer (Menu Supported flags, Build exe-suffix,
    # HealthCheck tool paths, SDK cache, State.OS) compares against
    # 'Windows'/'Linux'/'MacOS' (Get-OSPlatform canonical). Raw sources vary:
    # .NET Platform ('Win32NT'/'Unix'), CI runner vars ('Windows'/'Linux'/
    # 'macOS'). Normalize once here so no call site re-implements the mapping.
    try { $e.OS = Resolve-CanonicalOS -RawOS ([string]$e.OS) } catch { }
    return $e
}

<#
.SYNOPSIS
    Maps a raw OS token to the canonical 'Windows'/'Linux'/'MacOS' form.
.DESCRIPTION
    Comparison is case-insensitive. 'Unix' (.NET Platform covers BOTH Linux
    and macOS) and unknown/empty tokens delegate to Get-OSPlatform, which
    disambiguates via /proc vs SystemVersion.plist (last resort: 'Linux').
#>
function Resolve-CanonicalOS {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RawOS)
    $r = if ($RawOS) { $RawOS.Trim() } else { '' }
    if ($r -in @('Windows', 'Win32NT', 'win', 'windows')) { return 'Windows' }
    if ($r -in @('Linux', 'linux')) { return 'Linux' }
    if ($r -in @('MacOS', 'macOS', 'OSX', 'osx', 'darwin')) { return 'MacOS' }
    if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) {
        try {
            $detected = [string](Get-OSPlatform)
            if (-not [string]::IsNullOrWhiteSpace($detected)) { return $detected }
        } catch { }
    }
    if ($r -eq 'Unix') { return 'Linux' }
    if ($r) { return $r }
    return 'Unknown'
}

function Test-CIEnvironment {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $env = Get-BuildEnvironment
    if ($null -eq $env) { return $false }
    return [bool]$env.IsCI
}

Export-ModuleMember -Function @('Get-BuildEnvironment', 'Test-CIEnvironment', 'Resolve-CanonicalOS')
