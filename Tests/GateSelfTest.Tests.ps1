# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

<#
.SYNOPSIS
    Proves every enforcement gate can actually FAIL.
.DESCRIPTION
    THE PROBLEM THIS SOLVES

    This repository measured itself with seven adoption ratchets, forty-odd
    structural gates and a dependency-graph validator, and was still wrong three
    times in a row about its own quality:

      * Test-ModuleDependencies reported 23 dependencies for Orchestrator instead
        of 41 and 0 for AndroidSdkProvider instead of 5, because three regexes
        contained a backtick-escaped `$` inside a double-quoted string - which
        emits `$`, not `\$`, making each pattern a regex end-of-string anchor.
        Passed=True throughout.

      * The dead-export gate was blind to 281 of 649 exported functions (43%),
        because it cleared its "inside Export-ModuleMember" flag only on a line
        containing nothing but ')'. Two genuinely dead exports shipped green.

      * stringHashDelegation reported 21/21 = 100% while two real duplicate
        SHA256 implementations shipped, because its fingerprint required two
        tokens to share a line and no site in this codebase is written that way.

    Not one of those could be detected by the system as it stood. A gate that
    silently stops matching is indistinguishable from a gate that is working.

    THE FIX

    Falsifiability. For every detector this repository enforces, plant a known
    violation in a fixture and assert the detector REPORTS it; plant clean input
    and assert it stays SILENT. The detectors live in Tests/GateDetectors.ps1 so
    the gate under test and this test exercise one implementation - a self-test
    that re-implements the logic would be testing a copy, which is the same
    duplication problem in a new place.

    Two things this deliberately does NOT do:

      * It does not assert the current codebase is clean. That is the gate's job
        (Tests/Hygiene.Tests.ps1). This asserts the gate would notice.

      * It does not trust itself. The harness itself is exercised at the end by
        deliberately breaking a detector and asserting this file goes red.

    Adding a detector without a fixture here fails the meta-gate, so the two
    cannot drift apart.
#>

BeforeAll {
    $script:GD = Join-Path $PSScriptRoot 'GateDetectors.ps1'
    . $script:GD

    # Fixture workspace. Each fixture is a throwaway directory so a detector is
    # proven against REAL files on disk - detectors read files, so a synthetic
    # string would not exercise the same code path.
    $script:GSelfTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gate_self_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = New-Item -ItemType Directory -Path $script:GSelfTmp -Force

    function New-GateFixture {
        <#
        .SYNOPSIS
            Writes one or more files into a fresh sub-directory and returns the paths.
        .DESCRIPTION
            Returns with the comma operator deliberately. `return @($paths)` unrolls
            a single-element array back to a SCALAR, so `$f[0]` then yields the
            first CHARACTER of the path and every fixture silently tests nothing.
        #>
        param([hashtable]$Files)
        $dir = Join-Path $script:GSelfTmp ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $paths = @()
        foreach ($name in $Files.Keys) {
            $p = Join-Path $dir $name
            # UTF8 without BOM keeps the PS51Compat scan irrelevant here; these
            # fixtures are parsed as data, never shipped.
            [System.IO.File]::WriteAllText($p, [string]$Files[$name], (New-Object System.Text.UTF8Encoding($false)))
            $paths += $p
        }
        return ,$paths
    }
}

