# SELinux PaC — three-app customer talk

**LAST_VERIFIED:** 2026-09-17 — authored on macOS. **Not yet run on RHEL hardware.** Re-verify on RHEL 9.x (or CentOS Stream 9) with JWS 6 + `jws6-tomcat-selinux`, or the distro Tomcat fallback + JDK 17, and update this line.

Present **nothing to do → tune it → build it**. Demo apps are **Tomcat App A**, **Tomcat App B**, and **Spring Boot shopapi**. Flask `app/` is **not** in the talk; it remains the offline `make check` fixture.

**Follow also:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) for the two-host shopapi generate/canary/soak acts (technical profile).

## The three situations

Red Hat customers mostly run JWS (Tomcat), EAP, Python, Node, and Spring Boot. Only some of those have vendor policy. The talk uses three apps so people can place their own estate:

| App | What it is | What we do |
|-----|------------|------------|
| **App A** | Tomcat, **greenfield**, standard paths, port **8080** | Already deployed, confined, **enforcing**. Evidence, not a live step. |
| **App B** | Tomcat, **inherited**: `/opt/appdata`, port **8090**, outbound gateway | Real denials. One-line `semanage` / `setsebool`. **Zero `.te`.** |
| **shopapi** | Spring Boot JVM under systemd | **No vendor module.** Only this one hits the generator. |

App A is a standard deploy. App B is the one you inherited — something else had 8080, content landed in `/opt/appdata`, it talks to a payment gateway. That is what most estates look like.

**Same Tomcat domain:** App A and App B run as `jws6_tomcat_t` or `tomcat_t`. SELinux is **not** isolating them from each other. If you need that isolation, use separate instances or containers.

**JWS vs Tomcat:** JWS needs a Red Hat subscription and the JWS repo. If bootstrap cannot see that repo, it installs **upstream Tomcat** from the distro and confines it with **`tomcat_t`**, not `jws6_tomcat_t`. The narrative is identical. Bootstrap prints which variant it chose.

## Commands

```bash
# Understand the flow (Mac, CI, any laptop — no SELinux, no podman, no JVM)
bash scripts/demo_present.sh --dry-run --profile customer

# Night before: is App A still confined?
bash scripts/demo_present.sh --preflight

# From-scratch VM (root, RHEL)
make demo-bootstrap
# then:
bash scripts/demo_present.sh --preflight
bash scripts/demo_present.sh --profile customer
```

| Flag | Meaning |
|------|---------|
| `--profile customer` | Acts 0–3 (~20 min): triage, App A, App B, generate shopapi |
| `--profile technical` | Customer path plus PR + two-host shopapi pipeline |
| `--acts 0,1,2` | Manual act list |
| `--preflight` | Pass/fail table; names `make demo-bootstrap` if App A is missing/unconfined |
| `--dry-run` | Narration + commands + expected output; **executes nothing** |
| `--open-pr` | Preflight requires `gh auth` |

Two-host generate/canary/soak (`demo_e2e_mac.sh` / `_rhel_qa.sh` / `_rhel_prod.sh`) is **shopapi**, not Flask (technical Act 5).

## Acts

| Act | Time | What you show |
|-----|------|----------------|
| **0 Triage** | ~2 min | Vendor-policy check: which apps are covered, which are unconfined. Names **shopapi** as the generate target. Runs **before** staging. |
| **1 App A** | ~1 min | `getenforce`, process domain, successful `/standard/`, then `/standard/forbidden.jsp` + `ausearch`. No changes. |
| **2 App B** | ~5 min | Trigger label / port / boolean denials. `ausearch \| audit2why`. One-line fixes. No `.te`. |
| **3 shopapi** | rest of customer path | `SELinuxContext=shopapi_t`, types-only seed, generate from **observed** AVCs. First-ship: `/health` `/state` `/log`. |
| **4–5** | technical | PR on `selinux/shopapi/`; canary, soak, `/feature-spool` outage, rollback via `demo_e2e_*.sh`. |

## Presenter framing

- Decline the generator twice (A covered, B tuned) before it appears. That restraint is the point.
- Act 1 without the forbidden curl is just an assertion. Always show the denial. The file is world-readable on purpose so DAC cannot hide the AVC.
- Act 2: if a probe produces **no** AVC, say so — do not invent a fix.
- shopapi policy: **no JVM cookbook**. If `execmem` is in the AVC log, generate uses `--allow-needs-review` so CODEOWNERS see it. If it is not in the log, do not add it.
- `SELinuxContext=` plus a private JRE launcher at `/opt/shopapi/bin/java` (labeled `shopapi_exec_t`). `/usr/bin/java` is shared `bin_t` and `203/EXEC` under enforcing `shopapi_t`.
- Do not curl `/feature-spool` until after the first module is enforcing on prod.

## Self-service

| Who | Path |
|-----|------|
| Us (maintained host) | App A persists. `--preflight` the night before. Act 1 is evidence. |
| Colleague on a throwaway VM | `make demo-bootstrap` (idempotent; resume after Ctrl-C). |
| Customer after the meeting | Same bootstrap + `--dry-run` on a laptop first. |
| Laptop, no RHEL | `--dry-run` only. `make check` still uses Flask as a **test** fixture. |

`payments/` remains a **CI multi-module fixture**, not a talk app.

## What is not in this talk

- Flask `app/` — offline `make check` and optional training labs only. Do not install it on the VMs.
- Overlaying `selinux/stub/`.
- Generating a `.te` for Tomcat App A or App B.
- `semodule -i` (or `audit2allow`) on prod.

**Ship path after generate:** [RHEL_TWO_HOST.md](../admin/RHEL_TWO_HOST.md) → [ANSIBLE_OPERATIONS.md](../admin/ANSIBLE_OPERATIONS.md) → [DENIAL_RESPONSE.md](../admin/DENIAL_RESPONSE.md).
