# Escape-rate / change-failure SLO memo — `_Build`

Date: 2026-11-16
ADR-0003 applies: this repository does not self-certify L5.

## What this is, and what it is NOT

This memo records the only escape-adjacent signal this repository can
honestly produce today from its own CI pipeline, and states plainly what it
cannot produce.

**Produced here (committed, reproducible, gated):**
`Tests/ci-run-history.json` — 90 days of runs of the primary `_Build CI`
workflow. Result and rate:

```
_Build CI, last 90d (history snapshot generated 2026-11-16):
  runs in window: 121
  success 18, failure 79, cancelled 24
  change-failure rate (success+failure denominator): 81.44%
  (failure here means THIS CI pipeline went red; not user-visible defects)
```

**NOT produced here (not enough real production data):**

- `_Build` is a distributed tool sold as a NuGet package. Its consumers
  (projects built by it) are outside this repository; a defect that escapes
  into a consumer CI run is observable by the consumer, not by `_Build`. No
  cross-project incident feed exists here to count escapes.
- MTTR is defined by durations of actual incidents. There are two recorded
  production escapes in `qpm-ledger.json` but no MTTR-partitioned incident
  timeline; the slo target in `slo-monitor` is a report field, not a
  measured target. No MTTR estimate is committed — only a target exists,
  not a measurement, and the target is aspiration.
- no SLO target (escape-rate < X%, MTTR < Y minutes) is set until that
  production deployment + incident feed exists. Setting one would be
  aspiration, not SLO.

## What an escape-rate measurement WOULD require

1. A production deployment flow (projects built by this tool) plus a way to
   know which build artefacts escaped the consumer's pre-merge gates.
2. An incident feed with real incidents, severity and resolution timestamps
   in `Tests/incident-ledger.json`-compatible schema.
3. A gate comparing that feed against an escape-rate target — exactly the
   pattern of `Tests/CarGate.Tests.ps1` but with a nonzero target, which
   requires data.
4. Third-party review of definition + data, per CMMI practice.

## What the CI history signal DOES tell a reviewer

- that this pipeline was red more often than green during the last 90 days
  because the tool was under heavy active remediation: 79 of 97
  non-cancelled recent main-workflow runs were red, 24 cancelled.
- that 18 of 97 non-cancelled runs were green, including the last several
  (itself the current state of `main`).
- that failure and cancellation events are visible, not suppressed by a
  green-light committer.
- that no SLO / MTTR target can be honestly set until consumer incident data
  exists, and the repository does not pretend otherwise.

## The honest label

Use this document's figures as "current CI change-failure rate" only. Do not
quote an escape rate, an MTTR, an availability number, or an SLO from this
repository. Those numbers do not exist for consumers of `_Build`. ADR-0003
stands; this memo is evidence for an SCAMPI appraisal, not a finding against
this tool's consumer-facing quality.
