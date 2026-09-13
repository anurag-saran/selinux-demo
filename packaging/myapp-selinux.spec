Name:           myapp-selinux
Version:        1.1.0
Release:        1%{?dist}
Summary:        SELinux policy module for Order Processor demo application
License:        MIT
URL:            https://github.com/anurag-saran/selinux-demo
BuildArch:      noarch

Requires:       selinux-policy-targeted >= 38.1.19-1
Requires(post):  policycoreutils
Requires(post):  selinux-policy-base

Source0:        myapp.pp
Source1:        myapp.te
Source2:        myapp.fc

%description
Custom SELinux policy module (myapp) for the Order Processor PoC application.
Installs type enforcement for myapp_t and myapp_backend_t with FHS paths under
/var/lib/myapp and /run/myapp.

%prep
# Binary policy package is built by CI/scripts/compile_and_validate.sh

%install
install -d %{buildroot}%{_datadir}/selinux/packages
install -m 0644 %{SOURCE0} %{buildroot}%{_datadir}/selinux/packages/myapp.pp

%files
%defattr(-,root,root,-)
%{_datadir}/selinux/packages/myapp.pp

%post
%selinux_modules_install -s targeted %{_datadir}/selinux/packages/myapp.pp
%selinux_relabel_pre -s targeted
%selinux_relabel_post -s targeted
if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t myapp_port_t -p tcp 8888 2>/dev/null || \
        semanage port -m -t myapp_port_t -p tcp 8888 2>/dev/null || true
    semanage port -a -t myapp_backend_port_t -p tcp 8889 2>/dev/null || \
        semanage port -m -t myapp_backend_port_t -p tcp 8889 2>/dev/null || true
fi

%postun
if [ $1 -eq 0 ]; then
    %selinux_modules_uninstall -s targeted myapp
fi

%changelog
* Sun Sep 13 2026 PoC Maintainer <maintainer@example.com> - 1.1.0-1
- FHS paths, refpolicy interfaces, dedicated port types
