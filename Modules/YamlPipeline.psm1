# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

<#
.SYNOPSIS
    Minimal YAML reader for gbuild pipeline definitions (gbuild.pipeline.yml).
.DESCRIPTION
    README.md documented pipeline-as-code (gbuild.pipeline.yml with name /
    trigger / env / steps) for the whole time the feature did not exist:
    there was no YAML parser in Modules at all, Resolve-PipelineSteps read
    only build.pipeline.steps, and the referenced example file and
    gbuild.pipeline.schema.json were both absent. This module implements
    exactly the documented subset and nothing more.

    Deliberately a SUBSET, not a general YAML implementation:
      * block mappings and block sequences, space indentation
      * scalars: plain, 'single', "double"
      * comments (# ...) and document markers (--- / ...)
      * flow sequences of scalars: [a, b, c]
      * one level of nesting inside a sequence item

    Explicitly REJECTED, each with a parse error rather than silent
    misbehaviour, because a half-understood YAML file must fail loudly:
      * anchors/aliases (&a, *a) and merge keys (<<)
      * block scalars (| and >) - a multi-line script body belongs in
        build.pipeline.steps, which takes real PowerShell
      * tags (!tag)
      * tabs used for indentation
      * a step list nested deeper than one level

    ERROR DESIGN. Internal helpers never carry English prose. They throw
    [PipelineYamlError], which carries a machine Code plus format arguments,
    and exactly ONE boundary (ConvertTo-PipelineYamlMessage) maps a code to a
    locale key. That keeps the parser's internal failures translatable
    without string-interpolating English at 30 throw sites, and it means a
    new parse rule is one new code rather than one new hardcoded sentence.

    PowerShell 5.1-parseable: no (if), no ternary, no ??, no ForEach-Object
    -Parallel. It needs no third-party module, so it works in a generated
    standalone bundle where powershell-yaml would be absent.
#>


$script:PipelineYamlDefaults = @{
    FileName        = 'gbuild.pipeline.yml'
    SchemaFileName  = 'gbuild.pipeline.schema.json'
    AllowedRootKeys = @('name', 'trigger', 'version', 'env', 'steps')
    # 'env' is deliberately NOT a step key: the parser supports one level of
    # nesting inside a sequence item, so a step-local mapping cannot be read
    # and would only be rejected later with a misleading message. Per-step
    # environment belongs in gbuild.config.json build.pipeline.steps.
    # 'job' opts the step into background-job isolation (Invoke-PipelineStepJobAttempt):
    # the body runs in a child process with a HARD timeout instead of the
    # in-process post-hoc SLA. It REQUIRES 'timeout' on the same step.
    AllowedStepKeys = @('step', 'task', 'when', 'timeout', 'retry', 'job')
}

<#
    Structured parse/validation failure. Code is a stable machine identifier;
    Args feed the locale template. The human-readable Message is passed to the
    base constructor rather than assigned afterwards - Exception.Message is
    read-only, so an assign attempt fails with a misleading "Message is a
    ReadOnly property" error that hides the actual parse failure.
#>
class PipelineYamlError : System.Exception {
    [string]$Code
    [object[]]$Args
    PipelineYamlError([string]$code, [string]$message, [object[]]$errArgs) : base($message) {
        $this.Code = $code
        $this.Args = @($errArgs)
    }
}

<#
.SYNOPSIS
    Maps a PipelineYamlError code to a localized message.
.DESCRIPTION
    The single place English leaves this module. Every code is listed
    explicitly (rather than resolved as 'log.pipeline.yaml.' + $code) so the
    locale-key wiring gate can see each key as a literal in production source,
    and so an unmapped code fails loudly instead of leaking a raw code string.

    When Locale is not loaded (a standalone Import-Module of this module, or a
    bundle built before Tier-1 Locale is available) there is no resolver. Rather
    than duplicating the English templates here - which would be a second copy
    that Locale can never update - the fallback returns the structured code and
    its arguments. That is less readable but it is truthful, and it keeps the
    locale files the single owner of English prose.
#>
function ConvertTo-PipelineYamlMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Code, [object[]]$ErrorArgs = @())

