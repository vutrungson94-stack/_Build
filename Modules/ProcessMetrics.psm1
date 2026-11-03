# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.psm1 - CMMI L5: measure the PROCESS, not just the product.
#
# WHY THIS MODULE EXISTS
# The platform already had an industrial measurement apparatus for the thing it
# BUILDS: Metrics/OTLP/Prometheus, SLO burn rate, AnomalyDetector, RootCause,
# AutoTuner, AuditLedger, supply-chain provenance. Build duration, cache hit
# rate and failure rate were all measured and trended.
#
# What was NOT measured was the process that produces the platform itself.
# Every structural gate in Tests\Hygiene.Tests.ps1 is a BINARY assertion: red or
# green, at one instant. A gate cannot answer:
#   * is the backlog of a defect class shrinking, or has the dedup process died?
#   * after a class reached zero, does it stay at zero, or does it creep back?
#   * at the current removal rate, when is the remaining backlog finished?
# Those questions need a TIME SERIES of a RATIO, which is what this module
# produces.
#
# DESIGN (L4 floor + L5 curve, deliberately separated)
#   * Tests\process-baseline.json  -> committed "adoptionFloor". An L4
#     regression gate. Works on a FRESH CI CHECKOUT with no history, because
#     the floor is version-controlled. Lowering the floor is a visible,
#     reviewable act; the file's own description forbids editing it to make a
#     red run green.
#   * Tests\TestResults\process-trend.jsonl -> APPEND-ONLY, one line per run.
#     This is the curve. Ephemeral per run and published as a CI artifact with
#     retention, because a committed time series produces merge conflicts on
#     every PR.
#
# Every class here is deliberately computed by DETERMINISTIC STATIC ANALYSIS:
# no timestamps inside a ratio, no randomness, no dependency on whether a test
# happened to be skipped. That is what makes two runs comparable.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Locale')

# Directories that hold generated output. Scanning them would make every metric
# depend on how many logs the last run happened to leave behind.
#
# BUILT BY THE SHARED HELPER, not hand-written. This list was eleven literal
# regexes of the form '\\logs\\', and every one of them required a literal
# backslash. Measured on the shipped set: all eleven match on Windows and NOT ONE
# matches on Linux or macOS, where $f.FullName spells the separator '/'. So on
# exactly the hosts where the multi-platform claim is being tested, the metric
# silently counted every file under logs/, obj/, bin/, .gbuildcache/ and the
# adoption ratios it produces were wrong - quietly, with no error.
#
# PathUtils.Get-ExcludeDirPattern emits a [\\/] separator class for every
# separator in every entry, so one list is correct on both hosts. That is also the
# seventh hand-written copy of this builder the audit found; routing through the
# shared owner is what removes the last one and stops the copies drifting again.
$script:ProcessMetricsExcludedDirNames = @(
    '.tools', '.gbuild', '.gbuildcache', 'logs', 'TestResults',
    'build-reports', 'distributed-report', 'reports', 'node_modules',
    'obj', 'bin'
)
$script:ProcessMetricsExcludedDirs = @()
if (-not (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue)) {
    $puPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
    if (Test-Path -LiteralPath $puPath -PathType Leaf) {
        $null = Import-Module $puPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}
if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
    try { $script:ProcessMetricsExcludedDirs = @(Get-ExcludeDirPattern -Dirs $script:ProcessMetricsExcludedDirNames) } catch { $script:ProcessMetricsExcludedDirs = @() }
}
if ($script:ProcessMetricsExcludedDirs.Count -eq 0) {
    # Standalone fallback: BuildConstants.SyntaxCheckExcludeDirs names these via
    # the shared builder; when even that is unavailable, emit the same shape here
    # rather than the backslash-only literals that silently matched nothing on
    # POSIX.
    $script:ProcessMetricsExcludedDirs = @($script:ProcessMetricsExcludedDirNames | ForEach-Object { '[\\/]' + [regex]::Escape($_) + '[\\/]' })
}

# A quoted path literal passed to Join-Path / Import-Module that contains a
# backslash. The literal must be a plain PATH TOKEN: no regex metacharacters.
#
# That whitelist is the whole point. The earlier greedy pattern
# ("(Join-Path|Import-Module)[^\r\n]*'[^']*\\[^']*'") produced a false positive
# on Policy.Tests.ps1, where an OPA rule value '(?i)password\s*=' on the SAME
# LINE as an unrelated Join-Path was reported as a Windows path literal. A metric
# that cries wolf on a green build gets ignored, and an ignored metric is worse
# than no metric.
# The patterns are owned by BuildConstants.Get-BuildPathLiteralPatterns and read
# from there, NOT restated here. Two hand-maintained copies is exactly how the
# metric and its gate came to disagree: the gate tightened its token, this copy
# kept the old one, and the ratchet reported 100% while the gate would have
# failed the build. The local values remain only as a standalone fallback for the
# case where BuildConstants cannot be imported at all.
$script:ProcessPathConstructPattern = $null
$script:ProcessPathAssertPattern = $null
if (-not (Get-Command Get-BuildPathLiteralPatterns -ErrorAction SilentlyContinue)) {
    $bcPath = Join-Path $PSScriptRoot 'BuildConstants.psm1'
    if (Test-Path -LiteralPath $bcPath -PathType Leaf) {
        $null = Import-Module $bcPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}
if (Get-Command Get-BuildPathLiteralPatterns -ErrorAction SilentlyContinue) {
    try {
        $pp = Get-BuildPathLiteralPatterns
        $script:ProcessPathConstructPattern = [string]$pp.Construct
        $script:ProcessPathAssertPattern = [string]$pp.Assert
    } catch { }
}
if (-not $script:ProcessPathConstructPattern) {
    $script:ProcessPathToken = "[\w\-\/:.~%+,@# ]+"
    $script:ProcessPathConstructPattern = "(?:Join-Path|Import-Module)[^\r\n]*?'$script:ProcessPathToken(?:\\$script:ProcessPathToken)+'"
    $script:ProcessPathAssertPattern = "-BeLike\s+'\*[^']*\\[^']*'"
}

function Get-ProcessCodeFile {
    <#
    .SYNOPSIS
        Production and test source files that participate in process metrics.
    .DESCRIPTION
        Each result carries .Kind = 'production' | 'test'. A class that is about
        PRODUCTION behaviour must filter on it, because otherwise test FIXTURES
        that legitimately mention a contract name (a Pester test asserting a
        handler fired for 'EVT_BUILD_ERROR') get counted as production
        violations. The 2026-09 audit's whole lesson was that a metric and its
        gate disagreeing on a green build destroys the credibility of the trend,
        so the scope is explicit rather than implicit in the caller.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ToolRoot
    )

Set-StrictMode -Version 1.0
    $result = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        @{ Path = (Join-Path $ToolRoot 'Modules'); Kind = 'production' },
        @{ Path = (Join-Path $ToolRoot 'Steps');  Kind = 'production' },
        @{ Path = (Join-Path $ToolRoot 'Hooks');  Kind = 'production' },
        @{ Path = (Join-Path $ToolRoot 'Tests');  Kind = 'test' }
    )
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r.Path -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $r.Path -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -notin @('.psm1', '.ps1')) { continue }
            $excluded = $false
            foreach ($pattern in $script:ProcessMetricsExcludedDirs) {
                if ($f.FullName -match $pattern) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            # The gate file carries every detection pattern by definition and
            # the test files carry every key/fixture by definition; including
            # either would make the metric self-referential.
            if ($f.Name -in @('Hygiene.Tests.ps1', 'ModuleHygiene.Tests.ps1', 'Locale.Tests.ps1', 'ProcessMetrics.psm1')) { continue }
            $result.Add([PSCustomObject]@{ FullName = $f.FullName; Name = $f.Name; Extension = $f.Extension; Kind = $r.Kind; DirectoryName = $f.Directory.Name }) | Out-Null
        }
    }
    # Entry scripts at the tool root are production too. The process metric used
    # to scan only Modules/Steps/Hooks/Tests, so `gbuild.ps1 -Help` prose and
    # installer errors lived outside every adoption ratio while still being the
    # text a user reads first.
    foreach ($f in @(Get-ChildItem -LiteralPath $ToolRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
        if ($f.Name -in @('Hygiene.Tests.ps1', 'ModuleHygiene.Tests.ps1', 'Locale.Tests.ps1', 'ProcessMetrics.psm1')) { continue }
        $result.Add([PSCustomObject]@{ FullName = $f.FullName; Name = $f.Name; Extension = $f.Extension; Kind = 'production'; DirectoryName = $f.Directory.Name }) | Out-Null
    }
    return @($result)
}

