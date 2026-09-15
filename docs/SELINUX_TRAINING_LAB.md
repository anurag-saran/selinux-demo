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

**Time:** about **90–120 minutes** on a prepared VM (add time for Podman setup on macOS).

**You need:** SELinux-enabled Linux (or Podman VM), `sudo`, this repo cloned, optional internet for Lab 6.

**Convention:** Example output shows the **shape** of answers — your PIDs and timestamps will differ.

### Two paths

| Path | Order |
|------|--------|
| **Full course (first time)** | Lab **1 → 6 → 2 → 3 → 4 → 5 → 7 → 8 → 9** (Lab 10 optional) |
| **Demo prep (short)** | Lab **1 → 6 → 7 → Finish** |

Lab 6 installs the demo app. Labs 2–5 need those files and services — do **Lab 6 right after Lab 1** on the full path.

### Words you'll reuse

| Term | Plain English |
|------|----------------|
| **Type / domain** | Short name in a label (`myapp_t`, `myapp_log_t`) — policy rules use these |
| **Label / context** | Full tag on a file or process; focus on the **type** (third field) |
| **AVC** | Audit line: “SELinux blocked (or would block) this access” |
| **Permissive domain** | That process type keeps running; denials are **logged** for policy authors |

---

## Running on macOS

macOS has **no SELinux**. Run all lab commands **inside the Podman Machine Linux VM**, not in Mac Terminal.

**Why Podman?** The demo needs a real RHEL-like kernel with SELinux, audit, and `semanage` — the VM provides that without a separate cloud server.

```bash
bash scripts/fix_podman.sh
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
bash scripts/run_on_podman_vm.sh sync    # copy repo into VM
bash scripts/run_on_podman_vm.sh setup   # same as Lab 6, inside VM
bash scripts/run_on_podman_vm.sh shell   # interactive VM shell for labs
```

Inside the VM: `cd /home/core/selinux-demo` and continue with Lab 1.  
Curl **`127.0.0.1:8888` inside the VM** — the app does not listen on your Mac.  
Details: [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md).

---

## Course map

| Lab | Why it matters | Commands |
|-----|----------------|----------|
| [1](#lab-1--is-selinux-on) | Nothing else works if SELinux is off | `getenforce`, `sestatus` |
| [6](#lab-6--install-demo-staging) | Gives you a real app + policy to learn on | `setup_staging_env.sh` |
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

**Why we do this:** Reading labels on `/etc/passwd` teaches syntax, but the **demo and workshop** use the Flask app under `/opt/myapp`, its policy module, systemd units, and permissive `myapp_t`. Lab 6 builds that world in one step.

**Question you're answering:** *Is the demo app running with the same SELinux setup the workshop expects?*

**When:** Run this **right after Lab 1** on the full course path.

### Command: one-shot staging install

```bash
cd /path/to/selinux-demo
sudo bash scripts/setup_staging_env.sh
```

| What it does (high level) | Installs policy (`.pp`), labels paths, starts `myapp` + backend services, adds `myapp_t` to the permissive list, enables audit-friendly settings |
| Why `sudo` | Installing policy and changing SELinux state requires root |
| Success signal | Script exits **0** with no error at the end |

### Commands: verify the install

```bash
systemctl is-active myapp.service myapp-backend.service
```

| What it does | Checks both systemd units are running (app + backend for Tier 6 URLs) |
| Good output | Two lines both saying `active` |

```bash
curl -s http://127.0.0.1:8888/ | head -c 200
echo
```

| What it does | Hits the health endpoint — proves the app listens on port 8888 |
| Good output | JSON containing `"status":"ok"` |

```bash
getenforce
sudo semanage permissive -l
```

| What it does | Confirms **host still Enforcing** but **`myapp_t` is log-only** (staging model) |
| Good output | `Enforcing` and a list containing `myapp_t` |

**Example combined output:**

```text
active
active
{"status":"ok","selinux":{...}}
Enforcing
myapp_t
```

**Checkpoint:** Services are active; host is Enforcing; `myapp_t` is permissive. You are ready for label and curl labs.

**If it fails:** Port 8888 in use, missing packages, or audit — see [TESTING.md](TESTING.md).

---

## Lab 2 — Read file labels

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
| What to look at | Third field: `myapp_exec_t`, `myapp_var_lib_t`, `myapp_log_t` — **different types for different roles** (program vs data vs log) |

**Example output:**

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
| What to notice | Flask → **`myapp_t`**; backend stub → **`myapp_backend_t`** (second domain for network labs) |

**Example output:**

```text
system_u:system_r:myapp_t:s0    ... python3 /opt/myapp/app.py
system_u:system_r:myapp_backend_t:s0    ... backend_stub.py
```

**Checkpoint:** You can explain that **`myapp_t` on the process** is not the same as **`myapp_log_t` on the log file** — rules connect the two explicitly in `.te`.

**Learn:** [SELINUX_BASICS.md §4](SELINUX_BASICS.md).

---

## Lab 4 — Policy on disk vs reality

**Why we do this:** Policy can be correct in Git but files on disk still have **old labels** (restore missed, manual copy, wrong `chcon`). The app then gets denials even though `.te` “looks fine.”

**Question you're answering:** *Does the label on disk match what policy expects for this path?*

**When:** After **Lab 6**.

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
| Why `var_log_t` | Generic log type — policy for **myapp** expects **`myapp_log_t`**, so writes may be denied or logged |

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
| `/probe-backend`, `/notify-socket` | Network / Unix socket to **`myapp_backend_t`** |

**Checkpoint:** All six succeed (no `curl` errors). That is what `wait_for_endpoints.sh` and deploy reports expect in production.

---

## Lab 8 — Find and read an AVC

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
- [ ] Lab 6 services are **active**; **`myapp_t`** is permissive; host is **Enforcing**.
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
| Empty `ausearch` | auditd off or no denials yet | `systemctl start auditd`; Lab 7 |
| `curl` fails | App not running | `systemctl restart myapp.service` |
| Wrong file types | Disk ≠ policy | `sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp` |
| On Mac only | No SELinux on host | [Running on macOS](#running-on-macos) — VM shell |

---

## Document map

| Guide | Use when |
|-------|----------|
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | Concept reference |
| **This file** | Guided labs with **why** + **what each command does** |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Live workshop |
| [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) | Repository tour |
