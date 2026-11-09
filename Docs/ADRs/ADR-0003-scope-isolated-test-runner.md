# ADR-0003 — Run state-sensitive test scopes in isolated child processes

Status: Accepted
Date: 2026-11-09

## Context

`_Build`'s test suite grew past the point where every test file could share one
PowerShell session. `_Build` and `_Sync` export the same command names into the
global namespace (`Write-Log`, `Write-SubLog`, `Resolve-SafeColor`, ...), so
whichever module imported last decided what those commands meant. A run of all
`*.Tests.ps1` in one session produced order-dependent failures: a scope that
passed alone failed after another scope had re-imported a module with `-Force`.

Running all tests in one session also let module-global state leak between
scopes: a retry counter in `PipelineEngine` survived into the next file, and an
`AnomalyDetector` sample-history path from a previous scope made a later scope
report `InsufficientData` instead of `Healthy`.

## Decision

`Tests/Run-CoreTests.ps1` runs a fast in-process core batch for module-isolated
scopes and spawns **every state-sensitive scope in its own child process**
(`pwsh -File Run-CoreTests.ps1 -Scope <Name>`). The parent parses each child's
canonical `GBUILD_CORE_VERDICT` line and treats a killed child as an infra
failure, never as a passing scope.

The runner also self-heals: it keeps an in-memory copy of its own script and
restores it if endpoint protection removes it mid-suite.

## Consequences

- A scope's failure is always attributable to that scope, not to a previous one.
- A crash or quarantine in one scope cannot abort the whole suite.
- The suite is slower than a single-session run, and that is accepted.
- `_Tests/gtest.ps1 -Project .` must **not** be used against `_Build`: the
  harness's PowerShell runner is single-session. See `AGENTS.md` §6.

## Evidence

- `Tests/Run-CoreTests.ps1` (scope map, child-process spawn, verdict parsing,
  self-heal)
- `_Tests/run-suite.ps1` (the same per-tool isolation principle, documented)
