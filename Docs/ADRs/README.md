# Architecture Decision Records

This directory holds the reviewable decision records for `_Build`. Each ADR
states a decision, the context that forced it, and the consequences. The code
comments record *what* the current shape is; these records explain *why* it is
that shape and not another.

| ADR | Decision | Status |
|---|---|---|
| [0001](ADR-0001-module-split-pattern.md) | Split a module only at a sub-domain boundary, using a dot-sourced subdirectory | Accepted |
| [0002](ADR-0002-governed-duplication.md) | Some duplication is intentional and pinned by a test | Accepted |
| [0003](ADR-0003-scope-isolated-test-runner.md) | Run state-sensitive test scopes in isolated child processes | Accepted |
| [0004](ADR-0004-committed-generated-docs.md) | Generated API docs are committed and gated against the module inventory | Accepted |
| [0005](ADR-0005-single-source-of-truth.md) | Defaults, config, paths and locale messages each have exactly one owner | Accepted |

## How to add an ADR

1. Copy the next number. One decision per file.
2. State the decision in the title, the context that forced it, and the
   consequences (including the ones you are accepting).
3. If you reverse an ADR, mark it `Superseded by ADR-XXXX` and write a new one.
   Never edit a accepted ADR's decision section in place.
4. Link it from the table above.

ADRs are prose, not code. They are not generated and must not be deleted to make
a gate pass.