function Get-ProcessCodeText {
    <#
    .SYNOPSIS
        File text with WHOLE-LINE and BLOCK comments removed, LINE NUMBERS PRESERVED.
    .DESCRIPTION
        Comments are stripped because they are prose, not code. The hygiene gates
        already made this call, and ProcessMetrics MUST use the SAME
        methodology: a ratio computed one way by the gate and another way by the
        metric would make the two disagree on a green build, which destroys the
        credibility of the whole curve.

        Comment lines are BLANKED, never removed. This version used to drop them
        outright, which silently renumbered every line after the first comment
        block in a file - so the offender list it reports, whose entire purpose is
        to be actionable ("file:line"), pointed at the wrong lines. SDK.psm1:118
        was reported as a hardcoded-English log site; line 118 is the sentence
        "Build state carrying BuildConfig (optional...)" inside a doc comment,
        while the real site was line 166. Anyone acting on that report would have
        edited the wrong code.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object[]]$Files)
    $map = @{}
    foreach ($f in $Files) {
        $raw = try { [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) } catch { '' }
        if ([string]::IsNullOrEmpty($raw)) { $map[$f.FullName] = ''; continue }
        $out = [System.Collections.Generic.List[string]]::new()
        $inBlock = $false
        $inHereString = $false
        $hereDelim = ''
        foreach ($line in ($raw -split "`r?`n")) {
            $probe = $line.Trim()
            if ($inHereString) {
                # Keep the line number by blanking the physical line. A here-string
                # is DATA (an embedded script, help text, a template that ships to
                # a profile); counting its Write-Host lines as production emits
                # charged the reporter to localize the source code it embeds.
                $out.Add('') | Out-Null
                if ($probe -like ($hereDelim + '@*') -or $probe -eq $hereDelim + '@' -or $probe -like ($hereDelim + '@ *')) {
                    $inHereString = $false
                    $hereDelim = ''
                }
                continue
            }
            if ($inBlock) {
                # Blank, do not remove: keeps every following line at its real number.
                $out.Add('') | Out-Null
                if ($probe -match '#>') { $inBlock = $false }
                continue
            }
            if ($probe -match '^<#') {
                $out.Add('') | Out-Null
                if ($probe -notmatch '#>') { $inBlock = $true }
                continue
            }
            if ($probe -match '^#') { $out.Add('') | Out-Null; continue }
            # Here-string start: @' or @" (and @' / @" can be concatenated after
            # `=`, so anchor on the end of the trimmed line).
            if ($probe -match '^[^\r\n]*@([\''"])\s*$') {
                $hereDelim = $Matches[1]
                $inHereString = $true
                # Preserve any code before the opening marker, blank only the data.
                $prefix = $line -replace '@[\''"]\s*$', ''
                $out.Add($prefix) | Out-Null
                continue
            }
            # Drop trailing comments on a code line; the code itself survives.
            $code = ($line -replace '\s+#(?![{]).*$', '')
            $out.Add($code) | Out-Null
        }
        $map[$f.FullName] = ($out -join "`n")
    }
    return $map
}

function New-ProcessAdoptionClass {
    <#
    .SYNOPSIS
        One adoption class: a numerator, a denominator, the ratio, AND the
        specific sites still outstanding.
    .DESCRIPTION
        Carrying the offenders is not decoration. A ratio with no list of what
        is left is a number nobody can act on, which is the failure mode this
        whole module exists to eliminate. Every class therefore records
        "file:line" for each remaining bypass, so the remediation work for the
        next increment is derivable from the measurement itself.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Class,
        [string]$Description = '',
        [int]$Adopted = 0,
        [int]$Total = 0,
        [string]$Metric = '',
        [string[]]$Offenders = @()
    )
    $ratio = if ($Total -gt 0) { [math]::Round(($Adopted / [double]$Total), 4) } else { 1.0 }
    return [PSCustomObject]@{
        Class       = $Class
        Description = $Description
        Adopted     = $Adopted
        Total       = $Total
        Adoption    = $ratio
        Metric      = $Metric
        Remaining   = $Offenders.Count
        Offenders   = @($Offenders)
    }
}