Set-StrictMode -Version 1.0

    if (-not (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
        return ('{0}({1})' -f $Code, (@($ErrorArgs) -join ', '))
    }

    # Both message modes must name the construct: the standalone branch above
    # returns 'Code(args)', so the localized sentence carries the code too.
    # Pipeline errors are matched programmatically (callers catch
    # [PipelineYamlError] but tests and logs match Message text), and a bare
    # localized sentence does not name the code. Pinned by
    # Tests/YamlPipeline.Tests.ps1 'rejects <Name>'.
    $sentence = switch ($Code) {
        'TabIndent'          { Get-LocaleMessage -Key 'log.pipeline.yaml.tabIndent'        -MessageArgs $ErrorArgs }
        'BlockScalar'        { Get-LocaleMessage -Key 'log.pipeline.yaml.blockScalar'      -MessageArgs $ErrorArgs }
        'Anchor'             { Get-LocaleMessage -Key 'log.pipeline.yaml.anchor'           -MessageArgs $ErrorArgs }
        'Tag'                { Get-LocaleMessage -Key 'log.pipeline.yaml.tag'              -MessageArgs $ErrorArgs }
        'TopLevelSequence'   { Get-LocaleMessage -Key 'log.pipeline.yaml.topLevelSequence' -MessageArgs $ErrorArgs }
        'BadRootIndent'      { Get-LocaleMessage -Key 'log.pipeline.yaml.badRootIndent'    -MessageArgs $ErrorArgs }
        'ExpectedKeyValue'   { Get-LocaleMessage -Key 'log.pipeline.yaml.expectedKeyValue' -MessageArgs $ErrorArgs }
        'DuplicateKey'       { Get-LocaleMessage -Key 'log.pipeline.yaml.duplicateKey'     -MessageArgs $ErrorArgs }
        'SequenceIndent'     { Get-LocaleMessage -Key 'log.pipeline.yaml.sequenceIndent'   -MessageArgs $ErrorArgs }
        'SequenceOverIndent' { Get-LocaleMessage -Key 'log.pipeline.yaml.seqOverIndent'    -MessageArgs $ErrorArgs }
        'EmptySequenceItem'  { Get-LocaleMessage -Key 'log.pipeline.yaml.emptySeqItem'     -MessageArgs $ErrorArgs }
        'ItemIndent'         { Get-LocaleMessage -Key 'log.pipeline.yaml.itemIndent'       -MessageArgs $ErrorArgs }
        'ItemKeyValue'       { Get-LocaleMessage -Key 'log.pipeline.yaml.itemKeyValue'     -MessageArgs $ErrorArgs }
        'NestedMapIndent'    { Get-LocaleMessage -Key 'log.pipeline.yaml.nestedMapIndent'  -MessageArgs $ErrorArgs }
        'FlowMapping'        { Get-LocaleMessage -Key 'log.pipeline.yaml.flowMapping'      -MessageArgs $ErrorArgs }
        'NotFlowSequence'    { Get-LocaleMessage -Key 'log.pipeline.yaml.notFlowSequence'  -MessageArgs $ErrorArgs }
        'UnbalancedQuote'    { Get-LocaleMessage -Key 'log.pipeline.yaml.unbalancedQuote'  -MessageArgs $ErrorArgs }
        'Unreadable'         { Get-LocaleMessage -Key 'log.pipeline.yaml.unreadable'       -MessageArgs $ErrorArgs }
        'RootUnavailable'    { Get-LocaleMessage -Key 'log.pipeline.yaml.rootUnavailable'  -MessageArgs $ErrorArgs }
        'EmptyFile'          { Get-LocaleMessage -Key 'log.pipeline.yaml.emptyFile'        -MessageArgs $ErrorArgs }
        'UnknownRootKey'     { Get-LocaleMessage -Key 'log.pipeline.yaml.unknownRootKey'   -MessageArgs $ErrorArgs }
        'NoSteps'            { Get-LocaleMessage -Key 'log.pipeline.yaml.noSteps'          -MessageArgs $ErrorArgs }
        'EmptySteps'         { Get-LocaleMessage -Key 'log.pipeline.yaml.emptySteps'       -MessageArgs $ErrorArgs }
        'StepNotMapping'     { Get-LocaleMessage -Key 'log.pipeline.yaml.stepNotMapping'   -MessageArgs $ErrorArgs }
        'UnknownStepKey'     { Get-LocaleMessage -Key 'log.pipeline.yaml.unknownStepKey'   -MessageArgs $ErrorArgs }
        'MissingStepName'    { Get-LocaleMessage -Key 'log.pipeline.yaml.missingStepName'  -MessageArgs $ErrorArgs }
        'MissingTask'        { Get-LocaleMessage -Key 'log.pipeline.yaml.missingTask'      -MessageArgs $ErrorArgs }
        'EmptyTask'          { Get-LocaleMessage -Key 'log.pipeline.yaml.emptyTask'        -MessageArgs $ErrorArgs }
        'DuplicateStep'      { Get-LocaleMessage -Key 'log.pipeline.yaml.duplicateStep'    -MessageArgs $ErrorArgs }
        'NonNumeric'         { Get-LocaleMessage -Key 'log.pipeline.yaml.nonNumeric'       -MessageArgs $ErrorArgs }
        'NegativeTimeout'    { Get-LocaleMessage -Key 'log.pipeline.yaml.negativeTimeout'  -MessageArgs $ErrorArgs }
        'JobWithoutTimeout'  { Get-LocaleMessage -Key 'log.pipeline.yaml.jobNoTimeout'    -MessageArgs $ErrorArgs }
        'WhenParseError'     { Get-LocaleMessage -Key 'log.pipeline.yaml.whenParseError'   -MessageArgs $ErrorArgs }
        'EnvNotMapping'      { Get-LocaleMessage -Key 'log.pipeline.yaml.envNotMapping'    -MessageArgs $ErrorArgs }
        default             { Get-LocaleMessage -Key 'log.pipeline.yaml.generic'         -MessageArgs @($Code) }
    }
    return ('[{0}] {1}' -f $Code, $sentence)
}

