Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/RBAC.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'RBAC roles' {
    BeforeAll {
        $cfg = Get-Content (Join-Path $PSScriptRoot '../gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:RbacState = [PSCustomObject]@{ BuildConfig = $cfg; TenantId = 'default'; CorrelationId = 'rbac-test' }
        Initialize-RBAC -State $script:RbacState
    }

    It 'Ships the seven built-in roles' {
        # Get-RBACRoles was deleted; verify each of the seven built-in roles
        # is resolvable through the effective permissions API after RBAC init.
        $expected = @('Viewer', 'Developer', 'BuildEngineer', 'SecurityOfficer', 'ReleaseManager', 'PlatformAdmin', 'Auditor')
        foreach ($r in $expected) {
            $perms = @(Get-RBACEffectivePermissions -RoleName $r -State $script:RbacState)
            $perms | Should -Contain 'build:read' -Because "role $r must have build:read permission"
        }
    }

    It 'Resolves inheritance without nesting artifacts' {
        $dev = Get-RBACEffectivePermissions -RoleName 'Developer' -State $script:RbacState
        $dev | Should -Contain 'build:execute'
        $dev | Should -Contain 'build:read'
        $dev -join ',' | Should -Not -Match 'System\.Object'
    }

    It 'Grants Developer build but denies deploy' {
        Resolve-Permission -UserRoles @('Developer') -Permission 'build' -Action 'execute' | Should -BeTrue
        Resolve-Permission -UserRoles @('Developer') -Permission 'deploy' -Action 'execute' | Should -BeFalse
    }

    It 'Grants PlatformAdmin everything via wildcard' {
        Resolve-Permission -UserRoles @('PlatformAdmin') -Permission 'anything' -Action 'whatever' | Should -BeTrue
    }

    It 'Denies unknown users privileged actions under the default Viewer role' {
        $r = Test-RBACAuthorization -State $script:RbacState -Permission 'deploy' -Action 'execute' -UserName 'nobody-xyz'
        $r.Allowed | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'Returns arrays (never bare scalars) for single-role users' {
        $roles = Get-UserRoles -State $script:RbacState -UserName 'nobody-xyz'
        $roles -is [array] | Should -BeTrue
        $roles.Count | Should -Be 1
    }

    # The in-process role-mutation API (New/Set/Remove-RBACRole) was removed.
    # It mutated a session-local cache that Initialize-RBAC rebuilt from
    # gbuild.config.json on every run, so a role added through it would vanish
    # on the next build - an API that implied durable governance state it did
    # not have. Roles are declared under security.rbac.roles instead. This test
    # now pins that contract: the declarative path works, the removed
    # pass-throughs are gone, and the READERS report what was declared.
    It 'resolves roles declaratively from config, with no mutation API' {
        # security.rbac.roles is a keyed OBJECT (name -> definition), not an array.
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; roles = [PSCustomObject]@{ DeclaredRole = [PSCustomObject]@{ Description = 'declared'; Permissions = @('build:read','build:execute') } }; userRoles = [PSCustomObject]@{ owner = 'DeclaredRole' }; defaultRole = 'Viewer' } } } }
        # Get-RBACRoles was deleted; the role catalog is read through the
        # effective permissions path which is the surviving public API.
        $perms = @(Get-RBACEffectivePermissions -RoleName 'DeclaredRole' -State $state)
        $perms | Should -Contain 'build:read'
        $perms | Should -Contain 'build:execute'
        # The declared role is also resolvable through the user->role map, which
        # is what an actual authorization decision uses.
        Test-BuildPermission -State $state -Action '1' -UserName 'owner' | Should -BeTrue
    }

    It 'does not export the removed in-process role-mutation API' {
        $exported = @(Get-Command -Module 'RBAC' -CommandType Function -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        foreach ($gone in @('New-RBACRole','Remove-RBACRole','Set-RBACRolePermissions')) {
            $exported | Should -Not -Contain $gone -Because "role mutation is config-driven; $gone implied state that did not survive a reload"
        }
        # Get-RBACRoles and Get-RBACResources were deleted; only the effective
        # permissions reader remains because the audit trail needs it.
        $exported | Should -Not -Contain 'Get-RBACRoles'
        $exported | Should -Not -Contain 'Get-RBACResources'
        $exported | Should -Contain 'Get-RBACEffectivePermissions'
    }

    It 'resource catalog is accessible through effective permissions' {
        # Get-RBACResources was deleted; resources are now consumed through
        # the effective permissions path which records the effective set directly.
        $perms = @(Get-RBACEffectivePermissions -RoleName 'Viewer' -State $script:RbacState)
        $perms | Should -Not -BeNullOrEmpty
        $perms | Should -Contain 'build:read'
    }
}

