# SELinux compile image (Docker Hub / UBI 9)

Red Hat demo hosts pull a pre-baked **UBI 9** image with `selinux-policy-devel`, `setools`, and targeted policy — no per-run `dnf`.

Related: [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md) (default generator), [TESTING.md](TESTING.md) §4 CI compile jobs, [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) (`lib/selinux_build_image.sh`).

## Default image

```text
docker.io/asaran/selinux-demo-selinux-build:ubi9
```

Also tagged `:latest` when published with `SELINUX_BUILD_IMAGE_PUSH_LATEST=1` (default).

## Demo laptop / CI

```bash
export SELINUX_BUILD_IMAGE=docker.io/asaran/selinux-demo-selinux-build:ubi9
bash scripts/lib/selinux_build_image.sh pull   # or ensure (pull → local build)
bash scripts/dev_generate_policy.sh --skip-export
```

`ensure_selinux_build_image` (used by compile scripts) runs **pull-first** when `SELINUX_BUILD_IMAGE_PULL=1` (default).

## Publish (maintainer)

Use a [Docker Hub access token](https://hub.docker.com/settings/security) — **do not commit passwords or tokens**.

```bash
export DOCKERHUB_USER=asaran
export DOCKERHUB_TOKEN='…'
bash scripts/publish_selinux_compile_image.sh
```

Builds from [`packaging/Containerfile.selinux-build`](../packaging/Containerfile.selinux-build) (`registry.access.redhat.com/ubi9/ubi:latest`). On subscription-entitled builders:

```bash
export SELINUX_BUILD_BASE_IMAGE=registry.redhat.io/rhel9/rhel:9.4
podman login registry.redhat.io
bash scripts/publish_selinux_compile_image.sh
```

## Overrides

| Variable | Default |
|----------|---------|
| `SELINUX_BUILD_IMAGE` | `docker.io/asaran/selinux-demo-selinux-build:ubi9` |
| `SELINUX_BUILD_IMAGE_PULL` | `1` |
| `SELINUX_BUILD_IMAGE_AUTO` | `1` (local build if pull fails) |
| `SELINUX_COMPILE_IMAGE` | `registry.access.redhat.com/ubi9/ubi:latest` (slow path) |
