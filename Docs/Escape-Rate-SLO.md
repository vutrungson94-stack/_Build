# Escape-rate / change-failure SLO memo — `_Build`

Date: 2026-11-16
ADR-0003 applies: this repository does not self-certify L5.

## What this is, and what it is NOT

This memo records the escape-adjacent signals this repository can honestly
produce today, and states plainly what it cannot produce.

## What EXISTS here (committed, reproducible, gated, enforced)

**1. An internal, enforced SLO set — `Tests/process-baseline.json`, section
`.slo` — derived from the committed objective and enforced by
`gbuild.ps1 -SelfTest` (section "6d. SLO GATE"), measured in the same run
via `Get-BuildQpmMeasures` and the process-metrics engine:**

```
objective (as recorded in the baseline):
  "No verification defect may reach a green state unnoticed, and the process
   that verifies this platform must itself stay at the targets it publishes."

escapeRate:  ≤ 0 NEW escaped defects per 7-day window
  measured: 0 escapes detected in the last 7 days (both recorded escapes are
            dated 2026-11-03; snapshot measured 2026-11-12)
            Escaped defects are recorded append-only in Tests/qpm-ledger.json
            (QPM-2026-001 Standalone template deletion; QPM-2026-002
            workspace-root guard), each with escapedBecause + prevention.
            The tool computes MTTR from detectedAtUtc/resolvedAtUtc.

mttr:        ≤ 900 s max mean recovery time (a 15-minute ceiling on the
             mean recovery time)
  measured: 137 s mean recovery time over the 50-sample QPM window
            (measured 2026-11-12); the metric reports n/a (fail-open) when
            the window holds no recovery incident

adoption:    ≥ 0.99 minimum mean adoption
  measured: 1.0 (7 of 7 adoption classes at parity, 0 below floor;
            snapshot measured 2026-11-12)
```

These targets are enforced, not aspirational: `gbuild.ps1 -SelfTest` fails
if any of them is missed. They are about **this repository's own
verification process** — defects that reached a green state — not about
consumers of the built artefacts.

**2. The 90-day CI change-failure rate** (`Tests/ci-run-history.json`,
unlocked-but-gated artefact, locked by `Tests/CiRunHistory.Tests.ps1`):

```
_Build CI, last 90d (snapshot generated 2026-11-16):
  runs in window: 121
  success 18, failure 79, cancelled 24
  change-failure rate (success+failure denominator): 81.44%
  (a red run here means a push to main failed this pipeline, largely during
   the recent remediation passes; it is NOT a user-visible defect)
```

## What does NOT exist here (not enough real production data)

- `_Build` is a distributed tool. Its consumers (projects built by it) live
  outside this repository; a defect escaping into a consumer is observable by
  the consumer, not by this repo. There is no consumer-side deployment or
  incident feed committed here, so **no consumer-facing escape rate or
  consumer-facing MTTR measurement exists and none is claimed.**
- the internal SLO above covers escapes into "green" states of THIS
  repository's own verification — it is one repo's process SLO, not an
  organisational rating and not a product-quality guarantee for consumers.

## What a consumer-facing escape-rate measurement WOULD require

1. A deployment feed (which build artefacts reached which consumer project).
2. An incident feed with real incidents, severity and resolution timestamps
   (see `Tests/incident-ledger.json`-style schema conventions elsewhere in
   this toolset) contributing consumer-side samples.
3. A gate comparing that feed against an escape-rate target derived from a
   stated objective — the pattern already in use for the internal SLO.
4. Third-party review of definition + data, per CMMI practice.

## The honest label

Use this document for exactly three statements:

- *this repository enforces an internal escape-rate/MTTR/adoption SLO against
  its own verification process* (see `process-baseline.json .slo` and
  `gbuild.ps1 -SelfTest`);
- *this repository does not have, and does not claim, a consumer-facing
  escape rate, an availability number, or a production SLO*;
- *the 81.44% figure is a CI change-failure rate over a remediation period,
  not an escape rate*. ADR-0003 stands; this memo is evidence for an
  SCAMPI appraisal, not a finding against this tool's consumer-facing
  quality.
