
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildSetting'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'
Import-GBuildModuleIfMissing -Name 'ErrorHandling' -SentinelCommand 'Invoke-HistoryWriteWithRetry'
# Owner of Invoke-BuildSecretProtect, which Protect-RootCauseText delegates to.
Import-GBuildModuleIfMissing -Name 'SharedUtils' -SentinelCommand 'Invoke-BuildSecretProtect'
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Test-PathUnderRoots'
# Shared preamble: root resolver, path resolver, config reader.
# Intentionally duplicated in AnomalyDetector.psm1 (not imported from a
# shared module): both files load through -Global imports where a shared
# preamble module hits module-scope issues, so each module carries its own
# copy. Keep the two copies byte-identical; the duplication is asserted by
# the near-duplicate hygiene check, not by an import.
$script:RootCauseHistoryPath = $null
$script:RootCauseEnabled = $true

function Get-DiagnosticRoot {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    foreach ($name in @('ProjectRoot', 'WorkingDir', 'ScriptRoot')) {
        $value = if ($State) { [string](Get-SectionValue -Section $State -Key $name -Default '') } else { '' }
        if ($value) {
            try { if ($name -eq 'ScriptRoot' -and (Split-Path -Leaf $value) -ieq 'Modules') { return (Split-Path -Parent $value) } } catch { }
            return $value
        }
    }
    if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) {
        return [string](Get-BuildRootDirectory -State $State)
    }
    throw (Get-LocaleMessage -Key 'log.diagnostic.noRoot')
}

function Resolve-DiagnosticPath {
    param([PSCustomObject]$State, [string]$Path)
    $root = Get-DiagnosticRoot $State
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $root $Path)) }
    if (-not (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue)) { return '' }
    if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($root))) { return '' }
    return $candidate
}

function Resolve-RootCausePath {
    param([PSCustomObject]$State, [string]$Path)
    return (Resolve-DiagnosticPath -State $State -Path $Path)
}

function Get-RootCauseConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $section = $null
    if ($State -and (Get-Command Get-SectionValue -ErrorAction SilentlyContinue)) {
        try { $section = Get-SectionValue -Section (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -Key 'rootCause' -Default $null } catch { $section = $null }
    }
    $reportDir = if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { [string](Get-BuildSetting -Key 'ReportOutputDir' -State $State -Fallback 'build-reports') } else { 'build-reports' }
    $get = {
        param([string]$Key, [string]$Property, $Fallback)
        # Defensive lookups: this function is called by a tool that may not have
        # loaded ConfigProvider (Get-SectionValue) or BuildConstants
        # (Get-BuildSetting). Before the guard, a missing command turned the whole
        # config resolution into a CommandNotFound, which meant the CAR ledger
        # could not be written at all - and the CAR is exactly what a failing gate
        # needs. A missing optional dependency now degrades to the documented
        # defaults instead of throwing.
        if ($null -ne $section -and (Get-Command Get-SectionValue -ErrorAction SilentlyContinue)) {
            try {
                $value = Get-SectionValue -Section $section -Key $Property -Default $null
                if ($null -ne $value) { return $value }
            } catch { }
        }
        if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) {
            try { return (Get-BuildSetting -Key $Key -State $State -Fallback $Fallback) } catch { return $Fallback }
        }
        return $Fallback
    }
    return [PSCustomObject]@{ enabled = [bool](& $get 'RootCauseEnabled' 'enabled' $true); historyPath = [string](& $get 'RootCauseHistoryPath' 'historyPath' (Join-Path $reportDir 'root-cause.jsonl')); maxHistoryEntries = [math]::Max(1, [math]::Min(10000, [int](& $get 'RootCauseMaxHistoryEntries' 'maxHistoryEntries' 500))) }
}

