Summary: Bloonix agent daemon
Name: bloonix-agent
Version: 0.36
Release: 1%{dist}
License: Commercial
Group: Utilities/System
Distribution: RHEL/CentOS/Suse

Packager: Jonny Schulz <js@bloonix.de>
Vendor: Bloonix

BuildArch: noarch
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

Source0: http://download.bloonix.de/sources/%{name}-%{version}.tar.gz
Requires: facter
Requires: bloonix-core
Requires: perl(Getopt::Long)
Requires: perl(JSON)
Requires: perl(Log::Handler)
Requires: perl(Params::Validate)
Requires: perl(Term::ReadKey)
Requires: perl(Time::HiRes)
AutoReqProv: no

%description
bloonix-agent provides the bloonix agent.

%define with_systemd 0
%define mandir8 %{_mandir}/man8
%define docdir %{_docdir}/%{name}-%{version}
%define blxdir /usr/lib/bloonix
%define initdir /etc/init.d
%define logrdir %{_sysconfdir}/logrotate.d
%define logdir /var/log/bloonix
%define rundir /var/run/bloonix
%define pod2man /usr/bin/pod2man

%prep
%setup -q -n %{name}-%{version}
%{pod2man} bin/bloonix-agent.in >bin/bloonix-agent.8

%build
%{__perl} Configure.PL --prefix /usr --without-perl --ssl-ca-file /etc/pki/tls/certs/ca-bundle.crt --build-package
%{__make}
cd perl;
%{__perl} Build.PL installdirs=vendor
%{__perl} Build

%install
rm -rf %{buildroot}
%{__make} install DESTDIR=%{buildroot}
mkdir -p ${RPM_BUILD_ROOT}%{mandir8}
mkdir -p ${RPM_BUILD_ROOT}%{logrdir}
mkdir -p ${RPM_BUILD_ROOT}%{docdir}
install -d -m 0750 ${RPM_BUILD_ROOT}%{logdir}
install -d -m 0750 ${RPM_BUILD_ROOT}%{rundir}
install -c -m 0644 etc/logrotate.d/bloonix ${RPM_BUILD_ROOT}%{logrdir}/
install -c -m 0444 bin/bloonix-agent.8 ${RPM_BUILD_ROOT}%{mandir8}/
install -c -m 0444 LICENSE ${RPM_BUILD_ROOT}%{docdir}/
install -c -m 0444 ChangeLog ${RPM_BUILD_ROOT}%{docdir}/

%if %{?with_systemd}
install -p -D -m 0644 %{buildroot}%{blxdir}/etc/systemd/bloonix-agent.service %{buildroot}%{_unitdir}/bloonix-agent.service
%else
install -p -D -m 0755 %{buildroot}%{blxdir}/etc/init.d/bloonix-agent %{buildroot}%{initdir}/bloonix-agent
%endif

cd perl;
%{__perl} Build install destdir=%{buildroot} create_packlist=0
find %{buildroot} -name .packlist -exec %{__rm} {} \;

%pre
getent group bloonix >/dev/null || /usr/sbin/groupadd bloonix
getent passwd bloonix >/dev/null || /usr/sbin/useradd \
    bloonix -g bloonix -s /sbin/nologin -d /var/run/bloonix -r

%post
%if %{?with_systemd}
#%systemd_post bloonix-agent.service
systemctl preset bloonix-agent.service
systemctl condrestart bloonix-agent.service
%else
if test ! -e "/etc/sysconfig/bloonix-agent" ; then
    echo 'LOGGER="/usr/bin/logger -t bloonix-agent"' >/etc/sysconfig/bloonix-agent
fi
/sbin/chkconfig --add bloonix-agent
/sbin/service bloonix-agent condrestart &>/dev/null
%endif

if [ ! -e "/etc/bloonix/agent/main.conf" ] ; then
    mkdir -p /etc/bloonix/agent
    cp -a /usr/lib/bloonix/etc/agent/main.conf /etc/bloonix/agent/main.conf
    chown root:bloonix /etc/bloonix/agent
    chown root:bloonix /etc/bloonix/agent/main.conf
fi
if [ ! -e "/etc/bloonix/agent/conf.d" ] ; then
    mkdir -p /etc/bloonix/agent/conf.d
    chown root:bloonix /etc/bloonix/agent/conf.d
fi
if [ ! -e "/etc/bloonix/agent/sudoers.d" ] ; then
    mkdir -p /etc/bloonix/agent/sudoers.d
    chown root:bloonix /etc/bloonix/agent/sudoers.d
fi
# fix permissions
chown -R root /etc/bloonix
chgrp -R bloonix /etc/bloonix
chmod -R o-rwx /etc/bloonix
chmod -R g-w /etc/bloonix

%preun
%if %{?with_systemd}
systemctl --no-reload disable bloonix-agent.service
systemctl stop bloonix-agent.service
systemctl daemon-reload
#%systemd_preun bloonix-agent.service
%else
if [ $1 -eq 0 ]; then
    /sbin/service bloonix-agent stop &>/dev/null || :
    /sbin/chkconfig --del bloonix-agent
fi
%endif

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)

