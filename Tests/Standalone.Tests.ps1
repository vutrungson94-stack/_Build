#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Standalone.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe 'Standalone packaging' {
    BeforeAll {
function New-StandaloneTestState {
    param(
        [string]$Root,
        [string]$OutputPath = '',
        [bool]$IncludeConfig = $false,
        [bool]$EmbedLocales = $true,
        [PSCustomObject]$Security
    )
    if ($null -eq $Security) { $Security = [PSCustomObject]@{} }
    return [PSCustomObject]@{
        ScriptRoot = $Root
        BuildConfig = [PSCustomObject]@{
            build = [PSCustomObject]@{
                standalone = [PSCustomObject]@{
                    enabled = $true
                    outputFile = $OutputPath
                    includeConfig = $IncludeConfig
                    embedLocales = $EmbedLocales
                    bundleVersion = '1.0.0'
                }
            }
            security = $Security
        }
    }
}

function New-MinimalStandaloneBundle {
    param([string]$Root)
    [void][System.IO.Directory]::CreateDirectory($Root)
    $files = [System.Collections.Generic.List[object]]::new()
    $requiredPaths = @('gbuild.ps1', 'Modules/ModuleBootstrap.ps1', 'Modules/Orchestrator.psm1', 'Modules/Loader.psm1', 'Modules/Plugins/BasePlugin.ps1', 'gbuild.config.schema.json', 'gbuild.plugin.schema.json')
    foreach ($relative in $requiredPaths) {
        $source = Join-Path $Root ($relative.Replace('/', '\'))
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $source))
        [System.IO.File]::WriteAllBytes($source, [System.Text.Encoding]::UTF8.GetBytes('SAMPLE'))
        $files.Add(@{ RelPath = $relative; FullPath = $source; Required = $true })
    }
    $source = Join-Path $Root 'gbuild.ps1'
    $manifest = New-StandaloneManifest -FileList $files -Version '9.9.9'
    $payload = ConvertTo-Base64Payload -FileList $files -Strict -Manifest $manifest -Version '9.9.9'
    $output = Join-Path $Root 'minimal-bundle.ps1'
    $result = New-StandaloneBundleScript -State ([PSCustomObject]@{ ScriptRoot = $Root }) -OutputPath $output -PayloadLines $payload -Version '9.9.9' -Manifest $manifest
    return [PSCustomObject]@{ Result = $result; Path = $output }
}

function Get-StandaloneBundleManifest {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $needle = '$manifestBase64 = '''
    $start = $text.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'Bundle manifest assignment not found' }
    $start += $needle.Length
    $end = $text.IndexOf("'", $start, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'Bundle manifest terminator not found' }
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($text.Substring($start, $end - $start)))
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Set-StandaloneBundleManifest {
    param([string]$Path, $Manifest)
    $text = [System.IO.File]::ReadAllText($Path)
    $needle = '$manifestBase64 = '''
    $start = $text.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'Bundle manifest assignment not found' }
    $valueStart = $start + $needle.Length
    $end = $text.IndexOf("'", $valueStart, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'Bundle manifest terminator not found' }
    $json = $Manifest | ConvertTo-Json -Depth 10 -Compress
    $base64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    return $text.Substring(0, $valueStart) + $base64 + $text.Substring($end)
}

function Set-StandaloneBundlePayload {
    param([string]$Path, [string]$OldPath, [string]$NewPath, [string]$Base64)
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^' + [regex]::Escape($OldPath) + ';[A-Za-z0-9+/=]+$'
    $regex = [regex]::new($pattern)
    $replacement = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $NewPath + ';' + $Base64 }
    $updated = $regex.Replace($text, $replacement, 1)
    if ($updated -eq $text) { throw "Payload path '$OldPath' not found" }
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-StandaloneBundlePayload {
    param([string]$Path, [string]$RelPath)
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^' + [regex]::Escape($RelPath) + ';[A-Za-z0-9+/=]+\n'
    $regex = [regex]::new($pattern)
    $updated = $regex.Replace($text, '', 1)
    if ($updated -eq $text) { throw "Payload path '$RelPath' not found" }
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
}