# =============================================================================
# CLASSIFIER TABLE
# =============================================================================
# WHY THIS IS DATA AND NOT INLINE LITERALS
# The 15 confidence scores, suggestions and tag sets below used to be written
# straight into the if/elseif chain, while Get-RootCauseConfig - immediately
# above - was fully config-driven. That split meant a project could tune
# rootCause.maxHistoryEntries from gbuild.config.json but had no way to tune,
# say, how confident the PortConflict classifier is, and the only way to change
# it was to edit a branch in the middle of a 15-way conditional.
#
# Moving the payload to a table makes each classifier a named row, so:
#   * every score is overridable through config (rootCause.confidence.<Category>
#     and rootCause.suggestion.<Category>), matching the rest of the module;
#   * the ORDER of evaluation is data, so a project can insert its own
#     classifier ahead of the built-ins without touching control flow;
#   * a test can assert the shipped table rather than 15 inline numbers.
#
# 'Match' entries are applied in array order and the first hit wins, so more
# specific patterns must come first - the ordering below is preserved exactly
# from the original chain, which is behaviour-preserving by construction.
$script:RootCauseClassifiers = @(
    @{ Category = 'MissingSDK';      Confidence = 0.92; Suggestion = 'Install the .NET SDK and verify PATH contains the SDK directory.'; Tags = @('sdk', 'environment', 'dotnet'); Match = '(?i)(dotnet|sdk|runtime).*not found|not found.*(dotnet|sdk|runtime)|install.*\.net|missing.*sdk' }
    @{ Category = 'PortConflict';    Confidence = 0.95; Suggestion = 'Stop the conflicting process or configure a different port.'; Tags = @('port', 'conflict', 'networking'); Match = '(?i)port.*(?:already|in use|occupied|\bbusy\b)|address already in use|only one usage of each socket|failed to bind' }
    @{ Category = 'DiskFull';        Confidence = 0.93; Suggestion = 'Free disk space or increase the configured health threshold.'; Tags = @('disk', 'storage', 'environment'); Match = '(?i)disk.*(?:full|space|exceeded)|no space left|insufficient disk|write error' }
    @{ Category = 'RestoreFailure';  Confidence = 0.88; Suggestion = 'Check package sources, network connectivity, and package versions.'; Tags = @('nuget', 'restore', 'network'); Match = '(?i)nuget|restore.*fail|Unable to resolve|NU\d{4}|packages.*not found|source.*not reachable' }
    @{ Category = 'CompileError';    Confidence = 0.90; Suggestion = 'Fix the compiler errors in the listed source files.'; Tags = @('compile', 'csharp', 'code'); Match = '(?i)CS\d{4}|MSB\d+|compiler|csc\.exe|build(?:ing)?.*(?:fail|error)|error\s+\w+\.cs\(\d+\)'; CaptureRelated = '([A-Za-z0-9_]+\.cs)\((\d+)\)' }
    @{ Category = 'AndroidBuild';    Confidence = 0.85; Suggestion = 'Verify the Android SDK path, signing configuration, and application ID.'; Tags = @('android', 'adb', 'mobile'); Match = '(?i)adb|android|keystore|apk|aab|manifest|applicationid' }
    @{ Category = 'ContainerError';  Confidence = 0.87; Suggestion = 'Check the Docker daemon, image reference, registry authentication, and storage driver.'; Tags = @('docker', 'container', 'ci'); Match = '(?i)docker|container|image|registry|manifest.*unknown|exec.*docker' }
    @{ Category = 'PermissionDenied'; Confidence = 0.91; Suggestion = 'Check file permissions and deployment credentials.'; Tags = @('permission', 'auth', 'security'); Match = '(?i)access denied|permission|unauthorized|elevation|admin|forbidden|401|403' }
    @{ Category = 'NetworkError';    Confidence = 0.89; Suggestion = 'Check network connectivity, proxy settings, firewall rules, and timeout configuration.'; Tags = @('network', 'timeout', 'transient'); Match = '(?i)timeout|timed out|no such host|dns|connect(?:ion)?.*(?:refused|reset|fail)|unable to connect|503|504' }
    @{ Category = 'GitError';        Confidence = 0.86; Suggestion = 'Ensure the working directory is the expected git repository.'; Tags = @('git', 'versioning', 'source'); Match = '(?i)git|not a git repository|fatal.*not a|branch|commit|tag|dirty' }
    @{ Category = 'ConfigError';     Confidence = 0.84; Suggestion = 'Validate the build configuration against its schema.'; Tags = @('config', 'json', 'validation'); Match = '(?i)config|json|parse|invalid.*json|schema|validation|missing.*property' }
    @{ Category = 'OutOfMemory';     Confidence = 0.90; Suggestion = 'Reduce build parallelism or increase available memory.'; Tags = @('memory', 'oom', 'resource'); Match = '(?i)out of memory|memory|oom|heap|stackoverflow|process.*killed' }
    @{ Category = 'HotReloadError';  Confidence = 0.83; Suggestion = 'Check file-watcher limits and project compatibility.'; Tags = @('hotreload', 'watch', 'developer'); Match = '(?i)hot reload|dotnet watch|file watcher|watcher' }
    # TransientError and UserCancelled are keyed off the ErrorRecord's own
    # CategoryInfo as well as the message, so they carry a Predicate rather than
    # a bare Match. The original chain tested CategoryInfo FIRST in the same
    # condition; that ordering is preserved.
    @{ Category = 'TransientError';  Confidence = 0.80; Suggestion = 'Retry the build after the transient condition clears.'; Tags = @('transient', 'retry'); Match = '(?i)transient|retry|temporary|lock|sharing violation'; CategoryInfo = 'Transient' }
    @{ Category = 'UserCancelled';   Confidence = 0.95; Suggestion = 'The build was cancelled; no automatic change is required.'; Tags = @('user', 'cancelled'); Match = '(?i)cancel|abort|user'; CategoryInfo = 'User' }
)

