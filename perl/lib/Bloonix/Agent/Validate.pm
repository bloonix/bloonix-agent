=head1 NAME

Bloonix::Agent::Validate - Validate the Agent configuration.

=head1 SYNOPSIS

    Bloonix::Agent::Validate->config(
        configfile => $configfile,
        pid_file => $pid_file,
        sock_file => $sock_file
    );

=head1 DESCRIPTION

Validate the Bloonix Agent configuration.

=head1 FUNCTIONS

=head2 config

=head2 main

=head2 host

=head2 service

=head2 server

=head1 PREREQUISITES

    Params::Validate
    Sys::Hostname

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2009 by Jonny Schulz. All rights reserved.

=cut

package Bloonix::Agent::Validate;

use strict;
use warnings;
use Bloonix::Config;
use Bloonix::REST;
use Params::Validate qw();
use Sys::Hostname;

use constant IS_WIN32 => $^O =~ /Win32/i ? 1 : 0;

sub config {
    my ($class, $file) = @_;

    # Bloonix::Config is new, so it's necessary to check
    # first if the configuration is written in the old style
    # of Config::General.
    open my $fh, "<", $file or die "unable to open configuration file '$file' - $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    my $config = Bloonix::Config->parse($file);

    return $class->main($config);
}

sub args {
    my $class = shift;

    my %args = Params::Validate::validate(@_, {
        configfile => {
            type => Params::Validate::SCALAR,
            default => "/etc/bloonix/agent/main.conf"
        },
        pid_file => {
            type => Params::Validate::SCALAR,
            default => "/var/run/bloonix/bloonix-agent.pid"
        },
        sock_file => {
            type => Params::Validate::SCALAR,
            default => "/var/run/bloonix/bloonix-agent.sock"
        }
    });

    return \%args;
}

sub main {
    my $class = shift;

    my %options = Params::Validate::validate(@_, {
        user => {
            type => Params::Validate::SCALAR,
            default => "bloonix"
        },
        group => {
            type => Params::Validate::SCALAR,
            default => "bloonix"
        },
        server => {
            type => Params::Validate::HASHREF
        },
        satellite => {
            type => Params::Validate::HASHREF,
            default => {}
        },
        host => {
            type => Params::Validate::HASHREF | Params::Validate::ARRAYREF,
            default => []
        },
        log => { # deprecated
            type => Params::Validate::HASHREF,
            optional => 1
        },
        logger => {
            type => Params::Validate::HASHREF,
            optional => 1
        },
        plugins => {
            type => Params::Validate::SCALAR,
            default => "/usr/local/lib/bloonix/plugins"
        },
        nagios_plugins => { # deprecated
            type => Params::Validate::SCALAR,
            optional => 1
        },
        simple_plugins => {
            type => Params::Validate::SCALAR,
            optional => 1
        },
        env => {
            type => Params::Validate::HASHREF,
            default => { }
        },
        agents => { # min 1, max 9999
            type  => Params::Validate::SCALAR,
            regex => qr/^[1-9]\d{0,3}\z/,
            default => 1
        },
        max_concurrent_checks => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 4
        },
        poll_interval => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 60
        },
        plugin_libdir => {
            type => Params::Validate::SCALAR,
            default => "/var/lib/bloonix/agent"
        },
        config_path => {
            type => Params::Validate::SCALAR,
            default => "/etc/bloonix/agent"
        },
        benchmark => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+:\d+\z/,
            default => 0
        },
        use_sudo => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => [ "unset" ]
        },
        perlbin => {
            type => Params::Validate::SCALAR,
            default => ""
        }
    });

    if ($options{poll_interval} < 15) {
        # min value
        $options{poll_interval} = 15;
    }

    if ($options{nagios_plugins}) {
        $options{simple_plugins} = delete $options{nagios_plugins};
    }

    if ($options{max_concurrent_checks} == 0) {
        $options{max_concurrent_checks} = 4;
    }

    my $env = $options{env};
    $options{env}{PLUGIN_LIBDIR} = $options{plugin_libdir};
    $options{env}{CONFIG_PATH} = $options{config_path};

    foreach my $key (qw/plugins simple_plugins/) {
        if ($options{$key}) {
            $options{$key} = [ split /,/, $options{$key} ];
            s/^\s+// for @{$options{$key}};
            s/\s+$// for @{$options{$key}};
        }
    }

    if (ref $options{use_sudo} ne "ARRAY") {
        $options{use_sudo} = [ $options{use_sudo} ];
    }

    my %use_sudo;
    foreach my $opt (@{$options{use_sudo}}) {
        $opt =~ s/\s//g;
        foreach my $key (split /,/, $opt) {
            $use_sudo{$key} = 1;
        }
    }
    delete $use_sudo{unset};
    $options{use_sudo} = \%use_sudo;

    if ($options{benchmark}) {
        require Bloonix::Agent::Benchmark;
        $options{benchmark} = Bloonix::Agent::Benchmark->new($options{benchmark});
        $options{host} = $options{benchmark}->get_hosts;
    }

    if ($options{log}) {
        $options{logger} = $options{log};
    }

    my $hosts = delete $options{host};

    if (IS_WIN32) {
        if (ref $hosts eq "ARRAY") {
            # find the first active host, because it's possible
            # that multiple hosts are configured but the hosts
            # are inactive
            foreach my $host (@$hosts) {
                my $validated = $class->host($host);

                if ($validated->{active} eq "yes") {
                    $options{host} = $validated;
                    last;
                }
            }
        } else {
            $options{host} = $class->host($hosts);

            if ($options{host}{active} ne "yes") {
                $options{host} = {};
            }
        }
    } else {
        $options{host} = { };

        if (ref $hosts eq "HASH") {
            $hosts = [ $hosts ];
        }

        foreach my $host (@$hosts) {
            my $validated = $class->host($host);
            my $host_id = $validated->{host_id};

            if ($validated->{active} eq "yes") {
                $options{host}{$host_id} = $validated;
                $options{host}{$host_id}{time} = time;
                $options{host}{$host_id}{in_progress} = 0;
            }
        }
    }

    $class->server($options{server});

    return \%options;
}

