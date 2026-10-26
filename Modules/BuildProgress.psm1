# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-BuildModule -Dependencies @('SharedUtils', 'BuildConstants')
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

<#
.SYNOPSIS
    Resolves the build.progress config block with BuildConstants fallbacks.
#>
function Get-ProgressConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $enabled = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'ProgressEnabled' -State $State -Fallback $true } else { $true }
    $stream = if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { Get-ConfigValue -Path 'build.progress.streamOutput' -State $State -Default $true } else { $true }
    $throttle = [int](Get-BuildConstant -Key 'ProgressThrottleMs' -State $State -Fallback 300)
    $beat    = [int](Get-BuildConstant -Key 'ProgressElapsedSec' -State $State -Fallback 5)
    $poll    = [int](Get-BuildConstant -Key 'ProgressPollMs' -State $State -Fallback 100)
    return @{
        Enabled      = [bool]$enabled
        StreamOutput = [bool]$stream
        ThrottleMs   = $throttle
        HeartbeatSec = $beat
        PollMs       = $poll
    }
}

<#
.SYNOPSIS
    Formats an elapsed-seconds tag like "[  12s]" for live progress lines.
#>
function Format-ElapsedTag {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Secs)
    return ('[ {0,4:0}s]' -f $Secs)
}

<#
.SYNOPSIS
    Quotes a single argument for a native command line (Windows rules).
#>
function ConvertTo-ProcessArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)
    return (ConvertTo-BuildArgument -Value $Value)
}

<#
.SYNOPSIS
    Classifies a build-output line: Blank / Error / Warn / Milestone / Gear.
.DESCRIPTION
    Single source for the dotnet-output classifier regexes - shared by the
    built-in handler in Invoke-WithLiveOutput and Build.psm1's $liveLine
    callback (previously two drifted copies of the same three regexes).
#>
function Test-BuildOutputLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return 'Blank' }
    if ($Line -match '(?i)\berror\b') { return 'Error' }
    if ($Line -match '(?i)\bwarning\b') { return 'Warn' }
    if ($Line -match '(Build succeeded|Build FAILED|->\s|Publish:|Done Building|Time Elapsed)') { return 'Milestone' }
    return 'Gear'
}

<#
.SYNOPSIS
    Shortens a build-output line for console display without losing the important tail.
.DESCRIPTION
    # Previous version blindly cut after MaxLineExcerptChars chars from the head
    hiding the filename/extension that matters most. This version:
      1) Tries to make absolute paths relative to ProjectRoot (".\LamToanLop1.csproj").
      2) Middle-truncates preserving head + tail so both drive and filename stay visible:
    # e.g. <Drive>:\LapTrinth\...\LamToanLop1.csproj
    Applies identically to all locales (vi/de/ja) because the line is treated as
    opaque text - only length and separators matter. Default 100 chars fits the
    60% content width on a 100-col window (BuildConstants.LogContentWidthRatio).
