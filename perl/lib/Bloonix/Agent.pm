package Bloonix::Agent;

use strict;
use warnings;
use Bloonix::Agent::Validate;
use Bloonix::Worker;
use Bloonix::Facts;
use Bloonix::IPC::Cmd;
use Bloonix::REST;
use Bloonix::HangUp;
use JSON;
use Time::HiRes;

# Y is used for the host id that is processed.
use Log::Handler;
Log::Handler->create_logger("bloonix")->set_pattern("%Y", "Y", "n/a");

# Some quick accessors.
use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/config log json host benchmark worker io dio done reload/);
__PACKAGE__->mk_accessors(qw/poll_interval command_regex is_win32/);
__PACKAGE__->mk_accessors(qw/exitcode allowed_agent_options/);

# The agent version number.
our $VERSION = "0.38";

sub run {
    my $class = shift;
    my $options = Bloonix::Agent::Validate->args(@_);
    my $config = Bloonix::Agent::Validate->config($options->{configfile});
    my $self = bless $options, $class;

    $self->config($config);

    # If the agent runs on win32 than all the cool features
    # like eval or alarm are not available :(
    if ($self->is_win32) {
        return $self->run_win32;
    }

    # If the agent runs on a non win32 operation system...
    $self->run_unix;
}

sub init_base {
    my $self = shift;

    # Valid plugin exit codes.
    $self->exitcode({qw(0 OK 1 WARNING 2 CRITICAL 3 UNKNOWN)});

    # Valid agent options.
    $self->allowed_agent_options({
        map { $_ => 1 } qw(
            timeout kill_signal timeout_status
            unknown_status error_status
        )
    });

    $self->poll_interval(15);
    $self->is_win32($^O =~ /Win32/i ? 1 : 0);
    $self->command_regex(qr!^
        (?:[a-zA-Z_0-9][a-zA-Z_0-9\-]*/)*  # sub directories are allowed
        (?:[a-zA-Z_0-9][a-zA-Z_0-9\-]+     # the command name
            (?:\.[a-zA-Z]+){0,1}           # file extension of the command
        )
    \z!x);

    $self->json(JSON->new);
    $self->dio(Bloonix::REST->new($self->config->{server}));
    $self->done(0);
    $self->reload(0);
    $self->set_env;

    if ($self->config->{benchmark}) {
        $self->benchmark($self->config->{benchmark});
    }
}

sub init_unix {
    my $self = shift;
    my $config = $self->config;

    Bloonix::HangUp->now(
        user => $config->{user},
        group => $config->{group},
        pid_file => $self->{pid_file},
        dev_null => 0
    );

    # Create the directory where the plugins should store its data.
    if ($ENV{PLUGIN_LIBDIR} && !-e $ENV{PLUGIN_LIBDIR}) {
        mkdir $ENV{PLUGIN_LIBDIR}
            or die "unable to create directory '$ENV{PLUGIN_LIBDIR}' - $!";
    }
}

sub init_logger {
    my $self = shift;
    $self->log(Log::Handler->get_logger("bloonix"));
    $self->log->set_default_param(die_on_errors => 0);
    $self->log->config(config => $self->config->{logger});
    $self->log->notice("initializing agent worker");

    # This is the best way to determine dirty code :)
    $SIG{__WARN__} = sub { $self->log->warning(@_) };
    # This is just used to debug the initialisation of the agent
    # and will be removed later on unix systems.
    $SIG{__DIE__} = sub { 
        if (
            $_[0] !~ m!Can't locate object method "tid" via package "threads"! || # from http::tiny
            $_[0] !~ m!Socket version 1\.95 required--this is only version 1\.82! || # from io::socket::ssl
            $_[0] !~ m!Can't locate Socket6\.pm! # from io::socket::ssl
        ) {
            $self->log->warning(@_); 
        } else {
            $self->log->trace(fatal => @_); 
        }
    };
}