function Get-BuildProcessMetrics {
    <#
    .SYNOPSIS
        Measures every adoption class in one deterministic pass.
    .DESCRIPTION
        Returns an object with .Classes (the adoption ratios), .MeanAdoption
        (mean adoption across classes), .BelowParityCount and .BelowParityRatio
        (how many classes, and what fraction, are not yet at 1.0).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([string]$ToolRoot)

    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    $files = @(Get-ProcessCodeFile -ToolRoot $ToolRoot)
    $prod  = @($files | Where-Object { $_.Kind -eq 'production' })
    $text  = Get-ProcessCodeText -Files $files
    $allProd = (($prod | ForEach-Object { [string]$text[$_.FullName] }) -join "`n")
    # localeKeyWiring needs raw text too: a locale key can be consumed inside an
    # emitted template script. The shared text map blanks here-strings for
    # prose-emit measurement, but the key is still real usage if the emitted
    # script itself calls Resolve-LogMessage with it.
    $allProdRaw = @()
    foreach ($f in @($prod)) {
        try { $allProdRaw += @([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)) } catch { }
    }
    $allProdRaw = $allProdRaw -join "`n"
    $all   = (($files | ForEach-Object { [string]$text[$_.FullName] }) -join "`n")
    $classes = [System.Collections.ArrayList]::new()

    # --- 1. file-lock delegation: only SharedUtils may open a lock ----------
    # The detection pattern is assembled from parts on purpose. Written
    # literally, the string "FileShare\]::None" appears in this file's own
    # source, and the hygiene gate that forbids inline lock loops then flags
    # ProcessMetrics.psm1 as an offender - the metric would trip the gate that
    # guards it. Same trap the gate files themselves avoid.
    $lockOpenPattern = 'FileShare\]::' + 'None'
    $lockOwners = 0; $lockOffenders = 0; $lockList = @()
    foreach ($f in $prod) {
        if ($f.Name -ne 'SharedUtils.psm1') { continue }
        $lockOwners = ([regex]::Matches([string]$text[$f.FullName], $lockOpenPattern)).Count
    }
    foreach ($f in $prod) {
        if ($f.Name -eq 'SharedUtils.psm1') { continue }
        $n = ([regex]::Matches([string]$text[$f.FullName], $lockOpenPattern)).Count
        if ($n -gt 0) { $lockOffenders += $n; $lockList += ("{0} x{1}" -f $f.Name, $n) }
    }
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'fileLockDelegation' -Adopted $lockOwners -Total ($lockOwners + $lockOffenders) -Description 'Only SharedUtils opens a lock FileStream; every module calls Enter-BuildFileLock. The Semaphore primitive used by DeployTargets.Enter-DeployLock is a separate, machine-wide primitive and is intentionally not counted by this class (a lock here is cross-process, not a FileStream over a path)' -Metric 'lock FileStream sites outside SharedUtils' -Offenders $lockList))

    # --- 2. event-name registry (production publishers only) ----------------
    $evtVars = ([regex]::Matches($allProd, '\$EVT_[A-Z_]+')).Count
    $evtLits = ([regex]::Matches($allProd, "(?:-EventName\s+|Add-BuildEvent\s+|Send-BuildEvent\s+)'EVT_[A-Z_]+'")).Count
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'eventNameRegistry' -Adopted $evtVars -Total ($evtVars + $evtLits) -Description 'Publishers use the EventBus EVT_* constants instead of repeating the string' -Metric 'quoted EVT_* literals at production publish sites'))

    # --- 3. SharedUtils lazy-import owner (production only) -----------------
    # Logging.psm1 is REGISTERED as exempt, not overlooked. It is the root of
    # the bootstrap chain: ModuleBootstrap.ps1 dot-sources BuildImport, which
    # loads Logging, so Logging cannot dot-source ModuleBootstrap without a
    # cycle. It is the single module for which the shared owner is unreachable,
    # and saying so in the metric is what keeps the ratio honest instead of
    # quietly penalising the one file that cannot comply.
    $sharedUtilsImportExempt = @('Logging.psm1')
    $inline = 0; $inlineList = @()
    foreach ($f in $prod) {
        if ($f.Extension -ne '.psm1') { continue }
        if ($sharedUtilsImportExempt -contains $f.Name) { continue }
        $n = ([regex]::Matches([string]$text[$f.FullName], "Join-Path \`$PSScriptRoot 'SharedUtils\.psm1'")).Count
        if ($n -gt 0) { $inline += $n; $inlineList += ("{0} x{1}" -f $f.Name, $n) }
    }
    $ownerCalls = ([regex]::Matches($allProd, 'Initialize-BuildSharedUtils')).Count
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'sharedUtilsImportOwner' -Adopted $ownerCalls -Total ($ownerCalls + $inline) -Description 'The lazy SharedUtils import has one owner in ModuleBootstrap.ps1 (Logging.psm1 is the bootstrap root and is registered exempt)' -Metric 'inline Join-Path $PSScriptRoot SharedUtils.psm1 sites outside the exempt bootstrap root' -Offenders $inlineList))

    # --- 4. string-hash delegation (production only) -----------------------
    # Scope, stated precisely because the previous fingerprint was wrong twice:
    #   * A STRING hash (UTF8 -> SHA256 -> LOWERCASE HEX over a path, key or
    #     fingerprint) is what the shared owner Get-BuildStringHash provides.
    #   * A BYTE-STREAM digest (ComputeHash over file content) is a different
    #     question - the owner takes a string, not bytes.
    #   * A BASE64 digest with a CONFIGURABLE algorithm (AuditLedger's
    #     security.ledger.hashAlgorithm, default SHA256) is a third shape: the
    #     encoding and the algorithm are both caller-chosen, so it cannot be
    #     routed through a fixed hex/SHA256 helper without changing the ledger
    #     format that existing entries were signed with.
    # The earlier 'UTF8.GetBytes AND BitConverter anywhere in the file' test
    # conflated all three, which made the class permanently unsatisfiable and hid
    # the real backlog - exactly the failure this module's own header warns
    # about, since an inaccurate metric is worse than none.
    $delegated = ([regex]::Matches($allProd, 'Get-BuildStringHash')).Count
    # AuditLedger's own digest is registered, not overlooked: base64 output and a
    # configurable algorithm, so it is not a spelling of the hex/SHA256 helper.
    $byteOrBase64DigestExempt = @('AuditLedger.psm1')
    $manual = 0; $hashList = @()
    # The string-hash shape, and only that shape:
    #     $v = [System.Text.Encoding]::UTF8.GetBytes($someString)
    #     ... $sha.ComputeHash($v) ... BitConverter::ToString ... (hex)
    #
    # The previous fingerprint required `ComputeHash\([^)]*UTF8\.GetBytes` on
    # ONE line, so it matched nothing in this codebase (every site assigns $bytes
    # on a separate line, and the hex render often precedes the ComputeHash call
    # textually). The class reported 21/21 = 100% while PluginHelpers and Locale
    # both carried an inline copy. A ratchet that cannot fail is worse than none.
    #
    # Tracking the VARIABLE is what keeps real file digests out: Cache hashes a
    # MemoryStream built from file content and encodes a length prefix with
    # UTF8.GetBytes nearby, so a proximity-only rule flags it; but ComputeHash is
    # fed $combined, never the $lengthBytes that UTF8.GetBytes produced, so the
    # data-flow check leaves it alone - as it correctly leaves Standalone's
    # [byte[]] parameter digest, CacheProvider's FileStream digest and
    # SupplyChain's ReadAllBytes digest unflagged.
    $assignRx = [regex]'\$(\w+)\s*=\s*[^=]{0,160}?UTF8\.GetBytes\('
    $hashRx  = [regex]'ComputeHash\(\$(\w+)\)'
    $hexRx   = [regex]'BitConverter\]::ToString'
    foreach ($f in $prod) {
        if ($f.Name -eq 'SharedUtils.psm1') { continue }
        if ($byteOrBase64DigestExempt -contains $f.Name) { continue }
        $c = [regex]::Replace([string]$text[$f.FullName], '\s+', ' ')
        $isStringHash = $false
        foreach ($am in $assignRx.Matches($c)) {
            $v = $am.Groups[1].Value
            $windowStart = $am.Index
            $window = $c.Substring($windowStart, [Math]::Min(700, $c.Length - $windowStart))
            $fed = $false
            foreach ($hm in $hashRx.Matches($window)) { if ($hm.Groups[1].Value -eq $v) { $fed = $true; break } }
            if (-not $fed) { continue }
            if (-not $hexRx.IsMatch($window)) { continue }
            $isStringHash = $true; break
        }
        if ($isStringHash) { $manual++; $hashList += $f.Name }
    }
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'stringHashDelegation' -Adopted $delegated -Total ($delegated + $manual) -Description 'UTF8->SHA256->hex over a STRING goes through the shared Get-BuildStringHash; byte-stream file digests are a separate concern and are not counted' -Metric 'production files that build a string hash inline: UTF8.GetBytes -> assigned variable -> ComputeHash(that variable) -> hex' -Offenders $hashList))

    # --- 5. platform-neutral path literals in tests -------------------------
    # Exemptions are PATTERN-scoped, not file-scoped, and are read from
    # Tests/process-baseline.json - the same source the hygiene gate reads. Two
    # earlier iterations were wrong and both are worth recording:
    #   * the list was hardcoded here AND in the gate, and the copies drifted
    #     (metric said 90%, gate said 100%) - a metric and its gate disagreeing
    #     on a green build destroys trust in the whole trend;
    #   * the list exempted whole FILES, so adding one new backslash to an
    #     already-exempt file was invisible. That is a suppression wearing a
    #     name. Each exemption now names the exact offending fragment, and any
    #     OTHER backslash in the same file is still counted.
    $pathTotal = 0; $pathClean = 0; $pathList = @()
    $allowed = @()
    $baselinePath = Join-Path $ToolRoot 'Tests/process-baseline.json'
    if (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
        try {
            $bj = [System.IO.File]::ReadAllText($baselinePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($bj.PSObject.Properties.Name -contains 'platformPathLiteralExemptions') {
                $allowed = @($bj.platformPathLiteralExemptions | ForEach-Object { [PSCustomObject]@{ file = [string]$_.file; pattern = [string]$_.pattern } })
            }
        } catch { }
    }
    $isExempt = {
        param([string]$FileName, [string]$Line)
        foreach ($e in $allowed) {
            if ($e.file -ne $FileName) { continue }
            if ($Line.Contains($e.pattern)) { return $true }
        }
        return $false
    }
    # SCOPE WAS WRONG, and the mutation test in Tests/ProcessMetrics.Mutation.Tests.ps1
    # is what proved it. This loop only ever considered `Kind -eq 'test'`, so the
    # class advertised "no Windows-only path literals" while inspecting nothing
    # but the test suite - the one place a backslash is least likely to be
    # load-bearing. Production Modules/ was never scanned, so a hardcoded
    # 'cache\index.json' in a shipped module would have been invisible while the
    # class reported a confident 104/104. The baseline file's own wording
    # ("Test files build repository paths with a forward slash...") described the
    # implementation rather than the requirement.
    #
    # It now scans production too, because multi-platform portability is a claim
    # about SHIPPED code. The pattern itself still targets a QUOTED windows path
    # segment after a path constructor, which is what actually breaks on POSIX;
    # regex character classes like '[\\/]' and explicit separator normalisation
    # are not that shape and are not charged.
    foreach ($f in $files) {
        if ($f.Kind -eq 'test') {
            if ($f.Extension -ne '.ps1') { continue }
        } else {
            if ($f.Kind -ne 'production') { continue }
            if ($f.Extension -notin @('.psm1', '.ps1')) { continue }
        }
        $pathTotal++
        $c = [string]$text[$f.FullName]
        $bad = $false; $why = ''
        $ln = 0
        foreach ($line in ($c -split "`n")) {
            $ln++
            if (($line -match $script:ProcessPathConstructPattern) -or ($line -match $script:ProcessPathAssertPattern)) {
                if (& $isExempt $f.Name $line) { continue }
                $bad = $true; $why = ($line.Trim()); break
            }
        }
        if ($bad) { $pathList += ("{0}:{1}  {2}" -f $f.Name, $ln, $why) } else { $pathClean++ }
    }
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'platformPathLiterals' -Adopted $pathClean -Total $pathTotal -Description 'No shipped file constructs a repository path with a hardcoded Windows backslash separator, so a path built here resolves on POSIX too (production Modules/Steps/Hooks AND the test suite are both scanned)' -Metric 'files constructing a repository path with a backslash separator (production and test)' -Offenders $pathList))

    # --- 6. locale key wiring ----------------------------------------------
    $localesDir = Join-Path $ToolRoot 'Locales'
    $localeAdopted = 0; $localeTotal = 0
    if (Test-Path -LiteralPath $localesDir -PathType Container) {
        $enFile = Get-ChildItem -LiteralPath $localesDir -Filter 'en.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($enFile) {
            $enKeys = @()
            try { $enKeys = @(([System.IO.File]::ReadAllText($enFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).PSObject.Properties.Name) } catch { $enKeys = @() }
            $families = @('log.stepName.', 'log.strategy.', 'log.sdk.source.', 'log.level.', 'log.marker.', 'log.status.')
            $localeTotal = $enKeys.Count
            $localeUnreferenced = @()
            foreach ($k in $enKeys) {
                if ($allProdRaw.Contains($k)) { $localeAdopted++; continue }
                $isFamily = $false
                foreach ($fam in $families) { if ($k.StartsWith($fam)) { $isFamily = $true; break } }
                if ($isFamily) { $localeAdopted++; continue }
                $localeUnreferenced += $k
            }
        }
    }
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'localeKeyWiring' -Adopted $localeAdopted -Total $localeTotal -Description 'Every shipped locale key is reachable from code (no translated strings nobody reads)' -Metric 'unreferenced locale keys' -Offenders $localeUnreferenced))

    # --- 7. i18n prose coverage --------------------------------------------
    # MEASURES PROSE, NOT LINES.
    #
    # The previous version counted every emit line without a locale resolver, which
    # conflated two unrelated things:
    #   * PROSE          a literal English sentence a user reads -> must be localized
    #   * NOT PROSE      a separator, ASCII art, or relayed tool/build output
    #                    -> there is nothing to translate
    # Measured on the shipped tree that split is 223 prose vs 46 non-prose. Forcing
    # the non-prose sites through the locale system would mean putting
    # `Write-Log "   $($glyphs.gear)  $msg"` behind a translation key, which is
    # absurd; excluding the prose instead would let real English sentences escape.
    #
    # The baseline's own note had already recorded the ceiling ("50 of the 565 emit
    # lines are NOT translatable prose ... achievable ceiling ~515/565") but the
    # metric never implemented it, so the class was permanently < 1.0 no matter how
    # much prose was migrated. That makes a ratchet nobody can satisfy, which is the
    # same "metric that cannot fail" defect the string-hash class had.
    #
    # Non-prose is EXCLUDED from the denominator but still REPORTED, so it stays
    # visible: a new decorative emit line cannot quietly inflate the ratio.
    $emitProseTotal = 0; $emitProseLocalized = 0
    $emitNonProse = 0
    $emitList = @(); $emitNonProseList = @()
    # NOT line-anchored. The previous pattern was
    #     '(?m)^\s*(?:Write-Log|Write-Info|Warn|Error|Success|Step)\b'
    # which only matched an emit call at the START of a line, while the dominant
    # form in this codebase is the mid-line guard:
    #     if ($x) { Write-Log 'msg' 'Warn' $State }
    # 44% of user-facing emit lines are mid-line, so the gate was structurally
    # blind to them and reported 100% while ~200 English sentences shipped. A
    # ratchet that cannot fail is worse than no ratchet: it certifies the defect.
    #
    # The verb set is enumerated per OCCURRENCE, so two emits on one line count
    # twice, and Write-Host / Write-Warning are included because they carry much
    # of the user-facing text in Steps/ and Hooks/. Write-Success and Write-Step
    # were listed but are not PowerShell verbs and exist nowhere in the tree.
    #
    # Write-SubLog / Write-LogSafe / Write-ErrorSafe were ALSO absent and were
    # added for the same reason Write-Host was: they are user-facing emit paths.
    # Write-SubLog wraps its argument in
    #     Resolve-LogMessage -Key 'Processing' -MessageArgs @($msg)
    # which localizes the TEMPLATE only - the caller's English still reaches the
    # console verbatim, so 'Write-SubLog "Running tests for X..."' is an
    # unlocalized emit exactly like Write-Log. Excluding a verb from the scan is
    # indistinguishable from having no gate for it at all.
    #
    # Two exclusions keep the denominator honest:
    #   * a GUARD, not an emit: `Get-Command Write-Log` / `Get-Module Logging`
    #     names the verb as an argument. There are hundreds of these and they
    #     emit nothing.
    #   * the token must be in COMMAND position: preceded by start of line or
    #     one of  { ; ( } and not by a member access.
    # Residual false-positive classes closed after the real backlog was migrated:
    # a parameter NAME (-NoNewline, -ForegroundColor), the VALUE of a colour
    # switch (the bare token Gray / Red), and PowerShell language keywords plus
    # block punctuation following the call on the same line ('} catch { }').
    # `throw` joins the emit verbs: an exception message is the text a CI log or
    # IDE shows first, so it is subject to the same localization rule as Write-Log.
    $emitRe = '(?<![\w-])(?:Write-Log|Write-LogSafe|Write-ErrorSafe|Write-Info|Write-Warn|Write-Done|Write-Fail|Write-SubLog|Write-Host|Write-Warning|throw)(?![\w-])'
    $guardRe = '(?:Get-Command|Get-Module|Remove-Module|Import-Module|Export-ModuleMember)\s+(?:-\w+\s+\S+\s+)*(?:Write-Log|Write-LogSafe|Write-ErrorSafe|Write-Info|Write-Warn|Write-Done|Write-Fail|Write-SubLog|Write-Host|Write-Warning)(?![\w-])'
    $locRe = 'Get-LocaleMessage|Get-LogLocalized|Resolve-LogMessage|Get-MenuLabel|Get-MenuTitle|Get-PluginLocaleText'
    foreach ($f in $prod) {
        $c = [string]$text[$f.FullName]
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $ln = 0
        # Comment-aware. The scan used to run over raw file text, so an emit-shaped
        # phrase INSIDE a doc comment counted as a real emit site - the shipped
        # Logging.psm1 doc block literally contains the line
        # `Write-Log wrapper" item in the 10/10 hardening plan.`, which is prose
        # about the helper, not a call to it. No comment stripper existed in
        # Modules/, so the state is tracked inline here.
        $inBlockComment = $false
        foreach ($line in ($c -split "`n")) {
            $ln++
            $probe = $line.Trim()
            if ($inBlockComment) {
                if ($probe -match '#>') { $inBlockComment = $false }
                continue
            }
            if ($probe -match '^<#') {
                if ($probe -notmatch '#>') { $inBlockComment = $true }
                continue
            }
            if ($probe -match '^#') { continue }
            if ($line -notmatch $emitRe) { continue }
            if ($line -match '^\s*function\s+') { continue }
            # Strip the guard occurrences first: `Get-Command Write-Log` names the
            # verb as an argument and emits nothing, so it is not an emit site.
            # The remainder is then enumerated per OCCURRENCE, not per line.
            $scanLine = [regex]::Replace($line, $guardRe, ' ')
            if ($scanLine -notmatch $emitRe) { continue }
            $lineLocalized = [bool]($scanLine -match $locRe)
            foreach ($emitMatch in [regex]::Matches($scanLine, $emitRe)) {
            # Does the message argument carry translatable words? Decided on the
            # message, not on the level/colour/state arguments that follow it.
            $rest = $scanLine.Substring($emitMatch.Index + $emitMatch.Length).Trim()
            $nonProse = $false
            if ($emitMatch.Value -eq 'throw') {
                # A thrown exception's PROSE comes from its string argument, not
                # from `[System.InvalidOperationException]::new(...)` or from a
                # later `$message` variable. Treat bare rethrow and relayed
                # variables as non-prose; charge only when an English literal is
                # actually present on the line (which is what the locale gate
                # must see).
                if ([string]::IsNullOrWhiteSpace($rest) -or $rest -match '^\$' -or $rest -match '^\( *\$') {
                    $nonProse = $true
                } else {
                    $throwLiterals = @([regex]::Matches($rest, '[''"]([^''"]*)[''"]') | ForEach-Object { $_.Groups[1].Value })
                    $throwWords = @(($throwLiterals -join ' ') -split '\s+' | Where-Object { $_ -match '[A-Za-z]{3,}' })
                    if ($throwLiterals.Count -eq 0 -or $throwWords.Count -eq 0) { $nonProse = $true }
                }
            } elseif ($rest -match '^('' "")\s*(,|\)|$)') {
                # Write-Log ' ' - a spacing separator.
                $nonProse = $true
            } elseif ($rest -match '^\-Message\s+\$') {
                # Write-Log -Message $Var ... - a forwarding call (Write-LogSafe
                # and friends). The caller owns the text and has already resolved it.
                $nonProse = $true
            } elseif ($rest -match '^[''"]') {
                $lit = [regex]::Match($rest, '^[''"]([^''"]*)[''"]').Groups[1].Value
                # Decide on the WORDS, not on the string. Interpolations first:
                # `"   $($glyphs.gear)  $msg"` contains the letters "gear" and
                # "msg" only inside interpolated values, so the literal text is a
                # prefix plus a relayed value - nothing to translate. Then drop
                # bracketed subsystem tags: "[PARALLEL] $msg" is a marker, not
                # prose, while "[SDK] Building {0} ..." is.
                $stripped = [regex]::Replace($lit, '\$\([^\)]*\)', ' ')
                # The BRACED variable form ${name} is the same kind of
                # interpolation as $(...). Without this it survives as the
                # literal text '{rb}', and
                #   Write-LogSafe "${lb}FAIL${rb} $($_.Exception.Message)"
                # - a colour marker wrapped around a RELAYED exception message,
                # with nothing to translate - was charged as translatable prose.
                $stripped = [regex]::Replace($stripped, '\$\{[^}]*\}', ' ')
                $stripped = [regex]::Replace($stripped, '\$[A-Za-z_][\w:.\[\]]*', ' ')
                $stripped = [regex]::Replace($stripped, '\[[A-Z][A-Z0-9_]{1,}\]', ' ')
                if ($stripped.Trim() -eq '' -or $stripped -notmatch '[A-Za-z]{3,}') {
                    $nonProse = $true
                }
            } elseif ($rest -match '^\$') {
                # Relayed output, or a value that was already localized upstream.
                $nonProse = $true
            } else {
                # A COMPUTED message: an expression rather than a plain literal,
                # e.g. Menu's `(("  [{0}]" -f $k).PadRight(7) + " " + $item.Label)`
                # which renders an already-localized label. Test the same way:
                # remove every string literal and every interpolation, and if no
                # translatable word survives, there is nothing to translate.
                $stripped = [regex]::Replace($rest, '\$\([^\)]*\)', ' ')
                $stripped = [regex]::Replace($stripped, '\$\{[^}]*\}', ' ')
                $stripped = [regex]::Replace($stripped, '\$[A-Za-z_][\w:.\[\]]*', ' ')
                $stripped = [regex]::Replace($stripped, "'[^']*'", ' ')
                $stripped = [regex]::Replace($stripped, '"[^"]*"', ' ')
                $stripped = [regex]::Replace($stripped, '\[[A-Z][A-Z0-9_]{1,}\]', ' ')
                # Method calls are code, not words: `.PadRight(7)` is not prose.
                $stripped = [regex]::Replace($stripped, '\.[A-Za-z_]\w*\s*\(', ' ')
                # Parameter NAMES are code too, and they were the last class of
                # false positive: `Write-Host (' ' * $pad) -NoNewline
                # -ForegroundColor Gray` is a spacing/separator emit, but with
                # only the literals and variables removed, the words
                # "NoNewline" and "ForegroundColor" survived the `[A-Za-z]{3,}`
                # test and the line was charged as translatable prose. The
                # emitted text was punctuation. A switch is `-Name`, never a
                # standalone word, so dropping `-Word` is unambiguous here.
                $stripped = [regex]::Replace($stripped, '-\w+', ' ')
                # ... and so is the VALUE of a colour switch. After `-ForegroundColor`
                # is dropped, the bare token "Gray"/"Red" remained and satisfied
                # the same test on two lines whose real output was a carriage
                # return and an exception message:
                #   Write-Host ("`r" + $msg + $pad) -NoNewline -ForegroundColor Gray
                #   Write-Host ("[FATAL] " + $_.Exception.Message) -ForegroundColor Red
                # A ConsoleColor name is a fixed enumeration, not prose.
                $stripped = [regex]::Replace($stripped, '\b(?:Black|DarkBlue|DarkGreen|DarkCyan|DarkRed|DarkMagenta|DarkYellow|Gray|DarkGray|Blue|Green|Cyan|Red|Magenta|Yellow|White)\b', ' ')
                # Language keywords and block punctuation. `try { Write-Host
                # ("`r" + $msg + $pad) -NoNewline -ForegroundColor Gray } catch
                # { }` emits a carriage return plus relayed build output, but the
                # word "catch" that FOLLOWS the call on the same line survived
                # every strip above and was charged as translatable prose. These
                # are reserved words; they can never be part of emitted text.
                $stripped = [regex]::Replace($stripped, '\b(?:catch|finally|else|elseif|then|end|begin|process|foreach|while|do|until|switch|continue|break|return|function|filter|param|throw|trap|in)\b', ' ')
                $stripped = $stripped -replace '[{}]', ' '
                if ($stripped.Trim() -eq '' -or $stripped -notmatch '[A-Za-z]{3,}') { $nonProse = $true }
            }
            if ($nonProse) {
                $emitNonProse++
                continue
            }
            $emitProseTotal++
            if ($lineLocalized) { $emitProseLocalized++ } else { $emitList += ("{0}:{1}" -f $f.Name, $ln) }
            }
        }
    }
    [void]$classes.Add((New-ProcessAdoptionClass -Class 'i18nProseCoverage' -Adopted $emitProseLocalized -Total $emitProseTotal -Description 'User-facing log PROSE routes through a locale resolver (separators, ASCII art and relayed tool output are excluded from the denominator and counted as summary.EmitSitesNonProse; every emit verb is scanned at every position on the line, including Write-Host, Write-Warning and throw; production entry scripts at the tool root are in scope)' -Metric 'log emit sites whose message argument carries translatable English but no locale resolver' -Offenders $emitList))

    # --- summary -------------------------------------------------------------
    # MeanAdoption is a plain mean, which UNDERSTATES a tree where most classes
    # are already perfect: one broad coverage class (i18nProseCoverage, 37%)
    # drags the mean to 43% even though six of seven classes are at 1.0. The
    # at-parity count and below-parity ratio are reported alongside it so a
    # number cannot be read as "the process is failing" when the truth is "one
    # class has a long tail".
    $atParityCount = @($classes | Where-Object { $_.Adoption -ge 1.0 }).Count
    $belowParityCount = $classes.Count - $atParityCount
    $summary = [PSCustomObject]@{
        Schema          = 'gbuild.process-metrics.v1'
        MeasuredAtUtc   = (Get-Date).ToString('o')
        ToolRoot        = $ToolRoot
        FilesScanned    = $files.Count
        ProductionFiles = $prod.Count
        Classes         = @($classes)
        ClassCount      = $classes.Count
        ClassesAtParity = $atParityCount
        # Reported so the exclusion is auditable: if this number grows, new
        # decorative emit lines are being added instead of prose being migrated.
        EmitSitesNonProse = $emitNonProse
        BelowParityCount = $belowParityCount
        BelowParityRatio = [math]::Round(($belowParityCount / [math]::Max(1, $classes.Count)), 4)
        MeanAdoption    = [math]::Round(((@($classes | ForEach-Object { $_.Adoption }) | Measure-Object -Average).Average), 4)
        TotalRemaining  = (@($classes | ForEach-Object { $_.Remaining }) | Measure-Object -Sum).Sum
        AtParity        = ($atParityCount -eq $classes.Count)
    }
    return $summary
}

