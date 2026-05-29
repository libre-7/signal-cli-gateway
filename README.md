# signal-cli-gateway

**Configurable, security-hardened Docker container for signal-cli daemon.**
Designed for Hermes Agent integration and other automation use cases.

## Quick Start

```bash
# 1. Build the image
docker build -t signal-cli-gateway .

# 2. Link your phone (one-time setup)
mkdir -p signal-cli-data
docker run --rm -it \
  -v "$(pwd)/signal-cli-data:/opt/signal-cli-data" \
  -e DEVICE_NAME=HermesAgent \
  signal-cli-gateway \
  bash /scripts/link-account.sh

# Scan the QR code from Signal → Settings → Linked Devices

# 3. Run the daemon
docker run -d --name signal-cli-gateway --restart unless-stopped \
  --network host \
  -v "$(pwd)/signal-cli-data:/opt/signal-cli-data" \
  -e SIGNAL_ACCOUNT=+123****7890 \
  -e SECURITY_MODE=loopback-proxy \
  -e SECURITY_PROXY_TOKEN=my-secret-token \
  signal-cli-gateway

# 4. Configure Hermes
# SIGNAL_HTTP_URL=http://127.0.0.1:8880
# SIGNAL_ACCOUNT=+123****7890
# (Hermes connects to the proxy — IP allowlist bypasses auth)
```

## Security Modes

| Mode | Env Var | signal-cli | Exposed | Auth | Proxy | Use Case |
|------|---------|------------|---------|------|-------|----------|
| **Loopback** | `loopback` | 127.0.0.1:8080 | ❌ | None | No | Hermes on host networking, trusted LAN |
| **Loopback + Proxy** | `loopback-proxy` | 127.0.0.1:8080 | 127.0.0.1:8880 (proxy) | Bearer + IP allowlist | **secured-signal-api** | ✅ **Recommended default** |
| **Exposed + Proxy** | `exposed-proxy` | 127.0.0.1:8080 | 0.0.0.0:8880 (proxy) | Bearer + IP allowlist | **secured-signal-api** | Multi-host, Kubernetes, cloud |
| **UNIX Socket** | `unix` | `/var/run/signal-cli/socket` | Socat bridge 127.0.0.1:8080 | File perms | Socat | Maximum process isolation |

### Why loopback-proxy is the default

1. **signal-cli is never exposed** — binds to 127.0.0.1, unreachable from other containers
2. **Authentication on every proxied request** — Bearer token or Basic Auth required
3. **Dangerous endpoints blocked by default** — `/v1/register`, `/v1/qrcodelink`, `/v1/configuration`, `/v1/unregister`, etc.
4. **IP allowlist for Hermes** — trusted IPs bypass auth so Hermes' `signal.py` adapter works unpatched
5. **Auto-generated random token** — if you don't set `SECURITY_PROXY_TOKEN`, one is generated and logged at startup

## Architecture

