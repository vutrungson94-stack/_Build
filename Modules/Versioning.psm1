# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Versioning.psm1 (Semantic Versioning)
# ==================================================================================================
#
# Provides:
#   - Auto-increment version based on git tags
#   - Version from .csproj or version.json
#   - Git commit hash embedding
#   - AssemblyInfo generation
#   - gbuild --version-bump (major|minor|patch)
#   - Changelog auto-generation from git log
# ==================================================================================================

# -- Import dependencies --------------------------------------------------------

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Environment', 'SharedUtils')
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildTimestamp'

# -- Module-scope vars ----------------------------------------------------------
$script:VersionState = @{
    Current    = $null
    Next       = $null
    BumpType   = 'patch'
    CommitHash = $null
    Branch     = $null
    IsDirty    = $false
}

# Private helper: find first .csproj under search root (Level 5: VersionSearchDepth).
<#
.SYNOPSIS
    Resolves the directory version discovery scans. Fails closed.
.DESCRIPTION
    Single owner for "where do we look for .csproj/version sources?". Both call
    sites used to fall back to '.' (the process current directory) when
    State.WorkingDir was missing, so a version bump could read - and, via the
    <Version> regex write path, MODIFY - whatever .csproj happened to sit under
    the launch directory. A missing root now throws.
#>
function Resolve-VersionSearchRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    foreach ($prop in @('WorkingDir', 'ProjectRoot', 'ScriptRoot')) {
        if ($State -and $State.PSObject.Properties.Name -contains $prop -and $State.$prop -and
            [System.IO.Path]::IsPathRooted([string]$State.$prop)) {
            return [string]$State.$prop
        }
    }
    throw [System.InvalidOperationException]::new($(if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.versioning.searchRootUndetermined' -Fallback 'Version search root is undetermined: State carries no rooted WorkingDir/ProjectRoot/ScriptRoot. Refusing to scan the current directory.' } else { 'Version search root is undetermined: State carries no rooted WorkingDir/ProjectRoot/ScriptRoot. Refusing to scan the current directory.' }))
}

function Find-VersionCsproj {
    param([string]$SearchRoot, [PSCustomObject]$State = $null)
    $vDepth = 2
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $vDepth = [int](Get-BuildConstant -Key 'VersionSearchDepth' -State $State -Fallback 2) } catch { $vDepth = 2 }
    }
    if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
        return (Invoke-CompatibleChildItem -Path $SearchRoot -Filter '*.csproj' -Recurse -Depth $vDepth -File | Select-Object -First 1)
    }
    return (Get-ChildItem -Path $SearchRoot -Filter '*.csproj' -Recurse -EA SilentlyContinue | Select-Object -First 1)
}

# -- Version file resolution (single owner of versioning.versionFile) -----------
<#
.SYNOPSIS
    Resolves the absolute path of the version manifest.
.DESCRIPTION
    Single owner of `versioning.versionFile`. Get-CurrentVersion and
    Invoke-VersionBump each used to build this path inline with a hardcoded
    "version.json", so the config key was declared but never read and renaming
    it had no effect. Relative names resolve against the PROJECT root (the parent
    of _Build), matching the previous inline behaviour; absolute names are used
    as-is.
