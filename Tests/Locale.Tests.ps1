#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Locale" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    # ── Get-CurrentLocale ────────────────────────────────────────────────
    It "Get-CurrentLocale returns the default 'en' initially" {
        Set-CurrentLocale -Locale 'en'
        Get-CurrentLocale | Should -Be 'en'
    }

    # ── Set-CurrentLocale ────────────────────────────────────────────────
    It "Set-CurrentLocale 'vi' switches the current locale" {
        Set-CurrentLocale -Locale 'vi'
        Get-CurrentLocale | Should -Be 'vi'
    }

    It "Set-CurrentLocale with an unsupported locale falls back to 'en'" {
        Set-CurrentLocale -Locale 'xx'
        Get-CurrentLocale | Should -Be 'en'
    }

    # ── Get-LocaleMessage built-in (no resource file) ───────────────────
    It "Get-LocaleMessage returns the built-in English text for an unknown key" {
        Set-CurrentLocale -Locale 'en'
        Get-LocaleMessage -Key 'menu.exit' | Should -Be 'Exit'
    }

    It "Get-LocaleMessage returns the built-in Vietnamese text when locale is 'vi'" {
        Set-CurrentLocale -Locale 'vi'
        Get-LocaleMessage -Key 'Processing' -MessageArgs @('demo') | Should -Match 'Đang xử lý'
    }

    It "Get-LocaleMessage returns the key itself when no message exists" {
        Set-CurrentLocale -Locale 'en'
        Get-LocaleMessage -Key 'no.such.key.xyz' | Should -Be 'no.such.key.xyz'
    }

    # ── Set-LocaleFromState (config-driven) ─────────────────────────────
    It "Set-LocaleFromState reads build.locale.default from BuildConfig" {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{ locale = [PSCustomObject]@{ default = 'vi' } }
            }
        }
        Set-LocaleFromState -State $state | Should -Be 'vi'
        Get-CurrentLocale | Should -Be 'vi'
    }

    It "Set-LocaleFromState falls back to the current locale when config lacks locale" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
        Set-LocaleFromState -State $state | Should -Be (Get-CurrentLocale)
    }

    # ── Resource file loading (Locales/<locale>.json, UTF-8) ────────────
    It "Import-LocaleResource loads the vi.json resource file with correct UTF-8 text" {
        $res = Import-LocaleResource -Locale 'vi'
        $res['menu.exit'] | Should -Be 'Thoát'
    }

    It "Get-LocaleMessage prefers the external resource over built-in messages" {
        Set-CurrentLocale -Locale 'vi'
        Get-LocaleMessage -Key 'menu.exit' | Should -Be 'Thoát'
        Get-LocaleMessage -Key 'menu.debugAndroid' | Should -Be 'Chạy trên thiết bị Android'
    }

    # ── Resource file BOM enforcement (PS 5.1 mojibake guard) ──────────────
    It "every Locales/*.json is saved with a UTF-8 BOM" {
        $localesDir = Join-Path $global:GBuildModuleRoot '../Locales'
        $files = Get-ChildItem -LiteralPath $localesDir -Filter '*.json' -File
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)[0..2]
            $bytes.Count | Should -Be 3
            $bytes[0] | Should -Be 0xEF
            $bytes[1] | Should -Be 0xBB
            $bytes[2] | Should -Be 0xBF
        }
    }
    It "all locale files share identical key sets" {
        $localesDir = Join-Path $global:GBuildModuleRoot '../Locales'
        $files = Get-ChildItem -LiteralPath $localesDir -Filter '*.json' -File
        $files.Count | Should -Be 7
        $enFile = $files | Where-Object BaseName -eq 'en'
        $enKeys = @(([System.IO.File]::ReadAllText($enFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)
        $enKeys.Count | Should -BeGreaterThan 200
        foreach ($f in ($files | Where-Object BaseName -ne 'en')) {
            $keys = @(([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)
            $keys.Count | Should -Be $enKeys.Count -Because "$($f.BaseName).json key count must match en.json"
            for ($i = 0; $i -lt $keys.Count; $i++) {
                $keys[$i] | Should -Be $enKeys[$i] -Because "$($f.BaseName).json key '$($keys[$i])' must match en.json at position $i"
            }
        }
    }

    It "cache/deploy/security keys translate in every locale" {
        $sampleKeys = @('log.cache.cleared', 'log.dt.deployingTo', 'log.security.phaseScan')
        foreach ($loc in @('en', 'vi', 'de', 'es', 'fr', 'ja', 'zh')) {
            Set-CurrentLocale -Locale $loc
            foreach ($k in $sampleKeys) {
                Get-LocaleMessage -Key $k | Should -Not -Be $k -Because "key '$k' must have a translation in '$loc'"
            }
        }
        Set-CurrentLocale -Locale 'en'
    }

    It "translations actually differ from en (no copy-paste placeholders)" {
        # The existing checks only assert the resolved value is NOT the key, which
        # a verbatim copy of en.json passes. So a translator could replace every
        # value with the English string and the suite stayed green, while the
        # product shipped "multilingual" output it never had.
        #
        # Language-neutral values are legitimately identical: ASCII box glyphs,
        # level names, format-only tags, and product names. This allows a bounded
        # number of them but requires real translation for the bulk.
        $localesDir = Join-Path $global:GBuildModuleRoot '../Locales'
        $files = Get-ChildItem -LiteralPath $localesDir -Filter '*.json' -File
        $enJson = [System.IO.File]::ReadAllText(($files | Where-Object BaseName -eq 'en').FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($f in ($files | Where-Object BaseName -ne 'en')) {
            $loc = $f.BaseName
            $json = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $enValues = @{}
            foreach ($p in $enJson.PSObject.Properties) { $enValues[$p.Name] = [string]$p.Value }
            $total = 0; $identical = @()
            foreach ($p in $json.PSObject.Properties) {
                $total++
                if ([string]$p.Value -ceq $enValues[$p.Name]) { $identical += $p.Name }
            }
            # Placeholder-only and glyph keys are expected to match; prose must not.
            # 20% is a generous ceiling that still catches a wholesale regression.
            $maxIdentical = [math]::Max(12, [int]($total * 0.20))
            $identical.Count | Should -BeLessOrEqual $maxIdentical -Because "$loc has $($identical.Count)/$total values byte-identical to en (limit $maxIdentical); the rest of the file is untranslated prose. Identical keys: $((@($identical | Select-Object -First 12)) -join ', ')"
        }
    }

    It "no locale key is dead (every key is reachable from code)" {        # 2026-09 audit: 51 message keys existed in all 7 locale files with zero
        # consumers, i.e. 357 translated strings maintained for nothing. They
        # were removed, and this gate stops the class from returning.
        $localesDir = Join-Path $global:GBuildModuleRoot '../Locales'
        $enFile = Get-ChildItem -LiteralPath $localesDir -Filter 'en.json' -File
        $enKeys = @(([System.IO.File]::ReadAllText($enFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).PSObject.Properties.Name)

        # Every code site that can consume a key.
        $sources = @()
        foreach ($p in @(Get-ChildItem -LiteralPath (Join-Path $global:GBuildModuleRoot '..') -Recurse -File -Include '*.psm1', '*.ps1')) {
            if ($p.FullName -match '[\\/](\.tools|logs|TestResults|build-reports|reports|distributed-report)[\\/]' -or $p.Name -eq 'Locale.Tests.ps1') { continue }
            $sources += $p.FullName
        }
        $corpus = ''
        foreach ($p in $sources) {
            try { $corpus += [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) + "`n" } catch { }
        }
        # Dynamic families built by prefix, e.g. "log.stepName.$name".
        $families = @('log.stepName.', 'log.strategy.', 'log.sdk.source.', 'log.level.', 'log.marker.', 'log.status.')
        $dead = @()
        foreach ($k in $enKeys) {
            if ($corpus.Contains($k)) { continue }
            $isFamily = $false
            foreach ($f in $families) { if ($k.StartsWith($f)) { $isFamily = $true; break } }
            if (-not $isFamily) { $dead += $k }
        }
        $dead | Should -BeNullOrEmpty -Because "these keys are translated into 7 locales but nothing reads them; wire or delete: $($dead -join ', ')"
    }

    It "every key used in code exists in en.json (no missing direction)" {
        # Companion to the dead-key gate above: that gate catches keys nobody
        # reads; this one catches keys that are read but have no translation.
        # Before 2026-10, 135 call sites passed -Fallback literals for keys
        # absent from every locale file, and Get-LocaleMessage returned the
        # fallback WITHOUT [string]::Format, so users saw literal "{0}".
        # Both halves are now gated: this test for the missing keys, and the
        # fallback-format test below for the rendering.
        $localesDir = Join-Path $global:GBuildModuleRoot '../Locales'
        $enFile = Get-ChildItem -LiteralPath $localesDir -Filter 'en.json' -File
        $enKeys = @(([System.IO.File]::ReadAllText($enFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).PSObject.Properties.Name)
        $enSet = @{}; foreach ($k in $enKeys) { $enSet[$k] = 1 }
        $builtIn = @('Done', 'DoneWithTime', 'Fail', 'FailWithTime', 'Processing', 'LoggingEnabled', 'StepRetry', 'PipelineCancelled', 'StepSkipped', 'StepFailed', 'PipelineTimeout', 'StepTimeout', 'StepFailedJob', 'BuildFailed', 'SecurityIssues', 'NoSecurityIssues', 'GStateNotInitialized', 'RequiredModuleNotFound')
        # Deliberate negative-test keys (assert the missing-key path itself).
        $negative = @('no.such.key.xyz', 'menu.nonexistent')
        $sources = @()
        foreach ($p in @(Get-ChildItem -LiteralPath (Join-Path $global:GBuildModuleRoot '..') -Recurse -File -Include '*.psm1', '*.ps1')) {
            if ($p.FullName -match '[\\/](\.tools|logs|TestResults|build-reports|reports|distributed-report)[\\/]' -or $p.FullName -match '[\\/]Tests[\\/]') { continue }
            $sources += $p.FullName
        }
        $keyPat = [regex]'(Get-LocaleMessage|Resolve-LogMessage|Write-MetricLog|Get-MenuLabel)\s+(?:-Locale\s+[''"][^''"]+[''"]\s+)?-Key\s+[''"]([A-Za-z0-9_.]+)[''"]'
        $missing = @{}
        foreach ($p in $sources) {
            try { $text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } catch { continue }
            foreach ($m in $keyPat.Matches($text)) {
                $k = $m.Groups[2].Value
                if ($enSet.ContainsKey($k)) { continue }
                if ($builtIn -contains $k) { continue }
                if ($negative -contains $k) { continue }
                if (-not $missing.ContainsKey($k)) { $missing[$k] = @() }
                $missing[$k] += (Split-Path -Leaf $p)
            }
        }
        $missing.Keys | Should -BeNullOrEmpty -Because "these keys are requested by code but absent from en.json; add them (English text from the call-site -Fallback): $($missing.Keys -join ', ')"
    }

    It "Get-LocaleMessage formats the -Fallback literal with -MessageArgs" {
        # Regression test for the 2026-10 defect: the -Fallback branch returned
        # the literal without [string]::Format, printing "Pass={0}" to users.
        Set-CurrentLocale -Locale 'en'
        Get-LocaleMessage -Key 'no.such.key.xyz' -MessageArgs @('A', 'B') -Fallback 'x={0} y={1}' | Should -Be 'x=A y=B'
        # A fallback that cannot format (arg mismatch) must degrade to the raw
        # literal, never throw.
        Get-LocaleMessage -Key 'no.such.key.xyz' -MessageArgs @('A') -Fallback 'x={0} y={1}' | Should -Be 'x={0} y={1}'
        Set-CurrentLocale -Locale 'en'
    }

    It "core pipeline messages translate in every locale" {
        $sampleKeys = @('log.system.building', 'log.project.scanning', 'log.target.using', 'log.sast.primaryLanguage', 'log.status.passed', 'log.stepName.Build')
        foreach ($loc in @('en', 'vi', 'de', 'es', 'fr', 'ja', 'zh')) {
            Set-CurrentLocale -Locale $loc
            foreach ($k in $sampleKeys) {
                Get-LocaleMessage -Key $k | Should -Not -Be $k -Because "key '$k' must have a translation in '$loc'"
            }
        }
        Set-CurrentLocale -Locale 'en'
    }

    It "does not auto-select a locale from the operating-system environment" {
        $module = Get-Module Locale
        & $module { $script:ExplicitLocaleSet = $false; $script:CurrentLocale = 'en' }
        $env:LANG = 'vi_VN.UTF-8'
        try {
            Get-CurrentLocale | Should -Be 'en'
        } finally {
            Remove-Item Env:\LANG -ErrorAction SilentlyContinue
            Set-CurrentLocale -Locale 'en'
        }
    }
}

Describe "Locale device persistence (bounded per-device cache)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Remove-Item Env:\GBUILD_LOCALE -ErrorAction SilentlyContinue
        Set-CurrentLocale -Locale 'en'
    }

    It "GBUILD_LOCALE overrides config and persists the choice to the device cache" {
        $tmp = New-IntegrationTempDir
        try {
            $env:GBUILD_LOCALE = 'vi'
            $state = [PSCustomObject]@{
                ScriptRoot = $tmp
                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} }
            }
            Set-LocaleFromState -State $state | Should -Be 'vi'
            $cacheFile = Join-Path $tmp '.gbuild/locale.json'
            Test-Path -LiteralPath $cacheFile -PathType Leaf | Should -BeTrue
            $d = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $d.locale | Should -Be 'vi'
            $d.deviceId | Should -Be (Get-DeviceId)
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "device cache hit restores the remembered language without env or config" {
        $tmp = New-IntegrationTempDir
        try {
            $first = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Save-DeviceLocaleCache -State $first -Locale 'ja' | Should -BeTrue
            Set-CurrentLocale -Locale 'en'
            $second = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Set-LocaleFromState -State $second | Should -Be 'ja'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "remembered choice beats the shipped config default" {
        $tmp = New-IntegrationTempDir
        try {
            $seed = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Save-DeviceLocaleCache -State $seed -Locale 'vi' | Should -BeTrue
            Set-CurrentLocale -Locale 'en'
            $state = [PSCustomObject]@{
                ScriptRoot = $tmp
                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ locale = [PSCustomObject]@{ default = 'en' } } }
            }
            Set-LocaleFromState -State $state | Should -Be 'vi'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "legacy cache without source is ignored (no OS auto-detect resurrection)" {
        $tmp = New-IntegrationTempDir
        try {
            $dir = Join-Path $tmp '.gbuild'
            $null = New-Item -ItemType Directory -Path $dir -Force
            (@{ version = 1; deviceId = (Get-DeviceId); locale = 'vi'; updatedAt = '2026-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
                Set-Content -LiteralPath (Join-Path $dir 'locale.json') -Encoding UTF8
            Set-CurrentLocale -Locale 'en'
            $state = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Set-LocaleFromState -State $state | Should -Be 'en'
            $d = Get-Content -LiteralPath (Join-Path $dir 'locale.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $d.source | Should -Be 'default'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "first run with no cache defaults to English and binds the device" {
        $tmp = New-IntegrationTempDir
        try {
            Set-CurrentLocale -Locale 'en'
            $state = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Set-LocaleFromState -State $state | Should -Be 'en'
            $d = Get-Content -LiteralPath (Join-Path $tmp '.gbuild/locale.json') -Raw -Encoding UTF8 | ConvertFrom-Json
             $d.deviceId | Should -Be (Get-DeviceId)
             $d.locale | Should -Be 'en'
             $d.source | Should -Be 'default'
         } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
     }

     It "cache carried to a new machine resets to English and overwrites the cache" {
        $tmp = New-IntegrationTempDir
        try {
            $dir = Join-Path $tmp '.gbuild'
            $null = New-Item -ItemType Directory -Path $dir -Force
            (@{ version = 1; deviceId = ('0' * 64); locale = 'vi'; updatedAt = '2026-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
                Set-Content -LiteralPath (Join-Path $dir 'locale.json') -Encoding UTF8
            $state = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            Set-LocaleFromState -State $state | Should -Be 'en'
            $d = Get-Content -LiteralPath (Join-Path $dir 'locale.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $d.deviceId | Should -Be (Get-DeviceId)
            $d.locale | Should -Be 'en'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "corrupt or oversized cache is ignored and replaced, never throws" {
        $tmp = New-IntegrationTempDir
        try {
            $dir = Join-Path $tmp '.gbuild'
            $null = New-Item -ItemType Directory -Path $dir -Force
            ('x' * 5000) | Set-Content -LiteralPath (Join-Path $dir 'locale.json') -Encoding UTF8 -NoNewline
            $state = [PSCustomObject]@{ ScriptRoot = $tmp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
            { Set-LocaleFromState -State $state } | Should -Not -Throw
            ((Get-Item -LiteralPath (Join-Path $dir 'locale.json')).Length) | Should -BeLessThan 4096
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "state without ScriptRoot never touches the device cache" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
        Get-DeviceLocaleCachePath -State $state | Should -Be $null
        Save-DeviceLocaleCache -State $state -Locale 'vi' | Should -BeFalse
        { Set-LocaleFromState -State $state } | Should -Not -Throw
    }

    # --- Regression: a relative / un-normalized ScriptRoot used to make
    # Get-DeviceLocaleCachePath return a CWD-relative path, so the per-device
    # record was written into whatever directory the launcher ran from. This is
    # how F:\.gbuild\locale.json appeared at the filesystem root. ---
    It "a relative ScriptRoot never yields a device cache path" {
        Get-DeviceLocaleCachePath -State ([PSCustomObject]@{ ScriptRoot = '.' }) | Should -Be $null
        Get-DeviceLocaleCachePath -State ([PSCustomObject]@{ ScriptRoot = '..' }) | Should -Be $null
        Get-DeviceLocaleCachePath -State ([PSCustomObject]@{ ScriptRoot = '.gbuild' }) | Should -Be $null
    }

    It "Save-DeviceLocaleCache writes nothing for a relative ScriptRoot" {
        $origLoc = $PWD.Path
        try {
            Set-Location -LiteralPath $( [System.IO.Path]::GetTempPath() )
            $before = Test-Path -LiteralPath (Join-Path $( [System.IO.Path]::GetTempPath() ) '.gbuild')
            Save-DeviceLocaleCache -State ([PSCustomObject]@{ ScriptRoot = '..' }) -Locale 'vi' | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $( [System.IO.Path]::GetTempPath() ) '.gbuild') | Should -Be $before
        } finally { Set-Location -LiteralPath $origLoc }
    }

    It "Get-DeviceLocaleCachePath always returns a rooted, normalized path" {
        $tmp = New-IntegrationTempDir
        try {
            $p = Get-DeviceLocaleCachePath -State ([PSCustomObject]@{ ScriptRoot = $tmp })
            $p | Should -Not -BeNullOrEmpty
            [System.IO.Path]::IsPathRooted([string]$p) | Should -BeTrue
            $p | Should -Not -Match '(\.\.)(\\|/|$)'
            $p | Should -Be (Join-Path ([System.IO.Path]::GetFullPath($tmp)) '.gbuild/locale.json')
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-AvailableLocales and Get-LocaleDisplayList expose every display language" {
        $langs = Get-AvailableLocales
        $langs | Should -Contain 'en'
        $langs.Count | Should -BeGreaterOrEqual 7
        Get-LocaleDisplayList | Should -Match 'vi'
    }

    It "Show-LocaleHelp prints the OS-correct switch commands without throwing" {
        $helpText = Show-LocaleHelp 6>&1 | Out-String
        $helpText | Should -Match 'Vietnamese'
        $helpText | Should -Not -Match 'Tiếng Việt'
    }
}

Describe "Locale message-template integrity" {
    # The catalogs were generated by capturing the ENGLISH SOURCE TEXT of each
    # call site verbatim. When that text contained a PowerShell variable the
    # catalog stored the variable name literally, so the operator was shown
    # "Required module not found: $path" instead of the path, and the
    # translated catalogs showed the same literal. 25 keys were affected and
    # nothing caught it: the key-parity test only compared key NAMES.
    #
    # These three gates close that class of defect for good.

    BeforeAll {
        $script:LmToolRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) ''
        $script:LmLocaleDir = Join-Path $script:LmToolRoot 'Locales'
        $script:LmModuleDir = Join-Path $script:LmToolRoot 'Modules'
        $script:LmLangs = @('en', 'vi', 'zh', 'ja', 'fr', 'es', 'de')
        $script:LmCatalogs = @{}
        foreach ($l in $script:LmLangs) {
            $p = Join-Path $script:LmLocaleDir "$l.json"
            $script:LmCatalogs[$l] = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        # Keys whose text legitimately shows a PowerShell variable to the user
        # (the variable they are being told to set), not a value to interpolate.
        $script:LmLiteralAllowed = @('ui.locale.switchEnv', 'log.install.line62', 'log.install.line212')
    }

    It "gives every locale the same placeholder set for every key" {
        $en = $script:LmCatalogs['en']
        $offenders = @()
        foreach ($prop in $en.PSObject.Properties) {
            $expected = @([regex]::Matches([string]$prop.Value, '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            foreach ($l in $script:LmLangs) {
                $target = $script:LmCatalogs[$l].PSObject.Properties[$prop.Name]
                if (-not $target) { $offenders += "$l is missing key '$($prop.Name)'"; continue }
                $actual = @([regex]::Matches([string]$target.Value, '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                if (Compare-Object $expected $actual) {
                    $offenders += "$l key '$($prop.Name)' placeholders [$($actual -join ',')] differ from en [$($expected -join ',')]"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It "never leaves an uninterpolated variable in a message" {
        $offenders = @()
        foreach ($l in $script:LmLangs) {
            foreach ($prop in $script:LmCatalogs[$l].PSObject.Properties) {
                if ($script:LmLiteralAllowed -contains $prop.Name) { continue }
                $value = [string]$prop.Value
                # $env:NAME / $PROFILE are literal text the user must act on.
                $stripped = [regex]::Replace($value, '\$env:[A-Za-z_][A-Za-z0-9_]*', '')
                $stripped = [regex]::Replace($stripped, '\$PROFILE\b', '')
                $stripped = [regex]::Replace($stripped, '\$global:[A-Za-z_][A-Za-z0-9_]*', '')
                if ($stripped -match '\$[A-Za-z_]') {
                    $offenders += "$l key '$($prop.Name)' contains an uninterpolated variable: $value"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It "passes one message argument per placeholder at every call site" {
        $offenders = @()
        foreach ($f in Get-ChildItem -LiteralPath $script:LmModuleDir -Recurse -Include *.psm1, *.ps1 -File) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ($cmd.GetCommandName() -ne 'Resolve-LogMessage' -and $cmd.GetCommandName() -ne 'Get-LocaleMessage') { continue }
                $els = @($cmd.CommandElements)
                $key = $null
                $argCount = 0
                $argIsVar = $false
                for ($i = 0; $i -lt $els.Count; $i++) {
                    $e = $els[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($e.ParameterName -eq 'MessageArgs') {
                            # '-MessageArgs @(...)' parses as the parameter plus a
                            # sibling ArrayExpressionAst; '-MessageArgs $a, $b'
                            # parses as the parameter plus a sibling
                            # ArrayLiteralAst. Both carry their elements in the
                            # NEXT element, not in the parameter's own Argument.
                            $target = $e.Argument
                            if (-not $target -and ($i + 1) -lt $els.Count) { $target = $els[$i + 1] }
                            if ($target -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                                $inner = $target.SubExpression
                                if ($inner -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                                    $argCount = @($inner.Elements).Count
                                } else { $argIsVar = $true }
                            } elseif ($target -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                                $argCount = @($target.Elements).Count
                            } elseif ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
                                $argIsVar = $true
                            } elseif ($target) {
                                $argCount = 1
                            }
                        }
                        continue
                    }
                    if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and -not $key -and $e.Value -match '^log\.') {
                        $key = $e.Value
                    }
                }
                if (-not $key) { continue }
                $prop = $script:LmCatalogs['en'].PSObject.Properties[$key]
                if (-not $prop) { $offenders += "$($f.Name): key '$key' is not in en.json"; continue }
                $placeholders = ([regex]::Matches([string]$prop.Value, '\{(\d+)\}')).Count
                if ($argIsVar) { continue }
                if ($placeholders -gt 0 -and $argCount -eq 0) {
                    $offenders += "$($f.Name): key '$key' has $placeholders placeholder(s) but the call site passes no message argument"
                } elseif ($argCount -ne $placeholders) {
                    $offenders += "$($f.Name): key '$key' gets $argCount argument(s) but the message has $placeholders placeholder(s)"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}
