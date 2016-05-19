package Bloonix::Agent;

use strict;
use warnings;
use Bloonix::Agent::Register;
use Bloonix::Agent::Validate;
use Bloonix::Agent::Worker;
use Bloonix::Dispatcher;
use Bloonix::IO::SIPC;
use Bloonix::HangUp;
use JSON;
use Time::HiRes;

# Y is used for the host id that is processed.
use Log::Handler;

# Some quick accessors.
use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/config log json host hosts benchmark dio done reload/);
__PACKAGE__->mk_accessors(qw/poll_interval stash on_hold dispatcher worker measurement/);
__PACKAGE__->mk_accessors(qw/next_progress_status/);
__PACKAGE__->mk_array_accessors(qw/jobs host_queue/);

# The agent version number.
our $VERSION = "0.72";

sub run {
    my $class = shift;
    my $argv = Bloonix::Agent::Validate->args(@_);
    my $self = bless $argv, $class;

    if ($^O =~ /Win32/i ? 1 : 0) {
        $self->init_config;
        $self->init_pid_file;
        $self->init_logger;
        $self->init_env;
        $self->init_objects;
        $self->init_worker;
        $self->worker->poll_interval($self->config->{poll_interval});
        return $self->worker->process_win32;
    }

    $self->init_config;
    $self->init_logger;
    $self->init_env;
    $self->init_objects;
    $self->init_dispatcher;
    $self->init_worker;
    $self->dispatcher->run;
}

sub init_config {
    my $self = shift;

    $self->init_pre_hangup;
    $self->retry_init_config;

    if (!scalar keys %{$self->config->{host}}) {
        while (1) {
            $self->retry_init_config;

            if (scalar keys %{$self->config->{host}}) {
                last;
            }

            sleep 10;
        }
    }

    $self->init_post_hangup;
}

sub retry_init_config {
    my $self = shift;

    my $config = Bloonix::Agent::Validate->config($self->{configfile});
    $self->config($config);
    $self->hosts($config->{host});

    if (
        (!$self->config->{host} || !scalar keys %{$self->config->{host}})
        && -e "/etc/bloonix/agent/register.conf"
    ) {
        Bloonix::Agent::Register->host($config);
    }
}

sub init_logger {
    my $self = shift;

    $self->log(Log::Handler->create_logger("bloonix"));
    $self->log->set_pattern("%Y", "Y", "n/a");
    $self->log->set_default_param(die_on_errors => 0);
    $self->log->set_default_param(timeformat => "%b %d %Y %H:%M:%S");
    $self->log->set_default_param(message_layout => "[%T] %L %P %t %m");
    $self->log->config(config => $self->config->{logger});
    $self->log->notice("initializing dispatcher");

    # This is the best way to determine dirty code :)
    $SIG{__WARN__} = sub { $self->log->warning(@_) };
    # Add a stack trace on die().
    $SIG{__DIE__} = sub {
        if (
            # from http::tiny
            $_[0] !~ m!Can't locate object method "tid" via package "threads"! ||
            # from io::socket::ssl
            $_[0] !~ m!Socket version 1\.95 required--this is only version 1\.82! ||
            # from io::socket::ssl
            $_[0] !~ m!Can't locate Socket6\.pm!
        ) {
            $self->log->warning(@_);
        } else {
            $self->log->trace(fatal => @_);
        }
    };
}

sub init_pre_hangup {
    my $self = shift;

    Bloonix::HangUp->now(
        pid_file => $self->{pid_file},
        dev_null => 0
    );
}

sub init_post_hangup {
    my $self = shift;

    Bloonix::SwitchUser->to(
        $self->config->{user},
        $self->config->{group}
    );
}

sub init_pid_file {
    my $self = shift;
    my $file = $self->{pid_file};

    open my $fh, ">", $file
        or die "unable to open run file '$file': $!";
    print $fh $$
        or die "unable to write to run file '$file': $!";
    close $fh;
}