function Get-BuildProcessTrendPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ToolRoot)
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $ToolRoot 'Tests/TestResults/process-trend.jsonl')
}

function Write-BuildProcessTrend {
    <#
    .SYNOPSIS
        Appends ONE record to the append-only trend file. This is the curve.
    .DESCRIPTION
        Append, never overwrite: the value of the file is its history. A missing
        or unreadable file is created; a corrupt trailing line is tolerated
        (a killed run must not make the next run fail).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$Metrics,
        [string]$ToolRoot,
        [string]$RunId = '',
        [string]$Channel = 'local',
        [string]$ProjectType = ''
    )
    if (-not $Metrics) { $Metrics = Get-BuildProcessMetrics -ToolRoot $ToolRoot }
    if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $path = Get-BuildProcessTrendPath -ToolRoot $ToolRoot
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue) }
    # L5 OPP v2: every record carries its project type so the fleet summary can
    # split control limits per type. Explicit -ProjectType wins; otherwise the
    # language detector classifies the tool tree (guarded: unavailable on a
    # stripped import); 'unknown' keeps v1 records comparable.
    $typeRoot = $ToolRoot
    if ([string]::IsNullOrWhiteSpace($typeRoot)) { $typeRoot = Split-Path -Parent $PSScriptRoot }
    $ptype = [string]$ProjectType
    if ([string]::IsNullOrWhiteSpace($ptype) -and (Get-Command Get-PrimaryLanguage -ErrorAction SilentlyContinue)) {
        try {
            $detected = Get-PrimaryLanguage -SearchRoot $typeRoot -Depth 2
            if ($null -ne $detected -and $detected.PSObject.Properties.Name -contains 'Language' -and -not [string]::IsNullOrWhiteSpace([string]$detected.Language)) { $ptype = [string]$detected.Language }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($ptype)) { $ptype = 'unknown' }
    $record = [ordered]@{
        schema         = 'gbuild.process-trend.v2'
        runId          = $RunId
        recordedAtUtc  = (Get-Date).ToString('o')
        channel        = $Channel
        projectType    = $ptype
        host           = if ($env:GITHUB_ACTIONS) { 'github-actions' } elseif ($env:TF_BUILD) { 'azure-devops' } else { 'local' }
        psVersion      = [string]$PSVersionTable.PSVersion
        os             = if (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { [string](Get-OSPlatform) } else { 'unknown' }
        filesScanned   = $Metrics.FilesScanned
        classCount     = $Metrics.ClassCount
        classesAtParity = $Metrics.ClassesAtParity
        meanAdoption   = $Metrics.MeanAdoption
        totalRemaining = $Metrics.TotalRemaining
        atParity       = [bool]$Metrics.AtParity
        classes        = @($Metrics.Classes | ForEach-Object {
            [ordered]@{ class = $_.Class; adopted = $_.Adopted; total = $_.Total; adoption = $_.Adoption; remaining = $_.Remaining }
        })
    }
    $json = [PSCustomObject]$record | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonShallowDepth' -Fallback 6) } else { 6 }) -Compress
    try { $enc=[System.Text.UTF8Encoding]::new($false); $fs=[System.IO.File]::Open($path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read); try { $b=$enc.GetBytes($json + [Environment]::NewLine); $fs.Write($b,0,$b.Length); $fs.Flush($true) } finally { $fs.Dispose() } } catch { }
    # L5 OPP: best-effort fleet summary over recent history. Silent by design
    # (no log, no output change, never throws): it exists so Get-FleetSLOSummary
    # and the control-limit helpers have a production caller in this module.
    try {
        $recent = @(Get-BuildProcessTrend -ToolRoot $ToolRoot -Last 30)
        if ($recent.Count -ge 2) { [void](Get-FleetSLOSummary -Records $recent) }
    } catch { }
    return $path
}

function Get-BuildProcessTrend {
    <#
    .SYNOPSIS
        Reads the trend file back as a time series (oldest first).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$ToolRoot, [int]$Last = 0)
    $path = Get-BuildProcessTrendPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null } catch { }
    }
    $ordered = @($records)
    if ($Last -gt 0 -and $ordered.Count -gt $Last) { $ordered = @($ordered[($ordered.Count - $Last)..($ordered.Count - 1)]) }
    return $ordered
}

