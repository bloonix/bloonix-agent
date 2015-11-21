CONFIG=Makefile.config

include $(CONFIG)

default: build

build:

	# Init script
	for file in \
		etc/init/bloonix-agent \
		etc/init/bloonix-pre-start \
		etc/init/bloonix-agent.service \
		etc/init/bloonix-init-source \
		etc/bloonix/agent/main.conf \
		bin/bloonix-agent \
		bin/bloonix-cli \
		bin/bloonix-init-host \
	; do \
		cp $$file.in $$file; \
		sed -i "s!@@PERL@@!$(PERL)!g" $$file; \
		sed -i "s!@@SSL_CA_PARAM@@!$(SSL_CA_PARAM)!g" $$file; \
		sed -i "s!@@SSL_CA_VALUE@@!$(SSL_CA_VALUE)!g" $$file; \
		sed -i "s!@@PREFIX@@!$(PREFIX)!g" $$file; \
		sed -i "s!@@USRLIBDIR@@!$(USRLIBDIR)!g" $$file; \
		sed -i "s!@@CACHEDIR@@!$(CACHEDIR)!g" $$file; \
		sed -i "s!@@CONFDIR@@!$(CONFDIR)!g" $$file; \
		sed -i "s!@@INITDIR@@!$(INITDIR)!g" $$file; \
		sed -i "s!@@LIBDIR@@!$(LIBDIR)!g" $$file; \
		sed -i "s!@@LOGDIR@@!$(LOGDIR)!g" $$file; \
		sed -i "s!@@RUNDIR@@!$(RUNDIR)!g" $$file; \
		sed -i "s!@@SRVDIR@@!$(SRVDIR)!g" $$file; \
		sed -i "s!@@USERNAME@@!$(USERNAME)!g" $$file; \
		sed -i "s!@@GROUPNAME@@!$(GROUPNAME)!g" $$file; \
	done;

	# Perl
	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build.PL installdirs=$(PERL_INSTALLDIRS); \
		$(PERL) Build; \
	fi;

test:

	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build test; \
	fi;

install:

	# Base Bloonix directories
	for d in $(LIBDIR) $(LOGDIR) $(RUNDIR) $(USRLIBDIR) ; do \
		if test ! -d "$$d/bloonix" ; then \
			./install-sh -d -m 0750 -o $(USERNAME) -g $(GROUPNAME) $$d/bloonix; \
		fi; \
	done;

	# This and that
	./install-sh -d -m 0755 -o root -g root $(CONFDIR)/bloonix;
	./install-sh -d -m 0755 -o root -g root $(CONFDIR)/bloonix/agent;
	./install-sh -d -m 0750 -o root -g $(GROUPNAME) $(CONFDIR)/bloonix/agent/conf.d;
	./install-sh -d -m 0750 -o $(USERNAME) -g $(GROUPNAME) $(LIBDIR)/bloonix/agent;
	./install-sh -d -m 0755 $(PREFIX)/bin;
	./install-sh -d -m 0755 $(PREFIX)/lib/bloonix/etc/sudoers.d;
	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/agent;
	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/bin;
	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/systemd;
	./install-sh -d -m 0755 $(USRLIBDIR)/bloonix/etc/init.d;
	./install-sh -c -m 0755 etc/init/bloonix-pre-start $(USRLIBDIR)/bloonix/bin/bloonix-pre-start;
	./install-sh -c -m 0755 etc/init/bloonix-init-source $(USRLIBDIR)/bloonix/bin/bloonix-init-source;
	./install-sh -c -m 0644 etc/init/bloonix-agent.service $(USRLIBDIR)/bloonix/etc/systemd/bloonix-agent.service;
	./install-sh -c -m 0755 etc/init/bloonix-agent $(USRLIBDIR)/bloonix/etc/init.d/bloonix-agent;
	./install-sh -c -m 0755 bin/bloonix-init-agent $(PREFIX)/bin/bloonix-init-agent;
	./install-sh -c -m 0755 bin/bloonix-agent $(PREFIX)/bin/bloonix-agent;
	./install-sh -c -m 0755 bin/bloonix-cli $(PREFIX)/bin/bloonix-cli;
	./install-sh -c -m 0755 bin/bloonix-init-host $(PREFIX)/bin/bloonix-init-host;
	./install-sh -c -m 0644 etc/bloonix/agent/main.conf $(USRLIBDIR)/bloonix/etc/agent/main.conf;
	./install-sh -c -m 0644 etc/sudoers.d/10_bloonix $(USRLIBDIR)/bloonix/etc/sudoers.d/10_bloonix;

	if test -d /usr/lib/systemd ; then \
		./install-sh -d -m 0755 $(DESTDIR)/usr/lib/systemd/system/; \
		./install-sh -c -m 0644 etc/init/bloonix-agent.service $(DESTDIR)/usr/lib/systemd/system/; \
	elif test -d /etc/init.d ; then \
		./install-sh -c -m 0755 etc/init/bloonix-agent $(INITDIR)/bloonix-agent; \
	fi;

	if test "$(BUILDPKG)" = "0" ; then \
		if test ! -e "$(CONFDIR)/bloonix/agent/main.conf" ; then \
			./install-sh -c -m 0640 -o root -g $(GROUPNAME) etc/bloonix/agent/main.conf $(CONFDIR)/bloonix/agent/main.conf; \
		fi; \
		if test ! -e "$(CONFDIR)/sudoers.d/10_bloonix" ; then \
			./install-sh -c -m 0440 -o root -g root etc/sudoers.d/10_bloonix $(CONFDIR)/sudoers.d/10_bloonix; \
		fi; \
		if test -d /usr/lib/systemd ; then \
			systemctl daemon-reload; \
		fi; \
	fi;

	# Install the Bloonix agent perl modules
	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; $(PERL) Build install; $(PERL) Build realclean; \
	fi;

clean:

	if test "$(WITHOUT_PERL)" = "0" ; then \
		cd perl; \
		if test -e "Makefile" ; then \
			$(PERL) Build clean; \
		fi; \
	fi;

