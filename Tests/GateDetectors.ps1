# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Cache for Get-GateComputedDispatchNames, keyed by the path set it was built
# from. Declared here because this file runs under Set-StrictMode, where reading
# an unassigned script variable is a terminating error rather than $null.
$script:GateDispatchCache = $null

<#
.SYNOPSIS
    The enforcement detectors, extracted so a gate and its own self-test run the
    SAME code.
.DESCRIPTION
    WHY THIS FILE EXISTS

    Three of this repository's gates were, at the same time, green and blind:

      * Test-ModuleDependencies matched three import patterns with a
        backtick-escaped `$` inside a double-quoted string. `` `$ `` does not emit
        the regex escape `\$`, so each pattern became `$PSScriptRoot` / `$dep` - a
        regex END-OF-STRING anchor - and could never match. Orchestrator reported
        23 dependencies instead of 41; AndroidSdkProvider reported 0 instead of 5.
        The validator still returned Passed=True.

      * The dead-export gate cleared its "inside an Export-ModuleMember" flag only
        on a line containing nothing but ')'. The 38 files that write the whole
        statement on one line therefore captured zero exported names, so the gate
        was blind to 281 of 649 exported functions (43%) while reporting green.

      * The stringHashDelegation ratchet required UTF8.GetBytes to sit textually
        inside the ComputeHash call on one line. No site in this codebase is
        written that way, so the class measured 21/21 = 100% while two real
        duplicates shipped.

    All three failed the same way: a regex that quietly stopped matching, in a
    system whose entire quality argument rests on its gates. Nothing in the
    repository could tell a gate that works from a gate that no longer matches
    anything.

    The fix is not "write the regex more carefully" - it is to make the gate
    falsifiable. Every detector below has a fixture in
    Tests/GateSelfTest.Tests.ps1 that plants a known violation and asserts the
    detector REPORTS it. A detector that cannot fail on a fixture it is supposed
    to catch fails the build instead of passing it.

    THE THREE-WAY RULE, which is what makes this hold:

        every detector must have BOTH
            a positive fixture - a seeded violation it MUST flag
            a negative fixture - clean input it MUST stay silent on

    The negative case is not decoration. A detector that matches everything is
    "green" in exactly the same way a detector that matches nothing is green, and
    only the negative case tells them apart.

    CONTRACT
        * Dot-source this file. It defines functions; it must not execute gates.
        * No Pester dependency: this file is loaded by tests and by the meta-gate.
        * Every detector takes FILE PATHS and returns finding STRINGS. A finding
          is "FileName:reason", never a boolean - a detector that returns only a
          bool cannot be debugged when it misfires.
        * Every detector is registered in Get-GateDetectorManifest. The meta-gate
          requires that list and the function table to agree, so a detector
          cannot be added without also being proven.
#>

Set-StrictMode -Version 1.0

# ---------------------------------------------------------------------------
# Detector: scriptblock closures that reference unbound free variables
# ---------------------------------------------------------------------------

function Get-GateClosureFreeVariables {
    <#
.SYNOPSIS
        Every `$name` a GetNewClosure() scriptblock reads that the enclosing
        function never binds.
.DESCRIPTION
        THE BUG CLASS THIS EXISTS TO STOP

        A `$sb = { ... }.GetNewClosure()` captures variables that EXIST in the
        scope where GetNewClosure() runs. When the closure body reads a name the
        enclosing function never assigned, PowerShell does NOT throw - not even
        under `Set-StrictMode -Version 1.0`, because the closure executes in a
        fresh dynamic-module scope whose strict-mode "uninitialized variable"
        check is not inherited. The read silently yields $null.

        Three real defects in this repository were exactly that shape, and each
        one disabled a control rather than crashing:

          * `-Incremental`  - the Build step passed `-Incremental:$Incremental`
            to the plugin cache, but the variable was never bound. The plugin
            cache short-circuit was permanently off.
          * `-GitHub`       - passed to Show-GuildMenu, never bound, always $false.
          * `-Target` / `-Distributed` / `-Security` - declared as parameters of
            Get-BuiltInPipelineSteps, but the only call site omitted them, so the
            `elseif (-not [string]::IsNullOrWhiteSpace($Target))` arm was
            unreachable and `gbuild -Target <id>` built a different target.
          * `$cfg`         - a local of the *Preflight* step read by the
            *AffectedScan* and *PolicyCheck* steps. Unbound in their scope, so
            `security.policy.enforcement = "block"` never threw and policy
            violations shipped green.

        A crash would have been survivable. A silent $null that disables a
        security gate is not, so this is checked with the AST rather than a
        regex: the enclosing function's assigned names are collected, and every
        variable read by each `.GetNewClosure()` scriptblock that is not in
        that set, not a parameter, and not a pipeline/automatic variable is
        reported.

        PS 5.1-parseable. No `?.`, no `??`, no ternary.
.PARAMETER Path
        Source file to analyse.
.PARAMETER FunctionName
        Restrict the analysis to one function (default: every function that
        contains a GetNewClosure() call).
.PARAMETER KnownExternal
        Names the file binds OUTSIDE the analysed function (module-level
        `$script:`/`$global:` aliases, or `$using:`-style host variables). These
        are accepted, not reported.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string]$FunctionName = '',
        [string[]]$KnownExternal = @()
    )
    $out = @()
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (-not $ast) { return @() }

    # Variables PowerShell provides to every scope. A closure reading one of
    # these is never an unbound-closure bug.
    $automatic = @(
        '_', 'args', 'input', 'this', 'null', 'true', 'false', 'error', 'host',
        'PSItem', 'PSCmdlet', 'PSBoundParameters', 'PSScriptRoot', 'PSCommandPath',
        'MyInvocation', 'PSVersionTable', 'PSHOME', 'PID', 'HOME', 'PWD', 'LASTEXITCODE',
        'ErrorActionPreference', 'ExecutionContext', 'ConsoleFileName', 'Matches', 'LASTEXITCODE',
        'StackTrace', 'ErrorDetails', 'OFS', 'PSDefaultParameterValues', 'PSNativeCommandUseErrorActionPreference'
    )

    # A name binds the ENCLOSING FUNCTION's scope only if it is assigned in that
    # function's own body - NOT inside a nested scriptblock. `$cfg = ...` written
    # inside the Preflight step binds Preflight's body; the PolicyCheck step is a
    # different scope and reading $cfg there is unbound. This distinction IS the
    # bug class, so the scope walk is the whole detector.
    $isOwnScope = {
        param($node, $owner)
        $p = $node.Parent
        while ($null -ne $p) {
            if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $false }
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return ($p -eq $owner) }
            if ($p -eq $owner) { return $true }
            $p = $p.Parent
        }
        return $true
    }

    $functions = @()
    if ($FunctionName) {
        $functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true))
    } else {
        $functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    }

    foreach ($fn in $functions) {
        # Every variable this function ASSIGNS or declares as a parameter is
        # legitimately readable from a closure defined inside it.
        $bound = New-Object System.Collections.Generic.HashSet[string]
        foreach ($a in $KnownExternal) { [void]$bound.Add([string]$a) }
        foreach ($a in $automatic) { [void]$bound.Add($a) }
        if ($fn.Body.ParamBlock) {
            foreach ($p in $fn.Body.ParamBlock.Parameters) {
                $pv = $p.Name.VariablePath.UserPath
                if ($pv) { [void]$bound.Add($pv) }
            }
        }
        foreach ($va in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if (-not (& $isOwnScope $va $fn)) { continue }
            $lv = $va.Left
            if ($lv -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $n2 = $lv.VariablePath.UserPath
                if ($n2) { [void]$bound.Add($n2) }
            } elseif ($lv -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                $inner = $lv.Child
                if ($inner -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $n3 = $inner.VariablePath.UserPath
                    if ($n3) { [void]$bound.Add($n3) }
                }
            }
        }
        # Compound assignment ($x += ...) and increment (++) also create the
        # variable. Same own-scope requirement.
        foreach ($ca in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.UnaryExpressionAst] }, $true)) {
            if (-not (& $isOwnScope $ca $fn)) { continue }
            $t = $ca.Child
            if ($t -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $n4 = $t.VariablePath.UserPath
                if ($n4) { [void]$bound.Add($n4) }
            }
        }
        # Foreach / For / While enumerators and catch variables also create.
        foreach ($fe in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if (-not (& $isOwnScope $fe.Variable $fn)) { continue }
            $n5 = $fe.Variable.VariablePath.UserPath
            if ($n5) { [void]$bound.Add($n5) }
        }
        foreach ($ce in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)) {
            if ($ce.CatchTypes) { }
            $n6 = $ce.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsVariable }, $true)
            foreach ($x in $n6) { if ($x.VariablePath.UserPath -eq '_') { [void]$bound.Add('_') } }
        }

        # Every scriptblock in this function that is later wrapped by
        # `.GetNewClosure()`.
        $closureTargets = @()
        foreach ($inv in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($inv.Member.Value -ne 'GetNewClosure') { continue }
            $target = $inv.Expression
            if ($target -is [System.Management.Automation.Language.ParenExpressionAst]) { $target = $target.Pipeline }
            $bodyAst = $null
            if ($target -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $bodyAst = $target.ScriptBlock }
            elseif ($target -is [System.Management.Automation.Language.PipelineAst]) {
                $he = $target.PipelineElements | Select-Object -First 1
                if ($he -is [System.Management.Automation.Language.CommandExpressionAst] -and $he.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $bodyAst = $he.Expression.ScriptBlock
                }
            }
            if ($bodyAst) { $closureTargets += $bodyAst }
        }

        foreach ($sb in $closureTargets) {
            # Reads = variable expressions that are NOT the target of an assignment
            # and NOT a parameter default binding inside this scriptblock.
            $readNames = @{}
            $assignedHere = @{}
            foreach ($asg in $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $l = $asg.Left
                if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { $assignedHere[$l.VariablePath.UserPath] = $true }
            }
            # The closure's OWN param() block binds names at invocation time.
            # `$ctx` in a rollback action, `$match` in a regex evaluator and
            # `$storeName`/`$keyName` in a keytool invoker are all supplied by
            # the CALLER, not captured - reporting them would make the detector
            # cry wolf on every legitimate closure.
            if ($sb.ParamBlock) {
                foreach ($p in $sb.ParamBlock.Parameters) {
                    $pv2 = $p.Name.VariablePath.UserPath
                    if ($pv2) { $assignedHere[$pv2] = $true }
                }
            }
            foreach ($ve in $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $vp = $ve.VariablePath
                if (-not $vp.IsVariable) { continue }   # $env:X, $global:X, $using:X
                # A SCOPED variable is not a closure capture. `$script:x` parses
                # with IsVariable=True and an EMPTY Scope - the qualifier lives in
                # the NAME ("script:x"), which is why the Scope check alone is not
                # enough and the name has to be tested too. None of these resolve
                # against the enclosing function's locals, so reporting them would
                # be a false positive on every legitimate closure.
                if ($vp.Scope) { continue }
                $nm = $vp.UserPath
                if (-not $nm) { continue }
                if ($nm -match '^(?i)(script|global|local|private|using):') { continue }
                if ($vp.DriveName) { continue }
                if ($assignedHere.ContainsKey($nm)) { continue }
                $readNames[$nm] = $ve.Extent.StartLineNumber
            }
            foreach ($nm in $readNames.Keys) {
                if ($bound.Contains($nm)) { continue }
                $out += [PSCustomObject]@{
                    File         = [System.IO.Path]::GetFileName($Path)
                    Function     = $fn.Name
                    Variable     = $nm
                    Line         = $readNames[$nm]
                }
            }
        }
    }
    return @($out)
}

function Find-GateUnboundClosureVars {
    <#
.SYNOPSIS
        Repo-wide wrapper over Get-GateClosureFreeVariables.
.DESCRIPTION
        Returns one "File:Function:$var (line N)" record per unbound closure
        read. A caller that wants to allowlist a site supplies -Exempt with
        "File::Function::Var" keys.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [hashtable]$Exempt = @{}
    )
    $findings = @()
    foreach ($p in $Paths) {
        $name = [System.IO.Path]::GetFileName($p)
        $rows = @()
        try { $rows = @(Get-GateClosureFreeVariables -Path $p) } catch { $rows = @() }
        foreach ($r in $rows) {
            $key = '{0}::{1}::{2}' -f $name, $r.Function, $r.Variable
            if ($Exempt.ContainsKey($key)) { continue }
            $findings += ('{0}:{1}: unbound closure variable ${2} (line {3})' -f $name, $r.Function, $r.Variable, $r.Line)
        }
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

function Get-GateDetectorManifest {
    <#
    .SYNOPSIS
        Every detector this repository enforces, with the reason it exists.
    .DESCRIPTION
        The manifest is the anti-drift mechanism: Tests/GateSelfTest.Tests.ps1
        iterates it to prove each detector can fail, and the meta-gate fails when
        a detector exists here but has no manifest entry (or the reverse). A
        detector nobody registered is a detector nobody tested.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    return @(
        @{ Name = 'Find-GateInlineWin32NT';       SelfTested = $true;  Gate = 'Hygiene: OS branching goes through Get-OSPlatform' }
        @{ Name = 'Find-GatePathLiterals';        SelfTested = $true;  Gate = 'Hygiene: repository-path literals are platform-neutral' }
        @{ Name = 'Find-GateAtomicTextWrites';    SelfTested = $true;  Gate = 'Hygiene: one atomic-append / file-lock implementation' }
        @{ Name = 'Find-GateFileLockLoops';       SelfTested = $true;  Gate = 'Hygiene: one atomic-append / file-lock implementation' }
        @{ Name = 'Find-GateEvtStringLiterals';   SelfTested = $true;  Gate = 'Hygiene: the event-name registry is authoritative' }
        @{ Name = 'Find-GateContainmentWalks';    SelfTested = $true;  Gate = 'Hygiene: OS branching goes through Get-OSPlatform' }
        @{ Name = 'Get-GateExportStatements';     SelfTested = $true;  Gate = 'Hygiene: no dead exported functions' }
        @{ Name = 'Get-GateExportedNames';        SelfTested = $true;  Gate = 'Hygiene: no dead exported functions / removed duplicate surface' }
        @{ Name = 'Get-GateIgnoredReferenceLines';SelfTested = $true;  Gate = 'Hygiene: no dead exported functions' }
        @{ Name = 'Get-GateFunctionDefinitions';  SelfTested = $true;  Gate = 'Hygiene: no dead exported functions' }
        @{ Name = 'Get-GateCodeWithoutComments';  SelfTested = $true;  Gate = 'Hygiene: path literals / source-exclusion pattern' }
        @{ Name = 'Find-GateCrossModuleUnexportedCalls'; SelfTested = $true;  Gate = 'Hygiene: a cross-module Get-Command target must be exported by someone' }
        @{ Name = 'Find-GateNonGlobalForceImports';     SelfTested = $true;  Gate = 'ModuleHygiene: -Force imports of shared modules must be -Global' }
        @{ Name = 'Get-GateClosureFreeVariables';       SelfTested = $true;  Gate = 'Hygiene: a GetNewClosure() body may only read variables its function binds' }
        @{ Name = 'Find-GateUnboundClosureVars';        SelfTested = $true;  Gate = 'Hygiene: a GetNewClosure() body may only read variables its function binds' }
    )
}

function Get-GateDetectorHelpers {
    <#
    .SYNOPSIS
        Support functions that are NOT detectors and need no violation fixture.
    .DESCRIPTION
        Distinguished from detectors so the meta-gate can demand "every DETECTOR
        is proven" without also demanding a fixture for plumbing like
        Get-GateSourceText. Both lists are explicit: a new function is either a
        detector with a proof, or a declared helper. Nothing is silently exempt,
        because a silently-exempt function is exactly how a real detector stops
        being checked.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        'Get-GateDetectorManifest'
        'Get-GateDetectorHelpers'
        'Get-GateSourceText'
        'Get-GatePathDetectorPatterns'
        'Get-GateReferenceCount'
        'Get-GateModuleSymbolTables'
        'Get-GateClosureFreeVariables'
        'Get-GateComputedDispatchNames'
    )
}

# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

# Memo for Get-GateReferenceCount. Declared once, here, so the variable exists
# before any detector runs (a missing $script: var under StrictMode is itself a
# hard error, and this file is dot-sourced into Pester blocks).
$script:GateLineCache = @{}

function Get-GateSourceText {
    <#
    .SYNOPSIS
        Raw file text, or '' when unreadable. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try { return [string](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) } catch { return '' }
}

function Get-GateCodeWithoutComments {
    <#
    .SYNOPSIS
        File text with every comment removed, preserving line structure.
    .DESCRIPTION
        Block comments are BLANKED rather than deleted so line numbers and brace
        matching survive. Both whole-line and trailing comments are removed.
        Essential, and easy to get wrong in a way that hides bugs: a structural
        gate that greps source text will otherwise match the explanatory comment
        attached to the very fix it is enforcing, and every corrected site then
        trips its own gate - which is how gates get switched off.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-GateSourceText -Path $Path
    if (-not $raw) { return '' }
    $text = [regex]::Replace($raw, '(?s)<#.*?#>', { param($m) ($m.Value -replace '[^\r\n]', ' ') })
    $text = [regex]::Replace($text, '(?m)^[ \t]*#.*$', '')
    # [ \t]+ not \s+ : \s matches newlines, so a \s-prefixed strip silently EATS
    # line breaks and shifts every subsequent line number.
    # (?m) IS REQUIRED here. Without it $ anchors to the end of the STRING, so a
    # mid-file trailing comment is never stripped at all - which is how the
    # inherited version of this line had been leaving `# trailing` in the text it
    # claimed to have cleaned.
    $text = [regex]::Replace($text, '(?m)[ \t]+#(?![{]).*$', '')
    return $text
}