sub host {
    my $class = shift;

    my %options = Params::Validate::validate(@_, {
        host_id => {
            type => Params::Validate::SCALAR,
            regex => qr/^[a-z0-9\-\.]+\z/,
            optional => 1
        },
        hostid => { # deprecated
            type  => Params::Validate::SCALAR,
            regex => qr/^[a-z0-9\-\.]+\z/,
            optional => 1
        },
        agent_id => {
            type => Params::Validate::SCALAR,
            default => "localhost"
        },
        agentid => { # deprecated
            type => Params::Validate::SCALAR,
            optional => 1
        },
        password => {
            type => Params::Validate::SCALAR,
        },
        active => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:no|yes)\z/,
            default => "yes"
        },
        server => {
            type => Params::Validate::HASHREF,
            optional => 1
        },
        use_sudo => {
            type => Params::Validate::SCALAR,
            default => "unset"
        },
        env => {
            type => Params::Validate::HASHREF,
            default => { }
        },
        execute_on_event => {
            type => Params::Validate::HASHREF,
            default => { }
        },
        config => {
            type => Params::Validate::SCALAR,
            default => ""
        },
        max_concurrent_checks => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 0
        }
    });

    if ($options{config}) {
        warn "the parameter 'config' is deprecated within the host section\n";
    }
    delete $options{config};

    if (!defined $options{host_id} && !defined $options{hostid}) {
        $options{host_id} = Sys::Hostname::hostname();
    }

    if (defined $options{agentid}) {
        $options{agent_id} = delete $options{agentid};
    }

    if (defined $options{hostid}) {
        $options{host_id} = delete $options{hostid};
    }

    $options{agent_id} =~ s/\s//g;

    # For backward compability
    if ($options{agent_id} eq "0") {
        $options{agent_id} = "localhost";
    }

    if ($options{agent_id} eq "9000") {
        $options{agent_id} = "remote";
    }

    $options{use_sudo} =~ s/\s//g;
    $options{use_sudo} = { map { $_ => 1 } split(/,/, $options{use_sudo}) };
    delete $options{use_sudo}{unset};

    if ($options{server}) {
        $class->server($options{server});
    }

    return \%options;
}

