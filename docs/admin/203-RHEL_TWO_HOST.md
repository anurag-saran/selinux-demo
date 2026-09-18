# 203 — Two Linux VMs (generate / canary / soak)

You have **three computers**. Only the two Linux VMs run SELinux. The Mac is the remote control.

The **customer talk** (vendor Tomcat already enforcing → tune inherited Tomcat → generate for Spring Boot) is **[202](../training/202-DEMO_GUIDE.md)** (`demo_present.sh`, one host, ~20 min). This file is the **~45 min three-host** walkthrough: ship shopapi policy with Ansible. Do not open this script in front of a customer who has not seen 202.

**Demo application is Spring Boot `shopapi`.** Offline `make check` uses deterministic fixtures. Do not install a second demo app on the VMs.

| Computer | Address | How you know you are typing on it |
|----------|---------|-----------------------------------|
| **Your Mac** | this laptop | Prompt looks like `asaran@asaran1-mac selinux-pac %` |
| **QA VM** (discovery box) | `192.168.64.6` | Prompt looks like `[ansible@rhel-qa ~]$` |
| **Prod VM** (pretend production) | `192.168.64.5` | Prompt looks like `[ansible@rhel-prod ~]$` |

**Golden rule:** look at the prompt before you paste.

If the prompt already says `[ansible@rhel-qa`, you are **already on the QA VM**. Do **not** `ssh` again.

If the guest hostname is still `rhel-dev`, the QA talk track runs `hostnamectl set-hostname rhel-qa` (prod: `rhel-prod`). SSH is by IP (`192.168.64.6` / `192.168.64.5`); the name is for the prompt.

Those addresses are this Mac’s UTM network. If a VM was recreated and `ping` fails, use the new addresses.

## Story

1. **From scratch:** install shopapi on rhel-qa with the types-only seed (`SELinuxContext=shopapi_t`, permissive) → curl `/health` `/state` `/log` (not `/feature-spool`) → generate `selinux/shopapi/` from those AVCs → **GitHub PR on selinux-pac** → canary on prod → **soak with the app up and a clean AVC file** → treat soak as complete (`force_enforce` + a change ticket; inventory still says 7 days).
2. **Outage, admin restore, then PaC:** `/feature-spool` writes `/var/spool/shopapi/feature.log` and returns **500** on **rhel-prod** → `emergency_rollback.yml` puts `shopapi_t` permissive so the app is **200** again (host stays Enforcing; no `semodule -i` on prod) → copy the AVC log to rhel-qa → generate + **second PR** → recanary prod → the same curl succeeds under the new module.

Re-running on the **same** VMs? On the Mac first: `bash scripts/reset_demo_vms.sh`, then start at [Present this lab](#present-this-lab-three-terminals). That unloads leftover `shopapi` modules and prod RPMs, restores the types-only `selinux/shopapi/` seed, and **untunes App B** (port 8090, `/opt/appdata` fcontext, connect boolean) so a 202 Act 2 on rhel-qa still produces denials. It does **not** uninstall the JVM. It is not `reset_host_state.yml`.

---

## Present this lab (three terminals)

| Window | Computer | Start here |
|--------|----------|------------|
| 1 | **Mac** | `cd /Users/asaran/projects/selinux-pac` then `bash scripts/demo_e2e_mac.sh` |
| 2 | **QA VM** | `ssh ansible@192.168.64.6` then, when the Mac says switch: `bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part app` (later `--part generate`) |
| 3 | **Prod VM** | `ssh ansible@192.168.64.5` then, when the Mac says switch: `bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app` (later `--part rpms`, `--part soak`, `--part soak-avc`, `--part fail`, `--part restore`, `--part retest`) |

Unattended: `bash scripts/demo_e2e_mac.sh --auto --no-type`. Talk-only: `--dry-run`.

The Mac script is the conductor. It types the explanations. Follow the `--part` it prints.

**Prod never clones this repo.** shopapi files arrive over `scp`. Policy arrives as `selinux-policy-ops` + `shopapi-selinux` RPMs.

QA inventory uses `soak_min_days: 0` so the talk can lock down. **Never copy that onto prod** (`inventory.production.yml` stays at 7 days). The gate is real; QA is lab-only. The Mac talk track prints a red **LAB ONLY** banner at that step.

---

## First-ship vs outage URLs

| When | Curl | Why |
|------|------|-----|
| Generate, soak | `http://127.0.0.1:8091/health` `/state` `/log` | In the first module |
| After enforce | `http://127.0.0.1:8091/feature-spool` | Writes `/var/spool/shopapi/feature.log` — **not** in the first `.fc` |

Port comes from `config/shopapi.manifest.yml` (`http.port`).

---

## Inventory

`bash scripts/setup_rhel_hosts.sh write` writes gitignored inventories with **`app_name: shopapi`**, `policy_pp_src` → `selinux/shopapi/shopapi.pp`, and `app_manifest_path` → `config/shopapi.manifest.yml`.

Lab QA inventory has `soak_min_days: 0`. **Never copy that onto prod.**

---

## Reset

```bash
bash scripts/reset_demo_vms.sh
```

Unloads leftover `shopapi` modules and prod RPMs. Restores the types-only `selinux/shopapi/` seed from git. Does not uninstall the JVM.

---

## Related

- **101** labs: [101-SELINUX.md](../training/101-SELINUX.md)
- **202** customer talk: [202-DEMO_GUIDE.md](../training/202-DEMO_GUIDE.md)
- **301** AAP: [301-ANSIBLE_OPERATIONS.md](301-ANSIBLE_OPERATIONS.md)
- **303** denial after ship: [303-DENIAL_RESPONSE.md](303-DENIAL_RESPONSE.md)