function Get-RootCauseClassifiers {
    <#
    .SYNOPSIS
        The classifier table, with config overrides applied.
    .DESCRIPTION
        Returns the shipped table merged with
          rootCause.confidence.<Category>  (a number)
          rootCause.suggestion.<Category>  (a string)
        from the active build config, so a project can retune a classifier
        without editing this module. Overrides are read once per call and the
        order of the shipped table is preserved, because order decides which
        classifier wins when two patterns both match.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([PSCustomObject]$State = $null)
    $section = $null
    if ($State) { $section = Get-SectionValue -Section (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -Key 'rootCause' -Default $null }
    $confOverrides = $null
    $suggOverrides = $null
    if ($section) {
        $confOverrides = Get-SectionValue -Section $section -Key 'confidence' -Default $null
        $suggOverrides = Get-SectionValue -Section $section -Key 'suggestion' -Default $null
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $script:RootCauseClassifiers) {
        $copy = @{}
        foreach ($k in @($row.Keys)) { $copy[$k] = $row[$k] }
        $cat = [string]$copy['Category']
        if ($confOverrides) {
            $override = Get-SectionValue -Section $confOverrides -Key $cat -Default $null
            if ($null -ne $override) { try { $copy['Confidence'] = [double]$override } catch { } }
        }
        if ($suggOverrides) {
            $override = Get-SectionValue -Section $suggOverrides -Key $cat -Default $null
            if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override)) { $copy['Suggestion'] = [string]$override }
        }
        $out.Add([PSCustomObject]$copy) | Out-Null
    }
    return @($out.ToArray())
}

function Protect-RootCauseText {
    param([AllowNull()][object]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    # Delegates to the canonical routine, same shape as Security.Protect-SecurityText
    # and Sast.Protect-SastText. The inline fallback this replaces was a FOURTH
    # divergent copy of the assignment rule: token|secret|password|api_key|
    # authorization, with no passwd, no access_key and no credential. HealthCheck
    # and InfraVerification both matched all three, so any `passwd=` or
    # `access_key=` reached a root-cause report in clear whenever Alerting was
    # not loaded - a redaction gap created purely by the duplication.
    # -State is forwarded so security.redactPatterns applies to this sink as well.
    return (Invoke-BuildSecretProtect -Text ([string]$Text) -State $State)
}

function Get-RootCauseAnalysis {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [PSCustomObject]$State = $null)
    $message = [string]$ErrorRecord.Exception.Message
    $categoryInfo = [string]$ErrorRecord.CategoryInfo.Category
    $analysis = [ordered]@{ Category = 'Unknown'; Confidence = 0.0; Suggestion = 'Review the error message and stack trace above.'; RelatedFiles = @(); Tags = @('unclassified') }
    # L5: score all matching classifiers, pick best confidence (tie-break by
    # table order). Previously first-hit-wins, so a broad low-confidence rule
    # placed early could shadow a specific high-confidence rule later. Behaviour
    # is preserved for single-match cases (the common path + all existing tests);
    # only multi-match ambiguity changes, and then toward the higher-confidence
    # diagnosis. CategoryInfo exact match outranks message regex on ties.
    $best = $null; $bestOrder = [int]::MaxValue; $order = 0
    foreach ($rule in (Get-RootCauseClassifiers -State $State)) {
        $hit = $false; $viaCategory = $false
        if ($rule.CategoryInfo -and $categoryInfo -eq $rule.CategoryInfo) { $hit = $true; $viaCategory = $true }
        if (-not $hit -and $rule.Match -and $message -match $rule.Match) { $hit = $true }
        if (-not $hit) { $order++; continue }
        $conf = [double]$rule.Confidence
        # CategoryInfo signal is stronger than a message substring; bump it
        # slightly for ranking only (reported Confidence stays config-tuned).
        $rank = $conf + $(if ($viaCategory) { 0.01 } else { 0 })
        $take = $false
        if ($null -eq $best) { $take = $true }
        elseif ($rank -gt $best.Rank + 0.000001) { $take = $true }
        elseif ([math]::Abs($rank - $best.Rank) -le 0.000001 -and $order -lt $bestOrder) { $take = $true }
        if ($take) {
            $related = @()
            if ($rule.CaptureRelated -and $message -match $rule.CaptureRelated) { $related = @($Matches[1]) }
            $best = @{ Rule = $rule; Rank = $rank; Related = $related }
            $bestOrder = $order
        }
        $order++
    }
    if ($best) {
        $analysis.Category = [string]$best.Rule.Category
        $analysis.Confidence = [double]$best.Rule.Confidence
        $analysis.Suggestion = [string]$best.Rule.Suggestion
        $analysis.Tags = @($best.Rule.Tags)
        $analysis.RelatedFiles = @($best.Related)
    }
    return [PSCustomObject]$analysis
}

