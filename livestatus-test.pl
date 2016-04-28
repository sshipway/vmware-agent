#!/usr/bin/perl

use strict;
use Monitoring::Livestatus;

my($NAGIOS) = 'nagcolprd01.its.auckland.ac.nz';
my($HOST) = 'Nagios';

$HOST = $ARGV[0] if($ARGV[0]);

print "Connecting...\n";
my $livestatus = Monitoring::Livestatus->new(
    peer=>"${NAGIOS}:6557", keepalive=>0,
    errors_are_fatal=>1, warnings=>1,
);
my $cmd = "GET hosts\nColumns: address alias state\nFilter: host_name ~ ^$HOST";
print "Searching...\n";
print "$cmd\n";
my $count = $livestatus->selectscalar_value($cmd);
if( $Monitoring::Livestatus::ErrorCode ) {
	print "ERROR: ".$Monitoring::Livestatus::ErrorMessage."\n";
	exit 1;
}
#my($count) = $#arr;
print "Returned: $count\n";
exit 0;
