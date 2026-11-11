# gbuild — Portable Build Platform

[![Build](https://github.com/your-org/your-repo/actions/workflows/build.yml/badge.svg)](https://github.com/your-org/your-repo/actions/workflows/build.yml)

## What is this?

`_Build/` is a **standalone, portable build system**. You can clone it once, keep it on your machine or USB, and use it to build **any project** — without copying `_Build` into every repo.

## Architecture

```
_Build/
├── gbuild.ps1              # Entry point (Windows / PowerShell)
├── gbuild                  # POSIX launcher (Linux / macOS / WSL)
├── Install-GBuild.ps1      # Global shortcut installer
├── gbuild.config.json      # Configuration (portable) or use project-local config
├── Modules/                # Core modules
│   ├── Orchestrator.psm1   # Main orchestrator (Start-GBuild)
│   ├── Logging.psm1        # Logging, colors, progress bars
│   ├── Menu.psm1           # Interactive build menu
│   ├── Loader.psm1         # Plugin system (discovery + dispatch)
│   ├── Preflight.psm1      # Cross-language pre-build validation
│   ├── Parallel.psm1       # Runspace pool parallel execution
│   ├── Cache.psm1          # Build cache (content-addressable, single-hash)
│   ├── Build.psm1          # Build execution (dotnet, deploy, live progress)
│   ├── BuildProgress.psm1  # Single-line heartbeat + classifier (Test-BuildOutputLine)
│   ├── BuildConstants.psm1 # Single source of truth for defaults
│   ├── PathUtils.psm1      # Portable path helpers (no hardcode)
│   ├── Project.psm1        # Project detection + metadata
│   ├── SDK.psm1            # SDK discovery + caching (6-strategy waterfall)
│   ├── Environment.psm1    # OS detection, path utilities
│   ├── Clean.psm1          # Smart clean (bin/obj)
│   ├── Deploy.psm1         # Android AAB, web, desktop publish
│   ├── DeployTargets.psm1  # Deploy targets (Azure/AWS/Vercel/GCP/K8s)
│   ├── Android.psm1        # Android tools (adb, keystore)
│   ├── ErrorHandling.psm1  # Error classification + rollback + circuit breaker
│   ├── EventBus.psm1       # Pub/sub (21 events, 21 wired)
│   ├── CacheProvider.psm1  # Remote cache (Azure Blob / S3)
│   ├── Versioning.psm1     # Version bump + changelog
│   ├── Security.psm1       # Secret scan + vulnerability check
│   ├── Sast.psm1           # Multi-language SAST
│   ├── Policy.psm1         # Policy-as-code (OPA)
│   ├── Siem.psm1           # SIEM export (CEF/syslog/JSONL)
│   ├── Standalone.psm1     # Single-file bundle
│   ├── SupplyChain.psm1    # SBOM + provenance + compliance
│   ├── InfraVerification.psm1 # Infra checks (-VerifyInfra)
│   ├── HealthCheck.psm1    # Doctor/health check suite
│   ├── Report.psm1         # Build metrics + reports + SARIF
│   ├── Metrics.psm1        # Prometheus + OTLP
│   ├── Alerting.psm1       # Webhook alerts
│   ├── Distributed.psm1    # Multi-host builds via SSH
│   ├── Container.psm1      # DI container
│   ├── CredentialVault.psm1 # AES-256-CBC vault
│   ├── BuildContext.psm1   # Build context (State)
│   ├── IContract.psm1      # Interface contracts
│   ├── Documentation.psm1  # Help + module docs
│   ├── HotReload.psm1      # dotnet watch integration
│   ├── LanguageDetector.psm1 # Build file → language mapping (21 entries)
│   ├── SharedUtils.psm1    # Shared utilities + universal syntax check + audit log
│   └── Providers/           # Strategy providers (CI/local)
│       ├── BuildStrategyProvider.psm1
│       └── EnvironmentProvider.psm1
├── Plugins/                # Language plugins (loaded by Loader)
│   ├── Dotnet.psm1         # C#/F#/VB.NET
│   ├── Node.psm1           # Node.js/TypeScript
│   ├── Python.psm1         # Python
│   ├── Rust.psm1           # Rust/Cargo
│   ├── Java.psm1           # Java/Maven/Gradle (Kotlin/Scala)
│   ├── Go.psm1             # Go
│   ├── Docker.psm1         # Docker
│   ├── Ruby.psm1           # Ruby/Bundler
│   ├── PHP.psm1            # PHP/Composer
│   ├── Cpp.psm1            # C/C++/CMake (C)
│   ├── Elixir.psm1         # Elixir
│   ├── Swift.psm1          # Swift
│   └── Avalonia.psm1       # Avalonia UI
│   └── helpers/            # Shared plugin helpers
│       ├── PluginHelpers.psm1
│       └── DotnetHelpers.psm1
├── Tests/                  # Pester tests
└── Docs/                   # ADRs and API docs
```

## Three Usage Modes

### Mode 1: Embedded (default)

`_Build/` lives **inside** your project repo.

```powershell
# From project root
.\_Build\gbuild.ps1

# From any subdirectory
.\_Build\gbuild.ps1

# With options
.\_Build\gbuild.ps1 -Incremental
.\_Build\gbuild.ps1 -Clean
.\_Build\gbuild.ps1 -GitHub
.\_Build\gbuild.ps1 -Security
```

### Mode 2: Portable / USB / Separate Clone

Keep `_Build/` in a **single place** (USB, `G:\tools\_Build`, `~/gbuild`, etc.) and build **any project** from anywhere.

```powershell
# From inside the project folder — auto-detects project root
PS E:\my-project> G:\tools\_Build\gbuild.ps1

# Explicit project path — works from anywhere
PS C:\> G:\tools\_Build\gbuild.ps1 -Project E:\my-project

# Incremental build
PS anywhere> G:\tools\_Build\gbuild.ps1 -Project E:\my-project -Incremental

# Linux / macOS / WSL
cd /path/to/project
/media/usb/_Build/gbuild
/media/usb/_Build/gbuild -Project /path/to/any/project
```

### Mode 3: Global Shortcut (`gbuild`)

Install once, then type **`gbuild`** from any directory.

```powershell
# Run this one time
PS G:\tools\_Build> .\Install-GBuild.ps1 -GbBuildHome 'G:\tools\_Build'

# Then, from any project:
PS E:\my-project> gbuild
PS C:\other-project> gbuild -Project C:\other-project

# Short alias
PS E:\my-project> gb
```

>`Install-GBuild.ps1` writes a function + alias into your PowerShell `$PROFILE`. It survives new sessions.

## Auto-Detection

When you run without `-Project`, gbuild walks up from the current directory looking for project markers:

| Marker | Language |
|--------|----------|
| `*.csproj`, `*.fsproj`, `*.vbproj`, `*.sln` | .NET |
| `package.json` | Node.js |
| `Cargo.toml` | Rust |
| `go.mod` | Go |
| `pyproject.toml` | Python |
| `pom.xml`, `build.gradle` | Java |
| `Dockerfile` | Docker |
| `CMakeLists.txt` | C/C++ |
| `Gemfile`, `composer.json` | Ruby / PHP |

Max depth: **10 levels up**. If nothing is found, it falls back to the **parent directory of `_Build/`**.

## Project Root Resolution Order

1. `-Project <path>` argument (explicit)
2. `GBUILD_PROJECT` environment variable
3. Walk up from current working directory (auto-detect)
4. Parent of `_Build/` directory (legacy fallback)

## Configuration

Config is resolved in this order:

1. `_Build/gbuild.config.json` (portable — config travels with the build tool)
2. `ProjectRoot/gbuild.config.json` (embedded — config lives in the project)

If both exist, project-local config **overrides** portable defaults.

### Example: Project-Local Config

```json
{
  "build": {
    "defaultConfiguration": "Release",
    "preflight": {
      "checkSyntax": true,
      "checkManifest": true,
      "checkAllManifests": true,
      "requiredTools": ["dotnet", "node", "cargo"],
      "minDiskSpaceMB": 2048
    }
  }
}
```

### Code Signing of Windows Artifacts (`security.peSign`)

The `SignArtifacts` pipeline step signs the Windows PE artifacts (`.exe` / `.dll`) a build
produced, so a downloaded binary is not flagged as an unknown publisher by SmartScreen.
It is **off by default** — a project opts in through its own `gbuild.config.json`:

```json
{
  "security": {
    "peSign": {
      "enabled": true,
      "tool": "powershell",
      "certificateThumbprint": "8654BF862AB38906CD548D74431ACF1FA08592C0",
      "artifacts": ["*.exe", "*.dll"],
      "timestampUrl": "http://timestamp.digicert.com",
      "verify": "signature",
      "failOnError": true
    }
  }
}
```

| `tool` | Signs with | Needs |
|---|---|---|
| `powershell` | `Set-AuthenticodeSignature` | nothing (ships with PowerShell) |
| `signtool` | Windows SDK `signtool.exe` + a `.pfx` | Windows SDK on PATH |
| `external` | any command line that signs one file | the command; `{file}` is replaced with the artifact path |

`verify` selects the bar: `valid` (the chain must be trusted — a CA certificate),
`signature` (the file only has to carry a signature — a self-signed certificate the
client machines trust), `none`. The certificate password is never read from the config
file: it comes from the environment variable named by `certificatePasswordEnv`.

`security.artifactSign` stays the owner of **container / OCI** signing (cosign,
notation); the two sections never overlap.

### Signing with a real CA (Azure Artifact Signing)

A self-signed certificate does **not** satisfy SmartScreen: the "Windows protected your
PC" prompt is the Application Reputation service, not the certificate chain, and a
self-signed certificate has no reputation with Microsoft. For a downloadable artifact the
signature has to come from a CA in the Trusted Root Program. Azure Artifact Signing is the
cheapest fully automatic option (the client machines install nothing):

```json
{
  "security": {
    "peSign": {
      "enabled": true,
      "tool": "external",
      "externalCommand": "C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\signtool.exe",
      "externalArguments": "sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib \"C:\\Program Files (x86)\\Microsoft Artifact Signing Client\\x64\\Azure.CodeSigning.Dlib.dll\" /dmdf \"C:\\signing\\metadata.json\" {file}",
      "artifacts": ["*.exe"],
      "verify": "valid",
      "failOnError": true
    }
  }
}
```

The argument template is split quote-aware and re-quoted for the native command, so a
path with spaces stays one argument. `metadata.json` carries the Artifact Signing
endpoint, account and certificate profile; the signing itself happens in Microsoft's
cloud, so no private key ever reaches the build agent.

## Pipelines (Config-Driven)

The build pipeline is a sequence of named steps. By default gbuild supplies a
built-in pipeline (`RegisterPlugins` → `ScanProject` → `Preflight` → `AffectedScan`
→ `Build` → `SecurityScan` → `AutoTune` → `SupplyChain` → `SastScan` → `PolicyCheck`
→ `SiemExport` → `StandaloneBundle` → `PublishArtifact`). You can override it entirely
from config:

> **Warning:** when `build.pipeline.steps` is **non-empty**, it **replaces** the
> built-in pipeline. Only list steps you implement yourself.

```json
{
  "build": {
    "pipeline": {
      "maxRetries": 1,
      "steps": [
        {
          "name": "RegisterPlugins",
          "script": "Register-Plugins -State $State",
          "retry": 1
        },
        {
          "name": "ScanProject",
          "script": "param($ctx) $ctx.csproj = Find-Project -State $State"
        },
        {
          "name": "CustomAudit",
          "script": "param($ctx) Invoke-Audit -ProjectDir $ctx.projectDir",
          "when": "param($ctx) [bool]($ctx.csproj)"
        },
        {
          "name": "Build",
          "script": "Invoke-GuildChoice -Choice '2' -MenuConfig (New-GuildMenuConfig -ProjectType $ctx.projectType -OS $State.OS -State $State) -State $State -ProjPath $ctx.projPath -ProjectDir $ctx.projectDir -ProjectType $ctx.projectType"
        }
      ]
    }
  }
}
```

Step fields: `name` (required), `script` (required — scriptblock body, receives
`$ctx`), `when` (optional condition scriptblock returning a bool; `false` skips
the step and fires `EVT_STEP_SKIPPED`), `retry` (optional int), `timeoutSeconds`
(optional int), `jobIsolated` (optional bool, default `false`).

**Timeouts, honestly.** Without `jobIsolated`, `timeoutSeconds` is enforced as an
SLA measured *after* the step body returns: a step that hangs will hang the
pipeline, and the breach is only reported afterwards. With
`"jobIsolated": true` (which **requires** `timeoutSeconds` on the same step),
the body runs in a background child process: when the timeout elapses the child
is killed and the attempt fails with `StepTimeout`, then retries normally.
Job steps run against a deserialized copy of `$ctx` (merged back on success)
and a read-only snapshot of `$State`, so a step that depends on the caller's
live session must stay in-process. In YAML the key is `job: true`.

`build.pipeline.mode` selects how config steps combine with the built-in ones:
`replace` (default, config steps only), `merge` (override same-named built-in steps
in place and append new ones), or `append` (built-in steps first, then config steps).

### YAML Pipeline Definitions (`gbuild.pipeline.yml`)

`Modules/YamlPipeline.psm1` + `Modules/Orchestrator.psm1` (`Resolve-PipelineSteps` /
`Resolve-PipelineYamlSteps` / `Invoke-GuildPipeline`) provide pipeline-as-code. When a
pipeline file is present it takes **precedence** over `build.pipeline.steps`.

```yaml
name: gbuild-pipeline
trigger: manual
version: "1.0"

env:
  BUILD_CONFIG: Release

steps:
  - step: ScanProject
    task: ScanProjectTask
    timeout: 60

  - step: Build
    task: BuildTask
    timeout: 600

  - step: Deploy
    task: DeployTask
    timeout: 300
    when: "($ctx.buildAttempted -and $ctx.buildOk)"
```

Each `task:` is a PowerShell command invoked as `& <task> $ctx`; the optional `when:`
expression is evaluated against `$ctx` and skips the step when false. See
`_Build/gbuild.pipeline.yml` for the shipped example.

**Discovery** — first hit wins:

1. `build.pipeline.file` (relative to the build root unless rooted)
2. `gbuild.pipeline.yml` in the project root

Discovery deliberately does **not** look in `ScriptRoot` (the `_Build` install
directory ships the file as an example, so reading it there would replace the built-in
pipeline for every project on the machine) and does **not** walk up parent directories.

**Supported YAML subset.** Block mappings and sequences, plain/`'single'`/`"double"`
scalars, `#` comments, `---`/`...` markers, and flow sequences of scalars (`[a, b]`).

Rejected with a **parse error** rather than silently misread: anchors/aliases/merge
keys, block scalars (`|`, `>`), tags, tab indentation, and nesting deeper than one
level inside a sequence item. A step with an unknown key, a missing `task`, a
non-numeric `timeout` or an unparseable `when` fails the build. Multi-line
PowerShell belongs in `build.pipeline.steps`, which takes real script bodies.

> **Note:** `timeoutSeconds` without job isolation is enforced as an SLA measured
> after the step body runs, not as a preemptive kill. A step that hangs will
> hang the pipeline. Mark the step `"jobIsolated": true` (config) or `job: true`
> (YAML, requires `timeout:`) for a real kill.

### Affected-Project Detection (Nx-style)

`build.affected` enables an `AffectedScan` pipeline step that fingerprints each
project (content hash, stored by the normal build-cache write-path) and combines
it with `git status`/`git diff` to report which projects actually need building:

```json
{
  "build": {
    "affected": {
      "enabled": true,
      "skipUnchanged": false
    }
  }
}
```

- `enabled` — run the scan (report only by default; harmless in CI).
- `skipUnchanged` — when `true`, unchanged projects are dropped from the parallel
  build list (single-project builds still run their normal cache check).

## Preflight (Auto Before Build)

Preflight runs **automatically** before every build. It validates:

| Check | What it catches |
|-------|-----------------|
| **Syntax** | PowerShell parse errors, C#/F#/VB bracket balance, XML well-formedness, JSON malformation |
| **Manifest** | Unparseable `*.csproj`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `Dockerfile`, `CMakeLists.txt`, etc. |
| **Tools** | Missing CLI tools (`dotnet`, `node`, `cargo`, `go`, `mvn`, `docker`...) |
| **Disk space** | Insufficient free space (default: 2 GB) |
| **Network** | Unreachable endpoints (if configured) |
| **Plugin-specific** | Language-level rules from each plugin (`cargo check`, `npm install`, `composer validate`...) |

If preflight fails, build **stops immediately** with a clear error report. Warnings do not block build unless configured otherwise.

Disable preflight entirely:

```json
{
  "build": {
    "preflight": {
      "enabled": false
    }
  }
}
```

## Supported Platforms

| OS | Runtime | Entry |
|----|---------|-------|
| **Windows** | PowerShell 5.1+ (built-in) | `gbuild.ps1` |
| **WSL / Linux** | `pwsh` (PowerShell Core) | `gbuild` (POSIX launcher) |
| **macOS** | `pwsh` (brew install) | `gbuild` (POSIX launcher) |

### Installing PowerShell on Unix

```bash
# Ubuntu / Debian
sudo apt install powershell

# Fedora / RHEL
sudo dnf install powershell

# macOS
brew install --cask powershell
```

## Quick Reference

```powershell
# Embedded mode
.\_Build\gbuild.ps1
.\_Build\gbuild.ps1 -Incremental
.\_Build\gbuild.ps1 -Clean
.\_Build\gbuild.ps1 -GitHub
.\_Build\gbuild.ps1 -Security
.\_Build\gbuild.ps1 -Distributed
.\_Build\gbuild.ps1 -SyntaxCheck

# Portable / USB
G:\tools\_Build\gbuild.ps1 -Project E:\my-project
G:\tools\_Build\gbuild.ps1 -Project E:\my-project -Incremental

# Global shortcut (after Install-GBuild.ps1)
gbuild
gbuild -Project E:\my-project
gbuild -Incremental
gb
```

## Key Features

| Feature | Module | Description |
|---------|--------|-------------|
| SDK auto-discovery | SDK.psm1 | Finds dotnet/java/android SDKs (6-strategy waterfall) |
| Smart clean | Clean.psm1 | Safely removes bin/obj/cache |
| Parallel build | Parallel.psm1 | Runspace pool for multi-project (config MaxJobs) |
| Build cache | Cache.psm1 | Content-addressable, single-hash, remote (S3/Azure) |
| Live progress | BuildProgress.psm1 | Single-line heartbeat + classifier (no spam) |
| Build constants | BuildConstants.psm1 | Single source of truth (no hardcode) |
| Path utils | PathUtils.psm1 | Portable path helpers (no hardcode) |
| Plugin system | Loader.psm1 | 13 language plugins (Dotnet, Node, Python, Rust, Java, Go, Docker, Ruby, PHP, Cpp, Avalonia, Elixir, Swift) |
| Preflight validation | Preflight.psm1 | Cross-language checks before build (21 checks) |
| Interactive menu | Menu.psm1 | 30+ build options + utilities |
| Health check | HealthCheck.psm1 | Validates SDK/disk/network/ports |
| Security scan | Security.psm1 | Secret detection + vulnerability check (SAST) |
| Hot reload | HotReload.psm1 | dotnet watch integration (process-tree) |
| Cross-platform | Environment.psm1 | Windows/Linux/macOS/WSL support |
| Credential vault | CredentialVault.psm1 | AES-256-CBC + PBKDF2, tenant-scoped |
| Distributed build | Distributed.psm1 | Multi-host builds via SSH + circuit breaker |
| Pipeline runner | Orchestrator.psm1 (pipeline engine, formerly PipelineRunner.psm1) | Retry, timeout, cancellation, circuit breaker |
| DI container | Container.psm1 | Singleton/transient services |
| Observability | Metrics.psm1 | Prometheus + OTLP protojson |

## Advanced

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `GBUILD_PROJECT` | Default project root when `-Project` is omitted |
| `GBUILD_PORT` | Launcher port (default: 5000) |
| `DOTNET_ROOT` | Override dotnet SDK location |
| `ANDROID_HOME` | Android SDK root |
| `JAVA_HOME` | JDK location |
| `GPG_KEY` / `GPG_PASS` | Code signing (release mode) |

### Hooks

Place scripts in `_Build/Hooks/`:

- `pre-build.ps1` — runs before build starts
- `post-build.ps1` — runs after successful build
- `pre-deploy.ps1` — runs before deploy
- `post-deploy.ps1` — runs after deploy

### Cache

- Local cache: `.gbuildcache/` (auto-managed)
- Remote cache: Azure Blob Storage or AWS S3 (configure in `gbuild.config.json`)
- Cache is keyed by project file hash + TFM + configuration

### CI/CD

```yaml
# Example: GitHub Actions
- name: Build
  run: |
    if [ -f "_Build/gbuild" ]; then chmod +x _Build/gbuild; fi
    ./_Build/gbuild -GitHub -Incremental
```

## Troubleshooting

**PowerShell execution policy blocks `.ps1` on Windows:**
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**`pwsh` not found on Linux/macOS:**
```bash
# Ubuntu/Debian
sudo apt install powershell

# macOS
brew install --cask powershell
```

**Project not detected:**
- Ensure one of the marker files exists (`*.csproj`, `package.json`, `Cargo.toml`, etc.)
- Use `-Project <absolute-path>` for explicit override

**Build tool on USB is slow:**
- Copy `_Build/` to a local drive for frequent use
- Enable build cache in `gbuild.config.json` to speed up repeated builds
 