#>
function Resolve-VersionFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    $name = 'version.json'
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        $cfgName = [string](Get-ConfigValue -Path 'versioning.versionFile' -State $State -Default '')
        if (-not [string]::IsNullOrWhiteSpace($cfgName)) { $name = $cfgName }
    }
    if ([System.IO.Path]::IsPathRooted($name)) { return $name }
    # Fail closed: the old final arm returned the BARE filename, so Invoke-VersionBump
    # wrote the project's version manifest into the process current directory.
    if ($State -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) {
        return (Join-Path ([string]$State.ProjectRoot) $name)
    }
    if ($State -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) {
        # Anchor on the TOOL root, not its parent. The parent arm put the
        # version manifest one level ABOVE the tool: with the tool at
        # <workspace>\_Build the manifest landed in <workspace>, and with the
        # tool at <workspace> it landed in the workspace's parent - the one
        # place outside the system where nothing may write. A manifest with
        # no owning project belongs to the tool itself.
        return (Join-Path ([string]$State.ScriptRoot) $name)
    }
    throw [System.InvalidOperationException]::new($(if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.versioning.fileRootUndetermined' -Fallback 'Version file root is undetermined: State carries neither a rooted ProjectRoot nor a rooted ScriptRoot. Refusing to resolve version.json against the current directory.' } else { 'Version file root is undetermined: State carries neither a rooted ProjectRoot nor a rooted ScriptRoot. Refusing to resolve version.json against the current directory.' }))
}

# -- Get current version from .csproj or version.json --------------------------
<#
.SYNOPSIS
    Gets the current version from version.json, .csproj, or git tags.
.DESCRIPTION
    Tries version.json first, then the <Version> element in a .csproj file,
    then the latest git tag. Returns a PSCustomObject with Version, Source,
    CommitHash, Branch, and IsDirty properties.
.PARAMETER State
    The build state object.
.OUTPUTS
    PSCustomObject
#>
function Get-CurrentVersion {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $defaultVersion = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'DefaultProjectVersion' -Fallback '0.1.0' } else { '0.1.0' }
    $result = [PSCustomObject]@{
        Version    = $defaultVersion
        Source     = 'default'
        CommitHash = ''
        Branch     = ''
        IsDirty    = $false
    }

    # 1. Try the configured version file first (versioning.versionFile).
    $versionFile = Resolve-VersionFilePath -State $State

    if (Test-Path $versionFile) {
        try {
            $data = Read-JsonSafe -FilePath $versionFile

            if ($data -and $data.version) {
                $result.Version = $data.version
                $result.Source  = "version.json"
                return $result
            }
        } catch { # version.json parse failed — try next source
        }
    }

    # 2. Try .csproj Version property (Regex to avoid prepending XML declaration on SDK style projects)
    $searchRoot = Resolve-VersionSearchRoot -State $State
    $csproj = Find-VersionCsproj -SearchRoot $searchRoot

    if ($csproj) {
        try {
            $content = Get-Content $csproj.FullName -Raw -Encoding UTF8 -EA Stop
            if ($content -match '<Version>\s*(.*?)\s*</Version>') {
                $result.Version = $matches[1].Trim()
                $result.Source  = $csproj.Name
                return $result
            }
        } catch { # .csproj parse failed — try git tags
        }
    }

    # 3. Try git tags
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $latestTag = (& git describe --tags --abbrev=0 2>$null)
        if ($latestTag) {
            $tag = $latestTag -replace '^v', ''
            if ($tag -match '^\d+\.\d+\.\d+') {
                $result.Version = $matches[0]
                $result.Source  = "git tag: $latestTag"
            }
        }
    }

    return $result
}

# -- Bump version (semantic versioning) ----------------------------------------
<#
.SYNOPSIS
    Bumps the semantic version number and updates version.json and .csproj.
.DESCRIPTION
    Increments the version according to the bump type (major, minor, patch,
    rc, beta), appends git commit hash and dirty flag, updates both
    version.json and the <Version> element in the project's .csproj file.
.PARAMETER State
    The build state object.
.PARAMETER BumpType
    The version bump type: major, minor, patch, rc, or beta.
.OUTPUTS
    string
