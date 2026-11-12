# AGENTS.md — instructions for humans and AI assistants

Before you change **any** file in this repository, read this file. It is the
contract that keeps a 75k-line, 7-locale, 3-OS build platform stable while it is
being changed. This repo is a **tool**, not an application: a defect here breaks
every project built with it, so the rules below are stricter than they look.

## 1. Scope discipline

- Fix **only** the thing you were asked to fix. No drive-by rewrites, no
  "while I was here" refactors, no reformatting untouched code.
- If a fix requires touching a file that is not related to the request, stop and
  say so — do not decide on your own.
- Never mix reverting work with fixing work in one change.
- Never weaken a gate, a baseline, a floor, or a test to make a run green. If a
  gate is provably wrong: revert, analyse, change **this file first**, then
  adjust the gate with a note explaining why the gate was wrong.

## 2. The mandatory loop (do not skip)

Every change goes through this loop, in order:

1. **Analyse** — read the code paths involved, the failing log/repro, and the
   invariants in §4. Do not start editing from memory. This codebase is heavily
   self-documenting: read the comment above the function you are about to change.
   It usually records the exact incident that shaped the current shape.
2. **Baseline** — run the gates on the untouched tree and write down which checks
   fail **before** your change:
   ```powershell
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SelfTest
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SyntaxCheck
   ```
3. **Design** — smallest safe change. Identify the single owner of the concept
   you are touching (§4) and change that owner, not a copy.
4. **Implement — and fix until green.** If a test fails after your change, you do
   not "accept it for now". Read the failure, then fix the code or back the
   change out and use a different approach.
5. **Verify** — run the scopes that cover your change, then the full suite:
   ```powershell
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope <YourScope>
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-E2ETests.ps1' -Scope All
   ```
   `-Scope` accepts **one** scope or `All`. For several scopes set
   `$env:GBUILD_SS_LIST = 'ScopeA,ScopeB'` and omit `-Scope`.
6. **Docs** — if you added, renamed, or deleted a function in `Modules/`, the
   generated docs MUST be refreshed in the same change:
   ```powershell
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Import-Module './Modules/Documentation.psm1' -Force; Show-GBuildHelp -Modules"
   ```
   `Tests/Documentation.Tests.ps1` fails if `Docs/api-reference.md` or
   `Docs/API/*.md` drift from the module inventory. If the change reverses an
   architectural decision, update `Docs/ADRs/` in the same change (new ADR or
   `Superseded by`, never an in-place edit of a decision).
7. **Baseline** — `Tests/process-baseline.json` holds MEASURED numbers. When the
   process changes (a new scope, a new gate, an accepted skip), update the
   measured values and the `generatedAtUtc`. Never edit a floor
   (`adoptionFloor.*.minAdoption`, `coverage.floorPercent`,
   `core.skippedMaxAllowed`) upward to make a red run green — raising a floor is
   the ratchet and it goes down as the backlog shrinks, never up to pass.
8. **Build/Sync** — `_Tests` → `_Build` → `_Sync`, in that order:
   ```powershell
   _Tests/gtest.ps1  -SelfTest                 # harness gates (parse, config, imports, hygiene, validation, suite)
   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips
   _Sync/gsync.ps1   -Project . -Yes -NonInteractive
   ```
   Do not run `_Tests -Project .` against `_Build` itself — see §6.

You are not finished when the code looks right. You are finished when the loop is
green.

## 3. Why the loop exists

Real escaped defects from this repo, both found after a "green" commit:

- `Standalone.psm1` — a cleanup deleted `Get-StandaloneHash` from the emitted
  bundle template as a "duplicate" of the module-scope function. The template is
  an artifact boundary and cannot call module-private functions, so every emitted
  standalone bundle died at startup with *"Get-StandaloneHash is not recognized"*.
- `publish-artifact.ps1` — a containment check compared raw paths, so a macOS
  `/var/folders/...` fixture was rejected as outside the permitted roots and the
  artifact step failed on every macOS run.