function Write-RootCauseHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Analysis, [PSCustomObject]$State = $null)
    $cfg = Get-RootCauseConfig -State $State
    if (-not $cfg.enabled) { return $false }
    # Lock contention must not drop root-cause evidence under parallel load.
    # Attempts and delays are owned by ErrorHandling.Invoke-HistoryWriteWithRetry.
    $written = Invoke-HistoryWriteWithRetry -OperationName 'root-cause history write' -Action {
        $path = Resolve-RootCausePath -State $State -Path $cfg.historyPath
        $files = @((Get-SectionValue -Section $Analysis -Key 'RelatedFiles' -Default @()) | ForEach-Object { try { [System.IO.Path]::GetFileName([string]$_) } catch { '' } } | Where-Object { $_ -and $_ -notmatch '(?i)(token|secret|password)' })
        $tags = @((Get-SectionValue -Section $Analysis -Key 'Tags' -Default @()) | ForEach-Object { $tagText = Protect-RootCauseText ([string]$_) -State $State; if ($tagText -match '(?i)(https?://|token|secret|password|api[_-]?key|sk-|ghp_)') { 'REDACTED' } else { $tagText } })
        $entry = [PSCustomObject]@{ Schema = 'rootcause.analysis.v1'; Timestamp = (Get-Date).ToString('o'); Category = [string](Get-SectionValue -Section $Analysis -Key 'Category' -Default 'Unknown'); Confidence = [math]::Max(0.0, [math]::Min(1.0, [double](Get-SectionValue -Section $Analysis -Key 'Confidence' -Default 0))); Suggestion = Protect-RootCauseText ([string](Get-SectionValue -Section $Analysis -Key 'Suggestion' -Default '')) -State $State; RelatedFiles = @($files); Tags = @($tags); CorrelationId = if ($State) { [string](Get-SectionValue -Section $State -Key 'CorrelationId' -Default '') } else { '' }; TenantId = if ($State) { [string](Get-SectionValue -Section $State -Key 'TenantId' -Default 'default') } else { 'default' } }
        $line = $entry | ConvertTo-Json -Compress
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'root-cause'
        try { $lines = [System.Collections.Generic.List[string]]::new(); foreach ($item in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$item) | Out-Null }; $lines.Add($line) | Out-Null; [void](Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries)) } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
    # L5 CAR: best-effort record for high-confidence diagnoses. Silent by design
    # (no log, never changes the history verdict): gives New-CARRecord and
    # Write-CARRecord a production caller in this same module.
    try {
        $conf = [double](Get-SectionValue -Section $Analysis -Key 'Confidence' -Default 0)
        if ($written -and $conf -ge 0.8) {
            $sev = 'High'
            if ($conf -ge 0.9) { $sev = 'Critical' }
            $rec = New-CARRecord -Category ([string](Get-SectionValue -Section $Analysis -Key 'Category' -Default 'Unknown')) -Confidence $conf -Severity $sev -Suggestion ([string](Get-SectionValue -Section $Analysis -Key 'Suggestion' -Default '')) -State $State
            if ($null -ne $rec) { [void](Write-CARRecord -Record $rec -State $State) }
        }
    } catch { }
    return $written
}

