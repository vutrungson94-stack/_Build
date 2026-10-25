# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# Hygiene.Tests.ps1 - STRUCTURAL gates (restored tail; full original had ~1400 lines)
Set-StrictMode -Version 1.0

BeforeAll {
    $hygToolRoot    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    . (Join-Path $PSScriptRoot 'GateDetectors.ps1')
    $hygModulesDir = Join-Path $hygToolRoot 'Modules'
    $hygPluginDir  = Join-Path $hygModulesDir 'Plugins'
    $hygProviderDir = Join-Path $hygModulesDir 'Providers'
    $hygStepsDir   = Join-Path $hygToolRoot 'Steps'
    $hygHooksDir   = Join-Path $hygToolRoot 'Hooks'
    $hygTestsDir   = Join-Path $hygToolRoot 'Tests'

    function Get-HygScriptFile {
        param([string]$Path, [switch]$Recurse)
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
        $found = @()
        if ($Recurse) {
            $found = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' -or $_.Extension -eq '.psd1' })
        } else {
            $found = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' -or $_.Extension -eq '.psd1' })
        }
        return $found
    }
    function Get-HygProdFiles {
        $out = @()
        foreach ($d in @($hygModulesDir, $hygPluginDir, $hygProviderDir, $hygStepsDir, $hygHooksDir)) { $out += @(Get-HygScriptFile -Path $d -Recurse) }
        $out += @(Get-HygScriptFile -Path $hygToolRoot)
        return $out
    }
    $script:HygProdFiles = Get-HygProdFiles
    $script:HygProdPaths = @($script:HygProdFiles | ForEach-Object { $_.FullName })
    $script:HygTestPaths = @((Get-HygScriptFile -Path $hygTestsDir -Recurse) | ForEach-Object { $_.FullName })
    $script:HygIgnProd = Get-GateIgnoredReferenceLines -Paths $script:HygProdPaths
    $script:HygIgnTest = Get-GateIgnoredReferenceLines -Paths $script:HygTestPaths
}
Describe 'Hygiene: no dead exported functions' {
    It 'has every exported function reachable from production or tests' {
        $defs = @()
        foreach ($p in $script:HygProdFiles) {
            # Get-GateFunctionDefinitions, not a private regex. This file used to
            # carry `^\s*function\s+Name\s*\{` inline, which missed
            # `function global:Name {` and `function Name($a) {` and counted
            # nested closures as module surface. Re-implementing the detector
            # here is the duplication problem restated one level up: the
            # self-test proved the shared copy while the gate ran the weak one.
            foreach ($d in @(Get-GateFunctionDefinitions -Path $p.FullName)) {
                $defs += [PSCustomObject]@{ Name = $d.Name; File = $p.FullName; Line = $d.Line; Exported = $false; DefiningModule = $p.FullName }
            }
            # AST-based, so a single-line Export-ModuleMember is read exactly the
            # same as a multi-line block, and either quote style counts.
            $exported = @(Get-GateExportedNames -Path $p.FullName)
            foreach ($d in @($defs | Where-Object { $_.File -eq $p.FullName })) { if ($exported -contains $d.Name) { $d.Exported = $true } }
        }
        $defs.Count | Should -BeGreaterThan 200 -Because 'the module surface is large enough for this gate to be meaningful'

        # DELIBERATE PUBLIC API (exempt, documented, each re-reviewed on any
        # change). These have zero production call sites by DESIGN, not neglect:
        #   ErrorHandling.Reset-ErrorLog      - per-run lifecycle reset for
        #     long-lived hosts that call Start-GBuild more than once in a
        #     session. Its absence meant error state leaked between runs.
        #   PluginSDK.New-PluginManifestTemplate - scaffolding for third-party
        #     plugin authors. The whole point of a plugin SDK is an entry point
        #     that THIS repository never calls.
        # Anything else exported-but-unreachable is dead surface.
        $deliberate = @(
            # Functions with zero production call sites kept as PUBLIC API for
            # external consumers. Each entry names its real consumer. The tag
            # format is Module::Function (no extension).
            'AutoTuner::Approve-AutoTuneProposal',   # pilot operator decision API
            'AutoTuner::New-AutoTuneProposal',       # pilot proposal API
            'CacheProvider::Get-LocalCacheDir',      # exported accessor for external cache consumers
            'Container::Set-ServiceFactory',         # documented DI extension point
            'Menu::Show-BuildEnvironmentSummary',    # config-declared custom menu handler (gbuild.config.json)
            'PluginSDK::New-PluginManifestTemplate',  # plugin SDK scaffolding entry point
            'ProcessMetrics::Find-RatchetCandidates', # ratchet-history tooling
            'ProcessMetrics::Get-BuildProcessSparkline', # .github/workflows/build.yml:746
            'ProcessMetrics::Get-FleetBillingSummary',# fleet rollup consumer
            'ProcessMetrics::Invoke-FleetRollup',     # fleet rollup
            'ProcessMetrics::Publish-FleetSLOSummary',# fleet SLO publish
            'ProcessMetrics::Write-BuildProcessTrend',# Tests/Run-CoreTests.ps1:683
            'RootCause::Confirm-CARClosure',         # CAR ledger operator API
            'RootCause::Export-CARAuditPack',        # CAR audit pack export
            'RootCause::Get-TenantUsageSummary',     # tenant usage API
            'RootCause::Test-CARAuditPack'           # CAR audit pack verification
        )
        $dead = @()
        foreach ($d in @($defs | Where-Object { $_.Exported })) {
            # The defining module is NOT excluded from its own reference scan.
            #
            # It used to be (`-ExcludePaths @($d.DefiningModule)`), on the
            # reasoning that a module should not keep itself alive. That
            # premise is wrong: "reachable from production" is the question,
            # and a helper called 13 times inside the module that owns it is
            # plainly reachable from production. Excluding the owner asked a
            # strictly harder and strictly different question - "does any
            # OTHER module call this" - and answered it with the wrong verdict.
            #
            # The exclusion also had no protective effect: the self-reference
            # lines it was meant to suppress are already suppressed by
            # $script:HygIgnProd, which ignores the definition line and every
            # Export-ModuleMember line (see Get-GateIgnoredReferenceLines).
            # 324 exported functions in this tree have their only production
            # references inside their own module; one of them
            # (Orchestrator::Assert-BuildCommandAvailable, 13 call sites) had no
            # test reference either, and was therefore reported DEAD by this
            # very gate. That was the whole class of defect, not a lone name.
            if ((Get-GateReferenceCount -Name $d.Name -Paths $script:HygProdPaths -Ignored $script:HygIgnProd) -gt 0) { continue }
            $tag = "$([System.IO.Path]::GetFileNameWithoutExtension($d.File))::$($d.Name)"
            if ($deliberate -contains $tag) { continue }
            $dead += $tag
        }
        $dead | Should -BeNullOrEmpty -Because "these exported functions are dead: $($dead -join ', ')"

        # An allowlist entry must still be NEEDED.
        #
        # The gate above consults $deliberate only AFTER both reference scans
        # return zero, so an entry that has since become reachable is simply
        # never consulted - and the exemption it grants is permanent and
        # invisible. The concrete failure: delete the last caller of
        # Siem::Send-SiemUdp, the entry is still in the list, the gate stays
        # green, and the dead export ships. A reviewer reading the list sees a
        # justified exemption and has no way to know it now exempts nothing.
        #
        # This asserts the list is exactly the set of entries that are CURRENTLY
        # unreachable, so it can never drift past its own justification. Prune
        # the entry or restore the call site - both are real work; silently
        # widening an exemption is not.
        $stillReachable = @()
        foreach ($d in @($defs | Where-Object { $_.Exported })) {
            $tag = "$([System.IO.Path]::GetFileNameWithoutExtension($d.File))::$($d.Name)"
            if ($deliberate -notcontains $tag) { continue }
            if ((Get-GateReferenceCount -Name $d.Name -Paths $script:HygProdPaths -Ignored $script:HygIgnProd) -gt 0) { $stillReachable += $tag; continue }
        }
        $stillReachable | Should -BeNullOrEmpty -Because "these entries are in the deliberate-public-API list but ARE referenced, so the exemption now hides a live export from the gate: $($stillReachable -join ', ')"
    }
}