function Compare-BuildProcessTrend {
    <#
    .SYNOPSIS
        Diffs the newest record against the committed adoptionFloor.
    .DESCRIPTION
        This is the L5 gate and the only thing that distinguishes continuous
        improvement from a one-time cleanup.

        A binary hygiene gate says "not red". This says "worse than the floor",
        which is a strictly stronger and more actionable statement, and it
        survives the specific failure where a class was fixed, drifted back
        quietly, and no single gate noticed because each gate only looked at
        its own line.

        With NO history (fresh CI checkout) the comparison still works because
        the floor is version-controlled - that is the whole reason the floor
        lives in process-baseline.json instead of the ephemeral trend file.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$Metrics,
        [string]$ToolRoot
    )
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    if (-not $Metrics) { $Metrics = Get-BuildProcessMetrics -ToolRoot $ToolRoot }
    $baselinePath = Join-Path $ToolRoot 'Tests/process-baseline.json'
    $floor = $null
    $floorSource = 'none'
    if (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
        try {
            $b = [System.IO.File]::ReadAllText($baselinePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($b.PSObject.Properties.Name -contains 'adoptionFloor') { $floor = $b.adoptionFloor; $floorSource = 'Tests/process-baseline.json' }
        } catch { }
    }
    $regressions = [System.Collections.ArrayList]::new()
    $untracked = [System.Collections.ArrayList]::new()
    $improvements = [System.Collections.ArrayList]::new()
    foreach ($c in @($Metrics.Classes)) {
        $entry = $null
        if ($floor -and $floor.PSObject.Properties.Name -contains $c.Class) { $entry = $floor.PSObject.Properties[$c.Class].Value }
        if ($null -eq $entry) { [void]$untracked.Add($c.Class); continue }
        $min = [double]$entry.minAdoption
        if ($c.Adoption -lt ($min - 0.0001)) {
            [void]$regressions.Add([PSCustomObject]@{ Class = $c.Class; Current = $c.Adoption; Floor = $min; Metric = $c.Metric })
        } elseif ($c.Adoption -gt ($min + 0.0001)) {
            [void]$improvements.Add([PSCustomObject]@{ Class = $c.Class; Current = $c.Adoption; Floor = $min })
        }
    }
    return [PSCustomObject]@{
        Schema      = 'gbuild.process-trend-compare.v1'
        ComparedAtUtc = (Get-Date).ToString('o')
        FloorSource = $floorSource
        HasFloor    = ($null -ne $floor)
        Regressions = @($regressions)
        Improvements = @($improvements)
        Untracked   = @($untracked)
        Samples     = @(Get-BuildProcessTrend -ToolRoot $ToolRoot -Last 0).Count
        Passed      = ($regressions.Count -eq 0)
    }
}

function Get-BuildProcessSparkline {
    <#
    .SYNOPSIS
        Renders the adoption curve as text, for CI logs and for humans.
    .DESCRIPTION
        A number nobody looks at does not improve anything. This prints one line
        per class with a sparkline of its history, so the TREND is visible in
        the build log rather than requiring someone to open an artifact.

        -Ascii is auto-selected when the console cannot render the block glyphs.
        That is not cosmetic: a 2026-09 change to Encoding.psm1 set
        [Console]::OutputEncoding at module load, but a redirected CI log, a
        legacy code page, or a non-console host still renders U+2581..U+2588 as
        '?', which turns the curve into eight identical unreadable characters.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [PSCustomObject]$Metrics,
        [string]$ToolRoot,
        [int]$Width = 12,
        [switch]$Ascii
    )
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    if (-not $Metrics) { $Metrics = Get-BuildProcessMetrics -ToolRoot $ToolRoot }
    $history = @(Get-BuildProcessTrend -ToolRoot $ToolRoot)
    if (-not $Ascii) {
        $probe = [char]0x2588
        $Ascii = -not ([string]$probe).Equals([string][char]0x3F)
    }
    $blocks = if ($Ascii) { @('.', ':', '-', '=', '+', '*', '#', '@') } else { @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588) }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("  ADOPTION CURVE  ($($history.Count) recorded run(s); floor = Tests/process-baseline.json)")
    foreach ($c in @($Metrics.Classes)) {
        $series = [System.Collections.Generic.List[double]]::new()
        foreach ($h in $history) {
            $hc = @($h.classes | Where-Object { $_.class -eq $c.Class })
            if ($hc.Count -gt 0) { $series.Add([double]$hc[0].adoption) | Out-Null }
        }
        $series.Add($c.Adoption) | Out-Null
        $take = [math]::Max(1, [math]::Min($Width, $series.Count))
        $slice = @($series[($series.Count - $take)..($series.Count - 1)])
        $spark = ''
        foreach ($v in $slice) {
            $idx = [math]::Max(0, [math]::Min($blocks.Count - 1, [int][math]::Round($v * ($blocks.Count - 1))))
            $spark += [string]$blocks[$idx]
        }
        $pct = '{0,6:P1}' -f $c.Adoption
        $lines.Add(("  {0,-24} {1,-12} {2}  {3}" -f $c.Class, $spark, $pct, $c.Metric)) | Out-Null
    }
    return @($lines)
}

