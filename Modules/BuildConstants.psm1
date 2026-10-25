# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# ========================================================================
# BuildConstants.psm1 — Single source of truth for build defaults
# ========================================================================
# Centralizes magic numbers and default values that were previously
# hardcoded across multiple modules. Modules should reference these
# constants instead of duplicating values.
# ========================================================================

$script:BuildDefaults = @{
    # Disk space
    MinDiskMB               = 2048
    MaxCacheSizeMB          = 2048

    # Required CLI tools (health.requiredTools / before-build hook)
    DefaultRequiredTools    = @('dotnet', 'git')
    # Optional CLI tools probed by health checks (single source, config-overridable)
    DefaultOptionalTools    = @('node', 'npm', 'java', 'javac', 'adb', 'gh', 'docker', 'keytool')

    # Ports
    DefaultPort             = 5000
    DefaultPorts            = @(5000, 5001, 7000, 7001, 8080, 8443)
    MetricsPort             = 9100
    SyslogPort              = 514
    SshDefaultPort          = 22

    # Timeouts (ms unless noted)
    NetworkTimeout          = 15     # seconds (health.networkTimeout)
    ExeTimeoutMs            = 5000
    RetryBaseDelay          = 500
    RetryMaxDelayMs         = 10000
    ConnectTimeoutSec       = 30
    SdkRootHomeFallback     = '/root'  # fallback home dir when $env:HOME unset (SDK.psm1:300)
    WebProbeTimeoutMs       = 700  # HTTP probe timeout for web deploy (Deploy.psm1:Test-UrlServing)
    ExecutionTimeoutSec     = 600
    JobTimeoutSec           = 600
    DeployTimeoutMs         = 30000
    KubectlRolloutTimeoutSec = 120
    CachePushTimeoutSec     = 120
    CachePullTimeoutSec     = 120
    CacheHeadTimeoutSec     = 30
    CacheListTimeoutSec     = 60
    WebhookTimeoutSec       = 10
    DeployHealthTimeoutSec  = 10
    PreflightNetTimeoutSec  = 5

    # Delays (ms)
    PortWaitDelayMs         = 1000
    AdbUninstallDelayMs     = 800
    AdbDaemonRestartDelayMs = 600
    AdbInstallRetryCount    = 2
    AdbInstallRetryDelayMs  = 1200
    AdbAutoConnectEndpoints = @('127.0.0.1:5555', '127.0.0.1:5556', '127.0.0.1:5557', '127.0.0.1:7555', '127.0.0.1:21503', '127.0.0.1:62001', 'localhost:5555')
    WebAppLaunchDelayMs     = 250
    WebAppLaunchDelayMinMs  = 100
    WebAppReadyPortProbe    = $true
    HotReloadPollMs         = 200
    DistributedPollMs       = 100
    DeployHealthRetryMs     = 2000
    SiemUdpMaxBytes         = 60000

    # Retry
    MaxRetries              = 3
    HistoryWriteMaxAttempts = 3
    HistoryWriteRetryDelayMs = 100
    # Matches Enter-BuildFileLock's measured budget: under parallel-suite load
    # 5s proved too short (a 43s AutoTuner safety window timed out), so the
    # owner default is 15s. This key is the registry mirror of that decision;
    # callers must NOT pass their own literal (see ModuleBootstrap).
    HistoryLockTimeoutMs    = 15000
    CircuitBreakerThreshold = 5
    CircuitBreakerResetMs   = 60000
    PortWaitAttempts        = 20
    WebReadinessAttempts    = 30
    WebAppLaunchMaxAttempts = 3

    # Clean retry (Clean.psm1 Invoke-Retry — progressive backoff in SECONDS via Pow(2,i),
    # different semantics from ms-based errorHandling.baseDelayMs, so NOT mapped to errorHandling.*)
    CleanRetryAttempts      = 3
    CleanRetryDelayBaseSec  = 1

    # Domain-specific retry/limits — kept separate so they are not conflated with the generic MaxRetries
    AuditContextLines       = 1     # Security.Find-SecretsInFile context lines around a secret match
    DeployHealthRetries     = 3     # Test-DeployHealth probe retries (overridden by deploy.health.retries)
    ChangelogCommitCount    = 20    # New-Changelog git log depth (overridden by versioning.commitCount)
    CachePresignExpiresSec  = 3600  # S3 presigned URL expiry (overridden by build.cacheRemote.presignExpiresSeconds)

    # Per-domain search depths — do NOT share SdkDefaultSearchDepth (different semantics)
    LangDetectDepth         = 5     # LanguageDetector build-file scan (Get-DetectedLanguages)
    ProjectSearchDepth      = 5     # Project discovery csproj/sln (config.projects.*)

    # Primary-language tie-break order with equal detection scores (Get-PrimaryLanguage)
    PrimaryLanguagePriority = @('Avalonia', 'C#', 'F#', 'VB.NET', 'TypeScript', 'Node.js', 'Python', 'Rust', 'Java', 'Kotlin', 'Scala', 'Go', 'Ruby', 'PHP', 'C/C++', 'C', 'Swift', 'Elixir', 'PowerShell', 'Docker')

    # Cache
    CacheMaxEntries         = 256
    CacheMaxAgeDays         = 30
    CacheMaxSizeMb          = 512
    CacheEvictTargetRatio   = 0.8
    # Short hash display length (cache keys, restore dirs) + hash scan depth
    ShortHashLength         = 8
    CacheHashSearchDepth    = 5
    # Plugin incremental cache hash length (Loader plugin-build keys, 12 hex chars).
    # Distinct from ShortHashLength (8, .NET cache display) — different collision
    # budget for per-directory plugin fingerprints.
    PluginCacheHashLength   = 12
    # CorrelationId short-guid length (Initialize-BuildIdentity).
    CorrelationIdLength     = 12
    # Deploy choice BuildArgs single-source (was literals in Invoke-GuildChoice).
    # Config-overridable via build.deployChoiceArgs.* so MSBuild args change
    # without code edits.
    DeployChoiceArgsApk     = @('-p:AndroidPackageFormat=apk')
    DeployChoiceArgsIos     = @('-p:ArchiveOnBuild=true')
    DeployChoiceArgsWinMsix = @('-p:WindowsPackageType=None','-p:PublishSingleFile=false','--self-contained','true')
    DeployChoiceArgsAot     = @('-p:PublishAot=true','--self-contained','true')
    DeployConsoleSelfContained = 'true'
    DeployDefaultRid        = 'win-x64'
    # GitHub CI trigger single-source (was literals in Invoke-GuildChoice '13').
    CiWorkflowFile          = 'build.yml'
    CiPackageFormatNonInteractive = 'aab'
    CiPackageFormatInteractive = 'apk'
    CiDefaultBranch         = 'main'

    # Log / output directory names
    LogsDir                 = 'logs'

    # Log
    MaxLogFiles             = 5
    MaxLogSizeMB            = 10
    AuditLogMaxSizeMB       = 10
    # Age ceiling for per-run build_*.log retention (Invoke-LogRetention). The
    # file-count cap alone never removed an old-but-fewer-than-N file, so a
    # workspace building once a day accumulated logs forever.
    LogMaxAgeDays           = 30
    # Scoped pipeline logging: collapse disabled-step noise into one summary
    # line so each build only shows logs relevant to its own project type.
    LogScopedLogging        = $true
    # Reveal the publish-output folder after a successful build. Explicit
    # build.openOutput=true/false always wins; when unset, interactive dev
    # sessions open it and CI stays quiet (see Resolve-BuildOpenOutput).
    OpenOutput              = $false

    # Logging bootstrap (Logging.psm1 LogConfig snapshot; logging.* in config overrides these).
    # Values must MATCH gbuild.config.json so the parity test (BuildConstants.Tests.ps1) passes.
    LogFileRetryAttempts    = 3
    LogFileRetryDelayMs     = 1000

    # Logging UI presentation constants (console layout — not config-driven,
    # single-sourced here instead of literals scattered across Logging.psm1).
    LogMinWindowWidth       = 80
    LogMaxWindowWidth       = 120
    LogDefaultWindowWidth   = 100
    LogContentWidthRatio    = 0.60
    LogProgressBarWidth     = 20
    LogBoxPadSmall          = '   '
    LogBoxPadLarge          = '      '
    LogSeparatorChar        = '-'

    ParallelMaxJobs         = 8
    ParallelMaxJobsMin      = 1
    ParallelMaxJobsMax      = 16
    ParallelSearchMaxDepth  = 3
    ParallelProgressPollMs  = 200
    ParallelMaxJobsScaleFactor = 4
    EnableParallelBuild     = $true
    # Distributed per-host concurrency floor (single source, config-overridable)
    DistributedMinConcurrent = 1
    # Level 5 scale guards: global runspace-pool ceiling (backpressure for
    # 10+ hosts), batched SSH probing, per-task retry. Distinct semantics —
    # never reuse generic MaxRetries/Timeout keys for these domain values.
    DistributedMaxTotalConcurrency = 64
    DistributedProbeBatchSize = 8
    DistributedTaskMaxRetries = 2
    # Project-root auto-detect walk depth (Find-ProjectRoot MaxDepth)
    ProjectRootMaxDepth     = 10
    # Project marker file patterns for auto-detection (single source for gbuild.ps1 and Find-ProjectRoot)
    # CANONICAL project-root markers = the union of every BuildFile in
    # LanguageDetector's languageMap and every ManifestFiles entry declared by
    # the shipped plugins. Previously this list held 13 entries and omitted
    # Gemfile, composer.json, mix.exs, Package.swift, Makefile, build.sbt,
    # setup.py and setup.cfg - i.e. it could not recognise a root for 7 of the
    # 14 shipped plugins. Because PathUtils.Resolve-BuildProjectRoot runs
    # BEFORE anything is written, a pure-Ruby / PHP / Elixir / Swift / C
    # / Scala repository had no marker, the upward walk silently resolved an
    # unrelated ancestor, and .gbuild-state.gbuildstate + .gbuildcache/ +
    # build-reports/ were written there. Get-ProjectMarkers now unions this
    # with the live language map and the live plugin manifests, so the two
    # tables can never diverge again.
    #
    # DELIBERATELY EXCLUDED: '*.psm1' and '*.ps1'. The PowerShell plugin accepts
    # them as ManifestFiles (needed so test/lint dispatch can resolve a project
    # file for a script project), but they are NOT credible project-root
    # markers: a PowerShell "project" is simply a directory of scripts, so
    # almost any scratch/tooling/staging directory satisfies them. Including
    # them made Test-BuildProjectMarker return $true for a temp directory
    # containing a single stray script, which re-introduces exactly the
    # "resolves an unrelated ancestor and writes build output there" class of
    # bug this list exists to prevent. Root detection therefore requires an
    # unambiguous project MANIFEST; loose per-file dispatch patterns stay in
    # the plugin metadata where they belong.
    ProjectMarkers          = @('*.csproj','*.fsproj','*.vbproj','*.sln','package.json','Cargo.toml','go.mod','pyproject.toml','setup.py','setup.cfg','pom.xml','build.gradle','build.gradle.kts','build.sbt','CMakeLists.txt','Makefile','Gemfile','composer.json','mix.exs','Package.swift','Dockerfile')
    # Patterns a project should ignore when using gbuild. Single source (not scattered).
    # Overridable via config 'project.gitignorePatterns'.
    ProjectGitignorePatterns = @('_Build/','_Sync/','.gbuild/','.gbuildcache/','.gbuild-state.gbuildstate','*.gbuildstate','.gbuild-circuitbreaker.gbuildstate','*.lock','build-reports/','distributed-report/','reports/','logs/','publish-output/','TestResults/','Tests/TestResults/','test-results*.xml','testResults.xml','suite-progress-*.log','Tests/suite-progress-*.log','vault.key','*.vault.key','*.vault.salt','*.salt','gbuild-standalone-*/','nul*')
    # Generic filesystem walk bound ("effectively unbounded" sentinel) + depth error sentinel
    CompatibleChildItemMaxDepth = 2
    RelativeDepthErrorSentinel = 999999

    ProgressThrottleMs      = 300
    ProgressEnabled         = $true
    ProgressElapsedSec      = 5
    ProgressPollMs          = 100
    # Clamp bounds for the effective poll interval + final-drain floor (ms).
    ProgressPollClampMinMs  = 50
    ProgressPollClampMaxMs  = 200
    ProgressFinalDrainMs    = 120
    # Kill-wait bound after Kill() in BuildProgress (ms). Separate from ExeTimeoutMs
    # (full exe timeout) — Level 5: distinct semantics get distinct keys.
    ProgressKillWaitMs      = 5000

    ProfileInheritanceMaxDepth = 10
    TestEnabled                = $true
    # Default OFF: the shipped gbuild.config.json explicitly sets
    # build.test.lintEnabled=false, and the menu treats Lint ('I') as a
    # separate opt-in step from Test ('T'). Lint can hard-fail a build and
    # most lint toolchains are absent on a fresh machine, so a standalone
    # import (no config) must not run lint during the test phase either.
    # Fixed 2026-10: the stale $true default disagreed with the shipped
    # config and tripped the parity gate; aligned in data, not exempted.
    TestLintEnabled            = $false
    PreflightCheckTools        = $true
    PreflightCheckModuleGraph  = $true
    TelemetryEnabled           = $true
    TelemetryOtelEnabled       = $true

    # MSBuild parallel build arguments (configurable via build.msBuildParallelArgs)
    MsBuildParallelArgs = @("-p:BuildInParallel=true", "-m")

    # Alerting
    WebhookTokenRotationHours = 24
    WebhookTokenByteLength  = 24
    # JSON serialization depths (single source; deep variant for SBOM/provenance/OTLP)
    # Shallow=6 covers summary/error payloads (5-6), Health=8 covers health/SIEM
    # canonical forms. Protocol depths (SARIF 10, OTLP 10, ledger anchor 6,
    # orchestrator dump 100) keep their literal with a comment pointing here
    # so a global tune does not silently break a spec.
    JsonDefaultDepth        = 10
    JsonDeepDepth           = 20
    JsonShallowDepth        = 6
    JsonHealthDepth         = 8
    # Timestamp formats (single source; kinds are documented on Get-BuildTimestamp).
    TimestampFileStamp      = 'yyyyMMdd_HHmmss'
    TimestampRotationStamp  = 'yyyyMMdd-HHmmss'
    TimestampImageTag       = 'yyyyMMddHHmm'
    TimestampDisplay        = 'yyyy-MM-dd HH:mm:ss'
    TimestampDate           = 'yyyy-MM-dd'
    TimestampRoundTrip      = 'o'
    # Live-progress excerpt truncation + collected-lines cap
    ProgressExcerptMaxLength = 100
    ProgressMaxCollectedLines = 100

    # Security / CredentialVault (NIST: PBKDF2 >= 100K iterations)
    VaultPbkdf2Iterations   = 100000
    # PBKDF2 iteration FLOOR for the credential vault. This was 1000 while the
    # code hard-required >= 100000 in three places, so the table contradicted
    # its own enforcement. Get-VaultPbkdf2Iterations now derives the floor from
    # this key and raises it to the working iteration count if they disagree.
    VaultMinIterations      = 100000
    # Salts must NEVER be shared literals: CredentialVault resolves them
    # config/env-first, then a per-deployment random salt file (auto-generated
    # on first run). Empty defaults here are intentional - see Get-VaultSalt.
    VaultStaticSalt         = ''
    VaultMachineSalt        = ''
    # AEAD / DPAPI shape (Single source: previously two literal sites inside
    # CredentialVault - nonce/tag/AAD/keyLen). Changing AesPurposeUtf8
    # retro-breaks all DPAPI-protected blobs; treat as frozen unless re-keying
    # every vault file.
    VaultNonceSize          = 12
    VaultTagSize            = 16
    VaultAssociatedDataUtf8 = 'gbuild-vault-v2'
    VaultAesPurposeUtf8     = 'gbuild-vault-aead'
    VaultKeyLengthBytes     = 32
    # NOTE: only tool-owned dirs are excluded by default ('_Build' + build
    # artifacts). Generic host-owned names ('_Sync', '_Tests', '_Launch', ...)
    # are deliberately NOT listed: this tool is portable/embedded, and claiming
    # generic names would silently skip the host project's real source from
    # secret scanning. Hosts declare their own extras via security.excludeDirs.
    SecurityExcludeDirs     = @('bin', 'obj', 'node_modules', '.git', 'publish-output', '.gbuildcache', 'build-reports', 'wwwroot/lib', 'packages', 'TestResults', '_Build')
    # L5 CI posture: non-interactive runs deny privileged actions unless an
    # explicit allow-list (security.allowedActions / tenants) or full RBAC is
    # configured. Read-only actions stay available for diagnostics.
    RbacEnforceInCI           = $true
    RbacCiReadOnlyActions     = @('D', 'H', 'R')
    # Actions that mutate state outside the build output tree (deploy targets,
    # security scan, cache maintenance, changelog, cloud CI trigger). Single
    # source of truth for the privileged set: Orchestrator gates on it and
    # Menu.psm1 greys out entries the allow-list denies, so the UI can never
    # advertise an action that Test-ActionAllowed will reject.
    # N (menu.promote) is a DEPLOY action and is privileged: promoting
    # staging -> production changes a live environment. It was absent here while
    # the two fallbacks in RBAC.Get-RbacPrivilegedActions (moved from Orchestrator 2026-10) disagreed
    # (10 keys with N, 14 keys with N, this one with 13 and without N), so the
    # effective answer depended on which branch ran.
    RbacPrivilegedActions     = @('A','B','V','G','P','F','E','K','Y','N','S','L','C','13')
    BuildKillProcesses      = @('dotnet', 'iisexpress')
    HotReloadProcessName    = 'dotnet'
    SecretScanMaxFileMB     = 5
    SecretMatchPreviewLength = 50
    SecurityManifestSearchDepth = 2
    SecurityLicenseSearchDepth = 4
    SecurityScanDepth       = 2

    # Infra verification (verification.connectTimeout / verification.requestTimeout)
    VerificationConnectTimeoutSec = 10
    VerificationRequestTimeoutSec = 5

    # Android — debug keystore + default ApplicationId (single source of truth).
    # SECURITY NOTE (Level 5): AndroidDebugStorePass/KeyPass='android' are the
    # PUBLIC Android SDK debug-keystore defaults (same as `keytool -genkey`
    # debug values), NOT real secrets — safe to centralize here. Release signing
    # MUST come from signing.properties / android.keystore config / env
    # $env:GBUILD_ANDROID_STORE_PASS / $env:GBUILD_ANDROID_KEY_PASS (never committed).
    # The standard Android debug keystore uses a fixed DN/alias/password; these
    # are centralized here so they are not scattered as literals across Android.psm1
    # and Build.psm1. Real values come from signing.properties or the
    # android.keystore config section; secrets can also be supplied via
    # $env:GBUILD_ANDROID_STORE_PASS / $env:GBUILD_ANDROID_KEY_PASS.
    AndroidDefaultApplicationId = 'com.companyname.app'
    AndroidDebugAlias           = 'androiddebugkey'
    AndroidDebugStorePass       = 'android'
    AndroidDebugKeyPass         = 'android'
    AndroidDebugDname           = 'CN=GBuild Debug, O=Development, C=VN'
    AndroidDebugKeySize         = 2048
    AndroidDebugValidityDays    = 10000

    # Console glyphs (single source). Emoji are auto-converted to ASCII on PS5.1
    # by Logging's EmojiMap; keeping them centralized allows them to be rethemed
    # without touching call sites.
    Glyphs = @{
        error   = '❌'
        warn    = '⚠️'
        ok      = '✔'
        gear    = '⚙️'
        package = '📦'
    }

    # Directory names — single source for paths used across multiple modules
    PublishOutputDir        = 'publish-output'
    CacheDir                = '.gbuildcache'
    ReportOutputDir         = 'build-reports'

    # SDK — DefaultTfm is a fallback only; the build system detects the real TFM
    # from the project's <TargetFramework>(s)</TargetFrameworks> at runtime.
    SdkMajorMin             = 8
    DefaultTfm              = 'net8.0'
    # Default build configuration (build.defaultConfiguration in config overrides).
    DefaultConfiguration    = 'Release'

    # Build identity — single source of truth for the gbuild version string.
    # Used by the OTLP metrics service.version, the config schema expected
    # version, and the SBOM tool version. Bump here to change all three at once.
    Version                 = '2.0.0'

    # Plugin SDK — formal plugin manifest + versioning API (PluginSDK.psm1).
    # SdkApiVersion is the CURRENT plugin contract version: bump MAJOR on
    # breaking changes, MINOR on additive changes. ManifestSuffix is the
    # sidecar file name convention (<Name>.plugin.json). DefaultVersion is the
    # synthesized version for legacy plugins without a manifest file.
    PluginSdkApiVersion     = '1.0.0'
    PluginManifestSuffix    = '.plugin.json'
    PluginDefaultVersion    = '1.0.0'

    # SDK discovery — standard install-location fallbacks (single source, configurable)
    SdkDotnetMac           = '/usr/local/share/dotnet'
    SdkDotnetLinux         = '/usr/share/dotnet'
    SdkDotnetWindowsSub    = 'dotnet'
    SdkJvmMac              = '/Library/Java/JavaVirtualMachines'
    SdkJvmUnix             = @('/usr/lib/jvm', '/usr/local/lib/jvm')
    SdkAndroidLinux        = '/opt/android-sdk'
    # Per-platform ADB priority roots (Find-AdbPath) — previously hardcoded in Android.psm1
    SdkAndroidMac          = '/usr/local/share/android-sdk'
    SdkAndroidDebian       = '/usr/lib/android-sdk'
    SdkAndroidWindowsLocalSub = 'Android/Sdk'
    SdkAndroidWindowsProgramSub = 'Android/android-sdk'
    SdkAndroidHomeMacSub   = 'Library/Android/sdk'
    SdkAndroidHomeLinuxSub = 'Android/Sdk'
    AndroidAdbRelativeWin  = 'platform-tools/adb.exe'
    AndroidAdbRelativeUnix = 'platform-tools/adb'
    # Platform-tools directory leaf name (single source for Android.psm1/HealthCheck.psm1).
    PlatformToolsDirName   = 'platform-tools'
    # JDK javac relative paths (single source for HealthCheck.psm1 Test-JavaJdk).
    JdkJavacRelativeWin    = 'bin/javac.exe'
    JdkJavacRelativeUnix   = 'bin/javac'
    # Android cmdline-tools relative path (single source for SDK.psm1 default).
    # Overridable via sdk.androidCmdLineToolsRelPath config (Update-AndroidSdkConfig).
    AndroidCmdLineToolsRelPath = 'cmdline-tools/latest/bin'
    # Loopback address for port-bind probes (single source for Environment Test-PortBindable).
    LoopbackAddress        = '127.0.0.1'
    # Removable-media mount roots scanned by Get-AvailableDrives. The classic
    # /mnt-only scan missed udisks/systemd mounts under /media and /run/media.
    OsRemovableMountRoots  = @('/mnt', '/media', '/run/media')
    OsMacOSVolumeRoot      = '/Volumes'
    # Stable machine-identity sources for Locale.Get-DeviceId. These are OS
    # facts rather than tunable settings; centralizing them keeps the registry
    # path and machine-id candidates from drifting across identity consumers.
    OsMachineGuidRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
    OsMachineGuidValueName    = 'MachineGuid'
    OsMachineIdPaths          = @('/etc/machine-id', '/var/lib/dbus/machine-id')
    # Canonical tool binary names (single source for PATH-lookup fallbacks).
    DotnetToolName         = 'dotnet'
    TrivyToolName          = 'trivy'
    AdbToolName            = 'adb'
    # ADB connect timeout (ms) — single source for Get-AdbDevices auto-connect probes.
    # Low default (2000) so scanning 7 endpoints takes ~14s max instead of minutes.
    AdbConnectTimeoutMs    = 2000
    # SAST: for dotnet list package --vulnerable, exit code != 0 with no findings
    # means "no vulnerable packages" (not a tool crash). Treat as Passed.
    SastDotnetIgnoreNoFindingsExitCode = $true
    # SDK priority-path directory leaf names (single source for SDK.psm1 closures).
    DotnetProjectFilters     = @('*.csproj', '*.fsproj', '*.vbproj')
    DotnetSolutionFilter      = '*.sln'
    SdkJavaDirName         = 'Java'
    SdkAndroidDirName      = 'Android'
    SdkDotnetDirName       = '.dotnet'
    SdkJvmMacSubDir        = 'Library/Java/JavaVirtualMachines'
    SdkPlatformToolsDirName = 'platform-tools'
    SdkBuildToolsDirName   = 'build-tools'
    # SDK auto-provision defaults (Find-SdkAutoProvision)
    SdkAutoProvisionInstallDir = '~/.dotnet'
    SdkAutoProvisionChannel    = 'LTS'
    SdkAutoProvisionVersion    = ''
    SdkAutoProvisionInstallerSha256 = ''
    # Provider release tracking (Get-LatestReleasedSdkVersion): the newest SDK
    # the vendor has actually published. Empty MaxKnown = unknown (offline).
    SdkReleaseMetadataBaseUrl = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata'
    SdkMaxKnownVersion        = ''
    SdkReleaseCacheHours      = 24
    SdkReleaseCacheFileName   = 'dotnet-release.json'
    SdkAndroidSdkDirName   = 'Sdk'
    SdkAndroidSdkLegacyDirName = 'android-sdk'
    SdkAndroidStudioDirName = 'Android Studio'
    # gbuild-specific SDK probe paths (Find-AdbPath Step 5) — previously hardcoded in Android.psm1
    SdkGbuildDotSdkAndroidSdk = '.sdk/android-sdk'
    SdkGbuildDotSdk          = '.sdk'
    SdkGbuildParentDotSdkAndroidSdk = '../.sdk/android-sdk'
    SdkJbrDirName          = 'jbr'
    # Clean targets (single source for Clean.psm1 Invoke-SmartClean).
    CleanTargetDirNames    = @('bin', 'obj', '.vs', '.idea', '.fleet')
    CleanOutputFolderNames = @('wwwroot', 'bin', 'obj', '_framework')
    CleanArtifactExtensions = @('.dll', '.exe', '.pdb', '.deps.json', '.runtimeconfig.json', '.xml', '.staticwebassets.runtime.json', '.so', '.dylib', '.apk', '.aab', '.msix', '.appxbundle', '.pkg', '.ipa', '.wasm', '.blat', '.dat', '.map')
    # Artifacts eligible for GPG signing (single source for Steps/sign-gpg.ps1).
    # This is a DIFFERENT question from CleanArtifactExtensions and cannot borrow
    # its list: sign-gpg used to hardcode @('.exe','.dll','.zip') inline, which
    # covers Windows and nothing else. On a Linux or macOS project it therefore
    # found no .so / .dylib / .jar / .tar.gz and signed almost nothing while
    # reporting success - the failure mode of a filter that silently excludes.
    # Signing targets are the deployable forms only; .pdb/.xml/.map are debug
    # or documentation output and are deliberately absent.
    SignArtifactExtensions = @(
        '.exe', '.dll', '.msi', '.msix', '.appx', '.appxbundle', '.zip', '.nupkg', '.snupkg', '.jar', '.war'
        '.so', '.dylib', '.a', '.o'
        '.apk', '.aab', '.ipa', '.pkg', '.app', '.wasm', '.deb', '.rpm'
    )
    # Fallback project short name when no root is available (single source for Get-ProjectShortName).
    DefaultProjectShortName = 'gbuild-project'
    # dotnet-install script endpoints (SDK auto-provision downloader)
    SdkInstallScriptUrlUnix = 'https://dot.net/v1/dotnet-install.sh'
    SdkInstallScriptUrlWin  = 'https://dot.net/v1/dotnet-install.ps1'
    SdkInstallScriptNameUnix = 'dotnet-install.sh'
    SdkInstallScriptNameWin = 'dotnet-install.ps1'
    SdkDownloadPageUrl     = 'https://dotnet.microsoft.com/download'
    # Protected install locations requiring elevation (single source, config-overridable)
    SdkProtectedPathPatterns = @('Program Files', 'Windows', '/usr/*', '/opt/*')
    # SDK exe search depth for Find-SdkByDirectory
    SdkExeSearchDepth      = 2

    # Non-Windows `ps` binary fallback locations (HotReload.Get-PsBinary) — used when
    # `ps` is not on PATH: most distros place it at /bin/ps, Alpine/busybox at /usr/bin/ps.
    PsBinaryFallbackPaths  = @('/bin/ps', '/usr/bin/ps')

    # SDK discovery depths + cache expiry (mirror sdk.* in gbuild.config.json).
    # Previously literals in class SdkConfig (SDK.psm1) — now single-sourced here.
    SdkCacheExpiryDays      = 90
    SdkDefaultSearchDepth   = 4
    SdkProjectScanDepth     = 3
    SdkParentScanDepth      = 2
    SdkWinSearchDepthDelta  = 3

    # Default SAST tool per language (single source of truth).
    # security.sast.tools in config overrides each key at runtime (Sast.psm1).
    # Covers every language emitted by LanguageDetector (18 unique) so no
    # detected project silently skips SAST.
    SastToolMap = @{
        'C#'         = 'dotnet'
        'F#'         = 'dotnet'
        'VB.NET'     = 'dotnet'
        'Avalonia'   = 'dotnet'
        'LinuxDesktop' = 'dotnet'
        'TypeScript' = 'npm'
        'Node.js'    = 'npm'
        'Python'     = 'bandit'
        'Rust'       = 'cargo-audit'
        'Java'       = 'mvn'
        'Kotlin'     = 'mvn'
        'Scala'      = 'mvn'
        'Go'         = 'gosec'
        'Ruby'       = 'brakeman'
        'PHP'        = 'phpcs'
        'C/C++'      = 'cppcheck'
        'C'          = 'cppcheck'
        'Swift'      = 'swift'
        'Elixir'     = 'mix'
        'Docker'     = 'trivy'
        'PowerShell' = 'psscriptanalyzer'
    }
    # Numeric rank for vulnerability severities (monotonic threshold comparisons).
    # Shared by Sast.psm1 and SupplyChain.psm1 container-scan gate (single source).
    # low=1, medium/moderate=2, high=3, critical=4; unknown/empty=0 (never blocks).
    VulnSeverityRank = @{
        'low'      = 1
        'medium'   = 2
        'moderate' = 2
        'high'     = 3
        'critical' = 4
    }
    # Default fail threshold rank (high=3) when security.sast.severityThreshold is unknown
    VulnDefaultFailRank     = 3
    SastFallbackTruncateLength = 500
    # Per-tool SAST execution timeout (seconds). 0 = no timeout (legacy).
    # dotnet list --vulnerable hits NuGet per package and can stall for minutes
    # on first restore / blocked network; without this the SastScan pipeline
    # step hangs forever inside Invoke-WithLiveOutput (no timeout there).
    SastTimeoutSec = 120

    # --- Tooling the platform ships itself -------------------------------------
    # The platform owns its scanners. PowerShell SAST needs PSScriptAnalyzer and
    # _Build ships it under .tools\Modules (Install-GBuild.ps1 downloads it once),
    # but nothing on the RUNTIME path ever put that folder on PSModulePath - only
    # the installer did, and only for the install location it happened to write.
    # A repo-local run (the documented portable usage, .\_Build\gbuild.ps1) then
    # resolved no analyzer, reported the tool missing and - with the default
    # tool-unavailable policy - failed the build, so a project was blocked for
    # code that had never been scanned and was told to install the tool itself.
    # These keys are the single source for the folder, the pinned version and the
    # cmdlet->module mapping; SharedUtils.Resolve-VendoredToolModule consumes
    # them so no caller carries a literal path or version.
    VendoredToolsDirName  = '.tools/Modules'
    ScriptAnalyzerVersion = '1.25.0'
    # Scanner cmdlet -> the module this platform bundles for it. Sast.psm1 and
    # Plugins\PowerShell.psm1 both ask for 'Invoke-ScriptAnalyzer'; this map is
    # the only place that knows the bundled module is named PSScriptAnalyzer.
    VendoredToolModuleMap = @{
        'Invoke-ScriptAnalyzer' = 'PSScriptAnalyzer'
    }
    # Scanners whose NON-ZERO exit code means "the report contains findings", not
    # "the tool failed". npm audit exits 1 whenever the audit report holds any
    # vulnerability, so treating its exit code as a tool failure returned early
    # and discarded the vulnerability list: a Node.js build reported "Tool exited
    # with code 1" with findings=0 and blocked on a security gate that had hidden
    # exactly what it exists to surface. Only the dotnet path had this carve-out
    # (SastDotnetIgnoreNoFindingsExitCode); this list is its single source.
    SastToolsExitCodeSignalsFindings = @('npm')
    # Input a scanner needs before it can produce a report at all. A project
    # without that file is not a scanner failure: `npm audit` cannot say anything
    # about a project that has no lockfile, so the step came back Failed with
    # findings=0 and blocked the build on a gate that had scanned nothing. Listed
    # scanners are reported Skipped (ToolInputMissing) instead, which
    # security.sast.toolUnavailablePolicy then judges like any other tool that
    # could not run - so the operator decides, with one knob, instead of the
    # platform inventing a finding-free block.
    SastToolRequiredInputs = @{
        'npm' = @('package-lock.json', 'npm-shrinkwrap.json')
    }

    # SDK blacklist dirs per platform (SDK.psm1 SdkConfig.BlacklistDirs — used for
    # SDK discovery scans; NOT to be confused with SecurityExcludeDirs used for secret scans).
    SdkBlacklistBase        = @('node_modules', 'bin', 'obj', '.git')
    SdkBlacklistWindows     = @('node_modules', 'bin', 'obj', '.git', '.vs', 'AppData', 'Program Files (x86)', 'Windows')
    SdkBlacklistMac         = @('node_modules', 'bin', 'obj', '.git', '.DS_Store')

    # Bind / base-URL defaults (no longer hardcoded in Metrics/Deploy/SupplyChain)
    MetricsBindAddress     = 'localhost'
    DeployBaseUrl          = 'http://localhost'
    OtlpMetricsPath        = '/v1/metrics'
    OtlpTracesPath         = '/v1/traces'
    OtlpJsonDepth          = 10
    # SIEM private enterprise number for [gbuild@<id> ...] structured data (RFC5424)
    SiemEnterpriseId       = 32473
    # Project version fallback when no version file/manifest exists (single source)
    DefaultProjectVersion  = '0.1.0'
    VersionSearchDepth     = 2
    # Standalone single-file bundle format version (not the gbuild tool version)
    StandaloneBundleVersion = '1.0.0'
    SupplyChainToolName    = 'gbuild'
    # Cache index format version (Cache.psm1 / CacheProvider.psm1 — single source)
    CacheIndexVersion      = '2.0'

    # AutoTuner hardcoded fallbacks (single-sourced here so config overrides work)
    AutoTuneDefaultParallelMax     = 8
    AutoTuneParallelCeiling        = 16
    AutoTuneCacheMaxEntriesDefault = 256
    AutoTuneCacheMaxSizeMbDefault  = 512
    AutoTuneDefaultTimeoutMinutes  = 30
    AutoTuneFailRateThresholdLow   = 0.1
    AutoTuneFailRateThresholdHigh  = 0.3
    AutoTuneAvgDurationThreshold   = 300
    AutoTuneTimeoutMultiplier      = 1.5
    AutoTuneTimeoutRatio           = 0.8
    AutoTuneIncrementalRatio       = 0.7
    # Level 5 closed-loop: verify + rollback + cache hit-rate tuning.
    # verifyEnabled = dry-check applied values before commit; rollbackEnabled =
    # keep in-memory backup for Undo-AutoTuneApply; hit-rate thresholds drive
    # real cache-size recommendations from samples (not placeholder defaults).
    AutoTuneVerifyEnabled          = $true
    AutoTuneRollbackEnabled        = $true
    AutoTuneCacheHitRateLow        = 0.5
    AutoTuneCacheHitRateHigh       = 0.9

    # AnomalyDetector hardcoded fallbacks
    AnomalyDefaultWindowSize       = 20
    AnomalyFailureRateThreshold    = 0.3
    AnomalyFailureRateZScoreHigh   = 2.5
    AnomalyFailureRateZScoreCrit   = 4.0
    AnomalyTrendSlopeThreshold     = 0.5
    AnomalyTrendR2Threshold        = 0.4
    AnomalyTrendHighSlope          = 2.0

    # Supply-chain sentinel placeholders (used only when provenance data is absent)
    SupplyChainUnknownRepo     = 'https://localhost/unknown-repo'
    SupplyChainUnknownBuildType = 'https://localhost/unknown-build-type'

    # SLO targets + baseline drift switch. Every key mapped in ConfigKeyMap
    # (slo.*, baseline.driftEnabled) MUST have a default here (parity rule);
    # values mirror the shipped gbuild.config.json so config == default.
    SloEnabled                          = $true
    SloPreflightPassRateTarget          = 0.95
    SloPreflightPassRateWindowDays      = 30
    SloSecretScanFalsePositiveRateTarget = 0.01
    SloSecretScanFalsePositiveRateWindowDays = 30
    SloBuildSuccessRateTarget           = 0.9
    SloBuildSuccessRateWindowDays       = 30
    SloMttrSecondsTargetMedian          = 300
    SloMaxBurnRatePerSprint             = 0.2
    BaselineDriftEnabled                = $true
    BaselineDriftThresholdPct           = 10.0
    BaselineDriftMinDeltaSeconds        = 0.5
    BaselineAlertOnImprovement          = $false
    BaselineHistorySize                 = 5
    BaselineExcludedSteps               = @()

    # UI colors (single source of truth - resolved by Set-StateColors, gbuild.ps1, Resolve-SafeColor fallback)
    Colors                  = @{ Header = 'Magenta'; Info = 'Cyan'; Warn = 'Yellow'; Err = 'Red'; Succ = 'Green'; Gray = 'DarkGray'; White = 'White' }
    # Syntax check exclusions — directories to skip during SyntaxCheck, listed relative to project root.
    # Single source shared by Invoke-SyntaxCheck / Invoke-UniversalSyntaxCheck / gbuild.ps1 -SyntaxCheck.
    # _Build is an embedded tool copy inside the project (portable mode), NOT project
    # code — it must not be syntax-scanned, otherwise preflight fails on stale/broken tool copies.
    SyntaxCheckExcludeDirs  = @(
        'obj'
        'bin'
        '.git'
        'node_modules'
        'TestResults'
        'publish-output'
        '.gbuildcache'
        'build-reports'
        'logs'
        '_Build'
        # Vendored third-party tooling (e.g. PSScriptAnalyzer compatibility
        # profile JSONs with reserved "psobject" member names). Tool data is
        # not project code and must never block preflight syntax gates.
        '.tools'
    )
    # Syntax check exclusions — build-system launcher/entry files matched BY NAME at
    # any depth. A project may carry its own (often stale or PS7-only) gbuild copy at
    # its root or an embedded _Build; the build system must never be blocked by its
    # own tooling artifacts. Single source shared by Invoke-SyntaxCheck /
    # Invoke-UniversalSyntaxCheck / Preflight.
    SyntaxCheckExcludeFiles = @(
        'gbuild'
        'gbuild.ps1'
        'gbuild.bat'
    )

    # Level 5 service defaults (RootCause / AutoTuner / AnomalyDetector /
    # Distributed / Chaos). Every key mapped in ConfigKeyMap below MUST have a
    # default here so standalone imports (no config) still resolve centrally
    # instead of scattering literals across callers.
    RootCauseEnabled          = $true
    RootCauseHistoryPath      = 'build-reports/root-cause.jsonl'
    RootCauseMaxHistoryEntries = 500
    # L5 default posture: fully opt-in for standalone imports (enabled OFF, and
    # NEVER auto-apply tunings without operator approval (autoApply OFF)).
    # The shipped gbuild.config.json opts in (autoTune.enabled=true). Approval
    # workflow: review recommendations, set autoTune.autoApply=true per project.
    AutoTuneEnabled           = $false
    AutoTuneAutoApply         = $false
    AutoTuneHistoryPath       = 'build-reports/autotune-history.jsonl'
    AutoTuneMaxHistoryEntries = 200
    AutoTuneMinSamples        = 5
    # EWMA smoothing for the duration regressor. Was read as 'AutoTuneEwmaAlpha',
    # which was never a BuildConstants key, so it always fell back to 0.3.
    AutoTuneEwmaAlpha         = 0.3
    # DORA measurement window (Metrics.Get-DoraMetrics). Read as 'DoraWindowHours',
    # never defined, so it always fell back to 24.
    DoraWindowHours           = 24
    AnomalyEnabled            = $true
    AnomalyZScoreThreshold    = 3.0
    AnomalyEwmaAlpha          = 0.3
    AnomalyMinSamples         = 10
    AnomalyHistoryPath        = 'build-reports/anomaly-history.jsonl'
    AnomalyAlertOnAnomaly     = $true
    DistributedEnabled        = $false
    DistributedStrategy       = 'round-robin'
    DistributedRepoRoot       = ''
    DistributedConnectTimeout = 30
    DistributedExecTimeout    = 600
    DistributedStrictHostKey  = 'accept-new'
    DistributedReportPath     = 'distributed-report'
    ChaosEnabled              = $false
    ChaosSeed                 = 42
    # Pipeline engine single-source (was orphan keys: validate/retryEnabled/maxRetries/timeoutSeconds).
    PipelineValidate          = $true
    PipelineRetryEnabled      = $true
    PipelineMaxRetries        = 0
    PipelineTimeoutSeconds    = 0
    # Explicit YAML pipeline path. Empty = auto-discover gbuild.pipeline.yml in
    # ProjectRoot only. Never ScriptRoot: that directory ships the file as an
    # example, and reading it there would replace the built-in pipeline for
    # every project on the machine.
    PipelineFile              = ''
    # Step-level watchdog timeout (seconds; 0 = disabled). Config dot-path is the
    # ROOT-level 'stepTimeoutSeconds' — matches gbuild.config.json (root key) and
    # gbuild.config.schema.json (root property). Do NOT remap to build.*.
    StepTimeoutSeconds        = 0
    PluginDispatchEnabled     = $true
    # Level 5 single-source for former module-local literals (High/Medium hardcode).
    # Each has distinct semantics — never reuse a generic key (e.g. MaxRetries,
    # ExeTimeoutMs, CachePresignExpiresSec) for these domain values.
    ClusterBuildTimeoutSec    = 3600
    # Cluster orchestrator single-source (was $DefaultClusterConfig literals).
    ClusterCoordinatorType    = 'leader-election'
    ClusterLeaseName          = 'gbuild-coordinator'
    ClusterLeaseNamespace     = 'gbuild-system'
    ClusterElectionTTL        = 15
    ClusterRenewalInterval    = 5
ClusterSchedulingStrategy = 'least-loaded'
ClusterMaxConcurrentPerCluster = 8
# Per-build Kubernetes Job sizing. These replace the previously declared
# ClusterResourceCpu/ClusterResourceMemory, which were resolved into
# Scheduling.ResourceOverhead and then never read - the job manifest carried its
# own hardcoded 500m/1Gi requests and 2000m/4Gi limits, so an operator tuning
# cluster resources had no effect at all.
ClusterJobRequestCpu        = '500m'
ClusterJobRequestMemory     = '1Gi'
ClusterJobLimitCpu          = '2000m'
ClusterJobLimitMemory       = '4Gi'
ClusterJobTtlSeconds        = 86400
ClusterJobBackoffLimit      = 2
# Namespace submitted Jobs land in when the BuildSpec does not override it.
# Previously hardcoded as 'gbuild-jobs' in Submit-ClusterBuild with no config
# owner, so operators could not retarget Job submissions.
ClusterJobsNamespace        = 'gbuild-jobs'
    ClusterServiceAccount     = 'gbuild-worker'
    ClusterNamespace          = 'gbuild-system'
    ClusterTokenAudience      = 'gbuild'
    ClusterMetricsPort        = 9101
    ClusterHealthPort         = 9102
    ClusterLogLevel           = 'Info'
    ClusterHealthMonitorIntervalSec = 30
    ClusterHealthTimeoutSec   = 10
    # kubectl ceilings that used to be literals at every call site. Split by
    # SEMANTICS, not by value: an apply/rollout on a large or slow cluster needs
    # materially longer than a leader-election renew, and neither was adjustable.
    # ClusterLeaderTimeoutSec defaults to 2x Coordinator.RenewalInterval (5 s),
    # so a brief API stall no longer silently drops leadership.
    ClusterApplyTimeoutSec    = 30
    ClusterLeaderTimeoutSec   = 10
    ClusterBuildPollSec       = 10
    ClusterElectionBackoffSec = 5
    ClusterCapacityCpu        = '8'
    ClusterCapacityMemory     = '32Gi'
    ClusterDefaultMaxConcurrent = 8
    # Cache HA single-source (was inline literals in Get-RemoteCacheConfig).
    CacheHAReplicationStrategy = 'async'
    CacheHAReadPreference     = 'primary'
    CacheHAWriteConcern       = 'acknowledged'
    CacheHAFailbackEnabled    = $true
    CacheHAFailoverEnabled    = $true
    AuditLedgerMemoryCap      = 5000
    AuditLedgerFileMaxSizeMB  = 100
    AuditLedgerFileMaxFiles   = 100
    AuditLedgerCheckpointInterval = 1000
    CacheHAHealthCheckIntervalSec = 30
    CacheHAHealthCheckTimeoutSec  = 10
    CacheHAFailbackDelaySec   = 300
    CacheHAMaxStalenessSec    = 300
    CacheHAMaxRetries         = 3
    AnomalyCriticalZScore     = 5.0
    AnomalyHighZScore         = 4.0
    AnomalyEwmaMultiplier     = 2.0
    AnomalyFailureRateHighZScore2 = 3.0
    # Level 5 anomaly->alert closed loop: severity mapping single-sourced so
    # High/Critical anomalies always pass the alerting.minSeverity gate.
    # Anomaly->Alert severity map (High->Error, Critical->Critical) ensures
    # delivery instead of silent Warning-filter drop.
    AnomalyAlertSeverityMap = @{
        'Low'      = 'Info'
        'Medium'   = 'Warning'
        'High'     = 'Error'
        'Critical' = 'Critical'
    }
    # Level 5 OPA server (enterprise sidecar): URL empty = disabled, CLI/builtin
    # fallback chain applies. Timeout distinct from generic ExeTimeoutMs.
    PolicyOpaServerUrl = ''
    PolicyOpaServerTimeoutSec = 10
    # Prometheus scrape path (telemetry.prometheus.metricsPath). Previously the
    # Metrics module looked up a key that did not exist here, so the lookup
    # always fell through to a dead literal. Now config-overridable.
    PrometheusMetricsPath     = '/metrics/'
    # SDK discovery cache locations. Environment.psm1 and SDK.psm1 previously
    # each hardcoded these literals; now single-sourced here.
    SdkCacheUserRelativePath  = '.gbuild/sdkcache.json'
    SdkCacheLocalFileName     = '.sdkcache.json'

    # Severity ranking (single source of truth). Higher = more severe.
    # Shared by Alerting (severity threshold) and Siem (CEF/syslog PRI).
    # NOTE: Logging log-verbosity (ERROR=0..DEBUG=3) is a different axis and is
    # intentionally kept as a local switch — see Logging.psm1.
    SeverityRank            = @{
        'Info'       = 0
        'Information' = 0
        'OK'         = 0
        'Passed'     = 0
        'Pass'       = 0
        'Warning'    = 1
        'Warn'       = 1
        'Error'      = 2
        'Err'        = 2
        'Fail'       = 2
        'Failed'     = 2
        'Blocked'    = 2
        'Critical'   = 3
    }
}