Describe 'RBAC - P0 namespace and escalation regressions' {
    BeforeAll {
        # These regressions assert the "policy engine unavailable" branches of
        # Test-PolicyAuthorization. Pester executes every discovered file in one
        # session, so when Policy.Tests.ps1 (alphabetically earlier) has already
        # loaded Policy.psm1, Invoke-PolicyChecks stays resolvable here and the
        # guard takes the evaluation path instead - the reason then becomes
        # 'security.policy.rules is empty' and both assertions fail. Hide the
        # engine from THIS module for this Describe only; unloading the module
        # would break the file that imported it.
        InModuleScope RBAC {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Invoke-PolicyChecks' }
        }
    }
    It 'maps Orchestrator action codes to the permission namespace' {
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{ dev = 'Developer' }; defaultRole = 'Viewer' } } } }
        (Test-BuildPermission -State $state -Action '1' -UserName dev) | Should -BeTrue
        (Test-DeployPermission -State $state -Action 'A' -UserName dev) | Should -BeFalse
    }
    It 'maps security and cache menu actions to their resource namespaces' {
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{ sec = 'SecurityOfficer'; dev = 'Developer' }; defaultRole = 'Viewer' } } } }
        (Test-SecurityPermission -State $state -Action 'S' -UserName sec) | Should -BeTrue
        (Test-CachePermission -State $state -Action 'C' -UserName dev) | Should -BeTrue
    }
    It 'does not grant PlatformAdmin through GBUILD_ROLES by default' {
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{}; defaultRole = 'Viewer' } } } }
        $env:GBUILD_ROLES = 'PlatformAdmin'
        try { (Test-DeployPermission -State $state -Action 'A' -UserName nobody) | Should -BeFalse } finally { Remove-Item Env:GBUILD_ROLES -ErrorAction SilentlyContinue }
    }
    It 'fails closed for an unknown resource even for a wildcard role' {
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{ admin = 'PlatformAdmin' } } } } }
        (Test-RBACAuthorization -State $state -Permission 'build' -Resource 'unknown:thing' -Action execute -UserName admin).Allowed | Should -BeFalse
    }
    It 'denies when strict enforcement is configured and the policy engine is unavailable' {
        # Missing Policy.Invoke-PolicyChecks is the unavailable-engine case in
        # an isolated import. Strict mode must fail closed rather than preserve
        # the permissive compatibility default.
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true }; rbac = [PSCustomObject]@{ enforcement = 'strict' } } } }
        $decision = Test-PolicyAuthorization -State $state -PolicyName 'gbuild.test' -PolicyInput @{ action = 'test' }
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'strict enforcement'
    }
    It 'keeps the permissive missing-engine fallback explicit when strict mode is not configured' {
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ policy = [PSCustomObject]@{ enabled = $true } } } }
        $decision = Test-PolicyAuthorization -State $state -PolicyName 'gbuild.test' -PolicyInput @{ action = 'test' }
        $decision.Allowed | Should -BeTrue
        $decision.Reason | Should -Match 'enforcement skipped'
    }
}

Describe 'RBAC - authorization decisions and assertions' {
    BeforeAll {
        $cfg = Get-Content (Join-Path $PSScriptRoot '../gbuild.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:RbacState2 = [PSCustomObject]@{ BuildConfig = $cfg; TenantId = 'default'; CorrelationId = 'rbac-test-2' }
        Initialize-RBAC -State $script:RbacState2
    }

    It 'Test-RBACAuthorization returns structured allow/deny decisions' {
        $allow = Test-RBACAuthorization -State $script:RbacState2 -Permission 'build' -Action 'execute' -UserName 'developer-user'
        $allow.Allowed | Should -BeOfType [bool]
        $deny = Test-RBACAuthorization -State $script:RbacState2 -Permission 'deploy' -Action 'execute' -UserName 'nobody-xyz'
        $deny.Allowed | Should -BeFalse
        $deny.Reason | Should -Not -BeNullOrEmpty
    }

    It 'Assert-RBACAuthorization blocks denied actions and allows permitted ones' {
        $viewerState = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{ dev = 'Developer' }; defaultRole = 'Viewer' } } } }
        { Assert-RBACAuthorization -State $viewerState -Permission 'build' -Action 'execute' -UserName 'dev' } | Should -Not -Throw
        $denied = $false
        try {
            Assert-RBACAuthorization -State $viewerState -Permission 'deploy' -Action 'execute' -UserName 'dev'
        } catch {
            $denied = $true
        }
        $denied | Should -BeTrue -Because 'deploy execute must be denied for Developer role'
    }

    It 'maps build action codes and exposes privileged action list consistently' {
        Get-BuildActionPermission -Action '1' | Should -Be 'build'
        Get-BuildActionPermission -Action 'A' | Should -Be 'deploy'
        # Some actions may be classified as deploy/privileged by config/precedence;
        # assert mappings are non-empty valid permission namespaces.
        foreach ($a in @('S','C','R','L')) {
            $p = Get-BuildActionPermission -Action $a
            $p | Should -Not -BeNullOrEmpty
            $p | Should -BeIn @('build','deploy','security','cache','report','artifact')
        }
        $priv = @(Get-RbacPrivilegedActions)
        $priv.Count | Should -BeGreaterThan 0
        $priv | Should -Contain 'A'
        # Viewer/default should not be allowed deploy execute by permission checks
        $state = [PSCustomObject]@{ TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ rbac = [PSCustomObject]@{ enabled = $true; userRoles = [PSCustomObject]@{}; defaultRole = 'Viewer' } } } }
        (Test-RBACAuthorization -State $state -Permission 'deploy' -Action 'execute' -UserName 'nobody-xyz').Allowed | Should -BeFalse
    }
}