# ---------------------------------------------------------------------------
# Detector: inline OS branching
# ---------------------------------------------------------------------------

function Find-GateInlineWin32NT {
    <#
    .SYNOPSIS
        Files that branch on the OS inline instead of via the shared accessor.
    .DESCRIPTION
        [System.PlatformID]::Win32NT must appear only in the documented resolvers
        that have to answer before PathUtils is importable. Anywhere else it is a
        second, drifting implementation of "am I on Windows".
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Allowed = @()
    )
    $findings = @()
    foreach ($p in $Paths) {
        $name = [System.IO.Path]::GetFileName($p)
        if ($Allowed -contains $name) { continue }
        $raw = Get-GateSourceText -Path $p
        if (-not $raw) { continue }
        # A module that DEFINES the resolver is allowed to name the platform.
        if ($raw -match 'function\s+Get-OSPlatform') { continue }
        # Comments are stripped before counting: the explanatory comment attached
        # to a fix mentions the very token the gate searches for, and a gate that
        # matches its own documentation is a gate that gets switched off.
        $text = Get-GateCodeWithoutComments -Path $p
        if (-not $text) { continue }
        $count = ([regex]::Matches($text, 'PlatformID\]::Win32NT')).Count
        if ($count -gt 0) { $findings += ('{0} x{1}' -f $name, $count) }
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Detector: platform-hostile path literals
# ---------------------------------------------------------------------------

function Get-GatePathDetectorPatterns {
    <#
    .SYNOPSIS
        The path-construction and path-assertion regexes, read from their owner.
    .DESCRIPTION
        Read from the SINGLE owner, BuildConstants.Get-BuildPathLiteralPatterns -
        the same function Modules/ProcessMetrics.psm1 reads. They were two
        hand-maintained copies and they drifted: the gate tightened its token, the
        metric kept the old one, and the ratchet then reported 100% while the gate
        itself would have failed the build. A metric and its gate must never
        disagree, least of all on a green build.

        Assembled from variables rather than written inline: written inline the
        pattern contains a single quote (from the character class), which
        terminates the surrounding PowerShell string and the whole caller fails to
        PARSE.

        Two constraints in the token are load-bearing, both learned the hard way:

        * The quote character must NOT be in the class. If it is, `$token`
          swallows the closing quote and the pattern matches a plain
          `Join-Path $root 'Foo.psm1'` - i.e. every path in the repository.
        * At least ONE separator is required (`+`, not `*`). With `*` a path with
          no backslash at all matches, which is correct code.

        So the construction pattern accepts any number of separator-separated
        segments but requires at least one:

            'Modules\Sub\File.psm1'      caught   (1, 2 and 3 segment forms)
            'Foo.psm1'                   not caught

        and must NOT catch either of these, because both are correct code:

            -replace '\\', '/'           a REGEX escape, not a path separator
            '[\w\/]'                      a character class, not a path
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Read from the SINGLE owner, BuildConstants.Get-BuildPathLiteralPatterns -
    # the same function Modules/ProcessMetrics.psm1 reads. They were two
    # hand-maintained copies and they drifted: the gate tightened its token, the
    # metric kept the old one, and the ratchet then reported 100% while the gate
    # itself would have failed the build. A metric and its gate must never
    # disagree, least of all on a green build.
    if (-not (Get-Command Get-BuildPathLiteralPatterns -ErrorAction SilentlyContinue)) {
        $bcPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/BuildConstants.psm1'
        if (Test-Path -LiteralPath $bcPath -PathType Leaf) {
            $null = Import-Module $bcPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    if (Get-Command Get-BuildPathLiteralPatterns -ErrorAction SilentlyContinue) {
        try { return Get-BuildPathLiteralPatterns } catch { }
    }
    # Standalone fallback for when BuildConstants is unreachable. Byte-identical
    # to the owner on purpose: two DIFFERENT fallbacks would reintroduce exactly
    # the drift this function exists to remove.
    $token = "[\w\-\/:.~%+,@# ]+"
    return @{
        Token      = $token
        Construct  = "(?:Join-Path|Import-Module)[^\r\n]*?'$token(?:\\$token)+'"
        Assert     = "-BeLike\s+'\*[^']*\\[^']*'"
    }
}

function Test-GatePathLiteralExempt {
    <#
    .SYNOPSIS
        Whether a line matches a PATTERN-scoped exemption entry.
    .DESCRIPTION
        The exemption names the exact offending fragment, so a DIFFERENT
        backslash added to the same file is still caught. A file-scoped list
        would silently exempt every future violation in that file - a suppression
        wearing a name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Line,
        [object[]]$Exemptions = @()
    )
    foreach ($e in @($Exemptions)) {
        if ([string]$e.file -ne $FileName) { continue }
        if ($Line.Contains([string]$e.pattern)) { return $true }
    }
    return $false
}

function Find-GatePathLiterals {
    <#
    .SYNOPSIS
        Lines that build or assert a repository path using a backslash separator.
    .DESCRIPTION
        Backslash-as-separator is the single most common way a PowerShell build
        tool silently stops working on Linux and macOS. Production code currently
        has zero, but that is a MEASUREMENT, not a guarantee - so this detector
        must keep working or the guarantee lapses unnoticed.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [object[]]$Exemptions = @()
    )
    $p = Get-GatePathDetectorPatterns
    $findings = @()
    foreach ($path in $Paths) {
        $name = [System.IO.Path]::GetFileName($path)
        # Two things are load-bearing on this line.
        #
        # The parentheses: `f -split x` binds -split as a PARAMETER NAME and
        # fails, silently collapsing every fixture to a single line.
        #
        # The \r?\n and NOT "`r?`n": comment stripping removes the \r of a CRLF
        # pair - in multiline mode `$` matches before \n, so `.*` swallows the \r
        # - which leaves a stripped CRLF file all-LF. Splitting on a literal
        # CR/LF pair then finds almost no boundaries and every reported line
        # number is wrong. One 1148-line file measured 1005 that way, putting
        # this detector's findings 143 lines off.
        $lines = @((Get-GateCodeWithoutComments -Path $path) -split "\r?\n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if (-not $line) { continue }
            if (Test-GatePathLiteralExempt -FileName $name -Line $line -Exemptions $Exemptions) { continue }
            if ($line -match $p.Construct -or $line -match $p.Assert) {
                $findings += ('{0}:{1}' -f $name, ($i + 1))
            }
        }
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Detector: hand-rolled atomic text write
# ---------------------------------------------------------------------------

function Find-GateAtomicTextWrites {
    <#
    .SYNOPSIS
        Modules that hand-roll the atomic text write instead of delegating.
    .DESCRIPTION
        The fingerprint is the PAIR (File.Replace + a guid temp name). Either
        alone is legitimate - a guid is used for many things, and File.Replace
        appears in blob movers - so requiring both is what keeps the false
        positives down while still catching the real duplication.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Exempt = @()
    )
    $findings = @()
    foreach ($path in $Paths) {
        $name = [System.IO.Path]::GetFileName($path)
        if ($Exempt -contains $name) { continue }
        $text = Get-GateCodeWithoutComments -Path $path
        if (-not $text) { continue }
        if ($text -notmatch 'File\]::Replace') { continue }
        if ($text -notmatch 'guid\]::NewGuid') { continue }
        if ($text -match 'Write-BuildTextFileAtomic|Write-BuildJsonFile') { continue }
        $findings += $name
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Detector: independent file-lock loops
# ---------------------------------------------------------------------------

function Find-GateFileLockLoops {
    <#
    .SYNOPSIS
        Modules that open a lock FileStream themselves.
    .DESCRIPTION
        Only SharedUtils may construct a FileStream with FileShare.None. Every
        other module must call Enter-BuildFileLock, which pre-checks the timeout
        BEFORE the first attempt; a private open/poll/sleep loop evaluates the
        timeout only after a failed try, so a contended lock blocks for a full
        poll interval past its budget.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Exempt = @()
    )
    $findings = @()
    foreach ($path in $Paths) {
        $name = [System.IO.Path]::GetFileName($path)
        if ($Exempt -contains $name) { continue }
        $text = Get-GateCodeWithoutComments -Path $path
        if (-not $text) { continue }
        if ($text -match 'FileShare\]::None') { $findings += $name }
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Detector: event names published as string literals
# ---------------------------------------------------------------------------

function Find-GateEvtStringLiterals {
    <#
.SYNOPSIS
        Quoted EVT_* names passed to a publish call instead of the constant.
.DESCRIPTION
        Anchored to the PUBLISH CALL, not to the bare token. A quoted EVT_ name
        also appears in handler maps, subscriber lists and lookups, and those are
        not violations. The earlier unanchored form flagged AnomalyDetector for
        two legitimate references - a gate that cries wolf on a green build gets
        ignored, and an ignored gate is worse than none.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Exempt = @()
    )
    $findings = @()
    $rx = [regex]'(?:-EventName\s+|Add-BuildEvent\s+|Send-BuildEvent\s+)''EVT_[A-Z0-9_]+'''
    foreach ($path in $Paths) {
        $name = [System.IO.Path]::GetFileName($path)
        if ($Exempt -contains $name) { continue }
        $text = Get-GateCodeWithoutComments -Path $path
        if (-not $text) { continue }
        $count = $rx.Matches($text).Count
        if ($count -gt 0) { $findings += ('{0} x{1}' -f $name, $count) }
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# Detector: private containment + reparse walks
# ---------------------------------------------------------------------------

function Find-GateContainmentWalks {
    <#
    .SYNOPSIS
        Modules that implement their own "is this path inside the root" walk.
    .DESCRIPTION
        PathUtils.Test-PathUnderRoots and Test-NoReparsePointInPath are the single
        source. A private copy is not a style issue: the historical copies drifted
        by stopping the reparse walk BEFORE the volume root, so a SUBST drive or a
        mapped network share passed a check that was supposed to stop it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Exempt = @()
    )
    $findings = @()
    foreach ($path in $Paths) {
        $name = [System.IO.Path]::GetFileName($path)
        if ($Exempt -contains $name) { continue }
        $text = Get-GateCodeWithoutComments -Path $path
        if (-not $text) { continue }

        # 1. Match on the ENUM MEMBER `FileAttributes]::ReparsePoint`, never the
        #    bare word `ReparsePoint`. The shared helper is named
        #    Test-NoReparsePointInPath, so a bare-word match flags every CORRECT
        #    delegation - which is how this detector's first version reported
        #    Cache.psm1, DeployTargets.psm1 and three steps that all simply call
        #    the helper.
        if ($text -notmatch 'FileAttributes\]::ReparsePoint') { continue }

        # 2. Require the upward climb. A single-item "is this a symlink?" probe is
        #    a different question, answered by Test-ReparsePointItem. A WALK is
        #    what climbs to the volume root via GetPathRoot; without this the
        #    detector flagged every incidental reparse mention.
        if ($text -notmatch 'GetPathRoot|\.Parent\b') { continue }

        # 3. Delegation to either shared guard is the correct form.
        if ($text -match 'Test-NoReparsePointInPath|Test-PathUnderRoots|Test-ReparsePointItem') { continue }

        $findings += $name
    }
    return @($findings)
}

# ---------------------------------------------------------------------------
# AST helpers: export statements, definitions, reference counting
# ---------------------------------------------------------------------------

function Get-GateExportStatements {
    <#
    .SYNOPSIS
        Every Export-ModuleMember statement in a file, with its exact extent.
    .DESCRIPTION
        AST-based on purpose. The line-scanner this replaced set a flag on the
        opening line and cleared it only on a line containing nothing but ')',
        which meant the 38 single-line `Export-ModuleMember -Function @('A','B')`
        files captured nothing AND left the flag stuck true to EOF. There is no
        DotSourcesCommandAst type - a dot-source is a CommandAst whose
        InvocationOperator is Dot - which is worth recording because getting it
        wrong is silent too.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    $out = @()
    try {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
        if ($null -eq $ast) { return @() }
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($cmd.GetCommandName() -ne 'Export-ModuleMember') { continue }
            $out += [PSCustomObject]@{
                Start = $cmd.Extent.StartLineNumber
                End   = $cmd.Extent.EndLineNumber
                Text  = $cmd.Extent.Text
            }
        }
    } catch { }
    return @($out)
}

function Get-GateExportedNames {
    <#
    .SYNOPSIS
        Every name listed by a file's Export-ModuleMember statements.
    .DESCRIPTION
        Quote-style agnostic on purpose. The single-quote-only version of this
        helper was blind to Modules/Orchestrator.psm1, which exports all 33 of its
        names DOUBLE-quoted: a dead export there was invisible to the very gate
        meant to catch it, while the same name single-quoted elsewhere was caught.
        That asymmetry is the worst failure mode a detector can have - it looks
        like coverage.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $names = @()
    # Built from parts so no quoting convention has to be escaped by hand.
    $sq = [regex]::Escape("'") + '([A-Za-z][A-Za-z0-9_\-]*)' + [regex]::Escape("'")
    $dq = [regex]::Escape('"') + '([A-Za-z][A-Za-z0-9_\-]*)' + [regex]::Escape('"')
    $pattern = $sq + '|' + $dq
    foreach ($stmt in @(Get-GateExportStatements -Path $Path)) {
        foreach ($m in [regex]::Matches($stmt.Text, $pattern)) {
            if ($m.Groups[1].Success) { $names += $m.Groups[1].Value } else { $names += $m.Groups[2].Value }
        }
    }
    return @($names)
}

function Get-GateFunctionDefinitions {
    <#
    .SYNOPSIS
        Top-level function definitions in a file, with line numbers.
    .DESCRIPTION
        AST-based, because the line regex this replaced matched only
        `function Name {`. That silently missed `function global:Name {` and
        `function Name($a) {`, which are legal PowerShell and are exactly the
        forms a reintroduced duplicate would take - the gate was blind in the
        direction that mattered. Reading FunctionDefinitionAst.Name covers every
        spelling, and the AST is already parsed by Get-GateExportStatements.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    $out = @()
    $tokens = $null
    $errors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    } catch {
        # Unparseable file: fall back to the line scan so a syntax error is
        # reported as a parse failure elsewhere rather than as "no functions".
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ([string]$lines[$i] -match '^\s*function\s+(?:global:)?([A-Za-z][A-Za-z0-9_\-]*)\s*[\{\(]') {
                $out += [PSCustomObject]@{ Name = $Matches[1]; Line = ($i + 1) }
            }
        }
        return @($out)
    }
    # Top-level only: a FunctionDefinitionAst nested inside another function is
    # a closure, not a module-surface definition. The line regex this replaced
    # counted those closures as module functions (9 of them in this repository).
    # For `function global:Name {` the AST's Name carries the scope prefix, so it
    # is stripped or the name would never match an Export-ModuleMember entry.
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        $name = [string]$f.Name
        if ($name -match '^(?:global|script|private):(.+)$') { $name = $Matches[1] }
        $out += [PSCustomObject]@{ Name = $name; Line = $f.Extent.StartLineNumber }
    }
    return @($out | Sort-Object Line)
}

function Get-GateIgnoredReferenceLines {
    <#
    .SYNOPSIS
        Line numbers that must NOT count as a real reference to a function.
    .DESCRIPTION
        - the `function X {` definition line itself
        - every line inside an Export-ModuleMember statement (AST extent)
        - every whole-line comment, and every line inside a block comment

        Load-bearing, not cosmetic: two dead exported functions once survived the
        dead-export gate for months purely because each was named in the OTHER
        function's doc comment. A gate that counts prose as a call site is not a
        gate.

        COMMENT LINES COME FROM THE AST, NOT FROM TEXT SCANNING. The previous
        implementation tracked the block-comment open and close markers with a
        boolean over raw lines. That cannot tell a real opener from the same
        characters inside a string or a regex, and one unbalanced occurrence
        silently opens a comment that never closes: PathUtils.psm1 has 22 open
        markers and 21 close markers once such a literal is counted, so 271
        lines of that module - real code, including the call sites the gate
        exists to find - were being ignored as if they were prose. Across the
        production tree that silently discarded several thousand lines of
        executable code, which is the opposite failure from the one this gate
        was hardened against.

        Parser tokens cannot have that bug: an opener inside a string is part of
        a String token, and every Comment token reports its true line span.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Paths)
    $map = @{}
    foreach ($p in $Paths) {
        $set = [System.Collections.Generic.HashSet[int]]::new()

        # 1. comment lines, straight from the tokenizer
        $tk = $null; $errs = $null
        try { $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tk, [ref]$errs) } catch { $tk = $null }
        if ($tk) {
            foreach ($t in $tk) {
                if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
                for ($n = $t.Extent.StartLineNumber; $n -le $t.Extent.EndLineNumber; $n++) { [void]$set.Add($n) }
            }
        }

        # 2. the `function X {` definition line itself - but ONLY the definition part.
        # A single-line function (function X { ...body... }) carries real call
        # sites on its definition line. Ignoring the whole line hid every call
        # made from a one-line wrapper: Write-VisualBox is called by
        # Write-StepTitle and Write-SectionBox, both defined as one line, so it
        # read as having zero production references. Ignore the line only when
        # nothing follows the opening brace.
        $raw = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)
        foreach ($d in @(Get-GateFunctionDefinitions -Path $p)) {
            $ln = $d.Line
            if ($ln -lt 1 -or $ln -gt $raw.Count) { continue }
            $txt = [string]$raw[$ln - 1]
            $brace = $txt.IndexOf('{')
            if ($brace -lt 0) { [void]$set.Add($ln); continue }
            $tail = $txt.Substring($brace + 1).Trim()
            # An empty body is the signature alone. `$tail -eq ''` was the old
            # test and it missed the single most common shape there is:
            #     function Get-Solo { }
            # whose tail is "}", not "". Such a line therefore stayed COUNTED,
            # so every `function X { }` definition scored one phantom reference
            # to its own name - which is exactly the "counting prose/defining as
            # a call site" blindness this gate was rebuilt to end.
            #
            # Matching only closing braces keeps the one-line-wrapper exemption
            # intact: `function Write-VisualBox { Write-StepTitle }` has a real
            # body after the brace, so its line is still scanned and the call
            # site on it is still counted.
            if ($tail -eq '' -or $tail -match '^\}+$') { [void]$set.Add($ln) }
        }

        # 3. every line inside an Export-ModuleMember statement
        foreach ($stmt in @(Get-GateExportStatements -Path $p)) {
            for ($n = $stmt.Start; $n -le $stmt.End; $n++) { [void]$set.Add($n) }
        }
        $map[$p] = $set
    }
    return $map
}

