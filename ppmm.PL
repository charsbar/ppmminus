use strict;
use warnings;
use FindBin;
use File::Path ();

my $path = "$FindBin::Bin/" . shift;
(my $dir = $path) =~ s{[\\/]?([^\\/]+)$}{};
my ($file) = $1;

File::Path::mkpath($dir, 0, 0777) unless -d $dir;

open my $fh, '<', 'lib/App/ppmminus/script.pm' or die $!;
open my $out, '>', "$dir/$file" or die $!;
print $out "#!perl\n";
while (<$fh>) {
  next if /^#!.*perl/;
  print $out $_;
}
