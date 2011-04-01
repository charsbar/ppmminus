use strict;
use warnings;
use Test::More;
use App::ppmminus::script;

plan skip_all => "your perl is too old to test" if $] < 5.005;

eval { require Module::CoreList; 1 }
  or plan skip_all => "requires Module::CoreList to test";

my @true = (
  ['Config', undef, 'Config is in core'],
  ['Config', 0,     'Config is in core'],
);
my @false = (
  ['Config', '1.0', 'Config 1.0 is not in core (Config version is not defined so far)'],
  ['NonCoreModle', undef, 'NonCoreModule is in core'],
  ['NonCoreModle', 0,     'NonCoreModule is in core'],
  ['NonCoreModle', 1.0,   'NonCoreModule is in core'],
);

plan tests => @true + @false;

App::ppmminus::script::_set_corelist();

for my $t (@true) {
  ok App::ppmminus::script::_is_core($t->[0], $t->[1]), $t->[2];
}
for my $t (@false) {
  ok !App::ppmminus::script::_is_core($t->[0], $t->[1]), $t->[2];
}
