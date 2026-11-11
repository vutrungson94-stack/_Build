# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Release.psm1 - turns a build output into something you can SELL.
#
# A build that only leaves a folder of DLLs in publish-output is not a
# product: nobody can download a folder, verify it, or tell which build it is.
# This module produces the three things a downloadable product needs:
#
#   1. a single archive (zip) with the published app,
#   2. a .sha256 file so the buyer can verify the download,
#   3. a .json manifest: project, version, git commit, build time, whether the
#      binaries are signed, and the hash of the archive.
#
# Where it lands is configured ONCE per machine (the signing profile), so a
# project does not have to be set up by hand: every project that builds
# publishes itself.
#
# HYGIENE RULE: a build must not write outside the tool folder and the
# project it builds. The package therefore stays in <projectRoot>\release, and
# a copy to another folder only happens when the profile explicitly names one.
#
# Nothing here can fail a build: a release that cannot be written is a warning.

Set-StrictMode -Version 1.0

<#
.SYNOPSIS
    Resolves the version and git revision of the built project.
.DESCRIPTION
    Returns @{ Version = '1.0.0'; Commit = 'abc1234'; Dirty = $false }. The
    version comes from the project file, the commit from git when the project is
    a repository. A project without either still gets a usable version.
#>
<#
.SYNOPSIS
    Resolves the release configuration (machine profile + project config).
.DESCRIPTION
    Same layering as the signing config: the project/tool config first, the
    MACHINE profile last, because the machine profile owns the decision to
    publish every build to the shared release folder. Returns a hashtable
    with Enabled, OutputDir, IncludeChecksum and ExcludePatterns.
#>
function Get-ReleaseConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($State)

    $cfg = @{
        Enabled          = $true
        OutputDir        = ''
        IncludeChecksum  = $true
        ExcludePatterns  = @()
        ProfilePath      = ''
    }

    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try {
            $cfg.Enabled = [bool](Get-ConfigValue -Path 'security.release.enabled' -State $State -Default $true -Type bool)
            $cfg.OutputDir = [string](Get-ConfigValue -Path 'security.release.outputDir' -State $State -Default '' -Type string)
            $cfg.IncludeChecksum = [bool](Get-ConfigValue -Path 'security.release.includeChecksum' -State $State -Default $true -Type bool)
            $patterns = Get-ConfigValue -Path 'security.release.excludePatterns' -State $State -Default $null
            if ($patterns) {
                $list = @()
                foreach ($x in @($patterns)) { if (-not [string]::IsNullOrWhiteSpace([string]$x)) { $list += [string]$x } }
                $cfg.ExcludePatterns = $list
            }
        }
        catch { }
    }

    # The machine profile wins: one setup for every project.
    try {
        if (-not (Get-Command Get-CodeSigningProfile -ErrorAction SilentlyContinue)) {
            if (Get-Command Import-ModuleOnDemand -ErrorAction SilentlyContinue) {
                Import-ModuleOnDemand -ModuleNames @('CodeSigning')
            }
        }
        if (Get-Command Get-CodeSigningProfile -ErrorAction SilentlyContinue) {
            $profile = Get-CodeSigningProfile
            $cfg.ProfilePath = [string]$profile.Path
            if ($profile.Release.Count -gt 0) {
                $r = $profile.Release
                if ($r.ContainsKey('enabled')) { $cfg.Enabled = [bool]$r['enabled'] }
                if ($r.ContainsKey('outputDir')) { $cfg.OutputDir = [string]$r['outputDir'] }
                if ($r.ContainsKey('includeChecksum')) { $cfg.IncludeChecksum = [bool]$r['includeChecksum'] }
                if ($r.ContainsKey('excludePatterns')) {
                    $list = @()
                    foreach ($x in @($r['excludePatterns'])) { if (-not [string]::IsNullOrWhiteSpace([string]$x)) { $list += [string]$x } }
                    if ($list.Count -gt 0) { $cfg.ExcludePatterns = $list }
                }
            }
        }
    }
    catch { }

    return $cfg
}

