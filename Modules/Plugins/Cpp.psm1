# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Cpp'
    SupportedLanguages = @('C/C++', 'C')
    Priority = 2
    ToolName = 'cmake'
    AnyToolNames = @('make')
    ManifestFiles = @('CMakeLists.txt', 'Makefile')
    BuildCommand = 'cmake --build build'
    TestCommand = 'ctest'
    LintCommand = 'cppcheck'
    CleanCommand = 'cmake --build build --target clean'
    RunCommand = ''
    LintToolName = 'cppcheck'
    MissingToolLevel = 'Gray'
    SoftFailLint = $true
}

function Get-CppConfig {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    if ($State -and $State.BuildConfig) { try { if ($State.BuildConfig.build -and $State.BuildConfig.build.cpp) { return $State.BuildConfig.build.cpp } } catch { } }
    return $null
}

function Resolve-CppCompiler {
    param([PSCustomObject]$State)
    $cfg = Get-CppConfig -State $State
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'compiler' -and $cfg.compiler) { return [string]$cfg.compiler }
    foreach ($name in @('cl', 'clang', 'clang++', 'gcc', 'g++')) { if (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) { return $name } }
    return ''
}

function Resolve-CppGenerator {
    param([PSCustomObject]$State)
    $cfg = Get-CppConfig -State $State
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'generator' -and $cfg.generator) { return [string]$cfg.generator }
    return ''
}

