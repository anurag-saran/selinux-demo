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

**Jump ahead**

- Finished README `write` / `ping` / `doctor` / `bootstrap`? Start at [Part 2](#part-2--install-the-demo-app-on-the-dev-vm).
- Canary already printed `failed=0`? Start at [Part 4](#part-4--turn-permission-denied-into-new-rules).

---

## Present this lab (three terminals)

Open **three** Terminal windows. Each script types the explanation, types the command, then runs it (press Enter between steps). `--dry-run` types and talks only.

| Window | Computer | Start here |
|--------|----------|------------|
| 1 | **Mac** | `cd /Users/asaran/projects/selinux-pac` then `bash scripts/demo_e2e_mac.sh` |
| 2 | **Dev VM** | `ssh ansible@192.168.64.6` then, when the Mac says switch: `bash ~/selinux-pac/scripts/demo_e2e_rhel_dev.sh --part app` (later `--part generate`) |
| 3 | **Prod VM** | `ssh ansible@192.168.64.5` then, when the Mac says switch: `bash ~/e2e-demo/demo_e2e_rhel_prod.sh` |

The Mac script copies the VM talk tracks over SSH. Stay in the window whose prompt matches the table. Do not run `ssh ansible@192.168.64.6` from inside rhel-dev.

`bash scripts/demo_e2e_mac.sh --auto --no-type` skips the Enter pauses and runs the rhel-dev / rhel-prod talk tracks over SSH (recording / unattended).

---

## Words you will see (plain English)

| Word | Meaning |
|------|---------|
| **SSH** | “Log into the other computer from here.” Example: `ssh ansible@192.168.64.6` |
| **SELinux** | Linux’s extra lock on “this program may / may not do that” |
| **Enforcing** | The lock is on for the whole machine (what we want) |
| **AVC** | One line in the log that means SELinux said **no** |
| **Canary** | Install new rules in a **safe** way: the app is allowed to break them, but every break is logged |
| **Enforce** | Take away that safety net. Real blocks start |
| **Soak** | Watch the log for a while before enforce. **7 days on prod.** The lab **dev** box skips the wait |
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

### 1d. Bootstrap (print the next steps — it does not run them)

**What it does:** **Prints** commands. It does **not** install the demo app.

```bash
bash scripts/setup_rhel_hosts.sh bootstrap
```

**You should see:** a block starting `=== Bootstrap the DEV RHEL box`. Do not stop there. Follow **Part 2** below (same steps, with explanations).

One-time on a new Mac, if Ansible collections are missing:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

The SSH user `ansible` needs sudo on the VMs (no password, or Ansible will ask).

---

## Part 2 — Install the demo app on the dev VM

The Mac still has no SELinux. The **demo website** must live on `192.168.64.6`.

If `myapp.service` is already running on the VM and `~/selinux-pac` exists, skip to [Part 3](#part-3--build-the-rules-and-try-them-canary).

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

**What it does:** Installs the tools this lab needs. Short version:

| Package | In human terms |
|---------|----------------|
| `git` | Download this project onto the VM |
| `python3` | Run the demo app and helper scripts |
| `policycoreutils` + `policycoreutils-python-utils` | Load SELinux rules and labels |
| `setools-console` | `sesearch` — “is this already allowed?” |
| `audit` | `ausearch` — read the “permission denied” log |
| `selinux-policy-devel` | Build rules **on Linux** (the Mac cannot compile; copy `myapp.pp` back for Ansible) |

```bash
sudo dnf install -y git python3 policycoreutils policycoreutils-python-utils \
  setools-console audit selinux-policy-devel
```

**You should see:** `Complete!` or “already installed.”

### 2c. Copy the project onto the VM (if it is missing)

**Type this on: the dev VM**

**What it does:** Puts the project at `/home/ansible/selinux-pac` **on the VM**. That is a **second copy**. The Mac still has `/Users/asaran/projects/selinux-pac`. Ansible later looks on the VM, not in `/Users/...`.

Skip if this already works: `ls ~/selinux-pac`

```bash
git clone https://github.com/anurag-saran/selinux-pac.git ~/selinux-pac
```

### 2d. Install the demo app

**Type this on: the dev VM**

```bash
cd ~/selinux-pac
sudo bash scripts/setup_staging_env.sh
```

**What it does:** Installs a tiny website at `/opt/myapp` and starts two services (`myapp` and `myapp-backend`).

Then a health check:

```bash
sudo bash scripts/selinux_pac_adopt.sh doctor
```

**You should see:** `Enforcing`, and both services `active`:

```bash
systemctl is-active myapp.service myapp-backend.service
```

(`active` twice.)

### 2e. Log out of the VM

**Type this on: the dev VM**

```bash
exit
```

**You should see:** `asaran@asaran1-mac` again. The next commands are Mac commands.

---

## Part 3 — Build the rules and try them (canary)

### 3a. Build the SELinux rules file

**Type this on: rhel-dev** (SSH session, repo checkout)

```bash
cd /home/ansible/selinux-pac
bash scripts/compile_and_validate.sh selinux
```

**What it does:** Turns the human-readable rules (`.te` / `.fc`) into a file the VM can load (`selinux/myapp.pp`). Needs `selinux-policy-devel` on this Linux host (a Mac cannot compile SELinux).

**You should see:** `Built selinux/myapp.pp` and `ls selinux/myapp.pp` on rhel-dev.

Then **on the Mac**, copy the package back so Ansible (controller path `policy_pp_src`) can ship it:

```bash
cd /Users/asaran/projects/selinux-pac
scp ansible@192.168.64.6:~/selinux-pac/selinux/myapp.pp selinux/myapp.pp
```

### 3b. Canary (install rules in safe mode)

**Type this on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml
```

**What it does:** From the Mac, Ansible logs into `192.168.64.6`, copies `myapp.pp`, loads it, turns **only the demo app** to “log but don’t block,” hits the website to see if it is up, and starts a timer.

**You should see:** `failed=0` at the bottom. A line like `Recent myapp_t events: 0 raw, 0 net-new`. The `python3.9` warning is still harmless.

If it says the app manifest was not found under `/Users/...`, you are on an old inventory. Re-run Part 1a, or set the paths as in [ansible/README.md](../../ansible/README.md) (they must be `/home/ansible/selinux-pac/...` on the VM).

---

## Part 4 — Turn “permission denied” into new rules

Look at the prompt:

- **`asaran@asaran1-mac`** — you are on the Mac. Log in first:

  ```bash
  ssh ansible@192.168.64.6
  ```

- **`[ansible@rhel-dev`** — you are already on the VM. **Do not SSH.** Go straight to the next box.

Then **on the dev VM** (use `sudo` — the security log is root-only, and `policy_out/` was created as root by the earlier install):

```bash
cd ~/selinux-pac
sudo bash scripts/dev_generate_policy.sh --apply
```

If you already ran it without `sudo` and saw `policy_out/avc.log: Permission denied`, that is the same issue. Re-run with `sudo`.

**What it does:** Reads the “SELinux said no” log (`ausearch`) and proposes new allow rules in the **VM’s** copy of the project. `--apply` copies them into `selinux/` on that VM.

**You should see:** either new allow lines, or “nothing new.” Then log out:

```bash
exit
```

If you want those rule files on the Mac too (to keep them in git), copy `selinux/myapp.te` and `selinux/myapp.fc` from the VM back to `/Users/asaran/projects/selinux-pac/selinux/`.

---

## Part 5 — Lock down the lab (dev VM only)

**Type this on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml \
  -e change_ticket=LAB
```

**What it does:** Checks the log, then turns off the canary safety net on the **dev** VM. Lab settings allow this **immediately**. Production must wait **7 days** — do not copy that “no wait” setting onto the prod VM.

**You should see:** `failed=0`. On the VM, `getenforce` is still `Enforcing` (the whole OS stays locked). Only the demo app’s extra “allowed to break rules” flag is gone.

---

## Part 6 — Same idea on the prod VM (packages, 7-day wait)

**Do not** run `git clone` on `192.168.64.5`. Production gets SELinux helpers from installer files (RPMs), the way a real shop would.

The demo website (`/opt/myapp`) still needs to be running on prod. If it is not, install it the same way you would any app — not by leaving a git checkout for Ansible.

### 6a. Build the installer files

**Type this on: your Mac**

```bash
cd /Users/asaran/projects/selinux-pac
bash packaging/build_rpms.sh
ls dist/*.rpm
```

**What it does:** Builds two RPMs: tools (`selinux-policy-ops`) and the app’s SELinux rules (`myapp-selinux`). A real shop would put these in an internal package server. This lab copies them with `scp`.

**You should see:** `Built RPMs in …/dist/` and two `.rpm` files. If `rpmbuild` is missing on the Mac, build the RPMs on **rhel-dev** (`sudo dnf install -y rpm-build`).

### 6b. Copy them to the prod VM

**Type this on: your Mac**

```bash
scp dist/selinux-policy-ops-*.rpm dist/myapp-selinux-*.rpm ansible@192.168.64.5:~/
```

**What it does:** Copies the two installer files to the prod user’s home directory.

**You should see:** `100%` for each file.

### 6c. Install them on prod

If the prompt already says `[ansible@rhel-prod`, skip `ssh`. If you still see `asaran@asaran1-mac`:

```bash
ssh ansible@192.168.64.5
```

Then **on the prod VM**:

```bash
sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit
sudo dnf localinstall -y ~/selinux-policy-ops-*.rpm ~/myapp-selinux-*.rpm
rpm -q selinux-policy-ops myapp-selinux
exit
```

**What it does:** Installs the log tools, then the two RPMs (scripts under `/usr/libexec/selinux-policy-ops`, rules + a small config file under `/etc/myapp/`).

**You should see:** two package names with versions, then your Mac prompt after `exit`.

### 6d. Canary, watch the log, (do not) enforce yet

**Type every command in this step on: your Mac**

Ansible talks to `192.168.64.5`.

**Canary** — same idea as Part 3, on prod:

```bash
cd /Users/asaran/projects/selinux-pac
ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary
```

**Watch the log** — “did anything new get denied that the installed rules do not already allow?”

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary
```

**Status only** — how many days since canary (prod wants **7**):

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary
```

**Enforce** — will **fail on purpose** until seven days have passed. That is correct. You already locked down the **dev** VM in Part 5.

```bash
ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml \
  -e change_ticket=CHG123
```

In a company, the daily log check and the 7-day wait are usually scheduled in Ansible Automation Platform. Extra reading: [ANSIBLE_OPERATIONS.md](ANSIBLE_OPERATIONS.md), [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md). If something is denied after ship: [DENIAL_RESPONSE.md](DENIAL_RESPONSE.md).

---

## Cheat sheet — the three lines `doctor` prints

```text
Enforcing          SELinux is on for the whole VM (good)
/sbin/ausearch     tool that reads “permission denied” from the log
/bin/sesearch      tool that asks “is this already allowed in the live rules?”
```

---