function Get-GateModuleSymbolTables {
    <#
    .SYNOPSIS
        For every module file: which function names it DEFINES and which it EXPORTS.
    .DESCRIPTION
        Definitions come from a line scan that tolerates `function global:Name`
        and `function Name($a) {`; exports come from the AST extent of each
        Export-ModuleMember statement via Get-GateExportedNames, so both quote
        styles count. This table is what makes a cross-module lookup decidable
        without importing anything.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Paths)
    $defs = @{}
    $exports = @{}
    foreach ($p in $Paths) {
        $name = [System.IO.Path]::GetFileName($p)
        $d = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $text = Get-GateSourceText -Path $p
        foreach ($m in [regex]::Matches($text, '(?m)^\s*function\s+(?:global:)?([A-Za-z][A-Za-z0-9_\-]*)')) {
            [void]$d.Add($m.Groups[1].Value)
        }
        $defs[$name] = $d
        $exports[$name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in @(Get-GateExportedNames -Path $p)) { [void]$exports[$name].Add($n) }
    }
    return @{ Definitions = $defs; Exports = $exports }
}

function Find-GateNonGlobalForceImports {
    <#
    .SYNOPSIS
        Every `Import-Module ... -Force` that does NOT also say -Global.
    .DESCRIPTION
        This rule was implemented TWICE in ModuleHygiene.Tests.ps1 with a
        byte-identical quoted-path regex, so both copies had the same blind spot
        and fixing one would not have fixed the other. It lives here once.

        Why the rule matters: `Import-Module -Force` without `-Global` REPLACES
        the module in the current session only. When the caller is a nested or
        temporary scope (a Start-Job scriptblock, a plugin loader) the global
        binding another module already resolved is silently replaced on the way
        out, and PowerShell 5.1 orphans it on re-import - the failure family this
        gate exists to stop.

        Returns one record per finding: Line, Target (literal name when the path
        was quoted, else ''), IsLiteral ($true/$false). The caller owns the two
        policies that differ between the two former call sites - which literal
        targets are forbidden, and which variable-target sites are allowlisted.

    .PARAMETER CodeText
        Comment-stripped, string-preserving source text. The caller owns the
        stripper so this detector has no second implementation of it.
    .PARAMETER FileName
        Used only to label findings.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CodeText,
        [string]$FileName = '<text>'
    )
    $out = @()
    $idx = 0
    foreach ($ln in ($CodeText -split "`n")) {
        $idx++
        # Start-Job runs in an isolated child process and cannot orphan
        # parent-session modules.
        if ($ln -match 'Start-Job') { continue }
        if ($ln -notmatch 'Import-Module') { continue }
        if ($ln -notmatch '-Force') { continue }
        if ($ln -match '-Global') { continue }
        $qm = [regex]::Match($ln, '["'']([^"'']*?([\w-]+)\.psm1)["'']')
        if ($qm.Success) {
            $out += [PSCustomObject]@{ File = $FileName; Line = $idx; Target = $qm.Groups[2].Value; IsLiteral = $true }
        } else {
            $out += [PSCustomObject]@{ File = $FileName; Line = $idx; Target = ''; IsLiteral = $false }
        }
    }
    return @($out)
}