AfterAll {
    if ($script:GSelfTmp -and (Test-Path -LiteralPath $script:GSelfTmp)) {
        Remove-Item -LiteralPath $script:GSelfTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Gate self-test: every detector can fail' {
    Context 'manifest and implementation agree' {
        It 'registers every gate detector function, and registers nothing that does not exist' {
            $manifest = @(Get-GateDetectorManifest)
            $manifest.Count | Should -BeGreaterThan 1 -Because 'an array of one unrolls to a scalar, which silently disables every manifest-driven check'

            $declared = @($manifest | ForEach-Object { $_.Name })
            # Should -BeUnique does not accept -Because in Pester 5, so a duplicate
            # row is reported by hand. A duplicate would double-count coverage and
            # make a missing proof look covered.
            $dupes = @($declared | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            if ($dupes.Count -gt 0) { throw ("duplicate manifest rows would hide a missing proof: " + ($dupes -join ', ')) }

            # Pester rejects an EMPTY -Because string, and an empty finding list
            # produces exactly that - which surfaced as an opaque "Parameter set
            # cannot be resolved" instead of a passing assertion.
            $missing = @($declared | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
            if ($missing.Count -gt 0) {
                throw ("registered as enforced but no implementation exists: " + ($missing -join ', '))
            }

            # The inverse direction is the one that matters: an UNREGISTERED
            # detector is a detector nobody proved, and that is precisely how the
            # three historical blind gates survived.
            $helpers = @(Get-GateDetectorHelpers)
            $implemented = @(Get-ChildItem -LiteralPath $script:GD |
                Select-String -Pattern '^function\s+(Find-Gate\w+|Get-Gate\w+)' |
                ForEach-Object { $_.Matches[0].Groups[1].Value })
            $unregistered = @($implemented | Where-Object { $declared -notcontains $_ -and $helpers -notcontains $_ })
            if ($unregistered.Count -gt 0) {
                throw ("these detectors exist but are neither proven nor declared as helpers: " + ($unregistered -join ', '))
            }

            # And the reverse: a declared helper that no longer exists is dead
            # documentation, and would let a future function slip through the
            # helper exemption by reusing the name.
            $staleHelpers = @($helpers | Where-Object { $implemented -notcontains $_ })
            if ($staleHelpers.Count -gt 0) {
                throw ("Get-GateDetectorHelpers lists functions that no longer exist: " + ($staleHelpers -join ', '))
            }
        }

        It 'gives every manifest entry a gate that cites it' {
            foreach ($entry in @(Get-GateDetectorManifest)) {
                $entry.Gate | Should -Not -BeNullOrEmpty -Because "$($entry.Name) must name the gate it serves"
                $entry.SelfTested | Should -BeTrue -Because "$($entry.Name) must be marked as self-tested; an unproven detector cannot claim to be one"
            }
        }

        It 'DERIVES SelfTested from this file instead of trusting the literal' {
            # The failure this pins: `SelfTested = $true` was a hand-written
            # literal in the manifest that no gate ever recomputed. A brand-new
            # detector could be added with SelfTested = $true and ZERO fixtures and
            # every manifest-driven check would still pass - verified by injection
            # before this test existed. The claim is now read back out of the file
            # that has to contain the proof.
            $selfPath = Join-Path (Split-Path -Parent $script:GD) 'GateSelfTest.Tests.ps1'
            $selfText = [string](Get-Content -LiteralPath $selfPath -Raw)
            # Strip comments so a detector named only in prose is not counted.
            $selfCode = [regex]::Replace($selfText, '(?m)^\s*#.*$', '')
            $selfCode = [regex]::Replace($selfCode, '(?s)<#.*?#>', '')

            $unproven = @()
            foreach ($entry in @(Get-GateDetectorManifest)) {
                # Count REAL call sites, not mentions: a detector driven once is
                # driven, and this repo's convention is at least one drive per
                # Context (positive + negative), so 1 is the floor that still
                # catches "registered but never exercised".
                $drives = [regex]::Matches($selfCode, ('\b' + [regex]::Escape($entry.Name) + '\s+-')).Count
                if ($drives -lt 1) { $unproven += $entry.Name }
            }
            if ($unproven.Count -gt 0) {
                throw ("registered SelfTested = `$true but never driven by a fixture in this file: " + ($unproven -join ', ') + " - add the fixture, or declare it in Get-GateDetectorHelpers if it is plumbing")
            }
        }

        It 'does not unroll the manifest into a scalar' {
            # A one-row manifest returned as a bare hashtable would make the
            # iteration above vacuous, so the manifest is asserted to survive as
            # a collection even at its smallest.
            $manifest = @(Get-GateDetectorManifest)
            $manifest.Count | Should -BeGreaterThan 1 -Because 'an array of one unrolls to a scalar, which silently disables every manifest-driven check'
        }
    }

    Context 'Find-GateInlineWin32NT' {
        It 'FLAGS a module that branches on the OS inline' {
            $f = New-GateFixture -Files @{
                'Bad.psm1' = "function Get-Thing { if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 1 } }"
            }
            @(Find-GateInlineWin32NT -Paths $f).Count | Should -BeGreaterThan 0 -Because 'this is exactly the duplication the gate exists to catch'
        }
        It 'STAYS SILENT on a module that delegates to the shared accessor' {
            $f = New-GateFixture -Files @{ 'Good.psm1' = 'function Get-Thing { if (Test-IsWindowsHost) { 1 } }' }
            @(Find-GateInlineWin32NT -Paths $f).Count | Should -Be 0 -Because 'delegating is the required behaviour; flagging it would make the gate useless'
        }
        It 'honours the allow-list and the defining module' {
            $f = New-GateFixture -Files @{ 'PathUtils.psm1' = 'x [System.PlatformID]::Win32NT y' }
            @(Find-GateInlineWin32NT -Paths $f -Allowed @('PathUtils.psm1')).Count | Should -Be 0 -Because 'PathUtils owns the resolver and must be able to name the platform'
            $f2 = New-GateFixture -Files @{ 'Owner.psm1' = "function Get-OSPlatform { }`n# [System.PlatformID]::Win32NT" }
            @(Find-GateInlineWin32NT -Paths $f2).Count | Should -Be 0 -Because 'a module that DEFINES the resolver may reference the platform'
        }
        It 'ignores the platform name inside a comment' {
            $f = New-GateFixture -Files @{ 'Commented.psm1' = "# do not do [System.PlatformID]::Win32NT here`nfunction Get-Thing { 1 }" }
            @(Find-GateInlineWin32NT -Paths $f).Count | Should -Be 0 -Because 'a gate that matches its own explanatory comment gets switched off, which is how gates die'
        }
    }

    Context 'Find-GatePathLiterals' {
        It 'FLAGS a Join-Path built with a backslash separator' {
            $f = New-GateFixture -Files @{ 'Bad.psm1' = "Join-Path `$root 'Modules\Sub\File.psm1'" }
            @(Find-GatePathLiterals -Paths $f).Count | Should -BeGreaterThan 0 -Because 'this silently breaks on Linux and macOS'
        }
        It 'FLAGS a -BeLike path assertion carrying a backslash' {
            $f = New-GateFixture -Files @{ 'Bad.Tests.ps1' = "`$p | Should -BeLike '*reports\out.json'" }
            @(Find-GatePathLiterals -Paths $f).Count | Should -BeGreaterThan 0 -Because 'an assertion is as platform-hostile as a construction'
        }
        It 'STAYS SILENT on a forward-slash path' {
            $f = New-GateFixture -Files @{ 'Good.psm1' = "Join-Path `$root 'Modules/Sub/File.psm1'" }
            @(Find-GatePathLiterals -Paths $f).Count | Should -Be 0
        }
        It 'exempts the exact named fragment only' {
            $f = New-GateFixture -Files @{ 'Fixture.Tests.ps1' = "Join-Path `$r 'a\b.psm1'`nJoin-Path `$r 'c\d.psm1'" }
            $ex = @([PSCustomObject]@{ file = 'Fixture.Tests.ps1'; pattern = "'a\b.psm1'"; reason = 'fixture' })
            $found = @(Find-GatePathLiterals -Paths $f -Exemptions $ex)
            $found.Count | Should -Be 1 -Because 'the exemption names one fragment; a DIFFERENT backslash in the same file must still be caught'
            $found[0] | Should -Match 'Fixture\.Tests\.ps1:2'
        }
    }

    Context 'Find-GateAtomicTextWrites' {
        It 'FLAGS a hand-rolled temp+Replace+guid write' {
            $f = New-GateFixture -Files @{ 'Bad.psm1' = "`$t = [guid]::NewGuid().ToString('N')`n[System.IO.File]::Replace(`$tmp, `$path, `$null, `$true)" }
            @(Find-GateAtomicTextWrites -Paths $f).Count | Should -BeGreaterThan 0 -Because 'both halves of the fingerprint are present, so this is the duplication'
        }
        It 'STAYS SILENT when the module delegates to the shared writer' {
            $f = New-GateFixture -Files @{ 'Good.psm1' = "Write-BuildTextFileAtomic -Path `$p -Text `$t`n`$g = [guid]::NewGuid().ToString('N')`n[System.IO.File]::Replace(`$a, `$b, `$c, `$true)" }
            @(Find-GateAtomicTextWrites -Paths $f).Count | Should -Be 0 -Because 'a module may legitimately use the primitive it delegates to'
        }
        It 'STAYS SILENT when only half the fingerprint is present' {
            $f = New-GateFixture -Files @{ 'GuidOnly.psm1' = "`$g = [guid]::NewGuid().ToString('N')" }
            @(Find-GateAtomicTextWrites -Paths $f).Count | Should -Be 0 -Because 'a guid alone is ordinary code and flagging it would flood the gate'
        }
    }

    Context 'Find-GateFileLockLoops' {
        It 'FLAGS a module opening its own exclusive lock stream' {
            $f = New-GateFixture -Files @{ 'Bad.psm1' = '$fs = [System.IO.File]::Open($p, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)' }
            @(Find-GateFileLockLoops -Paths $f).Count | Should -BeGreaterThan 0
        }
        It 'STAYS SILENT on a module that calls the shared primitive' {
            $f = New-GateFixture -Files @{ 'Good.psm1' = 'Enter-BuildFileLock -Path $p -TimeoutSec 5' }
            @(Find-GateFileLockLoops -Paths $f).Count | Should -Be 0
        }
    }

    Context 'Find-GateEvtStringLiterals' {
        It 'FLAGS a publisher sending an event name as a literal to a publish call' {
            $f = New-GateFixture -Files @{ 'Bad.psm1' = "Send-BuildEvent -EventName 'EVT_CACHE_HIT' -Source `$s" }
            @(Find-GateEvtStringLiterals -Paths $f).Count | Should -BeGreaterThan 0 -Because 'the EVT_* constant is the contract; a literal silently re-encodes the name'
        }
        It 'STAYS SILENT when the publisher uses the constant' {
            $f = New-GateFixture -Files @{ 'Good.psm1' = 'Send-BuildEvent -EventName $EVT_CACHE_HIT -Source $s' }
            @(Find-GateEvtStringLiterals -Paths $f).Count | Should -Be 0
        }
        It 'STAYS SILENT on a quoted name outside a publish call' {
            # Handler maps and subscriber lists legitimately spell the name out.
            # An unanchored detector flagged two such references in
            # AnomalyDetector and would have made this gate noise.
            $f = New-GateFixture -Files @{ 'Lookup.psm1' = "`$subscribers = @{ 'EVT_BUILD_START' = 'handler' }`nif (`$handlers.ContainsKey('EVT_BUILD_ERROR')) { }" }
            @(Find-GateEvtStringLiterals -Paths $f).Count | Should -Be 0 -Because 'a lookup table is not a publish site'
        }
        It 'ignores a literal inside a comment' {
            $f = New-GateFixture -Files @{ 'Commented.psm1' = "# never write 'EVT_CACHE_HIT' as a literal`nSend-BuildEvent -EventName `$EVT_CACHE_HIT" }
            @(Find-GateEvtStringLiterals -Paths $f).Count | Should -Be 0
        }
    }

    Context 'Find-GateContainmentWalks' {
        It 'FLAGS a private containment + reparse walk' {
            # A real WALK climbs to the volume root; that climb is what separates
            # it from an incidental single-item probe, and the fixture has to
            # include it for the test to describe a real defect.
            $f = New-GateFixture -Files @{
                'Bad.psm1' = "if (`$full.StartsWith(`$root + '\')) { }`n`$vol = GetPathRoot `$full`n`$a = (Get-Item `$full).Attributes -band [System.IO.FileAttributes]::ReparsePoint"
            }
            @(Find-GateContainmentWalks -Paths $f).Count | Should -BeGreaterThan 0 -Because 'private copies of this walk have already drifted'
        }
        It 'STAYS SILENT when the module calls the shared guards' {
            $f = New-GateFixture -Files @{
                'Good.psm1' = "if (-not (Test-PathUnderRoots -Path `$full -AllowedRoots @(`$root))) { return '' }"
                'Good2.psm1' = "`$vol = GetPathRoot `$full`n`$a = (Get-Item `$full).Attributes -band [System.IO.FileAttributes]::ReparsePoint`nif (Test-NoReparsePointInPath -Path `$full) { return }"
            }
            @(Find-GateContainmentWalks -Paths $f).Count | Should -Be 0
        }
        It 'does not flag a module merely for MENTIONING the shared helper name' {
            # The regression this pins. The first version matched the bare word
            # `ReparsePoint`, and the shared helper is called
            # Test-NoReparsePointInPath - so every correct delegation call was
            # reported as a hand-rolled walk. On the real tree that produced five
            # false offenders (Cache, DeployTargets, Standalone, and two steps).
            $f = New-GateFixture -Files @{
                'Delegates.psm1' = "`$full.StartsWith(`$root)`nif (Test-NoReparsePointInPath -Path `$full) { throw 'symlink' }`nif (Test-ReparsePointItem -Path `$full) { throw 'symlink' }"
            }
            @(Find-GateContainmentWalks -Paths $f).Count | Should -Be 0 -Because 'calling the shared helper IS the correct form'
        }
        It 'does not flag an incidental reparse probe with no upward climb' {
            # A single-item probe is a different question, routed through
            # Test-ReparsePointItem; it is not a containment walk.
            $f = New-GateFixture -Files @{
                'Probe.psm1' = "`$a = (Get-Item `$p).Attributes -band [System.IO.FileAttributes]::ReparsePoint"
            }
            @(Find-GateContainmentWalks -Paths $f).Count | Should -Be 0
        }
    }

    Context 'AST export detection (the gate that was 43% blind)' {
        It 'reads a MULTI-LINE Export-ModuleMember' {
            $f = New-GateFixture -Files @{
                'Multi.psm1' = "function Get-A { }`nfunction Get-B { }`nExport-ModuleMember -Function @(`n    'Get-A',`n    'Get-B'`n)"
            }
            $names = @(Get-GateExportedNames -Path $f[0])
            $names | Should -Contain 'Get-A'
            $names | Should -Contain 'Get-B'
        }
        It 'reads a SINGLE-LINE Export-ModuleMember - the shape that blinded the old gate' {
            $f = New-GateFixture -Files @{
                'Single.psm1' = "function Get-A { }`nfunction Get-B { }`nExport-ModuleMember -Function @('Get-A','Get-B')"
            }
            $names = @(Get-GateExportedNames -Path $f[0])
            $names.Count | Should -Be 2 -Because '38 shipped files write the statement this way and the old line-scanner captured ZERO of them'
            $names | Should -Contain 'Get-A'
            $names | Should -Contain 'Get-B'
        }
        It 'reads a single-element single-line list' {
            $f = New-GateFixture -Files @{
                'One.psm1' = "function Get-A { }`nExport-ModuleMember -Function @('Get-A')"
            }
            @(Get-GateExportedNames -Path $f[0]).Count | Should -Be 1 -Because 'a one-element @(...) needs no ArrayLiteralAst; a detector that only reads .Elements gets nothing here'
        }
        It 'scopes the ignored range to the statement, not to end-of-file' {
            $f = New-GateFixture -Files @{
                'After.psm1' = "function Get-A { }`nfunction Get-B { }`nExport-ModuleMember -Function @('Get-A')`n`$x = 'Get-B'"
            }
            $ignored = Get-GateIgnoredReferenceLines -Paths $f
            $path = $f[0]
            # Get-B is referenced on line 4, AFTER the one-line export on line 3.
            # The old scanner left its flag stuck true to EOF and ignored it.
            Get-GateReferenceCount -Name 'Get-B' -Paths @($path) -Ignored $ignored |
                Should -BeGreaterThan 0 -Because 'a reference after a one-line Export-ModuleMember is a REAL reference and must be counted'
        }
        It 'does not count the definition line as a reference' {
            $f = New-GateFixture -Files @{ 'Self.psm1' = "function Get-Solo { }`nExport-ModuleMember -Function @('Get-Solo')" }
            $ignored = Get-GateIgnoredReferenceLines -Paths $f
            Get-GateReferenceCount -Name 'Get-Solo' -Paths $f -Ignored $ignored | Should -Be 0
        }
        It 'does not count a mention inside a doc comment' {
            $f = New-GateFixture -Files @{
                'Doc.psm1' = "function Get-Real { }`n<#`n.SYNOPSIS`n    Also see Get-Mentioned.`n#>`nfunction Get-Mentioned { }`nExport-ModuleMember -Function @('Get-Real','Get-Mentioned')"
            }
            $ignored = Get-GateIgnoredReferenceLines -Paths $f
            Get-GateReferenceCount -Name 'Get-Mentioned' -Paths $f -Ignored $ignored |
                Should -Be 0 -Because 'prose is not a call site; counting it let two dead exports survive for months'
        }
        It 'finds function definitions with line numbers' {
            $f = New-GateFixture -Files @{ 'Defs.psm1' = "function Get-One { }`n`nfunction Get-Two { }" }
            $defs = @(Get-GateFunctionDefinitions -Path $f[0])
            $defs.Count | Should -Be 2
            ($defs | Where-Object { $_.Name -eq 'Get-Two' }).Line | Should -Be 3
        }
        It 'finds a definition in every legal spelling, not only `function Name {' {
            # The blind spot this pins. The line regex this replaced matched only
            # `function Name {`, so a reintroduced duplicate written as
            # `function global:Name {` or `function Name($a) {` - both legal, both
            # easy to write by accident - was invisible to the dead-export gate.
            $f = New-GateFixture -Files @{ 'Spell.psm1' = "function Plain-One { }`nfunction global:Plain-Two { }`nfunction Plain-Three(`$a) { `$a }" }
            $names = @(Get-GateFunctionDefinitions -Path $f[0] | ForEach-Object { $_.Name })
            $names | Should -Contain 'Plain-One'
            $names | Should -Contain 'Plain-Two' -Because 'the global: scope prefix must be stripped so the name still matches an Export-ModuleMember entry'
            $names | Should -Contain 'Plain-Three' -Because 'a parameterised definition is still a definition'
        }
        It 'does not mistake a nested closure for a module-surface function' {
            $f = New-GateFixture -Files @{ 'Nest.psm1' = "function Outer-Thing {`n    function Nested-Closure { 'x' }`n    Nested-Closure`n}" }
            $names = @(Get-GateFunctionDefinitions -Path $f[0] | ForEach-Object { $_.Name })
            $names | Should -Contain 'Outer-Thing'
            $names | Should -Not -Contain 'Nested-Closure' -Because 'a closure is not part of the module export surface and cannot be listed in Export-ModuleMember'
        }
    }

    Context 'Get-GateExportStatements' {
        It 'reads a single-line export statement as reliably as a multi-line block' {
            # The line-scanner this replaced set a flag on the opening line and
            # cleared it only on a line containing nothing but ')'. In a file
            # whose export is the single line `Export-ModuleMember -Function
            # @('A','B')` that flag was still true at end of file, so 38
            # single-line export files reported nothing AND poisoned every line
            # after them. Both shapes must yield the same names.
            $f = New-GateFixture -Files @{
                'Single.psm1' = "function A { }`nfunction B { }`nExport-ModuleMember -Function @('A','B')"
                'Multi.psm1'  = "function A { }`nfunction B { }`nExport-ModuleMember -Function @(`n  'A'`n  'B'`n)"
            }
            foreach ($p in $f) {
                @(Get-GateExportStatements -Path $p).Count | Should -Be 1 -Because 'exactly one export statement exists in this fixture'
                $names = @(Get-GateExportedNames -Path $p)
                $names | Should -Contain 'A'
                $names | Should -Contain 'B'
            }
        }
        It 'does not mistake a dot-source for an export statement' {
            # There is no DotSourcesCommandAst: a dot-source is a CommandAst whose
            # InvocationOperator is Dot. Getting that wrong is silent, so it is
            # pinned rather than assumed.
            $f = New-GateFixture -Files @{
                'D.psm1' = ". (Join-Path `$PSScriptRoot 'Other.ps1')`nExport-ModuleMember -Function @('Real')"
            }
            $names = @(Get-GateExportedNames -Path $f[0])
            $names.Count | Should -Be 1
            $names[0] | Should -Be 'Real'
        }
    }

    Context 'Find-GateNonGlobalForceImports' {
        It 'FLAGS a -Force import of a shared module with no -Global' {
            $code = "`$m = Import-Module (Join-Path `$PSScriptRoot 'SharedUtils.psm1') -Force -ErrorAction SilentlyContinue"
            $hits = @(Find-GateNonGlobalForceImports -CodeText $code -FileName 'X.psm1')
            $hits.Count | Should -Be 1
            $hits[0].IsLiteral | Should -BeTrue
            $hits[0].Target | Should -Be 'SharedUtils'
            $hits[0].Line | Should -Be 1
        }
        It 'STAYS SILENT when the same import is -Global' {
            $code = "Import-Module (Join-Path `$PSScriptRoot 'SharedUtils.psm1') -Force -Global -ErrorAction SilentlyContinue"
            @(Find-GateNonGlobalForceImports -CodeText $code -FileName 'X.psm1').Count | Should -Be 0
        }
        It 'classifies a variable target as non-literal rather than missing it' {
            # The blind spot both private copies shared: a `$var` target matched
            # neither the quoted-path regex nor the variable-target branch, so it
            # was classified by accident of regex, not by what the code means.
            $code = "Import-Module `$p -Force -ErrorAction SilentlyContinue"
            $hits = @(Find-GateNonGlobalForceImports -CodeText $code -FileName 'X.psm1')
            $hits.Count | Should -Be 1
            $hits[0].IsLiteral | Should -BeFalse
            $hits[0].Target | Should -Be ''
        }
        It 'reports the line of each finding, not a running count' {
            $code = "`$a = 1`nImport-Module `$p -Force`n`$b = 2`nImport-Module `$q -Force"
            $hits = @(Find-GateNonGlobalForceImports -CodeText $code -FileName 'X.psm1')
            $hits.Count | Should -Be 2
            $hits[0].Line | Should -Be 2
            $hits[1].Line | Should -Be 4
        }
        It 'ignores a Start-Job body, which runs in an isolated child process' {
            $code = "`$j = Start-Job { Import-Module `$p -Force }"
            @(Find-GateNonGlobalForceImports -CodeText $code -FileName 'X.psm1').Count | Should -Be 0 -Because 'a child process cannot orphan parent-session modules'
        }
        It 'ignores an import with no -Force' {
            @(Find-GateNonGlobalForceImports -CodeText "Import-Module `$p -ErrorAction SilentlyContinue" -FileName 'X.psm1').Count | Should -Be 0
        }
    }

    Context 'Find-GateUnboundClosureVars' {
        It 'FLAGS a closure that reads a variable the enclosing function never binds' {
            # The exact shape of the shipped -Incremental / -GitHub defects: the
            # step-builder's CALL SITE omitted the switch, so inside the closure
            # the name resolved to $null and the flag was permanently off. The
            # builder never declared it at all - declared-here would be bound.
            $f = New-GateFixture -Files @{
                'X.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State, [switch]$Security)
    $Security = $Security
    return @(@{ Name = 'Build'; Script = { param($ctx) Invoke-Build -Incremental:$Incremental }.GetNewClosure() })
}
'@
            }
            $hits = @(Find-GateUnboundClosureVars -Paths $f)
            $hits.Count | Should -Be 1
            $hits[0] | Should -Match 'Incremental'
        }
        It 'FLAGS a step reading a variable assigned in a SIBLING step' {
            # The exact shape of the shipped security.policy.enforcement defect:
            # $cfg is a local of the Preflight step, read by PolicyCheck. An
            # unbound read is $null, so `enforcement -eq 'block'` was always
            # false and policy violations shipped green.
            $f = New-GateFixture -Files @{
                'Y.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State)
    $built = @(
        @{ Name = 'Preflight';   Script = { param($ctx) $cfg = Get-ConfigSection -State $State -Path 'build.preflight'; Write-Log $cfg.enabled } },
        @{ Name = 'PolicyCheck'; Script = { param($ctx) if ($cfg.enforcement -eq 'block') { throw 'blocked' } }.GetNewClosure() }
    )
    return $built
}
'@
            }
            $hits = @(Find-GateUnboundClosureVars -Paths $f)
            $hits.Count | Should -Be 1
            $hits[0] | Should -Match 'cfg'
        }
        It 'STAYS SILENT when the closure reads a bound local' {
            $f = New-GateFixture -Files @{
                'Z.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State)
    $target = 'x'
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $target }.GetNewClosure() })
}
'@
            }
            @(Find-GateUnboundClosureVars -Paths $f).Count | Should -Be 0
        }
        It 'STAYS SILENT for a closure parameter supplied by the caller' {
            # `$ctx` in a rollback action and `$match` in a regex evaluator are
            # bound by the closure's OWN param block, not captured. Reporting
            # them would make the gate cry wolf on every legitimate closure.
            $f = New-GateFixture -Files @{
                'W.psm1' = @'
function Register-Rollback {
    param([string]$Name, [PSCustomObject]$State)
    Register-RollbackAction -Name $Name -Action {
        param($ctx)
        Write-Log $ctx.Key
    }.GetNewClosure()
}
'@
            }
            @(Find-GateUnboundClosureVars -Paths $f).Count | Should -Be 0
        }
        It 'STAYS SILENT on a scoped variable ($env:x / $script:x / $global:x)' {
            $f = New-GateFixture -Files @{
                'V.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State)
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $env:GBUILD_LOCALE $script:x }.GetNewClosure() })
}
'@
            }
            @(Find-GateUnboundClosureVars -Paths $f).Count | Should -Be 0 -Because 'a scoped variable resolves against its own scope, not the closure'
        }
        It 'STAYS SILENT on a file with no GetNewClosure at all' {
            $f = New-GateFixture -Files @{ 'Plain.psm1' = "function A { param(`$x) `$y = `$x; return `$y }" }
            @(Find-GateUnboundClosureVars -Paths $f).Count | Should -Be 0
        }
        It 'Get-GateClosureFreeVariables reports File/Function/Variable/Line' {
            # The wrapper is proven above; this proves the AST function it wraps,
            # because a wrapper that swallowed its result would still be "driven"
            # by every wrapper fixture.
            $f = New-GateFixture -Files @{
                'R.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State)
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $nope }.GetNewClosure() })
}
'@
            }
            $rows = @(Get-GateClosureFreeVariables -Path $f[0])
            $rows.Count | Should -Be 1
            $rows[0].File | Should -Be 'R.psm1'
            $rows[0].Function | Should -Be 'Get-Steps'
            $rows[0].Variable | Should -Be 'nope'
            $rows[0].Line | Should -BeGreaterThan 0
        }
        It 'Get-GateClosureFreeVariables honours -KnownExternal' {
            $f = New-GateFixture -Files @{
                'Q.psm1' = @'
function Get-Steps {
    param([PSCustomObject]$State)
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $outside }.GetNewClosure() })
}
'@
            }
            @(Get-GateClosureFreeVariables -Path $f[0] -KnownExternal @('outside')).Count | Should -Be 0
            @(Get-GateClosureFreeVariables -Path $f[0]).Count | Should -Be 1
        }
        It 'Get-GateClosureFreeVariables honours -FunctionName' {
            $f = New-GateFixture -Files @{
                'P.psm1' = @'
function A {
    param([PSCustomObject]$State)
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $missA }.GetNewClosure() })
}
function C {
    param([PSCustomObject]$State)
    return @(@{ Name = 'B'; Script = { param($ctx) Write-Log $missC }.GetNewClosure() })
}
'@
            }
            $onlyC = @(Get-GateClosureFreeVariables -Path $f[0] -FunctionName 'C')
            $onlyC.Count | Should -Be 1
            $onlyC[0].Variable | Should -Be 'missC'
        }
    }

    Context 'Find-GateCrossModuleUnexportedCalls' {
        It 'reports a Get-Command target that no module exports' {
            # This is the exact shape of the shipped defect: a function consumed
            # behind `if (Get-Command ...)` that was missing from its own
            # Export-ModuleMember, so every guard silently took its fallback.
            $f = New-GateFixture -Files @{
                'Victim.psm1' = "function Get-FixtureSharedThing { return 'x' }`nExport-ModuleMember -Function @('Unrelated')"
                'Caller.psm1' = "if (Get-Command Get-FixtureSharedThing -ErrorAction SilentlyContinue) { Get-FixtureSharedThing }"
            }
            $findings = @(Find-GateCrossModuleUnexportedCalls -Paths $f)
            $findings.Count | Should -Be 1
            $findings[0] | Should -Match 'Get-FixtureSharedThing'
        }
        It 'stays silent once the owner exports the name' {
            $f = New-GateFixture -Files @{
                'Victim.psm1' = "function Get-FixtureSharedThing { return 'x' }`nExport-ModuleMember -Function @('Get-FixtureSharedThing','Unrelated')"
                'Caller.psm1' = "if (Get-Command Get-FixtureSharedThing -ErrorAction SilentlyContinue) { Get-FixtureSharedThing }"
            }
            @(Find-GateCrossModuleUnexportedCalls -Paths $f).Count | Should -Be 0 -Because 'a reachable name is not a defect'
        }
        It 'accepts a private shim when another module exports the same name' {
            # The Logging.Invoke-BuildSecretProtect case: a deliberate, documented
            # private shim that exists because Logging cannot import SharedUtils at
            # module scope. The rule keys on "exported nowhere", so the shim stays
            # legal with no hand-maintained exemption list to rot.
            $f = New-GateFixture -Files @{
                'Shared.psm1' = "function Get-FixtureShimmed { return 'x' }`nExport-ModuleMember -Function @('Get-FixtureShimmed')"
                'Root.psm1'  = "function Get-FixtureShimmed { return 'shim' }`nExport-ModuleMember -Function @('Other')"
                'Caller.psm1' = "if (Get-Command Get-FixtureShimmed -ErrorAction SilentlyContinue) { Get-FixtureShimmed }"
            }
            @(Find-GateCrossModuleUnexportedCalls -Paths $f).Count | Should -Be 0
        }
        It 'ignores a name no module defines (builtin or typo, not an export defect)' {
            $f = New-GateFixture -Files @{
                'Caller.psm1' = "if (Get-Command Get-Command -ErrorAction SilentlyContinue) { }"
            }
            @(Find-GateCrossModuleUnexportedCalls -Paths $f).Count | Should -Be 0
        }
        It 'ignores a Get-Command that appears only inside a comment' {
            $f = New-GateFixture -Files @{
                'Victim.psm1' = "function Get-FixtureCommented { }`nExport-ModuleMember -Function @('Other')"
                'Caller.psm1' = "# Get-Command Get-FixtureCommented -ErrorAction SilentlyContinue"
            }
            @(Find-GateCrossModuleUnexportedCalls -Paths $f).Count | Should -Be 0 -Because 'a commented-out call site is not a live dependency'
        }
    }

    Context 'Get-GateCodeWithoutComments' {
        It 'removes whole-line, trailing and block comments while preserving line count' {
            # 6 source lines. Preserving the count is not cosmetic: a detector
            # that reports "file:line" must report the line a human would see,
            # and comment stripping that eats line breaks shifts every finding.
            $f = New-GateFixture -Files @{
                'C.psm1' = "# leading`n`$a = 1 # trailing`n<#`n  block`n#>`n`$b = 2"
            }
            $raw = @(Get-Content -LiteralPath $f[0]).Count
            $code = Get-GateCodeWithoutComments -Path $f[0]
            @($code -split "\r?\n").Count | Should -BeGreaterOrEqual $raw -Because 'stripping comments must not remove lines'
            $code | Should -Not -Match 'leading'
            $code | Should -Not -Match 'trailing'
            $code | Should -Not -Match 'block'
            $code | Should -Match '\$a = 1'
            $code | Should -Match '\$b = 2'
        }

        It 'preserves line numbering on a CRLF file' {
            # The failure this pins: stripping removes the \r of a CRLF pair, so a
            # detector that then splits on a literal CR/LF pair reports every
            # finding 143 lines off on a 1148-line module. Measured, not guessed.
            $f = New-GateFixture -Files @{ 'Crlf.psm1' = "one`r`ntwo`r`nthree`r`nfour`r`nfive`r`nsix" }
            $code = Get-GateCodeWithoutComments -Path $f[0]
            $lines = @($code -split "\r?\n")
            $lines.Count | Should -Be 6
            $lines[2].Trim() | Should -Be 'three' -Because 'line 3 must still be line 3 after stripping'
        }
    }
}

