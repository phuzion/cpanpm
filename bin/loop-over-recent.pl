#!/usr/bin/perl

use strict;
use warnings;
use CPAN::DistnameInfo;
use File::Basename qw(dirname);
use Time::HiRes qw(sleep);
use YAML::Syck;

my $recent = "/home/ftp/pub/PAUSE/authors/id/RECENT-2d.yaml";
my $otherperls = "$0.otherperls";
my $statefile = "$ENV{HOME}/.cpan/loop-over-recent.state";

my $rx = qr!\.(tar.gz|tar.bz2|zip|tgz|tbz)$!;

my @perls = qw(); # we'll fill it at runtime!

my $max_epoch_worked_on = 0;
if (-e $statefile) {
  local $/;
  my $state = do { open my $fh, $statefile or die "Couldn't open '$statefile': $!";
                   <$fh>;
                 };
  chomp $state;
  $state += 0;
  $max_epoch_worked_on = $state if $state;
}
warn "max_epoch_worked_on[$max_epoch_worked_on]";
my $basedir = "/home/sand/CPAN-SVN/logs";
my %comboseen;
ITERATION: while () {
  my $iteration_start = time;
  opendir my $dh, $basedir or die;
  my @perls = sort grep { /^megainstall\..*\.d$/ } readdir $dh;
  pop @perls while ! -e "$basedir/$perls[-1]/perl-V.txt";
  shift @perls while @perls>1;
  {
    open my $fh, "$basedir/@perls/perl-V.txt" or die;
    while (<$fh>) {
      next unless /-Dprefix=(\S+)/;
      @perls = "$1/bin/perl";
      last;
    }
    close $fh;
  }
  shift @perls while @perls && ! -x $perls[0];
  if (open my $fh2, $otherperls) {
    while (<$fh2>) {
      chomp;
      s/#.*//; # remove comments
      next if /^\s*$/; # remove empty/white lines
      next unless -x $_;
      push @perls, $_;
    }
  }
  my($recent_data) = YAML::Syck::LoadFile($recent);
  $recent_data = [ grep { $_->{path} =~ $rx } @$recent_data ];
  {
    my %seen;
    $recent_data = [ grep { my $d = CPAN::DistnameInfo->new($_->{path});
                            !$seen{$d->dist}++
                          } @$recent_data ];
  }
 UPLOADITEM: for my $upload (reverse @$recent_data) {
    next unless $upload->{path} =~ $rx;
    next unless $upload->{type} eq "new";
    # never install stable reporters, they are most probably older
    # than we are
    next if $upload->{path} =~ m!DAGOLDEN/CPAN-Reporter-0\.\d+\.tar\.gz!;
    if ($upload->{epoch} < $max_epoch_worked_on) {
      warn "Already done: $upload->{path}\n" unless keys %comboseen;
      sleep 0.1;
      next UPLOADITEM;
    } elsif ($upload->{epoch} == $max_epoch_worked_on) {
      if ($comboseen{"ALL",$upload->{path}}) {
        next UPLOADITEM;
      }
      warn "Maybe already worked on, we'll retry them: $upload->{path}";
    }
    {
      open my $fh, ">", $statefile or die "Could not open >$statefile\: $!";
      print $fh $upload->{epoch}, "\n";
      close $fh;
    }
    $max_epoch_worked_on = $upload->{epoch};
    my $epoch_as_localtime = scalar localtime $upload->{epoch};
  PERL: for my $perl (@perls) {
      my $perl_version =
          do { open my $fh, "$perl -e \"print \$]\" |" or die "Couldnt open $perl: $!";
               <$fh>;
             };
      my $combo = "|-> '$perl'(=$perl_version) <-> '$upload->{path}' ".
          "<-> '$epoch_as_localtime'(=$upload->{epoch}) <-|";
      if (0) {
      } elsif ($comboseen{$perl,$upload->{path}}){
        warn "dead horses combo $combo";
        sleep 2;
        next PERL;
      } else {
        warn "\n\n$combo\n\n\n";
        my $abs = dirname($recent) . "/$upload->{path}";
        {
          local $| = 1;
          while (! -f $abs) {
            print ",";
            sleep 5;
          }
        }
        $ENV{PERL_MM_USE_DEFAULT} = 1;
        my @system = (
                      $perl,
                      "-Ilib",
                      "-MCPAN",
                      "-e",
                      "install '$upload->{path}'",
                     );
        # 0==system @system or die;
        unless (0==system @system){
          warn "ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN\n";
          warn "      Something went wrong during\n";
          warn "      $perl\n";
          warn "      $upload->{path}\n";
          warn "ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN-ATTN\n";
 	  sleep 30;
        }
        $comboseen{$perl,$upload->{path}} = $upload->{epoch};
      }
    }
    $comboseen{"ALL",$upload->{path}} = $upload->{epoch};
    next ITERATION; # see what is new before simply going through the ordered list
  }
  my $minimum_time_per_loop = 30;
  if (time - $iteration_start < $minimum_time_per_loop) {
    sleep $iteration_start + $minimum_time_per_loop - time;
  }
  for my $k (keys %comboseen) {
    delete $comboseen{$k} if $comboseen{$k} < time - 60*60*24*2;
  }
  { local $| = 1; print "."; }
}

print "\n";