function Get-BuildPathLiteralPatterns {
    <#
    .SYNOPSIS
        The canonical regexes that recognise a platform-hostile path literal.
    .DESCRIPTION
        SINGLE OWNER, read by BOTH consumers:
          * Modules/ProcessMetrics.psm1 (the adoption metric)
          * Tests/GateDetectors.ps1     (the enforcement gate)

        They lived as two hand-maintained copies and drifted the moment either
        changed - which is precisely the failure Tests/process-baseline.json warns
        about: "a metric and its gate disagreeing on a green build destroys trust
        in the whole trend". The gate tightened its token; the metric kept the old
        one; the ratchet then read 100% while the gate itself would have failed.
        BuildConstants is the one module both a production metric and a test
        library can read.

        Two properties of the token are load-bearing, both learned by being wrong:

          * The quote character must NOT be inside the class. If it is, the token
            swallows the closing quote and the pattern matches a plain
            `Join-Path $root 'Foo.psm1'` - i.e. every path in the repository.
          * At least ONE separator is required. With `*`, a path containing no
            backslash at all matches, which is correct code.

        Together they accept any number of separator-separated segments
        ('Modules\Sub\File.psm1' and 'Modules\Sub.psm1' both match) while still
        rejecting the two shapes that are correct code and were false positives:
        `-replace '\\', '/'` (a regex escape) and `'[\w\/]'` (a character class).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

Set-StrictMode -Version 1.0
    $token = "[\w\-\/:.~%+,@# ]+"
    return @{
        Token     = $token
        Construct = "(?:Join-Path|Import-Module)[^\r\n]*?'$token(?:\\$token)+'"
        Assert    = "-BeLike\s+'\*[^']*\\[^']*'"
    }
}