<#
.SYNOPSIS
    Builds a Causal-Analysis-and-Resolution record from a diagnosis.
.DESCRIPTION
    L5 CAR: an analysis (category/confidence/suggestion) becomes a TRACKED
    record { Id, Severity, Status=Open } that Confirm-CARClosure later closes
    with evidence. Severity is explicit (operator/test) so triage policy lives
    in data, not in a branch. Never throws on redaction failure: the suggestion
    falls back to plaintext rather than dropping the record.
#>
function New-CARRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Category = 'Unknown',
        [double]$Confidence = 0.0,
        [string]$Severity = 'Medium',
        [string]$Suggestion = '',
        [PSCustomObject]$State = $null
    )
    $sev = 'Medium'
    if (@('Critical', 'High', 'Medium', 'Low') -contains $Severity) { $sev = $Severity }
    $safeSuggestion = $Suggestion
    try { $safeSuggestion = Protect-RootCauseText ([string]$Suggestion) -State $State } catch { $safeSuggestion = [string]$Suggestion }
    $corr = ''
    try { if ($State) { $corr = [string](Get-SectionValue -Section $State -Key 'CorrelationId' -Default '') } } catch { $corr = '' }
    $tenant = 'default'
    try { if ($State) { $tenant = [string](Get-SectionValue -Section $State -Key 'TenantId' -Default 'default'); if ([string]::IsNullOrWhiteSpace($tenant)) { $tenant = 'default' } } } catch { $tenant = 'default' }
    return [PSCustomObject]@{
        Schema      = 'car.record.v1'
        Id          = ([guid]::NewGuid().ToString('N'))
        Timestamp   = (Get-Date).ToString('o')
        Category    = [string]$Category
        Confidence  = [math]::Max(0.0, [math]::Min(1.0, $Confidence))
        Severity    = $sev
        Status      = 'Open'
        Suggestion  = [string]$safeSuggestion
        CorrelationId = [string]$corr
        TenantId    = [string]$tenant
    }
}

function New-VerificationCAR {
    <#
    .SYNOPSIS
        Opens a corrective-action record for a FAILED VERIFICATION GATE.
    .DESCRIPTION
        The CAR shape has ONE owner: New-CARRecord. This function does not
        invent a second record format - it calls the owner and attaches the
        verification evidence the owner has no place for.

        Why it exists: the causal loop was OPEN but not CLOSED. A red gate
        printed a line and the run ended; opening a CAR from it was a manual
        step, so a defect could reach a green state with no analysis record
        behind it. The runner now calls this the moment a scope fails, so the
        analysis record is a BYPRODUCT of the failure instead of a task
        somebody has to remember.
    .PARAMETER Scope
        The verification scope that failed (the unit of the gate).
    .PARAMETER FailedTests
        The failing test names, as reported by the gate.
    .PARAMETER GateThatMissed
        Which gate detected the failure (the control that fired).
    .PARAMETER DetectedBy
        What produced the detection (test framework, CI job, ...).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [string[]]$FailedTests = @(),
        [string]$GateThatMissed = '',
        [string]$DetectedBy = '',
        [string]$Severity = 'High',
        [PSCustomObject]$State = $null
    )
    $tests = @($FailedTests | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $summary = "Verification gate failed in scope '{0}'." -f $Scope
    if ($tests.Count -gt 0) {
        $shown = @($tests | Select-Object -First 10)
        $summary += ' Failing test(s): ' + (($shown) -join '; ')
        if ($tests.Count -gt $shown.Count) { $summary += (' (+{0} more)' -f ($tests.Count - $shown.Count)) }
    }
    if (-not [string]::IsNullOrWhiteSpace($GateThatMissed)) { $summary += (' Gate that fired: {0}.' -f $GateThatMissed) }
    if (-not [string]::IsNullOrWhiteSpace($DetectedBy)) { $summary += (' Detected by: {0}.' -f $DetectedBy) }
    $record = New-CARRecord -Category 'VerificationGateFailure' -Confidence 1.0 -Severity $Severity -Suggestion $summary -State $State
    # The evidence travels with the record: a CAR that cannot name the scope
    # and the failing tests is a note, not a corrective-action record.
    $record | Add-Member -MemberType NoteProperty -Name 'Verification' -Value ([PSCustomObject]@{
        Scope          = [string]$Scope
        FailedTests    = @($tests)
        GateThatMissed = [string]$GateThatMissed
        DetectedBy     = [string]$DetectedBy
    }) -Force
    return $record
}