Describe 'Hygiene: intentional cross-module duplication stays governed' {
    # AnomalyDetector.psm1 and RootCause.psm1 each carry a private copy of a
    # shared preamble (root resolver + path resolver + config reader). The
    # duplication is intentional and the modules say so in their own comments:
    # both files load through -Global imports where a shared preamble module
    # hits module-scope issues, and
    # Tests/ModuleHygiene.Tests.ps1 ('no NEW inline root ternary') registers
    # these two files as approved sites for the inline root ladder.
    #
    # Those comments also claim the copies are "asserted by the near-duplicate
    # hygiene check". No such check existed: the claim was false, so the copies
    # were free to drift with nothing to notice. This gate makes the comment
    # true. Removing the duplication instead would break the root-ternary gate
    # those two registrations exist to allow, so the correct end state is
    # governed duplication, not zero duplication.
    #
    # Pinned on the FUNCTION BODY, not on a line number, so a legitimate change
    # to one module that is mirrored into the other passes.
    It 'keeps the AnomalyDetector/RootCause shared preamble byte-identical' {
        $a = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'AnomalyDetector.psm1') -Raw -Encoding UTF8
        $r = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'RootCause.psm1') -Raw -Encoding UTF8
        foreach ($fn in @('Get-DiagnosticRoot', 'Resolve-DiagnosticPath')) {
            # (?ms): s for the DOTALL body, m so ^ anchors per LINE - the
            # function is not at offset 0 of the file, and a plain (?s)^ would
            # only ever match a file that STARTS with it, which is a gate that
            # reports "missing" for the wrong reason.
            $pat = "(?ms)^function $([regex]::Escape($fn))\s*\{.*?^\}"
            $ma = [regex]::Match($a, $pat)
            $mr = [regex]::Match($r, $pat)
            $ma.Success | Should -BeTrue -Because "$fn must exist in AnomalyDetector.psm1"
            $mr.Success | Should -BeTrue -Because "$fn must exist in RootCause.psm1"
            # Normalise line endings: the two files must agree on LOGIC, and a
            # CRLF/LF difference is a checkout artefact, not a drift signal.
            $na = ($ma.Value -replace "`r`n", "`n")
            $nr = ($mr.Value -replace "`r`n", "`n")
            $na | Should -BeExactly $nr -Because "$fn is an intentional duplicate; changing it in one module must change it in the other or the approved root-ternary registrations silently describe two different ladders"
        }
    }

    It 'registers every pair it governs, so a new copy cannot be added unnoticed' {
        # An empty governance list is a gate that cannot fail. Pair each file
        # against the set it is declared to duplicate.
        $pairs = @(
            @{ A = 'AnomalyDetector.psm1'; B = 'RootCause.psm1' }
        )
        $pairs.Count | Should -BeGreaterThan 0 -Because 'a governance list with no entries proves nothing'
        foreach ($p in $pairs) {
            foreach ($side in @('A', 'B')) {
                $name = $p[$side]
                Test-Path -LiteralPath (Join-Path $script:HygModulesDir $name) -PathType Leaf |
                    Should -BeTrue -Because "the governed pair references $name, which no longer exists"
            }
            # The rationale must be recorded in BOTH files, or the next reader
            # finds a duplicate with no reason and no gate explaining it.
            foreach ($side in @('A', 'B')) {
                $name = $p[$side]
                $text = Get-Content -LiteralPath (Join-Path $script:HygModulesDir $name) -Raw -Encoding UTF8
                $text | Should -Match 'Intentionally duplicated' -Because "$name holds an approved duplicate and must say why, next to the copy"
            }
        }
    }
}