#>
function Get-BuildOutputExcerpt {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Line,
        [ValidateRange(0, 500)][int]$MaxLength = 0,
        [PSCustomObject]$State
    )
    if ($MaxLength -le 0) {
        $MaxLength = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            [int](Get-BuildConstant -Key 'ProgressExcerptMaxLength' -Fallback 100)
        } else { 100 }
    }
    $short = $Line.Trim()
    if ($short.Length -le $MaxLength) { return $short }
    # Make absolute project paths relative for brevity (portable, no hardcode).
    if ($State -and $State.ProjectRoot) {
        $projRoot = [string]$State.ProjectRoot
        if ($projRoot -and $short.Contains($projRoot)) {
            $short = $short.Replace($projRoot, '.')
            if ($short.Length -le $MaxLength) { return $short }
        }
    }
    # Also try WorkingDir as fallback
    if ($State -and $State.WorkingDir) {
        $wd = [string]$State.WorkingDir
        if ($wd -and $wd.Length -gt 3 -and $short.Contains($wd)) {
            $short = $short.Replace($wd, '.')
            if ($short.Length -le $MaxLength) { return $short }
        }
    }
    # Middle-truncate: keep head and tail, hide middle with ...
    $keep = $MaxLength - 3
    $headLen = [math]::Ceiling($keep / 2.0)
    $tailLen = $keep - $headLen
    $head = $short.Substring(0, $headLen)
    $tail = $short.Substring($short.Length - $tailLen)
    # Align tail to a path separator so we don't cut inside a filename
    $sepIdx = $tail.IndexOfAny(@('\', '/'))
    if ($sepIdx -ge 0 -and $sepIdx -le 8 -and ($tailLen + $sepIdx) -lt $short.Length) {
        # Shift a bit: include the separator, compensate head
        $tail = $tail.Substring($sepIdx)
        $headLen = $MaxLength - 3 - $tail.Length
        if ($headLen -gt 10) { $head = $short.Substring(0, $headLen) }
    }
    return $head + '...' + $tail
}

<#
.SYNOPSIS
    Runs a build command with real-time output streaming and a silence heartbeat.
.DESCRIPTION
    Two modes:
      -FilePath + -ArgList : System.Diagnostics.Process with async output readers.
        The main thread drains a synchronized queue and can emit a heartbeat
        ("[  Ns] <label> ...") even when the child process is fully silent
        (e.g. MAUI AOT/dex phases). True live progress on Windows PowerShell 5.1.
      -ScriptBlock         : pipeline streaming (& $ScriptBlock 2>&1 | per-line).
        Lines appear as the tool flushes them; no silence heartbeat.
    Both modes collect output into .Output (bounded retention: only the LAST
    100 lines are kept, so a long-running build cannot grow memory unbounded).
    When build.progress.enabled is false the command still runs and is collected,
    but nothing is displayed (CI-friendly).
.PARAMETER OnLine
    Optional per-line callback; it receives the line as its first argument.
    TRUE contract: the callback runs in its OWN scope - plain variable
    assignments inside it (e.g. `$count++`) are discarded when it returns and
    do NOT mutate caller variables. To accumulate state across lines, capture a
    REFERENCE object (hashtable, List[string]) from the enclosing scope and
    mutate its members. When omitted, a built-in classifier displays errors red,
    warnings yellow, milestones info and throttles the remaining noise as gray
    gear lines.
#>
function Invoke-WithLiveOutput {
    [CmdletBinding(DefaultParameterSetName = 'Process')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Process')][string]$FilePath,
        [Parameter(ParameterSetName = 'Process')][object[]]$ArgList = @(),
        [Parameter(Mandatory = $true, ParameterSetName = 'Script')][scriptblock]$ScriptBlock,
        [Parameter(ParameterSetName = 'Script')][object[]]$ScriptArgs = @(),
        [PSCustomObject]$State,
        [string]$Label = '',
        [string]$WorkingDir = '',
        [scriptblock]$OnLine,
        [switch]$Quiet,
        # Max wall-clock seconds for the child process. 0 = no timeout (legacy).
        # On timeout the process tree is killed and the result carries
        # TimedOut=$true with ExitCode 124 (timeout(1) convention) so callers
        # (e.g. SAST scans hitting a stalled NuGet feed) degrade gracefully
        # instead of hanging the pipeline forever.
        [int]$TimeoutSec = 0
    )

    $cfg = Get-ProgressConfig -State $State
    $collected = [System.Collections.Generic.List[string]]::new()
    $result = @{ ExitCode = 0; Output = $collected; ElapsedSec = 0.0; TimedOut = $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Transcript retention cap (per invocation): builds stream thousands of
    # lines; retaining ALL of them grows memory without bound. Keep only the
    # LAST N lines in .Output (List.RemoveAt(0) trim). Single source:
    # BuildConstants.ProgressMaxCollectedLines.
    $script:__gpbMaxCollectedLines = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        [int](Get-BuildConstant -Key 'ProgressMaxCollectedLines' -Fallback 100)
    } else { 100 }

    $glyphs = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        Get-BuildConstant -Key 'Glyphs' -Fallback @{}
    } else { @{} }
    $gErr  = if ($glyphs.error) { [string]$glyphs.error } else { '[x]' }
    $gWarn = if ($glyphs.warn) { [string]$glyphs.warn } else { '[!]' }
    $gOk   = if ($glyphs.ok) { [string]$glyphs.ok } else { '[v]' }
    $gGear = if ($glyphs.gear) { [string]$glyphs.gear } else { '[*]' }

    # Inline heartbeat state: single-line CR overwrite (image fix) - tracks previous
    # heartbeat length so the next overwrite can clear residual characters.
    $script:__gpbHeartbeatLen = 0
    $script:__gpbHeartbeatActive = $false
    $script:__gpbLastGear = 0.0

    # Shared per-line handler (invoked from this function's scope in both modes,
    # so $collected / $OnLine / counters resolve through the caller's scope).
    $handleLine = {
        param($raw)
        if ($null -eq $raw) { return }
        $line = $raw.ToString().TrimEnd()
        [void]$collected.Add($line)
        # Bound the transcript: retain only the LAST N lines.
        while ($collected.Count -gt $script:__gpbMaxCollectedLines) { $collected.RemoveAt(0) }
        if (-not $cfg.Enabled -or $Quiet -or -not $cfg.StreamOutput) { return }
        # Clear the heartbeat line before emitting real output so the console
        # does not interleave gear/error messages on top of the spinner.
        if ($script:__gpbHeartbeatActive) {
            try { Write-Host "" } catch { }
            $script:__gpbHeartbeatActive = $false
            $script:__gpbHeartbeatLen = 0
        }
        if ($OnLine) { & $OnLine $line; return }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        # Classification + excerpt single-sourced via Test-BuildOutputLine /
        # Get-BuildOutputExcerpt (shared with Build.psm1's $liveLine callback).
        switch (Test-BuildOutputLine -Line $line) {
            'Error'     { Write-Log "  $gErr  $line" 'Err' $State }
            'Warn'      { Write-Log "  $gWarn  $line" 'Warn' $State }
            'Milestone' { Write-Log "  $gOk  $line" 'Info' $State }
            default {
                $tick = $sw.Elapsed.TotalMilliseconds
                if (($tick - $script:__gpbLastGear) -ge $cfg.ThrottleMs) {
                    Write-Log "   $gGear  $(Get-BuildOutputExcerpt -Line $line -State $State)" 'Gray' $State
                    $script:__gpbLastGear = $tick
                }
            }
        }
    }

    $emitHeartbeat = {
        param([double]$NowSec)
        $tag = Format-ElapsedTag -Secs $NowSec
        $what = if ($Label) { $Label } else { 'build' }
        $msg = Get-LocaleMessage -Key 'log.build.stillRunning' -MessageArgs @($tag, $what)
        if (-not $Quiet -and $cfg.Enabled -and $cfg.StreamOutput) {
            # Single-line overwrite via CR: replaces the previous heartbeat in place
            # instead of emitting a new line every 5 s (image: 14s,19s,24s... spam).
            # In non-interactive / redirected hosts CR is ignored, so fall back to
            # Write-Log only when a real console is present. Check CI flags first.
            $isCI = $false
            try { $isCI = [bool]($State -and ($State.IsCI -or $State.NonInteractive)) } catch { }
            $useCR = $false
            if (-not $isCI) {
                try { $useCR = $Host.UI.RawUI -and $Host.UI.RawUI.CursorSize -ge 0 } catch { $useCR = $false }
            }
            if ($useCR) {
                $prev = [int]$script:__gpbHeartbeatLen
                $padLen = $prev - $msg.Length
                $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
                $fg = try { Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'DarkGray' } catch { 'DarkGray' }
                try { Write-Host "`r$msg$pad" -NoNewline -ForegroundColor $fg } catch { Write-Log $msg 'Gray' $State }
                $script:__gpbHeartbeatLen = $msg.Length
                $script:__gpbHeartbeatActive = $true
            } elseif (-not $isCI) {
                # Fallback for hosts without RawUI but still interactive: emit once via Write-Log
                # (throttled already by $cfg.HeartbeatSec, so still limited).
                Write-Log $msg 'Gray' $State
            }
            # CI / NonInteractive: heartbeat stays silent (no console spam). Elapsed time
            # is still available via EVT_STEP_PROGRESS for metrics.
        }
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_STEP_PROGRESS -Source $State -Data @{ Label = $what; ElapsedSec = [math]::Round($NowSec, 1) } | Out-Null
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Script') {
        # Baseline the ambient LASTEXITCODE so a stale value left over from an
        # unrelated earlier native command is NOT misreported as this
        # scriptblock's result. Only a CHANGED value is propagated.
        $baselineExit = 0
        $bl = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($bl -and $bl.Value -is [int]) { $baselineExit = [int]$bl.Value }
        & $ScriptBlock @ScriptArgs 2>&1 | ForEach-Object {
            $line = if ($null -eq $_) { '' } else { $_.ToString() }
            & $handleLine $line
        }
        $result.ExitCode = 0
        $lec = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($lec -and $lec.Value -is [int] -and ([int]$lec.Value -ne $baselineExit)) { $result.ExitCode = $lec.Value }
        $result.ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        return $result
    }

    # ---- Process mode: async readers + main-thread drain + true heartbeat ----

    # Resolve bare command names through PATH first: Get-Command finds .exe,
    # .cmd and .bat shims while raw CreateProcess (Process.Start) only finds .exe.
    # Get-Command can return MULTIPLE Application matches (e.g. a stub plus a real
    # SDK elsewhere on PATH) - .Source would then be a space-joined garbage
    # string, so always take the FIRST hit explicitly.
    if (-not [System.IO.Path]::IsPathRooted($FilePath) -and -not [System.IO.Path]::HasExtension($FilePath)) {
        $resolved = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue
        if ($resolved) {
            $first = @($resolved)[0]
            $src = if ($first.Source) { $first.Source } elseif ($first.Path) { $first.Path } else { $null }
            if ($src) {
                $FilePath = $src
                if ($FilePath -match '\.(cmd|bat)$') {
                    # Batch-file shims cannot be started directly with
                    # UseShellExecute=false - route them through the shell.
                    # $env:ComSpec only exists on Windows. Assigning it
                    # unconditionally left FilePath empty on Linux/macOS and
                    # turned a clear "not executable here" into an opaque
                    # process-start exception. Leave the path untouched so the
                    # normal failure surfaces.
                    if (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) {
                        $ArgList = @('/c', $FilePath) + @($ArgList)
                        $FilePath = $env:ComSpec
                    }
                }
            }
        }
    }

    $quoted = foreach ($a in $ArgList) {
        $v = [string]$a
        # ProcessStartInfo does NOT use a shell: never shell-quote (single quotes
        # on POSIX would become literal argument text). Wrap only args that
        # contain spaces in double quotes, which .NET respects on both OSes.
        if ($v -match '[ \t]') { '"' + $v + '"' } else { $v }
    }
    $psi = New-BuildProcessStartInfo -FilePath $FilePath -Arguments ($quoted -join ' ') -WorkingDirectory $WorkingDir
    if ($null -eq $psi) { return }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $sync = [System.Collections.Hashtable]::Synchronized(@{
        Queue      = [System.Collections.Queue]::new()
        LastOutput = 0.0
        Sw         = $sw
    })

    $outSub = Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -MessageData $sync -Action {
        if ($null -ne $EventArgs.Data -and $EventArgs.Data -ne '') {
            $Event.MessageData.Queue.Enqueue([string]$EventArgs.Data)
            $Event.MessageData.LastOutput = $Event.MessageData.Sw.Elapsed.TotalSeconds
        }
    }
    $errSub = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -MessageData $sync -Action {
        if ($null -ne $EventArgs.Data -and $EventArgs.Data -ne '') {
            $Event.MessageData.Queue.Enqueue([string]$EventArgs.Data)
            $Event.MessageData.LastOutput = $Event.MessageData.Sw.Elapsed.TotalSeconds
        }
    }

    $lastBeat = 0.0
    $timedOut = $false
    # Resolve before the process starts because the timeout branch below needs
    # the same bounded wait as the post-kill wait further down.
    $killWaitMs = 5000
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $killWaitMs = [int](Get-BuildConstant -Key 'ProgressKillWaitMs' -State $State -Fallback 5000) } catch { }
    }
    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        # Poll clamp bounds single-sourced from BuildConstants (ProgressPollClamp*Ms).
        $poll = [Math]::Max(
            [int](Get-BuildConstant -Key 'ProgressPollClampMinMs' -Fallback 50),
            [Math]::Min([int](Get-BuildConstant -Key 'ProgressPollClampMaxMs' -Fallback 200), $cfg.PollMs))
        # do-while: at least one pump so fast-exiting children still get their
        # OutputDataReceived/ErrorDataReceived engine events dispatched (events
        # only process while the engine sleeps).
        do {
            Start-Sleep -Milliseconds $poll
            while ($sync.Queue.Count -gt 0) { & $handleLine ([string]$sync.Queue.Dequeue()) }
            $now = $sw.Elapsed.TotalSeconds
            if ($TimeoutSec -gt 0 -and $now -ge $TimeoutSec -and -not $proc.HasExited) {
                $timedOut = $true
                # Teardown is owned by SharedUtils.Stop-BuildProcess, including
                # the whole-tree-first, process-only-fallback kill used here.
                Stop-BuildProcess -Process $proc -WaitMs $killWaitMs -EntireTree
                break
            }
            if (($now - $lastBeat) -ge $cfg.HeartbeatSec -and ($now - [double]$sync.LastOutput) -ge $cfg.HeartbeatSec) {
                & $emitHeartbeat -NowSec $now
                $lastBeat = $now
            }
        } while (-not $proc.HasExited)
        # Parameterless WaitForExit flushes the async readers before returning;
        # one more sleep lets the final queued events dispatch, then drain.
        # On timeout the process was just killed: bound the wait so a stubborn
        # child tree cannot hang us a second time. Level 5 single-source via
        # BuildConstants.ProgressKillWaitMs (distinct from ExeTimeoutMs).
        if ($timedOut) {
            $proc.WaitForExit($killWaitMs) | Out-Null
        } else {
            $proc.WaitForExit()
        }
        # Final-drain sleep floor single-sourced from BuildConstants.ProgressFinalDrainMs.
        Start-Sleep -Milliseconds ([Math]::Max([int](Get-BuildConstant -Key 'ProgressFinalDrainMs' -Fallback 120), $poll))
        while ($sync.Queue.Count -gt 0) { & $handleLine ([string]$sync.Queue.Dequeue()) }
        if ($timedOut) {
            # 124 = timeout(1) convention so downstream logs/metrics can
            # distinguish "tool too slow" from a genuine tool failure.
            $result.ExitCode = 124
            $result.TimedOut = $true
            [void]$collected.Add("[TIMEOUT] Process killed after ${TimeoutSec}s: $FilePath")
            while ($collected.Count -gt $script:__gpbMaxCollectedLines) { $collected.RemoveAt(0) }
        } else {
            # Capture the exit code BEFORE Dispose invalidates the process handle.
            $result.ExitCode = $proc.ExitCode
        }
        # Clear the inline heartbeat line so the final result starts on a fresh line.
        if ($script:__gpbHeartbeatActive) {
            try { Write-Host "" } catch { }
            $script:__gpbHeartbeatActive = $false
            $script:__gpbHeartbeatLen = 0
        }
    } finally {
        # Ensure heartbeat is cleared even on exception.
        if ($script:__gpbHeartbeatActive) {
            try { Write-Host "" } catch { }
            $script:__gpbHeartbeatActive = $false
            $script:__gpbHeartbeatLen = 0
        }
        Unregister-Event -SubscriptionId $outSub.Id -ErrorAction SilentlyContinue
        Unregister-Event -SubscriptionId $errSub.Id -ErrorAction SilentlyContinue
        Remove-Job -Id $outSub.Id -Force -ErrorAction SilentlyContinue
        Remove-Job -Id $errSub.Id -Force -ErrorAction SilentlyContinue
        # HasExited/Kill/Dispose all throw InvalidOperationException when Start()
        # never succeeded (e.g. executable not found) - swallow, the original
        # Start() exception must propagate to the caller.
        Stop-BuildProcess -Process $proc -WaitMs 0
        try { $proc.Dispose(); } catch { }
    }

    $result.ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    return $result
}

Export-ModuleMember -Function @('Get-ProgressConfig', 'Format-ElapsedTag', 'ConvertTo-ProcessArgument', 'Invoke-WithLiveOutput', 'Test-BuildOutputLine', 'Get-BuildOutputExcerpt')
