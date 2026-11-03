param(
    [switch]$Install,
    [switch]$Remove,
    [switch]$List,
    [string]$RepoPath,
    [string[]]$HookTypes = @('pre-commit', 'pre-push', 'post-commit'),
    [switch]$Force,
    [PSCustomObject]$State
)
Set-StrictMode -Version 1.0
# Self-healing bootstrap (standalone-safe). Single owner:
# Modules/StepBootstrap.ps1. When this script runs outside an Orchestrator
# session the shared libs are absent; that file walks up to the _Build root and
# imports them. No-op inside a normal gbuild run.
$__gbuildModulesDir = Split-Path -Parent $PSScriptRoot
$__gbuildStepBootstrap = Join-Path $__gbuildModulesDir 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildStepBootstrap -PathType Leaf) {
    . $__gbuildStepBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildModulesDir, __gbuildStepBootstrap -ErrorAction SilentlyContinue
if (-not $State -and (Get-Command Resolve-BuildState -ErrorAction SilentlyContinue)) { $State = Resolve-BuildState $State }
# Fail closed: installing executable git hooks is a code-execution primitive. The
# old fallback silently targeted the launch directory's .git\hooks, so invoking
# this step without -RepoPath planted hooks into whatever repository the operator
# happened to be standing in. Resolve from State first; refuse rather than guess.
if (-not $RepoPath) {
    $RepoPath = if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { [string]$State.ProjectRoot }
                elseif ($State -and $State.PSObject.Properties.Name -contains 'WorkingDir' -and $State.WorkingDir) { [string]$State.WorkingDir }
                else { '' }
}
if ([string]::IsNullOrWhiteSpace($RepoPath)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.manage-githooks.line31' -Fallback '-RepoPath is required: refusing to install git hooks into an undisclosed directory.')) }
try { $RepoPath = [System.IO.Path]::GetFullPath($RepoPath) } catch { }
$hooksSrc = Join-Path $PSScriptRoot '../Hooks/git'

function Write-ManagedLog {
    param([string]$Message, [string]$Level = 'Info')
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message $Level $State }
}

function Get-GitHooksDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return '' }
    $gitDir = ''
    if (Get-Command git -ErrorAction SilentlyContinue) { try { $gitDir = ((& git '-C' $Path rev-parse '--git-dir' 2>$null | Out-String).Trim()) } catch { $gitDir = '' } }
    if (-not $gitDir) { $candidate = Join-Path $Path '.git'; if (Test-Path -LiteralPath $candidate -PathType Container) { $gitDir = $candidate } }
    if (-not $gitDir) { return '' }
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Path $gitDir }
    $hooksDir = Join-Path $gitDir 'hooks'
    if (-not (Test-Path -LiteralPath $hooksDir -PathType Container)) { return '' }
    $repoFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $hooksFull = [System.IO.Path]::GetFullPath($hooksDir).TrimEnd('\', '/')
    $comparison = Get-PathComparison
    if (-not (($hooksFull -eq $repoFull) -or $hooksFull.StartsWith($repoFull + [System.IO.Path]::DirectorySeparatorChar, $comparison))) { return '' }
    return $hooksFull
}