<#
.SYNOPSIS
    Throws a localized PipelineYamlError, wrapping $Origin into the message.
#>
function New-PipelineYamlError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [object[]]$ErrorArgs = @(),
        [string]$Origin = ''
    )
    $all = @($ErrorArgs)
    if (-not [string]::IsNullOrWhiteSpace($Origin)) { $all = @($Origin) + @($ErrorArgs) }
    $msg = ConvertTo-PipelineYamlMessage -Code $Code -ErrorArgs $all
    throw ([PipelineYamlError]::new($Code, $msg, $all))
}

<#
.SYNOPSIS
    Removes an inline # comment from an unquoted YAML scalar.
.DESCRIPTION
    A '#' only starts a comment when it is at the start of the value or
    preceded by whitespace, so a URL fragment ('a#b') and a quoted '#'
    survive. Quoted scalars are handled by the caller before this runs.
#>
function Remove-YamlComment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
        if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
        if ($inSingle -or $inDouble) { continue }
        if ($ch -eq '#') {
            if ($i -eq 0 -or [char]::IsWhiteSpace($Value[$i - 1])) {
                return $Value.Substring(0, $i).TrimEnd()
            }
        }
    }
    return $Value
}

<#
.SYNOPSIS
    Converts a YAML scalar token into a PowerShell value.
.DESCRIPTION
    Quoted scalars are always strings. Unquoted scalars get the narrow type
    inference a pipeline file can rely on: integers, the literal true/false,
    and null/~. Anything else stays a string, so a step named "1" is not
    silently turned into an int.
#>
function ConvertFrom-YamlScalar {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[$v.Length - 1] -eq "'") {
        return $v.Substring(1, $v.Length - 2).Replace("''", "'")
    }
    if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') {
        return $v.Substring(1, $v.Length - 2)
    }
    if ($v -match '^-?\d+$') {
        $n = 0L
        if ([long]::TryParse($v, [ref]$n)) { return $n }
    }
    if ($v -ceq 'true') { return $true }
    if ($v -ceq 'false') { return $false }
    if ($v -ceq 'null' -or $v -ceq '~') { return $null }
    return $v
}

<#
.SYNOPSIS
    Splits a flow sequence scalar list ("[a, b, 'c d']") into items.
#>
function ConvertFrom-YamlFlowSequence {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][int]$LineNumber
    )

    $inner = $Value.Trim()
    if (-not ($inner.StartsWith('[') -and $inner.EndsWith(']'))) {
        New-PipelineYamlError -Code 'NotFlowSequence' -ErrorArgs @($LineNumber, $Line)
    }
    $inner = $inner.Substring(1, $inner.Length - 2).Trim()
    if ($inner.Length -eq 0) { return , @() }

    $items = [System.Collections.ArrayList]::new()
    $buf = ''
    $inSingle = $false
    $inDouble = $false
    foreach ($ch in $inner.ToCharArray()) {
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        if ($ch -eq ',' -and -not $inSingle -and -not $inDouble) {
            [void]$items.Add((ConvertFrom-YamlScalar -Value $buf))
            $buf = ''
            continue
        }
        $buf += $ch
    }
    if ($inSingle -or $inDouble) {
        New-PipelineYamlError -Code 'UnbalancedQuote' -ErrorArgs @($LineNumber, $Line)
    }
    [void]$items.Add((ConvertFrom-YamlScalar -Value $buf))
    return , $items.ToArray()
}

<#
.SYNOPSIS
    Splits "key: value" honouring quotes; returns $null when there is no colon.
