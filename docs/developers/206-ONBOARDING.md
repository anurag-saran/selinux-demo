# 206 — Onboarding an application

**Customer layout:** policy lives in **the application GitHub repo**, not in selinux-pac. Generate and compile on a **QA** RHEL box (`rhel-qa`). Admins ship a signed RPM and promote with AAP. **Prod never clones git.**

This repository is the **platform** (generator, forbidden-pattern CI, Ansible/AAP, ops RPM). The live two-host demo application is **shopapi** (`demo/shopapi/`, `selinux/shopapi/`) — policy PRs land **here**. `selinux/myapp.te` and `config/myapp.manifest.yml` remain **offline generator goldens** for `make check`.

**Prerequisites:** [102-SELINUX_BASICS.md](../training/102-SELINUX_BASICS.md) §1–7 and [config/README.md](../../config/README.md). Deploy: [301-ANSIBLE_OPERATIONS.md](../admin/301-ANSIBLE_OPERATIONS.md). Prod AVC: [303-DENIAL_RESPONSE.md](../admin/303-DENIAL_RESPONSE.md). Two-host lab: [203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md). Org checklist: [304-ADOPTION_CHECKLIST.md](../admin/304-ADOPTION_CHECKLIST.md).

---

## Where things live

| In the **app** GitHub repo | In **selinux-pac** / AAP |
|----------------------------|--------------------------|
| `selinux/*.te` `.fc` `policy_version.txt` | Generator (`dev_generate_policy.sh`), reusable Policy CI |
| `config/<app>.manifest.yml` (ports, units, probes) | `deploy_canary.yml` / soak / enforce / rollback |
| App binaries and systemd units | `selinux-policy-ops` RPM (scripts on prod) |
| Policy PR + CODEOWNERS (app + platform on `selinux/`) | Change ticket, 7-day soak, **no git on prod** |

```text
app repo  --deploy build-->  rhel-qa  --AVCs, generate-->  PR on app repo
app repo  --merged policy-->  RPM build  --AAP canary-->  rhel-prod
```

On **rhel-qa** (first confine or a new feature):

1. Deploy **this** app build (no module, or last shipped module).
2. First confine: run unconfined, show the AVC log is empty / not `app_t`, then create the domain (types + labels). Later features: old module + new endpoint → net-new AVCs.
3. Generate (`dev_generate_policy.sh` pre-flights vendor/base policy first — JWS, EAP, httpd, named, postgresql), open a PR **on the app repo**. CI must run `forbidden-patterns` (copy [`.github/workflows/selinux-policy-ci.yml`](../../.github/workflows/selinux-policy-ci.yml) or call it as a reusable workflow). See [204-DETERMINISTIC_POLICY.md](204-DETERMINISTIC_POLICY.md) (vendor pre-flight).
4. After merge: build `<app>-selinux` from **that** commit (`policy_version.txt` is the app’s policy NVR, not selinux-pac’s tag). AAP canary on prod.

Do not copy Ansible playbooks into every app repo. Do not keep a second “live” `.te` in selinux-pac for a customer app; this repo’s `selinux/myapp.te` is the **fixture** for tests. The demo’s live allow list is generated into [`selinux/shopapi/`](../../selinux/shopapi/).

**Fast path (still on this clone, for the payments example below):**

```bash
bash scripts/setup_rhel_hosts.sh write --qa-host QA --prod-host PROD
# --dev-host is the same flag (legacy name)
bash scripts/selinux_pac_adopt.sh doctor          # on rhel-qa
bash scripts/selinux_pac_adopt.sh init payments
```

**Where commands run:**

| Step | Where |
|------|--------|
| Copy manifest, `validate_app_manifest.sh`, compile | **rhel-qa** (`selinux-policy-devel`) |
| `scaffold_sepolicy_module.sh`, `semodule -i`, `restorecon` | **rhel-qa** |
| `ansible-playbook deploy_canary.yml` / `soak_monitor.yml` (AAP **Release canary** / **Soak monitor**) | **Controller** SSH to **rhel-prod** ([203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md)) |

---

## Payments example (second module in *this* repo)

The reference tree also ships **`payments`**: manifest template, policy under **`selinux/payments/`**, and a published **`.if`** interface. Use it to practice a second app **without** a separate GitHub repo. A customer’s second app would use the table above in **their** repo instead.

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

Compile like `myapp` on a host with `selinux-policy-devel`:

| | |
|--|--|
| **Where** | **rhel-qa** repo root (app checkout or this reference tree) |
| **Why** | Produces `payments.pp` for install (`compile_and_validate.sh` also runs forbidden-patterns) |

```bash
POLICY_MODULE=payments SELINUX_DOMAIN=payments_t \
  bash scripts/compile_and_validate.sh selinux/payments
```

PR CI (`forbidden-patterns`, `version-consistency`) runs on `selinux/` including `payments/` when those paths change. Compile stays on rhel-qa (or the app’s QA box).

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

- [203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md) — Mac + rhel-qa + rhel-prod
- [config/README.md](../../config/README.md) — manifest schema (ports vs probe host)
- [301-ANSIBLE_OPERATIONS.md](../admin/301-ANSIBLE_OPERATIONS.md) — canary / soak / enforce
- [204-DETERMINISTIC_POLICY.md](204-DETERMINISTIC_POLICY.md) — AVC → policy with `--manifest config/payments.manifest.yml`
- [304-ADOPTION_CHECKLIST.md](../admin/304-ADOPTION_CHECKLIST.md) — org fork checklist
