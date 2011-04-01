use strict;
use warnings;
use ExtUtils::MakeMaker;

my %params = (
  NAME          => 'App::ppmminus',
  AUTHOR        => 'Kenichi Ishigaki <ishigaki@cpan.org>',
  VERSION_FROM  => 'lib/App/ppmminus.pm',
  ABSTRACT_FROM => 'lib/App/ppmminus.pm',
  LICENSE       => 'perl',
  PREREQ_PM     => {
  },
  BUILD_REQUIRES => {
    'Test::More' => '0.47',
  },
  EXE_FILES => [qw/ppmm/],
  PM => {
    'lib/App/ppmminus.pm' => '$(INST_LIB)/App/ppmminus.pm',
    'lib/App/ppmminus/script.pm' => '$(INST_LIB)/App/ppmminus/script.pm',
  },
  clean => { FILES => 'ppmm' },
  META_MERGE => {
    resources => {
      repository => 'http://github.com/charsbar/ppmminus',
    },
  },
);

my $eumm = $ExtUtils::MakeMaker::VERSION;
delete $params{LICENSE}          if $eumm < 6.31;
delete $params{MIN_PERL_VERSION} if $eumm < 6.48;
delete $params{META_MERGE}       if $eumm < 6.46;
delete $params{META_ADD}         if $eumm < 6.46;
delete $params{LICENSE}          if $eumm < 6.31;

if ($eumm < 6.52 && $params{CONFIGURE_REQUIRES}) {
  $params{PREREQ_PM} = {
    %{ $params{PREREQ_PM}          || {} },
    %{ $params{CONFIGURE_REQUIRES} },
  };
  delete $params{CONFIGURE_REQUIRES};
}
if ($eumm < 6.5503 && $params{BUILD_REQUIRES}) {
  $params{PREREQ_PM} = {
    %{ $params{PREREQ_PM}      || {} },
    %{ $params{BUILD_REQUIRES} },
  };
  delete $params{BUILD_REQUIRES};
}

WriteMakefile(%params);