#>
function Split-YamlKeyValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)

    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
        if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
        if ($inSingle -or $inDouble) { continue }
        if ($ch -eq ':') {
            $after = if ($i + 1 -lt $Line.Length) { $Line[$i + 1] } else { ' ' }
            # A colon separates only when followed by whitespace or EOL, so
            # 'http://host' and 'a:b' stay scalars.
            if ($after -eq ' ' -or $i + 1 -eq $Line.Length) {
                return @{
                    Key   = $Line.Substring(0, $i).Trim()
                    Value = $Line.Substring($i + 1).Trim()
                }
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Parses a YAML subset into nested ordered dictionaries and arrays.
.PARAMETER Text
    File content. Accepts an array of lines or one string.
.PARAMETER Origin
    Label prefixed to every parse error (usually the file path).
.OUTPUTS
    PSCustomObject over an ordered dictionary of root keys, or $null for an
    empty / comment-only document.
#>
function ConvertFrom-GBuildYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()]$Text,
        [string]$Origin = '<yaml>'
    )

    $rawLines = @()
    if ($Text -is [string]) { $rawLines = @($Text -split "`r?`n") } else { $rawLines = @($Text) }

    $lines = [System.Collections.ArrayList]::new()
    for ($n = 0; $n -lt $rawLines.Count; $n++) {
        $raw = [string]$rawLines[$n]
        $lineNo = $n + 1
        if ($raw -match "`t") {
            New-PipelineYamlError -Code 'TabIndent' -ErrorArgs @($lineNo, $raw) -Origin $Origin
        }
        $noComment = Remove-YamlComment -Value $raw
        $trimmed = $noComment.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed -eq '---' -or $trimmed -eq '...') { continue }
        if ($trimmed.StartsWith('|') -or $trimmed.StartsWith('>')) {
            New-PipelineYamlError -Code 'BlockScalar' -ErrorArgs @($lineNo, $raw) -Origin $Origin
        }
        $indent = $noComment.Length - $noComment.TrimStart().Length
        [void]$lines.Add([PSCustomObject]@{ Indent = $indent; Text = $trimmed; Number = $lineNo })
    }
    if ($lines.Count -eq 0) { return $null }

    # Normalize the base indent so a file indented inside a repo still parses.
    $baseIndent = ($lines | Measure-Object -Property Indent -Minimum).Minimum

    # Anchors and tags are rejected wherever they appear, not only in key
    # position. `steps: &anchor` followed by a nested block is valid YAML but
    # unsupported here, and reporting it as "unexpected indentation" sends the
    # reader hunting for a spacing problem that is not there.
    function Test-YamlUnsupportedMarker {
        param([string]$Text)
        $t = $Text.TrimStart()
        return ($t.StartsWith('&') -or $t.StartsWith('*') -or $t.StartsWith('!'))
    }

    $i = 0
    $root = [ordered]@{}
    $seenRoot = @{}

    while ($i -lt $lines.Count) {
        $cur = $lines[$i]
        $relIndent = $cur.Indent - $baseIndent
        if ($relIndent -ne 0) {
            New-PipelineYamlError -Code 'BadRootIndent' -ErrorArgs @($cur.Number) -Origin $Origin
        }
        if ($cur.Text.StartsWith('- ') -or $cur.Text -eq '-') {
            New-PipelineYamlError -Code 'TopLevelSequence' -ErrorArgs @($cur.Number) -Origin $Origin
        }
        $kv = Split-YamlKeyValue -Line $cur.Text
        if (-not $kv -or $kv.Key.Length -eq 0) {
            New-PipelineYamlError -Code 'ExpectedKeyValue' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
        }
        if ($kv.Key.StartsWith('&') -or $kv.Key.StartsWith('*') -or $kv.Key -eq '<<') {
            New-PipelineYamlError -Code 'Anchor' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
        }
        if ($kv.Key.StartsWith('!')) {
            New-PipelineYamlError -Code 'Tag' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
        }
        if ($seenRoot.ContainsKey($kv.Key)) {
            New-PipelineYamlError -Code 'DuplicateKey' -ErrorArgs @($cur.Number, $kv.Key) -Origin $Origin
        }
        $seenRoot[$kv.Key] = $true

        $key = $kv.Key
        $inlineValue = $kv.Value
        $i++

        if ($inlineValue.Length -gt 0) {
            if (Test-YamlUnsupportedMarker -Text $inlineValue) {
                $marker = $inlineValue.TrimStart()
                if ($marker.StartsWith('!')) {
                    New-PipelineYamlError -Code 'Tag' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
                }
                New-PipelineYamlError -Code 'Anchor' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
            }
            if ($inlineValue.StartsWith('[')) {
                $root[$key] = ConvertFrom-YamlFlowSequence -Value $inlineValue -Line $cur.Text -LineNumber $cur.Number
            } elseif ($inlineValue.StartsWith('{')) {
                New-PipelineYamlError -Code 'FlowMapping' -ErrorArgs @($cur.Number, $cur.Text) -Origin $Origin
            } else {
                $root[$key] = ConvertFrom-YamlScalar -Value $inlineValue
            }
            continue
        }

        # Empty value: either a nested block or a null scalar. Peek ahead.
        if ($i -ge $lines.Count) { $root[$key] = $null; continue }
        $next = $lines[$i]
        $nextRel = $next.Indent - $baseIndent
        $isSequence = $next.Text.StartsWith('- ') -or $next.Text -eq '-'

        if (-not $isSequence -and $nextRel -le $relIndent) {
            $root[$key] = $null
            continue
        }
        if ($isSequence -and $nextRel -le $relIndent) {
            New-PipelineYamlError -Code 'SequenceIndent' -ErrorArgs @($next.Number, $key) -Origin $Origin
        }

        $childIndent = $nextRel
        if ($isSequence) {
            $items = [System.Collections.ArrayList]::new()
            while ($i -lt $lines.Count) {
                $item = $lines[$i]
                $itemRel = $item.Indent - $baseIndent
                if ($itemRel -lt $childIndent) { break }
                if ($itemRel -gt $childIndent) {
                    New-PipelineYamlError -Code 'SequenceOverIndent' -ErrorArgs @($item.Number, $key) -Origin $Origin
                }
                if (-not ($item.Text.StartsWith('- ') -or $item.Text -eq '-')) { break }
                $inline = if ($item.Text -eq '-') { '' } else { $item.Text.Substring(2).Trim() }
                $i++
                if ($inline.Length -eq 0) {
                    New-PipelineYamlError -Code 'EmptySequenceItem' -ErrorArgs @($item.Number, $key) -Origin $Origin
                }
                $itemKv = Split-YamlKeyValue -Line $inline
                if (-not $itemKv) {
                    # Plain scalar item.
                    [void]$items.Add((ConvertFrom-YamlScalar -Value $inline))
                    continue
                }
                # Mapping item: the first key is inline, the rest are sibling
                # lines deeper than the '- ' marker.
                $obj = [ordered]@{}
                $itemMapIndent = $itemRel + 2
                if ($itemKv.Key.StartsWith('&') -or $itemKv.Key.StartsWith('*') -or $itemKv.Key -eq '<<') {
                    New-PipelineYamlError -Code 'Anchor' -ErrorArgs @($item.Number, $inline) -Origin $Origin
                }
                if ($itemKv.Key.StartsWith('!')) {
                    New-PipelineYamlError -Code 'Tag' -ErrorArgs @($item.Number, $inline) -Origin $Origin
                }
                $obj[$itemKv.Key] = Convert-YamlInlineValue -Value $itemKv.Value -Line $inline -LineNumber $item.Number -Origin $Origin
                while ($i -lt $lines.Count) {
                    $sub = $lines[$i]
                    $subRel = $sub.Indent - $baseIndent
                    if ($subRel -le $itemRel) { break }
                    if ($sub.Text.StartsWith('- ')) { break }
                    $subKv = Split-YamlKeyValue -Line $sub.Text
                    if (-not $subKv) {
                        New-PipelineYamlError -Code 'ItemKeyValue' -ErrorArgs @($sub.Number, $sub.Text) -Origin $Origin
                    }
                    if ($subRel -lt $itemMapIndent) {
                        New-PipelineYamlError -Code 'ItemIndent' -ErrorArgs @($sub.Number, $key) -Origin $Origin
                    }
                    if ($obj.Contains($subKv.Key)) {
                        New-PipelineYamlError -Code 'DuplicateKey' -ErrorArgs @($sub.Number, $subKv.Key) -Origin $Origin
                    }
                    $i++
                    $obj[$subKv.Key] = Convert-YamlInlineValue -Value $subKv.Value -Line $sub.Text -LineNumber $sub.Number -Origin $Origin
                }
                [void]$items.Add([PSCustomObject]$obj)
            }
            $root[$key] = $items.ToArray()
            continue
        }

        # Nested mapping.
        $map = [ordered]@{}
        while ($i -lt $lines.Count) {
            $sub = $lines[$i]
            $subRel = $sub.Indent - $baseIndent
            if ($subRel -le $relIndent) { break }
            if ($subRel -ne $childIndent) {
                New-PipelineYamlError -Code 'NestedMapIndent' -ErrorArgs @($sub.Number, $key) -Origin $Origin
            }
            $subKv = Split-YamlKeyValue -Line $sub.Text
            if (-not $subKv) {
                New-PipelineYamlError -Code 'ExpectedKeyValue' -ErrorArgs @($sub.Number, $sub.Text) -Origin $Origin
            }
            if ($map.Contains($subKv.Key)) {
                New-PipelineYamlError -Code 'DuplicateKey' -ErrorArgs @($sub.Number, $subKv.Key) -Origin $Origin
            }
            $i++
            if ($subKv.Value.Length -eq 0) {
                $map[$subKv.Key] = $null
            } else {
                $map[$subKv.Key] = Convert-YamlInlineValue -Value $subKv.Value -Line $sub.Text -LineNumber $sub.Number -Origin $Origin
            }
        }
        $root[$key] = [PSCustomObject]$map
    }

    return [PSCustomObject]$root
}

