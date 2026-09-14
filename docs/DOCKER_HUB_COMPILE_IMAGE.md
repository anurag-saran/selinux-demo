# SELinux compile image (CentOS Stream 9 / Docker Hub)

Pre-baked **CentOS Stream 9** image with `selinux-policy-devel`, `setools-console`, and targeted policy. Matches **RHEL 9 deploys** (Stream is RHEL upstream). No per-run `dnf` on compile.

## Default image (pull-first)

```text
docker.io/asaran/selinux-demo-selinux-build:stream9
```

Also tagged `:latest` when published (`SELINUX_BUILD_IMAGE_PUSH_LATEST=1`, default).

## Quick use

```bash
export SELINUX_BUILD_IMAGE=docker.io/asaran/selinux-demo-selinux-build:stream9
bash scripts/lib/selinux_build_image.sh pull    # or ensure
bash scripts/compile_and_validate.sh selinux
```

`ensure_selinux_build_image` runs before compiles when `SELINUX_BUILD_IMAGE_PULL=1` (default).

## Build locally

Uses **`quay.io/centos/centos:stream9`** (override with `SELINUX_BUILD_BASE_IMAGE`):

```bash
bash scripts/build_selinux_compile_image.sh
```

On **macOS**, if Podman hits overlay errors:

```bash
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
bash scripts/repair_podman_machine.sh
bash scripts/build_selinux_compile_image.sh
```

## Publish to Docker Hub

```bash
export DOCKERHUB_USER=asaran
export DOCKERHUB_TOKEN='…'
bash scripts/publish_selinux_compile_image.sh
```

## Later: subscribed RHEL base (optional)

When you want the container `FROM` to be RHEL instead of Stream:

```bash
podman login registry.redhat.io
export SELINUX_BUILD_BASE_IMAGE=registry.redhat.io/rhel9/rhel:9.4
bash scripts/build_selinux_compile_image.sh
bash scripts/publish_selinux_compile_image.sh
```

Same Hub tag (`:stream9`) can still be used; the image contents were built on RHEL.

## Environment

| Variable | Default |
|----------|---------|
| `SELINUX_BUILD_IMAGE` | `docker.io/asaran/selinux-demo-selinux-build:stream9` |
| `SELINUX_BUILD_BASE_IMAGE` | `quay.io/centos/centos:stream9` |
| `SELINUX_COMPILE_IMAGE` | `quay.io/centos/centos:stream9` (slow path) |
| `SELINUX_BUILD_IMAGE_PULL` | `1` |
| `SELINUX_BUILD_IMAGE_AUTO` | `1` |

Related: [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md), [TESTING.md](TESTING.md).