sub init_env {
    my $self = shift;

    # Create the directory where the plugins should store its data.
    if ($ENV{PLUGIN_LIBDIR} && !-e $ENV{PLUGIN_LIBDIR}) {
        $self->log->notice("create plugin libdir $ENV{PLUGIN_LIBDIR}");
        mkdir $ENV{PLUGIN_LIBDIR}
            or die "unable to create directory '$ENV{PLUGIN_LIBDIR}' - $!";
    }

    foreach my $var (keys %{ $self->config->{env} }) {
        $self->log->notice("set env $var =", $self->config->{env}->{$var});
        $ENV{$var} = $self->config->{env}->{$var};
    }
}

sub init_objects {
    my $self = shift;

    # Backward compability
    my $srvconf = $self->config->{server};
    if ($srvconf->{proto} || $srvconf->{ssl_options}) {
        require Bloonix::REST;
        $self->config->{has_old_server_config} = 1;
        $self->dio(Bloonix::REST->new($self->config->{server}));
    } else {
        $self->dio(Bloonix::IO::SIPC->new($self->config->{server}));
    }

    $self->poll_interval($self->config->{poll_interval});
    $self->json(JSON->new);
    $self->done(0);
    $self->reload(0);
    $self->stash({});
    $self->on_hold({});
    $self->measurement({ time => time, count => 0 });
    $self->next_progress_status(time);
    $self->benchmark($self->config->{benchmark});
}

sub init_dispatcher {
    my $self = shift;

    my $dispatcher = Bloonix::Dispatcher->new(
        worker => $self->config->{agents},
        sock_file => $self->{sock_file}
    );

    $self->dispatcher($dispatcher);
    $self->dispatcher->on(init => sub { $self->log->notice("child $$ initialized") });
    $self->dispatcher->on(ready => sub { $self->get_ready_jobs(@_) });
    $self->dispatcher->on(process => sub { $self->worker->process_unix(@_) });
    $self->dispatcher->on(finish => sub { $self->finish_job(@_) });
    $self->dispatcher->on(reload => sub { $self->reload_config(@_) });
}

sub init_worker {
    my $self = shift;

    $self->worker(Bloonix::Agent::Worker->new);
    $self->worker->version($VERSION);
    $self->worker->config($self->config);
    $self->worker->log($self->log);
    $self->worker->benchmark($self->benchmark);
    $self->worker->json($self->json);
    $self->worker->dio($self->dio);
    $self->worker->dispatcher($self->dispatcher);
}

sub get_ready_jobs {
    my $self = shift;
    my @ready = $self->jobs->get;
    my $in_progress = 0;
    my $new_in_progress = 0;

    $self->jobs->clear;

    if (!$self->check_if_host_or_agent_is_active($self->config->{agent_active_when})) {
        sleep 5;
        return ();
    }

    if ($self->benchmark && !$self->benchmark->noexec_only) {
        push @ready, $self->get_hosts_for_benchmark;
        return @ready;
    }

    $self->log->debug("checking host list");

    foreach my $host_id (keys %{$self->hosts}) {
        my $host = $self->hosts->{$host_id};

        # Check if the host is already in progress.
        if ($host->{in_progress_since}) {
            $in_progress++;
        }
        # Queue the host if the host is not already in the queue
        # and if the host is ready to process.
        elsif (!$host->{in_queue_since} && $host->{time} <= time) {
            if ($self->check_if_host_or_agent_is_active($host->{when}, $host_id)) {
                $self->log->notice("push host $host_id into queue");
                $self->host_queue->push($host_id);
                $host->{in_queue_since} = time;
            } else {
                $host->{time} = time + 15;
            }
        }
    }

    # Only max_concurrent_hosts should be in progress.
    if ($in_progress < $self->config->{max_concurrent_hosts} && $self->host_queue->count) {
        $new_in_progress = 0;

        for ($in_progress + 1 .. $self->config->{max_concurrent_hosts}) {
            my $host_id = $self->host_queue->shift;
            my $host = $self->hosts->{$host_id};
            $host->{in_progress_since} = time;
            $host->{in_queue_since} = 0;
            $new_in_progress++;
            $self->stash->{$host_id} = bless {}, "Bloonix::Agent::Data";
            push @ready, {
                host => $host,
                todo => "get-services"
            };
            last unless $self->host_queue->count;
        }
    }

    $in_progress += $new_in_progress;

    $self->log->debug(
        "BENCHMARK:",
        "hosts in progress:", $in_progress,
        "thereof new:", $new_in_progress,
        "total in queue:", $self->host_queue->count
    );

    if ($self->host_queue->count && $self->next_progress_status < time) {
        $self->next_progress_status(5 + time);
        $self->log->notice("BENCHMARK:", $self->host_queue->count, "hosts in queue");
    }

    return @ready;
}

