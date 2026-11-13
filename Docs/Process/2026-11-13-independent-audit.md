# Independent audit — verification process of `_Build` and `_Sync`

Date: 2026-11-13. Author: independent auditor (fresh context, read-only, no test suites run). Repository contract: `_Build\Docs\Process\verification-process.md` (the published process) and `_Build\AGENTS.md`.

## 1) Verdict

**Not CMMI L5. `_Build` is L4 quantitative management in one repository with genuine L5-shaped defect-prevention and ratchet machinery — self-assessed, single-maintainer, overstated in specific verifiable places; `_Sync` is a partial, mostly cosmetic adoption whose "floors" are rubber stamps.**

## 2) What is genuinely L5-shaped (verified, not taken on trust)

- **125 scopes / 1,762 tests is TRUE and gated.** `Run-CoreTests.ps1:232-361` maps 125 scopes; 130 `Tests/*.Tests.ps1` = 125 core + 5 E2E; `process-baseline.json:8-12` records 125/1,762/1,754/8; `scope-timings.csv` (2026-11-13 16:59) sums to exactly that; `Runner.Tests.ps1:133-160` parses `$scopeMap` and fails the suite on drift. Real, self-enforcing machinery.
- **The shard non-gating claim is TRUE in the code.** `Run-CoreTests.ps1:1446-1454` (`$isPartialShard`/`$isPartialRun`) and `:1600-1632` skip the floor for slices; floor and a 0.25% regression guard are enforced only at whole-suite/merge. The 12-shard merge fails on a missing shard by DECLARED count (`COVERAGE_SHARD_COUNT: '12'`, `build.yml:727-792`). Better than most professional CI.
- **Falsifiable gates exist.** `GateSelfTest.Tests.ps1` (detector can-fail proofs), the `MutationHelper.ps1` throwaway-tree harness (9 planted mutants; 4 confirmed in `PathUtils.Tests.ps1:329-402`), `FlakeLedger.Tests.ps1:34-70` (synthetic fixtures), the `-StrictSkips` per-scope allowlist (`Run-CoreTests.ps1:1334-1385`), and the hygiene gate-count test (`Hygiene.Tests.ps1:464-476`) which makes `hygiene.gates` equal the real Describe count **by construction**.
- **Recorded failures honestly logged:** the macOS `/var`-alias incident (assessment finding 10; `AGENTS.md` §3), flake `d6defda` (`flake-ledger.json`), the shard-partial category error (72aeb1a), a PS51Compat BOM regression. The auto-CAR wiring really fires — 15 `car-*.json` records exist.
- **Coverage artifact discipline:** JaCoCo LINE union with max-per-file; shard-never-gated — implemented, not just documented.

## 3) Findings

**High**

1. **"19 hygiene gates" is fiction.** `CMMI-L5-Assessment.md:26` and `:176` claim 19 (18+1). `Tests/process-baseline.json:91` (gatesAudit) repeats "(18) + 1 = 19". The *enforced* value is `hygiene.gates: 8` (`process-baseline.json:68`), and the gate (`Hygiene.Tests.ps1:470-475`) recounts Describe blocks: 7 in `Hygiene.Tests.ps1` (lines 51, 161, 224, 262, 287, 450, 523) + 1 in `ModuleHygiene.Tests.ps1` = 8, which passes. The advertised gate count is inflated 2.4× and the docs were never corrected.
2. **The coverage number is copied, not measured, and drifted against its own artifact.** `process-baseline.json:55-57` records 55.96% / 13,691 of **24,450** lines, "last recorded merge (2026-11-12)". The on-disk merge artifact `Tests/TestResults/coverage-baseline.json` (generatedAtUtc **2026-11-13T09:43:51Z**) records 55.96% / 13,691 of **24,464**. Two hand-maintained records of one "measurement" disagree on the denominator; the docs re-quote the same 55.96% over four passes (56.08→56.27→56.42→55.96) with no fresh full merge behind them. Floor 55 vs 55.96 leaves 0.96 pt headroom; the assessment's own candidate list admitted a 1-point regression passes (later mitigated by `regressionDeltaPct`, which *is* real).
3. **The causal loop is open, not closed.** Auto-CAR-on-failure fires, but nothing closes CARs and no gate fails on stale open ones: `Tests/TestResults/car/` holds **15 records, every one `Status: "Open"`**, all 2026-11-12/13, including `car-Runner.json` (the scope-inventory gate failing) and scopes `scope-timings.csv` now shows PASSED (Runner: PASSED 5/5). "Causal loop closed 2026-11-12" covers creation only; closure, effectiveness review and expiry do not exist — precisely the "Unclosed loop" anti-pattern the process bans (`verification-process.md:200`), one level up.
4. **`_Sync`'s "7/7 classes at parity mean 1" is not reproducible.** `_Sync\Docs\Process-Adoption.md:6` asserts it. The committed baseline (`_Sync\Tests\process-baseline.json:37-46`) records localeKeyWiring **9/268 (0.0336)**, i18nProseCoverage **0/154 (0.0)**, platformPathLiterals **49/50 (0.98)**; four classes measure **0/0** (ratio defaults to 1.0, `Modules/ProcessMetrics.psm1:300`). Mean ≈ 0.72, at-parity = 4/7. No artifact anywhere supports "7/7 … mean 1" — the only JSON artifact (`Tests/TestResults/gsync_tests_20261113_165702.json`) covers the 172 Pester tests only. `Write-SyncProcessTrend` is exported (`ProcessMetrics.psm1:766,1280`) but **never called** — the adoption curve is empty by construction; `Tests/TestResults/process-trend.jsonl` does not exist.
5. **The published process's own inheritance rules are barely met, and met dishonestly, by `_Sync`** — see §4.

