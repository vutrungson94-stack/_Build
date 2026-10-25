#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Static tripwire for Windows PowerShell 5.1 incompatibilities. Proven 5.1-only
# failures (pwsh 7 parses AND runs them fine, so syntax checks never catch them):
#   `(if ...)` subexpression  -> "term 'if' is not recognized" (Cache, Parallel,
#                               DeployTargets, HealthCheck, Metrics incidents)
#   `?.` / `??` operators     -> parse error on 5.1
#   ternary `$c ? $a : $b`    -> parse error on 5.1
#   ForEach-Object -Parallel  -> parameter not found on 5.1
# Scans real code only (comments, strings and here-strings stripped). This file
# itself must stay 5.1-parseable: no `(if)`, no ?. / ??, no ternary.
# Twin of the stripper in ModuleHygiene.Tests.ps1 (duplicated on purpose: test
# files stay standalone like every other Tests/*.Tests.ps1). Deliberate
# divergence: this copy always strips strings (pattern text like ?. inside
# regex literals must not trip the scan); the hygiene copy has -KeepStrings
# because literal module paths live inside quotes.
# NOTE (Pester 5): helpers live inside BeforeAll — file-level functions are
# not visible to Describe blocks under Pester 5 discovery.

Describe 'PS51Compat - static 5.1 incompatibility scan' {
    BeforeAll {
        $script:CompatBuildRoot = Split-Path -Parent $PSScriptRoot
        $script:CompatDiscoveryErrors = New-Object System.Collections.Generic.List[string]

        function Get-CompatCodeText {
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Path)
            $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { return '' }
            $out = New-Object System.Collections.Generic.List[string]
            $inBlock = $false
            $inHere = $false
            foreach ($raw in $lines) {
                $line = [string]$raw
                if ($inHere) {
                    if ($line -match '^\s*"@\s*$') { $inHere = $false }
                    continue
                }
                if ($line -match '^\s*@"\s*$') { $inHere = $true; continue }
                $code = $line
                $guard = 0
                while ($true) {
                    $guard++
                    if ($guard -gt 20) { break }
                    if ($inBlock) {
                        $e = $code.IndexOf('#>')
                        if ($e -ge 0) { $code = $code.Substring($e + 2); $inBlock = $false } else { $code = ''; break }
                    } else {
                        $s = $code.IndexOf('<#')
                        if ($s -lt 0) { break }
                        $e = $code.IndexOf('#>', $s + 2)
                        if ($e -ge 0) { $code = $code.Substring(0, $s) + ' ' + $code.Substring($e + 2) } else { $code = $code.Substring(0, $s); $inBlock = $true; break }
                    }
                }
                $sb = New-Object System.Text.StringBuilder
                $sq = $false
                $dq = $false
                $subDepth = 0
                $i = 0
                while ($i -lt $code.Length) {
                    $ch = $code[$i]
                    if ($sq) {
                        if ($ch -eq "'") {
                            if (($i + 1) -lt $code.Length -and $code[$i + 1] -eq "'") { $i += 2 } else { $sq = $false; $i++ }
                        } else { $i++ }
                        continue
                    }
                    if ($dq) {
                        if ($ch -eq '`' -and ($i + 1) -lt $code.Length) { $i += 2; continue }
                        # $() inside "..." EXECUTES at runtime: scan it as code.
                        if ($ch -eq '$' -and ($i + 1) -lt $code.Length -and $code[$i + 1] -eq '(') {
                            [void]$sb.Append('$(')
                            $i += 2
                            $subDepth++
                            continue
                        }
                        if ($subDepth -gt 0) {
                            [void]$sb.Append($ch)
                            if ($ch -eq '(') { $subDepth++ }
                            elseif ($ch -eq ')') { $subDepth-- }
                            $i++
                            continue
                        }
                        if ($ch -eq '"') {
                            if (($i + 1) -lt $code.Length -and $code[$i + 1] -eq '"') { $i += 2 } else { $dq = $false; $i++ }
                        } else { $i++ }
                        continue
                    }
                    if ($ch -eq '#') { break }
                    if ($ch -eq "'") { $sq = $true; $i++; continue }
                    if ($ch -eq '"') { $dq = $true; $i++; continue }
                    [void]$sb.Append($ch)
                    $i++
                }
                $out.Add($sb.ToString())
            }
            return ($out -join "`n")
        }

        function Get-CompatTargetFiles {
            [CmdletBinding()]
            [OutputType([object[]])]
            param()
            $dirs = @(
                (Join-Path $script:CompatBuildRoot 'Modules')
                (Join-Path $script:CompatBuildRoot 'Steps')
                (Join-Path $script:CompatBuildRoot 'Hooks')
            )
            $files = New-Object System.Collections.Generic.List[object]
            foreach ($d in $dirs) {
                if (-not (Test-Path -LiteralPath $d -PathType Container)) {
                    $script:CompatDiscoveryErrors.Add("missing root: $d")
                    continue
                }
                try {
                    $found = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction Stop | Where-Object {
                        $extension = $_.Extension.ToLowerInvariant()
                        return ($extension -eq '.ps1' -or $extension -eq '.psm1' -or $extension -eq '.psd1')
                    } | Sort-Object -Property FullName)
                    foreach ($f in $found) { $files.Add($f) }
                } catch {
                    $script:CompatDiscoveryErrors.Add("${d}: $($_.Exception.Message)")
                }
            }
            $entry = Join-Path $script:CompatBuildRoot 'gbuild.ps1'
            if (Test-Path -LiteralPath $entry -PathType Leaf) {
                $files.Add((Get-Item -LiteralPath $entry))
            } else {
                $script:CompatDiscoveryErrors.Add("missing entry: $entry")
            }
            return $files.ToArray()
        }

        $script:CompatFiles = @(Get-CompatTargetFiles | Where-Object { $_ -ne $null })
    }

    It 'discovers every nested shipped PowerShell file without Include filters' {
        $script:CompatDiscoveryErrors | Should -BeNullOrEmpty
        $script:CompatFiles.Count | Should -BeGreaterThan 80
        $script:CompatFiles.FullName | Should -Contain (Join-Path $script:CompatBuildRoot 'Modules/Plugins/helpers/PluginHelpers.psm1')
        $script:CompatFiles.FullName | Should -Contain (Join-Path $script:CompatBuildRoot 'Modules/Providers/AndroidSdkProvider.psm1')
        $script:CompatFiles.FullName | Should -Contain (Join-Path $script:CompatBuildRoot 'Steps/manage-githooks.ps1')
        $script:CompatFiles.FullName | Should -Contain (Join-Path $script:CompatBuildRoot 'Hooks/before-build/01-env-validation.ps1')
    }

    It 'uses recursive extension filtering in the entrypoint syntax check' {
        $entryText = Get-Content -LiteralPath (Join-Path $script:CompatBuildRoot 'gbuild.ps1') -Raw -Encoding UTF8
        $entryText | Should -Match 'Get-ChildItem\s+-LiteralPath'
        $entryText | Should -Match '-Recurse'
        $entryText | Should -Not -Match ('Get-ChildItem[^\r\n]*-' + 'Include')
    }

    It 'scans a non-empty file set (Modules + entry script + Steps + Hooks)' {
        $script:CompatFiles.Count | Should -BeGreaterThan 80
    }

    It 'no parenthesized (if ...) subexpression (5.1: term if not recognized)' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:CompatFiles) {
            $code = Get-CompatCodeText -Path $f.FullName
            $idx = 0
            foreach ($ln in ($code -split "`n")) {
                $idx++
                if ($ln -match '(?<![\$@])\(if\s') {
                    $bad.Add(('{0}:{1}: {2}' -f $f.Name, $idx, $ln.Trim()))
                }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'no null-conditional (?.) or null-coalescing (??) operators' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:CompatFiles) {
            $code = Get-CompatCodeText -Path $f.FullName
            $idx = 0
            foreach ($ln in ($code -split "`n")) {
                $idx++
                if ($ln -match '\?\?') { $bad.Add(('{0}:{1}: ??' -f $f.Name, $idx)) }
                elseif ($ln -match '(?<!\$)\?\.') { $bad.Add(('{0}:{1}: ?.' -f $f.Name, $idx)) }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'no ternary (? :) expressions' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:CompatFiles) {
            $code = Get-CompatCodeText -Path $f.FullName
            $idx = 0
            foreach ($ln in ($code -split "`n")) {
                $idx++
                $probe = $ln -replace '\$[A-Za-z_?][A-Za-z0-9_?]*', 'V'
                $probe = $probe -replace '\|\s*\?', '|'
                if ($probe -match '\?[^?.{]*:') {
                    $bad.Add(('{0}:{1}: {2}' -f $f.Name, $idx, $ln.Trim()))
                }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'no ForEach-Object -Parallel (PS7-only parameter)' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:CompatFiles) {
            $code = Get-CompatCodeText -Path $f.FullName
            $idx = 0
            foreach ($ln in ($code -split "`n")) {
                $idx++
                if ($ln -match 'ForEach-Object\s+-Parallel\b') { $bad.Add(('{0}:{1}' -f $f.Name, $idx)) }
                elseif ($ln -match '(?<![\w-])foreach\s+-Parallel\b') { $bad.Add(('{0}:{1}' -f $f.Name, $idx)) }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'no Join-Path call takes 3+ positional children (PS6-only arity)' {
        # Load-bearing, and a class the scan above could not see.
        #
        # Every check in this file up to here matches SYNTAX shapes (operators,
        # keywords). Windows PowerShell 5.1 has an equally fatal failure that is
        # not a syntax shape at all: a cmdlet PARAMETER or ARITY that does not
        # exist there. Both known instances were in
        # Modules/Providers/AndroidSdkProvider.psm1 and both are OS-gated ADB
        # path lookups, i.e. exactly the code the Windows 5.1 host reaches
        # first:
        #     Join-Path A (Join-Path B C) D          <- 3 positional children, 6+
        #     Join-Path -AdditionalChildPath C D     <- parameter added in 6.0
        # Under 5.1 both throw "A positional parameter cannot be found" at
        # RUNTIME, which is why 0 of the syntax rules above flagged them and
        # why the defect could sit in a tree that had a dedicated 5.1 gate.
        #
        # AST rather than regex: a regex cannot tell a 3-argument call from a
        # nested one without counting parens, and would fire on the fixed form.
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:CompatFiles) {
            $tokens = $null; $errs = $null
            try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) } catch { continue }
            if ($null -eq $ast) { continue }
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }, $true)) {
                $positional = @($c.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
                # Join-Path <Path> <ChildPath> is the 5.1 arity; -AdditionalChildPath
                # does not exist there at all and is covered by the -Parameter rule.
                if ($positional.Count -gt 2) {
                    $bad.Add(('{0}:{1} (Join-Path with {2} positional children)' -f $f.Name, $c.Extent.StartLineNumber, $positional.Count))
                }
                foreach ($p in $c.CommandElements) {
                    if ($p -is [System.Management.Automation.Language.CommandParameterAst] -and $p.ParameterName -eq 'AdditionalChildPath') {
                        $bad.Add(('{0}:{1} (Join-Path -AdditionalChildPath is PS6+)' -f $f.Name, $p.Extent.StartLineNumber))
                    }
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'Windows PowerShell 5.1 throws "A positional parameter cannot be found" at runtime for both shapes, and no syntax-only rule can see them'
    }

    It 'every shipped script containing non-ASCII bytes starts with a UTF-8 BOM' {
        # Proven 5.1-only fatality (pwsh 7 defaults to UTF-8, so it never trips
        # there): Windows PowerShell decodes a BOM-less script with the system
        # ANSI codepage (often windows-1252). A UTF-8 em-dash (E2 80 94) then
        # decodes to U+00E2 U+20AC U+201D - and U+201D is a DOUBLE QUOTE to the
        # PowerShell tokenizer, so a string literal like " - $($x)" is terminated
        # early and the parse explodes (Orchestrator.psm1:988 and Report.psm1:622
        # both died exactly this way: UnexpectedToken / Missing closing '}').
        # Byte-level check on purpose: it must hold regardless of the host
        # codepage running the test.
        $bad = New-Object System.Collections.Generic.List[string]
        $roots = @(
            (Join-Path $script:CompatBuildRoot 'Modules')
            (Join-Path $script:CompatBuildRoot 'Steps')
            (Join-Path $script:CompatBuildRoot 'Hooks')
            (Join-Path $script:CompatBuildRoot 'Tests')
        )
        foreach ($d in $roots) {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
            $files = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
                $e = $_.Extension.ToLowerInvariant()
                $e -eq '.ps1' -or $e -eq '.psm1' -or $e -eq '.psd1'
            })
            foreach ($f in $files) {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                $hasBom = ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                if ($hasBom) { continue }
                $nonAscii = 0
                foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++; break } }
                if ($nonAscii -gt 0) { $bad.Add($f.FullName) }
            }
        }
        # The entry scripts carry the same requirement.
        foreach ($entry in @('gbuild.ps1', 'Install-GBuild.ps1')) {
            $p = Join-Path $script:CompatBuildRoot $entry
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $hasBom = ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if ($hasBom) { continue }
            $nonAscii = 0
            foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++; break } }
            if ($nonAscii -gt 0) { $bad.Add($p) }
        }
        # NOTE: gbuild (bash) and gbuild.bat are DELIBERATELY excluded - a BOM
        # breaks the shebang line and cmd.exe respectively, even with non-ASCII
        # comment bytes in them.
        $bad | Should -BeNullOrEmpty
    }
}
