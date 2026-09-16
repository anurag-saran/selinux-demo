# Two RHEL boxes (dev + prod)

This is the **end-to-end** document. [README — Try it on a Mac](../../README.md#try-it-on-a-mac) only gets Ansible talking to the VMs. **Everything after `bootstrap` is here.**

| You just ran (on the Mac) | What that meant | You are here |
|---------------------------|-----------------|--------------|
| `setup_rhel_hosts.sh write` | Inventories exist (gitignored) | Controller knows the IPs |
| `ping` | SSH works (`pong`) | Network + Python on both VMs |
| `doctor` | SELinux **Enforcing**; `ausearch` + `sesearch` found | Tools exist — see [Tools](#tools-this-lab-uses) |
| `bootstrap` | **Printed** SSH/`dnf` steps — it did **not** install the app | **Next: [§2](#2-on-rhel-dev--install-the-reference-app)** |

```text
Controller (Mac / AAP)          type commands HERE for Ansible / compile / RPMs
   ansible SSH ──► rhel-dev     type HERE for dnf, setup_staging_env, generator
   ansible SSH ──► rhel-prod    no git clone — RPMs only
```

**Bind ports** stay in the app manifest. **IPs** differ per box.

---

## Tools this lab uses

Doctor printed three lines per host, for example:

```text
Enforcing
/sbin/ausearch
/bin/sesearch
```

| Line / package | What it is | Why this tool needs it |
|----------------|------------|-------------------------|
| `Enforcing` (`getenforce`) | Whole-OS SELinux mode | Host must stay Enforcing. Only the **app domain** may be permissive during canary |
| `ausearch` (RPM **`audit`**) | Reads the kernel **audit log** | Finds **AVC** denials (“this process was denied that permission”). Generator + soak |
| `sesearch` (RPM **`setools-console`**) | Queries **installed policy** | Soak asks “is this allow already in the live module?” Net-new = AVC minus that |
| `selinux-policy-ops` (prod only) | Our ops RPM (`monitor_avc.sh`, …) | Prod has no git checkout; playbooks call scripts from this RPM |

`dnf install` on **rhel-dev** (printed by `bootstrap`) is the rest of the toolchain:

| Package | Commands you get | Why |
|---------|------------------|-----|
| `git` | `git clone` / `git pull` | Repo checkout **on rhel-dev only** |
| `python3` | Ansible modules, Flask, generator | Guest Python (the Mac ping warning about python3.9 is harmless) |
| `policycoreutils` | `restorecon`, `semodule` | Label files; install `.pp` modules |
| `policycoreutils-python-utils` | `semanage` | Per-domain permissive, port labels (`seport`) |
| `setools-console` | `sesearch` | Soak net-new (see above) |
| `audit` | `ausearch`, `auditd` | AVC log pipeline |
| `selinux-policy-devel` | refpolicy Makefile | Compile `.te` → `.pp` **on RHEL**. On a Mac controller you use the [compile image](COMPILE_IMAGE.md) instead |

Scripts/playbooks (run after packages exist):

| Command | Where you type | What it does |
|---------|----------------|--------------|
| `setup_staging_env.sh` | **rhel-dev** | Installs the **reference app** (`/opt/myapp`, systemd units, stub policy) |
| `selinux_pac_adopt.sh doctor` | **rhel-dev** | Same class of checks as host doctor, plus app paths |
| `compile_and_validate.sh selinux` | **Mac** | Builds `selinux/myapp.pp` from `.te`/`.fc` |
| `deploy_canary.yml` | **Mac** (Ansible) | Install module; **only** `myapp_t` permissive; HTTP probes; start soak clock |
| `dev_generate_policy.sh --apply` | **rhel-dev** | AVCs → proposed `.te`/`.fc` in the git checkout |
| `enforce_production.yml` | **Mac** | Soak gate, then take `myapp_t` out of permissive |
| `soak_monitor.yml` / `soak_status.yml` | **Mac** | Daily net-new check / read-only days elapsed |

Concepts: [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md) (§ labels, AVC, permissive domain).

---

## 1. Controller checks (`setup_rhel_hosts.sh`)

From **repo root on the Mac** (`cd ~/projects/selinux-demo` — not `$HOME`). These four commands only talk **to** the VMs over SSH.

| Command | What it does | Good sign |
|---------|----------------|-----------|
| `write --dev-host … --prod-host …` | Creates gitignored `ansible/inventory.dev.yml` and `ansible/inventory.production.yml`. Dev: **target** checkout paths (`/home/ansible/selinux-demo` for scripts + manifest), controller `.pp` path, `soak_min_days: 0`. Prod: RPMs, `soak_min_days: 7`, **no git**. | `Wrote …inventory.dev.yml` / `…inventory.production.yml` |
| `ping` | Ansible `ping` — SSH + Python | `SUCCESS` / `pong`. Ignore the python3.9 interpreter warning |
| `doctor` | Remote `getenforce`, `ausearch`, `sesearch` (prod also `rpm -q selinux-policy-ops`) | `Enforcing` + both tools. Ops RPM on prod can already be installed from an earlier lab |
| `bootstrap` | **Prints** the next SSH/`dnf` commands. Does **not** run them | Block titled `Bootstrap the DEV RHEL box` |

```bash
# Mac UTM lab IPs (change if ping fails after a VM recreate):
bash scripts/setup_rhel_hosts.sh write \
  --dev-host 192.168.64.6 \
  --prod-host 192.168.64.5 \
  --user ansible

bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
bash scripts/setup_rhel_hosts.sh bootstrap
```

Customer boxes: pass DNS names instead of those IPs. Examples: [`ansible/inventory.dev.example.yml`](../../ansible/inventory.dev.example.yml), [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml).

SSH user needs passwordless sudo (or become password). Collections: `ansible-galaxy collection install -r ansible/requirements.yml`.

---

## 2. On rhel-dev — install the reference app

`bootstrap` only **printed**. Type this **on rhel-dev** (not on the Mac):

```bash
ssh ansible@192.168.64.6

sudo dnf install -y git python3 policycoreutils policycoreutils-python-utils \
  setools-console audit selinux-policy-devel
# clone if ~/selinux-demo is missing:
# git clone https://github.com/anurag-saran/selinux-demo.git ~/selinux-demo
cd ~/selinux-demo
sudo bash scripts/setup_staging_env.sh
sudo bash scripts/selinux_pac_adopt.sh doctor
```

**Good sign:** `getenforce` is Enforcing; `systemctl is-active myapp.service myapp-backend.service` is `active`.

If this lab was already set up, skip `dnf`/clone when packages and `~/selinux-demo` exist; only re-run `setup_staging_env.sh` if the units are down.

Then **leave the SSH session**. Compile and canary from the **Mac**. `inventory.dev.yml` uses `/home/ansible/selinux-demo` **on the VM** for scripts and the manifest; the compiled `.pp` is copied from this Mac.

```bash
cd /Users/asaran/projects/selinux-demo
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml
```

Export AVCs **on rhel-dev**:

```bash
ssh ansible@192.168.64.6
cd ~/selinux-demo
bash scripts/dev_generate_policy.sh --apply
```

Lab enforce (dev only — `soak_min_days: 0`). The playbook **refuses** that value on the `production` group. Do **not** copy it into `inventory.production.yml`.

```bash
# back on the Mac
ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml \
  -e change_ticket=LAB
```

---

## 3. On rhel-prod — RPMs, canary, soak (no git)

**Do not clone the git repo onto prod.** On the **Mac**, build RPMs with [`packaging/build_rpms.sh`](../../packaging/build_rpms.sh), install `selinux-policy-ops` + `myapp-selinux` on rhel-prod, then:

| Playbook | What it does | Good sign |
|----------|----------------|-----------|
| `deploy_canary.yml --limit canary` | Ops + app SELinux RPM, module in, **only** `myapp_t` permissive, probes, soak marker | Play `ok`; HTTP 200; host still Enforcing |
| `soak_monitor.yml --limit canary` | AVCs since canary; **net-new** vs installed policy (`sesearch`) | `Soak OK` / `net_new=0`. Schedule daily in AAP |
| `soak_status.yml --limit canary` | Read-only: days elapsed vs `soak_min_days: 7` | `days_elapsed` in the output |
| `enforce_production.yml -e change_ticket=CHG123` | Soak gate, then remove permissive | Fails until 7 days. Lab: enforce on **dev** instead |

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123
```

The example inventory puts the **same host** in `canary` and `production`. Add more names under `production:` when you have a fleet.

AAP objects: [`ansible/aap/`](../../ansible/aap/) and [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md). Denial after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md). Soak/enforce gates: [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md).

---

## Backup: local Podman

Use this only when you have **no RHEL boxes**.

| Step | Command |
|------|---------|
| One-time VM | [SELINUX_TRAINING_LAB.md — Running on macOS](../training/SELINUX_TRAINING_LAB.md#running-on-macos) |
| Staging in VM | `bash scripts/run_on_podman_vm.sh setup` |
| AVC export from Mac | `bash scripts/dev_generate_policy.sh --use-vm --apply` |
| Compile without RHEL devel | [COMPILE_IMAGE.md](COMPILE_IMAGE.md) |

When the two RHEL boxes exist, use `setup_rhel_hosts.sh` and stop using `--use-vm`.