sub check_if_host_or_agent_is_active {
    my ($self, $when_cmd, $host_id) = @_;

    if (!$when_cmd) {
        return 1;
    }

    my $inactive = 1;

    eval {
        local $SIG{CHLD} = "DEFAULT";
        local $SIG{__DIE__} = sub { alarm(0) };
        local $SIG{ALRM} = sub { die "timeout" };
        alarm(15);
        system($when_cmd);
        $inactive = $? == -1 ? -1 : $? >> 8;
        alarm(0);
    };

    if ($inactive) {
        if ($host_id) {
            $self->log->info(
                "when clause for host $host_id returns",
                $inactive ? "False" : "True", "(ret: $inactive)"
            );
        } else {
            $self->log->info(
                "global when clause returns",
                $inactive ? "False" : "True", "(ret: $inactive)"
            );
        }
    }

    return $inactive ? 0 : 1;
}

sub get_hosts_for_benchmark {
    my $self = shift;
    my $total = scalar keys %{$self->hosts};
    my $in_progress = 0;
    my @hosts;

    if (!$self->host_queue->count) {
        if ($self->{start_benchmark}) {
            my $time = sprintf("%.3f", Time::HiRes::gettimeofday() - $self->{start_benchmark});
            $self->log->warning("BENCHMARK: processed $total hosts in:");
            $self->log->warning("BENCHMARK: ${time}s");
            $self->log->warning("BENCHMARK: --\n");
        }
        $self->host_queue->push(keys %{$self->hosts});
        my $sleep = 5;
        $self->log->warning("BENCHMARK: start benchmark for $total hosts in $sleep seconds");
        sleep $sleep;
        $self->log->warning("BENCHMARK: benchmark started");
        $self->{start_benchmark} = Time::HiRes::gettimeofday();
    }

    foreach my $host_id (keys %{$self->hosts}) {
        if ($self->hosts->{$host_id}->{in_progress_since}) {
            $in_progress++;
        }
    }

    if ($in_progress < $self->config->{max_concurrent_hosts} && $self->host_queue->count) {
        for ($in_progress + 1 .. $self->config->{max_concurrent_hosts}) {
            my $host_id = $self->host_queue->shift;
            my $host = $self->hosts->{$host_id};
            $host->{in_progress_since} = time;
            $in_progress++;
            $self->stash->{$host_id} = bless {}, "Bloonix::Agent::Data";
            push @hosts, {
                host => $host,
                todo => "get-services"
            };
            last unless $self->host_queue->count;
        }
    }

    if (!$self->{next_host_ready_status} || $self->{next_host_ready_status} <= time) {
        $self->{next_host_ready_status} = 2 + time;
        $self->log->warning(
            "BENCHMARK:",
            $self->host_queue->count, "hosts left to process,",
            $in_progress, "hosts in progress"
        );
    }

    return @hosts;
}

sub finish_job {
    my ($self, @finished) = @_;

    while (@finished) {
        my $status = shift @finished;
        my $object = shift @finished;
        my $data = shift @finished;
        my $host = $object->{host};
        my $last_todo = $object->{todo};

        # ToDo workflow:
        #   1. get-services
        #   2. check-service
        #   3. send-data

        if ($status eq "ok" && ref $data eq "HASH") {
            if ($last_todo eq "get-services") {
                $self->handle_todo_check_service($host, $data);
            } elsif ($last_todo eq "check-service") {
                $self->handle_todo_send_data($host, $data);
            }
        } elsif ($host && $host->{host_id}) { # status=err or data=finished
            $self->finish_host($host->{host_id});
        }
    }
}

