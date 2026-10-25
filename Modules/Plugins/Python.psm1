# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Python'
    SupportedLanguages = @('Python')
    Priority = 3
    ToolName = 'python3'
    FallbackToolNames = @('python')
    ManifestFiles = @('pyproject.toml', 'setup.py', 'setup.cfg')
    BuildCommand = 'python -m pip install -e .'
    TestCommand = 'pytest -v'
    LintCommand = 'ruff check .'
    CleanCommand = ''
    RunCommand = ''
    LintToolName = 'ruff'
    MissingToolLevel = 'Warn'
    SoftFailLint = $true
}

function Get-PythonBuildConfig {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $cfg = $null
    if ($State -and $State.BuildConfig) {
        try { if ($State.BuildConfig.build -and $State.BuildConfig.build.python) { $cfg = $State.BuildConfig.build.python } } catch { }
        if (-not $cfg) { try { if ($State.BuildConfig.python) { $cfg = $State.BuildConfig.python } } catch { } }
    }
    return $cfg
}

function Resolve-PythonRuntime {
    param([PSCustomObject]$State, [string]$ProjectDir, [switch]$Create)
    $cfg = Get-PythonBuildConfig -State $State
    $useVenv = $false
    $venvPath = '.venv'
    if ($cfg) {
        if ($cfg.PSObject.Properties.Name -contains 'useVenv') { $useVenv = [bool]$cfg.useVenv }
        if ($cfg.PSObject.Properties.Name -contains 'venvPath' -and $cfg.venvPath) { $venvPath = [string]$cfg.venvPath }
    }
    $base = Resolve-ToolExe -Candidates @('python3', 'python')
    if (-not $base) { return $null }
    if ($useVenv) {
        if (-not [System.IO.Path]::IsPathRooted($venvPath)) { $venvPath = Join-Path $ProjectDir $venvPath }
        # NOT $isWindows: read-only automatic variable since PowerShell 6.0, so
        # this assignment silently no-op'd and the HOST decided the venv layout
        # instead of the declared State.OS.
        $onWindows = $State -and ($State.PSObject.Properties.Name -contains 'OS') -and ([string]$State.OS -eq 'Windows')
        $pythonPath = if ($onWindows) { Join-Path $venvPath 'Scripts/python.exe' } else { Join-Path $venvPath 'bin/python' }
        if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf) -and $Create) {
            $created = Invoke-PluginCommandResult -ScriptBlock { param($exe, $dir) & $exe -m venv $dir } -State $State -ProjectDir $ProjectDir -ArgumentList @($base, $venvPath) -Label 'Creating Python virtual environment...'
            if (-not $created.Succeeded) { return $null }
        }
        if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { return $null }
        $base = $pythonPath
    }
    $pip = Invoke-PluginCommandResult -ScriptBlock { param($exe) & $exe -m pip --version } -State $State -ProjectDir $ProjectDir -ArgumentList @($base) -Label 'Checking Python pip...'
    if (-not $pip.Succeeded) { return $null }
    $pytest = Get-Command pytest -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $ruff = Get-Command ruff -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($useVenv) {
        $pytestPath = if ($onWindows) { Join-Path $venvPath 'Scripts/pytest.exe' } else { Join-Path $venvPath 'bin/pytest' }
        $ruffPath = if ($onWindows) { Join-Path $venvPath 'Scripts/ruff.exe' } else { Join-Path $venvPath 'bin/ruff' }
        if (Test-Path -LiteralPath $pytestPath -PathType Leaf) { $pytest = [PSCustomObject]@{ Path = $pytestPath; Source = $pytestPath } }
        if (Test-Path -LiteralPath $ruffPath -PathType Leaf) { $ruff = [PSCustomObject]@{ Path = $ruffPath; Source = $ruffPath } }
    }
    return [PSCustomObject]@{ Python = $base; Pip = $pip; VenvPath = $(if ($useVenv) { $venvPath } else { '' }); Pytest = $pytest; Ruff = $ruff }
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pyproject.toml', 'setup.py', 'setup.cfg')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'python.build' -ReasonCode 'ManifestMissing' -Message 'Python project manifest was not found'; if ($Detailed) { return $r }; return $false }
    $runtime = Resolve-PythonRuntime -State $State -ProjectDir $ProjectDir -Create
    if (-not $runtime) { $r = New-PluginActionResult -Status Failed -Operation 'python.build' -ReasonCode 'PythonRuntimeMissing' -Message 'Python and pip are required'; if ($Detailed) { return $r }; return $false }
    $args = @('-m', 'pip', 'install', '-e', '.', '--no-deps')
    $result = Invoke-PluginCommandResult -ScriptBlock { param($python, $pipArgs) & $python @pipArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($runtime.Python, $args) -Label 'Installing Python package...'
    if ($Detailed) { if ($result.Succeeded) { $out = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'python'; $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $out -Force }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pyproject.toml', 'setup.py', 'setup.cfg')
    $hasTests = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Include 'test_*.py', '*_test.py' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](.venv|venv|build|dist)[\\/]' }).Count -gt 0
    if (-not $manifest -or -not $hasTests) { $r = New-PluginActionResult -Status Skipped -Operation 'python.test' -ReasonCode 'NoTests' -Message 'No Python test suite was found'; if ($Detailed) { return $r }; return $false }
    $runtime = Resolve-PythonRuntime -State $State -ProjectDir $ProjectDir
    if (-not $runtime -or -not $runtime.Pytest) { $r = New-PluginActionResult -Status Skipped -Operation 'python.test' -ReasonCode 'ToolMissing' -Message 'pytest is not available in the selected Python environment'; if ($Detailed) { return $r }; return $false }
    $pytest = if ($runtime.Pytest.Source) { [string]$runtime.Pytest.Source } else { [string]$runtime.Pytest.Path }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($tool) & $tool -v } -State $State -ProjectDir $ProjectDir -ArgumentList @($pytest) -Label 'Running pytest...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $runtime = Resolve-PythonRuntime -State $State -ProjectDir $ProjectDir
    if (-not $runtime -or -not $runtime.Ruff) { $r = New-PluginActionResult -Status Skipped -Operation 'python.lint' -ReasonCode 'ToolMissing' -Message 'ruff is not available in the selected Python environment'; if ($Detailed) { return $r }; return $false }
    $ruff = if ($runtime.Ruff.Source) { [string]$runtime.Ruff.Source } else { [string]$runtime.Ruff.Path }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($tool) & $tool check . } -State $State -ProjectDir $ProjectDir -ArgumentList @($ruff) -Label 'Running ruff check...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pyproject.toml', 'setup.py', 'setup.cfg')
    if (-not $manifest) { $errors += 'Missing manifest: pyproject.toml/setup.py/setup.cfg' }
    $runtime = Resolve-PythonRuntime -State $State -ProjectDir $ProjectDir -Create
    if (-not $runtime) { $errors += 'Python with pip is not available' } else { if (-not $runtime.Pytest) { $warnings += 'pytest is not available' }; if (-not $runtime.Ruff) { $warnings += 'ruff is not available' } }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