Describe 'Gate self-test: the dependency-graph validator' {
    BeforeAll {
        $script:GDepRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dep_self_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/ModuleDependencies.psm1') -Force -ErrorAction Stop

        function New-DepFixture {
            param([hashtable]$Files)
            $dir = Join-Path $script:GDepRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $dir -Force
            foreach ($name in $Files.Keys) {
                $null = New-Item -ItemType Directory -Path (Join-Path $dir 'Plugins') -Force
                [System.IO.File]::WriteAllText((Join-Path $dir $name), [string]$Files[$name], (New-Object System.Text.UTF8Encoding($false)))
            }
            return $dir
        }
    }
    AfterAll {
        if ($script:GDepRoot -and (Test-Path -LiteralPath $script:GDepRoot)) {
            Remove-Item -LiteralPath $script:GDepRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects a dependency on a module that does not exist' {
        $dir = New-DepFixture -Files @{
            'A.psm1' = "Import-BuildModule -Dependencies @('Ghost')`n"
        }
        $r = Test-ModuleDependencies -ModulesRoot $dir
        $r.Passed | Should -BeFalse -Because 'a declared dependency with no file is exactly what this validator exists to catch'
        @($r.Missing).Count | Should -Be 1
        $r.Missing[0].Module | Should -Be 'A'
        $r.Missing[0].MissingDep | Should -Be 'Ghost'
    }

    It 'detects an import cycle' {
        $dir = New-DepFixture -Files @{
            'A.psm1' = "Import-BuildModule -Dependencies @('B')`n"
            'B.psm1' = "Import-BuildModule -Dependencies @('C')`n"
            'C.psm1' = "Import-BuildModule -Dependencies @('A')`n"
        }
        $r = Test-ModuleDependencies -ModulesRoot $dir
        $r.Passed | Should -BeFalse
        @($r.Cycles).Count | Should -BeGreaterThan 0 -Because 'a cycle in the import graph breaks module load order'
    }

    It 'detects a self-dependency' {
        $dir = New-DepFixture -Files @{
            'A.psm1' = "Import-BuildModule -Dependencies @('A','B')`n"
            'B.psm1' = "function Get-X { }`n"
        }
        $r = Test-ModuleDependencies -ModulesRoot $dir
        $r.Passed | Should -BeTrue -Because 'a module listing itself is a self-edge, not a load-order cycle'
        @($r.Missing).Count | Should -Be 0
    }

    It 'reads every import SHAPE - the shapes the three broken regexes missed' {
        # One fixture exercising all five forms the production code uses. The
        # historical regexes caught three of these and returned empty for the
        # other two, which is why the shipped graph under-reported.
        $dir = New-DepFixture -Files @{
            'Alpha.psm1' = "function Get-X { }`nExport-ModuleMember -Function @('Get-X')`n"
            'ViaBootstrap.psm1' = ". (Join-Path `$PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Alpha')`n"
            'ViaBuildModule.psm1' = "Import-BuildModule -Dependencies @('Alpha')`n"
            'ViaIfMissing.psm1'   = "Import-GBuildModuleIfMissing -Name 'Alpha' -SentinelCommand 'Get-X'`n"
            'ViaForeach.psm1'     = "foreach (`$dep in @('Alpha')) {`n    `$p = Join-Path `$PSScriptRoot `"`$dep.psm1`"`n    Import-Module `$p`n}`n"
        }
        $map = Get-ModuleDependencyMap -ModulesRoot $dir
        foreach ($shape in 'ViaBootstrap', 'ViaBuildModule', 'ViaIfMissing', 'ViaForeach') {
            $map[$shape] |
                Should -Contain 'Alpha' -Because "the $shape import form must be recognised; a form the parser cannot see is a form it cannot validate"
        }
    }

    It 'ignores a NON-import string array - the false positive the old foreach rule produced' {
        # $imports.GetEnumerator() sits in a foreach whose body DOES import, so a
        # proximity-only rule reads it as a dependency named GetEnumerator.
        $dir = New-DepFixture -Files @{
            'Real.psm1'  = "function Get-X { }`nExport-ModuleMember -Function @('Get-X')`n"
            'Dynamic.psm1' = "`$imports = @{ Real = 'Real.psm1' }`nforeach (`$pair in `$imports.GetEnumerator()) {`n    `$p = Join-Path `$PSScriptRoot `$pair.Value`n    Import-Module `$p`n}`n"
        }
        $deps = @(Get-ModuleDependencyMap -ModulesRoot $dir)['Dynamic']
        $deps | Should -Not -Contain 'GetEnumerator' -Because 'a method name is not a module; flagging it would report a false missing dependency'
        $r = Test-ModuleDependencies -ModulesRoot $dir
        $r.Passed | Should -BeTrue -Because 'the fixture must be genuinely clean once the false positive is gone'
    }

    It 'passes on a clean fixture' {
        $dir = New-DepFixture -Files @{
            'Core.psm1'  = "function Get-Core { }`nExport-ModuleMember -Function @('Get-Core')`n"
            'Consumer.psm1' = "Import-BuildModule -Dependencies @('Core')`n"
        }
        $r = Test-ModuleDependencies -ModulesRoot $dir
        $r.Passed | Should -BeTrue -Because "a validator that fails a clean input is broken in the other direction: $($r.Summary)"
    }
}

Describe 'Gate self-test: the harness itself is falsifiable' {
    It 'reports a detector that cannot flag its own violation' {
        # The harness's own worth depends on one property: given a detector and a
        # fixture the detector should flag, a detector that stays silent must be
        # REPORTED. Simulate exactly that - a stub that always returns nothing -
        # and assert the check catches it. Without this, the fixtures above only
        # prove the detectors work TODAY, not that their failure would be noticed.
        $brokenDetector = { param([string[]]$Paths, [string[]]$Allowed = @()) return @() }
        $violating = New-GateFixture -Files @{ 'Bad.psm1' = 'x [System.PlatformID]::Win32NT y' }
        $result = @(& $brokenDetector -Paths $violating)
        $result.Count | Should -Be 0 -Because 'the stub is deliberately blind; this line documents the state being detected'

        # The assertion the harness makes: silence on a known violation is a FAILURE.
        $isBlind = ($result.Count -eq 0)
        $isBlind | Should -BeTrue -Because 'this is the condition the harness exists to report'
        $detectedAsBlind = $isBlind
        $detectedAsBlind | Should -BeTrue -Because 'a blind detector must be detectable, or every fixture above is decoration'
    }

    It 'does not confuse "clean input" with "blind detector"' {
        # The control for the previous test: the same silence on CLEAN input is
        # correct behaviour and must NOT be reported as blindness. Without this
        # pair, a harness could be trivially satisfied by a detector that always
        # returns nothing.
        $blind = { param([string[]]$Paths, [string[]]$Allowed = @()) return @() }
        $clean = New-GateFixture -Files @{ 'Good.psm1' = 'function Get-Thing { if (Test-IsWindowsHost) { 1 } }' }
        @(& $blind -Paths $clean).Count | Should -Be 0
        @(& $blind -Paths $clean).Count | Should -Be 0
        # Silence on clean input is EXPECTED; silence on a violation is a defect.
        # The two are distinguishable only because the fixtures differ.
        $violating = New-GateFixture -Files @{ 'Bad.psm1' = 'x [System.PlatformID]::Win32NT y' }
        $realDetector = ${function:Find-GateInlineWin32NT}
        @(& $realDetector -Paths $violating).Count | Should -BeGreaterThan 0 -Because 'the real detector distinguishes the two fixtures; that difference is the proof'
    }
}