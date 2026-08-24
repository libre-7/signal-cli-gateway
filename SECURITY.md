# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| `:latest` (main branch) | ✅ |
| Version tags (`vX.Y.Z`) | ✅ |
| Feature branch tags | ⚠️ Unstable — development only |

## Reporting a Vulnerability

If you discover a security vulnerability in signal-cli-gateway, please **do not** open a public GitHub issue.

Please report it privately via GitHub Security Advisories:

1. Go to the [Security tab](https://github.com/libre-7/signal-cli-gateway/security)
2. Click **Report a vulnerability**
3. Describe the issue with as much detail as possible

You can also email **libre7@proton.me** with the details.

### What to include

- A clear description of the vulnerability
- Steps to reproduce or a proof-of-concept
- Affected versions or configurations
- Potential impact to users

### What to expect

- **Acknowledgment:** Within 48 hours
- **Assessment:** Within 7 days — we'll evaluate severity and confirm whether it applies
- **Fix timeline:** Critical issues will be patched as quickly as possible, typically within 2–4 weeks depending on complexity
- **Disclosure:** We'll coordinate public disclosure with you. You'll be credited in the release notes unless you prefer to remain anonymous

### Out of scope

- Issues that require physical access to the host machine
- Vulnerabilities in upstream projects (signal-cli, secured-signal-api) — please report those to the respective projects directly
- Theoretical attacks that require the attacker to already have root on the Docker host

## Security-relevant Configuration

The following environment variables and settings directly affect the security posture of the container:

| Setting | Effect |
|---------|--------|
| `SECURITY_MODE` | Controls which components are exposed and how. `loopback` is the minimum, `loopback-proxy` adds auth, `exposed-proxy` opens to the network. |
| `SECURITY_PROXY_TOKEN` | Bearer token for proxy authentication. Auto-generated if empty (logged once at startup). |
| `SECURITY_PROXY_ALLOWED_IPS` | CIDR ranges that bypass proxy auth. Default: `127.0.0.1,172.0.0.0/8,10.0.0.0/8` (narrowing tracked in issue #5). |
| `SIGNAL_CLI_PORT` | Internal daemon port. Always bound to loopback in proxy modes. |
| `SIGNAL_CLI_TRUST_NEW_IDENTITIES` | Controls automatic trust of new Signal identity keys. Default: `on-first-use`. |

The container runs as a non-root `signal` user at runtime. The config volume (`/opt/signal-cli-data`) contains Signal identity keys and should be treated as sensitive.
