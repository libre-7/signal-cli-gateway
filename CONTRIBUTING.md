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

## Registry flow

On push to `main`, the image is pushed to GHCR (`ghcr.io/libre-7/signal-cli-gateway`).
