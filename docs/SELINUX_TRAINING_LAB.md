# SELinux hands-on training lab — prepare for the demo

This is a **practice course**. Each lab follows the same pattern:

1. **Why** — what problem this step solves in real life  
2. **Question** — what you should be able to answer afterward  
3. **Commands** — what to run, what each command *does*, and what good output looks like  
4. **Checkpoint** — prove you understood before moving on  

| Document | Role |
|----------|------|
| **[SELINUX_BASICS.md](SELINUX_BASICS.md)** | Concepts first — skim **§1–7** (~15 min) |
| **This file** | Hands-on practice on a Linux host with SELinux |
| **[DEMO_GUIDE.md](DEMO_GUIDE.md)** | Full workshop after the labs |
| **[CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md)** | Where repo scripts and tools live |
| **[README.md](README.md)** | Index of all docs and reading order |

**Time:** about **90–120 minutes** on a prepared VM (add time for Podman setup on macOS).

**You need:** SELinux-enabled Linux (or Podman VM), `sudo`, this repo cloned, optional internet for Lab 6.

**Convention:** Example output shows the **shape** of answers — your PIDs and timestamps will differ.

**Repo root** = directory containing `scripts/` and `docs/` (clone path on Mac or Linux; inside the Podman VM it is usually `/home/core/selinux-demo` after `sync`).

### Two learning paths (Linux vs macOS)

Lab **6** installs the demo app and **stub** policy. **Labs 2–5 and 7+ need that install** — paths under `/opt/myapp`, systemd units, permissive **`myapp_t`**.