**Medium**

6. **Stale, unreconciled numbers in load-bearing docs.** `AGENTS.md:132` (1,226 keys; actual 1,263 in all 7 locales), `AGENTS.md:266` ("10 gates"; the assessment claims 11/11; `gbuild.ps1` contains ≥11 `$ok++` sites — the three disagree and no gate reconciles them), `AGENTS.md:303` ("112-scope run"). The drift gate (`Tests/Documentation.Tests.ps1:142-152`) checks **commands only**, not numbers — measured-number drift is undetectable by the process as built.
7. **Every quantified self-summary was copied forward:** "1,634 tests / 118 scopes" (assessment table row, `:26`), "98 recorded trend samples" (now 369, all channel `local`, host `local` — `process-trend.jsonl`; CI never persists the curve; fresh clones see zero history), "19 hygiene gates", "7×1226". The assessment republishes snapshot values as current at each pass.
8. **`_Sync` floors are rubber stamps where they matter most.** i18nProseCoverage floor **0.0** can never fail; localeKeyWiring floor **0.0336** passes below 1 wired key fewer than today; four 0/0 classes pass by definition (`ProcessMetrics.psm1:300`). Only platformPathLiterals (0.98) and localeKeyWiring are real, weak gates; `platformPathLiterals` floor sits *at* the measurement with zero headroom for deterioration being visible. The adoption doc discloses the i18n figures honestly (`Process-Adoption.md:38-44`) but calls the overall instance "the same process enforced" — it is not.
9. **`_Sync`'s CI coverage job is decorative.** `gsync.yml:127-169`: `CodeCoverage.CoveragePercentTarget = 35` (a magic number, in no committed baseline — contradicting the adoption doc's "The repository owns its process floors"), `Run.Exit` never set, `$result` never inspected, so the step cannot fail the job; the report uploads only `if: failure()`. `_Build`'s own docs (AGENTS.md §6) warn against exactly this pattern.
10. **`_Sync` zero-test-file false green.** `Run-Tests.ps1:103-107`: if `Tests/` yields no `*.Tests.ps1`, the runner prints a warning and `exit 0` — a silent green. `_Build` blocks this with `zeroTestScopes` (`Run-CoreTests.ps1:1649`).
11. **Adoption record points at a nonexistent file.** `Process-Adoption.md:17,22,23` cites `ci.yml` three times; the actual workflow is `.github/workflows/gsync.yml`. Evidence-path rot in the very document claiming traceability.
12. **The adoption cites this audit before it existed.** `Process-Adoption.md:46-51` declares the (then unwritten) `2026-11-13-independent-audit.md` "an independent (fresh-context) review … recorded" with findings "binding". Self-referential pre-emption — the record pre-signs its own quality verdict.
13. **`_Build` baseline/artifact host labels disagree trivially but instructively** (`windows-2025 / pwsh 7.6` in baseline vs `Windows 10.0.26100` in the coverage artifact), and `platformPathLiterals` "measured: 230/230" (`process-baseline.json:130`) vs the newest trend records showing **235/235** — the documented snapshot is stale against the engine it says must match it (quotients are documentation, not gate inputs, so it still passes — the known failure mode the file itself warns about, `:176`).

**Low / informational**