#>
function Invoke-VersionBump {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$BumpType = ''
    )

    # versioning.autoIncrement owns the default bump type. It was declared in
    # config but never read, so `autoIncrement: minor` silently did nothing and
    # every -VersionBump run applied a patch bump. Validated here rather than via
    # ValidateSet so an unset parameter can fall through to the configured value.
    if ($BumpType -and ($BumpType.ToLowerInvariant() -notin @('major', 'minor', 'patch', 'rc', 'beta'))) {
        throw $(if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.versioning.invalidBumpType' -MessageArgs @([string]$BumpType) -Fallback "Invalid bump type '$BumpType'. Expected one of: major, minor, patch, rc, beta." } else { "Invalid bump type '$BumpType'. Expected one of: major, minor, patch, rc, beta." })
    }
    if ([string]::IsNullOrWhiteSpace($BumpType)) {
        $BumpType = 'patch'
        if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
            $cfgBump = [string](Get-ConfigValue -Path 'versioning.autoIncrement' -State $State -Default '')
            if ($cfgBump -and ($cfgBump.ToLowerInvariant() -in @('major', 'minor', 'patch', 'rc', 'beta'))) {
                $BumpType = $cfgBump.ToLowerInvariant()
            }
        }
    }

    Write-Log (Resolve-LogMessage -Key 'log.version.bumping' -MessageArgs @([string]$BumpType) -Fallback '[VERSION] Bumping version ({0})...') "Info" $State
    if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
        Write-AuditLog -Action "version-bump:$BumpType" -Outcome 'Started' -State $State -Detail "Bumping version from $((Get-CurrentVersion -State $State).Version)"
    }

    $current = Get-CurrentVersion -State $State
    $currentStr = $current.Version
    $major = 0; $minor = 0; $patch = 0; $preRel = $null; $preRelNum = 0
    if ($currentStr -match '^(\d+)\.(\d+)\.(\d+)(?:-(rc|beta)\.(\d+))?$') {
        $major = [int]$matches[1]; $minor = [int]$matches[2]; $patch = [int]$matches[3]
        $preRel = $matches[4]; $preRelNum = if ($matches[5]) { [int]$matches[5] } else { 0 }
    } elseif ($currentStr -match '^(\d+)\.(\d+)\.(\d+)') {
        $major = [int]$matches[1]; $minor = [int]$matches[2]; $patch = [int]$matches[3]
    }

    $newVersion = switch ($BumpType) {
        'major' { "$($major + 1).0.0" }
        'minor' { "$major.$($minor + 1).0" }
        'patch' { "$major.$minor.$($patch + 1)" }
        'rc'    { $n = if ($preRel -eq 'rc') { $preRelNum + 1 } else { 1 }; "$major.$minor.$patch-rc.$n" }
        'beta'  { $n = if ($preRel -eq 'beta') { $preRelNum + 1 } else { 1 }; "$major.$minor.$patch-beta.$n" }
    }

    $commitHash = ''
    $branch = ''
    $isDirty = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $commitHash = (& git rev-parse --short HEAD 2>$null)
        $branch = (& git branch --show-current 2>$null)
        $uncommitted = (& git status --porcelain 2>$null | Measure-Object).Count
        $isDirty = $uncommitted -gt 0
    }

    # SemVer 2.0 ordering: prerelease identifiers must come BEFORE build metadata.
    # 'dirty' belongs to the prerelease part -> 1.2.4-dirty+abc (never 1.2.4+abc-dirty,
    # which is an invalid version because metadata is always the trailing segment).
    $prereleaseSuffix = if ($isDirty) { '-dirty' } else { '' }
    $fullVersion = "$newVersion$prereleaseSuffix"
    # versioning.embedCommitHash gates the SemVer build-metadata segment. The key
    # was declared in config but never read, so setting it to false still produced
    # 1.2.4-dirty+abc. Defaults to true to preserve existing behaviour.
    $embedCommit = $true
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        $cfgEmbed = Get-ConfigValue -Path 'versioning.embedCommitHash' -State $State
        if ($null -ne $cfgEmbed) { $embedCommit = [bool]$cfgEmbed }
    }
    if ($commitHash -and $embedCommit) {
        $fullVersion = "$fullVersion+$($commitHash)"
    }

    Write-Log (Resolve-LogMessage -Key 'log.version.current' -MessageArgs @([string]$current.Version) -Fallback '[VERSION] Current: {0}') "Gray" $State
    Write-Log (Resolve-LogMessage -Key 'log.version.new' -MessageArgs @([string]$fullVersion) -Fallback '[VERSION] New: {0}') "Succ" $State
    Write-Log (Resolve-LogMessage -Key 'log.version.source' -MessageArgs @([string]$current.Source) -Fallback '[VERSION] Source: {0}') "Gray" $State

    # Update the configured version file (versioning.versionFile)
    $versionFile = Resolve-VersionFilePath -State $State

    $versionData = [PSCustomObject]@{
        version     = $newVersion
        fullVersion = $fullVersion
        commit      = $commitHash
        branch      = $branch
        isDirty     = $isDirty
        bumpType    = $BumpType
        bumpedAt    = (Get-Date).ToString('o')
    }

    try {
        Save-JsonSafe -Data $versionData -FilePath $versionFile
        Write-Log (Resolve-LogMessage -Key 'log.version.fileUpdated' -MessageArgs @([string]$versionFile) -Fallback '[VERSION] Updated {0}') "Succ" $State
    } catch {
        Write-Log (Resolve-LogMessage -Key 'log.version.writeFailed' -MessageArgs @([string]$versionFile, $_) -Fallback '[WARN] Failed to write {0}: {1}') "Warn" $State
    }

    # Update .csproj if exists (Regex replacement avoids prepending <?xml ?> to SDK style csproj files)
    $searchRoot = Resolve-VersionSearchRoot -State $State
    $csproj = Find-VersionCsproj -SearchRoot $searchRoot

    if ($csproj) {
        try {
            $content = Get-Content $csproj.FullName -Raw -Encoding UTF8 -EA Stop
            if ($content -match '<Version>\s*.*?\s*</Version>') {
                $content = $content -replace '<Version>\s*.*?\s*</Version>', "<Version>$newVersion</Version>"

                # Write back with UTF8 No BOM for modern dotnet SDKs
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($csproj.FullName, $content, $utf8NoBom)

                Write-Log (Resolve-LogMessage -Key 'log.version.csprojUpdated' -MessageArgs @([string]$csproj.Name) -Fallback '[VERSION] Updated Version in {0}') "Succ" $State
            }
        } catch {
            Write-Log (Resolve-LogMessage -Key 'log.version.csprojFailed' -MessageArgs @([string]$_) -Fallback '[WARN] Failed to update csproj: {0}') "Warn" $State
        }
    }

    $script:VersionState = @{
        Current    = $current.Version
        Next       = $newVersion
        BumpType   = $BumpType
        CommitHash = $commitHash
        Branch     = $branch
        IsDirty    = $isDirty
    }

    if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
        Write-AuditLog -Action "version-bump:$BumpType" -Outcome 'Completed' -State $State -Detail "From $($current.Version) to $fullVersion"
    }
    return $fullVersion
}

