# =============================================================================
# signal-cli-gateway
# Multi-stage Docker build for signal-cli daemon with optional secured-signal-api
# proxy layer for authentication and endpoint security.
# =============================================================================
# Stage 1: signal-cli native binary
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517 AS signal-cli-builder

ARG SIGNAL_CLI_VERSION=0.14.7

# AsamK/signal-cli release signing key.
# Fingerprint verified against keys.openpgp.org and keyserver.ubuntu.com
# (both return the verified-email UID "AsamK <asamk@gmx.de>" for this key),
# and cross-checked against the issuer-fingerprint subpacket in the release
# .asc signatures themselves.
ARG SIGNAL_CLI_GPG_FINGERPRINT=FA10826A74907F9EC6BBB7FC2BA2CD21B5B09570

RUN apt-get update -qq && apt-get install -y -qq wget ca-certificates gnupg && rm -rf /var/lib/apt/lists/*

# Download tarball + detached signature, import the pinned release key,
# and verify. Any mismatch or missing signature fails the build.
RUN wget -q "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
         -O /tmp/signal-cli.tar.gz && \
    wget -q "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz.asc" \
         -O /tmp/signal-cli.tar.gz.asc && \
    mkdir -p /tmp/gnuph && chmod 700 /tmp/gnuph && \
    GNUPGHOME=/tmp/gnuph gpg --batch --no-tty --keyserver hkps://keys.openpgp.org --recv-keys "${SIGNAL_CLI_GPG_FINGERPRINT}" && \
    GNUPGHOME=/tmp/gnuph gpg --batch --no-tty --list-keys "${SIGNAL_CLI_GPG_FINGERPRINT}" | grep -q "${SIGNAL_CLI_GPG_FINGERPRINT}" || { echo "FATAL: signing key fingerprint mismatch" >&2; exit 1; } && \
    GNUPGHOME=/tmp/gnuph gpg --batch --no-tty --verify /tmp/signal-cli.tar.gz.asc /tmp/signal-cli.tar.gz && \
    mkdir -p /opt/signal-cli/bin && \
    tar xzf /tmp/signal-cli.tar.gz -C /opt/signal-cli/bin && \
    rm -rf /tmp/gnuph /tmp/signal-cli.tar.gz /tmp/signal-cli.tar.gz.asc && \
    test -x /opt/signal-cli/bin/signal-cli && \
    chmod +x /opt/signal-cli/bin/signal-cli

# Stage 2: secured-signal-api proxy binary
FROM golang:1.26-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS proxy-builder

ARG SECURED_PROXY_VERSION=v1.6.2
ARG TARGETARCH
ARG TARGETOS=linux

RUN apk add --no-cache git ca-certificates && \
    git clone --depth 1 --branch ${SECURED_PROXY_VERSION} \
        https://github.com/CodeShellDev/secured-signal-api.git /build && \
    cd /build && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 \
    go build -ldflags="-s -w -X main.version=${SECURED_PROXY_VERSION}" \
    -o /opt/secured-signal-api .

# Stage 3: final runtime image
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# Install runtime deps: socat for unix-socket mode, gosu for non-root
RUN apt-get update -qq && apt-get install -y -qq \
        socat \
        gosu \
        ca-certificates \
        curl \
        qrencode \
        && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r signal && useradd -r -g signal -d /opt/signal-cli-data -s /sbin/nologin signal

# Runtime dirs that need to exist (and be signal-owned) before start.
# /var/run/signal-cli holds the UNIX socket in SECURITY_MODE=unix;
# /tmp is used by curl/gosu children.
RUN mkdir -p /var/run/signal-cli /tmp && \
    chown -R signal:signal /var/run/signal-cli

# Copy signal-cli native binary (already extracted into /opt/signal-cli/bin/signal-cli in stage 1)
COPY --from=signal-cli-builder /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli
RUN chmod +x /usr/local/bin/signal-cli

# Copy secured-signal-api proxy binary (optional)
COPY --from=proxy-builder /opt/secured-signal-api /opt/secured-signal-api/secured-signal-api
RUN chmod +x /opt/secured-signal-api/secured-signal-api

# Copy entrypoint and helper scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Create data and config directories
RUN mkdir -p /opt/signal-cli-data /config && \
    chown -R signal:signal /opt/signal-cli-data /config

# Volumes
VOLUME ["/opt/signal-cli-data", "/config"]

# Ports (proxy binds here by default, signal-cli on 8080 internally)
EXPOSE 8880 8080

# -----------------------------------------------------------------------------
# WHY PID 1 RUNS AS ROOT
# The entrypoint must (a) chown the mounted data volume to the `signal` user
# (host bind mounts can carry arbitrary uid/gid) and (b) use gosu to drop
# privileges into `signal` for signal-cli, secured-signal-api, and socat.
# Every long-running process is therefore executed as `signal` via gosu;
# root exists only for this bootstrap. Combine with cap_drop: [ALL] and
# no-new-privileges in compose.yaml / unraid-template.xml.
# -----------------------------------------------------------------------------

# Health check — verifies the proxy endpoint is reachable, falls back to daemon
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://127.0.0.1:${PROXY_PORT:-8880}/api/v1/check || curl -sf http://127.0.0.1:${SIGNAL_CLI_PORT:-8080}/api/v1/check || exit 1

# Entrypoint
ENTRYPOINT ["/scripts/entrypoint.sh"]
