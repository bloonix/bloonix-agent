package Bloonix::Agent::Benchmark;

use strict;
use warnings;
use base qw(Bloonix::Accessor);

__PACKAGE__->mk_accessors(qw/get_hosts get_services/);

sub new {
    my ($class, $num) = @_;
    my $self = bless { todo => $num }, $class;

    if ($num ne "noexec-only") {
        ($self->{num_hosts}, $self->{num_services})
            = split /:/, $num;

        $self->create_hosts;
        $self->create_services;
    }

    return $self;
}

sub noexec_only {
    my $self = shift;

    return $self->{todo} eq "noexec-only";
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
    my ($self, $command) = @_;
    my @stdout;

    my $ipc = bless {
        stderr => [],
        timeout => 0,
        unknown => "",
        stdout => \@stdout,
        exitcode => 0
    }, "Bloonix::IPC::Cmd";

    if ($command eq "check-cpustat") {
        push @stdout, '{"status":"OK","stats":{"system":"0.84","quest":"0.00","softirq":"0.01","total":"4.91","idle":"95.09","nice":"0.11","irq":"0.00","steal":"0.00","other":"0.00","user":"3.82","iowait":"0.13"},"message":"total=4.91%, iowait=0.13%, system=0.84%, user=3.82%"}';
    } elsif ($command eq "check-diskusage") {
        push @stdout, '{"status":"OK","stats":{"usage":20004106240,"iusage":"297898","iusageper":"17","itotal":"1815072","total":29233254400,"freeper":27,"ifree":"1517174","free":7744155648,"usageper":"73","ifreeper":83},"message":"/: - usageper=73%, iusageper=17%"}';
    } elsif ($command eq "check-loadavg") {
        push @stdout, '{"status":"OK","stats":{"avg5":"0.13","avg1":"0.09","avg15":"0.19"},"message":"avg1=0.09, avg5=0.13, avg15=0.19"}';
    } elsif ($command eq "check-memstat") {
        push @stdout, '{"status":"OK","stats":{"swaptotal":1999630336,"swapusedper":"18.66","swapcached":28168192,"buffers":226463744,"dirty":9494528,"inactive":828805120,"memfree":211472384,"memused":"2955882496","pagetables":41922560,"committed":5598396416,"memusedper":"71.04","writeback":0,"active":1313333248,"slab":282632192,"swapfree":1626533888,"memtotal":4160913408,"vmallocused":25653248,"swapused":"373096448","memrealfree":"1205030912","cached":767094784,"mapped":61657088},"message":"memusedper=71.04%, swapusedper=18.66%"}';
    } elsif ($command eq "check-netstat") {
        push @stdout, '{"status":"OK","stats":{"failed":"0.00","recv_udp_errs":"0.00","close_wait":0,"close":6,"unknown":0,"closing":0,"last_ack":0,"sent_udp_pcks":"6.50","established":"131","active":"3.00","sent_resets":"0.50","syn_send":0,"syn_recv":0,"fin_wait2":6,"recv_resets":"0.50","recv_udp_pcks":"6.50","fin_wait1":0,"passive":"2.75","time_wait":158},"message":"established=131, active=3.00, passive=2.75"}';
    } elsif ($command eq "check-netstat-port") {
        push @stdout, '{"status":"OK","stats":{"established":"33","fin_wait2":0,"syn_recv":0,"syn_send":0,"close_wait":0,"fin_wait1":0,"close":0,"unknown":0,"time_wait":0,"closing":0,"last_ack":0},"message":"port 5432: established=33"}';
    } elsif ($command eq "check-open-files") {
        push @stdout, '{"status":"OK","stats":{"fh_alloc":"5248","nr_inodes":"183778","nr_dentry":"239448","fh_free":"0","nr_unused":"205299","nr_free_inodes":"64439","fh_max":"405080"},"message":"fh_real_free(98.70%), fh_alloc(5248), fh_free(0), fh_max(405080)"}';
    } elsif ($command eq "check-pgswstat") {
        push @stdout, '{"status":"OK","stats":{"pgpgin":"0.00","pgmajfault":"0.00","pgpgout":"18.00","pswpin":"0.00","pgfault":"1553.00","pswpout":"0.00"},"message":"pgpgin=0.00, pgpgout=18.00, pswpin=0.00, pswpout=0.00"}';
    } elsif ($command eq "check-procstat") {
        push @stdout, '{"status":"OK","stats":{"count":"603","runqueue":"1","blocked":"0","running":"1","new":"42.50"},"message":"new=42.50, runqueue=1, count=603, blocked=0, running=1"}';
    } elsif ($command eq "check-sockstat") {
        push @stdout, '{"status":"OK","stats":{"sockets":"722","udp":"5","ipfrag":"0","tcp":"131","raw":"3"},"message":"sockets=722, tcp=131, udp=5, raw=3, ipfrag=0"}';
    } else {
        push @stdout, '{"status":"OK","message":"OK"}';
    }

    return $ipc;
}

1;