function Duplicate-StandaloneBundlePayload {
    param([string]$Path, [string]$RelPath)
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^' + [regex]::Escape($RelPath) + ';[A-Za-z0-9+/=]+$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "Payload path '$RelPath' not found" }
    $updated = $text.Substring(0, $match.Index + $match.Length) + "`n" + $match.Value + $text.Substring($match.Index + $match.Length)
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-StandaloneBundleProcess {
    param([string]$Path, [string]$TempRoot = '', [switch]$SyntaxCheck)
    if ($TempRoot) { [void][System.IO.Directory]::CreateDirectory($TempRoot) }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $hostName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $startInfo.FileName = [string](@(Get-Command $hostName -CommandType Application -ErrorAction Stop)[0].Source)
    $mode = if ($SyntaxCheck) { '-SyntaxCheck' } else { '-SelfTest' }
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Path + '" ' + $mode
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($TempRoot) {
        $startInfo.EnvironmentVariables['TMP'] = $TempRoot
        $startInfo.EnvironmentVariables['TEMP'] = $TempRoot
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Output = ($stdoutTask.Result + $stderrTask.Result)
    }
}
    }

    It 'Get-StandaloneConfig returns null when State has no build.standalone' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
        Get-StandaloneConfig -State $state | Should -BeNullOrEmpty
    }

    It 'Get-StandaloneConfig reads the build.standalone section correctly' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ standalone = [PSCustomObject]@{ enabled = $true; outputFile = 'out.ps1' } } } }
        $cfg = Get-StandaloneConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.outputFile | Should -Be 'out.ps1'
    }

    It 'Get-StandaloneOutputPath uses the default name under ScriptRoot' {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ standalone = [PSCustomObject]@{ outputFile = 'gbuild-standalone.ps1' } } } }
        Get-StandaloneOutputPath -State $state | Should -Be (Join-Path $TestDrive 'gbuild-standalone.ps1')
    }

    It 'Get-StandaloneOutputPath keeps an absolute path' {
        $absolute = Join-Path $TestDrive 'custom-bundle.ps1'
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ standalone = [PSCustomObject]@{ outputFile = $absolute } } } }
        Get-StandaloneOutputPath -State $state | Should -Be $absolute
    }

    It 'Get-EmbeddedFiles returns deterministic canonical deduplicated runtime resources' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $state = New-StandaloneTestState -Root $buildRoot -EmbedLocales $true
        $files = Get-EmbeddedFiles -State $state
        $paths = [string[]]@($files | ForEach-Object { $_.RelPath })
        $expected = [string[]]$paths.Clone()
        [Array]::Sort($expected, [System.StringComparer]::OrdinalIgnoreCase)
        ($paths -join "`n") | Should -Be ($expected -join "`n")
        $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $paths) { [void]$unique.Add($path) }
        $unique.Count | Should -Be $paths.Count
        $paths | Should -Contain 'gbuild.ps1'
        $paths | Should -Contain 'Modules/ModuleBootstrap.ps1'
        $paths | Should -Contain 'Modules/Plugins/BasePlugin.ps1'
        $paths | Should -Contain 'Modules/Plugins/helpers/PluginHelpers.psm1'
        $paths | Should -Contain 'Modules/Providers/EnvironmentProvider.psm1'
        $paths | Should -Contain 'gbuild.config.schema.json'
        $paths | Should -Contain 'gbuild.plugin.schema.json'
        $paths | Should -Contain 'Hooks/before-build/01-env-validation.ps1'
        $paths | Should -Contain 'Steps/publish-artifact.ps1'
        $paths | Should -Contain 'Locales/en.json'
        ($paths -join "`n") | Should -Not -Match '(^|/)(\.git|\.gbuildcache|\.tools|logs?|reports?|cache|vendor|secrets?|state)(/|$)'
        $moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'Modules') -Recurse -File -Filter '*.psm1')
        @($files | Where-Object { $_.RelPath -like 'Modules/*.psm1' -or $_.RelPath -like 'Modules/*/*.psm1' -or $_.RelPath -like 'Modules/*/*/*.psm1' }).Count | Should -Be $moduleFiles.Count
        @($files | Where-Object { $_.RelPath -like 'Modules/Plugins/*.plugin.json' }).Count | Should -Be @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'Modules/Plugins') -File -Filter '*.plugin.json').Count
    }

    It 'Get-EmbeddedFiles honors locale and optional config switches' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $withoutOptional = Get-EmbeddedFiles -State (New-StandaloneTestState -Root $buildRoot -EmbedLocales $false -IncludeConfig $false)
        @($withoutOptional | Where-Object { $_.RelPath -like 'Locales/*' -or $_.RelPath -eq 'gbuild.config.json' }).Count | Should -Be 0
        $withOptional = Get-EmbeddedFiles -State (New-StandaloneTestState -Root $buildRoot -EmbedLocales $true -IncludeConfig $true)
        @($withOptional | Where-Object { $_.RelPath -eq 'Locales/en.json' }).Count | Should -Be 1
        @($withOptional | Where-Object { $_.RelPath -eq 'gbuild.config.json' }).Count | Should -Be 1
    }

    It 'New-StandaloneManifest records sorted size SHA-256 required and version' {
        $first = Join-Path $TestDrive 'a.txt'
        $second = Join-Path $TestDrive 'b.txt'
        [System.IO.File]::WriteAllText($first, 'alpha', (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($second, 'beta', (New-Object System.Text.UTF8Encoding($false)))
        $files = @(
            @{ RelPath = 'b.txt'; FullPath = $second; Required = $false }
            @{ RelPath = 'a.txt'; FullPath = $first; Required = $true }
        )
        $manifest = New-StandaloneManifest -FileList $files -Version '2.3.4'
        $manifest.version | Should -Be '2.3.4'
        ($manifest.files.path -join ',') | Should -Be 'a.txt,b.txt'
        $manifest.files[0].size | Should -Be 5
        $manifest.files[0].sha256 | Should -Match '^[0-9A-F]{64}$'
        $manifest.files[0].required | Should -BeTrue
        $manifest.files[1].required | Should -BeFalse
    }

    It 'New-StandaloneManifest rejects duplicate missing and empty files' {
        $existing = Join-Path $TestDrive 'exists.txt'
        $empty = Join-Path $TestDrive 'empty.txt'
        [System.IO.File]::WriteAllText($existing, 'x', (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllBytes($empty, [byte[]]@())
        { New-StandaloneManifest -FileList @(@{ RelPath = 'missing.txt'; FullPath = (Join-Path $TestDrive 'missing.txt'); Required = $true }) -Version '1.0.0' } | Should -Throw '*missing*'
        { New-StandaloneManifest -FileList @(@{ RelPath = 'empty.txt'; FullPath = $empty; Required = $true }) -Version '1.0.0' } | Should -Throw '*empty*'
        { New-StandaloneManifest -FileList @(@{ RelPath = 'exists.txt'; FullPath = $existing; Required = $true }, @{ RelPath = 'EXISTS.txt'; FullPath = $existing; Required = $true }) -Version '1.0.0' } | Should -Throw '*Duplicate*'
    }

    It 'ConvertTo-Base64Payload preserves the backward API and rejects strict hash drift' {
        $tmp = Join-Path $TestDrive 'sample.txt'
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('hello')
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        $file = @{ RelPath = 'sample.txt'; FullPath = $tmp; Required = $true }
        $payload = ConvertTo-Base64Payload -FileList @($file)
        $payload[0] | Should -Match '^sample\.txt;[A-Za-z0-9+/=]+$'
        $manifest = New-StandaloneManifest -FileList @($file) -Version '1.0.0'
        [System.IO.File]::WriteAllText($tmp, 'changed!', (New-Object System.Text.UTF8Encoding($false)))
        { ConvertTo-Base64Payload -FileList @($file) -Strict -Manifest $manifest -Version '1.0.0' } | Should -Throw '*SHA-256 changed*'
        $payload = ConvertTo-Base64Payload -FileList @(@{ RelPath = 'empty.txt'; FullPath = (Join-Path $TestDrive 'missing.txt') })
        $payload[0] | Should -Be 'empty.txt;'
    }

    It 'New-StandaloneBundleScript keeps the backward payload API and emits a manifest' {
        $out = Join-Path $TestDrive 'bundle.ps1'
        $payload = @('gbuild.ps1;U0FNUExF', '=M0RF')
        $result = New-StandaloneBundleScript -State ([PSCustomObject]@{ ScriptRoot = $TestDrive }) -OutputPath $out -PayloadLines $payload -Version '9.9.9'
        $result.Status | Should -Be 'OK'
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '\$payload = @'''
        $text | Should -Match 'function Restore-StandaloneFiles'
        (Get-StandaloneBundleManifest -Path $out).version | Should -Be '9.9.9'
    }

    It 'New-StandaloneBundle returns Skipped when build.standalone.enabled=false' {
        $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ standalone = [PSCustomObject]@{ enabled = $false } } } }
        (New-StandaloneBundle -State $state).Status | Should -Be 'Skipped'
    }

    It 'generates byte-identical LF-only bundles' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $firstPath = Join-Path $TestDrive 'first.ps1'
        $secondPath = Join-Path $TestDrive 'second.ps1'
        $state = New-StandaloneTestState -Root $buildRoot -EmbedLocales $true
        $first = New-StandaloneBundle -State $state -OutputPath $firstPath
        $second = New-StandaloneBundle -State $state -OutputPath $secondPath
        $first.Status | Should -Be 'OK'
        $second.Status | Should -Be 'OK'
        $first.SHA256 | Should -Be $second.SHA256
        $first.ManifestSHA256 | Should -Be $second.ManifestSHA256
        $bytes = [System.IO.File]::ReadAllBytes($firstPath)
        ($bytes -contains 13) | Should -BeFalse
    }

    It 'rejects a missing payload file and cleans the extraction directory' {
        $bundle = New-MinimalStandaloneBundle -Root (Join-Path $TestDrive 'missing')
        Remove-StandaloneBundlePayload -Path $bundle.Path -RelPath 'gbuild.ps1'
        $tempRoot = Join-Path $TestDrive 'missing-temp'
        $run = Invoke-StandaloneBundleProcess -Path $bundle.Path -TempRoot $tempRoot
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'missing manifest files|order mismatch'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'rejects duplicate payload paths and cleans the extraction directory' {
        $bundle = New-MinimalStandaloneBundle -Root (Join-Path $TestDrive 'duplicate')
        Duplicate-StandaloneBundlePayload -Path $bundle.Path -RelPath 'gbuild.ps1'
        $tempRoot = Join-Path $TestDrive 'duplicate-temp'
        $run = Invoke-StandaloneBundleProcess -Path $bundle.Path -TempRoot $tempRoot
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'Duplicate standalone payload path|order mismatch'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'rejects a manifest hash mismatch and cleans the extraction directory' {
        $bundle = New-MinimalStandaloneBundle -Root (Join-Path $TestDrive 'hash')
        $tampered = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('TAMPLE'))
        Set-StandaloneBundlePayload -Path $bundle.Path -OldPath 'gbuild.ps1' -NewPath 'gbuild.ps1' -Base64 $tampered
        $tempRoot = Join-Path $TestDrive 'hash-temp'
        $run = Invoke-StandaloneBundleProcess -Path $bundle.Path -TempRoot $tempRoot
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'SHA-256 verification failed'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'blocks path traversal before extraction and cleans the extraction directory' {
        $bundle = New-MinimalStandaloneBundle -Root (Join-Path $TestDrive 'traversal')
        $manifest = Get-StandaloneBundleManifest -Path $bundle.Path
        $traversal = '../escaped.txt'
        $gbuildEntry = @($manifest.files | Where-Object { $_.path -eq 'gbuild.ps1' })
        $gbuildEntry[0].path = $traversal
        $text = Set-StandaloneBundleManifest -Path $bundle.Path -Manifest $manifest
        [System.IO.File]::WriteAllText($bundle.Path, $text, (New-Object System.Text.UTF8Encoding($false)))
        $base64 = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('SAMPLE'))
        Set-StandaloneBundlePayload -Path $bundle.Path -OldPath 'gbuild.ps1' -NewPath $traversal -Base64 $base64
        $tempRoot = Join-Path $TestDrive 'traversal-temp'
        $run = Invoke-StandaloneBundleProcess -Path $bundle.Path -TempRoot $tempRoot
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'path traversal|not canonical'
        Test-Path -LiteralPath (Join-Path $tempRoot 'escaped.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'SelfTest verifies extraction manifest syntax imports plugin registration and manifest pairing' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $output = Join-Path $TestDrive 'full-bundle.ps1'
        $state = New-StandaloneTestState -Root $buildRoot -OutputPath $output -EmbedLocales $false
        $bundle = New-StandaloneBundle -State $state -OutputPath $output
        $bundle.Status | Should -Be 'OK'
        $bundle.Sidecars.Signing.Status | Should -Be 'Skipped'
        $bundle.Sidecars.SBOM.Status | Should -Be 'Skipped'
        $bundle.Sidecars.Provenance.Status | Should -Be 'Skipped'
        $tempRoot = Join-Path $TestDrive 'selftest-temp'
        $run = Invoke-StandaloneBundleProcess -Path $output -TempRoot $tempRoot
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match '\[SELFTEST\] PASS: .*manifest verified'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'verifies the manifest before normal SyntaxCheck execution and cleans the extraction directory' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $output = Join-Path $TestDrive 'normal-bundle.ps1'
        $state = New-StandaloneTestState -Root $buildRoot -OutputPath $output -EmbedLocales $false
        $bundle = New-StandaloneBundle -State $state -OutputPath $output
        $bundle.Status | Should -Be 'OK'
        $tempRoot = Join-Path $TestDrive 'normal-temp'
        $run = Invoke-StandaloneBundleProcess -Path $output -TempRoot $tempRoot -SyntaxCheck
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match '\[SYNTAX\] OK:'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }

    It 'marks the bundle Failed when an enabled sidecar helper fails' {
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $output = Join-Path $TestDrive 'sidecar-failure-bundle.ps1'
        $security = [PSCustomObject]@{
            artifactSign = [PSCustomObject]@{ enabled = $true }
            sbom = [PSCustomObject]@{ enabled = $false }
            provenance = [PSCustomObject]@{ enabled = $false }
        }
        $state = New-StandaloneTestState -Root $buildRoot -OutputPath $output -EmbedLocales $false -Security $security
        Mock -CommandName Get-StandaloneBundleSignature -ModuleName Standalone { @{ Status = 'Failed'; Reason = 'forced signing failure'; ArtifactPath = '' } }
        Mock -CommandName New-StandaloneBundleSupplyChain -ModuleName Standalone { @{ Status = 'Skipped'; Reason = ''; SBOM = @{ Status = 'Skipped'; Reason = ''; ArtifactPath = '' }; Provenance = @{ Status = 'Skipped'; Reason = ''; ArtifactPath = '' } } }
        $result = New-StandaloneBundle -State $state -OutputPath $output
        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Match 'forced signing failure'
        $result.Sidecars.Signing.Status | Should -Be 'Failed'
    }

    It 'reports optional sidecars as Skipped and enabled helper failures as Failed' {
        $bundlePath = Join-Path $TestDrive 'sidecars.ps1'
        [System.IO.File]::WriteAllText($bundlePath, 'bundle', (New-Object System.Text.UTF8Encoding($false)))
        $disabled = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sbom = [PSCustomObject]@{ enabled = $false }; provenance = [PSCustomObject]@{ enabled = $false }; artifactSign = [PSCustomObject]@{ enabled = $false } } } }
        $skipped = Get-StandaloneBundleSignature -BundlePath $bundlePath -State $disabled -Detailed
        $skipped.Status | Should -Be 'Skipped'
        $skippedSupply = New-StandaloneBundleSupplyChain -BundlePath $bundlePath -State $disabled -Detailed
        $skippedSupply.Status | Should -Be 'Skipped'
        $skippedSupply.SBOM.Status | Should -Be 'Skipped'
        $skippedSupply.Provenance.Status | Should -Be 'Skipped'
        $enabled = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ sbom = [PSCustomObject]@{ enabled = $true }; provenance = [PSCustomObject]@{ enabled = $false } } } }
        Mock -CommandName New-BuildSbom -ModuleName Standalone { throw 'forced SBOM failure' }
        $failed = New-StandaloneBundleSupplyChain -BundlePath $bundlePath -State $enabled -Detailed
        $failed.Status | Should -Be 'Failed'
        $failed.SBOM.Status | Should -Be 'Failed'
        $failed.Provenance.Status | Should -Be 'Skipped'
    }

    It 'Write-BuildJsonFile atomically replaces JSON and removes unique temp files on failure' {
        $path = Join-Path $TestDrive 'state.json'
        Write-BuildJsonFile -Path $path -Data @{ value = 1 } -Atomic | Should -BeTrue
        Write-BuildJsonFile -Path $path -Data @{ value = 2 } -Atomic | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).value | Should -Be 2
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.state.json.*.tmp' -Force).Count | Should -Be 0
        $destinationDirectory = Join-Path $TestDrive 'not-a-file'
        [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
        Write-BuildJsonFile -Path $destinationDirectory -Data @{ value = 3 } -Atomic | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.not-a-file.*.tmp' -Force).Count | Should -Be 0
    }

    It 'Get-StandaloneOutputPath throws instead of emitting the bundle into the CWD' {
        # The old CWD fallback made the Test-SafePath containment check circular
        # ($root IS the CWD), so any standalone.outputFile under the launch
        # directory passed and the bundle landed outside the tool tree.
        $origLoc = $PWD.Path
        $cwd = Join-Path $TestDrive 'cwdcheck'
        $null = New-Item -ItemType Directory -Path $cwd -Force
        try {
            Set-Location -LiteralPath $cwd
            { Get-StandaloneOutputPath -State ([PSCustomObject]@{}) } | Should -Throw
            { Get-StandaloneOutputPath -State ([PSCustomObject]@{ ScriptRoot = '.' }) } | Should -Throw
            @(Get-ChildItem -LiteralPath $cwd -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally { Set-Location -LiteralPath $origLoc }
    }
}
