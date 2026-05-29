# signal-cli-gateway: Design Document

## Purpose

A configurable, security-hardened Docker container for running the signal-cli
daemon in server environments. Designed as a drop-in companion for Hermes Agent,
but usable with any automation that needs Signal messaging.

---

## 1. Threat Model

Before evaluating approaches, define what we're protecting against.

### Assets
- **Signal account credentials** (private key material stored in `--config` dir)
- **Message content** flowing between Hermes ↔ signal-cli daemon
- **Control surface** (ability to send/receive as the linked Signal account)
- **Phone number linkage** (the daemon knows your Signal number)

### Threat Actors
| Actor | Access Level | Example |
|-------|-------------|---------|
| **LAN peer** | On the same subnet/network | Another Unraid container, a compromised IoT device |
| **Same-host container** | On the same Docker host, possibly bridged | Guest containers, malicious workloads |
| **External network** | Can reach the host IP on the exposed port | WAN attacker if port-forwarded, cloud metadata |
| **Compromised Hermes** | Running under the same gateway profile | Agent prompt injection through tool calls |

### Security Goals (Ranked)
1. Prevent unauthorized **sending** of messages as the linked account
2. Prevent unauthorized **reading** of inbound messages
3. Prevent **account hijacking** via exposed management endpoints
4. Protect **credentials at rest** in the config volume
5. Protect **traffic in transit** between Hermes and the daemon

---

## 2. Approaches to Securing the signal-cli Daemon

Each approach is evaluated along: **threat coverage**, **complexity**, **compatibility
with Hermes**, and **general applicability**.

### Approach 0: Raw Daemon (Baseline)

```
signal-cli daemon --http 0.0.0.0:8080
```

**How it works:** signal-cli's HTTP daemon exposes three unauthenticated endpoints:
- `POST /api/v1/rpc` — JSON-RPC method calls (send, list groups, etc.)
- `GET  /api/v1/events` — SSE stream of all inbound messages
- `GET  /api/v1/check` — Health check

**Threat coverage:**
- ❌ No authentication — anyone who can reach the port owns your Signal account
- ❌ No TLS — traffic in cleartext
- ❌ No endpoint filtering — `register`, `link`, `send` all exposed
- ✅ E2E encryption intact between daemon and Signal servers

**Complexity:** Zero.

**Hermes compatibility:** ✅ Direct — `SIGNAL_HTTP_URL=http://daemon:8080`

**Verdict:** Baseline only. Not safe for anything but localhost.

---

### Approach 1: Loopback Binding

```
signal-cli daemon --http 127.0.0.1:8080
```

**Change from baseline:** Bind to loopback only.

**Threat coverage:**
- ✅ Blocks all remote network access (LAN, external)
- ✅ Only same-host processes can reach it
- ❌ No auth between same-host callers — **any** container on `--network host` can use it
- ❌ No TLS

**Complexity:** Trivial (change interface address).

**Hermes compatibility:** ✅ Requires either `--network host` sharing (both containers) or an SSH/socat tunnel.

**Verdict:** Good **minimum** for single-user, single-host-network setups. Assumes all other containers on the host are trusted.

---

### Approach 2: UNIX Socket

```
signal-cli daemon --socket /var/run/signal-cli/socket
```

**How it works:** JSON-RPC over a UNIX domain socket. Access controlled by
filesystem permissions (`chmod 600`).

**Threat coverage:**
- ✅ No network exposure at all — not reachable via TCP/IP
- ✅ File permission control — only the right UID/GID can connect
- ❌ No TLS (not applicable — socket is kernel-isolated)
- ❌ Hermes adapter doesn't support UNIX sockets natively

**Complexity:** Medium. Requires socat bridge since Hermes expects HTTP:

```
socat TCP-LISTEN:127.0.0.1:8080,fork,reuseaddr \
      UNIX-CONNECT:/var/run/signal-cli/socket
```

**Hermes compatibility:** ⚠️ Requires socat bridge. Adds a sidecar process.

**Verdict:** Best for host-native installations. Equivalent to loopback+auth for
Docker setups after the socat bridge. The socat bridge re-exposes TCP, so the
net security gain vs. loopback binding is marginal for this use case.

---

### Approach 3: Reverse Proxy (Caddy / nginx)

```
[Caddy:8081] ← TLS + Basic Auth → [signal-cli:127.0.0.1:8080]
```

**How it works:** A reverse proxy sits in front of signal-cli, terminating TLS
and enforcing HTTP Basic Auth. signal-cli binds to `127.0.0.1:8080` only.

Caddy configuration:
```caddyfile
:8081 {
    basicauth {
        hermes $2a$14$HASHED_PASSWORD
    }
    reverse_proxy http://127.0.0.1:8080
}
```

