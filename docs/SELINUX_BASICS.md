# SELinux Basics — A Beginner's Guide

This guide explains **SELinux from zero** using examples from this repository's `myapp` demo. No prior MAC (Mandatory Access Control) experience required.

**Next steps after reading:**
- Run the workshop: [DEMO_GUIDE.md](DEMO_GUIDE.md)
- Deploy safely in production: [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md)

---

## What is SELinux?

**SELinux** (Security-Enhanced Linux) is a Linux kernel security module that adds **mandatory access control** on top of normal Unix permissions (owner/group/mode).

| Unix permissions | SELinux |
|------------------|---------|
| "Can user `myapp` read this file?" | "Can process running as **`myapp_t`** read a file labeled **`myapp_var_lib_t`**?" |
| User decides (within bounds) | **Policy** decides — admins define allowed interactions |
| `chmod`, `chown` | Policy modules (`.te`), file contexts (`.fc`), `restorecon` |

**Why it exists:** even if an app is compromised, SELinux limits what that process can touch (which files, ports, other processes) according to policy — not just whoever owns the file.

On RHEL, Fedora, and CentOS Stream, SELinux is **on by default**.

---

## The mental model in one sentence

Every process and file has a **label** (context). Policy contains **allow rules** that say which **source type** may do what to which **target type** for a given **object class**.

If no rule allows the operation → **denied** (in Enforcing mode).

---

## Contexts — how labels look

A SELinux context has four parts:

```text
user:role:type:level
system_u:system_r:myapp_t:s0
│        │        │       └── sensitivity/category (MLS/MCS; often s0)
│        │        └── type (the part you work with most)
│        └── role
└── SELinux user
```

For this PoC, focus on **type** — especially **`myapp_t`** (the app process domain).

### View labels on disk

```bash
ls -Z /opt/myapp/app.py
# system_u:object_r:myapp_exec_t:s0

ls -Z /var/myapp/
# files should be myapp_var_lib_t after policy + restorecon
```

### View labels on processes

```bash
ps -eZ | grep myapp
# system_u:system_r:myapp_t:s0  ... python ... app.py
```

If the process type and file type don't match what policy allows, you get an **AVC denial**.

---

## Core vocabulary

| Term | Plain English | In this repo |
|------|---------------|--------------|
| **Domain** | SELinux type of a *running process* | `myapp_t` — the Flask app |
| **Type** | Label on objects or processes | `myapp_exec_t`, `myapp_var_lib_t`, … |
| **Object class** | Kind of kernel object | `file`, `dir`, `tcp_socket`, `process` |
| **Allow rule** | Permission grant in policy | `allow myapp_t myapp_var_lib_t:file write;` |
| **Transition** | Process starts with a new type | systemd → `init_t` → **`myapp_t`** via `init_daemon_domain` |
| **File context** | Default label for a path | Defined in `selinux/myapp.fc` |
| **Module** | Packaged policy unit | `myapp.pp` (compiled from `.te` + `.fc`) |
| **AVC** | Logged access denial | Lines in `/var/log/audit/audit.log` |

**Domain vs type:** in conversation people say "domain" for process types like `myapp_t`. Technically it's still a *type* — domain is the role it plays.

---

## Enforcing vs Permissive

Check system mode:

```bash
getenforce
# Enforcing | Permissive | Disabled
```

| Mode | Behavior |
|------|----------|
| **Enforcing** | Denials are **blocked** and logged |
| **Permissive** | Denials are **logged only** — operation still succeeds |
| **Disabled** | SELinux off (avoid in production) |

### Per-domain permissive (what this repo uses)

You can keep the **OS enforcing** but mark **one domain** permissive:

```bash
sudo semanage permissive -a myapp_t   # canary / soak
sudo semanage permissive -l           # list permissive domains
sudo semanage permissive -d myapp_t   # enforce after soak
```

This is the RHEL-recommended rollout: collect AVCs without an outage, then enforce when policy is complete.

---

## What is an AVC denial?

**AVC** = Access Vector Cache. When SELinux denies (or would deny) an action, the kernel logs a line like:

```text
type=AVC msg=audit(1234567890.123:456): avc: denied { write } for pid=1234 comm="python3"
  scontext=system_u:system_r:myapp_t:s0
  tcontext=system_u:object_r:myapp_var_lib_t:s0
  tclass=file permissive=1
```

How to read it:

| Field | Meaning |
|-------|---------|
| `denied { write }` | Operation blocked (or logged in permissive) |
| `scontext` | **Source** — who tried (process type `myapp_t`) |
| `tcontext` | **Target** — what was accessed (file type `myapp_var_lib_t`) |
| `tclass=file` | Object class |
| `permissive=1` | Domain was permissive — request succeeded but was logged |

Search recent denials:

```bash
sudo ausearch -m avc -ts recent
sudo ausearch -m avc -ts recent | grep myapp_t
```

This repository **exports** those lines to `policy_out/avc.log` and feeds them to the AI policy CLI — instead of blindly running `audit2allow`.

---

## Policy files in this project

```text
selinux/
├── myapp.te          # Type Enforcement — rules (allow, types, transitions)
├── myapp.fc          # File Contexts — path → default label mappings
├── policy_version.txt
└── stub/             # Minimal permissive module for early staging
```

Compiled output (not committed):

```text
policy_out/myapp.pp   # Binary module installed with semodule -i
```

### Type Enforcement (`.te`) — rules

Example from [`selinux/myapp.te`](../selinux/myapp.te):