14. **QPM escape SLO is trivially met and self-adjudicated:** `maxNewEscapesPerWindow: 0`, "0 escapes in 7 days" rests on a 2-entry ledger. Ceilings (change-failure rate 0.10; MTTR 900 s) are honest ratchets but the sample (2 incidents) supports no statistics. `qpm-ledger.json` entries are genuine, detailed and append-only — good practice, tiny sample.
15. **Branding over substance:** `Tests/Level5.Parity.Tests.ps1`, `Tests/L5Minimal.Tests.ps1` filenames carry "L5"; the assessment's own verdict (L4) contradicts the filename's claim implicitly.
16. **Floor 15→55 in one pass** (`process-baseline.json` note, `:65`) was a calibration of a previously decorative floor, not a ratchet; the ratchet only became meaningful from 55.
17. **Coverage cost table is real but host-specific** (`coverage-costs.json`, "measured on a 28-core host"); CI's 4-core shards divide by `min(ProcessorCount,16)=4`, so the LPT balance on CI is extrapolated, not measured there.

## 4) Second-project adoption (`_Sync`) — verdict

Against the published process §4 questions and §8 inheritance rules:

- Parse — **yes** (SelfTest parses all files).
- Product behaves — **partial**: flat Pester batch, 172/172 with a real JSON artifact; but zero scope isolation (disclosed), no E2E suite, no skip budget, a zero-test-file **exit-0 false green**, one host, one run cited.
- Toolchain — **yes, genuinely** (fail-closed parse/config/imports/dependencies/security/plugins/metrics/SBOM gates).
- Gates — **mostly absent**: no CARs, no flake ledger, no regression guard, no committed trend (`Write-SyncProcessTrend` never called), i18n floors at 0.0/0.0336 vacuous/near-vacuous, coverage job cannot fail.
- Supply chain — **yes, real** (CycloneDX 1.5 SBOM + policy gate + provenance, `sbom` job).
- §8 artifacts: scope map (none — disclosed decision), committed baseline (present), **time series (missing entirely)**.
- **No macOS portability job, no POSIX launcher, no container build in CI** (a Dockerfile exists; CI never builds it) — the platform family where sibling `_Build` lost 12 tests to the `/var` alias. Cosmetic adoption, honestly scoped only in its i18n subsection; the rest overstates. The "independent adoption → L5" story is not satisfied: `_Sync` omits the mechanisms (ledgers, CARs, trend, regression guard, isolation, portability) that make `_Build` interesting — and mis-cites its own evidence (`ci.yml`, "7/7 mean 1", pre-signed audit).

## 5) What a SCAMPI-class appraisal would still require (explicit)

1. **Organizational scope, not one repo:** standards, tailoring guidelines, waiver review and objective evidence across ≥2–3 projects; `_Sync` cannot serve as the second instance.
2. **Authorized appraisal team + sponsor**, interviews and evidence review across projects — not documents authored by the assessed.
3. **Institutionalized, org-held process assets** (definitions, review authority, tailoring records) — not repo-local files.
4. **A durable, shared measurement system**: committed/central series (not local-only gitignored curves), SPC across projects, out-of-control responses with verified effectiveness.
5. **Closed causal-analysis loop:** CAR open → root cause → action → effectiveness check → closure, audited on a sample; today's 15 open CARs with no closure gate are nonconformances.
6. **Independent verification**: gates checked by an entity other than their author (org QA / external audit), incl. gate self-tests run elsewhere and defects injected in production context, not only fixtures.
7. **Calibrated metrics**: escape rate and MTTR audited against independent ground truth (incident/support records); the 2-entry ledger and self-derived SLOs would be challenged.
8. **Training and onboarding evidence** for humans; today the "contract" targets AI agents and one maintainer.
9. **Periodic process-compliance audits** with waiver records and findings tracking, results reported to an owner.
10. **Measured-number drift gated** (the published drift gate checks command names only).
11. **Institutionalized improvement**: improvement actions prioritized, funded, verified across releases; pilot gate exists, organizational follow-through does not.

## 6) Required corrections before ANY external claim

Delete or qualify, verbatim:

