#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$global:GBuildStepsDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Steps'
$global:GBuildHooksDir   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Hooks'
$global:GBuildTestRoot   = Split-Path -Parent $PSCommandPath
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Steps and Hooks scripts" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
        $global:td = New-IntegrationTempDir
        # State consumed by Write-Log / Resolve-ConfigValue (both exported by Logging.psm1).
        $global:state = [PSCustomObject]@{
            ScriptRoot  = $global:td
            ProjectRoot = $global:td
            WorkingDir  = $global:td
            BuildConfig = [PSCustomObject]@{ }
            Colors      = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
            OS          = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel    = 3
        }
        # Steps that drive at body-time read $global:GState.
        $global:GState = [PSCustomObject]@{ ScriptRoot=$global:td; ProjectRoot=$global:td; BuildConfig=$null; LogLevel=3 }
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if (Test-Path $global:td) { Remove-Item $global:td -Recurse -Force -EA 0 }
        Remove-Variable -Name GState -Scope Global -Force -EA 0
    }

    It "manage-githooks.ps1 functions are defined after dot-sourcing and run without throwing" {
        $hookRepo = Join-Path $global:td 'repo'
        New-Item -ItemType Directory -Path (Join-Path $hookRepo '.git/hooks') -Force | Out-Null
        # Dot-source WITH arguments so $RepoPath binds; templates dir (_Build\Hooks\git)
        # is intentionally absent, so Install/Get/Remove degrade gracefully.
        . (Join-Path $global:GBuildStepsDir 'manage-githooks.ps1') -RepoPath $hookRepo -HookTypes @('pre-commit','pre-push','post-commit')
        Get-Command Install-Hooks -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Remove-Hooks -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-HookList -ErrorAction SilentlyContinue  | Should -Not -BeNullOrEmpty
        { Install-Hooks } | Should -Not -Throw
        { Get-HookList }  | Should -Not -Throw
        { Remove-Hooks }  | Should -Not -Throw
    }

    It "pipeline-diagram.ps1 generates a Mermaid flowchart without throwing" {
        # Pass an explicit State so the output location is deterministic. The
        # script falls back to Resolve-BuildState (and then to the ambient
        # $global:GState) when given none, so in a full-suite run a leftover
        # GState from an earlier scope sent the diagram to a different project.
        $diagRoot = Join-Path $global:td 'diagram-out'
        New-Item -ItemType Directory -Path $diagRoot -Force | Out-Null
        $diagState = [PSCustomObject]@{
            ScriptRoot  = $global:td
            ProjectRoot = $diagRoot
            WorkingDir  = $diagRoot
        }
        { . (Join-Path $global:GBuildStepsDir 'pipeline-diagram.ps1') -State $diagState } | Should -Not -Throw
        # pipeline-diagram.ps1 resolves its output dir from report.outputDir
        # (build-reports), NOT the old 'reports' dir. This assertion used to be
        # wrapped in `if (Test-Path ...)` against the stale path, so it passed
        # vacuously and never verified the diagram was produced at all.
        $diag = Join-Path (Join-Path $diagRoot 'build-reports') 'pipeline-diagram.md'
        Test-Path $diag | Should -BeTrue
        $content = Get-Content -LiteralPath $diag -Raw
        ($content -match 'flowchart' -or $content -match 'graph') | Should -Be $true
        Remove-Item $diag -Force -EA 0
    }

    It "publish-artifact.ps1 creates a zip artifact from a source dir without throwing" {
        $src = Join-Path $global:td 'src'; $out = Join-Path $global:td 'out'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        Set-Content -Path (Join-Path $src 'file.txt') -Value 'hello' -Force
        { & (Join-Path $global:GBuildStepsDir 'publish-artifact.ps1') -SourceDir $src -OutputDir $out -Zip } | Should -Not -Throw
        Test-Path (Join-Path $out 'build-output.zip') | Should -Be $true
    }

    It "publish-artifact.ps1 supports State-only invocation (Orchestrator enabled-path shape)" {
        # Mirrors exactly how the Orchestrator PublishArtifact step calls it:
        # `& $artifactStep -State $State`. Source/Output dirs resolve from
        # config defaults (paths.publishOutput / build-reports under ScriptRoot).
        $w = Join-Path $global:td 'artifact-state'
        $pub = Join-Path $w 'publish-output'
        New-Item -ItemType Directory -Path $pub -Force | Out-Null
        Set-Content -Path (Join-Path $pub 'app.dll') -Value 'binary' -Force
        $st = [PSCustomObject]@{
            ScriptRoot  = $w
            ProjectRoot = $w
            WorkingDir  = $w
            BuildConfig = [PSCustomObject]@{ }
            Colors      = $global:state.Colors
            OS          = $global:state.OS
            LogLevel    = 3
        }
        { & (Join-Path $global:GBuildStepsDir 'publish-artifact.ps1') -State $st } | Should -Not -Throw
        Test-Path (Join-Path (Join-Path $w 'build-reports') 'build-output.zip') | Should -Be $true
    }

    It "publish-artifact.ps1 rejects archive names that escape output" {
        $src = Join-Path $global:td 'escape-src'; $out = Join-Path $global:td 'escape-out'
        New-Item -ItemType Directory -Path $src,$out -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'file.txt') -Value 'x'
        $outside = Join-Path $global:td 'escaped.zip'
        { & (Join-Path $global:GBuildStepsDir 'publish-artifact.ps1') -SourceDir $src -OutputDir $out -ArchiveName '..\escaped' -Zip -State $global:state } | Should -Not -Throw
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It "before-build hook folder script runs without throwing" {
        $hook = Join-Path (Join-Path $global:GBuildHooksDir 'before-build') '01-env-validation.ps1'
        Test-Path $hook | Should -Be $true
        { & $hook -State $global:state } | Should -Not -Throw
    }

    It "after-build hook folder script runs without throwing" {
        $hook = Join-Path (Join-Path $global:GBuildHooksDir 'after-build') '01-post-build.ps1'
        Test-Path $hook | Should -Be $true
        { & $hook -State $global:state -Success $true } | Should -Not -Throw
    }

    It "sign-gpg.ps1 has valid PowerShell syntax" {
        $p = Join-Path $global:GBuildStepsDir 'sign-gpg.ps1'
        Test-Path $p | Should -Be $true
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $p -Raw), [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It "sign-gpg.ps1 propagates signer failure" {
        $bin = Join-Path $TestDrive 'fake-gpg'; New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'gpg.cmd') -Value "@echo off`r`nexit /b 7"
        $oldPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$oldPath"
        $artifact = Join-Path $TestDrive 'artifact.zip'; Set-Content -LiteralPath $artifact -Value 'x'
        try {
            & (Join-Path $global:GBuildStepsDir 'sign-gpg.ps1') -Path $artifact -OutputDir $TestDrive -State $global:state
            $LASTEXITCODE | Should -Not -Be 0
        } finally { $env:PATH = $oldPath }
    }

    It "base config does not schedule a duplicate after-build vulnerability scan" {
        $configPath = Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.config.json'
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($config.hooks.'after-build').Count | Should -Be 0
    }

    It 'does not mutate post-build output without an explicit apply switch' {
        $root = Join-Path $global:td 'after-hook-readonly'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $state = [PSCustomObject]@{ ProjectRoot = $root; WorkingDir = $root; ScriptRoot = $root; BuildConfig = [PSCustomObject]@{} }
        & (Join-Path $global:GBuildHooksDir 'after-build/01-post-build.ps1') -State $state -Success $true
        Test-Path -LiteralPath (Join-Path $root 'CHANGELOG.md') | Should -BeFalse
    }

    It 'does not remove an unrelated git hook' {
        $repo = Join-Path $global:td 'unrelated-hook-repo'
        $hook = Join-Path $repo '.git/hooks/pre-commit'
        New-Item -ItemType Directory -Path (Split-Path -Parent $hook) -Force | Out-Null
        Set-Content -LiteralPath $hook -Value 'user-owned' -Encoding UTF8
        . (Join-Path $global:GBuildStepsDir 'manage-githooks.ps1') -RepoPath $repo -Remove -HookTypes @('pre-commit')
        Test-Path -LiteralPath $hook | Should -BeTrue
    }

    It 'git hook templates carry the same worktree-root walk' {
        # pre-commit/pre-push/post-commit are staged into .git/hooks/.gbuild
        # where no shared module is reachable, so the root discovery is an
        # inline walk by necessity (a git rev-parse replacement was probed and
        # reverted: from inside .git it exits 128 "must be run in a work
        # tree"). The walk must stay byte-identical in all three: it was
        # pasted 3 times and could otherwise diverge silently.
        $templates = @('pre-commit.ps1', 'pre-push.ps1', 'post-commit.ps1')
        $walks = @()
        foreach ($name in $templates) {
            $p = Join-Path (Join-Path $global:GBuildHooksDir 'git') $name
            Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue
            $text = Get-Content -LiteralPath $p -Raw
            $m = [regex]::Match($text, '(?s)(\$here = Split-Path -Parent \$MyInvocation\.MyCommand\.Path.*?\r?\n\})')
            $m.Success | Should -BeTrue -Because "$name must contain the shared worktree-root walk"
            $walks += $m.Groups[1].Value
        }
        $walks[1] | Should -Be $walks[0] -Because 'pre-push walk must stay byte-identical to pre-commit'
        $walks[2] | Should -Be $walks[0] -Because 'post-commit walk must stay byte-identical to pre-commit'
    }
}