<#
.SYNOPSIS
    Computes statistical control limits (mean +/- Sigma*stddev) over a series.
.DESCRIPTION
    L5 OPP: fixed thresholds (z=3, minSamples) cannot distinguish a stable
    process from a drifting one. Control limits derived from the measured
    history can: Test-ProcessInControl flags out-of-control runs. Returns $null
    when fewer than 2 samples exist (fail-open: no verdict without data).
    Pure math, no I/O, PS 5.1-safe.
#>
function Get-ProcessControlLimits {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [double[]]$Values = @(),
        [double]$Sigma = 3
    )
    $vals = @($Values)
    if ($Sigma -le 0) { $Sigma = 3 }
    if ($vals.Count -lt 2) { return $null }
    $mean = ($vals | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($v in $vals) { $d = [double]$v - $mean; $variance += $d * $d }
    $variance = $variance / [double]$vals.Count
    $std = [math]::Sqrt($variance)
    return [PSCustomObject]@{
        Count  = $vals.Count
        Mean   = [math]::Round($mean, 4)
        StdDev = [math]::Round($std, 4)
        Sigma  = $Sigma
        UCL    = [math]::Round(($mean + $Sigma * $std), 4)
        LCL    = [math]::Round(($mean - $Sigma * $std), 4)
    }
}

<#
.SYNOPSIS
    True when a value lies within previously computed control limits.
.DESCRIPTION
    Fail-open: $null limits (insufficient history) or unreadable bounds mean
    "no verdict", reported as in-control so a thin history never fails a build.
#>
function Test-ProcessInControl {
    [CmdletBinding()]
    [OutputType([bool])]
    param([double]$Value, $Limits = $null)
    if ($null -eq $Limits) { return $true }
    $ucl = $null; $lcl = $null
    try { $ucl = [double]$Limits.UCL; $lcl = [double]$Limits.LCL } catch { return $true }
    if ($null -eq $ucl -or $null -eq $lcl) { return $true }
    if ($Value -gt $ucl -or $Value -lt $lcl) { return $false }
    return $true
}

<#
.SYNOPSIS
    Aggregates trend records across projects/runs into one fleet SLO summary.
.DESCRIPTION
    L5 OPM input: per-run records (Write-BuildProcessTrend schema) become a
    fleet view { Projects, MeanAdoption, AtParity, OutOfControl[], Limits }.
    Out-of-control indexes come from Get-ProcessControlLimits, so the OPP
    helpers have a production caller in this same module. Never throws: an
    unreadable record is skipped, an empty input yields a zero summary.
#>
function Get-FleetSLOSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([object[]]$Records = @(), [double]$Sigma = 3)
    $recs = @($Records)
    $means = [System.Collections.Generic.List[double]]::new()
    $parity = 0
    # Per-project-type split (L5 OPP): records carrying a projectType field are
    # aggregated per type; records without one fall into 'unknown', so today's
    # v1 trend schema (no projectType) stays valid while a future schema bump
    # can promote the split without changing this contract.
    $byType = @{}
    foreach ($r in $recs) {
        if ($null -eq $r) { continue }
        $m = $null
        try { if ($r.PSObject.Properties.Name -contains 'meanAdoption') { $m = [double]$r.meanAdoption } } catch { $m = $null }
        if ($null -eq $m) { continue }
        $means.Add($m) | Out-Null
        try { if (($r.PSObject.Properties.Name -contains 'atParity') -and [bool]$r.atParity) { $parity++ } } catch { }
        $t = 'unknown'
        try { if (($r.PSObject.Properties.Name -contains 'projectType') -and -not [string]::IsNullOrWhiteSpace([string]$r.projectType)) { $t = [string]$r.projectType } } catch { $t = 'unknown' }
        if (-not $byType.ContainsKey($t)) { $byType[$t] = [System.Collections.Generic.List[double]]::new() }
        $byType[$t].Add($m) | Out-Null
    }
    $limits = $null
    if ($means.Count -ge 2) {
        try { $limits = Get-ProcessControlLimits -Values $means.ToArray() -Sigma $Sigma } catch { $limits = $null }
    }
    $ooc = @()
    if ($null -ne $limits) {
        $i = 0
        foreach ($m in $means) {
            $ok = $true
            try { $ok = Test-ProcessInControl -Value $m -Limits $limits } catch { $ok = $true }
            if (-not $ok) { $ooc += $i }
            $i++
        }
    }
    $avg = 0.0
    if ($means.Count -gt 0) { $avg = [math]::Round((($means | Measure-Object -Average).Average), 4) }
    $perType = [ordered]@{}
    foreach ($k in @($byType.Keys | Sort-Object)) {
        $vals = @($byType[$k])
        $a = 0.0
        if ($vals.Count -gt 0) { $a = [math]::Round((($vals | Measure-Object -Average).Average), 4) }
        $perType[$k] = [PSCustomObject]@{ Projects = $vals.Count; MeanAdoption = $a }
    }
    return [PSCustomObject]@{ Projects = $means.Count; MeanAdoption = $avg; AtParity = $parity; OutOfControl = @($ooc); Limits = $limits; PerType = [PSCustomObject]$perType }
}

<#
.SYNOPSIS
    Publishes the fleet SLO summary as a machine-readable report artifact.
.DESCRIPTION
    Control-plane handoff: an external dashboard/scheduler consumes
    fleet-slo.json instead of parsing logs. Returns the written path, or ''
    when the report directory is undeterminable (State without roots) or the
    write fails. Never throws.
#>
function Publish-FleetSLOSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Records = @(), [PSCustomObject]$State = $null, [string]$FileName = 'fleet-slo.json')
    try {
        if ($null -eq $State) { return '' }
        $dir = ''
        if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) {
            try { $dir = [string](Get-ReportDirectory -State $State) } catch { $dir = '' }
        }
        if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
        $leaf = [string]$FileName
        try { $leaf = [System.IO.Path]::GetFileName([string]$FileName) } catch { return '' }
        if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -ne [string]$FileName -or $leaf -eq '.' -or $leaf -eq '..') { return '' }
        $summary = Get-FleetSLOSummary -Records $Records
        $payload = [ordered]@{ schema = 'gbuild.fleet-slo.v1'; exportedAtUtc = (Get-Date).ToString('o'); summary = $summary }
        $depth = 10
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $depth = [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } catch { $depth = 10 }
        }
        $json = ([PSCustomObject]$payload | ConvertTo-Json -Depth $depth)
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $dir) }
        elseif (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        $out = Join-Path $dir $leaf
        [System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $out
    } catch { return '' }
}

<#
.SYNOPSIS
    Rolls up published fleet-slo.json artifacts into one fleet rollup.
.DESCRIPTION
    Control-plane consumption loop, file-based: every project publishes
    fleet-slo.json (Publish-FleetSLOSummary); the plane merges them here into
    fleet-rollup.json { DirCount, TotalProjects, MeanAdoption (weighted),
    ParityDirs, PerType (weighted) }. Skips unreadable or wrong-schema files
    instead of failing. Returns the written path, or '' on any failure.
    -OutputPath is operator-explicit (like the CAR audit pack), so no
    containment applies beyond writing exactly the requested file.
#>
function Invoke-FleetRollup {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FleetDir, [Parameter(Mandatory)][string]$OutputPath)
    try {
        if (-not (Test-Path -LiteralPath $FleetDir -PathType Container)) { return '' }
        $files = @(Get-ChildItem -LiteralPath $FleetDir -Recurse -File -Filter 'fleet-slo.json' -ErrorAction Stop)
        $projects = 0
        $weighted = 0.0
        $parityDirs = 0
        $typeN = @{}
        $typeW = @{}
        foreach ($f in $files) {
            try {
                $doc = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ([string]$doc.schema -ne 'gbuild.fleet-slo.v1') { continue }
                $s = $doc.summary
                $n = [int]$s.Projects
                $m = [double]$s.MeanAdoption
                $projects += $n
                $weighted += $m * $n
                if (@($s.OutOfControl).Count -eq 0) { $parityDirs++ }
                foreach ($pp in @($s.PerType.PSObject.Properties)) {
                    $tn = [int]$pp.Value.Projects
                    $tm = [double]$pp.Value.MeanAdoption
                    if (-not $typeN.ContainsKey($pp.Name)) { $typeN[$pp.Name] = 0; $typeW[$pp.Name] = 0.0 }
                    $typeN[$pp.Name] += $tn
                    $typeW[$pp.Name] += $tm * $tn
                }
            } catch { }
        }
        $mean = 0.0
        if ($projects -gt 0) { $mean = [math]::Round(($weighted / [double]$projects), 4) }
        $perType = [ordered]@{}
        foreach ($k in @($typeN.Keys | Sort-Object)) {
            $a = 0.0
            if ([int]$typeN[$k] -gt 0) { $a = [math]::Round(([double]$typeW[$k] / [double]$typeN[$k]), 4) }
            $perType[$k] = [PSCustomObject]@{ Projects = [int]$typeN[$k]; MeanAdoption = $a }
        }
        $rollup = [ordered]@{
            schema        = 'gbuild.fleet-rollup.v1'
            rolledUpAtUtc = (Get-Date).ToString('o')
            dirCount      = $files.Count
            totalProjects = $projects
            meanAdoption  = $mean
            parityDirs    = $parityDirs
            perType       = [PSCustomObject]$perType
        }
        $outFull = [System.IO.Path]::GetFullPath($OutputPath)
        $outDir = Split-Path $outFull -Parent
        if (-not [string]::IsNullOrWhiteSpace($outDir)) {
            if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $outDir) }
            elseif (-not (Test-Path -LiteralPath $outDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop }
        }
        [System.IO.File]::WriteAllText($outFull, (([PSCustomObject]$rollup | ConvertTo-Json -Depth 6)), (New-Object System.Text.UTF8Encoding($false)))
        return $outFull
    } catch { return '' }
}

