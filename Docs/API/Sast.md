# Sast

13 function(s). Source: `Modules/Sast.psm1`

### Get-SastConfig

Parameters: State :PSObject

### Get-SastTimeoutSec

Parameters: State :PSObject

### Get-SastDotnetIgnoreNoFindings

Parameters: State :PSObject

### Get-SastToolMap

Parameters: State :PSObject

### Get-SastCommand

Parameters: Language :String, State :PSObject

### Test-SastToolAvailable

Parameters: Tool :String

### Invoke-BuildSecretProtect

Parameters: Text :String, State :PSObject, Patterns :Array, RedactUrls :SwitchParameter, UrlRedactor :ScriptBlock

### Protect-SastText

Parameters: Text :String, State :PSObject

### Get-SastToolPolicy

Parameters: State :PSObject

### Get-SastProjectLanguages

Parameters: ProjectDir :String, State :PSObject

### ConvertTo-SastFindings

Parameters: Tool :String, Output :String, Language :String

### Invoke-SastTool

Parameters: Language :String, ProjectDir :String, State :PSObject

### Invoke-SastScan

Parameters: State :PSObject, ProjectDir :String