function Test-PathOwnership {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (Test-ReparsePointItem -Path $item.FullName) { return $false }
        if (Test-IsWindowsHost) {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $ownerName = $acl.Owner
            try {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($acl.Owner)
                $ownerName = $sid.Translate([System.Security.Principal.NTAccount]).Value
            } catch { }
            $owners = @($env:USERNAME, $env:USER, [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
            if ($env:USERDOMAIN -and $env:USERNAME) { $owners += "$env:USERDOMAIN\$env:USERNAME" }
            $owners = @($owners | Where-Object { $_ } | Select-Object -Unique)
            $trusted = $false
            if ($ownerName -and ($owners | Where-Object { $_ -ieq $ownerName })) { $trusted = $true }
            if (-not $trusted) {
                # Writability fallback for CI runners where git init creates
                # .git/hooks under a different account but the current user
                # can still modify the directory.
                try {
                    $probe = Join-Path $Path (".gbuild_probe_" + [guid]::NewGuid().ToString('N'))
                    [System.IO.File]::WriteAllText($probe, 'x')
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                    $trusted = $true
                } catch { $trusted = $false }
            }
            if (-not $trusted) { return $false }
        } else {
            # POSIX ownership. `stat` is NOT one binary across the platforms this
            # tool supports: GNU coreutils takes -c '%U', BSD/macOS takes
            # -f '%Su'. The previous GNU-only call meant that on macOS stat
            # printed an error, 2>$null swallowed it, $stat was empty, the
            # `$stat.Count -gt 0` guard was false, and the function returned
            # $true - the ownership check FAILED OPEN, so hooks could be
            # installed into a .git/hooks owned by a different user.
            #
            # Try BSD first (it is what macOS and the BSDs ship) and fall back
            # to GNU; whichever yields a non-empty owner is used.
            $owner = ''
            foreach ($statArgs in @(,@('-f', '%Su')), @(,@('-c', '%U'))) {
                if ($owner) { break }
                try {
                    $out = @(& stat @statArgs $Path 2>$null)
                    if ($out.Count -gt 0 -and $out[0]) { $owner = ([string]$out[0]).Trim() }
                } catch { }
            }
            $current = ''
            try {
                $who = @(& id -un 2>$null)
                if ($who.Count -gt 0 -and $who[0]) { $current = ([string]$who[0]).Trim() }
            } catch { }
            # FAIL CLOSED when ownership cannot be established. Installing an
            # executable hook is a code-execution primitive; an undeterminable
            # owner is not evidence of a trusted owner. The caller reports
            # "Refusing untrusted hooks directory" and skips the install, which
            # is recoverable, whereas a silent pass is not.
            if (-not ($owner -and $current -and $owner -eq $current)) {
                # Writability fallback (see Windows branch above).
                try {
                    $probe = Join-Path $Path (".gbuild_probe_" + [guid]::NewGuid().ToString('N'))
                    [System.IO.File]::WriteAllText($probe, 'x')
                    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                } catch { return $false }
            }
        }
    } catch {
        # FAIL CLOSED, consistently with the POSIX branch above. This catch used
        # to `return $true`, which is precisely the case the comment there says
        # must not happen: Get-Acl -ErrorAction Stop throws
        # UnauthorizedAccessException when the caller does NOT own or cannot read
        # the directory - i.e. exactly the untrusted case - and the function then
        # reported "trusted", so the caller proceeded to install EXECUTABLE git
        # hooks into an unverified .git/hooks. An undeterminable owner is not
        # evidence of a trusted owner; skipping the install is recoverable while
        # a silent pass is not.
        return $false
    }
    return $true
}

function Test-ManagedHook {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop; return ([string]$content -match 'GbuildManagedHook') } catch { return $false }
}

function Test-HookType {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Get-HookRelativePath {
    param([string]$BasePath, [string]$TargetPath)
    # String-based on purpose. This used to build [System.Uri] objects, which is
    # the standard trick - except that a WINDOWS path is not a URI: `[Uri]::new()`
    # reads the drive letter as a SCHEME, so MakeRelativeUri either threw or
    # produced nonsense. The function then fell through to its catch and returned
    # the ABSOLUTE template path, so every installed hook was pinned to the
    # machine's install directory (`D:\_Build\Hooks\git\pre-commit.ps1`); move or
    # clone the tool and every hook pointed at a path that no longer exists.
    # Nothing detected it, because -Install was a no-op: the template directory
    # did not exist, so this code path had never run.
    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    } catch {
        return $TargetPath
    }
    $comparison = Get-PathComparison
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($prefix, $comparison)) {
        # Different root (a second drive) or a path outside the hooks tree: no
        # relative form exists, so the absolute path is the only correct answer.
        return $targetFull
    }
    return $targetFull.Substring($prefix.Length)
}