%dir %attr(0755, root, root) %{blxdir}
%dir %attr(0755, root, root) %{blxdir}/bin
%{blxdir}/bin/bloonix-init-source
%{blxdir}/bin/bloonix-pre-start
%dir %attr(0755, root, root) %{blxdir}/etc
%dir %attr(0755, root, root) %{blxdir}/etc/agent
%{blxdir}/etc/agent/main.conf
%dir %attr(0755, root, root) %{blxdir}/etc/systemd
%{blxdir}/etc/systemd/bloonix-agent.service
%dir %attr(0755, root, root) %{blxdir}/etc/init.d
%{blxdir}/etc/init.d/bloonix-agent
%dir %attr(0755, root, root) %{logrdir}
%config(noreplace) %attr(0640, root, root) %{logrdir}/bloonix
%dir %attr(0750, bloonix, bloonix) %{logdir}
%dir %attr(0750, bloonix, bloonix) %{rundir}

%{_bindir}/bloonix-agent
%{_bindir}/bloonix-cli
%{_bindir}/bloonix-init-host

%if %{?with_systemd}
%{_unitdir}/bloonix-agent.service
%else
%{initdir}/bloonix-agent
%endif

%dir %attr(0755, root, root) %{docdir}
%doc %attr(0444, root, root) %{docdir}/LICENSE
%doc %attr(0444, root, root) %{docdir}/ChangeLog
%doc %attr(0444, root, root) %{mandir8}/bloonix-agent.8.gz

