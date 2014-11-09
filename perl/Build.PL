use strict;
use warnings;
use Module::Build;

my $build = Module::Build->new(
    create_makefile_pl => "traditional",
    module_name => "Bloonix::Agent",
    dist_author => "Jonny Schulz",
    dist_abstract => "Bloonix Agent",
    sign => 0,
    requires => {
        "Bloonix::Core" => 0,
        "Getopt::Long" => 0,
        "JSON" => 0,
        "Log::Handler" => 0,
        "Params::Validate" => 0,
        "Term::ReadKey" => 0,
        "Time::HiRes" => 0
    }
);

$build->create_build_script;
