# DotnetHelpers

7 function(s). Source: `Modules/Plugins/helpers/DotnetHelpers.psm1`

### Resolve-DotnetCommand

Parameters: State :PSObject

### Get-DotnetManifestFilters

Parameters: IncludeSolution :SwitchParameter, SolutionOnly :SwitchParameter

### Resolve-DotnetProjectFile

Parameters: ProjectFile :String, ProjectDir :String, Filters :String[]

### Invoke-NpmBuildIfPresent

Parameters: State :PSObject, ProjectDir :String, Label :String, ProjectFile :String, Detailed :SwitchParameter

### Invoke-DotnetTest

Parameters: State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, PluginLabel :String, Detailed :SwitchParameter

### Invoke-DotnetLint

Parameters: State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, PluginLabel :String, Detailed :SwitchParameter

### Get-DotnetPreflightResult

Parameters: State :PSObject, ProjectDir :String, ProjectFile :String, ManifestFilters :String[]