Describe 'Hygiene: removed duplicate surface stays removed' {
    It 'does not redefine a removed pass-through' {
        $removed = @('Invoke-InfraVerify', 'Invoke-InfraAutoRemediate', 'ConvertTo-EncryptedSecret', 'Assert-RequiredResult', 'Get-FileHashSHA256', 'Cancel-ClusterBuild', 'New-RBACRole', 'Remove-RBACRole', 'Set-RBACRolePermissions')
        $files = @(Get-ChildItem -LiteralPath $script:HygModulesDir -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
        $texts = @{}
        foreach ($p in $files) { try { $texts[$p.FullName] = Get-Content -LiteralPath $p.FullName -Raw } catch { } }
        $back = @()
        foreach ($n in $removed) {
            foreach ($k in $texts.Keys) {
                foreach ($d in @(Get-GateFunctionDefinitions -Path $k)) {
                    # AST-based: the line regex this used to require a literal
                    # `function Name {`, so a reintroduced duplicate written as
                    # `function global:Name {` or `function Name($a) {` slipped
                    # through every one of these nine names.
                    if ($d.Name -eq $n) { $back += "$n in $([System.IO.Path]::GetFileName($k)) (line $($d.Line))" }
                }
            }
        }
        $back | Should -BeNullOrEmpty -Because "these were removed as duplicates: $($back -join ', ')"
    }

    It 'does not export a removed pass-through' {
        $removed = @('Invoke-InfraVerify', 'Invoke-InfraAutoRemediate', 'ConvertTo-EncryptedSecret', 'Assert-RequiredResult', 'Get-FileHashSHA256', 'Cancel-ClusterBuild', 'New-RBACRole', 'Remove-RBACRole', 'Set-RBACRolePermissions')
        $files = @(Get-ChildItem -LiteralPath $script:HygModulesDir -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
        $back = @()
        foreach ($n in $removed) {
            foreach ($p in $files) {
                try {
                    foreach ($name in @(Get-GateExportedNames -Path $p.FullName)) {
                        if ($name -eq $n) { $back += "$n in $($p.Name)" }
                    }
                } catch { }
            }
        }
        $back | Should -BeNullOrEmpty -Because "these must not be exported: $($back -join ', ')"
    }
}

Describe 'Hygiene: enforcement gates are reachable' {
    It 'exports the process exit-code channel' {
        $t = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'Orchestrator.psm1') -Raw
        $t | Should -Match 'function Set-GBuildExitCode'
        $t | Should -Match 'function Get-GBuildExitCode'
        $t | Should -Match 'function Reset-GBuildExitCode'
    }

    It 'acts on the security verdict instead of discarding it' {
        $t = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'Orchestrator.psm1') -Raw
        $m = [regex]::Match($t, '(?s)\$secResult\s*=\s*Invoke-SecurityScan.*?Set-GBuildExitCode')
        $m.Success | Should -BeTrue -Because 'a failing Invoke-SecurityScan must reach the exit-code channel'
    }

    It 'resets the exit code before a run' {
        $t = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.ps1') -Raw
        $t | Should -Match 'Reset-GBuildExitCode'
    }

    It 'propagates the exit code to the shell' {
        $t = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.ps1') -Raw
        $t | Should -Match 'exit \$__buildExit'
    }
}

