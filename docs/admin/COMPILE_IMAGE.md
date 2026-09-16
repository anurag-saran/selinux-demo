# SELinux compile image (CentOS Stream 9)

Pre-baked **CentOS Stream 9** image with `selinux-policy-devel`, `setools-console`, and targeted policy. Matches **RHEL 9 deploys**.

**Production:** set **`SELINUX_BUILD_IMAGE`** to an **internal registry** (copy [`packaging/internal.env.example`](../../packaging/internal.env.example)). Do not pull Docker Hub from canary/prod controllers. On RHEL with `selinux-policy-devel`, compile natively — [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md).

**Doc index:** [README.md](../README.md).

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
| **Where (Mac)** | Repo root; optional **Podman or Docker** as a container CLI (policy still runs on RHEL) |
| **Where (Linux)** | Repo root; Podman or Docker if you use the container compile path |
| **Why** | Pulling the image is faster than building Stream 9 + `selinux-policy-devel` on every compile |

```bash
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
export DOCKERHUB_USER=asaran
export DOCKERHUB_TOKEN='…'   # Hub access token — never commit
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

## Container CLI notes

The compile image is a **tool container** (`podman` or `docker`). It is not a SELinux lab VM. Policy still runs on RHEL — [RHEL_TWO_HOST.md](RHEL_TWO_HOST.md).

On a Mac, install Podman or Docker and keep it on `PATH`. If `podman` is missing, compile natively on rhel-dev with `selinux-policy-devel`.

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
| `SELINUX_BUILD_IMAGE` | **Production:** `packaging/internal.env`. Local fallback `localhost/selinux-build:stream9` |
| `SELINUX_BUILD_BASE_IMAGE` | `quay.io/centos/centos:stream9` |
| `SELINUX_COMPILE_IMAGE` | `quay.io/centos/centos:stream9` (slow path) |
| `SELINUX_BUILD_IMAGE_PULL` | `1` |
| `SELINUX_BUILD_IMAGE_AUTO` | `1` |
| `CONTAINERS_STORAGE_DRIVER` | Optional; set if your container engine needs it |

### Internal registry (required for canary/prod controllers)

Do not pull Docker Hub from production. Copy [`packaging/internal.env.example`](../../packaging/internal.env.example) and export **`SELINUX_BUILD_IMAGE`**:

```bash
cp packaging/internal.env.example packaging/internal.env   # gitignored
# edit registry + SELINUX_RPM_REPO
set -a && source packaging/internal.env && set +a
bash scripts/lib/selinux_build_image.sh ensure
bash packaging/build_rpms.sh
bash packaging/publish_internal.sh   # rpmsign + createrepo_c
```

Laptop backup only: `SELINUX_BUILD_IMAGE_PULL=0` and `bash scripts/build_selinux_compile_image.sh` (never pushes).

Related: [DETERMINISTIC_POLICY.md](../developers/DETERMINISTIC_POLICY.md), [TESTING.md](../developers/TESTING.md), [README.md](../../README.md).
