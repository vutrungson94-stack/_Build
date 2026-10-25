#Requires -Version 5.1
Set-StrictMode -Version 1.0

<#
    Regression coverage for pipeline-as-code.

    README.md:237-268 documented gbuild.pipeline.yml (name/trigger/env/steps,
    task:, when:, timeout:) for the entire life of the feature while NOTHING
    implemented it: no YAML parser existed in Modules, no example file shipped,
    and Resolve-PipelineSteps read only build.pipeline.steps - so a pipeline
    file was silently ignored. These tests exist so that cannot recur.
#>

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:yamlModule = Join-Path $script:root 'Modules/YamlPipeline.psm1'
    Import-Module $script:yamlModule -Force -Global -DisableNameChecking -ErrorAction Stop

    function New-YamlFixture {
        param([string[]]$Lines)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-yml-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'gbuild.pipeline.yml'
        [System.IO.File]::WriteAllText($file, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ Dir = $dir; File = $file; State = [pscustomobject]@{ ProjectRoot = $dir } }
    }
}

AfterAll {
    foreach ($p in @((Get-Variable -Name yamlFixture -ValueOnly -ErrorAction SilentlyContinue),
                     (Get-Variable -Name yamlFixture2 -ValueOnly -ErrorAction SilentlyContinue))) {
        if ($p -and $p.Dir) { Remove-Item -LiteralPath $p.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'ConvertFrom-GBuildYaml' {
    It 'parses a scalar mapping' {
        $d = ConvertFrom-GBuildYaml -Text "name: gbuild-pipeline`nversion: `"1.0`"`ntrigger: manual"
        $d.name | Should -Be 'gbuild-pipeline'
        $d.version | Should -Be '1.0'
        $d.trigger | Should -Be 'manual'
    }

    It 'parses a nested mapping' {
        $d = ConvertFrom-GBuildYaml -Text "env:`n  BUILD_CONFIG: Release`n  FLAG: 1"
        $d.env.BUILD_CONFIG | Should -Be 'Release'
        $d.env.FLAG | Should -Be 1
    }

    It 'parses a block sequence of mappings' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: One`n    task: A`n  - step: Two`n    task: B"
        @($d.steps).Count | Should -Be 2
        @($d.steps)[0].step | Should -Be 'One'
        @($d.steps)[1].task | Should -Be 'B'
    }

    It 'strips trailing comments but keeps a URL fragment' {
        $d = ConvertFrom-GBuildYaml -Text "name: t  # a comment`nurl: http://host/x#frag"
        $d.name | Should -Be 't'
        $d.url | Should -Be 'http://host/x#frag'
    }

    It 'keeps a # inside quotes' {
        $d = ConvertFrom-GBuildYaml -Text "name: `"a #b`""
        $d.name | Should -Be 'a #b'
    }

    It 'parses a flow sequence' {
        $d = ConvertFrom-GBuildYaml -Text "tags: [a, b, 'c d']"
        @($d.tags).Count | Should -Be 3
        @($d.tags)[2] | Should -Be 'c d'
    }

    It 'keeps a colon inside an unquoted scalar' {
        $d = ConvertFrom-GBuildYaml -Text "url: http://example.com:8080/x"
        $d.url | Should -Be 'http://example.com:8080/x'
    }

    It 'returns $null for a comment-only document' {
        ConvertFrom-GBuildYaml -Text "# nothing here`n# still nothing" | Should -BeNullOrEmpty
    }

    It 'ignores document markers and blank lines' {
        $d = ConvertFrom-GBuildYaml -Text "---`nname: t`n`n...`n"
        $d.name | Should -Be 't'
    }
}

Describe 'ConvertFrom-GBuildYaml rejects what it cannot parse' {
    # A half-understood YAML file must fail loudly. Silently dropping a
    # construct is how a pipeline ends up running fewer steps than declared.
    $cases = @(
        @{ Name = 'tab indentation';     Text = "steps:`n`t- step: A";                  Code = 'TabIndent' }
        @{ Name = 'block scalar';        Text = "steps:`n  - step: A`n    script: |`n      body"; Code = 'BlockScalar' }
        @{ Name = 'anchor key';          Text = "steps: &s`n  - step: A";              Code = 'Anchor' }
        @{ Name = 'merge key';           Text = "defaults: &d`n  <<: *d";               Code = 'Anchor' }
        @{ Name = 'tag';                 Text = "steps: !!seq`n  - step: A";             Code = 'Tag' }
        @{ Name = 'inline flow mapping'; Text = "env: { A: B }";                       Code = 'FlowMapping' }
        @{ Name = 'top-level sequence';  Text = "- step: A`n  task: B";                 Code = 'TopLevelSequence' }
        @{ Name = 'duplicate root key';  Text = "name: a`nname: b";                    Code = 'DuplicateKey' }
        @{ Name = 'missing colon';       Text = "just text";                           Code = 'ExpectedKeyValue' }
    )
    It 'rejects <Name>' -ForEach $cases {
        $err = $null
        try { ConvertFrom-GBuildYaml -Text $Text } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        # Either a localized sentence (Locale loaded) or the structured code
        # (standalone import, no resolver). Both must name the construct.
        $err.Exception.Message | Should -Match ([regex]::Escape($Code))
    }
}

Describe 'Test-PipelineYamlDocument' {
    BeforeAll {
        $script:okDoc = ConvertFrom-GBuildYaml -Text "name: t`nsteps:`n  - step: One`n    task: Get-Date`n    timeout: 30"
    }

    It 'accepts a valid document' {
        Test-PipelineYamlDocument -Document $script:okDoc | Should -BeTrue
    }

    It 'tolerates the SourcePath provenance member' {
        $d = ConvertFrom-GBuildYaml -Text "name: t`nsteps:`n  - step: One`n    task: Get-Date"
        $d | Add-Member -MemberType NoteProperty -Name SourcePath -Value 'x.yml' -Force
        { Test-PipelineYamlDocument -Document $d } | Should -Not -Throw
    }

    It 'rejects a step whose timeout key is misspelled' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    timout: 60"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a step with no task' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a step with an empty task' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: `"`""
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a non-numeric timeout' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    timeout: soon"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a negative timeout' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    timeout: -5"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a when: expression that does not parse' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    when: `"(`""
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a duplicate step name' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n  - step: A`n    task: Y"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects an empty steps list' {
        $d = ConvertFrom-GBuildYaml -Text "name: t`nsteps:"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects a document with no steps block' {
        $d = ConvertFrom-GBuildYaml -Text "name: t"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'rejects job isolation without a timeout' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    job: true"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }

    It 'accepts job isolation with a timeout and maps it onto the engine contract' {
        $d = ConvertFrom-GBuildYaml -Text "steps:`n  - step: A`n    task: X`n    timeout: 30`n    job: true"
        { Test-PipelineYamlDocument -Document $d } | Should -Not -Throw
        $steps = ConvertFrom-PipelineYamlStep -Document $d
        @($steps)[0].TimeoutSeconds | Should -Be 30
        [bool]@($steps)[0].Job | Should -BeTrue
    }

    It 'rejects an unknown root key' {
        $d = ConvertFrom-GBuildYaml -Text "name: t`ntrigger: manual`nwhenever: x`nsteps:`n  - step: A`n    task: X"
        { Test-PipelineYamlDocument -Document $d } | Should -Throw
    }
}

Describe 'ConvertFrom-PipelineYamlStep' {
    BeforeAll {
        $script:doc = ConvertFrom-GBuildYaml -Text @(
            'name: t'
            'steps:'
            '  - step: Build'
            '    task: Start-BuildAndShow'
            '    timeout: 900'
            '    retry: 2'
            '  - step: ScanProject'
            '    task: Find-Project'
            '    when: "($ctx.csproj)"'
        )
        Test-PipelineYamlDocument -Document $script:doc | Out-Null
        $script:steps = ConvertFrom-PipelineYamlStep -Document $script:doc
    }

    It 'maps step/task/timeout/retry onto the engine contract' {
        @($script:steps).Count | Should -Be 2
        @($script:steps)[0].Name | Should -Be 'Build'
        @($script:steps)[0].TimeoutSeconds | Should -Be 900
        @($script:steps)[0].Retry | Should -Be 2
    }

    It 'builds an invocable scriptblock that passes $ctx' {
        # The engine calls & $step.Script $Context, so the task must receive it.
        $sb = @($script:steps)[0].Script
        $sb.ToString() | Should -Match '\$ctx'
    }

    It 'omits When when the step has no condition' {
        @($script:steps)[0].ContainsKey('When') | Should -BeFalse
    }

    It 'compiles when: into a scriptblock' {
        $when = @($script:steps)[1].When
        $when | Should -BeOfType [scriptblock]
        # Evaluating against a context must actually work.
        $ctx = @{ csproj = 'a.csproj' }
        (& $when $ctx) | Should -BeTrue
    }
}

Describe 'Get-BuildYamlPipelineDocument discovery' {
    BeforeAll {
        $script:yamlFixture = New-YamlFixture -Lines @('name: t', 'steps:', '  - step: One', '    task: Get-Date')
    }

    It 'finds gbuild.pipeline.yml in ProjectRoot' {
        $d = Get-BuildYamlPipelineDocument -State $script:yamlFixture.State
        $d | Should -Not -BeNullOrEmpty
        $d.name | Should -Be 't'
    }

    It 'records SourcePath for provenance' {
        $d = Get-BuildYamlPipelineDocument -State $script:yamlFixture.State
        $d.SourcePath | Should -Be $script:yamlFixture.File
    }

    It 'returns $null when no pipeline file exists' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-none-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        try {
            Get-BuildYamlPipelineDocument -State ([pscustomobject]@{ ProjectRoot = $empty }) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT auto-discover in ScriptRoot' {
        # ScriptRoot is the _Build install dir, which SHIPS gbuild.pipeline.yml
        # as an example. Discovering it there would replace the built-in
        # pipeline for every project on the machine.
        $nowhere = Join-Path ([System.IO.Path]::GetTempPath()) ('does-not-exist-' + [guid]::NewGuid().ToString('N'))
        $state = [pscustomobject]@{ ProjectRoot = $nowhere; ScriptRoot = $script:root }
        Get-BuildYamlPipelineDocument -State $state | Should -BeNullOrEmpty
    }

    It 'rejects an empty pipeline file rather than silently using the built-in one' {
        $f = New-YamlFixture -Lines @('# only a comment')
        try { Get-BuildYamlPipelineDocument -State $f.State | Out-Null; $threw = $false } catch { $threw = $true }
        finally { Remove-Item -LiteralPath $f.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        $threw | Should -BeTrue
    }

    It 'propagates a parse error instead of falling back to the built-in pipeline' {
        $f = New-YamlFixture -Lines @('steps:', '  - step: A', '    task: X', "    script: |", '      body')
        try {
            $doc = Get-BuildYamlPipelineDocument -State $f.State
            Test-PipelineYamlDocument -Document $doc | Out-Null
            $threw = $false
        } catch { $threw = $true }
        finally { Remove-Item -LiteralPath $f.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        $threw | Should -BeTrue
    }

    It 'surfaces an unknown step key at validation, not silently' {
        $f = New-YamlFixture -Lines @('steps:', '  - step: A', '    task: X', '    timout: 60')
        try {
            $doc = Get-BuildYamlPipelineDocument -State $f.State
            Test-PipelineYamlDocument -Document $doc | Out-Null
            $threw = $false
        } catch { $threw = $true }
        finally { Remove-Item -LiteralPath $f.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        $threw | Should -BeTrue -Because "a misspelled 'timout:' must not be silently ignored"
    }
}

Describe 'Set-PipelineYamlEnvironment' {
    It 'applies the env block and can restore it' {
        $doc = ConvertFrom-GBuildYaml -Text "env:`n  GBUILD_YAMLPROBE: applied"
        $applied = Set-PipelineYamlEnvironment -Document $doc -State ([pscustomobject]@{ ProjectRoot = $null })
        try {
            $applied.ContainsKey('GBUILD_YAMLPROBE') | Should -BeTrue
            $env:GBUILD_YAMLPROBE | Should -Be 'applied'
        } finally {
            Clear-PipelineYamlEnvironment -Applied $applied
        }
        (Test-Path Env:GBUILD_YAMLPROBE) | Should -BeFalse
    }

    It 'never overwrites an existing process value' {
        $env:GBUILD_YAMLPROBE = 'operator'
        try {
            $doc = ConvertFrom-GBuildYaml -Text "env:`n  GBUILD_YAMLPROBE: fromfile"
            $applied = Set-PipelineYamlEnvironment -Document $doc -State ([pscustomobject]@{ ProjectRoot = $null })
            try { $env:GBUILD_YAMLPROBE | Should -Be 'operator' }
            finally { Clear-PipelineYamlEnvironment -Applied $applied }
        } finally { Remove-Item Env:GBUILD_YAMLPROBE -ErrorAction SilentlyContinue }
    }

    It 'rejects a scalar env' {
        $doc = ConvertFrom-GBuildYaml -Text "env: nope`nsteps:`n  - step: A`n    task: X"
        { Set-PipelineYamlEnvironment -Document $doc -State ([pscustomobject]@{ ProjectRoot = $null }) } | Should -Throw
    }
}

Describe 'the shipped example' {
    It 'ships a gbuild.pipeline.yml that parses and validates' {
        $shipped = Join-Path $script:root 'gbuild.pipeline.yml'
        Test-Path $shipped | Should -BeTrue
        $doc = ConvertFrom-GBuildYaml -Text ([System.IO.File]::ReadAllText($shipped))
        Test-PipelineYamlDocument -Document $doc | Should -BeTrue
        @($doc.steps).Count | Should -BeGreaterThan 0
    }

    It 'documents only keys the parser actually supports' {
        # A documented key the parser rejects is the exact defect this feature
        # shipped with, so the example must not name one.
        $shipped = Join-Path $script:root 'gbuild.pipeline.yml'
        $doc = ConvertFrom-GBuildYaml -Text ([System.IO.File]::ReadAllText($shipped))
        foreach ($step in @($doc.steps)) {
            foreach ($k in @($step.PSObject.Properties.Name)) {
                @('step', 'task', 'when', 'timeout', 'retry') | Should -Contain $k
            }
        }
    }
}