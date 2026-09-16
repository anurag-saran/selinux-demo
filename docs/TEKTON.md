# Tekton pipelines (OpenShift Pipelines)

Tekton builds and validates policy artifacts. **Deploy** still runs via Ansible/AWX on SELinux hosts.

## Parameters (per app)

| Param | Example |
|-------|---------|
| `app-name` | `payments` |
| `manifest-path` | `config/payments.manifest.example.yml` |
| `policy-dir` | `selinux/payments` |

Same contract as [`config/README.md`](../config/README.md).

## Resources

Under [`tekton/`](../tekton/):

- `tasks/` — validate manifest, static checks, compile, optional AWX trigger
- `pipelines/selinux-pac-pr.yaml` — PR validation chain
- `pipelines/selinux-pac-release.yaml` — compile + RPM build
- `pipelinerun/example-*.yaml` — myapp and payments samples

## OpenShift install

```bash
oc login <api-url> --token=<token>   # or oc login from console
export TEKTON_NAMESPACE=selinux-pac  # optional
bash scripts/openshift/apply_tekton.sh
```

Requires **OpenShift Pipelines** operator. PipelineRuns need a git source (clone task or CI trigger) before `example-myapp.yaml` will pass.

## Deploy

Do not run `semodule` on generic cluster workers. Use `tasks/trigger-ansible-deploy.yaml` (AWX webhook) or install RPMs manually and run `ansible-playbook`.

## Image

Use the same compile image as CI: `SELINUX_BUILD_IMAGE` / [`packaging/Containerfile.selinux-build`](../packaging/Containerfile.selinux-build). Mirror in your registry for production.
