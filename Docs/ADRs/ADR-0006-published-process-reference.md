# ADR-0006 - Publish the verification process as an inheritable asset

Status: Accepted
Date: 2026-11-12

## Context

The platform measured itself, controlled its process with statistical limits
and ran a working improvement loop - much of the machinery of a CMMI Level 5
organization, per the self-assessment. What it
did not have was a **process asset**: the discipline existed only as
`AGENTS.md` inside this repository.

That made the platform a single point of process failure. Another project
adopting the toolchain inherited the *commands* but not the *discipline*, and
re-derived it from scratch, slightly differently every time. The maturity
assessment said so explicitly: "the standards live in one repo's `AGENTS.md`
and its own modules. There is no published process reference that other
projects inherit."

The same gap existed on the decision side and had already been closed there
(ADR-0001..ADR-0005): decisions were moved out of code comments into reviewable
records. The process itself had not been.

## Decision

Publish the portable part of the verification process as a document under
`Docs/Process/`, and gate it against the repository it describes.

- `Docs/Process/verification-process.md` holds the process: the objective, the
  roles, the mandatory loop, the **gate inventory**, the evidence artefacts, the
  ratchet doctrine, the coverage rules (one gate over one artefact set; a
  partial measurement is never compared with a global floor), the inheritance
  steps and the anti-patterns the process prevents.
- `Docs/Process/README.md` indexes it and states what deliberately does NOT
  transfer: the repository's own working rules, the generated API docs and the
  measured numbers.
- The gate inventory is machine-readable (an HTML-comment delimited block) so
  a test can check it against the repository contract: every command in the
  inventory must also appear in `AGENTS.md`, and every ADR must be listed in the
  ADR index.

`AGENTS.md` keeps the repository-specific contract and points at the published
reference; it is not replaced by it.

## Consequences

- The process is now inherit-able: another project can adopt the loop, the
  gates, the evidence and the ratchet doctrine without reading this
  repository's code.
- The published reference is a **second copy** of a list that also exists in
  `AGENTS.md`. That duplication is deliberate and governed: a sync gate fails
  when the two drift, which is the same pattern as the governed duplication in
  ADR-0002.
- A reference that stops matching the repository it describes is worse than no
  reference, because it is trusted. The sync gate is therefore part of the
  decision, not an optional extra.
- Measured numbers still do not transfer. A downstream project re-measures
  every threshold; copying a number is the mistake the inheritance section
  names explicitly.
- The remaining distance to a full L5 rating is now organisational: the
  platform publishes a process, but the organisation still has to decide who
  adopts it and how often it is reviewed.
