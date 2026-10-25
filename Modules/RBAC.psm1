# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'ConfigProvider')

# ============================================================================
# RBAC.psm1 — Role-Based Access Control Engine
# ============================================================================
# Provides enterprise-grade RBAC with roles, permissions, and resource-level
# authorization. Integrates with security.allowedActions and extends it with
# role hierarchies, resource scoping, and dynamic policy evaluation.

# ── Built-in role definitions (single source, config-overridable) ─────────────
$script:DefaultRoles = @{
    'Viewer' = @{
        Description = 'Read-only access to build reports and logs'
        Permissions = @(
            'build:read'
            'report:read'
            'log:read'
            'cache:read'
            'metric:read'
        )
    }
    'Developer' = @{
        Description = 'Standard developer build and test permissions'
        Permissions = @(
            'build:read'
            'build:execute'
            'test:execute'
            'lint:execute'
            'report:read'
            'log:read'
            'cache:read'
            'cache:write'
            'metric:read'
            'artifact:read'
        )
        Inherits = 'Viewer'
    }
    'BuildEngineer' = @{
        Description = 'Full build pipeline control including deploy and cache management'
        Permissions = @(
            'build:read'
            'build:execute'
            'build:configure'
            'test:execute'
            'lint:execute'
            'deploy:read'
            'deploy:execute'
            'cache:read'
            'cache:write'
            'cache:configure'
            'report:read'
            'report:write'
            'log:read'
            'metric:read'
            'artifact:read'
            'artifact:write'
            'security:read'
        )
        Inherits = 'Developer'
    }
    'SecurityOfficer' = @{
        Description = 'Security scanning, policy, and vulnerability management'
        Permissions = @(
            'security:read'
            'security:write'
            'security:configure'
            'scan:execute'
            'policy:read'
            'policy:write'
            'vuln:read'
            'vuln:write'
            'sbom:read'
            'sbom:write'
            'provenance:read'
            'provenance:write'
            'report:read'
            'log:read'
        )
        Inherits = 'Viewer'
    }
    'ReleaseManager' = @{
        Description = 'Release orchestration, versioning, and promotion'
        Permissions = @(
            'build:read'
            'build:execute'
            'deploy:read'
            'deploy:execute'
            'deploy:configure'
            'version:read'
            'version:write'
            'release:read'
            'release:write'
            'promote:execute'
            'artifact:read'
            'artifact:write'
            'report:read'
            'log:read'
        )
        Inherits = 'Developer'
    }
    'PlatformAdmin' = @{
        Description = 'Full platform administration including distributed config and tenants'
        Permissions = @(
            '*'
        )
        Inherits = 'BuildEngineer'
    }
    'Auditor' = @{
        Description = 'Compliance audit access to all logs, reports, and trails'
        Permissions = @(
            'audit:read'
            'log:read'
            'report:read'
            'metric:read'
            'security:read'
            'policy:read'
            'trail:read'
        )
        Inherits = 'Viewer'
    }
}

# ── Default resource hierarchy (config-overridable via security.rbac.resources) ──
$script:DefaultResources = @{
    'build' = @(
        'project'
        'pipeline'
        'configuration'
        'artifact'
    )
    'test' = @(
        'unit'
        'integration'
        'e2e'
        'coverage'
    )
    'deploy' = @(
        'environment'
        'target'
        'promotion'
        'rollback'
    )
    'cache' = @(
        'local'
        'remote'
        'index'
    )
    'security' = @(
        'scan'
        'policy'
        'vulnerability'
        'sbom'
        'provenance'
        'secret'
    )
    'report' = @(
        'build'
        'test'
        'security'
        'trend'
    )
    'log' = @(
        'build'
        'audit'
        'access'
        'error'
    )
    'metric' = @(
        'build'
        'cache'
        'performance'
        'quality'
    )
    'artifact' = @(
        'package'
        'container'
        'binary'
        'symbol'
    )
    'version' = @(
        'bump'
        'changelog'
        'tag'
    )
    'release' = @(
        'create'
        'publish'
        'rollback'
    )
    'promote' = @(
        'environment'
        'approval'
    )
    'audit' = @(
        'trail'
        'compliance'
        'access'
    )
    'trail' = @(
        'build'
        'deploy'
        'security'
        'admin'
    )
    'scan' = @(
        'secret'
        'sast'
        'container'
        'dependency'
        'license'
    )
    'policy' = @(
        'define'
        'evaluate'
        'enforce'
    )
    'vuln' = @(
        'report'
        'remediate'
        'suppress'
    )
    'sbom' = @(
        'generate'
        'sign'
        'verify'
    )
    'provenance' = @(
        'generate'
        'sign'
        'verify'
    )
    'secret' = @(
        'scan'
        'redact'
        'rotate'
    )
    # Well-known actions per resource family (distinct keys: the resource-type
    # entries above — 'cache', 'log', 'report', 'metric', 'artifact' — already
    # declare sub-resource scopes; these declare the action vocabulary).
    'cacheActions' = @(
        'read'
        'write'
        'configure'
        'evict'
        'sync'
    )
    'logActions' = @(
        'read'
        'search'
        'export'
    )
    'reportActions' = @(
        'read'
        'write'
        'export'
        'schedule'
    )
    'metricActions' = @(
        'read'
        'write'
        'alert'
    )
    'artifactActions' = @(
        'read'
        'write'
        'sign'
        'verify'
        'promote'
    )
}

# ── Module state ──────────────────────────────────────────────────────────────
# Per-tenant RBAC caches. These were three module-level hashtables plus a single
# $script:Initialized boolean, so the FIRST State to touch the module won for
# the rest of the process: a second tenant, or a second config, silently reused
# the first tenant's roles and resources. In a multi-tenant build that is a
# tenant-isolation failure, and it also made the module non-reentrant for any
# host that runs more than one build in a session.
# Key: policy-domain fingerprint (tenant + hash of security.rbac), see
# Get-RbacCacheKey. Value: @{ RoleCache; PermissionCache; ResourceCache }.
$script:RBACCaches = @{}
$script:RoleCache = @{}
$script:PermissionCache = @{}
$script:ResourceCache = @{}