**Threat coverage:**
- ✅ Authentication (Basic Auth)
- ✅ TLS termination (Caddy auto-provisions Let's Encrypt certs)
- ✅ Blocks unauthorized callers at the proxy layer
- ❌ signal-cli management endpoints still reachable (no endpoint filtering)
- ⚠️ Caddy must be managed/updated separately

**Complexity:** Medium. Docker multi-stage build adds Caddy binary.

**Hermes compatibility:** ❌ **Hermes' `signal.py` adapter does not support HTTP
Basic Auth or Bearer tokens.** The adapter constructs URLs directly:

```python
self.base_url = config.get("SIGNAL_HTTP_URL")
# Then calls:
await client.get(f"{self.base_url}/api/v1/events")
```

Without patching Hermes, you cannot use proxy auth. Workarounds:
1. **IP allowlisting** on the proxy — Hermes' IP bypasses auth (defeats purpose)
2. **Patch Hermes adapter** — add `SIGNAL_AUTH_TOKEN` env var
3. **Use Basic Auth in URL** `http://user:pass@proxy:8081` — may work depending on `httpx` handling

**Verdict:** Good general approach but poor Hermes compatibility without adapter
patches. Nginx is equivalent to Caddy here.

---

### Approach 4: Application-Layer Proxy (secured-signal-api)

```
[secured-signal-api:8880] ← Bearer/IP auth → [signal-cli:127.0.0.1:8080]
```

**Project:** [secured-signal-api](https://github.com/codeshelldev/secured-signal-api)
(Go, MIT, 28 stars, actively maintained, 34 releases as of May 2026)

**What it adds over a generic reverse proxy:**

| Feature | Nginx/Caddy | secured-signal-api |
|---------|-------------|-------------------|
| Bearer/Basic/Body/Query/Path auth | Basic Auth only | 5 auth methods |
| IP allowlisting | Via config | Built-in |
| Endpoint blocking | Manual location blocks | Built-in (blocks `/v1/register`, `qrcodelink`, etc.) |
| Per-token config overrides | ❌ | ✅ |
| Rate limiting | Manual via plugins | Built-in |
| Field policies (block specific numbers) | ❌ | ✅ |
| Message templates with placeholders | ❌ | ✅ |
| Trusted proxy support | Via headers | Built-in |

**Threat coverage:**
- ✅ Multi-method authentication (Bearer, Basic, etc.)
- ✅ Endpoint-level access control — blocks dangerous endpoints by default
- ✅ IP allowlisting — Hermes container can bypass auth via IP
- ✅ Rate limiting prevents abuse
- ✅ Field policies prevent specific phone numbers from being used as recipients
- ❌ No TLS built-in (but can run behind another reverse proxy)
- ✅ Actively maintained (last release April 2026)

**Complexity:** Low-Medium. Single Go binary, easy to add to multi-stage Docker build.

**Hermes compatibility:** ⚠️ Same auth issue as Approach 3 — adapter doesn't
support tokens. **But** `secured-signal-api` supports `trustedIPs`, allowing the
Hermes container to bypass auth if on a known IP. This is the cleanest solution:

```yaml
settings:
  access:
    trustedIPs:
      - 172.17.0.0/16     # Docker bridge
      - 127.0.0.1
      - 192.168.1.0/24    # Local LAN (optional)
```

With this, Hermes connects unauthenticated to the proxy, while any other caller
must present a Bearer token. The proxy still blocks dangerous endpoints even for
trusted IPs.

**Verdict:** Best option for Docker environments. Purpose-built for this use case.
The IP allowlisting solves the Hermes auth gap cleanly.

---

### Approach 5: SSH Tunnel (Remote Daemon)

```
[local Hermes] ← SSH tunnel → [remote signal-cli:127.0.0.1:8080]
```

**When you'd use this:** signal-cli runs on a separate machine or in a
container with no host-network sharing. The Hermes container establishes
a reverse SSH tunnel to forward the remote daemon's port to localhost.

**Threat coverage:**
- ✅ Traffic encrypted over SSH
- ✅ Only the tunnel user can access it
- ✅ No additional services exposed

**Complexity:** High. SSH key management, `autossh` for resilience, `GatewayPorts`
configuration.

**Hermes compatibility:** ✅ Works transparently — appears as `127.0.0.1:8080` locally.

**Verdict:** Niche but useful pattern for multi-host setups. Not the primary approach.

---

### Approach 6: WireGuard Tunnel (Remote Daemon)

```
[local Hermes] ← WireGuard → [remote signal-cli:127.0.0.1:8080]
```

Virtually identical to SSH tunnel in outcome but uses kernel-level encrypted
tunneling. Better performance, worse portability (needs kernel module or
userspace implementation).

**Verdict:** Overkill for this use case. SSH tunnel is simpler.

---

## 3. Summary Comparison

| Approach | Auth | TLS | Hermes Compat | Complexity | Docker-native |
|----------|------|-----|--------------|------------|---------------|
| 0: Raw 0.0.0.0 | ❌ | ❌ | ✅ Direct | None | ✅ |
| 1: Loopback | ❌ | ❌ | ✅ Host-net | Trivial | ✅ |
| 2: UNIX socket | File perms | N/A | ⚠️ Socat | Medium | ✅ |
| 3: Caddy reverse proxy | Basic | ✅ | ❌ Needs patch | Medium | ✅ |
| **4: secured-signal-api** | **Bearer+IP** | ❌* | **✅ Via IP allowlist** | **Low** | **✅** |
| 5: SSH tunnel | SSH key | ✅ | ✅ Transparent | High | ⚠️ |
| 6: WireGuard | WG key | ✅ | ✅ Transparent | High | ⚠️ |

\* *TLS can be added by placing another reverse proxy in front, or using
secured-signal-api's own TLS support if available.*

---

## 4. Recommended Design: Composite with Modes

The final container should support multiple **security modes** selected via
environment variable. This gives users choice based on their threat model and
infrastructure.

### Mode Definitions

| Mode | `SECURITY_MODE` | Components Exposed | Auth | Use Case |
|------|-----------------|-------------------|------|----------|
| **loopback** | `loopback` | `127.0.0.1:8080` | None | Hermes on host networking. Trusted environment. |
| **loopback-proxy** | `loopback-proxy` | `127.0.0.1:8880` (proxy only) | Bearer + IP allowlist | Hermes on host networking + auth. Default recommended. |
| **exposed-proxy** | `exposed-proxy` | `0.0.0.0:8880` (proxy only) | Bearer + IP allowlist | Multi-host setups, Kubernetes, cloud. Proxy handles access control. |
| **unix** | `unix` | `/var/run/signal-cli/socket` | File permissions + socat bridge | Maximum isolation on single host. |

### Architecture per Mode

```
loopback:
  signal-cli → 127.0.0.1:8080 (no auth)

loopback-proxy:
  signal-cli → 127.0.0.1:8080 (loopback, unreachable)
       ↑
  secured-signal-api → 127.0.0.1:8880 (Bearer auth, IP allowlist)
       ↑
  Hermes → 127.0.0.1:8880 (no auth needed, IP is trusted)

exposed-proxy:
  signal-cli → 127.0.0.1:8080 (loopback, unreachable)
       ↑
  secured-signal-api → 0.0.0.0:8880 (Bearer auth, IP allowlist)
       ↑
  Hermes/cURL/scripts → proxy:8880 (with Bearer token)

unix:
  signal-cli → /var/run/signal-cli/socket
       ↑ (socat bridge)
  socat → 127.0.0.1:8080
       ↑
  Hermes → 127.0.0.1:8080
```

### Environment Variable Interface

```bash
# -- Required --
SIGNAL_ACCOUNT=+1234567890     # Your Signal number (E.164)

# -- Security Mode (default: loopback) --
SECURITY_MODE=loopback          # Options: loopback, loopback-proxy, exposed-proxy, unix

# -- Security Mode: proxy auth (for loopback-proxy / exposed-proxy) --
SECURITY_PROXY_TOKEN=          # Bearer token for proxy auth (auto-generated if empty)
SECURITY_PROXY_ALLOWED_IPS=    # CIDRs that bypass auth (default: 127.0.0.1, 172.0.0.0/8)
SECURITY_PROXY_BLOCK_ENDPOINTS= # Additional endpoints to block (comma-separated)

# -- Security Mode: loopback / unix --
SIGNAL_CLI_PORT=8080           # signal-cli daemon port (default: 8080)
SIGNAL_CLI_BIND=127.0.0.1     # Bind address (default: 127.0.0.1)

# -- Signal daemon options --
SIGNAL_CLI_TRUST_NEW_IDENTITIES=on-first-use  # on-first-use, always, never
SIGNAL_CLI_IGNORE_ATTACHMENTS=false
SIGNAL_CLI_IGNORE_STORIES=true
```

---

## 5. Why This Design Wins

### Security is not optional
Every mode except `exposed` (which is explicitly labeled as requiring auth) binds
to loopback. Even in `loopback-proxy` mode, signal-cli binds to 127.0.0.1 and
only the proxy is reachable. The proxy enforces authentication.

### Hermes compatibility without patches
The `loopback-proxy` mode uses `secured-signal-api`'s IP allowlisting. Hermes
connects without auth, but only because its IP is trusted. All other callers
must present a Bearer token. No Hermes adapter patches needed.

### Progressive security
Users can start with `loopback` for testing, graduate to `loopback-proxy` for
production, and eventually add TLS with an external reverse proxy on top of
`loopback-proxy`.

### Clear failure modes
If `SECURITY_MODE` is set to a value that requires a proxy but the proxy binary
is missing (e.g., built without proxy support), the entrypoint exits with a
clear error message rather than silently degrading security.

### Credentials at rest
The config volume (`/opt/signal-cli-data`) contains the Signal identity keys.
The container runs as a non-root user. No other container on the host can read
this volume without explicit Docker volume sharing.

---

## 6. Docker Build Strategy

The Dockerfile uses **multi-stage builds** to minimize final image size:

```
Stage 1: signal-cli-builder
  - Downloads signal-cli native binary from GitHub releases
  - Extracts to /opt/signal-cli

Stage 2: secured-proxy-builder (conditional)
  - Downloads secured-signal-api binary from GitHub releases
  - Extracts to /opt/secured-proxy

Stage 3: final
  - Ubuntu 24.04 (glibc required for native signal-cli)
  - Copies binaries from stages 1 and 2
  - Installs socat (for unix mode)
  - Installs gosu (for non-root user switching)
  - Entrypoint script handles mode switching
```

**Image size estimates:**
- `loopback` mode only: ~420MB (340MB signal-cli + 80MB Ubuntu)
- `loopback-proxy` mode: ~440MB (signal-cli + ~20MB Go binary)
- Alpine is not feasible for native signal-cli (requires glibc)

---

## 7. Alternative Approaches Considered and Rejected

### Rejected: JVM-based signal-cli for Tor proxy support
**Why:** The native build is simpler, faster, and doesn't require a JDK at
runtime. The JVM build supports SOCKS proxy for Tor routing, but this can be
achieved with the native build using `proxychains4` as a wrapper. The native
build's 10x faster startup and lower memory usage outweigh the Tor routing
convenience. Users who need Tor can wrap the container with `proxychains4`.

### Rejected: HAProxy as proxy layer
**Why:** HAProxy doesn't support Bearer token auth natively. Would require
Lua scripting or external auth. Caddy or nginx with auth_request is simpler
if you want a generic reverse proxy. But `secured-signal-api` is purpose-built
and wins on both features and simplicity.

### Rejected: Separate proxy container (multi-container)
**Why:** The user asked for a single container. Multi-container adds orchestration
overhead (Docker Compose, health checks, dependency ordering). The entrypoint
manages both signal-cli and the proxy as child processes using signal forwarding.

### Rejected: SSH tunnel as primary approach
**Why:** Adds SSH key management complexity. Good for niche multi-host setups
but not the default. Can be documented as an advanced configuration but not
the primary design.

---

## 8. Operational Notes

### Account Linking
Account linking (QR code scan from phone) is a **one-time setup step**, not
part of the daemon runtime. The container provides `scripts/link-account.sh`
for this.

```bash
docker run --rm -it \
  -v signal-cli-data:/opt/signal-cli-data \
  signal-cli-gateway \
  bash /scripts/link-account.sh
```

This runs `signal-cli link -n "SignalGateway"` and prints the QR URI.

### Health Checks
```bash
# Daemon health
curl -f http://127.0.0.1:8080/api/v1/check

# Proxy health (if enabled)
curl -f http://127.0.0.1:8880/api/v1/check
```

### Logging
signal-cli logs go to stdout/stderr. The proxy logs at `info` level by default.
Set `LOG_LEVEL=debug` for troubleshooting.

### Updates
signal-cli needs to stay current — releases older than 3 months may break due
to Signal server protocol changes. The Dockerfile pins a specific version for
reproducibility. Users should periodically rebuild with the latest release tag.

---

## 9. Conclusion

The recommended approach — a multi-mode Docker container with `secured-signal-api`
as optional auth layer — balances security, flexibility, and Hermes compatibility
better than any single alternative. The env-var-driven mode selection lets users
choose their risk posture without forking the project.

For the default recommended setup:
- `SECURITY_MODE=loopback-proxy`
- Hermes connects on `127.0.0.1:8880` (host networking) or `signal-cli-gateway:8880` (Docker bridge)
- Bearer token + IP allowlisting protects the proxy
- signal-cli itself is unreachable, bound to 127.0.0.1:8080
- Dangerous endpoints (`/v1/register`, `/v1/qrcodelink`, etc.) blocked by proxy
