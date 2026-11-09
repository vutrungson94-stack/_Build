# Sast

17 function(s). Source: `Modules/Sast.psm1`

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

### Resolve-SastToolPath

Parameters: Tool :String, State :PSObject

### Test-SastToolAvailable

Parameters: Tool :String, State :PSObject

### Protect-SastText

Parameters: Text :String, State :PSObject

### Get-SastToolName

Parameters: Fallback :String

### Get-SastToolPolicy

Parameters: State :PSObject

### Get-SastExcludePattern

### Test-SastTestFixturePath

Parameters: FullName :String

### Get-SastProjectLanguages

Parameters: ProjectDir :String, State :PSObject

### ConvertTo-ScriptAnalyzerFindings

Parameters: Records :Object[]

### ConvertTo-SastFindings

Parameters: Tool :String, Output :String, Language :String

### Invoke-SastTool

Parameters: Language :String, ProjectDir :String, State :PSObject

### Invoke-SastScan

Parameters: State :PSObject, ProjectDir :String


