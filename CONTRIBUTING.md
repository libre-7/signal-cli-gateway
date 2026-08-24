# Contributing to signal-cli-gateway

Thanks for contributing! This document covers how to submit changes and the conventions in use.

## Quick start

1. Fork the repo and clone it
2. Create a branch: `fix/descriptive-name` or `feat/descriptive-name`
3. Make your changes
4. Push and open a PR against `main`

## Commit messages

Use conventional commit prefixes:

```
fix: describe what was broken and how it's fixed
feat: describe the new capability
docs: documentation only
```

Reference issues in the body (`Refs #N`) rather than the subject line.

## Branch naming

```
fix/security-mode-ip-range
feat/healthcheck-support
docs/network-mode-clarification
```

Hyphens, lowercase, descriptive.

## Dockerfile conventions

- Base images are digest-pinned for reproducibility
- Downloaded binaries are integrity-verified (checksum/GPG verification; tracked in issue #5)
- `apt-get install` includes cleanup in the same layer (`rm -rf /var/lib/apt/lists/*`)
- Multi-stage builds minimize final image size

## Shell script conventions

- `#!/usr/bin/env bash` with `set -euo pipefail`
- SPDX header where applicable
- Graceful shutdown via `trap` + `cleanup` function
- No secrets in `/proc/PID/cmdline`

## Version scheme

- Images are tagged with semver (`vX.Y.Z`), branch names, and commit SHAs
- The `:latest` tag follows `main`
- SHA-pinned tags are immutable

## Dependency version bumps

Dependabot does **not** track the pinned versions in this repo:

- `ARG SIGNAL_CLI_VERSION` in the `Dockerfile`
- `ARG SECURED_PROXY_VERSION` in the `Dockerfile`
- Base image digest pins (`FROM ...@sha256:...`)
- GitHub Action SHA pins in `.github/workflows/`

These must be bumped manually. Recommended cadence: **quarterly**, or
sooner when a security release lands (signal-cli especially — releases
older than ~3 months may break against Signal server protocol changes).

Manual bump procedure:

1. Check latest releases:
   - signal-cli: https://github.com/AsamK/signal-cli/releases
   - secured-signal-api: https://github.com/CodeShellDev/secured-signal-api/releases
2. Update the `ARG ..._VERSION=` values in the `Dockerfile`.
3. Recompute base image digests (`docker buildx imagetools inspect <image>`) and update the `@sha256:` pins.
4. Rebuild locally and run a smoke test (link + send) before opening the PR.

## Registry flow

On push to `main`, the image is pushed to GHCR (`ghcr.io/libre-7/signal-cli-gateway`).
