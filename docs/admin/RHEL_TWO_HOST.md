# Two RHEL boxes (dev + prod)

Preferred topology: **one RHEL host for development** (staging, AVC discovery, policy PRs) and **one RHEL host for production** (canary → soak → enforce). Run Ansible from a controller (laptop or AAP). Developers work on **dev**; admins ship to **prod**. **Local Podman is a backup** if you do not have RHEL yet.

```text
Controller (laptop / AAP)
   ansible SSH ──► rhel-dev     setup_staging_env.sh, AVC export, canary (lab soak_min_days=0)
   ansible SSH ──► rhel-prod    RPMs, canary, soak_monitor, enforce (soak_min_days=7)
```

**Bind ports** stay in the app manifest (same on both boxes). **IPs** differ per box (`ansible_host`, optional `http_probe_host`).

## 1. Write inventories

From **repo root on the controller**:

```bash
bash scripts/setup_rhel_hosts.sh write \
  --dev-host rhel-dev.example.com \
  --prod-host rhel-prod.example.com \
  --user ansible

bash scripts/setup_rhel_hosts.sh ping
bash scripts/setup_rhel_hosts.sh doctor
```

Writes gitignored `ansible/inventory.dev.yml` and `ansible/inventory.production.yml`. Examples to copy by hand: [`ansible/inventory.dev.example.yml`](../../ansible/inventory.dev.example.yml), [`ansible/inventory.production.example.yml`](../../ansible/inventory.production.example.yml).

SSH user needs passwordless sudo (or become password). `ansible` collection install: `ansible-galaxy collection install -r ansible/requirements.yml`.

## 2. Bootstrap the dev box

Print the SSH commands (packages, clone, demo app):

```bash
bash scripts/setup_rhel_hosts.sh bootstrap
```

On **rhel-dev** as root (or sudo):

```bash
sudo dnf install -y git python3 policycoreutils policycoreutils-python-utils \
  setools-console audit selinux-policy-devel
# clone this repo onto the box, then:
cd ~/selinux-demo
sudo bash scripts/setup_staging_env.sh
sudo bash scripts/selinux_pac_adopt.sh doctor
```

Compile **on the controller** (native RHEL devel, or Podman compile image on a laptop):

```bash
bash scripts/compile_and_validate.sh selinux
ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml
```

Export AVCs **on the dev box** (or from the controller after SSH):

```bash
# on rhel-dev, repo checkout:
bash scripts/dev_generate_policy.sh --apply
```

Dev inventory sets **`soak_min_days: 0`** so you can exercise enforce in a lab. The enforce playbook **refuses** that value on hosts in the `production` group. Do **not** copy it into `inventory.production.yml`.

## 3. Production box

**Do not clone the git repo onto prod.** Install RPMs (`selinux-policy-ops`, `myapp-selinux`) from [`packaging/build_rpms.sh`](../../packaging/build_rpms.sh), then:

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123
```

The example inventory puts the **same host** in `canary` and `production`. Add more names under `production:` when you have a fleet.

AAP objects: [`ansible/aap/`](../../ansible/aap/) and [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md) (workflows **Release canary** and **Promote to enforce**). File or port denied after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md). Soak/enforce gates: [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md).

## Backup: local Podman

Use this only when you have **no RHEL boxes** (workshop laptop, macOS).

| Step | Command |
|------|---------|
| One-time VM | [SELINUX_TRAINING_LAB.md — Running on macOS](../training/SELINUX_TRAINING_LAB.md#running-on-macos) |
| Staging in VM | `bash scripts/run_on_podman_vm.sh setup` |
| AVC export from Mac | `bash scripts/dev_generate_policy.sh --use-vm --apply` |
| Compile without RHEL devel | [DOCKER_HUB_COMPILE_IMAGE.md](COMPILE_IMAGE.md) |

When the two RHEL boxes arrive, switch to `setup_rhel_hosts.sh` and stop using `--use-vm` for day-to-day work.