sub handle_todo_check_service {
    my ($self, $host, $data) = @_;

    my $host_id = $host->{host_id};
    my @on_hold;

    my $max_concurrent_checks = $host->{max_concurrent_checks} 
        || $self->config->{max_concurrent_checks}
        || 4;

    while (my ($service_id, $service) = each %$data) {
        my $job = {
            todo => "check-service",
            host => $host,
            service_id => $service_id,
            service => $service
        };

        if ($max_concurrent_checks) {
            $self->jobs->push($job);
            $max_concurrent_checks--;
        } else {
            push @on_hold, $job;
        }

        $self->stash->{$host_id}->{left}->{$service_id} = 0;
        $self->stash->{$host_id}->{data}->{$service_id} = 0;
    }

    if (@on_hold) {
        $self->on_hold->{$host_id} = \@on_hold;
    }
}

sub handle_todo_send_data {
    my ($self, $host, $data) = @_;

    my $host_id = $host->{host_id};
    my $service_id = $data->{service_id};
    my $left = $self->stash->{$host_id}->{left};

    if (exists $left->{$service_id}) {
        delete $left->{$service_id};
    } else {
        $self->log->warning("service $service_id double checked");
    }

    $self->stash->{$host_id}->{data}->{$service_id} = $data->{result};

    if ($self->on_hold->{$host_id}) {
        $self->jobs->push(shift @{$self->on_hold->{$host_id}});
        if (@{$self->on_hold->{$host_id}} == 0) {
            delete $self->on_hold->{$host_id};
        }
    }

    if (scalar keys %{$self->stash->{$host_id}->{left}} == 0) {
        $self->jobs->push({
            todo => "send-data",
            host => $host,
            data => $self->stash->{$host_id}->{data}
        });
        delete $self->stash->{$host_id};
    }
}

sub finish_host {
    my ($self, $host_id) = @_;

    my $host = $self->hosts->{$host_id};
    delete $self->stash->{$host_id};

    # Maybe the host does not exist any more after a reload.
    if ($host) {
        $host->{in_progress_since} = 0;
        $host->{time} = time + $self->poll_interval;
        $self->log->notice("next check of host id $host->{host_id} at $host->{time}");

        if ($self->measurement->{time} + 5 < time) {
            my $delta_time = time - $self->measurement->{time};
            my $processed = sprintf("%.2f", $self->measurement->{count} / $delta_time);
            $self->log->notice("BENCHMARK: $processed hosts processed per second");
            $self->measurement->{time} = time;
            $self->measurement->{count} = 0;
        }

        $self->measurement->{count}++;
    }
}

sub reload_config {
    my ($self, @ready_jobs) = @_;
    my ($config, @ret);

    $self->log->notice("reloading dispatcher");

    eval { $config = Bloonix::Agent::Validate->config($self->{configfile}) };

    my $err = $@;

    if ($err) {
        $self->log->trace(error => "unable to reload the configuration");
        $self->log->trace(error => $err);
        return @ready_jobs;
    }

    my $old_hosts = $self->config->{host};
    my $new_hosts = $config->{host};

    foreach my $host_id (keys %$old_hosts) {
        if (exists $new_hosts->{$host_id}) {
            $new_hosts->{$host_id}->{in_progress_since} = $old_hosts->{$host_id}->{in_progress_since};
            $new_hosts->{$host_id}->{in_queue_since} = $old_hosts->{$host_id}->{in_queue_since};
            $new_hosts->{$host_id}->{time} = $old_hosts->{$host_id}->{time};
        }
    }

    # Parameter agents and section host can be reloaded! For all other
    # parameters and section a restart is necessary.
    $self->hosts($new_hosts);
    $self->config->{host} = $new_hosts;
    $self->config->{agents} = $config->{agents};
    $self->dispatcher->set_worker($config->{agents});

    # Kick queued hosts
    foreach my $job (@ready_jobs) {
        if ($new_hosts->{ $job->host->{host_id} }) {
            push @ret, $job;
        }
    }

    $self->log->debug("new config:");
    $self->log->debug(info => $self->config);
    $self->log->notice("reload successfully completed");
    return @ret;
}

# Just a pseudo class to cleanup big data objects.
package Bloonix::Agent::Data;

1;