function Get-BuildDefault {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [object]$Fallback = $null
    )
    if ($script:BuildDefaults.ContainsKey($Key)) {
        return $script:BuildDefaults[$Key]
    }
    return $Fallback
}

function Get-BuildTimestamp {
    <#
    .SYNOPSIS
        Formats the current (or supplied) time with a canonical timestamp kind.
    .DESCRIPTION
        Single owner for timestamp spellings. Artifact filenames, audit
        rotation names, deployment tags, human-readable log timestamps and
        calendar dates are different display questions: giving each a named
        kind keeps a future change from accidentally renaming one artifact
        while meaning to change another.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('FileStamp', 'RotationStamp', 'ImageTag', 'Display', 'Date', 'RoundTrip')]
        [string]$Kind = 'FileStamp',
        [DateTime]$At = (Get-Date)
    )
    # Explicit per-kind table: the hygiene consumer gate matches constant
    # names by text, and a dynamic 'Timestamp'+$Kind lookup would hide these.
    $format = switch ($Kind) {
        'FileStamp'     { $script:BuildDefaults['TimestampFileStamp'] }
        'RotationStamp' { $script:BuildDefaults['TimestampRotationStamp'] }
        'ImageTag'      { $script:BuildDefaults['TimestampImageTag'] }
        'Display'       { $script:BuildDefaults['TimestampDisplay'] }
        'Date'          { $script:BuildDefaults['TimestampDate'] }
        'RoundTrip'     { $script:BuildDefaults['TimestampRoundTrip'] }
    }
    return $At.ToString($format)
}

