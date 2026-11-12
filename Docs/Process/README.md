# Process assets

This directory holds the **process** of the `_Build` platform: the parts that
transfer to another project. The code transfers through the toolchain; the
process transfers through these documents.

| Document | What it is |
|---|---|
| [verification-process.md](verification-process.md) | The portable verification process: the loop, the gate inventory, the evidence, the ratchet doctrine, the coverage rules, and how another project inherits it |

## Why this exists

The platform's maturity was capped at "managed, not optimising" for one reason
that had nothing to do with code: the discipline lived in one repository's
`AGENTS.md`, so every other project had to re-derive it, and each derivation
was slightly different. A process that cannot be inherited is not a process
asset - it is a habit.

The same gap closed the other way: the **decisions** that shape this codebase
now live in [../ADRs](../ADRs/README.md) instead of in code comments, so a
reviewer can see *why* a shape was chosen.

## What is NOT here

- The repository's own working rules (what an agent may touch, what the
  invariants are): `../AGENTS.md`. They are specific to this repository and
  would be wrong to copy elsewhere.
- Generated API documentation: `../api-reference.md` and `../API/`. Those are
  generated from the module inventory and are gated against it.
- Measured numbers: `../../Tests/process-baseline.json`. They are measurements
  of *this* repository; a downstream project must re-measure, never copy.

## How a downstream project adopts it

1. Read [verification-process.md](verification-process.md) §2-§7 and decide
   which roles the project has.
2. Implement the questions of §4 with the project's own tools; the commands in
   the gate inventory are this repository's, not the standard's.
3. Create the four inheritance artefacts of §8: the gates, the scope map, a
   committed baseline and a per-run time series.
4. Re-measure every threshold. Copying a number from this repository is the
   mistake §8 exists to prevent.