```
loopback mode:
  signal-cli daemon → 127.0.0.1:8080 (loopback, TCP)

loopback-proxy mode:
  signal-cli daemon → 127.0.0.1:8080 (loopback, unreachable)
       ↑ (proxied, secured)
  secured-signal-api → 127.0.0.1:8880 (Bearer auth + IP allowlist)
       ↑
  Hermes → 127.0.0.1:8880 (IP is trusted, no auth needed)

exposed-proxy mode:
  signal-cli daemon → 127.0.0.1:8080 (loopback, unreachable)
       ↑ (proxied, secured)
  secured-signal-api → 0.0.0.0:8880 (Bearer auth + IP allowlist)
       ↑
  Any client → <host>:8880 (Bearer token required)

unix mode:
  signal-cli daemon → /var/run/signal-cli/socket
       ↑ (socat bridge)
  socat → 127.0.0.1:8080 (loopback, TCP)
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| **Required** | | |
| `SIGNAL_ACCOUNT` | — | Your Signal number in E.164 format (e.g. +123****7890) |
| **Security** | | |
| `SECURITY_MODE` | `loopback` | One of: `loopback`, `loopback-proxy`, `exposed-proxy`, `unix` |
| `SECURITY_PROXY_TOKEN` | auto-generated | Bearer token for proxy authentication |
| `SECURITY_PROXY_ALLOWED_IPS` | `127.0.0.1,172.0.0.0/8,10.0.0.0/8` | CIDR ranges that bypass proxy auth |
| **Ports** | | |
| `SIGNAL_CLI_PORT` | `8080` | signal-cli daemon port |
| `PROXY_PORT` | `8880` | secured-signal-api proxy port |
| **signal-cli options** | | |
| `SIGNAL_CLI_TRUST_NEW_IDENTITIES` | `on-first-use` | `on-first-use`, `always`, `never` |
| `SIGNAL_CLI_IGNORE_ATTACHMENTS` | `false` | |
| `SIGNAL_CLI_IGNORE_STORIES` | `true` | |
| `SIGNAL_CLI_IGNORE_AVATARS` | `true` | |
| `SIGNAL_CLI_IGNORE_STICKERS` | `true` | |
| **Account linking** | | |
| `DEVICE_NAME` | `SignalGateway` | Name shown in Signal's linked device list |

## Hermes Agent Integration

Once the gateway is running, add these to your Hermes `.env`:

```bash
# If gateway uses host networking:
SIGNAL_HTTP_URL=http://127.0.0.1:8880
SIGNAL_ACCOUNT=+123****7890
SIGNAL_HOME_CHANNEL=+123****7890

# Or if gateway is a separate container on a Docker network:
# SIGNAL_HTTP_URL=http://signal-cli-gateway:8880
```

Hermes connects to the proxy on port 8880. If Hermes' container IP is in the
`SECURITY_PROXY_ALLOWED_IPS` list, no Bearer token is needed — the proxy trusts
the connection source. All other callers must authenticate.

**No Hermes adapter patches needed.** The built-in `gateway/platforms/signal.py`
works as-is when the IP is allowlisted.

## Advanced: Custom Endpoint Restrictions

Mount your own `config.yml` to `/config/config.yml` to override default
endpoint blocking, add rate limiting, field policies, or message templates.
See [secured-signal-api docs](https://codeshelldev.github.io/secured-signal-api)
for the full configuration reference.

```bash
docker run -d --name signal-cli-gateway --restart unless-stopped \
  --network host \
  -v "$(pwd)/signal-cli-data:/opt/signal-cli-data" \
  -v "$(pwd)/custom-config.yml:/config/config.yml" \
  -e SIGNAL_ACCOUNT=+123****7890 \
  -e SECURITY_MODE=loopback-proxy \
  signal-cli-gateway
```

## Linking Your Phone (Step-by-Step)

```bash
mkdir -p /mnt/user/appdata/signal-cli-data

# Run link in interactive mode
docker run --rm -it \
  -v /mnt/user/appdata/signal-cli-data:/opt/signal-cli-data \
  -e DEVICE_NAME=HermesAgent \
  signal-cli-gateway \
  bash /scripts/link-account.sh
```

This prints a URI like:
```
sgnl://linkdevice?uuid=XXXX&pub_key=YYYY
```

On a headless system, convert to a QR:
```bash
# Install qrencode or use a container:
echo 'sgnl://linkdevice?uuid=XXXX&pub_key=YYYY' | \
  docker run --rm -i appropriate/curl qrencode -t ANSI256
```

Scan from your phone: **Signal → Settings → Linked Devices → +**.

## Build Options

The Dockerfile builds `secured-signal-api` from source. To skip the proxy
(leaner image, no Go build needed):

```bash
docker build --target signal-cli-builder -t signal-cli-gateway:no-proxy .
# Copy from stage 1 into a final Ubuntu base
```

## Design

See [DESIGN.md](DESIGN.md) for the full security analysis, threat model, and
comparison of all approaches considered.

## License

GNU General Public License v3.0
