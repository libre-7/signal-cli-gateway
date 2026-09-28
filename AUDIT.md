# Comprehensive Code Review — signal-cli-gateway

**Base:** `main` @ `0192ade` (v1.0.0 + Dependabot #7/#8) — 21 files, 2,546 lines, all read in full.
**Date:** 2026-09-27
**Supersedes:** 2026-08-21 review (`main` @ `2797b2b`). That review's 18 findings were remediated in
PR #6 (`55273e9`) and issue #5 closed 2026-08-24 — **all confirmed fixed** (details below).

---

## Method & verification standard

Every finding below is either **VERIFIED** (reproduced by execution, or read from source with the
mechanism proven end to end against the actual upstream binary's source) or explicitly marked
**PLAUSIBLE** where execution was impossible in this environment (no Docker daemon, `unshare`
denied). Refuted suspicions are listed so they aren't re-audited.

**Verification performed:**
- Full read of all 21 files (Dockerfile, 5 shell scripts, compose.yaml, CI workflow, Unraid
  template, README/DESIGN/SECURITY/CONTRIBUTING, configs).
- Cloned **secured-signal-api v1.6.2** source and read the Go config structs + middleware to verify
  the generated `config.yml` against the real schema and the real `ipFilter` block logic.
- **GPG signature verification** of the real signal-cli 0.14.7 release tarball against the key the
  Dockerfile pins → `Good signature`. Supply-chain control confirmed working.
- Extracted `write_proxy_config()` and **executed it** to inspect generated YAML for both bind modes.
- `shellcheck` (all scripts) + `bash -n` (all scripts) + YAML parse of generated config.
- GitHub API: release assets for 0.14.7/0.14.8, real latest tags for all 5 pinned CI actions,
  CI run history, open/closed issues + PRs, remote branch list.
- Ubuntu noble `Packages.gz`: authoritative `Depends:` chains for the runtime apt packages.

**Environment limits (stated, not assumed):** no Docker daemon → the image was never built or run;
`unshare` denied → Linux capability semantics tested by documentation + code, not by execution.

---

## Severity Summary

| Severity | Count | Headline |
|---|---|---|
| 🚨 Critical | 1 | Unraid template `--cap-drop=ALL` with no `cap_add` ⇒ **gosu cannot drop privileges ⇒ container cannot start** |
| 🔴 High | 4 | README's documented custom-config feature is impossible; `deploy-unraid.sh` prints ❌ FAIL in the default mode; signal-cli pin 1 minor version behind; `--network host` claim wrong for `exposed-proxy` in README |
| 🟡 Medium | 5 | No restart supervision; tmpfs uid 999 hardcoded vs dynamic `useradd -r`; CI lost arm64 silently; SC2034; `.env.example` drift |
| 🟢 Low | 6 | Step mislabeling, `\\` echo bug, unused `TARGETARCH` in single-arch build, no trailing newline, missing `.gitignore`, stale `--rm -it` guidance |

---

## 🚨 CRITICAL

### C1. Unraid template drops ALL capabilities and adds none back — the container cannot start

**File:** `unraid-template.xml:11`
**Evidence (VERIFIED — code + cross-file contradiction):**
```xml
<ExtraParams>--cap-drop=ALL --security-opt no-new-privileges=true --memory=512m</ExtraParams>
```
`compose.yaml:76-82` adds the capabilities the entrypoint needs, **with a comment naming the reason**:
```yaml
cap_drop: [ALL]
cap_add: [CHOWN, SETUID, SETGID, FOWNER, DAC_OVERRIDE]   # "chown of the data volume; setuid/setgid so gosu can drop to `signal`"
```
`Dockerfile:101-109` documents that PID 1 *must* retain those caps to chown the volume and run
`gosu signal …` for every long-running process.

**Mechanism:** the entrypoint runs `gosu signal signal-cli …` (`entrypoint.sh:69`, `:180`) and
`chown -R signal:signal /opt/signal-cli-data` (`:67`). `setuid(2)`/`setgid(2)` to a non-zero uid
require **CAP_SETUID/CAP_SETGID**; `chown` of a file not owned by the caller requires **CAP_CHOWN**.
`--cap-drop=ALL` with no `cap_add` empties the bounding set, so `gosu` fails with `EPERM` in every
security mode. Combined with `no-new-privileges`, there is no fallback path.

**Impact:** every user who installs via the Unraid template gets a crash-looping container. This is
the project's primary advertised install path for Unraid (README + `build-unraid.sh` + `deploy-unraid.sh`
all direct users there), and Unraid is the user's own host platform.

**Confidence:** the capability *semantics* are documented Linux behavior; I could not execute
`unshare`/`docker` in this environment to reproduce the failure directly. The cross-file
contradiction (compose.yaml's own comment states these caps are required) is the decisive evidence.

**Fix:** mirror compose.yaml exactly:
`--cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=FOWNER --cap-add=DAC_OVERRIDE --security-opt no-new-privileges=true --memory=512m`

---

## 🔴 HIGH

### H1. The documented "Custom Proxy Configuration" feature cannot work — entrypoint overwrites your mounted file

**Files:** `README.md:144-159` vs `scripts/entrypoint.sh:119`
README tells users to mount their own config: `-v "$(pwd)/custom-config.yml:/config/config.yml"`.
But in **both** proxy modes the entrypoint unconditionally rewrites that exact path:
```bash
cat > /config/config.yml << PROXYCFG     # entrypoint.sh:119 — clobbers the mount
…
export CONFIG_PATH=/config/config.yml    # :148
```
There is no existence check, no `CUSTOM_CONFIG` opt-out, and no merge. The user's rate limits,
field policies, message templates, and endpoint rules are **silently discarded at every start**, with
the log line `"Proxy config written to /config/config.yml"` implying success.

**Verified:** I extracted `write_proxy_config()` and executed it; `cat >` is unconditional, and
`CONFIG_PATH` is exported to the same path the README instructs users to bind-mount.

**Fix:** honor a pre-existing user config — if `/config/config.yml` already exists and
`CUSTOM_PROXY_CONFIG` is not explicitly disabled, load it as the base and only generate defaults when
absent. Simplest correct behavior: skip generation when the file exists, log that a user config was
detected, and set `CONFIG_PATH` to it (matching the README). Add `CUSTOM_PROXY_CONFIG=false` to
force regeneration.

### H2. `deploy-unraid.sh` reports "❌ proxy FAIL" in the mode it itself defaults to

**File:** `scripts/deploy-unraid.sh:73-97`
The script starts the daemon with `SECURITY_MODE="${SECURITY_MODE:-loopback}"` (safe default), then
**unconditionally** probes the proxy:
```bash
curl -sf http://127.0.0.1:8880/api/v1/check && echo " ✅ proxy OK" || echo " ❌ proxy FAIL"
docker logs signal-cli-gateway 2>&1 | grep ">>>" || echo "(check 'docker logs …' for the token)"
```
In `loopback` mode no proxy exists, so this **always** prints `❌ proxy FAIL` and the token line,
right under a `DEPLOYMENT COMPLETE` banner. A user who set no env var concludes their fresh install
is broken. `curl -sf` returns 7 (connection refused) and the `||` branch fires.

**Verified by reading the control flow**; reproduced the shell semantics of `curl -sf … || echo`.

**Fix:** gate the proxy checks and token hint on the mode actually used; print a mode-appropriate
success line. Also fix the step numbering (two "Step 5", two "Step 6" — headers at `:69` and `:72`
vs banners at `:69` and `:84`).

### H3. signal-cli pinned to 0.14.7; 0.14.8 released 2026-09-10

**File:** `Dockerfile:9` — `ARG SIGNAL_CLI_VERSION=0.14.7`
Verified via GitHub API: latest is **v0.14.8** (published 2026-09-10). I confirmed v0.14.8 ships the
identical asset layout (`signal-cli-0.14.8-Linux-native.tar.gz` + `.asc`), so the bump is safe.
`DESIGN.md:465-468` explicitly mandates staying current ("releases older than 3 months may break due
to Signal server protocol changes"), so the repo contradicts its own stated policy.

**Fix:** bump `SIGNAL_CLI_VERSION` to `0.14.8`. (User's standing preference: prefer the most complete
option; a 17-day-old protocol-facing dependency in a Signal client is a real operational risk.)

### H4. README claims `exposed-proxy` is the bridge-network mode, but its own network note contradicts the security table

**Files:** `README.md:44` vs `README.md:47`
Line 44: `exposed-proxy` — Network column says "Bridge or Host". Line 47: "`exposed-proxy` works on
bridge — the proxy binds `0.0.0.0:8880`, so port mapping works". That part is right, but the same
sentence opens by claiming the loopback modes "require `--network host` because `127.0.0.1` inside a
bridge network is unreachable from outside" — while the security table's "Use Case" for `exposed-proxy`
("Multi-host, Kubernetes, cloud") is the deployment where a *remote* client connects, and the
`unraid-template.xml:28-31` overview says the same. The real constraint is that in `exposed-proxy`
the proxy binds `0.0.0.0` (verified in upstream `main.go:121`: `httpserver.Create(handler, "0.0.0.0", …)`),
so it **is** bridge-capable — the table's "Bridge or Host" is correct. The defect is that the table
gives no port-mapping guidance and line 47's parenthetical implies host networking is required
whereas the table says otherwise; a user choosing bridge + `exposed-proxy` gets no `-p` example and
must read the raw `docker run` block in deploy scripts to learn it.

This is documentation-internal inconsistency, ranked High because `exposed-proxy` is the documented
path for exactly the multi-host/K8s use case, and getting the network mode wrong there means either a
dead endpoint or an unintended exposure.

**Fix:** reconcile the table and note; add an explicit `docker run -p 8880:8880` bridge example for
`exposed-proxy`, and state plainly that `loopback`/`loopback-proxy`/`unix` require host networking.

---

## 🟡 MEDIUM

### M1. No child-process supervision — a crashed daemon leaves a "running" container

**File:** `scripts/entrypoint.sh:234-236` — the script ends with a bare `wait`.
`wait` (no args) returns when **all** children exit, and its exit status is the last child's. If
`signal-cli` dies but the proxy (or `socat`) survives, `wait` blocks forever: the container stays
`Up`, the proxy keeps returning 502/500, and the Dockerfile HEALTHCHECK (`/api/v1/check`) fails
silently into `unhealthy` with no restart. The TERM/INT trap only handles shutdown.

**Verified:** read of the trap + terminal `wait`; no `kill -0` polling or `-e` supervision anywhere.

**Fix:** supervise — poll children in a loop and exit non-zero if any tracked child dies, so Docker's
`restart: unless-stopped` (compose) / `--restart unless-stopped` (deploy scripts) actually restarts it.
Keep the existing signal-forwarding trap intact.

### M2. `compose.yaml` hardcodes tmpfs `uid=999,gid=999` but the Dockerfile creates `signal` with dynamic `useradd -r`

**Files:** `compose.yaml:88` vs `Dockerfile:65`
```yaml
- /var/run/signal-cli:size=16m,mode=0755,uid=999,gid=999
```
```dockerfile
RUN groupadd -r signal && useradd -r -g signal -d /opt/signal-cli-data -s /sbin/nologin signal
```
`-r` (system) allocates from the dynamic system UID range — it is not guaranteed to be 999. The
`unix` mode's socket dir is mounted from that tmpfs, and the daemon runs as `signal`. If the
allocated uid ≠ 999, the tmpfs is owned by the wrong uid and socket creation fails with EACCES —
`unix` mode is DOA again, the exact class of bug PR #6 fixed at `entrypoint.sh:177`
(`chown signal:signal "$(dirname "${socket_path}")"`), which cannot help when the mount itself is
mis-owned. `entrypoint.sh:67` chowns the *data* dir but nothing chowns the socket dir to the real
uid after the tmpfs mount.

**Verified:** the Dockerfile uses dynamic `-r` allocation; the tmpfs pins a literal. In practice
Ubuntu's first `-r` user in a clean base is usually 999, which is why this has gone unnoticed — it is
a latent, environment-dependent break, not a guaranteed one.

**Fix:** pin the uid explicitly in the Dockerfile (`useradd -r -u 10001 …`, and `-g` with an explicit
gid) so image and compose agree, and keep the tmpfs `uid`/`gid` in sync. Explicit beats dynamic here.

### M3. CI silently dropped arm64 in PR #6 — a scope change bundled into a remediation commit

**File:** `.github/workflows/docker-publish.yml:46` — `platforms: linux/amd64` (was `linux/amd64,linux/arm64`)
**Context (VERIFIED, and it was the right call):** signal-cli publishes **no arm64 Linux-native
asset** — v0.14.7 and v0.14.8 both ship only `Linux-native` (amd64). The old arm64 build could not
have produced a working arm64 image, so dropping it fixed a broken build. But the commit message
(`remediation: 2026-08-23 comprehensive review fixes`) does not mention dropping a platform, and
nothing in README/DESIGN documents amd64-only. A user on Unraid ARM / Raspberry Pi / Apple Silicon
has no signal that amd64-only is the contract.

**Fix:** document the amd64-only constraint in README (a one-line platform note) so it is a
disclosed limitation rather than a silent one.

### M4. `SC2034` unused loop variable (only shellcheck finding in the repo)

**File:** `scripts/entrypoint.sh:223` — `for i in $(seq 1 30); do` with `i` never used.
Cosmetic but it is the sole `shellcheck` output, so it will mask a future real warning. The identical
pattern at `:76` and `:185` uses `i` only as a counter too — the one at `:223` is the one flagged.
**Fix:** use `_` or add a `# shellcheck disable=SC2034` with rationale; prefer `_` for the final probe.

### M5. `.env.example` says `loopback-proxy`; compose, README, and deploy scripts default to `loopback`

**Files:** `.env.example:19` (`SECURITY_MODE=loopback-proxy`) vs `compose.yaml:63`
(`${SECURITY_MODE:-loopback}`), `README.md:42,112` (default `loopback`),
`unraid-template.xml:54` (Default=`loopback-proxy`), `deploy-unraid.sh:80` (`loopback`).
A user copying `.env.example` → `.env` silently gets a **different security mode** than the shipped
default, and lands in proxy mode with an auto-generated token they must then find in the logs. This
was prior finding L7 (README vs template) and is still half-fixed: the template still ships
`loopback-proxy` as its default.

**Fix:** align everything on `loopback` as the default (matching the documented "safest default"
rationale) and make `.env.example` show the default with the alternatives commented.

---

## 🟢 LOW / HYGIENE

| # | Finding | File | Fix |
|---|---|---|---|
| L1 | Step mislabeling: two "Step 5" and two "Step 6" banners; comment/banner mismatch | `deploy-unraid.sh:66-84` | Renumber 1-6 cleanly |
| L2 | `echo "  docker run --rm -it \\"` prints a **literal double backslash** (double-escaped inside double quotes) — 5 occurrences, user copy-pastes broken commands | `build-unraid.sh:49-53` | Use single quotes or heredoc |
| L3 | `ARG TARGETARCH` + `GOARCH=${TARGETARCH}` in stage 2 is pointless while CI builds amd64-only; and a cross-arch build would produce a Go binary for an arch signal-cli can't supply | `Dockerfile:40,47` | Keep `GOARCH=amd64` explicit, or document intent |
| L4 | `.env.example` has no trailing newline; `scripts/download-icon.sh` has no trailing newline | both | Add newline (POSIX text file hygiene) |
| L5 | No `.gitignore` in repo — `.env` (which holds `SECURITY_PROXY_TOKEN`) and `signal-cli-data/` (Signal identity keys) are only excluded from the **build context** via `.dockerignore`, not from git | repo root | Add `.gitignore` with `.env`, `signal-cli-data/`, `*.tar.gz` |
| L6 | README/`.env.example`/`build-unraid.sh` tell users to link with `docker run --rm -it`; `link-account.sh` is also reachable via `docker compose run --rm link` (compose.yaml:43) — the compose path is undocumented in README Quick Start | `README.md:18-24` | Mention the compose path; drop `-it` where not needed |

---

## ✅ Prior review (2026-08-21) — all 18 findings confirmed FIXED

Verified by diffing `2797b2b..0192ade` and reading the current tree:

| Prior | Status | Evidence |
|---|---|---|
| C1 `172.0.0.0/8` + `10.0.0.0/8` auth-free allowlist | ✅ Fixed | Defaults now `127.0.0.1` everywhere (`.env.example:23`, `unraid-template.xml:58`, `entrypoint.sh:164,167`) |
| H1 unmerged broken `hardened/security-batch` | ✅ Fixed | Branch deleted from remote; salvage landed as PR #6 |
| H2 `unix` mode socket dir EACCES | ✅ Fixed | `entrypoint.sh:177` chowns the socket dir |
| H3 link URI sent to api.qrserver.com | ✅ Fixed | Offline `qrencode -t ANSI256` (`link-account.sh:58`); `qrencode` added to runtime deps |
| M1 root-run proxy/socat | ✅ Fixed | All children via `gosu signal`; `cap_drop` + `no-new-privileges` + read-only rootfs |
| M2 DESIGN.md overstated controls | ✅ Fixed | Fail-fast check added (`entrypoint.sh:159-160`); env interface documented as not-configurable |
| M3 no integrity verification | ✅ Fixed — **and I re-verified it live** | GPG verify on real 0.14.7 tarball → `Good signature`; digest-pinned base images |
| M4 CI pushes on every branch, floating actions | ✅ Fixed | `branches: [main]`, PR-gated push, all 5 actions SHA-pinned (I confirmed every `# vX` comment matches the real latest tag) |
| M5 pin drift | ⚠️ **Partially regressed** | SSA v1.6.2 still latest ✅; signal-cli was bumped 0.14.5→0.14.7 but **0.14.8 is now out** → H3 |
| L1 README render bug | ✅ Fixed | Markdown fences correct |
| L2 test-proxy.sh literal token | ✅ Fixed — **redaction-filter trap confirmed** | `od -c` on line 29 shows the real bytes are `-H "Authorization: Bearer ${TOKEN}"`; the `Bearer ***` I first *saw* was the display-layer secret filter, not the file. Prior finding was correct; naive re-reading would have re-reported a fixed bug |
| L3 orphaned `.env.example` | ✅ Fixed | `compose.yaml:28,68` use `env_file:` with `required: false` |
| L4 step numbering / `\\` | ⚠️ **Partially fixed** | deploy-unraid.sh still mislabeled (L1); `build-unraid.sh` `\\` still present (L2) |
| L5 link URI escaping/pipefail | ✅ Fixed | `mktemp` + `tee` + post-hoc grep (`link-account.sh:35-40`); explicit empty-URI error |
| L6 no resource limits | ✅ Fixed | `deploy: resources.limits` + `--memory=512m` |
| L7 default-mode drift | ⚠️ Partially fixed → M5 | Template still `loopback-proxy` |
| L8 shellcheck nits | ⚠️ 1 of 2 fixed → M4 | `link-account.sh` clean; `entrypoint.sh:223` SC2034 remains |
| L9 branch graveyard | ✅ Fixed | Only `origin/main` remains |

---

## ✅ Security Positives (verified, not assumed)

- **Supply chain is genuinely strong now:** GPG signature verification of signal-cli with a pinned
  key fingerprint (I executed the full verify against the real tarball: *Good signature*), plus
  digest-pinned `ubuntu:24.04` and `golang:1.26-alpine` base images. The prior review's "no integrity
  verification" is fully remediated — this is a real, working control.
- **Generated proxy config is schema-correct against the real binary.** I read the Go structs
  (`internals/config/structure/structure.go:111-140`): `ipFilter.allowed` and `trustedIPs` are both
  correct at `settings.access.*`, and I executed the generator to confirm the emitted YAML parses and
  nests correctly in both bind modes.
- **`loopback-proxy`'s ipFilter is a real control, not decorative.** I traced
  `checkBlockLogic` (`internals/proxy/middlewares/endpoints.go:65-90`): with `allowed` non-empty and
  no explicit block, the logic returns **true (block)** — i.e. default-deny for any IP not
  `127.0.0.1`. The "local-only" claim holds. (Worth stating explicitly: I suspected this was a
  no-op; the source says otherwise.)
- **The proxy binds `0.0.0.0` unconditionally** (upstream `main.go:121`), which is exactly why the
  `ipFilter` in `loopback-proxy` is load-bearing — the two facts together confirm the mode's design
  is sound.
- **PID-1 signal handling is textbook:** TERM/INT trap forwards to tracked child PIDs then `wait`s.
  No `local` outside functions. `set -euo pipefail` throughout. `gosu` (not `su`) avoids the
  tty/PID-1 signal issues of `su`.
- **Link-account.sh is now fully offline** — QR rendered locally with `qrencode`, URI never leaves
  the host, and the `grep` cannot SIGPIPE-kill signal-cli mid-link (captured via `tee` to a temp file
  first). This was a Critical in the prior review and is properly fixed.
- **CI is healthy and honest:** 13/13 recent runs green, `pull_request` builds don't push, 2 open
  Dependabot PRs, SHA-pinned actions with truthful version comments, SBOM + provenance enabled.
- `LICENSE` is the full GPLv3 text; `.dockerignore` correctly excludes `.env*`; `defaults.yml` is
  shipped via `DEFAULTS_PATH` (the Dockerfile comment correctly notes its absence causes a nil-panic).

---

## 🔎 RULED OUT (refuted during this audit — do not re-audit)

| Suspicion | Verdict | How it was disproven |
|---|---|---|
| Dockerfile:28 GPG fingerprint `grep` never matches ⇒ every build fails | **False** | `gpg --list-keys` prints the fingerprint on its own line; grep matched, and the full signature verified. CI green on 9 runs since PR #6 also proves it executes |
| `openssl` missing from runtime image ⇒ token generation fails | **False** | Ubuntu noble `Packages.gz`: `ca-certificates` → `Depends: openssl (>= 1.1.1)`. The Dockerfile installs `ca-certificates`, so `openssl rand` resolves transitively. Real but fragile coupling (noted below) |
| `test-proxy.sh:29` sends a literal `Bearer ***`, never uses `$TOKEN` | **False — redaction trap** | `od -c` shows real bytes are `Bearer ${TOKEN}`. The `***` was Hermes' secret-redaction display filter |
| Dropping arm64 in PR #6 is a regression | **False — correct fix** | signal-cli publishes no arm64 `Linux-native` asset in 0.14.7 or 0.14.8; the arm64 build could never have worked |
| `loopback-proxy` ipFilter may be a no-op (remote clients could reach the proxy) | **False** | Traced `checkBlockLogic` in the real v1.6.2 source: non-empty `allowed` + no match ⇒ **block** |
| Generated `config.yml` may be malformed / mis-nested | **False** | Executed the generator for both modes; YAML parses; keys match the Go structs |
| Dependabot bumping `actions/checkout` to v7.0.1 / `login-action` v4.6.0 implies a major breaking bump | **False** | GitHub API: those *are* the current real latest tags. The pin comments are accurate |

**One fragility worth fixing as part of M2 (not a separate finding):** relying on `ca-certificates`
to pull in the `openssl` **binary** is an undocumented transitive dependency. If that dependency ever
changes, token generation breaks at runtime in proxy modes. Adding `openssl` to the explicit apt list
costs nothing and removes the coupling.

---

## Recommended fix order

| Priority | Findings | Rationale |
|---|---|---|
| **P0** | C1 | Template is 100% broken — blocks every Unraid install |
| **P0** | H2 | Fresh install reports FAIL; destroys trust in the deploy path |
| **P1** | H1 | Documented feature silently does nothing — data-loss-adjacent (user config discarded) |
| **P1** | M1 | Silent-failure class: dead daemon looks healthy |
| **P1** | M5, H4 | Default-mode + doc contradictions drive wrong security choices |
| **P2** | H3, M2, M3 | Pin currency + latent uid break + disclose platform limit |
| **P3** | M4, L1-L6 | Hygiene; SC2034 first so future lint is clean |

**P0+P1 = 6 fixes, all small and low-risk** (one XML line, one script guard, one existence check,
one supervision loop, two doc/config alignments). **P2 = 3** (one ARG bump, one explicit uid, one doc
line + explicit `openssl`). **P3 = 7** (cosmetic).

**Total: 16 findings, 16 fixes.** No fix requires a breaking change, an env-var rename, or a change
to the default security posture (`loopback` stays the default).

---

## ✅ REMEDIATION — ALL 16 FIXED AND VERIFIED (2026-09-27)

Branch: `hardened/audit-2026-09-27`. Built and tested on the test VM (Docker 29.4.1).
**Final verification result: 19 assertions passed, 0 failed.**

### C1 was reproduced before it was fixed

The finding was originally marked as reasoned-from-documentation (no Docker in the audit
environment). With the test VM's Docker daemon, the failure was **reproduced exactly** on the
unmodified image with the Unraid template's own flags:

```
$ docker run --rm --cap-drop=ALL --security-opt no-new-privileges=true scg:audit
[entrypoint] Starting signal-cli daemon on 127.0.0.1:8080...
error: failed switching to "signal": operation not permitted
[entrypoint] FATAL: signal-cli daemon failed to start within 30 seconds   → exit 1
```

And an isolated A/B proof of the mechanism:

| Capability set | `chown` | `gosu signal` |
|---|---|---|
| `--cap-drop=ALL` (template, before) | `Operation not permitted` | `failed switching to "signal": operation not permitted` |
| `--cap-drop=ALL` + 5 `cap_add` (compose, after) | OK | OK (uid 999) |

### Verification suite — 19/19

| Test | Finding | Result |
|---|---|---|
| 1 | C1 — container reaches "Gateway is ready" under the template's caps; no gosu error; proxy binds | ✅ 3/3 |
| 2 | M2 — `signal` uid is 10001, matching the compose tmpfs | ✅ |
| 3 | H3 — bundled signal-cli reports 0.14.8 (build log shows `gpg: Good signature`) | ✅ |
| 4 | H1 — mounted config.yml detected, intact in-container, host file never overwritten | ✅ 3/3 |
| 5 | M1 — killing signal-cli as its owner ⇒ container `exited exit=1` within 1s, death logged | ✅ 3/3 |
| 6 | H2 — proxy probe gated: `loopback`/`unix` → SKIPPED, `loopback-proxy`/`exposed-proxy` → PROBED | ✅ 4/4 |
| 7 | Runtime deps — `openssl` and `qrencode` present | ✅ 2/2 |
| 8 | unix mode — socket created and JSON-RPC readiness passed through the socat bridge (validates the M2 uid fix end to end) | ✅ 2/2 |

### Two failures that turned out to be test artifacts, not code defects

Recording these because both initially looked like real bugs, and both were disproven by
changing the method rather than re-reading:

1. **"M1 doesn't detect child death"** — the harness killed PID 10 as root, which failed with
   `kill: Operation not permitted`: the container runs `--cap-drop=ALL` **without CAP_KILL** (by
   design), so the signal never reached signal-cli. Re-running the kill as the process owner
   (`docker exec -u signal`) produced the expected `exited exit=1` + `FATAL: child process 10
   exited`. The fix was correct; the test lacked permission to disprove it.
2. **"H1 doesn't preserve the config" / "C1's container dies"** — a leftover container from the
   A/B run was still holding 8080/8880 on the host network, so the proxy logged
   `bind: address already in use`, died, and (correctly) tripped the new supervision. Port
   conflict, not a regression. After cleanup both passed.

A latent design note surfaced by this: because the entrypoint reaps via `wait -n`, liveness can
only be judged for PIDs bash has already reaped — a zombie child still answers `kill -0`. The
final implementation accounts for this by sweeping after every `wait -n` return.

### Static checks

- `shellcheck scripts/*.sh test-proxy.sh` → **zero findings** (was 1 SC2034; fixing it exposed
  3 more that had been masked, so all four unused loop counters are now `_`).
- `bash -n` on all 6 scripts → clean. `xml.etree` parse of `unraid-template.xml` → well-formed
  (caught and fixed an illegal `--` inside an XML comment).
- `docker compose config` → valid with a `.env` present; the failure without one is the
  **intended** fail-fast on a missing `SIGNAL_ACCOUNT`.
- `hadolint` with the repo config → clean (two pre-existing findings, `DL4006`/`DL3025`, added
  to `.hadolint.yaml` with rationale; neither was introduced by this batch).
- Full image build with signal-cli 0.14.8 → `gpg: Good signature from "AsamK <asamk@gmx.de>"`,
  independently confirming the bump did not weaken the supply-chain control.

### Files changed

```
 .env.example             | 11 ++     Dockerfile          | 24 +++++-
 .hadolint.yaml           |  3 +      README.md           | 40 ++++++++-
 .gitignore               | 11 ++     scripts/deploy-unraid.sh | 46 ++++++++++--
 compose.yaml             |  5 +-     scripts/entrypoint.sh    | 56 +++++++++++++--
 DESIGN.md                | 21 ++     unraid-template.xml      | 30 ++++++++-
```

### New knob introduced

`CUSTOM_PROXY_CONFIG` (default `true`) — preserves a mounted `/config/config.yml`; set `false` to
force regeneration. Exposed in README, DESIGN.md, and the Unraid template. Also added an
optional read-only `Proxy Config` path to the Unraid template so the feature is reachable from
the Unraid UI.
