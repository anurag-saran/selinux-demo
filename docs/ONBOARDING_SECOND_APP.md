# Onboarding a second application (payments example)

The repo ships **`myapp`** as the primary demo and **`payments`** as a second onboarded module: manifest template, policy under **`selinux/payments/`**, and a published **`.if`** interface for dependent modules.

## Manifest

Copy and customize:

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

On a machine with `policycoreutils-devel`:

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

Uses the same compile image as `myapp` (override registry with **`SELINUX_BUILD_IMAGE`** — see [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md)):

```bash
bash scripts/lib/selinux_build_image.sh ensure   # or internal mirror
POLICY_MODULE=payments SELINUX_DOMAIN=payments_t \
  bash scripts/compile_and_validate.sh selinux/payments
```

CI runs this gate on every policy PR.

## Install

```bash
sudo semodule -i selinux/payments/payments.pp
sudo restorecon -Rv /opt/payments /var/lib/payments /var/log/payments /run/payments
```

## Related

- [config/README.md](../config/README.md) — manifest schema
- [DETERMINISTIC_POLICY.md](DETERMINISTIC_POLICY.md) — AVC → policy with `--manifest config/payments.manifest.yml`