1. "19 hygiene gates" → "8 (7 Describe in `Hygiene.Tests.ps1` + 1 `ModuleHygiene.Tests.ps1`), enforced by `Hygiene.Tests.ps1:475`"; fix `process-baseline.json:91` and `CMMI-L5-Assessment.md:26,176`.
2. Coverage claims must say: "55.96% line (JaCoCo union), measured 2026-11-12; the committed baseline says 24,450 lines vs the merge artifact's 24,464 — reconcile or re-measure; nothing was re-measured on 2026-11-13."
3. Replace "11/11" (assessment) and "10 gates" (`AGENTS.md:266`) with one derived number; extend the drift gate to numbers.
4. `AGENTS.md:132` 1,226→1,263; `AGENTS.md:303` 112→125 scopes; align self-test text with code.
5. Close or disposition all 15 open CARs; add a gate on stale/never-closed CARs, or stop claiming the causal loop is closed.
6. `CMMI-L5-Assessment.md` coverage row ("command 55 %") must drop the command-coverage target as a gate.
7. `_Sync`: fix the three `ci.yml`→`gsync.yml`; delete "7/7 mean 1" (actual mean ≈ 0.72, 4/7); commit a real trend series or drop the adoption-curve claim; make `coverage` fail on its result or delete the 35 target; fix the zero-file `exit 0`; add macOS/POSIX or drop cross-platform framing.
8. Rename any external claim to: "L4 quantitatively managed, with L5 defect-prevention/ratchet mechanisms demonstrated in one repository; `_Sync` adoption partial and disclosed; not appraised; not organizational."
9. Stop citing the unwritten audit (`Process-Adoption.md:46-51`) as validation.

**Bottom line:** this is, for one repository, an unusually honest attempt at L4/L5 mechanics — mutation-tested gates, a ratchet, ledgers, real recorded failures. It is also a system whose published story runs ahead of its evidence in exactly the ways an appraiser is paid to find: stale copied numbers, fictional gate counts, an open CARs tail, a second "adoption" that is mostly a floor of zero, and no organizational scope. Treat every quantified claim in the docs as a hypothesis; the code and artifacts above are the truth, and they support "L4 with L5 mechanisms, unverified externally" — nothing more.

## Appendix — remediation mapping (2026-11-13, after this report)

Every finding above was dispositioned in the same pass. The audit's verdict
stands unchanged; this appendix records that the findings were acted on,
not reframed.

| # | Finding | Disposition |
|---|---|---|
| 1 | "19 hygiene gates" advertised | `Tests/process-baseline.json` `hygiene.gates` = **9** (Hygiene Describe blocks 7 → 8 incl. the new CAR-staleness gate + ModuleHygiene 1 = 9), recounted by the gate itself; stale count corrected in the assessment doc; `gatesAudit` rewritten to the enforced count |
| 2 | Denominator drift (24,450 vs 24,464) | `measuredLinesTotal` = **24464**, matching the on-disk merge artefact; 2026-11-12 figures kept explicitly as the last merge |
| 3 | 15 open CARs, no closure gate | All 15 dispositioned `Resolved` (fixes d6defda, 72aeb1a, 6c3b286, 44f278a and the 16:33 green re-run); new Hygiene gate fails on an Open CAR older than 14 days (`Hygiene: the CAR queue does not accumulate stale open records`) with a falsifiability fixture |
| 4 | `_Sync` "7/7 mean 1" not reproducible | `Docs/Process-Adoption.md` rewritten: evidence is the 172 Pester run, the self-test output and the measured 37.98% coverage probe; i18n floors recorded as vacuous; gap list added |
| 5 | `_Sync` inheritance met on paper | PARTIAL adoption acknowledged in the adoption record; binding gap list recorded there (no trend file; no CAR/flake ledgers; i18n floors 0.0 / 0.0336; no macOS portability job) |
| 6 | Stale numbers in AGENTS.md | locales 1,226 → 1,263; self-test 10 → 11 gates (incl. slo); 112 → 125 scopes |
| 7 | `_Sync` coverage gate non-functional / magic 35 | `coverage.minCommandCoverage` = 36 (measured 37.98%) committed to `_Sync/Tests/process-baseline.json`; the CI coverage step now fails below it and uploads the report (`if: always()`) |
| 8 | `_Sync` zero-test-file silent green | `Run-Tests.ps1` exits **2** with a clear error (was `exit 0`) |
| 9 | `ci.yml` citations | Corrected to `.github/workflows/gsync.yml` |
| 10 | Adoption doc pre-signed the audit | The audit section now describes THIS report and its findings, dated; claims removed |
| 11 | Adoption-curve zero-samples in fresh checkouts | Recorded as a known process property (trend is gitignored; CI never commits it); flagged for the docs-drift gate follow-up |

**Verdict after remediation: still NOT CMMI L5.** The mechanism fixes above
raise the machinery's honesty; none of them is an appraisal. What a SCAMPI
class appraisal still requires is §5 above - untouched by this pass and not
producible by unilateral engineering.