sub service {
    my $class = shift;

    my %options = Params::Validate::validate(@_, {
        command => {
            type => Params::Validate::SCALAR
        },
        command_options => {
            type => Params::Validate::HASHREF,
            optional => 1
        },
        location_options => {
            type => Params::Validate::UNDEF | Params::Validate::SCALAR | Params::Validate::HASHREF,
            default => 0
        },
        timeout => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 60
        },
        kill_signal => {
            type => Params::Validate::SCALAR,
            regex => qr/^-{0,1}\d+\z/,
            default => 9
        },
        timeout_status => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:OK|WARNING|CRITICAL|UNKNOWN)\z/,
            default => "CRITICAL"
        },
        unknown_status => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:OK|WARNING|CRITICAL|UNKNOWN)\z/,
            default => "UNKNOWN"
        },
        error_status => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:OK|WARNING|CRITICAL|UNKNOWN)\z/,
            default => "UNKNOWN"
        }
    });

    if ($options{timeout} == 0) {
        $options{timeout} = 60;
    }

    if ($options{command} eq "check-nagios-wrapper") {
        $options{command} = "check-simple-wrapper";
    }

    my $command_options = $options{command_options};

    if ($command_options && exists $command_options->{"nagios-command"}) {
        $command_options->{"simple-command"} = delete $command_options->{"nagios-command"};
    }

    if ($options{command} eq "check-simple-wrapper") {
        $class->check_simple_command(\%options);
    }

    return \%options;
}

sub server {
    my ($class, $server) = @_;

    if ($server->{host}) {
        if ($server->{host} =~ /^\@/) {
            die "Invalid server configured. Please edit the configuration file and change the address to the bloonix server.\n";
        }
        if (!$server->{proto} && !$server->{ssl_options}) {
            $server->{peeraddr} = delete $server->{host};
            $server->{peerport} = delete $server->{port};
        }
    }
}

sub check_simple_command {
    my ($class, $options) = @_;

    my $regex = qr!^
        (                               # begin capture of the command
            (?:[\w]|[\w][\w\-]+/)*      # sub directories are allowed
            (?:[\w]|[\w][\w\-]+         # the command name
                (?:\.[a-zA-Z]+){0,1}    # file extension of the command
            )
        )                               # end capture of the command
        (?:
            \s+                         # whitespaces between cmd and args
            ([^'`\\]+)                  # capture the arguments
        ){0,1}
    \z!x;

    $options->{is_simple_check} = 1;

    if ($options->{command_options}->{"simple-command"} =~ $regex) {
        my ($command, $arguments) = ($1, $2);
        $options->{command} = $command;
        $options->{command_options} = $class->parse_command_options($arguments);
    } else {
        die "invalid simple command: ". $options->{command_options}->{"simple-command"};
    }
}

sub parse_command_options {
    my ($self, $argv) = @_;
    my $quote = IS_WIN32 ? '"' : "'";

    if (IS_WIN32 && $argv =~ /%/) {
        die "invalid characater '%' found in argument list";
    }

    my @args = ();
    my @parts = split /\s/, $argv;

    while (@parts) {
        my @values;
        OUTER:
        while (@parts) {
            my $value = shift @parts;
            push @values, $value;
            last if $value !~ s/^"//;

            while (@parts) {
                my $value = shift @parts;
                push @values, $value;
                last OUTER if $value =~ s/"\z//;
            }
        }

        if (@values) {
            my $value = join(" ", @values);

            if (IS_WIN32) {
                $value =~ s/"/\\"/g;
            }

            push @args, $quote . $value . $quote;
        }
    }

    return join(" ", @args);
}

1;