# ========================================================================
# Config key map: BuildConstants key <-> gbuild.config.json dot-path.
# Single source for the config-vs-default correspondence. Entries exist
# ONLY where gbuild.config.json actually defines a setting. Used by
# Get-BuildSetting (config-first lookup) and verified by tests.
# ========================================================================
$script:ConfigKeyMap = @{
    'MinDiskMB'                 = 'health.minDiskSpaceMB'
    'MaxCacheSizeMB'            = 'build.maxCacheSizeMB'
    'EnableParallelBuild'       = 'build.enableParallelBuild'
    'ParallelMaxJobs'           = 'build.maxParallelJobs'
    'ParallelMaxJobsMax'        = 'build.maxJobsMax'
    'ParallelSearchMaxDepth'    = 'build.searchMaxDepth'
    'TestEnabled'               = 'build.test.enabled'
    'TestLintEnabled'           = 'build.test.lintEnabled'
    'ProgressEnabled'           = 'build.progress.enabled'
    'PreflightCheckTools'       = 'build.preflight.checkTools'
    'PreflightCheckModuleGraph' = 'build.preflight.checkModuleGraph'
    'TelemetryEnabled'          = 'telemetry.enabled'
    'TelemetryOtelEnabled'      = 'telemetry.otel.enabled'
    'DefaultPort'               = 'build.defaultPort'
    'DefaultPorts'              = 'health.ports'
    'MetricsPort'               = 'telemetry.prometheus.port'
    'SyslogPort'                = 'security.siem.port'
    'NetworkTimeout'            = 'health.networkTimeout'
    'ExeTimeoutMs'              = 'sdk.exeTimeoutMs'
    'RetryBaseDelay'            = 'errorHandling.baseDelayMs'
    'RetryMaxDelayMs'           = 'errorHandling.maxDelayMs'
    'MaxRetries'                = 'errorHandling.maxRetries'
    'CircuitBreakerThreshold'   = 'errorHandling.circuitBreaker.failureThreshold'
    'CircuitBreakerResetMs'     = 'errorHandling.circuitBreaker.resetTimeoutMs'
    'PortWaitAttempts'          = 'build.portWaitAttempts'
    'PortWaitDelayMs'           = 'build.portWaitDelayMs'
    'AdbUninstallDelayMs'       = 'android.adbUninstallDelayMs'
    'AdbAutoConnectEndpoints'   = 'android.adbAutoConnectEndpoints'
    'AndroidDefaultApplicationId' = 'android.defaultApplicationId'
    'AndroidDebugAlias'         = 'android.keystore.alias'
    'AndroidDebugDname'         = 'android.keystore.distinguishedName'
    'AndroidDebugKeySize'       = 'android.keystore.keySize'
    'AndroidDebugValidityDays'  = 'android.keystore.validityDays'
    'WebReadinessAttempts'      = 'deploy.webReadinessAttempts'
    'WebAppLaunchDelayMs'       = 'deploy.webAppLaunchDelayMs'
    'WebAppLaunchDelayMinMs'    = 'deploy.webAppLaunchDelayMinMs'
    'WebAppReadyPortProbe'      = 'deploy.webPortProbe'
    'WebAppLaunchMaxAttempts'   = 'deploy.webAppLaunchMaxAttempts'
    'SecretScanMaxFileMB'       = 'security.scanMaxFileMB'
    'SecurityScanDepth'         = 'security.scanDepth'
    'DefaultOptionalTools'      = 'health.optionalTools'
    'ShortHashLength'           = 'build.cache.shortHashLength'
    'CacheHashSearchDepth'      = 'build.cache.hashDepth'
    'VerificationConnectTimeoutSec' = 'verification.connectTimeout'
    'VerificationRequestTimeoutSec' = 'verification.requestTimeout'
    'CacheMaxEntries'           = 'build.cacheLocal.maxEntries'
    'CacheMaxAgeDays'           = 'build.cacheLocal.maxAgeDays'
    'CacheMaxSizeMb'            = 'build.cacheLocal.maxSizeMb'
    'MaxLogFiles'               = 'logging.maxLogFiles'
    'MaxLogSizeMB'              = 'logging.maxLogSizeMB'
    'LogScopedLogging'          = 'build.scopedLogging'
    'OpenOutput'                = 'build.openOutput'
    'AuditLogMaxSizeMB'         = 'security.auditLogMaxSizeMB'
    'WebhookTokenRotationHours' = 'alerting.rotationIntervalHours'
    'WebhookTokenByteLength'  = 'alerting.tokenByteLength'
    'PublishOutputDir'          = 'paths.publishOutput'
    'CacheDir'                  = 'build.cacheDirectory'
    'ReportOutputDir'           = 'report.outputDir'
    'SdkMajorMin'               = 'health.minDotnetMajor'
    'DefaultTfm'                = 'dotnet.defaultTfm'
    'DefaultConfiguration'      = 'build.defaultConfiguration'
    'SecurityExcludeDirs'       = 'security.excludeDirs'
    'RbacEnforceInCI'             = 'security.rbac.enforceInCI'
    'RbacCiReadOnlyActions'       = 'security.rbac.ciReadOnlyActions'
    'RbacPrivilegedActions'       = 'security.rbac.privilegedActions'
    'SdkCacheExpiryDays'        = 'sdk.cacheExpiryDays'
    'SdkDefaultSearchDepth'     = 'sdk.defaultSearchDepth'
    'SdkProjectScanDepth'       = 'sdk.projectScanDepth'
    'SdkParentScanDepth'        = 'sdk.parentScanDepth'
    'SdkWinSearchDepthDelta'    = 'sdk.winSearchDepthDelta'
    'LogFileRetryAttempts'      = 'logging.fileRetryAttempts'
    'LogFileRetryDelayMs'       = 'logging.fileRetryDelayMs'
'ParallelProgressPollMs'       = 'build.progressPollIntervalMs'
    'ProgressThrottleMs'            = 'build.progress.throttleMs'
    'ProgressElapsedSec'            = 'build.progress.elapsedIntervalSec'
    'ProgressPollMs'                  = 'build.progress.pollMs'
'ParallelMaxJobsScaleFactor'    = 'build.parallelMaxJobsScaleFactor'

    # Step-level timeout watchdog (seconds; 0 = disabled).
    # When enabled, any build step exceeding this duration is logged as
    # 'step timed out' and counted as a step failure (honours retry config).
    # Dot-path is ROOT-level: gbuild.config.json carries "stepTimeoutSeconds" at
    # the document root and gbuild.config.schema.json declares the same root
    # property (additionalProperties: false at root — a build.* key would be
    # silently dropped / schema-invalid).
    'StepTimeoutSeconds'           = 'stepTimeoutSeconds'
    'DistributedMinConcurrent'      = 'distributed.minConcurrent'
    'MsBuildParallelArgs'           = 'build.msBuildParallelArgs'

    'ProjectRootMaxDepth'             = 'build.projectRootMaxDepth'
    'ProjectMarkers'                  = 'build.projectMarkers'
    'CompatibleChildItemMaxDepth'     = 'build.compatMaxDepth'
    'RelativeDepthErrorSentinel'      = 'build.relativeDepthErrorSentinel'
    'MetricsBindAddress'              = 'telemetry.prometheus.bindAddress'
    'PrometheusMetricsPath'           = 'telemetry.prometheus.metricsPath'
    'OtlpMetricsPath'                 = 'telemetry.otel.metricsPath'
    'OtlpTracesPath'                  = 'telemetry.otel.tracesPath'
    'OtlpJsonDepth'                   = 'telemetry.otel.jsonDepth'
    'SiemEnterpriseId'                = 'security.siem.enterpriseId'
    'DefaultProjectVersion'           = 'versioning.defaultVersion'
    'VersionSearchDepth'                = 'versioning.searchDepth'
    'StandaloneBundleVersion'         = 'build.standalone.bundleVersion'
    'SupplyChainToolName'               = 'supplyChain.toolName'
    'DefaultRequiredTools'              = 'health.requiredTools'
    'AndroidCmdLineToolsRelPath'        = 'sdk.androidCmdLineToolsRelPath'
    'AdbConnectTimeoutMs'               = 'android.adbConnectTimeoutMs'
    'SastDotnetIgnoreNoFindingsExitCode' = 'security.sast.dotnetIgnoreNoFindingsExitCode'
    'SastTimeoutSec'                    = 'security.sast.timeoutSec'
    'VendoredToolsDirName'              = 'paths.vendoredTools'
    'ScriptAnalyzerVersion'             = 'security.sast.bundledAnalyzerVersion'
    'PrimaryLanguagePriority'           = 'build.primaryLanguagePriority'

    # gbuild-specific SDK probe paths (Find-AdbPath Step 5)
    'SdkGbuildDotSdkAndroidSdk'   = 'sdk.gbuildDotSdkAndroidSdk'
    'SdkGbuildDotSdk'             = 'sdk.gbuildDotSdk'
    'SdkGbuildParentDotSdkAndroidSdk' = 'sdk.gbuildParentDotSdkAndroidSdk'

    # SDK auto-provision
    'SdkAutoProvisionInstallDir' = 'sdk.autoProvision.installDir'
    'SdkAutoProvisionChannel'    = 'sdk.autoProvision.channel'
    'SdkAutoProvisionVersion'    = 'sdk.autoProvision.version'
    'SdkAutoProvisionInstallerSha256' = 'sdk.autoProvision.installerSha256'
    # Provider release tracking (empty MaxKnown = unknown/offline)
    'SdkReleaseMetadataBaseUrl' = 'sdk.releaseMetadataBaseUrl'
    'SdkMaxKnownVersion'        = 'sdk.maxKnownSdkVersion'
    'SdkReleaseCacheHours'      = 'sdk.releaseCacheHours'
    'SdkReleaseCacheFileName'   = 'sdk.releaseCacheFileName'

    # SDK discovery paths (config-overridable)
    'SdkProtectedPathPatterns' = 'sdk.protectedPathPatterns'
    'SdkBlacklistWindows'      = 'sdk.blacklistWindows'
    'SdkBlacklistMac'          = 'sdk.blacklistMac'
    'SdkBlacklistBase'         = 'sdk.blacklistBase'

    # Level 5 modules (RootCause / AutoTuner / AnomalyDetector / Distributed)
    # Previously each module defined its own Get-*-Config with local hardcoded
    # fallbacks, bypassing the central ConfigKeyMap. Now single-sourced here so
    # gbuild.config.json overrides flow through Get-BuildSetting uniformly.
    'RootCauseEnabled'          = 'rootCause.enabled'
    'RootCauseHistoryPath'       = 'rootCause.historyPath'
    'RootCauseMaxHistoryEntries' = 'rootCause.maxHistoryEntries'
    'AutoTuneEnabled'            = 'autoTune.enabled'
    'AutoTuneAutoApply'          = 'autoTune.autoApply'
    'AutoTuneHistoryPath'        = 'autoTune.historyPath'
    'AutoTuneMaxHistoryEntries'  = 'autoTune.maxHistoryEntries'
    'AutoTuneMinSamples'         = 'autoTune.minSamplesBeforeTune'
    'AnomalyEnabled'             = 'anomaly.enabled'
    'AnomalyZScoreThreshold'     = 'anomaly.zScoreThreshold'
    'AnomalyEwmaAlpha'           = 'anomaly.ewmaAlpha'
    'AutoTuneEwmaAlpha'          = 'autoTune.ewmaAlpha'
    'DoraWindowHours'            = 'slo.doraWindowHours'
    'LogMaxAgeDays'              = 'logging.maxLogAgeDays'
    'AnomalyMinSamples'          = 'anomaly.minSamples'
    'AnomalyHistoryPath'         = 'anomaly.historyPath'
    'AnomalyAlertOnAnomaly'      = 'anomaly.alertOnAnomaly'
    'DistributedEnabled'         = 'distributed.enabled'
    'DistributedStrategy'        = 'distributed.strategy'
    'ConnectTimeoutSec'          = 'distributed.timeout.connect'
    'ExecutionTimeoutSec'        = 'distributed.timeout.execution'
    'DistributedRepoRoot'        = 'distributed.repoRoot'
    'DistributedConnectTimeout'  = 'distributed.timeout.connect'
    'DistributedExecTimeout'     = 'distributed.timeout.execution'
    'DistributedStrictHostKey'   = 'distributed.strictHostKeyChecking'
    'DistributedReportPath'      = 'distributed.reportPath'
    'ChaosEnabled'               = 'chaos.enabled'
    'ChaosSeed'                  = 'chaos.seed'

    'AutoTuneDefaultParallelMax'     = 'autoTune.defaultParallelMax'
    'AutoTuneParallelCeiling'        = 'autoTune.parallelCeiling'
    'AutoTuneCacheMaxEntriesDefault' = 'autoTune.cacheMaxEntriesDefault'
    'AutoTuneCacheMaxSizeMbDefault'  = 'autoTune.cacheMaxSizeMbDefault'
    'AutoTuneDefaultTimeoutMinutes'  = 'autoTune.defaultTimeoutMinutes'
    'AutoTuneFailRateThresholdLow'   = 'autoTune.failRateThresholdLow'
    'AutoTuneFailRateThresholdHigh'  = 'autoTune.failRateThresholdHigh'
    'AutoTuneAvgDurationThreshold'   = 'autoTune.avgDurationThreshold'
    'AutoTuneTimeoutMultiplier'      = 'autoTune.timeoutMultiplier'
    'AutoTuneTimeoutRatio'           = 'autoTune.timeoutRatio'
    'AutoTuneIncrementalRatio'       = 'autoTune.incrementalRatio'
    'AutoTuneVerifyEnabled'          = 'autoTune.verifyEnabled'
    'AutoTuneRollbackEnabled'        = 'autoTune.rollbackEnabled'
    'AutoTuneCacheHitRateLow'        = 'autoTune.cacheHitRateLow'
    'AutoTuneCacheHitRateHigh'       = 'autoTune.cacheHitRateHigh'

    # Level 5 process hygiene
    'BaselineDriftEnabled'       = 'baseline.driftEnabled'
    'BaselineDriftThresholdPct'  = 'baseline.driftThresholdPct'
    'BaselineDriftMinDeltaSeconds' = 'baseline.driftMinDeltaSeconds'
    'BaselineAlertOnImprovement' = 'baseline.alertOnImprovement'
    'BaselineHistorySize'        = 'baseline.historySize'
    'BaselineExcludedSteps'      = 'baseline.excludedSteps'

    # SLO (Service Level Objectives) — Level 5 fail-closed targets + burn-rate windows.
    'SloEnabled'             = 'slo.enabled'
    'SloPreflightPassRateTarget' = 'slo.preflightPassRateTarget'
    'SloPreflightPassRateWindowDays' = 'slo.preflightPassRateWindowDays'
    'SloSecretScanFalsePositiveRateTarget' = 'slo.secretScanFalsePositiveRateTarget'
    'SloSecretScanFalsePositiveRateWindowDays' = 'slo.secretScanFalsePositiveRateWindowDays'
    'SloBuildSuccessRateTarget'    = 'slo.buildSuccessRateTarget'
    'SloBuildSuccessRateWindowDays' = 'slo.buildSuccessRateWindowDays'
    'SloMttrSecondsTargetMedian'   = 'slo.mttrSecondsTargetMedian'
    'SloMaxBurnRatePerSprint'      = 'slo.maxBurnRatePerSprint'

    'AnomalyDefaultWindowSize'       = 'anomaly.defaultWindowSize'
    'AnomalyFailureRateThreshold'    = 'anomaly.failureRateThreshold'
    'AnomalyFailureRateZScoreHigh'   = 'anomaly.failureRateZScoreHigh'
    'AnomalyFailureRateZScoreCrit'   = 'anomaly.failureRateZScoreCrit'
    'AnomalyTrendSlopeThreshold'     = 'anomaly.trendSlopeThreshold'
    'AnomalyTrendR2Threshold'        = 'anomaly.trendR2Threshold'
    'AnomalyTrendHighSlope'          = 'anomaly.trendHighSlope'
    # Level 5 single-source for former module-local literals (High/Medium).
    'ProgressKillWaitMs'             = 'build.progress.killWaitMs'
    'ClusterBuildTimeoutSec'         = 'build.cluster.buildTimeoutSec'
    'AuditLedgerMemoryCap'           = 'security.auditLedger.memoryCap'
    'AuditLedgerFileMaxSizeMB'       = 'security.auditLedger.file.maxSizeMB'
    'AuditLedgerFileMaxFiles'        = 'security.auditLedger.file.maxFiles'
    'AuditLedgerCheckpointInterval'  = 'security.auditLedger.ledger.checkpointInterval'
    'CacheHAHealthCheckIntervalSec'  = 'build.cacheRemote.ha.failover.healthCheckIntervalSec'
    'CacheHAHealthCheckTimeoutSec'   = 'build.cacheRemote.ha.failover.healthCheckTimeoutSec'
    'CacheHAFailbackDelaySec'        = 'build.cacheRemote.ha.failover.failbackDelaySec'
    'CacheHAMaxStalenessSec'         = 'build.cacheRemote.ha.consistency.maxStalenessSec'
    'CacheHAMaxRetries'              = 'build.cacheRemote.ha.failover.maxRetries'
    'CacheHAReplicationStrategy'     = 'build.cacheRemote.ha.replicationStrategy'
    'CacheHAReadPreference'          = 'build.cacheRemote.ha.consistency.readPreference'
    'CacheHAWriteConcern'            = 'build.cacheRemote.ha.consistency.writeConcern'
    'CacheHAFailbackEnabled'         = 'build.cacheRemote.ha.failover.failbackEnabled'
    'CacheHAFailoverEnabled'         = 'build.cacheRemote.ha.failover.enabled'
    'CachePresignExpiresSec'         = 'build.cacheRemote.presignExpiresSeconds'
    'ClusterCoordinatorType'         = 'build.cluster.coordinator.type'
    'ClusterLeaseName'               = 'build.cluster.coordinator.leaseName'
    'ClusterLeaseNamespace'          = 'build.cluster.coordinator.leaseNamespace'
    'ClusterElectionTTL'             = 'build.cluster.coordinator.electionTTL'
    'ClusterRenewalInterval'         = 'build.cluster.coordinator.renewalInterval'
    'ClusterSchedulingStrategy'      = 'build.cluster.scheduling.strategy'
    'ClusterMaxConcurrentPerCluster' = 'build.cluster.scheduling.maxConcurrentPerCluster'
'ClusterJobRequestCpu'           = 'build.cluster.job.requestCpu'
'ClusterJobRequestMemory'        = 'build.cluster.job.requestMemory'
'ClusterJobLimitCpu'             = 'build.cluster.job.limitCpu'
'ClusterJobLimitMemory'          = 'build.cluster.job.limitMemory'
'ClusterJobTtlSeconds'           = 'build.cluster.job.ttlSecondsAfterFinished'
'ClusterJobBackoffLimit'         = 'build.cluster.job.backoffLimit'
'ClusterJobsNamespace'           = 'build.cluster.job.namespace'
    'ClusterServiceAccount'          = 'build.cluster.workloadIdentity.serviceAccount'
    'ClusterNamespace'               = 'build.cluster.workloadIdentity.namespace'
    'ClusterTokenAudience'           = 'build.cluster.workloadIdentity.tokenAudience'
    'ClusterMetricsPort'             = 'build.cluster.observability.metricsPort'
    'ClusterHealthPort'              = 'build.cluster.observability.healthPort'
    'ClusterLogLevel'                = 'build.cluster.observability.logLevel'
    'ClusterHealthMonitorIntervalSec' = 'build.cluster.healthMonitorIntervalSec'
    'ClusterHealthTimeoutSec'        = 'build.cluster.healthTimeoutSec'
    'ClusterBuildPollSec'            = 'build.cluster.buildPollSec'
    'ClusterElectionBackoffSec'      = 'build.cluster.electionBackoffSec'
    'PluginCacheHashLength'          = 'build.cache.pluginHashLength'
    'CorrelationIdLength'            = 'build.correlationIdLength'
    'DeployChoiceArgsApk'            = 'build.deployChoiceArgs.apk'
    'DeployChoiceArgsIos'            = 'build.deployChoiceArgs.ios'
    'DeployChoiceArgsWinMsix'        = 'build.deployChoiceArgs.winMsix'
    'DeployChoiceArgsAot'            = 'build.deployChoiceArgs.aot'
    'DeployConsoleSelfContained'     = 'build.deployChoiceArgs.consoleSelfContained'
    'DeployDefaultRid'               = 'build.deployChoiceArgs.defaultRid'
    'CiWorkflowFile'                 = 'ci.workflowFile'
    'CiPackageFormatNonInteractive'  = 'ci.packageFormatNonInteractive'
    'CiPackageFormatInteractive'     = 'ci.packageFormatInteractive'
    'CiDefaultBranch'                = 'ci.defaultBranch'
    'ClusterCapacityCpu'             = 'build.cluster.capacity.cpu'
    'ClusterCapacityMemory'          = 'build.cluster.capacity.memory'
    'ClusterDefaultMaxConcurrent'    = 'build.cluster.defaultMaxConcurrent'
    'PipelineValidate'               = 'build.pipeline.validate'
    'PluginDispatchEnabled'          = 'build.pluginDispatch.enabled'
    'PipelineRetryEnabled'           = 'build.pipeline.retryEnabled'
    'PipelineMaxRetries'             = 'build.pipeline.maxRetries'
    'PipelineTimeoutSeconds'         = 'build.pipeline.timeoutSeconds'
    'PipelineFile'                   = 'build.pipeline.file'
    'AnomalyCriticalZScore'          = 'anomaly.criticalZScore'
    'AnomalyHighZScore'              = 'anomaly.highZScore'
    'AnomalyEwmaMultiplier'          = 'anomaly.ewmaMultiplier'
    'AnomalyFailureRateHighZScore2'  = 'anomaly.failureRateHighZScore2'
    'DistributedMaxTotalConcurrency' = 'distributed.maxTotalConcurrency'
    'DistributedProbeBatchSize'      = 'distributed.probeBatchSize'
    'DistributedTaskMaxRetries'      = 'distributed.taskMaxRetries'
    'PolicyOpaServerUrl'             = 'security.policy.opaServerUrl'
    'PolicyOpaServerTimeoutSec'      = 'security.policy.opaServerTimeoutSec'
    # L5: former orphan keys — SDK install-location fallbacks, JDK/ADB relative
    # paths, clean targets and SSH default port. All config-overridable via
    # sdk.* / build.clean.* / distributed.sshPort so no caller bypasses config.
    'SdkDotnetMac'                   = 'sdk.dotnetMac'
    'SdkDotnetLinux'                 = 'sdk.dotnetLinux'
    'SdkJvmMac'                      = 'sdk.jvmMac'
    'SdkJvmUnix'                     = 'sdk.jvmUnix'
    'SdkAndroidLinux'                = 'sdk.androidLinux'
    'SdkAndroidMac'                  = 'sdk.androidMac'
    'SdkAndroidDebian'               = 'sdk.androidDebian'
    'JdkJavacRelativeWin'            = 'sdk.jdkJavacRelativeWin'
    'JdkJavacRelativeUnix'           = 'sdk.jdkJavacRelativeUnix'
    'AndroidAdbRelativeWin'          = 'sdk.androidAdbRelativeWin'
    'AndroidAdbRelativeUnix'         = 'sdk.androidAdbRelativeUnix'
    'CleanTargetDirNames'            = 'build.clean.targetDirNames'
    'CleanArtifactExtensions'        = 'build.clean.artifactExtensions'
    'SignArtifactExtensions'         = 'security.gpgSign.artifactExtensions'
    'CleanOutputFolderNames'         = 'build.clean.outputFolderNames'
    'SshDefaultPort'                 = 'distributed.sshPort'
    'SdkCacheUserRelativePath'       = 'sdk.cacheUserRelativePath'
}

