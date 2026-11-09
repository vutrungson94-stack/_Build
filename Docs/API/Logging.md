# Logging

36 function(s). Source: `Modules/Logging.psm1`

### Get-LogBootstrapConstant

Parameters: Key :String, Fallback :Object

### Resolve-LogMessage

Parameters: Key :String, MessageArgs :String[], Fallback :String

### Get-LogDisplayTimestamp

### Get-LogLocalized

Parameters: Key :String, Fallback :String

### Resolve-BuildText

Parameters: Text :String

### Resolve-ConfigValue

Parameters: State :PSObject, Path :String, Default :Object

### Get-LogConfigValue

Parameters: State :PSObject, Key :String, Default :Object

### Set-LogLevel

Parameters: Level :String

### Invoke-LogRotation

Parameters: Path :String, State :PSObject

### Invoke-LogRetention

Parameters: Directory :String, State :PSObject

### Start-Log

Parameters: Path :String, Level :String, State :PSObject

### Stop-Log

### Get-VisualLength

Parameters: Text :String

### Resolve-SafeColor

Parameters: ColorName :String, State :PSObject, Fallback :String

### Resolve-ConsoleColor

Parameters: State :PSObject, Name :String, Fallback :String

### Write-Log

Parameters: Message :String, Color :String, State :PSObject, Level :String

### Write-ErrorSafe

Parameters: ScriptBlock :ScriptBlock, Message :String, Color :String

### Write-LogSafe

Parameters: Message :String, Color :String, State :PSObject, Level :String

### Write-JsonLog

Parameters: Message :String, Level :String, State :PSObject

### Invoke-BuildSecretProtect

Parameters: Text :String, State :PSObject, Patterns :Array, RedactUrls :SwitchParameter, UrlRedactor :ScriptBlock

### Remove-Credentials

Parameters: Text :String, State :PSObject, Patterns :Array

### _2Col

Parameters: L :String, R :String, LC :String, RC :String, State :PSObject

### Show-ProgressBar

Parameters: Current :Int32, Total :Int32, Label :String

### Write-VisualBox

Parameters: Text :String, Color :String, ShowSeparator :Boolean, Large :SwitchParameter, State :PSObject

### Write-StepTitle

Parameters: Text :String, Color :String, ShowSeparator :Boolean, State :PSObject

### Write-SectionBox

Parameters: Title :String, Color :String, State :PSObject

### Set-StateColors

Parameters: State :PSObject

### Write-SubLog

Parameters: msg :String

### Write-Done

Parameters: msg :String, secs :Double, State :PSObject

### Write-Fail

Parameters: msg :String, secs :Double, State :PSObject

### Write-Info

Parameters: msg :String, State :PSObject

### Write-Warn

Parameters: msg :String, State :PSObject

### Write-Sep

### Set-BuildStateProperty

Parameters: State :PSObject, Name :String, Value :Object, Force :SwitchParameter

### Get-BuildState

Parameters: State :PSObject

### Resolve-BuildState

Parameters: State :PSObject