function Get-RbacCacheKey {
    param([PSCustomObject]$State = $null)

Set-StrictMode -Version 1.0
    # The cache key identifies the POLICY DOMAIN, not just the tenant. Two
    # States can share a tenant id and still declare different
    # security.rbac.roles/resources (different projects in one session, a
    # tenant override, a profile). Keying on the tenant alone reused the first
    # domain's roles for the second - a privilege confusion bug.
    $t = 'default'
    try { $t = [string](Get-RbacTenant -State $State) } catch { $t = 'default' }
    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'default' }
    $fingerprint = ''
    try {
        $rbacCfg = Get-ConfigValue -Path 'security.rbac' -State $State -Default $null
        if ($null -ne $rbacCfg) { $fingerprint = [string]($rbacCfg | ConvertTo-Json -Compress -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } else { 10 })) }
    } catch { $fingerprint = '' }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { return "$t|none" }
    # SharedUtils.Get-BuildStringHash owns UTF8 -> SHA256 -> lowercase hex.
    # Same digest as the inline copy this replaces, so the RBAC config
    # fingerprint that invalidates cached decisions stays byte-identical. The
    # fallback is gone rather than kept as a second spelling: two copies of one
    # hash is exactly how the cache-key hash ended up case-inconsistent once.
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    $hex = Get-BuildStringHash -Text $fingerprint
    if (-not $hex) { return "$t|unavailable" }
    return "$t|" + $hex.Substring(0, 32)
}

# ── Initialization ────────────────────────────────────────────────────────────

# ── Core permission resolution ────────────────────────────────────────────────


# ── User/Role assignment ──────────────────────────────────────────────────────

# ── Authorization decision functions ──────────────────────────────────────────


# ── Resource-level authorization helpers ──────────────────────────────────────






# ── Policy-as-Code integration (OPA/Rego fallback) ────────────────────────────

# ── Audit logging integration ─────────────────────────────────────────────────


# Role-mutation API (New-RBACRole / Remove-RBACRole / Set-RBACRolePermissions)
# was REMOVED. Those three mutated an in-process $script:RoleCache only, had
# zero production callers, and duplicated the supported path: roles are defined
# declaratively under security.rbac.roles in gbuild.config.json and rebuilt by
# Initialize-RBAC on every run. Keeping both meant a caller could add a role
# that vanished on the next build - the API implied durable governance state
# that did not exist.
#
# The two READERS below (Get-RBACRoles / Get-RBACResources) were deleted for
# the same reason: no production caller, and keeping them kept this comment
# describing a wiring that no longer existed. Write-RBACAuditEntry now records
# the effective permission set directly, which is the part a post-incident
# review actually needs.
function Get-RBACEffectivePermissions {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RoleName,
        [PSCustomObject]$State
    )
    Initialize-RBAC -State $State
    return Get-EffectivePermissions -RoleName $RoleName
}

