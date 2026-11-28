# Appraisal traceability — `_Build` (2026-11-28)

Self-assembled evidence index for a future appraiser. **Not a SCAMPI result,
not a certificate.** Verdict remains **Level 4 (Quantitatively Managed) with
L5-local defect-prevention/ratchet mechanisms** — see
`Docs/CMMI-L5-Assessment.md` and `Docs/Appraisal-Dossier.md`.

No final commit hash is written here: use `git log`. CI run numbers are
historical evidence, not a promise about future runs.

## Measured snapshot (current)

| Item | Value | Artifact |
|---|---|---|
| Core suite | 1,770 passed / 0 failed / 8 skipped / 1,778 total; 127 scopes, state-sensitive scopes isolated in child processes | `Tests/process-baseline.json`, `Tests/Run-CoreTests.ps1` |
| SelfTest | 11/11 gates: parse (103 files), config/schema, imports (25 modules), event-contract, commands, dependencies (77 modules, no cycles), process-metrics, process-control, qpm, slo, PSScriptAnalyzer | `gbuild.ps1 -SelfTest` |
| Adoption | 7/7 classes at 100%; 488 trend samples; 0 regressions | `Modules/ProcessMetrics.psm1`, trend JSONL |
| Coverage | merged LINE 57.81% (13,691 / 24,464), floor 57 (raise-only); 9 hygiene gates recounted by the gate itself | `Tests/process-baseline.json`, `Tests/Hygiene.Tests.ps1` |
| Ledgers | `Tests/qpm-ledger.json` (2 escaped defects, 0 new in 7-day window), `Tests/flake-ledger.json` (2 fixed), `Tests/car-ledger.json` (automatic CAR from failed scope) | `Tests/` |
| CI | run #135 success, 24/24 job instances from the 10-job workflow (matrix shards included); no job softened | `.github/workflows/build.yml`, Actions |
| i18n | 7 locales × 1,263 keys, byte parity | `Locales/*.json`, `Locale` scope |
| Supply chain | CycloneDX SBOM, SLSA-style provenance, artifact signing config | `Modules/SupplyChain.psm1`, `security.*` config |
| Plugin provenance | RSA-SHA256 `.sig` sidecars verified by `PluginSDK`; `requireSignature` fails closed; external plugin roots no longer load unverified code when the policy is on | `Modules/PluginSDK.psm1`, `Modules/Loader.psm1`, `Tests/PluginSDK.Tests.ps1` |

## Practice → evidence matrix (illustrative MG v2.0 mapping)

| Practice | Evidence in code/artifacts | Status |
|---|---|---|
| PAAN02 — Establish a process | `AGENTS.md` (contract with mandatory loop and invariants), `Docs/Process/verification-process.md` (published portable process), `Docs/Process/README.md` | done (repo-local, portable reference published) |
| PAAN03 — Define requirements | `gbuild.config.json` + schema (35 sections); config-key parity gate; `Modules/ConfigProvider.psm1` | done |
| PAAN05 — Process plan | `.github/workflows/build.yml` 10 jobs / 24 instances: syntax, test shards, gbuild-flow, ps51-smoke, portability, macOS, container, arm64, coverage shards + merge | done |
| QIA01 — Collect data | `Modules/ProcessMetrics.psm1`, `Modules/Metrics.psm1` (Prometheus/OTLP), `Modules/AuditLedger.psm1`, `Modules/Report.psm1` (SARIF) | done |
| QIA02 — Quality baselines | `Tests/process-baseline.json`, `Tests/ci-run-history.json`, `Tests/TestResults/coverage-baseline.json` | done |
| QIA03 — Establish baselines | `Modules/ProcessMetrics.psm1`, `Tests/ProcessMetrics.Mutation.Tests.ps1`, coverage union merge guard | done |
| QIA04 — Analyze performance | `Docs/CMMI-L5-Assessment.md`, `Docs/Process/2026-11-13-independent-audit.md`, control limits in ProcessMetrics | done |
| QIA05 — Establish control | `gbuild.ps1 -SelfTest`, `Tests/GateSelfTest.Tests.ps1`, `Tests/GateDetectors.ps1`, `Tests/FlakeLedger.Tests.ps1` | done |
| QIA06 — Monitor in statistical control | SPC window + QPM/SLO gates exist; escape/MTTR targets derived from repo-local objectives; no production business objective feed | **partial** |
| CAR03 — Causal analysis | `Modules/RootCause.psm1`; `Tests/Run-CoreTests.ps1` opens a CAR automatically on a failed scope; `Tests/car-ledger.json` | done (repo-local) |
| SPS — Supply-chain baseline | `Modules/SupplyChain.psm1`, SBOM policy gate, plugin signature gate, `security.*` config | done |
| IMP — Improvement | Ratchets (coverage 15→55→57, adoption floors at 1.0), `Modules/AutoTuner.psm1` with pilot approval, `Find-RatchetCandidates` | done (repo-local) |
| IMP L5 — Cross-project evidence | No consumer project has ratified this repo's baseline; `_Sync` adoption was audited as partial | **missing** |

## Governance notes

- The independent audit in `Docs/Process/2026-11-13-independent-audit.md` was
  self-commissioned and found real documentation inflation; most findings were
  remediated. It is evidence of honesty, **not** an external appraisal.
- Pushes touching `Modules/` require a real `Reviewed-by` trailer or
  `GBUILD_REVIEW_APPROVED=<reviewer>`; a `GBUILD_REVIEW_OVERRIDE` waiver is
  recorded as a waiver, never as approval.
- Rollback uses `git revert`; `git reset --hard` on a shared branch is forbidden.

## What an appraiser still needs (not producible by more code)

1. Authorized Lead Appraiser + sponsor + interviews.
2. Business-objective-derived production feed for escape rate/MTTR.
3. A second project that ratifies its own baseline and trend under this process.
4. A larger CAR population for effectiveness sampling.

Until those exist, no claim of L5 certification is valid.
