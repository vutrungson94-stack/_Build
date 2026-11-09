# ADR-0002 — Some duplication is intentional and pinned by a test

Status: Accepted
Date: 2026-11-09

## Context

The platform's stated rule is "no duplicated code". In practice, three
duplications exist and removing them would be wrong:

1. `Modules/AnomalyDetector.psm1` and `Modules/RootCause.psm1` each carry a
   byte-identical root/path preamble. Both modules load through `-Global`
   imports where a shared preamble module hits module-scope issues on
   Windows PowerShell 5.1.
2. `Modules/Standalone.psm1` defines `Get-StandaloneHash` twice: once in the
   live module and once inside the emitted-bundle template. The bundle is a
   self-contained artifact and cannot call module-private functions. A cleanup
   that deleted the template copy shipped a broken bundle to every user.
3. `Modules/Logging.psm1` keeps a lazy `Invoke-BuildSecretProtect` shim.
   `SharedUtils -> ModuleBootstrap -> Logging` is a circular module-scope
   dependency, so `Logging` cannot import `SharedUtils` at module scope.

## Decision

Duplication that is forced by an artifact boundary or a module-scope cycle is
allowed, but it must be **governed**: a test pins the copies together and the
rationale is written next to the copy. Duplication that is merely convenient is
not allowed.

The governance mechanisms are:

- `Tests/ModuleHygiene.Tests.ps1` pins the `AnomalyDetector` / `RootCause`
  preamble byte-identical and requires both files to state the rationale.
- The `Standalone` template copy is kept byte-identical to the live copy and
  pinned by the in-file comment contract.
- `Logging`'s shim delegates to `SharedUtils.Protect-BuildSecretText` on every
  call, so the behaviour cannot drift.

## Consequences

- A "remove looks-duplicated code" change to any of these three is a defect,
  not a cleanup. This is the exact shape of the 2026-11-03 escaped defect.
- A new duplication must either be removed or registered in
  `Tests/ModuleHygiene.Tests.ps1` with a stated reason.
- The governed-duplication list is a ratchet: it can shrink, but a new entry
  needs a test and a comment, not just a commit message.

## Evidence

- `Tests/ModuleHygiene.Tests.ps1` (intentional cross-module duplication gate)
- `Modules/Standalone.psm1` (in-file comment contract for the template copy)
- `Tests/qpm-ledger.json` entry QPM-2026-001 (the escaped defect this prevents)