function Get-BuildReleaseVersion {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ProjectDir = '',
        [string]$ProjectName = ''
    )

    $version = ''
    $commit = ''
    $dirty = $false

    if ($ProjectDir) {
        try {
            $proj = Get-ChildItem -LiteralPath $ProjectDir -Filter '*.csproj' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($proj) {
                if (-not $ProjectName) { $ProjectName = $proj.BaseName }
                $text = Get-Content -LiteralPath $proj.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($text) {
                    foreach ($tag in @('Version', 'VersionPrefix', 'PackageVersion', 'AssemblyVersion')) {
                        if ($version) { break }
                        $m = [regex]::Match($text, ('<' + $tag + '>\s*([^<]+?)\s*</' + $tag + '>'))
                        if ($m.Success) { $version = $m.Groups[1].Value.Trim() }
                    }
                }
            }
        }
        catch { }
    }

    if (-not $version) { $version = '0.0.0' }

    if ($ProjectDir) {
        try {
            if (Get-Command git -ErrorAction SilentlyContinue) {
                $inside = (& git -C $ProjectDir rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
                if ($inside -eq 'true') {
                    $commit = (& git -C $ProjectDir rev-parse --short HEAD 2>$null | Out-String).Trim()
                    $status = (& git -C $ProjectDir status --porcelain 2>$null | Out-String).Trim()
                    if ($status) { $dirty = $true }
                }
            }
        }
        catch { }
    }

    if (-not $commit) { $commit = (Get-Date).ToString('yyyyMMdd') }
    if (-not $ProjectName) { $ProjectName = 'build' }

    return @{ Version = $version; Commit = $commit; Dirty = $dirty; ProjectName = $ProjectName }
}

<#
.SYNOPSIS
    Creates the distributable package of a build output.
.DESCRIPTION
    Zips the published output, writes the .sha256 file and the .json manifest
    next to it, and copies the result to the release destination. Returns the
    paths of everything it wrote, or a Skipped result when there is nothing to
    package.
.PARAMETER SourceDir
    The published output (the folder the build produced).
.PARAMETER OutputDir
    Where the archive is written. Defaults to <projectRoot>\release.
.PARAMETER DestinationDir
    Where the archive is COPIED for publishing (a shared release folder).
