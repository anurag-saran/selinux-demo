# Two Linux VMs — follow this from start to finish

You have **three computers**. Only the two Linux VMs run SELinux. The Mac is the remote control.

| Computer | Address | How you know you are typing on it |
|----------|---------|-----------------------------------|
| **Your Mac** | this laptop | Prompt looks like `asaran@asaran1-mac selinux-pac %` |
| **Dev VM** (practice box) | `192.168.64.6` | Prompt looks like `[ansible@rhel-dev ~]$` |
| **Prod VM** (pretend production) | `192.168.64.5` | Prompt looks like `[ansible@rhel-prod ~]$` |

**Golden rule:** look at the prompt before you paste. A command meant for the VM will fail on the Mac, and the other way around.

If the prompt already says `[ansible@rhel-dev`, you are **already on the dev VM**. Do **not** run `ssh ansible@192.168.64.6` again. That logs into the same machine from itself (no Mac SSH key), so you get `Permission denied`. Skip the `ssh` line and run the next command.

Those addresses are this Mac’s UTM network. If a VM was recreated and `ping` fails, use the new addresses everywhere you see `192.168.64.6` or `192.168.64.5`.

**This lab is two acts**

1. **From scratch:** types-only domain seed on rhel-dev → AVCs → generate the first real `.te` → **GitHub PR** (CI `forbidden-patterns` should pass) → canary on prod → **soak with the app up and a clean AVC file** → treat soak as complete (`force_enforce` + a change ticket; inventory still says 7 days).
2. **Outage, admin restore, then PaC:** `/feature-spool` returns **500** on **rhel-prod** → `emergency_rollback.yml` puts `myapp_t` permissive so the app is **200** again (host stays Enforcing; no `semodule -i` on prod) → copy the AVC log to rhel-dev → generate + **second PR** → recanary prod → the same curl succeeds under the new module.

Do **not** compile and canary last week’s committed `1.1.x` module before generate. Do **not** overlay or mention `selinux/stub/` in this talk (that folder is training labs only).

**Jump ahead**

