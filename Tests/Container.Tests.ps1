#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "DI Container" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Container.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterEach {
        Clear-Services
    }

    It "Register-Service then Resolve-Service returns the factory output" {
        Register-Service -Name 'Greeter' -Factory { 'hello' }
        Resolve-Service -Name 'Greeter' | Should -Be 'hello'
    }

    It "Singleton services cache the instance (factory invoked once)" {
        $global:factoryCount = 0
        Register-Service -Name 'Counter' -Singleton -Factory { $global:factoryCount++; [PSCustomObject]@{ Id = $global:factoryCount } }
        $a = Resolve-Service -Name 'Counter'
        $b = Resolve-Service -Name 'Counter'
        $global:factoryCount | Should -Be 1
        $a | Should -Be $b
    }

    It "Transient services invoke the factory on every resolve" {
        $global:factoryCount = 0
        Register-Service -Name 'Trans' -Factory { $global:factoryCount++; [PSCustomObject]@{ Id = $global:factoryCount } }
        Resolve-Service -Name 'Trans' | Out-Null
        Resolve-Service -Name 'Trans' | Out-Null
        $global:factoryCount | Should -Be 2
    }

    It "Resolve-Service passes Argument to the factory" {
        Register-Service -Name 'Echo' -Factory { param($x) "got:$x" }
        Resolve-Service -Name 'Echo' -Argument 'abc' | Should -Be 'got:abc'
    }

    It "Resolve-Service throws for unregistered service" {
        { Resolve-Service -Name 'DoesNotExist' } | Should -Throw
    }

    It "Test-ServiceRegistered reflects registration state" {
        Register-Service -Name 'Probe' -Factory { $true }
        Test-ServiceRegistered -Name 'Probe' | Should -BeTrue
        Test-ServiceRegistered -Name 'Missing' | Should -BeFalse
    }

    It "Set-ServiceFactory replaces the factory for transient services" {
        Register-Service -Name 'Swapper' -Factory { 'original' }
        Resolve-Service -Name 'Swapper' | Should -Be 'original'
        Set-ServiceFactory -Name 'Swapper' -Factory { 'replaced' }
        Resolve-Service -Name 'Swapper' | Should -Be 'replaced'
    }

    It "Set-ServiceFactory resets singleton instance" {
        Register-Service -Name 'Svc' -Singleton -Factory { 'original' }
        Resolve-Service -Name 'Svc' | Should -Be 'original'
        Set-ServiceFactory -Name 'Svc' -Singleton -Factory { 'replaced' }
        Resolve-Service -Name 'Svc' | Should -Be 'replaced'
        Resolve-Service -Name 'Svc' | Should -Be 'replaced'
    }

    It "Set-ServiceFactory throws for unregistered service" {
        { Set-ServiceFactory -Name 'DoesNotExist' -Factory { 'x' } } | Should -Throw
    }

    It "Set-ServiceFactory toggles singleton flag" {
        Register-Service -Name 'Togglable' -Factory { Get-Random }
        $a = Resolve-Service -Name 'Togglable'
        $b = Resolve-Service -Name 'Togglable'
        $a | Should -Not -Be $b
        Set-ServiceFactory -Name 'Togglable' -Singleton -Factory { Get-Random }
        $c = Resolve-Service -Name 'Togglable'
        $d = Resolve-Service -Name 'Togglable'
        $c | Should -Be $d
    }
    It "Set-ServiceInstance re-seeds the cached singleton instance" {
        Register-Service -Name 'Seeded' -Singleton -Factory { 'original' }
        Set-ServiceInstance -Name 'Seeded' -Instance 'replaced'
        Resolve-Service -Name 'Seeded' | Should -Be 'replaced'
    }

    It "Set-ServiceInstance throws for unregistered service" {
        { Set-ServiceInstance -Name 'DoesNotExist' -Instance 'x' } | Should -Throw
    }

    It "Set-ServiceInstance is exported (production consumer Orchestrator uses it)" {
        Get-Command Set-ServiceInstance -Module Container -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
