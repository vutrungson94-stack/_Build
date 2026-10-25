param([PSCustomObject]$State)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
# Self-healing bootstrap (standalone-safe). Single owner:
# Modules/StepBootstrap.ps1. When this script runs outside an Orchestrator
# session the shared libs are absent; that file walks up to the _Build root and
# imports them. No-op inside a normal gbuild run.
$__gbuildModulesDir = Split-Path -Parent $PSScriptRoot
$__gbuildStepBootstrap = Join-Path $__gbuildModulesDir 'Modules/StepBootstrap.ps1'
if (Test-Path -LiteralPath $__gbuildStepBootstrap -PathType Leaf) {
    . $__gbuildStepBootstrap -Sentinels @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant') -Modules @()
}
Remove-Variable -Name __gbuildModulesDir, __gbuildStepBootstrap -ErrorAction SilentlyContinue
if (-not $State -and (Get-Command Resolve-BuildState -ErrorAction SilentlyContinue)) { $State = Resolve-BuildState $State }
if (-not $State) {
    # Standalone/manual use (". ./Steps/pipeline-diagram.ps1" with no -State, as the
    # help text documents) must still work: this is a diagnostic utility, not a
    # build step. Build a minimal State from the _Build root instead of bailing.
    # The previous `exit 1` was doubly wrong: a dot-sourced `exit` terminates the
    # CALLING session, and the old test wrapped its assertions in
    # `if (Test-Path ...)` so the diagram was silently never produced.
    $__selfRoot = $PSScriptRoot; $__d = 0
    while ($__selfRoot -and $__d -lt 6 -and -not (Test-Path -LiteralPath (Join-Path $__selfRoot 'Modules') -PathType Container)) { $__selfRoot = Split-Path $__selfRoot -Parent; $__d++ }
    if (-not $__selfRoot) { $__selfRoot = (Get-Location).ProviderPath }
    $State = [PSCustomObject]@{
        ScriptRoot  = $__selfRoot
        ProjectRoot = $__selfRoot
        WorkingDir  = $__selfRoot
        ConfigPath  = (Join-Path $__selfRoot 'gbuild.config.json')
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.pipeline.noBuildState' -Fallback '[PIPELINE] No build state supplied - generating from the _Build root config.') 'Gray' $State }
}
function Get-DiagramValue {
    param($Object, [string[]]$Names, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary]) { foreach ($key in $Object.Keys) { if ([string]$key -ieq $name) { return $Object[$key] } } }
        else { try { if ($Object.PSObject.Properties.Name -contains $name) { return $Object.$name } } catch { } }
    }
    return $Default
}
$root = if (($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif (($State.PSObject.Properties.Name -contains 'WorkingDir') -and $State.WorkingDir) { [string]$State.WorkingDir } elseif (($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
$config = if ($State.PSObject.Properties.Name -contains 'BuildConfig') { $State.BuildConfig } else { $null }
$configPath = if ($State.PSObject.Properties.Name -contains 'ConfigPath') { [string]$State.ConfigPath } else { '' }
if ($null -ne $config -and [string]::IsNullOrWhiteSpace($configPath) -and $null -eq (Get-DiagramValue $config @('build', 'pipeline', 'hooks', 'report') $null)) { $config = $null }
$sourceMode = 'config'
if ($null -eq $config) {
    $candidate = Join-Path $root 'gbuild.config.json'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { try { $config = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json; $configPath = $candidate } catch { $config = $null } }
}
if ($null -eq $config) { $sourceMode = 'static-fallback'; $configPath = 'unavailable' }
$pipeline = Get-DiagramValue $config @('pipeline') $null
$build = Get-DiagramValue $config @('build') $null
$validate = [bool](Get-DiagramValue $pipeline @('validate') $true)
$steps = @(Get-DiagramValue $pipeline @('steps') @())
$testEnabled = [bool](Get-DiagramValue (Get-DiagramValue $build @('test') $null) @('enabled') $true)
$lintEnabled = [bool](Get-DiagramValue (Get-DiagramValue $build @('test') $null) @('lintEnabled') $true)
$hooksBefore = @(Get-DiagramValue (Get-DiagramValue $config @('hooks') $null) @('before-build') @())
$hooksAfter = @(Get-DiagramValue (Get-DiagramValue $config @('hooks') $null) @('after-build') @())
$flow = [System.Collections.Generic.List[string]]::new()
$flow.Add('flowchart TD') | Out-Null
$flow.Add('    start([Start]) --> validate{Config valid?}') | Out-Null
if ($validate) { $flow.Add('    validate -->|yes| modules[Load modules]') | Out-Null; $flow.Add('    validate -->|no| defaults[Defaults]') | Out-Null; $flow.Add('    defaults --> modules') | Out-Null } else { $flow.Add('    validate --> modules[Load modules]') | Out-Null }
$flow.Add('    modules --> detect[Detect project]') | Out-Null
$previous = 'detect'
$index = 0
foreach ($step in $steps) {
    $index++
    $name = [string](Get-DiagramValue $step @('Name', 'name', 'Id', 'id') "ConfiguredStep$index")
    $safe = [regex]::Replace($name, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "ConfiguredStep$index" }
    $id = "S$index"
    $flow.Add("    $previous --> $id[$safe]") | Out-Null
    $previous = $id
}
$flow.Add("    $previous --> build[Build]") | Out-Null
$previous = 'build'
if ($testEnabled) { $flow.Add("    $previous --> tests[Run tests]") | Out-Null; $previous = 'tests' }
if ($lintEnabled) { $flow.Add("    $previous --> lint[Lint/validate]") | Out-Null; $previous = 'lint' }
$flow.Add("    $previous --> done([Done])") | Out-Null
$metadata = @("DiagramMode: $sourceMode", "ConfigPath: $configPath", "ConfiguredPipelineSteps: $($steps.Count)", "BeforeBuildHooks: $($hooksBefore.Count)", "AfterBuildHooks: $($hooksAfter.Count)")
$content = (($metadata + @($flow)) -join "`n") + "`n"
$outDir = [string](Get-DiagramValue (Get-DiagramValue $config @('paths') $null) @('reportsDir') '')
if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = [string](Get-DiagramValue (Get-DiagramValue $config @('report') $null) @('outputDir') 'build-reports') }
if (-not [System.IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path $root $outDir }
if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null }
$outFile = Join-Path $outDir 'pipeline-diagram.md'
[System.IO.File]::WriteAllText($outFile, $content, (New-Object System.Text.UTF8Encoding($false)))
if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.pipeline.diagramSaved' -MessageArgs @([string]$outFile, [string]$sourceMode) -Fallback '[PIPELINE] Diagram saved to {0} (source: {1})') 'Info' $State }
