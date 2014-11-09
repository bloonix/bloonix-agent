package Bloonix::CLI;

=head1 NAME

Bloonix::CLI - A simple command line interface for the webgui.

=head1 COPYRIGHT

Copyright (C) 2014 by Jonny Schulz. All rights reserved.

=head1 POWERED BY

     _    __ _____ _____ __  __ __ __   __
    | |__|  |     |     |  \|  |__|\  \/  /
    |  . |  |  |  |  |  |      |  | >    <
    |____|__|_____|_____|__|\__|__|/__/\__\

=cut

use strict;
use warnings;
use Bloonix::REST;
use Term::ReadKey;
use JSON;

use base qw(Bloonix::Accessor);
Bloonix::CLI->mk_accessors(qw/proto host path data timeout limit offset url/);
Bloonix::CLI->mk_accessors(qw/safe_session session_id token_id secret_file rest/);

sub run {
    my ($class, %opts) = @_;
    my $self = bless \%opts, $class;

    $self->validate_options;
    $self->init;

    if ($self->path =~ m!(/|-)(create|update|delete|add|remove)(/|-|$)!) {
        $self->get_token;
    } else {
        if (!defined $self->data->{limit}) {
            $self->data->{limit} = $self->limit;
        }
        if (!defined $self->data->{offset}) {
            $self->data->{offset} = $self->offset;
        }
    }

    my $res = $self->rest->get(
        path => $self->path,
        data => $self->data
    );

    return $res;
}

sub validate_options {
    my $self = shift;

    $self->{limit} //= 25;
    $self->{offset} //= 0;
    $self->{timeout} //= 30;
    $self->{long_life_cookie} //= 0;

    foreach my $key (qw/limit offset timeout save_session/) {
        if (defined $self->{$key} && $self->{$key} !~ /^\d+\z/) {
            die "ERR: invalid value for parameter '$key'\n";
        }
    }

    if ($self->url) {
        if ($self->url =~ m!^(https{0,1})://([a-zA-Z0-9\-\.]+?)(/.*|\z)!) {
            my ($proto, $host, $path) = ($1, $2, $3);
            $path ||= "/";
            $self->proto($proto);
            $self->host($host);
            $self->path($path);
        } else {
            die "ERR: invalid url '$self->{url}'\n";
        }
    } else {
        die "ERR: missing url\n";
    }

    if ($self->data) {
        if (!ref $self->data) {
            eval { $self->data( JSON->new->decode($self->data) ) };
            if ($@) {
                die "ERR: unable to de-serialize json data: $@";
            }
        }
    } else {
        $self->data({});
    }
}

sub init {
    my $self = shift;

    $self->rest(
        Bloonix::REST->new(
            proto => $self->proto,
            host => $self->host,
            timeout => 60,
            autodie => "yes"
        )
    );

    $self->rest->set_post_check(sub {
        my $content = shift;
        if (ref $content ne "HASH" || $content->{status} ne "ok") {
            die JSON->new->pretty->encode($content);
        }
    });

    $self->set_secret_file;
    $self->get_session_id;
}

sub set_secret_file {
    my $self = shift;

    my $home = $ENV{HOME} // (getpwuid($<))[7];

    if (!$home && !-d $home) {
        die "ERR: unable to determine home directory\n";
    }

    $self->secret_file($home ."/.bloonix-api-". $self->host);
}

sub get_session_id {
    my $self = shift;

    if ($self->read_session_id) {
        return;
    }

    $self->request_session_id;
}

sub read_session_id {
    my $self = shift;

    if (open my $fh, "<", $self->secret_file) {
        my $sid = <$fh>;
        close $fh;

        if ($sid && $sid =~ /^[^\s]+\z/) {
            $self->session_id($sid);
        }
    }

    if (!$self->session_id) {
        return undef;
    }

    $self->set_cookie;
    my $res;
    eval { $res = $self->rest->get(path => "/whoami") };

    if (!$res || $res->{status} ne "ok") {
        $self->say($res);
        return undef;
    }

    return 1;
}

sub request_session_id {
    my $self = shift;

    my ($username, $password) = $self->term_read_login_data;

    my $res = $self->rest->post(
        path => "/login",
        data => { username => $username, password => $password }
    );

    $self->say($res);

    if ($res->{status} ne "ok" || !$res->{data}->{sid}) {
        die "ERR: login failed\n";
    }

    $self->session_id($res->{data}->{sid});
    $self->set_cookie;
    $self->safe_session_id;
}

sub safe_session_id {
    my $self = shift;

    if (!$self->safe_session) {
        return;
    }

    if (open my $fh, ">", $self->secret_file or die $!) {
        print $fh $self->session_id;
        close $fh;
    }
}

sub set_cookie {
    my $self = shift;

    $self->rest->set_header(
        Cookie => join("=", sid => $self->session_id)
    );
}

sub term_read_login_data {
    my $self = shift;

    local $SIG{TERM} = $SIG{INT} = $SIG{INT} = sub {
        ReadMode(0);
        die "\ninterrupted\n";
    };

    # safe_session = 0 to suppress the message
    if (!defined $self->safe_session) {
        print "\nNote: use the parameter -S or --safe-session if you want to reuse\n";
        print "      the session ID the next time you use the CLI program.\n";
        print "      The session ID will be safed in ", $self->secret_file, ".\n\n";
    }

    print "\nPlease login to the web interface of bloonix:\n\n";

    print "Type your username: ";
    chomp(my $username = <STDIN>);

    print "Type your password: ";
    ReadMode("noecho");
    chomp(my $password = <STDIN>);
    ReadMode(0);

    print "\n";
    return ($username, $password);
}

sub get_token {
    my $self = shift;

    my $res = $self->rest->get(path => "/token/csrf");

    $self->data->{token} = $res->{data};
}

sub say {
    my ($self, $message) = @_;

    if (ref $message) {
        print JSON->new->pretty->encode($message);
    } elsif ($message) {
        print $message, "\n";
    }
}

1;
