# Loader

22 function(s). Source: `Modules/Loader.psm1`

### Register

### Get

### GetAll

### Clear

### Count

### Invoke-PluginCommand

Parameters: ScriptBlock :ScriptBlock, State :PSObject, ProjectDir :String, Label :String, WorkingDir :String, ArgumentList :Object[], Quiet :SwitchParameter

### Test-PluginInterface

Parameters: ModuleName :String, State :PSObject

### Register-Plugins

Parameters: State :PSObject

### Get-RegisteredPlugins

### Resolve-PluginForLanguage

Parameters: Language :String

### Invoke-PreflightForLanguage

Parameters: Language :String, ProjectDir :String, State :PSObject, ProjectFile :String

### Resolve-PluginDispatchContext

Parameters: State :PSObject, ProjectDir :String, ProjectFile :String, ManifestFiles :String[]

### Resolve-PluginDispatchConfiguration

Parameters: State :PSObject, Configuration :String

### Invoke-PluginActionInModule

Parameters: Module :Object, CommandName :String, State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, Incremental :SwitchParameter, Arguments :String, Detailed :SwitchParameter

### ConvertTo-PluginDispatchResult

Parameters: Value :Object, Operation :String

### Get-PluginDispatchOutputPath

Parameters: Result :Object, State :PSObject, ProjectDir :String

### Invoke-PluginBuildFor

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Incremental :SwitchParameter, Detailed :SwitchParameter

### Invoke-PluginTestFor

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Incremental :SwitchParameter, Detailed :SwitchParameter

### Invoke-PluginLintFor

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Incremental :SwitchParameter, Detailed :SwitchParameter

### Invoke-PluginCleanFor

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Detailed :SwitchParameter

### Invoke-PluginRunFor

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Arguments :String, Detailed :SwitchParameter

### Invoke-PluginBuildSafe

Parameters: State :PSObject, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, FallbackLanguage :String, Incremental :SwitchParameter, Detailed :SwitchParameter


