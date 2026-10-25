#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Metrics.E2E - mock end-to-end OTLP telemetry proof.
.DESCRIPTION
    Proves the metrics + OTLP code path works WITHOUT requiring a real
    Jaeger / OTel backend:
      - Metrics accumulate and export as Prometheus text (real module code).
      - OTLP push (Send-OtelTraces / Send-OtelMetrics) degrades gracefully
        when the collector is unreachable (no throw), per the module's
        graceful-degradation contract.
    No hardcoded endpoints, no external network.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "OTel Telemetry E2E (mock collector)" {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Clear-Metrics
        # A dead endpoint: proves graceful degradation (no throw) without a real backend.
        $script:DeadEndpoint = "http://127.0.0.1:1/otlp"
    }

    AfterAll {
        # Intentionally do NOT Remove-Module: Pester shares module session state
        # across files in one run; removing here would break later test files that
        # import the same module.
    }

    It "metrics accumulate and export as Prometheus text" {
        $c = New-MetricCounter -Name 'gbuild_e2e_total' -Help 'e2e test counter'
        Add-Metric -Metric $c
        Submit-BuildMetric -Name 'gbuild_e2e_total' -Value 1 -Labels @{ os = 'test' }
        $prom = Get-MetricsAsPrometheus
        $prom | Should -Match 'gbuild_e2e_total'
    }

    It "Send-OtelTraces degrades gracefully on unreachable collector" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        $trace = @{ resourceSpans = @( @{ name = 'gbuild.build' } ) }
        { Send-OtelTraces -State $state -OtelEndpoint $script:DeadEndpoint -TraceData $trace } | Should -Not -Throw
    }

    It "Send-OtelMetrics degrades gracefully on unreachable collector" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        { Send-OtelMetrics -State $state -OtelEndpoint $script:DeadEndpoint } | Should -Not -Throw
    }

    It "Send-OtelTraces pushes valid JSON to a live mock collector" {
        $collectorPort = 41827
        $collectorJob = Start-Job -ScriptBlock {
            param($p)
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$p/")
            $l.Start()
            $ctx = $l.GetContext()
            $r = New-Object System.IO.StreamReader($ctx.Request.InputStream)
            $body = $r.ReadToEnd()
            $r.Close()
            $ctx.Response.StatusCode = 200
            $ctx.Response.Close()
            $l.Stop(); $l.Dispose()
            return @{ Body = $body; ContentType = $ctx.Request.ContentType; Method = $ctx.Request.HttpMethod; Url = $ctx.Request.RawUrl }
        } -ArgumentList $collectorPort

        Start-Sleep 2

        $traceData = @{ resourceSpans = @(@{ name = 'gbuild.e2e' }) }
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        Send-OtelTraces -State $state -OtelEndpoint "http://127.0.0.1:$collectorPort" -TraceData $traceData

        $done = $collectorJob | Wait-Job -Timeout 10
        $done | Should -Not -BeNullOrEmpty
        $result = $collectorJob | Receive-Job
        $result.Method | Should -Be 'POST'
        $result.Url | Should -Be '/v1/traces'
        $result.Body | Should -Match 'gbuild.e2e'
    }

    It "Send-OtelMetrics pushes valid JSON to a live mock collector" {
        Clear-Metrics
        Add-Metric -Metric (New-MetricCounter -Name 'gbuild_test_e2e' -Help 'e2e test' -Labels @{})
        $collectorPort = 41828
        $collectorJob = Start-Job -ScriptBlock {
            param($p)
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$p/")
            $l.Start()
            $ctx = $l.GetContext()
            $r = New-Object System.IO.StreamReader($ctx.Request.InputStream)
            $body = $r.ReadToEnd()
            $r.Close()
            $ctx.Response.StatusCode = 200
            $ctx.Response.Close()
            $l.Stop(); $l.Dispose()
            return @{ Body = $body; Method = $ctx.Request.HttpMethod; Url = $ctx.Request.RawUrl }
        } -ArgumentList $collectorPort

        Start-Sleep 2

        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        Send-OtelMetrics -State $state -OtelEndpoint "http://127.0.0.1:$collectorPort"

        $done = $collectorJob | Wait-Job -Timeout 10
        $done | Should -Not -BeNullOrEmpty
        $result = $collectorJob | Receive-Job
        $result.Method | Should -Be 'POST'
        $result.Url | Should -Be '/v1/metrics'
        $result.Body | Should -Match 'gbuild_test_e2e'
    }
}
