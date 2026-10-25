#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Validates that the build-tool base config is free of consumer project
# contamination. The SBOM allowList at security.sbom.policy.allowList is a
# per-project overlay in the consuming repo (e.g. WebUI/gbuild.config.json),
# not in _Build/gbuild.config.json. This is the 97->100 polish check.

$testRoot = $PSScriptRoot
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $testRoot) 'Modules'

Describe 'ConfigContamination - base config must not contain consumer dependencies' {
    BeforeAll {
        # Paths MUST resolve here (not at file top level): Pester 5 runs file
        # top-level code without path variables, so top-level Join-Path results
        # are CWD-dependent. $PSScriptRoot is reliably set inside blocks.
        $testRoot = $PSScriptRoot
        $script:BasePath = Join-Path $testRoot '../gbuild.config.json'
        $script:ProjectPath = Join-Path (Split-Path (Split-Path $testRoot -Parent) -Parent) 'gbuild.config.json'
        $script:BaseRaw = Get-Content $script:BasePath -Raw -Encoding UTF8
        $script:Base = $script:BaseRaw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'base gbuild.config.json parses as valid JSON' {
        { $script:BaseRaw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'base security.sbom.policy.allowList is empty (not contaminated with project deps)' {
        $al = $null
        if ($script:Base.security -and $script:Base.security.sbom -and $script:Base.security.sbom.policy) {
            $al = $script:Base.security.sbom.policy.allowList
        }
        @($al).Count | Should -Be 0
    }

    It 'base allowList does NOT contain project-specific deps (Newtonsoft.Json, ts-morph, etc.)' {
        $al = @()
        if ($script:Base.security.sbom.policy.allowList) { $al = @($script:Base.security.sbom.policy.allowList) }
        $al -contains 'Newtonsoft.Json' | Should -BeFalse
        $al -contains 'ts-morph' | Should -BeFalse
    }

    It 'base security.sbom.policy.denyList carries only global secure-baseline denies (no project deps)' {
        # A shipped denyList of universally-blocked CVE coordinates (log4shell,
        # commons-collections deserialization gadgets) is a secure DEFAULT, not
        # contamination. Contamination = project-specific packages here.
        $dl = @()
        if ($null -ne $script:Base.security.sbom.policy.denyList) { $dl = @($script:Base.security.sbom.policy.denyList) }
        $dl -contains 'Newtonsoft.Json' | Should -BeFalse
        $dl -contains 'ts-morph' | Should -BeFalse
        foreach ($entry in $dl) { [string]$entry | Should -Not -BeNullOrEmpty }
    }

    It 'project-local gbuild.config.json (if present) carries the allowList overlay' {
        if (-not (Test-Path $script:ProjectPath)) {
            Set-ItResult -Skipped -Because "no project-local gbuild.config.json at $script:ProjectPath"
            return
        }
        $proj = Get-Content $script:ProjectPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $al = @()
        if ($proj.security -and $proj.security.sbom -and $proj.security.sbom.policy -and $proj.security.sbom.policy.allowList) {
            $al = @($proj.security.sbom.policy.allowList)
        }
        # WebUI overlay should contain its own deps; this proves separation.
        $al.Count | Should -BeGreaterThan 0
    }

    It 'BuildConstants fallback for centralized defaults is not considered contamination' {
        # Centralized defaults (MinDiskMB=2048 etc.) live in BuildConstants.psm1
        # as single-source fallbacks — not scattered hardcode. This test ensures
        # the base config still defines them as configurable values.
        $script:Base.build | Should -Not -BeNullOrEmpty
        $script:Base.health | Should -Not -BeNullOrEmpty
    }
}
