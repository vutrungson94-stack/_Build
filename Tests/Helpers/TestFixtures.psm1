Set-StrictMode -Version 1.0

function New-TestState {
    [PSCustomObject]@{
        LogLevel    = 3
        ScriptRoot  = $( [System.IO.Path]::GetTempPath() )
        DotnetCmd   = 'dotnet'
        CurrentTfm  = 'net10.0'
        BuildConfig = $null
        StartTime   = Get-Date
        OS          = 'Windows'
    }
}

Export-ModuleMember -Function @('New-TestState')
