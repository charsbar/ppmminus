package App::ppmminus::script;

use strict;
use warnings;
use Config ();
use ExtUtils::Install ();
use File::Path ();
use File::Spec;
use Getopt::Long ();
use Symbol ();

my (%escape, %core, $quote);

BEGIN {
  %escape = map { chr($_) => sprintf('%%%02X', $_) } (0..255);
  $quote  = ($^O eq 'MSWin32') ? q/"/ : q/'/;
}

sub new {
  my $class = shift;

  _set_corelist();

  bless {
    %{ _get_options() },
    workdir  => undef,
    extutils => {},
    arch     => _my_arch(),
  }, $class;
}

sub DESTROY {
  my $self = shift;
  my $workdir = $self->{workdir};
  File::Path::rmtree($workdir) if $workdir && -d $workdir;
}

sub run {
  my $self = shift;

  my ($cmd, @args) = @ARGV;

  $cmd = '' unless defined $cmd;

  my %mapping = (
    install => \&install,
  );

  if (my $method = $mapping{$cmd}) {
    $self->$method(@args);
  }
  else {
    $self->show_usage;
  }
}

sub install {
  my ($self, @args) = @_;

  my @dists;
  my %seen;
  my %requires;

  while(my $name = shift @args) {
    print "going to install $name\n";
    my $uri = _build_url($self->{server}, {
      c    => 'install',
      arch => $self->{arch},
      name => $name,
    });
    my $content = $self->_get($uri);
    unless ($content) {
      (my $module = $name) =~ s/::$//;
      my $req_ver = exists $requires{$name}
        ? ($requires{$name} || 0)
        : undef;
      next if defined $req_ver && _is_core($module, $req_ver);
      warn "$name is not found (maybe core?)\n";
      next;
    }
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
    my $archive = File::Spec->catfile($self->_workdir, $basename);
    $archive =~ s{\\}{/}g;
    $self->_mirror($uri, $archive);
    my $dir = File::Spec->catdir($self->_workdir, $name);
    $dir =~ s{\\}{/}g;
    if ($basename =~ /\.tar\.gz$/) {
      my $res = $self->_untar($archive, $dir);
    }
    elsif ($basename =~ /\.zip$/) {
      my $res = $self->_unzip($archive, $dir);
    }
    else {
      die "Unknown archive type: $uri";
    }

    # TODO: perlbrew/local_lib support
    my $area = (!$self->{area}) ? 'site'
             : ($self->{area} eq 'perl') ? ''
             : ($self->{area} eq 'vendor') ? 'vendor'
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
      verbose => $self->{verbose},
      dry_run => $self->{dry_run},
      uninstall_shadows => 0,
      always_copy => $self->{force},
      result => \my %installed,
    ]);
  }
}

sub show_usage {
  my $self = shift;
  print "Usage: $0 install <Module or Distribution name>\n";
}

# utils

sub _get_options {
  Getopt::Long::GetOptions(\my %opts, qw{
    force
    verbose
    dry_run
    area
    server=s
    lwp!
    wget!
    curl!
  });

  $opts{server} ||= 'http://ppm.charsbar.org/api/';

  if (!defined $opts{lwp} && !$opts{wget} && !$opts{curl}) {
    $opts{lwp} = 1;
  }

  \%opts;
}

sub _set_corelist {
  if (!%core && eval{ require Module::CoreList; 1}) {
    no warnings 'once';
    %core = %{$Module::CoreList::version{$]}};
  }
}

sub _is_core {
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
  my $self = shift;
  if ($self->{extutils}{untar}) {
    return $self->{extutils}{untar}->(@_);
  }

  my $tar = _which('tar');
  my $tar_ver;
  my $devnull = File::Spec->devnull;
  my $maybe_bad_tar = $tar && ($^O eq 'MSWin32' || $^O eq 'solaris' || (($tar_ver = `$tar --version 2>$devnull`) =~ /GNU.*1\.13/i));

  if ($tar && !$maybe_bad_tar) {
    chomp $tar_ver;
    print "use $tar $tar_ver\n";
    $self->{extutils}{untar} = sub {
      my ($file, $into) = @_;

      my $xf = ($self->{verbose} ? 'v' : '') . "zxf";
      my ($root, @others) = `$tar tfz $file` or return;

      chomp $root;
      $root =~ s{/([^/]*)}{};
      system("$tar $xf --directory=$into $file") and die $?;
    };
  }
  elsif ($tar and my $gzip = _which('gzip')) {
    print "use $tar and $gzip\n";
    $self->{extutils}{untar} = sub {
      my ($file, $into) = @_;

      my $xf = ($self->{verbose} ? 'v' : '') . "xf -";
      my ($root, @others) = `$gzip -dc $file | $tar tf -` or return;

      chomp $root;
      $root =~ s{/([^/]*)}{};
      File::Path::mkpath($into, $self->{verbose}, 0777);
      system("$gzip -dc $file | $tar $xf --directory=$into") and die $?;
    };
  }
  else {
    # TODO: Archive::Tar
  }
  $self->{extutils}{untar}->(@_);
}

