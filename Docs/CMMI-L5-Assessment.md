# CMMI L5 / Enterprise Platform Maturity Assessment — `_Build`

Assessment date: 2026-11-09
Scope: the `_Build` codebase itself (75,594 LOC across `Modules/` + `Tests/`,
220 PowerShell files, 7 locale catalogs). Evidence is taken from the code, not
from README claims. Every score below names the file that proves it.

## Verdict

**Level 4 (Quantitatively Managed), with several Level 5 (Optimizing)
mechanisms already operating.** The platform measures itself, controls its
process with statistical limits, and has a working continuous-improvement loop.
What keeps it short of a full L5 rating is not the absence of optimising
practices but the absence of an *organization-wide* process asset set and a
closed causal-analysis loop tied to every defect. For a single-maintainer
single-repo platform that is the expected ceiling.

| CMMI area | Level | Evidence |
|---|---|---|
| Process definition & standards | **L3** | `AGENTS.md` (this repo's contract), `Modules/BuildConstants.psm1`, `Modules/Tier1Modules.ps1`, `.gitattributes`, `.github/CODEOWNERS` |
| Quantitative management | **L4/L5** | `Modules/ProcessMetrics.psm1` (7 adoption classes, control limits), `Tests/process-baseline.json` (measured baseline + floors), `build-reports/metrics-baseline.json` |
| Defect prevention | **L5** | `Tests/GateDetectors.ps1`, `Tests/GateSelfTest.Tests.ps1`, `Tests/ModuleHygiene.Tests.ps1`, pre-commit/pre-push hooks, `Tests/qpm-ledger.json` |
| Causal analysis | **L4** | `Modules/RootCause.psm1` (CAR ledger, classifier table), `Modules/AnomalyDetector.psm1` |
| Continuous improvement | **L5** | `Modules/AutoTuner.psm1` (proposal + pilot gate), `Find-RatchetCandidates`, `Tests/ProcessMetrics.Mutation.Tests.ps1` |
| Verification & validation | **L4** | 1,566 tests, 19 hygiene gates, coverage floor, `Tests/Run-CoreTests.ps1` scope isolation |
| Configuration management | **L4** | `gbuild.config.json` + schema, config-key parity gate, `Modules/ConfigProvider.psm1` |
| Portability / cross-platform | **L5** | `Modules/PathUtils.psm1`, POSIX launcher, Docker multi-arch, CI matrix (ubuntu/macos/windows/arm64) |
| Code reuse / DRY | **L5** | 7/7 adoption classes at 100 %, governed duplication pinned by tests |
| Standalone operation | **L5** | `Modules/Standalone.psm1`, `Install-GBuild.ps1`, `-Project` injection |
| Multilingual / i18n | **L5** | 7 locales × 1,226 keys at parity, `localeKeyWiring` 100 %, `i18nProseCoverage` 100 % |
| Observability | **L4/L5** | `Modules/Logging.psm1`, `Modules/Metrics.psm1` (Prometheus/OTLP), `Modules/AuditLedger.psm1`, `Modules/SupplyChain.psm1` (SLSA), `Modules/Report.psm1` (SARIF) |
| Governance / security | **L4** | `Modules/Security.psm1`, `Modules/RBAC.psm1`, `Modules/Policy.psm1`, `Modules/CredentialVault.psm1`, pre-push review gate |

## What is genuinely L5 here

1. **The process measures itself and the measurement is mutation-tested.**
   `Modules/ProcessMetrics.psm1` computes 7 adoption ratios over the production
   tree. `Tests/ProcessMetrics.Mutation.Tests.ps1` plants a violation and proves
   the metric still fires — a ratchet that cannot fail is worse than no ratchet,
   and this repo has been bitten by exactly that (the baseline file records three
   separate false-green metric revisions).
2. **Escaped defects are a first-class artefact.** `Tests/qpm-ledger.json` is an
   append-only ledger of defects that reached a green state; `gbuild.ps1
   -SelfTest` gates on ledger *validity* and the change-failure rate window, and
   the ledger records the prevention for each escape.
3. **Improvement is automatic but not autonomous.** `Modules/AutoTuner.psm1`
   proposes tuning changes and requires an explicit pilot approval before
   apply (`Test-AutoTunePilotApproved`). `Find-RatchetCandidates` raises a floor
   only after a sustained improvement, so a single good run cannot loosen a
   gate.
4. **Gates are treated as code.** `Tests/GateSelfTest.Tests.ps1` runs the gate
   detectors against planted fixtures and fails when a detector goes blind.
   `Tests/ModuleHygiene.Tests.ps1` pins the two approved cross-module
   duplicates byte-identical and registers every variable-target import.

## What is missing for a full L5 rating

1. **No organisation-wide process asset set.** The standards live in one repo's
   `AGENTS.md` and its own modules. There is no published process reference that
   other projects inherit; each project re-derives its own discipline.
2. **Causal analysis is not closed-loop.** `RootCause.psm1` can classify and
   record a defect, and `qpm-ledger.json` records escapes, but nothing
   *automatically* opens a CAR record from a failed gate. The link is manual.
3. **No defect-rate / escape-rate target tied to business objectives.** The QPM
   gate enforces a change-failure rate window, but there is no SLO for escape
   rate, MTTR target, or adoption target derived from a platform objective.
4. **Coverage is measured on two different metrics that are not reconciled.**
   `Tests/process-baseline.json` records a 15 % line-coverage floor and a 55 %
   command-coverage gate; the file itself warns they must never be compared.
   That is honest, but it is also a sign that the coverage process is not yet
   unified.
5. **No ADR / decision record set.** `README.md` advertises "ADRs and API
   docs", but `Docs/` contains only generated API pages. Key decisions (module
   split pattern, governed duplication, scope-isolated test runner) are
   documented in code comments and test names, not in reviewable decision
   records.

