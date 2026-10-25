# RBAC

26 function(s). Source: `Modules/RBAC.psm1`

### New-RBACRole

Parameters: RoleName :String, Permissions :String[], Description :String, Inherits :String, State :PSObject

### Remove-RBACRole

Parameters: RoleName :String, State :PSObject

### Set-RBACRolePermissions

Parameters: RoleName :String, Permissions :String[], Description :String, Inherits :String, State :PSObject

### Get-RBACRoles

Parameters: State :PSObject

### Get-RBACResources

Parameters: State :PSObject

### Get-RBACEffectivePermissions

Parameters: RoleName :String, State :PSObject

### Get-RbacObjectKeys

Parameters: Object :Object

### Get-RbacObjectValue

Parameters: Object :Object, Name :String, Default :Object

### Get-RbacTenant

Parameters: State :PSObject

### Get-RbacAction

Parameters: Permission :String, Action :String

### Test-RbacResource

Parameters: Resource :String, State :PSObject

### Test-RbacTenantScope

Parameters: Roles :String[], State :PSObject

### Initialize-RBAC

Parameters: State :PSObject

### Get-EffectivePermissions

Parameters: RoleName :String

### Resolve-Permission

Parameters: UserRoles :String[], Permission :String, Resource :String, Action :String

### Get-UserRoles

Parameters: State :PSObject, UserName :String

### Test-RBACAuthorization

Parameters: State :PSObject, Permission :String, Resource :String, Action :String, UserName :String

### Test-BuildPermission

Parameters: State :PSObject, Action :String, ProjectName :String, UserName :String

### Test-DeployPermission

Parameters: State :PSObject, Action :String, Environment :String, Target :String, UserName :String

### Test-SecurityPermission

Parameters: State :PSObject, Action :String, ScanType :String, UserName :String

### Test-CachePermission

Parameters: State :PSObject, Action :String, CacheType :String, UserName :String

### Test-ReportPermission

Parameters: State :PSObject, Action :String, ReportType :String, UserName :String

### Test-ArtifactPermission

Parameters: State :PSObject, Action :String, ArtifactType :String, UserName :String

### Test-PolicyAuthorization

Parameters: State :PSObject, PolicyName :String, Input :Hashtable

### Write-RBACAuditEntry

Parameters: State :PSObject, Action :String, Allowed :Boolean, UserName :String, Permission :String, Resource :String, Detail :String

### Assert-RBACAuthorization

Parameters: State :PSObject, Permission :String, Resource :String, Action :String, UserName :String, Message :String