| Platform | One-time prep | Then do labs in this order |
|----------|---------------|----------------------------|
| **Native Linux** (RHEL, Fedora, Stream VM) | Clone repo; `cd` to repo root | **1 → 6 → 2 → 3 → 4 → 5 → 7 → 8 → 9** (10 optional). Lab **6** includes **`sudo bash scripts/setup_staging_env.sh`**. |
| **macOS** | [Running on macOS](#running-on-macos) steps **1–5** on the Mac (step **4** runs the **same install as Lab 6**, via `run_on_podman_vm.sh setup`) | Open VM shell, `cd` to repo in VM: **1 → [Lab 6 verify only](#verify-the-install) → 2 → 3 → …** Do **not** run `setup_staging_env.sh` again unless you are **reinstalling** staging. |
| **Demo prep (short)** | Same as your platform row above | **1 → Lab 6 (install or verify) → 7 → Finish** |

**Staging stub vs full policy in Git:** Lab 6 installs the **stub** module (`selinux/stub/` — minimal rules, **`myapp_t` permissive**). **`selinux/myapp.te`** is the **full** module ( **`myapp_backend_t`**, **`myapp_log_t`**, ports, etc.). Lab examples often show **full-policy** names; on stub-only staging the Flask app matches, but the **backend process** usually runs as **`myapp_t`**, not **`myapp_backend_t`**, until you install the full `.pp`. See [Lab 3](#lab-3--read-process-labels) and [Troubleshooting](#troubleshooting).

### Words you'll reuse

| Term | Plain English |
|------|----------------|
| **Type / domain** | Short name in a label (`myapp_t`, `myapp_log_t`) — policy rules use these |
| **Label / context** | Full tag on a file or process; focus on the **type** (third field) |
| **AVC** | Audit line: “SELinux blocked (or would block) this access” |
| **Permissive domain** | That process type keeps running; denials are **logged** for policy authors |
| **semanage** | Command on **Linux** that updates SELinux’s **live policy database** (e.g. “make `myapp_t` permissive”, add a port label). Labs 5–6 use it; it is **not** available on macOS itself |

---

## Running on macOS

macOS has **no SELinux** — no `getenforce`, no AVC audit stack, no `semanage`. You still **prepare** the lab from your Mac, but you **run every lab command inside a small Linux VM** that Podman starts for you.

**Why Podman?** The demo needs a real RHEL-like kernel with SELinux turned on, the **audit** subsystem (where AVC lines are written), and **`semanage`**. That tool talks to the kernel’s policy database so you can do things like list or change **per-domain permissive** mode (Lab 5) without turning off enforcement for the whole OS. A Podman Machine VM gives you that Linux environment on a laptop without renting a cloud server.

| Where you type | What runs there |
|----------------|-----------------|
| **Mac Terminal** (zsh), at the **repo root** after `git clone` | Podman install, `source env.sh`, `run_on_podman_vm.sh sync/setup/shell` — these talk to the VM from the host |
| **Inside the VM** (`run_on_podman_vm.sh shell`, prompt looks like Linux) | Lab 1–10: `getenforce`, `sudo semanage …`, `curl 127.0.0.1:8888`, etc. |

**Repo root on Mac** means the folder that contains `scripts/` and `docs/` — for example:

```bash
cd ~/selinux-demo    # your clone path may differ
pwd                  # should end in selinux-demo
```

### One-time setup (Mac Terminal, repo root)

Run these **on the Mac**, in order. Open **Terminal.app** (or iTerm), `cd` to the clone, then:

#### 1. Install or repair Podman and start the Linux VM

```bash
bash scripts/fix_podman.sh
```

| | |
|--|--|
| **Where** | Mac Terminal, current directory = repo root (`…/selinux-demo`) |
| **Why** | Downloads a supported Podman if needed, writes `~/.local/share/selinux-demo/podman/`, creates **`env.sh`**, and runs `podman machine init/start` so a SELinux-capable Linux VM exists |
| **Good sign** | Script ends with “Podman fixed” and `podman machine ls` shows a running machine |

First run can take several minutes (download + VM init).

#### 2. Point this shell at that Podman

```bash
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
```

| | |
|--|--|
| **Where** | Same Mac Terminal session **after** step 1 (repo root not required for the path, but you will run step 3 from repo root) |
| **Why** | Puts the user-local `podman` binary on `PATH` and sets `CONTAINERS_CONF` so `podman machine ssh` works. **New Terminal windows do not inherit this** — run `source …/env.sh` again, or add that line to `~/.zshrc` |
| **Check** | `podman --version` prints 4.x or 5.x; `podman machine ls` shows **Running** |

#### 3. Copy the repo into the VM

```bash
cd ~/selinux-demo   # repo root again if you left it
bash scripts/run_on_podman_vm.sh sync
```

| | |
|--|--|
| **Where** | Mac Terminal, repo root, **after** sourcing `env.sh` |
| **Why** | The VM has its own disk; `sync` tarballs your working tree to `/home/core/selinux-demo` inside the VM so labs see the same files as on your Mac |

#### 4. Install demo staging inside the VM (same as Lab 6 **install** on Linux)

```bash
bash scripts/run_on_podman_vm.sh setup
```

| | |
|--|--|
| **Where** | Mac Terminal, repo root |
| **Why** | Runs `sudo bash scripts/setup_staging_env.sh` **inside** the VM over SSH — never run that script on the Mac host |
| **Good sign** | Ends with “Setup complete” and curl hints |
| **Common follow-up** | **`[WARN] Services did not respond yet`** or **`FATAL: myapp-backend … unknown`** — install may still have finished; open the VM shell and run [Lab 6 verify](#verify-the-install), not a second setup |
| **Do not repeat on macOS** | After step 4, Lab 6 is **verify only** unless reinstalling |

#### 5. Open a VM shell for hands-on labs

```bash
bash scripts/run_on_podman_vm.sh shell
```

| | |
|--|--|
| **Where** | Mac Terminal starts it; your **prompt and commands from here on are inside Linux** |
| **Why** | Interactive SSH session so you run Lab 1’s `getenforce`, Lab 5’s `sudo semanage permissive -l`, etc. in the right OS |

Inside the VM:

```bash
cd /home/core/selinux-demo   # FCOS may show /var/home/core — run pwd if unsure
```

**macOS lab order after steps 1–5:** Lab **1** → Lab **6 (verify only)** → Labs **2–5, 7–9**.

**Checkpoint:** You can say which of the five setup commands run on the Mac vs which run only after `shell`.

**While in the VM:** curl **`http://127.0.0.1:8888`** there — the demo app listens inside the VM, not on your Mac’s localhost.

More Podman/image detail: [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md).

---

## Course map

| Lab | Why it matters | Commands |
|-----|----------------|----------|
| [1](#lab-1--is-selinux-on) | Nothing else works if SELinux is off | `getenforce`, `sestatus` |
| [6](#lab-6--install-demo-staging) | Demo app + stub policy + permissive `myapp_t` | **Linux:** `setup_staging_env.sh` · **macOS:** done in [step 4](#4-install-demo-staging-inside-the-vm-same-as-lab-6-install-on-linux) — **verify** in VM |
| [2](#lab-2--read-file-labels) | Files have types; rules say who may touch them | `ls -Z`, `matchpathcon` |
| [3](#lab-3--read-process-labels) | Processes have domains; different from file types | `ps -eZ` |
| [4](#lab-4--policy-on-disk-vs-reality) | Wrong on-disk labels cause mysterious denials | `restorecon` |
| [5](#lab-5--two-layer-permissive-demo) | How we test safely before enforce | `semanage permissive` |
| [7](#lab-7--hit-http-endpoints) | Generate realistic traffic for audit logs | `curl` |
| [8](#lab-8--find-and-read-an-avc) | Read the evidence policy authors use | `ausearch` |
| [9](#lab-9--map-avc-to-te-rule) | Connect logs to Git policy | `grep` in `.te` / `.fc` |
| [10](#lab-10--export-app-avcs-manifest) | How this repo exports denials for generators | manifest + export |

---

## Lab 1 — Is SELinux on?

**Where:** **Inside the Podman VM** (macOS) or on your **SELinux Linux host** — not in macOS Terminal.

**Why we do this:** Every other command in this course assumes the kernel is enforcing SELinux rules. If SELinux is disabled, `ls -Z` and AVC logs either lie or are empty — you would debug the wrong problem.

**Question you're answering:** *Is this machine actually running SELinux right now?*

### Command: whole-system mode

```bash
getenforce
```

| What it does | Asks the kernel: “Are SELinux decisions enforced globally?” |
| Good answers | `Enforcing` (denials block) or `Permissive` (denials logged, whole OS — rare in prod) |
| Bad for this course | `Disabled` — use a RHEL/Fedora/Stream VM or Podman VM |

**Example output:**

```text
Enforcing
```

### Command: extra detail (optional)

```bash
sestatus | head -5
```

| What it does | Shows SELinux enabled in config, not just today’s runtime |
| Why bother | Confirms SELinux will still be on after reboot |

**Example output:**

```text
SELinux status:                 enabled
Current mode:                   enforcing
```

**Checkpoint:** You can say why Lab 1 must pass before Labs 2–10.

**Learn:** [SELINUX_BASICS.md §7](SELINUX_BASICS.md) — Enforcing vs Permissive vs Disabled.

---

## Lab 6 — Install demo staging

**Why we do this:** The workshop uses the Flask app under `/opt/myapp`, a **stub** SELinux module, systemd units, and permissive **`myapp_t`**. Lab 6 **installs** that staging world (Linux or macOS step 4) and **verifies** it works.

**Question you're answering:** *Is the demo app running with the staging setup the course builds on?*

**When:** **Right after Lab 1** on the full course path.

| Platform | What you do in Lab 6 |
|----------|----------------------|
| **Native Linux** | Run **install** (below), then **verify** |
| **macOS** | **Install** already ran via [`run_on_podman_vm.sh setup`](#4-install-demo-staging-inside-the-vm-same-as-lab-6-install-on-linux). Skip install; run **verify** only inside the VM shell |

### Install (native Linux only — skip on macOS if setup step 4 succeeded)

**Where:** Repo root on a **SELinux Linux host** (SSH or console), not the Mac.

```bash
cd /path/to/selinux-demo
sudo bash scripts/setup_staging_env.sh
```

| What it does (high level) | Installs **stub** policy (`.pp` from `selinux/stub/`), labels paths, starts `myapp` + backend services, adds **`myapp_t`** to the permissive list when `semanage` is available |
| Why `sudo` | Installing policy and changing SELinux state requires root |
| Success signal | Script exits **0**; **`[WARN] Services did not respond yet`** can still appear — use verify below |

**macOS (Mac Terminal, repo root):** `bash scripts/run_on_podman_vm.sh setup` — equivalent install. Do **not** run `sudo setup_staging_env.sh` on the Mac.

### Verify the install

**Where:** On the machine where the app runs — **inside the VM** on macOS.

```bash
systemctl is-active myapp.service myapp-backend.service
```

| What it does | Checks both systemd units (Tier 6 needs the backend) |
| Good output | Two lines both saying `active` |

If the second line is **`inactive`** or **`failed`**, use the two commands below **inside the VM** (not on the Mac).

#### If `myapp-backend.service` is not active

**Why:** Labs 7–8 need a process listening on **8889** and **`/run/myapp/notify.sock`**. That is **`backend_stub.py`**, started by **`myapp-backend.service`**. If the unit crashed at setup time, you see **`unknown`** in the setup log and Tier 6 curls fail until it is fixed.

**Step 1 — read why it failed:**

```bash
sudo journalctl -u myapp-backend.service -n 30 --no-pager
```

| | |
|--|--|
| **Where** | Inside the VM / SELinux Linux host |
| **`journalctl`** | Shows **systemd’s log** for one unit (start errors, Python tracebacks, permission denied) |
| **`-u myapp-backend.service`** | Only lines for the backend unit — not the whole server log |
| **`-n 30`** | Last **30** lines — enough for a recent crash |
| **`--no-pager`** | Print to the terminal (don’t stop in `less`) |
| **What to look for** | `Failed to execute`, `ModuleNotFoundError`, `Address already in use`, SELinux AVC lines |
| **`203/EXEC` + Permission denied on `backend_stub.py`** | Often fixed by using explicit **`/opt/myapp/venv/bin/python`** in the unit (see repo `app/myapp-backend.service`); after pulling the fix: `sudo cp app/myapp-backend.service /etc/systemd/system/`, `sudo systemctl daemon-reload`, restart both services |
| **`can't open file … backend_stub.py` `[Errno 13]`** | **`ProtectSystem=strict`** made `/opt/myapp` read-only; backend unit needs **`ReadWritePaths=/opt/myapp`** (in current repo unit). Quick check: `sudo ls -laZ /opt/myapp/backend_stub.py` and `sudo -u myapp /opt/myapp/venv/bin/python -B /opt/myapp/backend_stub.py` (Ctrl+C if it stays up) |

**Step 2 — try starting again (backend first, then Flask):**

```bash
sudo systemctl restart myapp-backend.service myapp.service
```

| | |
|--|--|
| **Where** | Same VM / host |
| **`systemctl restart`** | Stops and starts the unit(s) — picks up code, venv, and labels after you fix the cause |
| **Order** | **Backend first** — `myapp.service` is configured to want the backend; Flask probes depend on **8889** and the notify socket |
| **Check** | Run `systemctl is-active myapp-backend.service myapp.service` again — both should say **`active`** |

If restart fails immediately, read **`journalctl`** again; fix the reported error (often missing venv/flask or port **8889** in use) before re-running Lab 6 verify.

```bash
curl -s http://127.0.0.1:8888/ | head -c 200
echo
```

| What it does | Health check on port **8888** (inside the VM, not on your Mac) |
| Good output | JSON containing `"status":"ok"` |

```bash
getenforce
sudo semanage permissive -l
```

| What it does | **Host Enforcing** + **`myapp_t`** on the permissive-domain list |
| Good output | `Enforcing` and a list containing `myapp_t` |

**Example combined output:**

```text
active
active
{"status":"ok","selinux":{...}}
Enforcing
myapp_t
```

**Checkpoint:** **`myapp.service`** is active; host is **Enforcing**; **`myapp_t`** is permissive. Fix **`myapp-backend.service`** before Lab 7 if it is not `active`.

**Setup script errors:** **`FATAL: myapp-backend.service running as unknown`** means the backend had no running process when the script checked — usually **not active**. Use [If `myapp-backend.service` is not active](#if-myapp-backendservice-is-not-active) above, not a blind second setup.

**If it fails:** See [TESTING.md](TESTING.md) and [Troubleshooting](#troubleshooting).

---

## Lab 2 — Read file labels

**Where:** Inside the VM / SELinux Linux host (paths are on that machine).

**Why we do this:** SELinux does not ask “can user `myapp` read this file?” It asks “can a process labeled **`myapp_t`** access a **file** labeled **`myapp_log_t`**?” You learn that by reading labels on disk.

**Question you're answering:** *What **type** does policy assign to this path?*

**When:** After **Lab 6** (or practice on `/etc/passwd` before Lab 6).

### Command: read a label on disk

```bash
ls -Z /opt/myapp/app.py
ls -Z /var/lib/myapp
ls -Z /var/log/myapp/data.log
```

| What it does | `ls` lists files; **`-Z`** adds the SELinux context (the label) |
| What to look at | Third field — e.g. **`myapp_exec_t`**, **`myapp_var_lib_t`**. Log file **`myapp_log_t`** appears after **`curl /save-log`** (Lab 7) or when **full** policy from `selinux/myapp.fc` is installed; **stub** staging may show a generic type until then |
| Missing log file | Run `curl -s http://127.0.0.1:8888/save-log` once, then `ls -Z` again |

**Example output (after `/save-log` or with full policy):**

```text
system_u:object_r:myapp_exec_t:s0       /opt/myapp/app.py
system_u:object_r:myapp_var_lib_t:s0    /var/lib/myapp
system_u:object_r:myapp_log_t:s0        /var/log/myapp/data.log
```

### Command: what policy *expects* (not just what is on disk)

```bash
matchpathcon /var/log/myapp/data.log
```

| What it does | Looks up the label **defined in policy** (from `.fc` + loaded module) for this path |
| Why it matters | Compare to `ls -Z` in Lab 4 — if they differ, you need `restorecon` |

**Checkpoint:** You can name the **type** (third field) for the app binary vs the log file.

**Learn:** [SELINUX_BASICS.md §3–4](SELINUX_BASICS.md).

---

## Lab 3 — Read process labels

**Where:** Inside the VM / SELinux Linux host.

**Why we do this:** The running Python process has its **own** label (domain). Policy allows **`myapp_t`** to do things — not “the myapp user” and not the file’s type.

**Question you're answering:** *What domain is the Flask process running in?*

**When:** After **Lab 6**.

### Command: process labels

```bash
ps -eZ | grep /opt/myapp/app.py
ps -eZ | grep backend_stub
```

| What it does | `ps -eZ` lists all processes with SELinux contexts; `grep` finds our demo processes |
| `-Z` vs `-z` | Capital **`-Z`** is SELinux; lowercase `-z` is unrelated — do not mix them up |
| **Podman FCOS VM (macOS lab)** | Services may stay in **`init_t`** instead of **`myapp_t`** — stub policy includes **`init_t`** allows for staging; **`permissive myapp_t`** still applies when transition works |
| **Full policy in Git / workshop enforce path** | Flask → **`myapp_t`**; backend → **`myapp_backend_t`** (second domain for Tier 6) |

**Example output (full policy installed):**

```text
system_u:system_r:myapp_t:s0    ... python3 /opt/myapp/app.py
system_u:system_r:myapp_backend_t:s0    ... backend_stub.py
```

**Stub staging — typical:**

```text
system_u:system_r:myapp_t:s0    ... python3 /opt/myapp/app.py
system_u:system_r:myapp_t:s0    ... backend_stub.py
```

**Checkpoint:** You can explain that **`myapp_t` on the process** is not the same as **`myapp_log_t` on the log file** — rules in **`selinux/myapp.te`** connect them (stub is intentionally minimal).

**Learn:** [SELINUX_BASICS.md §4](SELINUX_BASICS.md).

---

## Lab 4 — Policy on disk vs reality

**Where:** Inside the VM / SELinux Linux host.

**Why we do this:** Policy can be correct in Git but files on disk still have **old labels** (restore missed, manual copy, wrong `chcon`). The app then gets denials even though `.te` “looks fine.”

**Question you're answering:** *Does the label on disk match what policy expects for this path?*

**When:** After **Lab 6**. Ensure **`/var/log/myapp/data.log`** exists (e.g. `curl -s http://127.0.0.1:8888/save-log`).

### Commands: compare expectation vs reality

```bash
matchpathcon /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

| If they match | Good — labeling is consistent |
| If they differ | Disk is **mislabeled**; fix with `restorecon`, not by adding random allows |

### Optional exercise: break it, then fix it (lab host only)

```bash
sudo chcon -t var_log_t /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

| What `chcon` does | **Temporarily** forces a different type — simulates a labeling mistake |
| Why `var_log_t` | Generic log type — **full** policy for **myapp** expects **`myapp_log_t`** on that path |
| Stub note | If **`matchpathcon`** does not show **`myapp_log_t`**, you are still on **stub** policy — the exercise teaches **`restorecon`** mechanics; full log typing is in **`selinux/myapp.fc`** |

```bash
sudo restorecon -v /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

| What `restorecon` does | Re-applies labels from policy (`.fc`) to files on disk — **no `.te` edit** |
| When admins run this | After `semodule -i`, before restart, and in Ansible canary/enforce playbooks |

**Checkpoint:** “`.fc` defines the label; `restorecon` applies it to disk.”

**Learn:** [SELINUX_BASICS.md §6](SELINUX_BASICS.md).

---

## Lab 5 — Two-layer permissive (demo model)

**Where:** Inside the VM / SELinux Linux host.

**Why we do this:** In production you must **not** turn the whole OS permissive (`setenforce 0`). This project keeps the **host Enforcing** and only puts **`myapp_t`** in log-only mode while you collect AVCs and soak.

**Question you're answering:** *Is the host protected while still letting our app run and log denials?*

**When:** After **Lab 6**.

### Commands: two different checks

```bash
getenforce
sudo semanage permissive -l
```

| `getenforce` | Whole-system mode — should stay **`Enforcing`** |
| `semanage permissive -l` | **List** of process types that log denials instead of blocking — should include **`myapp_t`** during staging/soak |
| Not the same thing | Beginners often think Permissive in one command means the entire server is unsafe — here only **`myapp_t`** is special |

If `myapp_t` is missing (unusual after Lab 6):

```bash
sudo semanage permissive -a myapp_t
```

| What `-a` does | **Add** one domain to the log-only list — start of canary/soak style testing |

**Checkpoint:** “SSH and system services stay enforcing; only our app domain is permissive for evidence gathering.”

**Learn:** [SELINUX_BASICS.md §7](SELINUX_BASICS.md).

---

## Lab 7 — Hit HTTP endpoints

**Where:** Inside the VM / SELinux Linux host (`127.0.0.1:8888` is local to that machine).

**Why we do this:** Policy is written for **real behavior** — binding a port, writing logs, executing a script, talking to a backend. Each demo URL triggers a different permission class so AVCs (if any) point at the right rule.

**Question you're answering:** *Does the app work under SELinux, and did we exercise the paths the workshop tests?*

### Command: six integration GETs

```bash
for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
  echo "=== GET $path ==="
  curl -sf "http://127.0.0.1:8888${path}" | head -c 120
  echo
done
```

| What `curl -sf` does | HTTP GET; **`-f`** fails the loop if any URL errors (good gate) |
| Why six paths | Each maps to a different SELinux story (see [DEMO_GUIDE.md §3](DEMO_GUIDE.md)) |
| `/save-log` | File write to log type |
| `/run-script` | Execute labeled script |
| `/probe-backend`, `/notify-socket` | Need **`myapp-backend.service` active**; full policy uses separate **`myapp_backend_t`** — stub may still allow traffic with both processes in **`myapp_t`** |

**Checkpoint:** All six succeed (no `curl` errors). If **`/probe-backend`** or **`/notify-socket`** fail, fix the backend unit (Lab 6 verify) before blaming SELinux policy.

---

## Lab 8 — Find and read an AVC

**Where:** Inside the VM / SELinux Linux host.

**Why we do this:** When policy is incomplete, the kernel logs an **AVC** — that line is the **evidence** app teams use to propose `.te` changes (and what this repo exports before generation).

**Question you're answering:** *Who tried to do what to whom, and was it blocked or only logged?*

**Beginner note:** After Lab 6 + 7, you may see **zero new AVCs** — policy already allows those actions. That is success. Practice decoding with the **example line below**, or run Lab 4’s optional `chcon` + `curl /save-log` to create one real line, then **`restorecon`** the log.

### Command: is the audit daemon running?

```bash
sudo systemctl status auditd --no-pager | head -3
```

| What it does | AVCs are written by **auditd**; if it is stopped, `ausearch` is empty even when SELinux “would” deny |

### Command: fetch recent denial messages

```bash
sudo ausearch -m avc -ts recent 2>/dev/null | tail -5
```

| What it does | **`ausearch`** queries the structured audit log; **`-m avc`** filters to SELinux denial records; **`recent`** ≈ last ~10 minutes |
| Why not `grep /var/log/audit/audit.log` alone | `ausearch` handles rotation and format; scripts in this repo prefer it |

**Example line (illustrative):**

```text
type=AVC ... avc: denied { append write } ... scontext=...:myapp_t:s0 tcontext=...:myapp_log_t:s0 tclass=file permissive=1
```

| Field | Meaning |
|-------|---------|
| `denied { … }` | Missing permission(s) in policy |
| `scontext` … **`myapp_t`** | **Source** — process domain |
| `tcontext` … **`myapp_log_t`** | **Target** — file (or object) type |
| `tclass=file` | Kind of object (file, dir, tcp_socket, …) |
| `permissive=1` | Domain was permissive — app kept running; line is still **evidence** for policy updates |

### Command: focus on our app

```bash
sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp_t | tail -3
```

| What it does | Drops AVCs for other domains (`sshd_t`, `cron_t`, …) so you see **app-relevant** lines |

**Checkpoint:** Read one line aloud: “**myapp_t** tried to **write** a **file** labeled **myapp_log_t**.”

**Learn:** [SELINUX_BASICS.md §8](SELINUX_BASICS.md).

---

## Lab 9 — Map AVC to `.te` rule

**Where:** Repo root **inside the VM** (or Linux host) — you are reading **`selinux/myapp.te`** in git, not the stub module alone.

**Why we do this:** AVCs tell you *what* was denied; **`selinux/myapp.te`** is where admins **allow or refuse** it in Git. Connecting the two is the core skill for policy reviews and for this demo’s generator workflow.

**Question you're answering:** *Which rule (or missing rule) in Git explains this access?*

### Command: find rules involving the log type

```bash
grep -n myapp_log_t selinux/myapp.te | head -10
```

| What it does | Search the **Type Enforcement** file for types and allows related to logs |
| How to read an `allow` line | `allow myapp_t myapp_log_t:file { write … }` → processes in **`myapp_t`** may **`write`** **files** labeled **`myapp_log_t`** |

**Example fragments:**

```text
logging_log_filetrans(myapp_t, myapp_log_t, file)
allow myapp_t myapp_log_t:file { create write append ... };
```

### Command: where the log path gets its label

```bash
grep myapp_log selinux/myapp.fc
```

| What it does | **File contexts** — path patterns → default types applied by `restorecon` |
| `.te` vs `.fc` | **`.fc`** = “what label this path should have”; **`.te`** = “what labeled processes may do” |

**Checkpoint:** Given a write AVC to `myapp_log_t`, you can point at an `allow` or explain what rule would need to be added.

**Learn:** [SELINUX_BASICS.md §9](SELINUX_BASICS.md) — `/save-log` walkthrough.

---

## Lab 10 — Export app AVCs (manifest) *(optional)*

**Where:** Repo root inside the VM / Linux host.

**Why we do this:** The full demo runs `dev_generate_policy.sh`, which exports only **this app’s** denials using paths and domains from **`config/myapp.manifest.yml`** — not every AVC on the server, and not hardcoded guesses.

**Question you're answering:** *How does the repo turn audit logs into `policy_out/avc.log` safely for the right app?*

Skip until you run the generator; optional for demo-only attendees.

### Commands: validate manifest and show path filter

```bash
python3 scripts/lib/app_manifest.py validate config/myapp.manifest.yml
python3 scripts/lib/app_manifest.py paths-csv config/myapp.manifest.yml
```

| `validate` | Checks YAML schema — same check CI runs |
| `paths-csv` | Comma-separated path **substrings** used to filter AVC lines to **this app’s files** |

**Example output:**

```text
OK config/myapp.manifest.yml
/opt/myapp,/var/lib/myapp,/var/log/myapp,/run/myapp,/var/opt/myapp
```

### Optional: run the same export pipeline as scripts

```bash
mkdir -p policy_out
source scripts/lib/manifest_shell.sh
source scripts/lib/avc_query.sh
source_app_manifest_exports config/myapp.manifest.yml
export_app_avcs_to_file policy_out/avc.log boot "${PRIMARY_DOMAIN}" "${BACKEND_DOMAIN}" "${PATHS_CSV}"
wc -l policy_out/avc.log
```

| Step | Purpose |
|------|---------|
| `source_app_manifest_exports` | Loads **`PRIMARY_DOMAIN`**, **`PATHS_CSV`**, etc. from manifest |
| `export_app_avcs_to_file` | **`ausearch`** by domain + filter by paths → **`policy_out/avc.log`** |
| `wc -l` | How many lines matched — **zero** can mean no denials since boot, not necessarily failure |

**Checkpoint:** `policy_out/avc.log` is **filtered evidence for policy work**, not a full-server security report.

**Learn:** [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md).

---

## Finish — ready for the demo?

- [ ] I know **why** we check `getenforce` vs `semanage permissive -l` (two-layer model).
- [ ] I can read **`ls -Z` / `ps -eZ`** and find the **type** field.
- [ ] Lab 6: **`myapp.service`** (and **`myapp-backend.service`** for Tier 6) **active**; **`myapp_t`** permissive; host **Enforcing**.
- [ ] All **six** curls succeeded — I know **what each URL is for**.
- [ ] I can decode **`scontext` / `tcontext` / `denied`** on an AVC line.
- [ ] I can tie an access pattern to **`selinux/myapp.te`** and **`myapp.fc`**.
- [ ] I know **`selinux/`** is reviewed in Git; **`policy_out/`** is local output.

**Next:** [DEMO_GUIDE.md](DEMO_GUIDE.md) → `demo_present.sh --demo-mode` or `dev_generate_policy.sh`.

---

## Troubleshooting

| Symptom | Why it happens | Try |
|---------|----------------|-----|
| `getenforce` → Disabled | No SELinux on this OS | RHEL/Fedora VM or Podman VM |
| `podman machine ls` fails on Mac | Shell not using user-local Podman | `source ~/.local/share/selinux-demo/podman/env.sh` |
| Ran Lab 6 install twice on macOS | Step 4 + `setup_staging_env.sh` in VM | **Verify only** after step 4; reinstall only when intentionally resetting |
| `can't open file … backend_stub.py` Errno 13 | `ProtectSystem=strict` + `/opt/myapp` not in `ReadWritePaths` | Update unit from repo; or drop-in `ReadWritePaths=/opt/myapp /run/myapp` + `PYTHONDONTWRITEBYTECODE=1` |
| `203/EXEC` on `backend_stub.py` | Shebang exec + SELinux/systemd on FCOS | Use current `app/myapp-backend.service` (venv python path); `daemon-reload` + restart |
| `FATAL: myapp-backend … unknown` at setup end | Backend not running when script checked | VM: [Lab 6 — journalctl + restart](#if-myapp-backendservice-is-not-active) |
| `FATAL: … not myapp_backend_t` (stub staging) | **`wait_for_endpoints`** expects full manifest domains; stub uses **`myapp_t`** for both | Ignore if units are **active** and curls work; install full **`selinux/myapp.pp`** for production-like checks |
| Empty `ausearch` | auditd off or no denials yet | `systemctl start auditd`; Lab 7 |
| `curl` fails | App or backend not running | Lab 6 verify; `systemctl restart myapp-backend myapp` |
| Wrong file types | Disk ≠ policy | `sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp` |
| `curl` on Mac to 8888 fails | App listens **inside VM only** | `run_on_podman_vm.sh shell`, then curl **127.0.0.1** there |
| On Mac only | No SELinux on host | [Running on macOS](#running-on-macos) — VM shell for all labs |

---

## Document map

| Guide | Use when |
|-------|----------|
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | Concept reference |
| **This file** | Guided labs with **why** + **what each command does** |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Live workshop |
| [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) | Repository tour |