<#
.SYNOPSIS
    Prices tenant usage into billing lines (control-plane billing input).
.DESCRIPTION
    Pure math over Get-TenantUsageSummary tenant entries
    ({ Tenant, Total, Open, Closed, Critical }) and a rate table
    ({ PerRecord, PerCritical, PerOpen }, each defaulting when absent).
    Amounts round to 2 decimals. Never throws: unreadable entries are skipped.
#>
function Get-FleetBillingSummary {
    [CmdletBinding()]
    param([object[]]$Tenants = @(), [hashtable]$Rates = @{})
    $perRecord = 1.0
    $perCritical = 5.0
    $perOpen = 0.5
    try { if ($null -ne $Rates -and $Rates.ContainsKey('PerRecord')) { $perRecord = [double]$Rates['PerRecord'] } } catch { }
    try { if ($null -ne $Rates -and $Rates.ContainsKey('PerCritical')) { $perCritical = [double]$Rates['PerCritical'] } } catch { }
    try { if ($null -ne $Rates -and $Rates.ContainsKey('PerOpen')) { $perOpen = [double]$Rates['PerOpen'] } } catch { }
    $lines = [System.Collections.Generic.List[object]]::new()
    $grand = 0.0
    foreach ($t in @($Tenants)) {
        try {
            if ($null -eq $t) { continue }
            $name = [string]$t.Tenant
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $amount = ([int]$t.Total * $perRecord) + ([int]$t.Critical * $perCritical) + ([int]$t.Open * $perOpen)
            $amount = [math]::Round($amount, 2)
            $grand += $amount
            $lines.Add([PSCustomObject]@{ Tenant = $name; Records = [int]$t.Total; Critical = [int]$t.Critical; Open = [int]$t.Open; Amount = $amount }) | Out-Null
        } catch { }
    }
    return [PSCustomObject]@{ Currency = 'USD'; Lines = @($lines); Total = [math]::Round($grand, 2) }
}

<#
.SYNOPSIS
    Proposes floor raises sustained by history (ratchet input, never applies).
.DESCRIPTION
    Quarterly discipline, mechanized: for each class in -CurrentMetrics, when
    the current adoption AND the last -MinSustained history records carrying
    that class all sit above the committed floor, the class is eligible and
    the proposal is the sustained minimum rounded DOWN to 2 decimals. Returns
    @() when there is no floor, no history, or no sustained improvement. NEVER
    writes process-baseline.json: the operator reviews and applies, which is
    what keeps "raise only on evidence" honest instead of automatic.
#>
function Find-RatchetCandidates {
    [CmdletBinding()]
    param($Floor = $null, [PSCustomObject]$CurrentMetrics = $null, [object[]]$History = @(), [int]$MinSustained = 5)
    $out = [System.Collections.Generic.List[object]]::new()
    try {
        if ($null -eq $Floor -or $null -eq $CurrentMetrics) { return @() }
        if ($MinSustained -lt 1) { $MinSustained = 5 }
        $recs = @($History)
        foreach ($c in @($CurrentMetrics.Classes)) {
            try {
                $name = [string]$c.Class
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if (-not ($Floor.PSObject.Properties.Name -contains $name)) { continue }
                $floorVal = [double]$Floor.PSObject.Properties[$name].Value.minAdoption
                $cur = [double]$c.Adoption
                if ($cur -le ($floorVal + 0.0001)) { continue }
                $recent = @()
                foreach ($r in $recs) {
                    if ($null -eq $r -or $null -eq $r.classes) { continue }
                    foreach ($h in @($r.classes)) {
                        try { if ([string]$h.class -eq $name) { $recent += [double]$h.adoption } } catch { }
                    }
                }
                if ($recent.Count -lt $MinSustained) { continue }
                $tail = @($recent | Select-Object -Last $MinSustained)
                $sustainedMin = ($tail | Measure-Object -Minimum).Minimum
                $bad = $false
                foreach ($v in $tail) { if ([double]$v -le ($floorVal + 0.0001)) { $bad = $true; break } }
                if ($bad) { continue }
                $sustainedMin = [math]::Min($sustainedMin, $cur)
                $proposed = [math]::Floor($sustainedMin * 100.0) / 100.0
                if ($proposed -le ($floorVal + 0.0001)) { continue }
                $out.Add([PSCustomObject]@{ Class = $name; Floor = $floorVal; Proposed = $proposed; SustainedRuns = $tail.Count }) | Out-Null
            } catch { }
        }
    } catch { }
    return @($out)
}

<#
.SYNOPSIS
    SPC gate: compares the CURRENT metrics against control limits (UCL/LCL) computed from the recorded trend history.
.DESCRIPTION
    The adoptionFloor in Tests/process-baseline.json is a point threshold - it cannot
    tell a stable process from a drifting one. This function reads the last -Window
    recorded runs from process-trend.jsonl, computes per-class control limits with
    Get-ProcessControlLimits (population sigma, k = -Sigma), and fails when the
    current run falls below its LCL, i.e. the process shifted DOWNWARD.

    Two properties are deliberate:
      * ZERO-VARIANCE HISTORY needs a slack or every microscopic wobble fails. The
        slack is 1.5 quanta of ONE item not adopted (1/Total per class), so in a
        perfect process one slipped item reports in-control and two fail.
      * UCL breaches are REPORTED, never failed: this is an adoption metric, upper
        is better, and a gate that fails on improvement trains people to fear it.
      * Below -MinSamples there is no verdict (fail-open); a thin history never
        fails a build, it prints insufficient-history instead.
.PARAMETER Metrics
    Current-run metrics object from Get-BuildProcessMetrics.
.PARAMETER ToolRoot
    Tool root that holds Tests/TestResults/process-trend.jsonl.
.PARAMETER Window
    Number of trailing samples used to compute the limits.
.PARAMETER MinSamples
    Minimum history size before a verdict is given.
.PARAMETER Sigma
    Width of the control limits in population standard deviations.
.OUTPUTS
    [PSCustomObject] with HasLimits, Classes[], OutOfControl[], Warnings[], Passed.
#>
function Compare-BuildProcessControl {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$Metrics,
        [string]$ToolRoot,
        [int]$Window = 50,
        [int]$MinSamples = 12,
        [double]$Sigma = 3
    )
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    if (-not $Metrics) { $Metrics = Get-BuildProcessMetrics -ToolRoot $ToolRoot }
    if ($Sigma -le 0) { $Sigma = 3 }
    $history = @(Get-BuildProcessTrend -ToolRoot $ToolRoot -Last $Window)
    $samples = $history.Count
    $byClass = @{}
    foreach ($h in $history) {
        foreach ($c in @($h.classes)) {
            $name = [string]$c.class
            if (-not $byClass.ContainsKey($name)) { $byClass[$name] = New-Object System.Collections.Generic.List[double] }
            try { $byClass[$name].Add([double]$c.adoption) | Out-Null } catch { }
        }
    }
    $classes = [System.Collections.ArrayList]::new()
    $outOfControl = [System.Collections.ArrayList]::new()
    $warnings = [System.Collections.ArrayList]::new()
    $insufficient = [System.Collections.ArrayList]::new()
    foreach ($c in @($Metrics.Classes)) {
        $name = [string]$c.Class
        $total = [double]([int]([math]::Max(1, [int]$c.Total)))
        $quantum = 1.0 / $total
        $vals = if ($byClass.ContainsKey($name)) { @($byClass[$name]) } else { @() }
        $cl = Get-ProcessControlLimits -Values $vals -Sigma $Sigma
        if ($null -eq $cl) { [void]$insufficient.Add($name); continue }
        $cur = [double]$c.Adoption
        # Zero-variance slack: one slipped item is noise, two is signal.
        $lclEff = [double]$cl.LCL - (1.5 * $quantum)
        $failLow = $cur -lt $lclEff
        $warnLow = (-not $failLow) -and ($cl.StdDev -gt 0) -and ($cur -lt ([double]$cl.Mean - (2.0 * [double]$cl.StdDev)))
        $uclBreach = $cur -gt [double]$cl.UCL
        if ($failLow) {
            [void]$outOfControl.Add([PSCustomObject]@{ Class = $name; Current = [math]::Round($cur, 4); LCL = $cl.LCL; Mean = $cl.Mean; StdDev = $cl.StdDev; Quantum = [math]::Round($quantum, 4) })
        } elseif ($warnLow) {
            [void]$warnings.Add([PSCustomObject]@{ Class = $name; Current = [math]::Round($cur, 4); Mean = $cl.Mean; Note = 'below mean-2sigma (report only)' })
        }
        $classes.Add([PSCustomObject]@{
            Class      = $name
            Current    = [math]::Round($cur, 4)
            Mean       = $cl.Mean
            StdDev     = $cl.StdDev
            UCL        = $cl.UCL
            LCL        = $cl.LCL
            LCLEffective = [math]::Round($lclEff, 4)
            InControl  = (-not $failLow)
            Notes      = if ($uclBreach) { 'above UCL (improvement)' } else { '' }
        }) | Out-Null
    }
    $hasLimits = ($classes.Count -gt 0) -and ($samples -ge $MinSamples)
    $passed = if (-not $hasLimits) { $true } else { $outOfControl.Count -eq 0 }
    return [PSCustomObject]@{
        Schema         = 'gbuild.process-control.v1'
        MeasuredAtUtc  = (Get-Date).ToString('o')
        Window         = $Window
        MinSamples     = $MinSamples
        Sigma          = $Sigma
        Samples        = $samples
        HasLimits      = $hasLimits
        Classes        = @($classes)
        OutOfControl   = @($outOfControl)
        Warnings       = @($warnings)
        Insufficient   = @($insufficient)
        Passed         = $passed
    }
}

