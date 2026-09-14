Name:           selinux-policy-ops
Version:        1.0.0
Release:        1%{?dist}
Summary:        Shared SELinux deploy/readiness scripts (app-independent)
License:        MIT
URL:            https://github.com/anurag-saran/selinux-demo
BuildArch:      noarch

%description
Operational scripts for SELinux policy canary, enforce, and soak gates.
Installed under %{_libexecdir}/selinux-policy-ops for use by Ansible playbooks
and admins. Shared across application policy packages (myapp, payments, etc.).

%prep
# Scripts are copied from the repository at build time (see build script or CI).

%install
install -d %{buildroot}%{_libexecdir}/selinux-policy-ops/lib
install -m 0755 %{_builddir}/selinux-policy-ops-src/verify_file_contexts.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/
install -m 0755 %{_builddir}/selinux-policy-ops-src/wait_for_endpoints.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/
install -m 0755 %{_builddir}/selinux-policy-ops-src/monitor_avc.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/
install -m 0755 %{_builddir}/selinux-policy-ops-src/post_deploy_report.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/
install -m 0755 %{_builddir}/selinux-policy-ops-src/collect_soak_facts.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/
install -m 0644 %{_builddir}/selinux-policy-ops-src/lib/avc_query.sh \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/lib/
install -m 0644 %{_builddir}/selinux-policy-ops-src/lib/app_manifest.py \
    %{buildroot}%{_libexecdir}/selinux-policy-ops/lib/

%files
%defattr(-,root,root,-)
%{_libexecdir}/selinux-policy-ops/verify_file_contexts.sh
%{_libexecdir}/selinux-policy-ops/wait_for_endpoints.sh
%{_libexecdir}/selinux-policy-ops/monitor_avc.sh
%{_libexecdir}/selinux-policy-ops/post_deploy_report.sh
%{_libexecdir}/selinux-policy-ops/collect_soak_facts.sh
%{_libexecdir}/selinux-policy-ops/lib/avc_query.sh
%{_libexecdir}/selinux-policy-ops/lib/app_manifest.py

%changelog
* Sun Sep 13 2026 PoC Maintainer <maintainer@example.com> - 1.0.0-1
- Initial shared ops package for target-side readiness scripts
