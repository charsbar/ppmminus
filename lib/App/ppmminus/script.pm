package App::ppmminus::script;

use strict;
use warnings;
use Config ();
use ExtUtils::Install ();
use File::Path ();
use File::Spec;
use Getopt::Long ();
use LWP::UserAgent;

local $ENV{CYGWIN} = 'nodosfilewarning';

Getopt::Long::GetOptions(\my %opts, qw{
  force
  verbose
  dry_run
  area
  server=s
});

$opts{server} ||= 'http://ppm.charsbar.org/api/';

my %extutils;
my %escape = map { chr($_) => sprintf('%%%02X', $_) } (0..255);
my %core;
if (eval{ require Module::CoreList; 1}) {
  no warnings 'once';
  %core = %{$Module::CoreList::version{$]}};
}

my $arch = _my_arch();
my $workdir;

my $ua = LWP::UserAgent->new(env_proxy => 1);

my ($cmd, @args) = @ARGV;

$cmd = '' unless defined $cmd;

if ($cmd eq 'install') {
  _create_workdir();

  my @dists;
  my %seen;
  my %requires;

  while(my $name = shift @args) {
    print "going to install $name\n" if $opts{verbose};
    my $uri = _build_url($opts{server}, {
      c    => 'install',
      arch => $arch,
      name => $name,
    });
    my $res = $ua->get($uri);
    unless ((my $code = $res->code) == 200) {
      if ($code == 404) {
        (my $module = $name) =~ s/::$//;
        my $req_ver = exists $requires{$name}
          ? ($requires{$name} || 0)
          : undef;
        next if defined $req_ver && _its_core($module, $req_ver);
        warn "$name is not found (maybe core?)\n";
        next;
      }
      else {
        die $res->status_line . "\n";
      }
    }
    my $content = $res->decoded_content;
    my $items = eval $content;

DISTLOOP:
    for my $item (@$items) {
      my $name    = $item->{name};
      my $version = $item->{version};
      next if grep { $_->{name} eq $name && ($_->{version} || 0) >= $version } @dists;
      for my $provide (@{$item->{provide} || []}) {
        next DISTLOOP if $requires{$provide->{name}} && $requires{$provide->{name}} > ($provide->{version} || 0);
      }

      push @dists, {
        name     => $name,
        version  => $version,
        codebase => $item->{codebase},
      };
      for my $require (@{$item->{require} || []}) {
        next if $seen{$require->{name}}++;
        push @args, $require->{name};
        $requires{$require->{name}} = $require->{version};
      }
    }
  }

  for my $dist (reverse @dists) {
    my $name = $dist->{name};
    my $uri = $dist->{codebase};
    print "installing $name from $uri\n";

    my ($basename) = $uri =~ m{([^/]+)$};
    my $archive = File::Spec->catfile($workdir, $basename);
    $archive =~ s{\\}{/}g;
    $ua->mirror($uri, $archive);
    my $dir = File::Spec->catdir($workdir, $name);
    $dir =~ s{\\}{/}g;
    if ($basename =~ /\.tar\.gz$/) {
      my $res = _untar($archive, $dir);
    }
    elsif ($basename =~ /\.zip$/) {
      my $res = _unzip($archive, $dir);
    }
    else {
      die "Unknown archive type: $uri";
    }

    # TODO: perlbrew/local_lib support
    my $area = (!$opts{area}) ? 'site'
             : ($opts{area} eq 'perl') ? ''
             : ($opts{area} eq 'vendor') ? 'vendor'
             : 'site';
    my %from_to;
    for my $type (qw/arch bin lib man1 man3 script/) {
      my $subdir = File::Spec->catdir($dir, "blib/$type");
      $from_to{$subdir} = $Config::Config{"install$area$type"}
                       || $Config::Config{"installsite$type"}
                       || $Config::Config{"install$type"};
    }

    ExtUtils::Install::install([
      from_to => \%from_to,
      verbose => $opts{verbose},
      dry_run => $opts{dry_run},
      uninstall_shadows => 0,
      always_copy => $opts{force},
      result => \my %installed,
    ]);
  }
}
else {
  print "Usage: $0 install <Module or Distribution name>\n";
  exit;
}

exit;

# borrowed from PPM::Repositories by D.H. (PodMaster)

