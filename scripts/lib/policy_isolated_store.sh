#!/usr/bin/env bash
#
# policy_isolated_store.sh — Prepare semodule -p prefix with a copy of targeted store.
#
isolated_store_create() {
    local prefix
    prefix="$(mktemp -d)"
    mkdir -p "${prefix}/var/lib/selinux"
    cp -a /var/lib/selinux/targeted "${prefix}/var/lib/selinux/"
    printf '%s\n' "${prefix}"
}

isolated_store_kern() {
    local prefix="$1"
    printf '%s/var/lib/selinux/targeted/active/policy.kern\n' "${prefix}"
}

isolated_store_destroy() {
    local prefix="$1"
    rm -rf "${prefix}"
}
