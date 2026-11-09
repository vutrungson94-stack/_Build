# ADR-0001 — Split a module only at a sub-domain boundary

Status: Accepted
Date: 2026-11-09

## Context

`Modules/Orchestrator.psm1` had grown to contain eight distinct sub-domains
(config, deploy, environment, module loading, pipeline, pipeline events,
targets, standalone, SDK) with minimal cross-calls between them. Editing one
sub-domain meant loading a 1,000+ line file and risking a change in another.

At the same time, several modules (`SharedUtils`, `SDK`, `Build`,
`ProcessMetrics`, `BuildConstants`) exceed 1,000 lines but are a single domain
with high internal call density.

## Decision

Split a module when it contains **two or more distinct sub-domains with minimal
cross-calls**. Follow one pattern:

```
Modules/<Module>.psm1                 # dot-source block at the top
Modules/<Module>/<Module>.<SubDomain>.ps1
```

The sub-files share the module scope of the parent, so no import graph changes
and no public API changes.

Do **not** split a cohesive single-domain module, regardless of line count.
Cohesion and call density are the signal, not LOC.

## Consequences

- `Modules/Orchestrator/` now holds the split sub-domains; `Orchestrator.psm1`
  remains the entry point and the public surface.
- Splitting a cohesive module would increase file count without improving
  navigability, and would risk breaking module-scope state.
- A future split must follow the same subdirectory + dot-source pattern; a
  second split style would create two ways to do the same thing.

## Evidence

- `Modules/Orchestrator/` (nine sub-files, dot-sourced from `Orchestrator.psm1`)
- `Tests/ModuleHygiene.Tests.ps1` (module discovery and hygiene gates)