sub _unzip {
  my $self = shift;
  if ($self->{extutils}{unzip}) {
    return $self->{extutils}{unzip}->(@_);
  }

  if (my $unzip = _which('unzip')) {
    print "use $unzip\n";
    $self->{extutils}{unzip} = sub {
      my ($file, $into) = @_;

      my $opt = $self->{verbose} ? '' : '-q';
      my (undef, $root, @others) = `$unzip -t $file` or return;

      chomp $root;
      $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

      system("$unzip $opt -d $into $file") and die $?;
    };
  }
  else {
    # TODO: Archive::Zip
  }
  $self->{extutils}{unzip}->(@_);
}

sub _get {
  my $self = $_[0];
  if ($self->{extutils}{get}) {
    return $self->{extutils}{get}->(@_);
  }
  $self->_prepare_client;
  $self->{extutils}{get}->(@_);
}

sub _mirror {
  my $self = $_[0];
  if ($self->{extutils}{mirror}) {
    return $self->{extutils}{mirror}->(@_);
  }
  $self->_prepare_client;
  $self->{extutils}{mirror}->(@_);
}

sub _prepare_client {
  my $self = shift;

  if ($self->{lwp} and eval { require LWP::UserAgent; LWP::UserAgent->VERSION(5.802) }) {
    print "You have LWP::UserAgent $LWP::UserAgent::VERSION.\n";
    my $ua = LWP::UserAgent->new(
      parse_head => 0,
      env_proxy  => 1,
      agent      => "ppmminus/$VERSION",
    );
    $self->{extutils}{get} = sub {
      my ($self, $uri) = @_;
      my $res = $ua->get($uri);
      return unless $res->is_success;
      return $res->decoded_content;
    };
    $self->{extutils}{mirror} = sub {
      my ($self, $uri, $path) = @_;
      my $res = $ua->mirror($uri, $path);
      return $res->code;
    };
  }
  elsif ($self->{wget} and my $wget = _which('wget')) {
    print "You have $wget.\n";
    $self->{extutils}{get} = sub {
      my ($self, $uri) = @_;
      $self->_exec(my $fh, $wget, $uri, ($self->{verbose} ? () : '-q'), '-O', '-') or die "wget $uri: $!";
      local $/;
      <$fh>;
    };
    $self->{extutils}{mirror} = sub {
      my ($self, $uri, $path) = @_;
      $self->_exec(my $fh, $wget, $uri, ($self->{verbose} ? () : '-q'), '-O', $path) or die "wget $uri: $!";
      local $/;
      <$fh>;
    };
  }
  elsif ($self->{curl} and my $curl = _which('curl')) {
    print "You have $curl.\n";
    $self->{extutils}{get} = sub {
      my ($self, $uri) = @_;
      $self->_exec(my $fh, $curl, '-L', ($self->{verbose} ? () : '-s'), $uri) or die "curl $uri: $!";
      local $/;
      <$fh>;
    };
    $self->{extutils}{mirror} = sub {
      my ($self, $uri, $path) = @_;
      $self->_exec(my $fh, $curl, '-L', $uri, ($self->{verbose} ? () : '-s'), '-#', '-o', $path) or die "curl $uri: $!";
      local $/;
      <$fh>;
    };
  }
  else {
    # XXX: fallback to HTTP::Tiny?
    die "requires wget, curl, or LWP::UserAgent";
  }
}

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

sub _workdir {
  my $self = shift;
  return $self->{workdir} if $self->{workdir};

  my $workdir = "$ENV{HOME}/.ppmm/download/".time."-$$";
  File::Path::mkpath($workdir, $self->{verbose}, 0777);
  $self->{workdir} = $workdir;
}

sub _exec {
  my $self = shift;
  my $h = $_[0] ||= Symbol::gensym();

  if ($^O eq 'MSWin32') {
    my $cmd = join ' ', map { _quote($_) } @_[1..$#_];
    return open $h, "$cmd |";
  }

  if (my $pid = open $h, '-|') {
    return $pid;
  }
  elsif (defined $pid) {
    exec @_[1..$#_];
    exit 1;
  }
  else {
    return;
  }
}

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