function Get-CppToolchain {
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$Configuration)
    $compiler = Resolve-CppCompiler -State $State
    $generator = Resolve-CppGenerator -State $State
    $errors = @()
    if (-not $compiler) { $errors += 'No C/C++ compiler was found' }
    $cmake = [bool](Get-Command cmake -CommandType Application -ErrorAction SilentlyContinue)
    $make = [bool](Get-Command make -CommandType Application -ErrorAction SilentlyContinue)
    if (-not $cmake -and -not $make) { $errors += 'Neither CMake nor make was found' }
    return [PSCustomObject]@{ Compiler = $compiler; Generator = $generator; CMake = $cmake; Make = $make; Errors = $errors }
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $cmakeManifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('CMakeLists.txt')
    $makeManifest = Resolve-PluginManifest -ProjectDir $ProjectDir -ManifestFiles @('Makefile')
    if (-not $cmakeManifest -and -not $makeManifest) { $r = New-PluginActionResult -Status Failed -Operation 'cpp.build' -ReasonCode 'ManifestMissing' -Message 'CMakeLists.txt or Makefile was not found'; if ($Detailed) { return $r }; return $false }
    $toolchain = Get-CppToolchain -State $State -ProjectDir $ProjectDir -Configuration $Configuration
    if ($toolchain.Errors.Count -gt 0) { $r = New-PluginActionResult -Status Failed -Operation 'cpp.build' -ReasonCode 'ToolchainMissing' -Message ($toolchain.Errors -join '; ') -Details $toolchain; if ($Detailed) { return $r }; return $false }
    if ($cmakeManifest -and $toolchain.CMake) {
        $buildDir = Join-Path $ProjectDir 'build'
        $marker = Join-Path $buildDir '.gbuild-toolchain'
        $identity = "$($toolchain.Compiler)|$($toolchain.Generator)"
        $reconfigure = -not (Test-Path -LiteralPath $marker)
        if (-not $reconfigure) { $reconfigure = ([string](Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)).Trim() -ne $identity }
        if ($reconfigure) {
            New-Item -ItemType Directory -Path $buildDir -Force -ErrorAction SilentlyContinue | Out-Null
            $args = @('-S', $ProjectDir, '-B', $buildDir, "-DCMAKE_BUILD_TYPE=$Configuration")
            if ($toolchain.Generator) { $args += @('-G', $toolchain.Generator) }
            $configure = Invoke-PluginCommandResult -ScriptBlock { param($cmakeArgs) & cmake @cmakeArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($args) -Label 'Configuring CMake...'
            if (-not $configure.Succeeded) { if ($Detailed) { return $configure }; return $false }
            [System.IO.File]::WriteAllText($marker, ($identity + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        }
        $buildArgs = @('--build', $buildDir, '--config', $Configuration)
        if (-not $Incremental) { $buildArgs += '--clean-first' }
        $result = Invoke-PluginCommandResult -ScriptBlock { param($cmakeArgs) & cmake @cmakeArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($buildArgs) -Label "Running CMake build ($Configuration)..."
        if ($Detailed) { if ($result.Succeeded) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $buildDir -Force }; return $result }
        return [bool]$result.Succeeded
    }
    $make = if ($toolchain.Make) { 'make' } else { '' }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($command) & $command } -State $State -ProjectDir $ProjectDir -ArgumentList @($make) -Label 'Running make...'
    if ($Detailed) { if ($result.Succeeded) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value (New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'cpp') -Force }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $cmakeManifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('CMakeLists.txt')
    if ($cmakeManifest -and (Get-Command ctest -CommandType Application -ErrorAction SilentlyContinue)) {
        $buildDir = Join-Path $ProjectDir 'build'
        if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) { $r = New-PluginActionResult -Status Skipped -Operation 'cpp.test' -ReasonCode 'BuildOutputMissing' -Message 'CMake build directory was not found'; if ($Detailed) { return $r }; return $false }
        $result = Invoke-PluginCommandResult -ScriptBlock { ctest --test-dir build --output-on-failure } -State $State -ProjectDir $ProjectDir -ArgumentList @($Configuration) -Label 'Running ctest...'
        if ($Detailed) { return $result }
        return [bool]$result.Succeeded
    }
    $makeManifest = Resolve-PluginManifest -ProjectDir $ProjectDir -ManifestFiles @('Makefile')
    if ($makeManifest -and (Get-Command make -CommandType Application -ErrorAction SilentlyContinue)) {
        $result = Invoke-PluginCommandResult -ScriptBlock { make test } -State $State -ProjectDir $ProjectDir -Label 'Running make test...'
        if ($Detailed) { return $result }
        return [bool]$result.Succeeded
    }
    $r = New-PluginActionResult -Status Skipped -Operation 'cpp.test' -ReasonCode 'ToolMissing' -Message 'No C/C++ test runner is available'; if ($Detailed) { return $r }; return $false
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('CMakeLists.txt', 'Makefile')
    if (-not $manifest -or -not (Get-Command cppcheck -CommandType Application -ErrorAction SilentlyContinue)) { $r = New-PluginActionResult -Status Skipped -Operation 'cpp.lint' -ReasonCode 'ToolMissing' -Message 'cppcheck is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { cppcheck --enable=warning,performance,portability --error-exitcode=1 . } -State $State -ProjectDir $ProjectDir -Label 'Running cppcheck...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('CMakeLists.txt', 'Makefile')
    if (-not $manifest) { $errors += 'Missing CMakeLists.txt or Makefile' }
    if ($manifest) { $preflightCfg = Resolve-PluginConfiguration -State $State; $toolchain = Get-CppToolchain -State $State -ProjectDir $ProjectDir -Configuration $preflightCfg; $errors += @($toolchain.Errors) }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

$script:CustomRun = {
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [string]$Arguments = '', [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('CMakeLists.txt', 'Makefile')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'cpp.run' -ReasonCode 'ManifestMissing' -Message 'CMakeLists.txt or Makefile was not found'; if ($Detailed) { return $r }; return $false }
    $buildDir = Join-Path $ProjectDir 'build'
    if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) { $r = New-PluginActionResult -Status Skipped -Operation 'cpp.run' -ReasonCode 'BuildOutputMissing' -Message 'Build directory was not found; run Build first'; if ($Detailed) { return $r }; return $false }
    $onWindows = $State -and ($State.PSObject.Properties.Name -contains 'OS') -and ([string]$State.OS -eq 'Windows')
    # A C/C++ project's runnable artifact lives under build/. Prefer an explicit
    # .exe on Windows and extensionless executables elsewhere. This is a best
    # effort preview, not a substitute for a project-specific run target.
    $candidates = @()
    if ($onWindows) { $candidates = @(Get-ChildItem -LiteralPath $buildDir -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 5) }
    else { $candidates = @(Get-ChildItem -LiteralPath $buildDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not $_.Extension -or $_.Extension -eq '.elf' } | Select-Object -First 5) }
    if (-not $candidates) { $r = New-PluginActionResult -Status Skipped -Operation 'cpp.run' -ReasonCode 'NoExecutable' -Message 'No runnable C/C++ artifact was found under build/'; if ($Detailed) { return $r }; return $false }
    $target = $candidates[0].FullName
    $result = Invoke-PluginCommandResult -ScriptBlock { param($t, $extra) & $t $extra } -State $State -ProjectDir $ProjectDir -ArgumentList @($target, $Arguments) -Label "Running $(Split-Path -Leaf $target)..."
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