# ========================================================================
# Public Facade: Get-BuildConstant (in SharedUtils.psm1) is the primary entry point.
# Get-BuildSetting / Get-BuildDefault / Get-BuildConfigPath / Get-SeverityRank /
# Get-VulnSeverityRank / Get-ElapsedSeconds are internal helpers exposed for
# standalone module survival. Callers should use Get-BuildConstant.
#
# Resolution order (via Get-BuildConstant -> Get-BuildSetting):
#   1. gbuild.config.json via the ConfigKeyMap dot-path (requires -State)
#   2. a build default registered in $script:BuildDefaults
#   3. the -Fallback value
# ========================================================================
function Get-BuildSetting {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [PSCustomObject]$State = $null,
        [object]$Fallback = $null
    )

    if ($State -and $State.BuildConfig -and $script:ConfigKeyMap.ContainsKey($Key)) {
        $path = $script:ConfigKeyMap[$Key]
        # Single-source tree-walk via ConfigProvider.Find-ConfigNode when the
        # global module graph is loaded; inline walk kept as a standalone fallback
        # (ConfigProvider deliberately avoids a BuildConstants import, and vice
        # versa this module must not hard-depend on it for standalone survival).
        if (Get-Command Find-ConfigNode -ErrorAction SilentlyContinue) {
            $current = Find-ConfigNode -Root $State.BuildConfig -Path $path
            if ($null -ne $current) { return $current }
        } else {
            $segments = $path -split '\.'
            $current = $State.BuildConfig
            $found = $true
            foreach ($seg in $segments) {
                if ($null -eq $current) { $found = $false; break }
                if ($current -is [System.Collections.IDictionary]) {
                    if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { $found = $false; break }
                } elseif ($current.PSObject.Properties.Name -contains $seg) {
                    $current = $current.$seg
                } else { $found = $false; break }
            }
            if ($found -and $null -ne $current) { return $current }
        }
        if ($Key -eq 'EnableParallelBuild') {
            $legacy = $null
            if (Get-Command Find-ConfigNode -ErrorAction SilentlyContinue) {
                $legacy = Find-ConfigNode -Root $State.BuildConfig -Path 'build.enableParallel'
            } else {
                $build = $State.BuildConfig
                if ($build -is [System.Collections.IDictionary]) {
                    if ($build.ContainsKey('build')) { $build = $build['build'] }
                } elseif ($build.PSObject.Properties.Name -contains 'build') { $build = $build.build }
                if ($build -is [System.Collections.IDictionary]) {
                    if ($build.ContainsKey('enableParallel')) { $legacy = $build['enableParallel'] }
                } elseif ($build -and $build.PSObject.Properties.Name -contains 'enableParallel') { $legacy = $build.enableParallel }
            }
            if ($null -ne $legacy) { return $legacy }
        }
    }

    if ($script:BuildDefaults.ContainsKey($Key)) { return $script:BuildDefaults[$Key] }
    return $Fallback
}

