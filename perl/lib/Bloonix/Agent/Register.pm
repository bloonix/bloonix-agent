package Bloonix::Agent::Register;

use strict;
use warnings;
use Bloonix::Config;
use Bloonix::REST;
use Log::Handler;
use Net::DNS::Resolver;
use Sys::Hostname;

use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/config log rest/);

sub host {
    my $class = shift;
    my $self = bless {}, $class;

    $self->init;
    $self->register;
}

sub init {
    my $self = shift;

    $self->init_config;
    $self->init_logger;
    $self->init_rest;
}

sub init_config {
    my $self = shift;
    my $config = Bloonix::Config->parse("/etc/bloonix/agent/register.conf");
    $self->config($config);

    if (!$self->config->{logfile}) {
        $self->config->{logfile} = "/var/log/bloonix/bloonix-register.log";
    }

    if (!$self->config->{config_file}) {
        $self->config->{config_file} = "/etc/bloonix/agent/conf.d/host.conf";
    }
}

sub init_logger {
    my $self = shift;

    $self->log(
        Log::Handler->new(
            file => {
                filename => $self->config->{logfile},
                maxlevel => "info"
            }
        )
    );
}

sub init_rest {
    my $self = shift;

    $self->rest(
        Bloonix::REST->new(
            host => $self->config->{webgui_url}
        )
    );
}

sub register {
    my $self = shift;
    my $data = $self->get_data;

    while (1) {
        $self->log->info("try register host on", $self->config->{webgui_url});

        my $res = $self->rest->post(
            path => "/register/host",
            data => $data
        );

        if ($res && ref $res eq "HASH" && $res->{status}) {
            if ($res->{status} eq "ok") {
                $self->log->info("registration was successful");
                $self->save_host($res->{data});
                last;
            }
            if ($res->{status} eq "err-620") {
                $self->log->warning("host $data->{hostname} already exist");
                exit;
            }
        }

        $self->log->error("registration was not successful");
        $self->log->dump(error => $res);
        sleep 10;
    }
}

sub save_host {
    my ($self, $data) = @_;

    if (open my $fh, ">", $self->config->{config_file}) {
        print $fh join("\n",
            "host {",
            "    host_id $data->{host_id}",
            "    password $data->{password}",
            "    agent_id localhost",
            "}"
        );
        close $fh;
    } else {
        $self->log->error(
            "unable to open config file",
            $self->config->{config_file},
            "for writing: $!"
        );
        exit;
    }
}

sub get_data {
    my $self = shift;
    my $data = $self->config->{data};

    if (!$data->{hostname}) {
        $self->log->info("determine hostname");
        $data->{hostname} = Sys::Hostname::hostname();
        $self->log->info("found hostname:", $data->{hostname});
    }

    if (!$data->{ipaddr}) {
        $self->log->info("determine ipaddr");
        $data->{ipaddr} = $self->get_ip_by_hostname(ipv4 => $data->{hostname});
        $self->log->info("found ipaddr:", $data->{ipaddr});
    }

    if (!$data->{ipaddr6}) {
        $self->log->info("determine ipaddr6");
        $data->{ipaddr6} = $self->get_ip_by_hostname(ipv6 => $data->{hostname});
        $self->log->info("found ipaddr6:", $data->{ipaddr6});
    }

    $self->log->info(
        "register with hostname [", $data->{hostname}, "]",
        "ipaddr [", $data->{ipaddr}, "]",
        "ipaddr6 [", $data->{ipaddr6}, "]"
    );

    return $data;
}

sub get_ip_by_hostname {
    my ($self, $type, $hostname) = @_;

    if ($type =~ /ipv4/i) {
        $type = "A";
    } elsif ($type =~ /ipv6/i) {
        $type = "AAAA";
    }

    my $res = Net::DNS::Resolver->new(debug => 0);
    my $query = $res->search($hostname, $type);
    my $ipaddr = "";

    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq $type;
            $ipaddr = $rr->address;
        }
    }

    return $ipaddr;
}

1;