# -- Generate changelog from git log -------------------------------------------
<#
.SYNOPSIS
    Generates a CHANGELOG.md from conventional git commit history.
.DESCRIPTION
    Parses the last N git commits, categorizes them by conventional commit
    prefix (feat, fix, docs, style, refactor, test, chore, perf), and writes
    a markdown changelog file with version header and dated entries.
.PARAMETER State
    The build state object.
.PARAMETER CommitCount
    Number of recent commits to include (default: 20).
.PARAMETER OutputPath
    Output file path for the changelog. Defaults to CHANGELOG.md in the
    project root.
.OUTPUTS
    string
#>
function New-Changelog {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        # -1 = sentinel "use default" (versioning.commitCount > BuildConstants > 20)
        [int]$CommitCount = -1,
        [string]$OutputPath = ""
    )
    if ($CommitCount -le 0) {
        $CommitCount = Get-ConfigValue -Path 'versioning.commitCount' -State $State -Default (Get-BuildConstant -Key 'ChangelogCommitCount' -Fallback 20)
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Log (Resolve-LogMessage -Key 'log.version.gitMissing' -Fallback '[WARN] Git not available, cannot generate changelog') "Warn" $State
        return $null
    }

    $version = (Get-CurrentVersion -State $State).Version
    $lines = @()
    $lines += "# Changelog"
    $lines += ""
    $lines += "## [$version] - $(Get-BuildTimestamp -Kind Date)"
    $lines += ""

    # Conventional commits parsing
    $log = & git log -n $CommitCount --pretty=format:"%h|%s|%an|%ad" --date=short 2>$null
    foreach ($entry in $log) {
        $parts = $entry -split '\|', 4
        if ($parts.Count -lt 4) { continue }
        $hash = $parts[0]
        $subject = $parts[1]
        $author = $parts[2]
        $date = $parts[3]

        $icon = switch -Regex ($subject) {
            '^feat'     { '[FEAT]' }
            '^fix'      { '[FIX]' }
            '^docs'     { '[DOCS]' }
            '^style'    { '[STYLE]' }
            '^refactor' { '[REFACTOR]' }
            '^test'     { '[TEST]' }
            '^chore'    { '[CHORE]' }
            '^perf'     { '[PERF]' }
            default     { '[OTHER]' }
        }
        $lines += "- $icon $subject ($hash) - $author - $date"
    }

    $changelog = $lines -join "`n"

    if (-not $OutputPath) {
        # Fail closed: the old final arm was '.', so New-Changelog wrote
        # CHANGELOG.md into the process current directory. A changelog belongs to
        # a project, never to a launch directory.
        $root = if ($State -and $State.ProjectRoot -and [System.IO.Path]::IsPathRooted([string]$State.ProjectRoot)) {
            [string]$State.ProjectRoot
        } elseif ($State -and $State.ScriptRoot -and [System.IO.Path]::IsPathRooted([string]$State.ScriptRoot)) {
            Split-Path ([string]$State.ScriptRoot) -Parent
        } else {
            throw [System.InvalidOperationException]::new($(if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) { Get-LocaleMessage -Key 'log.versioning.changelogRootUndetermined' -Fallback 'Changelog root is undetermined: State carries neither a rooted ProjectRoot nor a rooted ScriptRoot. Refusing to write CHANGELOG.md into the current directory.' } else { 'Changelog root is undetermined: State carries neither a rooted ProjectRoot nor a rooted ScriptRoot. Refusing to write CHANGELOG.md into the current directory.' }))
        }
        $OutputPath = Join-Path $root "CHANGELOG.md"
    }

    try {
        $outDir = Split-Path $OutputPath -Parent
        if ($outDir) { if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { $null = Invoke-EnsureDirectory -Path $outDir } elseif (-not (Test-Path $outDir -PathType Container)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null } }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($OutputPath, $changelog, $utf8NoBom)
        Write-Log (Resolve-LogMessage -Key 'log.version.changelogCreated' -MessageArgs @([string]$OutputPath) -Fallback '[VERSION] Changelog created: {0}') "Succ" $State
    } catch {
        Write-Log (Resolve-LogMessage -Key 'log.version.changelogFailed' -MessageArgs @([string]$_) -Fallback '[WARN] Failed to write changelog: {0}') "Warn" $State
    }

    return $OutputPath
}

