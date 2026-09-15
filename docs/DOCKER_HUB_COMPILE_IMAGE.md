# SELinux compile image (CentOS Stream 9)

Pre-baked **CentOS Stream 9** image with `selinux-policy-devel`, `setools-console`, and targeted policy. Matches **RHEL 9 deploys** (Stream is RHEL upstream). No per-run `dnf` on compile.

**Who this is for:** developers who need to **compile** `.te`/`.fc` into `.pp` on a laptop without installing full SELinux devel packages on the host.

**Doc index:** [README.md](README.md).

**Registry:** Demo tags are published on Docker Hub; production shops set **`SELINUX_BUILD_IMAGE`** to an internal mirror (no script edits). See [Internal registry](#internal-registry-regulated-environments) below.

## Published image (pull-first)

These tags are on **Docker Hub** under [`asaran/selinux-demo-selinux-build`](https://hub.docker.com/r/asaran/selinux-demo-selinux-build):

| Tag | Use |
|-----|-----|
| **`stream9`** | Default for demos and CI (`SELINUX_BUILD_IMAGE`) |
| **`latest`** | Same image as `stream9` after publish |

```text
docker.io/asaran/selinux-demo-selinux-build:stream9
```

## Quick use (demo laptop)

| | |
|--|--|
| **Where (Mac)** | Terminal at **repo root** after `bash scripts/fix_podman.sh` and `source …/env.sh` — see [SELINUX_TRAINING_LAB.md — Running on macOS](SELINUX_TRAINING_LAB.md#running-on-macos) |
| **Where (Linux)** | Repo root; Podman or Docker if you use the container compile path |
| **Why** | Pulling the image is faster than building Stream 9 + `selinux-policy-devel` on every compile |

```bash
source "${HOME}/.local/share/selinux-demo/podman/env.sh"   # macOS: each new shell; puts Podman 5 on PATH
bash scripts/lib/selinux_build_image.sh pull    # seconds — or: ensure
bash scripts/compile_and_validate.sh selinux
```

Compiles invoked via `dev_generate_policy.sh`, `compile_and_validate.sh`, `validate_policy_semantics.sh`, and blast-radius scripts call **`ensure_selinux_build_image`** when `SELINUX_BUILD_IMAGE_PULL=1` (default): **pull → local build → slow Stream path**.

## Rebuild and publish (maintainers)

| | |
|--|--|
| **Where** | Maintainer machine with Podman and Docker Hub credentials |
| **Why** | Rebuild when `Containerfile.selinux-build` or base policy packages change |

```bash
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
export DOCKERHUB_USER=asaran
export DOCKERHUB_TOKEN='…'   # Hub access token — never commit

# macOS: fresh VM if overlay/readlink errors
bash scripts/repair_podman_machine.sh

bash scripts/publish_selinux_compile_image.sh
```

`publish_selinux_compile_image.sh` logs in to Docker Hub, **builds only if the tag is missing locally**, pushes `:stream9` and `:latest`.

Local build only (no push):

```bash
bash scripts/build_selinux_compile_image.sh
```

Build uses **`quay.io/centos/centos:stream9`** unless overridden:

```bash
export SELINUX_BUILD_BASE_IMAGE=quay.io/centos/centos:stream9
```

## macOS Podman notes

Full first-time setup (where each command runs): **[SELINUX_TRAINING_LAB.md — Running on macOS](SELINUX_TRAINING_LAB.md#running-on-macos)**.

| Issue | Fix |
|-------|-----|
| `readlink … storage/overlay/l: invalid argument` | `bash scripts/repair_podman_machine.sh` then rebuild/publish |
| Legacy Podman 2.x | `bash scripts/fix_podman.sh` (installs user-local 5.x + `CONTAINERS_STORAGE_DRIVER=vfs` in `env.sh`) |
| Build stops/restarts VM unnecessarily | Fixed: build/publish use `podman machine start` only (no `ensure_vm_ready` stop loop) |

Optional deep reset **inside** the Linux VM (usually not needed):

```bash
SELINUX_PODMAN_RESET_IN_VM=1 bash scripts/repair_podman_machine.sh
```

## Optional: subscribed RHEL base

When the container `FROM` should be RHEL instead of Stream:

```bash
podman login registry.redhat.io
export SELINUX_BUILD_BASE_IMAGE=registry.redhat.io/rhel9/rhel:9.4
bash scripts/publish_selinux_compile_image.sh
```

You may keep publishing to the same Hub tag `:stream9`; document in release notes if the base changed.

## Environment

| Variable | Default |
|----------|---------|
| `SELINUX_BUILD_IMAGE` | `docker.io/asaran/selinux-demo-selinux-build:stream9` |
| `SELINUX_BUILD_BASE_IMAGE` | `quay.io/centos/centos:stream9` |
| `SELINUX_COMPILE_IMAGE` | `quay.io/centos/centos:stream9` (slow path) |
| `SELINUX_BUILD_IMAGE_PULL` | `1` |
| `SELINUX_BUILD_IMAGE_AUTO` | `1` |
| `CONTAINERS_STORAGE_DRIVER` | `vfs` on macOS (via `~/.local/share/selinux-demo/podman/env.sh`) |

### Internal registry (regulated environments)

Docker Hub is optional. Point **`SELINUX_BUILD_IMAGE`** at any registry mirror (no script edits):

```bash
export SELINUX_BUILD_IMAGE=registry.example.com/security/selinux-demo-selinux-build:stream9
export SELINUX_BUILD_IMAGE_PULL=1   # or 0 to build only from Stream base locally
bash scripts/lib/selinux_build_image.sh ensure
```

Local-only shops: `SELINUX_BUILD_IMAGE_PULL=0` and `bash scripts/build_selinux_compile_image.sh` (never pushes).

Related: [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md), [TESTING.md](TESTING.md), [README.md](../README.md).
