#!/usr/bin/env perl

use v5.26;
use Monitoring::Tiny;
# use JSON;

# say encode_json(Monitoring::Tiny::monitor);
# say JSON->new->pretty->encode(Monitoring::Tiny::monitor);

use Data::Dumper;
say Dumper(Monitoring::Tiny::monitor);