sub _my_arch {
  my $arch = $Config::Config{archname};
  if ($] >= 5.008) {
    $arch .= "-$Config::Config{PERL_REVISION}.$Config::Config{PERL_VERSION}";
  }
  return $arch;
}

# borrowed from App::cpanminus by Tatsuhiko Miyagawa

sub _untar {
  if ($extutils{untar}) {
    return $extutils{untar}->(@_);
  }

  my $tar = _which('tar');
  my $tar_ver;
  my $devnull = File::Spec->devnull;
  my $maybe_bad_tar = $tar && ($^O eq 'MSWin32' || $^O eq 'solaris' || (($tar_ver = `$tar --version 2>$devnull`) =~ /GNU.*1\.13/i));

  if ($tar && !$maybe_bad_tar) {
    chomp $tar_ver;
    print "use $tar $tar_ver\n";
    $extutils{untar} = sub {
      my ($file, $into) = @_;

      my $xf = ($opts{verbose} ? 'v' : '') . "zxf";
      my ($root, @others) = `$tar tfz $file` or return;

      chomp $root;
      $root =~ s{/([^/]*)}{};
      system("$tar $xf --directory=$into $file") and die $?;
    };
  }
  elsif ($tar and my $gzip = _which('gzip')) {
    print "use $tar and $gzip\n";
    $extutils{untar} = sub {
      my ($file, $into) = @_;

      my $xf = ($opts{verbose} ? 'v' : '') . "xf -";
      my ($root, @others) = `$gzip -dc $file | $tar tf -` or return;

      chomp $root;
      $root =~ s{/([^/]*)}{};
      File::Path::mkpath($into, $opts{verbose}, 0777);
      system("$gzip -dc $file | $tar $xf --directory=$into") and die $?;
    };
  }
  else {
    # TODO: Archive::Tar
  }
  $extutils{untar}->(@_);
}

sub _unzip {
  if ($extutils{unzip}) {
    return $extutils{unzip}->(@_);
  }

  if (my $unzip = _which('unzip')) {
    print "use $unzip\n";
    $extutils{unzip} = sub {
      my ($file, $into) = @_;

      my $opt = $opts{verbose} ? '' : '-q';
      my (undef, $root, @others) = `$unzip -t $file` or return;

      chomp $root;
      $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

      system("$unzip $opt -d $into $file") and die $?;
    };
  }
  else {
    # TODO: Archive::Zip
  }
  $extutils{unzip}->(@_);
}

my $quote = ($^O eq 'MSWin32') ? q/"/ : q/'/;
sub _quote {
  $_[0] =~ /^${quote}.+${quote}$/ ? $_[0] : "$quote$_[0]$quote";
}

sub _which {
  my $exe = shift;
  my $ext = $Config::Config{exe_ext};
  for my $dir (File::Spec->path) {
    my $fullpath = File::Spec->catfile($dir, $exe);
    if (-x $fullpath or -x ($fullpath .= $ext)) {
      if ($fullpath =~ /\s/ && $fullpath !~ /^$quote/) {
        $fullpath = _quote($fullpath);
      }
      return $fullpath;
    }
  }
  return;
}

sub _create_workdir {
  $workdir = "$ENV{HOME}/.ppmm/download/".time."-$$";
  File::Path::mkpath($workdir, $opts{verbose}, 0777);
}

sub _its_core {
  my ($name, $version) = @_;
  if (exists $core{$name} && ($core{$name} || 0) >= ($version || 0)) {
    return 1;
  }
  return;
}

sub _build_url {
  my ($url, $params) = @_;
  if (%$params) {
    $url .= ($url =~ /\?/) ? '%' : '?';
  }
  $url .= join '&', map { "$_="._uri_escape($params->{$_}) }
                    keys %$params;
  $url;
}

sub _uri_escape {
  my $str = shift;
  $str =~ s/([^A-Za-z0-9\-\._~\/])/$escape{$1} || die sprintf("Can't escape \\x{%04X}", ord $1)/ge;
  $str;
}

END { File::Path::rmtree($workdir) if $workdir && -d $workdir }

__END__

=head1 NAME

ppmm - yet another PPM client

=head1 SYNOPSIS

  $ ppmm install App::ppmminus (module name)
  $ ppmm install App-ppmminus  (distribution name)

=head1 AUTHOR

Kenichi Ishigaki, E<lt>ishigaki@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Kenichi Ishigaki.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut