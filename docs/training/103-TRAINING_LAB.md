# 103 — Hands-on recap

Do **[101](101-SELINUX.md)** first (one RHEL box, shopapi, one AVC at a time). Then the three-app talk (**[202](202-DEMO_GUIDE.md)**).

There is no separate Flask lab or `selinux/stub/` overlay. `make training-lab` is a **talk dry-run** (`demo_present.sh --dry-run`); it does not replace **101**.

| # | Guide | Role |
|---|--------|------|
| **101** | [SELinux 101](101-SELINUX.md) | Pre-talk labs 0–7 — type these on **rhel-qa** |
| **102** | [SELinux basics](102-SELINUX_BASICS.md) | Reading primer — 101 lab 0 is §1–4 |
| **201** | [Code walkthrough](201-CODE_WALKTHROUGH.md) | Where scripts and tools live |
| **202** | [Three-app customer talk](202-DEMO_GUIDE.md) | `demo_present.sh`: one host, ~20 min |
| **203** | [Two Linux VMs](../admin/203-RHEL_TWO_HOST.md) | `demo_e2e_*.sh`: three hosts, ~45 min |
| **205** | [Testing](../developers/205-TESTING.md) | Offline `make check` (deterministic fixtures + smoke) |

## Recap (after 101)

Laptop (no SELinux):

```bash
make check
make training-lab
# same as: bash scripts/demo_present.sh --dry-run --profile customer
```

`make check` uses committed **`selinux/myapp.te`** / **`config/myapp.manifest.yml`** as **generator goldens**, plus **`selinux/shopapi/`** and **`selinux/payments/`**. It does not start an application. Typed generator practice without a VM: [101-SELINUX.md — Appendix B](101-SELINUX.md#appendix-b-laptop-no-selinux).

RHEL host (full talk, after 101):

```bash
make demo-bootstrap
bash scripts/demo_present.sh --preflight
bash scripts/demo_present.sh --profile customer
```

Shopapi-only (101 prep):

```bash
sudo bash scripts/demo_bootstrap.sh --shopapi-only
```

First-ship shopapi probes (on the SELinux host, not the Mac). In the **101**, curl **only `/log`** until lab 5. In the **talk**, all three first-ship URLs:

```bash
curl -sf http://127.0.0.1:8091/health
curl -sf http://127.0.0.1:8091/state
curl -sf http://127.0.0.1:8091/log
```

Labels and domain:

```bash
ls -Z /opt/shopapi /var/log/shopapi /var/lib/shopapi
ps -eZ | grep shopapi
```

Generate from observed AVCs:

```bash
sudo bash scripts/dev_generate_policy.sh --apply --app-name shopapi --app-root "$(pwd)"
```

Do not curl `/feature-spool` until the first module is enforcing. That path is 101 lab 5 and the outage beat in [203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md).

## Running on macOS

macOS has **no SELinux**. Use two RHEL VMs — [203-RHEL_TWO_HOST.md](../admin/203-RHEL_TWO_HOST.md) and [README — Try it on a Mac](../../README.md#try-it-on-a-mac). Run `getenforce`, `ls -Z`, and generate **on rhel-qa**, not in macOS Terminal. Laptop-only 101: [101-SELINUX.md — Appendix B](101-SELINUX.md#appendix-b-laptop-no-selinux).