Describe 'Hygiene: the launcher surface stays in sync with the help text' {
    It 'documents only switches that exist' {
        $ps1 = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.ps1') -Raw
        $doc = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'Documentation.psm1') -Raw
        # [Alias('x')][switch]$Name  /  [switch]$Name  /  [string]$Name ...
        # The public surface is EVERY param, not only the switches: -Project,
        # -Target, -Locale and -LogLevel are value params and are documented in
        # the same synopsis table. Collecting only `[switch]$Name` made the
        # reverse direction report those as phantoms.
        $params = @([regex]::Matches($ps1, '\[\s*(?:Alias\([^)]*\)\s*)?(?:switch|string|int|long|bool)\]\$([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $switches = @($params | Where-Object { $ps1 -match ('\[switch\]\$' + [regex]::Escape($_) + '\b') })
        $switches.Count | Should -BeGreaterThan 8 -Because 'the CLI surface is a public contract'
        $params.Count | Should -BeGreaterThan 8 -Because 'the CLI surface is a public contract'

        # Every switch the launcher actually accepts must be documented.
        #
        # Direction matters, and the previous direction was the bug. It scanned the
        # help text for switch-looking tokens and asserted each one existed in
        # gbuild.ps1 - with a SINGLE-QUOTED token pattern ("'(-[A-Za-z]+)'"), while
        # the help text documents switches bare in synopsis form. Measured on the
        # shipped file: 0 single-quoted tokens, 140 bare ones. $advertised was
        # always empty, $missing was always empty, and this gate reported PASS
        # while inspecting nothing - green because blind.
        #
        # Driving it from gbuild.ps1's real `[switch]$Name` params instead makes it
        # non-vacuous by construction: the set is 16 entries the parser produced,
        # so a documentation gap shows up as a gap.
        $undocumented = @($switches | Where-Object {
                $doc -notmatch ('(?<![A-Za-z0-9_])-' + [regex]::Escape($_) + '(?![A-Za-z0-9])')
            })
        $undocumented | Should -BeNullOrEmpty -Because "the launcher accepts switches the help text never documents: $($undocumented -join ', ')"

        # And the reverse direction, scoped to the synopsis table so embedded
        # PowerShell examples (-Encoding, -LiteralPath, cmdlet parameters) are not
        # mistaken for documented launcher switches.
        $synopsis = [regex]::Match($doc, '(?s)EXAMPLES:.*$')
        $table = if ($synopsis.Success) { $doc.Substring(0, $synopsis.Index) } else { $doc }
        $advertised = @(
            [regex]::Matches($table, '(?m)^\s{4,}-([A-Za-z][A-Za-z0-9]*)') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )
        $advertised.Count | Should -BeGreaterThan 5 -Because 'the help text documents the whole launcher surface; extracting none means the pattern is blind, not that the contract is clean'
        $phantom = @($advertised | Where-Object { $params -notcontains $_ })
        $phantom | Should -BeNullOrEmpty -Because "the help text advertises switches the launcher does not accept: $($phantom -join ', ')"
    }

    It 'keeps the standalone bundle emission in sync with gbuild.ps1' {
        # The bundle re-declares the launcher param surface as $sb.AppendLine lines
        # in New-StandaloneBundleScript. Nothing parses gbuild.ps1 to derive it, so
        # a new switch landing in the real launcher used to silently ship in every
        # bundle but fail the bundle-side parse/splat. Pin the two sets together.
        $ps1 = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.ps1') -Raw
        $sa  = Get-Content -LiteralPath (Join-Path $script:HygModulesDir 'Standalone.psm1') -Raw
        # Extract the param surface Standalone emits: each AppendLine row in
        # New-StandaloneBundleScript that declares a typed variable.
        $emitted = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($sa, "(?m)AppendLine\('([^']*(?:''[^']*)*)'\)")) {
            $row = $m.Groups[1].Value.Replace("''", "'")
            $pm = [regex]::Match($row, '\$([A-Za-z][A-Za-z0-9]*)\s*(=|,|$)')
            if ($pm.Success -and ($row -match '\[(Alias\(|switch|string|Parameter|int|long|bool)')) { [void]$emitted.Add($pm.Groups[1].Value) }
        }
        $sbParams = @($emitted | Sort-Object -Unique)
        # Restrict gbuild.ps1 extraction to its actual param(...) block: the
        # attribute shape ([switch]$Foo, [string]$Bar = ...) also occurs in
        # foreach bodies and object literals deeper in the launcher.
        $paramBlockMatch = [regex]::Match($ps1, '(?s)\bparam\(\s*(.*?)\n\)')
        $paramBlock = if ($paramBlockMatch.Success) { $paramBlockMatch.Groups[1].Value } else { '' }
        $psParams = @([regex]::Matches($paramBlock, '\[\s*(?:Alias\([^)]*\)\s*)*(?:switch|string|int|long|bool)\]\$([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $missingInSb = @($psParams | Where-Object { $sbParams -notcontains $_ })
        $missingInSb | Should -BeNullOrEmpty -Because "parameters in gbuild.ps1 that the standalone bundle does not emit: $($missingInSb -join ', ')"
        $missingInPs1 = @($sbParams | Where-Object { $psParams -notcontains $_ -and $_ -ne 'AdditionalArgs' })
        $missingInPs1 | Should -BeNullOrEmpty -Because "parameters the standalone bundle emits but gbuild.ps1 does not accept: $($missingInPs1 -join ', ')"
    }

    It 'keeps the batch launcher fallback reachable' {
        # cmd.exe expands %VAR% across a whole if/else compound at PARSE time.
        # gbuild.bat used `if %errorlevel% equ 0` INSIDE the else-branch, so the
        # test read the value left by the earlier `where pwsh` and never the
        # `where powershell` that had just run: the powershell.exe fallback was
        # dead code and a machine with only Windows PowerShell 5.1 - present on
        # every supported Windows release - was told PowerShell was missing. The
        # bash launcher used separate statements and worked, so the two
        # launchers silently disagreed with no test anywhere.
        $bat = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.bat') -Raw
        $bat | Should -Match 'EnableDelayedExpansion' -Because 'the deferred-expansion probe requires it, and cmd.exe silently mis-behaves without it'
        # Inside the fallback block, %errorlevel% must not appear: only
        # !errorlevel! resolves after the `where powershell` it is testing.
        $fallback = [regex]::Match($bat, '(?s)if not defined PWSH \(\s*where powershell.*?\)')
        $fallback.Success | Should -BeTrue -Because 'the powershell.exe fallback must exist at all'
        $fallback.Value | Should -Not -Match '%errorlevel%' -Because '%errorlevel% is expanded at parse time and always reads the previous probe'
        $fallback.Value | Should -Match '!errorlevel!' -Because 'only delayed expansion reads the probe it follows'
        $bat | Should -Match 'exit /b !errorlevel!' -Because 'the launcher must forward the host exit code so CI sees a real failure'
    }

    It 'keeps the profile shim CLI surface identical to the real entrypoint' {
        # Install-GBuild.ps1 writes a `gbuild` function into the user's
        # $PROFILE. That function is a FOURTH CLI surface, and it is the one
        # users actually type after installing - yet it declared none of
        # gbuild.ps1's eight aliases. `gbuild -gh` still worked, but only by
        # accident: ValueFromRemainingArguments swept `-gh` into
        # $AdditionalArgs and the real entrypoint understood it there. Tab
        # completion, Get-Command -Syntax and Get-Help all advertised a
        # different surface from the file the tool actually ships, in a codebase
        # whose own launchers carry a "SYNCHRONIZED - keep all three in sync"
        # header.
        #
        # The shim lives inside a here-string template, so it is DATA to the
        # parser. Extract the template and parse THAT, or this check silently
        # finds no parameters and passes.
        $installPath = Join-Path $script:HygToolRoot 'Install-GBuild.ps1'
        $text = Get-Content -LiteralPath $installPath -Raw
        $tmpl = [regex]::Match($text, "(?s)@'(?<body>.*?)'@")
        $tmpl.Success | Should -BeTrue -Because 'the profile shim is emitted as a here-string template; if that shape changes this test must change with it rather than silently pass'

        $getSurface = {
            param([string]$Code, [bool]$IsScript)
            $tk = $null; $er = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tk, [ref]$er)
            $pb = if ($IsScript) {
                $ast.ParamBlock
            } else {
                $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'gbuild' }, $true))
                if ($fn.Count -gt 0) { $fn[0].Body.ParamBlock } else { $null }
            }
            if (-not $pb) { return @() }
            $names = @()
            foreach ($p in $pb.Parameters) {
                $n = @($p.Name.VariablePath.UserPath)
                foreach ($al in @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Alias' })) {
                    foreach ($a in $al.PositionalArguments) { if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $n += $a.Value } }
                }
                $names += $n
            }
            return @($names | Sort-Object)
        }

        $entry  = & $getSurface (Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'gbuild.ps1') -Raw) $true
        $shim   = & $getSurface $tmpl.Groups['body'].Value $false
        $entry.Count | Should -BeGreaterThan 15 -Because 'the entrypoint declares 20 parameters; finding almost none means the extraction broke, not that the shim is clean'
        $shim.Count  | Should -BeGreaterThan 15 -Because 'the shim template must have parsed; an empty surface is a false green, not a pass'

        # AdditionalArgs is the shim's deliberate pass-through for anything the
        # entrypoint grows later, so it is not a divergence.
        $missing = @($entry | Where-Object { $shim -notcontains $_ -and $_ -ne 'AdditionalArgs' })
        $extra   = @($shim  | Where-Object { $entry -notcontains $_ -and $_ -ne 'AdditionalArgs' })
        ($missing + $extra) | Should -BeNullOrEmpty -Because "the installed `gbuild` must accept exactly what gbuild.ps1 accepts (missing: $($missing -join ', '); extra: $($extra -join ', '))"
    }

    It 'asks before rewriting the user profile' {
        # SupportsShouldProcess was declared on the installer and never once
        # consulted: it appended to (or rewrote) $PROFILE and defined a global
        # function plus a `gb` alias without asking. -WhatIf was accepted as a
        # switch and then ignored, which is worse than not offering it at all -
        # it tells the user the change is previewable when it is not.
        $text = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'Install-GBuild.ps1') -Raw
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match '\$PSCmdlet\.ShouldProcess' -Because 'declaring SupportsShouldProcess without calling ShouldProcess makes -WhatIf and -Confirm silently lie'
        $addOrSet = ([regex]::Matches($text, '(?m)^\s*(Add-Content|Set-Content)\s+-Path\s+\$profilePath')).Count
        $addOrSet | Should -BeGreaterThan 0 -Because 'the assertion above is only meaningful if the profile really is rewritten'
    }
}