<#
.SYNOPSIS
    Validates the QPM escaped-defect ledger (Tests/qpm-ledger.json).
.DESCRIPTION
    The ledger is the ONLY source for escaped-defect measures; without it every
    QPM figure would be invented. Validation is manual (no Test-Json dependency,
    PS 5.1-safe): parse, entry shape, id uniqueness and format, enum domains,
    timestamps parse and are ordered. Returns Passed=$false with human-readable
    Errors when anything is wrong - the self-test gate fails on that alone.
.OUTPUTS
    [PSCustomObject] with Passed, Entries, Errors, MeanRepairTimeSeconds.
#>
function Test-BuildQpmLedger {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ToolRoot,
        [string]$Path
    )
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    if (-not $Path) { $Path = Join-Path $ToolRoot 'Tests/qpm-ledger.json' }
    $errors = [System.Collections.ArrayList]::new()
    $entries = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [void]$errors.Add("ledger not found: $Path")
        return [PSCustomObject]@{ Schema = 'gbuild.qpm-ledger.v1'; Path = $Path; Passed = $false; Entries = @(); Errors = @($errors); MeanRepairTimeSeconds = $null }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        [void]$errors.Add("ledger is not valid JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Schema = 'gbuild.qpm-ledger.v1'; Path = $Path; Passed = $false; Entries = @(); Errors = @($errors); MeanRepairTimeSeconds = $null }
    }
    if ($null -eq $doc -or -not ($doc.PSObject.Properties.Name -contains 'entries')) {
        [void]$errors.Add('ledger has no entries[] array')
        return [PSCustomObject]@{ Schema = 'gbuild.qpm-ledger.v1'; Path = $Path; Passed = $false; Entries = @(); Errors = @($errors); MeanRepairTimeSeconds = $null }
    }
    $entries = @($doc.entries)
    $seen = @{}
    $idPattern = '^QPM-[0-9]{4}-[0-9]{3}$'
    $classes = @('escaped-defect', 'process-failure', 'near-miss')
    $severities = @('low', 'medium', 'high', 'critical')
    $repairSeconds = [System.Collections.Generic.List[double]]::new()
    $idx = 0
    foreach ($e in $entries) {
        $idx++
        $where = "entries[$idx]"
        foreach ($field in @('id', 'detectedAtUtc', 'class', 'severity', 'scope', 'summary')) {
            if (-not ($e.PSObject.Properties.Name -contains $field) -or $null -eq $e.$field -or [string]::IsNullOrWhiteSpace([string]$e.$field)) {
                [void]$errors.Add("$where missing required field '$field'")
            }
        }
        $id = [string]$e.id
        if ($id -and ($id -notmatch $idPattern)) { [void]$errors.Add("$where id '$id' does not match $idPattern") }
        if ($id) { if ($seen.ContainsKey($id)) { [void]$errors.Add("$where duplicate id '$id'") } else { $seen[$id] = $true } }
        $cls = [string]$e.class
        if ($cls -and ($classes -notcontains $cls)) { [void]$errors.Add("$where class '$cls' not in {$($classes -join ', ')}") }
        $sev = [string]$e.severity
        if ($sev -and ($severities -notcontains $sev)) { [void]$errors.Add("$where severity '$sev' not in {$($severities -join ', ')}") }
        $detected = $null; $resolved = $null
        try { $detected = [datetimeoffset]::Parse([string]$e.detectedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [void]$errors.Add("$where detectedAtUtc '$($e.detectedAtUtc)' does not parse") }
        if ($e.PSObject.Properties.Name -contains 'resolvedAtUtc' -and -not [string]::IsNullOrWhiteSpace([string]$e.resolvedAtUtc)) {
            try { $resolved = [datetimeoffset]::Parse([string]$e.resolvedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [void]$errors.Add("$where resolvedAtUtc '$($e.resolvedAtUtc)' does not parse") }
        }
        if ($detected -and $resolved) {
            if ($resolved -lt $detected) { [void]$errors.Add("$where resolvedAtUtc is before detectedAtUtc") }
            else { $null = $repairSeconds.Add(($resolved - $detected).TotalSeconds) }
        }
    }
    $meanRepair = if ($repairSeconds.Count -gt 0) { [math]::Round(($repairSeconds | Measure-Object -Average).Average, 1) } else { $null }
    return [PSCustomObject]@{
        Schema                = 'gbuild.qpm-ledger.v1'
        Path                  = $Path
        Passed                = ($errors.Count -eq 0)
        Entries               = @($entries)
        Errors                = @($errors)
        MeanRepairTimeSeconds = $meanRepair
    }
}

<#
.SYNOPSIS
    QPM measures: change failure rate and meantime-to-recovery, from the trend file and the escaped-defect ledger.
.DESCRIPTION
    Two data sources, both local and honest - nothing is fabricated when data is absent, it reports DataQuality instead:
      1. Tests/TestResults/process-trend.jsonl (schema gbuild.process-trend.v2) gives the
         CHANGE FAILURE RATE of the verification process over the last -WindowSamples runs
         (fraction with atParity=false) and the MEAN TIME TO RECOVERY, measured from each
         failing streak to the first passing sample after it.
      2. Tests/qpm-ledger.json (validated by Test-BuildQpmLedger) gives the ESCAPED DEFECT
         count and the mean repair time across ledger entries that carry both timestamps.
    All-time figures are always included for context; the gate reads only the window rate
    and the ledger validity (see gbuild.ps1 -SelfTest and Tests/process-baseline.json .qpm).
.OUTPUTS
    [PSCustomObject] gbuild.qpm.v1
#>
function Get-BuildQpmMeasures {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ToolRoot,
        [int]$WindowSamples = 50,
        [int]$MinSamples = 12
    )
    if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    if ($WindowSamples -lt 1) { $WindowSamples = 50 }
    $history = @(Get-BuildProcessTrend -ToolRoot $ToolRoot -Last $WindowSamples)
    $samples = $history.Count
    $failures = 0
    foreach ($r in $history) { if (-not [bool]$r.atParity) { $failures++ } }
    $rate = if ($samples -gt 0) { [math]::Round($failures / [double]$samples, 4) } else { $null }
    $all = @(Get-BuildProcessTrend -ToolRoot $ToolRoot -Last 0)
    $allFailures = 0
    foreach ($r in $all) { if (-not [bool]$r.atParity) { $allFailures++ } }
    $allRate = if ($all.Count -gt 0) { [math]::Round($allFailures / [double]$all.Count, 4) } else { $null }
    $streakStart = $null
    $recoveries = [System.Collections.Generic.List[double]]::new()
    foreach ($r in $history) {
        if (-not [bool]$r.atParity) {
            if ($null -eq $streakStart) { try { $streakStart = [datetimeoffset]::Parse([string]$r.recordedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture) } catch { } }
        } else {
            if ($null -ne $streakStart) {
                try { [void]$recoveries.Add(([datetimeoffset]::Parse([string]$r.recordedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture) - $streakStart).TotalSeconds) } catch { }
                $streakStart = $null
            }
        }
    }
    $meanRecovery = if ($recoveries.Count -gt 0) { [math]::Round(($recoveries | Measure-Object -Average).Average, 1) } else { $null }
    $ledger = Test-BuildQpmLedger -ToolRoot $ToolRoot
    $escaped = @($ledger.Entries | Where-Object { $_.class -eq 'escaped-defect' })
    $quality = if ($samples -ge $MinSamples) { 'measured' } else { 'insufficient-history' }
    return [PSCustomObject]@{
        Schema                  = 'gbuild.qpm.v1'
        MeasuredAtUtc           = (Get-Date).ToString('o')
        WindowSamples           = $WindowSamples
        Samples                 = $samples
        Failures                = $failures
        ChangeFailureRate       = $rate
        AllTimeSamples          = $all.Count
        AllTimeFailures         = $allFailures
        AllTimeChangeFailureRate = $allRate
        RecoveryIncidents       = $recoveries.Count
        MeanRecoveryTimeSeconds = $meanRecovery
        EscapedDefects          = $escaped.Count
        MeanRepairTimeSeconds   = $ledger.MeanRepairTimeSeconds
        LedgerValid             = $ledger.Passed
        LedgerErrors            = @($ledger.Errors)
        DataQuality             = $quality
    }
}

Export-ModuleMember -Function @(
    'Get-BuildProcessMetrics',
    'Get-BuildProcessTrendPath',
    'Write-BuildProcessTrend',
    'Get-BuildProcessTrend',
    'Compare-BuildProcessTrend',
    'Get-BuildProcessSparkline',
    'Get-ProcessControlLimits',
    'Test-ProcessInControl',
    'Compare-BuildProcessControl',
    'Test-BuildQpmLedger',
    'Get-BuildQpmMeasures',
    'Get-FleetSLOSummary',
    'Publish-FleetSLOSummary',
    'Invoke-FleetRollup',
    'Get-FleetBillingSummary',
    'Find-RatchetCandidates'
)