<#
.SYNOPSIS
    Converts a right-hand-side value token, rejecting inline flow mappings
    and block scalars wherever a value may appear.
#>
function Convert-YamlInlineValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Value,
        [string]$Line = '',
        [int]$LineNumber = 0,
        [string]$Origin = ''
    )
    if ($Value.StartsWith('&') -or $Value.StartsWith('*')) { New-PipelineYamlError -Code 'Anchor' -ErrorArgs @($LineNumber, $Line) -Origin $Origin }
    if ($Value.StartsWith('!')) { New-PipelineYamlError -Code 'Tag' -ErrorArgs @($LineNumber, $Line) -Origin $Origin }
    if ($Value.StartsWith('[')) { return (ConvertFrom-YamlFlowSequence -Value $Value -Line $Line -LineNumber $LineNumber) }
    if ($Value.StartsWith('{')) { New-PipelineYamlError -Code 'FlowMapping' -ErrorArgs @($LineNumber, $Line) -Origin $Origin }
    if ($Value.StartsWith('|') -or $Value.StartsWith('>')) { New-PipelineYamlError -Code 'BlockScalar' -ErrorArgs @($LineNumber, $Line) -Origin $Origin }
    return (ConvertFrom-YamlScalar -Value $Value)
}

<#
.SYNOPSIS
    Resolves a pipeline-file path against the build root.