## Findings from the audit (and their resolution)

| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | `Docs/api-reference.md` + `Docs/API/*.md` were 70 functions / 2 pages behind the modules (deleted `Alerting.Invoke-BuildSecretProtect` still documented; new `Alerting.Get-AlertRotationHours` missing) | High | Regenerated via `Show-GBuildHelp -Modules`; added a sync gate in `Tests/Documentation.Tests.ps1` |
| 2 | No `AGENTS.md` — no agent-readable contract for the 75k-line platform | High | Created `AGENTS.md` (scope discipline, mandatory loop, invariants, gates, rollback, DoD) |
| 3 | `Tests/process-baseline.json` recorded 94 scopes / 1,123 tests while the suite is 112 scopes / 1,566 tests | Medium | Updated to the measured values; the description no longer claims a per-run counterpart that nothing generates |
| 4 | Vietnamese comments | — | None found (one em-dash false positive) |
| 5 | 4 duplicate function names across files | Low | All four are documented and pinned: `Get-StandaloneHash` (module + emitted bundle template), `Get-DiagnosticRoot`/`Resolve-DiagnosticPath` (governed AnomalyDetector/RootCause preamble), `Invoke-BuildSecretProtect` (Logging lazy shim → SharedUtils) |
| 6 | 3 files flagged for backslash path literals by the `_Tests` metric | Low | All false positives: a regex pattern in `BuildConstants.psm1`, a separator-normalisation in `Cache.psm1`, and comments in `ModuleDependencies.psm1`. `_Build`'s own metric (token-based, with pattern-scoped exemptions) reports 218/218 |
| 7 | `Set-StrictMode` absent from 3 production files | — | Intentional: `ModuleBootstrap.ps1`, `OrchestratorLifecycle.ps1`, `Orchestrator.Pipeline.Events.ps1` are dot-sourced and inherit it from the caller |
| 8 | `README.md` claims `Docs/` holds ADRs | Low | Open — see recommendation 5 |
| 9 | `_Tests/gtest.ps1 -Project .` on `_Build` reports ~16 false failures | Medium | Documented in `AGENTS.md`; the harness's PowerShell runner is not scope-isolated. Authoritative path is `Tests/Run-CoreTests.ps1` |
| 10 | macOS CI failed 12 tests (Steps / CacheProvider / Deploy / Distributed / Sast) with "Archive path escaped output directory" while Windows + Linux were green | High | `PathUtils.Test-NoReparsePointInPath` now stops at the `/var`, `/tmp`, `/private/var`, `/private/tmp` OS aliases instead of rejecting every temp path; regression test added to `Tests/PathUtils.Tests.ps1` |