# -- Get build metadata (commit, branch, build time) ---------------------------
<#
.SYNOPSIS
    Gets build metadata including commit hash, branch, and dirty state.
.DESCRIPTION
    Returns a hashtable with BuildTime, OS, Hostname, User, Profile, and
    optionally Commit, Branch, and IsDirty from git if available.
.PARAMETER State
    The build state object.
.OUTPUTS
    hashtable
#>
function Get-BuildMetadata {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    $meta = @{
        BuildTime  = (Get-Date).ToString('o')
        OS         = $State.OS
        Hostname   = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { [string](Get-BuildIdentity).Host } else { [System.Environment]::MachineName }
        User       = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { [string](Get-BuildIdentity).User } else { [System.Environment]::UserName }
        Profile    = $State.ActiveProfile
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $meta.Commit   = (& git rev-parse --short HEAD 2>$null)
        $meta.Branch   = (& git branch --show-current 2>$null)
        $meta.IsDirty  = ((& git status --porcelain 2>$null) | Measure-Object).Count -gt 0
    }

    return $meta
}

Export-ModuleMember -Function @('Get-CurrentVersion', 'Invoke-VersionBump', 'New-Changelog', 'Get-BuildMetadata', 'Resolve-VersionFilePath', 'Resolve-VersionSearchRoot', 'Find-VersionCsproj')