#>
function New-BuildReleasePackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [string]$ProjectRoot = '',
        [string]$ProjectName = '',
        [string]$OutputDir = '',
        [string]$DestinationDir = '',
        [string[]]$ExcludePattern = @()
    )

    $result = @{ Status = 'Skipped'; Archive = ''; Checksum = ''; Manifest = ''; Copied = ''; Message = ''; SizeBytes = 0 }

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        $result.Message = "publish output not found: $SourceDir"
        return $result
    }

    # The build output usually lives in publish-output\<target>\ (for example
    # publish-output\winforms). Descend into that single child so the archive
    # holds the APPLICATION at its root - a customer unzips the package and
    # runs the exe, without hunting through a folder named after the target.
    $packageRoot = (Resolve-Path -LiteralPath $SourceDir).Path
    $topFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -ErrorAction SilentlyContinue)
    $topDirs = @(Get-ChildItem -LiteralPath $packageRoot -Directory -ErrorAction SilentlyContinue)
    if ($topFiles.Count -eq 0 -and $topDirs.Count -eq 1) {
        $packageRoot = $topDirs[0].FullName
    }

    $files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        $result.Message = 'publish output is empty'
        return $result
    }

    $version = Get-BuildReleaseVersion -ProjectDir $ProjectRoot -ProjectName $ProjectName

    if (-not $OutputDir) {
        $base = if ($ProjectRoot) { $ProjectRoot } else { (Split-Path -Parent $SourceDir) }
        $OutputDir = Join-Path $base 'release'
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        try { New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null }
        catch {
            $result.Status = 'Failed'
            $result.Message = "cannot create the release folder: $($_.Exception.Message)"
            return $result
        }
    }

    $stamp = "$($version.ProjectName)-$($version.Version)-$($version.Commit)"
    $safeStamp = ($stamp -replace '[^A-Za-z0-9._-]', '_')
    $archivePath = Join-Path $OutputDir "$safeStamp.zip"

    # Filter the files that must not ship (sources of the project, nested
    # build output, VCS metadata). The patterns are matched against the path
    # RELATIVE to the publish output - the publish output itself lives in a
    # folder called "publish-output", so matching the absolute path would
    # exclude every single file.
    # Match by PATH SEGMENT, not by a regex with slashes: 'obj/junk.dll' does
    # not match '/obj/' (no leading slash), which let the build junk into the
    # archive. A segment comparison is also separator-agnostic.
    $excludedSegments = @('.git', 'obj', 'bin', '.vs', 'publish-output', 'release')
    $extraSegments = @()
    foreach ($p in $ExcludePattern) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $extraSegments += ($p -replace '[\\/]+$', '')
    }

    $basePath = $packageRoot.TrimEnd('\')
    $selected = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($basePath.Length).TrimStart('\') -replace '\\', '/'
        $skip = $false
        foreach ($seg in ($rel -split '/')) {
            if ($excludedSegments -contains $seg -or $extraSegments -contains $seg) { $skip = $true; break }
        }
        if (-not $skip) { $selected += $f }
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }

        # Zip the SELECTED files, not the whole directory: CreateFromDirectory
        # would put the excluded files (obj\, .git\, nested publish-output\)
        # into the archive, and a product that ships its own build junk is a
        # product nobody can unpack cleanly.
        $stream = [IO.File]::Open($archivePath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($f in $selected) {
                    # Relative to the PACKAGE root, not to the publish output: the
                    # customer must find the exe at the top level of the zip.
                    $rel = $f.FullName.Substring($basePath.Length).TrimStart('\') -replace '\\', '/'
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $zip, $f.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }
            }
            finally { $zip.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = "cannot create the archive: $($_.Exception.Message)"
        return $result
    }

    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction SilentlyContinue)
    $hashText = if ($hash) { $hash.Hash.ToLowerInvariant() } else { '' }
    $result.SizeBytes = (Get-Item -LiteralPath $archivePath).Length

    # 1. The checksum file - this is what the buyer verifies the download with.
    $checksumPath = "$archivePath.sha256"
    try {
        "$hashText  $(Split-Path -Leaf $archivePath)" | Set-Content -LiteralPath $checksumPath -Encoding ASCII
        $result.Checksum = $checksumPath
    }
    catch { }

    # 2. The manifest - what this build is, and whether it is signed.
    $signed = $false
    $signer = ''
    $signedFiles = 0
    $checked = 0

    # The APPLICATION's own executable carries the signature that matters. The
    # framework DLLs next to it are signed by Microsoft, so reporting the first
    # signed file would name Microsoft as the publisher of this product.
    $appExe = @($selected | Where-Object {
        $_.Extension -eq '.exe' -and $version.ProjectName -and
        $_.BaseName -like ("$($version.ProjectName)*")
    } | Select-Object -First 1)
    if ($appExe.Count -eq 0) {
        $appExe = @($selected | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1)
    }

    foreach ($f in @($selected | Where-Object { $_.Extension -in @('.exe', '.dll') } | Select-Object -First 25)) {
        $checked++
        try {
            $sig = Get-AuthenticodeSignature -FilePath $f.FullName -ErrorAction SilentlyContinue
            if ($sig -and $sig.SignerCertificate) {
                $signedFiles++
                $signed = $true
                if ($appExe.Count -gt 0 -and $f.FullName -eq $appExe[0].FullName) {
                    $signer = [string]$sig.SignerCertificate.Subject
                }
            }
        }
        catch { }
    }
    if (-not $signer -and $appExe.Count -gt 0) {
        try {
            $appSig = Get-AuthenticodeSignature -FilePath $appExe[0].FullName -ErrorAction SilentlyContinue
            if ($appSig -and $appSig.SignerCertificate) { $signer = [string]$appSig.SignerCertificate.Subject }
        }
        catch { }
    }

    $manifest = [ordered]@{
        project      = $version.ProjectName
        version      = $version.Version
        commit       = $version.Commit
        dirty        = $version.Dirty
        builtAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        archive      = (Split-Path -Leaf $archivePath)
        sizeBytes    = $result.SizeBytes
        sha256       = $hashText
        signed       = $signed
        signedFiles  = $signedFiles
        checkedFiles = $checked
        signer       = $signer
        machine      = [Environment]::MachineName
    }
    $manifestPath = "$archivePath.json"
    try {
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $result.Manifest = $manifestPath
    }
    catch { }

    $result.Archive = $archivePath
    $result.Status = 'Succeeded'
    $result.Message = "$($selected.Count) file(s) packaged"

    # 3. Copy to a shared destination ONLY when the profile names one.
    if ($DestinationDir -and (Test-Path -LiteralPath $DestinationDir -PathType Container)) {
        try {
            $dest = Join-Path $DestinationDir (Split-Path -Leaf $archivePath)
            Copy-Item -LiteralPath $archivePath -Destination $dest -Force
            if (Test-Path -LiteralPath $checksumPath) { Copy-Item -LiteralPath $checksumPath -Destination ($dest + '.sha256') -Force }
            if (Test-Path -LiteralPath $manifestPath) { Copy-Item -LiteralPath $manifestPath -Destination ($dest + '.json') -Force }
            $result.Copied = $dest
        }
        catch {
            $result.Message = $result.Message + "; copy to the release folder failed: $($_.Exception.Message)"
        }
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-ReleaseConfig',
    'Get-BuildReleaseVersion',
    'New-BuildReleasePackage'
)