function Get-ProjectMarkers {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    # SINGLE SOURCE for "does this directory contain a buildable project?".
    # The result is the UNION of four sources, in this order:
    #   1. build.projectMarkers from config  (lets a user ADD a marker)
    #   2. the static BuildDefaults.ProjectMarkers canonical list
    #   3. the live LanguageDetector languageMap BuildFile values
    #   4. the live plugin manifest files, when the plugin SDK is loaded
    # Union, not override: dropping a marker cannot be expressed, because a
    # narrower list would silently make a supported language unbuildable. The
    # previous behaviour let build.projectMarkers REPLACE the canonical list,
    # which is how a Ruby-only repo ended up with a 13-entry list that did not
    # contain Gemfile.
    $set = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($items)
        foreach ($i in @($items)) {
            if ($null -eq $i) { continue }
            $v = ([string]$i).Trim()
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($seen.Add($v)) { $set.Add($v) }
        }
    }
    $configured = $null
    try { $configured = Get-BuildSetting -Key 'ProjectMarkers' -State $State -Fallback $null } catch { $configured = $null }
    if ($null -ne $configured) { & $add $configured }
    & $add $script:BuildDefaults['ProjectMarkers']
    # Live language map (module-scope variable of LanguageDetector; read only,
    # never imported from here - BuildConstants must stay dependency-free).
    if (Get-Command Get-LanguageMap -ErrorAction SilentlyContinue) {
        try {
            foreach ($entry in @(Get-LanguageMap)) {
                if ($entry -and ($entry.PSObject.Properties.Name -contains 'BuildFile')) {
                    $s = ([string]$entry.BuildFile).Trim()
                    $ext = [System.IO.Path]::GetExtension($s)
                    if ($ext -eq '.ps1' -or $ext -eq '.psm1') { continue }   # not a project-root marker
                    & $add $entry.BuildFile
                }
            }
        } catch { }
    }
    # Live plugin manifests: any plugin discovered in a Plugins dir. Loosely
    # typed per-file patterns ('*.ps1', '*.psm1') are filtered out of the ROOT
    # marker set - they identify a language but not a project, and admitting
    # them would make any directory containing a single stray script look like
    # a project root. They remain valid Plugin ManifestFiles for dispatch.
    if (Get-Command Get-RegisteredPlugins -ErrorAction SilentlyContinue) {
        try {
            foreach ($p in @(Get-RegisteredPlugins)) {
                foreach ($f in @($p.ManifestFiles)) {
                    $s = ([string]$f).Trim()
                    if ($s -like '*.*' -and $s -notlike '*.*/*') {
                        $ext = [System.IO.Path]::GetExtension($s)
                        if ($ext -eq '.ps1' -or $ext -eq '.psm1') { continue }
                    }
                    & $add $f
                }
            }
        } catch { }
    }
    if ($set.Count -eq 0) {
        $value = $script:BuildDefaults['ProjectMarkers']
        return @($value)
    }
    return @($set.ToArray())
}

