#Requires -Version 5.1
# Mutation-test harness for the targeted high-risk owners (PathUtils containment,
# SharedUtils redaction, ConfigProvider merge/override).
#
# A line-coverage percentage does not prove the assertions bite: a containment
# guard can be weakened fail-open and the tests that exercise it still pass
# against the codebase as it SHIPS. This harness builds a throwaway copy of the
# Modules tree with ONE hand-written mutation applied to ONE file, imports the
# mutant, and asserts the mutation produces the INSECURE / incorrect outcome.
# If a regression removes the discrimination (or the owner is refactored out
# from under a mutant), the mutation test fails - a surviver is a finding.
#
# The real tree is never touched: every mutant gets its own throwaway copy.

function New-MutationSandbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ModuleFile,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )
    $dst = Join-Path ([System.IO.Path]::GetTempPath()) ("gbuild-mut-$Name-" + [guid]::NewGuid().ToString('N'))
    Copy-Item (Join-Path $ToolRoot 'Modules') -Destination $dst -Recurse -Force

    $file = Join-Path $dst $ModuleFile
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "mutation sandbox: module file not found: $file"
    }
    # Line endings are not part of the invariant: a working tree may carry
    # CRLF or LF depending on checkout. Normalize before matching and write
    # the mutant back with LF (valid for PowerShell on every platform).
    $normalize = { param([string]$s) $s -replace "`r`n", "`n" }
    $text = & $normalize (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    $oldText = & $normalize $Old
    $newText = & $normalize $New
    # Ordinal substring replace: the mutant must be byte-identical everywhere
    # except the planted mutation. .Replace is not regex, so '\' and '$' in
    # the source text need no escaping.
    $mutated = $text.Replace($oldText, $newText)
    if ($mutated -eq $text) {
        Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
        throw "mutation sandbox: mutation '$Name' is no longer applicable - the source text it targets is gone. Re-check Modules/$ModuleFile and update the mutant."
    }
    [System.IO.File]::WriteAllText($file, $mutated, (New-Object System.Text.UTF8Encoding($true)))

    # Import the mutant under its own name so the caller's already-loaded
    # module is not replaced mid-suite.
    $leaf = [System.IO.Path]::GetFileName($file)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $mutantLeaf = $base + '.Mutation.psm1'
    Rename-Item -LiteralPath $file -NewName $mutantLeaf
    $mutantFile = Join-Path (Split-Path -Parent $file) $mutantLeaf
    $handle = Import-Module -Name $mutantFile -Force -PassThru
    return [PSCustomObject]@{ Root = $dst; Module = $handle }
}

function Remove-MutationSandbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Sandbox)
    if ($null -eq $Sandbox) { return }
    try { Remove-Module -ModuleInfo $Sandbox.Module -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
