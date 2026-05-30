# =============================================================================
# signal-cli-gateway
# Multi-stage Docker build for signal-cli daemon with optional secured-signal-api
# proxy layer for authentication and endpoint security.
# =============================================================================
# Stage 1: signal-cli native binary
FROM ubuntu:24.04 AS signal-cli-builder

ARG SIGNAL_CLI_VERSION=0.14.3

RUN apt-get update -qq && apt-get install -y -qq wget ca-certificates && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
         -O /tmp/signal-cli.tar.gz && \
    tar xzf /tmp/signal-cli.tar.gz -C /opt && \
    rm /tmp/signal-cli.tar.gz && \
    test -x /opt/signal-cli

# Stage 2: secured-signal-api proxy binary
FROM golang:1.26-alpine AS proxy-builder

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
FROM ubuntu:24.04

# Install runtime deps: socat for unix-socket mode, gosu for non-root
RUN apt-get update -qq && apt-get install -y -qq \
        socat \
        gosu \
        ca-certificates \
        curl \
        && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r signal && useradd -r -g signal -d /opt/signal-cli-data -s /sbin/nologin signal

# Copy signal-cli native binary (from native tarball — single flat file)
COPY --from=signal-cli-builder /opt/signal-cli /opt/signal-cli/bin/signal-cli
RUN ln -sf /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli

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

# Entrypoint
ENTRYPOINT ["/scripts/entrypoint.sh"]