function Get-RbacObjectKeys {
    param($Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
    return @($Object.PSObject.Properties.Name)
}

<#
.SYNOPSIS
    Case-insensitive config-node accessor. Single source: ConfigProvider.Get-SectionValue.
.DESCRIPTION
    The local implementation used `$Object.Contains($Name)` only, so a config node
    arriving as an ORDINAL dictionary missed on a mere casing difference and the
    caller silently fell back to its default - a security-relevant default (an
    RBAC role/permission resolving to nothing instead of the configured value).
#>
function Get-RbacObjectValue {
    param($Object, [string]$Name, $Default = $null)
    # Unconditional delegation; see AuditLedger.Get-LedgerField for why the
    # 9-line inline fallback this replaced could never execute (RBAC hard-imports
    # ConfigProvider with Get-SectionValue as its sentinel).
    return Get-SectionValue -Section $Object -Key $Name -Default $Default
}

function Get-RbacTenant {
    param([PSCustomObject]$State)
    $tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
    if ($tenant -eq 'default') { return $tenant }
    if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $tenant.Contains('..') -or $tenant -match '[. ]$') { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.rbac.line395' -Fallback 'RBAC tenant is invalid.')) }
    return $tenant
}

function Get-RbacAction {
    param([string]$Permission, [string]$Action)
    if ([string]::IsNullOrWhiteSpace($Action)) { return '' }
    $lower = $Action.ToLowerInvariant()
    if ($lower -in @('read','write','execute','configure','promote','rollback','scan','search','export','sign','verify','generate','evaluate','enforce','define','report','remediate','suppress','redact','rotate','evict','sync','alert','schedule')) { return $lower }
    switch ([string]$Permission.ToLowerInvariant()) {
        'report' { if ($lower -eq 'r') { return 'read' } }
        'artifact' { if ($lower -eq 'l') { return 'write' } }
        'security' { if ($lower -eq 's') { return 'execute' } }
        'cache' { if ($lower -eq 'c') { return 'write' } }
        'deploy' { if ($lower -in @('a','b','v','g','p','f','e','k','y','n')) { return 'execute' } }
        'build' { if ($lower -match '^\d+$') { return 'execute' } }
    }
    return $lower
}

function Test-RbacResource {
    param([string]$Resource, [PSCustomObject]$State)
    if ([string]::IsNullOrWhiteSpace($Resource)) { return $true }
    $tenant = Get-RbacTenant -State $State
    $known = @('action','project','environment','target','promotion','rollback','cache','report','log','metric','artifact','version','release','promote','audit','trail','scan','policy','vuln','sbom','provenance','secret','configuration','pipeline')
    foreach ($part in ($Resource -split ',')) {
        $token = $part.Trim()
        if (-not $token) { continue }
        $type = if ($token -match '^([^:]+):') { $matches[1].ToLowerInvariant() } else { $token.ToLowerInvariant() }
        if ($type -eq 'tenant') { if ($token -notmatch ('^tenant:' + [regex]::Escape($tenant) + '$')) { return $false }; continue }
        if ($type -notin $known -and -not $script:ResourceCache.ContainsKey($type)) { return $false }
    }
    return $true
}

function Test-RbacTenantScope {
    param([string[]]$Roles, [PSCustomObject]$State)
    $tenant = Get-RbacTenant -State $State
    foreach ($role in $Roles) {
        if (-not $script:RoleCache.ContainsKey($role)) { continue }
        $definition = $script:RoleCache[$role]
        foreach ($key in @('AllowedTenants','Tenants','allowedTenants')) {
            $allowed = Get-RbacObjectValue -Object $definition -Name $key -Default $null
            if ($null -ne $allowed -and @($allowed).Count -gt 0 -and $tenant -notin @($allowed)) { return $false }
        }
    }
    return $true
}

function Initialize-RBAC {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $cacheKey = Get-RbacCacheKey -State $State
    if ($script:RBACCaches.ContainsKey($cacheKey)) {
        $script:RoleCache = $script:RBACCaches[$cacheKey].RoleCache
        $script:PermissionCache = $script:RBACCaches[$cacheKey].PermissionCache
        $script:ResourceCache = $script:RBACCaches[$cacheKey].ResourceCache
        return
    }
    # Start from the built-in tables so a partial config OVERLAYS the platform
    # defaults instead of erasing them. Both caches used to be created empty and
    # populated only from config, so a config that declared a single custom
    # role/resource silently dropped Viewer, Developer, ... and all 19 built-in
    # resources - which then failed every authorization check. The schema already
    # documented "merges with built-in"; this is what that requires.
    $script:RoleCache = $script:DefaultRoles.Clone()
    $script:ResourceCache = $script:DefaultResources.Clone()
    $script:PermissionCache = @{}
    $configuredRoles = Get-ConfigValue -Path 'security.rbac.roles' -State $State -Default $null
    if ($configuredRoles) {
        foreach ($roleName in (Get-RbacObjectKeys -Object $configuredRoles)) {
            $definition = Get-RbacObjectValue -Object $configuredRoles -Name $roleName
            $permissions = @(Get-RbacObjectValue -Object $definition -Name 'Permissions' -Default @())
            $inherits = [string](Get-RbacObjectValue -Object $definition -Name 'Inherits' -Default '')
            $description = [string](Get-RbacObjectValue -Object $definition -Name 'Description' -Default '')
            $script:RoleCache[$roleName] = @{ Description = $description; Permissions = $permissions; Inherits = $inherits; AllowedTenants = @(Get-RbacObjectValue -Object $definition -Name 'AllowedTenants' -Default @()) }
            $script:PermissionCache[$roleName] = @(Get-EffectivePermissions -RoleName $roleName)
        }
    }
    $configuredResources = Get-ConfigValue -Path 'security.rbac.resources' -State $State -Default $null
    if ($configuredResources) { foreach ($resourceName in (Get-RbacObjectKeys -Object $configuredResources)) { $script:ResourceCache[$resourceName] = @(Get-RbacObjectValue -Object $configuredResources -Name $resourceName -Default @()) } }
    foreach ($roleName in @($script:RoleCache.Keys)) { $script:PermissionCache[$roleName] = @(Get-EffectivePermissions -RoleName $roleName) }
    $script:RBACCaches[$cacheKey] = @{ RoleCache = $script:RoleCache; PermissionCache = $script:PermissionCache; ResourceCache = $script:ResourceCache }
}

function Get-EffectivePermissions {
    [CmdletBinding()]
    param([string]$RoleName)
    if ($script:PermissionCache.ContainsKey($RoleName)) { return @($script:PermissionCache[$RoleName]) }
    if (-not $script:RoleCache.ContainsKey($RoleName)) { return @() }
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $resolve = {
        param([string]$Name)
        if (-not $visited.Add($Name)) { return @() }
        $role = $script:RoleCache[$Name]
        $result = @($role.Permissions)
        if ($role.Inherits -and $script:RoleCache.ContainsKey($role.Inherits)) { $result += @(& $resolve $role.Inherits) }
        return @($result | Select-Object -Unique)
    }
    return @(& $resolve $RoleName)
}

function Resolve-Permission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$UserRoles, [Parameter(Mandatory)][string]$Permission, [string]$Resource = '', [string]$Action = '')
    $base = ($Permission -split ':')[0].ToLowerInvariant()
    $semanticAction = Get-RbacAction -Permission $base -Action $Action
    $candidates = [System.Collections.Generic.List[string]]::new()
    [void]$candidates.Add($base + ':' + $semanticAction)
    [void]$candidates.Add($base + ':' + $Action.ToLowerInvariant())
    [void]$candidates.Add($base + ':*')
    if ($Resource) {
        foreach ($part in ($Resource -split ',')) {
            $token = $part.Trim().ToLowerInvariant()
            if (-not $token) { continue }
            if ($token -like 'action:*') { [void]$candidates.Add($base + ':' + $token) }
            else { $type = ($token -split ':')[0]; [void]$candidates.Add($base + ':' + $type + ':' + $semanticAction); [void]$candidates.Add($base + ':' + $type + ':*') }
        }
    }
    if ($base -eq 'security' -and $Resource -match '(^|,)scan(?::|$)') { [void]$candidates.Add('scan:' + $semanticAction) }
    foreach ($role in $UserRoles) {
        $permissions = @(Get-EffectivePermissions -RoleName $role)
        foreach ($candidate in $candidates) { if ($permissions -contains '*' -or $permissions -contains $candidate) { return $true } }
        if ($semanticAction -and @($permissions | Where-Object { $_ -eq ('*:' + $semanticAction) }).Count -gt 0) { return $true }
    }
    return $false
}

