# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ModuleDependencies.psm1 - explicit module dependency declarations + validator.
# Each gbuild module already declares its dependencies inline via:
#   Import-BuildModule -Dependencies @(...) / Import-GBuildModule -Names @(...)
#   . (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @(...)
# This module makes that graph EXPLICIT and TESTABLE:
#   - Get-ModuleDependencyMap parses all Modules/*.psm1 (+ Providers/) and
#     returns module -> string[] dependencies (no hardcoded map to drift).
#   - Test-ModuleDependencies validates every declared dep exists as a file
#     and detects import cycles via DFS (fails CI on cycle or missing dep).
# Tier-0: zero external deps (pure filesystem + regex), safe standalone.


function Get-ModuleDependencyMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ModulesRoot = $PSScriptRoot
    )

Set-StrictMode -Version 1.0
    if (-not $ModulesRoot -or -not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) {
        $ModulesRoot = $PSScriptRoot
    }
    $map = @{}
    $files = @()
    # Scan the module root recursively so nested providers/plugins/helpers are
    # included, then pick up tool-root-level Core/Plugins layouts (_Sync).
    $files += @(Get-ChildItem -Path $ModulesRoot -Filter '*.psm1' -File -Recurse -ErrorAction SilentlyContinue)
    $toolRoot = Split-Path -Parent $ModulesRoot
    foreach ($sub in @('Core', 'Plugins')) {
        $dir = Join-Path $toolRoot $sub
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $files += @(Get-ChildItem -Path $dir -Filter '*.psm1' -File -Recurse -ErrorAction SilentlyContinue)
        }
    }
    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $deps = [System.Collections.Generic.List[string]]::new()
        $content = ''
        try { $content = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop } catch { $content = '' }
        if (-not $content) { $map[$name] = @(); continue }
        $addFrom = {
            param([string[]]$Names)
            foreach ($d in $Names) {
                if (-not $d) { continue }
                if ($d -in @('ModuleBootstrap', 'BuildImport')) { continue }
                if ($d -eq $name) { continue }
                if (-not $deps.Contains($d)) { $deps.Add($d) }
            }
        }
        # Import-shape discovery is AST-based, not regex-based.
        #
        # The previous implementation matched three patterns with a PowerShell
        # backtick-escaped `$` inside a DOUBLE-quoted string:
        #     "foreach\s*\(\s*`$dep\s+in\s+@\(([^)]*)\)"
        #     "Join-Path\s+`$PSScriptRoot\s+'Providers\\([^']+)\.psm1'"
        #     "Join-Path\s+`$PSScriptRoot\s+'([^'/\\]+)\.psm1'"
        # `` `$ `` escapes the PowerShell `$`, it does NOT emit the regex escape
        # `\$`. Each pattern therefore became `$PSScriptRoot` / `$dep` - a
        # regex END-OF-STRING anchor followed by literal text - which can never
        # match. Measured consequence: Orchestrator reported 23 dependencies
        # instead of 40 and AndroidSdkProvider reported 0 instead of 5, i.e.
        # NONE of the platform's core modules had its Orchestrator->core edge
        # validated, while the validator still reported Passed=True.
        #
        # Walking the AST for Import-Module / Join-Path / named parameters
        # removes the whole bug class: there is no escaping to get wrong, and a
        # newly written import form is either understood by the AST or loudly
        # absent - never silently half-matched.
        $ast = $null
        try {
            $parseErrs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$parseErrs)
        } catch { $ast = $null }
        if ($null -ne $ast) {
            $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            $stringAst = { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }
            # Every literal that looks like a module file name under a node.
            # Walking the subtree (instead of reading CommandElements) is what
            # makes the NESTED form work:
            #     Join-Path (Join-Path $PSScriptRoot 'Providers') 'X.psm1'
            # where the module name is two levels down from Import-Module.
            $moduleNameLiterals = {
                param($Node)
                $out = @()
                foreach ($str in $Node.FindAll($stringAst, $true)) {
                    if ($str.Value -match '^[A-Za-z0-9_\-]+\.psm1$') { $out += [System.IO.Path]::GetFileNameWithoutExtension($str.Value) }
                }
                return @($out)
            }
            # String literals inside an array-typed argument. Two shapes, and the second
            # one is the trap:
            #   @('A','B') -> ArrayExpressionAst wrapping an ArrayLiteralAst
            #   @('A')     -> ArrayExpressionAst wrapping a BARE string literal;
            #                  a one-element array needs no ArrayLiteralAst node
            # Handling only ArrayLiteralAst silently drops every single-element
            # dependency list, so -Dependencies @('SharedUtils') contributed
            # nothing while -Dependencies @('A','B') worked.
            #
            # Deliberately returns nothing for a node that is not an array at
            # all: the foreach rule below passes a whole Condition, and a blanket
            # "all string literals underneath" fallback read
            # `foreach ($pair in $imports.GetEnumerator())` as a dependency named
            # GetEnumerator.
            $arrayLiterals = {
                param($Node)
                $out = @()
                if ($null -eq $Node) { return @($out) }
                if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    foreach ($e in $Node.Elements) {
                        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out += $e.Value }
                    }
                    return @($out)
                }
                if ($Node -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return @($out) }
                $arrays = @($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true))
                foreach ($arr in $arrays) {
                    foreach ($e in $arr.Elements) {
                        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out += $e.Value }
                    }
                }
                if ($arrays.Count -eq 0) {
                    # Single-element @('A') has no ArrayLiteralAst node.
                    foreach ($str in $Node.FindAll($stringAst, $true)) {
                        # Member names are StringConstant nodes too:
                        # @($script:Tier1ModuleList.Core) carries a 'Core' string
                        # that is the MEMBER of a member expression, not a module
                        # name. Reading it as a module produced a phantom
                        # 'Orchestrator -> Core' edge.
                        $p = $null
                        try { $p = $str.Parent } catch { $p = $null }
                        if (($p -is [System.Management.Automation.Language.MemberExpressionAst]) -and ($p.Member -eq $str)) { continue }
                        $out += $str.Value
                    }
                }
                return @($out)
            }
            # Values bound to -Parameter on a command: a single literal string or
            # any array literal. Non-literal arguments are skipped, so a variable
            # can never be stringified into a fake module name.
            #
            # CommandParameterAst.ParameterName does NOT include the leading
            # dash ('-Dependencies' is exposed as 'Dependencies'), so both sides
            # are normalised. Comparing the raw dash form is silent: the loop
            # finds no parameter, returns an empty list, and the module reports
            # zero dependencies with no error anywhere.
            $readNames = {
                param($Command, [string]$Parameter)
                $want = $Parameter.TrimStart('-')
                $elems = @($Command.CommandElements)
                $out = @()
                for ($i = 0; $i -lt $elems.Count; $i++) {
                    if ($elems[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($elems[$i].ParameterName.TrimStart('-') -ne $want) { continue }
                    if (($i + 1) -ge $elems.Count) { continue }
                    $nxt = $elems[$i + 1]
                    if ($nxt -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out += $nxt.Value; continue }
                    $out += (& $arrayLiterals $nxt)
                }
                return @($out)
            }
            $hasImportIn = {
                param($Node)
                if ($null -eq $Node) { return $false }
                foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $n2 = $c.GetCommandName()
                    if ($n2 -eq 'Import-Module' -or $n2 -eq 'Import-BuildModule') { return $true }
                }
                return $false
            }

            # 1. Import-Module naming a module file, directly or through a nested
            #    Join-Path.
            foreach ($cmd in $commands) {
                if ($cmd.GetCommandName() -ne 'Import-Module') { continue }
                & $addFrom (& $moduleNameLiterals $cmd)
            }
            # 2. The gbuild bootstrap helpers and their named list parameters.
            $nameArgs = @{
                'Import-BuildModule'          = @('-Dependencies')
                'Import-GBuildModule'          = @('-Names', '-Dependencies')
                'Import-ModuleOnDemand'        = @('-ModuleNames')
                'Import-GBuildModuleIfMissing' = @('-Name')
            }
            foreach ($cmd in $commands) {
                $cmdName = $cmd.GetCommandName()
                # A dot-source has no command name; rule 3 handles it.
                if (-not $cmdName) { continue }
                if (-not $nameArgs.ContainsKey($cmdName)) { continue }
                foreach ($pname in $nameArgs[$cmdName]) {
                    & $addFrom (& $readNames $cmd $pname)
                }
            }
            # 3. Dot-sourced ModuleBootstrap.ps1 -Dependencies @(...). A dot-source
            #    is a CommandAst whose InvocationOperator is 'Dot' (there is no
            #    DotSourcesCommandAst type), so without this rule the 30 modules
            #    using that form report no dependency at all.
            foreach ($cmd in $commands) {
                if ($cmd.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot) { continue }
                & $addFrom (@(& $readNames $cmd '-Dependencies') + (& $moduleNameLiterals $cmd))
            }
            # 4. foreach ($dep in @('A','B')) { ... Import-Module ... } - the
            #    Orchestrator Tier-1 eager lists. Gated on the body ACTUALLY
            #    importing: an ungated foreach rule reads every string array in the
            #    file as a dependency list, which is how BuildConstants keys and
            #    redaction regexes got listed as missing modules.
            #
            #    The Condition is a PipelineAst, so the array node is searched for
            #    inside it; a non-array condition (e.g. $imports.GetEnumerator())
            #    contributes nothing.
            $arrayNode = { param($Node) if ($null -eq $Node) { return $null }
                if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) { return $Node }
                if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) { return $Node }
                return @($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true))[0] }
            # Tier-1 indirection expander. Orchestrator.psm1 no longer inlines the
            # 20-name list; it iterates @($script:Tier1ModuleList.Core) (and
            # .Providers) from the shared Modules/Tier1Modules.ps1 data file.
            # Expanding from that same file keeps the graph's 20 edges truthful
            # instead of dropping them (or misreading 'Core' as a module).
            $tier1Expand = {
                param([string]$Which)
                $expanded = @()
                try {
                    $dataFile = Join-Path $ModulesRoot 'Tier1Modules.ps1'
                    if (Test-Path -LiteralPath $dataFile -PathType Leaf) {
                        $list = & { . $dataFile; Get-Tier1ModuleList }
                        if ($list -and $list.$Which) { $expanded = @($list.$Which) }
                    }
                } catch { }
                return @($expanded)
            }
            foreach ($fe in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                if (-not (& $hasImportIn $fe.Body)) { continue }
                $condText = ''
                try { $condText = [string]$fe.Condition.Extent.Text } catch { $condText = '' }
                $tier1m = [regex]::Match($condText, 'Tier1ModuleList\s*\.\s*(Core|Providers)')
                if ($tier1m.Success) {
                    & $addFrom (& $tier1Expand $tier1m.Groups[1].Value)
                    continue
                }
                $node = & $arrayNode $fe.Condition
                if ($null -eq $node) { continue }
                & $addFrom (& $arrayLiterals $node)
            }
        }
        $map[$name] = $deps.ToArray()
    }
    return $map
}