- `PathUtils.Test-NoReparsePointInPath` — a macOS CI run failed 12 tests across
  Steps / CacheProvider / Deploy / Distributed / Sast with "Archive path escaped
  output directory". Every temp path goes through `/var` → `/private/var`, and
  `Resolve-Path` does not resolve that alias, so the chain walk rejected every
  temp path on the platform. Windows and Linux were green, which is exactly why
  a local run could not see it.

All of these were invisible to a single "it works on my machine" pass. They are
now pinned by tests and by `-SelfTest` gates — and the macOS ones by a test that
runs on the platform that exposed them.

## 4. Invariants — breaking these is a regression, not a feature

### 4.1 Single source of truth

- **Defaults** live in `Modules/BuildConstants.psm1`. Never inline a default that
  already exists there; call `Get-BuildConstant` / `Get-BuildDefault`.
- **Config** lives in `gbuild.config.json` (shipped) and the project-local
  override. Read it through `Modules/ConfigProvider.psm1`
  (`Get-SectionValue` / `Get-ConfigValue`). Every config key must be consumed by
  code; a key nothing reads is a finding (see `Level5.Parity.Tests.ps1`).
- **Paths** live in `Modules/PathUtils.psm1`. Never build a repository path with
  a `\` literal; use `Join-Path` / `Split-Path` / `Resolve-Path`.
- **Redaction** lives in `Modules/SharedUtils.psm1`
  (`Protect-BuildSecretText` / `Invoke-BuildSecretProtect`). `Logging.psm1`
  keeps a lazy shim because of a circular import — do not add a third copy.
- **Tier-1 module list** lives in `Modules/Tier1Modules.ps1`. Never inline the
  list in a second consumer.
- **Locale messages** live in `Locales/*.json` (7 locales, 1226 keys, byte-parity
  enforced). Every user-facing emit goes through `Get-LocaleMessage` /
  `Resolve-LogMessage` with a `-Fallback`. Hardcoded English prose is a finding.
- **Comments are in English**, always — every comment, every doc comment, every
  commit message, every test name. This repo is maintained across locales and
  by AI agents; a Vietnamese-only comment is unreadable to most of them. Log
  *messages* are localized (see above), but the code that emits them is not.

### 4.2 Hardcoding

- No absolute machine paths, no `C:\Users\...`, no `/home/runner/...`, no
  hardcoded sibling-directory names (`'_Build'`, `'_Sync'`, `'_Tests'`) in
  product code. The tool must run from any directory, on a USB, on CI.
- OS-specific commands (`robocopy`, `xcopy`, `del /s`, `rd /s`, `cmd.exe`) do not
  belong in PowerShell logic. Detect `pwsh` vs `powershell` from `PATH`.
- Cross-platform path edge cases that have already bitten this repo — do not
  reintroduce them:
  - macOS: `/var` is a symlink to `/private/var`; Pester `$TestDrive` is under
    `/private/tmp`; the per-user TMPDIR is `/var/folders/<hash>/T/`. Containment
    checks must accept all of these.
  - **A reparse-point walk must STOP at an OS alias, never reject it.**
    `Resolve-Path` does NOT resolve symlinks (proven on a Windows junction and
    on the macOS CI runner), so a chain walk that flags every `ReparsePoint`
    rejects EVERY temp path on macOS (`/var`, `/tmp`). The single owner,
    `PathUtils.Test-NoReparsePointInPath`, stops at `/var`, `/tmp`,
    `/private/var` and `/private/tmp` on POSIX. Do not "simplify" that away,
    and do not add a new reparse walk without the same stop. A user-planted
    symlink BELOW the boundary must still be rejected.
  - Windows PowerShell 5.1 has no `$IsWindows` / `$IsLinux` / `$IsMacOS`.
    Import `Tests/Helpers/PlatformShim.ps1` in tests that branch on them.
  - `-Encoding UTF8` on every file read/write.
  - Generated file content must be platform-independent: never embed a
    raw filesystem path separator (`\` vs `/`) in generated text. The
    docs generator used to write `Modules/Plugins\Foo.psm1` on Windows and
    `Modules/Plugins/Foo.psm1` on POSIX, which made the committed-docs sync
    gate fail on Linux. Normalize separators before writing. Pinned by
    `Documentation.Tests.ps1` 'generated paths are platform-independent'.
  - `String.TrimEnd` (and any `params char[]` method) must be called with
    SINGLE-CHARACTER string arguments only. A multi-character string such
    as `'\'` (two backslashes) cannot be coerced to `System.Char` and
    throws at runtime; inside a `try { ... } catch { return $false }`
    that throw is swallowed and turns a valid path into a rejection
    (this is how the macOS `/var` alias branch failed). Use one
    backslash (`'\'`) or a `[char]` literal. Pinned by
    `PathUtils.Tests.ps1` 'TrimEnd coercion guard'.

### 4.3 Module architecture

- Split a module only when it contains **2+ distinct sub-domains with minimal
  cross-calls**, and then follow the existing pattern: a subdirectory named after
  the module, sub-files named `<Module>.<SubDomain>.ps1`, dot-sourced from the
  main `.psm1` (see `Modules/Orchestrator/`). Do **not** split cohesive
  single-domain modules (`SharedUtils`, `SDK`, `Build`, `ProcessMetrics`,
  `BuildConstants`) — high internal call density makes them one unit regardless
  of LOC.
- Approved cross-module duplication is **governed**, not accidental.
  `AnomalyDetector.psm1` and `RootCause.psm1` each carry a byte-identical
  preamble; `ModuleHygiene.Tests.ps1` pins them. Do not "fix" one copy.
- Nested `Import-Module <shared> -Force` without `-Global` orphans global
  commands on PS 5.1. Variable-target imports must be registered in the
  allowlist in `Tests/ModuleHygiene.Tests.ps1`.

### 4.4 Test architecture

- Scopes run in `Tests/Run-CoreTests.ps1`; the map is `$scopeMap`. A new test
  file needs a scope entry, or it never runs.
- State-sensitive scopes run in isolated child processes. A skip flag must be
  computed at **script scope** (before any `Describe`) so `-Skip` can bind
  during discovery. `Set-TestSkip` does not exist in Pester 5.9.0.
- Tests that need a sibling tool or an external project must **skip with a clear
  message** when it is absent — never hard-fail.
- `return ,@($collection.ToArray())` is not empty-safe: an empty collection
  becomes a one-element array. Use
  `$r = @($collection.ToArray()); if ($r.Count -eq 0) { return @() }; return ,$r`.
- `Write-SubLog` must be called with named parameters (`-Label`, `-Value`,
  `-Color`); positional binding throws.

### 4.5 Git and shipping

- The pre-push hook blocks a push that touches `Modules/` unless every commit in
  the range carries a `Reviewed-by: <name>` trailer, or the push is invoked with
  `GBUILD_REVIEW_APPROVED=<name>`, or an explicit waiver is recorded with
  `GBUILD_REVIEW_OVERRIDE=<reason>`. A waiver is never an approval.
- After `git add` / `commit` / `push` on Windows, verify with `git status` and
  `git log --oneline -3` against the remote. OneDrive/FSMonitor can lock
  `.git/index`; a clean local status is not proof the push landed.

## 5. Codebase quality audit (when assessing or improving the platform)

Assess the **actual codebase**, never markdown claims. Review file-by-file and
flow-by-flow:

- **Hardcode** — hardcoded values/paths/URLs/behavior. Replace with config, env,
  or shared constants only when safe and dynamic; preserve hardcodes that cannot
  be made dynamic (platform/runtime constraints, required literals, intentional
  fixed behavior) and document why.
- **Orphans** — unused exports, dead files/modules, unreachable branches, stale
  assets. Judge whether each has a valid current/future use in the active
  architecture; remove only when inappropriate (truly dead/misleading). Do not
  delete code that is intentionally extensible or required by a build/runtime
  contract. Internal helpers exported for testability are not orphans.
- **Duplication & reuse** — repeated logic, copy-pasted flows, parallel
  implementations. Consolidate through shared helpers only when behaviour stays
  identical and tests cover the path. Prefer reuse, but avoid risky
  abstractions that couple unrelated concerns. Intentional, governed
  duplication is allowed when a test pins it.
- **Independence & portability** — flows must run independently where designed,
  avoid hidden machine-specific assumptions, and work across Windows / Linux /
  macOS / WSL. Flag Windows-only paths/commands/shell assumptions when
  cross-platform support is claimed.
- **Multilingual / i18n** — locale handling, fallbacks, translated content paths,
  and no flow that hard-wires a single language. All 7 locale catalogs must stay
  at key parity.
- **Maturity lens (industrial)** — when requested, evaluate against **CMMI Level
  5 Optimizing / enterprise platform maturity** grounded in evidence from the
  codebase: repeatable gates, measurable quality/security, defect prevention,
  controlled change/rollback, automation, observability, traceability, governance,
  and continuous improvement. Report the current level candidly with gaps and
  prioritized remediation.

Quality fixes must follow §2: baseline, smallest safe change, fix-until-green, no
regressions.

## 6. The gates

```powershell
# Self-test (10 gates: parse, config, imports, event-contract, commands,
# dependencies, process-metrics, process-control, qpm, psscriptanalyzer)
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SelfTest

# Parse every shipped file (no execution)
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SyntaxCheck

# Full unit/state suite (isolated scopes). Expect: 0 failed.
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips

# End-to-end suite (Distributed, CacheProvider, Metrics, Enterprise, BuildE2E)
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-E2ETests.ps1' -Scope All

# POSIX launcher + smoke suite on Linux/macOS/WSL
./gbuild -SelfTest

# External harnesses
_Tests/gtest.ps1  -SelfTest                 # harness gates (parse, config, imports, hygiene, validation, suite)
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips
_Sync/gsync.ps1   -Project . -Yes -NonInteractive
```

The CI `coverage` job runs on BOTH push and pull_request and uses the
scope-isolated runner with the ratchet:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips -Coverage -MinCoveragePct 55
```

Do NOT replace that with a raw `Invoke-Pester` over `Tests/`: a single-session
run leaks module-global state between state-sensitive scopes and produces ~16
false failures (see section 6). The ratchet (55%) is a measured floor, not an
aspiration - raise it as coverage grows, never lower it to go green.

`-Coverage` implies the **full parallel** path: every scope is scheduled as its own
isolated child through a bounded pool (`-ParallelScopes N`, default
`min(ProcessorCount, 16)`, override with `GBUILD_SCOPE_PARALLELISM`). Pester
coverage is breakpoint-based and ~10x slower, so the sequential 112-scope run
took ~2 h and could never fit a CI budget. Each child is still a separate
process, so the state-isolation guarantee above is unchanged - do not
"optimise" this back into one session.

The coverage queue is ordered **longest-processing-time-first (LPT)** using the
measured per-scope costs in `Tests/TestResults/scope-timings.csv`, so the long
poles (e.g. the `Hygiene` gate family) start immediately and the wall clock
tracks the longest scope instead of the unluckiest tail. Sharded CI runs balance
shards by the same cost table and restore it from the prior `test` artifact
when available.

A shard's wall clock is its slice of the measured scope work divided by the
parallelism **inside** the shard, with the longest single scope as a floor that
no shard count can lift. Measured 2026-11-12: 15,618 s of scope work over 121
scopes under coverage instrumentation - and the instrumentation is roughly a
ten-fold multiplier that is NOT the same for every scope (the measurement
engine scans the whole tree and pays the breakpoint tax on every line of it,
while a scope that touches three modules pays it on three modules' worth), so
the plain timing table is the wrong input for a coverage run. The coverage
matrix therefore runs **12 shards**, balances them on
`Tests/coverage-costs.json` (the MEASURED coverage cost of every scope,
committed for the same reason the other baselines are: a fresh CI checkout has
no history to learn from), and the measurement engine was split into four
scopes (`ProcessMetricsEngine`, `ProcessMetricsTrend`, `ProcessMetricsRatchet`,
`ProcessMetricsControl`) so its pole could be spread. A scope that is too slow
to schedule is a scope that should be SPLIT - splitting a scope keeps the
isolation guarantee (each part still runs in its own child) and changes nothing
about what is measured.

**A shard never applies the global coverage floor.** A shard measures a slice,
so its percentage is a PARTIAL measurement and is published as
`coverage-shard-<n>-of-<m>.json`; the floor is enforced by the merge job,
which holds every shard's reports.

Child coverage XMLs are named `coverage-<pid>-<tag>.xml`; sharded runs pass
`-CoverageTag <shard>-<scope>` so reports from different machines cannot collide
on a reused PID. `-MergeOnly -Coverage` merges the XMLs already present and
enforces the line-coverage floor from `Tests/process-baseline.json`; it does not
execute Pester and does not require Pester to be installed.

Without `-Coverage` the runner uses the **hybrid** path: the state-sensitive
scopes still get their own child process, but the children run CONCURRENTLY
through the same bounded pool, and the fast in-process core batch runs in the
parent *while* they work. The process topology is identical to the sequential
run - only the timing changed - so the isolation guarantee is untouched. It is
opt-in: `-ParallelScopes N` or `GBUILD_SCOPE_PARALLELISM=N` (the CI `test` job
sets it to the runner's core count). A plain local run stays sequential: a
developer wants fast feedback and a quiet machine, not four children.

The suite writes `Tests/TestResults/scope-timings.csv` (scope, seconds, status,
counts, slowest first) and prints the ten slowest scopes at the end. It is a
DIAGNOSTIC, not a gate: nothing fails because of it. Use it before guessing
where the suite's time goes - the answer is usually three scopes, not fifty.

The merged percentage is a UNION over scopes, not a sum: a line covered in any
scope counts once. Per file, `covered = max over scopes` and
`total = max over scopes of (covered+missed)`; `missed` is derived as
`total - covered`. Deriving it any other way mixes one run's covered lines with
another run's missed lines and inflates the denominator (SDK.psm1 once reported
375+995 for a 995-line file, deflating the very percentage the ratchet
enforces). The merge also ignores `coverage-*.xml` files that already existed
before the run (PIDs are reused, so a stale file would otherwise be counted as
covered today).

`-SelfTest` must exit 0 before any project test run. A self-test that collects
failures but falls through to project tests is a defect: the self-test branch
must `exit` with its own verdict.

**Do not run `_Tests/gtest.ps1 -Project .` against `_Build` itself.** The
harness's PowerShell runner executes every `*.Tests.ps1` in ONE Pester session,
but `_Build`'s suite is scope-isolated on purpose: state-sensitive scopes
(`AnomalyDetector`, `Pipeline.E2E`, `PipelineEngine`, `Standalone`, ...) leak
module-global state into each other when they share a session. The result is a
false red (~16 failures: `Write-Log` orphaning, `InsufficientData` where
`Healthy` is expected, retry state surviving across files). The authoritative
path for `_Build` is `Tests/Run-CoreTests.ps1`, which spawns each state-sensitive
scope in its own child process. `_Tests -Project` is correct for flat
PowerShell projects; `_Build` is not one.

## 7. Rollback protocol

- `git revert <sha>`, never `git reset --hard` on a shared branch.
- If two consecutive rollbacks happen for the same task, stop. The approach is
  wrong — write down why and pick a different one.
- Never ship "temporary" fixes with the intent of fixing them later; fix the
  root cause now.

## 8. Definition of done

- All gates green on the changed tree, including the full suite and the docs
  sync gate.
- No new TODO without a tracking reference.
- No hardcoded project name or assumed path anywhere in the change.
- A human-readable commit message explaining *why*, not only *what*.