function Get-UserRoles {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$UserName = '')
    $tenant = Get-RbacTenant -State $State
    if (-not $UserName) { $UserName = if ($State -and $State.PSObject.Properties.Name -contains 'BuildIdentity' -and $State.BuildIdentity.User) { [string]$State.BuildIdentity.User } else { $env:USERNAME } }
    $roles = [System.Collections.Generic.List[string]]::new()
    $userRoles = Get-ConfigValue -Path 'security.rbac.userRoles' -State $State -Default @{}
    $mapped = Get-RbacObjectValue -Object $userRoles -Name $UserName -Default $null
    foreach ($role in @($mapped)) { if ($role) { [void]$roles.Add([string]$role) } }
    $groupRoles = Get-ConfigValue -Path 'security.rbac.groupRoles' -State $State -Default @{}
    if (Get-Command Get-UserGroups -ErrorAction SilentlyContinue) { try { foreach ($group in @(Get-UserGroups -UserName $UserName)) { foreach ($role in @(Get-RbacObjectValue -Object $groupRoles -Name ([string]$group) -Default @())) { if ($role) { [void]$roles.Add([string]$role) } } } } catch { } }
    if ($tenant -ne 'default') {
        $tenantRoles = Get-ConfigValue -Path ('security.tenants.' + $tenant + '.rbac.roles') -State $State -Default @{}
        foreach ($role in @(Get-RbacObjectValue -Object $tenantRoles -Name $UserName -Default @())) { if ($role) { [void]$roles.Add([string]$role) } }
        $tenantMap = Get-ConfigValue -Path 'security.rbac.tenantRoles' -State $State -Default @{}
        $mappedTenant = Get-RbacObjectValue -Object $tenantMap -Name $tenant -Default @{}
        foreach ($role in @(Get-RbacObjectValue -Object $mappedTenant -Name $UserName -Default @())) { if ($role) { [void]$roles.Add([string]$role) } }
    }
    if ($roles.Count -eq 0) { $defaultRole = [string](Get-ConfigValue -Path 'security.rbac.defaultRole' -State $State -Default 'Viewer'); [void]$roles.Add($defaultRole) }
    $trusted = ($State -and (($State.PSObject.Properties.Name -contains 'TrustedEnvironment' -and [bool]$State.TrustedEnvironment) -or ($State.PSObject.Properties.Name -contains 'TrustedRoleEnvironment' -and [bool]$State.TrustedRoleEnvironment)))
    $trustedConfig = [bool](Get-ConfigValue -Path 'security.rbac.trustEnvironmentRoles' -State $State -Default $false)
    $trustedFlag = $env:GBUILD_RBAC_TRUST_ENV -eq '1' -or $env:GBUILD_TRUSTED_ENV -eq '1'
    $allowedEnvRoles = @(Get-ConfigValue -Path 'security.rbac.trustedEnvRoles' -State $State -Default @())
    if (($trusted -or ($trustedConfig -and $trustedFlag)) -and $env:GBUILD_ROLES) {
        foreach ($role in @($env:GBUILD_ROLES -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { if ($allowedEnvRoles.Count -eq 0 -or $allowedEnvRoles -contains $role) { [void]$roles.Add($role) } }
    }
    return ,@($roles | Select-Object -Unique)
}

function Test-RBACAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$Permission, [string]$Resource = '', [string]$Action = '', [string]$UserName = '')
    Initialize-RBAC -State $State
    $roles = @(Get-UserRoles -State $State -UserName $UserName)
    $allowed = (Test-RbacResource -Resource $Resource -State $State) -and (Test-RbacTenantScope -Roles $roles -State $State) -and (Resolve-Permission -UserRoles $roles -Permission $Permission -Resource $Resource -Action $Action)
    $reason = if ($allowed) { '' } else { "User '$UserName' with roles [$($roles -join ', ')] lacks permission '$Permission'" + $(if ($Resource) { ":$Resource" }) + $(if ($Action) { ":$Action" }) }
    return @{ Allowed = $allowed; Roles = $roles; Permission = $Permission; Resource = $Resource; Action = $Action; TenantId = Get-RbacTenant -State $State; Reason = $reason }
}

function Test-BuildPermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$ProjectName = '', [string]$UserName = '')
    $resource = if ($ProjectName) { 'project:' + $ProjectName } else { 'project' }
    $decision = Test-RBACAuthorization -State $State -Permission 'build' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Test-DeployPermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$Environment = '', [string]$Target = '', [string]$UserName = '')
    $resource = if ($Environment) { 'environment:' + $Environment } else { 'environment' }; if ($Target) { $resource += ',target:' + $Target }
    $decision = Test-RBACAuthorization -State $State -Permission 'deploy' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Test-SecurityPermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$ScanType = '', [string]$UserName = '')
    $resource = if ($ScanType) { 'scan:' + $ScanType } else { 'scan' }
    $decision = Test-RBACAuthorization -State $State -Permission 'security' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Test-CachePermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$CacheType = '', [string]$UserName = '')
    $resource = if ($CacheType) { 'cache:' + $CacheType } else { 'cache' }
    $decision = Test-RBACAuthorization -State $State -Permission 'cache' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Test-ReportPermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$ReportType = '', [string]$UserName = '')
    $resource = if ($ReportType) { 'report:' + $ReportType } else { 'report' }
    $decision = Test-RBACAuthorization -State $State -Permission 'report' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Test-ArtifactPermission {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [string]$ArtifactType = '', [string]$UserName = '')
    $resource = if ($ArtifactType) { 'artifact:' + $ArtifactType } else { 'artifact' }
    $decision = Test-RBACAuthorization -State $State -Permission 'artifact' -Resource $resource -Action $Action -UserName $UserName
    return [bool]$decision.Allowed
}

function Get-RbacEnforcementMode {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    # L5: fail-closed opt-in. Default 'permissive' preserves compat (missing
    # engine skips enforcement, audit-logged). 'strict' denies on missing
    # engine or evaluation error. Reads security.rbac.enforcement, falls back
    # to security.policy.enforcement for single-knob operation.
    #
    # The catch used to return 'permissive' for BOTH "no setting configured"
    # (the intended default) and "the config read THREW" (a broken/unreadable
    # config). This function is the sole arming switch for every fail-closed
    # branch in the module (the policy gate at :1006 keys off it), so a
    # transient read failure silently disarmed fail-closed enforcement. Now a
    # read failure returns 'strict' - the safe direction - while an ABSENT
    # setting still yields the documented 'permissive' default.
    try {
        $mode = [string](Get-ConfigValue -Path 'security.rbac.enforcement' -State $State -Default '')
        if (-not [string]::IsNullOrWhiteSpace($mode)) { return $mode.ToLowerInvariant() }
        $pmode = [string](Get-ConfigValue -Path 'security.policy.enforcement' -State $State -Default '')
        if ($pmode.ToLowerInvariant() -in @('strict', 'fail')) { return 'strict' }
    } catch {
        # A setting the operator explicitly chose to 'strict' must not be
        # downgraded because the config read failed. Fail toward enforcement.
        Write-Log (Resolve-LogMessage -Key 'log.rbac.enforcementReadFailed' -Fallback '[RBAC] Enforcement-mode config read failed; defaulting to strict (fail-closed)') 'Warn' $State
        return 'strict'
    }
    return 'permissive'
}

