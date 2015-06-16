#!perl.exe
use strict;
use warnings;
use FindBin;
use Getopt::Long qw(:config no_ignore_case);

# -----------------------------------------------
# Parameters

my $server;
my $hostkey;

GetOptions(
    "server=s" => \$server,
    "hostkey=s" => \$hostkey
) or exit 1;

# -----------------------------------------------
# Path variables

my $path = $FindBin::Bin;
$path =~ s!/!\\!g;
$path =~ s!\\bloonix\\bin\\*.*!!;

my $config_template = "$path\\bloonix\\tmpl\\main.conf.in";
my $config_file = "$path\\appdata\\etc\\bloonix\\agent\\main.conf";

my $host_config_path = "$path\\appdata\\etc\\bloonix\\agent\\conf.d";

my $agent_template = "$path\\bloonix\\tmpl\\bloonix-agent.in";
my $agent_script = "bloonix-agent.pl";
my $agent_bin = "$path\\bloonix\\bin";

my $nssm_exe = "$path\\strawberry\\perl\\bin\\nssm_32.exe";
my $perl_exe = "$path\\strawberry\\perl\\bin\\perl.exe";
my $c_bin_path = "$path\\strawberry\\c\\bin";

open my $fhd, ">", "$path\\install.log" or die $!;

print $fhd "* paths\n";
print $fhd "starting installation\n";
print $fhd "path: $path\n";
print $fhd "config template: $config_template\n";
print $fhd "config file: $config_file\n";
print $fhd "host config path: $host_config_path\n";
print $fhd "agent template: $agent_template\n";
print $fhd "agent script: $agent_script\n";
print $fhd "nssm exe: $nssm_exe\n";
print $fhd "perl exe: $perl_exe\n";
print $fhd "c bin path: $c_bin_path\n";

$SIG{__DIE__} = sub { print $fhd @_ };

# -----------------------------------------------
# Create directory structure

print $fhd "* directories\n";

my @dirs = qw(
    Bloonix
    Bloonix\bin
    Bloonix\etc
    Bloonix\etc\bloonix
    Bloonix\etc\bloonix\agent
    Bloonix\etc\bloonix\agent\conf.d
    Bloonix\var
    Bloonix\var\log
    Bloonix\var\log\bloonix
    Bloonix\var\run
    Bloonix\var\run\bloonix
    Bloonix\var\tmp
    Bloonix\var\tmp\bloonix
    Bloonix\plugins
    Bloonix\simple-plugins
);

foreach my $dir (@dirs) {
    if (!-d "C:\\ProgramData\\$dir") {
        print $fhd "Creating directory $path\\$dir\n";
        mkdir "C:\\ProgramData\\$dir";
    }
}

if (!-e "$path\\appdata") {
    print $fhd "Create link from \"$path\\appdata\" to C:\\ProgramData\\Bloonix\n";
    system("mklink \"$path\\appdata\" C:\\ProgramData\\Bloonix /D");
}

# -----------------------------------------------
# Install the configuration files

print $fhd "* config files\n";

if (!-e $config_file) {
    print $fhd "Read template $config_template\n";
    open my $in, "<", $config_template or die $!;
    my $config = do { local $/; <$in> };
    close $in;

    $config =~ s/\@\@SETUPPATH\@\@/$path/g;

    if ($server) {
        $config =~ s/\@\@SERVER\@\@/$server/g;
    }

    print $fhd "Write config file $config_file\n";
    open my $out, ">", $config_file or die $!;
    print $out $config;
    close $out;
}

if ($hostkey && $hostkey =~ /^(.+)\.([^\s]+)\z/) {
    my $host_id = $1;
    my $password = $2;

    open my $fh, ">", "$host_config_path\\host-$host_id.conf" or die $!;
    print $fh "host {\n";
    print $fh "    host_id $host_id\n";
    print $fh "    password $password\n";
    print $fh "}\n";
    close $fh;
}

# -----------------------------------------------
# Install bloonix-agent.pl

print $fhd "* service\"\n";

my $service_exists = -e $agent_script;

if ($service_exists) {
    print $fhd "Stop service Bloonix-Agent\n";
    system("\"$nssm_exe\" stop Bloonix-Agent");
}

print $fhd "Read template $agent_template\n";
open my $in, "<", $agent_template or die $!;
my $agent = do { local $/; <$in> };
close $in;

$agent =~ s/\@\@SETUPPATH\@\@/$path/g;

print $fhd "Write script $agent_bin\\$agent_script\n";
open my $out, ">", "$agent_bin\\$agent_script" or die $!;
print $out $agent;
close $out;

if ($service_exists) {
    print $fhd "Start service Bloonix-Agent\n";
    system("\"$nssm_exe\" start Bloonix-Agent");
} else {
    print $fhd "Install service Bloonix-Agent\n";
    system("\"$nssm_exe\" install Bloonix-Agent \"$perl_exe\" \"$agent_script\"");
    system("\"$nssm_exe\" set Bloonix-Agent AppDirectory \"$agent_bin\"");
    if ($server && $hostkey) {
        system("\"$nssm_exe\" start Bloonix-Agent");
    }
}

exit 0;
