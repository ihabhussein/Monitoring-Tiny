package Monitoring::Tiny;
use warnings;

our (%cmds, %fields);
require "Monitoring/Tiny/$^O.pm";

sub normalize {
    my $h = shift;
    for my $k (keys %$h) {
        if ($h->{$k} =~ /(\d+(\.\d+)?)(\D)/) {
            my $v = 0 + $1;
            $v *= 1024               if uc $3 eq 'K';
            $v *= 1024 * 1024        if uc $3 eq 'M';
            $v *= 1024 * 1024 * 1024 if uc $3 eq 'G';
            $h->{$k} = $v;
        };
    };
};

sub monitor {
    my %data = (timestamp => $^T);

    for (`$cmds{TOP}`) {
        for my $key (keys %fields) {
            if (/^$key: /) {
                my @k = @{$fields{$key}};
                @{$data{$k[0]}}{@{$k[2]}} = (/$k[1]/);
                next;
            };
        };
    };

    unless (defined $data{MEM}{total}) {
        $data{MEM}{total} = 0 + `$cmds{MEM}`;
    };
    normalize($data{MEM});

    unless (defined $data{SWP}) {
        my @k = @{$fields{SWP}};
        @{$data{SWP}}{@{$k[2]}} = (`$cmds{SWP}` =~/$k[1]/);
    };
    normalize($data{SWP});

    unless (defined $data{DSK}) {
        my @k = @{$fields{DSK}};
        for (`$cmds{DSK}`) {
            next unless /$k[1]/;
            my %z;
            @z{@{$k[2]}} = (/$k[1]/);
            push @{$data{DSK}}, \%z;
        }
    };

    $data{PKG} = [map {chomp; $_} `$cmds{PKG}`];

    return \%data;
};

1;