#>
function Resolve-PipelineYamlPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [PSCustomObject]$State
    )
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    # Get-BuildRootedPath is the single owner of "resolve a relative path
    # against the build root". Falling back to (Get-Location) here would be a
    # second root resolver: the shell's directory, not the project's, which is
    # the exact bug PathUtils.Get-BuildRootDirectory exists to prevent.
    if (Get-Command Resolve-BuildRootedPath -ErrorAction SilentlyContinue) {
        return [string](Resolve-BuildRootedPath -RelativePath $Path -State $State)
    }
    New-PipelineYamlError -Code 'RootUnavailable' -ErrorArgs @($Path)
}

<#
.SYNOPSIS
    Locates gbuild.pipeline.yml and returns its parsed document.
.DESCRIPTION
    Resolution order (first hit wins):
      1. -Path, when given (resolved against the build root if relative)
      2. build.pipeline.file from config
      3. gbuild.pipeline.yml in State.ProjectRoot

    Auto-discovery is deliberately ProjectRoot-only. ScriptRoot is the
    _Build installation directory, which ships gbuild.pipeline.yml as a
    reference example: discovering it there would silently replace the
    built-in pipeline for every project on this machine. Falling back to the
    current directory would be equally wrong - that is wherever the shell
    happened to be, not the project being built - and walking up parent
    directories would let a stale file in an ancestor repository take over.

    Returns $null when no pipeline file exists.
#>
function Get-BuildYamlPipelineDocument {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [string]$Path = ''
    )

    $candidates = [System.Collections.ArrayList]::new()
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        [void]$candidates.Add((Resolve-PipelineYamlPath -Path $Path -State $State))
    } else {
        $configured = ''
        try {
            if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) {
                $configured = [string](Get-BuildSetting -Key 'PipelineFile' -State $State -Fallback '')
            }
            if ([string]::IsNullOrWhiteSpace($configured) -and (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue)) {
                $configured = [string](Get-ConfigValue -Path 'build.pipeline.file' -State $State -Default '')
            }
        } catch { $configured = '' }
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            [void]$candidates.Add((Resolve-PipelineYamlPath -Path $configured -State $State))
        } elseif ($State -and ($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) {
            [void]$candidates.Add((Join-Path ([string]$State.ProjectRoot) $script:PipelineYamlDefaults.FileName))
        }
    }

    foreach ($candidate in @($candidates.ToArray())) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        if (-not (Test-Path -LiteralPath ([string]$candidate) -PathType Leaf)) { continue }
        $text = ''
        try { $text = [System.IO.File]::ReadAllText([string]$candidate) }
        catch { New-PipelineYamlError -Code 'Unreadable' -ErrorArgs @($candidate, $_.Exception.Message) }
        $doc = ConvertFrom-GBuildYaml -Text $text -Origin ([string]$candidate)
        if ($null -eq $doc) {
            New-PipelineYamlError -Code 'EmptyFile' -ErrorArgs @($candidate)
        }
        $doc | Add-Member -MemberType NoteProperty -Name SourcePath -Value ([string]$candidate) -Force
        return $doc
    }
    return $null
}

