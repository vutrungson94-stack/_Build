# PluginHelpers

27 function(s). Source: `Modules/Plugins/helpers/PluginHelpers.psm1`

### Resolve-PluginManifest

Parameters: ProjectFile :String, ProjectDir :String, ManifestFiles :String[]

### Get-PluginLocaleText

Parameters: Key :String, MessageArgs :String[], Fallback :String

### Get-SimplePluginPreflight

Parameters: ToolName :String, FallbackToolNames :String[], AnyToolNames :String[], SecondaryToolNames :String[], ManifestFiles :String[], ManifestLabel :String, State :PSObject, ProjectDir :String, ProjectFile :String

### Invoke-SimplePluginTest

Parameters: ToolName :String, ToolNotFoundMsg :String, ManifestFiles :String[], TestCommand :String, State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, Detailed :SwitchParameter

### Invoke-SimplePluginLint

Parameters: ToolName :String, LintToolName :String, ToolNotFoundMsg :String, ManifestFiles :String[], LintCommand :String, State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, MissingToolLevel :String, SoftFail :SwitchParameter, Detailed :SwitchParameter

### Invoke-SimplePluginClean

Parameters: ToolName :String, ToolNotFoundMsg :String, ManifestFiles :String[], CleanCommand :String, State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, Detailed :SwitchParameter

### Invoke-SimplePluginRun

Parameters: ToolName :String, ToolNotFoundMsg :String, ManifestFiles :String[], RunCommand :String, State :PSObject, ProjectDir :String, ProjectFile :String, Configuration :String, Arguments :String, Detailed :SwitchParameter

### Resolve-PluginRunEntry

Parameters: ProjectDir :String, ProjectFile :String, AllowedExtensions :String[]

### Resolve-PluginBuild

Parameters: ToolName :String, ToolNotFoundMsg :String, ManifestFiles :String[], State :PSObject, ProjectDir :String, ProjectFile :String

### Test-NpmScriptDefined

Parameters: PackageJsonPath :String, ScriptName :String

### Resolve-ToolExe

Parameters: Candidates :String[]

### Invoke-WithEnv

Parameters: Name :String, Value :String, ScriptBlock :ScriptBlock, ArgumentList :Object[]

### Test-ConfigFilePresent

Parameters: ProjectDir :String, Patterns :String[]

### Test-PluginTestRequired

Parameters: State :Object

### New-PluginActionResult

Parameters: Status :String, Operation :String, ReasonCode :String, Message :String, ExitCode :Int32, Details :Object, OutputPath :String

### Get-PluginObjectValue

Parameters: Object :Object, Name :String, Default :Object

### ConvertTo-PluginActionResult

Parameters: Value :Object, Operation :String, OutputPath :String

### ConvertTo-PluginBoolean

Parameters: Value :Object, Operation :String

### Invoke-PluginCommandResult

Parameters: ScriptBlock :ScriptBlock, State :Object, ProjectDir :String, WorkingDir :String, ArgumentList :Object[], Label :String

### Resolve-PluginOutputDir

Parameters: State :Object, ProjectDir :String, Subdirectory :String

### New-PluginOutputDirectory

Parameters: State :Object, ProjectDir :String, Subdirectory :String

### Publish-PluginArtifacts

Parameters: Result :Object, State :Object, ProjectDir :String, Subdirectory :String, CandidatePaths :String[]

### Get-CanonicalPathHash

Parameters: Path :String

### Get-PluginFileHash

Parameters: Path :String

### Get-PluginInputHash

Parameters: ProjectDir :String, ProjectFile :String

### Get-PluginToolVersion

Parameters: ToolName :String, State :Object

### Get-PluginCacheKey

Parameters: Plugin :Object, Language :String, ProjectDir :String, ProjectFile :String, Configuration :String, Toolchain :String, InputHash :String


