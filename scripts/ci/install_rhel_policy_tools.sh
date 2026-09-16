#!/usr/bin/env bash
#
# install_rhel_policy_tools.sh — dnf install compile + sesearch tools (CI Stream 9 / RHEL).
#
set -euo pipefail
dnf -y install \
    selinux-policy-devel \
    checkpolicy \
    policycoreutils \
    setools-console \
    selinux-policy-targeted \
    make \
    python3 \
    python3-pyyaml \
    git \
    jq