sub set_env {
    my $self = shift;

    foreach my $var (keys %{ $self->config->{env} }) {
        $self->log->notice("set env $var =", $self->config->{env}->{$var});
        $ENV{$var} = $self->config->{env}->{$var};
    }
}

sub run_win32 {
    my $self = shift;

    $self->init_logger;
    $self->init_base;

    # On Win32 it's only possible to check
    # the local machine (= one host).
    if (scalar keys %{$self->config->{host}} > 1) {
        die "check multiple hosts is not possible on win32";
    }

    my ($host_id) = keys %{$self->config->{host}};

    if (!defined $host_id) {
        die "there is no active host configured";
    }

    $self->host( $self->config->{host}->{$host_id} );

    # A never ending story :-)
    while ( 1 ) {
        $self->process_check;
        sleep $self->poll_interval;
    }
}

sub run_unix {
    my $self = shift;

    $self->init_logger;
    $self->init_unix;
    $self->init_base;

    my $worker = Bloonix::Worker->new(
        agents => $self->config->{agents},
        sock_file => $self->{sock_file}
    );

    $self->worker($worker);
    $worker->on(init => sub { $self->init_agent(@_) });
    $worker->on(ready => sub { $self->get_ready_hosts(@_) });
    $worker->on(process => sub { $self->process_host(@_) });
    $worker->on(finish => sub { $self->finish_hosts(@_) });
    $worker->on(reload => sub { $self->reload_config(@_) });
    $worker->run;
}

sub init_agent {
    my $self = shift;

    $self->log->notice("child $$ initialized");
}

sub get_ready_hosts {
    my $self = shift;
    my @ready;

    if ($self->benchmark) {
        return $self->get_hosts_for_benchmark(@ready);
    }

    $self->log->debug("checking host list");

    foreach my $host_id (keys %{$self->hosts}) {
        my $host = $self->hosts->{$host_id};

        # Check if the host is already in progress.
        if ($host->{in_progress}) {
            next;
        }

        # Debug how many seconds left to check the host
        $self->log->debug("host $host_id $host->{time} <=", time);

        if ($host->{time} <= time) {
            $self->log->notice("host $host_id ready");
            push @ready, $host;
            $host->{in_progress} = time + 900;
        }
    }

    return @ready;
}

sub get_hosts_for_benchmark {
    my $self = shift;
    my $total = scalar keys %{$self->hosts};
    my $ready = 0;
    my @hosts;

    foreach my $host_id (keys %{$self->hosts}) {
        my $host = $self->hosts->{$host_id};
        if (!$host->{in_progress}) {
            push @hosts, $host;
            $ready++;
        }
    }

    if ($ready != $total) {
        return ();
    }

    $self->log->warning("BENCHMARK: start benchmark for $total hosts in 3 seconds");
    sleep 3;
    $self->log->warning("BENCHMARK: benchmark started");
    $self->{start_benchmark} = Time::HiRes::gettimeofday();
    $self->{next_benchmark_status} = time + 1;
    $self->{hosts_left_to_process} = $total;
    return @hosts;
}

sub process_host {
    my ($self, $host) = @_;

    $self->host($host);
    $self->log->set_pattern("%Y", "Y", "host id $host->{host_id}");

    if ($self->process_checks) {
        $self->worker->send_done;
    } else {
        $self->worker->send_err;
    }

    $self->log->set_pattern("%Y", "Y", "n/a");
}

