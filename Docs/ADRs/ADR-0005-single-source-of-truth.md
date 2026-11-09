# ADR-0005 — Defaults, config, paths and locale messages each have exactly one owner

Status: Accepted
Date: 2026-11-09

## Context

A portable build tool is duplicated by copy-paste: every module that needs a
default, a config value, a path rule or a message used to carry its own copy.
The copies drifted. A default changed in one place and not in another; a path was
built with a backslash on a POSIX host; an English log line survived a `-Locale`
switch.

## Decision

Each concept has exactly one owner. Everything else calls the owner.

| Concept | Owner | Callers use |
|---|---|---|
| Default values | `Modules/BuildConstants.psm1` | `Get-BuildConstant` / `Get-BuildDefault` |
| Configuration | `gbuild.config.json` + project override | `Modules/ConfigProvider.psm1` (`Get-SectionValue` / `Get-ConfigValue`) |
| Repository paths | `Modules/PathUtils.psm1` | `Join-Path` / `Split-Path` / `Resolve-Path` |
| Secret redaction | `Modules/SharedUtils.psm1` | `Protect-BuildSecretText` / `Invoke-BuildSecretProtect` |
| Tier-1 module list | `Modules/Tier1Modules.ps1` | dot-source |
| Locale messages | `Locales/*.json` | `Get-LocaleMessage` / `Resolve-LogMessage` |
| Bootstrap | `Modules/ModuleBootstrap.ps1` | dot-source |

A second copy is a finding unless it is a governed duplication under ADR-0002.

## Consequences

- The platform measures adherence with seven adoption classes in
  `Modules/ProcessMetrics.psm1`; all seven are at 100 % and a committed floor
  in `Tests/process-baseline.json` fails the build if any regresses.
- A new default belongs in `BuildConstants.psm1`, not inline at the call site.
- A new config key must be read by code; an unread key is a finding
  (`Level5.Parity.Tests.ps1`).
- A user-facing message must go through a locale resolver with a `-Fallback`;
  hardcoded English prose is a finding.

## Evidence

- `Modules/ProcessMetrics.psm1` (seven adoption classes)
- `Tests/process-baseline.json` (`adoptionFloor`, all `minAdoption: 1.0`)
- `Tests/Hygiene.Tests.ps1` (adoption floor gate)
- `Tests/Level5.Parity.Tests.ps1` (config-key parity)
