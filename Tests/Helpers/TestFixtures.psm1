Set-StrictMode -Version 1.0

function New-TestState {
    [PSCustomObject]@{
        LogLevel    = 3
        ScriptRoot  = $env:TEMP
        DotnetCmd   = 'dotnet'
        CurrentTfm  = 'net10.0'
        BuildConfig = $null
        StartTime   = Get-Date
        OS          = 'Windows'
    }
}

Export-ModuleMember -Function @('New-TestState')