sub finish_hosts {
    my ($self, @finished) = @_;

    if (!@finished) {
        return;
    }

    if ($self->benchmark) {
        my $total = scalar keys %{$self->hosts};
        my $count = scalar @finished / 3;
        $self->{hosts_left_to_process} -= $count;

        if ($self->{next_benchmark_status} < time) {
            $self->log->warning("BENCHMARK:", $self->{hosts_left_to_process}, "hosts left");
            $self->{next_benchmark_status} = time + 1;
        }

        if ($self->{hosts_left_to_process} == 0) {
            my $time = sprintf("%.3f", Time::HiRes::gettimeofday() - $self->{start_benchmark});
            $self->log->warning("BENCHMARK: processing of $total hosts took ${time}s");
        }
    }

    while (@finished) {
        my $status = shift @finished;
        my $host = shift @finished;
        my $message = shift @finished;

        $host->{in_progress} = 0;

        if (!defined $status || $status !~ /^(ok|err)\z/) {
            $self->log->error("invalid status received: $status");
        }

        $host->{time} = time + $self->poll_interval;
        $self->log->notice("next host check at", $host->{time});
    }
}

sub reload_config {
    my ($self, @hosts) = @_;
    my ($config, @ret);

    $self->log->notice("reloading worker");

    eval { $config = Bloonix::Agent::Validate->config($self->{configfile}) };

    my $err = $@;

    if ($err) {
        $self->log->trace(error => "unable to reload, please check the config file");
        $self->log->trace(error => $err);
        return @hosts;
    }

    my $old_hosts = $self->config->{host};
    my $new_hosts = $config->{host};

    foreach my $host_id (keys %$old_hosts) {
        if (exists $new_hosts->{$host_id}) {
            $new_hosts->{$host_id}->{time} = $old_hosts->{$host_id}->{time};
            $new_hosts->{$host_id}->{pid}  = $old_hosts->{$host_id}->{pid};
        }
    }

    # Parameter agents and section host can be reloaded! For all other
    # parameters and section a restart is necessary.
    $self->config->{host} = $new_hosts;
    $self->config->{agents} = $config->{agents};
    $self->worker->set_agents($config->{agents});

    foreach my $host (@hosts) {
        if ($new_hosts->{ $host->{host_id} }) {
            push @ret, $host;
        }
    }

    $self->log->debug("new config:");
    $self->log->debug(info => $self->config);
    $self->log->notice("reload successfully completed");
    return @ret;
}

sub process_checks {
    my $self = shift;
    my $time = Time::HiRes::gettimeofday();
    my ($return, $data);

    $self->log->notice("start processing host", $self->host->{host_id});

    eval {
        # Maybe the agent has a own server configuration.
        if ($self->host->{server}) {
            my $rest = Bloonix::REST->new($self->host->{server});
            $self->io($rest);
        } else {
            $self->io($self->dio);
        }

        ($return, $data) = $self->collect_statistics;
        $self->send_host_statistics($data);
    };

    if ($@) {
        $self->log->trace(error => $@);
        return undef;
    }

    $time = sprintf("%.6f", Time::HiRes::gettimeofday() - $time);
    $self->log->notice("end processing host (${time}s)");
    return $return;
}