Describe 'Hygiene: the process baseline is versioned and structurally valid' {
    It 'ships a tracked process baseline with the required sections' {
        $p = Join-Path $script:HygToolRoot 'Tests/process-baseline.json'
        Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue -Because 'the verification process must measure itself in a versioned file'
        $b = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($section in @('core', 'e2e', 'coverage', 'hygiene', 'compatibility')) {
            $b.PSObject.Properties.Name | Should -Contain $section -Because "the baseline must document $section"
        }
        $b.core.failedAllowed | Should -Be 0 -Because 'zero failures is the only acceptable baseline'
        $b.core.testsTotal | Should -BeGreaterThan 1000 -Because 'the suite size is the denominator of every ratio'
        $b.coverage.floorPercent | Should -BeGreaterThan 0 -Because 'an unmeasured process cannot be managed (CMMI L4)'
        $b.hygiene.gates | Should -BeGreaterThan 10 -Because 'the structural gates are the anti-regression mechanism'
        $b.hygiene.unreferencedConstantsAllowed | Should -Be 0
        $b.hygiene.deadExportedFunctionsAllowed | Should -Be 0

        # The declared gate count must equal the REAL count. This was
        # `Should -BeGreaterThan 10`, which is why the baseline could sit at 19
        # while only 17 Describe blocks existed - a number nobody could falsify
        # and nobody did. Counting the same thing the baseline claims to count is
        # what stops it drifting again.
        $actual = 0
        foreach ($gf in @('Tests/Hygiene.Tests.ps1', 'Tests/ModuleHygiene.Tests.ps1')) {
            $gp = Join-Path $script:HygToolRoot $gf
            if (-not (Test-Path -LiteralPath $gp -PathType Leaf)) { continue }
            $actual += ([regex]::Matches((Get-Content -LiteralPath $gp -Raw), '(?m)^\s*Describe\s')).Count
        }
        $b.hygiene.gates | Should -Be $actual -Because "the baseline must report the real gate count ($actual Describe blocks across Hygiene.Tests.ps1 + ModuleHygiene.Tests.ps1); a stale count is a number that measures nothing"
    }

    It 'keeps the deliberate public API list in sync with the dead-export gate' {
        $p = Join-Path $script:HygToolRoot 'Tests/process-baseline.json'
        $b = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $listed = @($b.hygiene.deliberatePublicApi)
        $listed | Should -Contain 'PluginSDK::New-PluginManifestTemplate'
        $listed | Should -Contain 'Container::Set-ServiceFactory'
        # The gate file must honour exactly this list - no silent divergence.
        $gate = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'Tests/Hygiene.Tests.ps1') -Raw
        foreach ($entry in $listed) {
            $gate | Should -Match ([regex]::Escape($entry)) -Because "the gate must exempt exactly the baseline's deliberate API: $entry"
        }
    }

    It 'resolves its $schema to a file that exists and validates the baseline' {
        # The baseline pointed $schema at
        # https://github.com/gbuild/_Build/Tests/process-baseline.schema.json -
        # a path on a repository that does not exist, naming a file that was
        # never shipped. Nothing consumed the pointer, so the artefact that is
        # supposed to measure the quality process was itself unvalidated, and a
        # structural regression in it would have shipped green. Two fixes, and
        # BOTH are needed: the schema now exists, and this gate makes the
        # pointer load-bearing instead of decorative.
        $p = Join-Path $script:HygToolRoot 'Tests/process-baseline.json'
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        $b = $raw | ConvertFrom-Json
        $ref = [string]$b.'$schema'
        $ref | Should -Not -BeNullOrEmpty -Because 'the baseline must declare the schema it claims to follow'

        # A relative reference is what makes this work offline and on a clean
        # checkout; an absolute https URL cannot be resolved by a local gate.
        $ref | Should -Not -Match '^https?://' -Because 'an off-machine URL cannot be verified by an offline gate, which is how the pointer rotted unnoticed'
        $resolved = Join-Path (Split-Path -Parent $p) $ref
        Test-Path -LiteralPath $resolved -PathType Leaf |
            Should -BeTrue -Because "the baseline's `$schema must resolve to a real file: $ref"

        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            $schema = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
            { Test-Json -Json $raw -Schema $schema -ErrorAction Stop } |
                Should -Not -Throw -Because 'the baseline must satisfy the schema it declares; the schema is the structural contract, not documentation'
        } else {
            Set-ItResult -Skipped -Because 'Test-Json is PowerShell 6+; the offline existence check above still ran'
        }
    }
}

Describe 'Hygiene: process adoption never regresses below its committed floor' {
    # THE L5 GATE. Every other gate in this file is binary: red or green, at one
    # instant, about one line of code. This one is about DIRECTION.
    #
    # The failure it catches is specific and had already happened here: a defect
    # class was cleaned up, reached zero, and then crept back one site at a time.
    # No individual gate noticed, because each gate only ever looked at its own
    # current value and every one of them was technically satisfied.
    #
    # Why the floor is COMMITTED (Tests/process-baseline.json) while the curve is
    # NOT: the curve needs history that only accumulates over time, so it cannot
    # gate a fresh CI checkout. The floor must therefore be version-controlled -
    # that split is what makes this gate work on the very first run of a new clone.
    It 'ships a committed adoption floor for every measured class' {
        }
    }