function Find-GateCrossModuleUnexportedCalls {
    <#
    .SYNOPSIS
        A name another module probes with Get-Command but no module exports.
    .DESCRIPTION
        The invariant is reachability, not tidiness: if module A does
        `if (Get-Command F) { F ... }` and F is DEFINED somewhere in Modules but
        EXPORTED nowhere, then every such guard silently takes its fallback
        branch. No error, no warning - the feature just stops working.

        Real instance this exists for: Security.Get-SecurityExcludeDirPattern
        was consumed by Policy, Sast and SupplyChain behind Get-Command guards
        and was missing from Security's Export-ModuleMember, so all three fell
        back to their own hardcoded pattern (Policy had none at all) and
        security.excludeDirs was honoured only inside Security.psm1 itself.

        Deliberately NOT a violation when SOME other module exports the name.
        Logging keeps a private Invoke-BuildSecretProtect shim that is never
        exported, because Logging sits at the root of the bootstrap chain and
        cannot import SharedUtils at module scope; RBAC's Get-Command correctly
        resolves SharedUtils' exported copy. Keying the rule on "exported
        nowhere" keeps that shim legal without a hand-maintained exemption list
        that would rot.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Exempt = @()
    )
    $tables = Get-GateModuleSymbolTables -Paths $Paths
    $defs = $tables.Definitions
    $exports = $tables.Exports

    # Names exported by at least one module: reachable, whatever else shadows them.
    $exportedSomewhere = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $exports.Keys) { foreach ($n in $exports[$k]) { [void]$exportedSomewhere.Add($n) } }

    $findings = @()
    foreach ($p in $Paths) {
        $fileName = [System.IO.Path]::GetFileName($p)
        $lines = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -match '^\s*#') { continue }
            foreach ($m in [regex]::Matches($line, 'Get-Command\s+(?:-\w+\s+)*([A-Za-z][A-Za-z0-9_\-]*)')) {
                $name = $m.Groups[1].Value
                if ($exportedSomewhere.Contains($name)) { continue }
                # Defined somewhere, but in no module at all -> a builtin/typo, not
                # an export defect. Defined nowhere -> same.
                $definedSomewhere = $false
                foreach ($k in $defs.Keys) { if ($defs[$k].Contains($name)) { $definedSomewhere = $true; break } }
                if (-not $definedSomewhere) { continue }
                if ($Exempt -contains $name) { continue }
                $findings += ('{0}:{1} {2}' -f $fileName, ($i + 1), $name)
            }
        }
    }
    return @($findings)
}

