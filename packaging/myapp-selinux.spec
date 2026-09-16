Name:           myapp-selinux
# modver is passed by packaging/build_rpms.sh from selinux/policy_version.txt (single source of truth).
Version:        %{modver}
Release:        1%{?dist}
Summary:        SELinux policy module for Order Processor demo application
License:        MIT
URL:            https://github.com/anurag-saran/selinux-demo
BuildArch:      noarch

Requires:       selinux-policy-ops >= 1.0.0
Requires(post): policycoreutils
Requires(post): selinux-policy-base

Source0:        myapp.pp
Source1:        myapp.te
Source2:        myapp.fc
Source3:        selinux-manifest.yml

%description
Custom SELinux policy module (myapp) for the Order Processor PoC application.
Installs type enforcement for myapp_t and myapp_backend_t with FHS paths under
/var/lib/myapp, /var/log/myapp, and /run/myapp.

%prep
# Binary policy built by scripts/compile_and_validate.sh; manifest from config/

%install
install -d %{buildroot}%{_datadir}/selinux/packages
install -m 0644 %{SOURCE0} %{buildroot}%{_datadir}/selinux/packages/myapp.pp
install -d %{buildroot}%{_sysconfdir}/myapp
install -m 0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/myapp/selinux-manifest.yml

%pre
%selinux_relabel_pre -s targeted

%post
%selinux_modules_install -s targeted %{_datadir}/selinux/packages/myapp.pp
if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t myapp_port_t -p tcp 8888 2>/dev/null || \
        semanage port -m -t myapp_port_t -p tcp 8888 2>/dev/null || true
    semanage port -a -t myapp_backend_port_t -p tcp 8889 2>/dev/null || \
        semanage port -m -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true
fi

%postun
if [ $1 -eq 0 ]; then
    %selinux_modules_uninstall -s targeted myapp
    if command -v semanage >/dev/null 2>&1; then
        semanage port -d -p tcp 8888 2>/dev/null || true
        semanage port -d -p tcp 8889 2>/dev/null || true
    fi
fi

%posttrans
%selinux_relabel_post -s targeted

%files
%defattr(-,root,root,-)
%{_datadir}/selinux/packages/myapp.pp
%config(noreplace) %{_sysconfdir}/myapp/selinux-manifest.yml
%doc %{SOURCE1}
%doc %{SOURCE2}

%changelog
* Sun Sep 13 2026 PoC Maintainer <maintainer@example.com> - 1.1.2-1
- Requires selinux-policy-ops; ship manifest under /etc/myapp/
- Policy 1.1.2 manage patterns, urand, narrowed /var/opt labeling

* Sun Sep 13 2026 PoC Maintainer <maintainer@example.com> - 1.1.1-1
- Path traversal, daemon baseline, /var/log/myapp log type + filetrans
