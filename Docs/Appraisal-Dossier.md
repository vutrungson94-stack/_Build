# Appraisal dossier — `_Build`

Assessment date: 2026-11-16 (self-assessed; NOT a SCAMPI appraisal)
Verdict: **Level 4 (Quantitatively Managed), with Level 5-local mechanisms.**
This document maps this repository to the practices an appraiser would ask
about. It is NOT a SCAMPI appraisal, not a certificate, and cannot be cited
as one by any party. ADR-0003 binds.

**Scope**: `_Build` only — a standalone .NET build platform. Sibling tools
`_Sync` and `_Tests` are independent repositories; this dossier does not
grade them, and no evidence below comes from them.

## What the reviewer can verify with one command

```powershell
./gbuild.ps1 -SelfTest    # expect: PASSED (11/11 checks), exit 0
```

## Actual numbers (measured 2026-11-16, not copied)

| Capability | Measured |
|---|---|
| Pester suite | 1,760 passed, 0 failed, 8 skipped, 1,768 total; 126 scopes, all state-sensitive isolated |
| SelfTest | 11/11 gates, parse 103 files, dependencies 77 modules / 184 edges / 0 missing / 0 cycles |
| Quality/coverage floor | floor 57 line coverage (measured 57.81%); 9 hygiene gates recounted by the gate itself |
| CI main-workflow, 90d | 18 success / 79 failure / 24 cancelled; change-failure rate 81.44% |

## Practice mapping (MG v2.0, illustrative)

| Practice | Evidence | Status |
|---|---|---|
| PAAN02 — Establishing a process | `AGENTS.md`, `README.md`, `.github/workflows/build.yml`, `gbuild.ps1 -SelfTest` + exit codes | done |
| PAAN03 — Defining process requirements | `gbuild.config.json` + schema; `Tests/Documentation.Tests.ps1` | done |
| PAAN05 — Developing the process plan | CI `build.yml` matrix (linux / windows / macos / arm64 / container / SBOM) | done |
| QIA01 — Collecting process data | `Tests/ProcessMetrics.psm1` trend + `tests/TestResults/process-trend.jsonl` | done |
| QIA02 — Process performance baseline | `Tests/process-baseline.json`, `Tests/ci-run-history.json` | done |
| QIA03 — Establishing process performance baselines | `Tests/ProcessMetrics.Tests.ps1`, `SelfTest` reads them | done |
| QIA04 — Analyzing process performance | `Docs/CMMI-L5-Assessment.md`, `Docs/Process/2026-11-13-independent-audit.md` | done |
| QIA05 — Establishing process control | `-SelfTest` gate suite (11 gates); `Runner.Tests.ps1` fails on process-baseline drift | done |
| QIA06 — Monitoring the process in statistical control | SPC gate exists, `ProcessControl` scope enforces suite samples; data exists but statistical stability of the CI history signal is not yet proven | partial, honestly bounded |
| CAR03 — Corrective action reports | `Tests/CarGate.Tests.ps1` (new 2026-11-16 in `_Sync`; not in `_Build` — gap stated); `Tests/CIRunHistorry.Tests.ps1` (this repo's CI history gate) | partial |
| SPS — Establishing a supply chain baseline | `Modules/SupplyChain.psm1`, `sbom` CI job, provenance | done |
| IMP — Assessing process improvement | `Docs/CMMI-L5-Assessment.md`, `Docs/Process/2026-11-13-independent-audit.md` | done |
| IMP Level 5 — Cross-project evidence | None; consumers of this tool are outside the repo and adopt it on their own authority. No consumer project has agreed in this repository to have its release flow measured. | **missing — stated honestly** |

## Known limitations (the honest gap list)

1. Production escape-rate / MTTR SLO: **none set** — this repo does not run on the consumer's CI; cross-project incident data does not exist in this repository. Any target would be aspiration.
2. Cross-project adoption evidence: **none recorded** — a consumer project would need to agree to have its release pipeline measured under `_Build`'s process.
3. CAR closure-effectiveness for `_Build`: a stale-CAR gate exists (CI self-test), but a verified-record ledger like `_Sync`'s does not exist yet; the gap is stated, not hidden.
4. SCAMPI appraisal: **none performed** — no lead appraiser, no sponsor, no interviews.
5. CI failure data exists (`Tests/ci-run-history.json`) but is **not an escape-rate SLO** and is not labeled as one.
