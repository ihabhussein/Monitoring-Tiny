package Monitoring::Tiny;
use warnings;

if ($^O eq 'linux') {
    sub monitor {
        my %data = (timestamp => $^T);

        return \%data;
    };
1;