function Get-GateComputedDispatchNames {
    <#
    .SYNOPSIS
        Names that a COMBINATION of a format string and a ValidateSet can
        produce, even though the composed name never appears literally.
    .DESCRIPTION
        Load-bearing, not cosmetic. Loader.psm1 dispatches plugin verbs with

            [ValidateSet('Test','Lint','Clean','Run')] [string]$Verb
            ...
            $commandName = 'Invoke-Plugin{0}' -f $Verb
            & (Get-Command $commandName) ...

        so Invoke-PluginTest / -Lint / -Clean / -Run are invoked but never
        written as literals. A literal-reference count therefore reports 0
        call sites for the 28 exports (Invoke-PluginRun / Invoke-PluginClean /
        Invoke-PluginTest / Invoke-PluginLint across all 14 shipped language
        plugins) and they read as test-only dead surface. They are reachable
        on every build that runs a plugin verb.

        Two independent shapes are read, so the detector cannot be fooled by a
        lone format string:
          * a -f format string containing a {0} placeholder, combined with a
            ValidateSet on any parameter of the enclosing function;
        Shape 2 (ValidateSet values that already spell the whole name) is
        deliberately absent - see the note in the body.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)][string[]]$Paths)

    # Cached PER PATH SET, not globally: the dead-export gate calls this once
    # with the production paths and once with the test paths. A single global
    # cache handed the production composition set to the test pass, so a name
    # reachable only through a dispatch defined in a test file would have been
    # credited as reachable in production.
    $cacheKey = (@($Paths) | Sort-Object) -join '|'
    if ($script:GateDispatchCache -and $script:GateDispatchCache.ContainsKey($cacheKey)) { return , $script:GateDispatchCache[$cacheKey] }
    $names = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($p in $Paths) {
        $errs = $null; $tk = $null
        try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tk, [ref]$errs) } catch { continue }
        if ($null -eq $ast) { continue }

        foreach ($f in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            # Shape 1: a -f format string with a {0} placeholder. The literal
            # prefix before {0} is the composed name's stem.
            # 'X{0}' -f $y parses as a BinaryExpressionAst with operator -f,
            # NOT a CommandAst - reading it as a command is why an earlier
            # version of this detector found nothing.
            $stem = $null
            foreach ($b in $f.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
                if ($b.Operator -ne [System.Management.Automation.Language.TokenKind]::Format) { continue }
                if ($b.Left -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ([string]$b.Left.Value -match '^(?<stem>[A-Za-z][A-Za-z0-9_.\-]*?)\{0\}') { $stem = $Matches['stem']; break }
            }
            # Collect every ValidateSet value the function declares.
            $verbs = New-Object System.Collections.Generic.List[string]
            foreach ($attr in $f.FindAll({ param($x) $x -is [System.Management.Automation.Language.AttributeAst] }, $true)) {
                $vn = $attr.TypeName.Name
                if ($vn -notlike 'ValidateSet*') { continue }
                foreach ($pos in $attr.PositionalArguments) {
                    if ($pos -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $verbs.Add([string]$pos.Value) }
                }
            }
            foreach ($v in $verbs) { if ($stem) { [void]$names.Add($stem + $v) } }
        }

        # Shape 2 was "a ValidateSet value that already carries the whole name".
        # It is deliberately NOT implemented. Enumerated against this tree it
        # contributed 55 entries of which 51 were junk (Android, build, ci,
        # MD5, SHA256, Test, Pass, Skip...), and because the dead-export gate
        # credits anything in this set as reachable, every one of those names
        # becomes a hole a genuinely dead export could hide behind. A narrower
        # detector that cannot fire is better than a broad one that cannot see.
        # If composed dispatch ever stops using -f + ValidateSet, add the shape
        # here WITH a fixture in GateSelfTest.Tests.ps1 - not a loose scan.
    }

    if (-not $script:GateDispatchCache -or $script:GateDispatchCache -isnot [hashtable]) {
        $script:GateDispatchCache = @{}
    }
    $script:GateDispatchCache[$cacheKey] = $names
    # The comma is load-bearing, not a style choice. Returning a
    # HashSet[string] through the pipeline UNROLLS it into its elements, so the
    # caller would receive string[]; .Count then reports the element count by
    # luck, and an EMPTY set arrives as $null and makes the caller's .Contains
    # throw. ', ' keeps the set intact.
    return , $names
}

