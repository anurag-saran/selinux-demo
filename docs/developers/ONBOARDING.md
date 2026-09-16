# Onboarding a second application (payments example)

The repo ships **`myapp`** as the primary demo and **`payments`** as a second onboarded module: manifest template, policy under **`selinux/payments/`**, and a published **`.if`** interface for dependent modules.

**Prerequisites:** read [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md) §1–7 and [config/README.md](../../config/README.md). **Doc index:** [README.md](../README.md). Deploy: [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md).

**Fast path:**

```bash
bash scripts/setup_rhel_hosts.sh write --dev-host DEV --prod-host PROD
bash scripts/selinux_pac_adopt.sh doctor          # on the RHEL host
bash scripts/selinux_pac_adopt.sh init payments
```

**Where commands run:**

| Step | Where |
|------|--------|
| Copy manifest, `validate_app_manifest.sh`, compile | **Controller** (RHEL devel or Podman compile image as backup) |
| `scaffold_sepolicy_module.sh`, `semodule -i`, `restorecon` | **RHEL dev** box |
| `ansible-playbook deploy_canary.yml` / `soak_monitor.yml` | **Controller** SSH to **RHEL prod** ([RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md)) |

---

## Manifest

| | |
|--|--|
| **Where** | **Repo root** |
| **Why** | Manifest drives paths, HTTP probes, and generator `--manifest` — without it scripts may fail closed instead of guessing `myapp` |

```bash
cp config/payments.manifest.example.yml config/payments.manifest.yml
bash scripts/validate_app_manifest.sh config/payments.manifest.example.yml
```

Key field: **`policy.module_dir: selinux/payments`** (not the default flat `selinux/`).

Point generators and deploy scripts at the manifest:

```bash
export APP_MANIFEST=config/payments.manifest.yml
export POLICY_APP=payments
```

## Scaffold with `sepolicy-generate` (RHEL / Stream host)

| | |
|--|--|
| **Where** | Linux with **`policycoreutils-devel`** installed |
| **Why** | Creates starter `.te`/`.if`/`.fc` files; script will **not** overwrite files already in git |

```bash
bash scripts/scaffold_sepolicy_module.sh payments payments_t
```

That runs:

```text
sepolicy-generate -a payments_t -t unconfined_t
```

in a temp dir, then copies **`payments.te`**, **`payments.if`**, and **`payments.fc`** into **`selinux/payments/`** only when those files are missing (won’t overwrite the reviewed module in git).

Edit types, baseline macros, and **`.if`** interfaces before compile. The checked-in **`payments.if`** exposes:

| Interface | Purpose |
|-----------|---------|
| **`payments_read_public_state(domain)`** | Read-only access to `payments_var_lib_t` |
| **`payments_domtrans(domain, role)`** | Transition into `payments_t` |

Consumers (e.g. another module’s `.te`) call these inside `optional_policy` or after `gen_require` — same as refpolicy modules.

## Compile

Uses the same compile image as `myapp` (override registry with **`SELINUX_BUILD_IMAGE`** — see [DOCKER_HUB_COMPILE_IMAGE.md](../admin/COMPILE_IMAGE.md)):

| | |
|--|--|
| **Where** | **Repo root** |
| **Why** | Produces `payments.pp` for install and CI compile gate |

```bash
bash scripts/lib/selinux_build_image.sh ensure   # or internal mirror
POLICY_MODULE=payments SELINUX_DOMAIN=payments_t \
  bash scripts/compile_and_validate.sh selinux/payments
```

CI runs this gate on every policy PR.

## Install

| | |
|--|--|
| **Where** | Target **SELinux host** with `sudo` |
| **Why** | Loads module into kernel policy store and fixes disk labels under app paths |

```bash
sudo semodule -i selinux/payments/payments.pp
sudo restorecon -Rv /opt/payments /var/lib/payments /var/log/payments /run/payments
```

## Related

- [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) — two RHEL boxes, inventories
- [config/README.md](../../config/README.md) — manifest schema (ports vs probe host)
- [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md) — canary / soak / enforce
- [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md) — AVC → policy with `--manifest config/payments.manifest.yml`
- [ADOPTION_CHECKLIST.md](../admin/ADOPTION_CHECKLIST.md) — org fork checklist