```text
type myapp_t;                    # process domain
type myapp_var_lib_t;           # data files under /var/myapp

allow myapp_t myapp_var_lib_t:file { create write append ... };
allow myapp_t unreserved_port_t:tcp_socket name_bind;   # port 8888
init_daemon_domain(myapp_t, myapp_exec_t);              # systemd start transition
```

- **`allow SOURCE TARGET:CLASS { permissions }`** — the basic building block
- **`init_daemon_domain`** — standard pattern for systemd-managed daemons
- **`require { type ... }`** — types defined in the base policy that you reference but don't declare

### File Contexts (`.fc`) — path labels

Example from [`selinux/myapp.fc`](../selinux/myapp.fc):

```text
/opt/myapp/app\.py    -- gen_context(system_u:object_r:myapp_exec_t,s0)
/var/myapp(/.*)?      -- gen_context(system_u:object_r:myapp_var_lib_t,s0)
```

After installing policy, existing files need relabeling:

```bash
sudo restorecon -Rv /var/myapp /opt/myapp
matchpathcon /opt/myapp/app.py    # what label policy expects
```

Wrong labels are a top cause of "app worked in staging, broke in prod."

---

## How a process gets its type

```text
systemd (init_t)
    → starts /opt/myapp/venv/bin/python /opt/myapp/app.py
    → entrypoint labeled myapp_exec_t
    → transition rule in policy
    → process runs as myapp_t
```

If the transition rule is missing, the service may stay in `init_t` or fail — common when testing only with manual `python app.py` instead of **`systemctl restart myapp`**.

---

## Install and manage policy modules

```bash
# Compile (this repo)
bash scripts/compile_and_validate.sh selinux

# Install / upgrade
sudo semodule -i selinux/myapp.pp

# Remove before upgrade (handled in our scripts)
sudo semodule -r myapp

# List loaded modules
sudo semodule -l | grep myapp
```

---

## Common beginner mistakes

| Mistake | Why it hurts | What this repo does |
|---------|--------------|---------------------|
| Setting entire OS permissive | Removes protection for everything | Only `myapp_t` permissive during soak |
| Using `audit2allow` blindly | Creates over-broad rules (`allow myapp_t *:*`) | AI + **forbidden-pattern CI** + human review |
| Skipping `restorecon` after deploy | Old files keep wrong types | `verify_file_contexts.sh`, Ansible playbooks |
| Testing only manual start | Missing systemd transition AVCs | Playbooks restart via **systemd** |
| Wrong port type for 8888 | `http_port_t` is wrong for 8888 on RHEL | Uses **`unreserved_port_t`** |
| Enforcing immediately | Misses weekly cron / logrotate edge cases | **7–14 day soak** before enforce |

---

## Useful commands (cheat sheet)

```bash
# Status
getenforce
sestatus

# Contexts
ls -Z PATH
ps -eZ | grep PROCESS
matchpathcon PATH

# Relabel
restorecon -Rv PATH
restorecon -Rv -n PATH          # dry-run: show what would change

# Audit / denials
sudo ausearch -m avc -ts recent
sudo tail -f /var/log/audit/audit.log

# Permissive domain
sudo semanage permissive -a myapp_t
sudo semanage permissive -d myapp_t
sudo semanage permissive -l

# Policy modules
sudo semodule -l
sudo semodule -i myapp.pp
sudo semodule -r myapp

# Booleans (not used in this PoC, but common on RHEL)
getsebool -a | grep httpd
sudo setsebool -P httpd_can_network_connect on
```

---

## How this maps to the demo workflow

```text
1. Run app as myapp_t (permissive)     →  AVCs logged, app still works
2. Export AVCs                         →  policy_out/avc.log
3. Generate policy                     →  selinux/myapp.te + .fc updates
4. Review + CI                         →  no wildcards / no shadow_t allows
5. Canary deploy                       →  semodule -i + semanage permissive -a
6. Soak + monitor                      →  check_soak_ready.sh, monitor_avc.sh
7. Enforce                             →  semanage permissive -d myapp_t
8. Outage?                             →  semanage permissive -a (rollback playbook)
```

See [DEMO_GUIDE.md](DEMO_GUIDE.md) for presenter steps and [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) for admin gates.

---

## Types in the myapp module (quick reference)

| Type | Used for |
|------|----------|
| `myapp_t` | Running Flask app process (domain) |
| `myapp_exec_t` | App binary, venv (entrypoint / interpreters) |
| `myapp_var_lib_t` | Data under `/var/myapp` (logs, state) |
| `myapp_script_exec_t` | `backup.sh` and scripts in `bin/` |
| `unreserved_port_t` | Binding TCP port **8888** |

---

## Further reading (external)

- [Red Hat SELinux User's and Administrator's Guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/using_selinux/index)
- `man selinux` — overview on RHEL systems
- `man semodule`, `man restorecon`, `man ausearch` — tool reference

---

## Glossary (one line each)

- **MAC** — Mandatory Access Control; policy enforced by the system, not chosen by the user
- **TE** — Type Enforcement; the allow/rule language in `.te` files
- **FC** — File Contexts; path-to-label mappings in `.fc` files
- **DAC** — Discretionary Access Control; classic Unix rwx permissions
- **MLS/MCS** — Multi-Level / Multi-Category Security; advanced; this PoC stays at `s0`

---

## Document map

| Guide | Audience |
|-------|----------|
| **This file** | New to SELinux — concepts and vocabulary |
| [DEMO_GUIDE.md](DEMO_GUIDE.md) | Running the live workshop demo |
| [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | RHEL admins — soak, canary, enforce gates |
| [README.md](../README.md) | Project overview and command index |
