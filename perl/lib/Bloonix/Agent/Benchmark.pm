package Bloonix::Agent::Benchmark;

use strict;
use warnings;
use base qw(Bloonix::Accessor);

__PACKAGE__->mk_accessors(qw/get_hosts get_services/);

sub new {
    my ($class, $num) = @_;

    my $self = bless {}, $class;
    $num ||= "10000:1";

    ($self->{num_hosts}, $self->{num_services})
        = split /:/, $num;

    $self->create_hosts;
    $self->create_services;

    return $self;
}

sub create_hosts {
    my ($self, $num) = @_;
    $num ||= $self->{num_hosts};
    my @hosts;

    foreach my $n (1..$num) {
        push @hosts, {
            host_id => $n,
            password => $n
        };
    }

    $self->get_hosts(\@hosts);
}

sub create_services {
    my ($self, $num) = @_;
    $num ||= $self->{num_services};
    my @services;

    foreach my $n (1..$num) {
        push @services, {
            service_id => $n,
            agent_id => "localhost",
            command => "check-loadavg",
            command_options => [
               { option => "warning", value => "avg1:20" },
               { option => "critical", value => "avg1:50" }
            ]
        };
    }

    $self->get_services({
        status => "ok",
        data => {
            services => \@services,
            interval => 15
        }
    });
}

sub get_check_result {
    my $self = shift;

    return bless {
        stderr => [],
        timeout => 0,
        unknown => "",
        stdout => [
            '{"status":"OK","stats":{"avg5":"2.14","avg1":"1.33","avg15":"1.40"},"message":"LOAD OK - avg1=1.33, avg5=2.14, avg15=1.40"}'
        ],
        exitcode => 0
    }, "Bloonix::IPC::Cmd";
}

1;
