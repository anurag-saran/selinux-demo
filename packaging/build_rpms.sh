#!/usr/bin/env bash
# Build selinux-policy-ops and myapp-selinux RPMs into dist/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
RPMBUILD="${ROOT}/packaging/rpmbuild"

if ! command -v rpmbuild >/dev/null 2>&1; then
    if [[ "$(uname -s)" == Darwin && "${BUILD_RPMS_LOCAL:-0}" != 1 ]]; then
        echo "rpmbuild is not on macOS — compiling and packing on rhel-qa, then copying dist/*.rpm back here." >&2
        exec bash "${ROOT}/scripts/build_rpms_on_dev.sh"
    fi
    echo "Note: rpmbuild not found; validating spec parity only" >&2
    bash "${ROOT}/scripts/validate_rpm_ops_parity.sh"
    exit 0
fi

# shellcheck source=../scripts/lib/version.sh
source "${ROOT}/scripts/lib/version.sh"
VERSION="$(policy_version "${ROOT}/selinux/policy_version.txt")"
# RPM Version comes from policy_version.txt only — do not hardcode in the .spec (rpmbuild cwd breaks fragile %define cat).

mkdir -p "${DIST}" "${RPMBUILD}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
OPS_SRC="${RPMBUILD}/BUILD/selinux-policy-ops-src"
mkdir -p "${OPS_SRC}/lib"
cp "${ROOT}/scripts/verify_file_contexts.sh" \
   "${ROOT}/scripts/wait_for_endpoints.sh" \
   "${ROOT}/scripts/monitor_avc.sh" \
   "${ROOT}/scripts/post_deploy_report.sh" \
   "${ROOT}/scripts/collect_soak_facts.sh" \
   "${ROOT}/scripts/check_soak_ready.sh" "${OPS_SRC}/"
cp "${ROOT}/scripts/lib/avc_query.sh" \
   "${ROOT}/scripts/lib/app_manifest.py" \
   "${ROOT}/scripts/lib/manifest_shell.sh" \
   "${ROOT}/scripts/lib/soak_net_new.py" "${OPS_SRC}/lib/"
mkdir -p "${OPS_SRC}/lib/pac_cli"
cp "${ROOT}/cli/soak_net_new.py" \
   "${ROOT}/cli/avc_preprocess.py" \
   "${ROOT}/cli/selinux_gen.py" "${OPS_SRC}/lib/pac_cli/"

bash "${ROOT}/scripts/validate_rpm_ops_parity.sh"
bash "${ROOT}/scripts/compile_and_validate.sh" selinux

cp "${ROOT}/packaging/selinux-policy-ops.spec" "${RPMBUILD}/SPECS/"
cp "${ROOT}/packaging/myapp-selinux.spec" "${RPMBUILD}/SPECS/"
cp "${ROOT}/selinux/myapp.pp" "${RPMBUILD}/SOURCES/myapp.pp"
cp "${ROOT}/selinux/myapp.te" "${RPMBUILD}/SOURCES/myapp.te"
cp "${ROOT}/selinux/myapp.fc" "${RPMBUILD}/SOURCES/myapp.fc"
cp "${ROOT}/config/myapp.manifest.yml" "${RPMBUILD}/SOURCES/selinux-manifest.yml"

# Ops spec uses relative paths to scripts/ — patch SOURCEDIR via rpmbuild -D
rpmbuild -ba \
  --define "_topdir ${RPMBUILD}" \
  --define "_sourcedir ${RPMBUILD}/SOURCES" \
  "${RPMBUILD}/SPECS/selinux-policy-ops.spec"

rpmbuild -ba \
  --define "_topdir ${RPMBUILD}" \
  --define "_sourcedir ${RPMBUILD}/SOURCES" \
  --define "modver ${VERSION}" \
  "${RPMBUILD}/SPECS/myapp-selinux.spec"

rm -f "${DIST}"/*.rpm
find "${RPMBUILD}/RPMS" -name '*.rpm' -exec cp {} "${DIST}/" \;
echo "Built RPMs in ${DIST}/"
ls -l "${DIST}"/*.rpm