function Resolve-CARPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    # Same directory as the root-cause history (no new config key, no schema
    # change): the CAR ledger lives next to the evidence it tracks.
    $cfg = Get-RootCauseConfig -State $State
    $hist = Resolve-RootCausePath -State $State -Path $cfg.historyPath
    if ([string]::IsNullOrWhiteSpace($hist)) { return '' }
    $dir = $null
    try { $dir = Split-Path $hist -Parent } catch { $dir = $null }
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    $candidate = Join-Path $dir 'car-records.jsonl'
    return (Resolve-DiagnosticPath -State $State -Path $candidate)
}

function Write-CARRecord {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][PSCustomObject]$Record, [PSCustomObject]$State = $null)
    $cfg = Get-RootCauseConfig -State $State
    if (-not $cfg.enabled) { return $false }
    return Invoke-HistoryWriteWithRetry -OperationName 'CAR record write' -Action {
        $path = Resolve-CARPath -State $State
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $line = $Record | ConvertTo-Json -Compress
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'car'
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($item in @(Read-BuildHistoryLines -Path $path)) { $lines.Add([string]$item) | Out-Null }
            $lines.Add($line) | Out-Null
            [void](Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries))
        } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
}

function Confirm-CARClosure {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Id, [string]$Evidence = '', [PSCustomObject]$State = $null)
    $cfg = Get-RootCauseConfig -State $State
    if (-not $cfg.enabled) { return $false }
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return Invoke-HistoryWriteWithRetry -OperationName 'CAR closure write' -Action {
        $path = Resolve-CARPath -State $State
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $safeEvidence = $Evidence
        try { $safeEvidence = Protect-RootCauseText ([string]$Evidence) -State $State } catch { $safeEvidence = [string]$Evidence }
        $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'car'
        try {
            $lines = [System.Collections.Generic.List[string]]::new()
            $found = $false
            foreach ($item in @(Read-BuildHistoryLines -Path $path)) {
                $out = [string]$item
                try {
                    $e = $item | ConvertFrom-Json -ErrorAction Stop
                    if ([string](Get-SectionValue -Section $e -Key 'Id' -Default '') -eq $Id) {
                        $e.Status = 'Closed'
                        $e | Add-Member -NotePropertyName 'ClosedAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force
                        $e | Add-Member -NotePropertyName 'Evidence' -NotePropertyValue ([string]$safeEvidence) -Force
                        $out = ($e | ConvertTo-Json -Compress)
                        $found = $true
                    }
                } catch { }
                $lines.Add($out) | Out-Null
            }
            if (-not $found) { return $false }
            [void](Write-BuildHistoryLines -Path $path @($lines | Select-Object -Last $cfg.maxHistoryEntries))
        } finally { Exit-BuildFileLock -Lock $lock }
        return $true
    }
}