%dir %{perl_vendorlib}/Bloonix/
%dir %{perl_vendorlib}/Bloonix/Agent
%{perl_vendorlib}/Bloonix/*.pm
%{perl_vendorlib}/Bloonix/Agent/*
%{_mandir}/man?/Bloonix::*

%changelog
* Sun Nov 16 2014 Jonny Schulz <js@bloonix.de> - 0.36-1
- Added use_sudo as global configuration parameter for the agent.
- Fixed owner of all directories and files within /etc/bloonix.
* Sat Nov 08 2014 Jonny Schulz <js@bloonix.de> - 0.35-1
- Decreased the poll interval from 20 to 15 seconds because the
  the lowest interval of check_frequency=high is 15 seconds.
* Wed Nov 05 2014 Jonny Schulz <js@bloonix.de> - 0.34-1
- Increased the default timeout for checks from 30 to 60 seconds.
* Wed Nov 05 2014 Jonny Schulz <js@bloonix.de> - 0.33-1
- Fixed the init script and removed S20 or any other
  prefix from basename.
* Mon Nov 03 2014 Jonny Schulz <js@bloonix.de> - 0.32-1
- Updated the license information.
* Sat Oct 25 2014 Jonny Schulz <js@bloonix.de> - 0.31-1
- On systems with systemd STDOUT and STDERR are redirected
  to syslog by default. On sysvinit system it's possible to
  redirect STDOUT and STDERR to syslog.
* Fri Oct 24 2014 Jonny Schulz <js@bloonix.de> - 0.30-1
- Disable die_on_errors by default so that the logger
  does not die on errors.
* Tue Aug 26 2014 Jonny Schulz <js@bloonix.de> - 0.29-1
- Splitted the bloonix-agent package into 2 packages.
  Dependencies are now find in the bloonix-core package.
- Switched back to the original HTTP::Tiny.
* Sat Jul 12 2014 Jonny Schulz <js@bloonix.de> - 0.28-1
- Added add_pre_check and post_check to Bloonix::REST.
- Added option check_ok_status to Bloonix::REST.
- Net::DNS::Resolver is used to resolv hostnames to ip
  addresses.
- Added new methods get_mtr and get_ip_by_hostname
  to Bloonix::Plugin.
* Mon May 26 2014 Jonny Schulz <js@bloonix.de> - 0.27-1
- Added Bloonix::Plugin::Socket.
- Bloonix::Plugin has an eval() method.
* Wed May 14 2014 Jonny Schulz <js@bloonix.de> - 0.26-1
- Minus values are now possible for thresholds.
- Added new features to Bloonix::Plugin.
* Mon May 12 2014 Jonny Schulz <js@bloonix.de> - 0.25-1
- execute_on_event is now working.
- Fixed encoding problems and added utf8 to parse the output
  of all plugins.
* Wed Apr 23 2014 Jonny Schulz <js@bloonix.de> - 0.24-1
- Replaced command_name with service_id. Temporaray files now
  has the service id in name instead the command_name.
- Removed interval option completly.
* Tue Apr 15 2014 Jonny Schulz <js@bloonix.de> - 0.23-1
- Fixed sudo usage.
* Sat Apr 12 2014 Jonny Schulz <js@bloonix.de> - 0.22-1
- Fixed comparing thresholds with the right operator.
- Description handling in plugins improved.
- A correct message is retured if a command does not exists.
* Sat Mar 23 2014 Jonny Schulz <js@bloonix.de> - 0.21-1
- Added method length() to Bloonix::REST.
- Adding utf8 support for config files.
- The default for parameter "config" is now "remote".
- The complete output of plugins can be JSON instead of simple
  text strings.
- A complete rewrite of the plugin system and a lot more.
* Sun Sep 08 2013 Jonny Schulz <js@bloonix.de> - 0.20-1
- Replaced HTTP::Tiny with Bloonix::HTTP::Tiny, that is just
  a fork with some modifications.
* Fri Aug 30 2013 Jonny Schulz <js@bloonix.de> - 0.19-1
- Fixed: the value of the parameter kill_signal is now used
  to kill timed out checks on Win32.
- It's now possible to set parameter env in the host section.
- Replaced LWP::UserAgent with HTTP::Tiny.
- Kicked the global timeout of 900 seconds because all
  blocking calls are eliminated. Another reason is
  that eval+alarm does not work on Win32.
- Implements FCGI proc manager to balance checks or to do
  world wide location checks. This feature is not available
  on Windows systems - what a happiness ;-)
* Thu Apr 18 2013 Jonny Schulz <js@bloonix.de> - 0.18-1
- Implemented a global timeout of 900 seconds to check a host.
  After the timeout the agent returns an error.
- Kicked bloonix-create-cert.
- Kicked parameter cbckey.
- Fixed reload - the agent throws an error on sighup.
- Added method "delete" to the REST api.
- Fixed is_stderr access on line 1054 in Agent.pm.
* Fri Feb 22 2013 Jonny Schulz <js@bloonix.de> - 0.16-1
- Added a autoflush method.
* Fri Feb 22 2013 Jonny Schulz <js@bloonix.de> - 0.15-1
- A complete re-design of the Bloonix::Agent.
- Fixed some issues with command parsing.
- Kicked Bloonix::IO::Socket. The agent uses now
  LWP::UserAgent to request or send data from/to
  the bloonix server.
- Improved the documentation and a lot of code.
- Kicked the bloonix proxy because proxing can now
  be solved via simple webserver configuration.
* Sun Sep 16 2012 Jonny Schulz <js@bloonix.de> - 0.13-1
- Add some restrictions which parameters for a command
  can be set remotly.
- Added environment variable CONFIG_PATH with default
  /etc/bloonix/agent.
- Fixed a bug in init.d/bloonix-agent. If the agent
  is not running and restarted then the agent will
  be started.
- Fixed a bug in the server protocol. The agent id
  was not passed if the agent id is set to 0.
- Improved the handling by data structure errors
  between the agent and server.
- Add some restrictions to execute a command via sudo.
- Fixed the search for the right plugin path.
- Adjust the return codes of the init scripts by LSB.
- Added "sleep 1" before daemonize().
- The daemon names changed! bloonix-agent called now bloonix-agent.
  bloonix-proxy called now bloonix-proxy.
- Added template blooni-proxy.in.
- Added bloonix-create-cert to make certificate creation
  easier.
* Tue Jan 03 2012 Jonny Schulz <js@bloonix.de> - 0.9-1
- Kicked Bloonix::Util.
- Added the possibility to start checks with sudo.
- Statistics are only cut from the status line if
  the plugin is marked as a nagios plugin.
- Plain data are now allowed instead of statistics.
- Added WARNING to execute_on_event as a status to
  cause a event.
* Fri Jul 08 2011 Jonny Schulz <js@bloonix.de> - 0.8-1
- Just a little fix in Bloonix::IO::Socket and replaced
  warn() with $log->debug.
* Fri Jul 08 2011 Jonny Schulz <js@bloonix.de> - 0.7-1
- Renamed environment variable YAML_FILE_BASEDIR to
  PLUGIN_LIBDIR.
- Fixed a bug! The return status of connect() wasn't
  intercept correctly, so that the agent runs in an
  error.
* Tue Jun 21 2011 Jonny Schulz <js@bloonix.de> - 0.5-1
- Section services will not be overwritten if more than
  one section is defined for the same host. Commands will
  be overwritten too.
- Added the build-in feature check_by_location.
- Added param to_stdin to Bloonix::IPC::Cmd.
- CHECK_HOST_ID and CHECK_COMMAND_NAME is set by
  the agent before a check will be executed.
* Fri Feb 25 2011 Jonny Schulz <js@bloonix.de> - 0.4-1
- Added the functionalety to run the agent on Win32 systems.
- If the system is Win32 then it's not possible to monitor
  multiple hosts.
- Replaced eval{} and alarm() with select() in Socket.pm.
  Added non-blocking.
- Change the default exit code to 3 for Bloonix::IPC::Cmd.
* Mon Dec 27 2010 Jonny Schulz <js@bloonix.de> - 0.3-1
- Fixed again the reload mechanism. Unfortunately
  the reload overwrite time and pid of each host.
- Fixed a bug in init.d/bloonix-agent. Unfornately the
  agent was never startet after system boot
  because there was a wrong usage of BASENAME.
* Wed Nov 17 2010 Jonny Schulz <js@bloonix.de> - 0.2-1
- Some code kicked from Cmd.pm.
- Fixed the reload mechanism.
- Fixed the path setting for plugins in main.conf.
* Mon Aug 02 2010 Jonny Schulz <js@bloonix.de> - 0.1-1
- Initial release.