<#
.SYNOPSIS
    Validates a parsed pipeline document against the supported schema.
.DESCRIPTION
    Fails loudly on an unknown root key or step key, a step with no task, a
    non-numeric timeout, or a pipeline with no steps. Silently ignoring an
    unknown key is how a typo'd 'timout: 60' would leave a step with no
    timeout and nobody would know.
.OUTPUTS
    $true, or the Document when -PassThru.
#>
function Test-PipelineYamlDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [PSCustomObject]$State,
        [switch]$PassThru
    )

    $origin = ''
    try { if ($Document.PSObject.Properties.Name -contains 'SourcePath') { $origin = [string]$Document.SourcePath } } catch { $origin = '' }
    $label = if ($origin) { $origin } else { 'pipeline definition' }

    # SourcePath is provenance metadata added by Get-BuildYamlPipelineDocument,
    # not authored content, so it is not a schema violation.
    $allowedRoot = @($script:PipelineYamlDefaults.AllowedRootKeys) + @('SourcePath')
    $unknownRoot = @()
    foreach ($p in @($Document.PSObject.Properties.Name)) {
        if ($allowedRoot -notcontains $p) { $unknownRoot += $p }
    }
    if ($unknownRoot.Count -gt 0) {
        New-PipelineYamlError -Code 'UnknownRootKey' -ErrorArgs @($label, ($unknownRoot -join ', '), ($allowedRoot -join ', '))
    }

    if (-not ($Document.PSObject.Properties.Name -contains 'steps')) {
        New-PipelineYamlError -Code 'NoSteps' -ErrorArgs @($label)
    }
    $steps = @($Document.steps)
    if ($steps.Count -eq 0) {
        New-PipelineYamlError -Code 'EmptySteps' -ErrorArgs @($label)
    }

    $allowedStep = $script:PipelineYamlDefaults.AllowedStepKeys
    $seen = @{}
    $index = 0
    foreach ($step in $steps) {
        $index++
        if ($null -eq $step -or $step -isnot [PSCustomObject]) {
            New-PipelineYamlError -Code 'StepNotMapping' -ErrorArgs @($index, $label)
        }
        $names = @($step.PSObject.Properties.Name)
        $unknown = @($names | Where-Object { $allowedStep -notcontains $_ })
        if ($unknown.Count -gt 0) {
            New-PipelineYamlError -Code 'UnknownStepKey' -ErrorArgs @($index, $label, ($unknown -join ', '), ($allowedStep -join ', '))
        }
        $stepName = ''
        if ($names -contains 'step') { $stepName = [string]$step.step }
        if ([string]::IsNullOrWhiteSpace($stepName)) {
            New-PipelineYamlError -Code 'MissingStepName' -ErrorArgs @($index, $label)
        }
        if (-not ($names -contains 'task')) {
            New-PipelineYamlError -Code 'MissingTask' -ErrorArgs @($stepName, $label)
        }
        $task = [string]$step.task
        if ([string]::IsNullOrWhiteSpace($task)) {
            New-PipelineYamlError -Code 'EmptyTask' -ErrorArgs @($stepName, $label)
        }
        if ($seen.ContainsKey($stepName)) {
            New-PipelineYamlError -Code 'DuplicateStep' -ErrorArgs @($stepName, $label)
        }
        $seen[$stepName] = $true

        # Parse-validate the when: expression HERE, not only in
        # ConvertFrom-PipelineYamlStep, so a malformed expression fails
        # validation before anything runs.
        if ($names -contains 'when') {
            $whenBody = [string]$step.when
            if (-not [string]::IsNullOrWhiteSpace($whenBody)) {
                $parseErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($whenBody, [ref]$null, [ref]$parseErrors)
                if ($parseErrors -and $parseErrors.Count -gt 0) {
                    New-PipelineYamlError -Code 'WhenParseError' -ErrorArgs @($stepName, $label, $parseErrors[0].Message)
                }
            }
        }

        foreach ($numeric in @('timeout', 'retry')) {
            if (-not ($names -contains $numeric)) { continue }
            $raw = $step.$numeric
            if ($null -eq $raw) { continue }
            if ($raw -is [long] -or $raw -is [int]) { continue }
            $parsed = 0
            if (-not [int]::TryParse([string]$raw, [ref]$parsed)) {
                New-PipelineYamlError -Code 'NonNumeric' -ErrorArgs @($stepName, $label, $numeric, $raw)
            }
        }
        if (($names -contains 'timeout') -and [int]$step.timeout -lt 0) {
            New-PipelineYamlError -Code 'NegativeTimeout' -ErrorArgs @($stepName, $label)
        }

        # Job isolation without a timeout is rejected here, not at run time:
        # an isolated step with no timeout can never be killed, which defeats
        # the only reason to isolate it.
        if (($names -contains 'job') -and [bool]$step.job -and -not ($names -contains 'timeout')) {
            New-PipelineYamlError -Code 'JobWithoutTimeout' -ErrorArgs @($stepName, $label)
        }
    }

    if ($PassThru) { return $Document }
    return $true
}