function Test-PolicyAuthorization {
    [CmdletBinding()]
    # NOTE: param was [hashtable]$Input which collides with the automatic
    # $Input variable and broke ALL calls (binding error Object[]->Hashtable).
    # Renamed to PolicyInput; the value was never consumed by the body.
    param([PSCustomObject]$State, [string]$PolicyName, [hashtable]$PolicyInput)
    $policy = Get-ConfigValue -Path 'security.policy' -State $State -Default $null
    if (-not $policy -or -not (Get-RbacObjectValue -Object $policy -Name 'enabled' -Default $false)) { return @{ Allowed = $true; Reason = 'policy disabled' } }
    # CORRECTED. This called `Test-OpaPolicy`, which is defined NOWHERE in the
    # repository. Because the guard below returned Allowed=$false when the
    # command was missing, enabling security.rbac.enabled together with the
    # shipped security.policy.enabled=true denied EVERY action, permanently -
    # the RBAC path had never been exercised end to end.
    # Canonical entrypoint is Policy.Invoke-PolicyChecks (opa-server -> opa CLI
    # -> builtin), which already returns the Pass/Status/Violations contract the
    # pipeline consumes. Route through it and translate its verdict here so
    # this wrapper keeps the Allowed/Reason shape Assert-RBACAuthorization
    # expects.
    if (-not (Get-Command Invoke-PolicyChecks -ErrorAction SilentlyContinue)) {
        # Permissive by default (compat): a missing optional policy engine must
        # not lock every operator out. Strict mode denies (fail-closed) so
        # production can enforce paved-road. Gap stays auditable either way.
        $mode = Get-RbacEnforcementMode -State $State
        if ($mode -in @('strict', 'fail', 'block')) {
            return @{ Allowed = $false; Reason = 'policy engine unavailable (Policy module not loaded) - denied by strict enforcement' }
        }
        return @{ Allowed = $true; Reason = 'policy engine unavailable (Policy module not loaded) - enforcement skipped' }
    }
    $projectDir = ''
    try { if ($State -and $State.PSObject.Properties.Name -contains 'ProjectRoot') { $projectDir = [string]$State.ProjectRoot } } catch { }
    try {
        $result = Invoke-PolicyChecks -State $State -ProjectDir $projectDir
    } catch {
        $mode = Get-RbacEnforcementMode -State $State
        if ($mode -in @('strict', 'fail', 'block')) {
            return @{ Allowed = $false; Reason = "policy evaluation error (fail-closed): $($_.Exception.Message)"; Policy = $PolicyName }
        }
        return @{ Allowed = $true; Reason = "policy evaluation error (fail-open): $($_.Exception.Message)"; Policy = $PolicyName }
    }
    $pass = $true
    if ($result -and $result.ContainsKey('Pass')) { $pass = [bool]$result.Pass } else { $pass = $true }
    $reason = ''
    if ($result -and $result.ContainsKey('Reason')) { $reason = [string]$result.Reason }
    if (-not $pass -and [string]::IsNullOrWhiteSpace($reason)) { $reason = "Policy denied '$PolicyName'" }
    return @{ Allowed = $pass; Reason = $reason; Policy = $PolicyName; Status = if ($result -and $result.ContainsKey('Status')) { [string]$result.Status } else { '' }; Violations = if ($result -and $result.ContainsKey('Violations')) { @($result.Violations) } else { @() } }
}

function Write-RBACAuditEntry {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action, [bool]$Allowed, [string]$UserName = '', [string]$Permission = '', [string]$Resource = '', [string]$Detail = '')
    # Get-RBACRoles and Get-RBACResources were deleted: exported, and called by
    # nothing. Write-RBACAuditEntry's own comment recorded the reason they had to
    # go - an audit trail that documented "RBAC allowed this" without recording
    # WHICH role set produced the verdict is useless for a post-incident review,
    # which is the point of an audit trail. The effective set is recorded
    # directly instead, so keeping the readers alive would keep the misleading
    # audit entry reachable.
    $rolesApplied = ''
    $effectivePerms = ''
    try {
        $userForPerms = if ($UserName) { $UserName } elseif ($State -and $State.BuildIdentity) { [string]$State.BuildIdentity.User } else { $env:USERNAME }
        $roleNames = @(Get-UserRoles -State $State -UserName $userForPerms)
        $rolesApplied = ($roleNames -join ',')
        $permSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($r in $roleNames) { foreach ($p in @(Get-RBACEffectivePermissions -RoleName $r -State $State)) { if ($p) { [void]$permSet.Add([string]$p) } } }
        $effectivePerms = (@($permSet) | Sort-Object) -join ','
    } catch { }
    # REDACT. This entry carried the raw, unredacted $Detail while
    # Security.Write-AuditLog redacts - so the RBAC sink leaked anything a
    # caller passed through it. Route both sinks through the same protector.
    if (Get-Command Invoke-BuildSecretProtect -ErrorAction SilentlyContinue) {
        try {
            $Detail = [string](Invoke-BuildSecretProtect -Text ([string]$Detail))
        } catch { }
    } elseif (Get-Command Protect-AlertText -ErrorAction SilentlyContinue) {
        try { $Detail = [string](Protect-AlertText -Text ([string]$Detail) -State $State) } catch { }
    }
    $entry = @{ Timestamp = (Get-Date).ToString('o'); Type = 'RBAC'; Action = $Action; Allowed = $Allowed; User = if ($UserName) { $UserName } elseif ($State -and $State.BuildIdentity) { [string]$State.BuildIdentity.User } else { $env:USERNAME }; Roles = @(Get-UserRoles -State $State -UserName $UserName) -join ','; RolesApplied = $rolesApplied; EffectivePermissions = $effectivePerms; Permission = $Permission; Resource = $Resource; Detail = $Detail; CorrelationId = if ($State -and $State.CorrelationId) { [string]$State.CorrelationId } else { '' }; TenantId = Get-RbacTenant -State $State }
    $ledgerWritten = $true
    $ledgerConfig = Get-ConfigValue -Path 'security.auditLedger' -State $State -Default $null
    $ledgerEnabled = $false
    if ($ledgerConfig) { if ($ledgerConfig -is [System.Collections.IDictionary]) { $ledgerEnabled = $ledgerConfig.Contains('enabled') -and [bool]$ledgerConfig['enabled'] } else { $ledgerEnabled = ($ledgerConfig.PSObject.Properties.Name -contains 'enabled' -and [bool]$ledgerConfig.enabled) } }
    if ($ledgerEnabled -and -not (Get-Command Write-AuditLedgerEntry -ErrorAction SilentlyContinue)) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.rbac.line721' -Fallback 'Tamper-resistant audit ledger is unavailable.')) }
    if (Get-Command Write-AuditLedgerEntry -ErrorAction SilentlyContinue) { $ledgerWritten = [bool](Write-AuditLedgerEntry -State $State -Entry $entry) }
    if (-not $ledgerWritten) { throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.rbac.line723' -Fallback 'RBAC audit ledger write failed.')) }
    if (Get-Command Write-BuildAuditLog -ErrorAction SilentlyContinue) { $path = Get-AuditLogPath -State $State -DefaultFileName 'rbac-audit.log'; Write-BuildAuditLog -LogPath $path -Entry $entry | Out-Null }
    return $true
}