## Prioritised remediation

1. **Add an ADR set** under `Docs/ADRs/` and make `README.md` true. Record at
   minimum: the module-split pattern, the governed-duplication decision, the
   scope-isolated test runner, and the committed-generated-docs decision. This
   is the cheapest remaining L5 gap to close. **Done 2026-11-09** — five ADRs
   and an index now live under `Docs/ADRs/`.
2. **Close the causal loop.** When a gate fails in CI, open (or require) a CAR
   record in `Tests/qpm-ledger.json` referencing the failing scope. The
   primitives already exist; only the wiring is missing.
3. **Publish the process.** Extract the discipline in `AGENTS.md` into a
   standalone process reference that other repos can inherit, so the platform
   is not a single point of process failure.
4. **Unify coverage.** Pick one coverage metric (command coverage is the one
   the CI gate uses) and record only that in `Tests/process-baseline.json`, or
   record both with an explicit reconciliation rule.
5. **Fix the `_Tests` PowerShell runner** to detect a project-specific runner
   (`Tests/Run-CoreTests.ps1`, `Run-Tests.ps1`) instead of running every
   `*.Tests.ps1` in one session. Out of `_Build` scope, but it is the reason
   finding 9 exists.

## 2026-11-12 update (measured)

- **Coverage (merged line, JaCoCo union):** raised from **53.77% (13,134 / 24,424)** baseline to **56.08% (13,696 / 24,424)** by adding targeted hermetic tests (SDK discovery waterfall; Build helpers `Get-CacheArtifactPatterns`/`Get-BuildPluginCacheKey`/`New-BuildResult`/`Invoke-BuildOutputReveal`/`Invoke-AndroidArtifactDeploy`; SharedUtils env/mode/CI/report/arg/syntax helpers; Orchestrator SDK/service helpers; HotReload plugin delegation). `Tests/process-baseline.json` `coverage.floorPercent` ratcheted **15 → 55** (raise only).
- **Coverage speed (parallel, state-isolated):** auto coverage degree raised to `min(ProcessorCount, 16)` with **LPT (longest-processing-time-first)** scheduling from the measured per-scope cost table (`Tests/TestResults/scope-timings.csv`), so the long pole (`ProcessMetrics` ~978s) starts first. Measured baseline wall **1,557.3s** at degree 16 (sum 14,168.5s); sharded CI balances by the same cost table and restores it from the prior `test` artifact.
- **Runner/CI workflow:** per-child coverage XMLs tagged `<shard>-<scope>` to avoid cross-shard PID collisions; `-MergeOnly -Coverage` merges existing JaCoCo XMLs and enforces the line floor without requiring Pester. `.github/workflows/build.yml` coverage shards use runner auto degree/LPT and restore the measured cost table for balanced sharding.
- **Still open:** full-coverage wall-clock under LPT remains bounded by the `ProcessMetrics` pole (~16 min of scope work); further speedup requires splitting/optimizing that scope’s covered work, not weakening isolation. Remaining high-miss areas include Build `Invoke-AutoDeploy`/`Invoke-DeviceDebug`/AAB/signing flows, HotReload watch loop, and Orchestrator event/pipeline registration paths.