<#
.SYNOPSIS
    Applies a pipeline document's 'env:' block to the current process.
.DESCRIPTION
    Values support ${env:NAME} placeholders, resolved through the shared
    ConfigProvider resolver so YAML pipelines expand env vars exactly like
    gbuild.config.json does. Existing process values are not overwritten, so
    an operator's explicit environment still wins over the file.
.OUTPUTS
    Hashtable of the keys that were actually applied (for restoration).
#>
function Set-PipelineYamlEnvironment {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Document,
        [PSCustomObject]$State
    )

    $applied = @{}
    if (-not ($Document.PSObject.Properties.Name -contains 'env')) { return $applied }
    $env = $Document.env
    if ($null -eq $env) { return $applied }
    if ($env -is [string] -or $env -is [ValueType]) {
        New-PipelineYamlError -Code 'EnvNotMapping' -ErrorArgs @()
    }

    foreach ($name in @($env.PSObject.Properties.Name)) {
        $raw = [string]$env.$name
        $value = $raw
        try {
            if (Get-Command Resolve-ConfigEnvironmentValue -ErrorAction SilentlyContinue) {
                $value = [string](Resolve-ConfigEnvironmentValue -Value $raw -State $State)
            }
        } catch { $value = $raw }
        if ([string]::IsNullOrEmpty([string]$name)) { continue }
        if (Test-Path -LiteralPath ("Env:{0}" -f $name)) { continue }
        Set-Item -LiteralPath ("Env:{0}" -f $name) -Value $value -ErrorAction SilentlyContinue
        $applied[[string]$name] = $value
    }
    return $applied
}

<#
.SYNOPSIS
    Removes environment keys applied by Set-PipelineYamlEnvironment.
#>
function Clear-PipelineYamlEnvironment {
    [CmdletBinding()]
    param([hashtable]$Applied)
    if (-not $Applied) { return }
    foreach ($name in @($Applied.Keys)) {
        Remove-Item -LiteralPath ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Converts a validated pipeline document into engine step hashtables.
.DESCRIPTION
    Each step's 'task:' becomes `& <task> $ctx`, matching the built-in
    pipeline's scriptblock contract. 'when:' becomes a scriptblock evaluated
    against $ctx by Invoke-GuildPipeline (same fail-open-on-throw semantics
    as JSON steps). 'timeout' maps to TimeoutSeconds, 'retry' to Retry.
.OUTPUTS
    Array of hashtables: @{ Name; Script; [When]; [Retry]; [TimeoutSeconds] }.
#>
function ConvertFrom-PipelineYamlStep {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]$Document,
        [PSCustomObject]$State
    )

    $resolved = [System.Collections.ArrayList]::new()
    foreach ($step in @($Document.steps)) {
        $names = @($step.PSObject.Properties.Name)
        $stepName = [string]$step.step
        $task = [string]$step.task
        $whenBody = if ($names -contains 'when') { [string]$step.when } else { '' }

        $entry = @{
            Name   = $stepName
            Script = [scriptblock]::Create("& $task `$ctx")
        }
        if ($names -contains 'when') { $entry.When = [scriptblock]::Create($whenBody) }
        if ($names -contains 'retry') { $entry.Retry = [int]$step.retry }
        if ($names -contains 'timeout') { $entry.TimeoutSeconds = [int]$step.timeout }
        if ($names -contains 'job') { $entry.Job = [bool]$step.job }
        [void]$resolved.Add($entry)
    }
    return , $resolved.ToArray()
}

Export-ModuleMember -Function @(
    'ConvertFrom-GBuildYaml',
    'ConvertFrom-PipelineYamlStep',
    'Get-BuildYamlPipelineDocument',
    'Set-PipelineYamlEnvironment',
    'Clear-PipelineYamlEnvironment',
    'Test-PipelineYamlDocument'
)