function Assert-RBACAuthorization {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Permission, [string]$Resource = '', [string]$Action = '', [string]$UserName = '', [string]$Message = '')
    $decision = Test-RBACAuthorization -State $State -Permission $Permission -Resource $Resource -Action $Action -UserName $UserName
    if (Get-Command Write-RBACAuditEntry -ErrorAction SilentlyContinue) { [void](Write-RBACAuditEntry -State $State -Action ('rbac:' + $(if ($decision.Allowed) { 'allow' } else { 'deny' }) + ':' + $Permission) -Allowed ([bool]$decision.Allowed) -UserName $UserName -Permission $Permission -Resource $Resource -Detail $decision.Reason) }
    if (-not $decision.Allowed) { $text = if ($Message) { $Message } else { $decision.Reason }; throw (Resolve-LogMessage -Key 'log.rbac.line733' -Fallback 'RBAC Authorization Failed: ' + $text) }
}

# ============================================================================
# Menu-choice authorization (moved from Orchestrator.psm1 2026-10).
# These three resolve which RBAC permission class a menu choice needs and
# evaluate the allow-list; they belong to the RBAC engine, not the build flow.
# ============================================================================

<#
.SYNOPSIS
    Maps a menu choice to its RBAC permission class.
.DESCRIPTION
    SINGLE SOURCE for "which RBAC permission does this menu choice need?".
    The table used to be duplicated as two independent 6-arm if/elseif chains
    inside Test-ActionAllowed (one resolving the permission TESTER, one
    resolving the permission NAME) plus a third copy of the privileged-action
    list inside Menu.psm1, so adding a choice in one place left the other two
    stale. Every consumer now calls this.
.PARAMETER Action
    The menu choice identifier.
.OUTPUTS
    string: One of 'deploy','security','cache','report','artifact','build'.
#>
function Get-BuildActionPermission {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Action)
    if ([string]::IsNullOrWhiteSpace($Action)) { return 'build' }
    switch ($Action) {
        { $_ -in @(Get-RbacPrivilegedActions -Kind 'deploy') }   { return 'deploy' }
        { $_ -eq 'S' } { return 'security' }
        { $_ -eq 'C' } { return 'cache' }
        { $_ -eq 'R' } { return 'report' }
        { $_ -eq 'L' } { return 'artifact' }
        { $_ -in @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16') } { return 'build' }
        default { return 'build' }
    }
}

<#
.SYNOPSIS
    Returns a canonical class of menu choices (deploy / build / privileged).
.DESCRIPTION
    Replaces the two hardcoded action lists that Orchestrator and Menu each
    carried a copy of. Config override is honoured through
    build.rbac.privilegedActions / build.rbac.ciReadOnlyActions.
#>
function Get-RbacPrivilegedActions {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Kind = 'privileged')
    # ONE owner: BuildConstants.RbacPrivilegedActions, which is config-overridable
    # through security.rbac.privilegedActions. The hardcoded fallback below is a
    # verbatim mirror of that constant. It previously appeared twice with two
    # DIFFERENT lists (10 keys and 14 keys) that also disagreed with the constant
    # itself (13 keys), so whether 'N' counted as privileged depended on which
    # branch executed. Deploy classification and the allow-list must be the same
    # set, so both kinds now resolve through the same fallback.
    $fallback = @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13')
    switch ($Kind) {
        'ciReadOnly' {
            $v = $null
            try { $v = Get-BuildConstant -Key 'RbacCiReadOnlyActions' -State $null -Fallback $null } catch { $v = $null }
            if ($null -ne $v -and @($v).Count -gt 0) { return @($v | ForEach-Object { [string]$_ }) }
            return @('D','H','R')
        }
        default {
            $v = $null
            try { $v = Get-BuildConstant -Key 'RbacPrivilegedActions' -State $null -Fallback $null } catch { $v = $null }
            if ($null -ne $v -and @($v).Count -gt 0) { return @($v | ForEach-Object { [string]$_ }) }
            return $fallback
        }
    }
}

<#
.SYNOPSIS
    Evaluates the RBAC allow-list for a privileged build action.
.DESCRIPTION
    When the config defines `security.allowedActions`, only listed actions are
    permitted; anything else is denied. When the config is absent the default is
    to allow all (backward compatible). Returns a hashtable with `Allowed` and `Reason`.
.PARAMETER State
    The build state (reads BuildConfig.security.allowedActions).
.PARAMETER Action
    The menu choice / action identifier to evaluate.
