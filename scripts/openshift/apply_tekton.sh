#!/usr/bin/env bash
# Apply Tekton tasks and pipelines to OpenShift Pipelines (namespaced).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${TEKTON_NAMESPACE:-selinux-pac}"

if ! command -v oc >/dev/null 2>&1; then
    echo "oc CLI required" >&2
    exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
    echo "Not logged in — run: oc login" >&2
    exit 1
fi

if ! oc get namespace openshift-pipelines >/dev/null 2>&1; then
    echo "WARN: openshift-pipelines namespace not found — is OpenShift Pipelines installed?" >&2
fi

oc get namespace "${NS}" >/dev/null 2>&1 || oc create namespace "${NS}"

oc apply -f "${ROOT}/tekton/tasks/" -n "${NS}"
oc apply -f "${ROOT}/tekton/pipelines/" -n "${NS}"

echo "Tekton resources applied in namespace ${NS}"
echo "List: oc get tasks,pipelines -n ${NS}"
echo "Run PR pipeline: oc create -f ${ROOT}/tekton/pipelinerun/example-myapp.yaml -n ${NS}"