function Test-ModuleDependencies {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ModulesRoot = $PSScriptRoot,
        [hashtable]$DependencyMap
    )
    if (-not $ModulesRoot -or -not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) {
        $ModulesRoot = $PSScriptRoot
    }
    if (-not $DependencyMap) {
        $DependencyMap = Get-ModuleDependencyMap -ModulesRoot $ModulesRoot
    }
    $missing = [System.Collections.ArrayList]@()
    # A dependency name may resolve to Modules/, Modules/Providers/,
    # Modules/Plugins/ or Modules/Plugins/helpers/ (the graph now includes the
    # whole Plugins tree, so resolution must too). Forward slashes only: see the
    # note on the map builder above -- this list is NOT walked recursively, so a
    # separator that does not resolve here produces a false "missing dependency".
    $searchDirs = @($ModulesRoot)
    foreach ($sub in @('Providers', 'Plugins', 'Plugins/helpers')) {
        $d = Join-Path $ModulesRoot $sub
        if (Test-Path -LiteralPath $d -PathType Container) { $searchDirs += $d }
    }
    foreach ($mod in $DependencyMap.Keys) {
        foreach ($dep in @($DependencyMap[$mod])) {
            $found = $false
            foreach ($dir in $searchDirs) {
                if (Test-Path -LiteralPath (Join-Path $dir ($dep + '.psm1')) -PathType Leaf) { $found = $true; break }
            }
            if (-not $found) {
                $missing.Add(([PSCustomObject]@{ Module = $mod; MissingDep = $dep })) | Out-Null
            }
        }
    }
    # Cycle detection via iterative DFS (white/gray/black).
    $cycles = [System.Collections.ArrayList]@()
    $color = @{}
    foreach ($k in $DependencyMap.Keys) { $color[$k] = 'white' }
    $stack = [System.Collections.Generic.List[string]]::new()
    function Enter-Node($node) {
        $color[$node] = 'gray'
        $stack.Add($node) | Out-Null
        foreach ($dep in @($DependencyMap[$node])) {
            if (-not $DependencyMap.ContainsKey($dep)) { continue }
            if ($color[$dep] -eq 'gray') {
                $idx = $stack.IndexOf($dep)
                $cycle = @($stack.GetRange($idx, ($stack.Count - $idx)) + @($dep)) -join ' -> '
                $cycles.Add($cycle) | Out-Null
            } elseif ($color[$dep] -eq 'white') {
                Enter-Node $dep
            }
        }
        $stack.RemoveAt($stack.Count - 1)
        $color[$node] = 'black'
    }
    foreach ($k in @($DependencyMap.Keys)) {
        if ($color[$k] -eq 'white') { Enter-Node $k }
    }
    $passed = ($missing.Count -eq 0 -and $cycles.Count -eq 0)
    return [PSCustomObject]@{
        Passed       = $passed
        Missing      = $missing.ToArray()
        Cycles       = $cycles.ToArray()
        ModuleCount  = $DependencyMap.Keys.Count
        Summary      = if ($passed) { "OK: $($DependencyMap.Keys.Count) modules, no missing deps, no cycles" } else { "FAIL: $($missing.Count) missing, $($cycles.Count) cycles" }
    }
}

Export-ModuleMember -Function @('Get-ModuleDependencyMap', 'Test-ModuleDependencies')
