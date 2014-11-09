=head1 NAME

Bloonix::Facts - Get system facts.

=head1 SYNOPSIS

    Bloonix::Facts->get();

=head1 DESCRIPTION

Get system facts.

=head1 FUNCTIONS

=head2 get

=head1 PREREQUISITES

    facter

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2009-2014 by Jonny Schulz. All rights reserved.

=cut

package Bloonix::Facts;

use strict;
use warnings;
use Bloonix::IPC::Cmd;
use constant IS_WIN32 => $^O =~ /Win32/i ? 1 : 0;

sub get {
    my $class = shift;
    my $facts = $class->_default;
    my $ipc;

    if (IS_WIN32) {
        $ipc = $class->_win32(@_);
    } else {
        $ipc = $class->_unix(@_);
    }

    if ($ipc) {
        foreach my $line (@{ $ipc->stdout }) {
            chomp $line;

            if ($line =~ /^([a-zA-Z_0-9]+)\s*=>\s*(.+)/) {
                my ($key, $value) = ($1, $2);
                $value =~ s/^\s+//;
                $value =~ s/\s+\z//;

                if (exists $facts->{$key} || $key =~ /^processor/) {
                    $facts->{$key} = $value;
                }
            }
        }
    }

    return $facts;
}

sub _unix {
    my ($class, $facter) = @_;

    if (!$facter || !-x $facter) {
        $facter = qx{which facter 2>/dev/null};
        chomp $facter;

        if (!$facter || !-x $facter) {
            foreach my $path ("/usr/bin", "/usr/local/bin") {
                if (-x "$path/facter") {
                    $facter = "$path/facter";
                }
            }
        }
    }

    if ($facter && -x $facter) {
        return Bloonix::IPC::Cmd->run(
            command => $facter,
            timeout => 30,
            kill_signal => 9
        );
    }
}

sub _win32 {
    my ($class, $facter) = @_;
    $facter = "facter.rb";

    return Bloonix::IPC::Cmd->run(
        command => $facter,
        timeout => 30,
        kill_signal => 1
    );
}

sub _default {
    my $class = shift;

    return {
        architecture  => "unknown",
        domain  => "unknown",
        facterversion  => "unknown",
        fqdn  => "unknown",
        hardwareisa  => "unknown",
        hardwaremodel  => "unknown",
        hostname  => "unknown",
        id  => "unknown",
        interfaces  => "unknown",
        ipaddress  => "unknown",
        ipaddress_eth0  => "unknown",
        ipaddress_lo  => "unknown",
        is_virtual  => "unknown",
        kernel  => "unknown",
        kernelmajversion  => "unknown",
        kernelrelease  => "unknown",
        kernelversion  => "unknown",
        lsbdistcodename  => "unknown",
        lsbdistdescription  => "unknown",
        lsbdistid  => "unknown",
        lsbdistrelease  => "unknown",
        lsbmajdistrelease  => "unknown",
        memoryfree  => "unknown",
        memorysize  => "unknown",
        memorytotal  => "unknown",
        netmask  => "unknown",
        netmask_eth0  => "unknown",
        netmask_lo  => "unknown",
        network_eth0  => "unknown",
        network_lo  => "unknown",
        operatingsystem  => "unknown",
        operatingsystemrelease  => "unknown",
        osfamily  => "unknown",
        physicalprocessorcount  => "unknown",
        processorcount  => "unknown",
        swapfree  => "unknown",
        swapsize  => "unknown",
        timezone  => "unknown",
        uptime  => "unknown",
        uptime_days  => "unknown",
        uptime_hours  => "unknown",
        uptime_seconds  => "unknown",
        virtual  => "unknown",
    };
}

1;