function Get-RootCauseSummary {
    [CmdletBinding()]
    param([PSCustomObject]$State = $null)
    $cfg = Get-RootCauseConfig -State $State
    $path = Resolve-RootCausePath -State $State -Path $cfg.historyPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [PSCustomObject]@{ Total = 0; Categories = @{}; AvgConfidence = 0.0; TopTags = @() } }
    $lock = $null
    try { $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'root-cause'; $lines = @(Read-BuildHistoryLines -Path $path) } finally { if ($lock) { Exit-BuildFileLock -Lock $lock } }
    $categories = @{}; $tags = @{}; $total = 0; $confidence = 0.0; $tenant = if ($State) { [string](Get-SectionValue -Section $State -Key 'TenantId' -Default '') } else { '' }
    foreach ($line in @($lines | Select-Object -Last $cfg.maxHistoryEntries)) {
        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            $entryTenant = [string](Get-SectionValue -Section $entry -Key 'TenantId' -Default '')
            if ($tenant -and $entryTenant -and $entryTenant -ne $tenant) { continue }
            $category = [string](Get-SectionValue -Section $entry -Key 'Category' -Default 'Unknown'); if (-not $categories.ContainsKey($category)) { $categories[$category] = 0 }; $categories[$category]++; $total++; $confidence += [double](Get-SectionValue -Section $entry -Key 'Confidence' -Default 0)
            foreach ($tag in @((Get-SectionValue -Section $entry -Key 'Tags' -Default @()))) { $name = [string]$tag; if (-not $tags.ContainsKey($name)) { $tags[$name] = 0 }; $tags[$name]++ }
        } catch { }
    }
    $top = @($tags.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { $_.Name })
    return [PSCustomObject]@{ Total = $total; Categories = $categories; AvgConfidence = if ($total -gt 0) { [math]::Round($confidence / $total, 2) } else { 0.0 }; TopTags = $top }
}

<#
.SYNOPSIS
    Summarizes CAR ledger usage per tenant (control-plane metering).
.DESCRIPTION
    Each CAR record carries its TenantId, so the ledger doubles as metering
    input for chargeback/showback: { Total, Open, Tenants.{name} =
    { Total, Open, Closed, Critical } }. Missing ledger -> zero summary
    (fail-open). Never throws.
#>
function Get-TenantUsageSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State = $null)
    $byTenant = [ordered]@{}
    $total = 0
    $open = 0
    try {
        $path = Resolve-CARPath -State $State
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $lock = $null
            $lines = @()
            try {
                $lock = Enter-BuildHistoryLock -Path $path -HistoryName 'car'
                $lines = @(Read-BuildHistoryLines -Path $path)
            } finally { if ($lock) { Exit-BuildFileLock -Lock $lock } }
            foreach ($line in $lines) {
                try {
                    $e = $line | ConvertFrom-Json -ErrorAction Stop
                    if ([string](Get-SectionValue -Section $e -Key 'Schema' -Default '') -ne 'car.record.v1') { continue }
                    $t = [string](Get-SectionValue -Section $e -Key 'TenantId' -Default 'default')
                    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'default' }
                    if (-not $byTenant.Contains($t)) { $byTenant[$t] = [PSCustomObject]@{ Tenant = $t; Total = 0; Open = 0; Closed = 0; Critical = 0 } }
                    $entry = $byTenant[$t]
                    $entry.Total++
                    $status = [string](Get-SectionValue -Section $e -Key 'Status' -Default 'Open')
                    if ($status -eq 'Closed') { $entry.Closed++ } else { $entry.Open++; $open++ }
                    if ([string](Get-SectionValue -Section $e -Key 'Severity' -Default '') -eq 'Critical') { $entry.Critical++ }
                    $total++
                } catch { }
            }
        }
    } catch { }
    return [PSCustomObject]@{ Total = $total; Open = $open; Tenants = [PSCustomObject]$byTenant }
}

<#
.SYNOPSIS
    Exports a third-party-auditable CAR pack (ledger + hash manifest).
.DESCRIPTION
    Copies the CAR ledger into -OutputPath with manifest.json carrying a
    sha256 per file plus a parse-verification verdict, so an external auditor
    can verify completeness without running gbuild. Returns the pack
    directory, or '' when there is nothing to export or a write fails. Never
    throws for I/O problems; -OutputPath itself is mandatory (binding error
    when absent, by design).