$script:CustomClean = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Detailed)
    # Safe artifact clean: removes only well-known build output beneath the
    # project root. No project root -> Refuse via the containment guard.
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pyproject.toml', 'setup.py', 'setup.cfg')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'python.clean' -ReasonCode 'ManifestMissing' -Message 'Python project manifest was not found'; if ($Detailed) { return $r }; return $false }
    $targets = @('build', 'dist') + @(Get-ChildItem -LiteralPath $ProjectDir -Directory -Filter '*.egg-info' -ErrorAction SilentlyContinue).Name
    $removed = 0
    foreach ($name in $targets) {
        $candidate = Join-Path $ProjectDir $name
        $ok = $false
        if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) { try { $ok = Test-PathUnderRoots -Path $candidate -AllowedRoots @($ProjectDir) } catch { $ok = $false } }
        else { try { $full = [System.IO.Path]::GetFullPath($candidate); $root = [System.IO.Path]::GetFullPath($ProjectDir); $ok = $full.StartsWith($root) } catch { $ok = $false } }
        if (-not $ok) { continue }
        try { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop; $removed++ } } catch { }
    }
    if ($Detailed) { return New-PluginActionResult -Status Succeeded -Operation 'python.clean' -ReasonCode 'OK' -Message ("Removed $removed build artifact(s)") }
    return $true
}

$script:CustomRun = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [string]$Arguments = '', [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pyproject.toml', 'setup.py', 'setup.cfg')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'python.run' -ReasonCode 'ManifestMissing' -Message 'Python project manifest was not found'; if ($Detailed) { return $r }; return $false }
    $entry = @()
    foreach ($candidate in @('__main__.py', 'main.py', 'app.py')) {
        foreach ($dir in @($ProjectDir, (Join-Path $ProjectDir 'src'))) {
            $full = Join-Path $dir $candidate
            if (Test-Path -LiteralPath $full -PathType Leaf) { $entry = $full; break }
        }
        if ($entry) { break }
    }
    if (-not $entry) { $r = New-PluginActionResult -Status Skipped -Operation 'python.run' -ReasonCode 'NoEntryPoint' -Message 'No main.py/__main__.py entry point found'; if ($Detailed) { return $r }; return $false }
    $runtime = Resolve-PythonRuntime -State $State -ProjectDir $ProjectDir
    if (-not $runtime) { $r = New-PluginActionResult -Status Skipped -Operation 'python.run' -ReasonCode 'ToolMissing' -Message 'Python runtime is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($py, $entryPath, $extra) & $py $entryPath $extra } -State $State -ProjectDir $ProjectDir -ArgumentList @($runtime.Python, $entry, $Arguments) -Label 'Running Python entry point...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

# Export list derived from the shared contract instead of a 5th copy of it.
# This literal was byte-identical in all 14 plugins (plus 2 in Loader and 2 in
# the test suite = 18 encodings of one contract). BasePlugin.ps1 is dot-sourced
# at the top of this file and owns the canonical list.
Export-ModuleMember -Function @(
    (Get-BasePluginContractFunctions)
    # Optional lifecycle verbs. Present in every plugin via BasePlugin, so the
    # dispatchers in Loader stay wired even when a plugin has no implementation.
    'Invoke-PluginClean'
    'Invoke-PluginRun'
)
