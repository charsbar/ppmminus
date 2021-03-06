use strict;
use warnings;
use lib 'lib';
use FindBin;
use File::Path ();
use App::ppmminus;

my $path = "$FindBin::Bin/" . shift;
(my $dir = $path) =~ s{[\\/]?([^\\/]+)$}{};
my ($file) = $1;

File::Path::mkpath($dir, 0, 0777) unless -d $dir;

open my $fh, '<', 'lib/App/ppmminus/script.pm' or die $!;
open my $out, '>', "$dir/$file" or die $!;

print $out <<"PREAMBLE";
#!perl
use strict;
use warnings;

local \$ENV{CYGWIN} = 'nodosfilewarning';

\$App::ppmminus::VERSION = $App::ppmminus::VERSION;

App::ppmminus::script->new->run(\@ARGV);

PREAMBLE

while (<$fh>) {
  next if /^#!.*perl/;
  next if /^use App::ppmminus;/;
  print $out $_;
}