function Get-GateReferenceCount {
    <#
    .SYNOPSIS
        Count real references to a name across files, excluding ignored lines.
    .DESCRIPTION
        Content is read ONCE per file and memoised, keyed by path + size +
        LastWriteTime. The previous version called Get-Content inside the
        per-name loop, so a gate over ~350 exported names re-read ~120 files
        (one of them 240 KB) tens of thousands of times: the dead-export gate
        alone took 584 s, which is why an entire Pester scope appeared to hang.
        The memo key includes the file's identity metadata so an edited file is
        never served stale. Counting semantics are unchanged.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Paths,
        [hashtable]$Ignored,
        [string[]]$ExcludePaths
    )
    # Filter out excluded paths (e.g. the defining module itself)
    if ($ExcludePaths -and $ExcludePaths.Count -gt 0) {
        $Paths = @($Paths | Where-Object { $ExcludePaths -notcontains $_ })
    }
    # A name produced by -f composition + ValidateSet (see
    # Get-GateComputedDispatchNames) IS a call site even though the literal
    # never appears. Without this, every plugin's Invoke-PluginRun /
    # Invoke-PluginClean / Test / Lint export counts zero production references
    # and is indistinguishable from dead surface. The composition set is built
    # once per session and cached, so this costs one AST pass, not one per name.
    if ((Get-GateComputedDispatchNames -Paths $Paths).Contains($Name)) { return 1 }
    $rx = [regex]('(?<![A-Za-z0-9_\-])' + [regex]::Escape($Name) + '(?![A-Za-z0-9_\-])')
    $n = 0
    foreach ($p in $Paths) {
        $lines = $null
        if ($script:GateLineCache -and $script:GateLineCache.ContainsKey($p)) {
            $entry = $script:GateLineCache[$p]
            try {
                $fi = [System.IO.FileInfo]::new($p)
                if ($fi.Exists -and $fi.Length -eq $entry.Length -and $fi.LastWriteTimeUtc -eq $entry.Mtime) {
                    $lines = $entry.Lines
                }
            } catch { $lines = $null }
        }
        if ($null -eq $lines) {
            $lines = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)
            try {
                $fi = [System.IO.FileInfo]::new($p)
                $script:GateLineCache[$p] = @{ Lines = $lines; Length = $fi.Length; Mtime = $fi.LastWriteTimeUtc }
            } catch { }
        }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($Ignored -and $Ignored.ContainsKey($p) -and $Ignored[$p].Contains($i + 1)) { continue }
            if ($rx.IsMatch([string]$lines[$i])) { $n++ }
        }
    }
    return $n
}