#>
function Export-CARAuditPack {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State = $null, [Parameter(Mandatory)][string]$OutputPath)
    try {
        $src = Resolve-CARPath -State $State
        if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { return '' }
        $outRoot = [System.IO.Path]::GetFullPath($OutputPath)
        if (Get-Command Invoke-EnsureDirectory -ErrorAction SilentlyContinue) { [void](Invoke-EnsureDirectory -Path $outRoot) }
        else { $null = New-Item -ItemType Directory -Path $outRoot -Force -ErrorAction Stop }
        $dst = Join-Path $outRoot 'car-records.jsonl'
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $text = [System.IO.File]::ReadAllText($dst, [System.Text.Encoding]::UTF8)
        $valid = 0
        $invalid = 0
        foreach ($ln in @($text -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $null = ($ln | ConvertFrom-Json -ErrorAction Stop); $valid++ } catch { $invalid++ }
        }
        $hash = ''
        if (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue) {
            try { $hash = [string](Get-BuildStringHash -Text $text -OnFailure '') } catch { $hash = '' }
        }
        if ([string]::IsNullOrWhiteSpace($hash)) { return '' }
        $manifest = [ordered]@{
            schema        = 'car.audit-pack.v1'
            exportedAtUtc = (Get-Date).ToString('o')
            files         = [ordered]@{ 'car-records.jsonl' = $hash }
            validRecords  = $valid
            invalidRecords = $invalid
            verified      = ($invalid -eq 0)
        }
        $mpath = Join-Path $outRoot 'manifest.json'
        [System.IO.File]::WriteAllText($mpath, (([PSCustomObject]$manifest | ConvertTo-Json -Depth 5)), (New-Object System.Text.UTF8Encoding($false)))
        return $outRoot
    } catch { return '' }
}

<#
.SYNOPSIS
    Re-verifies an exported CAR audit pack (the auditor's half).
.DESCRIPTION
    Reads manifest.json, recomputes the sha256 of every listed file with the
    shared string-hash owner, and recounts valid/invalid records against the
    manifest claims. Any mismatch (edited ledger, edited manifest, truncated
    file) yields Verified=$false with Reasons. Never throws for I/O problems.
#>
function Test-CARAuditPack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackPath)
    $reasons = [System.Collections.Generic.List[string]]::new()
    try {
        if (-not (Test-Path -LiteralPath $PackPath -PathType Container)) {
            return [PSCustomObject]@{ Verified = $false; Reasons = @('pack directory is not present') }
        }
        $mpath = Join-Path $PackPath 'manifest.json'
        if (-not (Test-Path -LiteralPath $mpath -PathType Leaf)) {
            return [PSCustomObject]@{ Verified = $false; Reasons = @('manifest.json is not present') }
        }
        $mf = Get-Content -LiteralPath $mpath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$mf.schema -ne 'car.audit-pack.v1') {
            return [PSCustomObject]@{ Verified = $false; Reasons = @('unexpected manifest schema') }
        }
        $hasHash = [bool](Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue)
        foreach ($fp in @($mf.files.PSObject.Properties)) {
            $fpath = Join-Path $PackPath $fp.Name
            if (-not (Test-Path -LiteralPath $fpath -PathType Leaf)) { $reasons.Add(('missing file: ' + $fp.Name)) | Out-Null; continue }
            if ($hasHash) {
                $text = [System.IO.File]::ReadAllText($fpath, [System.Text.Encoding]::UTF8)
                $h = ''
                try { $h = [string](Get-BuildStringHash -Text $text -OnFailure '') } catch { $h = '' }
                if ($h -ne [string]$fp.Value) { $reasons.Add(('hash mismatch: ' + $fp.Name)) | Out-Null }
            }
        }
        $ledger = Join-Path $PackPath 'car-records.jsonl'
        if (Test-Path -LiteralPath $ledger -PathType Leaf) {
            $valid = 0
            $invalid = 0
            foreach ($ln in @([System.IO.File]::ReadAllText($ledger, [System.Text.Encoding]::UTF8) -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                try { $null = ($ln | ConvertFrom-Json -ErrorAction Stop); $valid++ } catch { $invalid++ }
            }
            if ($valid -ne [int]$mf.validRecords -or $invalid -ne [int]$mf.invalidRecords) {
                $reasons.Add('record recount disagrees with the manifest') | Out-Null
            }
        }
        $ok = ($reasons.Count -eq 0)
        return [PSCustomObject]@{ Verified = $ok; Reasons = @($reasons) }
    } catch {
        $reasons.Add('pack is unreadable') | Out-Null
        return [PSCustomObject]@{ Verified = $false; Reasons = @($reasons) }
    }
}

Export-ModuleMember -Function @('Get-RootCauseAnalysis', 'Write-RootCauseHistory', 'Get-RootCauseSummary', 'Get-RootCauseConfig', 'Get-RootCauseClassifiers', 'New-CARRecord', 'New-VerificationCAR', 'Resolve-CARPath', 'Write-CARRecord', 'Confirm-CARClosure', 'Get-TenantUsageSummary', 'Export-CARAuditPack', 'Test-CARAuditPack')