#>
function Test-ActionAllowed {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Action)
    $cfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.security) { $State.BuildConfig.security } else { $null }
    $tenantId = if ($State -and $null -ne $State.TenantId) { [string]$State.TenantId } else { 'default' }
    $allowed = $null
    $effectiveSource = $null
    if ($cfg) {
        # Tenant-specific override wins when the active (non-default) tenant has one.
        $hasTenants = $cfg.PSObject.Properties.Name -contains 'tenants'
        if ($hasTenants -and $tenantId -ne 'default' -and $cfg.tenants.PSObject.Properties.Name -contains $tenantId) {
            if ($cfg.tenants.($tenantId).PSObject.Properties.Name -contains 'allowedActions') {
                $allowed = $cfg.tenants.($tenantId).allowedActions
                $effectiveSource = "security.tenants.$tenantId.allowedActions"
            }
        }
        if ($null -eq $allowed -and $cfg.PSObject.Properties.Name -contains 'allowedActions') {
            $allowed = $cfg.allowedActions
            $effectiveSource = 'security.allowedActions'
        }
    }
    if ($null -eq $allowed) {
        # No allow-list configured — fall through to RBAC layer below (default allow
        # when RBAC is also disabled, preserving backward compatibility).
    } else {
        if ($allowed -is [System.Collections.ICollection] -and $allowed.Count -eq 0) {
            # Empty allow-list means "deny all privileged actions" (fail-closed).
            return @{ Allowed = $false; Reason = "Action '$Action' denied: $effectiveSource is empty (fail-closed)." }
        }
        if ($Action -notin $allowed) {
            return @{ Allowed = $false; Reason = "Action '$Action' not in $effectiveSource allow-list." }
        }
    }
    # L5 CI deny-by-default: non-interactive runs (CI agents, --NonInteractive)
    # must not execute privileged actions without an explicit allow-list above
    # or full RBAC below. Read-only diagnostics stay available. Opt out per
    # project with security.rbac.enforceInCI=false (audited, not recommended).
    if ($null -eq $allowed) {
        $isCI = [bool]($State -and ($State.IsCI -or $State.NonInteractive))
        if ($isCI) {
            # Raw config read first (same precedent as $rbacCfg above): works
            # even in minimal sessions without the BuildConstants chain loaded.
            $enforceCI = $null
            if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and
                ($State.BuildConfig.security.PSObject.Properties.Name -contains 'rbac') -and
                ($State.BuildConfig.security.rbac.PSObject.Properties.Name -contains 'enforceInCI')) {
                $enforceCI = [bool]$State.BuildConfig.security.rbac.enforceInCI
            }
            if ($null -eq $enforceCI) {
                $enforceCI = $true
                try {
                    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                        $enforceCI = [bool](Get-BuildConstant -Key 'RbacEnforceInCI' -State $State -Fallback $true)
                    }
                } catch { $enforceCI = $true }
            }
            if ($enforceCI) {
                $ciReadOnly = $null
                if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and
                    ($State.BuildConfig.security.PSObject.Properties.Name -contains 'rbac') -and
                    ($State.BuildConfig.security.rbac.PSObject.Properties.Name -contains 'ciReadOnlyActions')) {
                    $ciReadOnly = @($State.BuildConfig.security.rbac.ciReadOnlyActions)
                }
                if ($null -eq $ciReadOnly) {
                    $ciReadOnly = @('D', 'H', 'R')
                    try {
                        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                            $ciReadOnly = @(Get-BuildConstant -Key 'RbacCiReadOnlyActions' -State $State -Fallback @('D', 'H', 'R'))
                        }
                    } catch { $ciReadOnly = @('D', 'H', 'R') }
                }
                if ($Action -notin $ciReadOnly) {
                    return @{ Allowed = $false; Reason = "Action '$Action' denied: CI/non-interactive runs require security.allowedActions (or tenant override) or security.rbac.enabled=true. Read-only: $($ciReadOnly -join ', '). Override: security.rbac.enforceInCI=false." }
                }
            }
        }
    }
    # Level 5 RBAC layer: when security.rbac.enabled, enforce resource-level
    # permissions via RBAC.psm1 helpers (Test-Build/Deploy/Security/Cache/Report/
    # ArtifactPermission + Write-RBACAuditEntry). Disabled by default → no-op.
    # Per-environment override (GBUILD_RBAC_MODE, no config edit needed):
    #   audit   = evaluate + audit-log every decision, always allow (safe rollout)
    #   enforce = same as security.rbac.enabled=true
    #   unset   = config behaviour preserved.
    try {
        $rbacCfg = $null
        if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and ($State.BuildConfig.security.PSObject.Properties.Name -contains 'rbac')) {
            $rbacCfg = $State.BuildConfig.security.rbac
        }
        $rbacEnabled = $false
        if ($rbacCfg -and ($rbacCfg.PSObject.Properties.Name -contains 'enabled')) { $rbacEnabled = [bool]$rbacCfg.enabled }
        $rbacAuditOnly = $false
        if (Get-Command Get-EnvMode -ErrorAction SilentlyContinue) {
            try {
                $rbacEnvMode = Get-EnvMode -Name 'GBUILD_RBAC_MODE'
                if ($rbacEnvMode -eq 'enforce') { $rbacEnabled = $true }
                elseif ($rbacEnvMode -eq 'audit') { $rbacEnabled = $true; $rbacAuditOnly = $true }
            } catch { }
        }
        if ($rbacEnabled) {
            # Module-local now: this function lives in RBAC.psm1, so the old
            # on-demand RBAC import it replaced is gone.
            $userName = if ($State -and $State.BuildIdentity -and $State.BuildIdentity.User) { [string]$State.BuildIdentity.User } else { '' }
            $rbacOk = $true
            $rbacReason = ''
            # SINGLE mapping of menu choice -> RBAC permission class. This table
            # used to be written out twice (once as a 6-arm if/elseif chain that
            # resolved the permission TESTER, once as a 6-arm chain that resolved
            # the permission NAME for Assert-RBACAuthorization), with the
            # privileged-action list repeated in both. Adding an action to one
            # and not the other produced a different verdict depending on which
            # code path ran.
            $permForAction = Get-BuildActionPermission -Action $Action
            $rbacArgs = @{ State = $State; Action = $Action; UserName = $userName }
            if ($permForAction -eq 'build') { $rbacArgs['ProjectName'] = $(if ($State -and $State.ProjectRoot) { Split-Path $State.ProjectRoot -Leaf } else { '' }) }
            # Explicit named calls (not & $name) so the permission testers stay
            # statically discoverable by grep and by ModuleHygiene. The mapping
            # is single-sourced in Get-BuildActionPermission; this switch only
            # applies it.
            $rbacTester = ''
            switch ($permForAction) {
                'deploy'   { if (Get-Command Test-DeployPermission   -ErrorAction SilentlyContinue) { $rbacTester = 'Test-DeployPermission' } }
                'security' { if (Get-Command Test-SecurityPermission -ErrorAction SilentlyContinue) { $rbacTester = 'Test-SecurityPermission' } }
                'cache'    { if (Get-Command Test-CachePermission    -ErrorAction SilentlyContinue) { $rbacTester = 'Test-CachePermission' } }
                'report'   { if (Get-Command Test-ReportPermission   -ErrorAction SilentlyContinue) { $rbacTester = 'Test-ReportPermission' } }
                'artifact' { if (Get-Command Test-ArtifactPermission -ErrorAction SilentlyContinue) { $rbacTester = 'Test-ArtifactPermission' } }
                'build'    { if (Get-Command Test-BuildPermission    -ErrorAction SilentlyContinue) { $rbacTester = 'Test-BuildPermission' } }
            }
            if ($rbacTester) {
                switch ($permForAction) {
                    'deploy'   { $rbacOk = [bool](Test-DeployPermission   @rbacArgs) }
                    'security' { $rbacOk = [bool](Test-SecurityPermission @rbacArgs) }
                    'cache'    { $rbacOk = [bool](Test-CachePermission    @rbacArgs) }
                    'report'   { $rbacOk = [bool](Test-ReportPermission   @rbacArgs) }
                    'artifact' { $rbacOk = [bool](Test-ArtifactPermission @rbacArgs) }
                    'build'    { $rbacOk = [bool](Test-BuildPermission    @rbacArgs) }
                }
                if (-not $rbacOk) { $rbacReason = "RBAC denied $permForAction action '$Action'." }
            }
            if (Get-Command Write-RBACAuditEntry -ErrorAction SilentlyContinue) {
                # Write-RBACAuditEntry DELIBERATELY throws when the tamper-resistant
                # ledger is enabled but unavailable or the write failed
                # (:733/:735). This call site caught and discarded that, so with
                # security.auditLedger.enabled=true and a broken ledger every
                # privileged-action decision was authorized AND unrecorded.
                # Re-raise: the enclosing catch now fails closed under strict.
                Write-RBACAuditEntry -State $State -Action "choice:$Action" -Allowed ([bool]$rbacOk) -UserName $userName -Permission $permForAction -Resource "action:$Action"
            }
            # Audit-only mode (GBUILD_RBAC_MODE=audit): decisions are evaluated
            # and logged above but never deny — safe path to production rollout.
            if ($rbacAuditOnly) {
                if (-not $rbacOk -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                    Write-Log (Get-LocaleMessage -Key 'log.orchestrator.m05' -MessageArgs @($Action, $rbacReason)) 'Warn' $State
                }
                return @{ Allowed = $true; Reason = '' }
            }
            if (-not $rbacOk) {
                return @{ Allowed = $false; Reason = $rbacReason }
            }
            # Strict enforcement via Assert-RBACAuthorization (throws on deny).
            # Wrapped so audit path above always runs; throw converts to deny below.
            if ($rbacTester -and (Get-Command Assert-RBACAuthorization -ErrorAction SilentlyContinue)) {
                try {
                    Assert-RBACAuthorization -State $State -Permission $permForAction -Resource "action:$Action" -Action $Action -UserName $userName
                } catch {
                    return @{ Allowed = $false; Reason = "RBAC assertion failed for '$Action': $($_.Exception.Message)" }
                }
            }
            # Policy-as-code gate via RBAC Test-PolicyAuthorization when OPA/policy enabled.
            # The parameter is -PolicyInput, NOT -Input. The function's parameter
            # was renamed from $Input precisely because $Input is an automatic
            # variable that made the original signature bind-error on every call,
            # but this call site was never updated: `-Input @{...}` does not bind
            # to `-PolicyInput`, the call threw, and the `catch {}` below turned
            # that into silence. The gate therefore NEVER evaluated - policy
            # denials could not stop a deploy - and because
            # security.rbac.enabled ships false the dead branch was never
            # noticed. A policy gate that cannot fail is not a gate.
            if (Get-Command Test-PolicyAuthorization -ErrorAction SilentlyContinue) {
                try {
                    $polResult = Test-PolicyAuthorization -State $State -PolicyName 'gbuild.deploy' -PolicyInput @{ action = $Action; tenant = $tenantId }
                    if ($polResult -and ($polResult.ContainsKey('Allowed')) -and (-not [bool]$polResult.Allowed)) {
                        return @{ Allowed = $false; Reason = "Policy denied '$Action': $($polResult.Reason)" }
                    }
                } catch {
                    # An evaluation error must not read as "allowed". In
                    # permissive mode the module already returns its own
                    # fail-open verdict (and audit-logs it); reaching here means
                    # the module itself could not be called, which is surfaced
                    # rather than swallowed.
                    $mode = 'permissive'
                    if (Get-Command Get-RbacEnforcementMode -ErrorAction SilentlyContinue) {
                        try { $mode = [string](Get-RbacEnforcementMode -State $State) } catch { }
                    }
                    if ($mode -in @('strict', 'fail', 'block')) {
                        return @{ Allowed = $false; Reason = "policy gate error (fail-closed): $($_.Exception.Message)" }
                    }
                }
            }
        }
    } catch {
        # The ENTIRE RBAC + policy enforcement block above sits inside this try.
        # This catch used to be empty and fell through to `Allowed = $true`, so
        # ANY throw inside it - from a permission tester, from
        # Assert-RBACAuthorization, from the deliberate audit-ledger throw at
        # Write-RBACAuditEntry, from the policy gate - silently AUTHORIZED a
        # privileged action. A control that cannot fail is not a control.
        #
        # Now: fail CLOSED whenever the operator asked for enforcement
        # (security.rbac.enforcement / security.policy.enforcement in strict|fail|
        # block, which also covers the case where the config read itself failed -
        # Get-RbacEnforcementMode returns 'strict' then). Under the documented
        # 'permissive' default the behaviour is unchanged, so a project that
        # never opted in keeps working exactly as before.
        $mode = 'permissive'
        if (Get-Command Get-RbacEnforcementMode -ErrorAction SilentlyContinue) {
            try { $mode = [string](Get-RbacEnforcementMode -State $State) } catch { $mode = 'strict' }
        }
        if ($mode -in @('strict', 'fail', 'block')) {
            $reason = "RBAC evaluation error (fail-closed): $($_.Exception.Message)"
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                try { Write-Log (Resolve-LogMessage -Key 'log.rbac.evalFailed' -MessageArgs @([string]$_.Exception.Message) -Fallback '[RBAC] Evaluation error (fail-closed): {0}') 'Err' $State } catch { }
            }
            return @{ Allowed = $false; Reason = $reason }
        }
    }
    return @{ Allowed = $true; Reason = '' }
}

Export-ModuleMember -Function @(
    'Initialize-RBAC',
    'Get-UserRoles',
    'Get-RbacEnforcementMode',
    'Test-RBACAuthorization',
    'Assert-RBACAuthorization',
    'Test-BuildPermission',
    'Test-DeployPermission',
    'Test-SecurityPermission',
    'Test-CachePermission',
    'Test-ReportPermission',
    'Test-ArtifactPermission',
    'Test-PolicyAuthorization',
    'Write-RBACAuditEntry',
    'Get-RBACEffectivePermissions',
    'Resolve-Permission',
    'Get-BuildActionPermission',
    'Get-RbacPrivilegedActions',
    'Test-ActionAllowed'
)
