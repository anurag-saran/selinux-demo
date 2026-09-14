# Deterministic generator fixtures

Run classification without RHEL / sepolgen:

```bash
python3 cli/deterministic_gen.py --explain \
  --avc-log docs/examples/fixtures/deterministic/01-mislabeled-var-lib/avc.log \
  --manifest config/myapp.manifest.yml \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc
```

CI smoke tests compare `findings.json` verdicts to `expected.json` in each directory.

On RHEL dev hosts, run once: **`sepolgen-ifgen`** (requires `policycoreutils-devel`) so interface matching works.
