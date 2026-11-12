# ADR-0007 - The three platform tools stay independent: borrowing is allowed, containment is not

Status: Accepted
Date: 2026-11-12

## Context

`_Tests`, `_Build` and `_Sync` are three separate tools that live side by side in
the same workspace. They are easily mistaken for one product with three
folders, and that mistake is expensive:

- a change in one is *expected* to show up in the other (nothing syncs them
  automatically, and they are released independently),
- a fix gets filed in the tool that shows the symptom instead of the tool that
  owns the concept,
- and, worst, code starts reaching across the boundary: one tool imports a
  module out of another's tree, or one tool's folder ends up inside another's,
  and the boundary stops existing.

What the three actually do is **borrow** each other:

- `_Tests` borrows the project under test to run its suites - and, since
  2026-11-12, it delegates to a project that ships its own runner instead of
  flattening every `*.Tests.ps1` into one Pester session,
- `_Build` borrows `_Tests/gtest.ps1` and `_Sync/gsync.ps1` as external gates,
- `_Sync` borrows the project it syncs.

That is borrowing: a process invokes a tool across a file-system boundary and
reads its exit code. It is not containment, and the difference is not
philosophical - it decides who owns a concept, who fixes a defect, and what
happens when one of the three is replaced.

## Decision

The three tools are INDEPENDENT systems. Five rules:

1. **No containment.** No tool may live inside another: no `_Build/_Tests`, no
   `_Sync/_Build`, no vendored copy of a sibling's modules, no sibling's files
   checked into another's tree.
2. **No code-level dependency.** Production code in one tool must not import,
   dot-source or read a module out of a sibling's tree. Invoking a sibling as
   an EXTERNAL PROCESS (a gate command, a sync command) is allowed; importing
   it is not.
3. **Borrowing is explicit and one-way.** The borrowing tool invokes the
   borrowed tool as a process, with its own arguments, and takes its exit code
   as the verdict. The borrowed tool keeps its own gates, its own scope
   isolation and its own ownership of every concept it implements.
4. **Concepts are owned once.** When two tools need the same concept, each owns
   its own copy on purpose and the duplication is governed (ADR-0002);
   neither reaches into the other for it.
5. **The boundary is checked, not remembered.** A gate asserts that no
   production file references a sibling tool's path and that no sibling tool's
   directory is present inside this one.

## Consequences

- The three repositories can be released, forked and replaced independently; a
  missing sibling degrades to a SKIP in the borrowing tool, never to a failure.
- The workspace layout (three sibling folders) is the supported layout.
  Nesting is not, and a nested copy is a defect, not a convenience.
- The published process (`Docs/Process/`) inherits the same boundary: a project
  adopts the PROCESS, not the tool tree. That is the point of publishing it -
  the discipline transfers, the folder layout does not.
- The rules are cheap to check, so they are checked: the independence gate
  scans production code and the tree, and a violation is a red build rather
  than a review comment nobody remembers.

## Evidence

- `Tests/Level5.Parity.Tests.ps1` - the independence gate (no production file
  reaches into a sibling tool; no sibling tool is contained here) and the
  pre-existing containment gate for the CI and container artifacts.
- `_Tests/Modules/TestRunner.psm1` - borrowing done right: the project runner
  is invoked as a process and its exit code is the verdict.
- `AGENTS.md` section 6 - the external harness gates are invoked, never
  imported.
