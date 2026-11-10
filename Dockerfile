# The base image is digest-pinned. `--platform` is DELIBERATELY NOT pinned to
# linux/amd64: it used to be, which combined with the `test "$TARGETARCH" =
# "amd64"` guard below made `docker buildx build --platform linux/arm64` a hard
# failure and forced Apple Silicon builders through QEMU emulation. The tag
# stays multi-arch and the arch is resolved from TARGETARCH at build time.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04@sha256:62300a213a9293916333df2b014cd3a8f22fb0b0b65f2bb446aaf436bcf8c868

ARG TARGETARCH=amd64
ARG GBUILD_USER=gbuild
ARG GBUILD_UID=10001
ARG GBUILD_GID=10001
ARG POWERSHELL_VERSION=7.4.6
ARG DOTNET_8_SDK_VERSION=8.0.425
ARG DOTNET_10_SDK_VERSION=10.0.401
ARG DOTNET_INSTALL_SCRIPT_URL=https://raw.githubusercontent.com/dotnet/install-scripts/v2025.12.10/src/dotnet-install.sh
ARG DOTNET_INSTALL_SCRIPT_SHA256=102a6849303713f15462bb28eb10593bf874bbeec17122e0522f10a3b57ce442
ARG NODE_VERSION=22.17.0
ARG NPM_VERSION=10.9.2
# Per-architecture Node checksums. Only AMD64 existed before, so an arm64 build
# was impossible; both are pinned so a compromised tarball is still caught.
ARG NODE_SHA256_AMD64=0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a
ARG NODE_SHA256_ARM64=3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4

ENV DOTNET_NOLOGO=true \
    DOTNET_CLI_TELEMETRY_OPTOUT=true \
    DEBIAN_FRONTEND=noninteractive

# apt metadata and package files on Ubuntu security mirrors can be briefly
# out of sync, which makes apt exit 100 with 404 Not Found on a valid version.
# Retry the update+install pair together so a transient mirror gap does not
# fail the multi-arch build.
RUN for attempt in 1 2 3; do \
        apt-get update \
        && apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            git \
        && rm -rf /var/lib/apt/lists/* \
        && break; \
        echo "apt update/install failed (attempt $attempt/3), retrying in 5s" >&2; \
        sleep 5; \
    done

# Multi-arch Node install. Resolves the architecture from TARGETARCH and picks
# the matching verified checksum; an unsupported architecture fails loudly here
# rather than installing an unverified or wrong-arch binary.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) NODE_ARCH="x64";   NODE_SHA256="${NODE_SHA256_AMD64}" ;; \
      arm64) NODE_ARCH="arm64"; NODE_SHA256="${NODE_SHA256_ARM64}" ;; \
      *) echo "::error::unsupported TARGETARCH '$TARGETARCH' (supported: amd64, arm64)" >&2; exit 1 ;; \
    esac; \
    NODE_FILE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz"; \
    curl --proto '=https' --tlsv1.2 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_FILE}" -o /tmp/node.tar.gz; \
    echo "${NODE_SHA256}  /tmp/node.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/node.tar.gz --strip-components=1 -C /usr/local; \
    rm /tmp/node.tar.gz; \
    # Dotnet arch must follow TARGETARCH. Pinning it to x64 made the arm64 image
    # carry an unusable SDK (and the grep assertions below could not have passed
    # on a real arm64 host, which is why the bug stayed invisible).
    case "$TARGETARCH" in \
      amd64) DOTNET_ARCH="x64" ;; \
      arm64) DOTNET_ARCH="arm64" ;; \
      *) echo "::error::unsupported TARGETARCH '$TARGETARCH'" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -fsSL "$DOTNET_INSTALL_SCRIPT_URL" -o /tmp/dotnet-install.sh; \
    echo "${DOTNET_INSTALL_SCRIPT_SHA256}  /tmp/dotnet-install.sh" | sha256sum -c -; \
    chmod +x /tmp/dotnet-install.sh; \
    /tmp/dotnet-install.sh --version "$DOTNET_8_SDK_VERSION" --install-dir /usr/share/dotnet --architecture "$DOTNET_ARCH" --no-path; \
    /tmp/dotnet-install.sh --version "$DOTNET_10_SDK_VERSION" --install-dir /usr/share/dotnet --architecture "$DOTNET_ARCH" --no-path; \
    rm /tmp/dotnet-install.sh; \
    groupadd --gid "$GBUILD_GID" "$GBUILD_USER"; \
    useradd --uid "$GBUILD_UID" --gid "$GBUILD_GID" --create-home --shell /usr/sbin/nologin "$GBUILD_USER"

ENV PATH="/usr/local/bin:/usr/share/dotnet:${PATH}" \
    DOTNET_ROOT=/usr/share/dotnet \
    HOME=/home/gbuild

WORKDIR /repo
COPY --chown=gbuild:gbuild . /repo
RUN mkdir -p /repo/.gbuildcache /repo/logs /repo/build-reports \
    && chown -R gbuild:gbuild /repo

USER gbuild
RUN test "$(node --version)" = "v${NODE_VERSION}" \
    && test "$(npm --version)" = "${NPM_VERSION}" \
    && dotnet --list-sdks | grep -Fq "${DOTNET_8_SDK_VERSION} " \
    && dotnet --list-sdks | grep -Fq "${DOTNET_10_SDK_VERSION} " \
    && pwsh -NoProfile -NonInteractive -Command "if (\$PSVersionTable.PSVersion.ToString() -ne '${POWERSHELL_VERSION}') { throw 'PowerShell version pin mismatch' }" \
    && pwsh -NoProfile -NonInteractive -File ./gbuild.ps1 -SyntaxCheck

CMD ["pwsh", "-NoProfile", "-NonInteractive", "-File", "./gbuild.ps1", "-GitHub", "-Incremental"]
