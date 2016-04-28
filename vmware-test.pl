#!/usr/bin/perl
##########################################################################

use strict;
use VMware::VIRuntime;
use VMware::VILib;

##########################################################################
# Other configurable options
my($SERVER)='itsvcsprd01.uoa.auckland.ac.nz';
my($USER)='UOA\\nagiosvc-prod';
my($PASS)='startprod@08';
my($TIMEOUT)=5;    # response time in secods
my($DEBUG)=1;

##########################################################################
my($perfmgr);
my(%perfkeys) = ();
my(%perfkeytypes) = ();
my($entity);
my(@queries) = ();
my(@metricids) = ();
my($perfdata);
my($interval) = 0;
my($si_view,$sc_view);

my($vmware);

$|=1;
$SIG{CHLD} = sub { print "SIGCHLD\n" if($DEBUG); };

#########################################################################
sub getcounters($$) {
	my($type) = $_[0];
	my($show)=$_[1];
	# we need to identify which counter is which
	my $perfCounterInfo = $perfmgr->perfCounter;
	print "Identifying perfcounter IDs\n" if($DEBUG>1);
	foreach ( @$perfCounterInfo ) {
		my($rollup) = $_->rollupType->val;
		my($name) = $_->groupInfo->key.":".$_->nameInfo->key;
		my($id) = $_->key;
		print "  $name ($rollup)\n" if($show);
		#next if($_->groupInfo->key !~ /$type/); # optimise
		if($rollup =~ /none|average|summation|latest/) {
			$perfkeys{$name}=$_->key;
			$perfkeys{"$name:$rollup"}=$id;
#			print $name.":".$rollup.'='.$id."\n";
			$perfkeytypes{$name}=$rollup;
			$perfkeys{$id} = $name;
			$perfkeytypes{$id}=$rollup;
		}
	}
}
sub getinterval() {
	# We try to get the interval closest to 5min (the normal polling
	# interval for MRTG)
	print "Retrieving interval data...\n" if($DEBUG>1);
	my $hi = $perfmgr->historicalInterval;
	foreach (@$hi) {
		print "Interval: ".$_->samplingPeriod."\n";
		$interval = $_->samplingPeriod if(!$interval);
		if($_->samplingPeriod == 300) { $interval = 300; last; }
	}
	print "Selected interval is: $interval\n" if($DEBUG);
}
sub makequery($) {
	my ($entities) = $_[0];
	@queries = ();

	foreach my $e ( @$entities ) {
		my $perfquery;
			print "Creating query for ".$e->name."\n" ;
		my (@t) = gmtime(time-$interval); # 5 mins agvl
		my $start = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
			(1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
		@t = gmtime(time);
		my $end   = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
			(1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
		print "Start time: $start\nEnd time  : $end\n" if($DEBUG);
		$perfquery = PerfQuerySpec->new(entity => $e->{mo_ref},
			metricId => \@metricids, intervalId => $interval,
			startTime => $start, endTime => $end );
		push @queries,$perfquery;
	}
}
sub runquery() {
	print "Retrieving data...\n" if($DEBUG);
	eval { $perfdata = $perfmgr->QueryPerf(querySpec => \@queries); };
	if ($@) {
		if (ref($@) eq 'SoapFault') {
			if (ref($@->detail) eq 'InvalidArgument') {
				print "Error: $@\n" if($DEBUG);
				print "Error: ".$@->detail."\n" if($DEBUG);
				return 1;
        		}
		}
		my($msg) = $@; $msg =~ s/^[\n\s]*//;
		print "Error: $msg\n" if($DEBUG);
		return 1;
	}
	if(! @$perfdata) {
		print "No perfdata returned\n" if($DEBUG);
		return 1;
	}
	return 0;
}

#########################################################################

sub getdata($$$) {
	my($vms,$varname,$instance) = @_;
	my(%results) = ();
	my(%rcount) = ();

	print "Retrieving PerfMgr data\n" if($DEBUG);
    $perfmgr = $vmware->get_view(mo_ref=>$sc_view->perfManager)
		if(!$perfmgr);
		
	getcounters('',0);
	getinterval();

	if(!$perfkeys{$varname}) {
		print "Unable to fnd a perf counter '$varname'\n";
		return;
	}

	print "Adding counterId ".$perfkeys{$varname}." instance '$instance' type ".$perfkeytypes{$perfkeys{$varname}}."\n";
	push @metricids, PerfMetricId->new (counterId => $perfkeys{$varname},
		instance => $instance );
	
	makequery($vms);
	return if(runquery());

	print "Perfstats retrieved...\n" if($DEBUG);
	my($idx) = 0;
	foreach my $pd (@$perfdata) {
		if($DEBUG) {
			if( defined $queries[$idx]->entity->{value} ) {
				print "Results for value ".(join ", ",$queries[$idx]->entity->{value})."\n" 
			} else {
				print "Results for name ".$queries[$idx]->entity->name."\n" 
			}
		}
		my $time_stamps = $pd->sampleInfo;
		my $values = $pd->value;
		next if(!$time_stamps or !$values);
		my $nval = $#$time_stamps;
		next if($nval<0);
		print "Perfdata object: ".$time_stamps->[$nval]->timestamp."\n" if($DEBUG);
		foreach my $v (@$values) {
			print "* ".$perfkeys{$v->id->counterId}."=".$v->value->[$nval]."\n";
			$rcount{$v->id->counterId} += 1;
			$results{$v->id->counterId} += $v->value->[$nval];
		}
		$idx+=1;
	}
}

#########################################################################
# MAIN

print "Starting.\n" if($DEBUG);

my($gu) = $ARGV[0];
my($var) = $ARGV[1];

if(!$gu) {
	print "Must give a guest name\n";
	print "Usage: vmware-test.pl guest counter [instance]\n";
	print "guest can be hostname or IP address\n";
	print "Omit counter to get a list of possible counters.\n";
	print "Some counters have instances (eg, CPU) and some dont.\n";
	print "CPU instances are 1...ncpu, net instances are device number (try 2000 up)\n";
	print "Disk instances are of the form scsi0:1 for bus 0, ID 1.\n";
	exit 1;
}

    $vmware = Vim->new(
        service_url => 'https://'.$SERVER.'/sdk/vimService.wsdl',
    );

	print "Connecting\n" if($DEBUG);
    eval {
        alarm( 10 );
        $vmware->login(
            user_name => $USER,
            password => $PASS,
        );
        alarm(0);
    };
    if($@) {
		print "Login failed: $@\n";
		exit 1;
	}

    $si_view = $vmware->get_service_instance();
    print ("Virtual Centre Time : ". $si_view->CurrentTime()."\n");
    $sc_view = $vmware->get_service_content();
    $perfmgr = $vmware->get_view(mo_ref=>$sc_view->perfManager);

if(!$var) {
	print "Must give a var name ( try cpu:usage )\n";
	getcounters('',1);
	exit 1;
}

# Do we need to identify a VM?
	print "Trying to locate $gu\n" if($DEBUG);
	my $vm = $vmware->find_entity_views (view_type => 'VirtualMachine',
		filter => {name => $gu });
	unless(@$vm) {
		print "Now trying as hostname...\n" if($DEBUG);
		$vm = $vmware->find_entity_views (view_type => 'VirtualMachine',
			filter => { 'guest.hostName' => qr/$gu/i });
		foreach ( @$vm ) { # we may have several with same hostname
			print "Guest is ".$_->runtime->powerState->val."\n" if($DEBUG);
			if($_->runtime->powerState->val eq 'poweredOn') {
				@$vm = ( $_ ); # Just keep the active one
				last;
			}
		}
	}
	unless(@$vm) {
		print "Now trying as IP address...\n" if($DEBUG);
		$vm = $vmware->find_entity_views (view_type => 'VirtualMachine',
			filter => { 'guest.ipAddress' => $gu });
#			filter => { 'guest.net[0].ipAddress' => $gu });
		foreach ( @$vm ) { # we may have several with same IP address
			print "Guest is ".$_->runtime->powerState->val."\n" if($DEBUG);
			if($_->runtime->powerState->val eq 'poweredOn') {
				@$vm = ( $_ ); # Just keep the active one
				last;
			}
		}
	}
	unless(@$vm) { 	
		print "Now trying as an ESX Host name...\n";
		$vm = $vmware->find_entity_views (view_type => 'HostSystem',
			filter => { 'name' => $gu });
	}
	unless(@$vm) { 	
		print "Now trying as a Cluster name...\n";
		$vm = $vmware->find_entity_views (view_type => 'ClusterComputeResource',
			filter => { 'name' => $gu });
	}
	unless(@$vm) { 	
		print "Now trying as a Datacentre name...\n";
		$vm = $vmware->find_entity_views (view_type => 'Datacenter',
			filter => { 'name' => $gu });
	}
	unless(@$vm) { 	
		print "Guest not found.\n";
		exit 1;
	}

if($ARGV[2]) {
getdata($vm,$var,$ARGV[2]);
}else {
getdata($vm,$var,'');
}

# Now disconnect from VI
	print "Disconnecting...\n" if($DEBUG);
    eval { $vmware->logout(); };
    if( $@ ) {
        print ("Logging out from VMware failed: $@\n");
    }

exit 0;