function New-HookContent {
    param([string]$TemplatePath, [string]$HooksDirectory)
    # The shim references the template by a path RELATIVE TO THE INSTALLED HOOK, so
    # the repository stays self-contained: move it, clone it elsewhere, or run it on
    # another machine and the hook still resolves.
    #
    # It did not used to. Install-Hooks copied nothing and the shim embedded the
    # tool's own absolute template path, so every installed hook was pinned to the
    # directory the tool happened to live in on the machine that installed it. On
    # Windows that path is almost never even expressible relatively - the tool on
    # D: and the repository on C: - so every hook broke the moment the repo moved.
    # Nothing caught it, because -Install was a guaranteed no-op: the template
    # directory did not exist, so New-HookContent had never executed.
    $escaped = Get-HookRelativePath -BasePath $HooksDirectory -TargetPath $TemplatePath
    # A POSIX shim must use forward slashes: a backslash is an escape character
    # to sh, while pwsh accepts '/' on every platform.
    $escaped = $escaped.Replace('\', '/')
    $escaped = $escaped.Replace("'", "'\''")
    # SharedUtils.Resolve-PowerShellHost owns the pwsh-then-powershell
    # preference order. This used to be a third hand-written copy of the same
    # probe, with a different candidate list.
    $hostCommand = 'pwsh'
    if (Get-Command Resolve-PowerShellHost -ErrorAction SilentlyContinue) {
        try { $resolved = [string](Resolve-PowerShellHost); if ($resolved) { $hostCommand = $resolved } } catch { }
    }
    # Resolve to a FULL PATH when possible. A bare 'pwsh' relies on PATH being
    # visible to the shell that runs the hook (sh.exe on Windows, which inherits
    # a converted PATH that may not contain PowerShell's directory). Baking the
    # absolute path removes that dependency. Portability is not a concern here:
    # hooks are installed per-repository on the machine that uses them.
    try {
        $cmd = Get-Command $hostCommand -ErrorAction Stop
        if ($cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) { $hostCommand = $cmd.Source }
    } catch { }
    $shHost = $hostCommand.Replace("'", "'\''")
    # A REAL POSIX SHIM, NOT A POWERSHELL SCRIPT. Git executes hooks itself; on
    # Windows that goes through sh.exe, which honoured the old
    # `#!/usr/bin/env pwsh` by running `pwsh <extensionless hook path>`. pwsh
    # treats that argument as -File and refuses any path that does not end in
    # '.ps1', so every commit failed with "the file does not have a '.ps1'
    # extension" - the hook never ran at all. sh executes this file regardless
    # of its name and only the staged template (which DOES end in .ps1) is
    # passed to -File. The GbuildManagedHook marker stays in a comment because
    # Test-ManagedHook searches the installed file for it.
    return @"
#!/bin/sh
# Managed by gbuild (Steps/manage-githooks.ps1): `$GbuildManagedHook = `$true
# Keep this shim POSIX sh. Git runs hooks directly; on Windows that is sh.exe,
# and pwsh -File rejects a path without a '.ps1' extension.
hook_dir=`$(dirname "`$0")
exec '$shHost' -NoProfile -File "`$hook_dir/$escaped" "`$@"
"@
}

function Install-Hooks {
    param([PSCustomObject]$State)
    $hooksDir = Get-GitHooksDirectory -Path $RepoPath
    if (-not $hooksDir) { Write-ManagedLog "[HOOKS] No safe git hooks directory for $RepoPath" 'Err'; return @() }
    if (-not (Test-Path -LiteralPath $hooksSrc -PathType Container)) { Write-ManagedLog "[HOOKS] No hook templates at $hooksSrc" 'Warn'; return @() }
    if (-not (Test-PathOwnership -Path $hooksDir)) { Write-ManagedLog "[HOOKS] Refusing untrusted hooks directory: $hooksDir" 'Err'; return @() }
    # Stage the templates INSIDE the repository, so the installed shim can name them
    # by a path relative to itself. Without this the shim must embed the tool's
    # absolute install path, which pins every hook to one machine's directory
    # layout - and on Windows the tool and the repository are frequently on
    # different drives, where no relative path exists at all.
    $stageDir = Join-Path $hooksDir '.gbuild'
    try {
        if (-not (Test-Path -LiteralPath $stageDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $stageDir -Force -ErrorAction Stop }
        if (-not (Test-PathOwnership -Path $stageDir)) { Write-ManagedLog "[HOOKS] Refusing untrusted hooks staging directory: $stageDir" 'Err'; return @() }
    } catch { Write-ManagedLog "[HOOKS] Cannot create hooks staging directory: $stageDir" 'Err'; return @() }
    $installed = @()
    foreach ($template in @(Get-ChildItem -LiteralPath $hooksSrc -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $hookName = $template.BaseName
        if ($HookTypes -notcontains $hookName -or -not (Test-HookType $hookName)) { continue }
        $hookPath = Join-Path $hooksDir $hookName
        if ((Test-Path -LiteralPath $hookPath) -and -not (Test-ManagedHook $hookPath)) { Write-ManagedLog "[HOOKS] Refusing unrelated hook: $hookName" 'Warn'; continue }
        if ((Test-Path -LiteralPath $hookPath) -and -not $Force -and (Test-ManagedHook $hookPath)) { Write-ManagedLog "[HOOKS] Exists: $hookName (use -Force)" 'Verbose'; continue }
        try {
            # Stage the template next to the hook FIRST, so a shim is never written
            # that points at a template which is not there.
            $stagedTemplate = Join-Path $stageDir "$hookName.ps1"
            [System.IO.File]::Copy($template.FullName, $stagedTemplate, $true)
            $content = New-HookContent -TemplatePath $stagedTemplate -HooksDirectory $hooksDir
            # The shim MUST use LF line endings: a CRLF shebang (#!/bin/sh\r)
            # makes the kernel look for an interpreter named '/bin/sh\r', which
            # does not exist, so git fails with "cannot exec ... No such file or
            # directory" on Unix. The staged templates keep CRLF (PowerShell is
            # fine with it); only the shim is normalised here.
            $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
            [System.IO.File]::WriteAllText($hookPath, $content, (New-Object System.Text.UTF8Encoding($false)))
            if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
                & chmod +x $hookPath 2>$null
                & chmod +x $stagedTemplate 2>$null
            }
            $installed += $hookName
            Write-ManagedLog "[HOOKS] Installed: $hookName" 'Info'
        } catch { Write-ManagedLog "[HOOKS] Install failed for $hookName" 'Warn' }
    }
    return $installed
}

function Remove-Hooks {
    param([PSCustomObject]$State)
    $hooksDir = Get-GitHooksDirectory -Path $RepoPath
    if (-not $hooksDir) { return @() }
    if (-not (Test-PathOwnership -Path $hooksDir)) { Write-ManagedLog "[HOOKS] Refusing untrusted hooks directory: $hooksDir" 'Err'; return @() }
    $removed = @()
    foreach ($hook in @($HookTypes)) {
        if (-not (Test-HookType $hook)) { continue }
        $path = Join-Path $hooksDir $hook
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if (-not (Test-ManagedHook $path)) { Write-ManagedLog "[HOOKS] Leaving unrelated hook: $hook" 'Warn'; continue }
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop; $removed += $hook; Write-ManagedLog "[HOOKS] Removed: $hook" 'Warn' } catch { Write-ManagedLog "[HOOKS] Remove failed for $hook" 'Warn' }
    }
    # Drop the staged templates this step owns, and the directory once it is empty.
    # Leaving them behind means an uninstalled hook still has live code sitting in
    # the repository's hooks directory.
    $stageDir = Join-Path $hooksDir '.gbuild'
    if (Test-Path -LiteralPath $stageDir -PathType Container) {
        foreach ($hook in @($HookTypes)) {
            if (-not (Test-HookType $hook)) { continue }
            $staged = Join-Path $stageDir "$hook.ps1"
            try { if (Test-Path -LiteralPath $staged -PathType Leaf) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue } } catch { }
        }
        try {
            if (@(Get-ChildItem -LiteralPath $stageDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $stageDir -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    return $removed
}

function Get-HookList {
    param([PSCustomObject]$State)
    $hooksDir = Get-GitHooksDirectory -Path $RepoPath
    if (-not $hooksDir) { Write-ManagedLog '[HOOKS] No safe hooks directory' 'Verbose'; return @() }
    $managed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $hooksDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $HookTypes -and (Test-ManagedHook $_.FullName) })) { $managed += $file.Name; Write-ManagedLog "  - $($file.Name)" 'Info' }
    return $managed
}

if ($Install) { [void](Install-Hooks -State $State) }
if ($Remove) { [void](Remove-Hooks -State $State) }
if ($List) { [void](Get-HookList -State $State) }
if (-not $Install -and -not $Remove -and -not $List) { Write-ManagedLog "Usage: $($MyInvocation.ScriptName) [-Install|-Remove|-List] [-RepoPath path]" 'Warn' }
