#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Validates the P0 fix: Config validation must NOT fail due to Windows env-var
# placeholders (e.g. ${env:APPDATA} -> C:\Users\...) containing backslashes.
# Backslashes are invalid JSON escapes (\U, \A) and caused
# "Cannot parse the JSON" on pwsh 7 where Test-Json -Schema exists.

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$global:GBuildTestRoot = Split-Path -Parent $PSCommandPath

Describe 'JsonValidation - env placeholder backslash regression' {
    BeforeAll {
        $script:ConfigPath = Join-Path $global:GBuildTestRoot '../gbuild.config.json'
        $script:SchemaPath = [System.IO.Path]::ChangeExtension($script:ConfigPath, '.schema.json')
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }

    It 'raw gbuild.config.json is valid JSON' {
        $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        { $null = $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'env-placeholder-safe JSON (replaced) is valid JSON' {
        $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        $safe = $raw -replace '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '/tmp/placeholder'
        { $null = $safe | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'env-placeholder-safe JSON passes schema on pwsh where Test-Json -Schema exists' {
        $testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
        $hasSchema = $testJsonCmd -and $testJsonCmd.Parameters.ContainsKey('Schema')
        if (-not $hasSchema) { Set-ItResult -Skipped -Because 'Test-Json -Schema not available on PS 5.1' ; return }
        $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        $safe = $raw -replace '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '/tmp/placeholder'
        $schema = Get-Content $script:SchemaPath -Raw -Encoding UTF8
        $r = $safe | Test-Json -Schema $schema -ErrorAction Stop
        $r | Should -BeTrue
    }

    It 'resolved JSON with Windows backslash WOULD fail schema (proves P0 root cause)' {
        $testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
        $hasSchema = $testJsonCmd -and $testJsonCmd.Parameters.ContainsKey('Schema')
        if (-not $hasSchema) { Set-ItResult -Skipped -Because 'Test-Json -Schema not available on PS 5.1' ; return }
        # Simulate Windows APPDATA env with backslashes injected via Resolve-EnvPlaceholder.
        $env:GBUILD_JSON_TEST_WINPATH = 'C:\Users\test\AppData\Roaming'
        try {
            $raw = '{ "path": "${env:GBUILD_JSON_TEST_WINPATH}" }'
            $resolved = Resolve-EnvPlaceholder -InputObject $raw
            $resolved | Should -Match 'C:\\Users'
            # Single backslash in JSON is invalid -> Test-Json must fail.
            { $null = $resolved | ConvertFrom-Json -ErrorAction Stop } | Should -Throw
            $fakeSchema = '{ "type": "object" }'
            { $null = $resolved | Test-Json -Schema $fakeSchema -ErrorAction Stop } | Should -Throw
        } finally {
            Remove-Item Env:\GBUILD_JSON_TEST_WINPATH -ErrorAction SilentlyContinue
        }
    }

    It 'Test-BuildConfig passes on current config even with APPDATA-style env injected' {
        # Exercises Orchestrator fix end-to-end: must use placeholder-safe json internally.
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $state = [PSCustomObject]@{
            ConfigPath  = $script:ConfigPath
            BuildConfig = (Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        # This used to hardcode an absolute Windows profile path belonging to the
        # author. That shipped a real account name into the repository, is a false
        # positive for every secret/path scanner pointed at the tree, and broke on
        # any machine where that user does not exist. A Windows-shaped path built
        # from $env:SystemDrive exercises the same backslash-escaping hazard with
        # no personal data in it.
        $old = $env:APPDATA
        $env:APPDATA = Join-Path ([string]$env:SystemDrive) 'Users/gbuild-test/AppData/Roaming'
        try {
            # Test-BuildConfig with Strict=false should return $true (non-throwing)
            $r = Test-BuildConfig -State $state
            $r | Should -BeTrue
        } finally {
            if ($null -ne $old) { $env:APPDATA = $old } else { Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'JsonValidation - config/schema key parity (unknown-key regression)' {
    # Regression guard for the pwsh-7 FATAL:
    # "All values fail against the false schema at '/build/monorepo'".
    # Both root and build declare additionalProperties:false, so ANY config key
    # missing from the schema aborts the build under Strict validation
    # (health.failOnInvalidConfig=true). These checks use plain
    # ConvertFrom-Json so they run on PS 5.1 too (no Test-Json -Schema needed).
    BeforeAll {
        $script:ConfigPath = Join-Path $global:GBuildTestRoot '../gbuild.config.json'
        $script:SchemaPath = [System.IO.Path]::ChangeExtension($script:ConfigPath, '.schema.json')
    }

    It 'schema file itself is valid JSON' {
        $raw = Get-Content $script:SchemaPath -Raw -Encoding UTF8
        { $null = $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'every top-level config key exists in schema properties' {
        $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sch = Get-Content $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $missing = @($cfg.PSObject.Properties.Name | Where-Object { -not ($sch.properties.PSObject.Properties.Name -contains $_) })
        $missing | Should -BeNullOrEmpty -Because ("unknown top-level keys would fail additionalProperties:false: " + ($missing -join ', '))
    }

    It 'every build config key exists in schema build.properties' {
        $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sch = Get-Content $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $missing = @($cfg.build.PSObject.Properties.Name | Where-Object { -not ($sch.properties.build.properties.PSObject.Properties.Name -contains $_) })
        $missing | Should -BeNullOrEmpty -Because ("unknown build keys would fail additionalProperties:false: " + ($missing -join ', '))
    }

    It 'every logging config key exists in schema logging.properties' {
        # Regression: logging.path was code-supported (Orchestrator
        # Initialize-BuildLogging) but schema-forbidden
        # (additionalProperties:false without path), so Strict validation
        # aborted the build for users following the code comment.
        $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sch = Get-Content $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $missing = @($cfg.logging.PSObject.Properties.Name | Where-Object { -not ($sch.properties.logging.properties.PSObject.Properties.Name -contains $_) })
        $missing | Should -BeNullOrEmpty -Because ("unknown logging keys would fail additionalProperties:false: " + ($missing -join ', '))
    }

    It 'config with documented logging.path passes schema (code-schema contract)' {
        $testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
        $hasSchema = $testJsonCmd -and $testJsonCmd.Parameters.ContainsKey('Schema')
        if (-not $hasSchema) { Set-ItResult -Skipped -Because 'Test-Json -Schema not available on PS 5.1' ; return }
        $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg.logging | Add-Member -MemberType NoteProperty -Name 'path' -Value 'mylogs' -Force
        $safe = ($cfg | ConvertTo-Json -Depth 30) -replace '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '/tmp/placeholder'
        $schema = Get-Content $script:SchemaPath -Raw -Encoding UTF8
        $r = $safe | Test-Json -Schema $schema -ErrorAction Stop
        $r | Should -BeTrue
    }
}