- Finished README `write` / `ping` / `doctor` / `bootstrap`? Start at [Part 2](#part-2--install-the-app-and-a-types-only-domain-seed).
- First generate already wrote `selinux/myapp.pp` on rhel-dev? Start at [Part 4](#part-4--copy-generated-policy-and-open-a-github-pr).

---

## Present this lab (three terminals)

Open **three** Terminal windows. Each script types the explanation, types the command, then runs it (press Enter between steps). `--dry-run` types and talks only.

| Window | Computer | Start here |
|--------|----------|------------|
| 1 | **Mac** | `cd /Users/asaran/projects/selinux-pac` then `bash scripts/demo_e2e_mac.sh` |
| 2 | **Dev VM** | `ssh ansible@192.168.64.6` then, when the Mac says switch: `bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part app` (later `--part generate`) |
| 3 | **Prod VM** | `ssh ansible@192.168.64.5` then, when the Mac says switch: `bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app` (later `--part rpms`, `--part soak`, `--part soak-avc`, `--part fail`, `--part restore`, `--part retest`) |

The Mac script copies the VM talk tracks over SSH. Stay in the window whose prompt matches the table. Do not run `ssh ansible@192.168.64.6` from inside rhel-dev.

`bash scripts/demo_e2e_mac.sh --auto --no-type` skips the Enter pauses and runs the rhel-dev / rhel-prod talk tracks over SSH (recording / unattended).

To show the real 7-day refuse on prod instead of talk-only enforce:

```bash
DEMO_PROD_FORCE_ENFORCE=false bash scripts/demo_e2e_mac.sh
```

---

## Words you will see (plain English)

| Word | Meaning |
|------|---------|
| **SSH** | “Log into the other computer from here.” Example: `ssh ansible@192.168.64.6` |
| **SELinux** | Linux’s extra lock on “this program may / may not do that” |
| **Enforcing** | The lock is on for the whole machine (what we want) |
| **AVC** | One line in the log that means SELinux said **no** |
| **Domain seed** | Types + file labels so systemd can start `myapp_t`. Not an allow list. Permissive is `semanage`, not extra rules in the `.te` |
| **Canary** | Install new rules in a **safe** way: the app is allowed to break them, but every break is logged |
| **Enforce** | Take away that safety net. Real blocks start |
| **Soak** | First-ship traffic stays 200; AVC file stays clean. **7 days on prod** before enforce. The lab **dev** box skips the wait |
| **PR** | GitHub pull request. CODEOWNERS review `selinux/` before you treat it as the product |
| **RPM** | An installer file for RHEL (like a `.pkg` on a Mac). Prod gets SELinux tools this way — **not** by cloning git |
| **Playbook** | A recipe Ansible runs from the Mac against a VM |

More detail later: [SELINUX_BASICS.md](../policy/SELINUX_BASICS.md).

---

## Part 1 — Can the Mac reach the VMs?

**Type every command in this part on: your Mac**

Open Terminal, then:

```bash
cd /Users/asaran/projects/selinux-pac
```

You must be in that folder. `cd` by itself (your home folder) is the wrong place.

### 1a. Save the VM addresses

**What it does:** Creates two small files on the Mac that tell Ansible “dev is `192.168.64.6`, prod is `192.168.64.5`.” Those files stay on your laptop (they are not committed to git).

```bash
bash scripts/setup_rhel_hosts.sh write \
  --dev-host 192.168.64.6 \
  --prod-host 192.168.64.5 \
  --user ansible
```

**You should see:** `Wrote …/inventory.dev.yml` and `Wrote …/inventory.production.yml`.

Skip this if you already ran it, unless an IP changed. Running it again overwrites those files.

### 1b. Ping (can we SSH?)

**What it does:** Ansible logs into both VMs and asks “are you there?”

```bash
bash scripts/setup_rhel_hosts.sh ping
```

**You should see:** `SUCCESS` / `pong` for `rhel-dev` and `rhel-prod`.

A yellow warning about `python3.9` is normal. Ignore it.

### 1c. Doctor (are SELinux tools there?)

**What it does:** On each VM it prints whether SELinux is on, and whether two log tools exist (`ausearch` = read the “no” log, `sesearch` = ask “is this already allowed?”).

```bash
bash scripts/setup_rhel_hosts.sh doctor
```

**You should see:** `Enforcing`, then a path like `/sbin/ausearch`, then `/bin/sesearch`. Prod may also say an ops RPM is not installed yet — that is OK until Part 6.

### 1d. Copy the talk tracks, then print bootstrap

The typewriter Mac script runs `scripts/sync_rhel_dev.sh` and copies the Flask app plus talk track to the prod VM. If you are following by hand:

```bash
bash scripts/sync_rhel_dev.sh
ssh ansible@192.168.64.5 'mkdir -p ~/e2e-demo/lib ~/e2e-demo/scripts ~/e2e-demo/app'
scp scripts/demo_e2e_rhel_prod.sh ansible@192.168.64.5:~/e2e-demo/
scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ansible@192.168.64.5:~/e2e-demo/lib/
scp scripts/setup_staging_env.sh scripts/wait_for_endpoints.sh ansible@192.168.64.5:~/e2e-demo/scripts/
scp -r app/. ansible@192.168.64.5:~/e2e-demo/app/
```

**Bootstrap** only **prints** commands. It does **not** install the demo app.

```bash
bash scripts/setup_rhel_hosts.sh bootstrap
```

**You should see:** a block starting `=== Bootstrap the DEV RHEL box`. Do not stop there. Follow **Part 2** below.

One-time on a new Mac, if Ansible collections are missing:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

The SSH user `ansible` needs sudo on the VMs (no password, or Ansible will ask).

---

## Part 2 — Install the app and a types-only domain seed

The Mac still has no SELinux. The **demo website** lives on `192.168.64.6` (and, in Part 2g, on prod). Install the Flask app with `--app-only` (no SELinux module). Then write a **types-only domain seed** so systemd can start `myapp_t`. Permissive is `semanage`, not extra allows in the `.te`. Generate writes the first real policy from AVCs.

### 2a. Log into the dev VM

Skip this if the prompt already says `[ansible@rhel-dev`. You are already there.

**Type this on: your Mac** (only if you still see `asaran@asaran1-mac`)

```bash
ssh ansible@192.168.64.6
```

**What it does:** Opens a remote terminal on the Linux VM.

**You should see:** the prompt change to `[ansible@rhel-dev ~]$`. From here until you type `exit`, you are **on the VM**.

### 2b. Install Linux packages

**Type this on: the dev VM** (prompt must say `rhel-dev`)

| Package | In human terms |
|---------|----------------|
| `git` | Download this project onto the VM |
| `python3` | Run the demo app and helper scripts |
| `policycoreutils` + `policycoreutils-python-utils` | Load SELinux rules and labels |
| `setools-console` | `sesearch` — “is this already allowed?” |
| `audit` | `ausearch` — read the “permission denied” log |
| `selinux-policy-devel` | Build rules **on Linux** (the Mac cannot compile) |

```bash
sudo dnf install -y git python3 policycoreutils policycoreutils-python-utils \
  setools-console audit selinux-policy-devel
```

**You should see:** `Complete!` or “already installed.”

### 2c. Copy the project onto the VM (if it is missing)

**Type this on: the dev VM**

**What it does:** Puts the project at `/home/ansible/selinux-pac` **on the VM**. That is a **second copy**. The Mac still has `/Users/asaran/projects/selinux-pac`.

Skip if this already works: `ls ~/selinux-pac`

```bash
git clone https://github.com/anurag-saran/selinux-pac.git ~/selinux-pac
```

(The Mac talk track rsyncs instead of clone when the tree already exists.)

### 2d. Install the app (no policy module)

**Type this on: the dev VM**

```bash
cd ~/selinux-pac
sudo bash scripts/setup_staging_env.sh --app-only
```

**What it does:** Installs a tiny website at `/opt/myapp` and starts `myapp` and `myapp-backend`. It does **not** load a SELinux module.

Then write types + file labels and load them. `semanage permissive` logs denials without blocking:

```bash
sudo bash scripts/write_domain_seed.sh --load
head -20 selinux/myapp.te
cat selinux/policy_version.txt
```

**You should see:** `policy_module(myapp, 1.0.0)` and types / `init_daemon_domain` — **not** a page of extra `allow` lines, and **not** `permissive myapp_t` inside the `.te`.

Then:

```bash
sudo bash scripts/selinux_pac_adopt.sh doctor
getenforce
systemctl is-active myapp.service myapp-backend.service
```

**You should see:** `Enforcing`, and `active` twice.

### 2e. Customer-visible files under `selinux/` on rhel-dev

Say this while `ls selinux/myapp.te selinux/myapp.fc selinux/policy_version.txt` is on the screen. Do **not** `ls selinux/stub/` in this talk.

| File | What it is |
|------|------------|
| **`myapp.te`** | Type enforcement. After `write_domain_seed.sh` this is types + systemd transition only. After `dev_generate_policy.sh --apply` it is the first real allow list from AVCs. |
| **`myapp.fc`** | `file_contexts`: which path gets which type. `restorecon` applies this. The generator adds rows when AVCs show unlabeled or wrong-type files. |
| **`policy_version.txt`** | One line, kept in lockstep with `policy_module(myapp, X.Y.Z)` inside the `.te`. PRs and the `myapp-selinux` RPM bump this. |
| **`myapp.pp`** | Compiled binary (**gitignored**). Built on rhel-dev only. Copied to the Mac so Ansible can ship it. A Mac cannot compile SELinux. |
| **`myapp_ports.cil`** | Optional CIL `portcon` for hosts without `semanage`. On RHEL, canary uses Ansible `seport`. |
| **`myapp_canary.te` / `.fc`** | Optional overlay when `semanage` is missing. Not loaded in this talk. |
| **`payments/`** | Second sample app for onboarding. Not this talk. |
| **`policy_out/`** (created in Part 3) | `avc.log` is the denial export. Generated `.te`/`.fc` live here before `--apply` copies them into `selinux/`. `pr_body.md` is the GitHub PR text. |

Git reviews these files. Prod never clones them — it gets an RPM built from them.

### 2f. Hit the first-ship URLs (collect AVCs)

Do **not** call `/feature-spool`. That test is Act 2 **on prod**.

```bash
for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
  echo "=== GET ${path} ==="
  curl -sf "http://127.0.0.1:8888${path}" | head -c 80
  echo
done
curl -sf http://127.0.0.1:8889/health; echo
```

**You should see:** JSON from each path. Under the types-only seed plus `semanage permissive`, the app succeeds; audit still records denials.

Stay on rhel-dev for Part 3 (or go back to the Mac so the typewriter can hand off `--part generate`).

### 2g. Install the same app on prod (still no policy)

**Type this on: the prod VM** (after the Mac has copied `~/e2e-demo/app` and `scripts/setup_staging_env.sh`)

```bash
sudo dnf install -y python3 policycoreutils policycoreutils-python-utils
sudo bash ~/e2e-demo/scripts/setup_staging_env.sh --app-only
curl -sf -o /dev/null http://127.0.0.1:8888/ && echo 'HTTP 200'
```

No git clone. No domain seed on prod. Policy arrives later as an RPM.

---

## Part 3 — Generate the first real policy from AVCs

Look at the prompt:

- **`asaran@asaran1-mac`** — you are on the Mac. Log in first: `ssh ansible@192.168.64.6`
- **`[ansible@rhel-dev`** — you are already on the VM. **Do not SSH.**

Then **on the dev VM** (use `sudo` — the security log is root-only, and `policy_out/` was created as root by the earlier install):

```bash
cd ~/selinux-pac
sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp
sudo bash scripts/dev_generate_policy.sh --apply
bash scripts/compile_and_validate.sh selinux
ls -l selinux/myapp.te selinux/myapp.fc selinux/policy_version.txt selinux/myapp.pp
head -30 selinux/myapp.te
ls policy_out
```

**What it does:** Reads the “SELinux said no” log (`ausearch`) and writes allow rules into **this VM’s** `selinux/`. `--apply` copies them from `policy_out/`. Compile turns `.te`/`.fc` into `myapp.pp`.

**You should see:** new allow lines (not “nothing new” against last week’s 1.1.x module), `Built selinux/myapp.pp`, and `policy_out/pr_body.md`.

Do **not** log out yet if you still need to scp from the Mac. The Mac talk track copies the files over SSH without you typing `exit`.

---

## Part 4 — Copy generated policy and open a GitHub PR

**Type every command in this part on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
mkdir -p policy_out
scp ansible@192.168.64.6:~/selinux-pac/selinux/myapp.te \
    ansible@192.168.64.6:~/selinux-pac/selinux/myapp.fc \
    ansible@192.168.64.6:~/selinux-pac/selinux/policy_version.txt \
    ansible@192.168.64.6:~/selinux-pac/selinux/myapp.pp \
    selinux/
scp ansible@192.168.64.6:~/selinux-pac/policy_out/pr_body.md policy_out/pr_body.md
cat selinux/policy_version.txt
bash scripts/demo_open_generated_pr.sh
```

**What it does:** Puts generated sources on the laptop (`policy_pp_src` is a Mac path). Opens a **live** GitHub PR from those files (CODEOWNERS + `pending-admin-review`). GitHub Actions runs `forbidden-patterns` (same script as `validate_forbidden_patterns.sh`). The generator already ran that check, so the job should be **green**. Needs `gh auth login` and push access.

**You should see:** a PR URL, then `Forbidden-pattern checks passed`. Merge is optional for the rest of this talk — canary uses the `.pp` you just copied.

Do **not** run `scripts/open_demo_policy_pr.sh` here. That script is a frozen 1.1.1 → 1.1.2 snapshot, not this generate.

---

## Part 5 — Canary + lab enforce on the dev VM

**Type this on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml
```

**What it does:** From the Mac, Ansible logs into `192.168.64.6`, copies `myapp.pp`, loads it, turns **only the demo app** to “log but don’t block,” hits the website, and starts a timer.

**You should see:** `failed=0` at the bottom. A line like `Recent myapp_t events: 0 raw, 0 net-new`.

If it says the app manifest was not found under `/Users/...`, you are on an old inventory. Re-run Part 1a.

Then lock down **dev** (lab inventory waits 0 days — do not copy that onto prod):

```bash
ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml \
  -e change_ticket=LAB
```

**You should see:** `failed=0`. On the VM, `getenforce` is still `Enforcing`. Only the demo app’s extra “allowed to break rules” flag is gone.

---

## Part 6 — Same policy on prod (RPMs; clean soak; talk-only enforce)

**Do not** run `git clone` on `192.168.64.5`. Production gets SELinux helpers from installer files (RPMs). The Flask app should already be running from [Part 2g](#2g-install-the-same-app-on-prod-still-no-policy).

### 6a. Build the installer files

**Type this on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
bash packaging/build_rpms.sh
ls dist/*.rpm
```

**What it does:** Builds two RPMs: tools (`selinux-policy-ops`) and the app’s SELinux rules (`myapp-selinux`). `rpmbuild` runs on **rhel-dev**; this laptop collects `dist/*.rpm`.

**You should see:** `Built RPMs in …/dist/` and two `.rpm` files.

### 6b. Copy them to the prod VM

```bash
scp dist/selinux-policy-ops-*.rpm dist/myapp-selinux-*.rpm ansible@192.168.64.5:~/
```

**You should see:** `100%` for each file.

### 6c. Install them on prod

If the prompt already says `[ansible@rhel-prod`, skip `ssh`. If you still see `asaran@asaran1-mac`:

```bash
ssh ansible@192.168.64.5
```

Then **on the prod VM**:

```bash
sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit
sudo rpm -Uvh --force ~/selinux-policy-ops-*.rpm ~/myapp-selinux-*.rpm
rpm -q selinux-policy-ops myapp-selinux
```

(`dnf localinstall` is a no-op when the NVR is unchanged and left stale scripts last time. `--force` the newest files in `~`.)

**You should see:** two package names with versions. Then go back to the Mac (type `exit` if you SSHed by hand).

### 6d. Canary, clean soak, talk-only enforce

**Type the Ansible commands on: your Mac.** Switch to the prod window when a `--part` line says so.

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary
```

Canary left `myapp_t` permissive. First-ship URLs are in the module you just shipped.

**On the prod VM** (`bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak`):

```bash
for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
  echo "=== GET ${path} ==="
  curl -sf "http://127.0.0.1:8888${path}" | head -c 80
  echo
done
sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp || echo "Good: no myapp AVC"
```

**You should see:** HTTP **200** on those six URLs and **no** myapp denials. Do **not** call `/feature-spool` yet.

**On the Mac**, soak_monitor should **pass** (net-new 0 vs installed policy):

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary
```

**On the prod VM** (`bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc`):

```bash
sudo test ! -f /var/lib/myapp/selinux_soak_last_fail.avc && echo "Good: no soak fail AVC file"
```

**You should see:** no fail file. Soak is clean.

**On the Mac:**

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
```

`soak_status` will show **0 of 7** days. That is correct. `inventory.production.yml` still has `soak_min_days: 7`. Enforce **refuses** a lab 0-day window on the `production` group.

**For this talk** we treat soak as complete with the product break-glass (`force_enforce` still needs a change ticket). We are not changing prod inventory to 0.

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=DEMO -e force_enforce=true
```

**You should see:** `failed=0`. Say out loud: a real shop omits `force_enforce` and waits seven clean days.

To demonstrate the refuse instead:

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123
```

That fails on purpose until soak elapses.

In a company, the daily log check and the 7-day wait are usually scheduled in Ansible Automation Platform. Extra reading: [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md), [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md). If something is denied after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

---

## Part 7 — Fail on prod; admin restore; generate on dev; second PR; recanary

A new write path was never in the first policy. Policy is now enforcing on prod. Show the outage, restore the app as admin, then fix policy on rhel-dev. Do not generate or `semodule -i` on prod.

### 7a. The outage

**On the prod VM** (`bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail`):

```bash
curl -sS http://127.0.0.1:8888/feature-spool || true
sudo ausearch -m avc -ts recent | tee /tmp/prod-feature-spool.avc | grep -E 'myapp|spool|var_spool' | tail -20
sudo chmod a+r /tmp/prod-feature-spool.avc
```

**You should see:** HTTP **500** and an AVC for `myapp_t` writing under `/var/spool/myapp`.

### 7b. Admin restore (app up; policy not fixed)

**On the Mac.** Host stays Enforcing. Only the app domain goes permissive. That is [emergency_rollback.yml](../../ansible/emergency_rollback.yml) / [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml
```

**On the prod VM** (`bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore`):

```bash
getenforce
systemctl is-active myapp.service myapp-backend.service
curl -sf -o /dev/null http://127.0.0.1:8888/ && echo 'HTTP 200 /'
curl -sf http://127.0.0.1:8888/feature-spool
```

**You should see:** `Enforcing`, units active, HTTP **200** on `/` and `/feature-spool`. Customers are not down. Policy is still the first module. Rollback also writes `/tmp/emergency_avc.log`.

### 7c. Generate the fix on rhel-dev

**On the Mac**, copy the fail log (or soak last-fail / emergency log) to rhel-dev:

```bash
scp ansible@192.168.64.5:/tmp/prod-feature-spool.avc /tmp/prod-feature-spool.avc
ssh ansible@192.168.64.6 'mkdir -p ~/selinux-pac/policy_out'
scp /tmp/prod-feature-spool.avc ansible@192.168.64.6:~/selinux-pac/policy_out/avc.log
```

**On the dev VM:**

```bash
cd ~/selinux-pac
sudo bash scripts/dev_generate_policy.sh --skip-export --apply
bash scripts/compile_and_validate.sh selinux
```

**On the Mac:** repeat Part 4 (`scp` + `bash scripts/demo_open_generated_pr.sh`), then Part 5 (canary + enforce on dev).

### 7d. Recanary prod and retest under the new module

Rebuild RPMs, `rpm -Uvh --force` on prod, canary again. This time `soak_monitor.yml` should **pass** (the new module already allows the spool write). Then the same talk-only enforce.

**On the prod VM** (`bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part retest`):

```bash
curl -sf http://127.0.0.1:8888/feature-spool
```

**You should see:** HTTP **200** under the new module (enforcing).

That is the product loop: **clean soak → enforce → outage → admin restore → generate on rhel-dev → PR (CI best-practices) → RPM → recanary**, not `semodule -i` on the box.

---

## Cheat sheet — the three lines `doctor` prints

```text
Enforcing          SELinux is on for the whole VM (good)
/sbin/ausearch     tool that reads “permission denied” from the log
/bin/sesearch      tool that asks “is this already allowed in the live rules?”
```
