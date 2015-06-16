#!perl.exe
use strict;
use warnings;
use FindBin;

my $path = $FindBin::Bin;
$path =~ s!/!\\!g;
$path =~ s!\\bloonix\\bin\\*.*!!;
my $nssm_exe = "$path\\strawberry\\perl\\bin\\nssm_32.exe";

system("\"$nssm_exe\" stop Bloonix-Agent");
system("\"$nssm_exe\" remove Bloonix-Agent confirm");

exit 0;
