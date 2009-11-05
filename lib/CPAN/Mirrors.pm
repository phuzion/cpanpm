# -*- Mode: cperl; coding: utf-8; cperl-indent-level: 4 -*-
# vim: ts=4 sts=4 sw=4:
package CPAN::Mirrors;
use strict;
use vars qw($VERSION $urllist $silent);
$VERSION = "1";

use Carp;
use FileHandle;
use Fcntl ":flock";

sub new {
    my ($class, $file) = @_;
    my $self = bless { 
        mirrors => [], 
        geography => {},
    }, $class;

    my $handle = FileHandle->new;
    $handle->open($file) 
        or croak "Couldn't open $file: $!";
    flock $handle, LOCK_SH;
    $self->_parse($file,$handle);
    flock $handle, LOCK_UN;
    $handle->close;

    # populate continents & countries

    return $self
}

sub continents {
    my ($self) = @_;
    return keys %{$self->{geography}};
}

sub countries {
    my ($self, @continents) = @_;
    @continents = $self->continents unless @continents;
    my @countries;
    for my $c (@continents) {
        push @countries, keys %{ $self->{geography}{$c} };
    }
    return @countries;
}

sub mirrors {
    my ($self, @countries) = @_;
    return @{$self->{mirrors}} unless @countries;
    my %wanted = map { $_ => 1 } @countries;
    my @found;
    for my $m (@{$self->{mirrors}}) {
        push @found, $m if exists $wanted{$m->country};
    }
    return @found;
}

sub best_mirrors {
    my ($self, %args) = @_;
    my $how_many = $args{how_many} || 1;
    my $callback = $args{callback};
    my $verbose = $args{verbose};

    my %mirrors_seen;
    my %avg;
    CONT: for my $c ( $self->continents ) {
        my @mirrors = $self->mirrors( $self->countries($c) );
        next CONT unless @mirrors;
        my $sample = 10;
        my $n = @mirrors < $sample ? scalar @mirrors : $sample;
        my @tests;
        RANDOM: for ( 0 .. $n-1 ) {
            my $m = splice( @mirrors, int(rand(@mirrors)), 1 );
            my $ping = $m->ping;
            $callback->($m,$ping) if $callback;
            next RANDOM unless defined $ping;
            $mirrors_seen{$m->hostname} = [$m, $ping];
            push @tests, $ping;
        }
        @tests = sort { $a <=> $b} @tests;
        if ( @tests > 5 ) { splice @tests, -2 }
        my $sum = 0;
        $sum += $_ for @tests;
        $avg{$c} = $sum / @tests if @tests;
    }
    
    if ( $verbose ) {
        print "Results by continent\n";
        for my $c ( keys %avg ) {
            printf( "%d ms  %s\n", int($avg{$c}*1000+.5), $c );
        }
        print "\n";
    }

    my @best_cont = sort { $avg{$a} <=> $avg{$b} } keys %avg ;
    @best_cont = shift @best_cont;
    print "Scanning @best_cont\n" if $verbose;

    my @timings;
    for my $m ($self->mirrors($self->countries(@best_cont))) {
        if ( $mirrors_seen{$m->hostname} ) {
            push @timings, $mirrors_seen{$m->hostname};
        }
        else {
            my $ping = $m->ping;
            next unless defined $ping;
            push @timings, [$m, $ping];
            $callback->($m,$ping) if $callback;
        }
    }
    return unless @timings;
    $how_many = @timings if $how_many > @timings;
    my @best =
        map  { $_->[0] }
        sort { $a->[1] <=> $b->[1] } @timings;
    return wantarray ? @best[0 .. $how_many-1] : $best[0];
}

# Adapted from Parse::CPAN::MirroredBy by Adam Kennedy
sub _parse {
    my ($self, $file, $handle) = @_;
    my $output = $self->{mirrors};
    my $geo = $self->{geography};

    local $/ = "\012";
    my $line = 0;
    my $mirror = undef;
    while ( 1 ) {
        # Next line
        my $string = <$handle>;
        last if ! defined $string;
        $line = $line + 1;

        # Remove the useless lines
        chomp( $string );
        next if $string =~ /^\s*$/;
        next if $string =~ /^\s*#/;

        # Hostname or property?
        if ( $string =~ /^\s/ ) {
            # Property
            unless ( $string =~ /^\s+(\w+)\s+=\s+\"(.*)\"$/ ) {
                croak("Invalid property on line $line");
            }
            my ($prop, $value) = ($1,$2);
            $mirror ||= {};
            if ( $prop eq 'dst_location' ) {
                my (@location,$continent,$country);
                @location = (split /\s*,\s*/, $value) 
                    and ($continent, $country) = @location[-1,-2];
                $continent =~ s/\s\(.*//;
                $continent =~ s/\W+$//; # if Jarkko doesn't know latitude/longitude
                $geo->{$continent}{$country} = 1 if $continent && $country;
                $mirror->{continent} = $continent || "unknown";
                $mirror->{country} = $country || "unknown";
            }
            elsif ( $prop eq 'dst_http' ) {
                $mirror->{http} = $value;
            }
            elsif ( $prop eq 'dst_ftp' ) {
                $mirror->{ftp} = $value;
            }
            elsif ( $prop eq 'dst_rsync' ) {
                $mirror->{rsync} = $value;
            }
            else {
                $prop =~ s/^dst_//;
                $mirror->{$prop} = $value;
            }
        } else {
            # Hostname
            unless ( $string =~ /^([\w\.-]+)\:\s*$/ ) {
                croak("Invalid host name on line $line");
            }
            my $current = $mirror;
            $mirror     = { hostname => "$1" };
            if ( $current ) {
                push @$output, CPAN::Mirrored::By->new($current);
            }
        }
    }
    if ( $mirror ) {
        push @$output, CPAN::Mirrored::By->new($mirror);
    }

    return;
}

#--------------------------------------------------------------------------#

package CPAN::Mirrored::By;
use strict;
use Net::Ping   ();

sub new {
    my($self,$arg) = @_;
    $arg ||= {};
    bless $arg, $self;
}
sub hostname { shift->{hostname} }
sub continent { shift->{continent} }
sub country { shift->{country} }
sub http { shift->{http} || '' }
sub ftp { shift->{ftp} || '' }
sub rsync { shift->{rsync} || '' }

sub url { 
    my $self = shift;
    return $self->{http} || $self->{ftp};
}

sub ping {
    my $self = shift;
    my $ping = Net::Ping->new("tcp",1);
    my ($proto) = $self->url =~ m{^([^:]+)};
    my $port = $proto eq 'http' ? 80 : 21;
    return unless $port;
    $ping->port_number($port);
    $ping->hires(1);
    my ($alive,$rtt) = $ping->ping($self->hostname);
    return $alive ? $rtt : undef;
}


1;