sub collect_statistics {
    my $self = shift;
    my $host_id = $self->host->{host_id};
    my $plugins = $self->config->{plugins};
    my $return = 1;
    my $data = { };

    my $services = $self->get_services($host_id)
        or return undef;

    $self->log->info("collect data for host id $host_id");

    foreach my $service_id (keys %$services) {
        # Send an alive signal before each command execution
        #$self->worker->send_alive;

        my $service = $services->{$service_id};
        my $command = $service->{command};
        my $ipc = $self->execute($service_id => $service);

        if (!$ipc) {
            # The command does not exists!
            $self->log->error("The command '$command' does not exists! Please install the plugin for this command!");
            $data->{$service_id} = {
                status => "UNKNOWN",
                message => "The command '$command' does not exists! Please install the plugin for this command!"
            };
            next;
        }

        my $stdout = $ipc->stdout;
        my $stderr = $ipc->stderr;
        my $exitcode = $ipc->exitcode;
        my $result = $data->{$service_id} = { };

        $self->log->info("checking state of service $service_id command $command");

        # Log stderr output of the plugin as notice!
        if (@$stderr) {
            foreach my $msg (@$stderr) {
                $self->log->notice("stderr:", $msg);
            }
        }

        if ($ipc->timeout) {
            $result->{status} = $service->{timeout_status};
            $result->{message} = $ipc->timeout;
            $result->{tags} = "timeout";
            $self->log->notice("timeout:", $ipc->timeout);
        } elsif ($ipc->unknown) {
            $result->{status} = $service->{unknown_status};
            $result->{message} = $ipc->unknown;
            $self->log->notice("unknown:", $ipc->unknown);
        } elsif ($exitcode !~ /^\d\z/ || $exitcode > 3 || $exitcode < 0) {
            $result->{status} = $service->{error_status};
            $result->{message} = "invalid exit code $exitcode";
            $self->log->warning("exitcode $exitcode:", @$stdout);
        } else {
            if ($return) {
                $return = $exitcode == 0;
            }

            $result->{status} = $self->exitcode->{$exitcode};
            $result->{message} = "the plugin does not return a status message";

            if ($stdout->[0] && $stdout->[0] =~ /^\s*{/) {
                $self->parse_json_plugin_output($result, $stdout);
            } else {
                $self->parse_mixed_plugin_output($service, $result, $service_id, $stdout, $stderr);
            }

            $self->log->info(
                "exitcode $exitcode name $service_id",
                "status $result->{status}",
                "message $result->{message}",
            );
        }

        $self->execute_on_event(
            $self->host->{execute_on_event},
            $result->{status},
            $command,
            $service_id
        );
    }

    if ($self->log->is_debug) {
        $self->log->debug("statistics collected");
        $self->log->dump(debug => $data);
    }

    $self->log->info("data collected");
    return ($return, $data);
}

sub parse_json_plugin_output {
    my ($self, $result, $stdout) = @_;
    my $output;

    eval { $output = $self->json->decode(join("", @$stdout)) };

    if ($@) {
        $result->{status} = "UNKNOWN";
        $result->{message} = "plugin output parser: unable to parse json output";
        $self->log->error("invalid json output:", $@);
    }

    if (ref $output ne "HASH") {
        $result->{status} = "UNKNOWN";
        $result->{message} = "plugin output parser: invalid data structure";
    }

    if ($output->{status} && $output->{status} !~ /^(?:OK|WARNING|CRITICAL|UNKNOWN)\z/) {
        $result->{status} = "UNKNOWN";
        $result->{message} = "plugin output parser: invalid status returned: $output->{status}";
    }

    foreach my $key (keys %$output) {
        $result->{$key} = $output->{$key};
    }
}

sub parse_mixed_plugin_output {
    my ($self, $service, $result, $service_id, $stdout, $stderr) = @_;

    # the first line is the message
    my $message = shift @$stdout || "";

    # store statistics from a bloonix plugin
    my $stats = join("\n", @$stdout);

    if ($message) {
        $result->{message} = $message;
    } elsif (@$stderr) {
        my $errmsg = join(" ", @$stderr);

        if (length $errmsg > 500) {
            $errmsg = substr($errmsg, 0, 497) . "...";
        }

        $result->{message} = $errmsg;
    }

    if ($service->{is_nagios_check}) {
        $self->parse_nagios_stats($result, $message, $service_id);
    } elsif ($stats) {
        $self->parse_plugin_stats($result, $stats);
    }
}

sub execute {
    my ($self, $service_id, $service) = @_;
    my $hostenv = $self->host->{env};

    # Set the host environment
    my %oldenv;

    foreach my $key (keys %$hostenv) {
        $oldenv{$key} = $ENV{$key};
        $ENV{$key} = $hostenv->{$key};
        $self->log->debug("set host env $key = $hostenv->{$key}");
    }

    # Execute the command
    my $ipc = $self->execute_command($service_id => $service);

    # Restore the environment
    foreach my $key (keys %oldenv) {
        $ENV{$key} = $oldenv{$key};
        $self->log->debug("reset host env $key = $oldenv{$key}");
    }

    return $ipc;
}

sub execute_command {
    my ($self, $service_id, $service) = @_;
    my $host_id = $self->host->{host_id};
    my $use_sudo = $self->host->{use_sudo};
    my $main_use_sudo = $self->config->{use_sudo};
    my ($plugins, $sudo, $basedir, %oldenv);

    if ($service->{is_nagios_check}) {
        if (!$self->config->{nagios_plugins}) {
            $self->log->error("no plugin path set for nagios plugins");
            return undef;
        }
        $plugins = $self->config->{nagios_plugins};
    } else {
        $plugins = $self->config->{plugins};
    }

    my $command = $service->{location_options}
        ? "check-by-satellite"
        : $service->{command};

    # sudo is only allowed by some restrictions!
    if ($main_use_sudo->{$command} || $use_sudo->{$command}) {
        $sudo = 1;
    }

    # Search the plugin. Yes, I know, it's possible to set the
    # plugin directories via set PATH variable, but I don't like
    # that because the only place to configure the plugin directory
    # should be the agent directory.
    foreach my $dir (@$plugins) {
        my $command_dir = $self->is_win32 ? "$dir\\$command" : "$dir/$command";
        if (-e $command_dir) {
            $basedir = $dir;
        }
    }

    if (!$basedir) {
        return undef;
    }

    # Store the env from the service to the environment.
    foreach my $key (keys %{ $service->{env} }) {
        $oldenv{$key} = $ENV{$key};
        $ENV{$key} = $service->{env}->{$key};
        $self->log->debug("set service env $key = $service->{env}->{$key}");
    }

    if (!-e $ENV{PLUGIN_LIBDIR}) {
        $self->log->info("create plugin libdir $ENV{PLUGIN_LIBDIR}");
        mkdir $ENV{PLUGIN_LIBDIR};
    }

    # Each service can have its own environment, but the environment
    # from the configuration file will be forced!
    foreach my $var (keys %{ $service->{env} }) {
        $ENV{$var} = $service->{env}->{$var};
    }

    # Store the host id and command name to env,
    # maybe some plugins needs it.
    $ENV{CHECK_HOST_ID} = $host_id;
    $ENV{CHECK_SERVICE_ID} = $service_id;

    if ($self->is_win32) {
        # Wrap basedir/command into double quotation marks
        $command =~ s/^([^\s]+)/$1"/;
        $command = '"'."$basedir\\$command";
    } else {
        $command = "$basedir/$command";
    }

    if ($sudo) {
        $command = "sudo $command";
    }

    my $ipc;

    if ($self->benchmark) {
        $command = "$command --stdin";
        $self->log->info("bloonix check: host id $host_id service $service_id command $command");
        $self->log->info($self->json->encode($service->{command_options}));
        $ipc = $self->benchmark->get_check_result;
    } elsif ($service->{is_nagios_check}) {
        $self->log->info("nagios check: host id $host_id service $service_id command $command");
        $ipc = Bloonix::IPC::Cmd->run(
            command => $command,
            arguments => $service->{command_options},
            timeout => $service->{timeout},
            kill_signal => $service->{kill_signal}
        );
    } elsif ($service->{location_options} && ref $service->{location_options} eq "HASH") {
        my $to_stdin = $self->json->encode({
            locations => $service->{location_options}->{locations},
            check_type => $service->{location_options}->{check_type},
            concurrency => $service->{location_options}->{concurrency},
            service_id => $service_id,
            command => {
                timeout => $service->{timeout},
                command => $service->{command},
                command_options => $service->{command_options}
            }
        });
        $command = "$command --stdin";
        $self->log->info("location check: host id $host_id service $service_id command $command");
        $self->log->info($to_stdin);
        $ipc = Bloonix::IPC::Cmd->run(
            command => $command,
            timeout => 150,
            kill_signal => $service->{kill_signal},
            to_stdin => $to_stdin
        );
    } else {
        my $to_stdin = $self->json->encode($service->{command_options});
        $command = "$command --stdin";
        $self->log->info("bloonix check: host id $host_id service $service_id command $command");
        $self->log->info($to_stdin);
        $ipc = Bloonix::IPC::Cmd->run(
            command => $command,
            timeout => $service->{timeout},
            kill_signal => $service->{kill_signal},
            to_stdin => $self->json->encode($service->{command_options})
        );
    }

    # Restore the environment
    foreach my $key (keys %oldenv) {
        $ENV{$key} = $oldenv{$key};
        $self->log->debug("reset service env $key = $oldenv{$key}");
    }

    return $ipc;
}

sub execute_on_event {
    my ($self, $execute, $service_status, $service_check, $service_id) = @_;

    if (exists $execute->{$service_id} && ref $execute->{$service_id} eq "HASH") {
        $execute = $execute->{$service_id};
    } elsif (exists $execute->{$service_check} && ref $execute->{$service_check} eq "HASH") {
        $execute = $execute->{$service_check};
    } else {
        return;
    }

    my $command = $execute->{command};
    my $status = $execute->{status};

    if (defined $command && defined $status && $status =~ /$service_status/) {
        $command =~ s/%S/$service_status/g;
        $command =~ s/%C/$service_check/g;
        $command =~ s/%I/$service_id/g;

        # Execute the command in the background!
        if ($command !~ /&\s*$/ && !$self->is_win32) {
            $command .= " &";
        }

        $self->log->warning("exeucte on event:", $command);
        system($command);
    }
}

sub parse_nagios_stats {
    my ($self, $result, $stats, $service_id, $nagios_rename) = @_;

    if ($stats !~ s/.+\|//) {
        return;
    }

    my (%stats, %rename, @pairs);
    $stats =~ s/^[\s\r\n]+//;
    $stats =~ s/[\s\r\n]+\z//;
    @pairs = split /\s+/, $stats;

    if ($nagios_rename) {
        foreach my $pair (split /\s+/, $nagios_rename) {
            my ($key, $value) = split /=/, $pair;
            $rename{$key} = $value;
        }
    }

    foreach my $pair (@pairs) {
        my ($key, $value) = split /=/, $pair;

        if (defined $key && defined $value) {
            if ($nagios_rename && exists $rename{$key}) {
                $stats{$rename{$key}} = $value;
            } else {
                $stats{$key} = $value;
            }
        } else {
            $self->log->trace(error => "unable to parse nagios statistics for service id $service_id (pair: $pair)");
        }
    }

    if (scalar keys %stats) {
        $result->{stats} = \%stats;
    }
}

sub parse_plugin_stats {
    my ($self, $result, $stats) = @_;

    $stats =~ s/^[\s\r\n]+//;
    $stats =~ s/[\s\r\n]+\z//;

    # JSON statistics begins with {
    if ($stats =~ /^{/) {
        eval { $stats = $self->json->decode($stats) };

        if ($@) {
            $self->log->trace(error => "unable to de-serialize statistics");
            $self->log->trace(error => $stats);
            $self->log->trace(error => $@);
        } else {
            $result->{stats} = $stats;
        }
    }
}

sub send_host_statistics {
    my ($self, $data) = @_;

    if (!$data || !scalar keys %$data) {
        # That should never happends!
        $self->log->notice("skipping send data to the bloonix server because no data collected");
        return undef;
    }

    # Send an alive signal before send the service data.
    #$self->worker->send_alive;

    # Send the data to the bloonix server.
    $self->log->info("send data to server");
    $self->log->dump(debug => $data);

    if (!$self->benchmark) {
        $self->io->post(
            data => {
                whoami => "agent",
                version => $VERSION,
                host_id => $self->host->{host_id},
                agent_id => $self->host->{agent_id},
                facts => Bloonix::Facts->get(),
                password => $self->host->{password},
                data => $data
            }
        );
    }

    $self->log->notice("data were sent to server");
    #$self->worker->send_alive;
}

sub get_services {
    my ($self, $host_id) = @_;
    my $config = { };

    # Send an alive signal before fetch the service configuration.
    #$self->worker->send_alive;

    # Request the services to check from the bloonix server.
    my $response;

    if ($self->benchmark) {
        $response = $self->benchmark->get_services;
    } else {
        $response = $self->io->get(
            data => {
                whoami => "agent",
                version => $VERSION,
                host_id => $self->host->{host_id},
                agent_id => $self->host->{agent_id},
                password => $self->host->{password},
            }
        );
    }

    if (!defined $response || ref $response ne "HASH" || !defined $response->{status}) {
        $self->log->notice(error => "invalid response received from server");
        $self->log->dump(error => $response);
        return undef;
    }

    if ($response->{status} ne "ok") {
        if (ref $response->{message}) {
            $self->log->error("invalid response from server response:");
            $self->log->dump(error => $response);
        } else {
            $self->log->warning("server response for host id $host_id:", $response->{message});
        }
        return undef;
    }

    if (ref $response->{data} ne "HASH") {
        $self->log->error("invalid data structure received from server");
        return undef;
    }

    my $data = $response->{data};

    if (!exists $data->{services} || ref $data->{services} ne "ARRAY" || !@{$data->{services}}) {
        $self->log->notice("no configuration available");
        return undef;
    }

    foreach my $service (@{$data->{services}}) {
        $self->parse_command_options($service, $config);
    }

    if ($@) {
        $self->log->trace(error => $@);
        $self->log->dump(error => $response);
        return undef;
    } elsif ($self->log->is_debug) {
        $self->log->dump(debug => $response);
    }

    return $config;
}

sub parse_command_options {
    my ($self, $service, $config) = @_;
    my $error;

    if (ref($service) ne "HASH") {
        $error = "invalid config structure";
    } elsif (!defined $service->{service_id} || $service->{service_id} !~ /^\d+\z/) {
        $error = "missing mandatory param service_id";
    } elsif (!defined $service->{command}) {
        $error = "missing mandatory param command";
    } elsif ($service->{command} !~ $self->command_regex) {
        $error = "invalid command '$service->{command}' (config received from server)";
    } elsif ($service->{command_options} && ref $service->{command_options} ne "ARRAY") {
        $error = "invalid command options structure";
    } elsif ($service->{agent_options} && ref $service->{agent_options} ne "HASH") {
        $error = "invalid agent options structure";
    }

    if ($error) {
        $self->log->error($error);
        $self->log->dump(error => $service);
        return;
    }

    my $options = { };
    my $agent_options = {
        command => $service->{command},
        command_options => $options,
        location_options => $service->{location_options}
    };

    my $service_id = $service->{service_id};

    foreach my $opt (@{$service->{command_options}}) {
        if (!exists $opt->{option}) {
            $self->log->error("invalid option array structure: missing key option");
            return;
        }

        my $option = $opt->{option};
        my $value = $opt->{value};

        if (exists $options->{$option}) {
            if (ref $options->{$option} ne "ARRAY") {
                $options->{$option} = [ $options->{$option} ];
            }
            push @{$options->{$option}}, $value;
        } else {
            $options->{$option} = $value;
        }
    }

    foreach my $option (keys %{$service->{agent_options}}) {
        my $value = $service->{agent_options}->{$option};

        if ($self->allowed_agent_options->{$option}) {
            $agent_options->{$option} = $value;
        } else {
            $self->log->warning(
                "option '$option' is configured for service id",
                "$service_id but is not allowed",
            );
        }
    }

    $config->{$service_id} = Bloonix::Agent::Validate->service($agent_options);
}

sub hosts {
    my $self = shift;

    return $self->config->{host};
}

1;
