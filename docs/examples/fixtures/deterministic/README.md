# Deterministic generator fixtures

Each directory has `avc.log` + `expected.json` (verdict/tgt golden rows). CI runs them via `scripts/smoke_test.py` → `deterministic_fixture_classify`.

| Case | Verdict exercised |
|------|-------------------|
| `01-mislabeled-var-lib` | **`fc_drift`** — path already covered by `/var/lib/myapp(/.*)?` in `.fc`; fix is `restorecon`, not a new line |
| `02-port-bind` | **`private_port`** — `name_bind` on generic port type |
| `03-shadow-read` | **`forbidden`** — refuses `shadow_t` (exit 1) |
| `04-private-getopt` | **`direct`** — allow on module-private `myapp_port_t` |
| `05-baseline-covered` | Documents **`baseline`** — use smoke test `deterministic_baseline_verdict` (AVC fully covered → no net-new row) |
| `07-toolchain-required` | **`toolchain_required`** — base-type allow blocked without sepolgen (exit 1) |

**`interface`** verdict is covered by smoke test `deterministic_interface_verdict` (mocked sepolgen match).

Run classification without writing policy:

```bash
python3 cli/deterministic_gen.py --explain \
  --avc-log docs/examples/fixtures/deterministic/01-mislabeled-var-lib/avc.log \
  --manifest config/myapp.manifest.yml \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc
```

On RHEL dev hosts, run once: **`sepolgen-ifgen`** (requires `policycoreutils-devel`) so live interface matching works. Without it, use **`--allow-degraded`** only when you accept audited raw allows (`engine=degraded` in `findings.json`).

**Fast compiles:** build the pre-baked image once — `bash scripts/build_selinux_compile_image.sh` — then set `SELINUX_BUILD_IMAGE=selinux-demo/selinux-build:stream9`.