# Return the config dot-path registered for a BuildConstants key, or ''.
# Return the canonical severity rank (0..3) for a severity name, or -1 when unknown.
# Case-insensitive. Unknown/empty values return -1 so callers can fall back to
# their own defaults without hardcoding a severity order.
function Get-SeverityRank {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()]
        [string]$Severity = '',
        [int]$Fallback = -1
    )
    if ([string]::IsNullOrWhiteSpace($Severity)) { return $Fallback }
    $map = $script:BuildDefaults['SeverityRank']
    $key = $Severity.Trim()
    if ($map.ContainsKey($key)) { return [int]$map[$key] }
    foreach ($k in $map.Keys) {
        if ($k -ieq $key) { return [int]$map[$k] }
    }
    return $Fallback
}

function Get-ElapsedSeconds {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][datetime]$Start,
        [datetime]$End = (Get-Date),
        [int]$Decimals = 3
    )
    $secs = ($End - $Start).TotalSeconds
    if ($Decimals -lt 0) { return $secs }
    return [math]::Round($secs, $Decimals)
}

# Return the canonical vulnerability severity rank (low=1, medium/moderate=2,
# high=3, critical=4) for a severity name, or 0 when unknown (never blocks).
# Case-insensitive. Single source of truth shared by Sast.psm1 and
# SupplyChain.psm1 container-scan gate â€” previously each module had its own
# local rankMap literal, so a scale change had to be made in 3 places.
function Get-VulnSeverityRank {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()]
        [string]$Severity = ''
    )
    if ([string]::IsNullOrWhiteSpace($Severity)) { return 0 }
    $map = $script:BuildDefaults['VulnSeverityRank']
    $key = $Severity.Trim().ToLowerInvariant()
    if ($map.ContainsKey($key)) { return [int]$map[$key] }
    foreach ($k in $map.Keys) {
        if ($k -ieq $key) { return [int]$map[$k] }
    }
    return 0
}

Export-ModuleMember -Function @('Get-BuildDefault', 'Get-BuildTimestamp', 'Get-BuildSetting', 'Get-ProjectMarkers', 'Get-BuildPathLiteralPatterns', 'Get-SeverityRank', 'Get-VulnSeverityRank', 'Get-ElapsedSeconds')


