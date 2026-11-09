# Orchestrator

5 function(s). Source: `Modules/Orchestrator.psm1`

### Test-PreFlight

Parameters: State :PSObject

### Assert-BuildCommandAvailable

Parameters: Command :String, MessageKey :String, Fallback :String

### Send-AnomalyAlertIfNeeded

Parameters: Report :PSObject, State :PSObject

### Assert-CoreCommands

Parameters: State :PSObject, Repair :SwitchParameter

### Start-GBuild

Parameters: GitHub :SwitchParameter, NonInteractive :SwitchParameter, Incremental :SwitchParameter, Clean :SwitchParameter, CacheClear :SwitchParameter, CacheOptimize :SwitchParameter, CacheStats :SwitchParameter, VersionBump :SwitchParameter, Force :SwitchParameter, Security :SwitchParameter, Distributed :SwitchParameter, VerifyInfra :SwitchParameter, Target :String, LogLevel :String


