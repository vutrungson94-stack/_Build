# Verification process reference (portable)

Status: Published 2026-11-12. This is the **process asset** of the `_Build`
platform: the discipline a project inherits when it uses this toolchain. It is
written so that a project with a different codebase, a different language and
a different CI can adopt it without inheriting `_Build`'s code.

The repository-specific contract (what a contributor or an AI agent must obey
*inside this repository*) stays in `AGENTS.md`. This document is the portable
part: the loop, the gates, the evidence and the ratchet doctrine. The two are
kept in sync by a gate - see [Drift control](#drift-control).

## 1. Objective

> No defect may reach a green state unnoticed, and the process that verifies
> the product must itself be measured, ratcheted and improved.

Everything below exists to serve that sentence. A practice that cannot be
measured, or whose measurement is not enforced, does not belong in this
process.

## 2. Roles

| Role | Responsibility | Artefact |
|---|---|---|
| Author / AI agent | Makes the change, runs the gates, writes the evidence | The commit |
| Reviewer | Confirms the change is the smallest safe one and that the gates really ran | The review, or the waiver record |
| Gate runner | Executes the verification gates and publishes their evidence | The CI run |
| Process owner | Owns the committed floors and the objective | `Tests/process-baseline.json` |

The same person may hold several roles. What must not happen is a role being
skipped silently: an unrun gate is a failed gate.

## 3. The mandatory loop

1. **Analyse** - read the code path, the failing log and the invariants of the
   system. Comments in this codebase usually record the incident that shaped
   the current shape; read them before changing anything.
2. **Baseline** - run the gates on the *untouched* tree and record which
   checks fail **before** the change.
3. **Design** - the smallest safe change. Identify the single owner of the
   concept being changed and change that owner, not a copy.
4. **Implement and fix until green** - a failing test after the change is not
   "accepted for now"; fix the code or back the change out.
5. **Verify** - run the scopes that cover the change, then the full suite.
6. **Document** - refresh generated documentation in the same change when the
   public surface moved; record a decision when a decision was made.
7. **Re-measure and ratchet** - update the committed baseline from the
   *measured* numbers of the change. Floors move in one direction only.
8. **Ship** - publish, and verify the publication landed (a clean local status
   is not proof).

Steps 2 and 7 are the ones that are usually skipped, and they are the two that
turn a suite into a process.

## 4. Gate inventory

The authoritative list for this repository. Every entry must run before a
change is published, and its result must be visible in the run.

<!-- GATE INVENTORY -->
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SelfTest
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File './gbuild.ps1' -SyntaxCheck
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-CoreTests.ps1' -Scope All -StrictSkips
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'Tests/Run-E2ETests.ps1' -Scope All
./gbuild -SelfTest
<!-- /GATE INVENTORY -->

What each gate is for:

| Gate | Question it answers | Fails when |
|---|---|---|
| `-SelfTest` | Does the toolchain work, and is the *process* still at its floors? | A gate is broken, a module cannot be imported, a committed floor regressed, the QPM/SLO target was missed |
| `-SyntaxCheck` | Does every shipped file parse? | A shipped file has a parse error |
| core suite | Does the product behave? | A scope fails, a scope produces no verdict, or the accepted-skip budget is exceeded |
| end-to-end suite | Does the product work in a realistic flow? | An end-to-end scenario fails |
| POSIX launcher | Does the tool start on a non-Windows host? | The launcher or the smoke suite fails |

Additional gates that belong to this repository and are NOT part of the
portable set: the pre-commit / pre-push hooks, the pull-request review gate and
the coverage ratchet (see §7).

## 5. Evidence

A gate that produces no evidence cannot be audited. Every gate in this process
publishes at least one artefact:

| Artefact | Produced by | Retained |
|---|---|---|
| Per-scope verdict, timing table | core suite | per run, published as a CI artefact |
| Coverage report (line + bytecode view) | coverage run / merge | per run |
| Adoption curve sample (time series) | every core-suite run | append-only series |
| Escaped-defect ledger entry | a human, when a defect escaped | committed, append-only |
| Corrective-action record | automatically, on a failed gate | per run |
| Decision record | a human, when a decision was made | committed |

## 6. Ratchet doctrine

This is the part that makes the process *improving* rather than merely
*guarded*.

- A **floor** (coverage floor, accepted-skip budget, adoption floor) is
  lowered as the backlog shrinks and **raised** when the measurement proves the
  process got better. It is never lowered to make a red run green.
- An **SLO** (escape rate over a window, mean recovery time, mean adoption) is
  a target derived from the stated objective. It is re-derived only when the
  objective changes, and the derivation is recorded next to the number.
- A measurement is **recorded where it is measured**. A number copied from
  another run, from another metric or from another denominator is not a
  measurement of this gate.
- A gate that cannot fail is worse than no gate: every ratchet in this
  process is proven to fail by a planted violation.

## 7. Coverage

- One gate over one artefact set: the coverage number that is gated is the one
  that can be recomputed from the published reports alone.
- A partial measurement (one shard, one scope, one platform) is published as a
  diagnostic and is **never** compared with a global floor. Comparing them is
  a category error, and it produces a red job whose tests all passed.
- The union over scopes is a union, not a sum: a line covered in any scope
  counts exactly once.

## 8. Inheritance

A project that adopts this process needs four things:

1. **The gates** - run the inventory above; the commands are repository
   specific, the *questions* in §4 are not.
2. **A scope map** - map the project's test suites to named scopes, and decide
   which of them mutate global state (those run in isolation).
3. **A committed baseline** - a version-controlled file holding the measured
   numbers and the floors, so the gate works on a fresh checkout with no
   history.
4. **A time series** - an append-only per-run file holding the same
   measurements, so the floor can be a trend rather than a snapshot.

What deliberately does **not** transfer: the module layout, the specific gate
implementations, the accepted-skip budget, and the thresholds. Those are
measurements of *this* repository and must be re-measured, never copied.

### 8.1 Boundaries: tools that take part in the same verification stay independent

A verification process usually involves several tools - a test harness, a
builder, a synchroniser. They are **independent systems** that borrow each
other, and the difference decides who owns a concept and who fixes a defect:

- **Borrowing is allowed**: a tool invokes another as a process, with its own
  arguments, and takes its exit code as the verdict. A borrowed tool keeps its
  own gates, its own scope isolation and its own ownership of every concept it
  implements.
- **Containment is not**: no tool lives inside another, no vendored copy of a
  sibling's modules, no sibling's files inside another's tree.
- **No code-level dependency**: production code must not import or read a
  module out of a sibling's tree.
- **Concepts are owned once**: when two tools need the same concept, each owns
  its own copy on purpose and the duplication is governed - neither reaches
  into the other for it.
- **The boundary is checked, not remembered**: a gate asserts that no
  production file references a sibling tool and that no sibling tool is
  contained here.

A project that inherits this process inherits the PROCESS, not a tool tree.

## 9. Drift control

The published reference and the repository contract are checked against each
other: every command in the gate inventory above must also appear in the
repository's `AGENTS.md`, and every decision record must be listed in the ADR
index. A reference that silently stops matching the repository it describes
is worse than no reference, because it is trusted.

## 10. Anti-patterns this process exists to prevent

| Anti-pattern | What it looks like | The rule that stops it |
|---|---|---|
| Floor lowering | "Let me lower the coverage floor to make CI green" | Floors move only from measurement |
| Metric drift | A number in the baseline that no engine produces | The gate reads the engine, not the file |
| Partial vs global | A shard's percentage compared with the global floor | Partial measurements are diagnostics |
| Unclosed loop | A red gate and no analysis record | A failed gate opens a corrective-action record |
| Silent scope | A test file that is never executed | Every test file belongs to a scope |
| Unreconciled metrics | Two published percentages, no rule between them | One gate, one artefact set, a written reconciliation |
