package Bloonix::Agent::Worker;

use strict;
use warnings;
use Bloonix::Agent::Validate;
use Bloonix::Facts;
use Bloonix::IPC::Cmd;
use Bloonix::REST;
use Time::HiRes;

# Some quick accessors.
use base qw(Bloonix::Accessor);
__PACKAGE__->mk_accessors(qw/config log json host benchmark worker io dio/);
__PACKAGE__->mk_accessors(qw/command_regex exitcode allowed_agent_options/);
__PACKAGE__->mk_accessors(qw/dispatcher version/);

sub new {
    my ($class, %opts) = @_;
    my $self = bless \%opts, $class;

    # Valid plugin exit codes.
    $self->exitcode({qw(0 OK 1 WARNING 2 CRITICAL 3 UNKNOWN)});

    # Valid agent options.
    $self->allowed_agent_options({
        map { $_ => 1 } qw(
            timeout kill_signal timeout_status
            unknown_status error_status
        )
    });

    $self->command_regex(qr!^
        (?:[a-zA-Z_0-9][a-zA-Z_0-9\-]*/)*  # sub directories are allowed
        (?:[a-zA-Z_0-9][a-zA-Z_0-9\-]+     # the command name
            (?:\.[a-zA-Z]+){0,1}           # file extension of the command
        )
    \z!x);

    return $self;
}

sub process {
    my ($self, $job) = @_;
    my $data;

    $self->host(delete $job->{host});
    $self->log->set_pattern("%Y", "Y", "host id ". $self->host->{host_id});

    if ($job->{todo} eq "get-services") {
        $data = $self->get_services;
    } elsif ($job->{todo} eq "check-service") {
        $data = {
            result => $self->check_service($job->{service_id}, $job->{service}),
            service_id => $job->{service_id}
        };
    } elsif ($job->{todo} eq "send-data") {
        $self->send_host_statistics($job->{data});
        $data = "finished";
    }

    $self->dispatcher->send_done($data);
    $self->log->set_pattern("%Y", "Y", "n/a");
}

sub init_rest {
    my $self = shift;

    eval {
        # Maybe the agent has a own server configuration.
        if ($self->host->{server}) {
            my $rest = Bloonix::REST->new($self->host->{server});
            $self->io($rest);
        } else {
            $self->io($self->dio);
        }
    };

    if ($@) {
        $self->log->trace(error => $@);
    }
}

sub check_service {
    my ($self, $service_id, $service) = @_;
    my $host_id = $self->host->{host_id};
    my $plugins = $self->config->{plugins};
    my $result = {};

    $self->init_rest;
    $self->log->notice("check service for host id $host_id");

    # Send an alive signal before each command execution
    #$self->worker->send_alive;

    my $command = $service->{command};
    my $ipc = $self->execute($service_id => $service);

    if (!$ipc) {
        # The command does not exists!
        $self->log->error("The command '$command' does not exists! Please install the plugin for this command!");
        $result->{status} = "UNKNOWN";
        $result->{message} = "The command '$command' does not exists! Please install the plugin for this command!";
        return $result;
    }

    my $stdout = $ipc->stdout;
    my $stderr = $ipc->stderr;
    my $exitcode = $ipc->exitcode;

    $self->log->notice("checking state of host id $host_id service $service_id command $command");

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

    if ($self->log->is_debug) {
        $self->log->debug("service result:");
        $self->log->dump(debug => $result);
    }

    $self->log->info("service checked");
    return $result;
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
    my $stats;

    if ($message) {
        if ($service->{is_simple_check}) {
            if ($message =~ /^(.+?)\|(.+)/) {
                ($message, $stats) = ($1, $2);
            }
        } else {
            $stats = join("\n", @$stdout);
        }

        $result->{message} = $message;
    } elsif (@$stderr) {
        my $errmsg = join(" ", @$stderr);

        if (length $errmsg > 500) {
            $errmsg = substr($errmsg, 0, 497) . "...";
        }

        $result->{message} = $errmsg;
    }

    if ($stats) {
        if ($service->{is_simple_check}) {
            $self->parse_simple_stats($result, $stats, $service_id);
        } elsif ($stats) {
            $self->parse_plugin_stats($result, $stats);
        }
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

    if ($service->{is_simple_check}) {
        if (!$self->config->{simple_plugins}) {
            $self->log->error("no plugin path set for simple plugins");
            return undef;
        }
        $plugins = $self->config->{simple_plugins};
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
        my $command_dir = "$dir/$command";
        if (-e $command_dir) {
            $basedir = $dir;
        }
    }

    if (!$basedir) {
        # Log $command is necessary to determine if
        # check-by-satellite does not exit.
        $self->log->error("command $command does not exist");
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

    $command = "$basedir/$command";

    if ($sudo) {
        $command = "sudo $command";
    }

    my $ipc;

    if ($self->benchmark) {
        $command = "$command --stdin";
        $self->log->info("bloonix check: host id $host_id service $service_id command $command");
        $self->log->info($self->json->encode($service->{command_options}));
        $ipc = $self->benchmark->get_check_result;
    } elsif ($service->{is_simple_check}) {
        $self->log->info("simple check: host id $host_id service $service_id command $command");
        $self->log->info("$command $service->{command_options}");
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
        if ($command !~ /&\s*$/) {
            $command .= " &";
        }

        $self->log->warning("exeucte on event:", $command);
        system($command);
    }
}

sub parse_simple_stats {
    my ($self, $result, $stats, $service_id) = @_;

    my (%stats, @pairs);
    $stats =~ s/^[\s\r\n]+//;
    $stats =~ s/[\s\r\n]+\z//;

    # Allowed format: a=1 b=2.4 'c d e'=3 f=4.0
    foreach my $pair ($stats =~ /\s*((?:'.+?'|[^\s]+)=[^\s]+)\s*/g) {
        my ($key, $value) = split /=/, $pair;
        $key =~ s/'//g;

        if (defined $key && defined $value) {
            # units will not be removed and can be handled in the webgui
            $value =~ s/;.*//;
            $stats{$key} = $value;
        } else {
            $self->log->trace(error => "unable to parse simple statistics for service id $service_id (pair: $pair)");
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
    $self->init_rest;

    if (!$self->benchmark) {
        $self->io->post(
            data => {
                whoami => "agent",
                version => $self->version,
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
    my $self = shift;
    my $host_id = $self->host->{host_id};
    my $config = { };

    # Send an alive signal before fetch the service configuration.
    #$self->worker->send_alive;
    $self->init_rest;

    # Request the services to check from the bloonix server.
    my $response;

    if ($self->benchmark) {
        $response = $self->benchmark->get_services;
    } else {
        $response = $self->io->get(
            data => {
                whoami => "agent",
                version => $self->version,
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

1;
