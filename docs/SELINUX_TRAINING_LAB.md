# SELinux hands-on training lab — prepare for the demo

This is a **practice course**: copy commands, compare your output to the examples, and check each **checkpoint** before moving on.

| Document | Role |
|----------|------|
| **[SELINUX_BASICS.md](SELINUX_BASICS.md)** | Read concepts (labels, `.te`/`.fc`, soak) — **skim sections 1–7 first** |
| **This file** | **Do** the commands on a Linux host with SELinux |
| **[DEMO_GUIDE.md](DEMO_GUIDE.md)** | Full 10-act workshop after you finish the labs |
| **[CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md)** | Where scripts and Python tools live in the repo |

**Time:** about **90–120 minutes** on a prepared VM (add 30 min if you build Podman from scratch on macOS).

**You need:**

- A machine with **SELinux enabled** (RHEL 8/9, Fedora, CentOS Stream 9, or this repo’s **Podman VM** — see [Running on macOS](#running-on-macos) below).
- **Root** (`sudo`) for staging setup, `restorecon`, and `semanage`.
- This repository cloned (e.g. `/home/you/selinux-demo` on Linux, or on your Mac with the repo synced into the Podman VM).
- **Optional:** internet for `setup_staging_env.sh` to install packages.

---

## Running on macOS

**Short answer:** run the labs **inside the Podman Machine Linux VM**, not in Terminal on macOS itself.

| On Mac host | In Podman VM (Linux) |
|-------------|----------------------|
| `getenforce` does not exist / not meaningful | Labs **1–10** work |
| No `/var/log/audit/audit.log` for SELinux | `ausearch`, AVCs, `semanage` work |
| Good for editing repo in Cursor | Good for **`sudo bash scripts/setup_staging_env.sh`** |

### One-time setup (Mac)

From your clone of this repo on the Mac:

```bash
bash scripts/fix_podman.sh
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
bash scripts/run_on_podman_vm.sh sync
bash scripts/run_on_podman_vm.sh setup
```

`setup` syncs the project into the VM and runs **`setup_staging_env.sh`** there (same as Lab 6).

### Run each lab command inside the VM

**Option A — interactive shell (easiest for learning):**

```bash
source "${HOME}/.local/share/selinux-demo/podman/env.sh"
bash scripts/run_on_podman_vm.sh shell
```

You land in a shell on the VM with the project at **`/home/core/selinux-demo`**. Then:

```bash
cd /home/core/selinux-demo
getenforce
sudo semanage permissive -l
# …rest of lab commands…
```

Type `exit` to leave the VM shell.

**Option B — one command from Mac:**

```bash
bash scripts/run_on_podman_vm.sh exec 'getenforce'
bash scripts/run_on_podman_vm.sh exec 'cd /home/core/selinux-demo && ls -Z /opt/myapp/app.py'
```

### macOS vs native Linux checklist

- [ ] Podman Machine running (`podman machine list`)
- [ ] Sourced **`podman/env.sh`** in every Mac terminal session you use for Podman
- [ ] After editing files on the Mac, run **`bash scripts/run_on_podman_vm.sh sync`** before labs that need new scripts
- [ ] Lab **7** curls **`127.0.0.1:8888` inside the VM** (services listen there, not on your Mac localhost)

**Demo prep on Mac:** after labs, you can run the workshop with  
`bash scripts/demo_present.sh --use-vm --demo-mode --auto` ([DEMO_GUIDE.md §6–7](DEMO_GUIDE.md)).

**Easier alternative:** use any **cloud or local Linux VM** (RHEL/Fedora/Stream) with SSH and skip Podman — run the lab natively on that host.

Podman troubleshooting: [DOCKER_HUB_COMPILE_IMAGE.md](DOCKER_HUB_COMPILE_IMAGE.md) (macOS section).

---

**Convention:** lines starting with `$` are commands you run. Blocks below them are **example output** — your PIDs, timestamps, and audit IDs will differ; match the **shapes** (types, words, exit codes).

**Do you need Linux experience?** Basic shell only: `cd`, `sudo`, copy-paste. No prior SELinux knowledge if you skim [SELINUX_BASICS.md §1–4](SELINUX_BASICS.md) (~10 minutes) first.

### Two ways through the course

| Path | Who | Order |
|------|-----|--------|
| **Full course** | First time with SELinux | Labs **1 → 6 → 2 → 3 → 4 → 5 → 7 → 8 → 9** (Lab 10 optional) |
| **Demo prep (short)** | Already read basics | Labs **1 → 6 → 7 → Finish** checklist, then [DEMO_GUIDE.md](DEMO_GUIDE.md) |

Labs **2–5** need the demo app installed (**Lab 6**). The course map lists topics in concept order; **run Lab 6 right after Lab 1** unless you only practice on `/etc/passwd` in Lab 2.

### Tiny glossary (used in every lab)

| Word | Remember as |
|------|-------------|
| **Type / domain** | The short name in the **middle** of a label (`myapp_t`, `myapp_log_t`) |
| **Label / context** | Full string: `system_u:object_r:myapp_t:s0` — beginners focus on **`myapp_t`** |
| **AVC** | One audit log line saying “access was denied (or would be)” |
| **Permissive domain** | App keeps running; denials are **logged** for that process type only |

---

## Course map

| Lab | Topic | You will run |
|-----|--------|----------------|
| [1](#lab-1--is-selinux-on) | Is SELinux on? | `getenforce`, `sestatus` |
| [2](#lab-2--read-file-labels) | File labels | `ls -Z`, `matchpathcon` |
| [3](#lab-3--read-process-labels) | Process labels | `ps -eZ` |
| [4](#lab-4--policy-on-disk-vs-reality) | Expected vs actual label | `matchpathcon` vs `ls -Z` |
| [5](#lab-5--two-layer-permissive-demo) | OS Enforcing + app permissive | `semanage permissive` |
| [6](#lab-6--install-demo-staging) | Staging environment | `setup_staging_env.sh` |
| [7](#lab-7--hit-http-endpoints) | Integration surface | `curl` six URLs |
| [8](#lab-8--find-and-read-an-avc) | Denial logs | `ausearch`, field decode |
| [9](#lab-9--map-avc-to-te-rule) | Policy source | `grep` in `myapp.te` |
| [10](#lab-10--export-app-avcs-manifest) | Repo export pipeline | manifest `paths-csv`, optional export |
| [Finish](#finish--ready-for-the-demo) | Demo readiness | checklist → `DEMO_GUIDE.md` |

---

## Lab 1 — Is SELinux on?

**Goal:** Confirm SELinux is active before you trust any label commands.

```bash
getenforce
```

**Example output:**

```text
Enforcing
```

```bash
sestatus | head -5
```

**Example output:**

```text
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
Current mode:                   enforcing
Mode from config file:          enforcing
```

**Checkpoint:** `getenforce` prints `Enforcing` or `Permissive` (not `Disabled`). If disabled, this course and demo require a SELinux-capable VM.

**Learn:** [SELINUX_BASICS.md §7](SELINUX_BASICS.md) — whole-system modes.

---

## Lab 2 — Read file labels

**Goal:** See the **type** (third field) on files the demo uses.

**When:** After **Lab 6** (recommended). Before Lab 6, you can still practice on any system file:

```bash
ls -Z /etc/passwd
```

**Example output:**

```text
system_u:object_r:passwd_file_t:s0    /etc/passwd
#                      ^^^^^^^^^^^^^^
#                      file TYPE — what policy rules reference
```

Once staging exists (Lab 6), run:

```bash
ls -Z /opt/myapp/app.py
ls -Z /var/lib/myapp
ls -Z /var/log/myapp/data.log
```

**Example output (after staging + restorecon):**

```text
system_u:object_r:myapp_exec_t:s0       /opt/myapp/app.py
system_u:object_r:myapp_var_lib_t:s0    /var/lib/myapp
system_u:object_r:myapp_log_t:s0        /var/log/myapp/data.log
```

```bash
matchpathcon /var/log/myapp/data.log
```

**Example output:**

```text
/var/log/myapp/data.log    system_u:object_r:myapp_log_t:s0
```

**Checkpoint:** You can point at the **third field** of a context and say whether it is a file type (`myapp_log_t`) or not.

**Learn:** [SELINUX_BASICS.md §3–4](SELINUX_BASICS.md).

---

## Lab 3 — Read process labels

**Goal:** See the **domain** (process type) of the running Flask app.

**When:** After **Lab 6**.

```bash
ps -eZ | grep /opt/myapp/app.py
```

**Example output:**

```text
system_u:system_r:myapp_t:s0    4521 ?  00:00:01 python3 /opt/myapp/app.py
#                  ^^^^^^^
#                  PROCESS domain
```

```bash
ps -eZ | grep backend_stub
```

**Example output:**

```text
system_u:system_r:myapp_backend_t:s0    4522 ?  ... python3 /opt/myapp/backend_stub.py
```

**Checkpoint:** You can explain why `myapp_t` on the process is **not** the same label as `myapp_log_t` on the log file.

**Learn:** [SELINUX_BASICS.md §4](SELINUX_BASICS.md) — `ls -Z` vs `ps -eZ`.

---

## Lab 4 — Policy on disk vs reality

**Goal:** Understand **mislabeled files** and why `restorecon` exists.

**When:** After **Lab 6** (needs `/var/log/myapp/data.log`).

```bash
matchpathcon /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

**If both show `myapp_log_t`:** labels match policy — good.

**Training exercise (optional, on a lab host only):** simulate a wrong label, then fix it.

```bash
sudo chcon -t var_log_t /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

**Example output:**

```text
system_u:object_r:var_log_t:s0    /var/log/myapp/data.log
```

Policy still **expects** `myapp_log_t` (`matchpathcon` unchanged). The app may log denials when it tries to write.

```bash
sudo restorecon -v /var/log/myapp/data.log
ls -Z /var/log/myapp/data.log
```

**Example output:**

```text
Relabeled /var/log/myapp/data.log from system_u:object_r:var_log_t:s0 to system_u:object_r:myapp_log_t:s0
system_u:object_r:myapp_log_t:s0    /var/log/myapp/data.log
```

**Checkpoint:** In one sentence: `.fc` says what label a path **should** have; `restorecon` applies that to disk.

**Learn:** [SELINUX_BASICS.md §6](SELINUX_BASICS.md).

---

## Lab 5 — Two-layer permissive (demo model)

**Goal:** Same state as staging/canary: **host Enforcing**, only **`myapp_t`** log-only.

**When:** After **Lab 6** (`setup_staging_env.sh` usually adds `myapp_t` for you).

```bash
getenforce
sudo semanage permissive -l
```

**After staging (Lab 6), example output:**

```text
Enforcing
myapp_t
```

If `myapp_t` is not listed yet:

```bash
sudo semanage permissive -a myapp_t
sudo semanage permissive -l
```

**Example output:**

```text
myapp_t
```

**Checkpoint:** You can answer: “Does `getenforce` Permissive mean the whole OS is unsafe?” (**No** — we use per-domain permissive; OS stays Enforcing.)

**Learn:** [SELINUX_BASICS.md §7](SELINUX_BASICS.md).

---

## Lab 6 — Install demo staging

**Goal:** Install the Flask app, policy module, systemd units, and permissive `myapp_t`.

From the repo root:

```bash
cd /path/to/selinux-demo
sudo bash scripts/setup_staging_env.sh
```

**What success looks like (abbreviated):**

- Script finishes **exit code 0**.
- `systemctl is-active myapp.service` → `active`
- `systemctl is-active myapp-backend.service` → `active`
- `curl -sf http://127.0.0.1:8888/` returns JSON (health).

Verify:

```bash
systemctl is-active myapp.service myapp-backend.service
curl -s http://127.0.0.1:8888/ | head -c 200
echo
getenforce
sudo semanage permissive -l
```

**Example output:**

```text
active
active
{"status":"ok","selinux":{...}}
Enforcing
myapp_t
```

**If something fails:** read script errors; common fixes are missing `auditd`, firewall, or port 8888 in use. See [TESTING.md](TESTING.md).

**Checkpoint:** Six Lab 2–3 commands work on `/opt/myapp` and running processes.

---

## Lab 7 — Hit HTTP endpoints

**Goal:** Exercise the same URLs the demo and `wait_for_endpoints.sh` use.

```bash
for path in / /save-log /run-script /rotate-log /probe-backend /notify-socket; do
  echo "=== GET $path ==="
  curl -sf "http://127.0.0.1:8888${path}" | head -c 120
  echo
done
```

**Example output (shape):**

```text
=== GET / ===
{"status":"ok",...

=== GET /save-log ===
ok

=== GET /run-script ===
ok
...
```

Each path touches different permissions (logs, script exec, backend TCP, Unix socket). See [DEMO_GUIDE.md §3](DEMO_GUIDE.md) table.

**Checkpoint:** All six return HTTP success (exit code 0 from `curl -sf`).

---

## Lab 8 — Find and read an AVC

**Goal:** Use the audit log and decode one denial line.

**Beginner note:** After a successful staging install, you may see **few or zero** new AVCs — policy already allows the six curls. That is **good**. Use the **illustrative line below** to practice decoding, or run Lab 4’s optional `chcon` step and `curl /save-log` once to generate a real line (then `restorecon` the log file).

```bash
sudo systemctl status auditd --no-pager | head -3
sudo ausearch -m avc -ts recent 2>/dev/null | tail -5
```

**Example raw line (illustrative — yours will differ):**

```text
type=AVC msg=audit(1710000000.123:456789): avc: denied { append write } for pid=4521 comm="python3" name="data.log" dev="..." ino=12345 scontext=system_u:system_r:myapp_t:s0 tcontext=system_u:object_r:myapp_log_t:s0 tclass=file permissive=1
```

**Decode:**

| Piece | Meaning |
|-------|---------|
| `denied { append write }` | Permission(s) missing from policy |
| `scontext=...:myapp_t:s0` | **Source** — your app process |
| `tcontext=...:myapp_log_t:s0` | **Target** — file type |
| `tclass=file` | Object class |
| `permissive=1` | Domain was permissive — operation still ran; line is **evidence** |

Filter to app domain:

```bash
sudo ausearch -m avc -ts recent 2>/dev/null | grep myapp_t | tail -3
```

**Checkpoint:** Given a line, you can name **source type**, **target type**, and **permission**.

**Learn:** [SELINUX_BASICS.md §8](SELINUX_BASICS.md).

---

## Lab 9 — Map AVC to `.te` rule

**Goal:** Connect a denial to human-readable policy in Git.

Example: write to `myapp_log_t` (from `/save-log`):

```bash
grep -n myapp_log_t selinux/myapp.te | head -10
```

**Example output (fragments):**

```text
logging_log_filetrans(myapp_t, myapp_log_t, file)
allow myapp_t myapp_log_t:file { create write append ... };
```

Read one `allow` line as: **`myapp_t` may `write` `file` objects labeled `myapp_log_t`.**

Optional — see file context for the log directory:

```bash
grep myapp_log selinux/myapp.fc
```

**Checkpoint:** You can open `selinux/myapp.te` and find an `allow` that matches a denial you saw in Lab 8 (or explain which rule would fix a missing permission).

**Learn:** [SELINUX_BASICS.md §9](SELINUX_BASICS.md) worked example.

---

## Lab 10 — Export app AVCs (manifest) *(optional — after Labs 1–9)*

**Goal:** Use the same **identity and paths** as CI — not hardcoded `/opt/myapp` guesses. Skip this lab if you only need the live demo; come back before you run `dev_generate_policy.sh`.

```bash
python3 scripts/lib/app_manifest.py validate config/myapp.manifest.yml
python3 scripts/lib/app_manifest.py paths-csv config/myapp.manifest.yml
```

**Example output:**

```text
OK config/myapp.manifest.yml
/opt/myapp,/var/lib/myapp,/var/log/myapp,/run/myapp,/var/opt/myapp
```

Optional — export filtered AVCs (requires audit data since boot):

```bash
mkdir -p policy_out
source scripts/lib/manifest_shell.sh
source scripts/lib/avc_query.sh
source_app_manifest_exports config/myapp.manifest.yml
export_app_avcs_to_file policy_out/avc.log boot "${PRIMARY_DOMAIN}" "${BACKEND_DOMAIN}" "${PATHS_CSV}"
wc -l policy_out/avc.log
head -2 policy_out/avc.log
```

**Example output:**

```text
42 policy_out/avc.log
type=AVC msg=audit(...): avc: denied { ... } ... scontext=...:myapp_t:s0 ...
```

If `wc -l` shows `0`, trigger Lab 7 again or widen time window; export only includes **manifest paths** and **manifest domains**.

**Checkpoint:** You know `policy_out/avc.log` is **filtered app evidence**, not the full server audit log.

**Learn:** [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) — manifest + `avc_query.sh`.

---

## Finish — ready for the demo?

Check all boxes, then open **[DEMO_GUIDE.md](DEMO_GUIDE.md)**.

- [ ] I can run `getenforce` and `semanage permissive -l` and explain the two-layer model.
- [ ] I can read `ls -Z` and `ps -eZ` and identify the **type** field.
- [ ] I ran staging setup and both systemd units are **active**.
- [ ] I curled all **six** demo endpoints successfully.
- [ ] I found at least one **AVC** and decoded `scontext` / `tcontext` / `denied { }`.
- [ ] I opened **`selinux/myapp.te`** and matched an `allow` to an access pattern.
- [ ] I know **`selinux/`** is reviewed in Git and **`policy_out/`** is local scratch.

**Next steps:**

1. Presenter run: `bash scripts/demo_present.sh --demo-mode` (or `--skip-ai` offline).
2. Developer run: `bash scripts/dev_generate_policy.sh` (see [README.md](../README.md)).
3. Code map: [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md).

---

## Troubleshooting quick reference

| Symptom | Try |
|---------|-----|
| `getenforce` → Disabled | Use RHEL/Fedora/Stream VM or Podman machine with SELinux |
| Empty `ausearch` | `sudo systemctl start auditd`; repeat Lab 7 |
| `curl` connection refused | `sudo systemctl restart myapp.service`; check `journalctl -u myapp` |
| Wrong file types | `sudo restorecon -Rv /opt/myapp /var/lib/myapp /var/log/myapp /run/myapp` |
| macOS host only | [Running on macOS](#running-on-macos): `run_on_podman_vm.sh shell`, labs inside VM |

---

## Document map

| Guide | Use when |
|-------|----------|
| [SELINUX_BASICS.md](SELINUX_BASICS.md) | Concept reference and cheat sheet |
| **This file** | Instructor-led or self-paced **labs** |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Live workshop acts |
| [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md) | Repository tour |
